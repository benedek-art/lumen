// BrushResolutionTests.swift
// Astra M04 and SUPPLEMENTAL-BACKLOG S-10: a brush mask must select the same part of the
// photograph at the draft proxy, the fit view and the export.
//
// A stroke's geometry is stored source-normalized, so the only way the three can disagree
// is in how the rasterizer turns that geometry into pixels. Two ways were measured
// (docs/audit-2026-10/streams/P15-brush.md has the numbers):
//
//   * Stamp spacing had a 1 px floor. Flow is a deposit per stamp, so a radius under ten
//     pixels laid fewer deposits per unit of stroke at low resolution than at high: the
//     M04 trigger line peaked at 0.26 at 512 px and 0.63 at 4096.
//   * A stamp sampled at pixel centres stops being the stroke once its radius spans only
//     a pixel or two, and an Intersect or Subtract of two such strokes folded on that
//     coarse grid is wrong again: max/min/× of two pixel averages is not the pixel
//     average of max/min/×.
//
// HOW "THE SAME PART OF THE PHOTOGRAPH" IS MEASURED. Every render is box-reduced to one
// common grid whose cell is coarser than the coarsest render's pixel, and compared with
// a truth rendered where the thinnest stroke is a 12 px radius. The frame is a 6:1 band
// so the long edge — which is what a stroke's size is a fraction of — can be large while
// the plane stays small enough for a debug test. Sizes are chosen so the thinnest
// stroke's radius is the one the app meets with Size 0.002 (the slider minimum): ~1 px
// at the 1024 draft proxy, ~2.5 px at a 2560 fit view, ~6 px at a 6120 export.
//
// TOLERANCE: every grid cell within 0.10 of the truth, and total selected area within 2%.
// Before the fix the worst cell was off by 0.52 and a thin low-flow stroke kept 16% of
// its area at the proxy.

import XCTest
@testable import LumenCore

final class BrushResolutionTests: XCTestCase {

    // MARK: - Fixture

    /// Grid 170 × 28; every render is an exact multiple of it.
    private static let grid = (width: 170, height: 28)
    /// Thinnest-stroke radius ≈ 1.0 px (draft), 2.55 px (fit), 6.1 px (export).
    private static let resolutions = [(width: 340, height: 56),
                                      (width: 850, height: 140),
                                      (width: 2040, height: 336)]
    private static let truthSize = (width: 4080, height: 672)

    /// Stroke sizes are the app's at a 3× longer edge: 0.006 here is Size 0.002 there.
    private static let minimumSize = 0.006

    private struct Case {
        var name: String
        var mask: Mask
        var sets: [String: BrushStrokeSet]
    }

    private static func line(_ y: Double, x0: Double = 0.1007, x1: Double = 0.9013,
                             size: Double, feather: Double = 50, flow: Double = 100,
                             density: Double = 100, erase: Bool = false,
                             slope: Double = 0) -> BrushStroke {
        let points = (0...8).map { i -> BrushPoint in
            let u = Double(i) / 8
            return BrushPoint(x: x0 + (x1 - x0) * u, y: y + slope * u, pressure: 1, t: i * 8)
        }
        return BrushStroke(points: points, size: size, feather: feather, flow: flow,
                           density: density, erase: erase, automask: false)
    }

