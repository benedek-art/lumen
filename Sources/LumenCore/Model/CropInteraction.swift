// CropInteraction.swift
// The arithmetic behind the crop tool's hands that `CropGeometry` did not yet have:
// ⌥-drag about the centre, dragging the PICTURE under a fixed frame, the arrow-key
// nudge, and the largest rectangle a ratio can have once the picture is turned.
//
// Here rather than in `CropOverlayView` for the reason the rest of the crop maths is in
// LumenCore: a view cannot be tested on a machine with no renderer, and every one of
// these has a clamp that is easy to get wrong in exactly the case nobody tries by hand.

import Foundation

extension CropGeometry {

    // MARK: - Resizing about the centre (⌥-drag)

    /// The crop a handle drag produces with ⌥ held: the rectangle grows and shrinks
    /// about its own centre, Lightroom's Alt-drag. The opposite handle moves by the same
    /// amount the other way, so a corner travels `dx` and the width changes by `2·dx`.
    ///
    /// The clamp is what differs from an anchored drag: the centre is fixed, so the
    /// room on an axis is twice the distance from the centre to the NEARER frame edge.
    /// A locked ratio scales both axes together to fit, for the reason
    /// `shrinkIntoFrame` gives — clamping one axis is how a lock silently breaks.
    public static func resizeAboutCentre(_ origin: Crop, handle: Handle,
                                         dx: Double = 0, dy: Double = 0,
                                         lockedAspect: Double? = nil,
                                         frameAspect: Double = 1) -> Crop {
        let start = normalized(origin)
        guard dx.isFinite, dy.isFinite else { return start }
        let ratio: Double? = {
            guard let lockedAspect, lockedAspect.isFinite, lockedAspect > 0,
                  frameAspect.isFinite, frameAspect > 0 else { return nil }
            return lockedAspect / frameAspect
        }()
        let cx = start.x + start.w / 2
        let cy = start.y + start.h / 2
        let maxW = 2 * Swift.min(cx, 1 - cx)
        let maxH = 2 * Swift.min(cy, 1 - cy)

        var w = start.w
        var h = start.h
        if handle.movesLeft { w = start.w - 2 * dx }
        if handle.movesRight { w = start.w + 2 * dx }
        if handle.movesTop { h = start.h - 2 * dy }
        if handle.movesBottom { h = start.h + 2 * dy }

        if let ratio {
            if handle.isCorner {
                // The same "whichever axis moved further" rule as the anchored drag, so
                // the two feel alike under the hand.
                let viaWidth = w, viaHeight = h * ratio
                w = abs(viaWidth - start.w) >= abs(viaHeight - start.h * ratio)
                    ? viaWidth : viaHeight
                h = w / ratio
            } else if handle.movesLeft || handle.movesRight {
                h = w / ratio
            } else {
                w = h * ratio
            }
            w = Swift.max(w, 1e-12)
            h = w / ratio
            let fit = Swift.min(1, maxW / w, maxH / h)
            w *= fit
            h *= fit
            // Ratio-preserving floor, capped where the centre leaves no room for it.
            let lift = Swift.max(minimumCropFraction / w, minimumCropFraction / h)
            if lift > 1 {
                let capped = Swift.min(lift, Swift.max(Swift.min(maxW / w, maxH / h), 1))
                w *= capped
                h *= capped
            }
        } else {
            w = Swift.max(Swift.min(w, maxW), minimumCropFraction)
            h = Swift.max(Swift.min(h, maxH), minimumCropFraction)
        }
        return normalized(Crop(x: cx - w / 2, y: cy - h / 2, w: w, h: h))
    }

    // MARK: - Dragging the picture under the frame

    /// The result of dragging the PICTURE under a fixed frame.
    public struct ImagePan: Equatable, Sendable {
        /// The crop the recipe should hold.
        public var crop: Crop
        /// How far the picture actually travelled, in the same normalized units the drag
        /// was given — the drag clamped at the frame edge, so the picture stops following
        /// the pointer exactly where the crop runs out of picture.
        public var dx: Double
        public var dy: Double
    }

