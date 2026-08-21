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
