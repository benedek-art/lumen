// PolygonMaskTests.swift
// docs/36 §2 A — a closed outline the photographer drew.
//
// "Select that building" had no answer in this application but the brush. Capture One,
// Photoshop, Affinity and ON1 all ship an outline tool; Lightroom does not, and neither
// did we. It is the largest single selection gap left.
//
// ONE KIND DOES BOTH JOBS, and the tests are written to hold that: a lasso is a polygon
// whose vertices arrived quickly, so the wire format cannot tell them apart, the
// rasterizer cannot either, and a hurried lasso can be tidied vertex by vertex
// afterwards — which is the thing every editor that keeps them as separate tools cannot
// do.
//
// The interesting assertions are about the EDGE, because a fill is trivial and an edge
// is not:
//
//   * Feather 0 is one pixel of ramp, not zero. A hard fill is a staircase, and the one
//     place a mask must never look cheap is the boundary someone drew by hand.
//   * The ramp is CENTRED on the outline, so feathering a shape does not shrink or grow
//     it — the drawn boundary stays the half-selected line.
//   * Winding is even-odd, so a lasso that crosses itself does not punch a hole where
//     the photographer's hand wobbled.

import XCTest
@testable import LumenCore

final class PolygonMaskTests: XCTestCase {

    private let w = 100
    private let h = 100

