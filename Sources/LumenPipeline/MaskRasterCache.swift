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
//
// WHY THE SETTLE RUNG IS STILL NOT HELD, WRITTEN DOWN SO IT STOPS BEING RE-DISCOVERED.
//
// `store` refuses every raster above the draft proxy, so a settle — which since docs/31
// round two §3 rasterizes at the render target's own resolution — re-folds every mask
// in the stack from nothing, every time, at up to sixteen times the proxy's pixels.
// That is the larger half of the 1.7–3.0 s settle after a mask edit, and holding it
// looks like a two-line change: route anything up to
// `DraftLadder.interactiveLongEdgeCeiling` into a second, byte-budgeted list and serve
// it on an exact key hit.
//
// It is not legal yet, and the reason is in the KEY rather than in this file. THE KEY
// IS NOT A COMPLETE FUNCTION OF THE RASTER. A `maskRef` component's alpha is another
// mask's finished alpha — `MaskRaster.referenced` resolves it against `plan.allMasks`,
// deliberately, including masks that are switched off — and neither that mask's
// definition nor its stroke set appears anywhere in this mask's key
// (`PipelineRenderer.maskRasterKey`: the photograph, THIS mask's JSON, the size, THIS
// mask's stroke refs, the matte kind names, the picture fingerprint). So editing mask A
// changes mask B's raster without moving B's key.
//
// Today that under-key is survivable precisely BECAUSE the settle rung is thrown away:
// a draft frame can show B stale, and the settle re-folds B from nothing and repairs
// it. Hold the settle rung and the repair stops happening — B's referenced selection
// freezes at whatever A last looked like, in the loupe and in the delivered file, with
// nothing badged. A cache that changes the settled picture is not an optimisation, and
// no eviction rule inside this class can fix it: the missing dependency is invisible
// from here, and the mask that carries it (a disabled mask, held only in `allMasks`) is
// never a client of this cache at all, so it can never announce that it changed.
//
// The prerequisite is one change in the key builder, not here: `maskJSON` must become a
// RASTER identity — the mask's components, whole-mask invert and refine chain, CLOSED
// OVER every mask reachable through `maskRef` and their stroke sets. That also removes
// the opposite defect in the same term, which costs a bake on every event of every
// drag: `maskJSON` today is the WHOLE mask, so `adjust`, `amount`, `enabled`, `blend`,
// `name` and `group` are all in the key, and not one of them touches the raster
// (`MaskAlgebra`'s header and `MaskRaster.combine`'s both say so outright). Dragging a
// mask's own Exposure slider therefore invalidates its raster on every mouse event and
// re-folds it at settle resolution on release, for an edit that cannot change a pixel
// of it.

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
            // A SETTLE CANCELS THE DRAG'S LEFTOVER RASTER.
            //
            // `pending` is populated by the stale branch below and by nothing else, so
            // anything queued here is a DRAFT-rung raster for a frame of a gesture that
            // has just ended — a frame no one will ask for again, since the next thing
            // the viewer does is show the settle. Left in the queue it runs concurrently
            // with the bake on the next line, and the two are scalar passes over planes
            // large enough that they contend for memory bandwidth rather than sharing
            // idle cores, while the photographer waits for exactly one of them. Probe
            // (b)'s numbers say that is 12.8–190 ms of a core spent against the pass
            // being waited on, per mask, at the end of every drag.
            //
            // Dropping it is free in the only sense that matters: `pending` is a
            // deferral, never a promise, and a draft that does ask for that key again
            // simply bakes it — the same thing it would have done had the queue not
            // reached it in time.
            if !allowStale { pending.removeValue(forKey: maskID) }
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
        //
        // The settle rung between those two is the one this rule throws away for a
        // reason that is no longer the memory argument; see the header for what has to
        // change in the KEY before it can be held, and why no rule inside this class
        // can substitute for that.
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
