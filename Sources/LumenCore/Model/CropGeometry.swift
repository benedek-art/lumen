// CropGeometry.swift
// Where the crop rectangle actually lands, as arithmetic rather than as a transform
// chain inside a renderer.
//
// This was `PipelineRenderer.applyGeometry`, which is `#if os(macOS)` and had no test of
// any kind. What it computed was wrong in a way that shows on every straightened
// photograph:
//
//     let straightened = out.extent.applying(orientation)
//
// `CGRect.applying` returns the axis-aligned BOUNDING BOX of the transformed rectangle.
// For a rotation that box is strictly larger than the picture — a 3:2 frame at 5° has a
// bounding box 12% larger in area — and the crop was then taken as a fraction of THAT.
// So the default crop of the whole frame, on a straightened photograph, included the
// four empty triangular wedges rotation leaves behind. Nothing anywhere in the
// repository computed an inscribed rectangle, so there was no auto-fit to save it.
//
// The fix is to define the frame the crop is a fraction OF as the largest axis-aligned
// rectangle that fits inside the rotated picture. Then the default crop is the whole of
// that, and any crop inside it is inside the picture — by construction, at every angle,
// rather than by the user noticing and dragging the corners in.
//
// The crop is unchanged at angle 0, where the inscribed rectangle IS the source frame,
// so no existing recipe renders differently unless it was already exposing corners.

import Foundation

public enum CropGeometry {

    /// Smallest crop a drag may produce, as a fraction of the usable frame. Shared with
    /// the overlay so the view and the renderer cannot disagree about the floor.
    public static let minimumCropFraction: Double = 0.05

    // MARK: - The inscribed rectangle

    /// The largest axis-aligned rectangle that fits inside a `width × height` frame
    /// rotated by `degrees`, centred on it.
    ///
    /// The standard result, and worth writing the derivation down because the degenerate
    /// case is easy to miss. Rotating by `a`, a candidate rectangle `wr × hr` has to
    /// satisfy both projections of the source's half-extents:
    ///
    ///     wr·cos a + hr·sin a ≤ W
    ///     wr·sin a + hr·cos a ≤ H
    ///
    /// Solving both with equality gives
    ///
    ///     wr = (W·cos a − H·sin a) / cos 2a
    ///     hr = (H·cos a − W·sin a) / cos 2a
    ///
    /// which is the answer while both numerators are positive. Once the frame is long
    /// enough — `sin 2a · longer ≥ shorter` — one of them goes negative and the true
    /// maximum is pinned by the short side alone: the rectangle spans half the short
    /// side and runs corner to corner, giving `wr = hr·(longer/shorter)` scaled off
    /// `shorter/2`. At `a = 45°` on a square both branches agree at `side/√2`, which is
    /// the check that the join is real and not a fudge.
    public static func usableSize(width: Double, height: Double,
                                  degrees: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return (0, 0) }
        guard degrees.isFinite else { return (width, height) }

        // A rotation and its supplement inscribe the same rectangle, and the sign is
        // irrelevant to size, so fold everything into [0°, 90°].
        var a = degrees.truncatingRemainder(dividingBy: 180)
        if a < 0 { a += 180 }
        if a > 90 { a = 180 - a }
        let radians = a * .pi / 180
        let sinA = abs(sin(radians))
        let cosA = abs(cos(radians))
        if sinA < 1e-12 { return (width, height) }
        if cosA < 1e-12 { return (height, width) }

        let shorter = Swift.min(width, height)
        let longer = Swift.max(width, height)

