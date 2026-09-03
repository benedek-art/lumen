// The read-ahead's two rules: which photograph, and — the one that keeps warming from
// making paging worse — when it is allowed at all (docs/34).
import XCTest
@testable import LumenCore

final class DecodeWarmingTests: XCTestCase {

    // MARK: Which

    func testWarmsTheNextPhotographWhenMovingForward() {
        XCTAssertEqual(DecodeWarming.indices(cursor: 4, count: 20, movingForward: true),
                       [5])
    }

    func testWarmsThePreviousWhenMovingBackward() {
        XCTAssertEqual(DecodeWarming.indices(cursor: 4, count: 20, movingForward: false),
                       [3])
    }

    /// At the end of the roll in the direction of travel there is nothing to warm, and
    /// warming the other neighbour would be warming the one just left.
    func testTheEndsWarmNothing() {
        XCTAssertEqual(DecodeWarming.indices(cursor: 19, count: 20, movingForward: true),
                       [])
        XCTAssertEqual(DecodeWarming.indices(cursor: 0, count: 20, movingForward: false),
                       [])
    }

    func testSpanIsHonouredAndClamped() {
        XCTAssertEqual(DecodeWarming.indices(cursor: 0, count: 20,
                                             movingForward: true, span: 3),
                       [1, 2, 3])
        XCTAssertEqual(DecodeWarming.indices(cursor: 18, count: 20,
                                             movingForward: true, span: 3),
                       [19], "a span may not run off the end of the roll")
    }

    func testDegenerateInputsWarmNothing() {
        XCTAssertEqual(DecodeWarming.indices(cursor: 0, count: 0, movingForward: true), [])
        XCTAssertEqual(DecodeWarming.indices(cursor: -1, count: 5, movingForward: true), [])
        XCTAssertEqual(DecodeWarming.indices(cursor: 7, count: 5, movingForward: true), [])
        XCTAssertEqual(DecodeWarming.indices(cursor: 1, count: 5,
                                             movingForward: true, span: 0), [])
    }

    /// One ahead. Two would double the memory held for frames nobody asked for and
    /// double the window in which a page lands behind a warm.
    func testTheDefaultSpanIsOne() {
        XCTAssertEqual(DecodeWarming.span, 1)
    }

    // MARK: When — the rule that keeps this from backfiring

    /// A decode has no cancellation points, so a warm in flight blocks the photograph
    /// the owner actually asked for. Culling never settles, so culling never warms.
    func testPagingDoesNotWarm() {
        XCTAssertFalse(DecodeWarming.mayWarm(currentIsSettled: false,
                                             viewerHasPhoto: true,
                                             gestureInFlight: false),
                       "an unsettled viewer is someone paging — the actor must stay free")
    }

    func testDwellingWarms() {
        XCTAssertTrue(DecodeWarming.mayWarm(currentIsSettled: true,
                                            viewerHasPhoto: true,
                                            gestureInFlight: false))
    }

    /// The render lane belongs to the hand while a slider is moving.
    func testAGestureBlocksWarming() {
        XCTAssertFalse(DecodeWarming.mayWarm(currentIsSettled: true,
                                             viewerHasPhoto: true,
                                             gestureInFlight: true))
    }

    func testAnEmptyViewerWarmsNothing() {
        XCTAssertFalse(DecodeWarming.mayWarm(currentIsSettled: true,
                                             viewerHasPhoto: false,
                                             gestureInFlight: false))
    }
}
