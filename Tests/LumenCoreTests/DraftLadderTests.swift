// The draft-resolution ladder's contract (docs/23 M1a): down fast, up slow, never
// above what the caller asked for, and deaf to frames that were not its own answer.
import XCTest
@testable import LumenCore

final class DraftLadderTests: XCTestCase {

    private func feed(_ ladder: inout DraftLadder, ms: Double, times: Int,
                      requested: Int = 4096) {
        for _ in 0..<times {
            ladder.record(draftMilliseconds: ms,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested)
        }
    }

    func testStartsAtTheTopAndNeverExceedsTheRequest() {
        let ladder = DraftLadder()
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[0],
                       "a fast machine's first frames should not pay for a slow one")
        XCTAssertEqual(ladder.longEdge(requested: 1024), 1024,
                       "the ladder must never size a draft above the settle it serves")
    }

    func testOneHotFrameStepsDownImmediately() {
        var ladder = DraftLadder()
        feed(&ladder, ms: DraftLadder.stepDownOver + 5, times: 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[1],
                       "a hot draft is a dropped frame the hand feels now")
    }

    func testSustainedHeatWalksToTheFloorAndStops() {
        var ladder = DraftLadder()
        feed(&ladder, ms: 200, times: 10)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs.last,
                       "the floor is the floor; below it the answer is the budget "
                           + "failing, not a smaller picture")
    }

    func testHeadroomMustBeAPatternBeforeItIsSpent() {
        var ladder = DraftLadder()
        feed(&ladder, ms: 200, times: 1) // down one rung
        feed(&ladder, ms: 5, times: DraftLadder.stepUpAfter - 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[1],
                       "a few cheap frames are not yet a pattern")
        feed(&ladder, ms: 5, times: 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[0],
                       "a full streak of cheap frames earns the rung back")
    }

    func testAMiddlingFrameResetsTheStreak() {
        var ladder = DraftLadder()
        feed(&ladder, ms: 200, times: 1)
        feed(&ladder, ms: 5, times: DraftLadder.stepUpAfter - 1)
        feed(&ladder, ms: DraftLadder.budgetMilliseconds, times: 1) // inside budget, no headroom
        feed(&ladder, ms: 5, times: DraftLadder.stepUpAfter - 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[1],
                       "the streak restarts after any frame without clear headroom")
    }

    func testFramesRenderedBelowTheRungTeachNothing() {
        var ladder = DraftLadder()
        // A 512 px settle wants a 512 px draft; its cost says nothing about 2048.
        for _ in 0..<(DraftLadder.stepUpAfter * 2) {
            ladder.record(draftMilliseconds: 1, renderedLongEdge: 512, requested: 512)
        }
        feed(&ladder, ms: 200, times: 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[1],
                       "tiny-frame samples must not have banked a step-up streak")
    }
}