        if shorter <= 2 * sinA * cosA * longer {
            let half = 0.5 * shorter
            return width >= height
                ? (half / sinA, half / cosA)
                : (half / cosA, half / sinA)
        }
        let cos2a = cosA * cosA - sinA * sinA
        return ((width * cosA - height * sinA) / cos2a,
                (height * cosA - width * sinA) / cos2a)
    }

    // MARK: - Resolving a crop

    /// A crop resolved onto real pixels.
    ///
    /// `x`/`y` are measured from the top-left of the *usable* frame — the inscribed
    /// rectangle above, centred on the rotated picture — because that is the frame the
    /// normalized crop is a fraction of. The renderer converts to Core Image's y-up
    /// extent; nothing here knows about that convention, which is why it can be tested
    /// on a machine with no renderer.
    public struct Resolved: Equatable, Sendable {
        /// The usable frame's size in source pixels, before the crop.
        public var usableWidth: Double
        public var usableHeight: Double
        /// The crop within it, in source pixels, top-left origin.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// Output scale folded in from `targetLongEdge`; 1 when there is none.
        public var scale: Double

        /// What the file ends up being, in whole pixels.
        public var outputWidth: Int { Swift.max(Int((width * scale).rounded()), 1) }
        public var outputHeight: Int { Swift.max(Int((height * scale).rounded()), 1) }

        public init(usableWidth: Double, usableHeight: Double, x: Double, y: Double,
                    width: Double, height: Double, scale: Double) {
            self.usableWidth = usableWidth
            self.usableHeight = usableHeight
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.scale = scale
        }
    }

    public static func resolve(sourceWidth: Double, sourceHeight: Double,
                               geometry: Geometry,
                               targetLongEdge: Int? = nil,
                               allowUpscale: Bool = false) -> Resolved {
        let usable = usableSize(width: sourceWidth, height: sourceHeight,
                                degrees: geometry.angle)
        let crop = normalized(geometry.crop)

        let x = crop.x * usable.width
        let y = crop.y * usable.height
        let w = crop.w * usable.width
        let h = crop.h * usable.height

        var scale = 1.0
        if let targetLongEdge, targetLongEdge > 0 {
            let long = Swift.max(w, h)
            if long > 0 {
                let wanted = Double(targetLongEdge) / long
                scale = allowUpscale ? wanted : Swift.min(1, wanted)
            }
        }
        return Resolved(usableWidth: usable.width, usableHeight: usable.height,
                        x: x, y: y, width: w, height: h, scale: scale)
    }

    /// A crop clamped into the unit square, with a floor on its size.
    ///
    /// Every entry point runs through this: a crop arrives from a sidecar, a catalog row
    /// or a drag, and `w` of 0 or a NaN `x` reaches a `CGRect` otherwise. The floor is
    /// the same one the overlay's drag enforces.
    public static func normalized(_ crop: Crop) -> Crop {
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        var w = Num.clamp(finite(crop.w, 1), minimumCropFraction, 1)
        var h = Num.clamp(finite(crop.h, 1), minimumCropFraction, 1)
        var x = Num.clamp(finite(crop.x, 0), 0, 1)
        var y = Num.clamp(finite(crop.y, 0), 0, 1)
        // Pull the rectangle back inside rather than shrinking it: a crop that ran off
        // the edge is a crop whose POSITION is wrong, and shrinking it instead changes
        // the composition the user framed.
        if x + w > 1 { x = Swift.max(1 - w, 0); w = Swift.min(w, 1 - x) }
        if y + h > 1 { y = Swift.max(1 - h, 0); h = Swift.min(h, 1 - y) }
        return Crop(x: x, y: y, w: w, h: h)
    }

    // MARK: - Verification helpers

    /// Whether a point in the usable frame's own coordinates lies inside the source
    /// picture once the rotation is undone. What "no transparent corners" MEANS, so a
    /// test can assert it rather than assert a formula against itself.
    public static func containsInSource(x: Double, y: Double,
                                        sourceWidth: Double, sourceHeight: Double,
                                        degrees: Double, tolerance: Double = 1e-6) -> Bool {
        let usable = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        // Centre both frames, rotate the point back into the source's axes.
        let cx = x - usable.width / 2
        let cy = y - usable.height / 2
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        let sx = cx * c + cy * s
        let sy = -cx * s + cy * c
        return abs(sx) <= sourceWidth / 2 + tolerance
            && abs(sy) <= sourceHeight / 2 + tolerance
    }
}

// MARK: - Dragging

extension CropGeometry {

