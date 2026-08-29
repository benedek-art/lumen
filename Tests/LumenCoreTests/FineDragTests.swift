// FineDragTests.swift
// ⇧ makes a drag fine, and the whole difficulty is that it may be pressed and released
// in the middle of one.
//
// `SliderTrack.value(from:travelled:)` reads the pointer's CURRENT offset from the press
// — absolutely, with no accumulator — and that is exactly the property that makes a
// dropped motion sample harmless (`SliderDragTests` is mostly about it). Multiplying
// that absolute offset the instant ⇧ goes down also multiplies the travel already spent,
// so the thumb snaps back to a quarter of where the hand had taken it and snaps forward
// again on release. These tests pin the fix — an anchor that moves only when the
// modifier does — and, just as importantly, that the fix did not cost the property it
// was built around.

import XCTest
@testable import LumenCore

final class FineDragTests: XCTestCase {

    private var track: SliderTrack {
        SliderTrack(width: 142, lowerBound: -100, upperBound: 100, step: 1)
    }

    // MARK: The gear change is worth nothing

    func testPressingShiftMidDragDoesNotMoveTheValue() {
        var drag = FineDrag(startValue: 0)
        let before = drag.value(track: track, travelled: 30, fine: false)
        let after = drag.value(track: track, travelled: 30, fine: true)
        XCTAssertEqual(before, after,
                       "the thumb must not jump at the moment the modifier goes down")
    }

    func testReleasingShiftMidDragDoesNotMoveTheValueEither() {
        var drag = FineDrag(startValue: 0)
        _ = drag.value(track: track, travelled: 20, fine: false)
        let fine = drag.value(track: track, travelled: 50, fine: true)
        let coarse = drag.value(track: track, travelled: 50, fine: false)
        XCTAssertEqual(fine, coarse)
    }

    func testShiftCanBeTappedRepeatedlyWithoutTheValueDrifting() {
        // The failure this would most plausibly ship with: a rebase that is very
        // slightly lossy, so twenty taps walk the value away from under the cursor.
        var drag = FineDrag(startValue: 0)
        let settled = drag.value(track: track, travelled: 40, fine: false)
        for i in 0..<20 {
            XCTAssertEqual(drag.value(track: track, travelled: 40, fine: i % 2 == 0),
                           settled, "drifted on toggle \(i)")
        }
    }

    // MARK: Fine is finer, and by the stated amount

    func testFineTravelIsWorthAQuarterOfCoarseTravel() {
        var coarse = FineDrag(startValue: 0)
        var fine = FineDrag(startValue: 0, fine: true)
        let c = coarse.value(track: track, travelled: 40, fine: false)
        let f = fine.value(track: track, travelled: 40, fine: true)
        XCTAssertEqual(f, c * FineDrag.scale, accuracy: 1)
        XCTAssertLessThan(abs(f), abs(c))
    }

    func testFineTravelAfterAGearChangeIsMeasuredFromTheChangeAndNotFromThePress() {
        // 30 points coarse, then 40 more points fine, is 30 points' worth plus a
        // quarter of 40 — NOT a quarter of 70.
        //
        // The middle line is the one that matters and it is not ceremony: the gear
        // changes at the sample that first REPORTS it, and the pointer is at 30 points
        // when ⇧ goes down. Deliver the change only at 70 and the answer is 70 points'
        // worth, correctly — everything up to the modifier is coarse travel.
        var drag = FineDrag(startValue: 0)
        _ = drag.value(track: track, travelled: 30, fine: false)
        _ = drag.value(track: track, travelled: 30, fine: true)
        let mixed = drag.value(track: track, travelled: 70, fine: true)

        let coarsePart = track.value(from: 0, travelled: 30)
        let expected = track.value(from: coarsePart, travelled: 40 * FineDrag.scale)
        XCTAssertEqual(mixed, expected, accuracy: 1e-9)

        var wholeGestureFine = FineDrag(startValue: 0, fine: true)
        let allFine = wholeGestureFine.value(track: track, travelled: 70, fine: true)
        XCTAssertNotEqual(mixed, allFine,
                          "a gear change must not retroactively rescale earlier travel")
    }