    /// Lightroom's drag inside the crop: the photograph slides with the pointer and the
    /// rectangle holds still on screen. In the recipe that is the crop moving the OTHER
    /// way over the picture, by the same amount, with the same clamp `move` applies.
    ///
    /// `dx`/`dy` are the pointer's travel as fractions of the usable frame on screen.
    public static func panImage(_ origin: Crop, dx: Double, dy: Double) -> ImagePan {
        let start = normalized(origin)
        guard dx.isFinite, dy.isFinite else { return ImagePan(crop: start, dx: 0, dy: 0) }
        let moved = move(start, dx: -dx, dy: -dy)
        return ImagePan(crop: moved, dx: start.x - moved.x, dy: start.y - moved.y)
    }

    // MARK: - Arrow keys

    /// One arrow press, as a fraction of the usable frame. 0.2 % is about 12 px on a
    /// 6000 px frame — fine enough to settle a crop, coarse enough to see it move.
    public static let nudgeStep: Double = 0.002
    /// ⇧ multiplies the step, the same gearing a slider's arrow keys use.
    public static let nudgeShiftMultiplier: Double = 10

    /// The crop after an arrow press: the rectangle slides, never resizes, and stops at
    /// the frame edge. `steps` are signed counts of `nudgeStep` per axis, y downward.
    public static func nudge(_ crop: Crop, stepsX: Double, stepsY: Double,
                             shift: Bool = false) -> Crop {
        let k = nudgeStep * (shift ? nudgeShiftMultiplier : 1)
        return move(crop, dx: stepsX * k, dy: stepsY * k)
    }

    // MARK: - The largest rectangle a ratio can have

    /// The largest crop at `aspect` (width ÷ height in pixels) that this frame can hold,
    /// as a normalized crop of the usable frame, centred. This is what a ratio pick on a
    /// fresh frame writes (`centred`), named for what it is.
    public static func largestRect(aspect: Double, sourceWidth: Double, sourceHeight: Double,
                                   degrees: Double) -> Crop {
        centred(aspect: aspect, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                degrees: degrees)
    }

    /// The largest rectangle at `aspect`, in source pixels, that fits inside the
    /// `width × height` picture turned by `degrees` — Lightroom's "Constrain to Image"
    /// bound, measured against the turned picture itself rather than against its
    /// centred inscribed rectangle.
    ///
    /// Centred is optimal: the turned picture is convex and symmetric about its centre,
    /// so if a rectangle fits offset by t it also fits offset by −t, and by convexity
    /// it fits at the midpoint. A centred `w × w/aspect` box fits when both projections
    /// of its half-extents are inside the picture's:
    ///
    ///     w·|cos a| + h·|sin a| ≤ W
    ///     w·|sin a| + h·|cos a| ≤ H
    ///
    /// so `w` is the smaller of the two solutions. This is the yardstick the current
    /// usable-frame model is measured against (REPORT.md: the gap on off-ratio locks).
    public static func largestInRotatedImage(aspect: Double, width: Double, height: Double,
                                             degrees: Double) -> (width: Double, height: Double) {
        guard aspect > 0, aspect.isFinite, width > 0, height > 0,
              width.isFinite, height.isFinite, degrees.isFinite else { return (0, 0) }
        let radians = degrees * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let w = Swift.min(width / (c + s / aspect), height / (s + c / aspect))
        return (w, w / aspect)
    }

    /// Whether all four corners of a crop lie inside the turned picture — "no
    /// transparent corner", stated as a test can check it.
    public static func cropIsInsidePicture(_ crop: Crop, sourceWidth: Double,
                                           sourceHeight: Double, degrees: Double,
                                           tolerance: Double = 1e-6) -> Bool {
        let usable = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        let c = normalized(crop)
        let xs = [c.x, c.x + c.w].map { $0 * usable.width }
        let ys = [c.y, c.y + c.h].map { $0 * usable.height }
        for x in xs {
            for y in ys where !containsInSource(x: x, y: y, sourceWidth: sourceWidth,
                                                sourceHeight: sourceHeight,
                                                degrees: degrees, tolerance: tolerance) {
                return false
            }
        }
        return true
    }
}
