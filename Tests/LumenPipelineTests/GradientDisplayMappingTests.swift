#if os(macOS)
// GradientDisplayMappingTests.swift
// Lane M3 SPEC S10: the map from a mask's SOURCE frame to the displayed (cropped,
// straightened, flipped) frame is a similarity, so what `MaskCanvas` draws perpendicular
// on screen — a gradient's three lines across its axis, an ellipse's two axes — is
// perpendicular in source pixels, which is the frame `MaskRaster` and the mask kernels
// evaluate in. If this map ever picked up a shear or an anisotropic scale, the handles
// would draw in one place and the mask would render in another on rotated crops only,
// which is exactly the kind of drift nobody sees at fit-to-window on an uncropped file.

import CoreGraphics
import XCTest
import LumenCore
@testable import LumenPipeline

final class GradientDisplayMappingTests: XCTestCase {

    private let source = CGSize(width: 6000, height: 4000)

    private func geometries() -> [Geometry] {
        var out: [Geometry] = [Geometry()]
        for angle in [-17.0, 3.5, 30.0] {
            for flip in [false, true] {
                var g = Geometry()
                g.angle = angle
                g.flipH = flip
                g.crop = Crop(x: 0.1, y: 0.15, w: 0.6, h: 0.5)
                out.append(g)
            }
        }
        return out
    }

    /// Displayed-normalized → displayed PIXELS of the target frame, where a similarity
    /// has to show itself (normalized display coordinates are per-axis, like the recipe's).
    private func displayedPixels(_ nx: Double, _ ny: Double, _ g: Geometry) -> CGPoint {
        let d = PipelineRenderer.displayedNormalized(sourceX: nx, sourceY: ny,
                                                     geometry: g, sourceSize: source)
        let target = PipelineRenderer.geometryRects(g, sourceSize: source).target
        return CGPoint(x: d.x * target.width, y: d.y * target.height)
    }

    func testRoundTripIsExact() {
        for g in geometries() {
            for (u, v) in [(0.0, 0.0), (0.3, 0.7), (1.0, 1.0), (0.52, 0.11)] {
                let s = PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                                                          geometry: g, sourceSize: source)
                let back = PipelineRenderer.displayedNormalized(
                    sourceX: Double(s.x), sourceY: Double(s.y), geometry: g, sourceSize: source)
                XCTAssertEqual(Double(back.x), u, accuracy: 1e-9, "angle \(g.angle)")
                XCTAssertEqual(Double(back.y), v, accuracy: 1e-9, "angle \(g.angle)")
            }
        }
    }

    /// Two perpendicular, equal-length vectors in SOURCE PIXELS map to two perpendicular,
    /// equal-length vectors in displayed pixels, at every axis angle.
    func testPerpendicularInPixelsStaysPerpendicularOnScreen() {
        let w = Double(source.width), h = Double(source.height)
        for g in geometries() {
            for axis in stride(from: 0.0, to: 180.0, by: 22.5) {
                let a = axis * Double.pi / 180
                let len = 500.0                                   // source pixels
                let c = (x: 0.45, y: 0.5)
                let u = (x: cos(a) * len / w, y: sin(a) * len / h)
                let v = (x: -sin(a) * len / w, y: cos(a) * len / h)
                let p0 = displayedPixels(c.x, c.y, g)
                let pu = displayedPixels(c.x + u.x, c.y + u.y, g)
                let pv = displayedPixels(c.x + v.x, c.y + v.y, g)
                let du = (Double(pu.x - p0.x), Double(pu.y - p0.y))
                let dv = (Double(pv.x - p0.x), Double(pv.y - p0.y))
                let lu = (du.0 * du.0 + du.1 * du.1).squareRoot()
                let lv = (dv.0 * dv.0 + dv.1 * dv.1).squareRoot()
                let cosAngle = (du.0 * dv.0 + du.1 * dv.1) / (lu * lv)
                let degrees = acos(Swift.max(-1, Swift.min(1, cosAngle))) * 180 / Double.pi
                XCTAssertEqual(degrees, 90, accuracy: 0.01,
                               "axis \(axis)°, straighten \(g.angle)°, flip \(g.flipH)")
                XCTAssertEqual(lu / lv, 1, accuracy: 1e-6, "anisotropic scale")
            }
        }
    }
}
#endif
