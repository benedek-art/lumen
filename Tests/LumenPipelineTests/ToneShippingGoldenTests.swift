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
// The parity bounds are TIGHTENED TO MEASUREMENT (gpu-parity #18's own prints:
// worst 0.0213 interactive / 0.0107 export across all six sliders), with the same
// order of headroom the colour-path golden carries for runner variance. The
// per-slider worst still PRINTS (TONEGOLD lines) so drift is visible before it is
// red. Two architectural error sources are known and inside the bounds:
// trilinear-vs-tetrahedral table sampling out of fp16, and the interactive tone
// cube's 32 knots against the reference's 1024-sample table. Run #18 also convicted
// the first draft's aliveness metric — absolute display-linear difference
// under-weighs the shadow controls — so aliveness is measured in stops.

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

    /// Movement in STOPS, floored at a quarter-code of display white — the metric
    /// that is fair to the shadow controls. Run #18 convicted the first draft of this
    /// test, not the pipeline: Blacks −70 genuinely moved the graph (0.0069
    /// display-linear) but an ABSOLUTE bar of 0.02 under-weighs deep shadows by
    /// construction — a 2 EV drop of a 0.003 display value is 0.002 absolute, while
    /// the same drop at the top of the range is 0.5. In stops both read the same.
    private func worstStopShift(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        let floor = 1e-4
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                for channel in 0..<3 {
                    let va = Swift.max(Double(a[x, y][channel]), floor)
                    let vb = Swift.max(Double(b[x, y][channel]), floor)
                    worst = Swift.max(worst, abs(log2(va / vb)))
                }
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
            // Tightened from run #18's own prints (worst 0.0213 interactive /
            // 0.0107 export across all six sliders), with headroom for runner
            // variance in the same proportion the colour-path golden carries.
            let parityBound = lutSize >= LUT3D.exportSize ? 0.018 : 0.035
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

                // ALIVE through the graph that ships: the move is visible against
                // the default render by far more than any table could err — measured
                // in stops, so Blacks' deep-shadow work counts the same as Whites'.
                let moved = worstStopShift(gpu, defaultGPU)
                XCTAssertGreaterThan(moved, 0.2,
                                     "\(move.name) moved the shipping graph by only "
                                         + "\(moved) stops at table size \(lutSize)")

                // PARITY with the reference on the same plan.
                let reference = ReferenceRenderer.render(source, plan: plan)
                let worst = worstDifference(gpu, reference)
                print("TONEGOLD size \(lutSize) \(move.name): parity worst "
                      + String(format: "%.5f", worst)
                      + "  aliveness " + String(format: "%.3f", moved) + " stops")
                XCTAssertLessThan(worst, parityBound,
                                  "\(move.name) diverged from the reference by "
                                      + "\(worst) at table size \(lutSize)")
            }
        }
    }
}

#endif
