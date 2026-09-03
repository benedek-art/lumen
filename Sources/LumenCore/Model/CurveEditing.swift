// CurveEditing.swift
// The arithmetic behind the tone curve editor's direct manipulation — everything that
// decides WHICH point a press took hold of, WHERE that point is allowed to go, whether
// it may be removed, and what the readout says about it.
//
// It lives here rather than in `CurveEditorView` because none of it is drawing. A curve
// editor is the surface where every property a gesture can get wrong is reachable in one
// second of hand movement — a point that crosses its neighbour, an anchor deleted by
// accident, a hit target smaller than the ink — and until this file existed every one of
// those rules sat as a `private static` inside a `#if os(macOS)` SwiftUI view, which is
// the one place in this repository nothing can be tested. `MonotoneCubic` (the
// interpolation) and `CurveStack` (the bake) have always been here; the EDITING half was
// the part with no test and it is the half a hand touches.
//
// The rules, stated once:
//   · A point's x is clamped strictly inside its neighbours' window, so the array stays
//     sorted and the index a drag is holding stays the point the user grabbed. Crossing
//     is not merely ugly — `MonotoneCubic` drops a duplicate x outright, so a crossed
//     pair would silently become one point and the drag would be holding an index that
//     no longer means what it meant.
//   · The FIRST and LAST points are the curve's black and white anchors and cannot be
//     deleted. `MonotoneCubic` extends flat outside `[x_first, x_last]`, so a curve that
//     has lost its anchor at 0 renders every shadow below the new first point as one
//     identical value — a posterized block, produced by a gesture whose only intent was
//     to remove a point, and recoverable only by flattening the whole curve.
//   · Hit tolerance is stated in the plot's own pixels and converted here, so the target
//     can be larger than the drawn point without the two geometries being written twice.
//
// Everything is expressed in the graph's normalized space (x and y both 0…1, y up) with
// tolerances passed in as fractions of the plot, because LumenCore may not import
// CoreGraphics and because the unit square is the only coordinate system the curve
// itself is denominated in.

import Foundation

public enum CurveEditing {

    // MARK: - Constants

    /// The window a dragged point keeps clear of each neighbour.
    ///
    /// It has to be strictly positive rather than zero: `MonotoneCubic.init` drops any
    /// point whose x is `<=` the previous one, so two points allowed to touch become one
    /// point in the evaluated curve while the editor still draws and indexes two. At the
    /// develop column's 292 pt plot, 0.004 is 1.2 pt — under the width of the drawn dot,
    /// so it is not a gap a hand can feel.
    public static let minimumPointGap: Double = 0.004

    /// The default parametric splits, and the bounds every path clamps them into.
    /// 10–90% per docs/04 §7.1: a split pinned to either end would leave a region with
    /// no axis under it and nothing for its slider to do.
    public static let defaultSplits: [Double] = [0.25, 0.5, 0.75]
    public static let splitFloor: Double = 0.10
    public static let splitCeiling: Double = 0.90
    public static let minimumSplitGap: Double = 0.02

    // MARK: - Clamping

