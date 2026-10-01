// AsShotNeutralSanitationTests.swift
// A file that records no camera neutral must not render black.
//
// The corpus lane's Leica M Monochrom DNG (corpus id 1087) is LinearRaw, one sample per
// pixel, with no ColorMatrix, AsShotNeutral or CalibrationIlluminant. Its decode is
// correct and finite; its delivered frame was 100% black. The mechanism: the as-shot
// temperature/tint the decoder reports for such a file are not numbers, `Num.clamp`
// passes NaN through (`Swift.max(NaN, lo)` is NaN), `WhiteBalanceEngine` then builds a
// NaN S6 matrix — its `aK == tK` identity test is false on NaN — and both renderers
// multiply every pixel by it. An 8-bit render of NaN is black.
//
// These run on Linux: the fix is in LumenCore, so both renderers inherit it.

import XCTest
@testable import LumenCore

final class AsShotNeutralSanitationTests: XCTestCase {

    private let undefined: [(kelvin: Double, tint: Double)] = [
        (.nan, .nan), (.nan, 0), (.nan, 12), (0, 0), (-1, 0), (-5500, 3),
        (.infinity, 0), (-.infinity, 0), (.signalingNaN, .nan),
    ]

    private func assertFinite(_ m: Mat3, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertTrue(m.m[i][j].isFinite, "\(message): m[\(i)][\(j)] = \(m.m[i][j])",
                              file: file, line: line)
            }
        }
    }

    // MARK: - The engine

    /// With the recipe at "as shot", a file with no neutral adapts from the reference
    /// to itself: the S6 matrix is the identity, so grey stays grey and nothing is NaN.
    func testAnUndefinedAsShotNeutralBuildsAFiniteNeutralPreservingMatrix() {
        for shot in undefined {
            let wb = WhiteBalanceEngine(asShotKelvin: shot.kelvin, asShotTint: shot.tint,
                                        targetKelvin: nil, targetTint: nil)
            let label = "as-shot \(shot.kelvin) K / \(shot.tint)"
            assertFinite(wb.matrix, label)
            XCTAssertLessThan(wb.matrix.maxAbsDifference(.identity), 1e-12, label)
            let grey = wb.apply(RGB(gray: 0.18))
            XCTAssertEqual(grey.r, 0.18, accuracy: 1e-12, label)
            XCTAssertEqual(grey.g, 0.18, accuracy: 1e-12, label)
            XCTAssertEqual(grey.b, 0.18, accuracy: 1e-12, label)
        }
    }

    /// Any explicit target on such a file adapts from the documented reference, the
    /// same matrix a rendered (non-raw) file gets — finite, and identical to it.
    func testAnUndefinedAsShotNeutralAdaptsFromTheRenderedFileReference() {
        let ref = WhiteBalanceEngine.Neutral.reference
        for shot in undefined where !(shot.kelvin.isFinite && shot.kelvin > 0) {
            for target in [(3200.0, 0.0), (7500.0, -20.0), (5500.0, 15.0)] {
                let wb = WhiteBalanceEngine(asShotKelvin: shot.kelvin, asShotTint: shot.tint,
                                            targetKelvin: target.0, targetTint: target.1)
                let expected = WhiteBalanceEngine(asShotKelvin: ref.kelvin,
                                                  asShotTint: ref.tint,
                                                  targetKelvin: target.0,
                                                  targetTint: target.1)
                assertFinite(wb.matrix, "as-shot \(shot) → \(target)")
                XCTAssertEqual(wb.matrix.flattened, expected.matrix.flattened,
                               "as-shot \(shot) → \(target)")
            }
        }
        // A real temperature with an undefined tint keeps the temperature.
        let half = WhiteBalanceEngine.Neutral.sanitizedAsShot(kelvin: 3200, tint: .nan)
        XCTAssertEqual(half, WhiteBalanceEngine.Neutral(kelvin: 3200, tint: 0))
    }

    /// A NaN target is "as shot", which is what nil already means.
    func testANaNTargetIsAsShot() {
        let wb = WhiteBalanceEngine(asShotKelvin: 4300, asShotTint: 6,
                                    targetKelvin: .nan, targetTint: .nan)
        assertFinite(wb.matrix, "NaN target")
        XCTAssertTrue(wb.isIdentity)
        XCTAssertEqual(wb.matrix.flattened, Mat3.identity.flattened)
    }

    /// The Temp/Tint rows and the eyedropper read the same neutral the render uses.
    func testTheRowAndThePickerNeverSeeNaN() {
        let shown = WhiteBalanceEngine.displayed(
            temp: nil, tint: nil, asShot: WhiteBalanceEngine.Neutral(kelvin: .nan, tint: .nan))
        XCTAssertEqual(shown.temperature, 5500)
        XCTAssertEqual(shown.tint, 0)

        let current = WhiteBalanceEngine(asShotKelvin: .nan, asShotTint: .nan,
                                         targetKelvin: nil, targetTint: nil)
        let picked = WhiteBalanceEngine.neutralizing(sample: RGB(0.3, 0.2, 0.1),
                                                     asShotKelvin: .nan, asShotTint: .nan,
                                                     current: current)
        XCTAssertTrue(picked.kelvin.isFinite && picked.tint.isFinite, "\(picked)")
        let fallback = WhiteBalanceEngine.neutralizing(sample: RGB(0, 0, 0),
                                                       asShotKelvin: .nan, asShotTint: .nan,
                                                       current: current)
        XCTAssertEqual(fallback.kelvin, 5500)
        XCTAssertEqual(fallback.tint, 0)
    }

    // MARK: - The whole reference render

    /// The defect as the corpus saw it, end to end on the reference renderer: a mid-grey
    /// frame with a NaN as-shot neutral and a default recipe. Before the fix every
    /// output sample was NaN (which an 8-bit encode turns into black).
    func testAGreyFrameWithNoCameraNeutralRendersGreyNotBlack() {
        let source = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.18) }
        let plan = RenderPlan(recipe: Recipe(), asShotKelvin: .nan, asShotTint: .nan)
        assertFinite(plan.linear.matrix, "S6 linear stage")
        XCTAssertEqual(plan.balancedNeutral, WhiteBalanceEngine.Neutral.reference)

        let out = ReferenceRenderer.render(source, plan: plan)
        let control = ReferenceRenderer.render(source, plan: RenderPlan(recipe: Recipe()))
        for value in out.pixels {
            XCTAssertTrue(value.isFinite, "a sample is \(value)")
        }
        let centre = out[4, 4]
        XCTAssertGreaterThan(centre.g, 0.05, "rendered black: \(centre)")
        XCTAssertEqual(centre.r, centre.g, accuracy: 1e-4, "grey lost neutrality")
        XCTAssertEqual(centre.b, centre.g, accuracy: 1e-4, "grey lost neutrality")
        XCTAssertEqual(out.pixels, control.pixels,
                       "a file with no neutral must render as the rendered-file reference")
    }

    // MARK: - No change for any defined input

    /// `clampFinite` is `clamp` bit for bit for every non-NaN input, bounds included.
    func testClampFiniteIsClampForEveryNonNaNInput() {
        let values: [Double] = [
            -.infinity, -1e300, -5500, -300, -1, -Double.leastNonzeroMagnitude, -0.0, 0.0,
            Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, 1e-9, 0.5, 1,
            299.999, 300, 300.0001, 1000, 2000, 5500, 50_000, 1e300, .infinity,
        ]
        let bounds: [(Double, Double)] = [
            (0, 1), (-300, 300), (ColorTemperature.minKelvin, ColorTemperature.maxKelvin),
            (-0.0, 0.0), (0.0, -0.0), (5, 5), (-.infinity, .infinity), (.nan, 1), (0, .nan),
        ]
        var checked = 0
        for (lo, hi) in bounds {
            for x in values {
                for fallback in [0.0, .nan, 5500] {
                    let a = Num.clampFinite(x, lo, hi, fallback: fallback)
                    let b = Num.clamp(x, lo, hi)
                    XCTAssertEqual(a.bitPattern, b.bitPattern,
                                   "clampFinite(\(x), \(lo), \(hi)) = \(a), clamp = \(b)")
                    checked += 1
                }
            }
            XCTAssertEqual(Num.clampFinite(.nan, lo, hi, fallback: 42), 42)
        }
        XCTAssertEqual(checked, values.count * bounds.count * 3)
    }

    /// The engine as it was before this fix: clamp, then adapt. Every positive finite
    /// as-shot temperature, every finite as-shot tint, and every non-NaN target —
    /// including out-of-range, zero, negative and infinite ones — must produce the
    /// same nine doubles, bit for bit. A full grid, not a diagonal.
    func testEveryDefinedInputBuildsTheSameMatrixItAlwaysDid() {
        func oldMatrix(_ asK: Double, _ asT: Double, _ tgK: Double?, _ tgT: Double?) -> Mat3 {
            let aK = Num.clamp(asK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
            let aT = Num.clamp(asT, -300, 300)
            let tK = Num.clamp(tgK ?? aK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
            let tT = Num.clamp(tgT ?? aT, -300, 300)
            return WhiteBalanceEngine.adaptation(asShot: (aK, aT), target: (tK, tT),
                                                 space: .rec2020)
        }
        let asKelvins: [Double] = [Double.leastNonzeroMagnitude, 1, 900, 1999, 2000, 2856,
                                   3200, 4300, 5500, 6504, 9000, 25_000, 50_000, 1e9]
        let asTints: [Double] = [-1000, -300, -42.5, -0.0, 0, 7, 150, 300, 1000]
        let targetKelvins: [Double?] = [nil, -.infinity, -5, 0, 1, 2500, 5500, 7777, 1e7,
                                        .infinity]
        let targetTints: [Double?] = [nil, -.infinity, -500, -60, 0, 33.3, 300, .infinity]
        var checked = 0
        for asK in asKelvins {
            for asT in asTints {
                for tgK in targetKelvins {
                    for tgT in targetTints {
                        let new = WhiteBalanceEngine(asShotKelvin: asK, asShotTint: asT,
                                                     targetKelvin: tgK, targetTint: tgT)
                        let old = oldMatrix(asK, asT, tgK, tgT)
                        XCTAssertEqual(new.matrix.flattened.map(\.bitPattern),
                                       old.flattened.map(\.bitPattern),
                                       "as-shot \(asK)/\(asT) → \(String(describing: tgK))"
                                           + "/\(String(describing: tgT))")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, asKelvins.count * asTints.count
                           * targetKelvins.count * targetTints.count)

        // And the row display, for every positive finite neutral.
        for asK in asKelvins {
            for asT in asTints {
                let shown = WhiteBalanceEngine.displayed(
                    temp: nil, tint: nil,
                    asShot: WhiteBalanceEngine.Neutral(kelvin: asK, tint: asT))
                XCTAssertEqual(shown.temperature.bitPattern,
                               Num.clamp(asK, ColorTemperature.minKelvin,
                                         ColorTemperature.maxKelvin).bitPattern)
                XCTAssertEqual(shown.tint.bitPattern, Num.clamp(asT, -300, 300).bitPattern)
            }
        }
    }
}
