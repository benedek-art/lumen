// SliderNudgeTests.swift
// What one arrow press is worth on a focused slider — and, at the foot of the file, what
// one click of a wheel is worth on a slider that is merely under the pointer.
//
// The nudge is the last item on D45's list of deliberate omissions, and it was omitted
// for a reason that had nothing to do with arithmetic: the arrows already mean "previous
// / next photo", claimed by a dispatcher whose NSEvent monitor sits in FRONT of the
// responder chain, so a focused slider would never have seen one. docs/28 Phase 7 clears
// that; this file pins what happens once the key arrives.
//
// Denominated in STEPS rather than points, because a key press has no pointer behind it
// and the step is the smallest move a slider can distinguish anyway — the drag snaps to
// it, so a finer nudge would be a key that appears to do nothing.

import XCTest
@testable import LumenCore

final class SliderNudgeTests: XCTestCase {

    /// A ±100 tone control, step 1, on the develop column's track.
    private var tone: SliderTrack {
        SliderTrack(width: 142, lowerBound: -100, upperBound: 100, step: 1)
    }

    /// Exposure: ±5 EV in hundredths, where the step is far finer than a pixel of track.
    private var exposure: SliderTrack {
        SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
    }

    // MARK: One press is one step

    func testOnePressMovesOneStep() {
        XCTAssertEqual(tone.nudged(0, steps: 1), 1)
        XCTAssertEqual(tone.nudged(0, steps: -1), -1)
        XCTAssertEqual(tone.nudged(42, steps: 1), 43)
    }

    func testOnePressOnAFinelySteppedControlMovesOneOfITSSteps() {
        // The case that makes the nudge worth having. One point of track is ~0.07 EV
        // here, so the drag cannot address a hundredth at all; the key can.
        XCTAssertEqual(tone.nudged(0, steps: 1), 1)
        XCTAssertEqual(exposure.nudged(0, steps: 1), 0.01, accuracy: 1e-12)
        XCTAssertEqual(exposure.nudged(1.23, steps: 1), 1.24, accuracy: 1e-12)
    }

    func testShiftIsTenPressesAndNotADifferentRule() {
        // ⇧ multiplies the count; it does not switch to another quantum. So ten single
        // presses and one shifted press must land on the same number.
        var walked = 0.0
        for _ in 0..<10 { walked = tone.nudged(walked, steps: 1) }
        XCTAssertEqual(tone.nudged(0, steps: 10), walked)

        var fine = 0.0
        for _ in 0..<10 { fine = exposure.nudged(fine, steps: 1) }
        XCTAssertEqual(exposure.nudged(0, steps: 10), fine, accuracy: 1e-9)
    }

    func testZeroPressesIsStillNormalised() {
        // Not a no-op: a value that arrived off-step from somewhere else comes back on
        // it, which is the same thing every other entry point does.
        XCTAssertEqual(tone.nudged(42.4, steps: 0), 42)
        XCTAssertEqual(tone.nudged(500, steps: 0), 100)
    }

    // MARK: It pins at the SOFT range, like a drag and unlike typing

    func testItPinsAtTheSoftLimitRatherThanRunningPast() {
        XCTAssertEqual(tone.nudged(100, steps: 1), 100)
        XCTAssertEqual(tone.nudged(-100, steps: -1), -100)
        XCTAssertEqual(tone.nudged(99, steps: 10), 100)
    }

    func testLeaningOnTheKeyCannotWalkPastTheEnd() {
        var value = 0.0
        for _ in 0..<500 { value = tone.nudged(value, steps: 1) }
        XCTAssertEqual(value, 100)
        for _ in 0..<500 { value = tone.nudged(value, steps: -1) }
        XCTAssertEqual(value, -100)
    }

    // MARK: The result is always a value a recipe can hold

    func testEveryNudgeLandsOnAStep() {
        var value = -100.0
        for _ in 0..<200 {
            value = tone.nudged(value, steps: 1)
            XCTAssertEqual(value, value.rounded(), accuracy: 1e-12,
                           "\(value) is not on the step")
        }
    }

    func testANonFiniteValueIsHeldRatherThanPropagated() {
        // A NaN in a recipe is data loss, not a bad render: the canonical JSON refuses
        // non-conforming floats and collapses, and the collapsed recipe is what reaches
        // the sidecar.
        XCTAssertTrue(tone.nudged(.nan, steps: 1).isNaN,
                      "held, not converted — the caller's guard is what refuses it")
        XCTAssertFalse(tone.nudged(.infinity, steps: 1).isFinite)
        // What must never happen is a finite input becoming non-finite.
        for start in [-100.0, -1, 0, 1, 100] {
            XCTAssertTrue(tone.nudged(start, steps: 1).isFinite)
            XCTAssertTrue(tone.nudged(start, steps: -10).isFinite)
        }
    }

