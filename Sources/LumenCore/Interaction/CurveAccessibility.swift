// CurveAccessibility.swift
// What the curve editor's points and split handles say to VoiceOver, and what one
// accessibility increment does to them.
//
// UX-03, the half `SliderAccessibility` left: `CurveEditorView` draws its graph and its
// split rail on a `Canvas`, so a point curve with five points read as nothing at all —
// no element per point, no value, no way to move one without a pointer. Each point and
// each split is now an adjustable element; the rules for its name, its spoken value and
// its step live here, where they run without a Mac.

import Foundation

public enum CurveAccessibility {

    /// One accessibility step on either axis: one percent of the encoded axis, the same
    /// unit the editor's readout states positions in ("in 25.0%   out 40.0%").
    public static let step: Double = 0.01

    // MARK: Points

    /// "Red channel black point", "Point curve point 2 of 3", "… white point".
    ///
    /// The two ends are named for what they are — they are the curve's anchors and the
    /// moves photographers make with them have names — and the interior points are
    /// counted among themselves, so the count does not include the two anchors.
    public static func pointLabel(curve: String, index: Int, count: Int) -> String {
        if index <= 0 { return "\(curve) black point" }
        if index >= count - 1 { return "\(curve) white point" }
        return "\(curve) point \(index) of \(Swift.max(count - 2, 1))"
    }

    /// Both halves of the point, as the readout states them: the picture input it sits
    /// at and the output it maps that input to, in percent.
    public static func pointValue(input: Double, output: Double) -> String {
        "input " + CurveEditing.percent(input * 100) + "%, output "
            + CurveEditing.percent(output * 100) + "%"
    }

    /// One increment or decrement of a point's OUTPUT — the axis that reads as "more"
    /// and "less" — by one step, snapped to the step and clamped to the graph. x stays
    /// where it is, and the list keeps its length and order, so `index` still names the
    /// same point afterwards.
    public static func raisingOutput(_ points: [[Double]], index: Int,
                                     _ direction: SliderAccessibility.Direction) -> [[Double]] {
        guard points.indices.contains(index), points[index].count >= 2 else { return points }
        let y = stepped(points[index][1], direction)
        return CurveEditing.moved(points, index: index, toX: points[index][0], toY: y)
    }

    /// One step of a point's INPUT, offered as a named action beside the adjustable
    /// output, since one element carries one increment axis.
    ///
    /// The step is taken on the axis the graph DRAWS the point at (`plottedX`, the
    /// picture input), then mapped back to the axis it is stored on through `storedX` —
    /// on the Point tab those differ whenever a parametric slider is off zero, and a
    /// step announced as one percent of input has to be one percent of input. The move
    /// is `CurveEditing.moved`, so the point cannot cross a neighbour.
    public static func shiftingInput(_ points: [[Double]], index: Int, plottedX: Double,
                                     _ direction: SliderAccessibility.Direction,
                                     storedX: (Double) -> Double) -> [[Double]] {
        guard points.indices.contains(index), points[index].count >= 2 else { return points }
        let target = storedX(stepped(plottedX, direction))
        return CurveEditing.moved(points, index: index, toX: target, toY: points[index][1])
    }

    // MARK: Splits

    /// "Split between Shadows and Darks": what a split IS is the boundary between two of
    /// the four regions whose sliders sit under the graph.
    public static func splitLabel(index: Int, regions: [String]) -> String {
        guard index >= 0, index + 1 < regions.count else { return "Split \(index + 1)" }
        return "Split between \(regions[index]) and \(regions[index + 1])"
    }

    public static func splitValue(_ position: Double) -> String {
        CurveEditing.percent(position * 100) + "%"
    }

    /// One step of one split, kept inside its neighbours (the minimum gap either side)
    /// and inside the 10–90 % band every interactive path enforces, so the three stay
    /// ascending and `index` still names the split being adjusted.
    public static func adjustedSplits(_ splits: [Double], index: Int,
                                      _ direction: SliderAccessibility.Direction) -> [Double] {
        guard splits.indices.contains(index) else { return splits }
        var out = splits
        let gap = CurveEditing.minimumSplitGap
        let lower = index > 0 ? splits[index - 1] + gap : CurveEditing.splitFloor
        let upper = index < splits.count - 1 ? splits[index + 1] - gap : CurveEditing.splitCeiling
        let moved = CurveEditing.clampedSplit(stepped(splits[index], direction))
        guard upper >= lower else { return splits }
        out[index] = Swift.min(Swift.max(moved, lower), upper)
        return out
    }

    // MARK: -

    /// `value` one step up or down, snapped to the step so repeated actions land on
    /// whole percents rather than accumulating float dust, and clamped to 0…1.
    static func stepped(_ value: Double, _ direction: SliderAccessibility.Direction) -> Double {
        let base = value.isFinite ? value : 0
        let moved = base + (direction == .increment ? step : -step)
        return CurveEditing.clamp01((moved / step).rounded() * step)
    }
}
