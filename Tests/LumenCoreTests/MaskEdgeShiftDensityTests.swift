// MaskEdgeShiftDensityTests.swift
// Edge Shift on a mask that never reaches 1.
//
// `MaskEdgeShiftTests` holds every fixture at amount 100, so each one runs from 0 to 1
// and the reconstruction's three hard-coded constants — the α = 0.5 boundary, the
// 0.02…0.98 transition band, the rebuild to 1 — all happen to be right. A component at
// amount 60 breaks all three at once: its 0.6 interior lands inside the band with a
// gradient of zero, the mean gradient collapses, the ramp is measured tens of pixels
// wide on an edge that is one pixel, and the rebuild then fills the interior to 1.0
// and spreads a halo outside the edge — at Edge +25 AND at Edge −25. At amount 40 no
// pixel reaches 0.5 and the slider does nothing at all.
//
// What these tests pin is the label: Edge moves the boundary and leaves the density
// and the hardness of the edge alone.

import XCTest
@testable import LumenCore

final class MaskEdgeShiftDensityTests: XCTestCase {

    private let size = (width: 200, height: 200)

    private func hardRadial(_ cx: Double, amount: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.15, 0.15]
        c.feather = 0
        c.rotation = 0
        c.amount = amount
        return c
    }

    private func folded(_ components: [MaskComponent], edge: Double) -> Plane {
        var m = Mask(components: components)
        m.refine = MaskRefine(feather: 0, edge: edge, blur: 0)
        return MaskRaster.combine(mask: m, size: size)
    }

    /// The finding's trigger: one hard radial at amount 60, Edge ±25 on 200² (1 px).
    func testEdgeShiftPreservesPartialDensityAndHardEdge() {
        let c = hardRadial(0.5, amount: 60)
        let plain = folded([c], edge: 0)
        XCTAssertEqual(plain[100, 100], 0.6, accuracy: 1e-4)
        XCTAssertEqual(plain[140, 100], 0, accuracy: 1e-6)
        for edge in [25.0, -25.0] {
            let shifted = folded([c], edge: edge)
            XCTAssertEqual(shifted[100, 100], 0.6, accuracy: 0.05,
                           "Edge \(edge) changed the density")
            XCTAssertLessThan(shifted[140, 100], 0.02,
                              "Edge \(edge) spread a hard edge into a halo")
            XCTAssertLessThanOrEqual(shifted.range.max, 0.6 + 1e-4,
                                     "Edge \(edge) raised alpha above the mask's own peak")
        }
        XCTAssertLessThan(folded([c], edge: -25).mean, plain.mean,
                          "erosion did not shrink a partial-density mask")
        XCTAssertGreaterThan(folded([c], edge: 25).mean, plain.mean,
                             "dilation did not grow a partial-density mask")
    }

    /// Amount 40 never reaches α = 0.5; the boundary is still there and must still move.
    func testEdgeShiftMovesAMaskThatNeverReachesOneHalf() {
        let c = hardRadial(0.5, amount: 40)
        let plain = folded([c], edge: 0)
        let grown = folded([c], edge: 50)
        let shrunk = folded([c], edge: -50)
        XCTAssertGreaterThan(grown.mean, plain.mean, "Edge +50 did nothing at amount 40")
        XCTAssertLessThan(shrunk.mean, plain.mean, "Edge −50 did nothing at amount 40")
        XCTAssertEqual(grown[100, 100], 0.4, accuracy: 0.02)
        XCTAssertLessThanOrEqual(grown.range.max, 0.4 + 1e-4)
    }

    /// Two plateaus at different densities: one peak cannot describe both, so the
    /// weaker component must keep its own density rather than be rebuilt to the
    /// stronger one's.
    func testEdgeShiftKeepsEachDensityOnAMultiDensityMask() {
        let weak = hardRadial(0.27, amount: 60)
        let strong = hardRadial(0.73, amount: 100)
        let plain = folded([weak, strong], edge: 0)
        XCTAssertEqual(plain[54, 100], 0.6, accuracy: 1e-4)
        XCTAssertEqual(plain[146, 100], 1, accuracy: 1e-4)
        for edge in [25.0, -25.0] {
            let shifted = folded([weak, strong], edge: edge)
            XCTAssertEqual(shifted[54, 100], 0.6, accuracy: 0.05,
                           "Edge \(edge) changed the weak component's density")
            XCTAssertEqual(shifted[146, 100], 1, accuracy: 0.05,
                           "Edge \(edge) changed the strong component's density")
        }
        XCTAssertLessThan(folded([weak, strong], edge: -25).mean, plain.mean)
        XCTAssertGreaterThan(folded([weak, strong], edge: 25).mean, plain.mean)
    }

    /// The direct form, without the component machinery in the way.
    func testEdgeShiftOnAPartialSquareKeepsItsDensity() {
        let p = Plane(width: 100, height: 100) { x, y in
            (x > 0.3 && x < 0.7 && y > 0.3 && y < 0.7) ? 0.6 : 0
        }
        for edge in [50.0, -50.0] {
            let s = MaskRaster.edgeShifted(p, edge: edge, longEdge: 100)
            XCTAssertEqual(s[50, 50], 0.6, accuracy: 0.05, "Edge \(edge) changed the density")
            XCTAssertLessThan(s[20, 50], 0.02, "Edge \(edge) spread a hard edge")
        }
    }
}