    /// Which part of the rectangle a drag has hold of.
    ///
    /// Eight, not four. The overlay offered corners only, so the one-axis adjustment
    /// every crop ends with — "a little off the top" — meant dragging a corner and
    /// fixing the width it also changed.
    public enum Handle: String, CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool {
            self == .bottomLeft || self == .bottom || self == .bottomRight
        }
        var isCorner: Bool {
            self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight
        }
    }

    /// The crop a drag produces, in normalized coordinates.
    ///
    /// `lockedAspect` is width ÷ height in PIXELS, which is what a ratio menu means and
    /// what the user sees. The crop is normalized to the usable frame, so the normalized
    /// ratio is `lockedAspect / frameAspect` — getting that conversion wrong is how "1:1"
    /// produced an 8:9 rectangle on a 4:3 body, which this codebase has already been bitten
    /// by once in the ratio menu.
    ///
    /// Locked drags keep the ratio through the CLAMP as well, which is the half that is
    /// easy to miss: pushing a locked crop into a corner has to shrink both axes, because
    /// clamping one of them is exactly how a lock silently becomes "Custom".
    public static func resize(_ origin: Crop, handle: Handle,
                              dx: Double = 0, dy: Double = 0,
                              lockedAspect: Double? = nil,
                              frameAspect: Double = 1) -> Crop {
        let start = normalized(origin)
        guard dx.isFinite, dy.isFinite else { return start }

        let ratio = lockedRatio(lockedAspect, frameAspect: frameAspect)

        // Anchor: the corner or edge the drag does NOT move.
        let anchorX = handle.movesLeft ? start.x + start.w : start.x
        let anchorY = handle.movesTop ? start.y + start.h : start.y
        let signX: Double = handle.movesLeft ? -1 : 1
        let signY: Double = handle.movesTop ? -1 : 1

        var w = start.w
        var h = start.h
        if handle.movesLeft { w = start.w - dx }
        if handle.movesRight { w = start.w + dx }
        if handle.movesTop { h = start.h - dy }
        if handle.movesBottom { h = start.h + dy }
        w = Swift.max(w, minimumCropFraction)
        h = Swift.max(h, minimumCropFraction)

        if let ratio {
            if handle.isCorner {
                // Honour whichever axis the drag pushed further, so the corner tracks
                // the pointer instead of lagging on one axis.
                w = Swift.max(w, h * ratio)
                h = w / ratio
            } else if handle.movesLeft || handle.movesRight {
                h = w / ratio
            } else {
                w = h * ratio
            }
        }

        var rect = place(anchorX: anchorX, anchorY: anchorY, signX: signX, signY: signY,
                         w: w, h: h, handle: handle, start: start, locked: ratio != nil)

        if let ratio {
            rect = shrinkIntoFrame(rect, anchorX: anchorX, anchorY: anchorY,
                                   signX: signX, signY: signY, ratio: ratio,
                                   handle: handle, start: start)
        }
        return normalized(rect)
    }

    /// The crop a move-drag produces: the rectangle slides, and never resizes.
    public static func move(_ origin: Crop, dx: Double, dy: Double) -> Crop {
        let start = normalized(origin)
        guard dx.isFinite, dy.isFinite else { return start }
        var out = start
        out.x = Num.clamp(start.x + dx, 0, Swift.max(1 - start.w, 0))
        out.y = Num.clamp(start.y + dy, 0, Swift.max(1 - start.h, 0))
        return out
    }

    /// Width ÷ height a ratio menu should report for a crop, in pixels.
    ///
    /// Against the USABLE frame, not the source: a straightened photograph's crop is a
    /// fraction of the inscribed rectangle, so reading it back against the source's own
    /// aspect makes the menu disagree with the rectangle it just wrote.
    public static func displayedAspect(_ crop: Crop, sourceWidth: Double,
                                       sourceHeight: Double, degrees: Double) -> Double? {
        let usable = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        let c = normalized(crop)
        let h = c.h * usable.height
        guard h > 0, usable.width > 0 else { return nil }
        return (c.w * usable.width) / h
    }

    /// The crop a ratio menu should write: `aspect` in pixels, centred, as large as fits.
    public static func centred(aspect: Double, sourceWidth: Double, sourceHeight: Double,
                               degrees: Double) -> Crop {
        let usable = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        guard aspect > 0, aspect.isFinite, usable.width > 0, usable.height > 0 else {
            return Crop()
        }
        let frameAspect = usable.width / usable.height
        var w = 1.0, h = 1.0
        if aspect > frameAspect { h = frameAspect / aspect } else { w = aspect / frameAspect }
        return normalized(Crop(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h))
    }

    // MARK: Drag internals

    private static func lockedRatio(_ lockedAspect: Double?, frameAspect: Double) -> Double? {
        guard let lockedAspect, lockedAspect.isFinite, lockedAspect > 0,
              frameAspect.isFinite, frameAspect > 0 else { return nil }
        return lockedAspect / frameAspect
    }

    /// Rebuild the rectangle from its anchor. An edge handle keeps the extent it does
    /// not drive — unless a lock derived it, in which case it grows about that edge's
    /// midpoint, which is what keeps a locked edge drag from walking sideways.
    private static func place(anchorX: Double, anchorY: Double,
                              signX: Double, signY: Double,
                              w: Double, h: Double, handle: Handle,
                              start: Crop, locked: Bool) -> Crop {
        var x: Double
        var y: Double
        if handle.movesLeft || handle.movesRight {
            x = signX > 0 ? anchorX : anchorX - w
        } else {
            x = locked ? start.x + (start.w - w) / 2 : start.x
        }
        if handle.movesTop || handle.movesBottom {
            y = signY > 0 ? anchorY : anchorY - h
        } else {
            y = locked ? start.y + (start.h - h) / 2 : start.y
        }
        return Crop(x: x, y: y, w: w, h: h)
    }

    /// Shrink a locked rectangle about its anchor until it fits the unit square.
    ///
    /// Clamping the offending edge instead is what turns a 16:9 crop into "Custom" the
    /// moment it touches the top of the frame.
    private static func shrinkIntoFrame(_ rect: Crop, anchorX: Double, anchorY: Double,
                                        signX: Double, signY: Double, ratio: Double,
                                        handle: Handle, start: Crop) -> Crop {
        var w = rect.w
        var h = rect.h
        // How much room the anchor leaves in each direction the rectangle grows.
        let roomX = handle.movesLeft || handle.movesRight
            ? (signX > 0 ? 1 - anchorX : anchorX)
            : 1.0
        let roomY = handle.movesTop || handle.movesBottom
            ? (signY > 0 ? 1 - anchorY : anchorY)
            : 1.0
        if roomX > 0, w > roomX { w = roomX; h = w / ratio }
        if roomY > 0, h > roomY { h = roomY; w = h * ratio }
        // The floor is ratio-preserving too. Flooring each axis on its own is the same
        // mistake as clamping each edge on its own — a locked crop dragged past the
        // minimum came out at the FRAME's aspect rather than its own, so the lock broke
        // at exactly the moment the drag got extreme.
        if w < minimumCropFraction { w = minimumCropFraction; h = w / ratio }
        if h < minimumCropFraction { h = minimumCropFraction; w = h * ratio }
        return place(anchorX: anchorX, anchorY: anchorY, signX: signX, signY: signY,
                     w: w, h: h, handle: handle, start: start, locked: true)
    }
}

