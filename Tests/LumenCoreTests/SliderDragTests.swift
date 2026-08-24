// SliderDragTests.swift
// Whether a dropped gesture can explain a control that "does not work".
//
// The report this arbitrates: Highlights, Whites and Blacks were called dead after a
// session in which they read 2, 11 and −7 on ±100 tracks. The offered explanation was
// that the interface had eaten most of the drag. These tests take that seriously
// enough to check it, and it does not survive: a relative drag reads the pointer's
// CURRENT offset from the press, so no number of dropped interior samples can shrink
// what a gesture is worth.
//
// What they do pin is the one way a gesture CAN come up short — a final position that
// is never delivered as a sample — and the fix for it, which is that the release is a
// sample too.

import XCTest
@testable import LumenCore

final class SliderDragTests: XCTestCase {

    /// A ±100 tone control on a track the width the develop column actually affords:
    /// 320 points of panel, less the 78-point label, the 52-point readout and the gaps.
    private var toneTrack: SliderTrack {
        SliderTrack(width: 158, lowerBound: -100, upperBound: 100, step: 1)
    }

    // MARK: The theory under test

    func testDroppingEveryInteriorSampleOfADragChangesNothing() {
        // The whole gesture, then the same gesture with all but the last sample thrown
        // away, then only the last sample. One value.
        let track = toneTrack
        let everySample: [Double] = stride(from: 0.0, through: 79.0, by: 1.0).map { $0 }
        let full = SliderDrag.outcome(track: track, from: 0, delivered: everySample)
        let decimated = SliderDrag.outcome(track: track, from: 0,
                                           delivered: everySample.filter {
                                               $0.truncatingRemainder(dividingBy: 10) == 0
                                                   || $0 == 79
                                           })
        let lastOnly = SliderDrag.outcome(track: track, from: 0, delivered: [79])

        XCTAssertEqual(full, decimated)
        XCTAssertEqual(full, lastOnly)
        XCTAssertEqual(full, 100, "79 points of a 158-point track is half the span")
    }

    func testATinyValueMeansATinyGestureAndNotALostOne() {
        // The arithmetic that refutes the theory, stated as the numbers from the
        // screenshot. Two units on this track is a pointer that moved a point and a
        // half. Eleven is under nine points. Whatever produced those values, it was not
        // a full-travel drag whose middle went missing — a drag that reached the end of
        // the track and lost every sample but one still reports the end of the track.
        let track = toneTrack
        XCTAssertLessThan(abs(track.travelNeeded(from: 0, to: 2)), 5)
        XCTAssertLessThan(abs(track.travelNeeded(from: 0, to: 11)), 12)
        XCTAssertLessThan(abs(track.travelNeeded(from: 0, to: -7)), 8)
        // And what a real full-travel drag costs, for contrast.
        XCTAssertGreaterThan(track.travelNeeded(from: 0, to: 100), 70)
    }

    func testTheSameHoldsForEveryPlausibleTrackWidth() {
        // Not an artefact of guessing the panel's layout. On any track from a cramped
        // 100 points to a wide 400, reaching the top of a ±100 control costs at least a
        // quarter of the track, and landing on 2 costs less than a tenth of it.
        for width in stride(from: 100.0, through: 400.0, by: 20.0) {
            let track = SliderTrack(width: width, lowerBound: -100, upperBound: 100,
                                    step: 1)
            XCTAssertGreaterThanOrEqual(track.travelNeeded(from: 0, to: 100), width / 4)
            XCTAssertLessThan(abs(track.travelNeeded(from: 0, to: 2)), width / 10)
            // The property itself, at every width: only the last sample is read.
            XCTAssertEqual(SliderDrag.outcome(track: track, from: 0,
                                              delivered: [1, 5, 20, width / 2]),
                           SliderDrag.outcome(track: track, from: 0,
                                              delivered: [width / 2]))
        }
    }

    // MARK: The way a gesture CAN come up short

    func testAGestureWhoseLastSampleNeverArrivesStopsWhereItWasLeft() {
        // The failure mode that is real. If the samples stop coming at 20 points and
        // the pointer travels on to 79 before the button comes up, the control holds
        // the value 20 points was worth — unless the release itself is read.
        let track = toneTrack
        let stalled = SliderDrag.outcome(track: track, from: 0, delivered: [5, 12, 20])
        XCTAssertNotEqual(stalled, 100)
        XCTAssertEqual(stalled, track.value(from: 0, travelled: 20))
    }

