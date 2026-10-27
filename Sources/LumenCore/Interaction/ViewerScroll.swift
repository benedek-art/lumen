// ViewerScroll.swift
// What a scroll over the photograph means — the verb the viewer did not have.
//
// The owner, fifth round: "there's a bit of funky stuff happening with the two-finger
// zoom for the trackpad. It's very slow, it's clunky… The whole scroll is kind of
// interesting. Zooming in. Both with the mouse and with the trackpad are pretty broken
// right now."
//
// Reading the viewer's gesture surface against that report: there was NO scroll handler
// on the picture at all. `LumenScrollNudge` catches ⌥-scroll over a slider row and
// nothing catches anything over the image, so a wheel mouse had no zoom verb whatsoever
// — press-and-drag-right and the keyboard were the entire vocabulary — and a trackpad
// two-finger scroll, which is how a Mac user moves a document they are zoomed into,
// did nothing. "Broken" is the accurate word for a control surface that ignores the
// input; the pinch being sluggish on a 33 MP plate (docs/32 fifth round, `ZoomRegion`)
// was the other half, and the two together are what the report describes.
//
// THE GRAMMAR, SECOND VERSION. The first split the instruments: a wheel zoomed, a
// trackpad scroll panned, ⌥ zoomed on either. The owner, after living with it: "the
// zoom is still an issue … two finger scrolling or two finger zooming". A Magic Mouse
// reports PRECISE deltas exactly like a trackpad, so on the owner's mouse a
// two-finger scroll at fit did nothing at all, and zoomed in it panned when he meant
// to zoom. The instrument was never a reliable discriminator.
//
//   · A SCROLL ZOOMS, on every instrument, about the pointer — the Lightroom and
//     Capture One reflex, and one rule instead of a rule per device.
//   · ⌥ held PANS, for the trackpad hand that wants two fingers to move a zoomed
//     picture. ⌥ because it was already this surface's "the other verb" key, and
//     ⌃-scroll is macOS's own screen zoom.
//   · Panning without a modifier is the drag's job (`LoupeView.dragGesture`), and the
//     pinch still zooms through `MagnifyGesture`.
//
// Direction is taken off the RAW delta, exactly as the slider nudge takes it: scrolling
// the way you scroll a document toward its top zooms in and moves the picture with your
// fingers, so both verbs inherit whatever the photographer's system scroll direction
// already is instead of disagreeing with every other surface on their Mac for one of
// the two settings.
//
// Pure arithmetic, tested on Linux; the AppKit half — which events exist, what phase
// they are in — is `LumenViewerScroll.swift`, which is as thin as that split allows.

import Foundation

public enum ViewerScroll {

    /// What one scroll event should do to the viewer.
    public enum Verb: Equatable, Sendable {
        /// Multiply the current zoom by this, anchored at the pointer.
        case zoom(factor: Double)
        /// Move the picture by these points — the same sign convention as
        /// `LoupeViewport.pan`, so the picture follows the fingers.
        case pan(dx: Double, dy: Double)
        /// Nothing this surface should answer: a pan at fit (there is nothing to
        /// pan), a sideways-only scroll, or a delta that is not a number.
        case ignore
    }

    /// Points of continuous scrolling that double the zoom.
    ///
    /// Deliberately COARSER than the scrubby drag's 150 (`ContinuousZoom`). A drag is
    /// a deliberate grip that ends when the hand lets go; a scroll is a flick with
    /// momentum behind it, and at 150 a single ordinary trackpad flick would cross the
    /// whole fit → 16:1 range and land wherever the inertia stopped.
    public static let pointsPerDoubling: Double = 300

    /// What one line of a wheel is worth in those points.
    ///
    /// A wheel reports LINES, not points — the distinction `ScrollNudge` already turns
    /// on — and a detent is usually one line. At 100 points a detent is 2^(1/3), so
    /// three clicks double the zoom: coarse enough to cross the range in a few flicks
    /// of a finger, fine enough to stop where you meant to.
    public static let pointsPerLine: Double = 100

    /// The verb for one scroll event.
    ///
    /// `deltaX`/`deltaY` are AppKit's raw scrolling deltas, `precise` is
    /// `hasPreciseScrollingDeltas`, `panModifier` is ⌥, and `zoomed` says whether the
    /// picture is above fit — the only state a pan needs, because there is nothing to
    /// pan at fit.
    public static func verb(deltaX: Double, deltaY: Double,
                            precise: Bool, panModifier: Bool,
                            zoomed: Bool) -> Verb {
        guard deltaX.isFinite, deltaY.isFinite else { return .ignore }
        if panModifier {
            guard zoomed else { return .ignore }
            guard deltaX != 0 || deltaY != 0 else { return .ignore }
            // A wheel's lines are worth `pointsPerLine` here too, or a ⌥-wheel pan
            // would crawl one point per detent.
            let scale = precise ? 1 : pointsPerLine / 4
            return .pan(dx: deltaX * scale, dy: deltaY * scale)
        }
        // Y only, and X ignored, for `LumenScrollNudge`'s reason: a wheel has no X at
        // all, so honouring it would make the same flick mean different things on
        // different instruments and leave a diagonal one needing a tie-break nobody
        // could predict.
        let points = precise ? deltaY : deltaY * pointsPerLine
        guard points != 0 else { return .ignore }
        let factor = pow(2, points / pointsPerDoubling)
        guard factor.isFinite, factor > 0 else { return .ignore }
        return .zoom(factor: factor)
    }

    /// Whether a momentum (inertia) event should still be honoured.
    ///
    /// Yes for a pan — a document coasts, and that coast is most of what makes trackpad
    /// scrolling feel like the platform. No for a zoom: magnification that carries on
    /// after the fingers stop lands at a level nobody chose, which is the same argument
    /// `LumenScrollNudge` makes for dropping momentum on a slider. Stated as a rule
    /// here so both halves of the decision live beside each other.
    public static func honoursMomentum(_ verb: Verb) -> Bool {
        switch verb {
        case .pan: return true
        case .zoom, .ignore: return false
        }
    }
}