    func testFineStillReachesTheEndOfTheTrackWithinOneGesture() {
        // A quarter is a taste call, and the reason it is a quarter rather than a
        // tenth: a full-travel fine drag has to stay possible in one hand movement.
        var drag = FineDrag(startValue: 0, fine: true)
        let value = drag.value(track: track, travelled: track.width * 4, fine: true)
        XCTAssertEqual(value, 100)
    }

    // MARK: What must NOT have changed

    func testWithoutTheModifierItIsExactlyTheOrdinaryDrag() {
        // The view uses this type on every drag, not only shifted ones, so a coarse
        // gesture through `FineDrag` and through `SliderTrack` directly must be the
        // same number at every sample.
        var drag = FineDrag(startValue: 12)
        for travelled in stride(from: -200.0, through: 200.0, by: 7.0) {
            XCTAssertEqual(drag.value(track: track, travelled: travelled, fine: false),
                           track.value(from: 12, travelled: travelled),
                           "diverged at \(travelled)")
        }
    }

    func testDroppedSamplesStillDoNotChangeWhereACoarseDragLands() {
        // The property `SliderDragTests` exists to defend, re-checked through the new
        // type: every sample is resolved from the pointer's current position, so the
        // interior of a gesture can be thrown away.
        var every = FineDrag(startValue: 0)
        var last = FineDrag(startValue: 0)
        for t in stride(from: 0.0, through: 79.0, by: 1.0) {
            _ = every.value(track: track, travelled: t, fine: false)
        }
        let full = every.value(track: track, travelled: 79, fine: false)
        XCTAssertEqual(full, last.value(track: track, travelled: 79, fine: false))
    }

    func testDroppedSamplesDoNotChangeAFINEDragEitherOnceTheGearIsSet() {
        // Weaker than the coarse case and honestly so: the anchor is set by the FIRST
        // sample that reports the new gear, so which sample that is does matter. What
        // must hold is that samples after the gear change can be dropped freely.
        var every = FineDrag(startValue: 0)
        var sparse = FineDrag(startValue: 0)
        _ = every.value(track: track, travelled: 10, fine: true)
        _ = sparse.value(track: track, travelled: 10, fine: true)
        for t in stride(from: 11.0, through: 90.0, by: 1.0) {
            _ = every.value(track: track, travelled: t, fine: true)
        }
        XCTAssertEqual(every.value(track: track, travelled: 90, fine: true),
                       sparse.value(track: track, travelled: 90, fine: true))
    }

    // MARK: What the view actually calls, and why the shape is odd

    func testResolvingReportsNothingToStoreWhileTheGearIsUnchanged() {
        // THE PERFORMANCE PROPERTY, and it is the reason `resolving` exists beside the
        // mutating form. In SwiftUI a `@State` write is a view invalidation, so a slider
        // storing a gearbox on every mouse event would publish on every event of every
        // drag — including the majority that do not move the value, because the pointer
        // has not crossed a step. That is exactly the per-event cost `CommandState` and
        // `EditRevision` exist to keep off this path.
        let drag = FineDrag(startValue: 0)
        for travelled in stride(from: 0.0, through: 120.0, by: 1.0) {
            let out = drag.resolving(track: track, travelled: travelled, fine: false)
            XCTAssertNil(out.changedGear,
                         "a coarse sample at \(travelled) asked to be stored")
        }
    }

    func testResolvingReportsAReplacementExactlyWhenTheGearMoves() {
        let coarse = FineDrag(startValue: 0)
        let toFine = coarse.resolving(track: track, travelled: 30, fine: true)
        let gearbox = try? XCTUnwrap(toFine.changedGear)
        XCTAssertNotNil(gearbox, "the gear changed and nothing was handed back to store")

        // And the replacement then reports nothing to store while ⇧ stays down.
        guard let gearbox else { return }
        for travelled in stride(from: 31.0, through: 90.0, by: 1.0) {
            XCTAssertNil(gearbox.resolving(track: track, travelled: travelled,
                                           fine: true).changedGear)
        }
    }

    func testResolvingAndTheMutatingFormAgreeAtEverySample() {
        // Two entry points, one answer — otherwise the tests above would be measuring a
        // different drag from the one the app runs.
        var mutating = FineDrag(startValue: 0)
        var stored = FineDrag(startValue: 0)
        for (i, travelled) in stride(from: 0.0, through: 100.0, by: 3.0).enumerated() {
            let fine = (i / 4) % 2 == 1
            let a = mutating.value(track: track, travelled: travelled, fine: fine)
            let out = stored.resolving(track: track, travelled: travelled, fine: fine)
            if let changed = out.changedGear { stored = changed }
            XCTAssertEqual(a, out.value, "diverged at \(travelled), fine: \(fine)")
        }
    }

