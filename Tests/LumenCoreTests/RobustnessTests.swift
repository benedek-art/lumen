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

    // MARK: - Saturation must keep working in the highlights

    /// The lum-vs-sat rolloff used to close a second smoothstep at brightness 1.0 —
    /// about two and a half stops over mid-grey — so Saturation and positive Vibrance
    /// did nothing at all above it. Every bright sky and every lit highlight. The
    /// rolloff is a taper now: highlights saturate less, they do not stop being
    /// colours.
    func testSaturationStillWorksAboveDisplayWhite() {
        for brightness in [1.0, 1.5, 2.0, 4.0, 20.0] {
            XCTAssertGreaterThan(ColorEngine.lumSatRolloff(brightness), 0.2,
                                 "saturation switched off at brightness \(brightness)")
        }
        // Full effect through the ordinary range, and nothing at true black.
        XCTAssertEqual(ColorEngine.lumSatRolloff(0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ColorEngine.lumSatRolloff(0), 0, accuracy: 1e-12)
        XCTAssertEqual(ColorEngine.lumSatRolloff(.nan), 0, accuracy: 1e-12)

        // Monotone non-increasing above the knee, and smooth: no step anywhere.
        var previous = ColorEngine.lumSatRolloff(ColorEngine.satRolloffHi0)
        var x = ColorEngine.satRolloffHi0
        while x < 30 {
            x += 0.01
            let v = ColorEngine.lumSatRolloff(x)
            XCTAssertLessThanOrEqual(v, previous + 1e-12, "rolloff rose at \(x)")
            XCTAssertLessThan(previous - v, 0.02, "rolloff stepped at \(x)")
            previous = v
        }

        // And the whole engine actually moves a bright saturated colour.
        var adjust = ColorAdjust()
        adjust.saturation = 60
        let engine = ColorEngine(mixer: Mixer(), pointColors: [], color: adjust,
                                 primaries: Primaries(), bw: nil)
        let bright = RGB(1.33, 1.01, 0.13)          // ~2.5 stops over mid-grey
        XCTAssertGreaterThan(engine.apply(bright).maxAbsDifference(bright), 0.01,
                             "saturation did nothing to a highlight")
    }

    // MARK: - The first step of a slider must be a first step

    /// Denoise ran the whole image through the variance-stabilizing round trip the
    /// moment Luminance left zero, and the unbiased inverse lifted every pixel by a
    /// constant — about 2.3e-3 linear at ISO 102400, a milky black arriving in full on
    /// the first step of the slider. The correction is a debias for a coefficient that
    /// was actually estimated and a pedestal for one that was not, so it is applied in
    /// proportion to how much shrinking happened.
    func testDenoiseDoesNotLiftBlacksOnItsFirstStep() {
        let black = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0) }
        let profile = NoiseProfile(a: 1.024e-2, b: 1e-6)   // ~ISO 102400

        func render(luma: Double) -> Double {
            let params = ClassicNR(luma: luma, chroma: 0, hotPixels: 0)
            let engine = ClassicalDenoise(params, profile: profile, isoDefaults: false)
            return engine.apply(black)[4, 4].g
        }

        XCTAssertEqual(render(luma: 0), 0, accuracy: 1e-12, "denoise off is not free")
        XCTAssertLessThan(abs(render(luma: 1)), 3e-4,
                          "the first step of Luminance lifted black to \(render(luma: 1))")

        // And the climb stays proportional — no jump anywhere along the slider.
        var previous = 0.0
        for value in stride(from: 0.0, through: 100.0, by: 5.0) {
            let out = render(luma: value)
            XCTAssertLessThan(abs(out - previous), 1.5e-3,
                              "denoise stepped between \(previous) and \(out) at \(value)")
            previous = out
        }
    }

    // MARK: - A control that exists must do something

    /// Seven sliders in the mask panel moved a value that no render stage read. The
    /// panel offered Temp, Tint, Texture, Clarity, Dehaze, Sharpness and Noise; the
    /// local stage applied exposure, contrast, the tone pair, hue, saturation and
    /// vibrance, and silently dropped the rest. Temp and Tint were the worst of it:
    /// they were in the stage's identity test, so moving one marked the stage live and
    /// rebuilt its table — and then produced exactly the same picture.
    ///
    /// This walks every local field the panel exposes and asserts the render moves.
    func testEveryLocalSliderThePanelOffersChangesThePicture() throws {
        let source = ImageBuffer(width: 24, height: 16) { u, v in
            // Texture and Clarity need something to find, and Dehaze needs a gradient
            // it can read as depth, so this is not a flat field.
            let detail = 0.06 * sin(u * 47) * cos(v * 31)
            return RGB(0.30 + detail, 0.26 + detail * 0.8, 0.20 + detail * 0.6)
        }

        var base = Recipe()
        var component = MaskComponent(op: .add, kind: .radial)
        component.center = [0.5, 0.5]
        component.radii = [0.9, 0.9]
        component.feather = 20
        var mask = Mask(name: "whole frame")
        mask.components = [component]
        base.masks = [mask]
        let unedited = ReferenceRenderer.render(source, plan: RenderPlan(recipe: base))

        let fields: [(String, (inout LocalAdjust) -> Void)] = [
            ("temp", { $0.temp = 80 }),
            ("tint", { $0.tint = 80 }),
            ("texture", { $0.texture = 90 }),
            ("clarity", { $0.clarity = 90 }),
            ("dehaze", { $0.dehaze = 80 }),
            ("sharpness", { $0.sharpness = 90 }),
            ("softening (negative sharpness)", { $0.sharpness = -90 }),
            ("exposure", { $0.exposure = 0.8 }),
            ("saturation", { $0.sat = 70 }),
            ("hue", { $0.hue = 40 }),
        ]

        for (name, mutate) in fields {
            var recipe = base
            mutate(&recipe.masks[0].adjust)
            let out = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))
            var worst = 0.0
            for y in 0..<out.height {
                for x in 0..<out.width {
                    worst = Swift.max(worst, out[x, y].maxAbsDifference(unedited[x, y]))
                }
            }
            XCTAssertGreaterThan(worst, 1e-4,
                                 "the local \(name) slider changed nothing")
        }
    }

    // MARK: - Scene-referred means unbounded

    /// No scene-referred stage may change its behaviour at a particular brightness.
    /// The colour and grade stages used to finish with a display-gamut soft clip, and
    /// `Gamut.softClip` returns its input untouched once OKLab L reaches 1 — so a
    /// colour was compressed below roughly three and a half stops over mid-grey and
    /// passed through above it. A step in the middle of the working range.
    ///
    /// The quantity compared is the output divided by the SCENE SCALE — not by the
    /// input channel. A per-channel ratio is meaningless for a channel that carries
    /// almost no signal: at hue 90 the blue component of the test colour is a
    /// thousandth of the red, so its "gain" came out at −64 and swung wildly for
    /// arithmetic reasons that have nothing to do with continuity. Dividing by the
    /// common scale asks the question that was actually meant: for a stage that treats
    /// exposure as exposure, this vector barely moves as the scene brightens.
    ///
    /// The tolerance is relative to the response's own magnitude, because a grading
    /// wheel is an offset at constant lightness, and the relative size of a fixed
    /// offset grows without bound as luminance falls. That is a real property of the
    /// tool, not a discontinuity.
    func testSceneReferredStagesAreContinuousInExposure() {
        var color = ColorAdjust()
        color.saturation = 60
        color.vibrance = 30
        let colorEngine = ColorEngine(mixer: Mixer(), pointColors: [], color: color,
                                      primaries: Primaries(), bw: nil)
        let gradeEngine = GradeEngine(
            wheels: GradingWheels(shadows: Wheel(hue: 220, sat: 0.3, lum: 0)),
            printerLights: PrinterLights())

        for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
            let tint = OKLabTransform.working.toRGB(OKLCh(L: 0.5, C: 0.12, h: hue))
            let unit = tint / Swift.max(tint.maxComponent, 1e-6)
            for engine in ["colour", "grade"] {
                var previousResponse: RGB?
                var ev = -6.0
                while ev <= 8 {
                    let scale = 0.18 * pow(2.0, ev)
                    let out = engine == "colour"
                        ? colorEngine.apply(unit * scale)
                        : gradeEngine.apply(unit * scale)
                    let response = out / scale
                    if let previous = previousResponse {
                        // Largest ABSOLUTE component: a response can be negative, and
                        // `maxComponent` on an all-negative triple is the smallest one.
                        let magnitude = Swift.max(1.0, Swift.max(abs(previous.r),
                                                                 Swift.max(abs(previous.g),
                                                                           abs(previous.b))))
                        let step = response.maxAbsDifference(previous) / magnitude
                        // A twentieth of a stop of input may not move the stage's
                        // response by a tenth of its own size. Smooth shaping over a
                        // multi-stop window moves it by a few percent per step; a
                        // switch moves it by all of whatever it was switching.
                        XCTAssertLessThan(
                            step, 0.12,
                            "\(engine) stage stepped at \(ev) EV, hue \(hue): "
                                + "response went \(previous) → \(response)")
                    }
                    previousResponse = response
                    ev += 0.05
                }
            }
        }
    }

    // MARK: - Which table is wrong

    /// `referenceColor` is two cubes in series and `exactColor` is neither, so when
    /// they disagree the useful question is *which* cube. This measures them one at a
    /// time, at the colour the composed test reports as its worst case.
    ///
    /// The colour stage is measured in the space it is stored in — log — because that
    /// is where its interpolation error actually lives. A tenth of a stop there is a
    /// seven percent error in linear, so quoting the linear number would blame the
    /// table for the exponential.
    func testEachTableTracksItsOwnExactEvaluationSeparately() {
        var recipe = Recipe()
        recipe.develop.tone.contrast = 30
        recipe.develop.color.saturation = 20
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.3, lum: 0)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

        let color = ColorEngine(mixer: recipe.develop.mixer,
                                pointColors: recipe.develop.pointColors,
                                color: recipe.develop.color,
                                primaries: recipe.look.primaries, bw: recipe.look.bw)
        let grade = GradeEngine(wheels: recipe.look.wheels,
                                printerLights: recipe.look.printerLights,
                                whiteAnchorEV: plan.tone.whiteAnchorEV,
                                blackAnchorEV: plan.tone.blackAnchorEV)

        var worstColorEV = 0.0, worstColorWhere = ""
        var worstFinish = 0.0, worstFinishWhere = ""

        for i in 0...24 {
            let ev = -7 + Double(i) * 0.5
            for hue in stride(from: 0.0, to: 360.0, by: 45.0) {
                let tint = OKLabTransform.working.toRGB(OKLCh(L: 0.5, C: 0.1, h: hue))
                let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                let scene = normalized * (0.18 * pow(2.0, ev))

                // Everything before the first cube, exactly as both paths compute it.
                var c = plan.linear.apply(scene)
                if !plan.toneIsIdentity {
                    let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
                    c = c * plan.tone.gain(at: Num.safeLog2(lum / 0.18))
                }

                // Cube one: colour and grade, log in and log out.
                let tabled = plan.colorGradeLUT.sample(LumenLog.encode(c))
                let exactEncoded = LumenLog.encode(grade.apply(color.apply(c)))
                let dEncoded = tabled.maxAbsDifference(exactEncoded) * LumenLog.range
                if dEncoded > worstColorEV {
                    worstColorEV = dEncoded
                    worstColorWhere = "\(ev) EV hue \(hue): in \(c) "
                        + "table \(LumenLog.decode(tabled)) "
                        + "exact \(grade.apply(color.apply(c)))"
                }

                // Cube two: picture formation and the curve, from the SAME input on
                // both sides, so cube one's error does not get charged to it.
                let exactGraded = grade.apply(color.apply(c))
                let finishTable = plan.finishLUT.sample(LumenLog.encode(exactGraded))
                    * plan.finishScale
                let formed = plan.displayTransform.apply(exactGraded,
                                                         gamut: RenderPlan.sharedGamutBoundary)
                let finishExact = CurveStack(recipe.develop.curve)
                    .apply(formed, white: plan.displayWhite, space: .rec2020)
                let dFinish = finishTable.maxAbsDifference(finishExact)
                if dFinish > worstFinish {
                    worstFinish = dFinish
                    worstFinishWhere = "\(ev) EV hue \(hue): in \(exactGraded) "
                        + "table \(finishTable) exact \(finishExact)"
                }
            }
        }

        XCTAssertLessThan(worstColorEV, 0.02,
                          "colour/grade table is off by \(worstColorEV) stops at \(worstColorWhere)")
        XCTAssertLessThan(worstFinish, 0.01,
                          "finish table is off by \(worstFinish) at \(worstFinishWhere)")
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

    /// The same rule for the stages the test above left out.
    ///
    /// The bug it was written for — an always-on gamut clip running inside a stage the
    /// plan swaps out when it is identity — is a shape, not an incident, and it can
    /// live in any of these just as easily. Tone reports `isIdentity` and nothing
    /// checked that a pixel survives it; Detail and Denoise were allowed 1e-5, which is
    /// room enough for a clip; and the Film Lab at Strength 0 has an explicit contract
    /// that it is "bit-identical to having no film block at all", which nothing asserted.
    func testEveryOtherIdentityStageIsAlsoExactlyIdentity() {
        let probes = [RGB(0.3, 0.5, 0.2), RGB(0.9, 0.05, 0.02), RGB(1.6, 0.2, 0.05),
                      RGB(4, 4, 4), RGB(-0.01, 0.2, 0.3), RGB(0.18, 0.18, 0.18)]

        let tone = ToneEngine(tone: Tone())
        XCTAssertTrue(tone.isIdentity, "a default Tone did not report itself identity")
        for c in probes {
            let t = Num.safeLog2(RGBColorSpace.rec2020.luminance(c) / 0.18)
            XCTAssertEqual(tone.gain(at: t), 1, accuracy: 1e-12,
                           "the tone stage applied a gain to \(c) at rest")
        }

        // Film at Strength 0 must equal the neutral rendering exactly — not "closely".
        // Both paths go through the same display transform and the same gamut
        // boundary; if they ever disagree, Strength becomes a discontinuous control at
        // one end of its own range.
        var off = FilmChain.defaultRecipe(for: FilmStock.portra400)
        off.amount = 0
        let filmOff = FilmChain(off, displayWhite: 1.0)
        XCTAssertTrue(filmOff.isIdentity, "Strength 0 did not reduce to the neutral chain")
        // Built exactly as `FilmChain.init` builds its own neutral rendering: the
        // neutral preset at `displayWhite × 100`, in the working space.
        var neutralParams = DisplayTransformParams.neutral
        neutralParams.whiteTarget = 100
        let neutral = DisplayTransform(neutralParams, space: .rec2020)
        for c in probes {
            XCTAssertLessThan(
                filmOff.apply(c).maxAbsDifference(neutral.apply(c, gamut: Gamut.sharedBoundary)),
                1e-12, "the film chain at Strength 0 disagreed with the neutral "
                    + "rendering on \(c)")
        }

        // Detail and Denoise are spatial, so they run on a frame rather than a pixel —
        // but the rule is the same, and at 1e-12 rather than the 1e-5 those two are
        // allowed elsewhere, which is room enough for a clip to hide in. The field
        // deliberately runs past display white, since that is where a stray clamp bites.
        let field = ImageBuffer(width: 16, height: 16) { u, v in
            RGB(0.18 * pow(2, u * 6 - 3), 0.4 * v + 0.05, 1.8 * u)
        }
        let detailOff = DetailEngine.apply(
            field, detail: Detail(),
            decomposition: DetailEngine.Decomposition(image: field, workingRadius: 4))
        XCTAssertLessThan(detailOff.maxAbsDifference(field), 1e-12,
                          "the detail stage moved a pixel at rest")

        let denoiseOff = ClassicalDenoise(ClassicNR(luma: 0, chroma: 0, hotPixels: 0),
                                          profile: NoiseProfile.forISO(100),
                                          isoDefaults: false).apply(field)
        XCTAssertLessThan(denoiseOff.maxAbsDifference(field), 1e-12,
                          "the denoise stage moved a pixel at rest")
    }

    // MARK: - Rendering is a pure function

    /// "Rendering is a pure function of (original, recipe, pipelineVersion)" —
    /// `Recipe.swift`'s opening line, and the premise the entire cache rests on. If it
    /// is false anywhere, a cached tile and a fresh render disagree and the app shows
    /// one picture in the grid and a different one in the loupe.
    ///
    /// Nothing asserted it. These are the two halves: the same plan twice must be
    /// bit-identical, and two independently-built plans from equal recipes must agree
    /// as well — the second is the one that catches state captured at construction,
    /// which is where a cache key stops meaning what it says.
    func testTheSameRecipeAlwaysRendersTheSamePixels() {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.4
        recipe.develop.tone.contrast = 30
        recipe.develop.color.saturation = 20
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.3, lum: -0.2)
        recipe.look.vignette = -0.8
        recipe.develop.detail.texture = 25

        let source = ImageBuffer(width: 24, height: 12) { u, v in
            RGB(0.18 * pow(2, u * 8 - 4), 0.5 * v + 0.02, 1.4 * u * v + 0.01)
        }

        let plan = RenderPlan(recipe: recipe)
        let first = ReferenceRenderer.render(source, plan: plan)
        let again = ReferenceRenderer.render(source, plan: plan)
        XCTAssertEqual(first.pixels, again.pixels,
                       "the same plan rendered the same frame differently twice")

        // A separately-constructed plan from an equal recipe. This is what the
        // fingerprint promises when it is used as a cache key.
        let copy = recipe
        XCTAssertEqual(copy, recipe)
        let rebuilt = ReferenceRenderer.render(source, plan: RenderPlan(recipe: copy))
        XCTAssertEqual(first.pixels, rebuilt.pixels,
                       "two plans built from equal recipes rendered differently")
    }

    /// The contrapositive, which is the half that makes the fingerprint worth having:
    /// recipes that render the same must share one, and recipes that render differently
    /// must not. Without the second, a cache key is free to serve the wrong picture.
    func testTheFingerprintTracksWhetherThePictureChanges() throws {
        var base = Recipe()
        base.develop.tone.exposure = 0.4

        // Cosmetics do not change the picture, so they must not change the key —
        // otherwise renaming a mask throws away every cached render of that photo.
        var renamed = base
        renamed.masks = [Mask(id: "a0000000-0000-0000-0000-000000000001", name: "Sky",
                              enabled: true, amount: 100, components: [],
                              refine: MaskRefine(), adjust: LocalAdjust())]
        var renamedAgain = renamed
        renamedAgain.masks[0].name = "Sky (final)"
        renamedAgain.masks[0].id = "b0000000-0000-0000-0000-000000000002"
        XCTAssertEqual(try RecipeFingerprint.fingerprint(renamed),
                       try RecipeFingerprint.fingerprint(renamedAgain),
                       "renaming a mask changed the render key")
        XCTAssertTrue(renamed.rendersSameAs(renamedAgain))

        // Anything that does change the picture must change the key, including a
        // difference far below what any slider readout would show.
        var nudged = base
        nudged.develop.tone.exposure = 0.4000000001
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(base),
                          try RecipeFingerprint.fingerprint(nudged),
                          "a real difference in exposure did not reach the key")
        XCTAssertFalse(base.rendersSameAs(nudged))
    }

    // MARK: - A slider must keep doing more, and must not move another slider

    /// Two properties the monotonicity limiter broke while fixing an inversion.
    ///
    /// The first version solved ONE scale over the whole zonal sum and clipped hard at
    /// it. Highlights' window lives above mid-grey and Shadows' below — disjoint — so
    /// the constraint that binds is always in one of them, and multiplying the sum cut
    /// the other one down with it: Highlights at −100 turned Shadows +60 into an
    /// effective +33.8, which made the Highlights slider's meaning depend on Shadows,
    /// Contrast and Whites. And the hard clip left 43 of the top 44 settings of
    /// Highlights applying one identical value.
    ///
    /// Every assertion that existed still passed, because they check fixed points,
    /// anchor geometry and monotonicity in x — all of which a slider that returns zero
    /// also satisfies.
    func testHighlightsAndShadowsKeepDoingMoreAndLeaveEachOtherAlone() {
        for contrast in [0.0, -60, 60] {
            for direction in [1.0, -1.0] {
                var previousHigh = -1.0
                var previousLow = -1.0
                for setting in 0...100 {
                    let amount = direction * Double(setting)
                    let high = abs(ToneEngine(tone: Tone(contrast: contrast,
                                                         highlights: amount))
                        .effectiveHighlights)
                    let low = abs(ToneEngine(tone: Tone(contrast: contrast,
                                                        shadows: amount))
                        .effectiveShadows)
                    if setting >= 2 {
                        XCTAssertGreaterThan(
                            high, previousHigh,
                            "Highlights \(amount) at contrast \(contrast) applied no "
                                + "more than \(amount - direction) did")
                        XCTAssertGreaterThan(
                            low, previousLow,
                            "Shadows \(amount) at contrast \(contrast) applied no more "
                                + "than \(amount - direction) did")
                    }
                    previousHigh = high
                    previousLow = low
                }
            }
        }

        // Independence. The windows share no domain, so there is no honest reason for
        // one to move the other.
        for contrast in [0.0, -60, 60] {
            for whites in [0.0, 100] {
                let alone = ToneEngine(tone: Tone(contrast: contrast, shadows: 60,
                                                  whites: whites)).effectiveShadows
                for highlights in [-100.0, -50, 50, 100] {
                    let together = ToneEngine(tone: Tone(contrast: contrast,
                                                         highlights: highlights,
                                                         shadows: 60, whites: whites))
                        .effectiveShadows
                    XCTAssertEqual(together, alone, accuracy: 1e-12,
                                   "Highlights \(highlights) moved Shadows +60 from "
                                       + "\(alone) to \(together)")
                }
            }
        }

        // And the limiter is not touching ordinary settings: below the knee the slider
        // is applied exactly, or the fix has weakened the control everywhere to buy
        // safety at one end.
        for setting in [10.0, 25, 40] {
            XCTAssertEqual(ToneEngine(tone: Tone(highlights: -setting))
                .effectiveHighlights, -setting / 100, accuracy: 1e-12,
                "Highlights −\(setting) was already being limited")
        }
    }

    /// A local Colour tint has to change the picture, and hold luminance while it does.
    ///
    /// It changed nothing here: the reference renderer's local stage never read
    /// `colorTint` at all, while the GPU path applied it — so the two rendered different
    /// pictures for any mask carrying one, and every golden that compares them would
    /// have diverged wherever it was set. The mirror-image gap was on the other side:
    /// the GPU declared a mask identity when its only edit was a Point Colour swatch.
    /// One shared implementation now, which is the only thing that makes that class of
    /// divergence impossible rather than merely fixed.
    func testTheLocalColourTintTintsAndHoldsLuminance() {
        let space = RGBColorSpace.rec2020
        let warm: [Double] = [0.9, 0.45, 0.2]
        for probe in [RGB(0.18, 0.18, 0.18), RGB(0.4, 0.2, 0.1), RGB(0.05, 0.3, 0.6)] {
            let before = space.luminance(probe)

            // Strength 0 and a nil swatch are both exact identities.
            XCTAssertEqual(ReferenceRenderer.applyColorTint(probe, tint: warm,
                                                            strength: 0).maxAbsDifference(probe),
                           0, accuracy: 0)
            XCTAssertEqual(ReferenceRenderer.applyColorTint(probe, tint: nil,
                                                            strength: 1).maxAbsDifference(probe),
                           0, accuracy: 0)

            // At full strength the colour becomes the swatch's hue, and the pixel's own
            // luminance survives — that is what makes this a tint rather than a paint.
            let tinted = ReferenceRenderer.applyColorTint(probe, tint: warm, strength: 1)
            XCTAssertEqual(space.luminance(tinted), before, accuracy: before * 1e-9,
                           "the tint moved \(probe)'s luminance")
            XCTAssertGreaterThan(tinted.maxAbsDifference(probe), 1e-6,
                                 "a full-strength tint left \(probe) unchanged")

            // And it is a genuine mix: half strength lands between the two.
            let half = ReferenceRenderer.applyColorTint(probe, tint: warm, strength: 0.5)
            for channel in 0..<3 {
                let lo = Swift.min(probe[channel], tinted[channel]) - 1e-9
                let hi = Swift.max(probe[channel], tinted[channel]) + 1e-9
                XCTAssertTrue(half[channel] >= lo && half[channel] <= hi,
                              "half strength left the interval in channel \(channel)")
            }
        }

        // A black swatch cannot divide by its own zero luminance.
        let degenerate = ReferenceRenderer.applyColorTint(RGB(0.3, 0.3, 0.3),
                                                          tint: [0, 0, 0], strength: 1)
        XCTAssertTrue(degenerate.isFinite, "a black swatch produced \(degenerate)")
    }

    // MARK: - The whole pipeline, everything on

    /// A recipe with every stage active, through the full reference renderer.
    ///
    /// The suite is thick with per-stage contracts and thin on integration: ten tests
    /// call `ReferenceRenderer.render`, and each turns on one or two things. Nothing
    /// asked what happens when tone, colour, grade, presence, a mask, a film stock,
    /// halation, grain and a vignette are all live on the same frame — which is the
    /// only configuration a photographer working a real edit ever produces.
    ///
    /// Nothing here is a tolerance to tune. Every assertion is a property that must
    /// hold for ANY correct render, so this cannot rot into a golden that gets
    /// regenerated when it fails.
    private func everythingRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.35
        recipe.develop.tone.contrast = 30
        recipe.develop.tone.highlights = -60
        recipe.develop.tone.shadows = 45
        recipe.develop.tone.whites = 20
        recipe.develop.tone.blacks = -15
        recipe.develop.raw.temp = 6200
        recipe.develop.raw.tint = 6
        recipe.develop.color.saturation = 18
        recipe.develop.color.vibrance = 25
        recipe.develop.detail.texture = 30
        recipe.develop.detail.clarity = 20
        recipe.develop.detail.dehaze = 15
        recipe.develop.detail.sharpen = ManualSharpen(amount: 60, radius: 1.2, detail: 40)
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.25, lum: -0.15)
        recipe.look.wheels.high = Wheel(hue: 40, sat: 0.20, lum: 0.10)
        recipe.look.printerLights = PrinterLights(master: 2, r: -1, g: 0, b: 1)
        recipe.look.vignette = -0.9
        recipe.look.filmLab = FilmLab(stock: "lumen/portra400", amount: 70, pushPull: 0.5,
                                      halation: 40,
                                      grain: FilmGrain(size: 1.2, amount: 55))

        var luma = MaskComponent(op: .add, kind: .lumaRange)
        luma.lo = 0.3
        luma.hi = 0.8
        luma.smooth = 60
        var adjust = LocalAdjust()
        adjust.exposure = -0.4
        adjust.sat = 20
        adjust.clarity = 15
        recipe.masks = [Mask(id: "e0000000-0000-0000-0000-000000000001",
                             name: "Midtones", enabled: true, amount: 90,
                             components: [luma],
                             // Every term in the refine chain is scaled by the long
                             // edge — the guided-filter radius is Feather × 2% of it and
                             // rounds to an integer, the blur σ is Blur × 1% of it and
                             // has to clear 0.05. On a small frame that means modest
                             // settings round away to nothing: at 40 px, Feather 20 is
                             // radius 0 and Blur 10 is σ = 0.04, so the whole chain is
                             // an identity and "turning refine off changes nothing"
                             // would be a fact about the test frame, not the code.
                             // These three all engage at `everythingSource`'s size.
                             refine: MaskRefine(feather: 50, edge: 10, blur: 20),
                             adjust: adjust)]
        return recipe
    }

    private func everythingSource() -> ImageBuffer {
        // Structure at several scales so presence, sharpening and the mask all have
        // something to act on, and a wide luminance range so the tone stack is
        // exercised across its whole domain.
        ImageBuffer(width: 64, height: 44) { u, v in
            let ev = -7 + u * 12
            let level = 0.18 * pow(2, ev)
            let fine = 1 + 0.10 * sin(u * 90) * cos(v * 70)
            let coarse = 1 + 0.20 * sin(u * 7 + v * 5)
            return RGB(level * fine * coarse,
                       level * fine * (1.9 - 0.9 * v),
                       level * coarse * (0.6 + 0.5 * v))
        }
    }

    func testTheWholePipelineWithEveryStageOnProducesASanePicture() {
        let source = everythingSource()
        let plan = RenderPlan(recipe: everythingRecipe())
        let out = ReferenceRenderer.render(source, plan: plan)

        XCTAssertEqual(out.width, source.width)
        XCTAssertEqual(out.height, source.height)

        var lowest = Double.infinity
        var highest = -Double.infinity
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = out[x, y]
                XCTAssertTrue(c.isFinite,
                              "the composed render produced \(c) at (\(x), \(y))")
                for channel in 0..<3 {
                    lowest = Swift.min(lowest, c[channel])
                    highest = Swift.max(highest, c[channel])
                }
            }
        }
        // Display-referred output. Grain rides on top of picture formation, so a small
        // overshoot above white is legal; a large one means a stage escaped its domain.
        XCTAssertGreaterThanOrEqual(lowest, -0.01,
                                    "the composed render went to \(lowest), below black")
        XCTAssertLessThanOrEqual(highest, 1.15,
                                 "the composed render reached \(highest), far above "
                                     + "display white")
        // And it is a picture, not a flat field: a 12-stop ramp has to survive as one.
        XCTAssertGreaterThan(highest - lowest, 0.3,
                             "the composed render spans only \(highest - lowest)")
    }

    /// Every stage in that recipe has to contribute. Turning any ONE of them off must
    /// change the result — otherwise it is riding along doing nothing, which is exactly
    /// the failure mode that put four mask kinds, three sharpening sliders and a film
    /// print-size picker into the audit backlog.
    func testEveryStageInTheFullRecipeChangesTheResult() {
        let source = everythingSource()
        let full = ReferenceRenderer.render(source, plan: RenderPlan(recipe: everythingRecipe()))

        func worstDifference(_ mutate: (inout Recipe) -> Void) -> Double {
            var recipe = everythingRecipe()
            mutate(&recipe)
            let other = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))
            var worst = 0.0
            for y in 0..<full.height {
                for x in 0..<full.width {
                    worst = Swift.max(worst, full[x, y].maxAbsDifference(other[x, y]))
                }
            }
            return worst
        }

        let stages: [(String, (inout Recipe) -> Void)] = [
            ("exposure", { $0.develop.tone.exposure = 0 }),
            ("contrast", { $0.develop.tone.contrast = 0 }),
            ("highlights", { $0.develop.tone.highlights = 0 }),
            ("shadows", { $0.develop.tone.shadows = 0 }),
            ("whites", { $0.develop.tone.whites = 0 }),
            ("blacks", { $0.develop.tone.blacks = 0 }),
            ("white balance", { $0.develop.raw.temp = 5500; $0.develop.raw.tint = 0 }),
            ("saturation", { $0.develop.color.saturation = 0 }),
            ("vibrance", { $0.develop.color.vibrance = 0 }),
            ("texture", { $0.develop.detail.texture = 0 }),
            ("clarity", { $0.develop.detail.clarity = 0 }),
            ("dehaze", { $0.develop.detail.dehaze = 0 }),
            ("sharpening", { $0.develop.detail.sharpen = ManualSharpen() }),
            ("shadow wheel", { $0.look.wheels.shadows = Wheel() }),
            ("highlight wheel", { $0.look.wheels.high = Wheel() }),
            ("printer lights", { $0.look.printerLights = PrinterLights() }),
            ("vignette", { $0.look.vignette = 0 }),
            ("film stock", { $0.look.filmLab = nil }),
            ("film strength", { $0.look.filmLab?.amount = 0 }),
            ("halation", { $0.look.filmLab?.halation = 0 }),
            ("grain", { $0.look.filmLab?.grain.amount = 0 }),
            ("the mask", { $0.masks = [] }),
            ("the mask's amount", { $0.masks[0].amount = 0 }),
            ("the mask's refine", { $0.masks[0].refine = MaskRefine() }),
        ]
        for (name, mutate) in stages {
            XCTAssertGreaterThan(worstDifference(mutate), 1e-6,
                                 "turning off \(name) changed nothing — it is not "
                                     + "reaching the picture")
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
        var where_ = ""
        for i in 0...20 {
            let ev = -8 + Double(i) * 0.6
            for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
                for chroma in [0.02, 0.10, 0.20] {
                    let tint = OKLabTransform.working.toRGB(
                        OKLCh(L: 0.5, C: chroma, h: hue))
                    let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                    let scene = normalized * (0.18 * pow(2.0, ev))
                    let table = plan.referenceColor(scene)
                    let exact = plan.exactColor(scene)
                    let d = table.maxAbsDifference(exact)
                    if d > worst {
                        worst = d
                        where_ = "\(ev) EV hue \(hue) C \(chroma): scene \(scene) "
                            + "table \(table) exact \(exact)"
                    }
                }
            }
        }
        XCTAssertLessThan(worst, 0.01, "export table error reached \(worst) at \(where_)")
    }
}
