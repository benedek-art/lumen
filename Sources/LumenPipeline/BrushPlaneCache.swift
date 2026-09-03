// BrushPlaneCache.swift
// The held brush planes — the piece that stops painting from getting more expensive the
// more you have painted.
//
// `MaskRaster.brushPlane` painted every stroke of a set on every rasterization, so a
// sixty-stroke mask paid sixty strokes on every settle, every export and every draft
// cache miss, and the sixty-first stroke made all sixty-one more expensive (docs/36
// §1.2). `MaskRaster.accumulatedBrushPlane` can resume from a plane that already holds
// a prefix of the set; this is the thing that remembers one.
//
// WHY IT CANNOT KEY ON `strokesRef`. The reference is a content hash of the whole blob,
// so appending one stroke changes it — the append case, which is the only case worth
// optimising, would miss every time. So the key is the COMPONENT's identity
// (`maskID#index`), which survives an append, and the entry carries the strokes it was
// painted from so the prefix relationship can be *checked* rather than assumed:
//
//     held.strokes.count <= now.strokes.count  &&  now.strokes.prefix(n) == held.strokes
//
// That comparison is O(points); painting is O(stamps × stamp area), roughly two orders
// of magnitude more. Any other change — a stroke deleted, an undo, a retro-edit of a
// stroke's feather (docs/36 §1.1) — fails the prefix test and repaints, which is
// correct rather than merely safe.
//
// `sizeKey` and `sourceKey` are in the key for the same reason they are in
// `MaskRasterCache`'s: a plane painted at the draft proxy is not a plane at settle
// resolution, and a stroke drawn with Automask samples the picture, so the same strokes
// over a different exposure are a different plane. A brush WITHOUT automask does not
// read the picture at all, and its `sourceKey` is "-" so a tone edit does not throw the
// painting away.
//
// THE SETTLE RUNG WAS UNREACHABLE, which is the half of docs/36 §1.2 that survived.
//
// This file's own header said "two rungs (draft and settle)" and `store` then refused
// to hold either one of them above `maskRasterLongEdge` — so the settle rung existed in
// the prose and nowhere else. A brush stroke commits on mouse-up (`MaskCanvas`
// publishes `livePoints` to the canvas and the STROKE to the recipe, so the set grows
// by one complete stroke per gesture), the draft frame after it resumes and paints one
// stroke at 1024, and then the settle — which since docs/31 round two §3 rasterizes at
// the render target's own resolution — found nothing to resume from and repainted the
// WHOLE SET at up to 4096 px. Sixty strokes at sixteen times the proxy's pixels, once
// per stroke drawn, on the pass the photographer is actually waiting for. The docs/36
// measurement said a session's painting should track the number of strokes drawn and
// not its square; with the settle rung dropped it tracked the square exactly, one
// resolution up.
//
// WHAT IT ACTUALLY COSTS, MEASURED RATHER THAN REASONED. Painting a 60-stroke set with
// `MaskRaster.accumulatedBrushPlane`, release build, this project's Linux container
// (whose geometry-only combine at 1024 runs 32–45 ms against docs/23 probe (b)'s
// 12.8 ms, so read it as ~2.5–3.5× slower than probe (b)'s box and probe (b)'s note as
// 2–4× slower again than an M-series Mac):
//
//     4096×2731  cold repaint of all 60      34,205 ms
//     4096×2731  resume, paint the 60th         709 ms      48× less
//     2560×1707  cold repaint of all 60       8,485 ms
//
// So the rung this holds is worth roughly 33 s per settle on that container at 4096 and
// 8 s at a fit-view 2560 — call it 0.6–1.7 s per settle on the owner's machine at a fit
// view, against a reported stall of 1.7–3.0 s. It is the largest single term in it.
//
// AND "SIXTEEN TIMES THE PIXELS" UNDERSTATES IT, which is worth writing down because
// every argument in this file and the next reached for that ratio. 4096 is 16.0× the
// pixels of 1024 and, measured, 22–25× the time: a guided refine's radius is itself
// `feather/100 × 0.02 × longEdge` so its window grows with resolution, and even the
// pure per-pixel geometry case (no radius term at all) came in at 24.6×, which is the
// working set falling out of cache. The settle is not 16× the draft. It is about 23×.
//
// So retention above the proxy is a BYTE budget rather than a long edge, and DELIVERIES
// are still refused: an export paints at the export target, a single 45 MP plane is
// ~180 MB, and a one-shot render has nothing to resume into.
// `DraftLadder.interactiveLongEdgeCeiling` is the line between a surface being dragged
// on and a file being written, read from the ladder rather than restated.
//
// `MaskRasterCache` does NOT get the same treatment, and the asymmetry is deliberate
// rather than an oversight: that cache trusts a key completely, and its key does not
// name the masks a `maskRef` component resolves against, so holding its settle rung
// would freeze a referenced selection at whatever the mask it points to last looked
// like. This cache trusts nothing of the sort — the strokes are COMPARED, entry against
// request, and the only trusted term is the picture fingerprint that already gates the
// draft rung. See `MaskRasterCache`'s header for what has to be fixed there.

