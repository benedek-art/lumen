// ViewerMagnify.swift
// What one trackpad magnify event means to the viewer. The AppKit half — which
// events exist and where the pointer is — is `LumenViewerInput.swift`.

import Foundation

public enum ViewerMagnify {

    public enum Step: Equatable, Sendable {
        /// Multiply the picture's size by this, about the pointer.
        case zoom(factor: Double)
        /// The fingers lifted, or the system cancelled the gesture.
        case ended
        /// The two-finger double-tap: fit ↔ 1:1 at the pointer.
        case smartZoom
    }

    /// No single event shrinks the picture below this share of itself.
    static let minimumFactor: Double = 0.25

    /// AppKit's `magnification` is the change since the PREVIOUS event, so one
    /// event's factor is 1 plus it and the factors compound. Nil changes nothing.
    public static func factor(magnification: Double) -> Double? {
        guard magnification.isFinite, magnification != 0 else { return nil }
        return Swift.max(1 + magnification, minimumFactor)
    }

    /// The steps one event contributes: its increment, then the end when the event
    /// is the gesture's last. An ending event can carry a final increment.
    public static func steps(magnification: Double, ended: Bool) -> [Step] {
        var steps: [Step] = []
        if let factor = factor(magnification: magnification) {
            steps.append(.zoom(factor: factor))
        }
        if ended { steps.append(.ended) }
        return steps
    }
}
