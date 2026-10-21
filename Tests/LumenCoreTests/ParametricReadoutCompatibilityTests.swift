import XCTest
@testable import LumenCore

final class ParametricReadoutCompatibilityTests: XCTestCase {
    static let cases: [ParametricCurve] = [
        ParametricCurve(),
        ParametricCurve(highlights: 25, lights: 10, darks: -15, shadows: -20),
        ParametricCurve(darks: -100, shadows: 100),
        ParametricCurve(highlights: -100, lights: 100),
        ParametricCurve(highlights: 100, lights: -100, darks: 100, shadows: -100),
        ParametricCurve(highlights: -100, lights: 100, darks: -100, shadows: 100),
        ParametricCurve(highlights: 85, lights: -65, darks: -90, shadows: 100, splits: [0.02, 0.03, 0.04]),
        ParametricCurve(highlights: -100, lights: 80, darks: 50, shadows: -60, splits: [0.96, 0.97, 0.98]),
        ParametricCurve(highlights: 30, lights: -100, darks: 100, shadows: -50, splits: [0.8, 0.2, 0.6]),
        ParametricCurve(highlights: 200, lights: -200, darks: 45, shadows: -80, splits: [])
    ]

    // Recorded before refactoring the shared bake on the native Darwin release
    // build at f64456b. Darwin cos() bytes are not claimed to be Linux libm bytes.
    //
    // Cases 6 and 7 re-recorded on the Darwin CI runner for lane T2 (quality/t2-curves):
    // their splits ([.02, .03, .04] and [.96, .97, .98]) lie outside the editor's
    // 10–90 % bounds, and `regionCentres` now reads splits through
    // `CurveEditing.sanitizedSplits`, so they render the curve the editor draws for
    // them instead of one the editor could not show. Every in-bounds case is unchanged.
    #if os(macOS)
    func testRecordedDarwinPreReadoutCurveLUTBytes() {
        let expected = ["b08b6d2e7ae1088a", "31058daf12c29c18", "5aca7b43497da42a",
                        "48eea1d39fd5fcb2", "63b01fd0fe042002", "6d5484e57be381c0",
                        "3b631b452324859c", "140964803e5523f4", "e352ab703238ab5e",
                        "61a49a0dae3b3c85"]
        for (index, curve) in Self.cases.enumerated() {
            let lut = CurveStack.bakeParametric(curve)
            var digest = XXH64Stream()
            for position in 0..<1024 {
                var bits = lut.evaluate(Double(position) / 1023).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { digest.update(Data($0)) }
            }
            XCTAssertEqual(digest.hexDigest(), expected[index], "curve case \(index) changed its actual LUT bytes")
        }
    }
    #endif

    func testReadoutSharesActualBakeScaleAndNeverChangesRecipe() {
        for curve in Self.cases {
            var set = CurveSet(); set.parametric = curve
            let saved = set
            let stack = CurveStack(set)
            XCTAssertTrue(stack.parametricAppliedScale.isFinite)
            XCTAssertGreaterThanOrEqual(stack.parametricAppliedScale, 0)
            XCTAssertLessThanOrEqual(stack.parametricAppliedScale, 1)
            let caption = AppliedReadout.parametricEasingCaption(appliedScale: stack.parametricAppliedScale)
            XCTAssertEqual(caption != nil, stack.parametricAppliedScale < 0.995)
            XCTAssertEqual(set, saved)
        }
        XCTAssertNil(AppliedReadout.parametricEasingCaption(appliedScale: CurveStack(CurveSet()).parametricAppliedScale))
        var conflict = CurveSet(); conflict.parametric = ParametricCurve(darks: -100, shadows: 100)
        XCTAssertNotNil(AppliedReadout.parametricEasingCaption(appliedScale: CurveStack(conflict).parametricAppliedScale))
    }

    func testReadoutRefusesInvalidValuesAndDoesNotDisplayRoundedHundredPercent() {
        for value in [Double.nan, .infinity, -.infinity, -1, 1, 0.995, 2] {
            XCTAssertNil(AppliedReadout.parametricEasingCaption(appliedScale: value))
        }
        XCTAssertEqual(AppliedReadout.parametricEasingCaption(appliedScale: 0.624),
                       "Combined curve strength: 62% — reduced to keep tones in order.")
    }
}
