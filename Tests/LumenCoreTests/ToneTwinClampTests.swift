// ToneTwinClampTests.swift
//
// `RenderPlan.referenceColor` and `exactColor` are the per-pixel twins the goldens
// measure the renderers' tables against. Both renderers apply S7 through
// `toneGainLUT`, which `bakeGainLUT` builds AFTER its forward clamp — the Zones
// panel's only limiter, which renders a band of input tones as one output tone. The
// twins applied `tone.gain(at:)`, the gain the panel REQUESTED, so wherever the clamp
// fires (`zoneFlattening` non-nil; Darks +4 EV moved the tone by up to 2.2 EV) the
// twins and the render disagreed by the clamp itself, and any golden on such a recipe
// would have charged that to "interpolation error". These tests pin the twins to the
// tone the renderers actually apply.
//
// The register now eases itself (WS-08, `ToneEngine.appliedZoneEV`) and Darks alone no
// longer reaches the clamp, so the recipe here is the one that still does: Contrast −100
// with Darks +3, which flattens −3.18 … +2.22 EV. The assertions are unchanged.

import XCTest
@testable import LumenCore

final class ToneTwinClampTests: XCTestCase {

    /// Darks at `ev` under Contrast −100, the Zones recipe that still reaches the clamp.
    private func darksPlan(_ ev: Double) -> RenderPlan {
        var recipe = Recipe()
        recipe.develop.tone.contrast = -100
        recipe.develop.zones.dark.ev = ev
        return RenderPlan(recipe: recipe)
    }

    /// A uniform grey inside the flattened band: the guided mask of a flat image is
    /// the grey's own encoded luminance, so the renderer's pixel is the table-for-
    /// table twin of `referenceColor` — the only difference left is the tone LUT's
    /// interpolation, which at 1024 samples is far below the tolerance here.
    func testReferenceColorAppliesTheClampedToneTheRendererApplies() throws {
        let plan = darksPlan(3)
        let f = try XCTUnwrap(plan.tone.zoneFlattening(),
                              "precondition: Contrast −100, Darks +3 EV must reach the bake's clamp")
        let ev = -2.5
        XCTAssertTrue(ev > f.lowEV && ev < f.highEV, "precondition: \(ev) EV in the band")
        let grey = RGB(gray: 0.18 * pow(2, ev))
        let image = ImageBuffer(width: 8, height: 8) { _, _ in grey }
        let rendered = ReferenceRenderer.render(image, plan: plan)[4, 4]
        let twin = plan.referenceColor(grey)
        for (r, t, ch) in [(rendered.r, twin.r, "r"), (rendered.g, twin.g, "g"),
                           (rendered.b, twin.b, "b")] {
            XCTAssertEqual(t, r, accuracy: 1e-3 * Swift.max(abs(r), 1e-3),
                           "referenceColor \(ch) \(t) against the rendered \(r) at \(ev) EV "
                               + "under Contrast −100, Darks +3 EV: the twin skipped the tone clamp")
        }
    }

    /// The f32 twin, table-free, must keep the bake's promise too: no brighter grey
    /// renders darker. Inside the band the requested response falls; the rendered one
    /// is flat, so `exactColor`'s output may not fall either.
    func testExactColorNeverRendersABrighterGreyDarkerInsideTheClampedBand() throws {
        let plan = darksPlan(3)
        let f = try XCTUnwrap(plan.tone.zoneFlattening())
        var previous = -Double.infinity
        var ev = f.lowEV - 0.25
        while ev <= f.highEV + 0.25 {
            let out = plan.exactColor(RGB(gray: 0.18 * pow(2, ev)))
            let y = RGBColorSpace.rec2020.luminance(out)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-9,
                                        "exactColor renders \(ev) EV darker than the grey "
                                            + "just below it under Contrast −100, Darks +3 EV")
            previous = y
            ev += 0.05
        }
    }

    /// And the two twins agree with each other about tone on the clamp, as they did
    /// everywhere else: both analytic, so the tone stage adds nothing to the
    /// table-against-exact error the goldens measure.
    func testTheTwinsShareOneToneStageGainOnTheClamp() throws {
        let plan = darksPlan(3)
        XCTAssertNotNil(plan.toneResponseFloor)
        let f = try XCTUnwrap(plan.tone.zoneFlattening())
        let lut = plan.toneGainLUT
        for ev in stride(from: f.lowEV + 0.1, to: f.highEV, by: 0.3) {
            let lum = 0.18 * pow(2, ev)
            let analytic = plan.toneStageGain(RGB(gray: lum), space: .rec2020)
            let baked = lut.evaluate(LumenLog.encode(lum))
            XCTAssertEqual(analytic, baked, accuracy: 1e-3 * baked,
                           "the twins' tone gain at \(ev) EV is not the baked gain")
        }
        // And where the clamp never fires, there is no floor and nothing changed.
        XCTAssertNil(RenderPlan(recipe: Recipe()).toneResponseFloor)
    }

    /// A tone coordinate so large that its encoded value is infinite must read the last
    /// floor sample, not trap converting infinity to an index.
    func testAnInfiniteToneCoordinateReadsTheTopOfTheFloor() throws {
        let plan = darksPlan(3)
        let floor = try XCTUnwrap(plan.tone.bakeGainLUTAndFloor().floor,
                                  "precondition: Contrast −100, Darks +3 EV must produce a floor")
        for t in [64.0, 1024.0, 1e6] {
            let stops = plan.tone.renderedStops(at: t, floor: floor)
            XCTAssertEqual(stops, Swift.max(t + plan.tone.stops(at: t), floor[floor.count - 1]) - t,
                           "t = \(t)")
        }
    }
}
