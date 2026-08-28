// ContinuousZoom.swift
// The continuous zoom gestures' arithmetic: trackpad pinch, and the Lightroom-style
// scrubby drag (press at fit, drag right to zoom in, left to come back).
//
// Session C, owner: "I don't know what this strange zoom is, but I'd like to honestly
// remove it … either a two-finger spread on the touchpad or how Lightroom has it where
// if you press and hold and move your cursor left or right, it zooms." Click-to-zoom
// (`ViewportClick`) is deleted in the same commit; these two gestures replace it.
//
// Both gestures produce a zoom ratio in `ZoomLadder`'s denomination — 0 is fit,
// otherwise device pixels per FULL-RESOLUTION image pixel — and both resolve through
// one rule: a candidate at or below the fit ratio snaps to fit (0) rather than
// letting the picture shrink below the viewport or hover a hair above fit, and
// everything else is clamped by the ladder. Pure arithmetic, tested on Linux; the
// viewer feeds it gesture values and applies the result through the same `setZoom`
// verb every other zoom source uses.

import Foundation

public enum ContinuousZoom {

    /// Dragging this many points to the right doubles the zoom; the same distance
    /// left halves it. 150 pt spans fit → 1:1 → 4:1 in one comfortable wrist travel
    /// without re-gripping, which is the scrubby feel the owner named.
    public static let scrubPointsPerDoubling: Double = 150

    /// The slack above the fit ratio inside which a candidate still snaps to fit.
    /// Without it a pinch released a hair above fit leaves the frame imperceptibly
    /// cropped, and a scrub's first jittery points zoom instead of doing nothing.
    public static let fitSnapSlack: Double = 1.02

    /// A trackpad pinch: the gesture's total magnification multiplies the ratio the
    /// gesture STARTED at (fit starts from the fit ratio itself), so the picture
    /// tracks the fingers rather than compounding per event.
    public static func pinched(startZoom: Double, fitRatio: Double,
                               magnification: Double) -> Double {
        guard magnification.isFinite, magnification > 0 else {
            return ZoomLadder.clamp(startZoom)
        }
        return resolve(effectiveStart(startZoom, fitRatio: fitRatio) * magnification,
                       fitRatio: fitRatio)
    }

    /// The scrubby drag: horizontal travel in points, exponential so equal travel
    /// means equal zoom steps anywhere on the range.
    public static func scrubbed(startZoom: Double, fitRatio: Double,
                                horizontalTravel: Double) -> Double {
        guard horizontalTravel.isFinite else { return ZoomLadder.clamp(startZoom) }
        let factor = pow(2, horizontalTravel / scrubPointsPerDoubling)
        return resolve(effectiveStart(startZoom, fitRatio: fitRatio) * factor,
                       fitRatio: fitRatio)
    }

    /// What the gesture multiplies: the current ratio, except that fit — stored as 0,
    /// which no multiplication can leave — starts from the fit RATIO. A missing fit
    /// ratio (no image yet) starts from 1:1 rather than propagating a zero.
    static func effectiveStart(_ startZoom: Double, fitRatio: Double) -> Double {
        let zoom = ZoomLadder.clamp(startZoom)
        guard ZoomLadder.isFit(zoom) else { return zoom }
        return fitRatio.isFinite && fitRatio > 0 ? fitRatio : ZoomLadder.oneToOne
    }

    /// One resolution rule for both gestures: snap to fit at or below the fit ratio
    /// (with the slack), otherwise the ladder's clamp.
    static func resolve(_ candidate: Double, fitRatio: Double) -> Double {
        guard candidate.isFinite, candidate > 0 else { return ZoomLadder.fit }
        if fitRatio.isFinite, fitRatio > 0, candidate <= fitRatio * fitSnapSlack {
            return ZoomLadder.fit
        }
        return ZoomLadder.clamp(candidate)
    }
}
