// ZoomLayoutHold.swift
// What a continuous zoom is allowed to cost per event.
//
// The owner, after the publish storm on `zoomLevel` was already fixed: "the simple
// speed of zooming in and out is horrible, especially on the trackpad". The publish
// was real and it was not the whole bill. What remained is that every pinch event
// re-stated the canvas's LAYOUT — the plate's frame is `drawnFull(forZoom:)`, so a
// new zoom number is a new frame, a new layout of the plate and every overlay on it,
// and a fresh CoreGraphics scaled draw of the plate at the new size.
//
// And worse than the layout: the RENDER ASK moves with it. `requestedLongEdge`
// answers the container's bucket at fit and the sensor's own long edge the instant
// `zoom > 0`, so the FIRST event of a pinch out of fit changes the render key from a
// 2048-class whole-frame ask to a 7008-class one and launches a full demosaic of a
// 33 MP file — mid-gesture, against the same cores the gesture needs. That is the
// mechanism behind "slow AND glitchy" rather than merely soft: once the main actor
// cannot finish a pass between two trackpad events, AppKit coalesces the ones it has
// not delivered and the app stops SEEING the hand (`CommandState`'s own words, for
// the same failure two fixes ago).
//
// The fix is the one every photo application makes: while the zoom is moving, the
// picture on screen is a TRANSFORM of the frame already rendered — a layer scale,
// which costs the GPU one matrix — and nothing is re-laid-out, re-keyed or
// re-rendered at all. The instant the hand stops, the hold ends and one render lands
// at the new size, sharp. Mid-gesture softness in exchange for tracking the fingers
// is the trade Lightroom, Capture One and Preview all make.
//
// This file is only the arithmetic of the scale factor, so the view layer cannot
// invent its own: a ratio of two drawn extents, with every degenerate input answering
// 1 (draw it where it is) rather than 0, NaN or infinity — a `scaleEffect` given any
// of those makes the photograph vanish, which is the one outcome worse than slow.

import Foundation

public enum ZoomLayoutHold {

    /// How long the layout stays pinned after the last zoom change before the canvas
    /// re-states itself and one sharp render is asked for.
    ///
    /// Long enough that the gaps INSIDE a gesture never end the hold — a trackpad
    /// delivers pinch events far faster than this, and even a hesitant wheel turn
    /// stays inside it — and short enough that lifting your fingers and looking at the
    /// result feels like one motion rather than two. A pinch does not wait for it at
    /// all: `MagnifyGesture` has a real end, and that ends the hold immediately.
    public static let quietNanoseconds: UInt64 = 140_000_000

    /// The visual scale that turns the frame laid out at the held zoom into the frame
    /// the live zoom asks for — the `scaleEffect` the canvas wears while held.
    ///
    /// Both arguments are the SAME measurement (a drawn long edge, in points) taken at
    /// two zoom levels, so the ratio is the magnification and nothing else. Not held
    /// means `base == live` means exactly 1, with no floating-point drift to notice:
    /// the identity is returned by the equality branch rather than computed.
    public static func stretch(base: Double, live: Double) -> Double {
        guard base.isFinite, live.isFinite, base > 0, live > 0 else { return 1 }
        if base == live { return 1 }
        let scale = live / base
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }
}
