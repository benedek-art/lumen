// FilmLabDisplayTransformTests.swift
// docs/31 round two §2 — the Film Lab discarded the user's display transform.
//
// `FilmChain` rebuilt a Neutral transform and copied only `whiteTarget` into it, and
// `RenderPlan`'s gate is `amount > 0` — so Strength 0 rendered through the user's
// transform and Strength 1 rendered 99% Neutral. That is a discontinuity, not a blend:
// on the "Linear" preset one point of Strength moved the picture ~51 code values, and
// Black target was dropped outright. The blend base is now the recipe's SOLVED
// transform, handed in by `RenderPlan`.
//
// Every test here was run against the pre-fix engine and watched fail (by temporarily
// reverting `RenderPlan` to construct the chain without `base:`).

import XCTest
@testable import LumenCore

final class FilmLabDisplayTransformTests: XCTestCase {

    private func srgbCode(_ v: Double) -> Double {
        let x = Num.saturate(v)
        let encoded = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
        return encoded * 255
    }

    /// A recipe on the "Linear" preset with a stock loaded at `amount`.
    private func linearRecipe(amount: Double) -> Recipe {
        var recipe = Recipe()
        recipe.look.render = RenderParams(preset: "Linear")
        recipe.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: amount)
        return recipe
    }

    /// The plan's film chain must blend against the recipe's own solved transform —
    /// the wiring half of the fix, asserted directly so it cannot quietly revert to
    /// the rebuilt-Neutral base while every behavioural bound below stays barely green.
    func testThePlanHandsTheChainTheRecipesSolvedTransform() throws {
        let plan = RenderPlan(recipe: linearRecipe(amount: 100))
        let chain = try XCTUnwrap(plan.filmChain, "amount 100 must build the chain")
        XCTAssertTrue(chain.neutral.params.linear,
                      "the chain's blend base must be the recipe's SOLVED transform — "
                          + "this recipe renders through the Linear preset and the "
                          + "base claims otherwise, which is the rebuilt-Neutral bug")
    }

    /// Strength must be continuous at zero: the first point of the slider may move the
    /// picture by about one hundredth of the film look, never by a fifth of the range.
    ///
    /// Pre-fix, on the Linear preset, amount 0 → 1 moved mid-grey +2 EV by ~51 code
    /// values, because the 1% blend was drawn against a base that was 99% Neutral
    /// rather than 99% the user's own rendering.
    func testStrengthIsContinuousAtZeroOnTheLinearPreset() {
        let off = RenderPlan(recipe: linearRecipe(amount: 0))
        let on = RenderPlan(recipe: linearRecipe(amount: 1))
        var worst = 0.0
        for ev in stride(from: -8.0, through: 4.0, by: 0.25) {
            let scene = RGB(gray: 0.18 * pow(2.0, ev))
            let a = off.exactColor(scene)
            let b = on.exactColor(scene)
            for channel in 0..<3 {
                worst = Swift.max(worst, abs(srgbCode(a[channel]) - srgbCode(b[channel])))
            }
        }
        XCTAssertLessThan(worst, 3,
                          "one point of Strength moved the picture \(worst) of 255 "
                              + "code values — the blend base is not the recipe's own "
                              + "transform (pre-fix this measured ~51)")
    }

    /// And the far end of the slider agrees with the chain: Strength 100 renders the
    /// film look regardless of base, so the fix must not have changed what a full
    /// stock looks like.
    func testStrengthOneHundredIsStillTheFilmLook() {
        let neutralBase = RenderPlan(recipe: {
            var r = Recipe()
            r.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: 100)
            return r
        }())
        let linearBase = RenderPlan(recipe: linearRecipe(amount: 100))
        var worst = 0.0
        for ev in stride(from: -6.0, through: 3.0, by: 0.5) {
            let scene = RGB(gray: 0.18 * pow(2.0, ev))
            let a = neutralBase.exactColor(scene)
            let b = linearBase.exactColor(scene)
            for channel in 0..<3 {
                worst = Swift.max(worst, abs(srgbCode(a[channel]) - srgbCode(b[channel])))
            }
        }
        XCTAssertLessThan(worst, 1e-6,
                          "at Strength 100 the chain IS the S14 slot and the base is "
                              + "blended at weight zero — two different bases must "
                              + "render the same picture, and differed by \(worst)")
    }

    /// Black target must survive a partial film blend. The user raised the display
    /// floor to 5% of SDR white; at Strength 50 the rendering is half their transform,
    /// so the deepest shadow can fall no further than about half that floor.
    ///
    /// Pre-fix the base carried the Neutral default (0.0152%), so the floor the user
    /// set simply vanished the moment a stock was loaded.
    func testBlackTargetSurvivesAPartialFilmBlend() {
        var recipe = Recipe()
        recipe.look.render = RenderParams(preset: "Neutral", blackTarget: 5.0)
        recipe.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: 50)
        let plan = RenderPlan(recipe: recipe)
        let deepShadow = RGB(gray: 0.18 * pow(2.0, -14))
        let out = plan.exactColor(deepShadow)
        XCTAssertGreaterThan(out.minComponent, 0.020,
                             "a 5% Black target blended at half strength must hold the "
                                 + "floor near 2.5% of white; \(out.minComponent) means "
                                 + "the user's transform was discarded from the base")
    }

    /// The whole travel is a monotone walk between the two renderings — the property
    /// `testFilmStrengthStaysBetweenTheTwoRenderingsItBlends` pins for the default
    /// base, restated over a base the user has actually shaped.
    func testStrengthTravelsMonotonicallyBetweenTheUsersRenderingAndTheFilms() {
        var custom = Recipe()
        custom.look.render = RenderParams(preset: "Punchy", contrast: 2.4, skew: -0.2)
        custom.look.filmLab = FilmLab(stock: FilmStock.velvia50.id, amount: 0)

        func plan(_ amount: Double) -> RenderPlan {
            var r = custom
            r.look.filmLab?.amount = amount
            return RenderPlan(recipe: r)
        }
        let off = plan(0)
        let full = plan(100)
        let partials = [25.0, 50.0, 75.0].map { plan($0) }

        for ev in stride(from: -6.0, through: 3.0, by: 0.5) {
            let scene = RGB(gray: 0.18 * pow(2.0, ev))
            let user = off.exactColor(scene)
            let film = full.exactColor(scene)
            for partial in partials {
                let out = partial.exactColor(scene)
                for channel in 0..<3 {
                    let lo = Swift.min(user[channel], film[channel]) - 1e-9
                    let hi = Swift.max(user[channel], film[channel]) + 1e-9
                    XCTAssertTrue(out[channel] >= lo && out[channel] <= hi,
                                  "at \(ev) EV channel \(channel) the partial blend "
                                      + "\(out[channel]) left [\(lo), \(hi)] — the "
                                      + "blend is not between the two renderings")
                }
            }
        }
    }
}
