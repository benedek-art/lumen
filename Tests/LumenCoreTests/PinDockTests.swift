// PinDockTests.swift
// docs/36 §4 item 23's last piece — a mask's pin when the mask is off the picture.
//
// Zoom to 1:1 on a corner and every mask anchored elsewhere leaves the frame; a gradient
// dragged off the edge does it at any zoom. The pin was DROPPED then — so the one control
// that selects a mask from the photograph disappeared exactly at the moment the mask list
// becomes the only way left, which is the moment pins exist to avoid.
//
// The property that makes docking honest rather than merely present is the second half of
// the return value. A docked pin is a SIGNPOST, not a position: the mask is not there, it
// is that way. The caller draws the two differently, and a caller that could not tell
// them apart would be drawing a picture that claims a mask sits in a corner it does not.

import XCTest
@testable import LumenCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class PinDockTests: XCTestCase {

    private let frame = CGSize(width: 800, height: 600)

    private func dock(_ x: CGFloat, _ y: CGFloat) -> (point: CGPoint, docked: Bool)? {
        MaskHandles.dockedPin(CGPoint(x: x, y: y), in: frame)
    }

    func testAPinOnThePictureIsLeftExactlyWhereItIs() {
        for point in [(400.0, 300.0), (11.0, 11.0), (789.0, 589.0)] {
            let out = dock(CGFloat(point.0), CGFloat(point.1))
            XCTAssertEqual(out?.point.x, CGFloat(point.0))
            XCTAssertEqual(out?.point.y, CGFloat(point.1))
            XCTAssertEqual(out?.docked, false, "\(point) is on the picture")
        }
    }

    func testAPinOffTheEdgeDocksToItAndSaysSo() {
        let out = dock(-4000, 300)
        XCTAssertEqual(out?.point.x, CGFloat(MaskHandles.pinDockInset))
        XCTAssertEqual(out?.point.y, 300, "the axis that was on screen does not move")
        XCTAssertEqual(out?.docked, true)
    }

    func testItDocksOnEitherAxisIndependently() {
        // A mask above the frame but horizontally in view docks to the top edge at its
        // own x — which is what makes the pin a direction rather than just a corner.
        let above = dock(620, -900)
        XCTAssertEqual(above?.point.x, 620)
        XCTAssertEqual(above?.point.y, CGFloat(MaskHandles.pinDockInset))

        let right = dock(9000, 120)
        XCTAssertEqual(right?.point.x, frame.width - CGFloat(MaskHandles.pinDockInset))
        XCTAssertEqual(right?.point.y, 120)
    }

    func testACornerDocksToTheCorner() {
        let out = dock(-500, -500)
        XCTAssertEqual(out?.point.x, CGFloat(MaskHandles.pinDockInset))
        XCTAssertEqual(out?.point.y, CGFloat(MaskHandles.pinDockInset))
        XCTAssertEqual(out?.docked, true)
    }

    /// A pin is drawn as a disc about 5 pt in radius with an 11 pt grab circle. Docked
    /// flush to the edge, half of both would be off the picture and the thing would be
    /// visible and unclickable — which is worse than absent, because it looks like it
    /// works.
    ///
    /// ASSERTED IN POINTS, not against `pinDockInset`. The first draft of this test
    /// checked the result against the very constant it was meant to constrain, so
    /// setting the inset to zero passed it — a test that says "the number equals
    /// itself". Six points is the real claim: it clears the drawn radius.
    private static let pinRadius: Double = 6

    func testTheWholeDotStaysOnThePicture() {
        for point in [(-1.0, -1.0), (10_000.0, 10_000.0), (-1.0, 10_000.0),
                      (-5000.0, 300.0), (400.0, -5000.0)] {
            guard let out = dock(CGFloat(point.0), CGFloat(point.1)) else {
                return XCTFail("\(point) produced nothing")
            }
            XCTAssertGreaterThanOrEqual(Double(out.point.x), Self.pinRadius,
                                        "\(point) docked with the dot half off the left")
            XCTAssertGreaterThanOrEqual(Double(out.point.y), Self.pinRadius,
                                        "\(point) docked with the dot half off the top")
            XCTAssertLessThanOrEqual(Double(out.point.x),
                                     Double(frame.width) - Self.pinRadius)
            XCTAssertLessThanOrEqual(Double(out.point.y),
                                     Double(frame.height) - Self.pinRadius)
        }
        XCTAssertGreaterThanOrEqual(MaskHandles.pinDockInset, Self.pinRadius,
                                    "and the constant itself has to clear the dot")
    }

    func testJustOffTheEdgeIsDockedRatherThanNudgedSilently() {
        // One point outside the inset band. The flag has to be true or the caller draws
        // a solid pin a point from where the mask really is — which is not a lie worth
        // telling, but it is one the caller cannot detect without this.
        let out = dock(CGFloat(MaskHandles.pinDockInset) - 1, 300)
        XCTAssertEqual(out?.docked, true)
        XCTAssertEqual(out?.point.x, CGFloat(MaskHandles.pinDockInset))
    }

    func testAFrameTooNarrowToDockInStillProducesAPointOnIt() {
        // A 12 pt sliver cannot hold two 10 pt insets. Every answer is a compromise; the
        // one that is never OFF the picture is the one to make.
        let sliver = CGSize(width: 12, height: 600)
        guard let out = MaskHandles.dockedPin(CGPoint(x: -50, y: 300), in: sliver) else {
            return XCTFail("a sliver is still a frame")
        }
        XCTAssertGreaterThanOrEqual(out.point.x, 0)
        XCTAssertLessThanOrEqual(out.point.x, sliver.width)
    }

    func testAPoisonedPinOrFrameIsRefusedRatherThanPlaced() {
        XCTAssertNil(MaskHandles.dockedPin(CGPoint(x: CGFloat.nan, y: 10), in: frame))
        XCTAssertNil(MaskHandles.dockedPin(CGPoint(x: 10, y: CGFloat.infinity), in: frame))
        XCTAssertNil(MaskHandles.dockedPin(CGPoint(x: 10, y: 10),
                                           in: CGSize(width: 0, height: 600)))
        XCTAssertNil(MaskHandles.dockedPin(CGPoint(x: 10, y: 10),
                                           in: CGSize(width: CGFloat.nan, height: 600)))
    }

    func testNoPinIsEverDroppedForBeingFarAway() {
        // The defect, as one assertion: the old rule discarded anything more than 40 pt
        // outside the frame, which at 1:1 on a 45 MP file is most of the masks on it.
        for distance in [41.0, 500.0, 50_000.0] {
            XCTAssertNotNil(dock(CGFloat(-distance), 300),
                            "a pin \(distance) pt off the edge still has a home")
        }
    }
}
