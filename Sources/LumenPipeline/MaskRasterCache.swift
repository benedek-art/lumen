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
// The key builder in PipelineRenderer describes the selection's full reference
// closure: components, whole-mask inversion and refinement, including disabled donor
// masks; content-addressed stroke refs and availability; and stored matte generation.
// Local adjustments and cosmetic fields do not affect alpha and are excluded. This
// matters even without a larger cache: small native settles and exports fit within
// the existing 1024 px retention limit and must not reuse an obsolete donor selection.
//
// THE SETTLE RUNG (lane M9). Only rasters at or below the draft proxy used to be held,
// so every settle re-rasterized every CPU mask at the render's own resolution — up to
// the 4096 interactive ceiling — even when the edit that triggered it was an adjustment
// slider that changes no pixel of any alpha. On the measuring container that is 0.3–6 s
// of CPU per settle for one refined mask (docs/quality/lanes/M9/REPORT.md), paid again
// on every release of every slider. The key is complete (it names the full reference
// closure, the strokes, the matte generation and, per mask, the picture), so holding a
// settle raster is now only a memory question, and the answer is a byte budget, the
// same shape `BrushPlaneCache`'s settle rung uses: one entry per mask id, newest first,
// trimmed to `settleResidencyBudget`. Deliveries above the interactive ceiling are still
// refused: an export raster at 45 MP is ~180 MB and nothing revisits it.
//
// AND A CHEAP BAKE IS NEVER SERVED STALE. A draft miss used to serve the previous raster
// whatever the bake would cost, so a plain brush stroke committed on mouse-up showed the
// mask WITHOUT the stroke for the next frame and popped in a frame or two later. The
// cache now remembers how long each mask's last bake took, and a draft miss on a mask
// whose bake fits `synchronousBakeBudget` (8 ms in the renderer) bakes in line: exact on the first frame, at
// the price of a few milliseconds the frame can afford. A mask that is expensive to
// bake (a guided refine, an AI matte with Follow) keeps the stale door.

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

    /// What the settle rung may hold, in bytes. A 3:2 frame at the 4096 interactive
    /// ceiling is 4096×2731 Float = 44.7 MB, so this holds four of the largest rasters
    /// an interactive surface asks for; at a 2560 fit settle (17.5 MB) it holds ten.
    /// Against `RenderCoordinator.decodeResidencyBudget` (768 MB) it is a quarter, and
    /// what it buys is a settle that rasterizes nothing when no selection moved.
    static let settleResidencyBudget = 192 * 1024 * 1024

    /// A draft miss bakes in line when this mask's previous bake took no longer than
    /// this, instead of serving the previous raster. The renderer passes
    /// `interactiveSynchronousBakeBudget`; zero (the default) is the old rule, every
    /// draft miss with a previous raster served stale, which the queue tests pin.
    let synchronousBakeBudget: Double

    /// Half a 60 Hz frame: a plain brush or polygon at the 1024 proxy fits on an
    /// M-series Mac, a guided refine does not.
    static let interactiveSynchronousBakeBudget: Double = 8 // ms

    init(synchronousBakeBudget: Double = 0) {
        self.synchronousBakeBudget = synchronousBakeBudget
    }

    /// Whether a raster of this size is one the settle rung will hold.
    static func retains(width: Int, height: Int) -> Bool {
        Swift.max(width, height) <= DraftLadder.interactiveLongEdgeCeiling
            && width * height * MemoryLayout<Float>.stride <= settleResidencyBudget
    }

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
    /// Work already outside the lock cannot be cancelled, but it cannot publish into
    /// a replacement source's cache or alter the new generation's queue bookkeeping.
    private var generation: UInt64 = 0
    private var entries: [(maskID: String, entry: Entry)] = []
    /// The rung above the proxy, kept apart so a few settle-size rasters cannot evict
    /// the draft rasters a drag lives off. One per mask id, newest first.
    private var settled: [(maskID: String, entry: Entry)] = []
    /// Milliseconds the last bake of each mask took, for the synchronous-bake rule.
    private var bakeCost: [String: Double] = [:]
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
        let generation = self.generation
        if let index = entries.firstIndex(where: { $0.maskID == maskID }),
           entries[index].entry.key == key {
            entries[index].entry.identity = identity
            let held = entries[index].entry
            lock.unlock()
            Self.count { $0.hits += 1 }
            return held.plane
        }
        if let index = settled.firstIndex(where: { $0.maskID == maskID }),
           settled[index].entry.key == key {
            settled[index].entry.identity = identity
            let held = settled.remove(at: index)
            settled.insert(held, at: 0)
            lock.unlock()
            Self.count { $0.hits += 1 }
            return held.entry.plane
        }
        let previous = entries.first { $0.maskID == maskID }?.entry
        let cheap = synchronousBakeBudget > 0
            && (bakeCost[maskID] ?? .infinity) <= synchronousBakeBudget
        guard allowStale, !cheap, let previous, previous.identity == identity else {
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
            // A cheap mask's queued draft raster is superseded by this exact one too.
            if cheap { pending.removeValue(forKey: maskID) }
            lock.unlock()
            Self.count { $0.bakes += 1 }
            let built = timedBake(maskID, bakeExact)
            store(maskID: maskID, key: key, identity: identity, plane: built,
                  generation: generation)
            return built
        }
        Self.count { $0.staleServes += 1 }
        // Replace, never append: only the newest deferred raster can ever be shown.
        pending[maskID] = (key: key, identity: identity, bakeExact: bakeExact)
        let mustStart = !inFlight.contains(maskID)
        if mustStart { inFlight.insert(maskID) }
        lock.unlock()

        if mustStart {
            bakeQueue.async { [weak self] in
                self?.drainPending(maskID, generation: generation)
            }
        }
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
        generation &+= 1
        entries.removeAll()
        settled.removeAll()
        bakeCost.removeAll()
        pending.removeAll()
        inFlight.removeAll()
        lock.unlock()
    }

    /// Bytes held by the settle rung. Read by tests.
    var settledBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return settled.reduce(0) { $0 + $1.entry.plane.values.count * MemoryLayout<Float>.stride }
    }

    /// Run a bake and remember what it cost, for the synchronous-bake rule.
    private func timedBake(_ maskID: String, _ bake: () -> Plane) -> Plane {
        let started = DispatchTime.now().uptimeNanoseconds
        let built = bake()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        // Only a draft-rung bake prices the draft rule: a settle bake of the same mask
        // is ~23× the work and says nothing about what the next drag frame would pay.
        guard Swift.max(built.width, built.height) <= PipelineRenderer.maskRasterLongEdge
        else { return built }
        lock.lock()
        bakeCost[maskID] = ms
        if bakeCost.count > 4 * capacity { bakeCost.removeAll() }
        lock.unlock()
        return built
    }

    private func drainPending(_ maskID: String, generation: UInt64) {
        while true {
            lock.lock()
            guard generation == self.generation else {
                lock.unlock()
                return
            }
            guard let next = pending.removeValue(forKey: maskID) else {
                inFlight.remove(maskID)
                lock.unlock()
                return
            }
            lock.unlock()

            let built = timedBake(maskID, next.bakeExact)
            store(maskID: maskID, key: next.key, identity: next.identity, plane: built,
                  generation: generation)
        }
    }

    private func store(maskID: String, key: String, identity: String, plane: Plane,
                       generation: UInt64) {
        // The draft proxy's rasters go to `entries`, count-capped: they are what a drag
        // revisits and what the stale door serves. Anything larger up to the interactive
        // ceiling goes to the byte-budgeted settle rung. Export rasters, above the
        // ceiling, are not held: a single 45 MP raster is ~180 MB of Float plane and a
        // one-shot render never asks for it again.
        let entry = Entry(key: key, plane: plane, identity: identity)
        if Swift.max(plane.width, plane.height) <= PipelineRenderer.maskRasterLongEdge {
            lock.lock()
            guard generation == self.generation else {
                lock.unlock()
                return
            }
            entries.removeAll { $0.maskID == maskID }
            entries.insert((maskID: maskID, entry: entry), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
            lock.unlock()
            return
        }
        guard Self.retains(width: plane.width, height: plane.height) else { return }
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        settled.removeAll { $0.maskID == maskID }
        settled.insert((maskID: maskID, entry: entry), at: 0)
        // Newest first, so this is a prefix scan. An entry that alone exceeds the
        // budget cannot arrive: `retains` refused it above.
        var total = 0
        var kept: [(maskID: String, entry: Entry)] = []
        for held in settled {
            let bytes = held.entry.plane.values.count * MemoryLayout<Float>.stride
            guard total + bytes <= Self.settleResidencyBudget else { break }
            total += bytes
            kept.append(held)
        }
        settled = kept
        lock.unlock()
    }
}

#endif
