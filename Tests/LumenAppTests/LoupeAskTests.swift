// The loupe sizes its render ask from the frame on screen. Just after a switch that
// frame is still the previous photograph's, and asking at its aspect sent the first
// request of the new photograph through a key it would only leave again.
#if os(macOS)

import Foundation
import XCTest
@testable import LumenApp

final class LoupeAskTests: XCTestCase {
    private let current = URL(fileURLWithPath: "/roll/current.ARW")
    private let previous = URL(fileURLWithPath: "/roll/previous.ARW")

    func testAFrameOfThisPhotoSizesTheAsk() {
        XCTAssertEqual(LoupeAsk.sizingFrame(42, shownFor: current, photo: current), 42)
    }

    func testThePreviousPhotosFrameDoesNot() {
        XCTAssertNil(LoupeAsk.sizingFrame(42, shownFor: previous, photo: current))
        XCTAssertNil(LoupeAsk.sizingFrame(42, shownFor: nil, photo: current))
    }
}
#endif
