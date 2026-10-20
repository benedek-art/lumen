// ResponsivenessKeyTests.swift — ⌘Z and ⇧⌘Z while somebody is typing.
//
// WHAT WAS WRONG. `LumenCommands` replaces the `.undoRedo` command group, which deletes
// AppKit's own Undo/Redo items, and a menu key equivalent is offered by `NSMenu` before
// the key window's responder chain sees the event. So ⌘Z pressed while typing a value
// into a slider's numeric field, a keyword or the filter box did not undo the typing —
// it reverted the last PHOTO edit, out of sight, while the text stayed as typed. The
// pasteboard group already carries the carve-out for ⌘X/⌘C/⌘V/⌘A
// (`PasteboardCarveOutTests`); undo and redo did not.
//
// WHY THIS IS A TEXT SCAN: the defect is a property of the menu item's action, which
// cannot be exercised without a running `NSApplication`, a key window and a first
// responder. Comments are blanked first, so the explanatory comment above the group
// cannot satisfy the assertions on its own.
#if os(macOS)

import XCTest

final class ResponsivenessKeyTests: XCTestCase {

    private static var lumenAppSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp/LumenApp.swift")
    }

    /// The text of the menu item whose title starts with `titlePrefix`, from its
    /// `Button(` line up to (not including) the next `Button(` line.
    private static func item(startingWith titlePrefix: String,
                             in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(titlePrefix)
        }) else { return nil }
        var block = [lines[start]]
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("Button(") { break }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }

    private func assertCarveOut(title: String, selector: String, photoVerb: String,
                                chord: String, enablement: String) throws {
        let raw = try String(contentsOf: Self.lumenAppSource, encoding: .utf8)
        let source = blankingComments(in: raw)
        let block = try XCTUnwrap(Self.item(startingWith: title, in: source),
                                  "\(title) item not found in LumenApp.swift")
        XCTAssertTrue(block.contains(chord), "\(title) no longer carries \(chord)")
        XCTAssertTrue(block.contains(enablement),
                      "\(title)'s enabled state no longer follows the history")
        let focus = try XCTUnwrap(block.range(of: "TextEditingFocus.isActive"),
                                  "\(title) does not ask whether a text field is typing")
        let forward = try XCTUnwrap(block.range(of: "\"\(selector)\""),
                                    "\(title) does not offer \(selector) to the text field")
        let verb = try XCTUnwrap(block.range(of: photoVerb),
                                 "\(title) lost its photo verb \(photoVerb)")
        XCTAssertLessThan(focus.lowerBound, verb.lowerBound,
                          "\(title) runs \(photoVerb) before checking for a text field")
        XCTAssertLessThan(forward.lowerBound, verb.lowerBound,
                          "\(title) runs \(photoVerb) before offering the chord to "
                              + "the text field, so ⌘Z reverts a photo edit while "
                              + "the photographer is typing")
    }

    func testUndoOffersTheChordToATextFieldBeforeThePhotoHistory() throws {
        try assertCarveOut(title: "Button(commands.undoLabel", selector: "undo:",
                           photoVerb: "state.undo()",
                           chord: ".keyboardShortcut(\"z\", modifiers: [.command])",
                           enablement: ".disabled(!commands.canUndo)")
    }

    func testRedoOffersTheChordToATextFieldBeforeThePhotoHistory() throws {
        try assertCarveOut(title: "Button(commands.redoLabel", selector: "redo:",
                           photoVerb: "state.redo()",
                           chord: ".keyboardShortcut(\"z\", modifiers: [.command, .shift])",
                           enablement: ".disabled(!commands.canRedo)")
    }

    /// The scan must not be satisfiable by prose: a comment naming the fix, with the
    /// code absent, has to fail the lookup.
    func testTheScanIgnoresACommentThatNamesTheFix() {
        let sample = blankingComments(in: """
        Button(commands.undoLabel.map { "Undo \\($0)" } ?? "Undo") {
            // TextEditingFocus.isActive then "undo:"
            state.undo()
        }
        .keyboardShortcut("z", modifiers: [.command])
        Button("Next") { }
        """)
        let block = Self.item(startingWith: "Button(commands.undoLabel", in: sample)
        XCTAssertNotNil(block)
        XCTAssertFalse(block?.contains("TextEditingFocus.isActive") ?? true)
        XCTAssertFalse(block?.contains("Button(\"Next\")") ?? true)
    }
}

#endif
