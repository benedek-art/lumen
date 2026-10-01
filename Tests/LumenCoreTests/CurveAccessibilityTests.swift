// CurveAccessibilityTests.swift
// UX-03, the curve editor: its points and split handles had no accessibility semantics.
//
// Two halves, as in `SliderAccessibilityTests`. The rules — name, spoken value, one
// step on each axis, the splits' step — are LumenCore and run here. The wiring is
// `CurveEditorView` in LumenApp, which compiles only on macOS; it is pinned by source
// contracts on the comment-stripped file.

import XCTest
@testable import LumenCore

final class CurveAccessibilityTests: XCTestCase {

    // MARK: The rules

    func testAPointIsNamedForItsCurveAndItsPlace() {
        XCTAssertEqual(CurveAccessibility.pointLabel(curve: "Red channel", index: 0, count: 4),
                       "Red channel black point")
        XCTAssertEqual(CurveAccessibility.pointLabel(curve: "Red channel", index: 3, count: 4),
                       "Red channel white point")
        XCTAssertEqual(CurveAccessibility.pointLabel(curve: "Point curve", index: 1, count: 4),
                       "Point curve point 1 of 2")
        XCTAssertEqual(CurveAccessibility.pointLabel(curve: "Point curve", index: 2, count: 4),
                       "Point curve point 2 of 2")
    }

    func testAPointSpeaksBothHalvesAsTheReadoutDoes() {
        XCTAssertEqual(CurveAccessibility.pointValue(input: 0.25, output: 0.4),
                       "input 25.0%, output 40.0%")
        XCTAssertEqual(CurveAccessibility.pointValue(input: 1, output: 0),
                       "input 100.0%, output 0.0%")
    }

    /// Increment raises the output one percent and nothing else; decrement undoes it;
    /// the ends of the graph clamp.
    func testOneIncrementRaisesOnePointsOutputByOneStep() {
        let points: [[Double]] = [[0, 0], [0.25, 0.30], [0.75, 0.80], [1, 1]]
        let up = CurveAccessibility.raisingOutput(points, index: 1, .increment)
        XCTAssertEqual(up.count, 4)
        XCTAssertEqual(up[1][0], 0.25, accuracy: 1e-12, "the input must not move")
        XCTAssertEqual(up[1][1], 0.31, accuracy: 1e-12)
        XCTAssertEqual(up[0], points[0])
        XCTAssertEqual(up[2], points[2])
        let back = CurveAccessibility.raisingOutput(up, index: 1, .decrement)
        XCTAssertEqual(back[1][1], 0.30, accuracy: 1e-12)
        XCTAssertEqual(CurveAccessibility.raisingOutput(points, index: 3, .increment)[3][1], 1)
        XCTAssertEqual(CurveAccessibility.raisingOutput(points, index: 0, .decrement)[0][1], 0)
        XCTAssertEqual(CurveAccessibility.raisingOutput(points, index: 9, .increment), points,
                       "an index that names no point changes nothing")
    }

    /// The input step is taken on the axis the graph draws, then mapped to the stored
    /// axis; it cannot push a point past its neighbour.
    func testTheInputStepIsOnePercentOfThePlottedInputAndKeepsTheOrder() {
        let points: [[Double]] = [[0, 0], [0.40, 0.50], [0.42, 0.60], [1, 1]]
        let identity = CurveAccessibility.shiftingInput(points, index: 1, plottedX: 0.40,
                                                        .decrement, storedX: { $0 })
        XCTAssertEqual(identity[1][0], 0.39, accuracy: 1e-12)
        XCTAssertEqual(identity[1][1], 0.50, accuracy: 1e-12, "the output must not move")
        // A stored axis that is NOT the plotted one: the mapping is applied to the
        // stepped plotted x, not to the stored x.
        let mapped = CurveAccessibility.shiftingInput(points, index: 1, plottedX: 0.30,
                                                      .increment, storedX: { $0 + 0.05 })
        XCTAssertEqual(mapped[1][0], 0.36, accuracy: 1e-12)
        // Toward a neighbour 2% away: held at the minimum gap, never across it.
        var crowded = CurveAccessibility.shiftingInput(points, index: 1, plottedX: 0.40,
                                                       .increment, storedX: { $0 })
        crowded = CurveAccessibility.shiftingInput(crowded, index: 1, plottedX: crowded[1][0],
                                                   .increment, storedX: { $0 })
        XCTAssertLessThanOrEqual(crowded[1][0], 0.42 - CurveEditing.minimumPointGap + 1e-12)
        XCTAssertEqual(crowded[2][0], 0.42, accuracy: 1e-12)
    }

    /// Every step moves, at least half a step and at most one and a half, from any
    /// starting value — snapping cannot swallow an action.
    func testEveryStepMoves() {
        for k in 0...200 {
            let start = Double(k) * 0.00437
            guard start < 0.99 else { break }
            let up = CurveAccessibility.stepped(start, .increment)
            XCTAssertGreaterThanOrEqual(up - start, CurveAccessibility.step / 2 - 1e-12)
            XCTAssertLessThanOrEqual(up - start, CurveAccessibility.step * 1.5 + 1e-12)
        }
    }

