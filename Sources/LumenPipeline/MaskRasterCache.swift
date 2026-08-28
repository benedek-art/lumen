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
    private var pending: [String: (key: String, bakeExact: () -> Plane)] = [:]
    private let bakeQueue = DispatchQueue(label: "lumen.maskraster.bake",
                                          qos: .userInitiated)

    /// The raster for `maskID`, exact when the key matches or nothing is held;
    /// otherwise — on a draft frame only — the previous raster while the exact one
    /// bakes in the background.
    func plane(maskID: String, key: String, allowStale: Bool,
               bakeExact: @escaping () -> Plane) -> Plane {
        lock.lock()
        if let held = entries.first(where: { $0.maskID == maskID })?.entry,
           held.key == key {
            lock.unlock()
            Self.count { $0.hits += 1 }
            return held.plane
        }
        let previous = entries.first(where: { $0.maskID == maskID })?.entry.plane
        guard allowStale, let previous else {
            lock.unlock()
            Self.count { $0.bakes += 1 }
            let built = bakeExact()
            store(maskID: maskID, key: key, plane: built)
            return built
        }
        Self.count { $0.staleServes += 1 }
        // Replace, never append: only the newest deferred raster can ever be shown.
        pending[maskID] = (key: key, bakeExact: bakeExact)
        let mustStart = !inFlight.contains(maskID)
        if mustStart { inFlight.insert(maskID) }
        lock.unlock()

        if mustStart { bakeQueue.async { [weak self] in self?.drainPending(maskID) } }
        return previous
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
            store(maskID: maskID, key: next.key, plane: built)
        }
    }

    private func store(maskID: String, key: String, plane: Plane) {
        lock.lock()
        entries.removeAll { $0.maskID == maskID }
        entries.insert((maskID: maskID, entry: Entry(key: key, plane: plane)), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        lock.unlock()
    }
}

#endif
