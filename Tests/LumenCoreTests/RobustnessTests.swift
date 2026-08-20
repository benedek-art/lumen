// RobustnessTests.swift
// Regressions for the bug classes two adversarial reviews found, so they cannot come
// back quietly.
//
// The theme running through all of them: a property that is *self-consistent* is not
// the same as a property that is *correct*. The shaper's encode and decode were exact
// inverses of each other while the encoding was half a domain wrong. A stage that
// clamps looks fine until you ask it to do nothing. A search that finds the nearest
// point is not the same as a search that finds the right one.

import XCTest
@testable import LumenCore

final class RobustnessTests: XCTestCase {

    // MARK: - The shaper meets itself

    func testShaperBranchesMeetAtTheCrossover() {
        let cut = LumenLog.linearCut
        let below = LumenLog.encode(cut * (1 - 1e-12))
        let above = LumenLog.encode(cut)
        XCTAssertEqual(below, above, accuracy: 1e-9,
                       "the shaper's toe does not meet its log branch")
    }

    func testTheWholeShaperDomainIsUsable() {
        // Everything from zero upward must land inside the unit domain, or the cube
        // stages clamp it to index 0 and the shadows go flat.
        for x in [0.0, 1e-9, 1e-6, LumenLog.linearCut * 0.5, LumenLog.linearCut,
                  0.001, 0.18, 1.0, 100.0] {
            let y = LumenLog.encode(x)
            XCTAssertGreaterThanOrEqual(y, 0, "encode(\(x)) fell below the domain")
            XCTAssertLessThanOrEqual(y, 1, "encode(\(x)) rose above the domain")
        }
    }

    func testShaperIsStrictlyIncreasing() {
        var previous = -Double.infinity
        var x = 0.0
        while x < 600 {
            let y = LumenLog.encode(x)
            XCTAssertGreaterThanOrEqual(y, previous, "shaper reversed at \(x)")
            previous = y
            x = x < 1e-4 ? x + 5e-6 : x * 1.05
        }
    }

    // MARK: - Non-finite input must not crash

    /// Scene-referred data is unbounded, and a matrix with negative off-diagonals — a
    /// white balance always has some — turns an infinity into a NaN. `Num.saturate`
    /// does NOT sanitise one, because every comparison against NaN is false. These
    /// used to reach `Int()` and trap.
    func testTablesSurviveNonFiniteInput() {
        let lut1d = LUT1D(size: 64) { $0 * $0 }
        for x in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(lut1d.evaluate(x).isFinite, "LUT1D produced a non-finite value")
        }

        let lut3d = LUT3D(size: 9) { $0 }
        for c in [RGB(.nan, 0.5, 0.5), RGB(.infinity, .infinity, .infinity),
                  RGB(-.infinity, 0, 1)] {
            XCTAssertTrue(lut3d.sample(c).isFinite, "LUT3D produced a non-finite value")
        }

