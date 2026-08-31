// SimilarityPointTests.swift
// docs/35 §2.4 — "Similarity Point has no point".
//
// `MaskComponent` stored sampled colours and two selectivity widths and no geometry at
// all, so the gate evaluated over the whole frame: what shipped as "Colour Pick" was a
// Gaussian colour range wearing the name of DxO's U-Point, whose whole mechanic is
// similarity WITHIN A RADIUS with negative points that carve back.
//
// Two properties are asserted here and they pull in opposite directions, which is why
// both are needed. `testAComponentWithNoPointsStillGatesTheWholeFrame` is the
// compatibility half: every recipe written before the field renders identically after
// it. The rest is the feature: a positive point selects near itself and not far from
// itself, and a negative point removes what it covers without removing all of it.

import XCTest
@testable import LumenCore

final class SimilarityPointTests: XCTestCase {

    private let w = 64
    private let h = 48

    /// Left half a saturated red, right half the SAME red, top and bottom split by a
    /// darker band — so colour alone cannot tell left from right, and only geometry can.
    private func twoPatches() -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, _ in
            u < 0.5 ? RGB(0.45, 0.08, 0.06) : RGB(0.45, 0.08, 0.06)
        }
    }

    private func component(points: [[Double]]?) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .similarity)
        c.samples = [[0.45, 0.08, 0.06]]
        c.chromaSel = 40
        c.lumaSel = 40
        c.points = points
        return c
    }

    private func plane(_ c: MaskComponent) -> Plane {
        MaskRaster.rasterize(component: c, size: (width: w, height: h),
                             source: twoPatches())
    }

    private func at(_ p: Plane, _ u: Double, _ v: Double) -> Double {
        p[Int(u * Double(w)), Int(v * Double(h))]
    }

    // MARK: - Compatibility

    func testAComponentWithNoPointsStillGatesTheWholeFrame() {
        let p = plane(component(points: nil))
        XCTAssertGreaterThan(at(p, 0.15, 0.5), 0.9)
        XCTAssertGreaterThan(at(p, 0.85, 0.5), 0.9,
                             "without points the gate is global — this is what every "
                                 + "recipe written before the field means")
    }

    func testAnEmptyPointsArrayIsTreatedAsNoPoints() {
        let p = plane(component(points: []))
        XCTAssertGreaterThan(at(p, 0.85, 0.5), 0.9)
    }

    // MARK: - The spatial half

    func testAPositivePointSelectsNearItselfAndNotFarFromIt() {
        // A point at the left quarter, reaching a fifth of the long edge.
        let p = plane(component(points: [[0.25, 0.5, 0.20, 1]]))
        XCTAssertGreaterThan(at(p, 0.25, 0.5), 0.9, "at the point, the colour matches fully")
        XCTAssertLessThan(at(p, 0.85, 0.5), 0.05,
                          "the same colour on the far side is now OUT of the selection — "
                              + "which is the entire difference between this and a colour range")
    }

    func testThePointsFalloffIsSoftRatherThanACircle() {
        let p = plane(component(points: [[0.5, 0.5, 0.25, 1]]))
        let centre = at(p, 0.5, 0.5)
        let mid = at(p, 0.5 + 0.12, 0.5)
        let outside = at(p, 0.5 + 0.30, 0.5)
        XCTAssertGreaterThan(centre, 0.9)
        XCTAssertGreaterThan(mid, 0.05)
        XCTAssertLessThan(mid, centre, "there is a shoulder, not a cliff")
        XCTAssertLessThan(outside, 0.01)
    }

    func testANegativePointCarvesBackWhatAPositiveOneSelected() {
        var c = component(points: nil)
        c.samples = [[0.45, 0.08, 0.06], [0.45, 0.08, 0.06]]
        // One broad positive over the frame's middle, one negative inside it.
        c.points = [[0.5, 0.5, 0.6, 1], [0.35, 0.5, 0.15, -1]]
        let p = plane(c)
        XCTAssertGreaterThan(at(p, 0.5, 0.5), 0.8, "the positive point still selects")
        XCTAssertLessThan(at(p, 0.35, 0.5), 0.05,
                          "and the negative one has taken its own area back out")
    }

    func testANegativePointRemovesOnlyWhatItCovers() {
        var c = component(points: nil)
        c.samples = [[0.45, 0.08, 0.06], [0.45, 0.08, 0.06]]
        c.points = [[0.5, 0.5, 0.6, 1], [0.30, 0.5, 0.08, -1]]
        let p = plane(c)
        // Just outside the negative point's reach, the selection is intact — a negative
        // point is a dodge of the selection, not a hole punched through it.
        XCTAssertGreaterThan(at(p, 0.55, 0.5), 0.8)
    }

    // MARK: - Malformed input

    func testAMalformedPointSelectsNothingRatherThanEverything() {
        // Two values where three are needed. The dangerous failure would be to fall
        // back to the global gate, which would silently turn a local selection into a
        // whole-frame one on a recipe from another build.
        let p = plane(component(points: [[0.25, 0.5]]))
        XCTAssertLessThan(p.values.max().map(Double.init) ?? 1, 0.001)
    }

    func testAZeroRadiusPointSelectsNothing() {
        let p = plane(component(points: [[0.25, 0.5, 0, 1]]))
        XCTAssertLessThan(p.values.max().map(Double.init) ?? 1, 0.001)
    }

    func testANonFinitePointIsRefused() {
        let p = plane(component(points: [[Double.nan, 0.5, 0.2, 1]]))
        XCTAssertLessThan(p.values.max().map(Double.init) ?? 1, 0.001)
        for v in p.values { XCTAssertTrue(v.isFinite) }
    }

    func testMorePointsThanSamplesAreIgnoredRatherThanTrapping() {
        let p = plane(component(points: [[0.25, 0.5, 0.2, 1],
                                         [0.75, 0.5, 0.2, 1],
                                         [0.5, 0.5, 0.2, 1]]))
        XCTAssertGreaterThan(at(p, 0.25, 0.5), 0.9)
        XCTAssertLessThan(at(p, 0.75, 0.5), 0.05,
                          "only the first point pairs with the single sample")
    }

    // MARK: - Wire format

    func testPointsRoundTripThroughTheRecipeFormat() throws {
        var r = Recipe()
        r.masks = [Mask(id: "m", name: "pick",
                        components: [component(points: [[0.25, 0.5, 0.2, -1]])])]
        let json = try CanonicalJSON.canonicalRecipeJSON(r)
        let back = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(back.masks[0].components[0].points ?? [], [[0.25, 0.5, 0.2, -1]])
    }

    func testARecipeWrittenBeforeThePointsFieldStillDecodes() throws {
        // docs/36 §1.8: every added field is an additive optional with a
        // behaviour-preserving default, and each one ships with the test that says so.
        let json = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[\
        {"op":"add","kind":"similarity","samples":[[0.4,0.1,0.1]]}]}]}
        """
        let back = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertNil(back.masks[0].components[0].points)
    }
}
