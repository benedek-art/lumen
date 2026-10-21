// LensStageGPUParityTests.swift
// WS-28: the lens stage on the GPU (`RenderGraph.applyLens`, RenderGraph+Lens.swift)
// against `LensStage.apply`, the f64 reference, at three sizes (square, odd and wide,
// tall — the y flip and the half-diagonal are where two twins disagree if they do).
//
// THE TOLERANCE. 2e-3 absolute on fixtures spanning about 0.6. The warp's Catmull–Rom
// reads texel centres through Core Image's sampler, and Defringe runs a cube root and an
// atan2 in float; both are a few 1e-4 on these smooth fixtures. Every case also asserts
// that the stage moved something by far more than the tolerance, or the comparison
// would prove nothing.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class LensStageGPUParityTests: XCTestCase {

    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (128, 320)]
    private let tolerance = 2e-3

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf,
    ])

    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            RGB(0.25 + 0.2 * sin(23 * u) * cos(17 * v),
                0.3 + 0.15 * sin(19 * u + 1) * cos(13 * v),
                0.22 + 0.18 * cos(29 * v + 3 * u))
        }
    }

    /// Bright sky, a dark bar with a purple fringe beside it, a green fringe on the
    /// other side — `LensStageTests.fringeFrame`, at the parity sizes.
    private func fringeScene(_ w: Int, _ h: Int) -> ImageBuffer {
        var img = ImageBuffer(width: w, height: h)
        let a = w / 4, b = a + w / 10
        for y in 0..<h {
            for x in 0..<w {
                var c = RGB(0.8, 0.85, 0.95)
                if x >= a, x < b { c = RGB(0.02, 0.02, 0.02) }
                if x == a || x == a + 1 { c = RGB(0.12, 0.03, 0.16) }
                if x == b - 1 { c = RGB(0.06, 0.11, 0.03) }
                img[x, y] = c
            }
        }
        return img
    }

    func testTheLensKernelsCompile() {
        XCTAssertTrue(KernelLibrary.unavailableLensKernels.isEmpty,
                      "lens kernels failed: \(KernelLibrary.unavailableLensKernels)")
    }

    func testWarpAndVignetteMatchTheReference() throws {
        try XCTSkipUnless(KernelLibrary.unavailableLensKernels.isEmpty, "covered by the compile test")
        // Strong on purpose (≈ 0.4 px at these sizes' corners) so the warp moves pixels.
        let inputs = LensInputs(
            lateralCA: LateralCAModel(red: .init(k0: 0.002, k2: 0.001),
                                      blue: .init(k0: -0.0015, k2: -0.0008)),
            vignette: VignetteGain(a: 0.3, b: 0.2, c: 0.1))
        let recipe = Recipe()
        let plan = RenderPlan(recipe: recipe)
        var graph = RenderGraph()
        graph.lensInputs = inputs
        for size in sizes {
            let input = scene(size.w, size.h)
            let reference = LensStage.apply(input, lens: recipe.develop.geometry.lens, inputs: inputs)
            let gpu = try XCTUnwrap(readBack(graph.applyLens(ciImage(input), plan: plan),
                                             width: size.w, height: size.h))
            assertClose(gpu, reference, input, "warp+vignette @\(size.w)x\(size.h)")
        }
    }

    func testDefringeMatchesTheReference() throws {
        try XCTSkipUnless(KernelLibrary.unavailableLensKernels.isEmpty, "covered by the compile test")
        var recipe = Recipe()
        recipe.develop.geometry.lens = LensCorrections(
            profile: false, removeCA: false,
            defringe: Defringe(purpleAmount: 8, greenAmount: 12))
        let plan = RenderPlan(recipe: recipe)
        for size in sizes {
            let input = fringeScene(size.w, size.h)
            let reference = LensStage.apply(input, lens: recipe.develop.geometry.lens, inputs: .none)
            let gpu = try XCTUnwrap(readBack(RenderGraph().applyLens(ciImage(input), plan: plan),
                                             width: size.w, height: size.h))
            assertClose(gpu, reference, input, "defringe @\(size.w)x\(size.h)")
        }
    }

    /// The defaults with no measured model and no record: the input's own image back.
    func testDefaultsWithoutInputsAreTheInput() throws {
        let input = scene(331, 197)
        let image = ciImage(input)
        let out = RenderGraph().applyLens(image, plan: RenderPlan(recipe: Recipe()))
        XCTAssertTrue(out === image, "the stage built a node it had no reason to build")
    }

    private func assertClose(_ gpu: ImageBuffer, _ reference: ImageBuffer, _ input: ImageBuffer,
                             _ name: String) {
        var worst = 0.0, moved = 0.0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                worst = Swift.max(worst, gpu[x, y].maxAbsDifference(reference[x, y]))
                moved = Swift.max(moved, reference[x, y].maxAbsDifference(input[x, y]))
            }
        }
        XCTAssertGreaterThan(moved, 0.03, "\(name): the stage changed nothing")
        XCTAssertLessThan(worst, tolerance, "\(name): GPU is \(worst) from the reference")
    }

    private func ciImage(_ buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        var pixels = [Float](repeating: -1, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: CGRect(x: image.extent.minX, y: image.extent.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf, colorSpace: nil)
        }
        guard !pixels.contains(-1) else { return nil }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif
