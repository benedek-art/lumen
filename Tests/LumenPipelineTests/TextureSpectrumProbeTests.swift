// TextureSpectrumProbeTests.swift
//
// WS-14 (docs/quality/lanes/WS-14/SPEC.md G2): the two paths now implement ONE
// algorithm for each control (`RenderGraph.applyDetailBands`'s step table against
// `DetailEngine.applyTexture` / `applyClarity`), so this probe is no longer a sanity
// print: the GPU/reference gain ratio is asserted within [0.85, 1.15] at every period,
// for Texture (periods 2–32 px on a 2048 px frame, where Texture's band — 375–1500
// cycles per image long edge — is 1.4–5.5 px) and for Clarity (periods 8–128 px on a
// 2048 px frame; its band is 20–160 cpi, 13–100 px there). The frame was 96 px wide,
// where both bands are above Nyquist and the old ratio tested nothing.
//
// The history below is kept for the record.
//
// The measurement docs/24-detail's gap list calls "Texture one-band spectrum vs
// reference band-pass, unmeasured post-fix". The reference realizes Texture as a
// weighted à-trous band STACK with a resolution-tracked centre; the shipping GPU
// path realizes it as ONE guided band. The ε fix killed the rims; what nobody had
// measured since is the frequency response — per spatial period, how much gain each
// path actually delivers, and where the single band's response parts company with
// the stack's.
//
// PerfProbe's philosophy: this PRINTS a table (TEXSPEC lines) into the lane's log on
// every pipeline-touching push; the assertions are sanity ceilings only, because the
// judgement belongs to the numbers and the dossier, not to a bar guessed before the
// first run. The table is the recorded evidence the gap asks for; interpreting it —
// including whether the divergence at any period warrants the M3 band-stack port —
// happens in docs/24 with the numbers in hand.
//
// Isolated at the stage, deliberately: both paths are evaluated through their
// PRESENCE stage alone (`localStageInput` with a texture-only recipe against
// `DetailEngine.apply`), so the finish transform's nonlinearity cannot fold the
// spectrum before it is read.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class TextureSpectrumProbeTests: XCTestCase {

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh,
                                              .cacheIntermediates: false])

    private func sinusoid(period: Double, width: Int = 2048, height: Int = 32)
        -> ImageBuffer
    {
        ImageBuffer(width: width, height: height) { u, _ in
            let x = u * Double(width)
            return RGB(gray: 0.18 * (1.0 + 0.2 * sin(2 * .pi * x / period)))
        }
    }

    /// RMS contrast of the luminance plane — amplitude relative to the mean, the
    /// quantity a band gain multiplies.
    private func rmsContrast(_ image: ImageBuffer) -> Double {
        var sum = 0.0
        var count = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                sum += RGBColorSpace.rec2020.luminance(image[x, y])
                count += 1
            }
        }
        let mean = sum / count
        guard mean > 1e-9 else { return 0 }
        var variance = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let d = RGBColorSpace.rec2020.luminance(image[x, y]) - mean
                variance += d * d
            }
        }
        return (variance / count).squareRoot() / mean
    }

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
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
        let wroteSomething = stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] != 0 || pixels[$0 + 1] != 0 || pixels[$0 + 2] != 0
        }
        guard wroteSomething else { return nil }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Gain of the presence stage on a sinusoid, on both paths.
    private func gains(_ detail: Detail, period: Double) throws -> (reference: Double, gpu: Double) {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail = detail
        let plan = RenderPlan(recipe: recipe)
        let frame = sinusoid(period: period)
        let base = rmsContrast(frame)
        XCTAssertGreaterThan(base, 0.05, "the probe frame carries no signal")

        // Reference: the presence stage exactly as ReferenceRenderer runs it.
        let radius = Swift.max(Int(Double(frame.width) * 0.02), 3)
        let node = DetailEngine.Decomposition(image: frame, workingRadius: radius)
        let reference = DetailEngine.apply(frame, detail: detail, decomposition: node)

        // GPU: the same stage through the shipping graph, colour/tone identity.
        guard let gpuOut = readBack(
            RenderGraph().localStageInput(
                ciImage(from: frame), plan: plan,
                options: RenderGraph.Options(longEdge: frame.width)),
            width: frame.width, height: frame.height) else {
            throw XCTSkip("GPU stage render failed at period \(period)")
        }
        return (rmsContrast(reference) / base, rmsContrast(gpuOut) / base)
    }

    func testTextureFrequencyResponseOnBothPaths() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        for amount in [100.0, -100.0] {
            var detail = Detail()
            detail.texture = amount
            for period in [2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0] {
                let g = try gains(detail, period: period)
                let ratio = g.gpu / Swift.max(g.reference, 1e-9)
                print(String(format:
                    "TEXSPEC t%+.0f period %4.1f px: reference gain %5.3f   gpu gain %5.3f   "
                    + "gpu/ref %5.3f", amount, period, g.reference, g.gpu, ratio))
                XCTAssertGreaterThanOrEqual(ratio, 0.85,
                                            "Texture \(amount) at \(period) px: gpu/ref \(ratio)")
                XCTAssertLessThanOrEqual(ratio, 1.15,
                                         "Texture \(amount) at \(period) px: gpu/ref \(ratio)")
            }
        }
    }

    func testClarityFrequencyResponseOnBothPaths() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        for amount in [100.0, -100.0] {
            var detail = Detail()
            detail.clarity = amount
            for period in [8.0, 16.0, 24.0, 32.0, 48.0, 64.0, 96.0, 128.0] {
                let g = try gains(detail, period: period)
                let ratio = g.gpu / Swift.max(g.reference, 1e-9)
                print(String(format:
                    "CLARSPEC c%+.0f period %5.1f px: reference gain %5.3f   gpu gain %5.3f   "
                    + "gpu/ref %5.3f", amount, period, g.reference, g.gpu, ratio))
                XCTAssertGreaterThanOrEqual(ratio, 0.85,
                                            "Clarity \(amount) at \(period) px: gpu/ref \(ratio)")
                XCTAssertLessThanOrEqual(ratio, 1.15,
                                         "Clarity \(amount) at \(period) px: gpu/ref \(ratio)")
            }
        }
    }
}

#endif