// MARK: - Rotating

extension CropGeometry {

    /// How far from the pivot a rotate-drag has to be before it carries an angle, in the
    /// same view points the drag is measured in.
    ///
    /// An angle taken from two points a few pixels either side of the centre is noise
    /// in the way a two-pixel ruler drag is noise, and it arrives as a violent spin
    /// rather than as a small one. `Straighten.minimumDragFraction` is the same rule for
    /// the same reason, stated against a length instead of a radius.
    public static let minimumRotationRadius: Double = 16

    /// The signed sweep, in degrees, from one point to another about a centre.
    ///
    /// Measured in VIEW points with y DOWNWARD, as a drag gesture hands them over, so a
    /// positive sweep is clockwise on the screen — the same convention `Straighten`
    /// measures its ruler in, and the reason both live here rather than in the overlay
    /// that captures the drag.
    ///
    /// One `atan2` of the cross and dot products, not the difference of two `atan2`s:
    /// the difference wraps at ±180° and has to be unwrapped afterwards, and a rotate
    /// drag that crosses the pointer over the pivot's twelve o'clock is exactly where
    /// that unwrapping gets forgotten. This form is the signed angle BETWEEN the two
    /// vectors by construction.
    public static func rotationSweep(centreX: Double, centreY: Double,
                                     fromX: Double, fromY: Double,
                                     toX: Double, toY: Double,
                                     minimumRadius: Double = minimumRotationRadius) -> Double? {
        let ax = fromX - centreX, ay = fromY - centreY
        let bx = toX - centreX, by = toY - centreY
        guard ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite else { return nil }
        let floor = Swift.max(minimumRadius, 1e-9)
        guard (ax * ax + ay * ay).squareRoot() >= floor,
              (bx * bx + by * by).squareRoot() >= floor else { return nil }
        let sweep = atan2(ax * by - ay * bx, ax * bx + ay * by) * 180 / .pi
        return sweep.isFinite ? sweep : nil
    }

