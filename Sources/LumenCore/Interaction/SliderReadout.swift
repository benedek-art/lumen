// SliderReadout.swift
// What a slider's value pill prints, and where the parts of a slider row are drawn.
//
// Both live here rather than in `LumenSlider` for the reason the rest of this folder
// does: LumenApp compiles only on macOS and has no Linux tests, so a rule written there
// is a rule nobody can check from the lanes that edit it.

import Foundation

/// The digits in a slider's readout.
public enum SliderReadout {

    /// The readout's text for `value` at `decimals` places.
    ///
    /// NEVER A NEGATIVE ZERO. A drag back to the centre of a ±100 control snaps through
    /// `(-0.4).rounded() * 1`, which is −0.0, and `String(format: "%.0f", -0.0)` is "-0":
    /// the pill said the control was below neutral when it was on it. Any value that
    /// prints as zero prints without a sign.
    ///
    /// `signed` is Lightroom's convention for a control whose neutral is zero and sits
    /// inside the range: a positive value carries a "+" (`+0.35`, `+24`), so the sign
    /// of an edit can be read down the column without comparing digits to a midpoint.
    /// Zero carries no sign. A control whose neutral is not zero (Temp at 5500 K) is
    /// never signed, because "+5500" would read as an offset it is not.
    public static func text(_ value: Double, decimals: Int, signed: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        let places = Swift.min(Swift.max(decimals, 0), 6)
        var text = String(format: "%.\(places)f", value)
        let isZero = (Double(text) ?? 1) == 0
        if isZero {
            if text.hasPrefix("-") { text.removeFirst() }
            return text
        }
        if signed && !text.hasPrefix("-") { return "+" + text }
        return text
    }

    /// Whether a control's readout is signed: a neutral of exactly zero strictly inside
    /// the soft range. See `text`.
    public static func isSigned(defaultValue: Double, lowerBound: Double,
                                upperBound: Double) -> Bool {
        defaultValue == 0 && lowerBound < 0 && upperBound > 0
    }

    /// What the field holds when it opens for typing: the digits without a "+", so that
    /// replacing them is what a selection-replace has always been, and a bare negative
    /// keeps its sign because typing "-40" sets −40.
    public static func editingText(_ value: Double, decimals: Int) -> String {
        text(value, decimals: decimals, signed: false)
    }

    /// Whether committing `next` over `current` would change nothing a photographer can
    /// see: within a thousandth of a step, the slider's own `isModified` tolerance.
    ///
    /// Not `==`. A snapped value is `(v / step).rounded() * step`, which for 0.35 on a
    /// 0.01 step is 0.35000000000000003, while the field's text "0.35" parses to 0.35.
    /// Return after ↑/↓ in the field compared the two exactly and wrote an edit that
    /// changed nothing but still cost an undo step: 124 of Exposure's 1001 values.
    public static func isNoChange(_ next: Double, from current: Double, step: Double) -> Bool {
        guard next.isFinite, current.isFinite else { return next == current }
        return abs(next - current) <= Swift.max(step, 0) / 1000
    }

    /// The decimal places a step needs so that two adjacent reachable values never print
    /// the same string. 1 → 0, 0.1 → 1, 0.05 → 2, 0.01 → 2.
    public static func decimals(forStep step: Double) -> Int {
        guard step > 0, step.isFinite else { return 0 }
        for places in 0...6 {
            let scaled = step * pow(10, Double(places))
            if abs(scaled - scaled.rounded()) < 1e-9 { return places }
        }
        return 6
    }
}

/// Where the parts of a slider row sit, in points, measured from the groove's centre
/// line (y grows downward, as in SwiftUI).
///
/// The view reads every one of these. They are here, rather than as literals in the
/// view, because the defect they settle was a GEOMETRY defect: on a ramped track the
/// neutral mark ran 8 pt through a 5 pt groove and the deviation underline started at
/// the same x 4.5 pt below it, so the two met and drew an "L" at the centre of Exposure
/// and Contrast. A test that reads the numbers can say they no longer meet.
public enum SliderMetrics {

    /// The air the row adds above and below `Lumen.rowHeight` (24, in LumenApp).
    public static let rowPadding: Double = 2

    public static let grooveHeight: Double = 5
    public static let thumbDiameter: Double = 9
    /// Pointer over the track: the thumb says "this is what you will move".
    public static let thumbHoverDiameter: Double = 10
    public static let thumbDraggingDiameter: Double = 11

    /// The zero mark is a TICK ABOVE THE GROOVE, never a bar through it. Outside the
    /// groove it sits on the panel's own grey, so it needs no halo to survive a
    /// saturated stop, and it cannot meet anything drawn under the groove.
    public static let neutralTickWidth: Double = 1
    public static let neutralTickHeight: Double = 3
    /// Gap between the tick's foot and the groove's top lip.
    public static let neutralTickGap: Double = 1

    /// The deviation underline drawn under a ramped groove.
    public static let underlineHeight: Double = 2
    public static let underlineGap: Double = 1.5

    public static var grooveTop: Double { -grooveHeight / 2 }
    public static var grooveBottom: Double { grooveHeight / 2 }
    public static var neutralTickBottom: Double { grooveTop - neutralTickGap }
    public static var neutralTickTop: Double { neutralTickBottom - neutralTickHeight }
    /// Centre of the tick relative to the groove's centre: the view's y offset.
    public static var neutralTickCentre: Double { (neutralTickTop + neutralTickBottom) / 2 }
    public static var underlineTop: Double { grooveBottom + underlineGap }
    /// Centre of the underline relative to the groove's centre: the view's y offset.
    public static var underlineCentre: Double { underlineTop + underlineHeight / 2 }

    /// The row's hit target, top to bottom, for a row of `rowHeight`.
    public static func hitHeight(rowHeight: Double) -> Double { rowHeight + 2 * rowPadding }
    /// The thumb's grab target, left to right.
    public static var thumbGrabWidth: Double { 2 * SliderDrag.thumbGrabRadius }

    /// How far the keyboard focus fill reaches past the row's content on each side, so
    /// the label does not sit flush against the edge of the fill.
    public static let focusOutset: Double = 6
}
