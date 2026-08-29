// LumenScrollNudge.swift
// ⌥-scroll over a control, and the one rule that keeps it from breaking the panel it
// sits in.
//
// A LEAF FILE ON PURPOSE (docs/28 Part 9, and `LumenFocus.swift` before it). `LumenApp`
// compiles only on macOS and this machine cannot build it, so the surface checker and
// `swiftc -parse` are the only guards a change gets before CI, and neither sees anything
// type-level. `NSViewRepresentable` and a `scrollWheel(with:)` override are both new to
// this codebase, so they live in one small file where a mistake fails in one place
// instead of scattering through the slider.
//
// WHY A VIEW AND NOT A GLOBAL MONITOR. `KeyDispatcher` claims keys with
// `NSEvent.addLocalMonitorForEvents`, and that is the house precedent — but its own
// header explains why it is the wrong shape here: the monitor sits in FRONT of the
// responder chain, so it sees every scroll in the window and has no idea which of the
// ninety slider rows the pointer is over. Answering that from a monitor means
// hit-testing SwiftUI geometry by hand in AppKit coordinates, and keeping that answer
// right through every panel switch and scroll offset. A view under the pointer already
// knows it is under the pointer.
//
// WHY IT DOES NOT SWALLOW THE PANEL'S SCROLLING, which is the failure that would make
// this feature worse than not having it. The develop column is a `ScrollView` with as
// many as 38 rows in it; a row that ate un-modified wheel events would make the column
// unscrollable wherever a slider happens to be, which is nearly everywhere. So the gate
// is in `hitTest`, not in `scrollWheel`: unless the event AppKit is dispatching right now
// is a scroll wheel with ⌥ held, this view answers that it is not there. Every other
// event — a plain scroll, the track's own drag, the readout's tap-to-type, a
// double-click — finds the SwiftUI content underneath by exactly the path it takes
// today. The un-modified case is therefore not a new code path that has to behave like
// the old one; it is the absence of a code path.
//
// WHAT THIS COSTS WHEN ⌥ IS NOT HELD, stated exhaustively because the slider's
// per-mouse-event cost is under investigation for a separate defect (drags that tick,
// which `EditRevision`'s header explains as coalesced events rather than dropped frames)
// and anything added to that path has to be accountable.
//
//   · No event handler of any kind is installed. There is no `NSEvent` monitor, no
//     `NSTrackingArea`, no `onHover`, no `onContinuousHover`. Nothing polls, and nothing
//     runs on a timer.
//   · Nothing runs during a drag. AppKit routes `mouseDragged` to the view that took the
//     `mouseDown`, without hit-testing, so `hitTest` below is not reached at all between
//     the press and the release — the path the drag defect lives on never enters this
//     file.
//   · An un-modified scroll reaches `hitTest` exactly once and leaves after an enum
//     comparison. That single comparison IS the ⌥ gate; no design that answers "is this
//     event mine?" can cost less, and it is paid on scroll events only.
//   · Nothing here writes `@State`, publishes, or invalidates a view. The residue lives
//     on the `NSView`, which is the whole reason it is an `NSView` — see
//     `FineDrag.resolving` for the defect that rule exists to prevent.
//   · What it does add to a body pass is one closure and one pointer store per row, in a
//     row that already allocates about ten closures per pass for its two gestures, three
//     key handlers and two change handlers. It is not on the event path; it is on the
//     pass the event path already triggers, and it is within that pass's noise. Making it
//     literally nothing would mean capturing the callback once and never refreshing it,
//     which is wrong: rows exist whose `range`, `step` or `defaultValue` is computed
//     rather than written down — `LookPanel`'s film-lab rows read theirs off the stock,
//     and `MaskPanel`'s component rows off the component — and a control whose wheel
//     quietly used the range it was born with is a worse defect than a closure.
//
// The arithmetic — points to whole steps, and the residue that makes a slow scroll move
// anything at all — is `ScrollNudge` in LumenCore, where a Linux test can reach it. What
// is left here is the part only a Mac can run.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

extension View {

