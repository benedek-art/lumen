// CurveStageGPUParityTests.swift
//
// WS-01 / WS-12b N1: the curve left the finish cube and runs as its own stage after it,
// `CurveStage.apply` on the CPU and `RenderGraph.applyCurveStage` (the
// `lumenCurveStage` kernel) on the GPU. This holds the kernel to the Swift stage on the
// cases its branches exist for: a luminance-preserving S, a master curve without
// Preserve Luminance, a lifted black (the `liftedLuma` blend), a luma curve, per-channel
// curves, and an HDR white above 1 (the unit-slope continuation to `top`).

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class CurveStageGPUParityTests: XCTestCase {

    private let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
        ]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = working
        }
        return CIContext(options: options)
    }()

    /// A frame that crosses the whole encoded axis in every channel mix: a grey ramp,
    /// saturated ramps, near-black and (for HDR) values above white.
    private func frame(white: Double) -> ImageBuffer {
        ImageBuffer(width: 256, height: 8) { u, v in
            let x = u * white
            switch Int(v * 8) {
            case 0: return RGB(gray: x)
            case 1: return RGB(x, x * 0.4, x * 0.1)
            case 2: return RGB(x * 0.1, x * 0.6, x)
            case 3: return RGB(gray: x * 0.01)
            case 4: return RGB(x * 0.02, 0, x * 0.03)
            case 5: return RGB(x * 0.9, x, x * 0.2)
            case 6: return RGB(x, x * 0.95, x * 0.9)
            default: return RGB(0.5 * x, 0.25 * x, x)
            }
        }
    }

    private func gpu(_ stage: CurveStage, _ buffer: ImageBuffer, white: Double) -> ImageBuffer? {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                            size: CGSize(width: buffer.width, height: buffer.height),
                            format: .RGBAf, colorSpace: nil)
        guard let out = RenderGraph.applyCurveStage(input, stage, white: white,
                                                    space: .rec2020) else { return nil }
        var pixels = [Float](repeating: 0, count: buffer.width * buffer.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(out, toBitmap: base, rowBytes: buffer.width * 16,
                           bounds: input.extent, format: .RGBAf, colorSpace: nil)
        }
        return ImageBuffer(width: buffer.width, height: buffer.height, pixels: pixels)
    }

    private func check(_ set: CurveSet, white: Double = 1, _ name: String) throws {
        let stack = CurveStack(set)
        let stage = CurveStage(stack)
        XCTAssertFalse(stage.isIdentity, "\(name): the fixture must be a real curve")
        let input = frame(white: white)
        guard let out = gpu(stage, input, white: white) else {
            return XCTFail("\(name): the curve kernel did not run")
        }
        var worst = 0.0
        for y in 0..<input.height {
            for x in 0..<input.width {
                let want = stage.apply(input[x, y], white: white, space: .rec2020)
                let got = out[x, y]
                // In sRGB-encoded units of the display white, the axis the curve is
                // drawn on: 1/255 is one 8-bit code.
                let e = { (c: RGB) in c.map { TransferFunction.srgb.encode(Swift.max($0, 0) / white) } }
                let d = e(want) - e(got)
                worst = Swift.max(worst, Swift.max(abs(d.r), Swift.max(abs(d.g), abs(d.b))))
            }
        }
        XCTAssertLessThan(worst, 0.25 / 255, "\(name): GPU curve stage off by \(worst * 255) codes")
    }

    func testTheCurveKernelMatchesTheStageOnEveryBranch() throws {
        try XCTSkipUnless(KernelLibrary.curveStage != nil, "curve kernel unavailable")

        var s = CurveSet()
        s.point = [[0, 0], [0.25, 0.15], [0.75, 0.85], [1, 1]]
        try check(s, "S-curve, Preserve Luminance")

        var plain = s
        plain.preserveLuminance = false
        try check(plain, "S-curve, per channel")

        var lift = CurveSet()
        lift.point = [[0, 0.2], [1, 1]]
        try check(lift, "lifted black (liftedLuma)")

        var luma = CurveSet()
        luma.luma = [[0, 0], [0.4, 0.1], [0.6, 0.9], [1, 1]]
        try check(luma, "steep luma curve")

        var rgb = CurveSet()
        rgb.r = [[0, 0], [0.5, 0.58], [1, 1]]
        rgb.b = [[0, 0.05], [0.5, 0.45], [1, 0.95]]
        try check(rgb, "red and blue channel curves")

        var param = CurveSet()
        param.parametric.highlights = -100
        param.parametric.shadows = 100
        try check(param, "parametric extremes")

        try check(s, white: 4, "S-curve on an HDR white of 4")
    }
}

#endif
