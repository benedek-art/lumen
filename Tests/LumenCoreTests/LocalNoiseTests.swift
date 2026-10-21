// LocalNoiseTests.swift
// The mask panel's Noise and Colour Noise rows (WS-55, SPEC 7, 8, 10 and the
// inside-the-mask half of 9), on the reference renderer.
//
// The claim under test is narrow on purpose: a masked Noise row IS the global classical
// engine, with the mask's two strengths, the global shaping sliders and the plan's noise
// profile carried to the S11 signal level. So every assertion compares against an engine
// built by hand from those parts, at 1e-5 linear, rather than against a threshold on how
// much "smoother" the output looks — a second denoiser that happened to smooth about as
// much would pass the latter and is exactly what this lane exists to prevent.

import XCTest
@testable import LumenCore

final class LocalNoiseTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// A small mid-grey plate with deterministic Gaussian noise of the size ISO 3200
    /// carries, per channel, so both the luma and the chroma bands have something to do.
    /// 48 px is large enough for three à-trous levels and keeps each run in milliseconds.
    private static func noisyPlate(size: Int = 48, sigma: Double = 0.03,
                                   seed: UInt64 = 0x5EED) -> ImageBuffer {
        var state = seed
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(UInt64(1) << 53)
        }
        func gaussian() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
        var image = ImageBuffer(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                // A soft ramp under the noise, so the plate is not a flat field the
                // edge maps could treat specially.
                let base = 0.12 + 0.10 * Double(x) / Double(size)
                image[x, y] = RGB(base + sigma * gaussian(), base + sigma * gaussian(),
                                  base + sigma * gaussian())
            }
        }
        return image
    }

    /// A neutral recipe with global noise reduction OFF, so whatever moves is the mask.
    private static func plan(exposure: Double = 0) -> RenderPlan {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.tone.exposure = exposure
        return RenderPlan(recipe: recipe, captureISO: 3200)
    }

    /// The engine SPEC 7 names: the global one, with the given strengths.
    private static func engine(luma: Double, chroma: Double, plan: RenderPlan,
                               profile: NoiseProfile? = nil) -> ClassicalDenoise {
        let g = plan.classicalDenoise
        return ClassicalDenoise(luma: luma, chroma: chroma, hotPixels: 0,
                                lumaDetail: g.lumaDetail, lumaContrast: g.lumaContrast,
                                colorDetail: g.colorDetail,
                                colorSmoothness: g.colorSmoothness,
                                profile: profile ?? g.profile, levels: g.levels)
    }

    private static func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for i in 0..<a.pixels.count {
            worst = Swift.max(worst, abs(Double(a.pixels[i] - b.pixels[i])))
        }
        return worst
    }

    private func applyFull(_ image: ImageBuffer, mask: Mask, plan: RenderPlan,
                           noiseScale: Double = 1) -> ImageBuffer {
        let alpha = Plane(width: image.width, height: image.height, fill: 1)
        return ReferenceRenderer.applyMasks(image, plan: plan, alphas: [(mask, alpha)],
                                            space: space, noiseScale: noiseScale)
    }

    // MARK: - SPEC 7

    func testLocalNoiseIsTheGlobalEngine() {
        let image = Self.noisyPlate()
        let plan = Self.plan()
        XCTAssertTrue(plan.denoiseIsIdentity, "the fixture needs global NR off")
        for v in [30.0, 70, 100] {
            var mask = Mask(id: "m", name: "noise")
            mask.adjust.noise = v
            let out = applyFull(image, mask: mask, plan: plan)
            let expected = Self.engine(luma: v, chroma: 0, plan: plan)
                .apply(image, space: space)
            XCTAssertLessThanOrEqual(Self.maxDifference(out, expected), 1e-5,
                                     "local Noise \(v) is not the global engine")
            XCTAssertGreaterThan(Self.maxDifference(out, image), 1e-3,
                                 "local Noise \(v) did nothing")
        }
    }

    func testLocalColourNoiseIsTheGlobalEngine() {
        let image = Self.noisyPlate()
        let plan = Self.plan()
        for v in [30.0, 70, 100] {
            var mask = Mask(id: "m", name: "colour noise")
            mask.adjust.noiseChroma = v
            let out = applyFull(image, mask: mask, plan: plan)
            let expected = Self.engine(luma: 0, chroma: v, plan: plan)
                .apply(image, space: space)
            XCTAssertLessThanOrEqual(Self.maxDifference(out, expected), 1e-5,
                                     "local Colour Noise \(v) is not the global engine")
            XCTAssertGreaterThan(Self.maxDifference(out, image), 1e-3,
                                 "local Colour Noise \(v) did nothing")
        }
    }

    /// Mask Amount scales both rows and the product stays inside the slider's range.
    func testMaskAmountScalesTheStrengthAndClampsAtOneHundred() {
        let plan = Self.plan()
        var mask = Mask(id: "m", name: "amount", amount: 50)
        mask.adjust.noise = 60
        mask.adjust.noiseChroma = 40
        let half = LocalNoise.engine(for: mask, plan: plan)
        XCTAssertEqual(half?.luma ?? -1, 30, accuracy: 1e-12)
        XCTAssertEqual(half?.chroma ?? -1, 20, accuracy: 1e-12)
        mask.amount = 200
        let double = LocalNoise.engine(for: mask, plan: plan)
        XCTAssertEqual(double?.luma ?? -1, 100, accuracy: 1e-12)
        XCTAssertEqual(double?.chroma ?? -1, 80, accuracy: 1e-12)
        mask.amount = 0
        XCTAssertNil(LocalNoise.engine(for: mask, plan: plan))
    }

    // MARK: - SPEC 8

    func testLocalNoiseFollowsExposure() {
        let image = Self.noisyPlate()
        let plan = Self.plan(exposure: 2)
        let p = plan.classicalDenoise.profile
        var mask = Mask(id: "m", name: "after +2 EV")
        mask.adjust.noise = 70

        let carried = LocalNoise.profile(for: mask, plan: plan)
        XCTAssertEqual(carried.a, 4 * p.a, accuracy: 1e-15)
        XCTAssertEqual(carried.b, 16 * p.b, accuracy: 1e-18)

        let out = applyFull(image, mask: mask, plan: plan)
        let expected = Self.engine(luma: 70, chroma: 0, plan: plan,
                                   profile: NoiseProfile(a: 4 * p.a, b: 16 * p.b))
            .apply(image, space: space)
        XCTAssertLessThanOrEqual(Self.maxDifference(out, expected), 1e-5)
        // And it is a different picture from the uncarried profile, or the test above
        // proves nothing about the carrying.
        let uncarried = Self.engine(luma: 70, chroma: 0, plan: plan)
            .apply(image, space: space)
        XCTAssertGreaterThan(Self.maxDifference(expected, uncarried), 1e-4)
    }

    /// The mask's own Exposure multiplies in too, because the colour half has already
    /// applied it to the pixels the engine receives.
    func testLocalNoiseFollowsTheMasksOwnExposure() {
        let plan = Self.plan(exposure: 1)
        let p = plan.classicalDenoise.profile
        var mask = Mask(id: "m", name: "+1 EV in the mask")
        mask.adjust.exposure = 1
        mask.adjust.noise = 50
        let carried = LocalNoise.profile(for: mask, plan: plan)
        XCTAssertEqual(LocalNoise.signalGain(for: mask, plan: plan), 4, accuracy: 1e-12)
        XCTAssertEqual(carried.a, 4 * p.a, accuracy: 1e-15)
        XCTAssertEqual(carried.b, 16 * p.b, accuracy: 1e-18)
    }

    // MARK: - SPEC 10

    func testLocalNoiseFollowsTheGlobalPreviewRule() {
        let image = Self.noisyPlate()
        let plan = Self.plan()
        var mask = Mask(id: "m", name: "preview")
        mask.adjust.noise = 100
        mask.adjust.noiseChroma = 100
        let untouched = applyFull(image, mask: Mask(id: "m", name: "none"), plan: plan)

        // At and below the contributing scale: exactly the identity, like S3.
        for scale in [0.5, 0.25, 0.1] {
            let out = applyFull(image, mask: mask, plan: plan, noiseScale: scale)
            XCTAssertEqual(out.pixels, untouched.pixels,
                           "local Noise ran at noiseScale \(scale); S3 does not")
            XCTAssertTrue(Self.engine(luma: 100, chroma: 100, plan: plan)
                .scaled(noiseScale: scale).isIdentity)
        }
        // Above it: the global engine at that scale, exactly as S3 would build it.
        let out = applyFull(image, mask: mask, plan: plan, noiseScale: 0.8)
        let expected = Self.engine(luma: 100, chroma: 100, plan: plan)
            .scaled(noiseScale: 0.8).apply(image, space: space)
        XCTAssertLessThanOrEqual(Self.maxDifference(out, expected), 1e-5)
    }

    // MARK: - SPEC 9 (the inside-the-mask half, on a synthetic plate)

    func testLocalNoiseReducesNoiseOnlyInsideTheMask() {
        let image = Self.noisyPlate(size: 64)
        let plan = Self.plan()
        var mask = Mask(id: "m", name: "left half")
        mask.adjust.noise = 100
        mask.adjust.noiseChroma = 100
        // Left half selected, right half not.
        let alpha = Plane(width: 64, height: 64) { u, _ in u < 0.5 ? 1 : 0 }
        let out = ReferenceRenderer.applyMasks(image, plan: plan, alphas: [(mask, alpha)],
                                               space: space)

        for y in 0..<64 {
            for x in 32..<64 {
                XCTAssertEqual(out[x, y], image[x, y], "pixel (\(x), \(y)) outside moved")
            }
        }

        // High-pass sigma inside: the residual against a 3×3 box mean, away from the
        // seam and the frame edge.
        func highPassSigma(_ b: ImageBuffer) -> Double {
            var sum = 0.0, n = 0.0
            for y in 4..<60 {
                for x in 4..<26 {
                    var mean = 0.0
                    for dy in -1...1 { for dx in -1...1 { mean += b[x + dx, y + dy].g } }
                    let d = b[x, y].g - mean / 9
                    sum += d * d
                    n += 1
                }
            }
            return (sum / n).squareRoot()
        }
        let before = highPassSigma(image)
        let after = highPassSigma(out)
        XCTAssertLessThan(after, 0.7 * before,
                          "inside the mask high-pass σ went \(before) → \(after)")
    }

    /// Monotonic in the slider: more Noise never leaves more noise.
    func testLocalNoiseIsMonotonicInTheSlider() {
        let image = Self.noisyPlate()
        let plan = Self.plan()
        var last = Double.infinity
        for v in [0.0, 25, 50, 75, 100] {
            var mask = Mask(id: "m", name: "sweep")
            mask.adjust.noise = v
            let out = applyFull(image, mask: mask, plan: plan)
            var sum = 0.0
            for y in 1..<(out.height - 1) {
                for x in 1..<(out.width - 1) {
                    let d = out[x, y].g - 0.25 * (out[x - 1, y].g + out[x + 1, y].g
                                                  + out[x, y - 1].g + out[x, y + 1].g)
                    sum += d * d
                }
            }
            XCTAssertLessThanOrEqual(sum, last + 1e-12, "Noise \(v) left more noise")
            last = sum
        }
    }
}