    /// 0…1, with non-finite mapped to 0 rather than propagated.
    ///
    /// `Num.saturate` cannot be used for this: `min(max(NaN, 0), 1)` is NaN, because
    /// every comparison against NaN is false. A NaN reaching a `Path` is a drawing that
    /// silently disappears, and a NaN reaching the recipe is data loss — `JSONEncoder`
    /// refuses non-conforming floats, so the sidecar collapses to "{}".
    @inlinable public static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }

    // MARK: - The point list

    /// A sanitized control-point list. The wire form is `[[x, y], …]`; anything malformed
    /// — short rows, non-finite numbers — is dropped here rather than defended against at
    /// every use site, and a list too short to be a curve becomes the identity.
    ///
    /// Sorted on the way out, because every index-based rule below assumes ascending x
    /// and a decoded recipe promises nothing.
    public static func sanitized(_ raw: [[Double]]?) -> [[Double]] {
        guard let raw, !raw.isEmpty else { return identity }
        var out: [[Double]] = []
        out.reserveCapacity(raw.count)
        for row in raw where row.count >= 2 {
            let x = row[0]
            let y = row[1]
            guard x.isFinite, y.isFinite else { continue }
            out.append([clamp01(x), clamp01(y)])
        }
        guard out.count >= 2 else { return identity }
        out.sort { $0[0] < $1[0] }
        return out
    }

    public static let identity: [[Double]] = [[0, 0], [1, 1]]

    /// Whether this list is the untouched curve, which is what the recipe stores as nil
    /// so an identity curve costs the render nothing.
    public static func isIdentity(_ points: [[Double]]) -> Bool {
        points.count == 2
            && abs(points[0][0]) < 1e-9 && abs(points[0][1]) < 1e-9
            && abs(points[1][0] - 1) < 1e-9 && abs(points[1][1] - 1) < 1e-9
    }

    // MARK: - Moving a point

    /// Where `index` is allowed to sit on the x axis, given its neighbours.
    ///
    /// Returns the point's CURRENT x when the window has collapsed — which can only
    /// happen to a decoded curve whose neighbours arrive closer together than twice the
    /// gap — so a drag in that state moves the point vertically and refuses to reorder
    /// the array. Refusing is the whole job: the alternative is an index that stops
    /// naming the point the hand is holding, mid-drag.
    public static func clampedX(_ points: [[Double]], moving index: Int,
                                toX x: Double) -> Double {
        guard points.indices.contains(index), points[index].count >= 2 else { return 0 }
        let gap = minimumPointGap
        let lower = index > 0 ? points[index - 1][0] + gap : 0
        let upper = index < points.count - 1 ? points[index + 1][0] - gap : 1
        guard upper > lower else { return points[index][0] }
        return Swift.min(Swift.max(clamp01(x), lower), upper)
    }

    /// The list with `index` moved to (x, y), x clamped inside its neighbours' window.
    /// The array it returns is still sorted, still the same length, and `index` still
    /// names the same point.
    public static func moved(_ points: [[Double]], index: Int,
                             toX x: Double, toY y: Double) -> [[Double]] {
        guard points.indices.contains(index) else { return points }
        var out = points
        out[index] = [clampedX(points, moving: index, toX: x), clamp01(y)]
        return out
    }

    // MARK: - Deleting a point

    /// Whether a point may be removed. THE TWO ANCHORS MAY NOT.
    ///
    /// This is the rule the editor was missing, and it is not a nicety. Three routes
    /// reach deletion — ⌥-click, the context menu, and releasing a drag outside the
    /// graph — and the last of those is reachable by simply pulling the black point
    /// down and to the left, which is a thing photographers do to a curve on purpose.
    /// Losing it leaves `MonotoneCubic` extending flat below the new first point:
    /// every shadow under it renders one identical value, which is a posterized block
    /// the graph draws as a horizontal line and which nothing but Flatten undoes —
    /// and Flatten throws away every other point the photographer placed.
    ///
    /// Lightroom, Capture One, Photoshop and ART all hold the two ends permanent for
    /// this reason. They can still be DRAGGED, along the edges and into the field,
    /// which is what the black-point and white-point moves are.
    public static func isDeletable(index: Int, count: Int) -> Bool {
        index > 0 && index < count - 1
    }

    /// The list with `index` removed, or nil when that point is an anchor and the
    /// gesture must do nothing.
    public static func deleting(_ points: [[Double]], at index: Int) -> [[Double]]? {
        guard isDeletable(index: index, count: points.count) else { return nil }
        var out = points
        out.remove(at: index)
        return out
    }

    // MARK: - Hit testing

    /// The point under a press, or nil.
    ///
    /// Tolerances arrive as FRACTIONS of the plot — the caller divides its pixel radius
    /// by the plot's width and height — so the comparison below is the same circle in
    /// pixels that the drawn dot sits in, without this file knowing what a pixel is.
    /// The dot is drawn at radius 3 and the tolerance is 8, which is the point of
    /// stating them apart: the ink is a sight, the tolerance is what catches the hand.
    ///
    /// Ties go to the LAST point tested, matching the drawing order — the control points
    /// are painted in index order, so the one on top is the one a press should take.
    public static func hitIndex(_ points: [[Double]], x: Double, y: Double,
                                toleranceX: Double, toleranceY: Double) -> Int? {
        guard toleranceX > 0, toleranceY > 0, x.isFinite, y.isFinite else { return nil }
        var best: Int? = nil
        var bestDistance = 1.0
        for i in points.indices where points[i].count >= 2 {
            let dx = (points[i][0] - x) / toleranceX
            let dy = (points[i][1] - y) / toleranceY
            let distance = dx * dx + dy * dy
            if distance <= bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    /// The point nearest a given x, used to pick up the point a click just created.
    public static func nearestIndexByX(_ points: [[Double]], x: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var best = 0
        var bestDistance = Double.infinity
        for i in points.indices where points[i].count >= 2 {
            let distance = abs(points[i][0] - x)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return bestDistance.isFinite ? best : nil
    }

    /// Whether a release landed outside the graph by more than the margin, which is the
    /// drag-out-to-delete gesture docs/04 §7 adopts from ART. Margins are fractions of
    /// the plot, as above.
    public static func escapes(x: Double, y: Double,
                               marginX: Double, marginY: Double) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        return x < -marginX || y < -marginY || x > 1 + marginX || y > 1 + marginY
    }

    // MARK: - Parametric splits

    /// Three ascending splits inside the panel's own bounds, whatever arrived.
    ///
    /// A recipe can arrive from a sidecar another tool wrote — `ParametricCurve` decodes
    /// `splits` without validating them — so this repairs count, finiteness, order and
    /// spacing, and its repair may not violate the bound it just applied.
    ///
    /// THE CEILING IS THE SAME `splitCeiling` THE CLAMP USES, not something larger. It
    /// was 0.98 once, which let the gap repair push a split past the range every
    /// interactive path enforces: clamp the third split to 0.90, find it within the
    /// minimum gap of the second, and the repair moved it to 0.92. Pushing UP from the
    /// previous split can therefore run out of room, so the last resort walks the
    /// earlier ones DOWN instead — the alternative is returning a set that is still
    /// unsorted or still overlapping, which is what this function exists to rule out.
    public static func sanitizedSplits(_ raw: [Double]) -> [Double] {
        var out: [Double] = raw.count == defaultSplits.count ? raw : defaultSplits
        for i in out.indices where !out[i].isFinite {
            out[i] = defaultSplits[i]
        }
        out.sort()
        for i in out.indices {
            out[i] = clampedSplit(out[i])
        }
        for i in 1..<out.count where out[i] <= out[i - 1] + minimumSplitGap {
            out[i] = Swift.min(splitCeiling, out[i - 1] + minimumSplitGap)
        }
        for i in stride(from: out.count - 2, through: 0, by: -1)
        where out[i] >= out[i + 1] - minimumSplitGap {
            out[i] = Swift.max(splitFloor, out[i + 1] - minimumSplitGap)
        }
        return out
    }

    public static func clampedSplit(_ x: Double) -> Double {
        Swift.min(Swift.max(clamp01(x), splitFloor), splitCeiling)
    }

    // MARK: - Undo identity

    /// The coalescing key one point's drag records under.
    ///
    /// K-038, re-verified as A2-05: the editor keyed every point of a channel under
    /// `"curve." + channel`, and `HistoryCoalescing` folds two edits that share a key,
    /// a photo set and a 1.2 s window into one step. So placing a point and then moving
    /// a different one — two deliberate, different decisions, seconds apart — was ONE
    /// undo entry, and ⌘Z took both away. The index is what makes the key an identity
    /// for the decision rather than a name for the control; a drag holds one index for
    /// its whole life, so one drag is still one step.
    public static func pointCoalescingKey(prefix: String, channel: String,
                                          index: Int) -> String {
        "\(prefix)\(channel).point.\(index)"
    }

    // MARK: - Readout

    /// The in/out readout, in percent of the encoded axis (docs/04 §7.1's coordinate
    /// display). Both halves are clamped into 0…100 before formatting, which is what
    /// bounds the string: the longest it can produce is `in 100.0%   out 100.0%`, and
    /// no sign is reachable because the axis has no negative half.
    public static func readout(input: Double, output: Double) -> String {
        "in " + percent(input) + "%   out " + percent(output) + "%"
    }

    /// One split's readout while it is being dragged. The rail had no numbers at all —
    /// three anonymous triangles setting the one thing about the parametric curve a
    /// photographer might want to state exactly.
    public static func splitReadout(index: Int, position: Double) -> String {
        "split \(index + 1)   " + percent(position * 100) + "%"
    }

    /// One decimal, and never a non-finite string. The em dash is what a readout says
    /// when it has nothing to report; it is one glyph wide and cannot overflow anything
    /// a number fits in.
    public static func percent(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.1f", Swift.min(Swift.max(v, 0), 100))
    }
}
