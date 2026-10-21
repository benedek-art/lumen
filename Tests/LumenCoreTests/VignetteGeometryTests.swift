// VignetteGeometryTests.swift
// WS-41 SPEC lines 6-12 on the analytic profile and shape, plus rendered checks of
// the corner and the centre (line 10). `scripts/proof/ws41/profile.py` measures the
// same claims on lumen-render's 8-bit output.

import XCTest
@testable import LumenCore

final class VignetteGeometryTests: XCTestCase {

    /// ρ at which the profile reaches `level`, by bisection on [0, 1].
    private func radius(at level: Double, lower: Double, upper: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if DetailEngine.vignetteProfile(radius: mid, lower: lower, upper: upper) < level {
                lo = mid
            } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    private func edges(_ midpoint: Double, _ feather: Double, hd: Double = .infinity)
        -> (lower: Double, upper: Double) {
        DetailEngine.vignetteEdges(midpoint: midpoint, feather: feather, pixelHalfDiagonal: hd)
    }

    /// Line 6: r50(50) is the historical 0.6875, r50(0) ≤ 0.30, 0.90 ≤ r50(100) ≤ 1,
    /// strictly increasing with every 10 of midpoint moving it ≥ 0.02.
    func testMidpointSetsTheFiftyPercentRadius() {
        var previous = -Double.infinity
        for m in stride(from: 0.0, through: 100.0, by: 10.0) {
            let e = edges(m, 50)
            let r50 = radius(at: 0.5, lower: e.lower, upper: e.upper)
            XCTAssertEqual(r50, DetailEngine.vignetteCentre(midpoint: m), accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(r50 - previous, 0.02, "midpoint \(m)")
            previous = r50
        }
        XCTAssertEqual(DetailEngine.vignetteCentre(midpoint: 50), 0.6875, accuracy: 0)
        XCTAssertLessThanOrEqual(DetailEngine.vignetteCentre(midpoint: 0), 0.30)
        XCTAssertGreaterThanOrEqual(DetailEngine.vignetteCentre(midpoint: 100), 0.90)
        XCTAssertLessThanOrEqual(DetailEngine.vignetteCentre(midpoint: 100), 1.00)
        let e = edges(50, 50)
        XCTAssertEqual(e.lower, 0.375, accuracy: 0, "the default is the historical inner edge")
        XCTAssertEqual(e.upper, 1.0, accuracy: 0, "the default ends at the corner")
    }

    /// Lines 7 and 8: feather moves r50 by ≤ 0.02 at midpoints 25/50/75 and sets the
    /// 10-90 % width — 0.380 at 50, ≥ 0.60 at 100, every step of 10 above 0 adding ≥ 0.02.
    func testFeatherSetsTheWidthAndNotTheMidpoint() {
        for m in [25.0, 50.0, 75.0] {
            var r50s: [Double] = []
            for f in stride(from: 0.0, through: 100.0, by: 10.0) {
                let e = edges(m, f, hd: 461.5)
                r50s.append(radius(at: 0.5, lower: e.lower, upper: Swift.min(e.upper, 5)))
            }
            XCTAssertLessThanOrEqual(r50s.max()! - r50s.min()!, 0.02, "midpoint \(m)")
        }
        var widths: [Double] = []
        for f in stride(from: 0.0, through: 100.0, by: 10.0) {
            let e = edges(50, f, hd: 461.5)
            widths.append(radius(at: 0.9, lower: e.lower, upper: e.upper)
                          - radius(at: 0.1, lower: e.lower, upper: e.upper))
        }
        XCTAssertEqual(widths[5], 0.3803, accuracy: 0.006)
        XCTAssertGreaterThanOrEqual(widths[10], 0.60)
        for i in 2..<widths.count {
            XCTAssertGreaterThanOrEqual(widths[i] - widths[i - 1], 0.02, "feather \(i * 10)")
        }
    }

    /// Line 9: feather 0 is a hard edge one to two output pixels wide, whatever the size.
    func testFeatherZeroIsAHardAntiAliasedEdge() {
        for size in [(768.0, 512.0), (1536.0, 1024.0), (65.0, 65.0)] {
            let field = VignetteField(sourceWidth: size.0, sourceHeight: size.1)
            let e = edges(50, 0, hd: field.pixelHalfDiagonal)
            let widthPixels = (radius(at: 0.9, lower: e.lower, upper: e.upper)
                - radius(at: 0.1, lower: e.lower, upper: e.upper)) * field.pixelHalfDiagonal
            XCTAssertGreaterThanOrEqual(widthPixels, 1, "\(size)")
            XCTAssertLessThanOrEqual(widthPixels, 3, "\(size)")
        }
    }

    /// Line 10: the corner receives all of Amount while c + s/2 ≤ 1, and frac(1) beyond
    /// — at least half, continuous and non-increasing in midpoint and feather.
    func testTheCornerGetsTheAmountOrFracOne() {
        var previousRow: [Double] = []
        for m in stride(from: 0.0, through: 100.0, by: 5.0) {
            var row: [Double] = []
            var previous = Double.infinity
            for f in stride(from: 0.0, through: 100.0, by: 5.0) {
                let e = edges(m, f, hd: 500)
                let corner = DetailEngine.vignetteProfile(radius: 1, lower: e.lower,
                                                          upper: e.upper)
                if e.upper <= 1 {
                    XCTAssertEqual(corner, 1, accuracy: 1e-9, "m \(m) f \(f)")
                }
                XCTAssertGreaterThanOrEqual(corner, 0.5, "m \(m) f \(f)")
                XCTAssertLessThanOrEqual(corner, previous + 1e-12, "non-increasing in feather")
                previous = corner
                row.append(corner)
            }
            if !previousRow.isEmpty {
                for (a, b) in zip(previousRow, row) {
                    XCTAssertLessThanOrEqual(b, a + 1e-12, "non-increasing in midpoint")
                }
            }
            previousRow = row
        }
    }

    /// Line 10, rendered: the corner gets its stated share and the centre is bitwise
    /// untouched whenever c − s/2 > 0.
    func testTheRenderedCornerAndCentre() {
        let frame = ImageBuffer(width: 151, height: 101) { _, _ in RGB(gray: 0.18) }
        let field = VignetteField(sourceWidth: 151, sourceHeight: 101)
        for (m, f) in [(50.0, 50.0), (100.0, 100.0), (0.0, 0.0), (75.0, 20.0)] {
            let s = VignetteSettings(amount: -2, feather: f, midpoint: m)
            let out = DetailEngine.vignette(frame, s)
            let e = edges(m, f, hd: field.pixelHalfDiagonal)
            let p = field.uv(column: 0, row: 0)
            let frac = DetailEngine.vignetteProfile(
                radius: DetailEngine.vignetteRadius(u: p.u, v: p.v, exponent: 2, weight: 1),
                lower: e.lower, upper: e.upper)
            XCTAssertEqual(log2(out[0, 0].g / frame[0, 0].g) / -2, frac, accuracy: 1e-5)
            if e.upper <= 1 { XCTAssertEqual(frac, 1, accuracy: 0.015) }
            if e.lower > 0 {
                XCTAssertEqual(out[75, 50], frame[75, 50], "centre moved at m \(m) f \(f)")
            }
        }
    }

    /// Line 11: −100 is a rounded rectangle (edge midpoints ≥ 0.80 of Amount, flat
    /// along the edges), 0 the historical ellipse (0.540 at the edge midpoints), +100 a
    /// circle in pixels. The corner is at ρ = 1 for every roundness.
    func testRoundnessShapesTheVignette() {
        let field = VignetteField(sourceWidth: 768, sourceHeight: 512)
        let e = edges(50, 50)
        func frac(_ roundness: Double, _ u: Double, _ v: Double) -> Double {
            let shape = DetailEngine.vignetteShape(roundness: roundness,
                                                   halfWidth: field.halfWidth,
                                                   halfHeight: field.halfHeight)
            return DetailEngine.vignetteProfile(
                radius: DetailEngine.vignetteRadius(u: u, v: v, exponent: shape.exponent,
                                                    weight: shape.weight),
                lower: e.lower, upper: e.upper)
        }
        for r in stride(from: -100.0, through: 100.0, by: 10.0) {
            XCTAssertEqual(frac(r, 1, 1), 1, accuracy: 1e-9, "corner at roundness \(r)")
            let shape = DetailEngine.vignetteShape(roundness: r, halfWidth: 384,
                                                   halfHeight: 256)
            XCTAssertEqual(DetailEngine.vignetteRadius(u: 1, v: -1, exponent: shape.exponent,
                                                       weight: shape.weight), 1,
                           accuracy: 1e-12)
        }
        // −100
        XCTAssertGreaterThanOrEqual(frac(-100, 1, 0), 0.80)
        XCTAssertGreaterThanOrEqual(frac(-100, 0, 1), 0.80)
        let topVar = stride(from: -0.6, through: 0.6, by: 0.05).map { frac(-100, $0, 1) }
        XCTAssertLessThanOrEqual(topVar.max()! - topVar.min()!, 0.10)
        // 0
        XCTAssertEqual(frac(0, 1, 0), 0.540, accuracy: 0.01)
        XCTAssertEqual(frac(0, 0, 1), 0.540, accuracy: 0.01)
        // +100: the 50 % contour is a circle in pixels.
        let shape = DetailEngine.vignetteShape(roundness: 100, halfWidth: 384, halfHeight: 256)
        var contour: [Double] = []
        for degrees in stride(from: 0.0, through: 45.0, by: 5.0) {
            let a = degrees * .pi / 180
            var lo = 0.0, hi = 461.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                let rho = DetailEngine.vignetteRadius(u: mid * cos(a) / 384,
                                                      v: mid * sin(a) / 256,
                                                      exponent: shape.exponent,
                                                      weight: shape.weight)
                if DetailEngine.vignetteProfile(radius: rho, lower: e.lower,
                                                upper: e.upper) < 0.5 { lo = mid } else { hi = mid }
            }
            contour.append(lo)
        }
        XCTAssertLessThanOrEqual(contour.max()! / contour.min()!, 1.02)
        XCTAssertGreaterThanOrEqual(frac(100, 1, 0), 0.75)
        XCTAssertLessThanOrEqual(frac(100, 0, 1), 0.25)
    }

    /// Line 12: top_mid strictly decreases from −100 to +100 with every step of 20
    /// moving it ≥ 0.02 on 3:2, and 0…+100 is the same circle on 1:1.
    func testRoundnessIsMonotoneWithNoDeadTravel() {
        func topMid(_ r: Double, _ hw: Double, _ hh: Double) -> Double {
            let s = DetailEngine.vignetteShape(roundness: r, halfWidth: hw, halfHeight: hh)
            let e = edges(50, 50)
            return DetailEngine.vignetteProfile(
                radius: DetailEngine.vignetteRadius(u: 0, v: 1, exponent: s.exponent,
                                                    weight: s.weight),
                lower: e.lower, upper: e.upper)
        }
        var previous = Double.infinity
        for r in stride(from: -100.0, through: 100.0, by: 20.0) {
            let t = topMid(r, 384, 256)
            XCTAssertLessThanOrEqual(t, previous - 0.02, "roundness \(r)")
            previous = t
        }
        for r in stride(from: 0.0, through: 100.0, by: 20.0) {
            XCTAssertEqual(topMid(r, 256, 256), topMid(0, 256, 256), accuracy: 0.01)
        }
    }
}
