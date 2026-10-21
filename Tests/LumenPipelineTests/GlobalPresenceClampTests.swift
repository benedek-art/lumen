#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Global Texture and Clarity are ±100 controls. A hand-edited sidecar can carry ±250;
/// the reference clamped it and the graph did not, so the two renderers disagreed on
/// any value outside the slider. Both must clamp, identically.
final class GlobalPresenceClampTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

    /// 1024 x 64 with a 3 px ripple added (WS-14): Texture is a band of the picture —
    /// 375–1500 cycles per image long edge — so on the old 128 px frame it sat above
    /// Nyquist and could not move the picture enough for the liveness check below to
    /// mean anything. The clamp assertions are unchanged.
    private var input: ImageBuffer {
        ImageBuffer(width: 1024, height: 64) { u, v in
            let value = 0.18 + 0.04 * sin(2 * .pi * 128 * u) * cos(2 * .pi * 11 * v)
                + 0.015 * sin(2 * .pi * 3 * u) + 0.02 * cos(2 * .pi * 1024 * u / 3)
            return RGB(value * 0.9, value, value * 1.1)
        }
    }

    private func gpu(_ detail: Detail) throws -> ImageBuffer {
        let buffer = input
        let ci = buffer.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: buffer.width * 16,
                    size: CGSize(width: buffer.width, height: buffer.height),
                    format: .RGBAf, colorSpace: nil)
        }
        var recipe = Recipe()
        recipe.develop.detail = detail
        let plan = RenderPlan(recipe: recipe, lutSize: 17)
        let out = RenderGraph().applyPresence(ci, plan: plan,
                                              options: RenderGraph.Options(longEdge: buffer.width,
                                                                           lutSize: 17))
        return try XCTUnwrap(PipelineRenderer.buffer(from: out, context: context))
    }

    private func cpu(_ detail: Detail) -> ImageBuffer {
        let image = input
        let node = DetailEngine.Decomposition(image: image, workingRadius: 20, space: .rec2020)
        return DetailEngine.apply(image, detail: detail, decomposition: node)
    }

    private func worst(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        zip(a.pixels, b.pixels).reduce(0) { Swift.max($0, abs(Double($1.0) - Double($1.1))) }
    }

    func testBothRenderersClampGlobalTextureAndClarityAtOneHundred() throws {
        for texture in [true, false] {
            for sign in [-1.0, 1] {
                var atLimit = Detail()
                var beyond = Detail()
                if texture { atLimit.texture = 100 * sign; beyond.texture = 250 * sign }
                else { atLimit.clarity = 100 * sign; beyond.clarity = 250 * sign }
                let label = "\(texture ? "texture" : "clarity") \(sign)"
                // Liveness: the limit itself must move the picture, or equality proves nothing.
                XCTAssertGreaterThan(worst(try gpu(atLimit), input), 1e-4, label)
                XCTAssertGreaterThan(worst(cpu(atLimit), input), 1e-4, label)
                XCTAssertEqual(worst(try gpu(beyond), try gpu(atLimit)), 0,
                               "GPU \(label): a sidecar's ±250 must render as ±100")
                XCTAssertEqual(worst(cpu(beyond), cpu(atLimit)), 0,
                               "CPU \(label): a sidecar's ±250 must render as ±100")
            }
        }
    }
}
#endif
