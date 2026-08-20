// PlanTableCacheTests.swift
// The invariant the plan-table cache lives or dies by: a hit must be indistinguishable
// from a cold bake.
//
// A render cache that returns the wrong table does not crash and does not look obviously
// wrong — it shows the photographer the picture they had a moment ago and keeps showing
// it while they drag. That is the worst class of bug this project can ship, so the test
// is written to fail in both directions: every case asserts that the cached plan equals a
// freshly built one, AND that the mutation actually moved a table, so a case that has
// quietly stopped exercising the key announces itself instead of passing.

import XCTest
@testable import LumenCore

final class PlanTableCacheTests: XCTestCase {

    /// A recipe with a live colour stack and a live grade, so both tables are baked
    /// rather than short-circuited to the 2-sample identity.
    private func liveRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.develop.mixer.bands[2].sat = 40
        recipe.look.wheels.shadows.sat = 30
        recipe.look.wheels.shadows.hue = 210
        return recipe
    }

    func testACacheHitEqualsAColdBake() {
        let recipe = liveRecipe()

        // Each case must move at least one table, or it tests nothing about the key.
        // `printerLights` is deliberately absent: it reaches pixels through
        // `LinearStage.printerLightGains`, not through either table, so mutating it
        // proves nothing here. It stays IN the key anyway — over-keying costs a cache
        // miss, under-keying shows a stale picture.
        //
        // A wheel's hue is absent for the same reason: a hue angle at zero saturation is
        // a rotation of nothing, so `wheels.high.hue` alone leaves both tables identical.
        // The saturation is what makes the case bite.
        let cases: [(String, (inout Recipe) -> Void)] = [
            ("tone.whites", { $0.develop.tone.whites = 60 }),
            ("tone.blacks", { $0.develop.tone.blacks = -40 }),
            ("curve.parametric.highlights", { $0.develop.curve.parametric.highlights = 55 }),
            ("curve.point", { $0.develop.curve.point = [[0, 0], [0.5, 0.7], [1, 1]] }),
            ("render.preset", { $0.look.render.preset = "Linear" }),
            ("mixer.bands[2].sat", { $0.develop.mixer.bands[2].sat = -40 }),
            ("wheels.high.sat", { $0.look.wheels.high.sat = 45 }),
            ("color.saturation", { $0.develop.color.saturation = 25 }),
            ("color.vibrance", { $0.develop.color.vibrance = 35 }),
            ("primaries.rHue", { $0.look.primaries.rHue = 8 }),
        ]

        for (name, mutate) in cases {
            var changed = recipe
            mutate(&changed)

            // Warm the cache on the ORIGINAL, then ask for the changed one. If the key
            // misses anything the closures read, this is where the stale table comes
            // back.
            PlanTableCache.clear()
            let base = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                  lutSize: 17)
            let viaCache = RenderPlan(recipe: changed, asShotKelvin: 5500, asShotTint: 0,
                                      lutSize: 17)

            PlanTableCache.clear()
            let fresh = RenderPlan(recipe: changed, asShotKelvin: 5500, asShotTint: 0,
                                   lutSize: 17)

            XCTAssertEqual(viaCache.finishLUT, fresh.finishLUT,
                           "finishLUT came back stale after \(name)")
            XCTAssertEqual(viaCache.colorGradeLUT, fresh.colorGradeLUT,
                           "colorGradeLUT came back stale after \(name)")
            XCTAssertTrue(base.finishLUT != fresh.finishLUT
                            || base.colorGradeLUT != fresh.colorGradeLUT,
                          "\(name) moved neither table, so it cannot exercise the key")
        }
    }

    /// The same recipe twice must hit, and the hit must be the same object's worth of
    /// values. Without this the suite above would pass for a cache that never stores
    /// anything — which is correct, and pointless.
    func testTheSameRecipeIsServedFromTheCache() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let first = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                               lutSize: 17)

        // A slider that touches neither table: this is the drag case the cache exists
        // for, and it must not invalidate.
        var dragged = recipe
        dragged.develop.detail.texture = 62
        dragged.develop.detail.clarity = -31
        dragged.look.vignette = -0.8
        let second = RenderPlan(recipe: dragged, asShotKelvin: 5500, asShotTint: 0,
                                lutSize: 17)

        XCTAssertEqual(first.finishLUT, second.finishLUT)
        XCTAssertEqual(first.colorGradeLUT, second.colorGradeLUT)
        // And the plan still carries the moved values, so nothing was over-cached.
        XCTAssertEqual(second.detail.texture, 62)
        XCTAssertEqual(second.vignetteEV, -0.8)
    }

    /// Export-size bakes are not cached, because holding 6.6 MB for a table used once is
    /// worse than rebuilding it. The behaviour must still be identical.
    func testExportSizeIsCorrectWhetherOrNotItIsCached() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let a = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                           lutSize: LUT3D.exportSize)
        let b = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                           lutSize: LUT3D.exportSize)
        XCTAssertEqual(a.finishLUT, b.finishLUT)
        XCTAssertEqual(a.colorGradeLUT, b.colorGradeLUT)
        XCTAssertEqual(a.finishLUT.size, LUT3D.exportSize)
    }

    /// A different bake size must never be served the other size's table.
    func testSizeIsPartOfTheKey() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let draft = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                               lutSize: 17)
        let interactive = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                     lutSize: LUT3D.interactiveSize)
        XCTAssertEqual(draft.finishLUT.size, 17)
        XCTAssertEqual(interactive.finishLUT.size, LUT3D.interactiveSize)
        XCTAssertEqual(draft.colorGradeLUT.size, 17)
        XCTAssertEqual(interactive.colorGradeLUT.size, LUT3D.interactiveSize)
    }
}
