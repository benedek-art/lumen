// The tone curve as its own 1-D stage (`CurveStage`). Lane T2; numbers in
// docs/quality/lanes/WS-12b.

import XCTest
@testable import LumenCore

final class CurveStageTests: XCTestCase {

    /// The curves the audit measured through the finish cube, plus the steepest the
    /// editor can make and one of each kind of curve.
    static let curves: [(String, CurveSet)] = {
        func point(_ p: [[Double]], preserve: Bool = true) -> CurveSet {
            CurveSet(point: p, preserveLuminance: preserve)
        }
        var parametric = CurveSet()
        parametric.parametric = ParametricCurve(highlights: -100, shadows: 100)
        var everything = CurveSet(point: [[0, 0], [0.25, 0.15], [0.75, 0.85], [1, 1]],
                                  r: [[0, 0], [0.5, 0.6], [1, 1]],
                                  b: [[0, 0.05], [0.5, 0.45], [1, 1]],
                                  luma: [[0, 0], [0.4, 0.45], [1, 0.97]])
        everything.parametric = ParametricCurve(lights: 40, darks: -30)
        return [
            ("S", point([[0, 0], [0.25, 0.15], [0.75, 0.85], [1, 1]])),
            ("steep", point([[0, 0], [0.4, 0.1], [0.6, 0.9], [1, 1]])),
            ("dip", point([[0, 0], [0.3, 0.8], [0.35, 0.2], [1, 1]])),
            ("lift", point([[0, 0.1], [1, 1]])),
            ("cliff", point([[0, 0], [0.5, 0.05], [0.504, 0.95], [1, 1]])),
            ("steep, per channel", point([[0, 0], [0.4, 0.1], [0.6, 0.9], [1, 1]],
                                         preserve: false)),
            ("parametric", parametric),
            ("everything", everything),
        ]
    }()

    /// THE CURVE APPLIED IS THE CURVE DRAWN. Through the 33-point cube the steep curve
    /// was 33 codes off on a grey ramp; through the stage it must be under a quarter
    /// code everywhere (half a code for the cliff), on neutrals and on colours, in SDR
    /// and with HDR headroom.
    func testTheStageIsTheCurveToAQuarterCode() {
        var rng = SystemRandomNumberGenerator()
        for (name, set) in Self.curves {
            let stack = CurveStack(set)
            let stage = CurveStage(stack)
            var worst = 0.0
            for white in [1.0, 2.5] {
                // A dense neutral ramp, which is where the cube failed.
                for i in 0...4000 {
                    let v = TransferFunction.srgb.decode(Double(i) / 4000) * white
                    worst = max(worst, Self.codeError(stack, stage, RGB(v, v, v), white))
                }
                for _ in 0..<4000 {
                    let c = RGB(Double.random(in: 0...white, using: &rng),
                                Double.random(in: 0...white, using: &rng),
                                Double.random(in: 0...white, using: &rng))
                    worst = max(worst, Self.codeError(stack, stage, c, white))
                }
            }
            // The cliff is two points `minimumPointGap` apart — 7 codes per table cell
            // — and is the one case allowed half a code.
            let bound = name == "cliff" ? 0.5 : 0.25
            XCTAssertLessThan(worst, bound, "\(name): the stage is \(worst) codes off the curve")
        }
    }

    /// A NaN pixel trapped in the table read (`Int(_:)` on NaN). The exact curve returns
    /// a value; so must the stage, for every kind of curve.
    func testANaNPixelDoesNotTakeTheStageDown() {
        for (_, set) in Self.curves {
            let stage = CurveStage(CurveStack(set))
            _ = stage.apply(RGB(.nan, 0.5, 0.5))
            _ = stage.apply(RGB(0.2, .nan, .infinity))
        }
        XCTAssertEqual(CurveStage.lookup([0.1, 0.5, 0.9], .nan), 0.1, accuracy: 1e-6)
    }

    func testAnIdentityCurveIsAnIdentityStage() {
        let stage = CurveStage(CurveStack(CurveSet()))
        XCTAssertTrue(stage.isIdentity)
        XCTAssertNil(stage.master)
        XCTAssertNil(stage.luma)
        XCTAssertTrue(stage.channels.allSatisfy { $0 == nil })
        let c = RGB(0.3, 0.12, 0.7)
        XCTAssertEqual(stage.apply(c), c)
        // A red curve alone bakes one table.
        let red = CurveStage(CurveStack(CurveSet(r: [[0, 0], [0.5, 0.6], [1, 1]])))
        XCTAssertNil(red.master)
        XCTAssertNotNil(red.channels[0])
        XCTAssertNil(red.channels[1])
    }

    // MARK: - Parametric splits

    /// The engine clamped splits to 2–98 % with a 1 % gap and the editor to 10–90 % with
    /// 2 %, so a sidecar's splits could render one way and be drawn another. One rule now.
    func testTheEngineReadsSplitsThroughTheEditorsBounds() {
        for raw in [[0.01, 0.5, 0.99], [0.3, 0.3, 0.3], [0.95, 0.05, 0.5], [0.25, 0.5, 0.75]] {
            let s = CurveEditing.sanitizedSplits(raw)
            XCTAssertEqual(CurveStack.regionCentres(raw),
                           [s[0] / 2, (s[0] + s[1]) / 2, (s[1] + s[2]) / 2, (s[2] + 1) / 2],
                           "\(raw)")
        }
        var wild = ParametricCurve(darks: 60)
        wild.splits = [0.01, 0.5, 0.99]
        var drawn = wild
        drawn.splits = CurveEditing.sanitizedSplits(wild.splits)
        let a = CurveStack.bakeParametric(wild), b = CurveStack.bakeParametric(drawn)
        for i in 0...100 { XCTAssertEqual(a.evaluate(Double(i) / 100), b.evaluate(Double(i) / 100)) }
    }

    // MARK: - Helpers

    static func codeError(_ stack: CurveStack, _ stage: CurveStage, _ c: RGB,
                          _ white: Double) -> Double {
        let enc = TransferFunction.srgb
        let a = stack.apply(c, white: white), b = stage.apply(c, white: white)
        return 255 * max(abs(enc.encode(a.r) - enc.encode(b.r)),
                         abs(enc.encode(a.g) - enc.encode(b.g)),
                         abs(enc.encode(a.b) - enc.encode(b.b)))
    }

}
