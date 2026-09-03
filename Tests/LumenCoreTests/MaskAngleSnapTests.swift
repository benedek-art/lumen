// MaskAngleSnapTests.swift
// docs/36 §4 item 23 — Shift snaps a gradient to 15°, not to the two axes.
//
// What shipped constrained a drag to the horizontal or the vertical. That covers a level
// horizon and a straight-down sky and abandons the photographer for every other picture:
// a gradient raked along a hillside, or following a shaft of window light, is the
// ordinary case and it was the one case Shift could not help with.
//
// The property worth testing is not "it snaps" — it is that snapping changes the
// DIRECTION and nothing else. A constraint that also shortens the gradient makes the
// photographer fight a control that moves two things when they asked for one, and
// projecting onto the ray (the obvious implementation) does exactly that.

import XCTest
@testable import LumenCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class MaskAngleSnapTests: XCTestCase {

    private let anchor = CGPoint(x: 100, y: 100)

    private func angle(_ p: CGPoint) -> Double {
        atan2(Double(p.y - anchor.y), Double(p.x - anchor.x)) * 180 / .pi
    }

    private func length(_ p: CGPoint) -> Double {
        hypot(Double(p.x - anchor.x), Double(p.y - anchor.y))
    }

    private func at(_ degrees: Double, _ r: Double) -> CGPoint {
        CGPoint(x: anchor.x + CGFloat(cos(degrees * .pi / 180) * r),
                y: anchor.y + CGFloat(sin(degrees * .pi / 180) * r))
    }

    func testEveryResultLandsOnAMultipleOfFifteen() {
        // Swept finely enough that a step twice the size would be caught.
        for degrees in stride(from: -180.0, through: 180.0, by: 0.7) {
            let out = MaskHandles.snapped(at(degrees, 80), anchor: anchor)
            let landed = angle(out)
            let remainder = abs(landed.truncatingRemainder(dividingBy: 15))
            XCTAssertTrue(remainder < 1e-6 || abs(remainder - 15) < 1e-6,
                          "\(degrees)° landed on \(landed)°")
        }
    }

    func testItSnapsToTheNEARESTStopAndNotJustSomeStop() {
        for (input, expected) in [(1.0, 0.0), (7.0, 0.0), (8.0, 15.0), (22.0, 15.0),
                                  (23.0, 30.0), (44.0, 45.0), (46.0, 45.0),
                                  (-8.0, -15.0), (-7.0, 0.0), (100.0, 105.0)] {
            let landed = angle(MaskHandles.snapped(at(input, 60), anchor: anchor))
            XCTAssertEqual(landed, expected, accuracy: 1e-6, "\(input)°")
        }
    }

    func testTheLengthIsUntouched() {
        // The property that makes this a constraint rather than two controls at once. A
        // projection onto the snapped ray — the obvious implementation — would shorten
        // the drag by cos(error), which is 3% at the worst case and visible as the band
        // shrinking while the hand turns it.
        for degrees in stride(from: -180.0, through: 180.0, by: 3.0) {
            for r in [1.0, 37.5, 400.0] {
                let out = MaskHandles.snapped(at(degrees, r), anchor: anchor)
                XCTAssertEqual(length(out), r, accuracy: 1e-9,
                               "at \(degrees)° × \(r)")
            }
        }
    }

    func testTheOldZeroAndNinetyStillWork() {
        // Nothing anyone had learned about this key may stop working: 0 and 90 are
        // multiples of 15, so the previous behaviour is a subset of this one.
        XCTAssertEqual(angle(MaskHandles.snapped(at(2, 50), anchor: anchor)), 0,
                       accuracy: 1e-6)
        XCTAssertEqual(angle(MaskHandles.snapped(at(88, 50), anchor: anchor)), 90,
                       accuracy: 1e-6)
        XCTAssertEqual(angle(MaskHandles.snapped(at(178, 50), anchor: anchor)), 180,
                       accuracy: 1e-6)
    }

    func testAPressThatHasNotMovedSnapsToNothing() {
        // No travel is no angle, and the only answer that is not invented is the anchor.
        let out = MaskHandles.snapped(anchor, anchor: anchor)
        XCTAssertEqual(out.x, anchor.x)
        XCTAssertEqual(out.y, anchor.y)
    }

    func testAPoisonedPointDoesNotProduceAPoisonedResult() {
        for bad in [CGPoint(x: CGFloat.nan, y: 120),
                    CGPoint(x: 120, y: CGFloat.infinity)] {
            let out = MaskHandles.snapped(bad, anchor: anchor)
            XCTAssertTrue(out.x.isFinite && out.y.isFinite)
        }
    }

    func testAStepOfZeroIsRefusedRatherThanDividedBy() {
        let out = MaskHandles.snapped(at(37, 90), anchor: anchor, step: 0)
        XCTAssertTrue(out.x.isFinite && out.y.isFinite)
    }

    func testTheStopsAreDenseEnoughToBeUsefulAndCoarseEnoughToBeFelt() {
        // The choice itself, written down so changing it is deliberate. Twenty-four
        // stops around the circle: fine enough to include the diagonals, the thirds and
        // the sixths; coarse enough that the snap is felt as a constraint rather than
        // as a rounding error.
        XCTAssertEqual(MaskHandles.angleSnapDegrees, 15, accuracy: 0)
        XCTAssertEqual(360 / MaskHandles.angleSnapDegrees, 24, accuracy: 0)
        for wanted in [0.0, 30.0, 45.0, 60.0, 90.0, 120.0, 135.0] {
            XCTAssertEqual(wanted.truncatingRemainder(dividingBy: 15), 0, accuracy: 0,
                           "\(wanted)° must be reachable")
        }
    }
}
