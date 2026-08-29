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

    /// THE LADDER MUST NOT MISTAKE ITS OWN TRANSITION FOR THE DESTINATION.
    ///
    /// The lever is the decode scale: `renderPreview` derives `scaleFactor` from the
    /// size it is asked for and runs the whole graph at the decoded resolution. So
    /// asking for a smaller rung means a decode key the cache has never seen, and the
    /// first frame at every new rung pays a fresh RAW decode — the largest single cost
    /// in the interaction on a big file, and one no later frame at that size pays.
    ///
    /// This is what that costs if the ladder believes it. Each step down is followed by
    /// one expensive frame, the ladder reads it as "still too slow", and it steps again
    /// — all the way to the floor, on a machine whose steady-state cost at the SECOND
    /// rung was comfortable. The photographer sees a drag that starts sharp and gets
    /// blurrier the longer they hold the slider.
    func testAFreshDecodeAfterAStepDownDoesNotWalkTheLadderToTheFloor() {
        let requested = 4096
        let expensiveFirstFrameAtANewSize = DraftLadder.stepDownOver * 3
        let comfortableSteadyState = DraftLadder.stepUpUnder

        // Believing every frame: the ladder never sees a cheap one, because it changes
        // size before any size gets a second frame.
        var naive = DraftLadder()
        var previous: Int?
        for _ in 0..<12 {
            let size = naive.longEdge(requested: requested)
            let ms = size == previous ? comfortableSteadyState
                                      : expensiveFirstFrameAtANewSize
            naive.record(draftMilliseconds: ms, renderedLongEdge: size,
                         requested: requested)
            previous = size
        }
        XCTAssertEqual(naive.longEdge(requested: requested), DraftLadder.rungs.last,
                       "the fixture must actually produce the cascade, or the rule "
                           + "below is being credited with fixing nothing")

        // Skipping the transition frame: the same machine, the same frame times, and
        // the ladder settles one rung down instead of eight.
        var guarded = DraftLadder()
        previous = nil
        for _ in 0..<12 {
            let size = guarded.longEdge(requested: requested)
            let ms = size == previous ? comfortableSteadyState
                                      : expensiveFirstFrameAtANewSize
            if DraftLadder.isRepresentative(renderedLongEdge: size,
                                            previousRenderedLongEdge: previous) {
                guarded.record(draftMilliseconds: ms, renderedLongEdge: size,
                               requested: requested)
            }
            previous = size
        }
        XCTAssertEqual(guarded.rung, 0,
                       "every frame this ladder was allowed to see was comfortable, so "
                           + "it should still be at the top rung — it fell to "
                           + "\(guarded.longEdge(requested: requested)) px")
    }

    /// The number that decides between the two remaining explanations, and which this
    /// project has argued about for three rounds without printing.
    func testTheTimeAfterTheRenderIsTheIntervalLessTheRender() throws {
        let after = try XCTUnwrap(
            DraftLadder.afterRenderMilliseconds(renderMilliseconds: 12,
                                                sincePreviousFrameMilliseconds: 95,
                                                handWasWaiting: true))
        XCTAssertEqual(
            after, 83, accuracy: 1e-9,
            "a 12 ms render arriving every 95 ms is 83 ms spent somewhere the render "
                + "timer cannot see — that is the display path, and no resolution "
                + "ladder touches it")
    }

    func testAnIdleHandIsNotADisplayCost() {
        XCTAssertNil(
            DraftLadder.afterRenderMilliseconds(renderMilliseconds: 12,
                                                sincePreviousFrameMilliseconds: 400,
                                                handWasWaiting: false),
            "the loop was not saturated, so the gap belongs to the hand")
        XCTAssertNil(
            DraftLadder.afterRenderMilliseconds(renderMilliseconds: 12,
                                                sincePreviousFrameMilliseconds: nil,
                                                handWasWaiting: true),
            "the first frame of a gesture continues nothing")
        XCTAssertNil(
            DraftLadder.afterRenderMilliseconds(
                renderMilliseconds: 12,
                sincePreviousFrameMilliseconds:
                    DraftLadder.continuityCeilingMilliseconds + 1,
                handWasWaiting: true),
            "a gap longer than any gesture's frame period is a pause, not a cost")
    }

    func testARenderLongerThanItsOwnIntervalReportsNothingAfterRatherThanNegativeTime()
    throws {
        let after = try XCTUnwrap(
            DraftLadder.afterRenderMilliseconds(renderMilliseconds: 40,
                                                sincePreviousFrameMilliseconds: 30,
                                                handWasWaiting: true))
        XCTAssertEqual(
            after, 0, accuracy: 1e-9,
            "the period contains the render, so this is a clock or an ordering — and a "
                + "negative display cost on a HUD is worse than a zero")
    }

    /// THE RECOVERY THE OWNER ACTUALLY EXPERIENCED, as a test.
    ///
    /// A defect made every drag frame cost 457 ms. The ladder correctly walked to its
    /// floor. The defect was fixed — and the picture stayed blurry, because climbing was
    /// twelve cheap frames for one rung, spent once per gesture: eight more drags to get
    /// back. "If I move any of the sliders they are still extremely blurry" is what that
    /// looks like from the outside.
    func testACheapSettleRestoresTheLadderInOneGestureRatherThanEight() {
        var ladder = DraftLadder()
        let requested = 2560

        // The bad era: sustained heat walks it to the floor.
        for _ in 0..<40 {
            let size = ladder.longEdge(requested: requested)
            ladder.record(draftMilliseconds: 457, renderedLongEdge: size,
                          requested: requested)
        }
        XCTAssertEqual(ladder.longEdge(requested: requested), DraftLadder.rungs.last,
                       "the fixture must reach the floor, or there is nothing to "
                           + "recover from")

        // The fix lands. The very next gesture ends with a settle at the full size,
        // comfortably inside the budget.
        ladder.recordSettle(milliseconds: 14.5, renderedLongEdge: requested)
        XCTAssertEqual(ladder.longEdge(requested: requested), requested,
                       "a settle at \(requested) px inside the budget proves a draft at "
                           + "that size is affordable — a settle pays exact table bakes "
                           + "where a draft serves them stale, so the inequality only "
                           + "runs one way and it runs in this direction")
    }

    /// The claim may never be larger than the evidence.
    func testASettleNeverClaimsASizeItDidNotMeasure() {
        var ladder = DraftLadder()
        for _ in 0..<40 {
            let size = ladder.longEdge(requested: 4096)
            ladder.record(draftMilliseconds: 457, renderedLongEdge: size, requested: 4096)
        }
        ladder.recordSettle(milliseconds: 10, renderedLongEdge: 1280)
        XCTAssertEqual(ladder.longEdge(requested: 4096), 1280,
                       "a cheap settle at 1280 says nothing whatever about 4096")
    }

    /// A settle that blew the budget is not evidence of headroom, and must not climb.
    func testAnExpensiveSettleDoesNotClimb() {
        var ladder = DraftLadder()
        for _ in 0..<40 {
            let size = ladder.longEdge(requested: 2560)
            ladder.record(draftMilliseconds: 457, renderedLongEdge: size, requested: 2560)
        }
        let floor = ladder.rung
        ladder.recordSettle(milliseconds: DraftLadder.budgetMilliseconds + 1,
                            renderedLongEdge: 2560)
        XCTAssertEqual(ladder.rung, floor,
                       "the settle did not fit the budget, so it proves nothing")
    }

    /// And it must never step DOWN — heat is the draft path's business, measured on the
    /// frames a hand actually feels.
    func testASettleNeverStepsTheLadderDown() {
        var ladder = DraftLadder()
        XCTAssertEqual(ladder.rung, 0)
        ladder.recordSettle(milliseconds: 1, renderedLongEdge: 576)
        XCTAssertEqual(ladder.rung, 0,
                       "a cheap settle at a small size is not a reason to get worse")
    }

    /// The rule's own edges, stated separately from the scenario above.
    func testOnlyAFrameWhoseSizeMatchesThePreviousOneIsRepresentative() {
        XCTAssertFalse(DraftLadder.isRepresentative(renderedLongEdge: 2048,
                                                    previousRenderedLongEdge: nil),
                       "the first frame of a session pays a cold decode too")
        XCTAssertFalse(DraftLadder.isRepresentative(renderedLongEdge: 1600,
                                                    previousRenderedLongEdge: 2048),
                       "a step down is a new decode key")
        XCTAssertFalse(DraftLadder.isRepresentative(renderedLongEdge: 2048,
                                                    previousRenderedLongEdge: 1600),
                       "and so is a step up")
        XCTAssertTrue(DraftLadder.isRepresentative(renderedLongEdge: 2048,
                                                   previousRenderedLongEdge: 2048),
                      "two frames at one size is the steady state the budget is about")
    }

    /// Skipping the transition must not make the ladder deaf to a rung it cannot
    /// afford — it should cost one frame of delay, not the step.
    func testARungThatCannotBeAffordedIsStillCaughtOnItsSecondFrame() {
        var ladder = DraftLadder()
        let requested = 4096
        let size = ladder.longEdge(requested: requested)
        // First frame at this size: skipped by the rule, whatever it cost.
        XCTAssertFalse(DraftLadder.isRepresentative(renderedLongEdge: size,
                                                    previousRenderedLongEdge: nil))
        XCTAssertEqual(ladder.rung, 0)
        // Second frame, same size, still hot: this one counts.
        XCTAssertTrue(DraftLadder.isRepresentative(renderedLongEdge: size,
                                                   previousRenderedLongEdge: size))
        ladder.record(draftMilliseconds: DraftLadder.stepDownOver * 2,
                      renderedLongEdge: size, requested: requested)
        XCTAssertGreaterThan(ladder.rung, 0,
                            "one frame of delay is the price; deafness is not")
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
            ladder.record(draftMilliseconds: sample, renderMilliseconds: 15,
                          renderedLongEdge: rendered,
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

    // MARK: - Heat the ladder has no lever against

    /// THE FIELD DEFECT, as one test.
    ///
    /// Measured on the owner's machine during a slider drag: the draft render cost
    /// 11 ms, the delivery overhead read 0.1 ms on the large majority of frames, and
    /// spiked to 285/378/399 ms on scattered ones. Every spike was one sample eight
    /// times over `stepDownOver`, so every spike dropped a rung; the ladder reached its
    /// 576 floor inside one drag and stayed there for the session, leaving the picture
    /// soft under the hand at three times the headroom it needed.
    ///
    /// A 399 ms interval around an 11 ms render at 576 px is not a cost fewer pixels can
    /// relieve, so the ladder must not spend rungs on it.
    func testScatteredDeliveryStallsDoNotWalkTheLadderToTheFloor() {
        var ladder = DraftLadder()
        let requested = 4096
        // Twelve cheap frames, then a stall, twelve more, another stall — six times.
        for burst in 0..<6 {
            for _ in 0..<12 {
                let rendered = ladder.longEdge(requested: requested)
                ladder.record(draftMilliseconds: 11.1, renderMilliseconds: 11,
                              renderedLongEdge: rendered, requested: requested,
                              allowStepUp: false)
            }
            let rendered = ladder.longEdge(requested: requested)
            ladder.record(draftMilliseconds: [285, 378, 399][burst % 3],
                          renderMilliseconds: 11,
                          renderedLongEdge: rendered, requested: requested,
                          allowStepUp: false)
        }
        XCTAssertEqual(ladder.rung, 0,
                       "six isolated stalls around an 11 ms render are six stalls, not "
                           + "six rungs' worth of evidence that the machine is slow")
    }

    /// The other side of the same rule: delivery heat that REPEATS is a real cost, and
    /// fewer pixels is the only lever available for it.
    func testTwoConsecutiveHotDeliveriesDoStepDown() {
        var ladder = DraftLadder()
        let requested = 4096
        for _ in 0..<DraftLadder.stepDownRunOnDelivery {
            ladder.record(draftMilliseconds: 90, renderMilliseconds: 11,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        XCTAssertGreaterThan(ladder.rung, 0,
                            "sustained slow delivery is an expense, not an outlier")
    }

    /// Consecutive means consecutive. A comfortable frame between two stalls is the
    /// evidence that they were stalls.
    func testACoolFrameBetweenTwoStallsBreaksTheRun() {
        var ladder = DraftLadder()
        let requested = 4096
        let rendered = ladder.longEdge(requested: requested)
        ladder.record(draftMilliseconds: 399, renderMilliseconds: 11,
                      renderedLongEdge: rendered, requested: requested,
                      allowStepUp: false)
        ladder.record(draftMilliseconds: 11.1, renderMilliseconds: 11,
                      renderedLongEdge: rendered, requested: requested,
                      allowStepUp: false)
        ladder.record(draftMilliseconds: 399, renderMilliseconds: 11,
                      renderedLongEdge: rendered, requested: requested,
                      allowStepUp: false)
        XCTAssertEqual(ladder.rung, 0,
                       "two stalls separated by a good frame are two stalls")
    }

    /// A hot RENDER needs no corroboration: pixels caused it and fewer will fix it.
    /// This is the one-sample descent the ladder has always promised, and the delivery
    /// rule must not have slowed it down.
    func testAHotRenderStillStepsDownOnItsFirstFrame() {
        var ladder = DraftLadder()
        ladder.record(draftMilliseconds: DraftLadder.stepDownOver + 5,
                      renderMilliseconds: DraftLadder.stepDownOver + 5,
                      renderedLongEdge: DraftLadder.rungs[0], requested: 4096,
                      allowStepUp: false)
        XCTAssertEqual(ladder.rung, 1, "a hot render is a dropped frame felt now")
    }

    // MARK: - Climbing on what the render costs

    /// THE OTHER HALF OF THE FIELD DEFECT.
    ///
    /// The streak used to be judged on `costSample` — `max(render, frame period)`. Any
    /// machine whose frame period is floored above `stepUpUnder` by something other than
    /// pixels could therefore never accumulate a streak and never climb, however cheap
    /// its renders were. An 11 ms render arriving every 20 ms is a loop with obvious
    /// headroom, and the old rule read it as permanently ineligible.
    func testACheapRenderClimbsEvenWhenDeliveryIsSlowerThanTheStepUpThreshold() {
        var ladder = DraftLadder()
        let requested = 4096
        // Put it on the floor first, so there is somewhere to climb from.
        while ladder.rung < DraftLadder.rungs.count - 1 {
            ladder.record(draftMilliseconds: 200,
                          renderMilliseconds: 200,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        let floor = ladder.rung
        let period = 20.0
        XCTAssertGreaterThan(period, DraftLadder.stepUpUnder,
                             "the test is only meaningful if the old rule would refuse")
        for _ in 0..<DraftLadder.stepUpAfter {
            ladder.record(draftMilliseconds: period, renderMilliseconds: 11,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        ladder.gestureEnded()
        XCTAssertLessThan(ladder.rung, floor,
                          "an 11 ms render is headroom whatever the arrival rate is")
    }

    /// The hysteresis that keeps the previous test from becoming an oscillator: a cheap
    /// render inside a loop that is ALREADY missing the budget earns nothing, because
    /// spending it would only make the loop later. Between the budget and `stepDownOver`
    /// the ladder holds still — neither direction helps there.
    func testACheapRenderInAnAlreadyLateLoopEarnsNothing() {
        var ladder = DraftLadder()
        let requested = 4096
        ladder.record(draftMilliseconds: 200, renderMilliseconds: 200,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        let held = ladder.rung
        let late = (DraftLadder.budgetMilliseconds + DraftLadder.stepDownOver) / 2
        for _ in 0..<(DraftLadder.stepUpAfter * 3) {
            ladder.record(draftMilliseconds: late, renderMilliseconds: 11,
                          renderedLongEdge: ladder.longEdge(requested: requested),
                          requested: requested, allowStepUp: false)
        }
        ladder.gestureEnded()
        XCTAssertEqual(ladder.rung, held,
                       "a loop already over budget is not a loop with room for pixels")
        XCTAssertLessThan(late, DraftLadder.stepDownOver,
                          "and it is not hot enough to step down either — that dead "
                              + "band is the point")
    }

    /// A run of hot deliveries is a claim about one continuous gesture. Two unrelated
    /// stalls, one per drag, must not add up to evidence neither of them is.
    func testTheHandComingUpForgetsAnUnfinishedRunOfStalls() {
        var ladder = DraftLadder()
        let requested = 4096
        ladder.record(draftMilliseconds: 399, renderMilliseconds: 11,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        ladder.gestureEnded()
        ladder.record(draftMilliseconds: 399, renderMilliseconds: 11,
                      renderedLongEdge: ladder.longEdge(requested: requested),
                      requested: requested, allowStepUp: false)
        XCTAssertEqual(ladder.rung, 0,
                       "one stall in each of two drags is one stall in each of two drags")
    }

    /// Callers from before the split still mean what they said: with no separate render
    /// measurement the cost sample IS the render measurement, and one hot sample steps
    /// down immediately.
    func testACallerThatNamesNoRenderTimeIsTakenAtItsWord() {
        var ladder = DraftLadder()
        ladder.record(draftMilliseconds: 200,
                      renderedLongEdge: DraftLadder.rungs[0], requested: 4096)
        XCTAssertGreaterThan(ladder.rung, 0,
                             "an unqualified 200 ms frame is a 200 ms render")
    }

    // MARK: - Saturation, at both ends of the interval

    /// A HAND'S HESITATION IS NOT A RENDER COST.
    ///
    /// The interval runs from the previous frame's landing to this one's, and the
    /// viewer's saturation signal is read at the END of it. That alone admits the exact
    /// shape the owner's HUD reported: a pause mid-gesture with the button still down,
    /// then a hard resume, whose first frame is cancelled by the event behind it. The
    /// whole pause is then charged to the machine. All three of his samples — 285, 378,
    /// 399 ms — sit under `continuityCeilingMilliseconds`, in the band a hesitation
    /// occupies rather than the band a stall does.
    func testAPauseFollowedByAResumeIsNotSaturation() {
        XCTAssertFalse(DraftLadder.loopWasSaturated(thisFrameCancelled: true,
                                                    previousFrameCancelled: false),
                       "work queued behind this frame says nothing about whether any "
                           + "was queued when the interval opened")
    }

    /// The converse, which is the case the guard exists to admit: if the previous frame
    /// was itself cancelled, a newer request already existed when it landed, so this
    /// frame should have started immediately and the gap is the machine's.
    func testWorkQueuedAtBothEndsIsSaturation() {
        XCTAssertTrue(DraftLadder.loopWasSaturated(thisFrameCancelled: true,
                                                   previousFrameCancelled: true))
    }

    /// A frame with nothing queued behind it ends the run whatever came before, so the
    /// last frame of every gesture is never costed by its interval.
    func testTheLastFrameOfAGestureIsNeverSaturated() {
        XCTAssertFalse(DraftLadder.loopWasSaturated(thisFrameCancelled: false,
                                                    previousFrameCancelled: true))
        XCTAssertFalse(DraftLadder.loopWasSaturated(thisFrameCancelled: false,
                                                    previousFrameCancelled: false))
    }

    /// End to end: the owner's trace, through the guard that should have rejected it.
    /// A 399 ms hesitation reaches `costSample` as the render's own time, so the ladder
    /// sees an 11 ms frame and holds its rung.
    func testAHesitationReachesTheLadderAsTheRenderTimeAlone() {
        let saturated = DraftLadder.loopWasSaturated(thisFrameCancelled: true,
                                                     previousFrameCancelled: false)
        let sample = DraftLadder.costSample(renderMilliseconds: 11,
                                            sincePreviousFrameMilliseconds: 399,
                                            handWasWaiting: saturated)
        XCTAssertEqual(sample, 11, accuracy: 1e-9,
                       "the photographer's pause is not the machine's expense")
        var ladder = DraftLadder()
        ladder.record(draftMilliseconds: sample, renderMilliseconds: 11,
                      renderedLongEdge: ladder.longEdge(requested: 4096),
                      requested: 4096, allowStepUp: false)
        XCTAssertEqual(ladder.rung, 0, "and it costs no sharpness")
    }
}
