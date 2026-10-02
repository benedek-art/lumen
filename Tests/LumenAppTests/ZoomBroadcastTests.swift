// What a zoom change broadcasts, as a count.
//
// The third of these, after `PanelLayoutBroadcastTests` and `DragBroadcastTests`, and it
// exists because the same defect arrived a third time by a third door.
//
// `zoomLevel` was `@Published` on `AppState`, which is an `@EnvironmentObject` in
// twenty-two view files and a `@StateObject` on `LumenApp` — so one pinch event
// invalidated the whole window AND the `Scene`, seven menus with it. `setZoom` wrote it
// once per event, unguarded, and a pinch emits a high-rate stream. That is K-030, filed at
// S2 and open from the audit until now, and it is the mechanism behind the owner's report
// that "the two-finger zoom or the hold and drag on the mouse … are slow, they are glitchy".
//
// The reason it felt like treacle rather than like a low frame rate is written down in
// `CommandState`'s own header, about the identical defect one field over:
//
//   "Once the main actor cannot finish two whole-window passes inside the gap between two
//    mouse events, AppKit coalesces the events it has not delivered — and from that point
//    the app stops SEEING positions rather than merely rendering fewer of them."
//
// Two claims, and they are different claims:
//
//   · A zoom change costs ONE publish, on an object only the loupe watches.
//   · A zoom change that changes nothing costs ZERO. `@Published` performs no equality
//     check of its own, so that is the guard being measured and not the language — and it
//     is not a corner case: `ZoomLadder.clamp` saturates at 16, so every event after a
//     pinch reaches the ceiling asked for a value it already had.
//
// A counting test rather than an assertion about design, because "this does not publish"
// is not a property a type can carry in its signature, and this is the third time it has
// had to be measured instead of believed.

#if os(macOS)
import Combine
import XCTest
@testable import LumenApp
@testable import LumenCore

@MainActor
final class ZoomBroadcastTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// A fresh viewport, never `shared`: one test's zoom must not be the next test's
    /// starting point, and a publish counted here has to have come from this test.
    private func viewport() -> LoupeViewport { LoupeViewport() }

    func testAZoomChangePublishesExactlyOnce() {
        let v = viewport()
        var publishes = 0
        v.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        v.setZoom(1, at: nil)

        XCTAssertEqual(publishes, 1, "one zoom, one invalidation of one view")
        XCTAssertEqual(v.zoom, 1)
    }

    /// THE GUARD. Every event of a pinch that has run out of room asks for the value the
    /// viewport already holds, and a gesture that has run out of room is exactly when the
    /// hand keeps going.
    func testZoomingToTheRatioAlreadyShowingPublishesNothing() {
        let v = viewport()
        v.setZoom(1, at: nil)
        var publishes = 0
        v.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        v.setZoom(1, at: nil)
        v.setZoom(1, at: nil)
        v.setZoom(1, at: nil)

        XCTAssertEqual(publishes, 0, "an equal ratio is not a change")
    }

    /// Both ends of the ladder, because both saturate and both are reachable by a hand
    /// that keeps moving. Above the ceiling `clamp` returns 16 forever; below the floor it
    /// returns fit forever — and fit ALSO wrote `pan = .zero`, so that end was costing two
    /// writes per event rather than one.
    func testPushingPastEitherEndOfTheLadderPublishesNothingAfterTheFirst() {
        let ceiling = viewport()
        ceiling.setZoom(ZoomLadder.maximum, at: nil)
        var atCeiling = 0
        ceiling.objectWillChange.sink { _ in atCeiling += 1 }.store(in: &cancellables)
        for _ in 0..<24 { ceiling.setZoom(ZoomLadder.maximum * 4, at: nil) }
        XCTAssertEqual(atCeiling, 0, "24 events past the 16x ceiling, none of them a change")

        let floor = viewport()
        var atFloor = 0
        floor.objectWillChange.sink { _ in atFloor += 1 }.store(in: &cancellables)
        for _ in 0..<24 { floor.setZoom(-5, at: nil) }
        XCTAssertEqual(atFloor, 0, "24 events below fit, and fit is where it already was")
    }

    /// A PAN IS ONE PUBLISH PER EVENT, NOT TWO.
    ///
    /// `panBy` wrote `pan` unclamped and every caller wrote it again to clamp — so a
    /// trackpad flick or a held arrow key cost two invalidations per event, the first of
    /// them showing a value the second immediately corrected. `panTo` clamps before it
    /// publishes, and `panBy` is deleted so the shape cannot come back.
    func testAPanEventPublishesOnceAndNotTwice() {
        let v = viewport()
        let container = CGSize(width: 1600, height: 1000)
        let drawn = CGSize(width: 4800, height: 3000)
        var publishes = 0
        v.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        for step in 1...30 {
            v.panTo(x: CGFloat(step) * 7, y: CGFloat(step) * 5,
                    container: container, drawn: drawn)
        }

        XCTAssertEqual(publishes, 30, "thirty pan events, thirty invalidations")
    }

    /// A pan already against the bound publishes nothing, for the same reason a zoom at
    /// the ceiling does: that is exactly when a hand keeps pushing.
    func testPanningIntoTheBoundPublishesNothingAfterTheFirst() {
        let v = viewport()
        let container = CGSize(width: 1600, height: 1000)
        let drawn = CGSize(width: 4800, height: 3000)
        v.panTo(x: 99_999, y: 99_999, container: container, drawn: drawn)
        var publishes = 0
        v.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        for _ in 0..<20 {
            v.panTo(x: 99_999, y: 99_999, container: container, drawn: drawn)
        }

        XCTAssertEqual(publishes, 0, "already at the bound is not a change")
        XCTAssertEqual(v.pan.width, drawn.width / 2, accuracy: 1e-9)
    }

    /// A 60-EVENT PINCH COSTS SIXTY PUBLISHES AND NOT ONE MORE — and, critically, costs
    /// them on this object rather than on `AppState`. The count is the cheap half of the
    /// claim; the object it lands on is the expensive half.
    func testAPinchPublishesOncePerDistinctRatioAndNeverTouchesAppState() {
        let v = viewport()
        var ratios: [Double] = []
        for event in 0..<60 { ratios.append(1 + Double(event) * 0.05) }

        var publishes = 0
        v.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)
        for r in ratios { v.setZoom(r, at: nil) }

        XCTAssertEqual(publishes, ratios.count,
                       "every event of this pinch is a genuinely different ratio, so each "
                           + "one is one publish — the guard must not swallow real motion")

        // The structural half, asserted as text because it is a fact about a declaration
        // rather than about a value: nothing may put the zoom back on `AppState`.
        let appState = try! String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LumenApp/AppState.swift"),
            encoding: .utf8)
        XCTAssertFalse(appState.contains("var zoomLevel"),
                       "the zoom is back on AppState, which is observed by twenty-two "
                           + "views and the Scene — this is K-030 returning, and the "
                           + "counting above cannot see it because it counts the wrong "
                           + "object")
    }
}
#endif
