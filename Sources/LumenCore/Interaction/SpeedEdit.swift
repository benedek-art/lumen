// SpeedEdit.swift
// Hold a letter, drag on the photograph, adjust that parameter — without a panel, a
// pointer trip, or knowing which section the slider is in.
//
// docs/28 Phase 6 item 25 (D44). Capture One's most-praised feature and the one no
// macOS-native editor has. docs/12 §12.4 fixes the grammar: "`E` tapped is loupe view,
// `E` held with a scroll is Exposure" — tap versus hold, NOT a reserved letter. That is
// the spec's best idea, because reserving eight letters in an app that already uses
// nearly every one would have cost more than the feature is worth.
//
// THIS FILE IS THE RULES ONLY, and it is landing ahead of its wiring deliberately — the
// same split `Workspace` used, for the same reason. Wiring it means changing when eight
// EXISTING keys fire: `S` (scopes) and `H` (histogram) are toggles today, and under this
// grammar a tap toggles while a hold edits, so their action has to move from key-down to
// key-up. Get the discriminator wrong and eight working keys stop working. Every rule
// here is testable on Linux and none of it can be tested by reading; the dispatcher half
// belongs in a session that can watch a real key behave.

import Foundation

public enum SpeedEdit {

    /// What a held letter edits.
    ///
    /// The letters are shared with tap meanings ON PURPOSE — `E` is loupe, `S` is
    /// scopes, `H` is histogram — because a hold and a tap are different gestures and
    /// spending eight scarce letters to avoid discriminating between them would be
    /// paying twice.
    public enum Parameter: String, CaseIterable, Sendable {
        case exposure, contrast, highlights, shadows, temp, tint, lookAmount, maskAmount

        /// What the on-image readout prints while the hold is live. The photographer is
        /// looking at the picture, not at a panel, so this is the only thing naming what
        /// is moving.
        public var title: String {
            switch self {
            case .exposure: return "Exposure"
            case .contrast: return "Contrast"
            case .highlights: return "Highlights"
            case .shadows: return "Shadows"
            case .temp: return "Temperature"
            case .tint: return "Tint"
            case .lookAmount: return "Look Amount"
            case .maskAmount: return "Mask Amount"
            }
        }

        /// The parameter's full travel, used to turn a drag across the window into a
        /// change that feels the same on every control. Exposure is in stops and
        /// everything else is in panel units, which is why this is not one constant.
        public var range: ClosedRange<Double> {
            switch self {
            case .exposure: return -5...5
            case .temp: return 2000...50000
            case .tint: return -150...150
            case .lookAmount, .maskAmount: return 0...100
            case .contrast, .highlights, .shadows: return -100...100
            }
        }

        /// The smallest step a drag can land on, so a speed edit writes the same
        /// quantised values a slider does rather than a long decimal nothing else in the
        /// app would produce.
        public var step: Double {
            switch self {
            case .exposure: return 0.01
            case .temp: return 10
            default: return 1
            }
        }
    }

    /// `E`, `C`, `H`, `S`, `W`, `T`, `K`, `M` — docs/12 §12.4's map, verbatim.
    ///
    /// `W` and `T` for temperature and tint rather than the more obvious `T` and `I`:
    /// warm/tint is how the pair is spoken, and `T` alone would have to mean one of them.
    public static func parameter(forKey key: String) -> Parameter? {
        switch key.lowercased() {
        case "e": return .exposure
        case "c": return .contrast
        case "h": return .highlights
        case "s": return .shadows
        case "w": return .temp
        case "t": return .tint
        case "k": return .lookAmount
        case "m": return .maskAmount
        default: return nil
        }
    }

    /// Longer than this with the key down and it is a hold, whatever the pointer did.
    ///
    /// docs/12 §12.4's number. It is above the ~80 ms a deliberate tap takes and below
    /// the ~200 ms at which a hold starts to feel unacknowledged, which is the whole
    /// window a discriminator has to live in.
    public static let holdThresholdMilliseconds: Double = 150

    /// What a key-down turned out to mean.
    public enum Resolution: Equatable, Sendable {
        /// Short, still: the key's ordinary meaning fires now.
        case tap
        /// Moved, or held past the threshold: a speed edit is running and the tap
        /// meaning must NOT fire on release.
        case edit
        /// Held past the threshold on a letter that edits nothing. The ordinary meaning
        /// still fires, because refusing it would make a slow press of an unrelated key
        /// silently do nothing — and a photographer cannot tell a slow press from a
        /// broken app.
        case tapAfterHold
    }

    /// Decide what a completed key press was.
    ///
    /// MOVEMENT WINS OVER TIME, and that ordering is the whole discriminator. A
    /// photographer who presses and immediately drags has committed to an edit inside
    /// 20 ms, and making them wait out 150 ms first would put a visible hitch at the
    /// start of every speed edit — the one place the feature has to feel instant.
    /// Time is only the tie-breaker for a press that never moved.
    public static func resolve(key: String,
                               heldMilliseconds: Double,
                               pointerMoved: Bool) -> Resolution {
        let edits = parameter(forKey: key) != nil
        if pointerMoved && edits { return .edit }
        guard heldMilliseconds >= holdThresholdMilliseconds else { return .tap }
        return edits ? .edit : .tapAfterHold
    }

    /// How far a drag moves a parameter.
    ///
    /// One window-width of travel is one full range, so every parameter feels the same
    /// under the hand however differently it is denominated — which is the property that
    /// makes a pointer-free edit learnable at all. `fine` is ⇧, at a tenth, matching the
    /// slider's own fine drag rather than inventing a second ratio for the same idea.
    ///
    /// Horizontal only: a vertical component would collide with the pan a photographer
    /// is already used to performing on the picture, and there is no second parameter
    /// for it to mean.
    public static func delta(dragPoints: Double,
                             across width: Double,
                             parameter: Parameter,
                             fine: Bool) -> Double {
        guard width > 0, dragPoints.isFinite else { return 0 }
        let span = parameter.range.upperBound - parameter.range.lowerBound
        let raw = dragPoints / width * span * (fine ? 0.1 : 1)
        return (raw / parameter.step).rounded() * parameter.step
    }

    /// Where a drag lands, clamped and snapped — the same clamp-then-snap order
    /// `SliderTrack.resolve` uses, so a speed edit and a slider drag cannot disagree
    /// about what a value is.
    public static func value(from start: Double,
                             dragPoints: Double,
                             across width: Double,
                             parameter: Parameter,
                             fine: Bool) -> Double {
        let moved = start + delta(dragPoints: dragPoints, across: width,
                                  parameter: parameter, fine: fine)
        let clamped = Swift.min(Swift.max(moved, parameter.range.lowerBound),
                                parameter.range.upperBound)
        return (clamped / parameter.step).rounded() * parameter.step
    }
}
