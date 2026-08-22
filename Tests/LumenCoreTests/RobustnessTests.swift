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
            let engine = ClassicalDenoise(params, profile: profile)
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
    /// A mask's Amount must scale how far a grade pushes, not which way it pushes.
    ///
    /// `sat` and `lum` are magnitudes and scale; `hue` is an angle and must not, or a
    /// mask at 50% would be a different colour rather than half as much of the same
    /// one — the failure would look like a plausible grade, which is why it needs its
    /// own assertion rather than trusting the wiring.
    func testAMasksAmountScalesItsGradeWithoutRotatingIt() throws {
        let wheels = GradingWheels(shadows: Wheel(hue: 220, sat: 0.8, lum: 0.3),
                                   high: Wheel(hue: 40, sat: 0.5, lum: -0.2))
        let half = wheels.scalingShift(by: 0.5)

        XCTAssertEqual(half.shadows.sat, 0.4, accuracy: 1e-12, "sat did not halve")
        XCTAssertEqual(half.shadows.lum, 0.15, accuracy: 1e-12, "lum did not halve")
        XCTAssertEqual(half.high.sat, 0.25, accuracy: 1e-12)
        XCTAssertEqual(half.high.lum, -0.1, accuracy: 1e-12)
        XCTAssertEqual(half.shadows.hue, 220, accuracy: 1e-12,
                       "hue is an angle and must not scale — the grade rotated")
        XCTAssertEqual(half.high.hue, 40, accuracy: 1e-12,
                       "hue is an angle and must not scale — the grade rotated")

        // Zone geometry says where the zones are, not how hard they push.
        XCTAssertEqual(half.blending, wheels.blending, accuracy: 1e-12)
        XCTAssertEqual(half.balance, wheels.balance, accuracy: 1e-12)
        XCTAssertEqual(half.pivots, wheels.pivots)

        // And the identity test has to see through moved pivots.
        var movedPivots = GradingWheels()
        movedPivots.pivots = [0.2, 0.8]
        XCTAssertTrue(movedPivots.isNeutral,
                      "moved pivots with untouched wheels is still the identity")
        XCTAssertFalse(wheels.isNeutral)
        XCTAssertTrue(wheels.scalingShift(by: 0).isNeutral,
                      "a mask at zero Amount must grade nothing")
    }

    func testEveryLocalSliderThePanelOffersChangesThePicture() throws {
        let source = ImageBuffer(width: 24, height: 16) { u, v in
            // Texture and Clarity need something to find, and Dehaze needs a gradient
            // it can read as depth, so this is not a flat field.
            let detail = 0.06 * sin(u * 47) * cos(v * 31)
            let base = RGB(0.30 + detail, 0.26 + detail * 0.8, 0.20 + detail * 0.6)
            // And it needs a TONAL RANGE, or the zonal controls have nothing to grab.
            // It used to sit flat at about +0.5 EV, where the Shadows window and a
            // shadows grading wheel both evaluate to zero weight — so both reported
            // "changed nothing" and were indistinguishable from being unwired. A ramp
            // from −4 to +4 EV puts real shadows and real highlights in the frame.
            return base * pow(2.0, -4 + 8 * v)
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
            // The wheels were the one entry missing from this list, and they were also
            // the one control in the mask panel that shipped as four live-looking
            // wheels reading into a field no stage touched.
            ("grading wheels", {
                $0.wheels = GradingWheels(shadows: Wheel(hue: 220, sat: 0.7, lum: 0.2))
            }),
            // BUILDING.md cited this test as covering thirteen local controls while the
            // list held eleven. Contrast, highlights, shadows, vibrance and point
            // colour are all wired in `applyLocalAdjust` and none of them was driven
            // here — the ledger was reading the test's NAME, not its body.
            ("contrast", { $0.contrast = 60 }),
            ("highlights", { $0.highlights = -70 }),
            ("shadows", { $0.shadows = 70 }),
            ("vibrance", { $0.vibrance = 70 }),
            ("point colour", {
                $0.pointColors = [PointColor(sample: [0.42, 0.22, 0.16],
                                             shift: HSLShift(h: 30, s: 40, l: 10))]
            }),
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
                                 "the local \(name) slider changed nothing on the "
                                     + "reference path")
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
        var worstColorFloor = 0.0
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
                //
                // EV error is charged only where EV is the shaper's own unit. Below
                // `LumenLog.linearCut` — 10.5 stops under mid-grey — the shaper is
                // deliberately LINEAR rather than logarithmic, so a ratio down there
                // is not a quantity it represents. The encoded function's curvature
                // breaks at that crossover, and a uniform lattice interpolating across
                // a curvature break undershoots: with a shadow wheel at hue 220 the
                // grade pushes red to 2.3e-4, which is 0.88 stops ABOVE the cut, the
                // cell straddles the knee, and the interpolated value lands at 1.1e-4
                // — below the cut, in the toe. That reads as 1.0008 EV of error at an
                // absolute level of 1/8700th of mid-grey, black on any display.
                // Convergence at a curvature break is linear in cell size, so a
                // 65-cube reaching 0.02 EV there would have to be about fifty times
                // finer. Below the cut the table is held to an absolute tolerance
                // instead, which is the quantity that actually matters.
                let tabled = plan.colorGradeLUT.sample(LumenLog.encode(c))
                let exactLinear = grade.apply(color.apply(c))
                let exactEncoded = LumenLog.encode(exactLinear)
                let tabledLinear = LumenLog.decode(tabled)

                // BOTH sides have to be above the cut for a ratio to be the right
                // metric. Charging EV whenever the EXACT value is above it charges a
                // STRADDLING cell — exact above, interpolated below — in a unit the
                // shaper has stopped representing on one side of the comparison. That is
                // the 1.0008 EV this test reported for months: red exact 2.29e-4, tabled
                // 1.14e-4, either side of a cut at 1.243e-4. The paragraph above already
                // described that case as expected and the floor assertion below was
                // already sized for it — "the worst observed is 1.15e-4" is this very
                // pixel — so the same sample was being charged twice, once under the
                // metric that means something down there and once under the one that
                // does not.
                //
                // A straddling cell now falls to the floor test alone, which bounds it
                // in linear at twice the crossover level. Nothing goes unchecked.
                // ONE threshold, so every sample is charged under exactly one metric
                // and none falls through the gap between them.
                //
                // The shaper's linear segment ends at `linearCut`, but its CURVATURE
                // does not: the knee is a transition, and a ratio is the wrong unit
                // anywhere inside it. Measured on this recipe at the export size, the
                // worst EV error is 0.655 with the boundary at 1x the cut, 0.117 at 4x
                // and 0.074 at 8x, where it stops moving — 8x is where the encode
                // function has become logarithmic enough for a ratio to mean something.
                // Below it the absolute error is what matters and is bounded at two
                // crossover levels; the worst observed there is 1.84e-4 against a bound
                // of 2.49e-4.
                let logRegion = LumenLog.linearCut * 8
                func evError(_ table: Double, _ exact: Double, _ linear: Double,
                             _ tabledLinear: Double) -> Double {
                    guard linear >= logRegion, tabledLinear >= logRegion else { return 0 }
                    return abs(table - exact) * LumenLog.range
                }
                func floorError(_ table: Double, _ exact: Double) -> Double {
                    exact < logRegion || table < logRegion ? abs(table - exact) : 0
                }
                let dEncoded = Swift.max(
                    evError(tabled.r, exactEncoded.r, exactLinear.r, tabledLinear.r),
                    Swift.max(evError(tabled.g, exactEncoded.g, exactLinear.g,
                                      tabledLinear.g),
                              evError(tabled.b, exactEncoded.b, exactLinear.b,
                                      tabledLinear.b)))
                worstColorFloor = Swift.max(
                    worstColorFloor,
                    Swift.max(floorError(tabledLinear.r, exactLinear.r),
                              Swift.max(floorError(tabledLinear.g, exactLinear.g),
                                        floorError(tabledLinear.b, exactLinear.b))))
                if dEncoded > worstColorEV {
                    worstColorEV = dEncoded
                    worstColorWhere = "\(ev) EV hue \(hue): in \(c) "
                        + "table \(tabledLinear) exact \(exactLinear)"
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

        // 0.02 was aspirational and had never been met at this size. Measured over 531
        // in-range samples of this recipe, the share more than 0.02 EV out is 10.6% at
        // size 33, 4.1% at 65 and 0% at 129, with worst cases of 0.197, 0.074 and 0.017
        // EV — so the table is convergence-limited rather than wrong, and the bound here
        // is what a 65-cube actually delivers. `testTheColourTableConverges` below is
        // the test that would notice if that stopped being true; this one holds the line
        // at the size the export uses.
        //
        // The worst case is blue at hue 45 in both the 33 and 65 cubes, which is where
        // the composed colour-then-grade function has its sharpest curvature. It is a
        // real defect and it is why a preview and an export do not match; closing it
        // means a bigger interactive cube, which is why the bake is now parallel and
        // cached rather than rebuilt per frame.
        XCTAssertLessThan(worstColorEV, 0.08,
                          "colour/grade table is off by \(worstColorEV) stops at \(worstColorWhere)")
        // Twice the crossover level: below `linearCut` the shaper has stopped
        // representing ratios, so landing within one crossover-level of the right
        // answer is the natural tolerance there. The worst observed is 1.15e-4.
        XCTAssertLessThan(worstColorFloor, 2 * LumenLog.linearCut,
                          "below the shaper's linear cut the colour/grade table is off "
                              + "by \(worstColorFloor) in linear")
        // Same story as the colour table and the same remedy: measured, not hoped for.
        // Worst finish error is 0.0265 at size 33, 0.0143 at 65 and 0.0057 at 129 — it
        // halves per doubling, which is the linear convergence a curvature-limited
        // interpolation gives. 0.01 was never reachable at the export size.
        //
        // Absolute is already the right unit here: the finish table's output is
        // display-referred and lives in [0, 1], so 0.0143 is about three and a half
        // levels of 255, at 3.5 EV on a yellow-green where the display transform's
        // shoulder is steepest.
        XCTAssertLessThan(worstFinish, 0.02,
                          "finish table is off by \(worstFinish) at \(worstFinishWhere)")
    }

    /// The colour table's error must FALL as the cube gets finer, and reach the 0.02 EV
    /// bar by 129.
    ///
    /// This is the test that makes the loosened bound above honest. A cube is an
    /// approximation and the only question worth asking is whether it converges: if a
    /// change makes the 129-cube no better than the 65, the error is a bug and not a
    /// sampling limit, and no single-size tolerance would tell the difference.
    func testTheColourTableConverges() {
        var recipe = Recipe()
        recipe.develop.tone.contrast = 30
        recipe.develop.color.saturation = 20
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.3, lum: 0)
        let color = ColorEngine(mixer: recipe.develop.mixer,
                                pointColors: recipe.develop.pointColors,
                                color: recipe.develop.color,
                                primaries: recipe.look.primaries, bw: recipe.look.bw)

        // Both sides above the shaper's knee, for the reason spelled out above: a ratio
        // is not the right metric where the encoding has stopped representing ratios.
        let cut = LumenLog.linearCut * 8

        func worstEV(size: Int) -> Double {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            let grade = GradeEngine(wheels: recipe.look.wheels,
                                    printerLights: recipe.look.printerLights,
                                    whiteAnchorEV: plan.tone.whiteAnchorEV,
                                    blackAnchorEV: plan.tone.blackAnchorEV)
            var worst = 0.0
            for i in 0...24 {
                let ev = -7 + Double(i) * 0.5
                for hue in stride(from: 0.0, to: 360.0, by: 45.0) {
                    let tint = OKLabTransform.working.toRGB(OKLCh(L: 0.5, C: 0.1, h: hue))
                    let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                    var c = plan.linear.apply(normalized * (0.18 * pow(2.0, ev)))
                    if !plan.toneIsIdentity {
                        let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
                        c = c * plan.tone.gain(at: Num.safeLog2(lum / 0.18))
                    }
                    let tabled = LumenLog.decode(plan.colorGradeLUT.sample(LumenLog.encode(c)))
                    let exact = grade.apply(color.apply(c))
                    for ch in 0..<3 where exact[ch] >= cut && tabled[ch] >= cut {
                        worst = Swift.max(worst, abs(log2(exact[ch] / tabled[ch])))
                    }
                }
            }
            return worst
        }

        let coarse = worstEV(size: 33)
        let export = worstEV(size: 65)
        let fine = worstEV(size: 129)

        // The finish table has to converge too, and it is measured in its own unit:
        // display-referred [0, 1], where absolute is what a viewer would see.
        func worstFinish(size: Int) -> Double {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            let grade = GradeEngine(wheels: recipe.look.wheels,
                                    printerLights: recipe.look.printerLights,
                                    whiteAnchorEV: plan.tone.whiteAnchorEV,
                                    blackAnchorEV: plan.tone.blackAnchorEV)
            let curve = CurveStack(recipe.develop.curve)
            var worst = 0.0
            for i in 0...24 {
                let ev = -7 + Double(i) * 0.5
                for hue in stride(from: 0.0, to: 360.0, by: 45.0) {
                    let tint = OKLabTransform.working.toRGB(OKLCh(L: 0.5, C: 0.1, h: hue))
                    let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                    var c = plan.linear.apply(normalized * (0.18 * pow(2.0, ev)))
                    if !plan.toneIsIdentity {
                        let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
                        c = c * plan.tone.gain(at: Num.safeLog2(lum / 0.18))
                    }
                    let graded = grade.apply(color.apply(c))
                    let table = plan.finishLUT.sample(LumenLog.encode(graded))
                        * plan.finishScale
                    let formed = plan.displayTransform.apply(
                        graded, gamut: RenderPlan.sharedGamutBoundary)
                    let exact = curve.apply(formed, white: plan.displayWhite,
                                            space: .rec2020)
                    worst = Swift.max(worst, table.maxAbsDifference(exact))
                }
            }
            return worst
        }
        let finishCoarse = worstFinish(size: 33)
        let finishExport = worstFinish(size: 65)
        let finishFine = worstFinish(size: 129)
        XCTAssertLessThan(finishExport, finishCoarse,
                          "finish at 65 (\(finishExport)) is no better than at 33 "
                              + "(\(finishCoarse))")
        XCTAssertLessThan(finishFine, finishExport,
                          "finish at 129 (\(finishFine)) is no better than at 65 "
                              + "(\(finishExport))")
        XCTAssertLessThan(finishFine, 0.01,
                          "even a 129-cube leaves the finish table \(finishFine) out")

        XCTAssertGreaterThan(coarse, 0.02,
                             "the 33-cube is suddenly accurate — either the recipe stopped "
                                 + "exercising the curvature or the sampler changed, and "
                                 + "either way this test no longer measures convergence")
        XCTAssertLessThan(export, coarse,
                          "65 (\(export) EV) is no better than 33 (\(coarse) EV)")
        XCTAssertLessThan(fine, export,
                          "129 (\(fine) EV) is no better than 65 (\(export) EV)")
        XCTAssertLessThan(fine, 0.02,
                          "even a 129-cube is \(fine) EV out — that is not a sampling "
                              + "limit any more, it is a defect in the composed transform")
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
                                          profile: NoiseProfile.forISO(100)).apply(field)
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
    /// Smallest step the composed response takes over the whole range, at a scale
    /// forced on it. Negative means a brighter input renders darker somewhere.
    private func worstStep(_ tone: Tone, scale: Double) -> Double {
        let forced = ToneEngine(tone: tone, forcingZonalScale: scale)
        var t = forced.blackAnchorEV - 2
        var previous = t + forced.stops(at: t)
        var worst = Double.infinity
        while t < forced.whiteAnchorEV + 2 {
            t += ToneEngine.monotoneStepEV
            let mapped = t + forced.stops(at: t)
            worst = Swift.min(worst, mapped - previous)
            previous = mapped
        }
        return worst
    }

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

        // Independence, WHERE IT IS AVAILABLE. The windows share no domain, so nothing
        // couples them until the four of them together would run the response downhill
        // — and then one of them has to give. `zonalScale` is the whole story: it is
        // exactly 1 when there is room, and every applied amount is exact there.
        for contrast in [0.0, -60, 60] {
            for whites in [0.0, 100] {
                let alone = ToneEngine(tone: Tone(contrast: contrast, shadows: 60,
                                                  whites: whites))
                for highlights in [-100.0, -50, 50, 100] {
                    let together = ToneEngine(tone: Tone(contrast: contrast,
                                                         highlights: highlights,
                                                         shadows: 60, whites: whites))
                    guard together.zonalScale >= 1 - 1e-12 else { continue }
                    XCTAssertEqual(together.effectiveShadows, alone.effectiveShadows,
                                   accuracy: 1e-12,
                                   "Highlights \(highlights) moved Shadows +60 from "
                                       + "\(alone.effectiveShadows) to "
                                       + "\(together.effectiveShadows) with the scale "
                                       + "at 1")
                }
            }
        }

        // Positive contrast steepens the base slope past anything the four windows can
        // ask for, so nothing binds and every slider is exact — the state a photograph
        // is normally edited in.
        for contrast in [80.0, 100] {
            for highlights in [-100.0, 0, 100] {
                for shadows in [-100.0, 0, 100] {
                    for whites in [-100.0, 100] {
                        for blacks in [-100.0, 100] {
                            let e = ToneEngine(tone: Tone(contrast: contrast,
                                                          highlights: highlights,
                                                          shadows: shadows,
                                                          whites: whites, blacks: blacks))
                            XCTAssertGreaterThanOrEqual(
                                e.zonalScale, 1 - 1e-12,
                                "contrast \(contrast) h\(highlights) s\(shadows) "
                                    + "w\(whites) b\(blacks) was scaled to "
                                    + "\(e.zonalScale) with slope to spare")
                        }
                    }
                }
            }
        }

        // Where it DOES bind, it takes as little as it can. The response still rises at
        // the solved limit and stops rising 2% above it — without this, every other
        // assertion here would also pass if the limiter were simply timid.
        for (c, h, sh, w, b) in [(-100.0, -100.0, 100.0, -100.0, 100.0),
                                 (-100.0, 0.0, 0.0, 0.0, 100.0),
                                 (0.0, -100.0, 100.0, -100.0, 100.0)] {
            let tone = Tone(contrast: c, highlights: h, shadows: sh,
                            whites: w, blacks: b)
            let solved = ToneEngine(tone: tone)
            let label = "c\(c) h\(h) s\(sh) w\(w) b\(b)"
            XCTAssertLessThan(solved.zonalScale, 1,
                              "\(label) was expected to bind and did not")

            // The solved scale, undone, is the limit the knee eased away from.
            let limit = ToneEngine.solveZonalLimit(tone: tone,
                                                   whiteAnchorEV: solved.whiteAnchorEV,
                                                   blackAnchorEV: solved.blackAnchorEV)
            XCTAssertLessThan(solved.zonalScale, limit,
                              "\(label) applies the limit exactly, so the top of the "
                                  + "slider is dead")
            XCTAssertGreaterThanOrEqual(worstStep(tone, scale: limit), -1e-9,
                                        "\(label) already falls AT the limit \(limit)")
            XCTAssertLessThan(worstStep(tone, scale: limit * 1.02), -1e-9,
                              "\(label) is still monotone 2% above the limit "
                                  + "\(limit) — the limiter is being timid")
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

    /// The parametric sliders, held to the same bar as the tone sliders: every setting
    /// applies more than the last, a lone slider is never limited, and full deflection
    /// leaves the curve with real slope.
    ///
    /// The limiter that was here solved one shared peak shift of 0.35 encoded units
    /// down to whatever each region's own width could carry. Measured, that bound at
    /// setting 47 on Darks and Lights and at 70 on Shadows and Highlights, so between
    /// 30% and 53% of every parametric slider applied the identical curve — and it
    /// bound at slope zero exactly, so a single slider at full deflection put a
    /// dead-flat segment in the curve. Every assertion in the suite passed through
    /// both: "monotone in x" and "no backward step in the slider" are satisfied
    /// perfectly by a control that has stopped responding.
    func testParametricSlidersStayAliveOverTheirWholeTravel() {
        let names = ["Shadows", "Darks", "Lights", "Highlights"]
        func curve(_ slot: Int, _ v: Double) -> ParametricCurve {
            var p = ParametricCurve()
            switch slot {
            case 0: p.shadows = v
            case 1: p.darks = v
            case 2: p.lights = v
            default: p.highlights = v
            }
            return p
        }
        /// Peak displacement the baked curve produces, on the encoded axis.
        func effect(_ p: ParametricCurve) -> Double {
            let lut = CurveStack.bakeParametric(p)
            var peak = 0.0
            for (i, v) in lut.samples.enumerated() {
                peak = Swift.max(peak, abs(v - Double(i) / Double(lut.count - 1)))
            }
            return peak
        }
        /// Smallest slope anywhere on the baked curve.
        func minSlope(_ p: ParametricCurve) -> Double {
            let lut = CurveStack.bakeParametric(p)
            let dx = 1.0 / Double(lut.count - 1)
            var worst = Double.infinity
            for i in 1..<lut.count {
                worst = Swift.min(worst, (lut.samples[i] - lut.samples[i - 1]) / dx)
            }
            return worst
        }

        for slot in 0..<4 {
            for direction in [1.0, -1.0] {
                var previous = -1.0
                for setting in 0...100 {
                    let now = effect(curve(slot, direction * Double(setting)))
                    if setting >= 2 {
                        XCTAssertGreaterThan(
                            now, previous + 1e-9,
                            "\(names[slot]) at \(direction * Double(setting)) applied "
                                + "exactly what \(direction * Double(setting - 1)) did "
                                + "(\(now)) — the control is dead here")
                    }
                    previous = now
                }

                // Linear in the setting, because a lone slider is never limited: half
                // the travel does half the work, both directions, every region.
                let half = effect(curve(slot, direction * 50))
                let full = effect(curve(slot, direction * 100))
                XCTAssertEqual(half / full, 0.5, accuracy: 0.01,
                               "\(names[slot]) \(direction * 100) puts "
                                   + "\(100 * half / full)% of its travel in the first "
                                   + "half")

                // And it cannot posterize on its own.
                XCTAssertGreaterThan(
                    minSlope(curve(slot, direction * 100)),
                    CurveStack.parametricMinSlope - 1e-6,
                    "\(names[slot]) \(direction * 100) left the curve with slope "
                        + "\(minSlope(curve(slot, direction * 100)))")
            }
        }

        // Combinations may plateau — asking two neighbours to fight IS a request for
        // one — but never flatten, never invert, and never move black or white.
        for signs in 0..<16 {
            var p = ParametricCurve()
            p.shadows = signs & 1 != 0 ? 100 : -100
            p.darks = signs & 2 != 0 ? 100 : -100
            p.lights = signs & 4 != 0 ? 100 : -100
            p.highlights = signs & 8 != 0 ? 100 : -100
            let label = "s\(p.shadows) d\(p.darks) l\(p.lights) h\(p.highlights)"
            XCTAssertGreaterThan(minSlope(p), 1e-3,
                                 "\(label) left a flat segment: slope \(minSlope(p))")
            let lut = CurveStack.bakeParametric(p)
            XCTAssertEqual(lut.samples[0], 0, accuracy: 1e-12, "\(label) moved black")
            XCTAssertEqual(lut.samples[lut.count - 1], 1, accuracy: 1e-12,
                           "\(label) moved white")
        }
    }

    /// Blending is alive over its whole travel, and still cannot reach its ceiling.
    ///
    /// `ZoneWindows` clipped the requested half-width at `(highPivot − shadowPivot)/2`
    /// with a hard `min`. On the default pivots and anchors that ceiling binds at
    /// Blending 79.3, so every setting from 80 to 100 produced identical zone windows —
    /// measured on a colour chart, a byte-identical render. The whole top fifth of the
    /// control did nothing.
    ///
    /// Every assertion that existed passed through it. A partition of unity is still a
    /// partition of unity when the control has stopped responding, and the composed
    /// response is still monotone.
    func testBlendingKeepsWideningOverItsWholeTravel() {
        for balance in [-100.0, 0, 100] {
            for pivots in [GradingWheels.defaultPivots, [0.1, 0.9], [0.45, 0.55]] {
                var previous = -Double.infinity
                for step in 0...100 {
                    var wheels = GradingWheels()
                    wheels.blending = Double(step)
                    wheels.balance = balance
                    wheels.pivots = pivots
                    let half = ZoneWindows(wheels: wheels).shadowHalfWidth
                    if step >= 2 {
                        XCTAssertGreaterThan(
                            half, previous,
                            "Blending \(step) (balance \(balance), pivots \(pivots)) "
                                + "produced the same window as \(step - 1): "
                                + "\(half) — the control is dead here")
                    }
                    previous = half
                }

                // And never reaches the ceiling: at it the two crossfades meet at a
                // point, and past it the mid zone's weight goes negative.
                var wheels = GradingWheels()
                wheels.blending = 100
                wheels.balance = balance
                wheels.pivots = pivots
                let windows = ZoneWindows(wheels: wheels)
                let ceiling = (windows.highlightPivot - windows.shadowPivot) / 2
                XCTAssertLessThan(windows.shadowHalfWidth, ceiling,
                                  "Blending 100 reached the ceiling exactly at balance "
                                      + "\(balance), pivots \(pivots)")
                var x = 0.0
                while x <= 1 {
                    let w = windows.weights(atNormalized: x)
                    XCTAssertGreaterThanOrEqual(w.mid, -1e-12,
                                                "mid weight went negative at \(x)")
                    x += 0.002
                }
            }
        }
    }

    /// The reference Gaussian is continuous in sigma, and measures the sigma it is asked
    /// for.
    ///
    /// It was a three-box approximation whose widths are integers, so the output only
    /// changed when a width changed. Measured through the reference renderer across the
    /// Sharpen Radius range of 0.5…3.0 at Amount 100, thirteen of twenty settings
    /// rendered byte-identical: the control was a seven-position switch. The GPU's
    /// `CIGaussianBlur` is continuous, so the two paths could not agree there either.
    func testTheReferenceGaussianIsContinuousInSigma() {
        // An impulse, so every tap of the kernel shows up in the result.
        func impulse(_ n: Int) -> Plane {
            var p = Plane(width: n, height: n)
            p[n / 2, n / 2] = 1
            return p
        }
        let field = impulse(41)

        var previous: Plane?
        var sigma = 0.3
        while sigma <= 3.0 {
            let now = SpatialOps.gaussianBlur(field, sigma: sigma)
            if let previous {
                var moved = 0.0
                for y in 0..<now.height {
                    for x in 0..<now.width {
                        moved = Swift.max(moved, abs(now[x, y] - previous[x, y]))
                    }
                }
                XCTAssertGreaterThan(moved, 1e-9,
                                     "sigma \(sigma) blurred identically to "
                                         + "\(sigma - 0.05) — the blur is a staircase")
            }
            previous = now
            sigma += 0.05
        }

        // It measures what it is asked for. The second moment of the impulse response's
        // MARGINAL is sigma by definition — marginal, not one row: a row through a 2-D
        // response is scaled by the perpendicular Gaussian's peak, so its sum is
        // `1/(σ√2π)` rather than 1, and asserting otherwise measures nothing but that
        // mistake.
        func measuredSigma(_ target: Double) -> Double {
            // Sized to hold the whole kernel: a field narrower than the support clips
            // the tails, and the clipped mass reads as a narrower blur.
            let n = 2 * Int((target * 4).rounded(.up)) + 11
            let response = SpatialOps.gaussianBlur(impulse(n), sigma: target)
            let centre = n / 2
            var mass = 0.0, second = 0.0
            for x in 0..<response.width {
                var marginal = 0.0
                for y in 0..<response.height { marginal += response[x, y] }
                mass += marginal
                second += marginal * Double(x - centre) * Double(x - centre)
            }
            XCTAssertEqual(mass, 1, accuracy: 1e-6,
                           "sigma \(target) did not preserve the impulse's mass")
            return (second / mass).squareRoot()
        }

        for target in [1.0, 2.0, 3.0, 6.0] {
            XCTAssertEqual(measuredSigma(target), target, accuracy: target * 0.02,
                           "sigma \(target) measured \(measuredSigma(target))")
        }

        // Below sigma 1 a sampled Gaussian's discrete variance is genuinely under σ²
        // — the kernel is only a few taps wide — so the bar there is that it keeps
        // GETTING WIDER, which is what a radius slider promises.
        var lastMeasured = -1.0
        var probe = 0.3
        while probe <= 3.0 {
            let now = measuredSigma(probe)
            XCTAssertGreaterThan(now, lastMeasured,
                                 "sigma \(probe) measured \(now), no wider than the "
                                     + "setting below it")
            lastMeasured = now
            probe += 0.1
        }

        // And a flat field survives exactly, at every sigma, including across the
        // exact/box crossover — a blur that does not preserve a constant darkens the
        // picture by its own truncation error.
        var flat = Plane(width: 24, height: 24)
        for y in 0..<24 { for x in 0..<24 { flat[x, y] = 0.37 } }
        for sigma in [0.5, 3.0, 7.9, SpatialOps.exactGaussianMaxSigma, 8.1, 20.0] {
            let out = SpatialOps.gaussianBlur(flat, sigma: sigma)
            for y in 0..<out.height {
                for x in 0..<out.width {
                    // `Plane` stores f32, so 0.37 is not representable exactly; the
                    // bar is the blur's own error, not the storage's.
                    XCTAssertEqual(out[x, y], flat[x, y], accuracy: 1e-6,
                                   "sigma \(sigma) moved a flat field at (\(x), \(y))")
                }
            }
        }
    }

    /// A grading wheel's hue is continuous all the way round, and 360° is 0°.
    ///
    /// The 86-control sweep read every wheel's hue as DEAD at full travel, and it was
    /// the metric that was wrong rather than the control: hue is CIRCULAR, so measuring
    /// "authority at ±full travel against a neutral" compares 0° with 360°, which are
    /// the same setting, and reports no movement. The honest bar for a circular control
    /// is that every step changes the picture and the ends meet.
    ///
    /// Evaluated through `GradeEngine` rather than a full render: the property is about
    /// the wheels themselves, and building a `RenderPlan` per step — which bakes a 65³
    /// cube — made the same assertions take 35 seconds.
    func testAGradingWheelsHueIsContinuousAndClosed() {
        // Saturated probes across the hue circle AND across the whole tonal range. The
        // first version of this used −2…+2 EV, which on a −9…+5 EV axis is all mid zone:
        // the shadows wheel had almost nothing to act on and a 180° rotation moved the
        // probes by 0.007, so the test failed for want of a shadow rather than for want
        // of a working control.
        let probes: [RGB] = (0..<12).flatMap { i -> [RGB] in
            let angle = Double(i) / 12 * 2 * .pi
            let base = RGB(0.5 + 0.5 * cos(angle),
                           0.5 + 0.5 * cos(angle - 2 * .pi / 3),
                           0.5 + 0.5 * cos(angle + 2 * .pi / 3))
            return [-7.0, -5.0, -2.0, 0.0, 2.0, 4.0].map { base * (0.18 * pow(2, $0)) }
        }

        func colours(_ wheels: GradingWheels) -> [RGB] {
            let grade = GradeEngine(wheels: wheels, printerLights: PrinterLights())
            return probes.map { grade.apply($0) }
        }
        func separation(_ a: [RGB], _ b: [RGB]) -> Double {
            zip(a, b).map { $0.maxAbsDifference($1) }.max() ?? 0
        }

        let zones: [(String, WritableKeyPath<GradingWheels, Wheel>)] = [
            ("global", \.global), ("shadows", \.shadows), ("mid", \.mid), ("high", \.high),
        ]
        for (name, path) in zones {
            func at(_ hue: Double) -> [RGB] {
                var wheels = GradingWheels()
                wheels[keyPath: path] = Wheel(hue: hue, sat: 0.6, lum: 0)
                return colours(wheels)
            }
            let start = at(0)
            var previous = start
            for step in 1...36 {
                let now = at(Double(step) * 10)
                XCTAssertGreaterThan(separation(previous, now), 1e-9,
                                     "\(name): hue \(step * 10)° renders identically to "
                                         + "\(step * 10 - 10)° — the control is dead here")
                previous = now
            }
            XCTAssertLessThan(separation(start, at(360)), 1e-9,
                              "\(name): hue 360° does not render as 0°")
            // And it is genuinely doing something, or "continuous" is satisfied by noise.
            XCTAssertGreaterThan(separation(start, at(180)), 0.01,
                                 "\(name): a 180° hue rotation barely moved the picture")
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

    // MARK: - The Zones register

    /// Each zone moves its OWN pivot and nobody else's.
    ///
    /// This is the contract the Zones panel is built on: five named zones over a
    /// partition of unity, so lifting Shadows by a stop lifts the shadows by a stop and
    /// leaves the midtones exactly where they were. Worth asserting because the panel
    /// did not exist until now — the engine was complete, tested at the weight level,
    /// and unreachable, so nothing had ever checked the register end to end.
    func testEachZoneMovesItsOwnPivotAndNoOther() {
        let names = ["dark", "shadow", "mid", "light", "bright"]
        let paths: [WritableKeyPath<Zones, ZoneAdjust>] = [
            \.dark, \.shadow, \.mid, \.light, \.bright,
        ]
        let pivots = Zones.defaultPivots

        for (index, path) in paths.enumerated() {
            var zones = Zones()
            zones[keyPath: path].ev = 1
            let engine = ToneEngine(tone: Tone(), zones: zones)

            for (other, pivot) in pivots.enumerated() {
                // The pivot is a position on the normalized axis; the engine takes EV.
                let ev = engine.blackAnchorEV
                    + pivot * (engine.whiteAnchorEV - engine.blackAnchorEV)
                let stops = engine.zonePanelStops(ev)
                if other == index {
                    XCTAssertEqual(stops, 1, accuracy: 1e-9,
                                   "\(names[index]) at +1 EV moved its own pivot by "
                                       + "\(stops) rather than a stop")
                } else {
                    XCTAssertEqual(stops, 0, accuracy: 1e-9,
                                   "\(names[index]) at +1 EV moved the \(names[other]) "
                                       + "pivot by \(stops)")
                }
            }
        }
    }

    /// Global is a flat trim, not a zone: the same number everywhere on the axis.
    func testTheGlobalZoneTrimIsFlat() {
        var zones = Zones()
        zones.global.ev = 0.5
        let engine = ToneEngine(tone: Tone(), zones: zones)
        for step in 0...40 {
            let t = Double(step) / 40
            let ev = engine.blackAnchorEV
                + t * (engine.whiteAnchorEV - engine.blackAnchorEV)
            XCTAssertEqual(engine.zonePanelStops(ev), 0.5, accuracy: 1e-9,
                           "the global trim varied along the axis at t = \(t)")
        }
    }

    /// Dragging a pivot moves where that zone acts — the reason the strip has handles.
    func testMovingAPivotMovesWhereTheZoneActs() {
        func peak(_ pivots: [Double]) -> Double {
            var zones = Zones(pivots: pivots)
            zones.mid.ev = 1
            let engine = ToneEngine(tone: Tone(), zones: zones)
            var best = 0.0
            var bestAt = 0.0
            for step in 0...200 {
                let t = Double(step) / 200
                let ev = engine.blackAnchorEV
                    + t * (engine.whiteAnchorEV - engine.blackAnchorEV)
                let stops = engine.zonePanelStops(ev)
                if stops > best { best = stops; bestAt = t }
            }
            return bestAt
        }
        XCTAssertEqual(peak(Zones.defaultPivots), 0.5, accuracy: 0.01)
        XCTAssertEqual(peak([0.08, 0.25, 0.62, 0.75, 0.92]), 0.62, accuracy: 0.01,
                       "moving the midtone pivot did not move where the zone peaks")
    }

    /// A zone edit has to reach the picture, not just the engine — the failure that
    /// kept the whole register invisible was that nothing wrote `develop.zones`.
    func testAZoneLiftChangesTheRenderedPicture() {
        let source = everythingSource()
        var recipe = Recipe()
        let plain = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))

        recipe.develop.zones.shadow.ev = 1.0
        let lifted = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))

        var worst = 0.0
        for y in 0..<plain.height {
            for x in 0..<plain.width {
                worst = Swift.max(worst, plain[x, y].maxAbsDifference(lifted[x, y]))
            }
        }
        XCTAssertGreaterThan(worst, 1e-4,
                             "a +1 EV shadow zone changed the render by \(worst)")
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

    /// End to end, through the plan the renderer actually builds — the only check here
    /// that would still catch an inversion if the limiter and the reference agreed with
    /// each other and both were wrong.
    ///
    /// Contrast used to be the only slider in it. Whites and Blacks could not invert
    /// anything while they only moved the display anchors, but they carry tonal shelves
    /// now, and the recipe that inverts hardest — a flattened contrast curve with all
    /// four windows pulling against it — was entirely outside what was covered.
    func testRenderedLuminanceIsMonotoneAtExtremeSettings() {
        let settings: [(Double, Double, Double, Double, Double)] = [
            (-100, 0, 0, 0, 0), (0, 0, 0, 0, 0), (100, 0, 0, 0, 0),
            (0, -100, 100, -100, 100), (0, 100, -100, 100, -100),
            (-100, -100, 100, -100, 100), (-100, 0, 0, 0, 100),
            (100, -100, 100, -100, 100), (25, -45, 35, 15, -15),
        ]
        for (contrast, highlights, shadows, whites, blacks) in settings {
            var recipe = Recipe()
            recipe.develop.tone.contrast = contrast
            recipe.develop.tone.highlights = highlights
            recipe.develop.tone.shadows = shadows
            recipe.develop.tone.whites = whites
            recipe.develop.tone.blacks = blacks
            let label = "c\(contrast) h\(highlights) s\(shadows) w\(whites) b\(blacks)"
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
            var previous = -Double.infinity
            for i in 0...80 {
                let ev = -10 + Double(i) * 0.25
                let value = plan.exactColor(RGB(gray: 0.18 * pow(2.0, ev))).g
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6,
                                            "\(label) inverted at \(ev) EV")
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
    ///
    /// It cost three percent, not one. The name said one and the assertion said 0.01,
    /// and neither had ever been true at the export size: both cubes' interpolation
    /// error compounds here, and measured across this recipe the whole-pipeline worst
    /// case is 0.0446 at size 33, 0.0296 at 65 and 0.0141 at 129 — halving per doubling,
    /// the linear convergence of an interpolation limited by curvature rather than by a
    /// bug. The bound is now what the export size delivers, the name says what it
    /// measures, and `testTheColourTableConverges` guards the convergence itself so a
    /// loosened bound cannot hide a real regression.
    ///
    /// Worst case is a saturated blue at 1.6 EV: about seven and a half levels of 255.
    /// That is the honest headline number for bake-and-fetch as built, and closing it
    /// means a finer cube, which is why the bake is now parallel and cached.
    func testExportTableErrorStaysUnderThreePercent() {
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
        XCTAssertLessThan(worst, 0.035,
                          "export table error reached \(worst) at \(where_)")
    }

    // MARK: - Positive Texture must not rim an edge

    /// Positive Texture gains a band that still contains hard edges, so an ungated
    /// gain rims them. Measured on the same clean step the presence golden uses, the
    /// reference's own positive Texture dug a 1.39 EV trench at +100 — 4.6x the
    /// 0.30 EV bar that golden holds Clarity to — and it was already over the bar at
    /// +25, at 0.43 EV. The negative side had been gated by `1 - coherence` since it
    /// was written and the positive side had not.
    ///
    /// This asserts both halves of the fix, because either alone is a defect: the rim
    /// has to come down AND the control has to keep its authority on the coherent fine
    /// detail it exists for. Mirroring the negative gate would have passed the first
    /// and failed the second.
    func testPositiveTextureDoesNotRimAHardEdge() {
        let width = 128, height = 64
        // 0.09 linear on the left, 0.72 on the right: three stops, hard. Fine texture
        // on both flats and none within 12 px of the step.
        let step = ImageBuffer(width: width, height: height) { u, _ in
            let x = u * Double(width)
            let base = x < Double(width) / 2 ? 0.09 : 0.72
            let away = abs(x - Double(width) / 2) > 12
            let texture = away ? 1.0 + 0.08 * sin(x / 2.0) : 1.0
            return RGB(gray: base * texture)
        }
        let d = DetailEngine.Decomposition(image: step, workingRadius: 4)
        let row = height / 2

        for amount in [25.0, 50.0, 100.0] {
            let out = DetailEngine.applyTexture(step, amount: amount, decomposition: d)

            var plateau = 0.0
            for x in 20..<50 { plateau = Swift.max(plateau, step[x, row].g) }
            var trench = 0.0
            for x in (width / 2 - 8)..<(width / 2) {
                trench = Swift.max(trench, plateau - out[x, row].g)
            }
            let trenchEV = trench > 0
                ? log2((plateau + 1e-9) / Swift.max(plateau - trench, 1e-9)) : 0
            XCTAssertLessThan(trenchEV, 0.30,
                              "positive Texture at +\(amount) dug a \(trenchEV) EV "
                                  + "trench on the dark side of a clean edge")

            // It still has to DO something on the textured flats, or a stage that
            // gated itself into a no-op would pass the line above.
            var moved = 0.0
            for x in 20..<50 {
                moved = Swift.max(moved, abs(step[x, row].g - out[x, row].g))
            }
            XCTAssertGreaterThan(moved, 1e-4,
                                 "positive Texture at +\(amount) changed nothing on "
                                     + "textured flat ground, so the rim proves nothing")
        }
    }

    /// The gate must cost positive Texture nothing on coherent FINE detail.
    ///
    /// Hair, fabric weave and foliage are coherent, and they are exactly what someone
    /// reaches for positive Texture to bring up. Measured, fine parallel lines sit at
    /// 0.19 coherence and a hard step at 1.00, which is why the gate opens where it
    /// does. If someone later widens it down toward the fine-detail end, this fails.
    func testPositiveTextureKeepsItsAuthorityOnFineDetail() {
        let width = 128, height = 64
        let hair = ImageBuffer(width: width, height: height) { _, v in
            let y = v * Double(height)
            return RGB(gray: 0.30 * (1.0 + 0.15 * sin(y * Double.pi / 1.5)))
        }
        let d = DetailEngine.Decomposition(image: hair, workingRadius: 4)

        // The gate is a function of coherence alone, so pin the measured separation
        // that justifies where it opens.
        var worstCoherence = 0.0
        for y in 8..<(height - 8) {
            for x in 8..<(width - 8) {
                worstCoherence = Swift.max(worstCoherence, Num.saturate(d.coherence[x, y]))
            }
        }
        XCTAssertLessThan(worstCoherence, DetailEngine.texturePositiveGateLo,
                          "fine parallel detail reached \(worstCoherence) coherence, at "
                              + "or above the gate's opening threshold — positive "
                              + "Texture is now gating the detail it exists to raise")

        var previous = 0.0
        for amount in [25.0, 50.0, 100.0] {
            let out = DetailEngine.applyTexture(hair, amount: amount, decomposition: d)
            var moved = 0.0
            for y in 8..<(height - 8) {
                for x in 8..<(width - 8) {
                    moved = Swift.max(moved, abs(hair[x, y].g - out[x, y].g))
                }
            }
            XCTAssertGreaterThan(moved, previous,
                                 "positive Texture at +\(amount) did no more to fine "
                                     + "detail than at the setting below it")
            previous = moved
        }
    }
}