    func testASplitIsNamedForTheRegionsItSeparatesAndStepsInsideItsNeighbours() {
        let regions = ["Shadows", "Darks", "Lights", "Highlights"]
        XCTAssertEqual(CurveAccessibility.splitLabel(index: 0, regions: regions),
                       "Split between Shadows and Darks")
        XCTAssertEqual(CurveAccessibility.splitLabel(index: 2, regions: regions),
                       "Split between Lights and Highlights")
        XCTAssertEqual(CurveAccessibility.splitValue(0.35), "35.0%")

        let splits = CurveEditing.defaultSplits
        let up = CurveAccessibility.adjustedSplits(splits, index: 1, .increment)
        XCTAssertEqual(up[1], 0.51, accuracy: 1e-12)
        XCTAssertEqual(up[0], splits[0])
        XCTAssertEqual(up[2], splits[2])
        // Against a neighbour: held at the minimum gap, so the order and the index hold.
        let tight = [0.25, 0.48, 0.50]
        let pushed = CurveAccessibility.adjustedSplits(tight, index: 1, .increment)
        XCTAssertEqual(pushed[1], 0.50 - CurveEditing.minimumSplitGap, accuracy: 1e-12)
        // At the band's ends.
        XCTAssertEqual(CurveAccessibility.adjustedSplits([0.10, 0.5, 0.75], index: 0,
                                                         .decrement)[0], 0.10, accuracy: 1e-12)
        XCTAssertEqual(CurveAccessibility.adjustedSplits([0.25, 0.5, 0.90], index: 2,
                                                         .increment)[2], 0.90, accuracy: 1e-12)
    }

    // MARK: The wiring (source contracts)

    /// Each point is its own labelled, valued, adjustable element; the step goes through
    /// the rules above and is bracketed like a drag under that point's own key.
    func testTheCurveEditorsPointsAreAdjustableElements() throws {
        let code = try ShellSource.code("Sources/LumenApp/CurveEditorView.swift")
        let plot = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private var plot: some View", in: code)))
        XCTAssertTrue(plot.contains(".overlay { pointElements(plotted: controls, size: size) }"),
                      "the plot no longer mounts its point elements")
        let rail = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private var splitRail: some View", in: code)))
        XCTAssertTrue(rail.contains(".overlay { splitElements(splits: splits, size: size) }"),
                      "the split rail no longer mounts its handle elements")

        let points = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private func pointElements(", in: code)))
        for needle in [
            "ForEach(Array(plotted.enumerated())",
            ".allowsHitTesting(false)",
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(Text(CurveAccessibility.pointLabel(",
            ".accessibilityValue(Text(CurveAccessibility.pointValue(",
            ".accessibilityAdjustableAction { direction in",
            "case .increment: accessibilityPointStep(index, .increment, input: false)",
            "case .decrement: accessibilityPointStep(index, .decrement, input: false)",
            "accessibilityPointStep(index, .increment, input: true)",
            "accessibilityPointStep(index, .decrement, input: true)",
        ] {
            XCTAssertTrue(points.contains(needle), "pointElements lost \(needle)")
        }
        let splits = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private func splitElements(", in: code)))
        for needle in [
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(Text(CurveAccessibility.splitLabel(",
            ".accessibilityValue(Text(CurveAccessibility.splitValue(position)))",
            "case .increment: accessibilitySplitStep(index, .increment)",
            "case .decrement: accessibilitySplitStep(index, .decrement)",
        ] {
            XCTAssertTrue(splits.contains(needle), "splitElements lost \(needle)")
        }

        let step = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private func accessibilityPointStep(", in: code)))
        XCTAssertTrue(step.contains("CurveAccessibility.raisingOutput(points, index: index, direction)"))
        XCTAssertTrue(step.contains("CurveAccessibility.shiftingInput(points, index: index,"))
        XCTAssertTrue(step.contains("storedX: { storedX($0) }"),
                      "the input step must map the plotted x to the stored axis")
        Self.assertBracketed(step, write: "commitPoints(next, key: pointKey(index))")
        let splitStep = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private func accessibilitySplitStep(", in: code)))
        XCTAssertTrue(splitStep.contains("CurveAccessibility.adjustedSplits(splits, index: index, direction)"))
        Self.assertBracketed(splitStep, write: "writeSplits(next)")
    }

    /// Open, write, close, in that order: one undo step whose deferred write lands.
    private static func assertBracketed(_ body: String, write: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let open = body.range(of: "sliderGestureChanged(true)"),
              let commit = body.range(of: write),
              let close = body.range(of: "sliderGestureChanged(false)") else {
            XCTFail("the step is not bracketed around \(write)", file: file, line: line)
            return
        }
        XCTAssertTrue(open.upperBound <= commit.lowerBound && commit.upperBound <= close.lowerBound,
                      "the bracket must open before and close after \(write)",
                      file: file, line: line)
    }
}
