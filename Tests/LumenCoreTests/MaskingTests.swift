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
}