    func testATrackThatHasNotBeenLaidOutYetStillNormalisesTheValue() {
        // Width is a drag's denominator and a nudge has no denominator, so an unlaid
        // track is not a reason to refuse the key — but it is a reason not to trust any
        // arithmetic that divides by width. Clamp and snap still apply.
        let unlaid = SliderTrack(width: 0, lowerBound: -100, upperBound: 100, step: 1)
        XCTAssertFalse(unlaid.isUsable)
        XCTAssertEqual(unlaid.nudged(42.4, steps: 5), 42)
        XCTAssertEqual(unlaid.nudged(500, steps: 1), 100)
    }

    func testAZeroSpanRangeIsNotWalkedOffItsOneValue() {
        let flat = SliderTrack(width: 142, lowerBound: 3, upperBound: 3, step: 1)
        XCTAssertEqual(flat.nudged(3, steps: 10), 3)
        XCTAssertEqual(flat.nudged(3, steps: -10), 3)
    }

    // MARK: The non-linear axis

    func testTempNudgesInKELVINRatherThanInTrackPosition() {
        // Temp's track is the mired axis, but its STEP is 10 K and a key press is
        // denominated in steps. So an arrow moves 10 K wherever you are on the axis —
        // which is the honest reading of "one step" and, unlike the drag, is the same
        // size at both ends.
        let temp = SliderTrack(width: 142, lowerBound: 2000, upperBound: 50000,
                               step: 10, scale: .reciprocal)
        XCTAssertEqual(temp.nudged(5500, steps: 1), 5510)
        XCTAssertEqual(temp.nudged(40000, steps: 1), 40010)
        XCTAssertEqual(temp.nudged(2000, steps: -1), 2000)
        XCTAssertEqual(temp.nudged(50000, steps: 1), 50000)
    }
}

// MARK: - The wheel

/// The nudge's second input device (docs/28 Phase 6 item 26).
///
/// ⌥-scroll reaches `SliderTrack.nudged` above, so everything that file pins about what a
/// step is worth is already true of it. What is NEW, and what this class is for, is
/// getting from a scroll event to a number of steps at all: a wheel reports discrete
/// lines and a trackpad reports continuous points, neither of them says where the gesture
/// started, and a reading that discards the travel between two whole steps leaves a slow
/// scroll doing nothing whatsoever.
final class ScrollNudgeTests: XCTestCase {

    /// AppKit's `hasPreciseScrollingDeltas`, named at the call site so each test says
    /// which instrument it is describing.
    private let trackpad = true
    private let wheel = false

    // MARK: One click of a wheel is one press of an arrow

    func testOneWheelLineIsExactlyOneStep() {
        // The equivalence the whole feature is built on: the wheel is the arrow key you
        // do not have to focus the row to use.
        var nudge = ScrollNudge()
        XCTAssertEqual(nudge.steps(scrolling: 1, precise: wheel), 1)
        XCTAssertEqual(nudge.steps(scrolling: -1, precise: wheel), -1)
    }

    func testAWheelLeavesNothingBankedBetweenClicks() {
        // A wheel's delta converts to a whole number of steps, so ten separate clicks and
        // ten clicks in a row must be identical — no residue can survive one of them to
        // make the next arrive early.
        var separate = ScrollNudge()
        var total = 0
        for _ in 0..<10 { total += separate.steps(scrolling: 1, precise: wheel) }
        XCTAssertEqual(total, 10)

        var atOnce = ScrollNudge()
        XCTAssertEqual(atOnce.steps(scrolling: 10, precise: wheel), 10)
    }

    // MARK: A scroll chopped up differently is worth the same

    func testTheSameTravelIsTheSameNumberOfStepsHoweverItIsDelivered() {
        // The scroll's version of the dropped-sample rule `SliderDragTests` is about. A
        // drag gets it for free by being absolute; a scroll has to earn it by carrying
        // the remainder.
        let travel = 20 * ScrollNudge.pointsPerStep
        for chunk in [1.0, 2, 3, 5, 8, 40, travel] {
            var nudge = ScrollNudge()
            var steps = 0
            var delivered = 0.0
            while delivered < travel {
                let next = Swift.min(chunk, travel - delivered)
                steps += nudge.steps(scrolling: next, precise: trackpad)
                delivered += next
            }
            XCTAssertEqual(steps, 20,
                           "\(travel) points delivered \(chunk) at a time was worth "
                               + "\(steps) steps, not 20")
        }
    }

