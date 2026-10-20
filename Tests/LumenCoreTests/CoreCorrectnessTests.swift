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
}
