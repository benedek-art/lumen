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
    /// at fit the loupe never asked for `rungs[0]`. `PhotoRenderModel.load` then took
    /// `max(1024, fullLongEdge / 2)`, and `fullLongEdge` is the viewport in device
    /// pixels bucketed to 256 — so a 16-inch MacBook Pro's loupe (≈1180 pt centre pane
    /// at 2×, bucket 2560) asked for 1280. (Round 3 removed that halving; the request
    /// is the settle's own resolution now, and the top rung is 4096, so the guard would
    /// no longer fire for this reason either. The one-directional rule below is what
    /// makes it correct rather than accidentally satisfied.)
    /// 1280 ≠ 2048, the guard fired, and the ladder
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

    /// WHILE THE HAND IS DOWN THE LADDER ONLY GIVES BACK.
    ///
    /// Stepping down mid-drag is a machine admitting what it cannot afford, and the
    /// hand feels it as the picture keeping up. Stepping UP mid-drag spends frame rate
    /// on sharpness the eye cannot resolve in a moving picture — and at the boundary
    /// between two rungs it oscillates, so the picture's sharpness changes several
    /// times a second under the hand. That is a flicker, and this project has just
    /// spent a round removing one.
    ///
    /// It matters now in a way it did not before: raising the top rung to 4096 means a
    /// fast machine sits at the top with real headroom, which is exactly the state that
    /// banks a step-up streak.
    func testTheLadderNeverClimbsWhileAGestureIsInFlight() {
        var ladder = DraftLadder()
        let requested = 4096
        // One hot frame to get off the top, so there is a rung to climb back to.
        ladder.record(draftMilliseconds: 200,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        let afterHeat = ladder.rung
        XCTAssertGreaterThan(afterHeat, 0, "heat must still be heard mid-gesture")

        // Now a long run of comfortably cheap frames — many times the streak length.
        for _ in 0..<(DraftLadder.stepUpAfter * 4) {
            ladder.record(draftMilliseconds: 1,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        XCTAssertEqual(ladder.rung, afterHeat,
                       "the picture's sharpness may not change under a moving hand")

        // Between gestures the same headroom earns the rung back.
        for _ in 0..<DraftLadder.stepUpAfter {
            ladder.record(draftMilliseconds: 1,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: true)
        }
        XCTAssertLessThan(ladder.rung, afterHeat,
                          "at rest a single change of sharpness is invisible, so the "
                              + "headroom should be spent")
    }

    /// THE HOLD MUST NOT BECOME A RATCHET.
    ///
    /// Holding the rung during a gesture is right — a rung earned back mid-drag is a
    /// visible change of sharpness under a moving hand. But drags are very nearly the
    /// ONLY time this ladder sees a frame: drafts come from slider edits, and otherwise
    /// only from a photo switch, a zoom or a matte landing. So gating the step-up on
    /// "not mid-gesture" and RESETTING the streak while gated means a comfortable drag
    /// can never bank anything, and one hard drag on one heavy photograph drops the rung
    /// for the rest of the session. Every later drag is then needlessly soft, on a
    /// machine that could afford better — which is the complaint this whole round is
    /// about, arriving by a different door.
    ///
    /// So the streak is BANKED while the hand is down and spent when it comes up, where
    /// a single change of sharpness is invisible.
    func testAComfortableGestureEarnsItsRungBackWhenTheHandComesUp() {
        var ladder = DraftLadder()
        let requested = 4096
        ladder.record(draftMilliseconds: 200,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        let afterHeat = ladder.rung
        XCTAssertGreaterThan(afterHeat, 0)

        // A comfortable drag at the new rung: cheap frames, all of them mid-gesture.
        for _ in 0..<DraftLadder.stepUpAfter {
            ladder.record(draftMilliseconds: 1,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        XCTAssertEqual(ladder.rung, afterHeat,
                       "sharpness may not change under a moving hand")

        ladder.gestureEnded()
        XCTAssertLessThan(ladder.rung, afterHeat,
                          "a whole gesture of comfortable frames is exactly the "
                              + "evidence a step up needs; spending it at rest costs "
                              + "one invisible change of sharpness")
    }

    /// And a gesture that ran hot must NOT earn anything back when it ends — heat
    /// breaks the streak wherever it happens.
    func testAHotGestureEarnsNothingBack() {
        var ladder = DraftLadder()
        let requested = 4096
        for _ in 0..<DraftLadder.stepUpAfter {
            ladder.record(draftMilliseconds: 1,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        ladder.record(draftMilliseconds: 200,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        let afterHeat = ladder.rung
        ladder.gestureEnded()
        XCTAssertEqual(ladder.rung, afterHeat,
                       "the gesture ended hot; there is nothing to spend")
    }

    /// The top rung must cap nothing: a machine with headroom drafts at the resolution
    /// the settle will deliver, which is what makes a drag sharp rather than soft.
    func testTheTopRungIsWhateverTheViewerAsksFor() {
        let ladder = DraftLadder()
        for requested in [4096, 3456, 2560, 2048, 1280] {
            XCTAssertEqual(ladder.longEdge(requested: requested), requested,
                           "an untroubled machine must draft at the settle's own "
                               + "resolution, not at a fraction of it")
        }
    }

    // MARK: What a frame cost the hand, not what the renderer reported

    /// THE LADDER WAS BLIND TO EVERYTHING AFTER THE RENDER. A frame's wall time is
    /// measured around the render call and stops there — the SwiftUI handoff, the body
    /// pass, the texture upload and compositing all happen after it and none of them
    /// are free. Removing the half-resolution cap quadrupled the bytes involved, so a
    /// ladder that could not see them would sit at the top rung reporting cheap frames
    /// while the picture ticked.
    func testASaturatedLoopIsCostedByTheFrameIntervalNotTheRenderTime() {
        // A render that reports 12 ms while frames actually land 40 ms apart: the
        // missing 28 ms is real and the hand is feeling it.
        XCTAssertEqual(DraftLadder.costSample(renderMilliseconds: 12,
                                              sincePreviousFrameMilliseconds: 40,
                                              handWasWaiting: true),
                       40,
                       "the cost of a frame is when the NEXT one can start, not when "
                           + "the renderer stopped counting")
    }

    /// And the false positive that makes the interval unusable on its own: a slow hand
    /// produces long gaps because the app was IDLE, and costing those would step the
    /// ladder down for being asked to do less.
    func testASlowHandIsNotAnExpensiveFrame() {
        XCTAssertEqual(DraftLadder.costSample(renderMilliseconds: 12,
                                              sincePreviousFrameMilliseconds: 400,
                                              handWasWaiting: false),
                       12,
                       "nothing was queued behind this frame; the gap is the hand's, "
                           + "not the machine's")
    }

    /// A gap longer than any gesture's frame period is a pause, whatever the
    /// saturation signal said — the two can disagree across a stall.
    func testAPauseIsNeverCostedAsAFrame() {
        XCTAssertEqual(
            DraftLadder.costSample(
                renderMilliseconds: 12,
                sincePreviousFrameMilliseconds:
                    DraftLadder.continuityCeilingMilliseconds + 1,
                handWasWaiting: true),
            12)
    }

    /// The first frame of a photograph has no predecessor, and a clock that misbehaves
    /// must not decide a resolution.
    func testTheFirstFrameAndABadClockFallBackToTheRenderTime() {
        for period in [nil, Double.nan, -5, 0] as [Double?] {
            XCTAssertEqual(DraftLadder.costSample(renderMilliseconds: 12,
                                                  sincePreviousFrameMilliseconds: period,
                                                  handWasWaiting: true),
                           12, "period \(String(describing: period))")
        }
    }

    /// End to end: a loop whose RENDER is comfortably inside budget but whose delivered
    /// frames are not must still walk the ladder down. This is the case the old input
    /// could not express at all.
    func testAFastRenderWithSlowDeliveryStillStepsDown() {
        var ladder = DraftLadder()
        let requested = 4096
        for _ in 0..<3 {
            let rendered = ladder.longEdge(requested: requested)
            let sample = DraftLadder.costSample(renderMilliseconds: 15,
                                                sincePreviousFrameMilliseconds: 90,
                                                handWasWaiting: true)
            ladder.record(draftMilliseconds: sample, renderedLongEdge: rendered,
                          requested: requested, allowStepUp: false)
        }
        XCTAssertLessThan(ladder.longEdge(requested: requested), requested,
                          "15 ms of render inside a 90 ms frame is a picture that "
                              + "ticks, and the ladder is the thing that answers it")
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
