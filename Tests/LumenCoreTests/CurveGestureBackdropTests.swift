// The curve editor's press, drag and backdrop rules (lane T2): a click places a point on
// the curve without moving it, a drag moves by the hand's displacement with a fine mode
// that never jumps, and the histogram behind the graph sits on the curve's INPUT axis.

import XCTest
@testable import LumenCore

final class CurveGestureBackdropTests: XCTestCase {

    // MARK: - Placing

    func testAClickOnEmptyGraphAddsAPointOnTheCurveAndDoesNotMoveIt() {
        let points: [[Double]] = [[0, 0], [0.25, 0.15], [0.75, 0.85], [1, 1]]
        let before = MonotoneCubic(points: points)
        let x = 0.5
        let placed = CurveEditing.placing(points, x: x, curveY: before.evaluate(x))
        XCTAssertEqual(placed.points.count, 5)
        XCTAssertEqual(placed.points[placed.index], [x, before.evaluate(x)])
        // Exactly unmoved where the hand pressed. Elsewhere the spline re-solves its
        // tangents around a new knot, which every interpolating spline does (Lightroom's
        // included): measured 1.9 codes at worst on this S-curve, bounded here at 3.
        let after = MonotoneCubic(points: placed.points)
        XCTAssertEqual(after.evaluate(x), before.evaluate(x), accuracy: 1e-12)
        var worst = 0.0
        for i in 0...1000 {
            let t = Double(i) / 1000
            worst = max(worst, abs(after.evaluate(t) - before.evaluate(t)))
        }
        XCTAssertLessThan(worst * 255, 3.0, "placing a point moved the curve \(worst * 255) codes")
    }

    /// The old placement went through `settingPoint`'s 0.02 snap, which moved an
    /// existing point to the CLICK's height when the click was within 2 % of it in x.
    func testAClickBesideAPointNeverYanksItToTheClickHeight() {
        let points: [[Double]] = [[0, 0], [0.5, 0.7], [1, 1]]
        // 0.015 away in x — inside the old snap — and far below.
        let placed = CurveEditing.placing(points, x: 0.515, curveY: 0.72)
        XCTAssertTrue(placed.points.contains([0.5, 0.7]), "the existing point moved")
        XCTAssertEqual(placed.points.count, 4)
        // Closer than two minimum gaps, the press takes the existing point unchanged.
        let grabbed = CurveEditing.placing(points, x: 0.503, curveY: 0.1)
        XCTAssertEqual(grabbed.points, points)
        XCTAssertEqual(grabbed.index, 1)
    }

    // MARK: - Dragging

