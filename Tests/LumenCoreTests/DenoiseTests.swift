// DenoiseTests.swift
// Tier 1, the declared flagship: what each of the seven controls does, and whether the
// numbers the GPU stage is handed are the numbers the reference shrinks with.
//
// The bar every test here has to clear is that it can FAIL. "Denoise reduced the noise"
// passes for a stage that blurs the picture flat, and it passed for a stage that had no
// caller at all — so every assertion below pins both halves: the control moved the
// quantity it is supposed to move, and it left alone the one it is not.

import XCTest
@testable import LumenCore

final class DenoiseTests: XCTestCase {

    // MARK: - Frames

    /// A flat mid-grey field with Poisson–Gaussian noise from the profile itself, so
    /// "one σ" means what the engine thinks it means.
    ///
    /// The noise is a deterministic hash rather than a system RNG: a golden that draws
    /// a different frame on every run cannot be debugged, and the whole point of these
    /// numbers is that they are reproducible.
    private func noisyField(level: Double, profile: NoiseProfile,
                            width: Int = 96, height: Int = 96,
                            seed: UInt64 = 0x9E37) -> ImageBuffer {
        var buffer = ImageBuffer(width: width, height: height)
        let sigma = profile.sigma(at: level)
        for y in 0..<height {
            for x in 0..<width {
                var c = RGB(gray: level)
                for channel in 0..<3 {
                    let n = Self.gaussian(x: x, y: y, channel: channel, seed: seed)
                    c[channel] = Swift.max(level + n * sigma, 0)
                }
                buffer[x, y] = c
            }
        }
        return buffer
    }