    private func outline(_ points: [[Double]], feather: Double = 0) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = points
        c.feather = feather
        return c
    }

    private func plane(_ c: MaskComponent, _ width: Int? = nil, _ height: Int? = nil)
        -> Plane {
        MaskRaster.rasterize(component: c,
                             size: (width: width ?? w, height: height ?? h))
    }

    /// A square from 0.25 to 0.75 in both axes — on a square frame that is pixels 25…75.
    private func square(_ feather: Double = 0) -> MaskComponent {
        outline([[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]], feather: feather)
    }

    // MARK: - It fills

    func testTheInsideIsSelectedAndTheOutsideIsNot() {
        let p = plane(square())
        XCTAssertEqual(Double(p[50, 50]), 1, accuracy: 1e-9, "the middle")
        XCTAssertEqual(Double(p[30, 30]), 1, accuracy: 1e-9, "well inside a corner")
        XCTAssertEqual(Double(p[5, 5]), 0, accuracy: 1e-9, "outside")
        XCTAssertEqual(Double(p[95, 50]), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(p[50, 5]), 0, accuracy: 1e-9)
    }

    func testATriangleIsATriangleAndNotItsBoundingBox() {
        // The guard against a fill that quietly became a bounding box, which is the
        // laziest way this could be wrong and would pass every square fixture.
        let p = plane(outline([[0.5, 0.15], [0.85, 0.85], [0.15, 0.85]]))
        XCTAssertGreaterThan(Double(p[50, 70]), 0.99, "inside the triangle")
        XCTAssertLessThan(Double(p[20, 25]), 0.01, "in the box but outside the triangle")
        XCTAssertLessThan(Double(p[80, 25]), 0.01)
    }

    func testAConcaveOutlineKeepsItsNotch() {
        // An L, drawn counter-clockwise. The notch is the whole reason a photographer
        // reaches for an outline instead of a rectangle.
        let l = outline([[0.2, 0.2], [0.8, 0.2], [0.8, 0.4],
                         [0.4, 0.4], [0.4, 0.8], [0.2, 0.8]])
        let p = plane(l)
        XCTAssertGreaterThan(Double(p[30, 30]), 0.99, "the corner of the L")
        XCTAssertGreaterThan(Double(p[70, 30]), 0.99, "the arm")
        XCTAssertGreaterThan(Double(p[30, 70]), 0.99, "the leg")
        XCTAssertLessThan(Double(p[70, 70]), 0.01, "and the notch is empty")
    }

    func testTheWindingIsEvenOddSoASelfCrossingLassoHasNoHole() {
        // A bow tie: two triangles meeting at a point, which is what a lasso drawn in a
        // hurry looks like. Under the nonzero rule one lobe would cancel; under
        // even-odd both are selected, and both are what the hand meant.
        let bow = outline([[0.2, 0.2], [0.8, 0.8], [0.8, 0.2], [0.2, 0.8]])
        let p = plane(bow)
        XCTAssertGreaterThan(Double(p[35, 50]), 0.9, "the left lobe")
        XCTAssertGreaterThan(Double(p[65, 50]), 0.9, "and the right lobe")
    }

    // MARK: - The edge

    func testFeatherZeroAntialiasesTheEdgesThatNeedIt() {
        // An axis-aligned edge sitting exactly on a pixel boundary is genuinely 0 → 1
        // with nothing between, and that is correct rather than a staircase: no pixel
        // is partially covered. The first draft of this test asserted otherwise on
        // exactly that fixture and was wrong about what antialiasing is for.
        //
        // The cases that need it are the ones a hand draws: an edge between pixel
        // centres, and a diagonal. Both must produce partial coverage at Feather 0.
        let offGrid = plane(outline([[0.253, 0.2], [0.757, 0.2],
                                     [0.757, 0.8], [0.253, 0.8]]))
        let straddling = (20..<32).filter {
            Double(offGrid[$0, 50]) > 1e-4 && Double(offGrid[$0, 50]) < 1 - 1e-4
        }
        XCTAssertEqual(straddling.count, 1,
                       "an edge between two pixel centres covers exactly one of them "
                           + "partially")

        let diagonal = plane(outline([[0.5, 0.1], [0.9, 0.5], [0.5, 0.9], [0.1, 0.5]]))
        let soft = (0..<100).filter {
            Double(diagonal[$0, 30]) > 0.05 && Double(diagonal[$0, 30]) < 0.95
        }
        XCTAssertGreaterThanOrEqual(soft.count, 2,
                                    "a 45° edge is partially covered on both sides")
        XCTAssertLessThanOrEqual(soft.count, 6,
                                 "and it is antialiasing, not a soft edge: \(soft.count) "
                                     + "partial samples across two edges")
    }

    func testTheRampIsCentredSoFeatheringDoesNotMoveTheBoundary() {
        // The property that makes a feathered outline stay the size it was drawn. At
        // every feather the drawn boundary must read about one half.
        for feather in [0.0, 25.0, 60.0, 100.0] {
            let p = plane(square(feather))
            // x = 25 in a 100-wide frame is the boundary; pixel 24's centre sits half a
            // pixel outside it and pixel 25's half a pixel inside, so the pair
            // straddles the line and averages to the value AT it.
            let straddle = (Double(p[24, 50]) + Double(p[25, 50])) / 2
            XCTAssertEqual(straddle, 0.5, accuracy: 0.06,
                           "at feather \(feather) the drawn boundary is not half-selected")
        }
    }

    func testMoreFeatherIsAWiderRampAndNotASmallerShape() {
        let hard = plane(square(0))
        let soft = plane(square(80))
        func rampWidth(_ p: Plane) -> Int {
            (10..<50).filter { Double(p[$0, 50]) > 0.02 && Double(p[$0, 50]) < 0.98 }.count
        }
        XCTAssertGreaterThan(rampWidth(soft), rampWidth(hard) + 2)
        // And the centre is untouched: a feather that ate into the fill would be a
        // shrink wearing a feather's name.
        XCTAssertEqual(Double(soft[50, 50]), 1, accuracy: 1e-6)
    }

    // MARK: - Units

    func testTheFeatherIsIsotropicOnANonSquareFrame() {
        // Long-edge units, the same convention `linearPlane` and `radialPlane` use.
        // Measured in normalized space a feather would be wider across a 3:2 frame than
        // down it, and an outline drawn around a face would be soft on the sides and
        // crisp top and bottom.
        let wide = 180, tall = 120
        let p = MaskRaster.rasterize(component: square(60),
                                     size: (width: wide, height: tall))
        func ramp(_ samples: [Double]) -> Int {
            samples.filter { $0 > 0.05 && $0 < 0.95 }.count
        }
        let across = ramp((0..<wide).map { Double(p[$0, tall / 2]) })
        let down = ramp((0..<tall).map { Double(p[wide / 2, $0]) })
        // Two edges are crossed in each direction, so both counts are twice one ramp.
        XCTAssertEqual(Double(across), Double(down), accuracy: 2,
                       "the ramp is \(across) px across and \(down) px down")
    }

    func testTheShapeScalesWithTheRasterRatherThanTheResolution() {
        // The same outline at draft and at export must select the same REGION.
        let small = plane(square(30), 60, 60)
        let large = plane(square(30), 240, 240)
        for u in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let a = Double(small[Int(u * 60), 30])
            let b = Double(large[Int(u * 240), 120])
            XCTAssertEqual(a, b, accuracy: 0.03, "at u = \(u)")
        }
    }

    // MARK: - What it refuses

    func testTwoPointsAreNotAnOutline() {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = [[0.2, 0.2], [0.8, 0.8]]
        XCTAssertNotNil(c.validationError())
        XCTAssertEqual(plane(c).values.max().map(Double.init) ?? 1, 0, accuracy: 0,
                       "and an incomplete outline selects nothing rather than "
                           + "everything")
    }

    func testAnAbsentPathIsIncompleteRatherThanEmptySelectionByAccident() {
        let c = MaskComponent(op: .add, kind: .polygon)
        XCTAssertNotNil(c.validationError())
    }

    func testAPoisonedVertexSelectsNothingRatherThanPoisoningThePlane() {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = [[0.2, 0.2], [Double.nan, 0.8], [0.8, 0.2]]
        XCTAssertNotNil(c.validationError())
        let p = plane(c)
        XCTAssertTrue(p.values.allSatisfy { $0.isFinite })
        XCTAssertEqual(p.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testADegenerateOutlineWithEveryPointTheSameDoesNotDivideByZero() {
        let c = outline([[0.5, 0.5], [0.5, 0.5], [0.5, 0.5]])
        let p = plane(c)
        XCTAssertTrue(p.values.allSatisfy { $0.isFinite })
        XCTAssertLessThan(Double(p[10, 10]), 0.01)
    }

    // MARK: - It composes like every other component

    func testAnOutlineIntersectsAndSubtractsLikeAnyOtherComponent() {
        var subtract = square()
        subtract.op = .subtract
        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.5, 0.5]
        radial.radii = [0.45, 0.45]
        radial.feather = 0
        let mask = Mask(id: "m", name: "cut", components: [radial, subtract])
        let p = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        XCTAssertLessThan(Double(p[50, 50]), 0.01, "the square is cut out of the disc")
        XCTAssertGreaterThan(Double(p[50, 12]), 0.9, "and the disc's rim survives")
    }

    // MARK: - Wire format

    func testAnOutlineRoundTrips() throws {
        var recipe = Recipe()
        let c = outline([[0.1, 0.2], [0.9, 0.25], [0.5, 0.8]], feather: 35)
        recipe.masks = [Mask(id: "m", name: "outline", components: [c])]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(recipe).utf8))
        XCTAssertEqual(back.masks[0].components[0].kind, .polygon)
        XCTAssertEqual(back.masks[0].components[0].path?.count, 3)
        XCTAssertEqual(back.masks[0].components[0].path?[1][0], 0.9)
        XCTAssertEqual(back.masks[0].components[0].feather, 35)
    }

    func testARecipeWrittenBeforeOutlinesStillDecodes() throws {
        let json = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[\
        {"op":"add","kind":"radial","center":[0.5,0.5],"radii":[0.3,0.3]}]}]}
        """
        let r = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertNil(r.masks[0].components[0].path)
    }

    func testAnOutlineNeedsNeitherThePictureNorAMatte() {
        // It is pure geometry, like the gradients: no source image, no model, nothing
        // to fail to supply. `readsSourceImage` saying otherwise would make every
        // renderer hand it a stage input it does not use.
        XCTAssertFalse(MaskKind.polygon.readsSourceImage)
        XCTAssertFalse(MaskKind.polygon.needsMatte)
    }
}
