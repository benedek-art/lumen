// KeyGrammarTests.swift
// The mechanism behind "the Help sheet cannot drift from the dispatcher".
//
// That sentence was in Keymap.swift, above a reference that had already drifted: seven
// ⌘-shortcuts attached to SwiftUI buttons appeared in neither the reference nor the
// dispatcher. Being data is not a mechanism. This file is the mechanism — it reads the
// Swift sources and fails when a key exists in one place and not the other.
//
// It runs on Linux, in LumenCore's suite, because it is a scan over text. The target it
// scans cannot be compiled here and has no test target of its own, which is exactly why
// every defect in the interaction audit was invisible.

import XCTest
@testable import LumenCore

final class KeyGrammarTests: XCTestCase {

    // MARK: Finding the sources

    /// The repository, from this file's own path. `Bundle.module` carries the fixtures,
    /// not the sources, and the sources are what this test is about.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private static var appSources: [URL] {
        let directory = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "swift" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Comments blanked, string bodies kept, length and newlines preserved.
    ///
    /// One pass rather than two regexes: a `//` inside a string and a `"` inside a
    /// comment each break the other's pattern, and `scripts/check-swift-surface.py`
    /// learned that the expensive way. Blanking in place keeps every offset valid.
    private static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }

    // MARK: Reading `.keyboardShortcut` call sites

    private enum Shortcut: Equatable {
        /// `.keyboardShortcut("k", modifiers: […])`.
        case literal(KeyBinding)
        /// `.keyboardShortcut(.defaultAction)` / `.cancelAction` — Return and Escape
        /// inside one sheet, not an application-wide chord.
        case sheetAction
        /// A key the scanner cannot read because it is computed at the call site.
        case computed(String)
    }

    /// Every `.keyboardShortcut(…)` in `text`, classified.
    ///
    /// The walk steps over string literals rather than blanking them, for two reasons
    /// that pull opposite ways: the key IS a string literal, so blanking them would
    /// make every binding unreadable — and a `.keyboardShortcut(` written inside a
    /// string, which this file's own sample does, is prose rather than a call site.
    /// Paren depth in the argument skips strings too, so a `"("` key equivalent cannot
    /// run the scan off the end of the call.
    private static func shortcuts(in text: String) -> [Shortcut] {
        let source = Array(withoutComments(text))
        let needle = Array(".keyboardShortcut(")
        var found: [Shortcut] = []
        var i = 0

        /// Index just past the string literal starting at `start`.
        func endOfString(_ start: Int) -> Int {
            var j = start + 1
            while j < source.count {
                if source[j] == "\\" { j += 2; continue }
                if source[j] == "\"" { return j + 1 }
                if source[j] == "\n" { return j }
                j += 1
            }
            return j
        }

        while i < source.count {
            if source[i] == "\"" {
                i = endOfString(i)
                continue
            }
            guard i + needle.count <= source.count,
                  Array(source[i..<(i + needle.count)]) == needle else {
                i += 1
                continue
            }
            var j = i + needle.count
            var depth = 1
            var argument = ""
            while j < source.count && depth > 0 {
                if source[j] == "\"" {
                    let end = endOfString(j)
                    argument += String(source[j..<Swift.min(end, source.count)])
                    j = end
                    continue
                }
                let c = source[j]
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                argument.append(c)
                j += 1
            }
            found.append(classify(argument))
            i = j
        }
        return found
    }

    private static func classify(_ argument: String) -> Shortcut {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".defaultAction") || trimmed.hasPrefix(".cancelAction") {
            return .sheetAction
        }
        guard trimmed.hasPrefix("\""), let key = firstStringLiteral(in: trimmed) else {
            return .computed(trimmed)
        }
        let modifiers = trimmed.contains("modifiers:")
            ? String(trimmed[trimmed.range(of: "modifiers:")!.upperBound...])
            : ""
        return .literal(KeyBinding(key,
                                   command: modifiers.contains(".command"),
                                   shift: modifiers.contains(".shift"),
                                   option: modifiers.contains(".option"),
                                   control: modifiers.contains(".control")))
    }

    /// The contents of the first `"…"` in `text`, with `\\` escapes resolved for the
    /// two characters that occur in a key equivalent.
    private static func firstStringLiteral(in text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "\"") else { return nil }
        var body = ""
        var i = start + 1
        while i < characters.count {
            let c = characters[i]
            if c == "\\" && i + 1 < characters.count {
                body.append(characters[i + 1])
                i += 2
                continue
            }
            if c == "\"" { return body }
            body.append(c)
            i += 1
        }
        return nil
    }

    /// Every string literal on a line of `text` that begins a `case`. The dispatcher's
    /// bare-key grammar is one switch over characters, so its cases are the claim.
    private static func switchCaseLiterals(in text: String) -> Set<String> {
        var keys: Set<String> = []
        for line in withoutComments(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            var rest = Substring(trimmed)
            while let range = rest.range(of: "\"") {
                let tail = String(rest[range.lowerBound...])
                guard let literal = firstStringLiteral(in: tail) else { break }
                keys.insert(literal)
                guard let after = tail.range(of: "\"", range: tail.index(after: tail.startIndex)..<tail.endIndex)
                else { break }
                rest = Substring(tail[after.upperBound...])
            }
        }
        return keys
    }

    // MARK: The scanner has to be able to see

    func testTheScannerFindsTheSourcesAndReadsShortcutsOutOfThem() {
        // A parity test whose scanner silently matches nothing passes every other
        // assertion in this file. This is the assertion that cannot be satisfied by
        // finding nothing.
        let files = Self.appSources
        XCTAssertGreaterThan(files.count, 20, "Sources/LumenApp not found at \(Self.repositoryRoot)")

        var literals = 0
        var sheetActions = 0
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                XCTFail("could not read \(file.lastPathComponent)")
                continue
            }
            for shortcut in Self.shortcuts(in: text) {
                if case .literal = shortcut { literals += 1 }
                if case .sheetAction = shortcut { sheetActions += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(literals, 15,
                                    "only \(literals) literal shortcuts read — the parser "
                                        + "has stopped seeing the call sites")
        XCTAssertGreaterThanOrEqual(sheetActions, 3,
                                    "the sheets' Return and Escape buttons went missing")
    }

    func testTheScannerReadsAKnownCallSiteExactly() {
        // The parser, pinned against hand-written examples of every form it has to
        // handle, so a change to it fails here rather than by quietly reporting less.
        let sample = """
        Button("Open") { }
            .keyboardShortcut("o", modifiers: [.command])
        Button("Unstack") { }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        Button("Clear") { }
            // .keyboardShortcut("q", modifiers: [.command])
            .keyboardShortcut("\\\\", modifiers: [.command])
        Button("Done") { }
            .keyboardShortcut(.defaultAction)
        Button("Step") { }
            .keyboardShortcut(decrement, modifiers: modifiers)
        Text("a .keyboardShortcut(\\"z\\", modifiers: [.command]) inside a string")
        """
        let read = Self.shortcuts(in: sample)
        // Six call sites are written above; four are real. The commented-out one and
        // the one inside a `Text` are prose, and a scanner that counted them would
        // demand a reference entry for a sentence.
        XCTAssertEqual(read, [
            .literal(KeyBinding("o", command: true)),
            .literal(KeyBinding("g", command: true, shift: true)),
            .literal(KeyBinding("\\", command: true)),
            .sheetAction,
            .computed("decrement, modifiers: modifiers"),
        ])
    }

    // MARK: 1 — every attached chord is declared, and every declared chord is attached

    func testEveryCommandShortcutInTheAppIsInTheReference() {
        var attached: Set<KeyBinding> = []
        var whereFound: [KeyBinding: String] = [:]
        for file in Self.appSources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for shortcut in Self.shortcuts(in: text) {
                guard case .literal(let binding) = shortcut else { continue }
                attached.insert(binding)
                whereFound[binding] = file.lastPathComponent
            }
        }

        let declared = KeyGrammar.declaredBindings
        for binding in attached.sorted(by: { $0.display < $1.display }) {
            XCTAssertTrue(declared.contains(binding),
                          "\(binding.display) is attached in "
                              + "\(whereFound[binding] ?? "?") and is in neither the "
                              + "dispatcher nor the keyboard reference")
        }
        for binding in declared.sorted(by: { $0.display < $1.display }) {
            XCTAssertTrue(attached.contains(binding),
                          "the reference promises \(binding.display) and nothing in "
                              + "Sources/LumenApp attaches it")
        }
    }

    // MARK: 2 — the bare-key grammar matches the dispatcher's own switch

    func testTheBareKeyGrammarMatchesTheDispatcher() {
        let keymap = Self.repositoryRoot
            .appendingPathComponent("Sources/LumenApp/Keymap.swift")
        guard let text = try? String(contentsOf: keymap, encoding: .utf8) else {
            XCTFail("Keymap.swift not found at \(keymap.path)")
            return
        }
        let claimed = Self.switchCaseLiterals(in: text)
        XCTAssertGreaterThan(claimed.count, 20,
                             "only \(claimed.count) dispatcher keys read — the scan has "
                                 + "stopped seeing the switch")
        XCTAssertEqual(claimed, KeyGrammar.dispatchedKeys,
                       "the dispatcher claims "
                           + "\(claimed.subtracting(KeyGrammar.dispatchedKeys).sorted()) "
                           + "that the reference does not, and the reference claims "
                           + "\(KeyGrammar.dispatchedKeys.subtracting(claimed).sorted()) "
                           + "that the dispatcher does not")
    }

    // MARK: 3 — the escape hatch is data

    func testAComputedShortcutOnlyExistsInAFileThatSaysWhy() {
        for file in Self.appSources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let computed = Self.shortcuts(in: text).filter {
                if case .computed = $0 { return true }
                return false
            }
            guard !computed.isEmpty else { continue }
            let reason = KeyGrammar.filesWithComputedShortcuts[file.lastPathComponent]
            XCTAssertNotNil(reason,
                            "\(file.lastPathComponent) attaches \(computed.count) "
                                + "shortcut(s) a scanner cannot read, and is not named "
                                + "in KeyGrammar.filesWithComputedShortcuts")
        }
        for (name, reason) in KeyGrammar.filesWithComputedShortcuts {
            XCTAssertFalse(reason.isEmpty, "\(name) is exempt with no reason given")
            let exists = Self.appSources.contains { $0.lastPathComponent == name }
            XCTAssertTrue(exists, "\(name) is exempt and does not exist")
        }
    }

    // MARK: The table's own consistency

    func testNoTwoEntriesClaimTheSameChord() {
        var seen: [KeyBinding: String] = [:]
        for entry in KeyGrammar.groups.flatMap(\.rows) {
            guard let binding = entry.binding else { continue }
            if let other = seen[binding] {
                XCTFail("\(binding.display) is claimed by both \"\(other)\" and "
                            + "\"\(entry.action)\"")
            }
            seen[binding] = entry.action
        }
    }

    func testEveryLineOfTheSheetSaysSomething() {
        XCTAssertFalse(KeyGrammar.groups.isEmpty)
        for group in KeyGrammar.groups {
            XCTAssertFalse(group.title.isEmpty)
            XCTAssertFalse(group.rows.isEmpty, "\(group.title) is an empty section")
            for entry in group.rows {
                XCTAssertFalse(entry.keys.isEmpty, "a line of \(group.title) has no key")
                XCTAssertFalse(entry.action.isEmpty,
                               "\(entry.keys) in \(group.title) has no description")
            }
        }
    }

    func testAChordIsPrintedTheWayItIsAttached() {
        // The key column of a menu-command line is rendered from its binding, so a
        // chord cannot be printed one way and bound another.
        for entry in KeyGrammar.groups.flatMap(\.rows) {
            guard let binding = entry.binding else { continue }
            XCTAssertEqual(entry.keys, binding.display)
        }
        XCTAssertEqual(KeyBinding("g", command: true, shift: true).display, "⇧⌘G")
        XCTAssertEqual(KeyBinding("c", command: true, option: true).display, "⌥⌘C")
        XCTAssertEqual(KeyBinding("\\", command: true).display, "⌘\\")
        XCTAssertEqual(KeyBinding("/", command: true).display, "⌘/")
    }
}

