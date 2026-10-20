// ResponsivenessPanelTests.swift
// The develop panels' own drag surfaces, held to the slider contract: a press that has
// not moved writes nothing, and a body pass does not rebuild what has not changed.
//
// Pinned here:
//   · the two pivot strips (Look's zone weights, Zones' five centres) map a drag to a
//     pivot only once the pointer has travelled — the press itself is not an edit;
//   · the curve editor's plot and rail skip the zero-translation press the same way,
//     so a click on a point no longer pulls it under the cursor;
//   · the curve editor builds its `CurveStack` once per distinct curve, and the memo
//     always answers for the curve it was asked about.
// The gesture wiring is view code a unit test cannot drive, so it is read off the
// source with comments blanked, the way `ResponsivenessSliderTests` does.
#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessPanelTests: XCTestCase {

    @MainActor
    func testAPivotPressThatHasNotMovedWritesNothing() {
        XCTAssertNil(ZoneWeightStrip.draggedPivot(from: 0.3, translation: 0, width: 200))
        XCTAssertNil(ZonePivotStrip.draggedPivot(from: 0.3, translation: 0, width: 200))
        // No width, no axis to map onto.
        XCTAssertNil(ZoneWeightStrip.draggedPivot(from: 0.3, translation: 10, width: 0))
        XCTAssertNil(ZonePivotStrip.draggedPivot(from: 0.3, translation: 10, width: 0))
    }

    @MainActor
    func testAPivotDragMovesByTranslationAndClamps() throws {
        let look = try XCTUnwrap(ZoneWeightStrip.draggedPivot(from: 0.3, translation: 20,
                                                               width: 200))
        XCTAssertEqual(look, 0.4, accuracy: 1e-12)
        let zones = try XCTUnwrap(ZonePivotStrip.draggedPivot(from: 0.5, translation: -50,
                                                               width: 100))
        XCTAssertEqual(zones, 0, accuracy: 1e-12)
        XCTAssertEqual(ZoneWeightStrip.draggedPivot(from: 0.9, translation: 400, width: 200), 1)
    }

    @MainActor
    func testTheCurveStackMemoAnswersForTheCurveAsked() {
        let bent = CurveSet(point: [[0, 0], [0.5, 0.7], [1, 1]])
        let flat = CurveSet()
        XCTAssertEqual(CurveEditorView.memoizedStack(for: bent).set, bent)
        XCTAssertEqual(CurveEditorView.memoizedStack(for: flat).set, flat)
        let again = CurveEditorView.memoizedStack(for: bent)
        XCTAssertEqual(again.set, bent)
        XCTAssertEqual(again.master(0.5), CurveStack(bent).master(0.5), accuracy: 1e-12)
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return blankingComments(in: try String(
            contentsOf: root.appendingPathComponent("Sources/LumenApp/\(name)"),
            encoding: .utf8))
    }

    func testTheCurvePressIsNotAMove() throws {
        let code = try source("CurveEditorView.swift")
        let guardPress = try XCTUnwrap(code.range(of: "guard value.translation != .zero"))
        let move = try XCTUnwrap(code.range(of: "updateDrag(to: value.location, size: size)"))
        XCTAssertLessThan(guardPress.lowerBound, move.lowerBound,
                          "the press must be skipped before the held point is moved")
        let railGuard = try XCTUnwrap(code.range(of: "guard value.translation.width != 0"))
        let railMove = try XCTUnwrap(code.range(
            of: "moveSplit(index, toX: value.location.x, size: size)"))
        XCTAssertLessThan(railGuard.lowerBound, railMove.lowerBound)
    }

    func testTheCurveStackIsNotRebuiltPerRead() throws {
        let code = try source("CurveEditorView.swift")
        XCTAssertFalse(code.contains("CurveStack(curveSet)"),
                       "every read of `stack` must go through the memo")
    }

    func testThePivotStripsRouteThroughTheGuard() throws {
        XCTAssertTrue(try source("LookPanel.swift").contains("ZoneWeightStrip.draggedPivot("))
        XCTAssertTrue(try source("ZonesPanel.swift").contains("ZonePivotStrip.draggedPivot("))
    }
}
#endif
