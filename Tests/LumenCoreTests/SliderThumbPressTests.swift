// SliderThumbPressTests.swift
// What picking a slider's thumb up and putting it down again, without moving it, is
// worth: nothing.
//
// The slider's drag gesture has a minimum distance of zero, so a plain click on the
// thumb is a gesture — it delivers one motion sample with zero travel and a release
// with zero travel, and both used to commit `value(from: start, travelled: 0)`. That
// was `snapped(clamped(start))`, not `start`. Two kinds of value are legitimately NOT
// on the soft-range step grid, and a click rewrote both:
//
//   - The as-shot white balance. The Temp row shows the camera's unrounded Kelvin
//     (5137.4 K) while `raw.temp` is nil; a click wrote 5150, which pins an override,
//     flips the preset menu to Custom, and freezes this photograph's neutral into a
//     recipe that may be copied onto another. Tint did the same with +7.3 → +7.
//   - A typed hard-range value. Type −8 into Exposure (the hard range is ±10) and the
//     thumb is drawn at the left end; click it and the value became −5 — three stops
//     from a gesture that did not move. `SliderTrack.nudged` already fixed exactly this
//     for arrows and the wheel (SliderNudgeTests); the drag never got the same rule.
//
// The contract pinned here is the one SliderDrag.swift's header states: a relative
// drag is a pure function of pointer travel, so zero travel is zero change. And the
// first REAL travel from a value outside the soft range moves it from where it is, by
// that travel, rather than first evicting it to the soft limit.

import XCTest
@testable import LumenCore

final class SliderThumbPressTests: XCTestCase {

    /// Temp: 2000…50000 K on the mired axis, step 50, on the develop column's track.
    private var temp: SliderTrack {
        SliderTrack(width: 142, lowerBound: 2000, upperBound: 50000, step: 50,
                    scale: .reciprocal)
    }

    /// Tint: soft ±150, step 1 (the hard range is ±300).
    private var tint: SliderTrack {
        SliderTrack(width: 142, lowerBound: -150, upperBound: 150, step: 1)
    }

    /// Exposure: soft ±5 EV in hundredths (the hard range is ±10).
    private var exposure: SliderTrack {
        SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
    }

    // MARK: Zero travel is zero change

    func testPressingTheThumbWithoutMovingChangesNothing() {
        // The as-shot readouts, which sit between steps.
        XCTAssertEqual(temp.value(from: 5137.4, travelled: 0), 5137.4)
        XCTAssertEqual(temp.value(from: 3226, travelled: 0), 3226)
        XCTAssertEqual(tint.value(from: 7.3, travelled: 0), 7.3)
        // Typed values, unsnapped by design.
        XCTAssertEqual(exposure.value(from: 0.333, travelled: 0), 0.333)
        // Typed values in the hard range, beyond the soft limit.
        XCTAssertEqual(exposure.value(from: -8, travelled: 0), -8)
        XCTAssertEqual(tint.value(from: -250, travelled: 0), -250)
    }

    func testTheReleaseOfAnUnmovedPressCommitsTheValueItFound() {
        // The release is a sample like any other, so it obeys the same rule.
        XCTAssertEqual(SliderDrag.endedValue(track: exposure, from: -8, travelled: 0), -8)
        XCTAssertEqual(SliderDrag.endedValue(track: temp, from: 5137.4, travelled: 0), 5137.4)
    }

    func testTheGearboxTheViewActuallyDrivesHoldsTheValueToo() {
        // LumenSlider resolves every sample through FineDrag, coarse or fine.
        var coarse = FineDrag(startValue: 5137.4)
        XCTAssertEqual(coarse.value(track: temp, travelled: 0, fine: false), 5137.4)
        var fine = FineDrag(startValue: -8, fine: true)
        XCTAssertEqual(fine.value(track: exposure, travelled: 0, fine: true), -8)
        // ⇧ going down before the pointer has moved rebases at the untouched value.
        var shifted = FineDrag(startValue: 7.3)
        XCTAssertEqual(shifted.value(track: tint, travelled: 0, fine: true), 7.3)
    }

    // MARK: A drag from beyond the soft limit starts from where the value is

    func testADragDoesNotDragAHardRangeValueBackToTheSoftLimit() {
        // One point of track is about 0.07 EV. From −8 that is −7.93 to the right and
        // −8.07 to the left would be PAST the value — held where it is, as `nudged`
        // holds it — not −4.93 after a three-stop eviction.
        let pt = exposure.span / exposure.width
        XCTAssertEqual(exposure.value(from: -8, travelled: 1), (-8 + pt * 1).rounded(toPlaces: 2),
                       accuracy: 1e-9)
        XCTAssertEqual(exposure.value(from: -8, travelled: -1), -8)
        XCTAssertEqual(tint.value(from: -250, travelled: -5), -250)
        XCTAssertEqual(tint.value(from: 250, travelled: 5), 250)
        // Inward travel still moves it, and enough of it still crosses the whole track.
        XCTAssertGreaterThan(tint.value(from: -250, travelled: 10), -250)
        XCTAssertEqual(exposure.value(from: -8, travelled: 10_000), 5)
    }

    func testAValueInsideTheSoftRangeStillCannotBeDraggedOutOfIt() {
        // The widening is only ever as far as the value already is.
        XCTAssertEqual(exposure.value(from: 4.9, travelled: 10_000), 5)
        XCTAssertEqual(exposure.value(from: -4.9, travelled: -10_000), -5)
        XCTAssertEqual(temp.value(from: 5000, travelled: 10_000), 50000)
        XCTAssertEqual(temp.value(from: 5000, travelled: -10_000), 2000)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = Foundation.pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
