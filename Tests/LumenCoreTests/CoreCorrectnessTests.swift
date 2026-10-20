// CoreCorrectnessTests.swift
//
// Regression tests for correctness bugs found in the October 2026 LumenCore audit
// (outside colour and tone maths). Each test failed before its fix.

import Foundation
import XCTest
@testable import LumenCore

final class CoreCorrectnessTests: XCTestCase {

    // MARK: - SpatialOps.boxBlur

    /// The running sum used to latch a non-finite sample: NaN - NaN is NaN and
    /// Inf - Inf is NaN, so one bad pixel turned everything below and right of it NaN.
    /// Only outputs whose window holds the bad sample may be affected.
    func testBoxBlurKeepsANonFiniteSampleInsideItsWindow() {
        for poison in [Float.nan, .infinity, -.infinity] {
            var p = Plane(width: 16, height: 16, fill: 1)
            p.values[2 * 16 + 2] = poison
            let out = SpatialOps.boxBlur(p, radius: 1)
            for y in 0..<16 {
                for x in 0..<16 where abs(x - 2) > 1 || abs(y - 2) > 1 {
                    XCTAssertEqual(out[x, y], 1, accuracy: 1e-6, "poison \(poison) at (\(x),\(y))")
                }
            }
            XCTAssertFalse(out[2, 2].isFinite, "inside the window the bad sample is still reported")
        }
    }

    func testBoxBlurOfFiniteInputIsUnchangedByTheGuard() {
        let p = Plane(width: 9, height: 7, values: (0..<63).map { Float(($0 * 37) % 11) / 10 })
        let out = SpatialOps.boxBlur(p, radius: 2)
        // Hand-computed reference: clamp-to-edge box of width 5, separable.
        for y in 0..<7 {
            for x in 0..<9 {
                var sum = 0.0
                for dy in -2...2 {
                    for dx in -2...2 { sum += p.clampedSample(x + dx, y + dy) }
                }
                XCTAssertEqual(out[x, y], sum / 25, accuracy: 1e-6)
            }
        }
    }

    // MARK: - Spot retouch

    /// A finite but huge spot or source position (hand-edited or corrupt sidecar) used
    /// to trap in Int(floor(...)) on every render of the photo. StrokeHeal already
    /// refuses these; spots must too.
    func testHugeFiniteSpotCoordinatesDoNotTrap() {
        let image = ImageBuffer(width: 40, height: 30) { u, v in RGB(gray: 0.2 + 0.3 * u + 0.1 * v) }
        for v in [1e20, -1e20, 1e300, -1e300, Double.greatestFiniteMagnitude] {
            let far = HealSpot(x: v, y: 0.5, sourceX: 0.5, sourceY: 0.5)
            XCTAssertNil(SpotRetouch.resolve(far, width: 40, height: 30))
            let farY = HealSpot(x: 0.5, y: v, sourceX: 0.5, sourceY: 0.5)
            XCTAssertNil(SpotRetouch.resolve(farY, width: 40, height: 30))
            XCTAssertEqual(SpotRetouch.apply(image, spots: [far, farY]).pixels, image.pixels)
            for mode in [HealMode.clone, .heal] {
                let farSource = HealSpot(mode: mode, x: 0.5, y: 0.5, sourceX: v, sourceY: -v)
                let out = SpotRetouch.apply(image, spots: [farSource])
                XCTAssertTrue(out.pixels.allSatisfy { $0.isFinite }, "\(mode) \(v)")
            }
            let window = SpotSourceSearch.window(for: far, sourceWidth: 40, sourceHeight: 30)
            XCTAssertGreaterThanOrEqual(window.width, 1)
            XCTAssertLessThanOrEqual(window.x + window.width, 40)
        }
    }

    func testBilinearFarOffTheFrameRepeatsTheEdge() {
        let image = ImageBuffer(width: 4, height: 3) { u, v in RGB(u, v, 0.5) }
        XCTAssertEqual(image.bilinear(-1e30, 1.5), image.bilinear(-3, 1.5))
        XCTAssertEqual(image.bilinear(1e30, 1e30), image[3, 2])
    }

