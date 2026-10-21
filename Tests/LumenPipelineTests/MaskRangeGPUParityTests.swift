// MaskRangeGPUParityTests.swift
// Lane M9: the range-mask kernels against the CPU definition.
//
// `MaskRaster.lumaRangePlane`, `luminosityPlane`, `colorRangePlane` and `levels` are the
// definition; `MaskGPU`'s range path is only allowed to exist while it reads the same
// numbers off the same picture. Each case runs the GPU path over a stage buffer handed
// in as a CIImage and the reference over the SAME buffer at the SAME size, so the only
// thing compared is the kernel arithmetic: no resampling on either side.
//
// Three sizes, as `MaskGPUParityTests`: square, wide-and-odd, tall. The picture spans
// the whole EV axis and past both ends, turns through every hue, and carries negative
// and zero components, because a stage input in a wide working space does.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskRangeGPUParityTests: XCTestCase {

    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (128, 320)]

    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull(),
                                              .workingFormat: CIFormat.RGBAf])

    /// Worst pixel allowed on a soft selection, and the share of pixels allowed past
    /// 1e-3 on any selection. A hard band is a step, and a Float32 log2 a few ulps from
    /// the Double one flips the odd pixel sitting exactly on it; that is a share, not a
    /// worst pixel.
    private let worstSoft = 2e-3
    private let shareTolerance = 1e-3

    // MARK: - Fixtures

    private func picture(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            // Luminance from 2^-13 to 2^6: past both ends of the -10…+4 EV axis.
            let l = pow(2, -13 + 19 * u)
            let t = 2 * Double.pi * v
            var c = RGB(l * (0.55 + 0.45 * cos(t)),
                        l * (0.55 + 0.45 * cos(t - 2.1)),
                        l * (0.55 + 0.45 * cos(t + 2.1)))
            // A strip of out-of-gamut and black pixels.
            if v > 0.9 { c = RGB(c.r * 1.4 - 0.05 * l, c.g * 0.3, -0.02 * l) }
            if u < 0.02 { c = RGB.zero }
            return c
        }
    }

    private func image(_ buffer: ImageBuffer) -> CIImage {
        buffer.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: buffer.width * 16,
                    size: CGSize(width: buffer.width, height: buffer.height),
                    format: .RGBAf, colorSpace: nil)
        }
    }

    private func band(_ lo: Double, _ hi: Double, smooth: Double,
                      channel: MaskChannel? = nil, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .lumaRange)
        c.lo = lo; c.hi = hi; c.smooth = smooth; c.channel = channel
        return c
    }

    private func luminosity(_ series: LuminositySeries, level: Double,
                            channel: MaskChannel? = nil) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .luminosity)
        c.series = series; c.level = level; c.channel = channel
        return c
    }

    private func colour(_ samples: [[Double]], refine: Double,
                        op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .colorRange)
        c.samples = samples; c.rangeAmount = refine
        return c
    }

    /// Colours the picture actually contains, so a range selects something.
    private func samples(_ picture: ImageBuffer, _ n: Int) -> [[Double]] {
        (0..<n).map { k in
            let x = (picture.width * (3 + 5 * k)) / 48
            let y = (picture.height * (1 + 7 * k)) / 64
            let c = picture[x, y]
            return [c.r, c.g, c.b]
        }
    }

    private func cases(_ picture: ImageBuffer) -> [(name: String, mask: Mask, soft: Bool)] {
        var out: [(String, Mask, Bool)] = []
        for channel in [nil, MaskChannel.red, .green, .blue, .max, .min] {
            for smooth in [0.0, 25, 100] {
                out.append(("band \(channel?.rawValue ?? "luma") smooth \(smooth)",
                            Mask(id: "b", components: [band(0.3, 0.65, smooth: smooth,
                                                            channel: channel)]),
                            smooth > 0))
            }
        }
        out.append(("band reaching both ends",
                    Mask(id: "b2", components: [band(0, 1, smooth: 50)]), true))
        for series in LuminositySeries.allCases {
            for level in [1.0, 3.5] {
                out.append(("luminosity \(series.rawValue) \(level)",
                            Mask(id: "l", components: [luminosity(series, level: level)]),
                            true))
            }
        }
        out.append(("luminosity on the brightest channel",
                    Mask(id: "l2", components: [luminosity(.midtones, level: 2,
                                                           channel: .max)]), true))
        for n in [1, 3, 8] {
            for refine in [0.0, 50, 100] {
                out.append(("colour \(n) samples refine \(refine)",
                            Mask(id: "c", components: [colour(samples(picture, n),
                                                              refine: refine)]),
                            true))
            }
        }
        // Folded with gradients and each other, inverted, and through Levels.
        var linear = MaskComponent(op: .intersect, kind: .linear)
        linear.line = [0.5, 0.9, 0.5, 0.1]
        var stack = Mask(id: "s", components: [
            band(0.2, 0.8, smooth: 50), linear,
            colour(samples(picture, 2), refine: 60, op: .subtract),
        ])
        out.append(("band ∩ gradient − colour", stack, true))
        stack.invert = true
        out.append(("inverted stack", stack, true))
        var levels = Mask(id: "v", components: [band(0.25, 0.7, smooth: 60)])
        levels.refine.levelsLo = 15
        levels.refine.levelsHi = 80
        levels.refine.levelsGamma = 1.8
        out.append(("levels with gamma", levels, true))
        levels.refine.levelsGamma = 1
        levels.invert = true
        out.append(("inverted levels, gamma 1", levels, true))
        var partial = band(0.3, 0.7, smooth: 40)
        partial.amount = 37
        partial.invert = true
        out.append(("inverted component at 37%", Mask(id: "p", components: [partial]), true))
        return out
    }

    private func gpuPlane(_ mask: Mask, source: CIImage,
                          _ size: (w: Int, h: Int)) throws -> Plane {
        let extent = CGRect(x: 0, y: 0, width: size.w, height: size.h)
        let alpha = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent, source: source),
                                  "the GPU path refused a mask this table says it takes")
        var bytes = [Float](repeating: 0, count: size.w * size.h * 4)
        bytes.withUnsafeMutableBytes { raw in
            context.render(alpha, toBitmap: raw.baseAddress!, rowBytes: size.w * 16,
                           bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        var plane = Plane(width: size.w, height: size.h)
        for i in 0..<(size.w * size.h) { plane.values[i] = bytes[i * 4] }
        return plane
    }

    // MARK: - The comparison

    func testRangeKernelsMatchTheReference() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable,
                          "range kernels failed: \(KernelLibrary.unavailableMaskKernels)")
        for size in sizes {
            let buffer = picture(size.w, size.h)
            let source = image(buffer)
            for (name, mask, soft) in cases(buffer) {
                let reference = MaskRaster.combine(mask: mask,
                                                   size: (width: size.w, height: size.h),
                                                   source: buffer)
                let gpu = try gpuPlane(mask, source: source, size)
                var worst = 0.0, wx = 0, wy = 0, past = 0
                for y in 0..<size.h {
                    for x in 0..<size.w {
                        let d = abs(reference[x, y] - gpu[x, y])
                        if d > 1e-3 { past += 1 }
                        if d > worst { worst = d; wx = x; wy = y }
                    }
                }
                let share = Double(past) / Double(size.w * size.h)
                let detail = "\(name) at \(size.w)×\(size.h): worst \(worst) at (\(wx), \(wy))"
                    + " — reference \(reference[wx, wy]), gpu \(gpu[wx, wy]); "
                    + "share past 1e-3 \(share)"
                XCTAssertLessThan(share, shareTolerance, detail)
                if soft { XCTAssertLessThan(worst, worstSoft, detail) }
                // A selection that is empty on both sides proves nothing.
                if name.hasPrefix("band luma smooth 25") {
                    XCTAssertGreaterThan(reference.values.max() ?? 0, 0.9, detail)
                    XCTAssertLessThan(reference.values.min() ?? 1, 0.1, detail)
                }
            }
        }
    }

    /// A colour-range fixture that selects nothing would pass the comparison above
    /// trivially. Pin that the sampled colours are actually selected.
    func testTheColourFixtureSelectsSomething() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable)
        let buffer = picture(256, 256)
        let mask = Mask(id: "c", components: [colour(samples(buffer, 3), refine: 50)])
        let gpu = try gpuPlane(mask, source: image(buffer), (256, 256))
        let selected = gpu.values.filter { $0 > 0.5 }.count
        XCTAssertGreaterThan(selected, 256 * 256 / 100)
        XCTAssertLessThan(selected, 256 * 256 * 9 / 10)
    }

    // MARK: - Eligibility

    func testOnlyPointwiseChainsAndRangeKindsTakeTheGPUPath() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable)
        let longEdge = 2048
        let plain = Mask(id: "a", components: [band(0.2, 0.6, smooth: 50)])
        XCTAssertTrue(MaskGPU.isGPUEvaluable(plain, longEdge: longEdge))
        XCTAssertTrue(MaskGPU.readsPicture(plain))
        XCTAssertNil(MaskGPU.alpha(for: plain, extent: CGRect(x: 0, y: 0, width: 8, height: 8),
                                   source: nil),
                     "a band with no picture to read must fall back, not render empty")

        var levels = plain
        levels.refine.levelsGamma = 2
        XCTAssertTrue(MaskGPU.isGPUEvaluable(levels, longEdge: longEdge))

        var edge = plain
        edge.refine.edge = 5
        XCTAssertFalse(MaskGPU.isGPUEvaluable(edge, longEdge: longEdge))
        var blur = plain
        blur.refine.blur = 10
        XCTAssertFalse(MaskGPU.isGPUEvaluable(blur, longEdge: longEdge))
        var guided = plain
        guided.refine.feather = 10
        XCTAssertFalse(MaskGPU.isGPUEvaluable(guided, longEdge: longEdge))
        // Refine whose radius rounds to nothing at this size runs no guided filter on
        // the CPU either, so it is pointwise here.
        guided.refine.feather = 1
        XCTAssertEqual(MaskRaster.refineRadius(feather: 1, longEdge: 1024), 0)
        XCTAssertTrue(MaskGPU.isGPUEvaluable(guided, longEdge: 1024))

        for kind in [MaskKind.brush, .polygon, .similarity, .similarityLine, .aiSubject,
                     .depthRange, .maskRef] {
            let c = MaskComponent(op: .add, kind: kind)
            XCTAssertFalse(MaskGPU.isGPUEvaluable(
                Mask(id: "k", components: [band(0.2, 0.6, smooth: 50), c]),
                longEdge: longEdge), "\(kind) has no GPU form")
        }
        var bad = band(0.2, 0.6, smooth: 50)
        bad.hi = nil
        XCTAssertFalse(MaskGPU.isGPUEvaluable(Mask(id: "x", components: [bad]),
                                              longEdge: longEdge),
                       "an incomplete component is the CPU fold's business")
    }
}

#endif
