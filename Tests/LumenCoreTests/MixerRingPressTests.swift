// MixerRingPressTests.swift
// The first click of a double-click on the mixer's hue ring writes nothing (B3-05).
//
// The ring's drag has `minimumDistance: 0`, so the press arrives as a change; the
// double-click reset reads `clickCount >= 2`, which the FIRST click never has. So the
// first click dragged the nearest grabbed handle to the clicked angle and recorded it,
// the second reset the arc, and one ⌘Z restored the arc with the yanked handle — an arc
// the photographer never made. `ColorPanel` compiles on macOS only; this reads it as
// text, line comments stripped, on the lane that runs.

import XCTest

final class MixerRingPressTests: XCTestCase {

    func testAPressThatHasNotMovedWritesNothing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/ColorPanel.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")

        guard let grab = code.range(of: "MixerHueRing.grab(at: drag.startLocation"),
              let move = code.range(of: "onHandleMoved(handle, angle)",
                                    range: grab.upperBound..<code.endIndex) else {
            return XCTFail("the ring's press-and-drag path moved")
        }
        let path = String(code[grab.upperBound..<move.lowerBound])
        guard let still = path.range(of: "drag.translation.width != 0 || "
                                         + "drag.translation.height != 0") else {
            return XCTFail("a press with no travel reaches onHandleMoved: the first click "
                           + "of a double-click moves the handle before the reset")
        }
        guard let opens = path.range(of: "sliderGestureChanged(true)") else {
            return XCTFail("the ring no longer opens a gesture")
        }
        XCTAssertLessThan(still.lowerBound, opens.lowerBound,
                          "a stationary press still opens a gesture epoch before the "
                              + "travel check")
    }
}
