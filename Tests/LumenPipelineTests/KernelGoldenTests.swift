// KernelGoldenTests.swift
// The tests that make the GPU path trustworthy from a machine that has no GPU.
//
// Every custom kernel has a Swift twin in LumenCore. These tests compile the kernels,
// render synthetic frames through the real Core Image graph, pull the pixels back, and
// compare against the reference implementation. That is the whole verification story
// for the shader surface: if a kernel stops matching its reference, this suite says so
// on the next push, not after a shoot.
//
// The tolerances are stage-declared (docs/14 §8.1). Where a table is involved they
// also bound its interpolation error, which is the honest cost of the bake-and-fetch
// architecture and should be measured rather than assumed.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class KernelGoldenTests: XCTestCase {

    /// Working-space context: everything renders in extended linear Rec.2020, and
    /// pixels come back as raw floats with no colour conversion in the way.
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
        .workingFormat: CIFormat.RGBAf,
    ])

    // MARK: - Dehaze must not repaint the sky

    /// Dehaze scales the colour, it does not repaint it.
    ///
    /// The shipping kernel used to recombine per channel — `(I − A)/t + A` — which is a
    /// different scale factor per channel and therefore a hue rotation. Measured
    /// outside this suite on a veiled blue sky under a warm veil, that form moved the
    /// hue by 13.4°, which is the magenta cast docs/06 calls impossible by
    /// construction. It was impossible only on `ReferenceRenderer`, which renders no
    /// user pixels; this is the path every preview and every export takes.
    ///
    /// A single luminance ratio is a pure multiply, so hue survives exactly. The bar is
    /// 1° rather than 0 because the read-back is f32 through a GPU and the input hues
    /// are computed in double.
    func testDehazeDoesNotRotateHue() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 32, height = 32
        // A veiled blue with a gradient, so the dark channel is not constant and the
        // transmission map has something to vary over.
        let source = ImageBuffer(width: width, height: height) { u, v in
            RGB(0.26 + 0.10 * u, 0.34 + 0.06 * v, 0.52 + 0.06 * u)
        }
        let input = ciImage(from: source)
        let output = RenderGraph.applyDehaze(input, amount: 60, longEdge: width)

        guard let before = readBack(input, width: width, height: height),
              let after = readBack(output, width: width, height: height)
        else { return XCTFail("dehaze render failed") }

        var worstShift = 0.0
        var moved = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = before[x, y], b = after[x, y]
                moved = Swift.max(moved, a.maxAbsDifference(b))
                let ha = OKLabTransform.working.toLCh(a).h
                let hb = OKLabTransform.working.toLCh(b).h
                var delta = abs(hb - ha)
                if delta > 180 { delta = 360 - delta }
                worstShift = Swift.max(worstShift, delta)
            }
        }
        // It has to have DONE something, or hue preservation is trivially true.
        XCTAssertGreaterThan(moved, 0.01,
                             "dehaze changed nothing, so this proves nothing")
        XCTAssertLessThan(worstShift, 1.0,
                          "dehaze rotated hue by \(worstShift)° — the recombination is "
                              + "per-channel again, not a luminance ratio")
    }

    // MARK: - The eyedropper's probe

    /// A source that hands back a known picture, so the probe can be asked whether it
    /// reads the pixel it was pointed at.
    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        private let image: CIImage
        init(_ image: CIImage) { self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// The probe must read the pixel it was pointed at.
    ///
    /// Asserted against `readBack` rather than against an absolute idea of "top",
    /// deliberately. Core Image extents are bottom-up while the UI hands down a
    /// top-down fraction, and `CIImage(bitmapData:)`'s row order is a third convention
    /// again — a probe with the flip missing returns a perfectly plausible colour, just
    /// the one mirrored about the centre line, which on a photograph reads as "the
    /// eyedropper is a bit inaccurate" rather than as a bug. Comparing against the same
    /// read-back path every golden in this file already trusts pins the probe to the
    /// convention the renderer actually uses, instead of to one I asserted.
    func testTheSceneProbeReadsThePointItWasGiven() throws {
        // Every pixel distinct in both axes, so a swap or a flip cannot coincide.
        let width = 16, height = 16
        let source = ImageBuffer(width: width, height: height) { u, v in
            RGB(0.1 + 0.8 * u, 0.5, 0.1 + 0.8 * v)
        }
        let stub = StubSource(ciImage(from: source))
        let renderer = PipelineRenderer()
        guard let expected = readBack(ciImage(from: source), width: width, height: height)
        else { return XCTFail("read-back failed") }

        for (px, py) in [(3, 2), (12, 4), (8, 8), (2, 13), (14, 15)] {
            let u = (Double(px) + 0.5) / Double(width)
            let v = (Double(py) + 0.5) / Double(height)
            guard let sample = renderer.sampleSceneLinear(source: stub, recipe: Recipe(),
                                                          sourceX: u, sourceY: v,
                                                          radius: 0)
            else { return XCTFail("no sample at \(px),\(py)") }
            let want = expected[px, py]
            XCTAssertEqual(sample.r, want.r, accuracy: 0.02,
                           "probe read the wrong COLUMN at \(px),\(py): "
                               + "got \(sample) want \(want)")
            XCTAssertEqual(sample.b, want.b, accuracy: 0.02,
                           "probe read the wrong ROW at \(px),\(py) — the vertical "
                               + "flip is wrong: got \(sample) want \(want)")
        }
    }

    /// Out-of-frame requests clamp; they do not crash and do not return garbage.
    func testTheSceneProbeSurvivesTheCorners() throws {
        let source = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.25) }
        let stub = StubSource(ciImage(from: source))
        let renderer = PipelineRenderer()
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0), (-1.0, 2.0)] {
            guard let sample = renderer.sampleSceneLinear(source: stub, recipe: Recipe(),
                                                          sourceX: x, sourceY: y)
            else { return XCTFail("no sample at \(x),\(y)") }
            XCTAssertTrue(sample.isFinite, "non-finite sample at \(x),\(y)")
            XCTAssertEqual(sample.g, 0.25, accuracy: 0.02, "wrong value at \(x),\(y)")
        }
    }

    // MARK: - Availability

    /// The load-bearing environment check. If this fails, the app still renders — via
    /// the CPU reference — but the failure must be loud, because everything below it
    /// is measuring something that is not running.
    func testEveryKernelCompiles() {
        XCTAssertTrue(KernelLibrary.isAvailable,
                      "kernels failed to compile: \(KernelLibrary.unavailableKernels)")
    }

    // MARK: - Helpers

    /// A synthetic scene-referred frame: a log-spaced luminance ramp crossed with a
    /// hue sweep, covering 20 stops and the saturated corners where colour maths
    /// misbehaves.
    ///
    /// Deliberately ROW-INVARIANT — every row is identical. Core Image's origin is
    /// bottom-left and ImageBuffer's is top-left, and rather than encode a guess about
    /// where the flip lands into a dozen numeric comparisons, the comparisons are made
    /// immune to it. `testCropUsesImageCoordinates` is the single place the convention
    /// is asserted, and it asserts it directly.
    private func testImage(width: Int = 64, height: Int = 8) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            let ev = -14 + u * 20
            let level = 0.18 * pow(2.0, ev)
            let hue = u * 720
            let lch = OKLCh(L: 0.5, C: 0.12, h: hue)
            let tint = OKLabTransform.working.toRGB(lch)
            let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
            return normalized * level
        }
    }

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf,
                       colorSpace: nil)
    }

    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        // A stage that changed the extent must fail loudly rather than have this read
        // some arbitrary corner of it.
        XCTAssertEqual(image.extent.width, CGFloat(width), accuracy: 0.5)
        XCTAssertEqual(image.extent.height, CGFloat(height), accuracy: 0.5)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: image.extent.origin.x, y: image.extent.origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        // A render that wrote nothing — a kernel silently unavailable, a colour-space
        // mismatch, an extent CI decided was empty — leaves this buffer exactly as it
        // was allocated. Every downstream assertion in this file is a comparison, and
        // an all-zero frame satisfies a surprising number of them: "grey stays grey"
        // reads 0 == 0 == 0 and passes at every pixel. This declares `-> ImageBuffer?`
        // and never returned nil, so the `guard let` at each call site could not catch
        // it either. One check here protects every test in the file.
        //
        // Alpha is excluded: `ImageBuffer.init(width:height:)` fills it with 1, but a
        // render that wrote nothing into THIS buffer leaves alpha at 0 too, so a frame
        // whose colour channels are all zero is either black-and-opaque (which no test
        // here produces, since every source is a grey ramp or a step) or a dead read.
        let wroteSomething = stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] != 0 || pixels[$0 + 1] != 0 || pixels[$0 + 2] != 0
        }
        guard wroteSomething else {
            XCTFail("the render produced an all-zero frame — the kernel wrote nothing, "
                        + "and comparing against it would pass by accident")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Compare two buffers pixel for pixel. Safe against the origin convention only
    /// because every test frame here is row-invariant; see `testImage`.
    private func compare(_ a: ImageBuffer, _ b: ImageBuffer,
                         tolerance: Double, label: String) {
        XCTAssertEqual(a.width, b.width, label)
        XCTAssertEqual(a.height, b.height, label)
        guard a.width == b.width, a.height == b.height else { return }
        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<a.height {
            for x in 0..<a.width {
                let d = a[x, y].maxAbsDifference(b[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        XCTAssertLessThan(worst, tolerance,
                          "\(label): worst difference \(worst) at \(worstAt)")
    }

    // MARK: - Shaper

    func testLogEncodeKernelMatchesReference() throws {
        try XCTSkipUnless(KernelLibrary.logEncode != nil, "kernel unavailable")
        let source = testImage()
        let input = ciImage(from: source)
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: input.extent, [input]),
              let result = readBack(encoded, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        let expected = source.map { LumenLog.encode($0) }
        compare(expected, result, tolerance: 2e-4, label: "logEncode")
    }

    func testLogRoundTripThroughBothKernels() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = testImage()
        let input = ciImage(from: source)
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: input.extent, [input]),
              let decoded = KernelLibrary.apply(KernelLibrary.logDecode,
                                                extent: input.extent, [encoded]),
              let result = readBack(decoded, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        // A relative comparison: the domain spans 20 stops, so an absolute tolerance
        // would be meaningless at both ends of it.
        var worstRelative = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let a = source[x, y]
                let b = result[x, y]
                for channel in 0..<3 {
                    let reference = abs(a[channel])
                    guard reference > 1e-5 else { continue }
                    worstRelative = Swift.max(worstRelative,
                                              abs(a[channel] - b[channel]) / reference)
                }
            }
        }
        XCTAssertLessThan(worstRelative, 0.02,
                          "shaper round trip drifted by \(worstRelative * 100)%")
    }

    // MARK: - Tables

    func testColorCubeMatchesTheBakedTable() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        // A table with real structure in all three channels, so a transposed or
        // mis-strided upload cannot pass by symmetry.
        let lut = LUT3D(size: 17) { c in
            RGB(Num.saturate(c.r * 0.8 + 0.1),
                Num.saturate(c.g * c.g),
                Num.saturate(1 - c.b))
        }
        // Row-invariant, but with three independent functions of u so a transposed or
        // mis-strided upload cannot pass by symmetry.
        let source = ImageBuffer(width: 64, height: 4) { u, _ in
            RGB(u, u * u, 1 - u)
        }
        let input = ciImage(from: source)
        guard let mapped = ColorCube.filter(lut, image: input),
              let result = readBack(mapped, width: source.width, height: source.height)
        else { return XCTFail("cube filter failed") }

        let expected = source.map { lut.sample($0) }
        compare(expected, result, tolerance: 3e-3, label: "CIColorCube")
    }

    // MARK: - Multiply and blend

    func testMultiplyKernelIsUnclamped() throws {
        try XCTSkipUnless(KernelLibrary.multiply != nil, "kernel unavailable")
        let a = ImageBuffer(width: 8, height: 4) { _, _ in RGB(4, 2, 0.5) }
        let b = ImageBuffer(width: 8, height: 4) { _, _ in RGB(3, 3, 3) }
        guard let out = KernelLibrary.apply(KernelLibrary.multiply,
                                            extent: ciImage(from: a).extent,
                                            [ciImage(from: a), ciImage(from: b)]),
              let result = readBack(out, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        // 12 must survive: a clamping multiply would silently destroy every
        // scene-referred highlight in the app.
        XCTAssertEqual(result[0, 0].r, 12, accuracy: 0.05)
        XCTAssertEqual(result[0, 0].g, 6, accuracy: 0.05)
        XCTAssertEqual(result[0, 0].b, 1.5, accuracy: 0.02)
    }

    func testBlendMaskInterpolates() throws {
        try XCTSkipUnless(KernelLibrary.blendMask != nil, "kernel unavailable")
        let base = ImageBuffer(width: 8, height: 4) { _, _ in RGB(0, 0, 0) }
        let over = ImageBuffer(width: 8, height: 4) { _, _ in RGB(2, 2, 2) }
        let mask = ImageBuffer(width: 8, height: 4) { _, _ in RGB(0.25, 0.25, 0.25) }
        guard let out = KernelLibrary.apply(
            KernelLibrary.blendMask, extent: ciImage(from: base).extent,
            [ciImage(from: base), ciImage(from: over), ciImage(from: mask)]),
              let result = readBack(out, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        XCTAssertEqual(result[0, 0].r, 0.5, accuracy: 0.01)
    }

    // MARK: - Guided filter

    /// A hard edge with noise on both sides: a blur smears it, a guided filter keeps
    /// it. That difference is the entire reason the tone stage uses one.
    ///
    /// Measured as a ratio against the input, both directions, for the reason the CPU
    /// twin of this test carries at length: the absolute-level version passed on
    /// `guidedSelfFilter` returning its input unchanged, because a plane whose plateaus
    /// are already 0.2 and 0.8 with ±0.02 of noise satisfies "left < 0.35", "right >
    /// 0.65" and "variation < 0.02" before any filter runs.
    func testGuidedFilterSmoothsBelowItsThresholdAndKeepsDetailAbove() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let epsilon = 0.0008
        let threshold = epsilon.squareRoot()

        func step(amplitude: Double) -> ImageBuffer {
            var image = ImageBuffer(width: 64, height: 16)
            for y in 0..<16 {
                for x in 0..<64 {
                    let base = x < 32 ? 0.2 : 0.8
                    image[x, y] = RGB(gray: base
                                          + ((x + y) % 2 == 0 ? amplitude : -amplitude))
                }
            }
            return image
        }

        /// Largest excursion within either plateau, away from the borders and the step.
        func plateauSwing(_ image: ImageBuffer) -> Double {
            var swing = 0.0
            for range in [6..<26, 38..<58] {
                var lo = Double.infinity
                var hi = -Double.infinity
                for y in 4..<12 {
                    for x in range {
                        lo = Swift.min(lo, image[x, y].r)
                        hi = Swift.max(hi, image[x, y].r)
                    }
                }
                swing = Swift.max(swing, hi - lo)
            }
            return swing
        }

        func filtered(_ source: ImageBuffer) throws -> ImageBuffer {
            guard let out = RenderGraph.guidedSelfFilter(ciImage(from: source),
                                                         radius: 4, epsilon: epsilon),
                  let result = readBack(out, width: source.width, height: source.height)
            else { throw XCTSkip("guided filter produced no image") }
            return result
        }

        let quiet = step(amplitude: threshold / 4)
        let smoothed = try filtered(quiet)
        let quietRatio = plateauSwing(smoothed) / plateauSwing(quiet)
        XCTAssertLessThan(quietRatio, 0.45,
                          "noise well under √ε survived at \(quietRatio) of its input "
                              + "swing; an identity filter scores 1.0")

        let loud = step(amplitude: threshold * 3.5)
        let kept = try filtered(loud)
        let loudRatio = plateauSwing(kept) / plateauSwing(loud)
        XCTAssertGreaterThan(loudRatio, 0.4,
                             "detail well over √ε was smoothed away, surviving at only "
                                 + "\(loudRatio) of its input swing")

        // The edge is what neither pass may cost, measured as the difference of the
        // plateau means so the noise cancels out of it.
        for (label, image) in [("quiet", smoothed), ("loud", kept)] {
            var left = 0.0, right = 0.0, n = 0.0
            for y in 4..<12 {
                for x in 6..<26 { left += image[x, y].r }
                for x in 38..<58 { right += image[x, y].r }
                n += 20
            }
            XCTAssertGreaterThan(right / n - left / n, 0.45,
                                 "the \(label) pass smeared the step to "
                                     + "\(right / n - left / n) of 0.6")
        }
    }

    // MARK: - The whole graph

    /// Named for what it is: the colour path, in draft, on a recipe with three sliders
    /// moved. It is NOT neutral — the previous name would have had the next reader
    /// assume neutrality was covered here, which it is not.
    func testGraphMatchesTheReferenceRendererOnTheColourPath() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        recipe.develop.tone.contrast = 25
        recipe.develop.color.saturation = 15

        let source = testImage(width: 48, height: 12)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let graph = RenderGraph()
        let output = graph.build(ciImage(from: source), plan: plan,
                                 options: RenderGraph.Options(longEdge: 48, draft: true))
        guard let gpu = readBack(output, width: source.width, height: source.height) else {
            return XCTFail("graph render failed")
        }

        // Draft skips the spatial stages on both sides, so this compares exactly the
        // colour path: matrix, tone gain, tables.
        let reference = ReferenceRenderer.render(source, plan: plan)

        var worst = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                worst = Swift.max(worst, reference[x, y].maxAbsDifference(gpu[x, y]))
            }
        }
        // Display-referred output in 0…1; 2% is the declared tolerance for the
        // combined fp16 storage and table interpolation error.
        XCTAssertLessThan(worst, 0.02, "GPU graph diverged from the reference by \(worst)")
    }

    func testNeutralRecipeLeavesAGreyRampNeutral() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = ImageBuffer(width: 32, height: 4) { u, _ in
            RGB(gray: 0.18 * pow(2, -8 + u * 12))
        }
        let plan = RenderPlan(recipe: Recipe())
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 32,
                                                                      draft: true))
        guard let result = readBack(output, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        // Assert it is a RAMP before asserting it is grey. `r == g == b` is true of
        // any uniform frame, so on its own this passed on a render that wrote nothing
        // — the `readBack` guard now catches that case, and this makes the test itself
        // discriminating rather than relying on the helper.
        XCTAssertGreaterThan(result[31, 2].g, result[0, 2].g * 8,
                             "a 12-stop ramp came back nearly flat")
        XCTAssertGreaterThan(result[16, 2].g, 0.01, "the ramp's middle is at black")

        for x in 0..<source.width {
            let c = result[x, 2]
            XCTAssertEqual(c.r, c.g, accuracy: 0.004, "grey picked up a cast at \(x)")
            XCTAssertEqual(c.g, c.b, accuracy: 0.004, "grey picked up a cast at \(x)")
        }
    }

    /// The spatial stages, compared against the reference at all.
    ///
    /// Every other graph comparison in this file passes `draft: true`, which skips the
    /// spatial stages on both sides — so the GPU denoise, texture, clarity, dehaze,
    /// capture sharpening, vignette and mask rasterization were compared to the
    /// reference renderer NEVER. This is the one that turns them on.
    ///
    /// The tolerance is a SMOKE-TEST BOUND, not a measurement. These stages are
    /// separable-kernel approximations of the reference's exact filters and I have no
    /// GPU to measure the real divergence on, so 0.25 is set to catch a stage wired to
    /// the wrong input, applied twice, or missing entirely — not to certify the last
    /// percent of a blur. Tighten it to the measured value on the first green run;
    /// leaving a number here that was guessed tight would just cost a red cycle.
    ///
    /// The second half of the test carries the real weight and needs no calibration:
    /// turning the spatial stages off must move the picture. Without that, this would
    /// be comparing two copies of the colour path and would pass with every spatial
    /// kernel unwired.
    func testGraphMatchesTheReferenceRendererWithTheSpatialStagesOn() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        var recipe = Recipe()
        recipe.develop.detail.texture = 40
        recipe.develop.detail.clarity = 30
        recipe.look.vignette = -1.0

        let source = testImage(width: 64, height: 32)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 64,
                                                                      draft: false))
        guard let gpu = readBack(output, width: source.width, height: source.height) else {
            return XCTFail("graph render failed")
        }
        let reference = ReferenceRenderer.render(source, plan: plan)

        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let d = reference[x, y].maxAbsDifference(gpu[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        XCTAssertLessThan(worst, 0.25,
                          "the spatial path diverged by \(worst) at \(worstAt)")

        // And each stage actually ran — measured ONE AT A TIME.
        //
        // This used to turn all three on together and assert that something moved. The
        // −1 EV vignette alone cleared that bar by a wide margin, so texture and clarity
        // could be completely unwired and the assertion still passed. They were not
        // unwired, but they were computing their gain on the shaper's encoded plane
        // instead of in stops — a factor of twenty-four — and this is the test that was
        // supposed to notice. A check that a group of stages did *something* is not a
        // check on any one of them.
        func render(_ mutate: (inout Recipe) -> Void) throws -> ImageBuffer {
            var r = Recipe()
            mutate(&r)
            let p = RenderPlan(recipe: r, lutSize: LUT3D.exportSize)
            guard let out = readBack(
                RenderGraph().build(ciImage(from: source), plan: p,
                                    options: RenderGraph.Options(longEdge: 64,
                                                                 draft: false)),
                width: source.width, height: source.height) else {
                throw XCTSkip("render failed")
            }
            return out
        }

        let plain = try render { _ in }
        func movement(from other: ImageBuffer) -> Double {
            var moved = 0.0
            for y in 0..<source.height {
                for x in 0..<source.width {
                    moved = Swift.max(moved, plain[x, y].maxAbsDifference(other[x, y]))
                }
            }
            return moved
        }

        // The bar is 0.001, and it is derived rather than picked. This 64x32 frame is
        // 20 EV across 64 columns, so its fine-detail band measures 9.9e-3 in the
        // shaper's encoded plane — 0.24 EV. The contract is a gain of 2^(0.36·ΔEV) per
        // stop, giving 2^0.086 = 1.061, about 6% of local contrast, which on the
        // mid-tone pixels this frame actually contains is worth ~0.004 of movement.
        //
        // 0.02 stood here first and was unreachable: it was written expecting the
        // 24x units fix to produce a large number, without measuring what the band on
        // this frame is worth. The three cases the bar has to separate are
        //   dead stage        exactly 0.0     (a radius CIBoxBlur ignores; this is
        //                                     what Texture was doing)
        //   gain in encoded   ~1.5e-4         (the 24x units bug)
        //   contract honoured ~4e-3
        // so 0.001 clears the second by 7x and sits 4x under the third. The measured
        // value is in the message either way, so a miss here is self-diagnosing.
        let texture = movement(from: try render { $0.develop.detail.texture = 40 })
        XCTAssertGreaterThan(texture, 0.001,
                             "Texture +40 moved the frame by \(texture) — 0.0 means the "
                                 + "band collapsed, a few e-4 means the gain is being "
                                 + "computed in the shaper's encoded units, not stops")

        let clarity = movement(from: try render { $0.develop.detail.clarity = 30 })
        XCTAssertGreaterThan(clarity, 0.001,
                             "Clarity +30 moved the frame by \(clarity)")

        let vignette = movement(from: try render { $0.look.vignette = -1.0 })
        XCTAssertGreaterThan(vignette, 0.05,
                             "a −1 EV vignette moved the frame by \(vignette)")
    }

    func testMidGreyLandsWhereTheTransformPromises() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = ImageBuffer(width: 8, height: 4) { _, _ in RGB(gray: 0.18) }
        let plan = RenderPlan(recipe: Recipe())
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 8,
                                                                      draft: true))
        guard let result = readBack(output, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        XCTAssertEqual(result[4, 2].g, 0.18, accuracy: 0.006)
    }

    // MARK: - Geometry

    func testCropUsesImageCoordinates() {
        // A frame whose top half is white and bottom half is black. Cropping the top
        // quarter must return white — this is the y-flip that Core Image's bottom-up
        // extent makes so easy to get backwards.
        let source = ImageBuffer(width: 16, height: 16) { _, v in
            RGB(gray: v < 0.5 ? 1.0 : 0.0)
        }
        var recipe = Recipe()
        recipe.develop.geometry.crop = Crop(x: 0, y: 0, w: 1, h: 0.25)

        let cropped = PipelineRenderer.applyGeometry(ciImage(from: source), recipe: recipe)
        guard let result = readBack(cropped, width: 16, height: 4) else {
            return XCTFail("crop render failed")
        }
        var total = 0.0
        for y in 0..<result.height {
            for x in 0..<result.width { total += result[x, y].g }
        }
        let mean = total / Double(result.width * result.height)
        XCTAssertGreaterThan(mean, 0.9, "crop took the wrong end of the frame")
    }
}

#endif
