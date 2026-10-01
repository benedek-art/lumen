// F1-06, as a shape.
//
// The mask canvas is the size of the photograph and goes live whenever ANOTHER mask's
// pin is on it — correctly, because a pin you can press is a target. But it was
// hit-testing the whole frame for it, so one enabled mask parked anywhere made every
// pan, every double-click and every scroll over the entire picture disappear into an
// overlay that had nothing to do with them. The viewer felt dead in exactly the
// conditions a mask is worked in, which is why this was filed at S2.
//
// The fix is a `contentShape`: the whole rectangle while there is a shape here to draw
// on, the pin discs when there is not. This asserts that rule directly — a path
// contains the pins and does not contain the picture around them.
#if os(macOS)
import XCTest
import SwiftUI
import LumenCore
@testable import LumenApp

final class MaskCanvasHitAreaTests: XCTestCase {

    private let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let radius: CGFloat = 11

    /// A drawable component of its own: the whole frame is the target, because you draw
    /// anywhere on it.
    func testNilPinsIsTheWholeRectangle() {
        let path = MaskCanvasHitArea(pins: nil, radius: radius).path(in: frame)
        XCTAssertEqual(path.boundingRect, frame)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 600, y: 400),
                      CGPoint(x: 1199, y: 799)] {
            XCTAssertTrue(path.contains(point), "\(point) is inside the frame")
        }
    }

    /// Live only for a foreign pin: the disc answers and the picture around it does not.
    /// The second half is the whole finding — before the fix, every one of these far
    /// points was swallowed.
    func testForeignPinsAnswerOnlyAtTheDiscs() {
        let pins = [CGPoint(x: 300, y: 200), CGPoint(x: 900, y: 640)]
        let path = MaskCanvasHitArea(pins: pins, radius: radius).path(in: frame)
        for pin in pins {
            XCTAssertTrue(path.contains(pin), "the pin's own centre must answer")
            XCTAssertTrue(path.contains(CGPoint(x: pin.x + radius * 0.6, y: pin.y)),
                          "so must a press just off centre, inside the grab radius")
        }
        for away in [CGPoint(x: 5, y: 5), CGPoint(x: 600, y: 400),
                     CGPoint(x: 1195, y: 795), CGPoint(x: 300, y: 200 + radius * 3)] {
            XCTAssertFalse(path.contains(away),
                           "\(away) is the photograph, and the photograph answers it")
        }
    }

    /// The discs are exactly the grab radius the press test uses — an affordance drawn
    /// at one size and hit at another is the defect class this file is already about.
    func testDiscsAreTheGrabRadius() {
        let pin = CGPoint(x: 400, y: 400)
        let path = MaskCanvasHitArea(pins: [pin], radius: radius).path(in: frame)
        XCTAssertEqual(path.boundingRect.width, radius * 2, accuracy: 1e-9)
        XCTAssertEqual(path.boundingRect.height, radius * 2, accuracy: 1e-9)
        XCTAssertEqual(path.boundingRect.midX, pin.x, accuracy: 1e-9)
        XCTAssertEqual(path.boundingRect.midY, pin.y, accuracy: 1e-9)
    }

    /// The grab radius the canvas passes is `MaskHandles.grabRadius`, not a literal 11
    /// written twice — the copy that drifts is how the ink and the target part company.
    func testTheCanvasUsesTheSharedGrabRadius() {
        XCTAssertEqual(MaskCanvas.pinGrab, CGFloat(MaskHandles.grabRadius))
    }

    /// Unreachable in the app — `isLive` is false with neither a component nor a pin —
    /// but an empty list must be "nothing answers", never "everything does".
    func testNoPinsAnswerNothing() {
        let path = MaskCanvasHitArea(pins: [], radius: radius).path(in: frame)
        XCTAssertTrue(path.isEmpty)
        XCTAssertFalse(path.contains(CGPoint(x: 600, y: 400)))
    }
}
#endif