    func testTheReleaseCarriesTheGestureToWhereThePointerActuallyIs() {
        // The fix, as arithmetic: a release is a sample, and it is the last one. Read
        // it, and a gesture whose every motion sample was dropped still lands under the
        // cursor. Ignore it — which is what the viewer's slider did, its `onEnded`
        // setting a flag and never looking at the location — and the value a drag is
        // worth depends on whether a motion event happened to beat the mouse-up.
        let track = toneTrack
        let released = SliderDrag.endedValue(track: track, from: 0, travelled: 79)
        XCTAssertEqual(released, 100)
        XCTAssertEqual(released,
                       SliderDrag.outcome(track: track, from: 0, delivered: [79]),
                       "a release must resolve exactly like any other sample")
    }

    func testTheReleaseIsWorthTheSameWhicheverSamplesPrecededIt() {
        let track = toneTrack
        let ended = SliderDrag.endedValue(track: track, from: 0, travelled: 40)
        XCTAssertEqual(SliderDrag.outcome(track: track, from: 0,
                                          delivered: [3, 9, 25, 40]), ended)
        XCTAssertEqual(SliderDrag.outcome(track: track, from: 0, delivered: [40]), ended)
    }

    // MARK: The arithmetic itself

    func testADragAcrossTheWholeTrackCoversTheWholeRange() {
        let track = toneTrack
        XCTAssertEqual(track.value(from: -100, travelled: track.width), 100)
        XCTAssertEqual(track.value(from: 100, travelled: -track.width), -100)
    }

    func testTheValueIsClampedToTheSoftRangeAndThenSnappedToTheStep() {
        // The control clamps and then snaps, in that order, and a model that rounds
        // differently from the control is not a model of it.
        let track = toneTrack
        XCTAssertEqual(track.value(from: 0, travelled: 10_000), 100)
        XCTAssertEqual(track.value(from: 0, travelled: -10_000), -100)

        let fine = SliderTrack(width: 158, lowerBound: -5, upperBound: 5, step: 0.01)
        let value = fine.value(from: 0, travelled: 1)
        XCTAssertEqual(value, (value / 0.01).rounded() * 0.01, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(value, 5)
    }

    func testAPressOnTheTrackLandsWhereItWasPressed() {
        // The one absolute step in the gesture: pressing the bare track jumps once, and
        // everything after that is relative to the press. Without the jump a click on
        // the track does nothing at all.
        let track = toneTrack
        XCTAssertEqual(track.valueAtPress(x: 0), -100)
        XCTAssertEqual(track.valueAtPress(x: track.width), 100)
        XCTAssertEqual(track.valueAtPress(x: track.width / 2), 0)
    }

    func testGrabbingTheThumbIsWiderThanTheThumbIsDrawn() {
        // Aiming at a nine-point circle and missing costs the value jumping, so the
        // grab region is deliberately larger than the target.
        XCTAssertTrue(SliderDrag.grabsThumb(pressX: 100, thumbX: 100))
        XCTAssertTrue(SliderDrag.grabsThumb(pressX: 110, thumbX: 100))
        XCTAssertFalse(SliderDrag.grabsThumb(pressX: 130, thumbX: 100))
        XCTAssertGreaterThan(SliderDrag.thumbGrabRadius, 9 / 2)
    }

    // MARK: Degenerate inputs

    func testATrackThatHasNotBeenLaidOutYetHoldsTheValueRatherThanDividingByZero() {
        let unlaid = SliderTrack(width: 0, lowerBound: -100, upperBound: 100, step: 1)
        XCTAssertFalse(unlaid.isUsable)
        XCTAssertEqual(unlaid.value(from: 42, travelled: 500), 42)
        XCTAssertEqual(unlaid.travelNeeded(from: 0, to: 100), 0)
    }

    func testANonFiniteTravelCannotReachTheValue() {
        // A NaN in a recipe is not a bad render, it is data loss: the canonical JSON
        // refuses non-conforming floats and collapses, and the collapsed recipe is what
        // reaches the sidecar. Nothing from a gesture may become one.
        let track = toneTrack
        XCTAssertEqual(track.value(from: 12, travelled: .nan), 12)
        XCTAssertEqual(track.value(from: 12, travelled: .infinity), 12)
        XCTAssertTrue(track.value(from: 12, travelled: .nan).isFinite)
    }

    func testAZeroSpanRangeIsNotUsableAndIsNotDividedBy() {
        let flat = SliderTrack(width: 158, lowerBound: 3, upperBound: 3, step: 1)
        XCTAssertFalse(flat.isUsable)
        XCTAssertEqual(flat.value(from: 3, travelled: 40), 3)
    }
}
