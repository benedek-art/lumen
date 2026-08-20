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
    private func testImage(width: Int = 64, height: Int = 16) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, v in
            let ev = -14 + u * 20
            let level = 0.18 * pow(2, ev)
            let hue = v * 360
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
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: image.extent.origin.x, y: image.extent.origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Core Image's origin is bottom-left and ImageBuffer's is top-left, so a
    /// round trip through a filter comes back flipped. Comparing statistics that do
    /// not depend on row order keeps these tests about the maths.
    private func compareIgnoringRowOrder(_ a: ImageBuffer, _ b: ImageBuffer,
                                         tolerance: Double, label: String) {
        XCTAssertEqual(a.width, b.width, label)
        XCTAssertEqual(a.height, b.height, label)
        guard a.width == b.width, a.height == b.height else { return }
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let flipped = b[x, b.height - 1 - y]
                worst = Swift.max(worst, a[x, y].maxAbsDifference(flipped))
            }
        }
        XCTAssertLessThan(worst, tolerance, "\(label): worst difference \(worst)")
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
        compareIgnoringRowOrder(expected, result, tolerance: 2e-4, label: "logEncode")
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
                let b = result[x, source.height - 1 - y]
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
        let source = ImageBuffer(width: 32, height: 8) { u, v in
            RGB(u, v, (u + v) / 2)
        }
        let input = ciImage(from: source)
        guard let mapped = ColorCube.filter(lut, image: input),
              let result = readBack(mapped, width: source.width, height: source.height)
        else { return XCTFail("cube filter failed") }

        let expected = source.map { lut.sample($0) }
        compareIgnoringRowOrder(expected, result, tolerance: 3e-3, label: "CIColorCube")
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

    func testGuidedFilterPreservesAStepEdge() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        // A hard edge with noise on both sides: a blur smears it, a guided filter
        // keeps it. That difference is the entire reason the tone stage uses one.
        let source = ImageBuffer(width: 64, height: 16) { u, v in
            let base = u < 0.5 ? 0.2 : 0.8
            let noise = (sin(u * 211) * cos(v * 173)) * 0.02
            return RGB(gray: base + noise)
        }
        let input = ciImage(from: source)
        guard let filtered = RenderGraph.guidedSelfFilter(input, radius: 4,
                                                          epsilon: 0.0004),
              let result = readBack(filtered, width: source.width, height: source.height)
        else { return XCTFail("guided filter failed") }

        let left = result[8, 8].r
        let right = result[55, 8].r
        XCTAssertLessThan(left, 0.35, "dark side lifted — edge was smeared")
        XCTAssertGreaterThan(right, 0.65, "bright side dropped — edge was smeared")
        // And it did smooth: the noise amplitude inside a flat region must fall.
        var variation = 0.0
        for x in 10..<28 {
            variation = Swift.max(variation, abs(result[x, 8].r - left))
        }
        XCTAssertLessThan(variation, 0.02, "guided filter did not smooth the interior")
    }

    // MARK: - The whole graph

    func testGraphMatchesTheReferenceRendererOnANeutralRecipe() throws {
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
                let a = reference[x, y]
                let b = gpu[x, source.height - 1 - y]
                worst = Swift.max(worst, a.maxAbsDifference(b))
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
        for x in 0..<source.width {
            let c = result[x, 2]
            XCTAssertEqual(c.r, c.g, accuracy: 0.004, "grey picked up a cast at \(x)")
            XCTAssertEqual(c.g, c.b, accuracy: 0.004, "grey picked up a cast at \(x)")
        }
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