extension KeyGrammarTests {

    /// A SWIFTUI BUILDER TAKES TEN CHILDREN, AND SAYS SO IN A LANGUAGE NOBODY READS.
    ///
    /// `LumenCommands.body` is one `Group` of `CommandGroup`s and `CommandMenu`s. Adding
    /// an eleventh does not produce "too many children". It produces
    ///
    ///     error: 'buildExpression' is unavailable: this expression does not conform
    ///            to 'Commands'
    ///
    /// on the ELEVENTH line, followed by one "does not conform to 'View'" per child, and
    /// says nothing about arity at all. It reads as a type error about an expression that
    /// plainly IS a `Commands`. It cannot be reproduced here — `LumenApp` compiles only
    /// on macOS — and `swiftc -parse` is blind to it, because it is a type-check failure
    /// rather than a syntax one. It broke three CI lanes and cost a round trip.
    ///
    /// So the limit is asserted where it is cheap, in the file that already reads these
    /// sources as text. Counting braces would be writing a parser; counting the children
    /// at one known indentation inside one known `Group` fails before CI does, which is
    /// all this needs to do.
    func testTheCommandsBuilderStaysUnderItsTenChildLimit() throws {
        let file = Self.repositoryRoot
            .appendingPathComponent("Sources/LumenApp/LumenApp.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let children = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("            CommandGroup(")
                        || $0.hasPrefix("            CommandMenu(") }
        XCTAssertGreaterThan(children.count, 5,
                             "the scanner found almost nothing, so it is not scanning")
        XCTAssertLessThanOrEqual(children.count, 10,
                                 "a Commands builder takes ten children and this Group "
                                     + "has \(children.count). Nest a second Group — or "
                                     + "better, merge two menus that should have been "
                                     + "one. The compiler will only tell you that some "
                                     + "expression does not conform to Commands.")
    }
}
