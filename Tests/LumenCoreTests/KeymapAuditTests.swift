// KeymapAuditTests.swift
// Text scans over Sources/LumenApp for keymap defects the app target cannot test on
// Linux. Each assertion names the rule a source line broke.

import XCTest
@testable import LumenCore

final class KeymapAuditTests: XCTestCase {

    private static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp", isDirectory: true)
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: appDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Lines with their `//` comments removed; enough for call sites written one per line.
    private static func code(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? "" : String(line)
        }
    }

    /// The files whose shortcuts sit in the Scene's `.commands`, which AppKit registers
    /// whatever the window is showing.
    private static let menuBarFiles: Set<String> = ["LumenApp.swift", "CullCommands.swift"]

    /// A ⌘ chord on a view is registered only while that view is in the hierarchy, so a
    /// chord attached to an in-window button dies with the button (Lights Out `out`
    /// removes the filter bar, and ⌘\ with it).
    func testEveryCommandChordIsAttachedInTheMenuBar() throws {
        let files = (try FileManager.default.contentsOfDirectory(
            at: Self.appDirectory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        for file in files where !Self.menuBarFiles.contains(file.lastPathComponent) {
            let lines = Self.code(try String(contentsOf: file, encoding: .utf8))
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: ".keyboardShortcut(\"") else { continue }
                let call = line[range.lowerBound...]
                XCTAssertFalse(call.contains(".command"),
                               "\(file.lastPathComponent):\(index + 1) attaches a ⌘ chord to a "
                                   + "view: \(call.trimmingCharacters(in: .whitespaces)). "
                                   + "Attach it in the Scene's commands, where it cannot "
                                   + "leave the hierarchy.")
            }
        }
        for name in Self.menuBarFiles {
            XCTAssertTrue(try Self.source(name).contains(".keyboardShortcut(\""), name)
        }
    }

    /// `CommandGroup(replacing: .undoRedo)` removes AppKit's Undo and Redo, so ⌘Z and ⇧⌘Z
    /// reach the photo history from inside a text field unless the item offers them to
    /// the field first, as Cut, Copy, Paste and Select All do.
    func testUndoAndRedoOfferTheChordToATextFieldFirst() throws {
        let menu = Self.code(try Self.source("LumenApp.swift")).joined(separator: "\n")
        let pairs: [(String, String, String)] = [
            (".keyboardShortcut(\"z\", modifiers: [.command])",
             "TextEditingFocus.undo()", "state.undo()"),
            (".keyboardShortcut(\"z\", modifiers: [.command, .shift])",
             "TextEditingFocus.redo()", "state.redo()"),
        ]
        for (shortcut, forward, verb) in pairs {
            guard let end = menu.range(of: shortcut),
                  let start = menu.range(of: "Button(", options: .backwards,
                                         range: menu.startIndex..<end.lowerBound)
            else { XCTFail("\(shortcut) not found in LumenApp.swift"); continue }
            let block = menu[start.lowerBound..<end.lowerBound]
            guard let guardAt = block.range(of: forward) else {
                XCTFail("the item carrying \(shortcut) runs \(verb) with no \(forward): "
                            + "⌘Z typed into a text field undoes the photograph's edit")
                continue
            }
            guard let verbAt = block.range(of: verb) else {
                XCTFail("the item carrying \(shortcut) no longer runs \(verb)")
                continue
            }
            XCTAssertLessThan(guardAt.lowerBound, verbAt.lowerBound,
                              "\(verb) runs before the chord is offered to the text field")
        }
    }
}
