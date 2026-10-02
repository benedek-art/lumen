// S-05 against the real undo stack: two point deletions are two undo steps, and
// placing a point then dragging it is still one.
//
// The edits are the editor's own: `CurveEditing.deleting` and `settingPoint`/`moved`
// make the curves, `CurveEditing.deletionCoalescingKey`/`deletionLabel` and
// `pointCoalescingKey` are what `CurveEditorView` passes to `updateRecipe`, and the
// records go into `HistoryStack.record` exactly as `updateRecipe` sends them. The two
// records land microseconds apart, well inside the 1.2 s coalescing window — which is
// the condition under which the old `delete.<channel>.<index>` key folded them.

#if os(macOS)
import XCTest
@testable import LumenApp
@testable import LumenCore

@MainActor
final class CurveDeletionHistoryTests: XCTestCase {

    private let photo = URL(fileURLWithPath: "/roll/curve.arw")

    private func recipe(_ points: [[Double]]) -> Recipe {
        var r = Recipe()
        r.develop.curve.point = points
        return r
    }

    private func record(_ history: HistoryStack, from: [[Double]], to: [[Double]],
                        key: String?, label: String? = nil, epoch: Int? = nil) {
        history.record(before: [photo: HistoryStack.PhotoEdit(recipe: recipe(from))],
                       after: [photo: HistoryStack.PhotoEdit(recipe: recipe(to))],
                       coalescingKey: key, label: label, gestureEpoch: epoch)
    }

    private func points(_ edit: [URL: HistoryStack.PhotoEdit]?) -> [[Double]]? {
        edit?[photo]?.recipe?.develop.curve.point
    }

    func testTwoDeletionsAtOneIndexAreTwoUndoSteps() throws {
        let history = HistoryStack()
        let start: [[Double]] = [[0, 0], [0.25, 0.2], [0.5, 0.55], [0.75, 0.8], [1, 1]]
        let once = try XCTUnwrap(CurveEditing.deleting(start, at: 1))
        let twice = try XCTUnwrap(CurveEditing.deleting(once, at: 1))
        // two ⌥-clicks: two gestures, so two epochs
        record(history, from: start, to: once, key: CurveEditing.deletionCoalescingKey,
               label: CurveEditing.deletionLabel, epoch: 1)
        record(history, from: once, to: twice, key: CurveEditing.deletionCoalescingKey,
               label: CurveEditing.deletionLabel, epoch: 2)

        XCTAssertEqual(history.steps.count, 2,
                       "two deletions of two different points became one undo step")
        XCTAssertEqual(history.undoLabel, CurveEditing.deletionLabel)
        XCTAssertEqual(points(history.undo()), once,
                       "the first ⌘Z must bring back ONE point, the second deleted")
        XCTAssertEqual(points(history.undo()), start)
    }

    /// The same, from the context menu, which runs outside any gesture.
    func testTwoContextMenuDeletionsAreTwoUndoSteps() throws {
        let history = HistoryStack()
        let start: [[Double]] = [[0, 0], [0.3, 0.25], [0.6, 0.7], [1, 1]]
        let once = try XCTUnwrap(CurveEditing.deleting(start, at: 1))
        let twice = try XCTUnwrap(CurveEditing.deleting(once, at: 1))
        record(history, from: start, to: once, key: CurveEditing.deletionCoalescingKey)
        record(history, from: once, to: twice, key: CurveEditing.deletionCoalescingKey)
        XCTAssertEqual(history.steps.count, 2)
    }

    /// Place-then-drag is ONE step: the placement and the adjustment share the point's
    /// key, and undo returns to before the point existed.
    func testPlacingAPointAndDraggingItIsStillOneUndoStep() {
        let history = HistoryStack()
        let start: [[Double]] = CurveEditing.identity
        let placed = CurveEditing.sanitized(CurveStack.settingPoint(start, x: 0.4, y: 0.5))
        let index = CurveEditing.nearestIndexByX(placed, x: 0.4) ?? 1
        let key = CurveEditing.pointCoalescingKey(prefix: "curve.", channel: "point",
                                                  index: index)
        record(history, from: start, to: placed, key: key, epoch: 5)
        var current = placed
        for step in 1...10 {
            let next = CurveEditing.moved(current, index: index, toX: 0.4,
                                          toY: 0.5 + Double(step) / 100)
            record(history, from: current, to: next, key: key, epoch: 5)
            current = next
        }
        XCTAssertEqual(history.steps.count, 1, "place-then-drag split into several steps")
        XCTAssertEqual(points(history.undo()), start)
    }
}
#endif
