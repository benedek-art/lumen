// ControlAccessibilityTests.swift
// The drawn controls that VoiceOver could not read: the segmented picker never said
// which option was chosen.
//
// The controls are LumenApp, which compiles only on macOS, so they are pinned by source
// contracts in the style of `SliderAccessibilityTests`, which run on every lane.

import XCTest

final class ControlAccessibilityTests: XCTestCase {

    private static func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `header` to the next top-level closing brace.
    private static func body(from header: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: header), "\(header) moved")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Only the chip and the label colour marked the chosen segment, so every option
    /// read as the same "<label>, button".
    func testTheSegmentedPickerMarksTheChosenOptionSelected() throws {
        let picker = try Self.body(from: "struct LumenSegmented<T: Hashable>: View {",
                                   in: Self.appSource("LumenControls"))
        XCTAssertTrue(picker.contains(
            ".accessibilityAddTraits(selection == option.value ? .isSelected : [])"),
            "LumenSegmented no longer tells VoiceOver which option is selected")
        XCTAssertTrue(picker.contains(".accessibilityElement(children: .contain)"))
    }
}
