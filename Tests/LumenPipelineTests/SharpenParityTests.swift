// SharpenParityTests.swift
// S12 creative sharpening on the GPU (`RenderGraph.applySharpen(_:stage:)`) against
// `SharpenStage.apply`. Same fixture and the same tolerances as
// CaptureSharpenParityTests, for the same reasons (a y-flip-symmetric stage; a ratio
// compared in f32 and in the app's f16).

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class SharpenParityTests: XCTestCase {

    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        var state: UInt64 = 0x51ED
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        var plane = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) - Double(w) / 2
                let v = Double(y) - Double(h) / 2
                var value = (u * cos(0.087) + v * sin(0.087)) > 0 ? 0.36 : 0.09
                if y > h * 2 / 3 { value = 0.18 * (1 + 0.5 * cos(Double.pi * Double(x) / 2)) }
                if x == w / 4 && y < h / 2 { value = 0.9 }   // a one-pixel bright line
                plane[x, y] = value
            }
        }
        plane = SpatialOps.gaussianBlur(plane, sigma: 0.8)
        return ImageBuffer(width: w, height: h) { uu, vv in
            let x = Swift.min(Int(uu * Double(w)), w - 1)
            let y = Swift.min(Int(vv * Double(h)), h - 1)
            let base = plane[x, y] * (1 + 0.04 * noise())
            let disk = hypot(uu - 0.7, vv - 0.3) < 0.12
            return disk ? RGB(base * 1.6, base, base * 0.5) : RGB(gray: base)
        }
    }

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func readBack(_ image: CIImage, _ w: Int, _ h: Int,
                          _ format: CIFormat) -> ImageBuffer {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(),
                                      .outputColorSpace: NSNull(),
                                      .workingFormat: format, .cacheIntermediates: false])
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ctx.render(image, toBitmap: base, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBAf, colorSpace: nil)
        }
        return ImageBuffer(width: w, height: h, pixels: pixels)
    }

    func testTheSharpenKernelsCompile() {
        XCTAssertEqual(SharpenKernels.unavailable, [])
    }

    func testTheGPUStageMatchesTheReference() throws {
        try XCTSkipUnless(SharpenKernels.available, "sharpen kernels unavailable")
        let settings: [(String, ManualSharpen, Double)] = [
            ("70/1/25/0", ManualSharpen(amount: 70, radius: 1, detail: 25), 1),
            ("150/3/100/0 halo 50",
             ManualSharpen(amount: 150, radius: 3, detail: 100, haloSuppression: 50), 1),
            ("100/1/0/60", ManualSharpen(amount: 100, radius: 1, detail: 0, masking: 60), 1),
            ("100/2 at scale 0.4", ManualSharpen(amount: 100, radius: 2), 0.4),
        ]
        for (label, p, scale) in settings {
            let stage = SharpenStage(p, decodeScale: scale)
            for (format, tolerance) in [(CIFormat.RGBAf, 2e-3), (CIFormat.RGBAh, 2e-2)] {
                let (w, h) = (150, 110)
                let input = scene(w, h)
                let expected = stage.apply(input)
                let got = readBack(RenderGraph.applySharpen(ciImage(from: input),
                                                            stage: stage), w, h, format)
                var worst = 0.0
                var moved = 0.0
                for y in 0..<h {
                    for x in 0..<w {
                        let i = input[x, y].g
                        guard i > 1e-3 else { continue }
                        moved = Swift.max(moved, abs(expected[x, y].g / i - 1))
                        worst = Swift.max(worst, abs(expected[x, y].g / i - got[x, y].g / i))
                    }
                }
                XCTAssertGreaterThan(moved, 0.03, "\(label): the reference did nothing")
                XCTAssertLessThan(worst, tolerance, "\(label) \(format): ratio diff \(worst)")
            }
        }
    }
}

#endif
