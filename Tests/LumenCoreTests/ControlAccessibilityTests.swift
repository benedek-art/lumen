// ControlAccessibilityTests.swift
// The drawn controls that VoiceOver could not read: the segmented picker never said
// which option was chosen, and a toggle row was an unnamed "on, button".
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

    /// A toggle row's title was a sibling `Text` and its switch an unnamed
    /// "on, button". The row is now one element named by its title.
    func testAToggleRowIsOneButtonNamedByItsTitle() throws {
        let row = try Self.body(from: "struct LumenToggleRow: View {",
                                in: Self.appSource("LumenControls"))
        for needle in [
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(Text(title))",
            ".accessibilityValue(Text(isOn ? \"on\" : \"off\"))",
            ".accessibilityAddTraits(.isButton)",
            ".accessibilityAction { if isEnabled { isOn.toggle() } }",
        ] {
            XCTAssertTrue(row.contains(needle), "LumenToggleRow lost \(needle)")
        }
        let bar = try Self.appSource("FilterBar")
        let strip = try XCTUnwrap(bar.range(of: "private var autoAdvanceToggle: some View {"))
        let tail = String(bar[strip.upperBound...].prefix(2000))
        XCTAssertTrue(tail.contains(".accessibilityLabel(Text(\"Auto-advance\"))"),
                      "the Auto-advance strip's switch is unnamed again")
    }

    /// The two standalone tick boxes are named where they are placed.
    func testTheStandaloneCheckboxesAreNamed() throws {
        let sheet = try Self.appSource("ExportSheet")
        let box = try XCTUnwrap(sheet.range(of: "LumenCheckbox(isOn: $enabled)"))
        XCTAssertTrue(sheet[box.upperBound...].prefix(400).contains(".accessibilityLabel("))
        let heal = try Self.appSource("HealCanvas")
        let spots = try XCTUnwrap(heal.range(of: "LumenCheckbox(isOn: $tool.visualize)"))
        XCTAssertTrue(heal[spots.upperBound...].prefix(200)
            .contains(".accessibilityLabel(Text(\"Visualize Spots\"))"))
    }
}
