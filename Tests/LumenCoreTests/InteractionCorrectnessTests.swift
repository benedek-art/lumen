// InteractionCorrectnessTests.swift
// Regressions for three interaction defects: a drag that evicted a typed hard-range
// value, a curve placement whose undo key a later placement could reuse, and a brush
// stabilizer whose rope was shorter along a non-square frame's short axis.

import XCTest
@testable import LumenCore

final class InteractionCorrectnessTests: XCTestCase {

    // MARK: - A drag must not evict a value typed past the soft limit

    /// Exposure: soft ±5 (the track), hard ±10 (typing). −8 is legal, and pressing the
    /// thumb without moving used to commit −5: three stops from a gesture worth nothing.
    func testADragOnAHardRangeValueStartsFromItRatherThanFromTheSoftLimit() {
        let track = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        // Pressing the thumb without moving is worth nothing.
        XCTAssertEqual(track.value(from: -8, travelled: 0), -8)
        XCTAssertEqual(SliderDrag.endedValue(track: track, from: -8, travelled: 0), -8)
        XCTAssertEqual(SliderDrag.outcome(track: track, from: -8, delivered: [0]), -8)
        // The gearbox the view actually uses.
        let gear = FineDrag(startValue: -8)
        XCTAssertEqual(gear.resolving(track: track, travelled: 0, fine: false).value, -8)
        var fine = FineDrag(startValue: -8)
        XCTAssertEqual(fine.value(track: track, travelled: 0, fine: true), -8)
        // A small inward drag moves in proportion to the travel, starting from −8.
        XCTAssertEqual(track.value(from: -8, travelled: 14.2), -7, accuracy: 1e-9)
        // Outward travel holds the value (nudged's rule) rather than pushing it further.
        XCTAssertEqual(track.value(from: -8, travelled: -50), -8)
        // A long inward drag can bring it home, and still stops at the far soft limit.
        XCTAssertEqual(track.value(from: -8, travelled: 142), 2, accuracy: 1e-9)
        XCTAssertEqual(track.value(from: -8, travelled: 10_000), 5)
        // The readout scrub: 3 pt on the 426 pt scrub track.
        let scrub = SliderTrack(width: 426, lowerBound: -5, upperBound: 5, step: 0.01)
        XCTAssertEqual(scrub.value(from: -8, travelled: 3), -7.93, accuracy: 1e-9)
        // The other side.
        XCTAssertEqual(track.value(from: 8, travelled: 0), 8)
        XCTAssertEqual(track.value(from: 8, travelled: 50), 8)
    }

    func testAHardRangeValueOnTheReciprocalAxisIsHeldToo() {
        let temp = SliderTrack(width: 142, lowerBound: 2000, upperBound: 50000, step: 10,
                               scale: .reciprocal)
        XCTAssertEqual(temp.value(from: 1800, travelled: 0), 1800, accuracy: 1e-6)
        XCTAssertEqual(temp.value(from: 1800, travelled: -40), 1800, accuracy: 1e-6)
        let moved = temp.value(from: 1800, travelled: 5)
        XCTAssertGreaterThan(moved, 1800)
        XCTAssertTrue(moved.isFinite)
    }

    /// Values inside the soft range behave exactly as before.
    func testADragInsideTheSoftRangeIsUnchanged() {
        let track = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        XCTAssertEqual(track.value(from: 0, travelled: 0), 0)
        XCTAssertEqual(track.value(from: 4, travelled: 1000), 5)
        XCTAssertEqual(track.value(from: -4, travelled: -1000), -5)
        XCTAssertEqual(track.value(from: 12, travelled: .nan), 5)
    }
}
