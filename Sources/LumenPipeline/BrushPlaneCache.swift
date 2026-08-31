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

#if os(macOS)

import Foundation
import LumenCore

final class BrushPlaneCache {

    /// Two rungs (draft and settle) for a handful of components. A 1024 px plane is
    /// ~2.8 MB of Float; twelve is under 35 MB, and settle-size planes are not held
    /// (see `store`), for the same reason `MaskRasterCache` does not hold them.
    private let capacity = 12

    private struct Entry {
        var strokes: [BrushStroke]
        var plane: Plane
    }

    private let lock = NSLock()
    /// Insertion-ordered, newest first — the same shape `MaskRasterCache` uses, and for
    /// the same reason: the list is short enough that a linear scan beats a dictionary
    /// plus a separate recency list.
    private var entries: [(key: String, entry: Entry)] = []

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
        lock.unlock()
    }

    private func store(key: String, strokes: [BrushStroke], plane: Plane) {
        // Export-size planes are not held, the same rule `MaskRasterCache` applies:
        // a single 45 MP plane is ~180 MB, and an export is a one-shot anyway.
        guard Swift.max(plane.width, plane.height) <= PipelineRenderer.maskRasterLongEdge
        else { return }
        lock.lock()
        entries.removeAll { $0.key == key }
        entries.insert((key: key, entry: Entry(strokes: strokes, plane: plane)), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        lock.unlock()
    }
}

#endif