    /// The angle the recipe should hold after a rotate-drag, given the angle it held
    /// when that drag began.
    ///
    /// THE SIGN, which is the only hard part and is `Straighten`'s derivation applied
    /// the other way round. A source direction `s` appears on the frame at `angle + s`,
    /// and at `−(angle + s)` when the frame is mirrored. So making the picture follow a
    /// clockwise pointer means RAISING the angle — and lowering it under a flip, where
    /// the mirror has already negated the sweep. Backwards, the picture runs away from
    /// the pointer, and only on the photographs somebody flipped.
    ///
    /// Clamped to the straighten range, so the slider, the ruler and this gesture cannot
    /// disagree about what the angle is allowed to be.
    public static func rotationAngle(from startAngle: Double, sweep: Double,
                                     flipped: Bool = false) -> Double {
        guard startAngle.isFinite, sweep.isFinite else { return 0 }
        let next = flipped ? startAngle - sweep : startAngle + sweep
        return Num.clamp(next, -Straighten.limitDegrees, Straighten.limitDegrees)
    }
}

// MARK: - Carrying a rectangle through an angle change

extension CropGeometry {

    /// The crop the recipe should hold after the straighten angle changes, given the
    /// crop it held before.
    ///
    /// The crop is stored as fractions of the USABLE frame, and the usable frame is a
    /// different rectangle at every angle — so a crop left untouched through an angle
    /// change is silently rescaled by the ratio of the two frames. Two people feel that:
    /// the owner, for whom every turn of the angle re-cropped the default full-frame
    /// rectangle to 100% of the new inscribed frame ("it automatically removes all the
    /// stuff… I want to tilt the image and then move the square that I made"), and
    /// anyone holding a ratio lock, whose 16:9 read 1.83:1 at 2° and 2.13:1 at 10° with
    /// the padlock still closed (docs/31 #10) — the two usable extents shrink by
    /// different factors, so pinned fractions cannot keep a pixel aspect.
    ///
    /// So the rectangle is stated in PIXELS, carried across, and restated against the
    /// new frame: the same pixel extent on the same centre where it fits, shrunk about
    /// its centre — both axes together, aspect preserved — by exactly the factor the new
    /// frame forces where it does not, and slid the least distance that brings it
    /// inside. Tilting becomes a rotation under a stable box rather than a re-crop, and
    /// a locked ratio survives the angle. The shrink is deliberately not undone on the
    /// way back: an angle returning toward 0° keeps whatever rectangle the excursion
    /// left, because growing a box nobody dragged is a re-crop by another name.
    ///
    /// Both usable frames are centred on the rotated picture, which is what makes the
    /// centre OFFSET the part of the position that survives the change of frame.
    public static func reangled(_ crop: Crop, sourceWidth: Double, sourceHeight: Double,
                                from oldDegrees: Double, to newDegrees: Double) -> Crop {
        let before = usableSize(width: sourceWidth, height: sourceHeight,
                                degrees: oldDegrees)
        let after = usableSize(width: sourceWidth, height: sourceHeight,
                               degrees: newDegrees)
        let c = normalized(crop)
        guard before.width > 0, before.height > 0,
              after.width > 0, after.height > 0 else { return c }

        // The rectangle in source pixels: its extent, and its centre's offset from the
        // frame's own centre.
        let w = c.w * before.width
        let h = c.h * before.height
        let cx = (c.x + c.w / 2 - 0.5) * before.width
        let cy = (c.y + c.h / 2 - 0.5) * before.height
        guard w > 0, h > 0 else { return c }

        // One scale for both axes, and only as much as the new frame demands. Clamping
        // each axis on its own is exactly how the aspect — and any ratio lock riding on
        // it — would break.
        let scale = Swift.min(1, after.width / w, after.height / h)
        let w2 = w * scale
        let h2 = h * scale
        let cx2 = Num.clamp(cx, -(after.width - w2) / 2, (after.width - w2) / 2)
        let cy2 = Num.clamp(cy, -(after.height - h2) / 2, (after.height - h2) / 2)
        return normalized(Crop(x: (cx2 - w2 / 2) / after.width + 0.5,
                               y: (cy2 - h2 / 2) / after.height + 0.5,
                               w: w2 / after.width,
                               h: h2 / after.height))
    }
}

// MARK: - Re-shaping a rectangle that already exists

