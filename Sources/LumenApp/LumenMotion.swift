// LumenMotion.swift
// Three motions, replacing eight numbers.
//
// Motion was the best-disciplined part of the design system before this file: 20 of the
// app's 34 animated transitions already agreed on `easeOut(0.12)`. What the other 14
// showed is a subtler failure than the type scale's, and a more interesting one — the
// numbers were not careless, they were LOCAL. Each was argued in a comment beside it, and
// two of those comments are arguing for the very consistency this file exists to provide.
//
// `PanelLayout`: "…inside it opened on visibly different timings — the kind of mismatch
// nobody can name and everybody feels." `DevelopPanel`: "furniture being moved, not an
// object being thrown." Both reached for a critically damped spring and picked 0.28.
// `LumenMenu` reached for the same shape for the same reason and picked 0.26. And the
// mask panel's own disclosures — the same gesture, a section folding open — never got the
// spring at all: they are `easeOut(0.14)` in one place and `easeOut(0.16)` in two others.
//
// So a fold in this app animated four ways across two curve families, while the file that
// fixed it locally wrote down that fixing it was the point. That is what a token is for.
//
// WHAT IS DELIBERATELY NOT HERE. Three timings stay written out where they are, because
// each answers a question no other site asks and folding them in would make this a list
// of durations rather than a set of roles:
//
//   · `LumenSwitch`'s knob, `spring(0.12, damping 1)` — a control's own travel under the
//     finger, argued in place at length ("a fifth of a second to arrive reads as the app
//     thinking about it").
//   · the scan spinner, `linear(0.9).repeatForever` — not a transition at all.
//   · `ControlPalette`'s scroll-to, `linear(0.08)` — near-instant on purpose, because the
//     list under the cursor has already changed and the eye needs the row, not the trip.

#if os(macOS)

import SwiftUI

extension Lumen {

    /// A CONTROL CHANGING STATE UNDER THE HAND — a hover fill arriving, a focus ring, a
    /// value pill lighting up, a thumb moving to where it was clicked.
    ///
    /// 0.12 s, ease-out, which is what 20 of the app's transitions already were. Fast
    /// enough that it reads as the control responding rather than as an animation, slow
    /// enough that the eye follows it instead of finding a new state already there.
    static let motionState: Animation = .easeOut(duration: 0.12)

    /// A SURFACE FOLDING OPEN OR CLOSED — a section, a panel, a menu, a drawer.
    ///
    /// A spring rather than a curve, and critically damped: it leaves immediately and
    /// does not overshoot, which is furniture being moved rather than thrown. 0.28 s,
    /// the number the two panel files independently reached; the menu's 0.26 and the
    /// mask panel's ease-outs at 0.14 and 0.16 were the same gesture answered three more
    /// ways.
    ///
    /// Slower than `motionState` on purpose. A fold changes what is on screen rather
    /// than how one control looks, and the eye needs the extra 160 ms to follow where
    /// the content went — which is the whole reason it is animated instead of cut.
    static let motionFold: Animation = .spring(response: 0.28, dampingFraction: 1)

    /// A NUMBER OR A BAR SETTLING ON A NEW VALUE — a live density readout, a progress
    /// fraction.
    ///
    /// `smooth` rather than `easeOut`: a readout that decelerates hard reads as having
    /// snapped, and the thing being communicated is that the value is still moving.
    /// 0.22 s, from the density readout that already used it; the switch's fraction bar
    /// was doing the same job at `easeOut(0.18)`.
    static let motionReadout: Animation = .smooth(duration: 0.22)
}

#endif
