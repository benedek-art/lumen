// FilmLabHDRMidGreyTests.swift
// docs/05-spec-color.md §Film Lab — the film chain uses the "same HDR parameterization
// (docs/04-spec-tone.md, D8)" as the display transform it replaces, and D8 pins
// mid-grey to 0.18 display-linear in ABSOLUTE terms at every display peak: HDR
// headroom goes to speculars, never to the midtones.
//
// The chain did not honour that. It solved its calibration gains for grey at
// `0.18 × displayWhite` and scaled its normalised print transmittance by
// `displayWhite`, so film(c, w) was exactly w × film(c, 1): on a 400-nit EDR preview
// or an HDR export the film picture sat log₂(w) EV brighter than the base rendering it
// blends with, and Strength became an exposure ramp (+1.32 EV at Strength 50, w = 4).
// The chain now forms its picture against print paper white = SDR white at every
// peak, which is bit-identical at w = 1.
//
// Each test here was run against the pre-fix engine and watched fail.

import XCTest
@testable import LumenCore

final class FilmLabHDRMidGreyTests: XCTestCase {

    private let grey = RGB(gray: DisplayTransform.sceneMidGrey)

    /// Strength 100, so `apply` is the film picture alone with no base mixed in.
    func testTheFilmChainLandsMidGreyOnAbsolutePointOneEightAtEveryDisplayPeak() {
        for stock in FilmStock.all {
            for white in [1.0, 2.0, 4.0, 8.0] {
                let chain = FilmChain(FilmChain.defaultRecipe(for: stock),
                                      filmExposure: 0, displayWhite: white)
                let out = chain.apply(grey)
                for channel in 0..<3 {
                    // WS-13: the display target is `displayMidGrey` (0.25), the level the
                    // display transform the chain blends with puts scene mid-grey on.
                    XCTAssertEqual(out[channel], DisplayTransform.displayMidGrey, accuracy: 1e-4,
                                   "\(stock.id) at display white \(white): film mid-grey "
                                       + "must be display mid-grey absolute (D8), got \(out[channel]) "
                                       + "— \(log2(out[channel] / DisplayTransform.displayMidGrey)) EV off")
                }
            }
        }
    }

    /// The peak must not move the film picture at all below SDR white: raising the
    /// display's headroom is not a film exposure change.
    func testRaisingTheDisplayPeakDoesNotBrightenTheFilmPicture() {
        let recipe = FilmChain.defaultRecipe(for: .portra400)
        let sdr = FilmChain(recipe, filmExposure: 0, displayWhite: 1)
        let hdr = FilmChain(recipe, filmExposure: 0, displayWhite: 4)
        for ev in stride(from: -6.0, through: 2.0, by: 0.5) {
            let scene = RGB(0.18, 0.15, 0.11) * pow(2.0, ev)
            let a = sdr.apply(scene)
            let b = hdr.apply(scene)
            for channel in 0..<3 {
                XCTAssertEqual(a[channel], b[channel], accuracy: 1e-9,
                               "scene \(ev) EV, channel \(channel): the film picture at "
                                   + "display white 4 must match display white 1")
            }
        }
    }

    /// Through the whole plan on an HDR render: Strength must blend two pictures that
    /// agree on mid-grey, so grey stays put from Strength 0 through 100.
    func testFilmStrengthDoesNotRampExposureOnAnHDRRender() {
        for whiteTarget in [200.0, 400.0] {
            var values: [Double] = []
            for amount in [0.0, 50.0, 100.0] {
                var recipe = Recipe()
                recipe.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: amount)
                let plan = RenderPlan(recipe: recipe, displayWhiteTarget: whiteTarget)
                values.append(plan.exactColor(grey).g)
            }
            for (i, v) in values.enumerated() {
                XCTAssertEqual(v, values[0], accuracy: 2e-3,
                               "white target \(whiteTarget): Strength \([0, 50, 100][i]) "
                                   + "renders grey at \(v), Strength 0 at \(values[0]) — "
                                   + "\(log2(v / values[0])) EV of exposure ramp")
            }
        }
    }
}
