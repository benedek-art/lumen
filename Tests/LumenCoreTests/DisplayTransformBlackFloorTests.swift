// DisplayTransformBlackFloorTests.swift
// A saturated colour sliding into black must not get lighter on the way down.

import XCTest
@testable import LumenCore

final class DisplayTransformBlackFloorTests: XCTestCase {

    static let chromaticities: [(String, RGB)] = [
        ("blue", RGB(0.3, 0.5, 1.8)), ("red", RGB(1.6, 0.4, 0.3)),
        ("green", RGB(0.4, 1.4, 0.5)), ("cyan", RGB(0.2, 1.0, 1.1)),
        ("skin", RGB(1.3, 0.9, 0.7)), ("grey", RGB(1, 1, 1)),
    ]

    /// Largest OKLab L reversal along an exposure ramp, and where it is.
    static func worstReversal(_ render: (RGB) -> RGB, base: RGB) -> (drop: Double, ev: Double) {
        let context = OKLabTransform.working
        var previous = -Double.infinity
        var worst = (drop: 0.0, ev: 0.0)
        for ev in stride(from: -14.0, through: -3, by: 0.02) {
            let L = context.toLab(render(base * (0.18 * pow(2, ev)))).L
            if previous - L > worst.drop { worst = (previous - L, ev) }
            previous = Swift.max(previous, L)
        }
        return worst
    }

    /// Below the black anchor the hue-stable branch fades into the per-channel one.
    /// The ratio branch put a saturated colour's minor channels BELOW `black` while
    /// per-channel put them AT it, so the fade lifted the darker pixel: at Black target
    /// 9 a blue ramp lost 0.115 OKLab L between −9.5 and −10 EV, and 0.014 at the
    /// default 0.0152.
    func testTheToeNeverRendersADarkerColourLighter() {
        for blackTarget in [0.0, 0.0152, 1, 3, 9] {
            for preset in DisplayTransformParams.presetNames where preset != "Linear" {
                var recipe = Recipe()
                recipe.look.render.preset = preset
                recipe.look.render.blackTarget = blackTarget
                let transform = DisplayTransform.forRecipe(recipe)
                for (name, base) in Self.chromaticities {
                    let worst = Self.worstReversal({
                        transform.apply($0, gamut: RenderPlan.sharedGamutBoundary)
                    }, base: base)
                    XCTAssertLessThan(worst.drop, 1e-4,
                                      "\(preset), Black target \(blackTarget): \(name) "
                                          + "rendered \(worst.drop) OKLab L lighter just "
                                          + "below \(worst.ev) EV than at it")
                }
            }
        }
    }

    /// The same property through what ships: the export-size finish table.
    func testTheShippedTableHoldsTheToeMonotone() {
        for blackTarget in [0.0152, 9] {
            var recipe = Recipe()
            recipe.look.render.blackTarget = blackTarget
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
            for (name, base) in Self.chromaticities {
                let worst = Self.worstReversal({ plan.referenceColor($0) }, base: base)
                XCTAssertLessThan(worst.drop, 2e-3,
                                  "Black target \(blackTarget): \(name) reversed by "
                                      + "\(worst.drop) OKLab L at \(worst.ev) EV through "
                                      + "the finish table")
            }
        }
    }

    /// A neutral at and below the floor is exactly `black`, as it always was.
    func testNeutralBlackStillLandsOnTheBlackTarget() {
        for blackTarget in [0.0152, 3, 9] {
            var params = DisplayTransformParams()
            params.blackTarget = blackTarget
            let transform = DisplayTransform(params)
            for v in [0.0, 1e-9, 1e-6, 1e-5] {
                let out = transform.apply(RGB(gray: v))
                for channel in 0..<3 {
                    XCTAssertEqual(out[channel], transform.black, accuracy: 1e-9,
                                   "scene \(v) at Black target \(blackTarget)")
                }
            }
        }
    }
}
