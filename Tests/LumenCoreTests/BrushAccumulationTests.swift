// BrushAccumulationTests.swift
// docs/36 §1.2 — the defect these exist for, and the property that makes the fix legal.
//
// `MaskRaster.brushPlane` painted every stroke of the set on every rasterization, so a
// sixty-stroke mask paid sixty strokes on every settle, every export and every draft
// cache miss, and the sixty-first stroke made all sixty-one more expensive. Painting
// got more expensive the more you had already painted.
//
// The fix rests on one property of the fold: a stroke reads only the accumulator, never
// the strokes before it. Paint deposits `a + flow·s·max(density − a, 0)`; an eraser
// multiplies toward zero. Both are functions of `a` alone. So painting `[0..<k)` and
// then `[k...]` must equal painting `[0...]`, exactly — and `testResuming…IsTheSameAs…`
// is that equality, not an approximation of it.
//
// The second test is the one that would catch a fix that quietly did nothing.
// `testResumingDoesNotRepaintTheStrokesItWasHandedFor` resumes from a plane that could
// not have come from those strokes — a flat 0.5 field — and asserts the outcome carries
// that field. An implementation that ignored `resuming` and repainted from stroke one
// would return a plane with 0 where nothing was painted, and fail.

import XCTest
@testable import LumenCore

final class BrushAccumulationTests: XCTestCase {

    private let size = (width: 48, height: 32)

    /// Strokes that overlap, so the fold order and the density ceiling both matter.
    /// Deterministic: no randomness anywhere in this file.
    private func strokeSet(count: Int) -> BrushStrokeSet {
        var strokes: [BrushStroke] = []
        for i in 0..<count {
            let t = Double(i) / Double(Swift.max(count - 1, 1))
            let y = 0.25 + 0.5 * t
            let points = (0...6).map { step -> BrushPoint in
                let u = Double(step) / 6
                return BrushPoint(x: 0.15 + 0.7 * u,
                                  y: y + 0.06 * sin(u * 6.2 + Double(i)),
                                  pressure: 1,
                                  t: step * 8)
            }
            strokes.append(BrushStroke(points: points,
                                       size: 0.10,
                                       feather: i.isMultiple(of: 2) ? 60 : 10,
                                       flow: 55,
                                       density: 90,
                                       erase: i.isMultiple(of: 5) && i > 0,
                                       automask: false))
        }
        return BrushStrokeSet(strokes: strokes)
    }

    private func whole(_ set: BrushStrokeSet) -> Plane {
        MaskRaster.accumulatedBrushPlane(strokes: set, size: size, source: nil, resuming: nil)
    }

    private func prefix(_ set: BrushStrokeSet, _ k: Int) -> BrushStrokeSet {
        BrushStrokeSet(strokes: Array(set.strokes.prefix(k)))
    }

