#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// WS-04 SPEC line 16: the GPU twin of S6 (`RenderGraph.applyMatrix`) clamps to the
/// half-float maximum exactly as `LinearStage.apply` does, and otherwise matches it.
///
/// The main context's intermediates are RGBAh, whose largest finite value is 65504.
/// At Exposure +10 (×1024) a scene value of 64 is 65536, which an unclamped matrix
/// stores as +inf; the clamp fused after `CIColorMatrix` must store ±65504 instead.
final class ExposureGPUParityTests: XCTestCase {
    private let halfContext = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAh])
    private let floatContext = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

    private func image(_ buffer: ImageBuffer) -> CIImage {
        buffer.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: buffer.width * 16,
                    size: CGSize(width: buffer.width, height: buffer.height),
                    format: .RGBAf, colorSpace: nil)
        }
    }

    private func row(_ values: [RGB]) -> ImageBuffer {
        var buffer = ImageBuffer(width: values.count, height: 1)
        for (i, v) in values.enumerated() { buffer[i, 0] = v }
        return buffer
    }

    /// One unit in the last place of the half-float nearest `x`.
    private func halfULP(_ x: Double) -> Double {
        let a = Swift.max(abs(x), 6.103515625e-05)   // the smallest normal half
        return pow(2, floor(log2(a)) - 10)
    }

    private func plan(_ exposure: Double, _ base: Recipe = Recipe()) -> RenderPlan {
        var recipe = base
        recipe.develop.tone.exposure = exposure
        return RenderPlan(recipe: recipe, asShotKelvin: 6503.7072, asShotTint: 9.77,
                          lutSize: 17)
    }

    func testApplyMatrixClampsToHalfMaxLikeCPU() throws {
        let stage = plan(10).linear
        XCTAssertFalse(stage.isIdentity)
        let values = [RGB(64, 64, 64), RGB(1e3, 1e3, 1e3), RGB(-1e3, -1e3, -1e3),
                      RGB(64, 1e3, -1e3)]
        let input = row(values)
        let out = try XCTUnwrap(PipelineRenderer.buffer(
            from: RenderGraph.applyMatrix(image(input), stage.matrix), context: halfContext))
        var nonFinite = 0
        for i in values.indices {
            let gpu = out[i, 0], cpu = stage.apply(values[i])
            for (g, c) in [(gpu.r, cpu.r), (gpu.g, cpu.g), (gpu.b, cpu.b)] {
                if !g.isFinite { nonFinite += 1; continue }
                XCTAssertLessThanOrEqual(abs(g - c), halfULP(c),
                                         "pixel \(i): GPU \(g) vs CPU \(c)")
                XCTAssertLessThanOrEqual(abs(g), LinearStage.outputLimit)
            }
        }
        XCTAssertEqual(nonFinite, 0, "the RGBAh store must hold ±65504, not ±inf or NaN")
        XCTAssertEqual(out[0, 0].g, 65504)
        XCTAssertEqual(out[2, 0].g, -65504)
        // Alpha passes through the matrix and its clamp.
        XCTAssertEqual(out.pixels[3], 1)
    }

    func testApplyMatrixMatchesLinearStageOnRamp() throws {
        var ramp: [RGB] = []
        for i in 0..<400 {
            let e = -10 + 20 * Double(i) / 399
            let v = 0.18 * pow(2, e)
            ramp.append([RGB(v, v, v), RGB(v * 0.3, v * 0.6, v * 1.9),
                         RGB(v * 2.2, v * 1.3, v * 0.8), RGB(v * 1.5, v * 0.2, v * 0.1)][i % 4])
        }
        ramp.append(RGB(-0.02, 0.01, 0.05))
        ramp.append(RGB(0, 0, 0))
        ramp.append(RGB(100, 90, 80))
        let input = row(ramp)
        var warm = Recipe()
        warm.develop.raw.temp = 4200
        warm.develop.raw.tint = 8
        var nonFinite = 0, worstULPs = 0.0
        for base in [Recipe(), warm] {
            for k in [-3.0, 3.0] {
                let stage = plan(k, base).linear
                XCTAssertFalse(stage.isIdentity)
                let out = try XCTUnwrap(PipelineRenderer.buffer(
                    from: RenderGraph.applyMatrix(image(input), stage.matrix),
                    context: floatContext))
                for i in ramp.indices {
                    // The CPU side reads the same Float32 input the GPU sampled.
                    let gpu = out[i, 0], cpu = stage.apply(input[i, 0])
                    for (g, c) in [(gpu.r, cpu.r), (gpu.g, cpu.g), (gpu.b, cpu.b)] {
                        if !g.isFinite { nonFinite += 1; continue }
                        let ulps = abs(g - c) / halfULP(c)
                        worstULPs = Swift.max(worstULPs, ulps)
                        XCTAssertLessThanOrEqual(ulps, 1, "EV \(k) pixel \(i): \(g) vs \(c)")
                    }
                }
            }
        }
        print("WS-04 L16 ramp worst |GPU − CPU| = \(worstULPs) fp16 ulp")
        XCTAssertEqual(nonFinite, 0)
    }
}
#endif
