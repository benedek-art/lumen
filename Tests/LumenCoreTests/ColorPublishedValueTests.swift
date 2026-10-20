// ColorPublishedValueTests.swift
// Constants checked against numbers published OUTSIDE this repository.
//
// ColorScienceTests pins the sRGB matrix and nothing else to a published value. Its
// adaptation tests (same white → identity, white → white) hold for ANY invertible cone
// matrix: a von Kries scale sends the source white to the destination white by
// construction, so a typo in a Bradford coefficient passed them. Its transfer-function
// round trip samples multiples of 0.05, which never reaches the sRGB linear toe below
// 0.0031308, so a wrong breakpoint or slope there passed too. Each assertion here was
// proven able to fail by perturbing the constant it checks (one coefficient of
// `ChromaticAdaptation.bradford` by 0.001, the smallest-effect one included; the sRGB toe slope 12.92 → 12.0; the P3
// green primary's x by 0.005) and watching it go red.

import XCTest
@testable import LumenCore

final class ColorPublishedValueTests: XCTestCase {

    private func assertMatrix(_ m: Mat3, _ expected: [[Double]], within tol: Double,
                              _ what: String, line: UInt = #line) {
        for r in 0..<3 { for c in 0..<3 {
            XCTAssertEqual(m.m[r][c], expected[r][c], accuracy: tol,
                           "\(what) [\(r)][\(c)]", line: line)
        } }
    }

    // MARK: - Adaptation

    func testBradfordD65ToD50MatchesLindbloom() {
        // Lindbloom's published Bradford D65→D50, derived from whites tabulated as XYZ
        // (0.95047, 1, 1.08883) → (0.96422, 1, 0.82521). Fed those same whites the
        // derivation reproduces it to 4e-8, so 1e-6 here. (From our xy chromaticities
        // the gap is 1.8e-4, which is why the whites are given explicitly: at that
        // tolerance a 0.001 error in a cone coefficient was invisible.)
        let m = ChromaticAdaptation.adapt(from: RGB(0.95047, 1, 1.08883),
                                          to: RGB(0.96422, 1, 0.82521),
                                          cone: ChromaticAdaptation.bradford)
        assertMatrix(m, [[1.0478112, 0.0228866, -0.0501270],
                         [0.0295424, 0.9904844, -0.0170491],
                         [-0.0092345, 0.0150436, 0.7521316]], within: 1e-6, "Bradford")
        // And the chromaticity-derived whites the app actually uses stay within the
        // fourth-decimal disagreement between the two tabulations.
        let app = ChromaticAdaptation.bradford(from: WhitePoint.d65, to: WhitePoint.d50)
        XCTAssertLessThan(app.maxAbsDifference(m), 2.5e-4)
    }

    func testCAT16ConeMatrixIsLiEtAl2017() {
        assertMatrix(ChromaticAdaptation.cat16, [[0.401288, 0.650173, -0.051461],
                                                 [-0.250268, 1.204414, 0.045854],
                                                 [-0.002079, 0.048952, 0.953127]],
                     within: 1e-9, "CAT16")
    }

    func testWhitePointsAreTheCIEValues() {
        let d65 = WhitePoint.d65.xyz()
        XCTAssertEqual(d65.r, 0.95046, accuracy: 1e-4)
        XCTAssertEqual(d65.g, 1, accuracy: 1e-12)
        XCTAssertEqual(d65.b, 1.08906, accuracy: 1e-4)
        let d50 = WhitePoint.d50.xyz()
        XCTAssertEqual(d50.r, 0.96422, accuracy: 1e-4)
        XCTAssertEqual(d50.b, 0.82521, accuracy: 1e-4)
    }

    // MARK: - Working and output spaces

    func testDisplayP3MatrixMatchesPublishedValues() {
        // Apple / SMPTE EG 432-1 with a D65 white, quoted to four decimals.
        assertMatrix(RGBColorSpace.displayP3.toXYZ, [[0.4866, 0.2657, 0.1982],
                                                     [0.2290, 0.6917, 0.0793],
                                                     [0.0000, 0.0451, 1.0439]],
                     within: 1e-4, "Display P3")
    }

    func testAdobeRGBMatrixMatchesPublishedValues() {
        // Lindbloom's Adobe RGB (1998) D65 matrix; same tabulated-white gap as
        // Bradford above, measured at 2.4e-4.
        assertMatrix(RGBColorSpace.adobeRGB.toXYZ, [[0.5767, 0.1856, 0.1882],
                                                    [0.2973, 0.6274, 0.0753],
                                                    [0.0270, 0.0707, 0.9911]],
                     within: 3e-4, "Adobe RGB")
    }

    // MARK: - Transfer functions, the linear toes

    func testSRGBLinearToeAndBreakpoint() {
        let tf = TransferFunction.srgb
        XCTAssertEqual(tf.encode(0.002), 0.02584, accuracy: 1e-9, "toe slope is 12.92")
        XCTAssertEqual(tf.decode(0.02), 0.02 / 12.92, accuracy: 1e-12)
        // IEC 61966-2-1: the two branches meet at 0.0031308 ↔ 0.04045 to within 3e-8.
        XCTAssertEqual(tf.encode(0.0031308), 0.04045, accuracy: 1e-6)
        XCTAssertEqual(tf.encode(0.0031308 + 1e-9), tf.encode(0.0031308), accuracy: 1e-7,
                       "the curve must be continuous across its breakpoint")
        XCTAssertEqual(tf.decode(0.04045), 0.0031308, accuracy: 1e-7)
        XCTAssertEqual(tf.decode(0.04045 + 1e-9), tf.decode(0.04045), accuracy: 1e-8)
        for i in 0...40 {
            let x = 0.004 * Double(i) / 40
            XCTAssertEqual(tf.decode(tf.encode(x)), x, accuracy: 1e-12, "toe round trip at \(x)")
        }
    }

    func testRec709LinearToe() {
        let tf = TransferFunction.rec709
        XCTAssertEqual(tf.encode(0.01), 0.045, accuracy: 1e-12, "toe slope is 4.5")
        XCTAssertEqual(tf.decode(0.045), 0.01, accuracy: 1e-12)
        XCTAssertEqual(tf.encode(0.5), 1.099 * pow(0.5, 0.45) - 0.099, accuracy: 1e-12)
    }

    // MARK: - OKLab

    func testOKLabOfTheSRGBPrimariesMatchesOttosson() {
        // Ottosson's published OKLab coordinates of the sRGB primaries, to six
        // decimals. EngineMathFixtureTests replays a Python mirror that copies the SAME
        // matrices, so it proves the two copies agree, never that they are right.
        let ctx = OKLabTransform.Context(space: .srgb)
        let expected: [(RGB, Double, Double, Double)] = [
            (RGB(1, 0, 0), 0.627955, 0.224863, 0.125846),
            (RGB(0, 1, 0), 0.866440, -0.233888, 0.179498),
            (RGB(0, 0, 1), 0.452014, -0.032457, -0.311528),
        ]
        for (rgb, L, a, b) in expected {
            let lab = ctx.toLab(rgb)
            XCTAssertEqual(lab.L, L, accuracy: 2e-6, "L of \(rgb)")
            XCTAssertEqual(lab.a, a, accuracy: 2e-6, "a of \(rgb)")
            XCTAssertEqual(lab.b, b, accuracy: 2e-6, "b of \(rgb)")
        }
    }
}