    /// Two uniform normals through a Box–Muller pair, off a deterministic 64-bit mix.
    private static func gaussian(x: Int, y: Int, channel: Int, seed: UInt64) -> Double {
        func mix(_ v: UInt64) -> UInt64 {
            var z = v &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let base = mix(seed &+ UInt64(bitPattern: Int64(x &* 73_856_093))
                       &+ UInt64(bitPattern: Int64(y &* 19_349_663))
                       &+ UInt64(channel &* 83_492_791))
        let u1 = Double(base >> 11) / Double(1 << 53)
        let u2 = Double(mix(base) >> 11) / Double(1 << 53)
        let r = (-2 * Foundation.log(Swift.max(u1, 1e-12))).squareRoot()
        return r * Foundation.cos(2 * Double.pi * u2)
    }

    /// σ of a buffer measured in the orthonormal basis the engine shrinks in, so a
    /// luma-only move and a chroma-only move can be told apart. Per-channel σ cannot
    /// tell them apart: denoising luma alone can only ever reduce a channel's σ by
    /// 18%, because two thirds of its variance lives in the chroma directions.
    private func basisSigma(_ image: ImageBuffer) -> (luma: Double, chroma: Double) {
        let rotate = ClassicalDenoise.toY0U0V0
        var y: [Double] = []
        var u: [Double] = []
        var v: [Double] = []
        y.reserveCapacity(image.width * image.height)
        for py in 0..<image.height {
            for px in 0..<image.width {
                let d = rotate.apply(image[px, py])
                y.append(d.r)
                u.append(d.g)
                v.append(d.b)
            }
        }
        func sigma(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let mean = values.reduce(0, +) / Double(values.count)
            let acc = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            return (acc / Double(values.count)).squareRoot()
        }
        return (sigma(y), (sigma(u) * sigma(u) + sigma(v) * sigma(v)).squareRoot())
    }

    private func engine(_ params: ClassicNR, iso: Double = 3200) -> ClassicalDenoise {
        ClassicalDenoise(params, profile: NoiseProfile.forISO(iso))
    }

    // MARK: - The two master sliders act on their own half of the basis

    func testLuminanceRemovesLumaNoiseAndLeavesChromaAlone() {
        let profile = NoiseProfile.forISO(3200)
        let noisy = noisyField(level: 0.18, profile: profile)
        let before = basisSigma(noisy)
        XCTAssertGreaterThan(before.luma, 1e-3, "the test frame carries no noise")

        var previous = before.luma
        for slider in [25.0, 60.0, 100.0] {
            let out = engine(ClassicNR(luma: slider, chroma: 0)).apply(noisy)
            let after = basisSigma(out)
            XCTAssertLessThan(after.luma, previous,
                              "Luminance \(slider) removed no more luma noise than the "
                                  + "step below it (\(after.luma) vs \(previous))")
            previous = after.luma
            // The other half must be untouched. A stage that smooths everything would
            // satisfy the line above and fail this one.
            XCTAssertEqual(after.chroma, before.chroma, accuracy: before.chroma * 0.02,
                           "Luminance \(slider) moved the chroma noise as well: "
                               + "\(after.chroma) against \(before.chroma)")
        }
        // And the magnitude, not just the direction: at 60 the luma noise is down to a
        // small fraction. Modelled at 4% of input on a 96×96 field.
        let out = engine(ClassicNR(luma: 60, chroma: 0)).apply(noisy)
        XCTAssertLessThan(basisSigma(out).luma, before.luma * 0.20,
                          "Luminance 60 left \(basisSigma(out).luma / before.luma) of "
                              + "the luma noise")
    }

    func testColourRemovesChromaNoiseAndLeavesLumaAlone() {
        let profile = NoiseProfile.forISO(3200)
        let noisy = noisyField(level: 0.18, profile: profile)
        let before = basisSigma(noisy)

        let out = engine(ClassicNR(luma: 0, chroma: 25, colorSmoothness: 0)).apply(noisy)
        let after = basisSigma(out)
        XCTAssertLessThan(after.chroma, before.chroma * 0.20,
                          "Colour 25 left \(after.chroma / before.chroma) of the chroma "
                              + "noise — the default is meant to be aggressive")
        XCTAssertEqual(after.luma, before.luma, accuracy: before.luma * 0.02,
                       "Colour moved the luminance noise: \(after.luma) against "
                           + "\(before.luma)")
    }

    // MARK: - The four sub-sliders that had no wire format

    /// Luminance Detail IS the threshold: `1.5 − detail/100`. Higher preserves texture,
    /// and the noise beside it, so more noise must survive at 100 than at 0.
    func testLuminanceDetailRaisesTheThresholdAndKeepsMoreNoise() {
        let profile = NoiseProfile.forISO(3200)
        let noisy = noisyField(level: 0.18, profile: profile)
        let base = basisSigma(noisy).luma

        var previous = 0.0
        for detail in [0.0, 50.0, 100.0] {
            let out = engine(ClassicNR(luma: 60, chroma: 0, lumaDetail: detail))
                .apply(noisy)
            let kept = basisSigma(out).luma
            XCTAssertGreaterThan(kept, previous,
                                 "Luminance Detail \(detail) kept no more than the step "
                                     + "below it (\(kept) vs \(previous))")
            previous = kept
        }
        // Both ends, as a ratio, so a slider that moved by a rounding error fails: 0
        // must be a real cut and 100 a real reprieve.
        let strict = basisSigma(engine(ClassicNR(luma: 60, chroma: 0, lumaDetail: 0))
            .apply(noisy)).luma
        let loose = basisSigma(engine(ClassicNR(luma: 60, chroma: 0, lumaDetail: 100))
            .apply(noisy)).luma
        XCTAssertGreaterThan(loose, strict * 3,
                             "Detail 100 kept \(loose / strict)× the noise Detail 0 did; "
                                 + "the threshold multiplier spans 1.5 to 0.5")
    }

    /// Luminance Contrast pulls the COARSE bands' thresholds down, so coarse luminance
    /// structure survives — which on a flat field reads as retained mottling.
    func testLuminanceContrastKeepsTheCoarseBands() {
        let profile = NoiseProfile.forISO(3200)
        let noisy = noisyField(level: 0.18, profile: profile)
        let off = basisSigma(engine(ClassicNR(luma: 80, chroma: 0, lumaContrast: 0))
            .apply(noisy)).luma
        let on = basisSigma(engine(ClassicNR(luma: 80, chroma: 0, lumaContrast: 100))
            .apply(noisy)).luma
        XCTAssertGreaterThan(on, off * 1.3,
                             "Luminance Contrast 100 kept \(on / off)× as much coarse "
                                 + "luma structure as 0 — the coarse-band threshold "
                                 + "scale is not reaching the shrinkage")

        // And it must act on the COARSE end only: the finest band's threshold carries a
        // `coarse` factor of exactly zero, so band 0 cannot move.
        let engineOff = engine(ClassicNR(luma: 80, chroma: 0, lumaContrast: 0))
        let engineOn = engine(ClassicNR(luma: 80, chroma: 0, lumaContrast: 100))
        let a = engineOff.lumaThresholds(levels: 5)
        let b = engineOn.lumaThresholds(levels: 5)
        XCTAssertEqual(a[0], b[0], accuracy: 1e-12,
                       "Luminance Contrast moved the finest band, which it must not")
        XCTAssertLessThan(b[4], a[4] * 0.2,
                          "Luminance Contrast barely moved the coarsest band: "
                              + "\(b[4]) against \(a[4])")
    }

    /// Colour Detail protects thin colour edges: more of the step across a chroma edge
    /// must survive as the slider rises.
    func testColourDetailProtectsAThinColourEdge() {
        let profile = NoiseProfile.forISO(3200)
        let width = 96, height = 96
        var frame = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let warm = x >= width / 2
                var c = RGB(0.18 + (warm ? 0.05 : 0), 0.18, 0.18 - (warm ? 0.05 : 0))
                for channel in 0..<3 {
                    let n = Self.gaussian(x: x, y: y, channel: channel, seed: 0x51ED)
                    c[channel] = Swift.max(c[channel] + n * profile.sigma(at: 0.18), 0)
                }
                frame[x, y] = c
            }
        }
        func step(_ image: ImageBuffer) -> Double {
            let rotate = ClassicalDenoise.toY0U0V0
            var right = 0.0
            var left = 0.0
            for y in 0..<height {
                right += rotate.apply(image[width / 2 + 1, y]).g
                left += rotate.apply(image[width / 2 - 2, y]).g
            }
            return (right - left) / Double(height)
        }
        let input = step(frame)
        var previous = 0.0
        for detail in [0.0, 50.0, 100.0] {
            let out = engine(ClassicNR(luma: 0, chroma: 80, colorDetail: detail,
                                       colorSmoothness: 0)).apply(frame)
            let kept = step(out)
            XCTAssertGreaterThan(kept, previous,
                                 "Colour Detail \(detail) preserved no more of the "
                                     + "colour edge than the step below it")
            XCTAssertLessThan(kept, input,
                              "Colour Detail \(detail) did not shrink chroma at all")
            previous = kept
        }
    }

    /// Colour Smoothness reaches the coarse chroma bands, which is where blotches live.
    func testColourSmoothnessReachesALargeChromaBlotch() {
        let profile = NoiseProfile.forISO(3200)
        let width = 96, height = 96
        var frame = noisyField(level: 0.18, profile: profile,
                               width: width, height: height)
        // A 12 px-σ chroma blob: too large for the fine bands, which is exactly the
        // artefact band shrinkage alone leaves behind.
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - Double(width) / 2
                let dy = Double(y) - Double(height) / 2
                let blob = Foundation.exp(-(dx * dx + dy * dy) / (2 * 144))
                var c = frame[x, y]
                c.r += 0.02 * blob
                c.b -= 0.02 * blob
                frame[x, y] = c
            }
        }
        func centreChroma(_ image: ImageBuffer) -> Double {
            let rotate = ClassicalDenoise.toY0U0V0
            var total = 0.0
            var count = 0.0
            for y in (height / 2 - 8)..<(height / 2 + 8) {
                for x in (width / 2 - 8)..<(width / 2 + 8) {
                    let d = rotate.apply(image[x, y])
                    total += (d.g * d.g + d.b * d.b).squareRoot()
                    count += 1
                }
            }
            return total / Swift.max(count, 1)
        }
        let input = centreChroma(frame)
        var previous = input
        for smooth in [0.0, 50.0, 100.0] {
            let out = engine(ClassicNR(luma: 0, chroma: 50, colorSmoothness: smooth))
                .apply(frame)
            let remaining = centreChroma(out)
            XCTAssertLessThan(remaining, previous,
                              "Colour Smoothness \(smooth) left as much of the blotch "
                                  + "as the step below it (\(remaining) vs \(previous))")
            previous = remaining
        }
        XCTAssertLessThan(previous, input * 0.75,
                          "Colour Smoothness 100 left \(previous / input) of the blotch")

        // The slider has TWO halves — a coarse-band threshold scale and a guided-filter
        // blotch pass — and the measurement above is satisfied by either one alone.
        // Deleting the band scale left every assertion so far green. So: the coarsest
        // chroma threshold must climb, and the finest must not move at all, because its
        // `coarse` factor is exactly zero.
        let flat = engine(ClassicNR(luma: 0, chroma: 50, colorSmoothness: 0))
            .chromaThresholds(levels: 5)
        let reaching = engine(ClassicNR(luma: 0, chroma: 50, colorSmoothness: 100))
            .chromaThresholds(levels: 5)
        XCTAssertEqual(flat[0], reaching[0], accuracy: 1e-12,
                       "Colour Smoothness moved the finest chroma band, which it must not")
        XCTAssertEqual(reaching[4], flat[4] * (1 + ClassicalDenoise.colorSmoothnessReach),
                       accuracy: 1e-9,
                       "Colour Smoothness 100 did not push the coarsest chroma band by "
                           + "its declared reach: \(reaching[4]) against \(flat[4])")
    }

    // MARK: - Hot pixels

    func testHotPixelsReplaceSpikesAndLeaveEdgesAlone() {
        let profile = NoiseProfile.forISO(3200)
        var frame = noisyField(level: 0.18, profile: profile, width: 64, height: 64)
        // A one-pixel line of real detail: every pixel on it has a neighbour on the same
        // side of the median, so none of them is an extremum and none may be touched.
        for y in 0..<64 { frame[32, y] = RGB(gray: 0.6) }
        frame[10, 10] = RGB(gray: 0.95)
        frame[40, 20] = RGB(gray: 0.0)
        let quiet = frame

        let off = engine(ClassicNR(luma: 0, chroma: 0, hotPixels: 0)).apply(frame)
        XCTAssertEqual(off[10, 10].g, 0.95, accuracy: 1e-6,
                       "Hot Pixels 0 removed a spike anyway")

        let on = engine(ClassicNR(luma: 0, chroma: 0, hotPixels: 50)).apply(frame)
        XCTAssertLessThan(on[10, 10].g, 0.30,
                          "the bright spike survived at \(on[10, 10].g)")
        XCTAssertGreaterThan(on[40, 20].g, 0.08,
                             "the dark spike survived at \(on[40, 20].g)")
        // The line is not a defect. Column 32 away from the spikes must come through.
        for y in [5, 25, 45, 60] {
            XCTAssertEqual(on[32, y].g, quiet[32, y].g, accuracy: 1e-6,
                           "Hot Pixels ate a one-pixel line at row \(y)")
        }
    }

    func testHotPixelGateLoosensAcrossTheSlider() {
        XCTAssertFalse(ClassicalDenoise.hotPixelK(0).isFinite,
                       "Hot Pixels 0 must be a no-op, not a very large k")
        XCTAssertEqual(ClassicalDenoise.hotPixelK(50), 4.5, accuracy: 1e-9)
        XCTAssertEqual(ClassicalDenoise.hotPixelK(100), 2.0, accuracy: 1e-9)
        XCTAssertGreaterThan(ClassicalDenoise.hotPixelK(25),
                             ClassicalDenoise.hotPixelK(75))
    }

    // MARK: - The encoded transform the kernels compute

    /// `GPUPlan.encodedForward` / `encodedInverse` are the shader expressions, written
    /// in Swift. They must be `VST.forward` / `VST.inverse` re-centred on mid-grey — a
    /// claim that can be checked on a machine with no GPU, and the reason the kernels
    /// can be trusted from one.
    func testTheEncodedTransformIsTheReferenceTransform() {
        let profiles: [(String, NoiseProfile)] = [
            ("ISO 100", NoiseProfile.forISO(100)),
            ("ISO 1600", NoiseProfile.forISO(1600)),
            ("ISO 102400", NoiseProfile.forISO(102400)),
            ("read-noise dominated", NoiseProfile(a: 1e-11, b: 1e-6)),
            ("pure read noise", NoiseProfile(a: 0, b: 4e-7)),
        ]
        var samples: [Double] = [0, 1e-4, 1e-3, 0.01, 0.05, 0.18, 0.5, 1.0, 4.0, 16.0, 64.0]
        samples.append(contentsOf: [-0.02, -0.005, -0.001])

        for (name, profile) in profiles {
            for luma in [40.0, 100.0] {
                let denoise = ClassicalDenoise(ClassicNR(luma: luma, chroma: 0),
                                               profile: profile)
                let plan = denoise.gpuPlan(width: 256, height: 256)
                let pedestal = VST.forward(plan.pedestalSignal, profile: profile)
                for x in samples {
                    // The reference floors the transform where its radicand goes
                    // negative; the kernel clamps the input to the same place, which is
                    // the same number because `f` of that place IS zero.
                    let floored = Swift.max(x, plan.signalFloor)
                    let expected = plan.encodedScale
                        * (VST.forward(floored, profile: profile) - pedestal)
                    let got = plan.encodedForward(x)
                    XCTAssertEqual(got, expected,
                                   accuracy: Swift.max(abs(expected) * 1e-9, 1e-9),
                                   "\(name) forward at \(x): \(got) vs \(expected)")

                    let back = plan.encodedInverse(expected)
                    let reference = VST.inverse(pedestal + expected / plan.encodedScale,
                                                profile: profile,
                                                shrinkage: plan.shrinkage)
                    XCTAssertEqual(back, reference,
                                   accuracy: Swift.max(abs(reference) * 1e-7, 1e-9),
                                   "\(name) inverse at \(x): \(back) vs \(reference)")
                }
            }
        }
    }

    /// The change of variables exists to keep the encoded plane inside a half-float
    /// working format. The bound is asserted, and so is the fact that it is needed —
    /// the un-shifted transform of a read-noise-dominated profile is four orders of
    /// magnitude past what a half can hold.
    func testTheEncodedPlaneStaysInsideAHalfFloat() {
        let halfMax = 65504.0
        let hostile = NoiseProfile(a: 1e-11, b: 1e-6)
        XCTAssertGreaterThan(VST.forward(1.0, profile: hostile), halfMax,
                             "the un-shifted transform now fits a half, so this test no "
                                 + "longer proves the pedestal is load-bearing")

        for profile in [NoiseProfile.forISO(100), NoiseProfile.forISO(6400),
                        NoiseProfile.forISO(102400), hostile,
                        NoiseProfile(a: 1e-8, b: 1e-8)] {
            let plan = ClassicalDenoise(ClassicNR(luma: 100, chroma: 100),
                                        profile: profile)
                .gpuPlan(width: 256, height: 256)
            for x in [0.0, 0.001, 0.18, 1.0, 16.0, 64.0] {
                let g = plan.encodedForward(x)
                XCTAssertTrue(g.isFinite, "encoded value at \(x) is not finite")
                XCTAssertLessThanOrEqual(abs(g), ClassicalDenoise.encodedCeiling * 1.001,
                                         "encoded \(x) reached \(g), past the ceiling")
            }
            // Well clear of the ceiling means well clear of half-float overflow, which
            // is the property that actually matters.
            XCTAssertLessThan(ClassicalDenoise.encodedCeiling * 4, halfMax)
        }
    }

    /// The GPU stage must shrink with the reference's own thresholds. Re-deriving them
    /// in the graph is exactly how two paths end up disagreeing about what a slider
    /// means, so the plan carries the reference's array, scaled.
    func testTheGPUPlanCarriesTheReferenceThresholds() {
        let params = ClassicNR(luma: 55, chroma: 45, hotPixels: 20,
                               lumaDetail: 70, lumaContrast: 30,
                               colorDetail: 60, colorSmoothness: 80)
        // Two profiles on purpose. ISO 6400 needs no rescaling, so it cannot tell a
        // plan that forgot `encodedScale` from one that applied it; base ISO carries a
        // `2/a` four times larger and does need one. A test that only used the first
        // passed with the scale deleted.
        var sawARescale = false
        for iso in [100.0, 6400.0] {
            let denoise = ClassicalDenoise(params, profile: NoiseProfile.forISO(iso))
            let plan = denoise.gpuPlan(width: 512, height: 512)
            XCTAssertEqual(plan.levels, denoise.effectiveLevels(width: 512, height: 512))
            let luma = denoise.lumaThresholds(levels: plan.levels)
            let chroma = denoise.chromaThresholds(levels: plan.levels)
            XCTAssertEqual(plan.lumaThresholds.count, luma.count)
            for j in 0..<luma.count {
                XCTAssertEqual(plan.lumaThresholds[j], luma[j] * plan.encodedScale,
                               accuracy: 1e-12, "ISO \(iso) luma band \(j)")
                XCTAssertEqual(plan.chromaThresholds[j], chroma[j] * plan.encodedScale,
                               accuracy: 1e-12, "ISO \(iso) chroma band \(j)")
            }
            XCTAssertGreaterThan(luma[0], 0)
            XCTAssertGreaterThan(chroma[0], 0)
            XCTAssertEqual(plan.chromaProtection, 0.6, accuracy: 1e-12)
            XCTAssertEqual(plan.lumaProtection, ClassicalDenoise.lumaEdgeProtection,
                           accuracy: 1e-12)
            XCTAssertEqual(plan.hotPixelK, ClassicalDenoise.hotPixelK(20),
                           accuracy: 1e-12)
            if abs(plan.encodedScale - 1) > 1e-6 { sawARescale = true }
        }
        XCTAssertTrue(sawARescale,
                      "no profile here needed rescaling, so this proves nothing about "
                          + "the thresholds carrying the scale")
    }

    /// A preview is decoded small, and downsampling has already averaged the noise
    /// down. The profile follows, or the preview is denoised for noise that is no
    /// longer in it while the export is not.
    func testThePreviewProfileFollowsTheDecodeScale() {
        let denoise = ClassicalDenoise(ClassicNR(luma: 50, chroma: 50),
                                       profile: NoiseProfile.forISO(6400))
        let full = denoise.gpuPlan(width: 4000, height: 3000, noiseScale: 1)
        let preview = denoise.gpuPlan(width: 1280, height: 960, noiseScale: 0.32 * 0.32)
        XCTAssertEqual(preview.profile.a, full.profile.a * 0.32 * 0.32, accuracy: 1e-15)
        XCTAssertEqual(preview.profile.b, full.profile.b * 0.32 * 0.32, accuracy: 1e-18)
        // A scale above 1 would be a caller bug, and must not amplify the profile.
        let silly = denoise.gpuPlan(width: 100, height: 100, noiseScale: 4)
        XCTAssertEqual(silly.profile.a, full.profile.a, accuracy: 1e-15)
    }

    // MARK: - ISO-adaptive defaults

    func testISODefaultsResolveEverySubSlider() {
        let low = ISODefaults.classic(forISO: 200)
        let high = ISODefaults.classic(forISO: 25600)
        XCTAssertGreaterThan(high.luma, low.luma)
        XCTAssertGreaterThan(high.chroma, low.chroma)
        // The two departures docs/07 §2.1 names: less texture preservation and more
        // blotch suppression where there is more gain. Strictly, so a flat table fails.
        XCTAssertLessThan(high.lumaDetail, low.lumaDetail)
        XCTAssertGreaterThan(high.colorSmoothness, low.colorSmoothness)
        // And the two that stay at Lightroom's defaults, because nothing measured says
        // otherwise.
        XCTAssertEqual(low.lumaContrast, 0, accuracy: 1e-12)
        XCTAssertEqual(high.lumaContrast, 0, accuracy: 1e-12)
        XCTAssertEqual(low.colorDetail, 50, accuracy: 1e-12)
        XCTAssertEqual(high.colorDetail, 50, accuracy: 1e-12)
        // Hot Pixels is a defect control, and defects do not scale with gain.
        XCTAssertEqual(high.hotPixels, 0, accuracy: 1e-12)
        // Everything lands inside its slider's range.
        for block in [low, high] {
            for value in [block.luma, block.chroma, block.lumaDetail,
                          block.lumaContrast, block.colorDetail,
                          block.colorSmoothness, block.hotPixels] {
                XCTAssertTrue(value >= 0 && value <= 100, "\(value) is off the slider")
            }
        }
    }

    func testStartingDenoiseIsAdaptiveWithAnISOAndFlatWithout() {
        let unknown = ISODefaults.startingDenoise(forISO: nil)
        XCTAssertEqual(unknown, Denoise(), "a file with no ISO got an invented profile")

        let shot = ISODefaults.startingDenoise(forISO: 6400)
        XCTAssertEqual(shot.mode, .classic)
        XCTAssertEqual(shot.classic.luma, ISODefaults.luminance(forISO: 6400),
                       accuracy: 1e-12)
        XCTAssertEqual(shot.classic.chroma, ISODefaults.color(forISO: 6400),
                       accuracy: 1e-12)
        XCTAssertGreaterThan(shot.classic.luma, 0,
                             "ISO 6400 started with no luminance NR at all")
        // Hostile input must not produce a hostile recipe.
        for iso in [0.0, -100, .infinity, .nan] {
            XCTAssertEqual(ISODefaults.startingDenoise(forISO: iso), Denoise(),
                           "ISO \(iso) produced something other than the flat defaults")
        }
    }

    /// The mode switch resolves before the engine sees it: Off is off including Hot
    /// Pixels, AI drops the adaptive rows so Tier 1 finishes rather than compensating
    /// twice, and Classic is left exactly as the panel shows it.
    func testTheModeSwitchResolvesThroughISODefaults() {
        let block = ClassicNR(luma: 40, chroma: 50, hotPixels: 30)

        let off = ISODefaults.classic(for: Denoise(mode: .off, classic: block))
        XCTAssertEqual(off.luma, 0, accuracy: 1e-12)
        XCTAssertEqual(off.chroma, 0, accuracy: 1e-12)
        XCTAssertEqual(off.hotPixels, 0, accuracy: 1e-12)

        let classic = ISODefaults.classic(for: Denoise(mode: .classic, classic: block))
        XCTAssertEqual(classic, block)

        let ai = ISODefaults.classic(for: Denoise(mode: .ai, classic: block))
        XCTAssertEqual(ai.luma, 0, accuracy: 1e-12)
        XCTAssertEqual(ai.chroma, 0, accuracy: 1e-12)
        XCTAssertEqual(ai.hotPixels, 30, accuracy: 1e-12,
                       "a defect control was zeroed by the AI coupling")
        // The hand-set exception, through the mechanism the shipping path uses. This
        // used to pass `lumaUserSet: true` as an argument — a parameter with a `false`
        // default that `RenderPlan` never supplied, so the assertion proved the
        // exception could be reached and NOT that anything reached it. The bit now
        // lives on the recipe, which is the only place a photograph can carry it.
        var handSet = block
        handSet.lumaUserSet = true
        let held = ISODefaults.classic(for: Denoise(mode: .ai, classic: handSet))
        XCTAssertEqual(held.luma, 40, accuracy: 1e-12,
                       "a hand-set Luminance was overwritten by the AI coupling")
        XCTAssertEqual(held.chroma, 0, accuracy: 1e-12,
                       "an inherited Colour survived the AI coupling because the OTHER "
                           + "master was hand-set")
        // The sub-sliders shape whichever master survives, and the coupling has no
        // business resetting them: it used to rebuild the block from three fields, so
        // switching to AI also silently reverted Colour Smoothness to 50.
        XCTAssertEqual(held.colorSmoothness, block.colorSmoothness, accuracy: 1e-12)
        XCTAssertEqual(held.lumaDetail, block.lumaDetail, accuracy: 1e-12)
    }

    /// The defect this closes was at a CALL SITE, not in the coupling, so the pin is on
    /// the plan the graph actually runs.
    func testAHandSetMasterSurvivesTheAIModeCouplingOnTheShippingPath() {
        var recipe = Recipe()
        recipe.develop.denoise = ISODefaults.startingDenoise(forISO: 6400)
        recipe.develop.denoise.mode = .ai
        // Inherited from the ISO table: AI zeroes both.
        let inherited = RenderPlan(recipe: recipe, captureISO: 6400)
        XCTAssertEqual(inherited.classicalDenoise.luma, 0, accuracy: 1e-12)
        XCTAssertEqual(inherited.classicalDenoise.chroma, 0, accuracy: 1e-12)

        // Hand-set: respected, which is what docs/07 §2.1 says and what the shipping
        // path did not do.
        recipe.develop.denoise.classic.luma = 42
        recipe.develop.denoise.classic.lumaUserSet = true
        let held = RenderPlan(recipe: recipe, captureISO: 6400)
        XCTAssertEqual(held.classicalDenoise.luma, 42, accuracy: 1e-12,
                       "switching to AI zeroed a hand-set Luminance on the render path")
        XCTAssertEqual(held.classicalDenoise.chroma, 0, accuracy: 1e-12,
                       "an inherited Colour was not zeroed")
    }

    // MARK: - The plan the graph actually reads

    func testTheRenderPlanCarriesAnEngineTheGraphCanRun() {
        var recipe = Recipe()
        recipe.develop.denoise = ISODefaults.startingDenoise(forISO: 6400)
        let plan = RenderPlan(recipe: recipe, captureISO: 6400)
        XCTAssertFalse(plan.denoiseIsIdentity,
                       "a 6400 recipe resolved to a stage the graph will skip")
        XCTAssertEqual(plan.classicalDenoise.luma, recipe.develop.denoise.classic.luma,
                       accuracy: 1e-12)
        XCTAssertEqual(plan.classicalDenoise.colorSmoothness,
                       recipe.develop.denoise.classic.colorSmoothness, accuracy: 1e-12)
        // The profile follows the ISO, which is what makes every threshold mean
        // something. Same recipe, two bodies' worth of gain, two different σ.
        let quiet = RenderPlan(recipe: recipe, captureISO: 100)
        XCTAssertGreaterThan(plan.classicalDenoise.profile.sigma(at: 0.18),
                             quiet.classicalDenoise.profile.sigma(at: 0.18) * 3,
                             "the noise profile ignored the ISO")

        var offRecipe = Recipe()
        offRecipe.develop.denoise = Denoise(mode: .off, classic: ClassicNR(luma: 80,
                                                                          chroma: 80))
        XCTAssertTrue(RenderPlan(recipe: offRecipe, captureISO: 6400).denoiseIsIdentity,
                      "Off still runs the stage")
    }

    // MARK: - Wire format

    /// Every recipe already written to a catalog or a sidecar predates the four
    /// sub-sliders. A strict decode would fail on all of them.
    func testTheOlderThreeFieldClassicNRStillDecodes() throws {
        let json = #"{"luma": 30, "chroma": 40, "hotPixels": 10}"#
        let decoded = try JSONDecoder().decode(ClassicNR.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.luma, 30, accuracy: 1e-12)
        XCTAssertEqual(decoded.chroma, 40, accuracy: 1e-12)
        XCTAssertEqual(decoded.hotPixels, 10, accuracy: 1e-12)
        // The four that were engine constants become the same numbers on the wire, so
        // an old recipe renders what it always rendered.
        XCTAssertEqual(decoded.lumaDetail, 50, accuracy: 1e-12)
        XCTAssertEqual(decoded.lumaContrast, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.colorDetail, 50, accuracy: 1e-12)
        XCTAssertEqual(decoded.colorSmoothness, 50, accuracy: 1e-12)
    }

    func testAllSevenFieldsSurviveARoundTrip() throws {
        let block = ClassicNR(luma: 12, chroma: 34, hotPixels: 56,
                              lumaDetail: 78, lumaContrast: 90,
                              colorDetail: 11, colorSmoothness: 22,
                              lumaUserSet: true, chromaUserSet: true)
        let data = try JSONEncoder().encode(block)
        XCTAssertEqual(try JSONDecoder().decode(ClassicNR.self, from: data), block)
    }

    /// The two `userSet` bits are a format addition, so the compatibility direction
    /// matters more than the round trip: every recipe already in a catalog or a sidecar
    /// was written without them and must decode as "never hand-set", which is what the
    /// AI coupling has been assuming about every photo.
    func testARecipeWrittenBeforeTheUserSetBitsDecodesAsNeverHandSet() throws {
        let json = Data("""
        {"luma":40,"chroma":55,"hotPixels":0,"lumaDetail":42,"lumaContrast":0,\
        "colorDetail":50,"colorSmoothness":84}
        """.utf8)
        let block = try JSONDecoder().decode(ClassicNR.self, from: json)
        XCTAssertEqual(block.luma, 40, accuracy: 1e-12)
        XCTAssertFalse(block.lumaUserSet)
        XCTAssertFalse(block.chromaUserSet)
        // And it costs nothing on the wire: a default block still serializes to the
        // empty canonical form, so no stored fingerprint moves.
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(Recipe()),
                       "{\"pipelineVersion\":\(currentPipelineVersion)}")
    }
}
