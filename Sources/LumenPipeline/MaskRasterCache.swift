// MaskRasterCache.swift
// The mask rasters, kept across frames — the piece that makes running S11 in every
// draft affordable.
//
// docs/23's probe (b) measured MaskRaster.combine at the 1024 px proxy: 12.8 ms for a
// geometry-only stack and 105–190 ms through the guided refine chain, in a release
// build. A drag frame's whole budget is ~35 ms, so re-rasterizing a refined mask per
// mouse event is not an optimisation problem, it is impossible — and the old answer,
// dropping every mask from every draft, is the "picture jumps on release" defect this
// cache exists to end.
//
// Same shape as `PlanTableCache.tableAllowingStale`, per mask id instead of per slot:
// an exact key hit returns the held raster; a miss on a DRAFT frame returns the mask's
// previous raster while the exact one bakes on a background queue, single-flight per
// mask, newest request winning; a miss with no previous raster bakes synchronously
// (first sight of a mask costs one raster, not a frame with the mask absent); and a
// settle or export frame never comes through the stale door at all.
//
// What "one raster stale" means on screen: dragging Exposure, a luma-range mask's
// EDGE placement lags the tones by one gesture and snaps at the pause — while the
// mask's adjustment contributes to every frame. Dragging the mask's own feather, the
// edge animates at the bake rate (5–10 Hz for a refined mask) behind a full-rate
// picture. Both beat the mask not being there at all, which is what shipped.

#if os(macOS)

import Foundation
import LumenCore

/// Public for its `Stats` surface alone (the HUD's counters); the raster machinery
/// stays internal to the pipeline for the same reason PlanTableCache's does.
public final class MaskRasterCache {

    /// A handful of photographs' worth of masks. A raster at the 1024 px proxy is a
    /// single-channel Float plane, ~2.8 MB; sixteen is under 45 MB and old photos'
    /// masks age out instead of accumulating for the life of the process.
    private let capacity = 16

    private struct Entry {
        var key: String
        var plane: Plane
        /// The photograph this raster last rendered — the same identity discipline
        /// `PlanTableCache` carries (docs/31 round two §4), because this cache has
        /// the same door: mask ids travel verbatim across photographs via Paste
        /// Settings, so "this mask id's previous raster" can be a DIFFERENT
        /// photograph's rasterized selection. A draft frame may ride a stale raster
        /// of its own photograph; it must never wear another photograph's.
        var identity: String
    }

    // MARK: Counters (docs/23 M1b: cache-hit counters on the HUD)

    /// Static on purpose: the app owns one renderer and the HUD wants one number,
    /// not a per-instance ledger it would have to plumb through three actors.
    public struct Stats: Equatable, Sendable {
        public var hits = 0
        public var bakes = 0
        public var staleServes = 0
    }
    private static let statsLock = NSLock()
    private static var stats = Stats()

    public static var currentStats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    private static func count(_ mutate: (inout Stats) -> Void) {
        statsLock.lock()
        mutate(&stats)
        statsLock.unlock()
    }

    private let lock = NSLock()
    private var entries: [(maskID: String, entry: Entry)] = []
    private var inFlight: Set<String> = []
    private var pending: [String: (key: String, identity: String,
                                   bakeExact: () -> Plane)] = [:]
    private let bakeQueue = DispatchQueue(label: "lumen.maskraster.bake",
                                          qos: .userInitiated)

    /// The raster for `maskID`, exact when the key matches or nothing is held;
    /// otherwise — on a draft frame only, and only for the SAME photograph — the
    /// previous raster while the exact one bakes in the background.
    ///
    /// `identity` is the photograph being rendered. An exact key hit is served to
    /// any photograph (the key contains the file url wherever pixels are read, so
    /// an exact hit cannot lie) and the entry adopts the identity; the stale
    /// borrow requires it to MATCH, so a photo switch renders its masks fresh
    /// rather than wearing the previous photograph's selection for a frame.
    func plane(maskID: String, key: String, identity: String, allowStale: Bool,
               bakeExact: @escaping () -> Plane) -> Plane {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.maskID == maskID }),
           entries[index].entry.key == key {
            entries[index].entry.identity = identity
            let held = entries[index].entry
            lock.unlock()
            Self.count { $0.hits += 1 }
            return held.plane
        }
        let previous = entries.first { $0.maskID == maskID }?.entry
        guard allowStale, let previous, previous.identity == identity else {
            lock.unlock()
            Self.count { $0.bakes += 1 }
            let built = bakeExact()
            store(maskID: maskID, key: key, identity: identity, plane: built)
            return built
        }
        Self.count { $0.staleServes += 1 }
        // Replace, never append: only the newest deferred raster can ever be shown.
        pending[maskID] = (key: key, identity: identity, bakeExact: bakeExact)
        let mustStart = !inFlight.contains(maskID)
        if mustStart { inFlight.insert(maskID) }
        lock.unlock()

        if mustStart { bakeQueue.async { [weak self] in self?.drainPending(maskID) } }
        return previous.plane
    }

    /// True while a background raster (or a queued one) is outstanding for `maskID`.
    func hasPendingBake(_ maskID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.contains(maskID) || pending[maskID] != nil
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        pending.removeAll()
        lock.unlock()
    }

    private func drainPending(_ maskID: String) {
        while true {
            lock.lock()
            guard let next = pending.removeValue(forKey: maskID) else {
                inFlight.remove(maskID)
                lock.unlock()
                return
            }
            lock.unlock()

            let built = next.bakeExact()
            store(maskID: maskID, key: next.key, identity: next.identity, plane: built)
        }
    }

    private func store(maskID: String, key: String, identity: String, plane: Plane) {
        // Rasters above the draft proxy are not held, the same rule
        // `PlanTableCache` applies to export-size bakes: settle and export rasters
        // now come at the RENDER's resolution (docs/31 round two §3), and a single
        // 45 MP export raster is ~180 MB of Float plane — sixteen of those is not a
        // cache, it is a leak. The proxy-sized draft rasters are the ones a drag
        // actually revisits, and they still land here.
        guard Swift.max(plane.width, plane.height) <= PipelineRenderer.maskRasterLongEdge
        else { return }
        lock.lock()
        entries.removeAll { $0.maskID == maskID }
        entries.insert((maskID: maskID,
                        entry: Entry(key: key, plane: plane, identity: identity)),
                       at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        lock.unlock()
    }
}

#endif
