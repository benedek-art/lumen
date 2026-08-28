// ToneShippingGoldenTests.swift
//
// The first shipping-path golden that MOVES the six tone sliders (docs/23 M2). The
// colour-path golden renders one composite recipe; the proof records drive the
// engine's tables; nothing before this drove each basic tone slider INDIVIDUALLY
// through `RenderGraph.build` — the graph that ships — at both table fidelities and
// compared the pixels against the reference renderer. Which means a defect specific
// to one slider's journey through the graph (a cube wired to the wrong register, a
// scale dropped on one path, the 32-knot bake replacing the 65 on export) had no
// test pointed at it.
//
// Two claims per slider, at BOTH the interactive and the export table size:
//   · ALIVE through the shipping graph — the slider's render differs from the
//     default render by more than table noise;
//   · PARITY — the graph's pixels track `ReferenceRenderer.render` on the same plan.
//
// The parity bounds are generous smoke bounds on first landing, for the same reason
// the spatial golden's was: this lane runs on CI's GPU, not here, and a guessed-tight
// bound costs a red cycle. The per-slider worst is PRINTED (TONEGOLD lines) so the
// bounds can be tightened to measurements on the next pass. Two architectural error
// sources are known and expected: trilinear-vs-tetrahedral table sampling out of fp16
// (0.028 measured on the colour path at export size), and the interactive tone cube's
// 32 knots against the reference's 1024-sample table (docs/23 M2's own measurement:
// up to 0.026 EV localized at export, 0.080 EV at 32 knots).

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class ToneShippingGoldenTests: XCTestCase {

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

    /// A ramp with colour: −8…+6 EV with a slow hue sweep, so a tone gain that
    /// mangles one channel cannot hide in grey.
    private func rampImage(width: Int = 64, height: Int = 8) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            let level = 0.18 * pow(2.0, -8 + u * 14)
            let tint = OKLabTransform.working.toRGB(OKLCh(L: 0.5, C: 0.08, h: u * 300))
            let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
            return normalized * level
        }
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

    private func worstDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                worst = Swift.max(worst, a[x, y].maxAbsDifference(b[x, y]))
            }
        }
        return worst
    }

    func testEachToneSliderMovesTheShippingGraphAndTracksTheReference() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")

        let source = rampImage()
        let ci = ciImage(from: source)

        let moves: [(name: String, mutate: (inout Recipe) -> Void)] = [
            ("exposure +1.5", { $0.develop.tone.exposure = 1.5 }),
            ("contrast +60", { $0.develop.tone.contrast = 60 }),
            ("highlights -80", { $0.develop.tone.highlights = -80 }),
            ("shadows +80", { $0.develop.tone.shadows = 80 }),
            ("whites +70", { $0.develop.tone.whites = 70 }),
            ("blacks -70", { $0.develop.tone.blacks = -70 }),
        ]

        for lutSize in [LUT3D.interactiveSize, LUT3D.exportSize] {
            // Smoke bounds on first landing; tighten to the TONEGOLD prints.
            let parityBound = lutSize >= LUT3D.exportSize ? 0.06 : 0.12
            var defaults = Recipe()
            defaults.develop.denoise.mode = .off
            let defaultPlan = RenderPlan(recipe: defaults, lutSize: lutSize)
            guard let defaultGPU = readBack(
                RenderGraph().build(ci, plan: defaultPlan,
                                    options: RenderGraph.Options(longEdge: source.width,
                                                                 lutSize: lutSize)),
                width: source.width, height: source.height) else {
                return XCTFail("default render failed at size \(lutSize)")
            }

            for move in moves {
                var recipe = Recipe()
                recipe.develop.denoise.mode = .off
                move.mutate(&recipe)
                let plan = RenderPlan(recipe: recipe, lutSize: lutSize)

                guard let gpu = readBack(
                    RenderGraph().build(ci, plan: plan,
                                        options: RenderGraph.Options(longEdge: source.width,
                                                                     lutSize: lutSize)),
                    width: source.width, height: source.height) else {
                    return XCTFail("\(move.name) render failed at size \(lutSize)")
                }

                // ALIVE through the graph that ships: the move is visible against the
                // default render by far more than any table could err.
                let moved = worstDifference(gpu, defaultGPU)
                XCTAssertGreaterThan(moved, 0.02,
                                     "\(move.name) moved the shipping graph by only "
                                         + "\(moved) at table size \(lutSize)")

                // PARITY with the reference on the same plan.
                let reference = ReferenceRenderer.render(source, plan: plan)
                let worst = worstDifference(gpu, reference)
                print("TONEGOLD size \(lutSize) \(move.name): parity worst "
                      + String(format: "%.5f", worst)
                      + "  aliveness " + String(format: "%.4f", moved))
                XCTAssertLessThan(worst, parityBound,
                                  "\(move.name) diverged from the reference by "
                                      + "\(worst) at table size \(lutSize)")
            }
        }
    }
}

#endif
