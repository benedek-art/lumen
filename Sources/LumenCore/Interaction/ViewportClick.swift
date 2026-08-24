// ViewportClick.swift
// When a press on the image viewer is a click-to-zoom, and when it is just a press.
//
// The owner's first session: "there are lots of zoom in, zoom out things that happen
// when I'm not pressed on the image full screen." `zoomLevel` has exactly one writer —
// the viewport's `setZoom` — and there is no scroll or magnify gesture anywhere in the
// application, so the only thing that can move it by hand is the viewer's own press
// gesture. That gesture asked one question: did the pointer travel less than three
// points before the button came up? If so, toggle the zoom.
//
// Which means EVERY press anywhere on the viewer toggled the zoom. The gesture is
// attached to the whole canvas, so the grey surround beside a fitted frame counted; a
// click to bring the window forward counted; a press-and-think-and-release counted; a
// modifier-click counted. At fit the pan branch returns early because nothing
// overflows, so at fit the gesture is nothing BUT a zoom toggle — press anywhere,
// including well away from the photograph, and the viewer jumps to 1:1. Press again
// and it drops back. That is the loop the owner described.
//
// Click-to-zoom itself is not the bug and is not removed here: it is fifteen years of
// Lightroom muscle memory (docs/12's inheritance argument) and the viewer's own header
// promises it. What was missing is that a click has to be aimed at the photograph and
// has to be a click. The four conditions below are that, as a value with tests, rather
// than as one comparison inside a gesture closure in a file with no test target.

import Foundation

/// One completed press on the image viewer, reduced to the four facts that decide
/// whether it meant "zoom here".
public struct ViewportPress: Sendable, Equatable {

    /// Manhattan distance the pointer covered between press and release, in points.
    /// Manhattan rather than Euclidean because that is what the viewer measures and
    /// the two disagree by up to √2 — which matters at a threshold of three.
    public let travel: Double

    /// Seconds the button was held.
    public let duration: Double

    /// True when the release landed inside the drawn photograph, false when it landed
    /// on the surround. A fitted frame letterboxes on one axis, and that surround is
    /// not the picture.
    public let landedOnImage: Bool

    /// True when any of ⌘ ⌥ ⇧ ⌃ was down. Modifier-clicks on an image mean other
    /// things everywhere else in this application, and none of them mean zoom.
    public let hadModifier: Bool

    public init(travel: Double, duration: Double, landedOnImage: Bool,
                hadModifier: Bool) {
        self.travel = travel
        self.duration = duration
        self.landedOnImage = landedOnImage
        self.hadModifier = hadModifier
    }
}

public enum ViewportClick {

    /// How far a press may drift and still be a click. Three points is what the viewer
    /// already used and it is a reasonable number: below the smallest deliberate drag,
    /// above the tremor of a trackpad click.
    public static let travelTolerance: Double = 3

    /// How long a press may last and still be a click.
    ///
    /// Half a second is the ordinary boundary between clicking a thing and holding it,
    /// and holding is what a photographer does to a photograph — pressing to steady the
    /// eye, pressing while deciding where to drag, pressing and changing their mind.
    /// None of those should end in a zoom, and all of them did.
    public static let holdTolerance: Double = 0.5

    /// Whether this press should toggle the zoom.
    ///
    /// All four conditions, and the two that were missing are the ones that made the
    /// gesture fire when nobody had aimed anything: it has to land on the photograph,
    /// and it has to be a click rather than a hold.
    public static func togglesZoom(_ press: ViewportPress) -> Bool {
        guard press.landedOnImage else { return false }
        guard !press.hadModifier else { return false }
        guard press.travel.isFinite, press.travel <= travelTolerance else { return false }
        guard press.duration.isFinite, press.duration <= holdTolerance else { return false }
        return true
    }
}
