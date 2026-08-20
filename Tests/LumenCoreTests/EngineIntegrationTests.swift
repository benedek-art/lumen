// EngineIntegrationTests.swift
// Contracts for the image-processing engines. Like the colour-science suite, these
// assert properties rather than numbers: perfect reconstruction, identity when the
// sliders are at zero, edges surviving an edge-aware filter, and the fold semantics
// masks are built on. Those are the things a refactor must not break, and they are
// checkable without a reference image.

import XCTest
@testable import LumenCore

final class EngineIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private func ramp(width: Int = 32, height: Int = 8) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            RGB(gray: 0.18 * pow(2, -8 + u * 12))
        }
    }

    private func flatPlane(_ value: Double, width: Int = 24, height: Int = 24) -> Plane {
        Plane(width: width, height: height, fill: value)
    }

    private func edgePlane(width: Int = 48, height: Int = 16) -> Plane {
        Plane(width: width, height: height) { u, v in
            let base = u < 0.5 ? 0.2 : 0.8
            return base + sin(u * 197) * cos(v * 131) * 0.02
        }
    }

    // MARK: - Spatial ops

    func testBoxBlurOfAConstantIsTheConstant() {
        let blurred = SpatialOps.boxBlur(flatPlane(0.42), radius: 5)
        let range = blurred.range
        XCTAssertEqual(range.min, 0.42, accuracy: 1e-6)
        XCTAssertEqual(range.max, 0.42, accuracy: 1e-6)
    }

    func testGaussianBlurPreservesTheMean() {
        let plane = edgePlane()
        let blurred = SpatialOps.gaussianBlur(plane, sigma: 3)
        XCTAssertEqual(blurred.mean, plane.mean, accuracy: 0.01)
    }

    func testGuidedFilterOfAConstantIsTheConstant() {
        let plane = flatPlane(0.3)
        let filtered = SpatialOps.guidedFilter(input: plane, guide: plane,
                                               radius: 4, epsilon: 0.001)
        let range = filtered.range
        XCTAssertEqual(range.min, 0.3, accuracy: 1e-5)
        XCTAssertEqual(range.max, 0.3, accuracy: 1e-5)
    }

    /// A step edge with checkerboard noise on both plateaus, at an amplitude stated as
    /// a multiple of the filter's own threshold. Built by index rather than through the
    /// `(u, v)` generator so the reference implementation can construct the identical
    /// plane and the two can be compared value for value.
    private func stepWithNoise(amplitude: Double,
                               width: Int = 48, height: Int = 16) -> Plane {
        var plane = Plane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let base = x < width / 2 ? 0.2 : 0.8
                plane[x, y] = base + ((x + y) % 2 == 0 ? amplitude : -amplitude)
            }
        }
        return plane
    }

    /// Largest peak-to-peak excursion within either plateau, away from the borders and
    /// the step — what "smoothed" and "preserved" are both measured as.
    private func plateauSwing(_ plane: Plane) -> Double {
        var swing = 0.0
        for range in [4..<(plane.width / 2 - 6), (plane.width / 2 + 6)..<(plane.width - 4)] {
            var lo = Double.infinity
            var hi = -Double.infinity
            for y in 4..<(plane.height - 4) {
                for x in range {
                    lo = Swift.min(lo, plane[x, y])
                    hi = Swift.max(hi, plane[x, y])
                }
            }
            swing = Swift.max(swing, hi - lo)
        }
        return swing
    }

    private func stepHeight(_ plane: Plane) -> Double {
        var left = 0.0, right = 0.0, n = 0.0
        for y in 4..<(plane.height - 4) {
            for x in 4..<(plane.width / 2 - 6) { left += plane[x, y] }
            for x in (plane.width / 2 + 6)..<(plane.width - 4) { right += plane[x, y] }
            n += Double(plane.width / 2 - 10)
        }
        return right / n - left / n
    }

    /// The property the tone stage depends on: smooth inside a surface, sharp across an
    /// edge. A filter that fails this haloes, which is the exact artefact Lumen's tone
    /// engine exists to avoid.
    ///
    /// Stated as `epsilon`'s documented semantics — it is a VARIANCE threshold in the
    /// guide's own units, so the filter smooths anything flatter than √ε and keeps
    /// anything above it — and measured against the input rather than against absolute
    /// levels. Both halves are needed: "noise was attenuated" alone is satisfied by a
    /// filter that flattens everything, and "the edge survived" alone is satisfied by a
    /// filter that does nothing.
    ///
    /// The version this replaces asserted absolute levels on a plane whose plateaus were
    /// already at 0.2 and 0.8 with noise of ±0.02 against a 0.03 tolerance. Every one of
    /// its three assertions passed on `guidedFilter` returning its input unchanged
    /// (0.2177 < 0.32, 0.7823 > 0.68, 0.0228 < 0.03) — it certified a filter that could
    /// have been doing nothing at all, for the four features that depend on this one.
    func testGuidedFilterSmoothsBelowItsThresholdAndKeepsDetailAbove() {
        let epsilon = 0.0008
        let threshold = epsilon.squareRoot()

        let quiet = stepWithNoise(amplitude: threshold / 4)
        let smoothed = SpatialOps.guidedFilter(input: quiet, guide: quiet,
                                               radius: 4, epsilon: epsilon)
        let quietRatio = plateauSwing(smoothed) / plateauSwing(quiet)
        XCTAssertLessThan(quietRatio, 0.35,
                          "noise well under √ε survived at \(quietRatio) of its input "
                              + "swing; an identity filter scores 1.0")

        let loud = stepWithNoise(amplitude: threshold * 3.5)
        let kept = SpatialOps.guidedFilter(input: loud, guide: loud,
                                           radius: 4, epsilon: epsilon)
        let loudRatio = plateauSwing(kept) / plateauSwing(loud)
        XCTAssertGreaterThan(loudRatio, 0.5,
                             "detail well over √ε was smoothed away, surviving at only "
                                 + "\(loudRatio) of its input swing")

        // The edge is the thing neither pass may cost. Measured as the difference of
        // the plateau means, so noise on either side cancels out of it.
        for (label, plane) in [("quiet", smoothed), ("loud", kept)] {
            XCTAssertGreaterThan(stepHeight(plane), 0.48,
                                 "the \(label) pass smeared the step to "
                                     + "\(stepHeight(plane)) of 0.6")
        }

        // No overshoot: the whole reason this is an affine model and not a bilateral.
        // Only meaningful on the quiet plane, whose input stays inside [0.19, 0.81].
        let range = smoothed.range
        XCTAssertGreaterThan(range.min, 0.18, "guided filter undershot the dark plateau")
        XCTAssertLessThan(range.max, 0.82, "guided filter overshot the bright plateau")
    }

    /// A constant plane is a fixed point of the box blur at every radius, borders
    /// included — the exact normalization the whole edge convention rests on, and what
    /// makes a radius wider than the image degenerate to the mean rather than to a
    /// darkened frame.
    func testBoxBlurIsAFixedPointOfAConstantAtEveryRadius() {
        for radius in [1, 3, 8, 40] {
            let blurred = SpatialOps.boxBlur(flatPlane(0.37), radius: radius)
            let range = blurred.range
            XCTAssertEqual(range.min, 0.37, accuracy: 1e-6,
                           "constant plane darkened at radius \(radius)")
            XCTAssertEqual(range.max, 0.37, accuracy: 1e-6,
                           "constant plane brightened at radius \(radius)")
        }
    }

    /// `gaussianBlur` has a real early-out at σ ≤ 0.05, so "returns its input" is a live
    /// code path rather than a hypothetical — and the mean-preservation test above it
    /// cannot tell the two apart. An impulse is the cheapest thing that can.
    func testGaussianBlurActuallyBlurs() {
        let sigma = 3.0
        var impulse = Plane(width: 41, height: 41)
        impulse[20, 20] = 1
        let blurred = SpatialOps.gaussianBlur(impulse, sigma: sigma)

        // Total energy is preserved — a blur redistributes, it does not consume.
        // The three box passes span ±7 px, well inside a 41×41 plane, so no energy
        // leaves the frame and this is an equality rather than a bound.
        var sum = 0.0
        for y in 0..<41 { for x in 0..<41 { sum += blurred[x, y] } }
        XCTAssertEqual(sum, 1.0, accuracy: 1e-5, "the blur lost energy")

        // Measured against the reference implementation rather than guessed: the peak
        // lands 2.3% under the true Gaussian's 1/(2πσ²), one σ out holds 0.652 of the
        // peak, and three σ out is exactly zero because the box support ends at 7 px.
        // Ten percent, 0.4 and 0.05 leave room for the approximation without leaving
        // room for the identity, which puts 1.0 at the peak and 0 everywhere else.
        let peak = blurred[20, 20]
        let ideal = 1 / (2 * Double.pi * sigma * sigma)
        XCTAssertEqual(peak, ideal, accuracy: ideal * 0.10,
                       "peak \(peak) is not the \(ideal) a σ=\(sigma) blur gives")
        XCTAssertGreaterThan(blurred[20 + Int(sigma), 20], peak * 0.4,
                             "nothing reached one σ out — this is not a σ=3 blur")
        XCTAssertLessThan(blurred[20 + 3 * Int(sigma), 20], peak * 0.05,
                          "energy reached three σ out — this is far wider than σ=3")
    }

    /// The à-trous stack must reconstruct exactly at unit gains, or every wavelet
    /// operation built on it introduces an error before it does any work.
    func testWaveletReconstructionIsExactAtUnitGains() {
        let plane = edgePlane(width: 64, height: 32)
        let decomposed = SpatialOps.atrousWavelet(plane, levels: 4)
        let gains = [Double](repeating: 1, count: decomposed.details.count)
        let rebuilt = SpatialOps.atrousReconstruct(details: decomposed.details,
                                                   residual: decomposed.residual,
                                                   gains: gains)
        var worst = 0.0
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                worst = Swift.max(worst, abs(rebuilt[x, y] - plane[x, y]))
            }
        }
        XCTAssertLessThan(worst, 1e-5, "wavelet reconstruction lost \(worst)")
    }

    /// Level `i` carries structure of roughly `2^(i+1)` px — the docstring's claim, and
    /// the entire reason Texture and Clarity can be different controls.
    ///
    /// The reconstruction test above cannot check this, or anything else about the
    /// kernel: `details[i] = current − smooth` followed by `current = smooth` makes the
    /// sum telescope to the input for ANY smoothing operator whatsoever. A wrong
    /// kernel, the wrong `1 << i` dilation, the wrong level count, even a `b3Spline`
    /// that returned its input (every detail band zero) — all reconstruct exactly. So
    /// exact reconstruction says the transform is invertible, and nothing more.
    ///
    /// A single spatial frequency in, and the band that holds it must be the band the
    /// docstring names. Measured against the reference implementation: a 4 px sinusoid
    /// puts 90% of its energy in level 0, and 8/16/32 px land in levels 1/2/3 with at
    /// least 3.6× the next-largest band.
    func testEachWaveletLevelCarriesTheScaleItClaims() {
        for (period, expectedLevel) in [(4.0, 0), (8.0, 1), (16.0, 2), (32.0, 3)] {
            var plane = Plane(width: 64, height: 64)
            for y in 0..<64 {
                for x in 0..<64 {
                    plane[x, y] = 0.5 + 0.2 * sin(2 * Double.pi * Double(x) / period)
                }
            }
            let stack = SpatialOps.atrousWavelet(plane, levels: 5)
            XCTAssertEqual(stack.details.count, 5, "wrong level count")

            // Interior only: the border is clamped, which puts energy at every scale.
            let energies = stack.details.map { band -> Double in
                var sum = 0.0
                for y in 16..<48 {
                    for x in 16..<48 { sum += band[x, y] * band[x, y] }
                }
                return sum
            }
            let peak = energies.firstIndex(of: energies.max()!)!
            XCTAssertEqual(peak, expectedLevel,
                           "a \(period) px sinusoid landed in level \(peak), not "
                               + "\(expectedLevel) — energies \(energies)")
            let runnerUp = energies.enumerated()
                .filter { $0.offset != peak }.map(\.element).max()!
            XCTAssertGreaterThan(energies[peak], runnerUp * 3,
                                 "level \(peak) holds only \(energies[peak]) against "
                                     + "\(runnerUp) next door — the bands are not "
                                     + "separating scales")
        }
    }

    /// A band gain is a pure coefficient scale — what makes Texture a recombination
    /// rather than a re-filter. Doubling one band must double exactly that band's
    /// contribution and leave every other one, and the residual, untouched.
    func testABandGainScalesOnlyThatBand() {
        let plane = edgePlane(width: 64, height: 32)
        let stack = SpatialOps.atrousWavelet(plane, levels: 4)
        let unit = [Double](repeating: 1, count: stack.details.count)

        var doubled = unit
        doubled[1] = 2
        let boosted = SpatialOps.atrousReconstruct(details: stack.details,
                                                   residual: stack.residual,
                                                   gains: doubled)
        var zeroed = unit
        zeroed[1] = 0
        let removed = SpatialOps.atrousReconstruct(details: stack.details,
                                                   residual: stack.residual,
                                                   gains: zeroed)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                // boosted − original == original − removed == the band itself.
                XCTAssertEqual(boosted[x, y] - plane[x, y], stack.details[1][x, y],
                               accuracy: 1e-5,
                               "gain 2 on level 1 did not add exactly that band")
                XCTAssertEqual(plane[x, y] - removed[x, y], stack.details[1][x, y],
                               accuracy: 1e-5,
                               "gain 0 on level 1 did not remove exactly that band")
            }
        }
    }

    func testUnsharpMaskOfAConstantChangesNothing() {
        let sharpened = SpatialOps.unsharpMask(flatPlane(0.5), sigma: 2,
                                               amount: 1, threshold: 0)
        XCTAssertEqual(sharpened.mean, 0.5, accuracy: 1e-5)
    }

    // MARK: - Detail engine

    func testPresenceAtZeroIsIdentity() {
        let source = ramp()
        let decomposition = DetailEngine.Decomposition(image: source, workingRadius: 4)
        let out = DetailEngine.apply(source, detail: Detail(), decomposition: decomposition)
        // Bit-exact, not "close": all three sub-stages guard on their amount and return
        // the input untouched, so 1e-5 was room for a clip to hide in.
        XCTAssertLessThan(out.maxAbsDifference(source), 1e-12)
    }

    func testTextureChangesLocalContrastWithoutMovingTheMean() {
        let source = ImageBuffer(width: 48, height: 16) { u, v in
            RGB(gray: 0.25 + sin(u * 60) * cos(v * 40) * 0.04)
        }
        let decomposition = DetailEngine.Decomposition(image: source, workingRadius: 6)
        var detail = Detail()
        detail.texture = 80
        let out = DetailEngine.apply(source, detail: detail, decomposition: decomposition)
        XCTAssertGreaterThan(out.maxAbsDifference(source), 1e-4, "Texture did nothing")

        let before = source.luminancePlane().mean
        let after = out.luminancePlane().mean
        XCTAssertEqual(after, before, accuracy: before * 0.12,
                       "Texture moved the overall exposure")
    }

    func testVignetteDarkensTheCornersAndLeavesTheCentre() {
        let source = ImageBuffer(width: 32, height: 32) { _, _ in RGB(gray: 0.5) }
        let out = DetailEngine.vignette(source, ev: -2)

        // Bit-identical, not "within 12%". The falloff smoothsteps from an inner radius
        // of 0.375, and `vignette` `continue`s wherever that is zero, so the centre is
        // literally not written. A 0.06 tolerance on a 0.5 value certified nothing: a
        // vignette that darkened the ENTIRE frame by 11% passed both assertions.
        XCTAssertEqual(out[16, 16].g, 0.5, accuracy: 0,
                       "the centre pixel was touched at all")
        XCTAssertLessThan(out[0, 0].g, 0.4, "corner did not darken")

        // And it is a vignette, not an exposure change: the darkening has to grow
        // outward from an untouched middle, so the frame's mean must fall while the
        // inner region stays exactly where it was.
        for (x, y) in [(16, 16), (14, 16), (16, 18), (18, 14)] {
            XCTAssertEqual(out[x, y].g, 0.5, accuracy: 0,
                           "the inner region moved at (\(x), \(y))")
        }
        var previous = 0.5
        for step in 0...15 {
            let value = out[16 - step, 16 - step].g
            XCTAssertLessThanOrEqual(value, previous + 1e-9,
                                     "the vignette brightened on the way to the corner")
            previous = value
        }
        XCTAssertLessThan(out.luminancePlane().mean, source.luminancePlane().mean,
                          "the vignette did not darken the frame at all")
    }

    // MARK: - Blob references

    /// The reference gate is untrusted-input handling: a `blob:` ref can arrive from a
    /// sidecar another tool wrote, and `../../` is a valid string. The reference
    /// implementation checks fifteen hostile vectors against its mirror of this
    /// function; until now the Swift it mirrors was checked against none of them.
    func testBlobReferencesThatWereNotWrittenHereAreRefused() {
        XCTAssertEqual(BlobStore.filename(for: "blob:xxh64:0123456789abcdef"),
                       "xxh64-0123456789abcdef.blob", "a valid reference was refused")

        let hostile = [
            "blob:xxh64:../../../etc/pas",      // right length, path characters
            "blob:xxh64:0123456789ABCDEF",      // uppercase
            "blob:xxh64:0123456789abcde",       // short
            "blob:xxh64:0123456789abcdef0",     // long
            "blob:xxh64:0123456789abcde/",      // a separator
            "blob:sha256:0123456789abcdef",     // wrong algorithm
            "blob:xxh64:0123456789abcde\u{0}",  // NUL
            "xxh64:0123456789abcdef",           // no scheme
            "blob:xxh64:",                      // empty digest
            "blob:xxh64:0123456789abcdef:x",    // extra component
            "",                                 // empty
            "blob:xxh64:０１２３４５６７89abcdef", // fullwidth digits: Unicode Hex_Digit
            "blob:xxh64:0123456789abcd f",     // embedded space
            "blob:xxh64:0123456789abcd.f",      // a dot
            "blob::0123456789abcdef",           // empty algorithm
        ]
        for ref in hostile {
            XCTAssertNil(BlobStore.filename(for: ref),
                         "a hostile reference was turned into a path: \(ref)")
        }
    }

    // MARK: - Denoise

    func testVSTRoundTrip() {
        let profile = NoiseProfile.forISO(3200)
        for x in [0.0, 0.001, 0.05, 0.4, 2.0] {
            let round = VST.algebraicInverse(VST.forward(x, profile: profile),
                                             profile: profile)
            XCTAssertEqual(round, x, accuracy: Swift.max(abs(x) * 1e-4, 1e-6), "at \(x)")
        }
    }

    func testVSTStabilizesVariance() {
        // The whole point of the transform: noise amplitude should stop depending on
        // signal level. Compare the transform's local slope against the noise sigma.
        let profile = NoiseProfile.forISO(6400)
        var ratios: [Double] = []
        for signal in [0.02, 0.1, 0.5] {
            let sigma = profile.sigma(at: signal)
            guard sigma > 0 else { continue }
            let spread = VST.forward(signal + sigma, profile: profile)
                - VST.forward(signal, profile: profile)
            ratios.append(spread)
        }
        guard let first = ratios.first, ratios.count > 1 else {
            return XCTFail("not enough sample points")
        }
        for r in ratios {
            XCTAssertEqual(r, first, accuracy: first * 0.2,
                           "VST did not stabilize variance across signal levels")
        }
    }

    func testClassicalDenoiseAtZeroIsIdentity() {
        let source = ramp()
        let engine = ClassicalDenoise(ClassicNR(luma: 0, chroma: 0, hotPixels: 0),
                                      profile: NoiseProfile.forISO(100),
                                      isoDefaults: false)
        let out = engine.apply(source)
        // Bit-exact for the same reason: with no hot-pixel pass and both shrinkage
        // constants at zero, `apply` returns its input.
        XCTAssertLessThan(out.maxAbsDifference(source), 1e-12)
    }

    func testClassicalDenoiseReducesNoiseInAFlatPatch() {
        let noisy = ImageBuffer(width: 48, height: 48) { u, v in
            let n = (sin(u * 913) * cos(v * 727) + sin(u * 331 + v * 517)) * 0.012
            return RGB(gray: 0.2 + n)
        }
        let engine = ClassicalDenoise(ClassicNR(luma: 70, chroma: 60, hotPixels: 0),
                                      profile: NoiseProfile.forISO(6400),
                                      isoDefaults: false)
        let out = engine.apply(noisy)
        let before = standardDeviation(noisy.luminancePlane())
        let after = standardDeviation(out.luminancePlane())
        XCTAssertLessThan(after, before, "denoise increased the noise")
    }

    func testAIBlendIsInstantAndLinear() {
        let original = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.2) }
        let denoised = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.4) }
        let splice = AIDenoiseSplice()
        XCTAssertEqual(splice.blend(original: original, denoised: denoised, amount: 0)[0, 0].g,
                       0.2, accuracy: 1e-6)
        XCTAssertEqual(splice.blend(original: original, denoised: denoised, amount: 100)[0, 0].g,
                       0.4, accuracy: 1e-6)
        XCTAssertEqual(splice.blend(original: original, denoised: denoised, amount: 50)[0, 0].g,
                       0.3, accuracy: 1e-6)
    }

    /// Overlap-discard bugs are the classic silent export corrupter, so the plan is
    /// asserted to cover the frame exactly — no gaps, no double-writes.
    func testTilePlanCoversTheFrameExactly() {
        for (w, h) in [(1000, 700), (2048, 2048), (61, 37), (5000, 3333)] {
            let tiles = TilePlan.plan(width: w, height: h, tile: 512, overlap: 32)
            XCTAssertTrue(TilePlan.coversExactly(tiles, width: w, height: h),
                          "tiling did not cover \(w)×\(h) exactly")
        }
    }

    func testISODefaultsIncreaseWithISO() {
        let low = ISODefaults.classic(forISO: 100)
        let high = ISODefaults.classic(forISO: 12800)
        // Strictly greater. `>=` is satisfied by a flat table, and that is not a
        // hypothetical here: `aiAmountAnchors` IS deliberately flat over part of its
        // range, so flattening `luminanceAnchors` the same way is a plausible edit this
        // would have waved through.
        XCTAssertGreaterThan(high.chroma, low.chroma)
        XCTAssertGreaterThan(high.luma, low.luma)

        // And the worked example the anchors state: the curve is linear in log2(ISO)
        // between (400, 0) and (6400, 25), so ISO 3200 sits three quarters of the way
        // along at 18.75. A number, not a direction.
        XCTAssertEqual(ISODefaults.luminance(forISO: 3200), 18.75, accuracy: 0.01)
        // Below the first anchor and above the last, the curve holds rather than
        // extrapolating into nonsense.
        XCTAssertEqual(ISODefaults.luminance(forISO: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(ISODefaults.luminance(forISO: 102400), 40, accuracy: 1e-9)
    }

    private func standardDeviation(_ plane: Plane) -> Double {
        let mean = plane.mean
        var acc = 0.0
        for v in plane.values {
            let d = Double(v) - mean
            acc += d * d
        }
        return (acc / Double(Swift.max(plane.values.count, 1))).squareRoot()
    }

    // MARK: - Masks

    func testLinearGradientIsMonotoneAlongItsAxis() {
        var component = MaskComponent(op: .add, kind: .linear)
        component.line = [0.2, 0.5, 0.8, 0.5]
        let plane = MaskRaster.rasterize(component: component,
                                         size: (width: 64, height: 16))
        var previous = -1.0
        for x in 0..<64 {
            let v = plane[x, 8]
            XCTAssertGreaterThanOrEqual(v, previous - 1e-6, "gradient reversed at \(x)")
            previous = v
        }
        XCTAssertLessThan(plane[2, 8], 0.05)
        XCTAssertGreaterThan(plane[61, 8], 0.95)
    }

    func testRadialIsStrongestAtItsCentre() {
        var component = MaskComponent(op: .add, kind: .radial)
        component.center = [0.5, 0.5]
        component.radii = [0.3, 0.3]
        component.feather = 50
        let plane = MaskRaster.rasterize(component: component,
                                         size: (width: 32, height: 32))
        XCTAssertGreaterThan(plane[16, 16], 0.9)
        XCTAssertLessThan(plane[0, 0], 0.1)
    }

    /// Feather has to produce an actual gradient, not just move a hard edge.
    ///
    /// It did not. `radialPlane`'s falloff branch read `smoothstep(1, rin, r)`, and
    /// `Num.smoothstep` guards a reversed edge pair with `if e1 <= e0 { return x < e0 ?
    /// 0 : 1 }` — `rin` is always below 1, so that branch fired on every call and
    /// returned 0 across the whole falloff. The mask was a hard-edged ellipse at every
    /// Feather setting; the slider only shrank the opaque core. The test above cannot
    /// see it, since 1 at the centre and 0 at the corner are true either way.
    func testFeatherProducesAGradientAndNotJustASmallerHardEdge() {
        var component = MaskComponent(op: .add, kind: .radial)
        component.center = [0.5, 0.5]
        component.radii = [0.35, 0.35]
        component.feather = 80
        let plane = MaskRaster.rasterize(component: component,
                                         size: (width: 64, height: 64))

        // Walking out from the centre, alpha must fall through intermediate values
        // rather than stepping straight from 1 to 0.
        var partial = 0
        var previous = 1.0
        for x in 32..<64 {
            let alpha = plane[x, 32]
            XCTAssertLessThanOrEqual(alpha, previous + 1e-6,
                                     "the mask brightened on the way out at x=\(x)")
            if alpha > 0.02 && alpha < 0.98 { partial += 1 }
            previous = alpha
        }
        XCTAssertGreaterThan(partial, 6,
                             "only \(partial) pixels along the radius were partially "
                                 + "covered — Feather 80 is drawing a hard edge")

        // A wider feather must reach further in, or the control does nothing.
        component.feather = 20
        let tight = MaskRaster.rasterize(component: component,
                                         size: (width: 64, height: 64))
        XCTAssertGreaterThan(tight[40, 32], plane[40, 32],
                             "Feather 20 was no more opaque mid-falloff than Feather 80")
    }

    /// The same bug lived in `stampProfile`, so every brush stamp was a hard-edged
    /// disc and a soft brush painted aliased edges.
    func testBrushStampsHaveASoftShoulder() {
        var partial = 0
        var previous = 1.0
        for step in 0...40 {
            let rho = Double(step) / 40
            let alpha = MaskRaster.stampProfile(rho, hardness: 0.2)
            XCTAssertLessThanOrEqual(alpha, previous + 1e-9,
                                     "the stamp brightened outward at rho \(rho)")
            if alpha > 0.02 && alpha < 0.98 { partial += 1 }
            previous = alpha
        }
        XCTAssertGreaterThan(partial, 20,
                             "only \(partial) of 41 samples across the stamp were "
                                 + "partially covered — the shoulder is a step")
        // The endpoints still meet the flat core and the rim exactly.
        XCTAssertEqual(MaskRaster.stampProfile(0.2, hardness: 0.2), 1, accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.stampProfile(1, hardness: 0.2), 0, accuracy: 1e-12)
    }

    // MARK: - Mask refinement

    /// `levels` — the density remap at the end of the refine chain.
    ///
    /// Nothing in the suite referenced `refine.` at all, so all six controls of that
    /// panel were untested. This one is a pure function, so it can be pinned exactly.
    func testMaskLevelsRemapsDensityTheWayItDocuments() {
        // Identity at the defaults, in both spellings of "full range". Accepting 0…1
        // and 0…100 as the same thing is a documented affordance, and a wire value that
        // silently meant a different range would rewrite every saved mask.
        for hi in [1.0, 100.0] {
            for v in [0.0, 0.25, 0.5, 0.75, 1.0] {
                XCTAssertEqual(MaskRaster.levels(v, lo: 0, hi: hi, gamma: 1), v,
                               accuracy: 1e-12, "levels moved \(v) at hi=\(hi)")
            }
        }

        // A window maps its endpoints to 0 and 1 and its midpoint to the middle.
        XCTAssertEqual(MaskRaster.levels(0.25, lo: 25, hi: 75, gamma: 1), 0,
                       accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.levels(0.75, lo: 25, hi: 75, gamma: 1), 1,
                       accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.levels(0.5, lo: 25, hi: 75, gamma: 1), 0.5,
                       accuracy: 1e-12)
        // Outside the window it saturates rather than extrapolating.
        XCTAssertEqual(MaskRaster.levels(0.1, lo: 25, hi: 75, gamma: 1), 0,
                       accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.levels(0.9, lo: 25, hi: 75, gamma: 1), 1,
                       accuracy: 1e-12)

        // γ > 1 raises density, γ < 1 lowers it — the direction the doc comment states,
        // and the one a user reads off the slider.
        for v in [0.2, 0.5, 0.8] {
            XCTAssertGreaterThan(MaskRaster.levels(v, lo: 0, hi: 100, gamma: 2), v,
                                 "gamma 2 did not raise density at \(v)")
            XCTAssertLessThan(MaskRaster.levels(v, lo: 0, hi: 100, gamma: 0.5), v,
                              "gamma 0.5 did not lower density at \(v)")
        }
        // The endpoints are fixed points of the gamma whatever it is.
        for gamma in [0.2, 0.5, 1.0, 2.0, 5.0] {
            XCTAssertEqual(MaskRaster.levels(0, lo: 0, hi: 100, gamma: gamma), 0,
                           accuracy: 1e-12)
            XCTAssertEqual(MaskRaster.levels(1, lo: 0, hi: 100, gamma: gamma), 1,
                           accuracy: 1e-12)
        }

        // hi ≤ lo collapses to a hard step rather than inverting: inversion is a
        // different control, and a mask that silently inverted on a dragged handle
        // would be the worst kind of surprise.
        XCTAssertEqual(MaskRaster.levels(0.3, lo: 60, hi: 40, gamma: 1), 0,
                       accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.levels(0.7, lo: 60, hi: 40, gamma: 1), 1,
                       accuracy: 1e-12)
        // And a non-finite input cannot produce a non-finite alpha.
        XCTAssertEqual(MaskRaster.levels(.nan, lo: 0, hi: 100, gamma: 1), 0,
                       accuracy: 1e-12)
    }

    func testRefineRadiusScalesWithTheFrame() {
        XCTAssertEqual(MaskRaster.refineRadius(feather: 0, longEdge: 2560), 0)
        // 2% of the long edge at Feather 100.
        XCTAssertEqual(MaskRaster.refineRadius(feather: 100, longEdge: 1000), 20)
        XCTAssertEqual(MaskRaster.refineRadius(feather: 50, longEdge: 1000), 10)
        // A radius that rounds below one pixel is no radius at all, not a radius of 0
        // that the guided filter would still be invoked for.
        XCTAssertEqual(MaskRaster.refineRadius(feather: 1, longEdge: 20), 0)
        XCTAssertEqual(MaskRaster.refineRadius(feather: .nan, longEdge: 1000), 0)
    }

    /// Edge and Blur, on a real mask: each must move it, in the direction its label
    /// promises, and neither may leave the 0…1 range a mask has to stay inside.
    func testEdgeShiftAndBlurMoveTheMaskInTheDirectionTheyClaim() {
        var component = MaskComponent(op: .add, kind: .radial)
        component.center = [0.5, 0.5]
        component.radii = [0.25, 0.25]
        component.feather = 10
        let base = MaskRaster.rasterize(component: component,
                                        size: (width: 96, height: 96))
        func coverage(_ p: Plane) -> Double { p.mean }

        let dilated = MaskRaster.edgeShifted(base, edge: 40, longEdge: 96)
        let eroded = MaskRaster.edgeShifted(base, edge: -40, longEdge: 96)
        // Measured against the reference: +40 grows coverage to 1.067× and −40 shrinks
        // it to 0.950×, so these thresholds have real margin on both sides while still
        // failing anything that leaves the mask alone.
        XCTAssertGreaterThan(coverage(dilated), coverage(base) * 1.03,
                             "Edge +40 did not grow the mask")
        XCTAssertLessThan(coverage(eroded), coverage(base) * 0.97,
                          "Edge −40 did not shrink the mask")
        XCTAssertEqual(coverage(MaskRaster.edgeShifted(base, edge: 0, longEdge: 96)),
                       coverage(base), accuracy: 1e-9, "Edge 0 moved the mask")

        for plane in [dilated, eroded] {
            let range = plane.range
            XCTAssertGreaterThanOrEqual(range.min, 0, "edge shift produced alpha < 0")
            XCTAssertLessThanOrEqual(range.max, 1, "edge shift produced alpha > 1")
        }

        // Blur widens the transition band without moving the mask's centre of mass
        // much — that is what distinguishes softening from dilating.
        let blurred = SpatialOps.gaussianBlur(base, sigma: 3)
        func partialFraction(_ p: Plane) -> Double {
            Double(p.values.filter { $0 > 0.02 && $0 < 0.98 }.count) / Double(p.values.count)
        }
        XCTAssertGreaterThan(partialFraction(blurred), partialFraction(base) * 1.5,
                             "blurring did not widen the transition band")
        XCTAssertEqual(coverage(blurred), coverage(base), accuracy: coverage(base) * 0.1,
                       "blurring changed how much of the frame the mask covers")
    }

    func testInvalidComponentRasterizesToNothingRatherThanCrashing() {
        let component = MaskComponent(op: .add, kind: .linear)  // no line
        let plane = MaskRaster.rasterize(component: component,
                                         size: (width: 8, height: 8))
        XCTAssertEqual(plane.range.max, 0, accuracy: 1e-9)
    }

    func testMaskAlgebraFoldSemantics() {
        // add = union, subtract = cut away, intersect = multiply, folded in order
        // from an accumulator that starts empty.
        let stack: [(op: MaskOp, invert: Bool, amount: Double, alpha: Double)] = [
            (.add, false, 100, 0.6),
            (.add, false, 100, 0.3),
        ]
        XCTAssertEqual(MaskAlgebra.combined(stack), 0.6, accuracy: 1e-9)

        let subtracting: [(op: MaskOp, invert: Bool, amount: Double, alpha: Double)] = [
            (.add, false, 100, 0.8),
            (.subtract, false, 100, 0.5),
        ]
        XCTAssertEqual(MaskAlgebra.combined(subtracting), 0.5, accuracy: 1e-9)

        let intersecting: [(op: MaskOp, invert: Bool, amount: Double, alpha: Double)] = [
            (.add, false, 100, 0.8),
            (.intersect, false, 100, 0.5),
        ]
        XCTAssertEqual(MaskAlgebra.combined(intersecting), 0.4, accuracy: 1e-9)

        // A stack that opens with subtract stays empty — same as Lightroom.
        let leading: [(op: MaskOp, invert: Bool, amount: Double, alpha: Double)] = [
            (.subtract, false, 100, 0.5),
        ]
        XCTAssertEqual(MaskAlgebra.combined(leading), 0, accuracy: 1e-9)
    }

    func testBrushStrokeSetRoundTrips() throws {
        let stroke = BrushStroke(points: [BrushPoint(x: 0.2, y: 0.3),
                                          BrushPoint(x: 0.4, y: 0.5)],
                                 size: 0.1, feather: 50, flow: 80, density: 100)
        let set = BrushStrokeSet(strokes: [stroke])
        let data = try set.encode()
        let decoded = try BrushStrokeSet.decode(data)
        XCTAssertEqual(decoded.strokes.count, 1)
        XCTAssertEqual(decoded.strokes[0].points.count, 2)
        XCTAssertEqual(decoded.strokes[0].size, 0.1, accuracy: 1e-9)
    }

    // MARK: - Film

    func testEveryStockAnchorsMidGrey() {
        for stock in FilmStock.all {
            let chain = FilmChain(FilmChain.defaultRecipe(for: stock), displayWhite: 1.0)
            let out = chain.apply(RGB(gray: 0.18))
            XCTAssertEqual(out.g, 0.18, accuracy: 0.01,
                           "\(stock.name) did not anchor mid-grey")
        }
    }

    /// Brighter scene, brighter picture — in every channel, at every setting the Film
    /// Lab panel can reach.
    ///
    /// This is the same rule that ToneEngine's Highlights and GradeEngine's colour
    /// wheels each broke independently: a gain applied through a tonal *window* can
    /// out-run the underlying slope inside that window and hand back a stretch of ramp
    /// that runs backwards, so a brighter subject prints darker. Film's windowed gains
    /// are the crossover tints — a density offset in the shadows, another in the
    /// highlights — and push/pull, which steepens the gammas with deliberate per-channel
    /// divergence. Nothing couples any of those to the curve's slope, so the safety is
    /// arithmetic (the tints are worth a few hundredths of a density unit against a
    /// negative spanning two) rather than enforced. Arithmetic changes when someone
    /// tunes a stock; this notices.
    ///
    /// Per channel, not just green: the tints and the push divergence are per-channel by
    /// construction, so red and blue are exactly where an inversion would appear first
    /// and the old green-only ramp was blind to it.
    func testNoStockEverPrintsABrighterSceneDarker() {
        for stock in FilmStock.all {
            for push in [-1.0, -0.5, 0.0, 1.0, 2.0] {
                for exposure in [-2.0, 0.0, 1.5, 3.0] {
                    // Strength is a straight mix against the neutral rendering, which is
                    // monotone in its own right, so a monotone chain stays monotone at
                    // every blend — 100 and one partial value is enough to catch a mix
                    // that is not the convex combination it claims to be.
                    for amount in [100.0, 45.0] {
                        var recipe = FilmChain.defaultRecipe(for: stock)
                        recipe.pushPull = push
                        recipe.amount = amount
                        let chain = FilmChain(recipe, filmExposure: exposure,
                                              displayWhite: 1.0)
                        let label = "\(stock.name) push \(push) film-exposure \(exposure)"
                            + " strength \(amount)"

                        var previous = RGB(gray: -Double.infinity)
                        // −10…+8 EV in fifth-stop steps: past the toe at one end and
                        // well past the shoulder at the other, finely enough that a
                        // reversal inside a crossover window cannot fall between samples.
                        for i in 0...90 {
                            let ev = -10 + Double(i) * 0.2
                            let out = chain.apply(RGB(gray: 0.18 * pow(2, ev)))
                            for channel in 0..<3 {
                                XCTAssertGreaterThanOrEqual(
                                    out[channel], previous[channel] - 1e-9,
                                    "\(label) inverted in channel \(channel) at \(ev) EV")
                            }
                            previous = out
                        }
                    }
                }
            }
        }
    }

    /// Strength is a blend, so it has to travel the whole way from the neutral rendering
    /// to the film one without overshooting either end — the mix that makes the
    /// monotonicity argument above hold has to actually be a mix.
    func testFilmStrengthStaysBetweenTheTwoRenderingsItBlends() {
        for stock in FilmStock.all {
            var full = FilmChain.defaultRecipe(for: stock)
            full.amount = 100
            var off = FilmChain.defaultRecipe(for: stock)
            off.amount = 0

            let filmChain = FilmChain(full, displayWhite: 1.0)
            let neutralChain = FilmChain(off, displayWhite: 1.0)
            // Built once per stock, not once per sample: constructing a chain runs the
            // calibration bisection, which is the expensive part of the whole suite.
            let blends: [(Double, FilmChain)] = [0.0, 25.0, 50.0, 75.0, 100.0].map {
                var recipe = full
                recipe.amount = $0
                return ($0, FilmChain(recipe, displayWhite: 1.0))
            }

            for ev in stride(from: -6.0, through: 5.0, by: 0.5) {
                let scene = RGB(gray: 0.18 * pow(2, ev))
                let film = filmChain.apply(scene)
                let neutral = neutralChain.apply(scene)
                for (amount, chain) in blends {
                    let out = chain.apply(scene)
                    for channel in 0..<3 {
                        let lo = Swift.min(film[channel], neutral[channel]) - 1e-9
                        let hi = Swift.max(film[channel], neutral[channel]) + 1e-9
                        XCTAssertTrue(out[channel] >= lo && out[channel] <= hi,
                                      "\(stock.name) at strength \(amount), \(ev) EV, "
                                          + "channel \(channel): \(out[channel]) is "
                                          + "outside [\(lo), \(hi)]")
                    }
                }
            }
        }
    }

    func testGrainPlateIsDeterministicAndUnitVariance() {
        let a = FilmGrainProfile.plate(size: 64, seed: 12345, sigma: 1)
        let b = FilmGrainProfile.plate(size: 64, seed: 12345, sigma: 1)
        XCTAssertEqual(a, b, "grain plate is not reproducible")

        // A plate that ignored its seed would also be perfectly reproducible. Two
        // frames of a burst share everything except the seed, so identical plates mean
        // identical grain — which reads as a dirty sensor, not as film.
        let other = FilmGrainProfile.plate(size: 64, seed: 12346, sigma: 1)
        XCTAssertNotEqual(a, other, "the plate ignored its seed")
        var differing = 0
        for (x, y) in zip(a, other) where x != y { differing += 1 }
        XCTAssertGreaterThan(differing, a.count / 2,
                             "only \(differing) of \(a.count) samples moved with the "
                                 + "seed — the plate is barely seeded")

        var sum = 0.0
        var sumSquares = 0.0
        for v in a {
            sum += Double(v)
            sumSquares += Double(v) * Double(v)
        }
        let n = Double(a.count)
        let mean = sum / n
        let variance = sumSquares / n - mean * mean
        XCTAssertEqual(mean, 0, accuracy: 0.02)
        XCTAssertEqual(variance, 1, accuracy: 0.05)
    }

    // MARK: - Colour and grade

    func testColorEngineIsIdentityWhenNothingIsSet() {
        let engine = ColorEngine(mixer: Mixer(), pointColors: [], color: ColorAdjust(),
                                 primaries: Primaries(), bw: nil)
        XCTAssertTrue(engine.isIdentity)
        let c = RGB(0.3, 0.5, 0.2)
        XCTAssertLessThan(engine.apply(c).maxAbsDifference(c), 1e-9)
    }

    func testMixerBandWeightsFormAPartitionOfUnity() {
        for degrees in stride(from: 0.0, to: 360.0, by: 7.0) {
            let weights = ColorEngine.bandWeights(hue: degrees)
            XCTAssertEqual(weights.count, 8)
            XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 1e-9,
                           "band weights did not sum to 1 at \(degrees)°")
        }
    }

    func testGradeIsIdentityWhenNothingIsSet() {
        let grade = GradeEngine(wheels: GradingWheels(), printerLights: PrinterLights())
        XCTAssertTrue(grade.isIdentity)
        let c = RGB(0.4, 0.3, 0.25)
        XCTAssertLessThan(grade.apply(c).maxAbsDifference(c), 1e-9)
    }

    func testPrinterLightsAreTwelfthsOfAStop() {
        let grade = GradeEngine(wheels: GradingWheels(),
                                printerLights: PrinterLights(master: 12, r: 0, g: 0, b: 0))
        let gains = grade.printerLightGains
        XCTAssertEqual(gains.r, 2, accuracy: 1e-9)
        XCTAssertEqual(gains.g, 2, accuracy: 1e-9)
        XCTAssertEqual(gains.b, 2, accuracy: 1e-9)

        let trim = GradeEngine(wheels: GradingWheels(),
                               printerLights: PrinterLights(master: 0, r: 12, g: 0, b: 0))
        XCTAssertEqual(trim.printerLightGains.r, 2, accuracy: 1e-9)
        XCTAssertEqual(trim.printerLightGains.g, 1, accuracy: 1e-9)
    }

    func testGradeZoneWeightsSumToOne() {
        let grade = GradeEngine(wheels: GradingWheels(), printerLights: PrinterLights())
        for ev in stride(from: -9.0, through: 5.0, by: 0.5) {
            let w = grade.zoneWeights(at: ev)
            XCTAssertEqual(w.shadows + w.mid + w.high, 1, accuracy: 1e-6,
                           "zone weights did not sum to 1 at \(ev) EV")
        }
    }

    // MARK: - Scopes

    func testHistogramCountsEveryPixel() {
        let source = ramp(width: 40, height: 10)
        let histogram = Histogram.compute(source, bins: 64)
        XCTAssertEqual(histogram.sampleCount, 400)
        let redTotal = histogram.channelCounts(.red).reduce(0, +)
        XCTAssertEqual(redTotal, 400)
    }

    func testHistogramFlagsClippedHighlights() {
        let blown = ImageBuffer(width: 16, height: 4) { _, _ in RGB(gray: 4.0) }
        let histogram = Histogram.compute(blown, bins: 64)
        XCTAssertGreaterThan(histogram.clippedFraction(.red, end: .high), 0.9)
        // The negative half, without which a `clippedFraction` returning 1.0
        // unconditionally passes: a blown frame is not clipped at the BOTTOM.
        XCTAssertLessThan(histogram.clippedFraction(.red, end: .low), 0.01)
        XCTAssertEqual(histogram.clippingMask(end: .high), 1 | 2 | 4,
                       "a blown grey frame must flag all three channels")
        XCTAssertEqual(histogram.clippingMask(end: .low), 0)
    }

    /// The other half of the same statement: a well-exposed frame must report nothing
    /// clipped at either end, and a crushed one must report the low end only. Without
    /// these, "flags clipping" is satisfied by flagging everything.
    func testHistogramReportsNoClippingOnAFrameThatIsNotClipped() {
        let grey = ImageBuffer(width: 16, height: 4) { _, _ in RGB(gray: 0.18) }
        let histogram = Histogram.compute(grey, bins: 64)
        for channel in [Histogram.Channel.red, .green, .blue] {
            XCTAssertLessThan(histogram.clippedFraction(channel, end: .high), 0.01,
                              "mid-grey reported as blown in \(channel)")
            XCTAssertLessThan(histogram.clippedFraction(channel, end: .low), 0.01,
                              "mid-grey reported as crushed in \(channel)")
        }
        XCTAssertEqual(histogram.clippingMask(end: .high), 0)
        XCTAssertEqual(histogram.clippingMask(end: .low), 0)

        let crushed = ImageBuffer(width: 16, height: 4) { _, _ in RGB.zero }
        let dark = Histogram.compute(crushed, bins: 64)
        XCTAssertGreaterThan(dark.clippedFraction(.green, end: .low), 0.9)
        XCTAssertLessThan(dark.clippedFraction(.green, end: .high), 0.01)
    }

    func testRawStatisticsRoundTripThroughItsBlob() {
        let source = ramp(width: 64, height: 16)
        let stats = RawStatistics.compute(source)
        let data = stats.encoded()
        guard let decoded = RawStatistics.decode(data) else {
            return XCTFail("raw statistics blob did not decode")
        }
        XCTAssertEqual(decoded.bins, stats.bins)
        XCTAssertEqual(decoded.sampleCount, stats.sampleCount)
    }

    /// Every field, with a distinguishable value in each.
    ///
    /// The test above compares `bins` and `sampleCount` only, while `encoded()` also
    /// writes the black level, four per-channel saturation levels, the CFA flag, the
    /// subsample stride, the analyzer revision and FOUR separate clipped-percentage
    /// arrays. A decoder reading the percentage block at the wrong offset — swapping
    /// near-clipped-low for clipped-low, say — passes it. Every value here is distinct
    /// so a transposition cannot hide behind an equality.
    func testRawStatisticsBlobCarriesEveryField() {
        let bins = (0..<(RawStatistics.channelCount * RawStatistics.binCount))
            .map { UInt32($0 * 3 + 1) }
        let stats = RawStatistics(bins: bins,
                                  clippedHighPercent: [1.5, 2.5, 3.5, 4.5],
                                  nearClippedHighPercent: [5.5, 6.5, 7.5, 8.5],
                                  clippedLowPercent: [9.5, 10.5, 11.5, 12.5],
                                  nearClippedLowPercent: [13.5, 14.5, 15.5, 16.5],
                                  sampleCount: 123_456,
                                  subsample: 4,
                                  blackLevel: 512.25,
                                  saturation: [16383, 16382, 16381, 16380],
                                  analyzerRevision: 1,
                                  sourceIsCFA: true)
        guard let decoded = RawStatistics.decode(stats.encoded()) else {
            return XCTFail("raw statistics blob did not decode")
        }
        XCTAssertEqual(decoded.bins, stats.bins)
        XCTAssertEqual(decoded.sampleCount, stats.sampleCount)
        XCTAssertEqual(decoded.subsample, stats.subsample)
        XCTAssertEqual(decoded.analyzerRevision, stats.analyzerRevision)
        XCTAssertEqual(decoded.sourceIsCFA, stats.sourceIsCFA)
        XCTAssertEqual(decoded.blackLevel, stats.blackLevel, accuracy: 1e-4)
        for channel in 0..<4 {
            XCTAssertEqual(decoded.saturation[channel], stats.saturation[channel],
                           accuracy: 1e-4, "saturation \(channel)")
            XCTAssertEqual(decoded.clippedHighPercent[channel],
                           stats.clippedHighPercent[channel], accuracy: 1e-4,
                           "clipped high \(channel)")
            XCTAssertEqual(decoded.nearClippedHighPercent[channel],
                           stats.nearClippedHighPercent[channel], accuracy: 1e-4,
                           "near-clipped high \(channel)")
            XCTAssertEqual(decoded.clippedLowPercent[channel],
                           stats.clippedLowPercent[channel], accuracy: 1e-4,
                           "clipped low \(channel)")
            XCTAssertEqual(decoded.nearClippedLowPercent[channel],
                           stats.nearClippedLowPercent[channel], accuracy: 1e-4,
                           "near-clipped low \(channel)")
        }
    }

    func testClippingOverlayMarksOnlyClippedPixels() {
        XCTAssertNil(ClippingOverlay.classify(RGB(gray: 0.5), mode: .highlights))
        XCTAssertNotNil(ClippingOverlay.classify(RGB(gray: 1.2), mode: .highlights))
    }

    // MARK: - The whole reference pipeline

    func testNeutralRecipeKeepsAGreyRampNeutral() {
        let source = ramp(width: 24, height: 6)
        let plan = RenderPlan(recipe: Recipe())
        let out = ReferenceRenderer.render(source, plan: plan)
        for x in 0..<out.width {
            let c = out[x, 3]
            // Tight, because the cube samples the diagonal exactly: a neutral input
            // lands on the shared edge of the six tetrahedra, so only the two neutral
            // corners contribute. Anything above float noise here means a stage has
            // started treating one channel differently from the others.
            XCTAssertEqual(c.r, c.g, accuracy: 1e-5, "grey picked up a cast at \(x): \(c)")
            XCTAssertEqual(c.g, c.b, accuracy: 1e-5, "grey picked up a cast at \(x): \(c)")
        }
    }

    /// What the default rendering actually does to a scene, as opposed to what it does
    /// not do.
    ///
    /// The single most basic statement about the picture — mid-grey renders to mid-grey
    /// — had no CPU test at all: the GPU golden asserts it, but that target is macOS-only
    /// and skipped without kernels, so on the Linux lane nothing said what any input
    /// renders to. And "grey stays grey" plus "exposure is monotone" are both satisfied
    /// by a renderer that returns its input untouched, which is why the anchors below
    /// come with the compression that distinguishes a picture from a passthrough: an
    /// identity renderer puts scene white at 5.76, not at 1.
    func testTheDefaultRenderingPutsTheAnchorsWhereItPromises() {
        let plan = RenderPlan(recipe: Recipe())

        // Mid-grey → mid-grey, exactly. This is a construction, not a tuning.
        XCTAssertEqual(plan.exactColor(RGB(gray: 0.18)).g, 0.18, accuracy: 1e-6,
                       "mid-grey did not land on mid-grey")

        // Scene white — mid-grey + 5 stops, the default white anchor — reaches display
        // white. An identity renderer would return 5.76 here.
        let white = plan.exactColor(RGB(gray: 0.18 * pow(2, 5))).g
        XCTAssertEqual(white, 1.0, accuracy: 0.02,
                       "the white anchor landed at \(white) instead of display white")

        // Nothing leaves the display range, in either direction, anywhere on the ramp.
        for ev in stride(from: -12.0, through: 8.0, by: 0.25) {
            let v = plan.exactColor(RGB(gray: 0.18 * pow(2, ev))).g
            XCTAssertGreaterThanOrEqual(v, 0, "\(ev) EV rendered below black")
            XCTAssertLessThanOrEqual(v, 1.0001, "\(ev) EV rendered above display white")
        }
    }

    /// Raising Exposure raises the picture — strictly, and by the amount the slider
    /// claims rather than by any amount at all.
    ///
    /// The version this replaces used `XCTAssertGreaterThan(value, previous - 1e-9)`,
    /// which is satisfied by equality, on a flat 4×4 field with one pixel read. A
    /// renderer that ignored `develop.tone.exposure` entirely — or ignored its input
    /// pixel entirely — passed it.
    func testRaisingExposureRaisesThePictureByTheAmountItClaims() {
        let source = ImageBuffer(width: 4, height: 4) { _, _ in RGB(gray: 0.18) }
        var previous = -Double.infinity
        var lowest = Double.infinity
        var highest = -Double.infinity

        for ev in stride(from: -3.0, through: 3.0, by: 0.5) {
            var recipe = Recipe()
            recipe.develop.tone.exposure = ev
            let out = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))
            let value = out[2, 2].g
            XCTAssertGreaterThan(value, previous + 1e-4,
                                 "half a stop of Exposure moved the picture by less "
                                     + "than 1e-4 at \(ev) EV")
            previous = value
            lowest = Swift.min(lowest, value)
            highest = Swift.max(highest, value)
        }
        XCTAssertGreaterThan(highest, lowest * 3,
                             "six stops of Exposure moved the picture from \(lowest) "
                                 + "to only \(highest)")

        // And the slider is exposure, not brightness: one stop of it must be
        // indistinguishable from having photographed twice the light. This is an
        // equality, so no no-op can satisfy it.
        let pushed = RenderPlan(recipe: {
            var r = Recipe()
            r.develop.tone.exposure = 1
            return r
        }()).exactColor(RGB(gray: 0.18))
        let brighterScene = RenderPlan(recipe: Recipe()).exactColor(RGB(gray: 0.36))
        XCTAssertLessThan(pushed.maxAbsDifference(brighterScene), 1e-9,
                          "+1 EV rendered differently from twice the scene light: "
                              + "\(pushed) vs \(brighterScene)")
    }

    /// The tables are an optimization; this bounds what they cost.
    func testBakedTablesTrackTheExactEvaluation() {
        var recipe = Recipe()
        recipe.develop.tone.contrast = 30
        recipe.develop.color.saturation = 20
        recipe.look.wheels.shadows = Wheel(hue: 220, sat: 0.3, lum: 0)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

        var worst = 0.0
        var where_ = ""
        for i in 0...24 {
            let ev = -7 + Double(i) * 0.5
            for hue in stride(from: 0.0, to: 360.0, by: 45.0) {
                let lch = OKLCh(L: 0.5, C: 0.1, h: hue)
                let tint = OKLabTransform.working.toRGB(lch)
                let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
                let scene = normalized * (0.18 * pow(2.0, ev))
                let approximated = plan.referenceColor(scene)
                let exact = plan.exactColor(scene)
                let d = approximated.maxAbsDifference(exact)
                if d > worst {
                    worst = d
                    where_ = "\(ev) EV hue \(hue): scene \(scene) table \(approximated) exact \(exact)"
                }
            }
        }
        XCTAssertLessThan(worst, 0.02, "table interpolation error reached \(worst) at \(where_)")
    }
}
