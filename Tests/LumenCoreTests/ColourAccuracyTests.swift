// ColourAccuracyTests.swift
// Regression tests for the colour-accuracy audit (October 2026). Each test was written
// against the unfixed code first and failed there; the comment on each says by how much.

import XCTest
@testable import LumenCore

final class ColourAccuracyTests: XCTestCase {

    // MARK: - Planckian locus

    /// Kim et al. (2002) give three y-cubics; above 4000 K the third one applies. The
    /// locus crossfade reads `planckianLocus` up to 4500 K, so the third segment is live.
    /// Before the fix 4400 K landed at y = 0.365855 (error 1.8e-4).
    func testPlanckianLocusUsesKimsHighSegmentAbove4000K() {
        for t in [4100.0, 4400.0, 5000.0, 6500.0] {
            let c = ColorTemperature.planckianLocus(t)
            let x = c.x
            let expectedY = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
            XCTAssertEqual(c.y, expectedY, accuracy: 1e-9, "y at \(t) K")
        }
        // Published Planckian chromaticity at 5000 K (CIE 1931 2°): (0.3451, 0.3516).
        let p5000 = ColorTemperature.planckianLocus(5000)
        XCTAssertEqual(p5000.x, 0.3451, accuracy: 5e-4)
        XCTAssertEqual(p5000.y, 0.3516, accuracy: 5e-4)
    }

    // MARK: - Display transform

    /// Scene black must land on the black target whatever hue preservation is set to.
    /// Before the fix the hue-stable branch returned 0 for a zero input (its fallback
    /// tested the floored norm, which is never 0), so the floor read 0 at the default
    /// hue preservation of 100 and the black target only at 0.
    func testSceneBlackLandsOnTheBlackTargetAtAnyHuePreservation() {
        var perChannel = DisplayTransformParams()
        perChannel.huePreservation = 0
        let expected = DisplayTransform(perChannel).apply(RGB(0, 0, 0))
        XCTAssertGreaterThan(expected.g, 1e-5, "black target is 0.0152% of white")
        for hp in [100.0, 70.0, 30.0] {
            var p = DisplayTransformParams()
            p.huePreservation = hp
            let out = DisplayTransform(p).apply(RGB(0, 0, 0))
            XCTAssertEqual(out.r, expected.r, accuracy: 1e-9, "hue preservation \(hp)")
            XCTAssertEqual(out.g, expected.g, accuracy: 1e-9, "hue preservation \(hp)")
            XCTAssertEqual(out.b, expected.b, accuracy: 1e-9, "hue preservation \(hp)")
        }
    }
}
