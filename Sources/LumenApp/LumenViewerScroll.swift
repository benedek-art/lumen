// LumenViewerScroll.swift
// The scroll wheel and the two-finger scroll, over the photograph.
//
// A LEAF FILE ON PURPOSE, for exactly the reasons `LumenScrollNudge.swift` gives at
// length and this file will not repeat: `LumenApp` builds only on a Mac, this machine
// has `swiftc -parse` and the surface checker and nothing else, and an
// `NSViewRepresentable` with a `scrollWheel(with:)` override is the shape where a
// mistake is invisible to both. So it is small, it is one file, and everything that can
// be decided arithmetically is decided in `ViewerScroll` (LumenCore, with tests) rather
// than here.
//
// WHY A VIEW AND NOT A GLOBAL MONITOR: same answer as the nudge. `KeyDispatcher`'s
// monitor sits in front of the responder chain and would have to hit-test SwiftUI
// geometry by hand to know whether the pointer is over the picture, the filmstrip or a
// panel. A view under the pointer already knows.
//
// WHAT IT CLAIMS: scroll wheel events, and nothing else. `hitTest` answers nil for
// every other event, so the drag-scrub, the pinch, the double-click, the hover readout
// and the mask canvas all reach the SwiftUI content underneath by exactly the path they
// take today — the un-modified case is not a new code path that has to behave like the
// old one, it is the absence of one.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

extension View {

    /// Scroll over this view reports a `ViewerScroll.Verb`; every other event passes
    /// through untouched.
    ///
    /// An overlay rather than a background, for `lumenOptionScrollNudge`'s reason: it
    /// costs the view no layout, and SwiftUI draws its own content rather than putting
    /// it in sibling `NSView`s, so a representable is the topmost real view under the
    /// pointer wherever it is placed.
    func lumenViewerScroll(zoomed: @escaping () -> Bool,
                           onVerb: @escaping (ViewerScroll.Verb) -> Void) -> some View {
        overlay(LumenViewerScrollCatcher(zoomed: zoomed, onVerb: onVerb))
    }
}

private struct LumenViewerScrollCatcher: NSViewRepresentable {
    let zoomed: () -> Bool
    let onVerb: (ViewerScroll.Verb) -> Void

    func makeNSView(context: Context) -> LumenViewerScrollView {
        LumenViewerScrollView()
    }

    func updateNSView(_ view: LumenViewerScrollView, context: Context) {
        // Re-stored per body pass rather than captured once, for the reason
        // `LumenScrollNudge` states: the closure a pass builds carries that pass's
        // bindings. Assigning a property on an `NSView` publishes nothing.
        view.zoomed = zoomed
        view.onVerb = onVerb
    }
}

private final class LumenViewerScrollView: NSView {

    var zoomed: (() -> Bool)?
    var onVerb: ((ViewerScroll.Verb) -> Void)?

    /// The gate. Anything but a scroll wheel is answered as though this view were not
    /// in the hierarchy — see the header, and `LumenScrollNudge.hitTest` for why
    /// reading `NSApp.currentEvent` to decide a hit test is sound during
    /// `sendEvent(_:)`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .scrollWheel else {
            return nil
        }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        let verb = ViewerScroll.verb(deltaX: Double(event.scrollingDeltaX),
                                     deltaY: Double(event.scrollingDeltaY),
                                     precise: event.hasPreciseScrollingDeltas,
                                     zoomModifier: event.modifierFlags.contains(.option),
                                     zoomed: zoomed?() ?? false)
        // The event is not ours: hand it back to the responder chain rather than
        // swallowing it. Today nothing above the viewer scrolls, so this is a
        // no-op — and the day something does, a fit-view flick reaching it is the
        // behaviour that file will expect.
        guard verb != .ignore else {
            super.scrollWheel(with: event)
            return
        }
        // Inertia coasts a pan and is dropped for a zoom — `ViewerScroll`'s rule,
        // where the argument for the split is written down.
        if !event.momentumPhase.isEmpty, !ViewerScroll.honoursMomentum(verb) { return }
        onVerb?(verb)
    }
}

#endif