        let boundary = Gamut.Boundary(hueSteps: 12, lightnessSteps: 5)
        XCTAssertEqual(boundary.maxChroma(L: .nan, hue: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(boundary.maxChroma(L: 0.5, hue: .nan), 0, accuracy: 1e-12)
    }

    func testRenderSurvivesAPoisonedPixel() {
        var source = ImageBuffer(width: 8, height: 4) { _, _ in RGB(gray: 0.2) }
        source[3, 2] = RGB(.nan, .infinity, -.infinity)
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1
        recipe.develop.tone.contrast = 40
        let out = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))
        // The clean pixels must still be right; the poisoned one may be anything
        // finite, but it must not have taken the render down.
        XCTAssertTrue(out[0, 0].isFinite)
        XCTAssertEqual(out.width, source.width)
    }

    // MARK: - The cube must not invent a colour cast

    /// A cube is interpolated, so it is allowed to be a little wrong — except on the
    /// neutral axis, where being a little wrong is a colour cast in a grey sky. The
    /// tetrahedral sampler makes the diagonal exact by construction; this is the test
    /// that says so, on a function deliberately built to be asymmetric between the
    /// channels so trilinear would have no chance of getting it right by luck.
    func testCubeKeepsTheNeutralAxisExact() {
        let lut = LUT3D(size: 17) { c in
            // Neutral in → neutral out, but wildly channel-asymmetric off the diagonal.
            let m = (c.r + 2 * c.g + 5 * c.b) / 8
            let spread = RGB(c.r - m, c.g - m, c.b - m)
            let base = m * m
            return RGB(base, base, base) + spread * 0.75
        }
        for i in 0...200 {
            let y = Double(i) / 200
            let out = lut.sample(RGB(gray: y))
            XCTAssertEqual(out.r, out.g, accuracy: 1e-9, "cast on the neutral axis at \(y)")
            XCTAssertEqual(out.g, out.b, accuracy: 1e-9, "cast on the neutral axis at \(y)")
            XCTAssertEqual(out.r, y * y, accuracy: 2e-3, "neutral value drifted at \(y)")
        }
    }

    func testCubeReproducesItsOwnGridPointsAndTheIdentity() {
        let size = 9
        let lut = LUT3D(size: size) { RGB($0.r * $0.r, $0.g, sqrt($0.b)) }
        let denom = Double(size - 1)
        for ri in 0..<size {
            for gi in 0..<size {
                for bi in 0..<size {
                    let c = RGB(Double(ri) / denom, Double(gi) / denom, Double(bi) / denom)
                    let expected = RGB(c.r * c.r, c.g, sqrt(c.b))
                    XCTAssertLessThan(lut.sample(c).maxAbsDifference(expected), 1e-6,
                                      "grid point \(c) did not come back")
                }
            }
        }

        let identity = LUT3D.identity(size: 2)
        for c in [RGB(0.13, 0.62, 0.91), RGB(0, 1, 0.5), RGB(0.777, 0.777, 0.2)] {
            XCTAssertLessThan(identity.sample(c).maxAbsDifference(c), 1e-9,
                              "the identity cube moved \(c)")
        }
    }

    // MARK: - Untrusted recipes

    /// Recipes arrive from sidecars and catalog rows written by other versions and
    /// other machines. None of this may trap.
    func testMalformedRecipeDoesNotTrap() {
        var recipe = Recipe()
        recipe.develop.zones.pivots = [0.2, 0.5, 0.8]     // three, not five
        recipe.develop.zones.mid.ev = 1.0
        recipe.develop.mixer.bands = [MixerBand(hue: 20)]  // one, not eight
        recipe.look.bw = BlackAndWhite(bands: [10, -10])   // two, not eight
        recipe.look.wheels.pivots = []                     // none

        let plan = RenderPlan(recipe: recipe)
        let out = plan.exactColor(RGB(0.2, 0.3, 0.4))
        XCTAssertTrue(out.isFinite)
    }

    func testEmptyAndDegenerateZonePivotsAreSurvivable() {
        for pivots in [[Double](), [0.5], [0.5, 0.5, 0.5, 0.5, 0.5], [0.9, 0.1, 0.5, 0.2, 0.7]] {
            var zones = Zones()
            zones.pivots = pivots
            zones.mid.ev = 0.5
            let engine = ToneEngine(tone: Tone(), zones: zones)
            XCTAssertTrue(engine.stops(at: 0).isFinite, "pivots \(pivots)")
            XCTAssertTrue(engine.stops(at: -6).isFinite, "pivots \(pivots)")
        }
    }

    // MARK: - Doing nothing must do nothing

    /// A stage that reports itself as identity must be bit-exact on every input,
    /// including saturated and above-white ones. The always-on gamut clip used to run
    /// anyway, which both changed a default recipe and disagreed with the plan, which
    /// swaps the stage out entirely when it is identity.
    func testIdentityStagesAreExactlyIdentity() {
        let color = ColorEngine(mixer: Mixer(), pointColors: [], color: ColorAdjust(),
                                primaries: Primaries(), bw: nil)
        let grade = GradeEngine(wheels: GradingWheels(), printerLights: PrinterLights())
        let curve = CurveStack(CurveSet())

        for c in [RGB(0.3, 0.5, 0.2), RGB(0.9, 0.05, 0.02), RGB(1.6, 0.2, 0.05),
                  RGB(4, 4, 4), RGB(-0.01, 0.2, 0.3)] {
            XCTAssertLessThan(color.apply(c).maxAbsDifference(c), 1e-12,
                              "colour stage moved \(c)")
            XCTAssertLessThan(grade.apply(c).maxAbsDifference(c), 1e-12,
                              "grade moved \(c)")
            XCTAssertLessThan(curve.apply(c).maxAbsDifference(c), 1e-12,
                              "curve moved \(c)")
        }
    }

    // MARK: - Monotonicity across the whole slider

    /// A brighter input must never render darker. The contrast relax window used to be
    /// narrow enough that the falling gain beat the rising distance past contrast 84.
    func testToneIsMonotoneAcrossTheWholeContrastRange() {
        for contrast in [-100.0, -50, 0, 50, 85, 100] {
            for pivot in [-4.0, 0, 4] {
                let engine = ToneEngine(tone: Tone(contrast: contrast, contrastPivot: pivot))
                var previous = -Double.infinity
                var t = -14.0
                while t <= 14 {
                    let mapped = engine.contrastMapped(t)
                    XCTAssertGreaterThanOrEqual(
                        mapped, previous - 1e-9,
                        "contrast \(contrast) pivot \(pivot) inverted at \(t) EV")
                    previous = mapped
                    t += 0.05
                }
            }
        }
    }

    func testRenderedLuminanceIsMonotoneAtExtremeSettings() {
        for contrast in [-100.0, 0, 100] {
            var recipe = Recipe()
            recipe.develop.tone.contrast = contrast
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
            var previous = -Double.infinity
            for i in 0...80 {
                let ev = -10 + Double(i) * 0.25
                let value = plan.exactColor(RGB(gray: 0.18 * pow(2.0, ev))).g
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6,
                                            "contrast \(contrast) inverted at \(ev) EV")
                previous = value
            }
        }
    }

    // MARK: - The white-balance inverse really is an inverse

    func testEyedropperInverseIsExactAcrossTheSlider() {
        for kelvin in stride(from: 2500.0, through: 20000.0, by: 1500.0) {
            for tint in [-120.0, -40, 0, 40, 120] {
                let chroma = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let back = ColorTemperature.temperatureAndTint(for: chroma)
                XCTAssertEqual(back.kelvin, kelvin, accuracy: kelvin * 0.01,
                               "K at \(kelvin)/\(tint)")
                XCTAssertEqual(back.tint, tint, accuracy: 1.0,
                               "tint at \(kelvin)/\(tint)")
            }
        }
    }

    // MARK: - Table accuracy, stated as a number

    /// The tables are an optimization. This is what they cost, measured rather than
    /// assumed — and it is also what caught the finish table being decoded twice.
    func testExportTableErrorStaysUnderOnePercent() {
        var recipe = Recipe()
        recipe.develop.tone.contrast = 35
        recipe.develop.color.saturation = 25
        recipe.develop.color.vibrance = 15
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.35, lum: 0.1)
        recipe.look.printerLights = PrinterLights(master: 3, r: -2, g: 0, b: 4)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

        var worst = 0.0
        for i in 0...20 {
            let ev = -8 + Double(i) * 0.6
            for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
                for chroma in [0.02, 0.10, 0.20] {
                    let tint = OKLabTransform.working.toRGB(
                        OKLCh(L: 0.5, C: chroma, h: hue))
                    let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                    let scene = normalized * (0.18 * pow(2.0, ev))
                    worst = Swift.max(worst, plan.referenceColor(scene)
                        .maxAbsDifference(plan.exactColor(scene)))
                }
            }
        }
        XCTAssertLessThan(worst, 0.01, "export table error reached \(worst)")
    }
}
