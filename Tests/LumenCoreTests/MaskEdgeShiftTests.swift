// MaskEdgeShiftTests.swift
// Edge Shift, swept rather than sampled.
//
// WHAT THE OLD TEST COULD NOT SEE, because this suite exists to be the answer to it.
// `EngineIntegrationTests.testEdgeShiftAndBlurMoveTheMaskInTheDirectionTheyClaim` puts
// ONE radial at ONE feather on ONE raster through THREE settings of the slider — Edge
// 0, +40, −40 — and asserts the sign of the coverage change. Every one of those
// assertions is true, and was true while an Edge of −20 on the everyday two-component
// mask GREW the selection by 8.6%. Three points on a one-dimensional slice of a space
// whose real dimensions are component count × per-component softness × raster size ×
// Edge, and the defect lived in the second of those, which the slice held fixed.
//
// So the sweeps below vary all four. What they assert is not a number but the two
// properties the control's own label promises: EROSION SHRINKS AND DILATION GROWS, at
// every step, and coverage is MONOTONE in Edge across the whole travel. A slider that
// is not monotone in the quantity it names has no reading a photographer can hold.
//
// THE RECONSTRUCTION IS GONE (docs/quality/lanes/WS-50/REPORT.md). Edge is now a flat
// greyscale dilation / erosion by a disc (an octagon, `MaskRaster.octagonMorphology`),
// which is monotone per pixel by construction and keeps every profile it is given. The
// tests that pinned the old reconstruction bit-for-bit, and the ramp-width statistics
// that decided when to use it, went with it: they asserted the machinery, and the
// machinery was what rebuilt a smooth radial as a linear ramp and tore thin features.
// The sweeps below are unchanged — they assert the label, and the label has not moved.

import XCTest
@testable import LumenCore

final class MaskEdgeShiftTests: XCTestCase {

    // MARK: - Fixtures