    private static func brush(_ ref: String, _ op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .brush)
        c.strokesRef = ref
        return c
    }

    private static func single(_ name: String, _ strokes: [BrushStroke]) -> Case {
        Case(name: name, mask: Mask(id: name, components: [brush(name)]),
             sets: [name: BrushStrokeSet(strokes: strokes)])
    }

    /// Astra M04's own trigger, at this fixture's scale: Size .01 → .03.
    private static let m04 = single("M04 Flow 10 / Density 80 line",
                                    [line(0.5, size: 0.03, flow: 10, density: 80,
                                          slope: 0.013)])
    private static let minimumLine = single("minimum-size line",
                                            [line(0.5, size: minimumSize, slope: 0.07)])
    private static let minimumSoftLine = single("minimum-size Flow 20 Feather 80 line",
                                                [line(0.5, size: minimumSize, feather: 80,
                                                      flow: 20, slope: -0.05)])

    private static var thinCases: [Case] {
        let thin = 2 * minimumSize
        let wide = 0.15
        return [
            m04, minimumLine, minimumSoftLine,
            single("thin dab", [BrushStroke(points: [BrushPoint(x: 0.3031, y: 0.4917)],
                                            size: thin, feather: 50, flow: 100,
                                            density: 100)]),
            single("ordinary Flow 30 line", [line(0.4, size: wide, flow: 30, slope: 0.2)]),
            single("thin erase across a wide stroke",
                   [line(0.5, size: wide),
                    line(0.5, x0: 0.2, x1: 0.8, size: thin, flow: 30, erase: true,
                         slope: 0.03)]),
            Case(name: "Add of two thin components",
                 mask: Mask(id: "add", components: [brush("a1"), brush("a2")]),
                 sets: ["a1": BrushStrokeSet(strokes: [line(0.45, size: thin, flow: 50, slope: 0.1)]),
                        "a2": BrushStrokeSet(strokes: [line(0.55, size: thin, flow: 50, slope: -0.1)])]),
            Case(name: "thin component Subtracted from a wide one",
                 mask: Mask(id: "sub", components: [brush("s1"), brush("s2", .subtract)]),
                 sets: ["s1": BrushStrokeSet(strokes: [line(0.5, size: wide)]),
                        "s2": BrushStrokeSet(strokes: [line(0.5, x0: 0.2, x1: 0.8, size: thin,
                                                            slope: 0.03)])]),
            Case(name: "wide component Intersected with a thin one",
                 mask: Mask(id: "int", components: [brush("i1"), brush("i2", .intersect)]),
                 sets: ["i1": BrushStrokeSet(strokes: [line(0.5, size: wide)]),
                        "i2": BrushStrokeSet(strokes: [line(0.48, x0: 0.05, x1: 0.95,
                                                            size: thin, slope: 0.05)])]),
            Case(name: "two thin components crossing under Intersect",
                 mask: Mask(id: "cross", components: [brush("c1"), brush("c2", .intersect)]),
                 sets: ["c1": BrushStrokeSet(strokes: [line(0.3, size: thin, slope: 0.4)]),
                        "c2": BrushStrokeSet(strokes: [line(0.7, size: thin, slope: -0.4)])]),
        ]
    }

    private static func reduced(_ p: Plane) -> [Double] {
        let (gw, gh) = grid
        let fx = p.width / gw, fy = p.height / gh
        precondition(fx * gw == p.width && fy * gh == p.height)
        var out = [Double](repeating: 0, count: gw * gh)
        for y in 0..<p.height {
            for x in 0..<p.width { out[(y / fy) * gw + x / fx] += Double(p.values[y * p.width + x]) }
        }
        return out.map { $0 / Double(fx * fy) }
    }

    /// Worst cell and area ratio of `c` at `size` against its truth. Returns failures.
    private func failures(_ c: Case, at sizes: [(width: Int, height: Int)]) -> [String] {
        let truth = Self.reduced(MaskRaster.combine(mask: c.mask, size: Self.truthSize,
                                                    strokeSets: c.sets))
        let truthArea = truth.reduce(0, +)
        XCTAssertGreaterThan(truthArea, 1, "\(c.name): the fixture must select something")
        var out: [String] = []
        for size in sizes {
            let g = Self.reduced(MaskRaster.combine(mask: c.mask, size: size,
                                                    strokeSets: c.sets))
            var worst = 0.0
            for i in 0..<g.count { worst = Swift.max(worst, abs(g[i] - truth[i])) }
            let area = g.reduce(0, +) / truthArea
            if worst > 0.10 || abs(area - 1) > 0.02 {
                out.append(String(format: "%@ at %d px: worst cell %.3f, area ×%.3f",
                                  c.name, size.width, worst, area))
            }
        }
        return out
    }

    // MARK: - M04: flow is per unit of stroke, not per pixel

    /// The spacing half on its own, at the resolutions where the stamp radius already
    /// spans a few pixels: the M04 trigger line at all three, and the minimum-size
    /// lines at the fit view and the export. With the 1 px spacing floor uncorrected the
    /// M04 line's area at the proxy is ×0.66 and the soft minimum line's at the fit view
    /// is ×0.45.
    func testAStrokeDepositsTheSameFlowPerUnitLengthAtEveryResolution() {
        var bad = failures(Self.m04, at: Self.resolutions)
        let fitAndExport = Array(Self.resolutions.dropFirst())
        bad += failures(Self.minimumLine, at: fitAndExport)
        bad += failures(Self.minimumSoftLine, at: fitAndExport)
        XCTAssertEqual(bad, [], bad.joined(separator: "\n"))
    }
}