    func testAScrollTooGentleToEarnAStepIsBankedRatherThanDiscarded() {
        // The defect this prevents is the loud one: a trackpad delivers two or three
        // points per event, every one of them rounds to nothing, and the control appears
        // not to answer the wheel at all.
        var nudge = ScrollNudge()
        var steps = 0
        for _ in 0..<Int(ScrollNudge.pointsPerStep) {
            steps += nudge.steps(scrolling: 1, precise: trackpad)
        }
        XCTAssertEqual(steps, 1, "eight banked points must eventually earn their step")
    }

    func testScrollingBackCancelsScrollingForward() {
        var nudge = ScrollNudge()
        XCTAssertEqual(nudge.steps(scrolling: ScrollNudge.pointsPerStep / 2,
                                   precise: trackpad), 0)
        XCTAssertEqual(nudge.steps(scrolling: -ScrollNudge.pointsPerStep / 2,
                                   precise: trackpad), 0)
        // The bank is empty again, so a full step's travel is worth exactly one step and
        // not two.
        XCTAssertEqual(nudge.steps(scrolling: ScrollNudge.pointsPerStep,
                                   precise: trackpad), 1)
    }

    func testDirectionIsSignPreservingInBothInstruments() {
        for precise in [true, false] {
            var nudge = ScrollNudge()
            let unit = precise ? ScrollNudge.pointsPerStep : 1
            XCTAssertGreaterThan(nudge.steps(scrolling: unit * 3, precise: precise), 0)
            XCTAssertLessThan(nudge.steps(scrolling: -unit * 3, precise: precise), 0)
        }
    }

    // MARK: A new gesture starts from nothing

    func testBeginningAGestureDropsTheRemainderOfTheLastOne() {
        // Only a trackpad can say a gesture began. Without honouring it, a few points
        // left over from the last flick fire the first step of the next one early —
        // which reads as a control that moves before the hand does.
        var nudge = ScrollNudge()
        XCTAssertEqual(nudge.steps(scrolling: ScrollNudge.pointsPerStep - 1,
                                   precise: trackpad), 0)
        nudge.beginGesture()
        XCTAssertEqual(nudge.steps(scrolling: 1, precise: trackpad), 0,
                       "one point after a fresh start is one point, not a whole step")
    }

    // MARK: What a bad event costs

    func testANonFiniteDeltaIsRefusedRatherThanPoisoningTheBank() {
        // NaN in the accumulator is permanent, and a control that silently stops
        // answering the wheel until its panel is rebuilt is a defect nobody would think
        // to report as one.
        var nudge = ScrollNudge()
        XCTAssertEqual(nudge.steps(scrolling: .nan, precise: trackpad), 0)
        XCTAssertEqual(nudge.steps(scrolling: .infinity, precise: trackpad), 0)
        XCTAssertEqual(nudge.steps(scrolling: -.infinity, precise: wheel), 0)
        XCTAssertEqual(nudge.steps(scrolling: ScrollNudge.pointsPerStep,
                                   precise: trackpad), 1,
                       "the bank must still work afterwards")
    }

    func testAnAbsurdDeltaCannotTrapTheIntegerConversion() {
        // `Int(_:)` traps on a value it cannot represent rather than saturating, so the
        // conversion is guarded instead of trusted. No hand produces this; a broken
        // driver might.
        var nudge = ScrollNudge()
        XCTAssertEqual(nudge.steps(scrolling: 1e300, precise: trackpad), 0)
        XCTAssertEqual(nudge.steps(scrolling: ScrollNudge.pointsPerStep,
                                   precise: trackpad), 1)
    }

    // MARK: The magnitude, as a statement about the hand

    func testAComfortableSwipeIsATweakAndNotAJourney() {
        // The taste call, written down so a change to `pointsPerStep` has to argue with
        // it: about 150 points of scrolling — one unhurried two-finger swipe — should be
        // worth a tweak on a ±100 control, not a traversal of it.
        var nudge = ScrollNudge()
        let steps = nudge.steps(scrolling: 150, precise: trackpad)
        XCTAssertGreaterThan(steps, 8)
        XCTAssertLessThan(steps, 40)

        let tone = SliderTrack(width: 142, lowerBound: -100, upperBound: 100, step: 1)
        let landed = tone.nudged(0, steps: steps)
        XCTAssertLessThan(abs(landed), 40, "one swipe must not cross the range")

        // The same swipe on Exposure, whose step is a hundredth of a stop: a fifth of a
        // stop, which is the size of adjustment the wheel exists for.
        let exposure = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        XCTAssertEqual(exposure.nudged(0, steps: steps), 0.19, accuracy: 0.06)
    }
}
