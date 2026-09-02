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
    /// - Parameter on: the surface value this sits ON, so the lift is ADDITIVE.
    ///   Hover used to be the literal 0.27, which is only a step for something already
    ///   at 0.24 — a chip on a well and a header on a panel both needed their own
    ///   number, and each invented one. Passing the base means every hovered thing in
    ///   the app rises by the same amount and the family reads as one system. The
    ///   default is the control surface, which is what this modifier was already
    ///   painting for.
    func lumenHoverable(radius: CGFloat = Lumen.radiusControl,
                        on base: Double = Lumen.controlSurfaceValue,
                        enabled: Bool = true) -> some View {
        modifier(LumenHoverModifier(radius: radius, base: base, enabled: enabled))
    }

    /// Report hover WITHOUT painting anything.
    ///
    /// For the several places that want to know the pointer is here in order to reveal
    /// an affordance — a section header's reset button, a chevron, a chip's remove
    /// glyph — rather than to light a surface up. Keeping it separate from
    /// `lumenHoverable` is what stops "I need to know about hover" from silently
    /// becoming "and therefore this row now glows", which is the exact effect the owner
    /// asked to be taken off the slider rows.
    func lumenHoverDetect(_ hovering: Binding<Bool>) -> some View {
        onHover { hovering.wrappedValue = $0 }
    }

    /// Hover fill and the pointing-hand cursor together: the whole "this is clickable"
    /// statement, in one call, so a new control cannot ship with half of it.
    ///
    /// Two one-file systems with five call sites between them was the audit's finding —
    /// hover and focus each existed and neither was reached for. A single verb is what
    /// makes them reachable.
    func lumenInteractive(radius: CGFloat = Lumen.radiusControl,
                          on base: Double = Lumen.controlSurfaceValue,
                          enabled: Bool = true) -> some View {
        lumenHoverable(radius: radius, on: base, enabled: enabled)
            .lumenClickCursor(enabled)
    }

    /// Say "this can be dragged sideways" with the cursor.
    ///
    /// For the slider's scrubby readout, the printer-light rows, and anything else whose
    /// interactivity is otherwise invisible. `NSCursor` is push/pop rather than set, so
    /// leaving the region restores whatever was underneath rather than assuming the
    /// arrow.
    func lumenScrubCursor(_ enabled: Bool = true) -> some View {
        modifier(LumenCursorModifier(cursor: .resizeLeftRight, enabled: enabled))
    }

    /// The pointing hand, for things that are buttons but do not look like buttons —
    /// chevrons, text links, the filmstrip's grid button.
    func lumenClickCursor(_ enabled: Bool = true) -> some View {
        modifier(LumenCursorModifier(cursor: .pointingHand, enabled: enabled))
    }

    /// The crosshair, for an armed pick surface — the WB eyedropper, a point-colour
    /// pick — where the pointer IS the instrument and "click lands a sample" is the
    /// promise the cursor makes.
    /// - Parameter enabled: whether the pick is armed. Tracked, not merely consulted
    ///   on entry: a mask canvas arms this only until the shape exists, and the cursor
    ///   has to go back to the arrow the moment it does, without waiting for the
    ///   pointer to leave and come back.
    func lumenPickCursor(_ enabled: Bool = true) -> some View {
        modifier(LumenCursorModifier(cursor: .crosshair, enabled: enabled))
    }
}

/// EVERY `NSCursor.push()` IN THIS APP, so that every one of them is balanced.
///
/// `push`/`pop` is a stack, and the three helpers above used to do the two halves in
/// two different closures with no record of whether the first had happened. Three ways
/// to leak, all of them ordinary:
///
///   - `enabled` flips between the enter and the exit, so the guard returns early and
///     the pop never runs;
///   - the view unmounts while the pointer is inside it — a pick overlay disappears the
///     instant the pick resolves — and `onHover(false)` never fires for a view that is
///     gone;
///   - SwiftUI delivers `onHover(true)` twice, which it does across a re-layout, so two
///     pushes meet one pop.
///
/// Each of those leaves the whole application wearing a resize or a crosshair cursor
/// until something else happens to push and pop over it. Twenty-nine call sites, so a
/// user hits it by moving the mouse normally.
///
/// The fix is to make the push a piece of view-local state and pop from every exit,
/// including `onDisappear`. This was already written once, correctly, for the pick
/// cursor; it is now the only implementation, which is why the pick helper is a call to
/// it rather than a second copy.
private struct LumenCursorModifier: ViewModifier {
    let cursor: NSCursor
    var enabled: Bool = true
    /// View-local, same rule as `LumenHoverModifier.hovering`: cursor state must never
    /// reach an `ObservableObject`.
    @State private var hovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0; sync() }
            // ARMING IS A SECOND INPUT, not a condition read once on entry. The mask
            // canvas arms its crosshair only while the shape it is asking for does not
            // exist yet, so the cursor has to return to the arrow the instant the shape
            // lands — with the pointer still inside, and no hover event coming.
            .onChange(of: enabled) { _, _ in sync() }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }

    /// At most one push outstanding, derived from the two inputs. Every path in and out
    /// goes through here, which is the whole of the discipline.
    private func sync() {
        let wants = hovering && enabled
        guard wants != pushed else { return }
        if wants { cursor.push() } else { NSCursor.pop() }
        pushed = wants
    }
}

private struct LumenHoverModifier: ViewModifier {
    let radius: CGFloat
    let base: Double
    let enabled: Bool
    /// Row-local. Hover state must never reach an `ObservableObject` — a pointer crossing
    /// a panel would publish once per row, and this app has already paid for that lesson
    /// once in `CommandState`.
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering && enabled ? Lumen.hovered(on: base) : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Lumen.motionState, value: hovering)
    }
}
#endif
