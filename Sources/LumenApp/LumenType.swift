// LumenType.swift
// A type scale, because there was not one.
//
// docs/30 §2.1. The measurement: 220 `.font(.system(size:))` calls in `Sources/LumenApp`,
// of which **199 — ninety percent — are 9, 10 or 11 point**. The ratio between 10 and 11
// is 1.1. A scale needs about 1.2 between steps to register as a step at all, so 9/10/11
// is not a scale, it is jitter: three sizes that look identical at arm's length, chosen
// ad hoc, which is exactly why nothing in the panel anchors the eye.
//
// Weight did no work either. **Twenty-seven of 220 calls carried a non-regular weight**,
// so 88% of the app's text was SF Pro Regular — the macOS system default, at the system
// default weight. That is the loudest "stock Apple" tell in the codebase, louder than any
// control.
//
// And there were TWO TYPEFACES. Twenty-three sites used `design: .monospaced`, which is
// SF Mono — a different family with a different x-height and stroke weight, sitting inches
// from SF Pro in the same row. Only three sites used `.monospacedDigit()`, which is the
// actual tool: tabular figures on the SAME face. Nobody ships a second family for numbers
// any more; Linear, Figma and Photomator all use tabular figures on their body face.
//
// Five hand-rolled ALL-CAPS styles existed at three sizes and three tracking values.
//
// So this file is four roles and one numeric style. Not "a font for every occasion" — a
// scale small enough that choosing from it is obvious and the next person cannot invent a
// sixth 10pt semibold.

#if os(macOS)
import SwiftUI

extension Font {

    /// Section headers and the workspace switcher. The top of the ramp inside a panel.
    ///
    /// 13, not 11, and `primaryText` rather than `secondaryText` where it is used: a
    /// heading drawn in the same colour and one weight-step from the rows it governs is
    /// not a heading, it is texture. That was the measured cause of "there's so much
    /// clutter, it's not neat" — six of these stacked, all the same weight as their
    /// contents, reading as a table of contents rather than as structure.
    static let lumenHeading: Font = .system(size: 13, weight: .semibold)

    /// Control labels, button text, list rows. The body of the app.
    static let lumenBody: Font = .system(size: 12, weight: .regular)

    /// The same, when it must carry emphasis — a selected tab, an active row.
    static let lumenBodyStrong: Font = .system(size: 12, weight: .medium)

    /// Captions, units, secondary annotation. The bottom of the ramp.
    ///
    /// 10 is the floor. There were 46 sites at 9pt in a build whose own design audit had
    /// already set 10 as the minimum and never enforced it.
    static let lumenCaption: Font = .system(size: 10, weight: .regular)

    /// EVERY NUMBER IN THE APP.
    ///
    /// Tabular figures on SF Pro, not SF Mono. `.monospacedDigit()` fixes the digit
    /// advance so a readout does not jitter as it counts, which is the only property a
    /// second typeface was ever bought for — and it keeps the number in the same voice as
    /// the label beside it. 13 sizes and 2 families collapse to one of each.
    static let lumenNumeric: Font = .system(size: 12, weight: .regular).monospacedDigit()

    /// A number that is the subject rather than an annotation — the slider readout while
    /// it is being scrubbed, the histogram's clipping percentages.
    static let lumenNumericStrong: Font = .system(size: 12, weight: .medium).monospacedDigit()
}

/// The one ALL-CAPS label, replacing five.
///
/// They existed at 11/0.8, 10/0.6, 10/0.6, 9/0.6 and 9/0.5 — five styles for one idea,
/// two of them below the app's own stated 10pt floor. Tracking rises as size falls,
/// because letter-spacing that reads as deliberate at 13pt reads as broken at 10.
struct LumenCapsLabel: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = Lumen.secondaryText

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(size >= 12 ? 0.6 : 0.8)
            .foregroundStyle(color)
    }
}
#endif
