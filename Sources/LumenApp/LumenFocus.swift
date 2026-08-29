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
//
// AND THEN THE HOVER RUNG CAME BACK OUT, one review later: "I would remove a bunch of
// the hover effects, like hovering over the white balance or the temperature or tint,
// stuff like that. I don't really like the fact that I can get that hover effect."
//
// He asked for hover on everything in the review before this one, and both requests are
// right, because a slider row is not the same kind of thing as a button. A button needs
// hover to say "this is pressable" — its whole affordance is that it can be clicked and
// nothing about a word in a panel says so on its own. A slider says what it is by
// LOOKING like a slider: there is a groove and a thumb sitting in it. The fill added
// nothing to that, and it cost something real, because these rows are what a photographer
// sweeps the pointer across on the way to the picture. Eleven of them lighting up in
// sequence is a wave of grey moving through the panel beside a photograph somebody is
// trying to judge the tone of — motion in the peripheral vision of a colour decision,
// which is the one thing docs/00's Law 4 says the surround may never do.
//
// So the fill is focus-only now, and the surviving hover in this app is on things you
// can click: headers, chevrons, tabs, buttons, chips. The keyboard state keeps its
// surface, because that is the state with nothing else to show it.

#if os(macOS)

import SwiftUI

extension View {

    /// Say that this row holds the keyboard, without a ring and without a hover.
    ///
    /// Drawn as a background rather than an overlay, because an overlay would sit ON the
    /// groove it is reporting — dimming the instrument in order to announce that you can
    /// type at it. It is the same fill `lumenHoverable()` paints one rung lower, so a
    /// focused row and a hovered button are visibly the same family of state.
    ///
    /// NO HOVER RUNG. It had one and the owner asked for it to go; the file header holds
    /// the argument. What is left is a single binary fill, which is also why this no
    /// longer needs `@State` of its own.
    func lumenFocusSurface(focused: Bool,
                           radius: CGFloat = Lumen.radiusControl) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(focused ? Lumen.controlActive : Color.clear))
            .contentShape(Rectangle())
            // Animated on the value rather than on the view, so losing focus fades out
            // rather than snapping — the asymmetry the eye reads as responsiveness.
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

#endif