    /// ⌥-scroll anywhere over this view reports whole steps, and every other event
    /// passes through untouched.
    ///
    /// An overlay rather than a background, for the same reason `lumenFocusRing` is one:
    /// it costs the control no layout. Which of the two it is makes no difference to
    /// event routing anyway — SwiftUI draws its own content rather than putting it in
    /// sibling `NSView`s, so a representable is the topmost real view under the pointer
    /// wherever it is placed, and `hitTest` is the only thing standing between it and
    /// every gesture the row already has.
    func lumenOptionScrollNudge(_ onSteps: @escaping (Int) -> Void) -> some View {
        overlay(LumenScrollNudgeCatcher(onSteps: onSteps))
    }
}

private struct LumenScrollNudgeCatcher: NSViewRepresentable {
    let onSteps: (Int) -> Void

    func makeNSView(context: Context) -> LumenScrollNudgeView {
        LumenScrollNudgeView()
    }

    func updateNSView(_ view: LumenScrollNudgeView, context: Context) {
        // Re-stored on every body pass rather than captured once, because the closure a
        // pass builds carries that pass's bindings. Assigning a property on an `NSView`
        // publishes nothing, which is also why the accumulator below lives there and not
        // in `@State`: a `@State` write is a view invalidation, and this one would happen
        // on every wheel event including the majority that do not earn a step. See
        // `FineDrag.resolving`, which exists for that exact defect.
        view.onSteps = onSteps
    }
}

private final class LumenScrollNudgeView: NSView {

    var onSteps: ((Int) -> Void)?

    /// Points of scrolling banked toward the next whole step. Lives here, in AppKit, for
    /// the reason `updateNSView` gives.
    private var nudge = ScrollNudge()

    /// The gate. Anything but an ⌥-modified scroll wheel is answered as though this view
    /// were not in the hierarchy, so the row keeps every gesture it has and the develop
    /// column keeps scrolling.
    ///
    /// Reading `NSApp.currentEvent` to decide a hit test is unusual enough to say why it
    /// is sound: during `NSWindow.sendEvent(_:)` it is the event being dispatched, which
    /// is precisely the question — "is the thing you are routing right now mine?". The
    /// slider's own double-click detection already reads it for the same reason. Every
    /// other caller of `hitTest` — cursor rectangles, tooltips, mouse tracking — gets nil
    /// and is right to.
    ///
    /// Nil is the safe answer in every case it cannot be sure of, including no current
    /// event at all, so an ⌥-scroll that fails to arrive costs a feature and a broken
    /// hit test would cost the whole control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              event.modifierFlags.contains(.option) else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            // Unreachable through the gate above, and deliberately still correct: an
            // un-modified scroll belongs to the enclosing scroll view, and the way to
            // give it back is to let `NSResponder` walk it up the chain.
            super.scrollWheel(with: event)
            return
        }
        // A trackpad says when a gesture begins; a wheel never does, which is the sentence
        // docs/28 item 26 was blocked on. Where the phase exists it is worth using.
        if event.phase.contains(.began) { nudge.beginGesture() }
        // MOMENTUM IS DISCARDED, not forwarded. Inertia is right for a document, which
        // has somewhere to coast to, and wrong for a value, which would carry on moving
        // after the hand stopped and land somewhere nobody chose. Forwarding it to
        // `super` instead would scroll the panel out from under an adjustment that had
        // just finished, which is worse than dropping it.
        guard event.momentumPhase.isEmpty else { return }
        // POSITIVE IS UP IS MORE, off the raw delta rather than off the physical
        // direction `isDirectionInvertedFromDevice` would recover. So ⌥-scroll runs a
        // control in whatever direction the photographer's own scrolling already runs:
        // a mouse user who has never opened Trackpad preferences gets wheel-away = more,
        // and a trackpad user gets the same flick that walks a list toward its top.
        // Normalising to the physical direction instead would make the row disagree with
        // the column it sits in for exactly one of the two settings, and this is one line
        // to flip if the owner's hand says otherwise.
        //
        // Y only, and X ignored. A mouse wheel has no X at all, so honouring it would
        // mean the same flick meant different things on different devices, and a diagonal
        // one would need a tie-break nobody could predict.
        let steps = nudge.steps(scrolling: Double(event.scrollingDeltaY),
                                precise: event.hasPreciseScrollingDeltas)
        guard steps != 0 else { return }
        onSteps?(steps)
    }
}

#endif
