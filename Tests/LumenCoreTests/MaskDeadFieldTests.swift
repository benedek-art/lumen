// MaskDeadFieldTests.swift
// The five local fields that are carried and not rendered, held to both halves of
// that promise.
//
// The owner's complaint was "I don't know how much of these is actually working", and
// the answer for `noise`, `noiseChroma`, `moire`, `defringe` and `grainAmount` is: none
// of them, on either renderer. `LocalAdjust`'s own header says so and says what each
// would take. This file is what stops that comment from going quietly out of date.
//
// TWO ASSERTIONS, and they pull in opposite directions on purpose:
//
//   The values SURVIVE. Deleting the fields would make Lumen silently drop data out of
//   a recipe written by hand or by a later version, which is worse than a field that
//   does nothing because it is invisible and permanent.
//
//   The values CHANGE NOTHING. The day one of them acquires a reader, the second half
//   of this file fails, and whoever wired it has to come here, delete the row, and move
//   the field out of the "carried, not rendered" block. That is the point: the comment
//   cannot rot, because a test fails when it becomes untrue.

import XCTest
@testable import LumenCore

final class MaskDeadFieldTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// Every field in the block, with a value well clear of its default.
    private static let carried: [(String, (inout LocalAdjust) -> Void, (LocalAdjust) -> Double)] = [
        ("noise", { $0.noise = 70 }, { $0.noise }),
        ("noiseChroma", { $0.noiseChroma = 65 }, { $0.noiseChroma }),
        ("moire", { $0.moire = 55 }, { $0.moire }),
        ("defringe", { $0.defringe = 80 }, { $0.defringe }),
        ("grainAmount", { $0.grainAmount = 45 }, { $0.grainAmount }),
    ]

    func testEveryCarriedFieldSurvivesASaveAndALoad() throws {
        var recipe = Recipe()
        var mask = Mask(id: "m", name: "carrier")
        for (_, set, _) in Self.carried { set(&mask.adjust) }
        recipe.masks = [mask]

        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(recipe).utf8))
        for (name, _, get) in Self.carried {
            XCTAssertEqual(get(back.masks[0].adjust), get(mask.adjust), accuracy: 0,
                           "\(name) was dropped on the way through the wire format")
        }
    }

    func testNoCarriedFieldChangesAPixelOnTheReferenceRenderer() {
        // A textured plate rather than a flat one: a denoise, a defringe and a grain
        // stage all need detail to have anything to do, and a constant image would let
        // a real reader pass this unnoticed.
        let image = ImageBuffer(width: 16, height: 16) { u, v in
            RGB(0.2 + u * 0.6, 0.5 + (v - 0.5) * 0.4,
                0.3 + ((Int(u * 16) + Int(v * 16)) % 2 == 0 ? 0.35 : 0))
        }
        let alpha = Plane(width: 16, height: 16, fill: 1)
        let plan = RenderPlan(recipe: Recipe())
        let untouched = ReferenceRenderer.applyMasks(
            image, plan: plan, alphas: [(Mask(id: "m", name: "none"), alpha)], space: space)

        for (name, set, _) in Self.carried {
            var mask = Mask(id: "m", name: name)
            set(&mask.adjust)
            let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                                   alphas: [(mask, alpha)], space: space)
            var worst = 0.0
            for i in 0..<out.pixels.count {
                worst = Swift.max(worst, abs(Double(out.pixels[i] - untouched.pixels[i])))
            }
            XCTAssertEqual(worst, 0, accuracy: 0,
                           "\(name) moved a pixel. If that is because it was WIRED, "
                               + "this test has done its job: delete its row here and "
                               + "move the field out of LocalAdjust's "
                               + "\"carried, not rendered\" block.")
        }
    }

    func testTheGlobalEnginesTheBlockedTwoWaitOnAreStillAbsent() {
        // `moire` and `defringe` are blocked on there being no global engine to be the
        // local half of, which is a claim about the tree rather than about effort. The
        // global defringe field exists and nothing reads it; if that changes, the local
        // half stops being blocked and this test says so.
        var recipe = Recipe()
        recipe.develop.geometry.lens.defringe = Defringe(purpleAmount: 20, greenAmount: 20)
        let plain = Recipe()

        let image = ImageBuffer(width: 12, height: 12) { u, _ in
            RGB(u < 0.5 ? 1.4 : 0.05, 0.2, u < 0.5 ? 0.05 : 1.4)
        }
        let withIt = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))
        let without = ReferenceRenderer.render(image, plan: RenderPlan(recipe: plain))
        var worst = 0.0
        for i in 0..<withIt.pixels.count {
            worst = Swift.max(worst, abs(Double(withIt.pixels[i] - without.pixels[i])))
        }
        XCTAssertEqual(worst, 0, accuracy: 0,
                       "a global defringe now renders — the local half is no longer "
                           + "blocked, and LocalAdjust's header needs updating")
    }
}
