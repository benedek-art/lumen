// PickEscapeTests.swift — Escape cancels a pending pick before it drops a slider's focus
// (docs/quality/lanes/WS-02/SPEC.md D1).

#if os(macOS)

import XCTest
@testable import LumenApp

final class PickEscapeTests: XCTestCase {

    @MainActor private func action(pick: Bool, slider: Bool, masking: Bool = false,
                                   heal: Bool = false, crop: Bool = false,
                                   grid: Bool = false) -> KeyDispatcher.EscapeAction {
        KeyDispatcher.escapeAction(pickArmed: pick, sliderHoldsFocus: slider,
                                   masking: masking, healArmed: heal,
                                   cropShowing: crop, inGrid: grid)
    }

    /// Armed, with a slider focused: the first press cancels the pick and consumes the
    /// key; the slider keeps focus, so the second press drops it.
    @MainActor func testFirstEscapeCancelsAPickWhileASliderHoldsFocus() {
        XCTAssertEqual(action(pick: true, slider: true), .cancelPick)
        XCTAssertEqual(action(pick: true, slider: true, masking: true, heal: true,
                              crop: true), .cancelPick)
        // After the first press the pick is gone and the slider still holds focus.
        XCTAssertEqual(action(pick: false, slider: true), .yieldToSlider)
        // And with focus dropped, the next layer out.
        XCTAssertEqual(action(pick: false, slider: false), .showGrid)
    }

    /// No pick armed: the nested idiom is unchanged — slider focus first, then masking,
    /// heal, crop, the grid, and finally nothing.
    @MainActor func testEscapeWithNoPickStillDropsSliderFocusFirst() {
        XCTAssertEqual(action(pick: false, slider: true, masking: true, heal: true,
                              crop: true), .yieldToSlider)
        XCTAssertEqual(action(pick: false, slider: false, masking: true, heal: true,
                              crop: true), .leaveMasking)
        XCTAssertEqual(action(pick: false, slider: false, heal: true, crop: true), .leaveHeal)
        XCTAssertEqual(action(pick: false, slider: false, crop: true), .leaveCrop)
        XCTAssertEqual(action(pick: false, slider: false, grid: false), .showGrid)
        XCTAssertEqual(action(pick: false, slider: false, grid: true), .pass)
    }
}

#endif
