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

    /// The property the tone stage depends on: smooth inside a surface, sharp across
    /// an edge. A filter that fails this haloes, which is the exact artefact Lumen's
    /// tone engine exists to avoid.
    func testGuidedFilterSmoothsInteriorsAndKeepsEdges() {
        let plane = edgePlane()
        let filtered = SpatialOps.guidedFilter(input: plane, guide: plane,
                                               radius: 4, epsilon: 0.0004)
        XCTAssertLessThan(filtered[6, 8], 0.32, "dark side lifted")
        XCTAssertGreaterThan(filtered[42, 8], 0.68, "bright side dropped")

        var interiorVariation = 0.0
        let reference = filtered[8, 8]
        for x in 8..<20 {
            interiorVariation = Swift.max(interiorVariation, abs(filtered[x, 8] - reference))
        }
        XCTAssertLessThan(interiorVariation, 0.03, "interior was not smoothed")
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
        XCTAssertLessThan(out.maxAbsDifference(source), 1e-5)
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
        XCTAssertEqual(out[16, 16].g, 0.5, accuracy: 0.06, "centre moved")
        XCTAssertLessThan(out[0, 0].g, 0.4, "corner did not darken")
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
        XCTAssertLessThan(out.maxAbsDifference(source), 1e-5)
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
        XCTAssertGreaterThanOrEqual(high.chroma, low.chroma)
        XCTAssertGreaterThanOrEqual(high.luma, low.luma)
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

    func testFilmChainIsMonotone() {
        for stock in FilmStock.all {
            let chain = FilmChain(FilmChain.defaultRecipe(for: stock), displayWhite: 1.0)
            var previous = -Double.infinity
            for i in 0...40 {
                let ev = -8 + Double(i) * 0.4
                let out = chain.apply(RGB(gray: 0.18 * pow(2, ev)))
                XCTAssertGreaterThanOrEqual(out.g, previous - 1e-6,
                                            "\(stock.name) inverted at \(ev) EV")
                previous = out.g
            }
        }
    }

    func testGrainPlateIsDeterministicAndUnitVariance() {
        let a = FilmGrainProfile.plate(size: 64, seed: 12345, sigma: 1)
        let b = FilmGrainProfile.plate(size: 64, seed: 12345, sigma: 1)
        XCTAssertEqual(a, b, "grain plate is not reproducible")

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

    func testRenderIsMonotoneInExposure() {
        let source = ImageBuffer(width: 4, height: 4) { _, _ in RGB(gray: 0.18) }
        var previous = -Double.infinity
        for ev in stride(from: -3.0, through: 3.0, by: 0.5) {
            var recipe = Recipe()
            recipe.develop.tone.exposure = ev
            let out = ReferenceRenderer.render(source, plan: RenderPlan(recipe: recipe))
            let value = out[2, 2].g
            XCTAssertGreaterThan(value, previous - 1e-9,
                                 "raising exposure darkened the image at \(ev) EV")
            previous = value
        }
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