extension CropGeometry {

    /// The crop a ratio menu should write OVER an existing rectangle: `aspect` in
    /// pixels, on the same centre, at the same scale, as large as the frame allows.
    ///
    /// `centred` throws the framing away, and that is what made "Original" a destructive
    /// button — the one control that could clear a ratio lock also put the rectangle
    /// back to the whole frame, so there was no way to say "keep this crop, stop holding
    /// 16:9". Reaching for the larger of the two scales rather than the smaller keeps
    /// the subject inside the new shape instead of shrinking away from it.
    public static func refit(_ crop: Crop, aspect: Double, sourceWidth: Double,
                             sourceHeight: Double, degrees: Double) -> Crop {
        let full = centred(aspect: aspect, sourceWidth: sourceWidth,
                           sourceHeight: sourceHeight, degrees: degrees)
        let c = normalized(crop)
        guard full.w > 0, full.h > 0 else { return c }
        // The floor is ratio-preserving, for the reason `shrinkIntoFrame` states: a
        // rectangle floored on one axis alone comes out at the FRAME's aspect rather
        // than its own, so the lock breaks at exactly the moment the crop gets small.
        let floor = Swift.min(Swift.max(minimumCropFraction / full.w,
                                        minimumCropFraction / full.h), 1)
        let scale = Num.clamp(Swift.max(c.w / full.w, c.h / full.h), floor, 1)
        let w = full.w * scale
        let h = full.h * scale
        return normalized(Crop(x: c.x + (c.w - w) / 2, y: c.y + (c.h - h) / 2, w: w, h: h))
    }

    /// The same rectangle turned on its side: the reciprocal pixel ratio, the same pixel
    /// dimensions where they still fit, on the same centre.
    ///
    /// docs/09 binds this to X and calls it "flip orientation". It is not a flip — the
    /// picture does not move — and it is the move a portrait crop of a landscape frame
    /// needs, which the ratio menu cannot express because every ratio in it is written
    /// wide.
    ///
    /// Swapped in PIXELS and converted back, because the crop is a fraction of the
    /// usable frame: swapping the normalized extents instead turns a 3:2 crop of a 3:2
    /// body into 4:9.
    public static func swappingOrientation(_ crop: Crop, sourceWidth: Double,
                                           sourceHeight: Double,
                                           degrees: Double) -> Crop {
        let usable = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        let c = normalized(crop)
        guard usable.width > 0, usable.height > 0 else { return c }
        var w = c.h * usable.height / usable.width
        var h = c.w * usable.width / usable.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return c }
        let over = Swift.max(w, h)
        if over > 1 { w /= over; h /= over }
        // The floor is ratio-preserving where the frame allows it, and capped where it
        // does not: a 140:1 crop of a 7:1 body has no 1:140 counterpart that fits, and
        // the honest answer there is the largest rectangle that does rather than one
        // that runs off the edge. `normalized` finishes it.
        let floor = Swift.max(minimumCropFraction / w, minimumCropFraction / h)
        if floor > 1 {
            let capped = Swift.min(floor, Swift.min(1 / w, 1 / h))
            w *= capped
            h *= capped
        }
        return normalized(Crop(x: c.x + (c.w - w) / 2, y: c.y + (c.h - h) / 2, w: w, h: h))
    }

    /// A ratio typed by hand — `16:9`, `16/9`, `3 x 2`, `1.85` — as width ÷ height.
    ///
    /// Nil for anything that is not a plausible ratio, so a custom field can decline an
    /// entry rather than write a rectangle nobody asked for. The bounds are wider than
    /// any preset and narrower than the arithmetic's own limits: 1:60 is a panorama and
    /// 1:600 is a typo.
    public static func aspect(fromText text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ":/xX×÷"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Empty pieces are kept and then refused, rather than filtered away: dropping
        // them turns the half-typed `16:` into a plain 16, which is a 16:1 crop written
        // while somebody was still reaching for the 9.
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let ratio: Double?
        switch parts.count {
        case 1: ratio = Double(parts[0])
        case 2:
            if let a = Double(parts[0]), let b = Double(parts[1]), b != 0 {
                ratio = a / b
            } else {
                ratio = nil
            }
        default: ratio = nil
        }
        guard let ratio, ratio.isFinite, ratio >= 1.0 / 60, ratio <= 60 else { return nil }
        return ratio
    }
}
