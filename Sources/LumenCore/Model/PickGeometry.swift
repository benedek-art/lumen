// PickGeometry.swift
// Where a click on the displayed (cropped, straightened, flipped) frame lands in the
// source, and back — as plain arithmetic a Linux test can hold.
//
// The renderer's own pair, `PipelineRenderer.sourceNormalized` / `displayedNormalized`,
// inverts the very `geometryRects` that `applyGeometry` draws with, which is the right
// way to build them and the reason this file does NOT replace them. But they are
// CoreGraphics code behind `#if os(macOS)`, and nothing anywhere tested them: every
// eyedropper, every on-image mask handle and every heal spot goes through a mapping no
// test had ever run. This is its twin, written out from the same expression, so the
// convention is pinned here and `PickGeometryParityTests` (LumenPipelineTests) holds
// the two equal. If they ever disagree the renderer is the authority — it is what the
// picture is drawn with.
//
// THE CONVENTION, from `geometryRects`:
//
//   orientation = identity.scaledBy(x: flipH ? −1 : 1, y: 1).rotated(by: −angle·π/180)
//
// A CGAffineTransform method concatenates its operation IN FRONT, so a point is rotated
// first and then mirrored: p' = F·R(θ)·p with θ = −angle, in Core Image's y-up source
// pixels. The straightened picture keeps its centre, so the usable rectangle
// (`CropGeometry.resolve`) is centred on M·centre, and the crop sits inside it measured
// from its top-left. Displayed coordinates are normalized 0…1, top-left origin.
//
// Not `CGAffineTransform`: it does not exist in Linux Foundation. Not Foundation's
// `AffineTransform` either — its composition order differs, which is exactly the kind of
// silent disagreement this file exists to rule out. A 2x2 matrix is all this needs.

import Foundation

public enum PickGeometry {

    /// The orientation's 2x2 matrix, rows (a, b) and (c, d): x' = a·x + b·y, y' = c·x + d·y.
    private struct Matrix {
        var a: Double
        var b: Double
        var c: Double
        var d: Double

        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            (a * x + b * y, c * x + d * y)
        }

        var inverse: Matrix {
            let det = a * d - b * c
            guard det != 0, det.isFinite else { return Matrix(a: 1, b: 0, c: 0, d: 1) }
            return Matrix(a: d / det, b: -b / det, c: -c / det, d: a / det)
        }
    }

    /// The orientation matrix and the displayed target rectangle, y-up, in source pixels.
    /// `geometryRects` restated.
    private static func rects(_ geo: Geometry, width w: Double, height h: Double)
        -> (orientation: Matrix, minX: Double, maxY: Double, width: Double, height: Double) {
        let theta = -geo.angle * .pi / 180
        let cosT = geo.angle != 0 ? cos(theta) : 1
        let sinT = geo.angle != 0 ? sin(theta) : 0
        // R(θ) = [[cos, −sin], [sin, cos]]; the mirror then negates the x row.
        let flip = geo.flipH ? -1.0 : 1.0
        let m = Matrix(a: flip * cosT, b: -flip * sinT, c: sinT, d: cosT)

        // A linear map sends the rectangle's centre to the centre of the rotated box,
        // and the bounding box of a centrally symmetric shape is centred on it too.
        let mid = m.apply(w / 2, h / 2)
        let resolved = CropGeometry.resolve(sourceWidth: w, sourceHeight: h, geometry: geo)
        let usableMinX = mid.x - resolved.usableWidth / 2
        let usableMaxY = mid.y + resolved.usableHeight / 2
        return (m, usableMinX + resolved.x, usableMaxY - resolved.y,
                resolved.width, resolved.height)
    }

    /// A displayed-frame point (normalized, top-left origin) as the source-normalized
    /// coordinate a recipe stores. `PipelineRenderer.sourceNormalized`'s twin.
    public static func sourcePoint(displayedX u: Double, displayedY v: Double,
                                   geometry: Geometry,
                                   sourceWidth w: Double,
                                   sourceHeight h: Double) -> (x: Double, y: Double) {
        guard w > 0, h > 0 else { return (0, 0) }
        let r = rects(geometry, width: w, height: h)
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let px = r.minX + u * r.width
        let py = r.maxY - v * r.height
        let inSource = r.orientation.inverse.apply(px, py)
        return (inSource.x / w, 1 - inSource.y / h)
    }

    /// The exact inverse: where a source-normalized point lands in the displayed frame.
    /// `PipelineRenderer.displayedNormalized`'s twin.
    public static func displayedPoint(sourceX nx: Double, sourceY ny: Double,
                                      geometry: Geometry,
                                      sourceWidth w: Double,
                                      sourceHeight h: Double) -> (x: Double, y: Double) {
        guard w > 0, h > 0 else { return (0, 0) }
        let r = rects(geometry, width: w, height: h)
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let p = r.orientation.apply(nx * w, (1 - ny) * h)
        return ((p.x - r.minX) / r.width, (r.maxY - p.y) / r.height)
    }
}
