// TextureSpectrumProbeTests.swift
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

    private func sinusoid(period: Double, width: Int = 96, height: Int = 32)
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

    func testTextureFrequencyResponseOnBothPaths() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")

        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail.texture = 100
        let plan = RenderPlan(recipe: recipe)
        var detail = Detail()
        detail.texture = 100

        for period in [2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0] {
            let frame = sinusoid(period: period)
            let base = rmsContrast(frame)
            XCTAssertGreaterThan(base, 0.05, "the probe frame carries no signal")

            // Reference: the presence stage exactly as ReferenceRenderer runs it.
            let radius = Swift.max(Int(Double(frame.width) * 0.02), 3)
            let node = DetailEngine.Decomposition(image: frame, workingRadius: radius)
            let reference = DetailEngine.apply(frame, detail: detail,
                                               decomposition: node)
            let referenceGain = rmsContrast(reference) / base

            // GPU: the same stage through the shipping graph, colour/tone identity.
            guard let gpuOut = readBack(
                RenderGraph().localStageInput(
                    ciImage(from: frame), plan: plan,
                    options: RenderGraph.Options(longEdge: frame.width)),
                width: frame.width, height: frame.height) else {
                return XCTFail("GPU stage render failed at period \(period)")
            }
            let gpuGain = rmsContrast(gpuOut) / base

            print(String(format:
                "TEXSPEC period %4.1f px: reference gain %5.3f   gpu gain %5.3f   "
                + "gpu/ref %5.3f", period, referenceGain, gpuGain,
                referenceGain > 1e-9 ? gpuGain / referenceGain : .nan))

            // Sanity ceilings only — a gain of 5x or an attenuation to a fifth at
            // +100 on either path is a wiring failure, not a tuning question.
            for (label, gain) in [("reference", referenceGain), ("gpu", gpuGain)] {
                XCTAssertLessThan(gain, 5.0,
                                  "\(label) gain \(gain) at period \(period)")
                XCTAssertGreaterThan(gain, 0.2,
                                     "\(label) gain \(gain) at period \(period)")
            }
        }
    }
}

#endif
