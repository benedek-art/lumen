// LumenViewerInput.swift
// The trackpad and the wheel over the photograph — scroll, pinch, and the two-finger
// double-tap — taken as plain AppKit events.
//
// AppKit rather than SwiftUI's `MagnifyGesture` for the pinch: the gesture reports a
// total since it began, only after a recognition threshold, and cannot see a scroll in
// the same touch. `magnify(with:)` reports each increment, with a phase and a place.
//
// A leaf file: `LumenApp` builds only on a Mac, so everything that can be decided
// arithmetically is decided in LumenCore (`ViewerScroll`, `ViewerMagnify`, with tests)
// and this is only which events exist and where the pointer is.
//
// `hitTest` answers nil for every other event, so drags, clicks and hover reach the
// SwiftUI content underneath by the path they would take with this view absent.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

extension View {

    /// Scroll and magnify events over this view are reported with the pointer's
    /// position in the view (points, origin top-left); every other event passes
    /// through untouched. An overlay, so it costs the view no layout.
    func lumenViewerInput(zoomed: @escaping () -> Bool,
                          onScroll: @escaping (ViewerScroll.Verb, CGPoint) -> Void,
                          onMagnify: @escaping (ViewerMagnify.Step, CGPoint) -> Void)
        -> some View {
        overlay(LumenViewerInputCatcher(zoomed: zoomed, onScroll: onScroll,
                                        onMagnify: onMagnify))
    }
}

private struct LumenViewerInputCatcher: NSViewRepresentable {
    let zoomed: () -> Bool
    let onScroll: (ViewerScroll.Verb, CGPoint) -> Void
    let onMagnify: (ViewerMagnify.Step, CGPoint) -> Void

    func makeNSView(context: Context) -> LumenViewerInputView {
        LumenViewerInputView()
    }

    func updateNSView(_ view: LumenViewerInputView, context: Context) {
        // Re-stored per body pass: the closures a pass builds carry that pass's state.
        view.zoomed = zoomed
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }
}

/// Internal rather than private so the automation driver can reach the event
/// overrides directly (`LumenViewerInputView.current`).
final class LumenViewerInputView: NSView {

    /// The loupe's catcher while it is in a window.
    private(set) static weak var current: LumenViewerInputView?

    var zoomed: (() -> Bool)?
    var onScroll: ((ViewerScroll.Verb, CGPoint) -> Void)?
    var onMagnify: ((ViewerMagnify.Step, CGPoint) -> Void)?

    /// A pinch happened in this touch, so the pan's coast after it is dropped: the
    /// picture stays where the fingers left it. Cleared when the next scroll begins.
    private var coastDropped: Bool = false

    /// Top-left origin, like the SwiftUI content this sits over.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            LumenViewerInputView.current = self
        } else if LumenViewerInputView.current === self {
            LumenViewerInputView.current = nil
        }
    }

    /// The gesture brackets are claimed with the gestures, so whichever event AppKit
    /// picks a gesture's target on finds this view.
    static func claims(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .scrollWheel, .magnify, .smartMagnify, .beginGesture, .endGesture, .gesture:
            return true
        default:
            return false
        }
    }

    /// The gate. Reading `NSApp.currentEvent` to decide a hit test is sound during
    /// `sendEvent(_:)` — see `LumenScrollNudge.hitTest`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              LumenViewerInputView.claims(event.type) else {
            return nil
        }
        return super.hitTest(point)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        let taken = scroll(deltaX: Double(event.scrollingDeltaX),
                           deltaY: Double(event.scrollingDeltaY),
                           precise: event.hasPreciseScrollingDeltas,
                           option: event.modifierFlags.contains(.option),
                           began: event.phase.contains(.began)
                               || event.phase.contains(.mayBegin),
                           coasting: !event.momentumPhase.isEmpty,
                           at: location(of: event))
        // Not ours — a fit-view trackpad scroll — goes back to the responder chain.
        if !taken { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        magnify(by: Double(event.magnification),
                ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
                at: location(of: event))
    }

    override func smartMagnify(with event: NSEvent) {
        onMagnify?(.smartZoom, location(of: event))
    }

    // MARK: The events' content

    // Split from the overrides so a driver that cannot mint an `NSEvent` of a
    // gesture type can still deliver exactly what one would.

    /// One scroll event. False when the viewer does not take it.
    @discardableResult
    func scroll(deltaX: Double, deltaY: Double, precise: Bool, option: Bool,
                began: Bool, coasting: Bool, at point: CGPoint) -> Bool {
        if began { coastDropped = false }
        let verb = ViewerScroll.verb(deltaX: deltaX, deltaY: deltaY,
                                     precise: precise, zoomModifier: option,
                                     zoomed: zoomed?() ?? false)
        guard verb != .ignore else { return false }
        // Inertia coasts a pan and is dropped for a zoom (`ViewerScroll`).
        if coasting, coastDropped || !ViewerScroll.honoursMomentum(verb) { return true }
        onScroll?(verb, point)
        return true
    }

    /// One magnify event: `magnification` is the change since the previous one.
    func magnify(by magnification: Double, ended: Bool, at point: CGPoint) {
        coastDropped = true
        for step in ViewerMagnify.steps(magnification: magnification, ended: ended) {
            onMagnify?(step, point)
        }
    }
}

#endif
