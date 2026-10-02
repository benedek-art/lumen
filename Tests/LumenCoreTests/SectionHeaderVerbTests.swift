// V7 D1: a disabled header verb's click fell through and folded the section.
//
// `LumenSectionHeader` puts the `onAction` Button, `.disabled(!actionEnabled)`, inside a
// row that carries `.onTapGesture { toggle() }`. A disabled SwiftUI Button does not
// consume the click, so the ancestor's tap fired: the greyed tray glyph on Albums or
// Stack collapsed the section. The fix is a swallowing layer on the verb while it is
// disabled. SwiftUI's hit-testing does not run on Linux, so this pins the structure:
// inside the verb's own `if let onAction` block, a disabled verb carries a hit-testable
// shape with its own (empty) tap.
import XCTest

final class SectionHeaderVerbTests: XCTestCase {

    func testADisabledHeaderVerbSwallowsItsClick() throws {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        let header = try XCTUnwrap(ShellSource.body(after: "struct LumenSectionHeader", in: code),
                                   "LumenSectionHeader is gone or renamed; re-point this pin")
        let verb = try XCTUnwrap(ShellSource.body(after: "if let onAction", in: header),
                                 "the header's verb block is gone; re-point this pin")
        let flat = ShellSource.squashed(verb)
        XCTAssertTrue(flat.contains(".disabled(!actionEnabled)"),
                      "the verb is no longer disabled by actionEnabled; this pin is stale")
        let swallow = try XCTUnwrap(ShellSource.body(after: "if !actionEnabled", in: verb),
                                    "a disabled header verb has no layer of its own to "
                                        + "take the click, so the click reaches the row's "
                                        + "onTapGesture and folds the section")
        let flatSwallow = ShellSource.squashed(swallow)
        XCTAssertTrue(flatSwallow.contains(".contentShape(Rectangle())"),
                      "the swallowing layer must be hit-testable (a clear colour with no "
                          + "content shape receives nothing)")
        XCTAssertTrue(flatSwallow.contains(".onTapGesture {}"),
                      "the swallowing layer must claim the tap with its own empty gesture")
    }

    /// The pointing hand is the row's promise that a click does something. The greyed
    /// verb answers no click, so the row's cursor stands down while the pointer is on
    /// it: the swallowing layer reports its hover, and the row's cursor is gated on it.
    func testTheRowsPointingHandStandsDownOverADisabledVerb() throws {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        let header = try XCTUnwrap(ShellSource.body(after: "struct LumenSectionHeader", in: code),
                                   "LumenSectionHeader is gone or renamed; re-point this pin")
        let verb = try XCTUnwrap(ShellSource.body(after: "if let onAction", in: header))
        let swallow = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "if !actionEnabled", in: verb)))
        XCTAssertTrue(swallow.contains(".onHover { overDisabledVerb = $0 }"),
                      "the disabled verb's layer does not report the pointer, so the row "
                          + "cannot know to drop its pointing hand there")
        XCTAssertTrue(swallow.contains(".onDisappear { overDisabledVerb = false }"),
                      "a layer removed under the pointer gets no exit; the flag would stick")
        let gate = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private var rowCursorEnabled: Bool", in: header)))
        XCTAssertTrue(gate.contains("isInteractive && !(overDisabledVerb && !actionEnabled)"))
        let flat = ShellSource.squashed(header)
        XCTAssertTrue(flat.contains(".lumenClickCursor(rowCursorEnabled)"),
                      "the row's cursor is not gated on the disabled verb")
        XCTAssertFalse(flat.contains(".lumenClickCursor(isInteractive)"),
                       "the row's cursor still ignores the disabled verb")
    }
}
