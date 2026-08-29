// LumenSwitch.swift
// The last two AppKit controls in the panels, drawn.
//
// The dropdown rebuild (`LumenMenu.swift`) took out `NSPopUpButton` because nothing
// could style it. Two controls survived that pass and they have the same two problems:
//
//   · **`Toggle(...).toggleStyle(.switch)`** — 26 `LumenToggleRow` call sites across
//     eight files, plus three bare ones. macOS draws it as a capsule filled with the
//     SYSTEM ACCENT when on, which on a default install is blue.
//   · **`ProgressView`** — the export bar and the sidebar spinner, both tinted the same
//     blue by the same mechanism.
//
// THE BLUE IS THE POINT, and it is not a taste argument. docs/00 Law 7: no hue may sit
// beside a colour judgement, and the app's own accent is a desaturated slate used at
// "marker scale, never area" precisely so it cannot bias one. A saturated blue capsule
// is area, it is a hue nobody chose, and in the develop column it sits inches from the
// photograph whose colour is being decided. The owner named the same family of control
// from the other end — "very, very old Apple view" — and the popups were only the loudest
// members of it.
//
// WHAT ON LOOKS LIKE INSTEAD, and why this particular grey. `Lumen.sliderFillModified`
// (0.72) is the value a slider's fill takes when it is NOT at its default — the app's
// existing word for "you changed this". A switch is a control with exactly two values,
// so an ON switch and a moved slider are the same statement, and now they are the same
// colour. Nothing new is invented and nothing is tinted.
//
// The knob is the slider's thumb: the same 0.99 → 0.78 vertical gradient, the same rim
// that is a highlight along the top and a dark edge along the bottom, the same cast
// shadow. Two controls in one column that both have a round grabbable part should not
// have been modelled by two different people, and until now they were.

#if os(macOS)
import SwiftUI

/// A two-state switch drawn in the app's own vocabulary.
///
/// Carries its own tap gesture so it works standalone, which matters because three call
/// sites are not inside a `LumenToggleRow`. Inside one, a click that lands on the switch
/// is consumed here and never reaches the row's gesture — which is what stops the two
/// cancelling each other out, exactly as it did when this was an AppKit `Toggle`.
struct LumenSwitch: View {

    @Binding var isOn: Bool
    var isEnabled: Bool = true

    /// 28 × 16 with a 12-point knob: two points of track visible at each end when the
    /// knob is parked, which is the proportion that reads as "there is somewhere for it
    /// to go". A mini AppKit switch is 26 × 15, so this costs the row nothing.
    private static let trackWidth: CGFloat = 28
    private static let trackHeight: CGFloat = 16
    private static let knob: CGFloat = 12

    @State private var hovering = false

    private var travel: CGFloat {
        (Self.trackWidth - Self.knob) / 2 - 1
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(isOn ? Lumen.sliderFillModified : Lumen.insetWell)
                // The same lip a slider groove has. Off, the switch is a well you could
                // put something in; on, it is filled. That is the whole metaphor, and it
                // is the one the groove beside it already uses.
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.black.opacity(isOn ? 0.20 : 0.45),
                                                    Color.white.opacity(isOn ? 0.16 : 0.05)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1))
                .frame(width: Self.trackWidth, height: Self.trackHeight)

            // THE SLIDER'S THUMB, not a second idea of a knob — see the file header.
            Circle()
                .fill(LinearGradient(
                    colors: [Color(nsColor: NSColor(white: 0.99, alpha: 1)),
                             Color(nsColor: NSColor(white: 0.78, alpha: 1))],
                    startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.55),
                                            Color.black.opacity(0.22)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5))
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.5), radius: hovering ? 2.5 : 1.5, y: 0.5)
                .offset(x: isOn ? travel : -travel)
        }
        .frame(width: Self.trackWidth, height: Self.trackHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && isEnabled }
        .onTapGesture { if isEnabled { isOn.toggle() } }
        // Critically damped, matching the accordion and the disclosures: the knob leaves
        // immediately and stops without overshooting. A bouncing switch is a toy.
        .animation(.spring(response: 0.22, dampingFraction: 1), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// A tick box, for the one place a switch would be the wrong word.
///
/// The export sheet lists recipes and each row says whether it is included in the next
/// run. That is a selection out of a set, not a state being turned on, and a column of
/// switches down a list reads as eight independent settings rather than as a choice of
/// which rows to act on. `.toggleStyle(.checkbox)` was right about the shape and wrong
/// about the colour, for the reason in this file's header.
struct LumenCheckbox: View {

    @Binding var isOn: Bool
    var isEnabled: Bool = true

    private static let side: CGFloat = 14

    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: Lumen.radiusChip - 2, style: .continuous)
            .fill(isOn ? Lumen.sliderFillModified : Lumen.insetWell)
            .overlay(
                RoundedRectangle(cornerRadius: Lumen.radiusChip - 2, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.black.opacity(isOn ? 0.20 : 0.45),
                                                Color.white.opacity(isOn ? 0.16 : 0.05)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    // Dark on the light fill, which is the only way round that works:
                    // a white tick on 0.72 grey is 1.3:1 and disappears at this size.
                    .foregroundStyle(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
                    .opacity(isOn ? 1 : 0))
            .frame(width: Self.side, height: Self.side)
            .opacity(isEnabled ? 1 : 0.45)
            .brightness(hovering && !isOn ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .animation(.easeOut(duration: 0.12), value: isOn)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "checked" : "unchecked")
    }
}

/// A determinate progress bar, drawn.
///
/// `ProgressView(value:)` is the same blue as the switch was and for the same reason. The
/// export bar is the one place in the app a photographer watches a control rather than a
/// photograph, so it is also the one place a saturated hue is least defensible: there is
/// nothing else on screen to compare it against.
struct LumenProgressBar: View {

    /// 0…1. Clamped here rather than at the call sites, because a progress fraction is
    /// derived from two counts and the interesting failures — a zero denominator, a
    /// count that overshoots — are exactly the ones that produce a non-finite value.
    let value: Double
    var height: CGFloat = 5

    private var fraction: Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Lumen.insetWell)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [Color.black.opacity(0.45),
                                                        Color.white.opacity(0.05)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1))
                Capsule(style: .continuous)
                    .fill(Lumen.sliderFillModified)
                    .frame(width: Swift.max(proxy.size.width * fraction, fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.18), value: fraction)
    }
}

/// The indeterminate case — "something is happening and nobody can say how much".
///
/// A rotating arc rather than a bouncing bar, at the app's own greys. It is one shape and
/// one animation, which is all `ProgressView()` was drawing too, only in blue and at a
/// size chosen by AppKit.
struct LumenSpinner: View {

    var diameter: CGFloat = 14
    var lineWidth: CGFloat = 2

    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Lumen.secondaryText,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: turning)
            // Started in `onAppear` rather than from an initial value: a
            // `repeatForever` animation attached to a property that never changes does
            // not run at all, which is the way this control most commonly ships dead.
            .onAppear { turning = true }
    }
}
#endif
