// LumenFocus.swift
// The focus ring, and nothing else.
//
// A LEAF FILE ON PURPOSE (docs/28 Part 9). `LumenApp` compiles only on macOS and this
// machine cannot build it, so the surface checker and `swiftc -parse` are the only
// guards a change gets before CI. Neither sees type-level errors. `.focusable()`,
// `.focusEffectDisabled()` and `@FocusState` on a custom control are new to this
// codebase, so they live in one small file where a mistake fails in one place instead of
// scattering through the slider.
//
// WHY THE APP DRAWS ITS OWN RING. macOS's system focus ring is a blue halo sized for
// standard AppKit controls; on a 4-point groove inside a zero-chroma panel it reads as a
// bug rather than as state. `.focusEffectDisabled()` turns it off and this draws the
// audit's version instead (docs/25 step 8): a 1.5-point accent border at 60%, which is
// the one place besides the modified dot and the primary selection where the accent is
// allowed to appear at all (Law 7, and docs/25's accent policy — marker scale, never
// area).

#if os(macOS)

import SwiftUI

extension View {

    /// Draw the app's focus ring around this control when it holds keyboard focus.
    ///
    /// An overlay rather than a border, so it costs the control no layout: a ring that
    /// changed a row's height on focus would make the whole panel jump when the arrow
    /// keys moved between rows.
    func lumenFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = 4) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Lumen.accent.opacity(0.6), lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.1), value: isFocused)
    }
}

#endif
