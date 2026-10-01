// GestureUndoStepTests.swift
// One drag is one undo step even when it writes two fields under two keys (W2/L-02).
//
// L-01 was a grading-wheel puck writing `hue` and `sat` through two bindings with two
// coalescing keys inside one mouse event: the open step's key alternated, never matched,
// and every event cost two undo steps until the 400-step ring evicted the session. The
// fix was a gesture epoch, as the first clause of `HistoryCoalescing.shouldCoalesce`,
// carried from `AppState.sliderGesture(active:)` through `updateRecipe` into
// `HistoryStack.record`.
//
// L-02 is why that needed saying twice: every coalescing fixture in the repository drove
// ONE key, so the suite was green under L-01 and would be green again if the fix were
// reverted. The rule itself now has a two-key case in LumenCore
// (`HistoryCoalescingTests`), but the rule is the one part that cannot regress quietly —
// the WIRING can: `AppState.updateRecipe` passing `gestureEpoch: recordingEpoch`, and
// `HistoryStack.record` handing both epochs to the rule. Drop either and every LumenCore
// test stays green while the wheel goes back to two steps per event.
//
// So these drive the real `AppState` with two keys per event, which is the only fixture
// shape that can see it. Substitutions, each red:
//   · `gestureEpoch: nil` in `AppState.updateRecipe`'s `history.record` call → 96 / 800
//     steps instead of 1 / 6;
//   · `openEpoch:`/`epoch:` dropped from `HistoryStack.record`'s rule call → the same;
//   · `gestureEpoch &+= 1` removed from `sliderGesture(active: true)` → the third test's
//     two gestures read the same epoch.
#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class GestureUndoStepTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, PhotoItem) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-gesture-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            try? FileManager.default.removeItem(at: root)
        }
        try run(state, PhotoItem(id: root.appendingPathComponent("frame.arw"), iso: 400))
    }

    /// One mouse event of a wheel drag: two fields, two keys, the way
    /// `LookPanel.bindWheel` writes a puck's hue and saturation.
    @MainActor
    private func puckEvent(_ state: AppState, _ photo: PhotoItem, _ i: Int) {
        state.updateRecipe(coalescingKey: "wheel.Shadows.hue", targets: [photo]) { _, r in
            r.develop.tone.contrast = Double(i % 90) + 1
        }
        state.updateRecipe(coalescingKey: "wheel.Shadows.sat", targets: [photo]) { _, r in
            r.develop.tone.exposure = Double(i) / 1000 + 0.001
        }
    }

    @MainActor
    func testAWheelDragWritingTwoKeysIsOneUndoStep() throws {
        try withState { state, photo in
            state.sliderGesture(active: true)
            for i in 0..<48 { puckEvent(state, photo, i) }
            state.sliderGesture(active: false)
            XCTAssertEqual(state.history.steps.count, 1,
                           "48 two-key events made \(state.history.steps.count) undo steps")
        }
    }

    /// The property the owner lost: a long drag must not evict the session's history.
    /// Five earlier, separate edits; a 400-event two-key drag (800 records, twice the
    /// ring); then five ⌘Z must arrive back before the first edit.
    @MainActor
    func testALongTwoKeyDragDoesNotEvictEarlierHistory() throws {
        try withState { state, photo in
            let original = state.recipe(for: photo)
            for (n, key) in ["crop.angle", "wb.temp", "tone.highlights", "tone.shadows",
                             "tone.whites"].enumerated() {
                state.updateRecipe(coalescingKey: key, targets: [photo]) { _, r in
                    r.develop.tone.blacks = Double(n + 1)
                }
            }
            state.sliderGesture(active: true)
            for i in 0..<400 { puckEvent(state, photo, i) }
            state.sliderGesture(active: false)

            XCTAssertEqual(state.history.steps.count, 6)
            for _ in 0..<6 { state.undo() }
            XCTAssertEqual(state.recipe(for: photo), original,
                           "six undos did not reach the state before the first edit — the "
                               + "drag evicted it")
        }
    }

    /// Two separate drags are two gestures, and the epoch is what says so: if a release
    /// and a re-press shared one, the second drag's edits would fold into the first's
    /// step through the epoch clause, past every key and every window.
    @MainActor
    func testTwoDragsAreTwoStepsBecauseEachGestureGetsItsOwnEpoch() throws {
        try withState { state, photo in
            state.sliderGesture(active: true)
            let first = state.recordingEpoch
            for i in 0..<10 { puckEvent(state, photo, i) }
            state.sliderGesture(active: false)
            XCTAssertNil(state.recordingEpoch, "no epoch outside a gesture")

            state.sliderGesture(active: true)
            let second = state.recordingEpoch
            XCTAssertNotNil(first)
            XCTAssertNotEqual(first, second, "two gestures shared one epoch")
            state.sliderGesture(active: false)
        }
    }
}

#endif
