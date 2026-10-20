// ResponsivenessSliderTests.swift
// The slider family's edit contract: an input that changes nothing writes nothing, and
// every write a gesture makes lands inside that gesture's bracket.
//
// Pinned here:
//   · a typed entry that re-enters the current value (Return on the pre-filled
//     readout, a blur without typing) is not an edit — `LumenSlider.typedValue`
//     returns nil and `commitText` opens no bracket;
//   · typed entries clamp to the HARD range and refuse garbage;
//   · the readout commits on blur as well as on Return;
//   · a press on the track opens the gesture bracket BEFORE the jump write, so the
//     jump is inside the deferral and the gesture's undo epoch;
//   · reset at rest writes nothing, on the slider and on the colour wheel.
// The last three are view wiring a unit test cannot drive, so they are read off the
// source with comments blanked, the way `ModifierKeysTests` checks its wiring.
#if os(macOS)
import XCTest
@testable import LumenApp

final class ResponsivenessSliderTests: XCTestCase {

    @MainActor
    func testRetypingTheCurrentValueIsNotAnEdit() {
        XCTAssertNil(LumenSlider.typedValue("25", current: 25, hardRange: -100...100))
        XCTAssertNil(LumenSlider.typedValue("25.0", current: 25, hardRange: -100...100))
        XCTAssertNil(LumenSlider.typedValue("+= 0", current: 25, hardRange: -100...100))
        // Clamped onto the value already held: still nothing to write.
        XCTAssertNil(LumenSlider.typedValue("500", current: 100, hardRange: -100...100))
    }

    @MainActor
    func testTypedEntryClampsToTheHardRange() {
        XCTAssertEqual(LumenSlider.typedValue("500", current: 0, hardRange: -100...100), 100)
        XCTAssertEqual(LumenSlider.typedValue("-500", current: 0, hardRange: -100...100), -100)
        XCTAssertEqual(LumenSlider.typedValue("8", current: 0, hardRange: -10...10), 8)
        XCTAssertEqual(LumenSlider.typedValue("-40", current: 10, hardRange: -100...100), -40)
    }

    @MainActor
    func testTypedGarbageIsRefused() {
        for text in ["", "abc", "nan", "inf", "1e999", "--"] {
            XCTAssertNil(LumenSlider.typedValue(text, current: 3, hardRange: -100...100),
                         "\"\(text)\" must not write")
        }
    }

    private func controls() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return blankingComments(in: try String(
            contentsOf: root.appendingPathComponent("Sources/LumenApp/LumenControls.swift"),
            encoding: .utf8))
    }

    func testTheReadoutCommitsOnBlur() throws {
        let code = try controls()
        XCTAssertTrue(code.contains("if !focused && isEditingText { commitText() }"),
                      "clicking away from the readout must apply the typed value")
    }

    func testTheTrackPressJumpIsInsideTheBracket() throws {
        let code = try controls()
        let open = try XCTUnwrap(code.range(of: "sliderGestureChanged(true)\n"
                                            + "                            let thumbX"))
        let jump = try XCTUnwrap(code.range(of: "commit(dragStartValue)"))
        XCTAssertLessThan(open.lowerBound, jump.lowerBound,
                          "the press jump must be written after the gesture opens")
        XCTAssertFalse(code.contains("value = dragStartValue"),
                       "the press jump must go through the guarded commit")
    }

    func testResetAtRestWritesNothing() throws {
        let code = try controls()
        XCTAssertTrue(code.contains("guard value != defaultValue else { return }"))
        XCTAssertTrue(code.contains("if sat != 0 || lum != 0 {"))
        XCTAssertTrue(code.contains("if nextSat != sat { sat = nextSat }"))
    }
}
#endif
