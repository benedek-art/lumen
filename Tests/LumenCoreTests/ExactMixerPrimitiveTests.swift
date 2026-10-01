import XCTest
@testable import LumenCore

final class ExactMixerPrimitiveTests: XCTestCase {
    private func primitive(_ recipe: Recipe) -> ExactMixer? {
        ColorEngine(mixer: recipe.develop.mixer, pointColors: recipe.develop.pointColors,
                    color: recipe.develop.color, primaries: recipe.look.primaries,
                    bw: recipe.look.bw).exactMixer
    }
    private func activeRecipe() -> Recipe {
        var r = Recipe()
        r.develop.mixer.bands[4].lum = -100
        return r
    }

    func testOnlyResolvedMixerHSLIsEligible() {
        let r = activeRecipe()
        XCTAssertNotNil(primitive(r))
        XCTAssertNil(primitive(Recipe()))
        let excluded: [(String, (inout Recipe) -> Void)] = [
            ("Uniformity", { $0.develop.mixer.uniformity = 1 }),
            ("Saturation", { $0.develop.color.saturation = 0.001 }),
            ("Vibrance", { $0.develop.color.vibrance = -0.001 }),
            ("primary", { $0.look.primaries.rHue = 1 }),
            ("tint hue", { $0.look.primaries.tintHue = 1 }),
            ("tint purity", { $0.look.primaries.tintPurity = 1 }),
            ("point colour", { $0.develop.pointColors = [PointColor(
                sample: [0.2, 0.4, 0.6], shift: HSLShift(h: 1, s: 0, l: 0))] }),
            ("B&W", { $0.look.bw = BlackAndWhite() }),
        ]
        for (name, mutate) in excluded {
            var changed = r
            mutate(&changed)
            XCTAssertNil(primitive(changed), name)
        }
    }

    func testIndependentRecipeStagesDoNotChangePrimitiveParameters() throws {
        var r = activeRecipe()
        r.develop.raw.temp = 4200
        r.develop.raw.tint = 12
        r.develop.tone.exposure = 1
        r.develop.tone.contrast = 20
        r.develop.detail.clarity = 10
        r.look.vignette = -1
        r.develop.curve.point = [[0, 0], [0.5, 0.6], [1, 1]]
        r.look.printerLights.master = 4
        XCTAssertEqual(try XCTUnwrap(primitive(r)).bands,
                       try XCTUnwrap(primitive(activeRecipe())).bands)
    }

    func testResolvedParametersApplyTheCurrentRecipeWithoutATable() throws {
        var r = activeRecipe()
        let input = RGB(0.38413364324424248, 0.59591710513566343, 0.64828909901873966)
        for amount in [-100.0, 100, -25] {
            r.develop.mixer.bands[4].lum = amount
            let mixer = try XCTUnwrap(primitive(r))
            let oracle = ColorEngine(mixer: r.develop.mixer, pointColors: [],
                                      color: r.develop.color, primaries: r.look.primaries,
                                      bw: nil).apply(input)
            XCTAssertEqual(mixer.apply(input), oracle)
        }
    }

    func testIdentityAndDisabledFamiliesRemainExactNoOps() throws {
        let input = RGB(-0.02, 0.5, 8)
        let neutral = RenderPlan(recipe: Recipe())
        XCTAssertTrue(neutral.colorGradeIsIdentity)
        XCTAssertNil(primitive(Recipe()))
        var r = activeRecipe()
        var bw = BlackAndWhite()
        bw.enabled = false
        r.look.bw = bw
        r.develop.color.protectSkin = 100
        r.develop.color.density = 0
        XCTAssertNotNil(primitive(r))
        XCTAssertEqual(try XCTUnwrap(primitive(r)).apply(input),
                       try XCTUnwrap(primitive(activeRecipe())).apply(input))
    }

    func testParametersShareTheEngineSanitization() throws {
        var r = activeRecipe()
        r.develop.mixer.bands = [MixerBand(hue: 500, sat: -500, lum: 500)]
        r.develop.mixer.bands[0].core = [-100, 1000]
        r.develop.mixer.bands[0].feather = [0, 1000]
        let exact = try XCTUnwrap(primitive(r))
        XCTAssertEqual(exact.bands.count, 8)
        XCTAssertEqual(exact.bands[0].hue, ColorEngine.hueRangeDegrees)
        XCTAssertEqual(exact.bands[0].saturation, -1)
        XCTAssertEqual(exact.bands[0].luminance, 1)
        XCTAssertEqual(exact.bands[0].arc, ColorEngine.bandArcs(r.develop.mixer.bands)[0])
        XCTAssertEqual(exact.bands[7].hue, 0)
    }
}
