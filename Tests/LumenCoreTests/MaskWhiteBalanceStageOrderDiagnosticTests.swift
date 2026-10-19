import Foundation
import XCTest
@testable import LumenCore

/// Stage-order diagnostics, not a colour-accuracy or aesthetic acceptance gate.
/// CAT16 adaptations compose; an intervening luminance-dependent gain generally
/// does not commute with them. The production order is S6 -> S7 -> S11 here, with
/// neutral presence, colour and grading, exactly as in ReferenceRenderer.render.
final class MaskWhiteBalanceStageOrderDiagnosticTests: XCTestCase {
    func testInterveningToneLimitsTheScopeOfAbsoluteWhiteBalanceCancellation() throws {
        let space = RGBColorSpace.rec2020
        let pixel = RGB(0.4, 0.35, 0.3)
        let input = ImageBuffer(width: 4, height: 4) { _, _ in pixel }
        var mask = Mask(id: "m", name: "window"); mask.adjust.kelvin = 5600
        let alpha = Plane(width: 4, height: 4, fill: 1)
        // Independent composition oracle: the intermediate global target cancels,
        // leaving the adaptation directly from the fixed as-shot to mask target.
        let direct = WhiteBalanceEngine(asShotKelvin: 5200, asShotTint: 0,
            targetKelvin: 5600, targetTint: 0, space: space).matrix.apply(pixel)
        var outputs: [[RGB]] = []
        var analyticToneGains: [Double] = []
        for contrast in [0.0, 50.0] {
            var pair: [RGB] = []
            for global in [4000.0, 9000.0] {
                var recipe = Recipe()
                recipe.develop.raw.temp = global
                recipe.develop.tone.contrast = contrast
                let plan = RenderPlan(recipe: recipe, asShotKelvin: 5200, asShotTint: 0)
                XCTAssertEqual(plan.detail.texture, 0)
                XCTAssertEqual(plan.detail.clarity, 0)
                XCTAssertEqual(plan.detail.dehaze, 0)
                XCTAssertTrue(plan.colorStage.isIdentity)
                XCTAssertTrue(plan.gradeIsIdentity)
                let staged = input.map { plan.linear.matrix.apply($0) }
                if contrast != 0 {
                    // A constant field has no spatial edge. Its S7 gain is evaluated
                    // at the post-WB luminance, which differs between global targets.
                    let luminance = space.luminance(plan.linear.matrix.apply(pixel))
                    analyticToneGains.append(plan.tone.gain(at: log2(luminance / 0.18)))
                }
                let toned = ReferenceRenderer.applyTone(staged, plan: plan, longEdge: 4, space: space)
                let out = ReferenceRenderer.applyMasks(toned, plan: plan,
                    alphas: [(mask, alpha)], space: space)[0, 0]
                pair.append(out)
                if contrast == 0 {
                    // Same existing Float32 pixel tolerance as MaskWhiteBalanceTests;
                    // this certifies only the no-intervening-edit composition control.
                    XCTAssertEqual(out.r, direct.r, accuracy: 1e-6)
                    XCTAssertEqual(out.g, direct.g, accuracy: 1e-6)
                    XCTAssertEqual(out.b, direct.b, accuracy: 1e-6)
                }
                print("WB stage diagnostic contrast=\(contrast) global=\(global) result=\(out)")
            }
            outputs.append(pair)
        }
        XCTAssertNotEqual(analyticToneGains[0], analyticToneGains[1],
                          "the intervening tone gain depends on the changed S6 luminance")
        let distance: (RGB, RGB) -> Double = { a, b in
            max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
        }
        let controlDifference = distance(outputs[0][0], outputs[0][1])
        let tonedDifference = distance(outputs[1][0], outputs[1][1])
        print("WB stage diagnostic no-tone difference=\(controlDifference), ordered-tone difference=\(tonedDifference), analytic gains=\(analyticToneGains)")
        // Only witness noncommutation relative to its rounding control. No bound is
        // imposed on acceptable visible error, and no creative math is retuned.
        XCTAssertGreaterThan(tonedDifference, controlDifference)
    }
}