    private func worstDifference(_ a: Plane, _ b: Plane) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var worst: Double = 0
        for i in 0..<a.values.count {
            worst = Swift.max(worst, abs(Double(a.values[i]) - Double(b.values[i])))
        }
        return worst
    }

    // MARK: - The property the fix rests on

    func testResumingAStrokeSetIsTheSameAsPaintingItWhole() {
        let set = strokeSet(count: 9)
        let reference = whole(set)

        // Every split, not one: a fix that happened to be right at the halfway point
        // and wrong at the ends would pass a single-split test.
        for k in 0...set.strokes.count {
            let head = whole(prefix(set, k))
            let resumed = MaskRaster.accumulatedBrushPlane(
                strokes: set, size: size, source: nil, resuming: (plane: head, strokes: k))
            XCTAssertEqual(worstDifference(reference, resumed), 0, accuracy: 0,
                           "resuming after \(k) strokes must be bit-identical to painting all "
                               + "\(set.strokes.count); the fold reads only the accumulator")
        }
    }

    func testResumingDoesNotRepaintTheStrokesItWasHandedFor() {
        // Five strokes, so the last one (index 4) is a paint rather than an eraser —
        // the fixture makes every fifth stroke an eraser, and an eraser cannot raise
        // the maximum, which is what the second assertion below reads.
        let set = strokeSet(count: 5)

        // A base no prefix of this set could have produced. If the implementation
        // repaints from stroke one, this field is gone from the answer.
        let marker: Float = 0.5
        var base = Plane(width: size.width, height: size.height)
        for i in 0..<base.values.count { base.values[i] = marker }

        let resumed = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: size, source: nil,
            resuming: (plane: base, strokes: set.strokes.count - 1))

        let lowest = resumed.values.min().map(Double.init) ?? 0
        let highest = resumed.values.max().map(Double.init) ?? 0
        XCTAssertGreaterThan(lowest, 0.0,
                             "every pixel should still carry the 0.5 field it was resumed "
                                 + "from; a zero means the whole set was repainted")
        XCTAssertGreaterThan(highest, Double(marker),
                             "the final stroke should still have been painted on top")

        // And the exact statement: resumed == base with only the last stroke applied.
        var expected = base
        let long = Double(Swift.max(size.width, size.height))
        MaskRaster.paint(stroke: set.strokes[set.strokes.count - 1], into: &expected,
                         width: size.width, height: size.height, longEdge: long, source: nil)
        XCTAssertEqual(worstDifference(expected, resumed), 0, accuracy: 0)
    }

    // MARK: - Every way a resume can be illegitimate

    func testAResumeAtTheWrongSizeIsRefusedRatherThanTrusted() {
        let set = strokeSet(count: 4)
        let wrongSize = Plane(width: size.width + 7, height: size.height, fill: 0.5)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: size, source: nil, resuming: (plane: wrongSize, strokes: 2))
        XCTAssertEqual(out.width, size.width)
        XCTAssertEqual(out.height, size.height)
        XCTAssertEqual(worstDifference(whole(set), out), 0, accuracy: 0,
                       "a mis-sized cache must degrade to a full repaint, never to a wrong mask")
    }

    func testAResumeCountPastTheEndOfTheSetIsRefused() {
        // Strokes removed or undone: the held plane holds MORE than the set now has,
        // so it is not a prefix of anything and the whole set is repainted.
        let set = strokeSet(count: 3)
        let stale = Plane(width: size.width, height: size.height, fill: 0.5)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: size, source: nil, resuming: (plane: stale, strokes: 9))
        XCTAssertEqual(worstDifference(whole(set), out), 0, accuracy: 0)
    }

    func testANegativeResumeCountIsRefused() {
        let set = strokeSet(count: 3)
        let stale = Plane(width: size.width, height: size.height, fill: 0.5)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: size, source: nil, resuming: (plane: stale, strokes: -1))
        XCTAssertEqual(worstDifference(whole(set), out), 0, accuracy: 0)
    }

    func testResumingAtTheFullCountPaintsNothingMore() {
        let set = strokeSet(count: 5)
        let done = whole(set)
        let again = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: size, source: nil,
            resuming: (plane: done, strokes: set.strokes.count))
        XCTAssertEqual(worstDifference(done, again), 0, accuracy: 0)
    }

    func testAnEmptySetResumesToWhateverItWasHanded() {
        let empty = BrushStrokeSet(strokes: [])
        let base = Plane(width: size.width, height: size.height, fill: 0.25)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: empty, size: size, source: nil, resuming: (plane: base, strokes: 0))
        XCTAssertEqual(worstDifference(base, out), 0, accuracy: 0)
    }

    // MARK: - The fold reaches it

    func testCombineUsesASuppliedBrushPlaneInsteadOfRepainting() {
        // The seam `PipelineRenderer` uses: hand the fold an already-painted plane and
        // it must be what the mask is built from. Proved with a plane the strokes could
        // not have produced — a uniform 1 — against a stroke set that covers a fraction
        // of the frame.
        let set = strokeSet(count: 3)
        let ref = "blob:xxh64:test"
        var component = MaskComponent(op: .add, kind: .brush)
        component.strokesRef = ref
        let mask = Mask(id: "m", name: "brush", components: [component])

        let painted = MaskRaster.combine(mask: mask, size: size, source: nil,
                                         strokeSets: [ref: set])
        let filled = Plane(width: size.width, height: size.height, fill: 1)
        let supplied = MaskRaster.combine(mask: mask, size: size, source: nil,
                                          strokeSets: [ref: set],
                                          aiMattes: [:],
                                          brushPlanes: [ref: filled])

        XCTAssertLessThan(painted.values.map(Double.init).reduce(0, +),
                          Double(size.width * size.height),
                          "the fixture must not already cover the frame, or this proves nothing")
        for v in supplied.values {
            XCTAssertEqual(Double(v), 1, accuracy: 1e-6,
                           "a supplied brush plane must be what the fold uses")
        }
    }

    func testAMisSizedSuppliedBrushPlaneIsIgnoredByTheFold() {
        let set = strokeSet(count: 3)
        let ref = "blob:xxh64:test"
        var component = MaskComponent(op: .add, kind: .brush)
        component.strokesRef = ref
        let mask = Mask(id: "m", name: "brush", components: [component])

        let painted = MaskRaster.combine(mask: mask, size: size, source: nil,
                                         strokeSets: [ref: set])
        let wrong = Plane(width: 8, height: 8, fill: 1)
        let out = MaskRaster.combine(mask: mask, size: size, source: nil,
                                     strokeSets: [ref: set],
                                     aiMattes: [:],
                                     brushPlanes: [ref: wrong])
        XCTAssertEqual(worstDifference(painted, out), 0, accuracy: 0)
    }
}
