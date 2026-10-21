// ToneMaskGPUParityTests.swift
//
// WS-07: the S7 tone mask on the GPU against its definition, directly — not through a
// whole-graph golden where a smooth ramp makes every mask look like the luminance.
//
// The frame is the case the mask exists for and the one fp16 is worst at: a 1 EV
// shadow/midtone step (an edge about 2√ε tall, where `a` sits mid-range) with ±0.2 EV
// of per-pixel noise on both plateaus (where the variance is small and
// `box(S²) − box(S)²` cancels in the working format). `ReferenceRenderer.toneMask`
// explains why the plain variance is kept anyway: where it is that small the mask is
// within a quantum of the luminance whatever `a` comes out as. This test is the
// measurement that claim answers to.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class ToneMaskGPUParityTests: XCTestCase {

    private let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = working
        }
        return CIContext(options: options)
    }()

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

    func testTheGPUToneMaskMatchesTheReferenceOnANoisyModerateEdge() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 400, height = 48
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func jitter() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(UInt64.max >> 11) - 0.5) * 0.4
        }
        let frame = ImageBuffer(width: width, height: height) { u, _ in
            let ev = (u < 0.5 ? -2.5 : -1.5) + jitter()
            return RGB(gray: 0.18 * pow(2.0, ev))
        }

        let log = frame.luminancePlane(space: .rec2020)
            .map { LumenLog.encode(Swift.max($0, 0)) }
        let reference = ReferenceRenderer.toneMask(log, longEdge: width)

        guard let lum = RenderGraph.logLuminance(ciImage(from: frame)),
              let mask = RenderGraph.toneMask(lum, longEdge: width),
              let gpu = readBack(mask, width: width, height: height)
        else { return XCTFail("tone mask render failed") }

        // In EV, the unit the tone gains read the mask in. Borders excluded by one
        // radius: both sides clamp, but the fp16 rounding of a clamped window is not
        // what this measures.
        let radius = ReferenceRenderer.toneMaskRadius(longEdge: width)
        var worst = 0.0, sum = 0.0, count = 0.0
        for y in radius..<(height - radius) {
            for x in radius..<(width - radius) {
                let d = abs(Double(gpu[x, y].g) - reference[x, y]) * LumenLog.range
                worst = Swift.max(worst, d)
                sum += d
                count += 1
            }
        }
        print(String(format: "TONEMASK gpu-vs-reference worst %.4f EV mean %.4f EV",
                     worst, sum / count))
        // One fp16 quantum of the encoded plane is ~0.012 EV; the simulation of this
        // exact pipeline in fp16 put the worst case near 0.02 EV.
        XCTAssertLessThan(sum / count, 0.02,
                          "the GPU tone mask is \(sum / count) EV from its definition on "
                              + "average; the gains it drives will differ by that much")
        XCTAssertLessThan(worst, 0.06,
                          "the GPU tone mask departs from its definition by \(worst) EV "
                              + "somewhere on a noisy 1 EV edge")
    }
}

#endif