    func testADragMovesByThePointersDisplacementNotToThePointer() {
        // Grabbed 0.02 to the right of its centre: the point does not snap sideways.
        var anchor = CurveEditing.DragAnchor(pointX: 0.5, pointY: 0.5,
                                             pointerX: 0.52, pointerY: 0.5)
        let still = anchor.position(pointerX: 0.52, pointerY: 0.5, fine: false)
        XCTAssertEqual(still.x, 0.5, accuracy: 1e-12)
        let moved = anchor.position(pointerX: 0.62, pointerY: 0.6, fine: false)
        XCTAssertEqual(moved.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(moved.y, 0.6, accuracy: 1e-12)
    }

    func testFineAdjustIsATenthOfTheHandAndNeverJumpsWhenToggled() {
        var anchor = CurveEditing.DragAnchor(pointX: 0.5, pointY: 0.5,
                                             pointerX: 0.5, pointerY: 0.5)
        let coarse = anchor.position(pointerX: 0.6, pointerY: 0.5, fine: false)
        XCTAssertEqual(coarse.x, 0.6, accuracy: 1e-12)
        // ⌥ goes down at 0.6: the point stays exactly where it was…
        let toggled = anchor.position(pointerX: 0.6, pointerY: 0.5, fine: true)
        XCTAssertEqual(toggled.x, 0.6, accuracy: 1e-12)
        // …and the next 0.1 of hand travel moves it 0.01.
        let fine = anchor.position(pointerX: 0.7, pointerY: 0.4, fine: true)
        XCTAssertEqual(fine.x, 0.61, accuracy: 1e-12)
        XCTAssertEqual(fine.y, 0.49, accuracy: 1e-12)
        // ⌥ released: still no jump, and full gain again from there.
        let back = anchor.position(pointerX: 0.7, pointerY: 0.4, fine: false)
        XCTAssertEqual(back.x, 0.61, accuracy: 1e-12)
        let after = anchor.position(pointerX: 0.75, pointerY: 0.4, fine: false)
        XCTAssertEqual(after.x, 0.66, accuracy: 1e-12)
    }

    func testTravelSaysWhetherAnOptionPressWasAClick() {
        var anchor = CurveEditing.DragAnchor(pointX: 0.3, pointY: 0.3,
                                             pointerX: 0.3, pointerY: 0.3, fine: true)
        _ = anchor.position(pointerX: 0.302, pointerY: 0.3, fine: true)
        XCTAssertEqual(anchor.travel, 0.002, accuracy: 1e-12)
        _ = anchor.position(pointerX: 0.3, pointerY: 0.3, fine: true)
        XCTAssertEqual(anchor.travel, 0.002, accuracy: 1e-12, "travel is the farthest, not the last")
    }

    // MARK: - The backdrop

    func testThroughTheIdentityTheBackdropIsTheHistogram() {
        let counts: [Double] = (0..<256).map { Double(($0 * 37) % 101) }
        let input = CurveBackdrop.inputCounts(counts) { $0 }
        for i in 0..<256 { XCTAssertEqual(input[i], counts[i], accuracy: 1e-9) }
    }

    /// The point of the whole change: render a ramp through an S-curve, bin the OUTPUT
    /// as the app does, pull it back, and get the INPUT's histogram — not the output's.
    func testTheBackdropOfAnSCurveIsTheInputDistribution() {
        let curve = MonotoneCubic(points: [[0, 0], [0.25, 0.12], [0.75, 0.88], [1, 1]])
        let bins = 256
        // A picture with a midtone hump on the curve's input axis.
        var inputTruth = [Double](repeating: 0, count: bins)
        var outputBinned = [Double](repeating: 0, count: bins)
        let samples = 200_000
        for s in 0..<samples {
            let u = (Double(s) + 0.5) / Double(samples)
            // Inverse-CDF of a smooth hump centred at 0.45.
            let x = min(max(0.45 + 0.18 * (2 * u - 1) * abs(2 * u - 1).squareRoot(), 0), 1)
            inputTruth[min(Int(x * Double(bins)), bins - 1)] += 1
            outputBinned[min(Int(curve.evaluate(x) * Double(bins)), bins - 1)] += 1
        }
        let recovered = CurveBackdrop.inputCounts(outputBinned) { curve.evaluate($0) }
        XCTAssertEqual(recovered.reduce(0, +), Double(samples), accuracy: 1e-6)
        // Compare as distributions over 32 coarse bins (8 fine bins each): the error of
        // the pulled-back histogram against the truth, vs the error of drawing the
        // output as-is (what the editor used to do).
        func coarse(_ v: [Double]) -> [Double] {
            (0..<32).map { c in v[(c * 8)..<(c * 8 + 8)].reduce(0, +) / Double(samples) }
        }
        let truth = coarse(inputTruth), fixed = coarse(recovered), old = coarse(outputBinned)
        let fixedError = zip(truth, fixed).map { abs($0 - $1) }.reduce(0, +)
        let oldError = zip(truth, old).map { abs($0 - $1) }.reduce(0, +)
        XCTAssertLessThan(fixedError, 0.02, "pulled-back backdrop is \(fixedError) off the input")
        XCTAssertGreaterThan(oldError, 0.25, "the test picture does not separate the two")
    }

    func testTheBackdropKeepsItsMassAndNeverGoesNegativeOnAFlatClip() {
        // A curve that clips white at 0.8: every input above 0.8 lands in the top bin.
        let f: (Double) -> Double = { min($0 / 0.8, 1) }
        var counts = [Double](repeating: 10, count: 64)
        counts[63] = 500
        let input = CurveBackdrop.inputCounts(counts, through: f)
        XCTAssertEqual(input.reduce(0, +), counts.reduce(0, +), accuracy: 1e-9)
        XCTAssertTrue(input.allSatisfy { $0 >= 0 })
    }

    func testTheNeutralTailOfEachStageIsTheCurvesThatFollowIt() {
        var set = CurveSet()
        set.point = [[0, 0], [0.5, 0.6], [1, 1]]
        set.luma = [[0, 0], [0.5, 0.4], [1, 1]]
        set.r = [[0, 0], [0.5, 0.7], [1, 1]]
        let stack = CurveStack(set)
        let w = RGBColorSpace.rec2020.luminanceWeights
        let x = 0.5
        let afterLuma = stack.lumaCurve(stack.master(x))
        let expectMaster = w.r * stack.channelCurve(afterLuma, channel: 0)
            + w.g * afterLuma + w.b * afterLuma
        XCTAssertEqual(stack.neutralTail(x, from: .master), expectMaster, accuracy: 1e-12)
        let lumaOnly = stack.lumaCurve(x)
        XCTAssertEqual(stack.neutralTail(x, from: .luma),
                       w.r * stack.channelCurve(lumaOnly, channel: 0) + w.g * lumaOnly
                           + w.b * lumaOnly, accuracy: 1e-12)
        XCTAssertEqual(stack.neutralTail(x, from: .channel(0)), 0.7, accuracy: 1e-12)
        XCTAssertEqual(stack.neutralTail(x, from: .channel(1)), 0.5, accuracy: 1e-12)
    }

    // MARK: - The call sites

    func testTheEditorPlacesDragsAndDrawsThroughTheseRules() throws {
        let source = try CurveMathTests.appSource("CurveEditorView.swift")
        for symbol in ["CurveEditing.placing(", "CurveEditing.DragAnchor(",
                       "anchor.position(", "CurveBackdrop.inputCounts(",
                       "curve.neutralTail(", "clickCount ?? 1) >= 2 {\n                deletePoint"] {
            XCTAssertTrue(source.contains(symbol), "CurveEditorView no longer calls \(symbol)")
        }
        XCTAssertFalse(source.contains("CurveStack.settingPoint(points"),
                       "a click on the graph goes through settingPoint's 0.02 snap again, "
                       + "which yanks a nearby point to the click's height")
        XCTAssertFalse(source.contains("histogram?.normalized(.luma)"),
                       "the backdrop is the curve's OUTPUT histogram again")
    }
}
