#if os(macOS)
import CoreGraphics
import XCTest
@testable import LumenApp

final class ColorWheelDragSessionTests: XCTestCase {
    /// The release moves to a different quadrant/radius with no intervening changed
    /// event. The end callback models the app's persistence boundary: its observed
    /// values must already be the release values, not the preceding frame's values.
    func testReleaseSamplePrecedesEditingEndAndCommitSeesFinalValues() {
        var session = ColorWheelDragSession()
        var hue = 0.0, saturation = 0.0
        var events: [String] = []
        var committed: (Double, Double)?
        let write: (Double, Double) -> Void = { h, s in
            hue = h
            saturation = s
            events.append("sample")
        }
        let editing: (Bool) -> Void = { active in
            events.append(active ? "begin" : "end")
            if !active { committed = (hue, saturation) }
        }
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        write: write, reset: { XCTFail("ordinary press must not reset") },
                        editingChanged: editing)
        XCTAssertEqual(hue, 0)
        XCTAssertEqual(saturation, 0.5)
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100,
                      write: write, editingChanged: editing)
        XCTAssertEqual(events, ["begin", "sample", "sample", "end"])
        XCTAssertEqual(committed?.0, 90)
        XCTAssertEqual(committed?.1, 0.5)
    }

    func testChangedNotificationsRemainActiveForEveryMovementUntilRelease() {
        var session = ColorWheelDragSession()
        var events: [String] = []
        let write: (Double, Double) -> Void = { _, _ in events.append("sample") }
        let editing: (Bool) -> Void = { events.append($0 ? "begin" : "end") }
        for location in [CGPoint(x: 75, y: 50), CGPoint(x: 50, y: 75)] {
            session.changed(location: location, diameter: 100, clickCount: 1,
                            write: write, reset: {}, editingChanged: editing)
        }
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100,
                      write: write, editingChanged: editing)
        XCTAssertEqual(events, ["begin", "sample", "begin", "sample", "sample", "end"])
    }

    func testReleaseKeepsExactCircularMappingAndClampsRadiusAtRim() {
        var session = ColorWheelDragSession()
        var hue = 0.0, saturation = 0.0
        let write: (Double, Double) -> Void = { hue = $0; saturation = $1 }
        session.changed(location: CGPoint(x: 50, y: 50), diameter: 100, clickCount: 1,
                        write: write, reset: {}, editingChanged: { _ in })
        // The displacement (-15, -20) is a 3-4-5 triangle at half radius,
        // with its independently calculated angle in the upper-left quadrant.
        session.ended(location: CGPoint(x: 35, y: 30), diameter: 100,
                      write: write, editingChanged: { _ in })
        XCTAssertEqual(hue, 233.13010235415598, accuracy: 1e-12)
        XCTAssertEqual(saturation, 0.5)
        session.changed(location: CGPoint(x: 50, y: 50), diameter: 100, clickCount: 1,
                        write: write, reset: {}, editingChanged: { _ in })
        session.ended(location: CGPoint(x: 50, y: -100), diameter: 100,
                      write: write, editingChanged: { _ in })
        XCTAssertEqual(hue, 270)
        XCTAssertEqual(saturation, 1)
    }

    func testDoubleClickResetCannotBeOverwrittenByChangedOrReleaseLocations() {
        var session = ColorWheelDragSession()
        var hue = 123.0, saturation = 0.75, luminance = 0.4
        var events: [String] = []
        let write: (Double, Double) -> Void = { h, s in
            hue = h; saturation = s; events.append("sample")
        }
        let reset: () -> Void = { saturation = 0; luminance = 0; events.append("reset") }
        let editing: (Bool) -> Void = { events.append($0 ? "begin" : "end") }
        session.changed(location: CGPoint(x: 90, y: 10), diameter: 100, clickCount: 2,
                        write: write, reset: reset, editingChanged: editing)
        session.changed(location: CGPoint(x: 10, y: 90), diameter: 100, clickCount: 1,
                        write: write, reset: reset, editingChanged: editing)
        session.ended(location: CGPoint(x: 100, y: 50), diameter: 100,
                      write: write, editingChanged: editing)
        XCTAssertEqual(events, ["begin", "reset", "end"])
        XCTAssertEqual(hue, 123, "reset preserves the saved hue")
        XCTAssertEqual(saturation, 0)
        XCTAssertEqual(luminance, 0)
        // Reset suppression belongs to one press, not the next ordinary gesture.
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        write: write, reset: reset, editingChanged: editing)
        session.ended(location: CGPoint(x: 50, y: 25), diameter: 100,
                      write: write, editingChanged: editing)
        XCTAssertEqual(hue, 270)
        XCTAssertEqual(saturation, 0.5)
        XCTAssertEqual(Array(events.suffix(4)), ["begin", "sample", "sample", "end"])
    }
}
#endif
