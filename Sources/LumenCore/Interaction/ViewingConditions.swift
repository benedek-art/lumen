// ViewingConditions.swift
// What the photograph is surrounded by, and how loud the chrome is around it.
//
// Two controls that look like preferences and are not. docs/00's Law 7 and docs/12
// §12.7 both treat the surround as part of the instrument: a tonal judgement made
// against the wrong background is wrong, reliably and in a direction you can predict,
// and every serious editor in the category ships something for it.
//
//   - LIGHTS OUT (`L`) cycles normal → dim → out. It is Lightroom's, and it answers
//     "get the interface out of my way": the chrome fades toward black while the
//     photograph is untouched.
//   - ASSESSMENT (`⌘B`) is darktable's colour-assessment mode and ISO 12646's
//     prescription: the photograph sits on a MID-GREY field with a thin white strip at
//     its edge as a diffuse-white anchor. It is for the last look before delivery, and
//     it is a different thing from lights-out — docs/12 §12.7 says so in as many words,
//     that "LR's Lights Out dims to black, which is the *wrong* surround for judging
//     tone".
//
// They are orthogonal because the keys are, and because the two questions are: how much
// interface is there, and what is the photograph sitting on. The precedence between them
// is stated once, here, rather than discovered in a view.
//
// In LumenCore because these are rules with numbers in them — a cycle order, a surround
// value, an ISO prescription — and `Sources/LumenApp` compiles on one CI lane and cannot
// be exercised by any test in this package.

import Foundation

/// Lightroom's lights-out cycle: how much of the interface is left.
public enum LightsOut: String, Codable, CaseIterable, Sendable {
    /// Everything on screen, as designed.
    case normal
    /// Chrome dimmed toward the surround, still legible, still clickable.
    case dim
    /// Chrome gone; the photograph on black.
    case out

    /// What the next press of `L` selects. A cycle, so three presses return.
    public var next: LightsOut {
        switch self {
        case .normal: return .dim
        case .dim: return .out
        case .out: return .normal
        }
    }

    /// How much of its normal presence the chrome keeps, 0…1.
    ///
    /// 0.35 rather than something nearer zero for `dim`: the middle rung has to remain
    /// USABLE — the point of it is to quiet the panels while still editing, and a
    /// control you cannot read is not dimmed, it is off. `out` is off, and the views
    /// remove the chrome rather than drawing it at zero, so nothing invisible can take
    /// a click.
    public var chromeOpacity: Double {
        switch self {
        case .normal: return 1
        case .dim: return 0.35
        case .out: return 0
        }
    }

    /// Whether the chrome should be removed from the layout entirely.
    public var hidesChrome: Bool { self == .out }
}

public enum ViewingConditions {

    /// ISO 12646's surround, encoded for the display.
    ///
    /// The standard asks for a neutral mid-grey around the image. `LumenLog.midGrey` is
    /// this engine's 0.18 scene-linear anchor, and what a display shows for it is that
    /// value through the transfer function — 0.18 encodes to about 0.4626 in sRGB. So
    /// the surround is not a taste value: it is the same grey the photograph's own
    /// mid-tone lands on, which is the entire point of the prescription.
    ///
    /// Computed rather than written as 0.4626 so that it follows `midGrey` if the
    /// engine's anchor ever moves, and so the number cannot be right in one file and
    /// stale in another.
    public static func assessmentSurround(
        transfer: TransferFunction = .srgb) -> Double {
        transfer.encode(LumenLog.midGrey)
    }

    /// The surround the viewer paints, given both controls.
    ///
    /// - Parameters:
    ///   - lights: the lights-out rung.
    ///   - assessment: whether ISO 12646 mode is on.
    ///   - normalSurround: the app's ordinary canvas value, so this rule does not have
    ///     to know the palette.
    ///
    /// ASSESSMENT WINS THE SURROUND, always, including over lights-out's black. That is
    /// the whole content of the disagreement docs/12 records with Lightroom: black is
    /// the wrong field for judging tone, so a mode whose only purpose is judging tone
    /// must not be overridden by one whose purpose is getting out of the way. Lights-out
    /// keeps the other half — it still takes the chrome away — so pressing both gives
    /// the thing somebody pressing both would want: nothing on screen but the
    /// photograph and the grey it is supposed to be judged against.
    public static func surround(lights: LightsOut, assessment: Bool,
                                normalSurround: Double) -> Double {
        if assessment { return assessmentSurround() }
        switch lights {
        case .normal, .dim: return normalSurround
        case .out: return 0
        }
    }

    /// Whether to draw the thin white strip at the photograph's edge.
    ///
    /// ISO 12646's diffuse-white anchor: without something at display white beside it,
    /// the eye adapts to the picture and the mid-grey field stops meaning anything. It
    /// belongs to assessment mode alone — a white line around the photograph in ordinary
    /// use is a border, and this app draws no borders.
    public static func showsWhiteAnchor(assessment: Bool) -> Bool { assessment }

    /// How loud the chrome is, given both controls.
    ///
    /// Assessment dims but does not remove: docs/12 §12.7 specifies "chrome dimmed" for
    /// it, because you are still going to reach for Export. Lights-out is the control
    /// that removes, so the quieter of the two wins.
    public static func chromeOpacity(lights: LightsOut, assessment: Bool) -> Double {
        Swift.min(lights.chromeOpacity, assessment ? 0.35 : 1)
    }
}