#if os(macOS)

import Foundation
import LumenCore

final class BrushPlaneCache {

    /// The draft rung's count cap: a handful of components at the 1024 px proxy. A
    /// plane there is ~2.8 MB of Float; twelve is under 35 MB.
    private let capacity = 12

    /// WHAT THE SETTLE RUNG MAY HOLD, IN BYTES — because bytes are what is actually
    /// being bounded and a long edge is a poor proxy for them, which is the argument
    /// `DraftLadder.materializedDecodeByteCeiling` already makes about held decodes.
    ///
    /// The arithmetic, so the number is auditable rather than felt: a 3:2 frame at the
    /// 4096 interactive ceiling is 4096×2731 = 11.2 M Float = 44.7 MB, so this holds two
    /// of the largest planes an interactive surface can ask for; at the 2560 rung a fit
    /// settle on an ordinary display actually uses it holds five, and at 2048, eight.
    /// The same count cap would be 34 MB at the proxy and 537 MB at the ceiling, which
    /// is the whole reason the rule cannot be a count.
    ///
    /// Against `RenderCoordinator.decodeResidencyBudget` (768 MB) and the 512 MB
    /// thumbnail cache this is a small share, and what it buys is the difference between
    /// a settle that repaints sixty strokes and one that paints the stroke just drawn.
    static let settleResidencyBudget = 96 * 1024 * 1024

    private struct Entry {
        var strokes: [BrushStroke]
        var plane: Plane
    }

    private let lock = NSLock()
    /// Insertion-ordered, newest first — the same shape `MaskRasterCache` uses, and for
    /// the same reason: the list is short enough that a linear scan beats a dictionary
    /// plus a separate recency list.
    private var entries: [(key: String, entry: Entry)] = []
    /// The rung above the proxy, split out rather than mixed into `entries` so a
    /// handful of settle-size planes cannot evict the draft rung the drag is living
    /// off. The key already carries `WxH`, so an entry belongs to exactly one of the
    /// two lists and a lookup that misses the first can only ever hit the second.
    private var settled: [(key: String, entry: Entry)] = []

    struct Stats: Equatable, Sendable {
        var resumed = 0
        var repainted = 0
        /// Strokes actually painted since the process started. The number that says
        /// whether this cache is doing its job: with it, a session's total tracks the
        /// number of strokes drawn; without it, the square of it.
        var strokesPainted = 0
    }
    private static let statsLock = NSLock()
    private static var stats = Stats()

    static var currentStats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    private static func count(_ mutate: (inout Stats) -> Void) {
        statsLock.lock()
        mutate(&stats)
        statsLock.unlock()
    }

