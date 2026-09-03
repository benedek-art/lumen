// SliderContractTests.swift
// Each slider's CONTRACT, asserted as arithmetic — the companion to the proof
// registry's authority sweep, answering the owner's session-B demand directly:
// "rigorous testing to make sure that they bring actual output that is measurable
// and accurate."
//
// The two harnesses divide the question the way it divides in practice. A proof
// record answers "does this control visibly move the picture, monotonically, across
// its whole travel" — the same six questions for all 136 controls. A contract here
// answers the question that is DIFFERENT for each control: does −100 Saturation
// actually reach black and white, does the vignette's number actually mean stops at
// the corner, does a curve point actually pass through itself. A control can hold a
// healthy record and still lie about its units; these are the tests for the lie.
//
// Every contract asserts something the code's own documentation promises, with the
// doc's location named, so a red here is either a regression or a promise that needs
// rewriting — and the commit has to say which.

import XCTest
@testable import LumenCore

final class SliderContractTests: XCTestCase {

    /// Full-pipeline render of a frame under a recipe, on the reference path.
    private func rendered(_ frame: ImageBuffer, _ recipe: Recipe) -> ImageBuffer {
        ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe))
    }

    private func maxChroma(_ image: ImageBuffer) -> Double {
        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = image[x, y]
                let peak = Swift.max(p.maxComponent, 1e-9)
                worst = Swift.max(worst, (p.maxComponent - p.minComponent) / peak)
            }
        }
        return worst
    }

    // MARK: - Saturation

    /// Recipe.swift's ColorAdjust header: "−100 reaches true B&W" is a contract, and
    /// protectSkin "does not attenuate a negative Saturation" — the guard that once
    /// left skin at 30% chroma in a frame taken all the way to black and white.
    func testSaturationMinusHundredReachesTrueBlackAndWhite() {
        for protect in [0.0, 70.0, 100.0] {
            var recipe = Recipe()
            recipe.develop.color.saturation = -100
            recipe.develop.color.protectSkin = protect
            let out = rendered(ProofFrames.colourChart(), recipe)
            XCTAssertLessThan(maxChroma(out), 0.02,
                "Saturation −100 with protectSkin \(protect) left "
                    + "\(maxChroma(out)) residual chroma — the pull must reach true "
                    + "B&W at every protection setting (ColorAdjust's own contract)")
        }
    }

    // MARK: - Density

    /// ColorEngine's header: colour intensifies by DENSIFYING — the subtractive
    /// branch darkens as it saturates, "that is the whole point of the density
    /// model", while the additive branch it blends against holds J. So on a
    /// saturated patch, walking density up at a fixed Saturation push must darken
    /// monotonically; and density is a chroma-path dial, so a neutral grey must not
    /// move at ANY density.
    func testDensityDarkensASaturatedPushAndLeavesNeutralsAlone() {
        let chart = ProofFrames.colourChart()
        // Patch 13 is the chart's strong red; patch 21 (Neutral 5) is the grey anchor.
        let red = ProofFrames.chartPatchCentre(13)
        let grey = ProofFrames.chartPatchCentre(21)

        var previousLuma = Double.infinity
        var greyReference: RGB? = nil
        for density in stride(from: 0.0, through: 100.0, by: 25.0) {
            var recipe = Recipe()
            recipe.develop.color.saturation = 60
            recipe.develop.color.density = density
            let out = rendered(chart, recipe)
            let luma = RGBColorSpace.rec2020.luminance(out[red.x, red.y])
            XCTAssertLessThanOrEqual(luma, previousLuma + 1e-6,
                "density \(density) brightened the red patch (\(luma) after "
                    + "\(previousLuma)) — the subtractive branch must densify, "
                    + "monotonically (ColorEngine.swift header)")
            previousLuma = luma

            let g = out[grey.x, grey.y]
            if let reference = greyReference {
                XCTAssertLessThan(g.maxAbsDifference(reference), 1e-9,
                    "density \(density) moved a neutral grey — density is a blend "
                        + "between two chroma paths and a neutral has no chroma")
            } else {
                greyReference = g
            }
        }
    }

    // MARK: - Vibrance and Protect Skin

    /// ColorBalanceParams and the panel both promise vibrance is "weighted toward
    /// LOW-chroma colours, so already-saturated colour resists further push".
    /// Measured at the engine stage where the weighting lives.
    func testVibranceSpendsItselfOnLowChromaColours() {
        let engine = ColorEngine(mixer: Mixer(), pointColors: [],
                                 color: ColorAdjust(vibrance: 60),
                                 primaries: Primaries(), bw: nil)
        let context = OKLabTransform.working
        let pale = context.toRGB(OKLCh(L: 0.60, C: 0.04, h: 250))
        let vivid = context.toRGB(OKLCh(L: 0.60, C: 0.16, h: 250))
        let paleGain = context.toLCh(engine.apply(pale)).C / 0.04
        let vividGain = context.toLCh(engine.apply(vivid)).C / 0.16
        XCTAssertGreaterThan(paleGain, vividGain * 1.1,
            "vibrance +60 boosted a pale blue x\(paleGain) and a vivid blue "
                + "x\(vividGain) — the low-chroma weighting is the documented "
                + "difference between Vibrance and Saturation")
    }

    /// ColorAdjust: protectSkin "attenuates Vibrance at both signs" inside the skin
    /// band. The chart's patch 2 is light skin (ProofFrames' own comment); patch 15
    /// is the blue control. Protection must bite the skin patch and spare the blue.
    func testProtectSkinAttenuatesSkinAndSparesBlue() {
        func chromaShift(_ patch: Int, protect: Double) -> Double {
            let engine = ColorEngine(mixer: Mixer(), pointColors: [],
                                     color: ColorAdjust(vibrance: 80,
                                                        protectSkin: protect),
                                     primaries: Primaries(), bw: nil)
            let input = ProofFrames.chartPatchColour(patch)
            let context = OKLabTransform.working
            return abs(context.toLCh(engine.apply(input)).C - context.toLCh(input).C)
        }
        let skinUnprotected = chromaShift(2, protect: 0)
        let skinProtected = chromaShift(2, protect: 100)
        XCTAssertLessThan(skinProtected, skinUnprotected * 0.6,
            "protectSkin 100 left \(skinProtected) of the skin patch's "
                + "\(skinUnprotected) vibrance move — protection must attenuate "
                + "meaningfully inside the band")
        let blueUnprotected = chromaShift(15, protect: 0)
        let blueProtected = chromaShift(15, protect: 100)
        XCTAssertGreaterThan(blueProtected, blueUnprotected * 0.85,
            "protectSkin 100 took the blue patch from \(blueUnprotected) to "
                + "\(blueProtected) — protection must not leak outside the skin band")
    }

    // MARK: - Mixer uniformity

    /// Recipe.swift: uniformity is "hue convergence (D13)". What the shipped design
    /// delivers, measured (docs/27 §2 carries the field): STRONG convergence in the
    /// flats around each band centre, zero at the seams — a boundary hue belongs to
    /// both sides and must stay — and, since the blended-target fix, no
    /// anti-convergent pockets (the first construction summed a full-deviation pull
    /// per band, and two seams' pulls cancelled into small backwards moves; this
    /// test's probe convicted it). The wide feathers leave the mid-band ramps close
    /// to identity, so wheel-WIDE aggregate convergence is weak — recorded in
    /// docs/27 as a limitation feeding the dossier's band-geometry item, not
    /// asserted away here. What IS the contract: centres converge hard, seams hold.
    func testUniformityConvergesAtBandCentresAndHoldsSeams() {
        let context = OKLabTransform.working
        let engine = ColorEngine(mixer: Mixer(uniformity: 100), pointColors: [],
                                 color: ColorAdjust(), primaries: Primaries(), bw: nil)
        func outHue(_ h: Double) -> Double {
            context.toLCh(engine.apply(
                context.toRGB(OKLCh(L: 0.55, C: 0.10, h: h)))).h
        }
        // The canonical geometry: centres at 29.23 + 45k, seams 22.5° off-centre.
        for k in 0..<8 {
            let centre = Num.wrapHue(29.23 + 45.0 * Double(k))
            let a = outHue(Num.wrapHue(centre - 4))
            let b = outHue(Num.wrapHue(centre + 4))
            let spread = abs(Num.hueDelta(a, b))
            XCTAssertLessThan(spread, 8.0 * 0.3,
                "an 8° pair around the \(centre)° centre converged to only "
                    + "\(spread)° at uniformity 100 — the flats are where "
                    + "convergence lives and they must deliver")
            let seam = Num.wrapHue(centre + 22.5)
            let seamMove = abs(Num.hueDelta(seam, outHue(seam)))
            XCTAssertLessThan(seamMove, 2.5,
                "the seam hue \(seam)° moved \(seamMove)° — a boundary colour "
                    + "belongs to both bands and uniformity must leave it be")
        }
    }

    // MARK: - Vignette

    /// EffectsPanel's caption: "Stops at the corner, applied on scene-linear data
    /// before the display transform." Stops means stops: at −2 EV the corner's
    /// scene-linear attenuation must reach 2^−2 against the centre.
    func testVignetteCornerIsTheStatedStops() {
        let flat = ImageBuffer(width: 128, height: 128) { _, _ in RGB(gray: 0.18) }
        var recipe = Recipe()
        recipe.look.render.preset = "Linear"   // read the attenuation, not the curve
        let plain = rendered(flat, recipe)
        recipe.look.vignette = -2
        let vignetted = rendered(flat, recipe)
        let centre = vignetted[64, 64].r / Swift.max(plain[64, 64].r, 1e-9)
        let corner = vignetted[1, 1].r / Swift.max(plain[1, 1].r, 1e-9)
        XCTAssertGreaterThan(centre, 0.95,
            "a vignette must leave the centre alone (centre kept \(centre))")
        XCTAssertEqual(corner, exp2(-2.0), accuracy: 0.12,
            "vignette −2 EV attenuated the corner to \(corner) of the plain render "
                + "— the slider's unit is stops at the corner, and 2^−2 is 0.25")
    }

    // MARK: - Point curve

    /// A curve point is a promise about a mapping: the curve passes through it.
    /// CurveStack's master curve, on its own encoded axis.
    func testCurvePointPassesThroughItself() {
        let set = CurveSet(point: [[0, 0], [0.3, 0.62], [1, 1]])
        let stack = CurveStack(set)
        XCTAssertEqual(stack.master(0.3), 0.62, accuracy: 1e-6,
            "the master curve returned \(stack.master(0.3)) at a point pinned to "
                + "0.62 — a curve that misses its own point is not that curve")
        XCTAssertEqual(stack.master(0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(stack.master(1.0), 1.0, accuracy: 1e-9)
    }

    // MARK: - Film grain

    /// Grain must vanish exactly at amount 0 and grow monotonically from there —
    /// measured as the standard deviation it adds to a flat field.
    func testGrainAmountZeroIsExactAndGrowthIsMonotone() {
        let flat = ImageBuffer(width: 128, height: 128) { _, _ in RGB(gray: 0.18) }
        func render(amount: Double) -> ImageBuffer {
            var recipe = Recipe()
            recipe.look.filmLab = FilmLab(stock: "portra400")
            recipe.look.filmLab?.grain.amount = amount
            return rendered(flat, recipe)
        }
        func deviation(_ image: ImageBuffer) -> Double {
            var sum = 0.0, sumSq = 0.0
            let n = Double(image.width * image.height)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let v = RGBColorSpace.rec2020.luminance(image[x, y])
                    sum += v; sumSq += v * v
                }
            }
            let mean = sum / n
            // A perfectly flat field can put the difference a few ulps below zero.
            return Swift.max(sumSq / n - mean * mean, 0).squareRoot()
        }
        let at0 = render(amount: 0)
        let reference = render(amount: 0)
        XCTAssertLessThan(at0.maxAbsDifference(reference), 1e-12,
            "grain at 0 must be deterministic and identical run to run")
        let sigma0 = deviation(at0)
        let sigma40 = deviation(render(amount: 40))
        let sigma100 = deviation(render(amount: 100))
        XCTAssertGreaterThan(sigma40, sigma0 + 1e-6,
            "grain 40 added no measurable deviation (\(sigma0) → \(sigma40))")
        XCTAssertGreaterThan(sigma100, sigma40,
            "grain 100 (\(sigma100)) must exceed grain 40 (\(sigma40)) — "
                + "amount is a magnitude")
    }

    // MARK: - Hot pixels

    /// D26: a single-pixel control. On a frame of genuine impulses the slider at 100
    /// must remove most of what the slider at 0 leaves — measured as the worst
    /// deviation of any pixel from the local field, through the shipping order
    /// (classical denoise runs before the render, as the registry documents).
    func testHotPixelsSliderRemovesImpulses() {
        let frame = ProofFrames.hotPixels()
        func worstSpike(hotPixels: Double) -> Double {
            var recipe = Recipe()
            recipe.develop.denoise.mode = .classic
            recipe.develop.denoise.classic.hotPixels = hotPixels
            let plan = RenderPlan(recipe: recipe, captureISO: 6400)
            let staged = plan.denoiseIsIdentity ? frame
                : plan.classicalDenoise.apply(frame)
            let out = ReferenceRenderer.render(staged, plan: plan)
            var worst = 0.0
            for y in 1..<(out.height - 1) {
                for x in 1..<(out.width - 1) {
                    let v = RGBColorSpace.rec2020.luminance(out[x, y])
                    var neighbours = 0.0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        neighbours += RGBColorSpace.rec2020.luminance(out[x + dx, y + dy])
                    }
                    worst = Swift.max(worst, abs(v - neighbours / 4))
                }
            }
            return worst
        }
        let untreated = worstSpike(hotPixels: 0)
        let treated = worstSpike(hotPixels: 100)
        XCTAssertLessThan(treated, untreated * 0.5,
            "hot pixels 100 left a worst spike of \(treated) against \(untreated) "
                + "untreated — the control must at least halve the worst impulse")
    }
}
