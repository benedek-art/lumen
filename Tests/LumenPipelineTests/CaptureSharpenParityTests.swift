// CaptureSharpenParityTests.swift
// S4 capture sharpening on the GPU (`RenderGraph.applyCaptureSharpen`) against
// `CaptureStage.apply`, the reference.
//
// The stage is symmetric under a y flip (a Gaussian, a gradient magnitude, a clamp over
// both diagonals, and a per-pixel ratio), so Core Image's bottom-left origin needs no
// correction here.
//
// THE TOLERANCE is on the RATIO the stage applies, because that is what it computes:
// out/in per pixel. 2e-3 in a float32 working format — eight Richardson–Lucy rounds
// accumulate rounding the double reference does not have, and the clamp's log2 is the
// GPU's — and 2e-2 in the app's half-float format, where a ratio of 1.002 is below a
// half's resolution near 1. The smallest correction the fixtures below take at an edge
// is ~0.1 EV (a 7 % ratio), so both bounds are well under what the stage does.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class CaptureSharpenParityTests: XCTestCase {

    private func context(_ format: CIFormat) -> CIContext {
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                            .workingFormat: format, .cacheIntermediates: false])
    }

    /// A blurred slanted edge, a blurred 4 px grating, a coloured disk and Poisson-ish
    /// noise at the ISO 1600 seed profile: every branch of the stage — deconvolution,
    /// edge clamp, ridge allowance, gate open and gate shut — has pixels here.
    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        let profile = NoiseProfile.forISO(1600)
        var state: UInt64 = 0x1234_5678
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        var plane = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) - Double(w) / 2
                let v = Double(y) - Double(h) / 2
                var value = (u * cos(0.087) + v * sin(0.087)) > 0 ? 0.4 : 0.05
                if y > h * 2 / 3 { value = 0.18 * (1 + 0.5 * cos(Double.pi * Double(x) / 2)) }
                plane[x, y] = value
            }
        }
        plane = SpatialOps.gaussianBlur(plane, sigma: 1.0)
        return ImageBuffer(width: w, height: h) { uu, vv in
            let x = Swift.min(Int(uu * Double(w)), w - 1)
            let y = Swift.min(Int(vv * Double(h)), h - 1)
            let base = plane[x, y]
            let n = noise() * profile.sigma(at: base) * 1.7
            let disk = hypot(uu - 0.25, vv - 0.3) < 0.12
            return disk ? RGB(base * 1.6 + n, base + n, base * 0.5 + n) : RGB(gray: base + n)
        }
    }

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func readBack(_ image: CIImage, _ w: Int, _ h: Int,
                          _ ctx: CIContext) -> ImageBuffer {
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ctx.render(image, toBitmap: base, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBAf, colorSpace: nil)
        }
        return ImageBuffer(width: w, height: h, pixels: pixels)
    }

    func testTheCaptureKernelsCompile() {
        XCTAssertEqual(CaptureKernels.unavailable, [],
                       "an S4 kernel failed to compile: capture sharpening is off on "
                       + "the GPU path while the CPU reference still runs it")
    }

    private func check(_ stage: CaptureStage, format: CIFormat, tolerance: Double,
                       size: (Int, Int), label: String) {
        let (w, h) = size
        let input = scene(w, h)
        let expected = stage.apply(input)
        let got = readBack(RenderGraph.applyCaptureSharpen(ciImage(from: input),
                                                           stage: stage),
                           w, h, context(format))
        var worst = 0.0
        var worstAt = (0, 0)
        var moved = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = input[x, y].g
                guard abs(i) > 1e-3 else { continue }
                let e = expected[x, y].g / i
                let g = got[x, y].g / i
                moved = Swift.max(moved, abs(e - 1))
                if abs(e - g) > worst { worst = abs(e - g); worstAt = (x, y) }
            }
        }
        XCTAssertGreaterThan(moved, 0.05, "\(label): the reference did nothing — the "
                             + "fixture no longer exercises the stage")
        XCTAssertLessThan(worst, tolerance,
                          "\(label): worst ratio difference \(worst) at \(worstAt)")
    }

    func testTheGPUStageMatchesTheReference() throws {
        try XCTSkipUnless(CaptureKernels.available, "capture kernels unavailable")
        let stages: [(String, CaptureStage)] = [
            ("default", CaptureStage(capture: CaptureSharpen(), captureISO: 1600)),
            ("amount 150 radius 1.4",
             CaptureStage(capture: CaptureSharpen(auto: true, radius: 1.4, amount: 150),
                          captureISO: 1600)),
            ("ISO 100 radius 0.5",
             CaptureStage(capture: CaptureSharpen(auto: true, radius: 0.5),
                          captureISO: 100)),
        ]
        for (label, stage) in stages {
            for size in [(160, 120), (97, 131)] {
                check(stage, format: .RGBAf, tolerance: 2e-3, size: size,
                      label: "\(label) \(size) f32")
            }
            check(stage, format: .RGBAh, tolerance: 2e-2, size: (160, 120),
                  label: "\(label) f16")
        }
    }

    func testIdentityIsUntouched() {
        let off = CaptureStage(capture: CaptureSharpen(auto: false), captureISO: 400)
        let input = ciImage(from: scene(32, 32))
        XCTAssertTrue(RenderGraph.applyCaptureSharpen(input, stage: off) === input,
                      "an identity stage must hand back its input, not a copy")
    }
}

#endif
