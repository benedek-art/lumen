// LumenFocus.swift
// Focus, expressed as a surface instead of as a ring.
//
// A LEAF FILE ON PURPOSE (docs/28 Part 9). `LumenApp` compiles only on macOS and this
// machine cannot build it, so the surface checker and `swiftc -parse` are the only
// guards a change gets before CI. Neither sees type-level errors. `.focusable()`,
// `.focusEffectDisabled()` and `@FocusState` on a custom control are new to this
// codebase, so they live in one small file where a mistake fails in one place instead of
// scattering through the slider.
//
// WHY THE RING WENT. It drew a 1.5-point `Lumen.accent` border around the whole slider
// row, and the owner reported it as a defect on sight: "when I press on something, for
// example, highlight, it gets a blue border around it, which I don't want." He was not
// describing a corner case. `.focusable()` takes focus on MOUSE-DOWN, so the ring fired
// on the first event of every drag of every slider in the app — a chromatic outline
// snapping on beside the photograph, in a window whose whole argument is that no hue may
// sit next to a colour judgement (Law 7, docs/00). The accent policy that admitted it
// says "marker scale, never area"; a border around a 304-point row is area.
//
// IT COULD NOT SIMPLY BE DELETED. `.focusEffectDisabled()` (LumenControls) turns the
// system halo off, and the row's whole keyboard affordance hangs off focus actually
// being held: ←/→ nudge and Escape reach the slider only because `rowFocused` →
// `sliderFocusChanged` → `AppState.sliderHoldsFocus` makes `KeyDispatcher` stand down.
// Removing the ring and drawing nothing would have left the app's one focusable control
// with an invisible state, which is worse than a loud one.
//
// So focus moved onto the channel hover already speaks — the row's own surface — and
// climbed one rung of the ladder rather than changing axis: hover fills
// `Lumen.controlHover` (0.27), focus fills `Lumen.controlActive` (0.31). That is the
// same rest/hover/active triple every button and chip in the app already uses, so focus
// now looks like "this control is engaged" instead of like an error state. Zero chroma,
// no stroke, and no layout: a ring that changed a row's height on focus would make the
// whole panel jump as the arrows moved between rows.

#if os(macOS)

import SwiftUI

extension View {

    /// Answer the pointer AND the keyboard on one surface.
    ///
    /// One modifier for both states rather than `lumenHoverable()` plus something drawn
    /// on top, because they are the same pixels: a hover fill is a background and a
    /// focus indication drawn as an overlay would sit ON the groove it is reporting,
    /// dimming the instrument to announce that you can type at it. Folding the two into
    /// a single three-step fill also means a row that is hovered AND focused cannot show
    /// both — it shows the higher state, which is the one the eye should read.
    ///
    /// Focus outranks hover deliberately. A focused row keeps its surface while the
    /// pointer wanders away, which is the entire reason a keyboard state exists.
    func lumenInteractiveSurface(focused: Bool,
                                 radius: CGFloat = Lumen.radiusControl) -> some View {
        modifier(LumenInteractiveSurface(focused: focused, radius: radius))
    }
}

private struct LumenInteractiveSurface: ViewModifier {
    let focused: Bool
    let radius: CGFloat
    /// Row-local. Hover state must never reach an `ObservableObject` — a pointer
    /// crossing a panel would publish once per row, and this app has already paid for
    /// that lesson once in `CommandState`.
    @State private var hovering = false

    private var fill: Color {
        if focused { return Lumen.controlActive }
        if hovering { return Lumen.controlHover }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // Animated on the values rather than on the view, so an un-hover fades out
            // rather than snapping — the asymmetry the eye reads as responsiveness.
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

#endif
