// SliderNudgeTests.swift
// What one arrow press is worth on a focused slider.
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
