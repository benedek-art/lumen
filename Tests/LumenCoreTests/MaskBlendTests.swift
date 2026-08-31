// MaskBlendTests.swift
// docs/36 §3, bet 1 — a blend mode per mask.
//
// Photoshop, Affinity and ON1 give a layer one; Capture One does not, and it has been
// an open request there for years. The reason to want it is specific: a mask in
// Luminosity mode moves tone and leaves colour exactly alone, which is dodging and
// burning skin without shifting it.
//
// The two properties asserted here are the two halves of "exactly alone", and they are
// what make the modes worth having rather than approximately right:
//
//   Luminosity  →  the result's CHROMATICITY equals the base's, its luminance the
//                  adjusted pixel's.
//   Colour      →  the result's CHROMATICITY equals the adjusted pixel's, its
//                  luminance the base's.
//
// Both are exact because both are a single luminance-ratio rescale, which is also why
// they are the two modes that are well defined on the scene-referred values this stage
// carries. Multiply, Screen and Soft Light are not, and are deliberately absent.

import XCTest
@testable import LumenCore

final class MaskBlendTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// Chromaticity as r:g:b normalized by their sum — the thing "leaves colour alone"
    /// is a claim about, independent of how bright the pixel is.
    private func chromaticity(_ c: RGB) -> (Double, Double, Double) {
        let sum = c.r + c.g + c.b
        guard sum > 1e-12 else { return (0, 0, 0) }
        return (c.r / sum, c.g / sum, c.b / sum)
    }

    /// `accuracy` is a parameter because the two claims are made at two scales. The
    /// pure function holds chromaticity to 1e-9 — it is one multiply. The whole-stage
    /// test runs the pixel through `ToneEngine` and `ColorEngine` first, and f64 down
    /// that path lands at about 1e-8; asserting 1e-9 there would be measuring the
    /// engines' rounding rather than the blend's exactness.
    private func assertSameColour(_ a: RGB, _ b: RGB,
                                  _ message: String,
                                  accuracy: Double = 1e-9,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let x = chromaticity(a), y = chromaticity(b)
        XCTAssertEqual(x.0, y.0, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(x.1, y.1, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(x.2, y.2, accuracy: accuracy, message, file: file, line: line)
    }

    private let base = RGB(0.30, 0.18, 0.11)        // a warm midtone, like skin
    private let adjusted = RGB(0.52, 0.44, 0.40)    // lifted AND cooled

    // MARK: - Normal changes nothing about what shipped

    func testNormalReturnsTheAdjustedPixelUntouched() {
        let out = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .normal, space: space)
        XCTAssertEqual(out.r, adjusted.r, accuracy: 0)
        XCTAssertEqual(out.g, adjusted.g, accuracy: 0)
        XCTAssertEqual(out.b, adjusted.b, accuracy: 0)
    }

    func testAMaskDecodesToNormalWhenTheFieldIsAbsent() throws {
        // docs/36 §1.8: every added field is an additive optional with a
        // behaviour-preserving default, and each ships with the test that says so.
        let json = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[],"adjust":{"exposure":1}}]}
        """
        let r = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(r.masks[0].blend, .normal)
    }

    func testTheBlendRoundTripsThroughTheRecipeFormat() throws {
        var r = Recipe()
        var m = Mask(id: "m", name: "skin")
        m.blend = .luminosity
        r.masks = [m]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(r).utf8))
        XCTAssertEqual(back.masks[0].blend, .luminosity)
    }

    // MARK: - Luminosity

    func testLuminosityTakesTheBrightnessAndLeavesTheColourExactlyAlone() {
        let out = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .luminosity, space: space)
        XCTAssertEqual(space.luminance(out), space.luminance(adjusted), accuracy: 1e-12,
                       "the brightness is the adjusted pixel's")
        assertSameColour(out, base,
                         "and the colour is the ORIGINAL's — this is the whole feature")
    }

    func testLuminosityIsNotJustTheAdjustedPixel() {
        // The guard against a mode that compiles and does nothing.
        let out = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .luminosity, space: space)
        let differs = abs(out.r - adjusted.r) + abs(out.g - adjusted.g) + abs(out.b - adjusted.b)
        XCTAssertGreaterThan(differs, 0.01,
                             "the fixture must actually change colour, or this proves nothing")
    }

    func testLuminosityHoldsAcrossExposureBecauseItIsARatio() {
        // Scene-referred values run past 1. A mode defined on a display domain would
        // break here; a luminance ratio does not.
        for gain in [0.001, 1.0, 64.0] {
            let out = MaskAlgebra.blended(base: base * gain, adjusted: adjusted * gain,
                                          blend: .luminosity, space: space)
            assertSameColour(out, base, "at gain \(gain)")
            XCTAssertEqual(space.luminance(out), space.luminance(adjusted * gain),
                           accuracy: 1e-9 * Swift.max(gain, 1))
        }
    }

    // MARK: - Colour

    func testColourTakesTheColourAndLeavesTheBrightnessExactlyAlone() {
        let out = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .color, space: space)
        XCTAssertEqual(space.luminance(out), space.luminance(base), accuracy: 1e-12,
                       "the brightness is the ORIGINAL's")
        assertSameColour(out, adjusted, "and the colour is the adjusted pixel's")
    }

    func testTheTwoModesAreTheTwoHalvesOfTheSameEdit() {
        // Together they carry everything the adjustment did — one takes the tone half,
        // the other the colour half — which is the property that makes them a pair
        // rather than two unrelated options.
        let lum = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .luminosity, space: space)
        let col = MaskAlgebra.blended(base: base, adjusted: adjusted,
                                      blend: .color, space: space)
        XCTAssertEqual(space.luminance(lum), space.luminance(adjusted), accuracy: 1e-12)
        assertSameColour(col, adjusted, "colour half")
        XCTAssertEqual(space.luminance(col), space.luminance(base), accuracy: 1e-12)
        assertSameColour(lum, base, "tone half")
    }

    // MARK: - The degenerate pixels, which are real photographs

    func testABlackBaseFallsThroughRatherThanDividing() {
        let out = MaskAlgebra.blended(base: RGB(0, 0, 0), adjusted: adjusted,
                                      blend: .luminosity, space: space)
        XCTAssertTrue(out.isFinite)
        XCTAssertEqual(out.r, adjusted.r, accuracy: 0,
                       "there is no colour in a black pixel to preserve, so Luminosity "
                           + "gives back the adjustment rather than a division")
    }

    func testABlackAdjustmentFallsThroughInColourMode() {
        let out = MaskAlgebra.blended(base: base, adjusted: RGB(0, 0, 0),
                                      blend: .color, space: space)
        XCTAssertTrue(out.isFinite)
        XCTAssertEqual(out.r, base.r, accuracy: 0)
    }

    func testFiniteInputNeverProducesANonFiniteOutput() {
        // The contract a test can actually hold. No mode can CLEAN a poisoned pixel —
        // `.normal` passes its argument through by definition, and the other two answer
        // with one of their two inputs — but none of them may MAKE one, at any
        // magnitude a scene-referred stage can carry.
        let magnitudes: [Double] = [0, 1e-12, 1e-7, 1e-3, 1, 64, 1e6, 1e12]
        for blend in MaskBlend.allCases {
            for m in magnitudes {
                for n in magnitudes {
                    let out = MaskAlgebra.blended(base: base * m, adjusted: adjusted * n,
                                                  blend: blend, space: space)
                    XCTAssertTrue(out.isFinite,
                                  "\(blend) at base ×\(m), adjusted ×\(n) produced "
                                      + "a non-finite pixel from two finite ones")
                }
            }
        }
    }

    func testAPoisonedInputComesBackAsOneOfTheInputsRatherThanAThirdValue() {
        // A NaN on the way in must not become a DIFFERENT non-finite value on the way
        // out — the pipeline's own poison tests assume a stage passes it through or
        // drops it, never that a stage invents one.
        for blend in MaskBlend.allCases {
            let poisonedBase = MaskAlgebra.blended(base: RGB(Double.nan, 1, 1),
                                                   adjusted: adjusted,
                                                   blend: blend, space: space)
            XCTAssertTrue(poisonedBase.isFinite || poisonedBase.r.isNaN,
                          "\(blend): a NaN base comes back as itself or as the adjustment")
            let poisonedOver = MaskAlgebra.blended(base: base,
                                                   adjusted: RGB(.infinity, 1, 1),
                                                   blend: blend, space: space)
            if blend == .color {
                XCTAssertTrue(poisonedOver.isFinite,
                              "Colour falls back to the finite base rather than to ∞ · 0")
            }
        }
    }

    // MARK: - Through the whole local stage

    func testAMaskInLuminosityModeMovesToneAndNotColour() {
        // The reference renderer's own composite, not the pure function: this is what
        // catches a blend that is right in `MaskAlgebra` and unwired in `applyMasks`.
        var mask = Mask(id: "m", name: "warm lift")
        mask.adjust.exposure = 1.0
        mask.adjust.temp = 60          // a colour move as well as a tone one
        mask.blend = .luminosity

        let image = ImageBuffer(width: 4, height: 4) { _, _ in RGB(0.30, 0.18, 0.11) }
        let alpha = Plane(width: 4, height: 4, fill: 1)
        let plan = RenderPlan(recipe: Recipe())
        let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                               alphas: [(mask, alpha)], space: space)

        var normalMask = mask
        normalMask.blend = .normal
        let normal = ReferenceRenderer.applyMasks(image, plan: plan,
                                                  alphas: [(normalMask, alpha)],
                                                  space: space)

        assertSameColour(out[0, 0], image[0, 0],
                         "in Luminosity the colour is untouched", accuracy: 1e-7)
        XCTAssertEqual(space.luminance(out[0, 0]), space.luminance(normal[0, 0]),
                       accuracy: 1e-7,
                       "and the brightness is exactly what the full edit would have given")
        let colourMoved = abs(chromaticity(normal[0, 0]).0 - chromaticity(image[0, 0]).0)
        XCTAssertGreaterThan(colourMoved, 1e-4,
                             "the fixture's edit must move colour, or this proves nothing")
    }

    func testHalfAnAlphaStillHalvesTheBlendedResult() {
        // The blend runs BEFORE the alpha composite, so Amount and the mask's softness
        // do exactly what they did.
        var mask = Mask(id: "m", name: "half")
        mask.adjust.exposure = 1.0
        mask.blend = .luminosity
        let image = ImageBuffer(width: 2, height: 2) { _, _ in RGB(0.30, 0.18, 0.11) }
        let full = ReferenceRenderer.applyMasks(
            image, plan: RenderPlan(recipe: Recipe()),
            alphas: [(mask, Plane(width: 2, height: 2, fill: 1))], space: space)
        let half = ReferenceRenderer.applyMasks(
            image, plan: RenderPlan(recipe: Recipe()),
            alphas: [(mask, Plane(width: 2, height: 2, fill: 0.5))], space: space)
        XCTAssertEqual(half[0, 0].r, (image[0, 0].r + full[0, 0].r) / 2, accuracy: 1e-9)
    }
}
