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
//
// Covered: the reference renderer, both at S11 (`applyMasks`) and end to end with grain
// on, each with a local-exposure positive control. NOT covered: the Metal path in
// LumenPipeline, which has no test target on this lane.

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

        // Positive control: a field that IS wired moves pixels through the same call and
        // alpha, so the zeros above are not a dead harness.
        var live = Mask(id: "m", name: "exposure")
        live.adjust.exposure = 1
        let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                               alphas: [(live, alpha)], space: space)
        var worst = 0.0
        for i in 0..<out.pixels.count {
            worst = Swift.max(worst, abs(Double(out.pixels[i] - untouched.pixels[i])))
        }
        XCTAssertGreaterThan(worst, 1e-3, "local exposure +1 moved nothing: the harness is dead")
    }

    /// The same promise through the whole reference renderer, with a full-frame mask and
    /// creative grain switched on. `applyMasks` alone cannot see a field wired where
    /// LocalAdjust's header says it would be: `grainAmount` into the grain stage, which
    /// runs after S11. The GPU path (LumenPipeline) is not covered on this lane.
    func testNoCarriedFieldChangesAPixelThroughTheWholeReferenceRender() {
        let image = ImageBuffer(width: 16, height: 16) { u, v in
            RGB(0.2 + u * 0.6, 0.5 + (v - 0.5) * 0.4,
                0.3 + ((Int(u * 16) + Int(v * 16)) % 2 == 0 ? 0.35 : 0))
        }
        var whole = MaskComponent(op: .add, kind: .radial)
        whole.center = [0.5, 0.5]
        whole.radii = [2, 2]
        whole.feather = 0

        func render(_ set: (inout LocalAdjust) -> Void) -> ImageBuffer {
            var recipe = Recipe()
            recipe.look.grain = CreativeGrain(amount: 40)
            var mask = Mask(id: "m", name: "whole", components: [whole])
            set(&mask.adjust)
            recipe.masks = [mask]
            return ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))
        }
        func worst(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
            var worst = 0.0
            for i in 0..<a.pixels.count {
                worst = Swift.max(worst, abs(Double(a.pixels[i] - b.pixels[i])))
            }
            return worst
        }
        let untouched = render { _ in }

        for (name, set, _) in Self.carried {
            XCTAssertEqual(worst(render(set), untouched), 0, accuracy: 0,
                           "\(name) moved a pixel in the full render. If it was WIRED, "
                               + "delete its row here and move the field out of "
                               + "LocalAdjust's \"carried, not rendered\" block.")
        }
        // Positive control: the mask covers the frame and a wired field reaches the output.
        XCTAssertGreaterThan(worst(render { $0.exposure = 1 }, untouched), 1e-3,
                             "local exposure +1 moved nothing: the mask or stage is dead")
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
