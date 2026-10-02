#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class LocalSofteningScaleTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

    private func fixture(_ width: Int) -> ImageBuffer {
        ImageBuffer(width: width, height: 16) { u, _ in
            RGB(gray: 0.18 + 0.03 * sin(2 * .pi * 64 * u))
        }
    }

    private func image(_ buffer: ImageBuffer) -> CIImage {
        buffer.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: buffer.width * 16,
                size: CGSize(width: buffer.width, height: buffer.height),
                format: .RGBAf, colorSpace: nil)
        }
    }

    /// RMS contrast in the same middle half of the scene, not an unrelated fixed-pixel
    /// window at each size. Edges are deliberately outside this comparison crop.
    private func contrast(_ buffer: ImageBuffer) -> Double {
        let values = (buffer.width / 4..<buffer.width * 3 / 4).map {
            buffer[$0, buffer.height / 2].r
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count))
    }

    func testNegativeLocalSharpnessRetainsTheSameSceneContrastAcrossRenderSizes() throws {
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        for amount in [-25.0, -50, -100] {
            var mask = Mask(id: "softening-scale")
            mask.adjust.sharpness = amount
            var cpuGains: [Double] = []
            var gpuGains: [Double] = []
            for width in [512, 1024, 2048, 4096] {
                let input = fixture(width)
                let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask,
                    plan: plan, space: .rec2020)
                let gpu = try XCTUnwrap(PipelineRenderer.buffer(from:
                    RenderGraph.applyLocalAdjust(image(input), mask: mask, plan: plan,
                        longEdge: width, lutSize: 17), context: context))
                let base = contrast(input)
                cpuGains.append(contrast(cpu) / base)
                gpuGains.append(contrast(gpu) / base)
                XCTAssertEqual(cpuGains.last!, gpuGains.last!, accuracy: 0.015,
                               "CPU/GPU disagree at \(width), strength \(amount)")
            }
            print("SOFTEN-SCALE amount=\(amount) CPU=\(cpuGains) GPU=\(gpuGains)")
            XCTAssertLessThan(cpuGains.max()! - cpuGains.min()!, 0.025)
            XCTAssertLessThan(gpuGains.max()! - gpuGains.min()!, 0.025)
        }
    }

    func testReferenceResolutionPreservesTheExistingSofteningLook() throws {
        let input = fixture(2560)
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        var mask = Mask(id: "reference-softening")
        mask.adjust.sharpness = -100
        let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask,
            plan: plan, space: .rec2020)
        let oldCPU = SpatialOps.gaussianBlur(input, sigma: 2.5)
        XCTAssertEqual(cpu.pixels, oldCPU.pixels)
        let oldGPU = image(input).clampedToExtent().applyingFilter("CIGaussianBlur",
            parameters: [kCIInputRadiusKey: 2.5]).cropped(to: image(input).extent)
        let expected = try XCTUnwrap(PipelineRenderer.buffer(from: oldGPU, context: context))
        let actual = try XCTUnwrap(PipelineRenderer.buffer(from:
            RenderGraph.applyLocalAdjust(image(input), mask: mask, plan: plan,
                longEdge: 2560, lutSize: 17), context: context))
        XCTAssertEqual(actual.pixels, expected.pixels)
    }

    func testZeroIsIdentityAndTheOnePixelTransitionDoesNotJump() throws {
        let input = fixture(2048)
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        let baseline = try XCTUnwrap(PipelineRenderer.buffer(from: image(input), context: context))
        let neutral = try XCTUnwrap(PipelineRenderer.buffer(from:
            RenderGraph.applyLocalAdjust(image(input), mask: Mask(id: "neutral"), plan: plan,
                longEdge: 2048, lutSize: 17), context: context))
        XCTAssertEqual(neutral.pixels, baseline.pixels)
        var gains: [Double] = []
        // Vary mask strength through sigma 1 on the same image. This exercises both
        // the exact small convolution and the established larger Gaussian path.
        for strength in [99.0, 99.9, 100, 100.1, 101] {
            var mask = Mask(id: "transition", amount: strength)
            mask.adjust.sharpness = -50
            let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask,
                plan: plan, space: .rec2020)
            let gpu = try XCTUnwrap(PipelineRenderer.buffer(from:
                RenderGraph.applyLocalAdjust(image(input), mask: mask, plan: plan,
                    longEdge: 2048, lutSize: 17), context: context))
            XCTAssertEqual(contrast(cpu), contrast(gpu), accuracy: 0.0003)
            gains.append(contrast(gpu) / contrast(input))
        }
        for pair in zip(gains, gains.dropFirst()) {
            XCTAssertLessThan(abs(pair.0 - pair.1), 0.01)
        }
    }
}
#endif