    // MARK: The detent, which must tick once rather than rumble

    func testCrossingTheDetentIsTrueForExactlyOneSampleOfASlowDrag() {
        // The property a proximity test cannot have, and the reason this is a crossing
        // test. Walk one step at a time through zero and count the ticks.
        var ticks = 0
        var previous = -5.0
        for value in stride(from: -5.0, through: 5.0, by: 1.0) {
            if SliderDrag.crossesDetent(from: previous, to: value, detent: 0) { ticks += 1 }
            previous = value
        }
        XCTAssertEqual(ticks, 1, "a walk through the detent must tick once")
    }

    func testLandingOnTheDetentTicksAndLeavingItDoesNot() {
        // Arriving is the event worth feeling. Ticking on departure too would make a
        // drag that stopped on zero buzz twice for one landmark.
        XCTAssertTrue(SliderDrag.crossesDetent(from: 3, to: 0, detent: 0))
        XCTAssertFalse(SliderDrag.crossesDetent(from: 0, to: 3, detent: 0))
        XCTAssertFalse(SliderDrag.crossesDetent(from: 0, to: -3, detent: 0))
    }

    func testSittingStillNeverTicks() {
        XCTAssertFalse(SliderDrag.crossesDetent(from: 0, to: 0, detent: 0))
        XCTAssertFalse(SliderDrag.crossesDetent(from: 7, to: 7, detent: 0))
    }

    func testAJumpRightOverTheDetentStillTicks() {
        // Events coalesce, so a fast drag can step from −40 to +40 in one sample. The
        // landmark was passed and the hand should be told.
        XCTAssertTrue(SliderDrag.crossesDetent(from: -40, to: 40, detent: 0))
        XCTAssertTrue(SliderDrag.crossesDetent(from: 40, to: -40, detent: 0))
    }

    func testADetentAwayFromZeroWorksTheSameWay() {
        // Temp's default is the photograph's as-shot neutral, which is 5500 K on almost
        // no camera; a detent hard-coded to zero would be a tick nobody ever feels.
        XCTAssertTrue(SliderDrag.crossesDetent(from: 5200, to: 5800, detent: 5500))
        XCTAssertFalse(SliderDrag.crossesDetent(from: 5600, to: 5800, detent: 5500))
    }

    func testMovingWhollyOnOneSideNeverTicks() {
        for a in stride(from: 1.0, through: 50.0, by: 3.0) {
            XCTAssertFalse(SliderDrag.crossesDetent(from: a, to: a + 2, detent: 0))
            XCTAssertFalse(SliderDrag.crossesDetent(from: -a, to: -a - 2, detent: 0))
        }
    }

    func testANonFiniteEndpointNeverTicks() {
        XCTAssertFalse(SliderDrag.crossesDetent(from: .nan, to: 1, detent: 0))
        XCTAssertFalse(SliderDrag.crossesDetent(from: -1, to: .nan, detent: 0))
        XCTAssertFalse(SliderDrag.crossesDetent(from: -1, to: 1, detent: .nan))
    }

    // MARK: Degenerate inputs

    func testANonFiniteTravelHoldsTheValueRatherThanPoisoningIt() {
        // A NaN in a recipe is data loss, not a bad render — the canonical JSON refuses
        // non-conforming floats and collapses, and the collapsed recipe reaches the
        // sidecar. Nothing from a gesture may become one.
        var drag = FineDrag(startValue: 12)
        XCTAssertEqual(drag.value(track: track, travelled: .nan, fine: false), 12)
        XCTAssertEqual(drag.value(track: track, travelled: .infinity, fine: true), 12)
        XCTAssertTrue(drag.value(track: track, travelled: .nan, fine: false).isFinite)
    }

    func testATrackThatHasNotBeenLaidOutYetHoldsTheValue() {
        let unlaid = SliderTrack(width: 0, lowerBound: -100, upperBound: 100, step: 1)
        var drag = FineDrag(startValue: 42)
        XCTAssertEqual(drag.value(track: unlaid, travelled: 500, fine: true), 42)
    }
}
