// MaskingTests.swift
// The two mask behaviours this batch wired end to end: the whole-mask invert, and the
// local point curve's second tap after picture formation.
//
// Both are asserted in two halves, because "something moved" passes for a broken
// stage. Every test here says what the control did AND what the right answer was:
// the invert is checked against the complement of the folded stack (not merely
// "different"), and the local curve against the curve evaluated on the pixel the
// render would otherwise have produced (not merely "the picture changed").

import XCTest
@testable import LumenCore

final class MaskingTests: XCTestCase {

    // MARK: - Fixtures

    /// A hard-edged ellipse in the middle of the frame: alpha is exactly 1 inside and
    /// exactly 0 outside, so a test can name a pixel that is definitely masked and one
    /// that is definitely not.
    private func hardRadial(feather: Double = 0) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [0.5, 0.5]
        c.radii = [0.3, 0.3]
        c.rotation = 0
        c.feather = feather
        return c
    }

    /// A scene-referred ramp with structure, so tone and curve both have something to
    /// act on across the whole domain.
    private func source(width: Int = 40, height: Int = 28) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, v in
            let ev = -5 + u * 8
            let level = 0.18 * pow(2, ev)
            return RGB(level * (1 + 0.08 * sin(u * 31)),
                       level * (1 + 0.05 * cos(v * 23)),
                       level * (0.9 + 0.2 * v))
        }
    }

    // MARK: - Whole-mask invert

    func testWholeMaskInvertIsTheComplementOfTheFoldedStack() {
        var mask = Mask(name: "ellipse", components: [hardRadial(feather: 40)])
        let size = (width: 48, height: 32)

        let straight = MaskRaster.combine(mask: mask, size: size)
        mask.invert = true
        let flipped = MaskRaster.combine(mask: mask, size: size)

        // The test only means something if the mask is a mask. A stack that rasterized
        // to a constant would satisfy the complement identity trivially.
        var lowest = 1.0
        var highest = 0.0
        for i in 0..<straight.values.count {
            lowest = Swift.min(lowest, Double(straight.values[i]))
            highest = Swift.max(highest, Double(straight.values[i]))
        }
        XCTAssertLessThan(lowest, 0.01, "the test mask selects everything")
        XCTAssertGreaterThan(highest, 0.99, "the test mask selects nothing")

        for y in 0..<size.height {
            for x in 0..<size.width {
                XCTAssertEqual(Double(flipped[x, y]), 1 - Double(straight[x, y]),
                               accuracy: 1e-6,
                               "invert is not the complement at (\(x), \(y))")
            }
        }
    }

    /// The order the doc fixes: invert, THEN the refinement chain. The two orders are
    /// distinguishable exactly because Levels is not symmetric about 0.5, which is why
    /// this uses it as the probe.
    func testWholeMaskInvertRunsBeforeTheRefinementChain() {
        let size = (width: 48, height: 32)
        let raw = MaskRaster.combine(mask: Mask(components: [hardRadial(feather: 60)]),
                                     size: size)

        let remap = MaskRefine(levelsLo: 10, levelsHi: 90, levelsGamma: 2.5)
        var mask = Mask(invert: true, components: [hardRadial(feather: 60)])
        mask.refine = remap
        let out = MaskRaster.combine(mask: mask, size: size)

        var worstCorrect = 0.0
        var worstAgainstTheOtherOrder = 0.0
        for y in 0..<size.height {
            for x in 0..<size.width {
                let v = Double(raw[x, y])
                let invertedFirst = MaskRaster.levels(1 - v, lo: remap.levelsLo,
                                                      hi: remap.levelsHi,
                                                      gamma: remap.levelsGamma)
                let remappedFirst = 1 - MaskRaster.levels(v, lo: remap.levelsLo,
                                                          hi: remap.levelsHi,
                                                          gamma: remap.levelsGamma)
                worstCorrect = Swift.max(worstCorrect,
                                         abs(Double(out[x, y]) - invertedFirst))
                worstAgainstTheOtherOrder = Swift.max(worstAgainstTheOtherOrder,
                                                      abs(invertedFirst - remappedFirst))
            }
        }
        XCTAssertLessThan(worstCorrect, 1e-6,
                          "the chain did not run on the inverted alpha")
        // …and the two orders really are different here, so the assertion above is
        // discriminating rather than an identity that holds either way.
        XCTAssertGreaterThan(worstAgainstTheOtherOrder, 0.05,
                             "the probe cannot tell the two orders apart")
    }

    /// Control to pixel: the same mask, the same adjustment, and the invert toggle
    /// decides which half of the frame moves.
    func testWholeMaskInvertMovesTheComplementOfThePicture() {
        let image = source()
        let inside = (x: image.width / 2, y: image.height / 2)
        let corner = (x: 1, y: 1)

        var adjust = LocalAdjust()
        adjust.exposure = -1.5
        var recipe = Recipe()
        recipe.masks = [Mask(name: "subject", components: [hardRadial()], adjust: adjust)]

        let plain = ReferenceRenderer.render(image, plan: RenderPlan(recipe: Recipe()))
        let masked = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))
        recipe.masks[0].invert = true
        let inverted = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))

        // Uninverted: the middle darkens, the corner is untouched.
        XCTAssertLessThan(masked[inside.x, inside.y].g, plain[inside.x, inside.y].g - 0.05,
                          "the mask did not darken what it selects")
        XCTAssertEqual(masked[corner.x, corner.y].g, plain[corner.x, corner.y].g,
                       accuracy: 1e-9, "the mask leaked outside its ellipse")

        // Inverted: exactly the other way round, and by the same amount.
        XCTAssertEqual(inverted[inside.x, inside.y].g, plain[inside.x, inside.y].g,
                       accuracy: 1e-9, "inverting still darkened the ellipse")
        XCTAssertEqual(inverted[corner.x, corner.y].g, masked[inside.x, inside.y].g
                           / plain[inside.x, inside.y].g * plain[corner.x, corner.y].g,
                       accuracy: 0.02,
                       "the inverted mask did not apply the same exposure outside")
    }

    // MARK: - Local Whites and Blacks

    /// A mask carrying nothing but Whites, or nothing but Blacks, moves the picture.
    ///
    /// The mask panel said the opposite in so many words — "Whites and Blacks reshape
    /// where Highlights and Shadows act in this mask; on their own they do not move the
    /// picture, because a mask has no white point of its own" — and that was true of an
    /// engine two rewrites ago. `ToneEngine.zonalStops` gives each of them a SHELF,
    /// added because an anchor-only Whites measured 26.7 code values across its whole
    /// travel and Blacks 0.20, "a slider a photographer would call dead". A mask's
    /// sub-recipe goes through that same engine on both render paths, so the shelves
    /// come with it.
    ///
    /// Nothing covered local Whites or Blacks on either path, which is how a caption
    /// could go on describing a previous engine.
    ///
    /// Measured in STOPS, against the model's own numbers rather than against "it
    /// changed": `whiteToneEV` is 1.3 and `blackToneEV` is 2.2, so the bar is most of
    /// the shelf rather than an epsilon. And the SHAPE is asserted as well as the
    /// magnitude — mid-grey must not move, and neither slider may reach the other's end
    /// of the range — because a global lift would satisfy a bare "something moved" and
    /// would be a different, worse defect.
    func testAMasksWhitesAndBlacksMoveThePictureOnTheirOwn() {
        // A neutral ramp from −6 to +4 EV about mid-grey, one row: enough range to
        // contain both shelves and mid-grey between them.
        let width = 101
        func ev(_ x: Int) -> Double { -6 + 10 * Double(x) / Double(width - 1) }
        let ramp = ImageBuffer(width: width, height: 1) { u, _ in
            RGB(gray: 0.18 * pow(2, -6 + 10 * u))
        }
        let plan = RenderPlan(recipe: Recipe())

        /// The shift this mask applies at each step of the ramp, in stops. Straight
        /// through `applyLocalAdjust`, which is the stage the caption is about: the
        /// mask alpha and the display transform are not part of the claim, and putting
        /// them in the way would only dilute what is being measured.
        func shift(_ mutate: (inout LocalAdjust) -> Void) -> [Double] {
            var adjust = LocalAdjust()
            mutate(&adjust)
            let mask = Mask(name: "whole frame", components: [hardRadial()],
                            adjust: adjust)
            let out = ReferenceRenderer.applyLocalAdjust(ramp, mask: mask, plan: plan,
                                                         space: .rec2020)
            return (0..<width).map { x in
                let before = Swift.max(ramp[x, 0].g, 1e-12)
                let after = Swift.max(out[x, 0].g, 1e-12)
                return log2(after / before)
            }
        }

        let midGrey = width * 6 / 10          // ev(60) = 0.0
        XCTAssertEqual(ev(midGrey), 0, accuracy: 0.06, "the ramp's mid-grey moved")

        let whites = shift { $0.whites = 100 }
        let top = whites[width - 1]
        XCTAssertGreaterThan(top, 1.0,
                             "a mask with only Whites +100 lifted the top of its range "
                                 + "by \(top) stops; `ToneEngine.whiteToneEV` is 1.3 "
                                 + "and the panel used to say it moved nothing at all")
        XCTAssertEqual(whites[midGrey], 0, accuracy: 0.02,
                       "Whites moved mid-grey by \(whites[midGrey]) stops — it is a "
                           + "shelf at the top of the range, not a global lift")
        XCTAssertEqual(whites[0], 0, accuracy: 0.02,
                       "Whites moved the bottom of the range by \(whites[0]) stops")

        let blacks = shift { $0.blacks = -100 }
        let bottom = blacks[0]
        XCTAssertLessThan(bottom, -1.5,
                          "a mask with only Blacks −100 dropped the bottom of its range "
                              + "by \(bottom) stops; `ToneEngine.blackToneEV` is 2.2")
        XCTAssertEqual(blacks[midGrey], 0, accuracy: 0.02,
                       "Blacks moved mid-grey by \(blacks[midGrey]) stops")
        XCTAssertEqual(blacks[width - 1], 0, accuracy: 0.02,
                       "Blacks moved the top of the range by \(blacks[width - 1]) stops")

        // And the mask's Amount scales them, like every other local control: half a
        // mask is half the shelf, not half of somewhere else.
        var halved = Mask(name: "half", components: [hardRadial()])
        halved.amount = 50
        halved.adjust.whites = 100
        let half = ReferenceRenderer.applyLocalAdjust(ramp, mask: halved, plan: plan,
                                                      space: .rec2020)
        let halfTop = log2(Swift.max(half[width - 1, 0].g, 1e-12)
                               / Swift.max(ramp[width - 1, 0].g, 1e-12))
        XCTAssertLessThan(halfTop, top - 0.2,
                          "Amount 50 applied \(halfTop) stops against \(top) at full — "
                              + "the mask's Amount is not reaching the tone engine")
        XCTAssertGreaterThan(halfTop, 0.2,
                             "Amount 50 applied \(halfTop) stops, which is not half of "
                                 + "anything")
    }

    // MARK: - Where a mask's samples are taken from

    /// A colour mask has to select the pixel that was clicked.
    ///
    /// The eyedropper stored the WORKING image — the decode through the S6 matrix and
    /// nothing else. `colorRangePlane` and `similarityPlane` compare those stored
    /// samples against the LOCAL STAGE INPUT, which is S6 plus the tone stage plus the
    /// colour and grade table. On a recipe with any real global tone or colour work the
    /// two are different colours, the trapezoid gates are 0 outside their tolerance
    /// rather than merely small, and the mask misses the pixel the photographer
    /// pointed at — worse the more the picture has been worked on, which is the
    /// opposite of how a tool should degrade.
    ///
    /// Measured end to end, through `ReferenceRenderer.render`, so the stage input the
    /// mask is compared against is the renderer's own and not this test's idea of it:
    /// both masks carry a strong local exposure lift, and what is asserted is how far
    /// the clicked pixel moved. The value fed to each is the only difference.
    ///
    /// Measured on this frame at Refine 20 with Contrast 90 and Saturation 90: the
    /// clicked pixel moves 0.339 from the stage tap, 0.000 from the working tap, and a
    /// patch of a different colour moves 0.000 from either. Not "less selected" — the
    /// trapezoid gates return exactly zero outside their tolerance, so the mask misses
    /// completely.
    func testAColourMaskSelectsTheColourThatWasClicked() {
        let side = 32
        // Four flat patches of clearly different hue at similar luminance, so a colour
        // range has something to include and something to exclude.
        let image = ImageBuffer(width: side, height: side) { u, v in
            if v < 0.5 { return u < 0.5 ? RGB(0.34, 0.07, 0.05) : RGB(0.08, 0.30, 0.07) }
            return u < 0.5 ? RGB(0.06, 0.09, 0.34) : RGB(0.18, 0.18, 0.18)
        }
        let clicked = (x: side / 4, y: side / 4)          // in the red patch
        let elsewhere = (x: 3 * side / 4, y: 3 * side / 4) // in the neutral patch

        // An ordinary edit: contrast and saturation, neither of which is in the linear
        // stage. Exposure and white balance deliberately are not used here — they live
        // in the S6 matrix, so BOTH taps carry them and neither would show anything.
        var edited = Recipe()
        edited.develop.tone.contrast = 90
        edited.develop.color.saturation = 90
        let plan = RenderPlan(recipe: edited)

        // The two candidate samples.
        //
        // `working` is what `RenderCoordinator.sampleWorking` returns: the decoded
        // pixel through the linear stage. `staged` is the local stage input, built
        // here the way `ReferenceRenderer.render` builds it — S6, S7, then the
        // colour+grade table. There is no S8 in that list because this recipe sets no
        // presence, which is why three stages is the whole of it.
        let working = plan.linear.matrix.apply(image[clicked.x, clicked.y])
        var stagedImage = image.map { plan.linear.matrix.apply($0) }
        stagedImage = ReferenceRenderer.applyTone(stagedImage, plan: plan,
                                                  longEdge: side, space: .rec2020)
        let lut = plan.colorGradeLUT
        stagedImage = stagedImage.map { LumenLog.decode(lut.sample(LumenLog.encode($0))) }
        let staged = stagedImage[clicked.x, clicked.y]

        /// The picture with a colour-range mask built from `sample`, lifting two stops.
        func render(sample: RGB) -> ImageBuffer {
            var component = MaskComponent(op: .add, kind: .colorRange)
            component.samples = [[sample.r, sample.g, sample.b]]
            component.rangeAmount = 20
            var adjust = LocalAdjust()
            adjust.exposure = 2
            var recipe = edited
            recipe.masks = [Mask(name: "that colour", components: [component],
                                 adjust: adjust)]
            return ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))
        }

        let plain = ReferenceRenderer.render(image, plan: plan)
        let fromStage = render(sample: staged)
        let fromWorking = render(sample: working)

        func moved(_ out: ImageBuffer, _ at: (x: Int, y: Int)) -> Double {
            out[at.x, at.y].maxAbsDifference(plain[at.x, at.y])
        }

        let stageHit = moved(fromStage, clicked)
        let workingHit = moved(fromWorking, clicked)
        let stageMiss = moved(fromStage, elsewhere)

        // The tap the mask is compared against selects what was clicked.
        XCTAssertGreaterThan(stageHit, 0.05,
                             "a mask sampled from the local stage input moved the "
                                 + "clicked pixel by only \(stageHit) — it is not "
                                 + "selecting the colour it was given")
        // And still discriminates: a mask that selects the whole frame would pass the
        // assertion above and be useless.
        XCTAssertLessThan(stageMiss, stageHit / 10,
                          "the mask moved a different patch by \(stageMiss) against "
                              + "\(stageHit) at the clicked one — it is selecting most "
                              + "of the frame rather than a colour")
        // The tap the eyedropper used does not.
        XCTAssertLessThan(workingHit, stageHit / 3,
                          "a sample taken one stage short of the comparison still "
                              + "selected the clicked pixel: \(workingHit) against "
                              + "\(stageHit). Either the global edit here is too small "
                              + "to separate the two taps, or the two taps are the "
                              + "same image and this test is measuring nothing")
    }

    // MARK: - The local point curve

    private func lift() -> CurveSet {
        // A midtone lift, monotone and clearly not the identity.
        CurveSet(point: [[0, 0], [0.5, 0.72], [1, 1]])
    }

    func testLocalCurveIsIdentityUntilThereIsOneToApply() {
        let c = RGB(0.2, 0.3, 0.45)
        XCTAssertTrue(LocalCurve(curve: nil).isIdentity)
        XCTAssertTrue(LocalCurve(curve: CurveSet()).isIdentity,
                      "an untouched curve set is not the identity")
        XCTAssertTrue(LocalCurve(curve: lift(), amount: 0).isIdentity,
                      "Amount 0 still bakes a table")
        XCTAssertEqual(LocalCurve(curve: nil).apply(c), c)

        let live = LocalCurve(curve: lift())
        XCTAssertFalse(live.isIdentity)
        XCTAssertGreaterThan(live.apply(RGB(gray: 0.2)).g, 0.2 + 0.05,
                             "a midtone lift did not lift the midtones")
    }

    /// Amount scales the curve's DISPLACEMENT — the definition docs/08 gives for what a
    /// mask's Amount does to a non-slider control.
    func testLocalCurveAmountScalesTheDisplacement() {
        let c = RGB(gray: 0.2)
        let full = LocalCurve(curve: lift(), amount: 100).apply(c)
        let half = LocalCurve(curve: lift(), amount: 50).apply(c)
        let over = LocalCurve(curve: lift(), amount: 200).apply(c)

        XCTAssertGreaterThan(full.g - c.g, 0.05, "the probe curve barely moves")
        XCTAssertEqual(half.g - c.g, (full.g - c.g) / 2, accuracy: 1e-9,
                       "Amount 50 is not half the displacement")
        XCTAssertEqual(over.g - c.g, (full.g - c.g) * 2, accuracy: 1e-9,
                       "Amount 200 does not amplify past the curve")
    }

    /// The axis is normalized by display white, so the same curve means the same thing
    /// on an HDR rendition as it does on an SDR one.
    func testLocalCurveIsDenominatedAgainstDisplayWhite() {
        let sdr = LocalCurve(curve: lift(), white: 1)
        let hdr = LocalCurve(curve: lift(), white: 4)
        let c = RGB(gray: 0.2)
        XCTAssertEqual(hdr.apply(c * 4).g, sdr.apply(c).g * 4, accuracy: 1e-9,
                       "the local curve reads absolute code values, not picture values")
    }

    /// The whole trace, on the reference path: a curve stored on a mask reaches pixels,
    /// only inside the mask, and lands where the curve says it should.
    func testAMasksCurveIsAppliedToTheFormedPictureThroughItsAlpha() {
        let image = source()
        let inside = (x: image.width / 2, y: image.height / 2)
        let corner = (x: 1, y: 1)

        var recipe = Recipe()
        recipe.masks = [Mask(name: "subject", components: [hardRadial()])]
        let plan = RenderPlan(recipe: recipe)
        let plain = ReferenceRenderer.render(image, plan: plan)

        recipe.masks[0].adjust.curve = lift()
        let curvedPlan = RenderPlan(recipe: recipe)
        let curved = ReferenceRenderer.render(image, plan: curvedPlan)

        // It did something…
        XCTAssertGreaterThan(curved[inside.x, inside.y].g,
                             plain[inside.x, inside.y].g + 0.02,
                             "the mask's curve changed no pixel")
        // …only where the mask is…
        XCTAssertEqual(curved[corner.x, corner.y].g, plain[corner.x, corner.y].g,
                       accuracy: 1e-9, "the mask's curve leaked outside its alpha")
        // …and it is the curve, evaluated on the FORMED picture. If the tap moved into
        // the local stage this equality would fail, because the same curve applied to
        // scene-referred values then pushed through the display transform is a
        // different picture.
        //
        // The tolerance is f32 storage, not modelling slack: `ImageBuffer` is f32, so
        // the expectation is recomputed in f64 from an already-rounded pixel.
        let tap = LocalCurve(curve: recipe.masks[0].adjust.curve, amount: 100,
                             white: curvedPlan.displayWhite)
        var checked = 0
        for y in 0..<image.height {
            for x in 0..<image.width where plain[x, y] != curved[x, y] {
                let expected = tap.apply(plain[x, y])
                XCTAssertLessThan(expected.maxAbsDifference(curved[x, y]), 2e-6,
                                  "the masked curve is not the curve at (\(x), \(y))")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100,
                             "only \(checked) pixels moved — the mask barely selects")
    }

    /// A curve that is stored but untouched must not change the render — the guard that
    /// keeps a second full-frame table off every photograph that has a mask.
    func testAnUntouchedStoredCurveRendersIdentically() {
        let image = source()
        var recipe = Recipe()
        recipe.masks = [Mask(name: "subject", components: [hardRadial()])]
        let without = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))

        recipe.masks[0].adjust.curve = CurveSet()
        let with = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe))

        for y in 0..<image.height {
            for x in 0..<image.width {
                XCTAssertEqual(with[x, y].maxAbsDifference(without[x, y]), 0,
                               "an identity curve moved the picture at (\(x), \(y))")
            }
        }
    }

    // MARK: - Where a matte comes from

    /// The panel, the generator and the "requires a model" copy all read this one
    /// property, so it is the single place the roster can be wrong. Three kinds are
    /// served by Vision on the machine, four are waiting on a model, and the seven
    /// non-AI kinds need no matte at all.
    func testEveryKindAgreesAboutWhereItsMatteComesFrom() {
        let vision: Set<MaskKind> = [.aiSubject, .aiBackground, .aiPerson]
        let model: Set<MaskKind> = [.aiSky, .aiObject, .aiLandscape, .depthRange]

        for kind in [MaskKind.brush, .linear, .radial, .lumaRange, .colorRange,
                     .similarity, .similarityLine, .aiSubject, .aiSky, .aiBackground,
                     .aiObject, .aiPerson, .aiLandscape, .depthRange] {
            let expected: MaskKind.MatteProvider
            if vision.contains(kind) {
                expected = .vision
            } else if model.contains(kind) {
                expected = .model
            } else {
                expected = .none
            }
            XCTAssertEqual(kind.matteProvider, expected,
                           "\(kind.rawValue) claims the wrong matte source")
            // The older question has to stay consistent with the newer one, or the
            // panel and the rasterizer disagree about which kinds are waiting.
            XCTAssertEqual(kind.needsMatte, expected != .none,
                           "\(kind.rawValue): needsMatte and matteProvider disagree")
        }
    }

    /// Whatever the provider, a component whose matte is missing selects NOTHING — it
    /// never falls back to selecting everything, which is the failure that would ship a
    /// whole-frame adjustment as if it were a subject mask.
    func testAKindWaitingOnAMatteSelectsNothing() {
        for kind in [MaskKind.aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson,
                     .aiLandscape] {
            var component = MaskComponent(op: .add, kind: kind)
            component.prompt = [[0.5, 0.5]]      // so aiObject validates
            let alpha = MaskRaster.combine(mask: Mask(components: [component]),
                                           size: (width: 16, height: 12))
            XCTAssertEqual(alpha.range.max, 0, accuracy: 1e-12,
                           "\(kind.rawValue) selected something with no matte supplied")
        }
    }

    /// And when a matte IS supplied it is used, at whatever size the raster wants.
    func testASuppliedMatteReachesTheMask() {
        var matte = Plane(width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<4 { matte[x, y] = 1 }
        }
        let component = MaskComponent(op: .add, kind: .aiSubject)
        let alpha = MaskRaster.combine(mask: Mask(components: [component]),
                                       size: (width: 32, height: 32),
                                       aiMattes: [MaskKind.aiSubject.rawValue: matte])
        XCTAssertGreaterThan(alpha[2, 16], 0.99, "the matte's left half did not select")
        XCTAssertLessThan(alpha[29, 16], 0.01, "the matte's right half selected anyway")
    }

    // MARK: - Overlays

    /// Each of the six modes has to do the one thing its name promises, at both ends
    /// of the alpha range. Asserting only "the modes differ" would pass for six
    /// permutations of the wrong rule.
    func testEverySixOverlayModeDrawsWhatItsNameSays() {
        let picture = RGB(0.80, 0.20, 0.20)     // a saturated red, so B&W is visible
        let tint = MaskOverlay.Tint.green
        func at(_ mode: MaskOverlay.Mode, _ alpha: Double) -> RGB {
            MaskOverlay.composite(picture: picture, alpha: alpha, mode: mode,
                                  tint: tint, strength: 1)
        }
        let grey = at(.imageOnBW, 0)
        // `mix` at t = 1 is `a + (b − a)`, which is b to within an ulp and not bitwise.
        func same(_ got: RGB, _ want: RGB, _ message: String) {
            XCTAssertLessThan(got.maxAbsDifference(want), 1e-12, message)
        }

        // Outside the mask.
        same(at(.colorOverlay, 0), picture, "Colour Overlay tinted an unmasked pixel")
        same(at(.colorOnBW, 0), grey, "Colour on B&W left an unmasked pixel in colour")
        same(at(.imageOnBW, 0), grey, "Image on B&W left an unmasked pixel in colour")
        same(at(.imageOnBlack, 0), RGB.zero, "Image on Black is not black outside")
        same(at(.imageOnWhite, 0), RGB.one, "Image on White is not white outside")
        same(at(.matte, 0), RGB.zero, "the Matte's unselected ground is not black")

        // Inside it.
        same(at(.colorOverlay, 1), tint.colour, "Colour Overlay did not tint")
        same(at(.colorOnBW, 1), tint.colour, "Colour on B&W did not tint")
        same(at(.imageOnBW, 1), picture, "Image on B&W did not show the image")
        same(at(.imageOnBlack, 1), picture, "Image on Black did not show the image")
        same(at(.imageOnWhite, 1), picture, "Image on White did not show the image")
        same(at(.matte, 1), RGB.one, "the Matte's selected ground is not white")

        // The greyscale really is a desaturation of THIS pixel, not a constant.
        XCTAssertEqual(grey.r, grey.g, accuracy: 1e-12)
        XCTAssertGreaterThan(grey.r, 0.05)
        XCTAssertLessThan(grey.r, picture.r)

        // The matte is the ground truth: it reports density, and it does so whatever
        // the picture underneath is doing.
        XCTAssertEqual(MaskOverlay.composite(picture: RGB.one, alpha: 0.4, mode: .matte,
                                             tint: .red).g, 0.4, accuracy: 1e-12)
    }

    func testOverlayStrengthOnlyWeakensTheTwoTintedModes() {
        let picture = RGB(0.5, 0.4, 0.3)
        for mode in MaskOverlay.Mode.allCases {
            let full = MaskOverlay.composite(picture: picture, alpha: 1, mode: mode,
                                             tint: .red, strength: 1)
            let half = MaskOverlay.composite(picture: picture, alpha: 1, mode: mode,
                                             tint: .red, strength: 0.5)
            switch mode {
            case .colorOverlay, .colorOnBW:
                XCTAssertGreaterThan(full.maxAbsDifference(half), 0.05,
                                     "\(mode.label) ignored its strength")
            default:
                XCTAssertEqual(full.maxAbsDifference(half), 0,
                               "\(mode.label) was weakened by a strength it must ignore")
            }
        }
    }

    /// The two cycles are the keyboard grammar: `⌥O` walks all six and comes home,
    /// `⇧O` walks all four. A `next` that skipped or repeated would strand a mode.
    func testTheOverlayCyclesVisitEveryValueOnce() {
        var mode = MaskOverlay.Mode.colorOverlay
        var seenModes: [MaskOverlay.Mode] = []
        for _ in 0..<MaskOverlay.Mode.allCases.count {
            seenModes.append(mode)
            mode = mode.next
        }
        XCTAssertEqual(mode, .colorOverlay, "⌥O does not return to where it started")
        XCTAssertEqual(Set(seenModes).count, MaskOverlay.Mode.allCases.count,
                       "⌥O visits a mode twice and another never")

        var tint = MaskOverlay.Tint.red
        var seenTints: [MaskOverlay.Tint] = []
        for _ in 0..<MaskOverlay.Tint.allCases.count {
            seenTints.append(tint)
            tint = tint.next
        }
        XCTAssertEqual(tint, .red, "⇧O does not return to where it started")
        XCTAssertEqual(Set(seenTints).count, MaskOverlay.Tint.allCases.count,
                       "⇧O visits a colour twice and another never")
        XCTAssertEqual(seenTints, [.red, .green, .white, .black],
                       "the colour cycle is not docs/08's order")
    }

    /// Only the Matte can be drawn without the photograph. Getting this wrong is what
    /// makes an overlay paint a black frame while the sampler is still being built.
    func testOnlyTheMatteCanBeDrawnWithoutThePicture() {
        for mode in MaskOverlay.Mode.allCases {
            XCTAssertEqual(mode.readsPicture, mode != .matte,
                           "\(mode.label) disagrees about needing the picture")
        }
    }

    // MARK: - The format

    func testTheInvertFlagSurvivesTheWireFormat() throws {
        var recipe = Recipe()
        recipe.masks = [Mask(id: "c0000000-0000-0000-0000-0000000000f1",
                             name: "Sky", invert: true,
                             components: [hardRadial()],
                             adjust: LocalAdjust())]
        recipe.masks[0].adjust.curve = lift()

        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let back = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(back.masks.first?.invert, true, "the whole-mask invert was lost")
        XCTAssertEqual(back.masks.first?.adjust.curve, lift(),
                       "the local curve was lost")

        // Two masks that differ only by the invert flag render differently, so they
        // must not share a cache key.
        var straight = recipe
        straight.masks[0].invert = false
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(recipe),
                          try RecipeFingerprint.fingerprint(straight),
                          "inverting a mask did not change the render fingerprint")
    }

    /// A mask written before `invert` existed still loads, with the rest of it intact.
    ///
    /// Built by encoding a real mask and DELETING the key, rather than by hand-writing
    /// a document: a hand-written one tests whatever the author happened to type, and
    /// the thing that has to survive is the exact shape the previous encoder produced.
    func testAMaskWithoutTheInvertKeyStillDecodes() throws {
        var recipe = Recipe()
        var adjust = LocalAdjust()
        adjust.exposure = -0.5
        recipe.masks = [Mask(id: "a1", name: "Sky", invert: true,
                             components: [hardRadial()], adjust: adjust)]

        guard case .object(var root) = try CanonicalJSON.tree(of: recipe),
              case .array(let masks) = root["masks"] ?? .null,
              case .object(var first) = masks.first ?? .null
        else { return XCTFail("the recipe did not encode to the expected shape") }
        XCTAssertNotNil(first["invert"], "the flag is not in the wire format at all")
        first["invert"] = nil
        root["masks"] = .array([.object(first)])

        let older = CanonicalJSON.serialize(.object(root))
        let back = try CanonicalJSON.decodeRecipe(from: Data(older.utf8))
        XCTAssertEqual(back.masks.count, 1, "the mask array failed to decode")
        XCTAssertEqual(back.masks.first?.invert, false,
                       "an absent invert key did not default to off")
        XCTAssertEqual(back.masks.first?.adjust.exposure, -0.5,
                       "the rest of the mask decoded wrong")
        XCTAssertEqual(back.masks.first?.components.count, 1,
                       "the component stack was lost")
    }

    // MARK: - The blobs an export has to have (MASK-23)

    /// A brush component pointing at `ref`, or at nothing when `ref` is nil.
    private func brush(_ ref: String?, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .brush)
        c.strokesRef = ref
        return c
    }

    /// One enabled mask with two blobs and a component that reads no blob at all, one
    /// DISABLED mask with a blob of its own, and a second enabled mask that reuses the
    /// first blob and adds an unpainted component.
    private func brushRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.masks = [
            Mask(id: "m1", name: "Sky",
                 components: [brush("blob:a"), hardRadial(), brush("blob:b")]),
            Mask(id: "m2", name: "Off", enabled: false,
                 components: [brush("blob:c")]),
            Mask(id: "m3", name: "Foreground",
                 components: [brush(nil), brush("blob:a"), brush("")]),
        ]
        return recipe
    }

    /// What the export has to have in hand is exactly what the rasterizer will ask for.
    ///
    /// Three things, and each of them is a way of refusing a delivery for no reason or
    /// of delivering a wrong one: a switched-off mask paints nothing, so its blob is not
    /// required; a blob used twice is one read, not two; and a brush component nobody
    /// has painted into references no blob and must not be counted as a missing one.
    func testTheBlobsAnExportNeedsAreTheOnesTheRasterizerWillAskFor() {
        XCTAssertEqual(BrushStrokes.references(in: brushRecipe()), ["blob:a", "blob:b"],
                       "the required blob set is not the set the render will fetch")
        XCTAssertEqual(BrushStrokes.references(in: Recipe()), [],
                       "a recipe with no masks asked for a blob")
    }

    /// The distinction `strokesAreResolved` was written for and nothing used: "this
    /// component has no strokes" is not "the bytes could not be read". Only the second
    /// may stop a delivery.
    func testAnUnreadableBlobRefusesTheDeliveryAndAnUnpaintedComponentDoesNot() {
        let recipe = brushRecipe()

        var asked: [String] = []
        func resolver(failing: Set<String>) -> (MaskComponent) -> Bool {
            { component in
                let ref = component.strokesRef ?? ""
                asked.append(ref)
                return !failing.contains(ref)
            }
        }

        // Everything readable: nothing missing, nothing refused.
        asked = []
        XCTAssertEqual(
            BrushStrokes.unresolvedReferences(in: recipe, isResolved: resolver(failing: [])),
            [], "a readable blob was reported missing")
        XCTAssertNil(BrushStrokes.refusal(unresolved: []),
                     "a delivery was refused with nothing missing")
        XCTAssertEqual(asked, ["blob:a", "blob:b"],
                       "the unpainted components were put to the resolver")

        // One blob unreadable: that reference, and a refusal that says what happened.
        asked = []
        let missing = BrushStrokes.unresolvedReferences(
            in: recipe, isResolved: resolver(failing: ["blob:b"]))
        XCTAssertEqual(missing, ["blob:b"], "the unreadable blob was not reported")
        let refusal = BrushStrokes.refusal(unresolved: missing)
        XCTAssertNotNil(refusal, "an unreadable blob did not refuse the delivery")
        XCTAssertEqual(refusal?.contains("1 brush stroke set"), true,
                       "the refusal does not say how much masking is at risk: "
                           + (refusal ?? "nil"))

        // A blob only a SWITCHED-OFF mask needs must not stop anything: that mask paints
        // no pixels, so the delivered file is exactly what the photographer asked for.
        XCTAssertEqual(
            BrushStrokes.unresolvedReferences(in: recipe,
                                              isResolved: resolver(failing: ["blob:c"])),
            [], "a disabled mask's unreadable blob refused a correct delivery")

        // Both live blobs unreadable: counted, and pluralized, because the count is the
        // whole of what the photographer can act on.
        let both = BrushStrokes.unresolvedReferences(
            in: recipe, isResolved: resolver(failing: ["blob:a", "blob:b"]))
        XCTAssertEqual(both, ["blob:a", "blob:b"])
        XCTAssertEqual(BrushStrokes.refusal(unresolved: both)?.contains("2 brush stroke sets"),
                       true, "the refusal miscounted or did not pluralize")
    }
}
