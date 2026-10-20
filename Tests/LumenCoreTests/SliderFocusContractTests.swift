// SliderFocusContractTests.swift
// What `LumenSlider` lets go of: an open readout field on blur, and both the field and
// keyboard focus when the photograph changes.
//
// SwiftUI focus cannot be driven from a test target, so these scan the comment-stripped
// source (`ShellSource`) for the handlers that carry the behaviour.

import Foundation
import XCTest

final class SliderFocusContractTests: XCTestCase {

    private static func slider() throws -> String {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        return try XCTUnwrap(ShellSource.body(after: "struct LumenSlider: View", in: code))
    }

    /// Findings 10/20/38: the readout field closed only on Return or Escape, so a field
    /// left open by a click elsewhere could later commit its stale snapshot.
    func testTheReadoutFieldCommitsOnBlurAndFocusesOnceItExists() throws {
        let s = ShellSource.squashed(try Self.slider())
        XCTAssertTrue(s.contains(
            ".onChange(of: textFocused) { _, focused in if !focused && isEditingText { commitText() } }"),
            "the readout field must commit when it loses focus")
        XCTAssertTrue(s.contains(".onAppear { textFocused = true }"),
                      "focus must be requested once the field exists")
        XCTAssertTrue(s.contains(
            ".onChange(of: value) { _, _ in if isEditingText && !textFocused { isEditingText = false } }"),
            "a field left open must close when the value moves under it")
    }

    /// Finding 39: focus taken by a drag followed the photographer to the next frame, so
    /// an arrow meant to page nudged the new photograph instead.
    func testANewPhotographReleasesRowFocusAndAnOpenField() throws {
        let s = try Self.slider()
        let handler = try XCTUnwrap(ShellSource.body(after: ".onChange(of: sliderSubject)",
                                                     in: s))
        XCTAssertTrue(handler.contains("rowFocused = false"))
        XCTAssertTrue(handler.contains("isEditingText = false"))

        let root = try ShellSource.code("Sources/LumenApp/ContentView.swift")
        XCTAssertTrue(root.contains(".environment(\\.sliderSubject, state.primarySelection?.id)"),
                      "the root must publish which photograph the sliders edit")
    }
}