    /// An automask stroke samples the source at each stamp BEFORE the off-frame check,
    /// so a huge finite point from a stroke blob used to trap in bilinear.
    func testAutomaskStrokeWithAHugeFinitePointDoesNotTrap() {
        let src = ImageBuffer(width: 64, height: 48) { _, _ in RGB(gray: 0.3) }
        for v in [1e20, -1e20, 1e300] {
            for (x, y) in [(v, 0.5), (0.5, v)] {
                let stroke = BrushStroke(points: [BrushPoint(x: x, y: y)], size: 0.1, automask: true)
                let plane = MaskRaster.accumulatedBrushPlane(
                    strokes: BrushStrokeSet(strokes: [stroke]), size: (width: 64, height: 48),
                    source: src, resuming: nil)
                XCTAssertEqual(plane.values.max() ?? 0, 0, "x=\(x) y=\(y)")
            }
        }
    }

    // MARK: - Crop drags

    /// Dragging an unlocked handle past the frame edge used to move the opposite edge:
    /// the overflow went to `normalized`, which keeps the size and slides the rectangle.
    func testAnUnlockedOvershootDoesNotMoveTheAnchor() {
        let start = Crop(x: 0.2, y: 0.2, w: 0.6, h: 0.6)
        let l = CropGeometry.resize(start, handle: .left, dx: -0.3)
        XCTAssertEqual(l.x, 0, accuracy: 1e-12)
        XCTAssertEqual(l.x + l.w, 0.8, accuracy: 1e-12)
        let r = CropGeometry.resize(start, handle: .right, dx: 0.3)
        XCTAssertEqual(r.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(r.x + r.w, 1.0, accuracy: 1e-12)
        let t = CropGeometry.resize(start, handle: .top, dy: -0.5)
        XCTAssertEqual(t.y, 0, accuracy: 1e-12)
        XCTAssertEqual(t.y + t.h, 0.8, accuracy: 1e-12)
        let b = CropGeometry.resize(start, handle: .bottom, dy: 0.3)
        XCTAssertEqual(b.y, 0.2, accuracy: 1e-12)
        XCTAssertEqual(b.y + b.h, 1.0, accuracy: 1e-12)
        let tl = CropGeometry.resize(start, handle: .topLeft, dx: -0.3, dy: -0.3)
        XCTAssertEqual(tl.x, 0, accuracy: 1e-12)
        XCTAssertEqual(tl.y, 0, accuracy: 1e-12)
        XCTAssertEqual(tl.x + tl.w, 0.8, accuracy: 1e-12)
        XCTAssertEqual(tl.y + tl.h, 0.8, accuracy: 1e-12)
        let br = CropGeometry.resize(start, handle: .bottomRight, dx: 0.3, dy: 0.3)
        XCTAssertEqual(br.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(br.y, 0.2, accuracy: 1e-12)
    }

    /// A locked corner dragged inward along one axis used to do nothing: the corner
    /// branch took the LARGER extent, which is the axis that did not move.
    func testALockedCornerDragInwardShrinks() {
        let start = Crop(x: 0.2, y: 0.2, w: 0.4, h: 0.4)
        let out = CropGeometry.resize(start, handle: .bottomRight, dx: -0.2, dy: 0,
                                      lockedAspect: 1.5, frameAspect: 1.5)
        XCTAssertEqual(out.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.2, accuracy: 1e-12)
        XCTAssertEqual(out.w, 0.2, accuracy: 1e-9)
        XCTAssertEqual(out.h, 0.2, accuracy: 1e-9)
        let up = CropGeometry.resize(start, handle: .topLeft, dx: 0, dy: 0.1,
                                     lockedAspect: 1.5, frameAspect: 1.5)
        XCTAssertEqual(up.w, 0.3, accuracy: 1e-9)
        XCTAssertEqual(up.h, 0.3, accuracy: 1e-9)
        XCTAssertEqual(up.x + up.w, 0.6, accuracy: 1e-12)
        XCTAssertEqual(up.y + up.h, 0.6, accuracy: 1e-12)
        // Growing still follows the axis pushed further.
        let grow = CropGeometry.resize(start, handle: .bottomRight, dx: 0.1, dy: 0.2,
                                       lockedAspect: 1.5, frameAspect: 1.5)
        XCTAssertEqual(grow.w, 0.6, accuracy: 1e-9)
        XCTAssertEqual(grow.h, 0.6, accuracy: 1e-9)
    }
}
