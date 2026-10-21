// What one mask raster costs on the CPU, per component kind and per refine step, at the
// three sizes the app actually asks for: the 1024 draft proxy, the 4096 interactive
// settle ceiling, and a 24 MP delivery. Lane M9's baseline (docs/quality/lanes/M9).
//
// Gated behind LUMEN_BENCH like `InteractiveCostBenchTests`, so CI never pays for it.
// Run in release: `swift test -c release -Xswiftc -enable-testing --filter
// MaskRasterCostBenchTests` with LUMEN_BENCH=1. Medians over a few repeats; the
// absolute numbers belong to the machine, read the ratios.
import XCTest
@testable import LumenCore

final class MaskRasterCostBenchTests: XCTestCase {

    private var enabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["LUMEN_BENCH"] else { return false }
        return !["", "0", "false", "no", "off"].contains(
            raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func median(_ name: String, repeats: Int, _ body: () -> Void) {
        body()
        var samples: [Double] = []
        for _ in 0..<repeats {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        print(String(format: "BENCH %-44@ p50 %10.2f ms", name as NSString,
                     samples[samples.count / 2]))
    }

    /// A smooth colour field: luminance spans the EV axis, hue turns across the frame.
    private func picture(_ w: Int, _ h: Int) -> ImageBuffer {
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) / Double(w), v = Double(y) / Double(h)
                let l = pow(2, -8 + 10 * u)
                let i = (y * w + x) * 4
                px[i] = Float(l * (0.6 + 0.4 * sin(6 * v)))
                px[i + 1] = Float(l * (0.6 + 0.4 * cos(5 * u + 2 * v)))
                px[i + 2] = Float(l * (0.6 + 0.4 * sin(3 * v + 1)))
            }
        }
        return ImageBuffer(width: w, height: h, pixels: px)
    }

    func testMaskRasterCostPerKind() throws {
        try XCTSkipUnless(enabled, "set LUMEN_BENCH=1")
        let sizes: [(String, Int, Int, Int)] = [
            ("1024", 1024, 683, 5), ("4096", 4096, 2731, 3), ("24MP", 6000, 4000, 1)]

        var luma = MaskComponent(op: .add, kind: .lumaRange)
        luma.lo = 0.3; luma.hi = 0.7
        var lumi = MaskComponent(op: .add, kind: .luminosity)
        lumi.series = .midtones; lumi.level = 2
        var color1 = MaskComponent(op: .add, kind: .colorRange)
        color1.samples = [[0.4, 0.2, 0.1]]
        var color4 = MaskComponent(op: .add, kind: .colorRange)
        color4.samples = [[0.4, 0.2, 0.1], [0.1, 0.3, 0.5], [0.2, 0.2, 0.2], [0.5, 0.4, 0.1]]
        var sim = MaskComponent(op: .add, kind: .similarity)
        sim.samples = [[0.4, 0.2, 0.1]]
        var linear = MaskComponent(op: .add, kind: .linear)
        linear.line = [0.5, 0.2, 0.5, 0.8]
        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.5, 0.5]; radial.radii = [0.3, 0.2]
        var polygon = MaskComponent(op: .add, kind: .polygon)
        polygon.path = (0..<24).map { k in
            let t = Double(k) / 24 * 2 * .pi
            return [0.5 + 0.3 * cos(t), 0.5 + 0.25 * sin(t)]
        }
        let strokes = BrushStrokeSet(strokes: (0..<10).map { k in
            BrushStroke(points: (0..<40).map { j in
                BrushPoint(x: 0.1 + 0.02 * Double(j), y: 0.1 + 0.07 * Double(k))
            })
        })
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "bench"

        for (label, w, h, repeats) in sizes {
            let src = picture(w, h)
            let size = (width: w, height: h)
            func time(_ name: String, _ c: MaskComponent) {
                median("\(label) \(name)", repeats: repeats) {
                    _ = MaskRaster.rasterize(component: c, size: size, source: src,
                                             strokes: strokes)
                }
            }
            time("linear", linear)
            time("radial", radial)
            time("polygon(24)", polygon)
            time("lumaRange", luma)
            time("luminosity", lumi)
            time("colorRange 1 sample", color1)
            time("colorRange 4 samples", color4)
            time("similarity 1 sample", sim)
            time("brush 10 strokes cold", brush)

            let base = MaskRaster.rasterize(component: luma, size: size, source: src)
            func chain(_ name: String, _ r: MaskRefine) {
                median("\(label) refine \(name)", repeats: repeats) {
                    _ = MaskRaster.refined(base, refine: r, source: src)
                }
            }
            chain("identity", MaskRefine())
            chain("levels", MaskRefine(levelsLo: 10, levelsHi: 90, levelsGamma: 1.5))
            chain("blur 30", MaskRefine(blur: 30))
            chain("edge +20", MaskRefine(edge: 20))
            chain("feather 30 (guided)", MaskRefine(feather: 30))
            median("\(label) guidePlane", repeats: repeats) {
                _ = MaskRaster.guidePlane(source: src, width: w, height: h)
            }
            let stack = Mask(id: "s", components: [luma, {
                var r = radial; r.op = .intersect; return r }()])
            median("\(label) combine luma∩radial", repeats: repeats) {
                _ = MaskRaster.combine(mask: stack, size: size, source: src)
            }
        }
    }
}