    /// The painted plane for one brush component, resuming from a held prefix when one
    /// is genuinely a prefix.
    ///
    /// - Parameters:
    ///   - componentKey: `"\(maskID)#\(index)"` — stable across an append, which is
    ///     exactly what `strokesRef` is not.
    ///   - sourceKey: the stage-input fingerprint, or `"-"` when no stroke in the set
    ///     has Automask on and the plane is therefore pure geometry.
    func plane(componentKey: String,
               set: BrushStrokeSet,
               size: (width: Int, height: Int),
               sourceKey: String,
               source: ImageBuffer?) -> Plane {
        let key = "\(componentKey)|\(size.width)x\(size.height)|\(sourceKey)"

        lock.lock()
        var resume: (plane: Plane, strokes: Int)? = nil
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let held = entries[index].entry
            let n = held.strokes.count
            if n <= set.strokes.count, Array(set.strokes.prefix(n)) == held.strokes {
                resume = (plane: held.plane, strokes: n)
                // Touch for recency.
                let moved = entries.remove(at: index)
                entries.insert(moved, at: 0)
            }
        } else if let index = settled.firstIndex(where: { $0.key == key }) {
            let held = settled[index].entry
            let n = held.strokes.count
            if n <= set.strokes.count, Array(set.strokes.prefix(n)) == held.strokes {
                resume = (plane: held.plane, strokes: n)
                let moved = settled.remove(at: index)
                settled.insert(moved, at: 0)
            }
        }
        lock.unlock()

        let painted = set.strokes.count - (resume?.strokes ?? 0)
        Self.count {
            if resume != nil { $0.resumed += 1 } else { $0.repainted += 1 }
            $0.strokesPainted += Swift.max(painted, 0)
        }

        let plane = MaskRaster.accumulatedBrushPlane(strokes: set, size: size,
                                                     source: source, resuming: resume)
        store(key: key, strokes: set.strokes, plane: plane)
        return plane
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        settled.removeAll()
        lock.unlock()
    }

    private func store(key: String, strokes: [BrushStroke], plane: Plane) {
        let entry = Entry(strokes: strokes, plane: plane)
        let long = Swift.max(plane.width, plane.height)
        if long <= PipelineRenderer.maskRasterLongEdge {
            lock.lock()
            entries.removeAll { $0.key == key }
            entries.insert((key: key, entry: entry), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
            lock.unlock()
            return
        }
        // Export-size planes are not held — the surviving half of the rule this
        // retention replaced, and the half of it that was right: a single 45 MP plane is
        // ~180 MB, and a one-shot render has nothing to resume into. The line is drawn
        // at `DraftLadder.interactiveLongEdgeCeiling` because that is where the ladder
        // already draws it — a render asking above it asked to deliver or to inspect,
        // not to be dragged on.
        guard long <= DraftLadder.interactiveLongEdgeCeiling else { return }
        lock.lock()
        settled.removeAll { $0.key == key }
        settled.insert((key: key, entry: entry), at: 0)
        trimSettledLocked()
        lock.unlock()
    }

    /// Bring the settle rung back under `settleResidencyBudget`, oldest first. Called
    /// with `lock` held.
    ///
    /// Newest-first order makes this a prefix scan: keep entries while they fit, drop
    /// the tail.
    ///
    /// A newest entry that does not fit the budget ALONE would empty the whole list —
    /// the scan breaks at the first miss, so nothing behind it is reached. That is not
    /// a case this rung can be in, and the bound is `store`'s rather than this
    /// function's: nothing above `DraftLadder.interactiveLongEdgeCeiling` is offered
    /// here at all, and the largest plane under it is a square 4096 × 4096 = 67 MB
    /// against a 96 MB budget. If that ceiling ever rises past a plane of
    /// `settleResidencyBudget`, this loop needs to skip the oversized entry rather than
    /// stop at it — stated here because the failure would look like a cache that
    /// mysteriously holds nothing.
    private func trimSettledLocked() {
        var total = 0
        var kept: [(key: String, entry: Entry)] = []
        for held in settled {
            let bytes = held.entry.plane.values.count * MemoryLayout<Float>.stride
            guard total + bytes <= Self.settleResidencyBudget else { break }
            total += bytes
            kept.append(held)
        }
        settled = kept
    }
}

#endif
