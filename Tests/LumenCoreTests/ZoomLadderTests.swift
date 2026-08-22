// ZoomLadderTests.swift
// The zoom rung a key lands on, and whether that key anchors at the cursor.
//
// The defect this pins: `Space` set the zoom level directly from the keymap —
// `zoomLevel == 0 ? 1 : 0` — instead of calling the viewport verb documented as
// "Space: fit ↔ 1:1, centred on the cursor". Same two ratios, no anchor. It is the
// second time this exact bug shipped on a different key, which is why the rule is a
// value with tests now rather than a method three files reimplement.

import XCTest
@testable import LumenCore

final class ZoomLadderTests: XCTestCase {

    func testToggleGoesFitToOneToOneAndBack() {
        XCTAssertEqual(ZoomLadder.toggleTarget(from: ZoomLadder.fit), ZoomLadder.oneToOne)
        XCTAssertEqual(ZoomLadder.toggleTarget(from: ZoomLadder.oneToOne), ZoomLadder.fit)
    }

    func testToggleIsAWayOutOfEveryZoomedState() {
        // Not just a flip between two values: from 2:1, or from a ratio reached by
        // zoom-in steps, one press is still the way back to the whole frame.
        for zoomed in [ZoomLadder.twoToOne, 1.5, 4, 8, ZoomLadder.maximum] {
            XCTAssertEqual(ZoomLadder.toggleTarget(from: zoomed), ZoomLadder.fit,
                           "toggling from \(zoomed) did not return to fit")
        }
    }

    func testZoomingInAnchorsAtTheCursorAndFittingDoesNot() {
        // This is the half of the verb the keymap skipped. Fit centres the frame, so
        // there is nothing to hold under the pointer; every other rung has to keep what
        // was under the cursor under the cursor.
        XCTAssertTrue(ZoomLadder.anchorsAtCursor(
            target: ZoomLadder.toggleTarget(from: ZoomLadder.fit)))
        XCTAssertFalse(ZoomLadder.anchorsAtCursor(
            target: ZoomLadder.toggleTarget(from: ZoomLadder.oneToOne)))
        for target in [ZoomLadder.oneToOne, ZoomLadder.twoToOne, 1.25, 16] {
            XCTAssertTrue(ZoomLadder.anchorsAtCursor(target: target))
        }
        XCTAssertFalse(ZoomLadder.anchorsAtCursor(target: ZoomLadder.fit))
        XCTAssertFalse(ZoomLadder.anchorsAtCursor(target: -1))
        XCTAssertFalse(ZoomLadder.anchorsAtCursor(target: .nan))
    }

    func testTheCycleWalksTheLadderAndComesBack() {
        var ratio = ZoomLadder.fit
        var seen: [Double] = []
        for _ in 0..<6 {
            ratio = ZoomLadder.cycleTarget(from: ratio)
            seen.append(ratio)
        }
        XCTAssertEqual(seen, [1, 2, 0, 1, 2, 0])
    }

    func testTheCycleRecoversFromARatioThatIsNotOnTheLadder() {
        // Zoom-in steps can leave the ratio between rungs. The cycle key must still be
        // a way back onto the ladder rather than a key that does nothing.
        XCTAssertEqual(ZoomLadder.cycleTarget(from: 1.37), ZoomLadder.oneToOne)
        XCTAssertEqual(ZoomLadder.cycleTarget(from: 8), ZoomLadder.oneToOne)
    }

    func testZoomingInFromFitLandsOnOneToOneRatherThanTwiceNothing() {
        XCTAssertEqual(ZoomLadder.zoomInTarget(from: ZoomLadder.fit), ZoomLadder.oneToOne)
        XCTAssertEqual(ZoomLadder.zoomInTarget(from: 1), 2)
        XCTAssertEqual(ZoomLadder.zoomInTarget(from: 2), 4)
    }

    func testZoomingInStopsAtTheCeiling() {
        XCTAssertEqual(ZoomLadder.zoomInTarget(from: ZoomLadder.maximum),
                       ZoomLadder.maximum)
        XCTAssertEqual(ZoomLadder.zoomInTarget(from: 12), ZoomLadder.maximum)
    }

    func testZoomingOutSnapsToFitInsteadOfHalvingForever() {
        // The rule that made − a way back to the whole frame. Halving without it walks
        // 1 → 0.5 → 0.25 → 0.125 and the user is at 12% with no key that fixes it.
        XCTAssertEqual(ZoomLadder.zoomOutTarget(from: 1), 0.5)
        XCTAssertEqual(ZoomLadder.zoomOutTarget(from: 0.5), ZoomLadder.fit)
        XCTAssertEqual(ZoomLadder.zoomOutTarget(from: ZoomLadder.fit), ZoomLadder.fit)

        // And it terminates from anywhere on the ladder, in a bounded number of steps.
        var ratio = ZoomLadder.maximum
        var steps = 0
        while !ZoomLadder.isFit(ratio) && steps < 100 {
            ratio = ZoomLadder.zoomOutTarget(from: ratio)
            steps += 1
        }
        XCTAssertTrue(ZoomLadder.isFit(ratio), "zoom-out never reached fit")
        XCTAssertLessThan(steps, 10)
    }

    func testANonFiniteOrNegativeRatioBecomesFitRatherThanPropagating() {
        // `zoomLevel` feeds the drawn size and the pan clamp, and a NaN there is a
        // frame that does not draw.
        XCTAssertEqual(ZoomLadder.clamp(.nan), ZoomLadder.fit)
        XCTAssertEqual(ZoomLadder.clamp(.infinity), ZoomLadder.fit)
        XCTAssertEqual(ZoomLadder.clamp(-.infinity), ZoomLadder.fit)
        XCTAssertEqual(ZoomLadder.clamp(-3), ZoomLadder.fit)
        XCTAssertEqual(ZoomLadder.clamp(1000), ZoomLadder.maximum)
        XCTAssertEqual(ZoomLadder.clamp(1.5), 1.5)
        XCTAssertTrue(ZoomLadder.isFit(.nan))
        XCTAssertEqual(ZoomLadder.label(.nan), "FIT")
        XCTAssertEqual(ZoomLadder.toggleTarget(from: .nan), ZoomLadder.oneToOne)
    }

    func testTheBadgeNamesTheThreeRungsAndMeasuresTheRest() {
        XCTAssertEqual(ZoomLadder.label(ZoomLadder.fit), "FIT")
        XCTAssertEqual(ZoomLadder.label(ZoomLadder.oneToOne), "1:1")
        XCTAssertEqual(ZoomLadder.label(ZoomLadder.twoToOne), "2:1")
        XCTAssertEqual(ZoomLadder.label(1.5), "150%")
        XCTAssertEqual(ZoomLadder.label(8), "800%")
    }

    func testEveryLadderRungIsReachableAndLabelled() {
        for rung in ZoomLadder.ladder {
            XCTAssertEqual(ZoomLadder.clamp(rung), rung)
            XCTAssertFalse(ZoomLadder.label(rung).isEmpty)
        }
        XCTAssertEqual(ZoomLadder.ladder.first, ZoomLadder.fit)
        XCTAssertEqual(Set(ZoomLadder.ladder).count, ZoomLadder.ladder.count)
    }
}
