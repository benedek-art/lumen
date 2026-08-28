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

    func testCheapFramesRenderedBelowTheRungBankNoStepUp() {
        var ladder = DraftLadder()
        // A 512 px settle wants a 512 px draft; being cheap says nothing about 2048.
        for _ in 0..<(DraftLadder.stepUpAfter * 2) {
            ladder.record(draftMilliseconds: 1, renderedLongEdge: 512, requested: 512)
        }
        feed(&ladder, ms: 200, times: 1)
        XCTAssertEqual(ladder.longEdge(requested: 4096), DraftLadder.rungs[1],
                       "tiny-frame samples must not have banked a step-up streak")
    }

    // MARK: The size the app actually asks for

    /// THE LADDER WAS DEAF ON EVERY WINDOW THE APP ACTUALLY RUNS IN.
    ///
    /// `record` refused any frame whose long edge was not exactly `rungs[rung]`, and
    /// at fit the loupe never asks for `rungs[0]`. `PhotoRenderModel.load` requests
    /// `max(1024, fullLongEdge / 2)`, and `fullLongEdge` is the viewport in device
    /// pixels bucketed to 256 — so a 16-inch MacBook Pro's loupe (≈1180 pt centre pane
    /// at 2×, bucket 2560) asks for 1280. 1280 ≠ 2048, the guard fired, and the ladder
    /// sat frozen at rung 0 for the life of the process. The one mechanism whose job is
    /// to keep a drag inside the 35 ms budget could not observe a single frame of it,
    /// however long those frames took.
    ///
    /// It survived because every test above feeds `requested: 4096` — the one value
    /// that keeps the guard satisfied, and the only one the app asks for when ZOOMED.
    /// The interactive case, at fit, where drags actually happen, was never fed.
    ///
    /// The rule the guard was reaching for is real but applies to ONE direction. Cost
    /// is monotone in pixels: a frame that blew the budget at 1280 px proves 2048 is
    /// unaffordable, so heat is evidence wherever it is measured. Cheapness is not —
    /// 1 ms at 512 px says nothing about 2048 — so a step UP still requires a frame
    /// rendered at the rung itself.
    func testHeatIsHeardAtTheSizeTheAppActuallyAsksFor() {
        for requested in [1024, 1280, 1408, 1664] {
            var ladder = DraftLadder()
            let rendered = ladder.longEdge(requested: requested)
            XCTAssertEqual(rendered, requested,
                           "the fixture must exercise a request BELOW the top rung")
            ladder.record(draftMilliseconds: 200, renderedLongEdge: rendered,
                          requested: requested)
            XCTAssertLessThan(
                ladder.longEdge(requested: requested), requested,
                "a 200 ms frame at \(requested) px is a dropped frame the hand feels; "
                    + "the ladder must step down even though the request never "
                    + "reached rungs[0]")
        }
    }

    /// The same defect stated as the drag it produces: sustained heat at the size a
    /// real loupe asks for has to walk the ladder down, not leave it at the top.
    func testASustainedHotDragAtFitReachesACheapRung() {
        var ladder = DraftLadder()
        let requested = 1280
        for _ in 0..<10 {
            ladder.record(draftMilliseconds: 120,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested)
        }
        XCTAssertEqual(ladder.longEdge(requested: requested), DraftLadder.rungs.last,
                       "ten hot frames in a row is a hand being told to wait; the "
                           + "ladder owes it the floor")
    }

    /// Heat may not buy a step up by the back door: stepping down is allowed from any
    /// size, stepping back up still needs frames rendered AT the rung.
    func testCheapFramesBelowTheRungStillEarnNothingAfterTheDownwardFix() {
        var ladder = DraftLadder()
        ladder.record(draftMilliseconds: 200, renderedLongEdge: 1280, requested: 1280)
        let afterHeat = ladder.rung
        XCTAssertGreaterThan(afterHeat, 0, "the hot frame should have stepped down")
        for _ in 0..<(DraftLadder.stepUpAfter * 3) {
            ladder.record(draftMilliseconds: 1, renderedLongEdge: 320, requested: 320)
        }
        XCTAssertEqual(ladder.rung, afterHeat,
                       "a 320 px frame being cheap is not evidence that the rung is "
                           + "affordable")
    }
}