    private func radial(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
                        feather: Double, rotation: Double = 0) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, cy]
        c.radii = [rx, ry]
        c.feather = feather
        c.rotation = rotation
        return c
    }

    private func polygon(feather: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = [[0.22, 0.18], [0.80, 0.26], [0.74, 0.82], [0.26, 0.71]]
        c.feather = feather
        return c
    }

    /// A hard outline confined to the left half, so a soft radial beside it keeps its
    /// own boundary instead of being swallowed by the fill.
    private func compactPolygon(feather: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = [[0.08, 0.22], [0.42, 0.28], [0.38, 0.80], [0.10, 0.70]]
        c.feather = feather
        return c
    }

    private func linear() -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .linear)
        c.line = [0.30, 0.20, 0.70, 0.80]
        return c
    }

    private func folded(_ components: [MaskComponent], _ w: Int, _ h: Int,
                        edge: Double = 0) -> Plane {
        var m = Mask(components: components)
        m.refine = MaskRefine(feather: 0, edge: edge, blur: 0)
        return MaskRaster.combine(mask: m, size: (width: w, height: h))
    }

    private func coverage(_ p: Plane) -> Double { p.mean }

    /// The mask that named this defect: one hard component and one soft one, both
    /// `.add`, which is what "brighten these two areas" produces on any afternoon.
    private var hardComponent: MaskComponent { radial(0.30, 0.50, 0.15, 0.15, feather: 0) }
    private var softComponent: MaskComponent { radial(0.70, 0.50, 0.20, 0.20, feather: 100) }
    private var mixedMask: [MaskComponent] { [hardComponent, softComponent] }

    /// The whole travel, at the step the panel ships (1) near zero and coarser out at
    /// the ends, because the sign flip this suite was written for lives between −2 and
    /// −12 and a sweep on tens would step straight over it.
    private let sliderSweep: [Double] = [-50, -44, -38, -32, -26, -22, -18, -16, -14, -12,
                                         -10, -8, -6, -5, -4, -3, -2, -1, 0,
                                         1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 22,
                                         26, 32, 38, 44, 50]

    // MARK: - 2. The defect

    /// THE MASK THAT NAMED THIS DEFECT, over the whole slider.
    ///
    /// Before: Edge −20 grew it by 8.6% at 320², Edge 0 was the GLOBAL MINIMUM of the
    /// travel, and the erode half was a hump that peaked around −26 and came back down
    /// without ever passing below where it started. Every setting of an erode control
    /// dilated.
    func testTheMixedWidthMaskErodesDilatesAndIsMonotoneAcrossTheWholeSlider() {
        for (w, h) in [(96, 96), (160, 160), (192, 192), (320, 320)] {
            let base = coverage(folded(mixedMask, w, h))
            XCTAssertGreaterThan(base, 0, "the fixture selects nothing at \(w)×\(h)")

            var previous = -Double.infinity
            var previousEdge = -Double.infinity
            for edge in sliderSweep {
                let c = coverage(folded(mixedMask, w, h, edge: edge))
                // Monotone in Edge: the whole point of a boundary control.
                XCTAssertGreaterThanOrEqual(
                    c, previous - 1e-12,
                    "at \(w)×\(h) coverage fell from Edge \(previousEdge) to Edge \(edge) "
                    + "(\(previous) → \(c)) — Edge is not monotone")
                previous = c
                previousEdge = edge
                if edge < 0 {
                    XCTAssertLessThan(c, base,
                                      "Edge \(edge) GREW the mask at \(w)×\(h): "
                                      + "\(c / base)× — an erode setting dilated")
                }
                if edge > 0 {
                    XCTAssertGreaterThan(c, base,
                                         "Edge \(edge) did not grow the mask at \(w)×\(h)")
                }
            }
        }
    }

    /// AND IT GETS WORSE WITH RESOLUTION, which is the half that made it a delivery bug
    /// rather than a preview bug: the reconstruction's ramp scales with the frame, so
    /// the same recipe was more wrong in the exported file than in the loupe. Erosion at
    /// −40 now shrinks by a consistent amount at every raster instead of growing more
    /// the larger the render gets.
    func testTheErosionIsTheSameSizeAtEveryRaster() {
        var ratios: [Double] = []
        for n in [96, 160, 192, 320, 480] {
            let base = coverage(folded(mixedMask, n, n))
            let eroded = coverage(folded(mixedMask, n, n, edge: -40))
            ratios.append(eroded / base)
        }
        let lo = ratios.min() ?? 0, hi = ratios.max() ?? 0
        XCTAssertLessThan(hi, 1, "Edge −40 grew the mask at some raster: \(ratios)")
        XCTAssertLessThan(hi - lo, 0.03,
                          "Edge −40 erodes by a different amount at different rasters "
                          + "(\(ratios)) — the shift is not resolution-independent")
    }

    /// No pixel may be dragged the wrong way by much, either. Coverage is a mean, and a
    /// mean can be right while the plane under it is wrong: before this change, Edge −20
    /// at 192² moved 8058 pixels UP and 5324 down, and the worst of them went from alpha
    /// 0.0000 to 0.3611 — a pixel entirely outside the mask, 36% selected by an erosion.
    func testNoPixelIsPushedFarTheWrongWayByAnErosion() {
        let a = folded(mixedMask, 192, 192)
        let b = folded(mixedMask, 192, 192, edge: -20)
        var grew = 0
        var worst = 0.0
        for i in 0..<a.values.count {
            let delta = Double(b.values[i]) - Double(a.values[i])
            if delta > 1e-9 { grew += 1 }
            worst = Swift.max(worst, delta)
        }
        XCTAssertLessThan(worst, 0.05,
                          "an erosion raised a pixel's alpha by \(worst)")
        XCTAssertLessThan(grew, a.values.count / 100,
                          "an erosion raised \(grew) pixels")
    }

    // MARK: - 3. The sweep the old test should have been

    /// COMPONENT COUNT × FEATHER MIX × RASTER × FINE EDGE STEPS.
    ///
    /// Every mask here holds edges of genuinely different widths, which is the region
    /// the shipped test never entered. The assertion is the label's own promise at every
    /// step of the slider, not at three of them.
    func testEdgeSweepsComponentCountFeatherMixAndRaster() {
        let mixes: [(String, [MaskComponent])] = [
            ("hard + soft", mixedMask),
            ("hard + mid", [hardComponent, radial(0.70, 0.50, 0.20, 0.20, feather: 50)]),
            ("polygon hard + soft radial",
             [compactPolygon(feather: 0), radial(0.74, 0.50, 0.22, 0.22, feather: 100)]),
            ("three widths", [radial(0.20, 0.30, 0.10, 0.10, feather: 0),
                              radial(0.60, 0.30, 0.15, 0.15, feather: 50),
                              radial(0.50, 0.80, 0.18, 0.18, feather: 100)]),
            ("small hard beside a large soft",
             [radial(0.18, 0.18, 0.06, 0.06, feather: 0),
              radial(0.60, 0.60, 0.30, 0.30, feather: 100)]),
            ("soft subtracted from hard",
             [radial(0.45, 0.50, 0.30, 0.30, feather: 0),
              { var c = radial(0.60, 0.50, 0.18, 0.18, feather: 100); c.op = .subtract; return c }()]),
        ]
        for (name, components) in mixes {
            for (w, h) in [(96, 96), (160, 160), (320, 320)] {
                let base = coverage(folded(components, w, h))
                var previous = -Double.infinity
                // Every step of the panel's own travel where a raster is cheap; every
                // other one at 320², where the sign and the ordering are the same
                // question asked of the same arithmetic.
                let sweep = w > 200 ? sliderSweep.enumerated()
                    .filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    : sliderSweep
                for edge in sweep {
                    let c = coverage(folded(components, w, h, edge: edge))
                    XCTAssertGreaterThanOrEqual(c, previous - 1e-12,
                                                "\(name) at \(w)×\(h): Edge \(edge) is "
                                                + "below the step before it")
                    previous = c
                    if edge <= -1 {
                        XCTAssertLessThan(c, base,
                                          "\(name) at \(w)×\(h): Edge \(edge) grew the "
                                          + "mask (\(c / base)×)")
                    }
                    if edge >= 1 {
                        XCTAssertGreaterThan(c, base,
                                             "\(name) at \(w)×\(h): Edge \(edge) did not "
                                             + "grow the mask")
                    }
                }
            }
        }
    }

    // MARK: - 4. The single soft radial

    /// THE SINGLE SOFT RADIAL USED TO RISE ON THE FIRST DOZEN STEPS OF ERODE — 0.33 % at
    /// Edge −6, 160² — because the old reconstruction rebuilt its smoothstep as a linear
    /// ramp. A flat erosion cannot raise any pixel, so the bound that recorded the
    /// residual is now the property itself: no erode setting grows it at all.
    func testTheSingleSoftRadialNeverRisesUnderErosion() {
        let soft = [softComponent]
        for n in [96, 160, 320] {
            let base = coverage(folded(soft, n, n))
            for edge in sliderSweep where edge < 0 {
                XCTAssertLessThan(coverage(folded(soft, n, n, edge: edge)), base,
                                  "Edge \(edge) did not shrink the single soft radial at \(n)²")
            }
            XCTAssertLessThan(coverage(folded(soft, n, n, edge: -40)) / base, 0.95,
                              "Edge −40 no longer erodes the single soft radial at \(n)²")
        }
    }

    // MARK: - 5. The invariants the chain rests on

    func testEdgeZeroAndNonFiniteLeaveTheMaskAlone() {
        for components in [mixedMask, [softComponent]] {
            let base = folded(components, 128, 128)
            XCTAssertEqual(MaskRaster.edgeShifted(base, edge: 0, longEdge: 128).values,
                           base.values, "Edge 0 moved the mask")
            XCTAssertEqual(MaskRaster.edgeShifted(base, edge: .nan, longEdge: 128).values,
                           base.values, "a non-finite Edge moved the mask")
        }
    }

    func testAlphaStaysInsideZeroToOneAtEverySetting() {
        for (w, h) in [(96, 96), (160, 160)] {
            for edge in sliderSweep {
                let p = folded(mixedMask, w, h, edge: edge)
                let range = p.range
                XCTAssertGreaterThanOrEqual(range.min, 0, "alpha < 0 at Edge \(edge)")
                XCTAssertLessThanOrEqual(range.max, 1, "alpha > 1 at Edge \(edge)")
                for v in p.values {
                    XCTAssertTrue(v.isFinite, "a non-finite alpha at Edge \(edge)")
                }
            }
        }
    }

    /// A plane with no boundary has nothing to shift, and an empty mask must not come
    /// back as anything else.
    func testMasksWithNoBoundaryAreUntouched() {
        for fill in [0.0, 1.0, 0.5] {
            let flat = Plane(width: 64, height: 64, fill: fill)
            for edge in [-50.0, -10, 10, 50] {
                XCTAssertEqual(MaskRaster.edgeShifted(flat, edge: edge, longEdge: 64).values,
                               flat.values,
                               "a flat plane at \(fill) moved at Edge \(edge)")
            }
        }
    }

    /// Each edge moves by the SHIFT, whatever its own width is. Measured as the radius of the α = 0.5 crossing on each component separately,
    /// which is where a boundary is by definition.
    func testExpandMovesTheHardAndSoftBoundariesByTheSameDistance() {
        let n = 320
        let shift = (40.0 / 50) * 0.01 * Double(n)   // Edge −40 ⇒ 2.56 px
        let base = folded(mixedMask, n, n)
        let eroded = folded(mixedMask, n, n, edge: -40)

        /// Where α crosses 0.5 along a horizontal ray from a component's centre.
        func crossing(_ p: Plane, centreX: Double, centreY: Int) -> Double {
            var last = Double(p.width)
            for x in 0..<p.width {
                let px = Double(x)
                guard px >= centreX else { continue }
                if p[x, centreY] < 0.5 { last = px; break }
            }
            return last - centreX
        }
        let hardBefore = crossing(base, centreX: 0.30 * Double(n), centreY: n / 2)
        let hardAfter = crossing(eroded, centreX: 0.30 * Double(n), centreY: n / 2)
        let softBefore = crossing(base, centreX: 0.70 * Double(n), centreY: n / 2)
        let softAfter = crossing(eroded, centreX: 0.70 * Double(n), centreY: n / 2)

        XCTAssertEqual(hardBefore - hardAfter, shift, accuracy: 1.5,
                       "the HARD boundary moved by \(hardBefore - hardAfter) px, not \(shift)")
        XCTAssertEqual(softBefore - softAfter, shift, accuracy: 1.5,
                       "the SOFT boundary moved by \(softBefore - softAfter) px, not \(shift)")
    }
}
