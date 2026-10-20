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
}
