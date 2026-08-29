// LumenHover.swift
// Make the pointer mean something.
//
// docs/30 §2.1. The measurement that carries this file: **67 `.help()` tooltips against
// five `onHover` handlers**, and **zero `NSCursor` changes anywhere in the application**.
//
// That ratio is the diagnosis in one line — the app teaches by tooltip rather than by
// affordance. A slider row, a segmented control, a workspace tab, a filter chip and
// forty-six bare text buttons are all completely dead to the cursor: no fill, no lift, no
// cursor change, nothing at all until the mouse button goes down. Raycast's surfaces are
// no more contrasty than ours; what makes them feel like objects is that every one of them
// answers the pointer inside 100ms.
//
// It also hides a real feature. The slider's readout is a scrubby number at 2.13 points
// per unit — three times finer than the track — and its only advertisement is a tooltip
// after a one-second hover delay. A precision instrument nobody can see is not shipped.
// The cursor is how every other tool in this category says "you can drag me": Figma,
// After Effects, Resolve, Photoshop and Capture One all swap to a horizontal-resize
// cursor over a scrubbable number.

#if os(macOS)
import AppKit
import SwiftUI

extension View {

    /// Lift this view when the pointer is over it.
    ///
    /// Deliberately a background rather than a scale or an opacity: a row that grows
    /// under the cursor moves the thing you were aiming at, and a row that brightens its
    /// text competes with the modified state, which is already carried by text colour.
    /// A surface change is the one channel not already spoken for.
    ///
    /// The animation is on the value rather than the view, so an un-hover fades out
    /// rather than snapping — the asymmetry the eye reads as responsiveness.
    func lumenHoverable(radius: CGFloat = Lumen.radiusControl,
                        enabled: Bool = true) -> some View {
        modifier(LumenHoverModifier(radius: radius, enabled: enabled))
    }

    /// Say "this can be dragged sideways" with the cursor.
    ///
    /// For the slider's scrubby readout, the printer-light rows, and anything else whose
    /// interactivity is otherwise invisible. `NSCursor` is push/pop rather than set, so
    /// leaving the region restores whatever was underneath rather than assuming the
    /// arrow.
    func lumenScrubCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// The pointing hand, for things that are buttons but do not look like buttons —
    /// chevrons, text links, the register door.
    func lumenClickCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct LumenHoverModifier: ViewModifier {
    let radius: CGFloat
    let enabled: Bool
    /// Row-local. Hover state must never reach an `ObservableObject` — a pointer crossing
    /// a panel would publish once per row, and this app has already paid for that lesson
    /// once in `CommandState`.
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering && enabled ? Lumen.controlHover : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
#endif
