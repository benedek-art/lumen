// The graph-cost probe behind docs/23 M1a's central bet: that a draft can run the FULL
// pipeline at reduced resolution instead of switching stages off. This times
// `RenderGraph.build` + readback at the candidate draft sizes, with every stage a
// draft currently gates out turned ON, and prints a table into the lane's log. The
// assertions are sanity ceilings only — the real budget (≤ ~35 ms p95 on the owner's
// machine) is judged from the printed numbers and the owner's HUD, not from a shared
// runner whose GPU varies.
//
// What it deliberately leaves out, so the numbers mean one thing:
//   · decode — the app decodes at target scale; this probe generates at target scale
//   · masks — their CPU raster cost is measured separately (docs/23 M0 probe b);
//     the GPU-side apply is one more kernel pass per mask
//   · the film chain — no stock is loaded, so halation and grain are off; their cost
//     is two gaussians and a tiled plate when a stock is on
#if os(macOS)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import LumenCore
@testable import LumenPipeline

final class PerfProbeTests: XCTestCase {

    /// A synthetic frame with gradients and fine structure, generated on the GPU so
    /// the probe times rendering rather than a 24-megapixel CPU fill.
    private func syntheticFrame(longEdge: Int) -> CIImage {
        let w = longEdge, h = longEdge * 2 / 3
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: w, y: h)
        gradient.color0 = CIColor(red: 0.02, green: 0.03, blue: 0.05)
        gradient.color1 = CIColor(red: 0.9, green: 0.8, blue: 0.6)

        let checker = CIFilter.checkerboardGenerator()
        checker.width = 6
        checker.color0 = CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        checker.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)

        let detail = checker.outputImage!.cropped(to: rect)
            .applyingFilter("CIMultiplyCompositing",
                            parameters: [kCIInputBackgroundImageKey:
                                            gradient.outputImage!.cropped(to: rect)])
        return detail
    }

    /// Every stage a draft currently gates out, on, at working values.
    private func fullRecipe() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.highlights = -40
        r.develop.tone.shadows = 25
        r.develop.raw.temp = 5200
        r.develop.color.saturation = 12
        r.develop.color.vibrance = 10
        r.develop.detail.texture = 30
        r.develop.detail.clarity = 25
        r.develop.detail.dehaze = 15
        r.develop.detail.sharpen.amount = 80
        r.develop.denoise.mode = .classic
        return r
    }

    func testTimeFullPipelineAtDraftSizes() throws {
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let recipe = fullRecipe()

        for longEdge in [1024, 1536, 2048] {
            let source = syntheticFrame(longEdge: longEdge)
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize)

            func renderPass(draft: Bool) -> Double {
                let opts = RenderGraph.Options(longEdge: longEdge, draft: draft,
                                               lutSize: LUT3D.interactiveSize)
                var best = Double.greatestFiniteMagnitude
                for rep in 0..<4 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let out = RenderGraph().build(source, plan: plan, options: opts)
                    let cg = context.createCGImage(out, from: out.extent)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    XCTAssertNotNil(cg)
                    if rep > 0 { best = Swift.min(best, ms) } // rep 0 is warm-up
                }
                return best
            }

            let gated = renderPass(draft: true)
            let full = renderPass(draft: false)
            print(String(format:
                "PERFPROBE longEdge %4d: gated draft %7.1f ms   full pipeline %7.1f ms   delta %+.1f ms",
                longEdge, gated, full, full - gated))
            XCTAssertLessThan(full, 10_000,
                "a full-pipeline frame at \(longEdge) px took over ten seconds — "
                    + "something is broken, not merely slow")
        }
    }
}
#endif
