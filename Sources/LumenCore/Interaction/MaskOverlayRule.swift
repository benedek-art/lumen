// MaskOverlayRule.swift
// When the red may go up, and what may take it down.
//
// The overlay had five inputs — a pin, a persistent phase, a hover, an edge gesture and
// a suppression — spread across nine writers of one variable, in a `@MainActor` class
// that needs a catalog on disk to construct. `grep soloMaskOverlay Tests/` returned
// nothing. It produced three defects in one audit, and every one of them was a guard:
//
//   · "Keep it hidden" cleared the overlay and left the PIN set, and flash, hover and
//     the edge-drag overlay all open with `guard !pinned` — so one menu click disabled
//     every ambient overlay for the rest of the photograph, with nothing on screen
//     saying so and only `O` able to undo it.
//   · `maskOverlaySuppressed` was written on every Effect press and READ BY NOTHING
//     except its own dedup guard, so a flash arriving mid-drag (clicking another mask's
//     pin, say) put the red back over the pixels being judged.
//   · Nothing kept the overlay up after a mask was made, and for the four kinds you
//     DRAW the creation flash composited a transparent wash — so a brush mask could
//     reach a finished adjustment without the red having been visible for one frame.
//
// Those three questions are values, not side effects. They live here, in the module
// that builds on Linux, and `AppState` CALLS them rather than restating them — a copy
// of a rule beside the rule is how the two drift.
//
// What is deliberately NOT here yet: the full precedence between a pin, an edge drag, a
// hover and a flash. `AppState` still expresses that by the order in which nine methods
// write `soloMaskOverlay`, which is exactly the shape that lost the pin. Moving it here
// means making those methods set inputs and recompute once, and that is a refactor of
// live view state on a target this repository cannot compile locally — so it is the
// next step rather than this one, and it is written down instead of half-done.

/// The three inputs that gate every ambient overlay rule.
///
/// A plain struct rather than an enum of states: the inputs are genuinely independent —
/// a photographer can be part-way through making one mask while another is pinned — and
/// collapsing them into one state means choosing the winner at the point each is SET,
/// which is the design that lost the pin in the first place.
public struct MaskOverlayRule: Equatable, Sendable {

    /// Whether the photographer asked to keep an overlay up, with `O` or the
    /// Show-overlay button. A decision, and decisions outrank feedback.
    public var pinned: Bool

    /// A mask that has been created and not yet adjusted, if any.
    ///
    /// The phase this type exists to name. It ends at the first Effect press — not at
    /// the first change of ANY kind, because refining an edge is still selection work
    /// and the overlay is the only place a selection is visible at all.
    public var persistentID: String?

    /// An Effect control is down. A red wash over the exact pixels being judged is an
    /// obstruction rather than information — the one moment the overlay must go.
    public var suppressed: Bool

    public init(pinned: Bool = false,
                persistentID: String? = nil,
                suppressed: Bool = false) {
        self.pinned = pinned
        self.persistentID = persistentID
        self.suppressed = suppressed
    }

    /// Whether an ambient rule — a creation flash, a hover, an edge gesture — may write
    /// the overlay at all.
    ///
    /// The guard that was missing half of itself. Every ambient writer checked the pin
    /// and none checked the suppression, so the one flag whose entire job was "not now"
    /// was inert, and hovering a row during an Exposure drag defeated the suppression
    /// outright.
    public var ambientAllowed: Bool { !pinned && !suppressed }

    /// Whether a stand-down timer holding `id` may take the overlay down.
    ///
    /// A mask still being made keeps its overlay: the timer is for feedback that has
    /// been seen, not for a selection still being drawn.
    public func mayStandDown(_ id: String) -> Bool { id != persistentID }

    /// What the overlay falls back to when the pointer leaves a mask's row.
    ///
    /// Not nil. Hovering a second mask's row while a new, unadjusted mask was lit used
    /// to end with the photograph dark, because the exit cleared the overlay outright
    /// and nothing put the persistent one back.
    public var afterHoverExit: String? { suppressed ? nil : persistentID }
}
