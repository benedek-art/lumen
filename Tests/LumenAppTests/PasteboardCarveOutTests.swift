// PasteboardCarveOutTests.swift — the four chords the Edit menu was taking from every
// text field in the application, and the three the sidebar was taking with it when it
// closed.
//
// WHAT WAS WRONG. `LumenCommands` replaces the whole `.pasteboard` command group. That
// is not "adds items beside Cut/Copy/Paste/Select All" — it DELETES AppKit's four and
// puts the develop-settings verbs in their place, for the whole application, in every
// context. A menu item's key equivalent is offered by `NSMenu` before the key window's
// responder chain sees the event, which is the same rule that made ⌘B a dead shortcut on
// the album button. So inside a keyword field, a new-album field or the export sheet's
// filename, ⌘C copied a recipe instead of the selected text, ⌘V pasted one over it, ⌘A
// selected photographs, and ⌘X was bound to nothing at all — AppKit's Cut item had gone
// with the group and nothing replaced it. Four chords, every text field in the app.
//
// And ⌥⌘S took three more. `NavigationSplitView` at `.detailOnly` does not merely hide
// the sources sidebar, it takes the column out of the view tree — and a
// `.keyboardShortcut` on a view that is not in the hierarchy is never registered. ⌘G,
// ⇧⌘G and ⇧⌘K were all attached to buttons inside that column, so all three died the
// moment a photographer hid it, silently, while the Help sheet went on printing them.
// The sidebar had already learned half of this lesson — its own comments explain that a
// shortcut inside a COLLAPSED SECTION is dead and hoist each one above the fold — and
// stopped one `if` short of the one that contains all of them.
//
// WHY THIS IS A TEXT SCAN. Both defects are properties of the SOURCE — which items exist,
// which chord each carries, and what each action does before it reaches a photo verb —
// and none of them can be observed without a running `NSApplication`, a key window and a
// first responder. `KeyGrammarTests` in this target reads these same files for the same
// reason; the scanner below is ported from it deliberately rather than shared, the way
// that one is ported from LumenCoreTests', so a change to either fails here rather than
// quietly reporting less.
//
// COMMENTS ARE BLANKED BEFORE ANYTHING IS SCANNED, and in this file that is not a
// nicety. `LumenApp.swift` explains this carve-out at length in prose that names
// `TextEditingFocus` and the chords it covers; a scan over the raw text would therefore
// find every symbol it is looking for in a tree where the fix had been deleted and the
// argument for it left behind. `testTheScannerIgnoresACommentThatNamesTheFix` pins that
// the stripper is the thing standing between this suite and passing its own substitution
// proof.
#if os(macOS)

import XCTest
import LumenCore

final class PasteboardCarveOutTests: XCTestCase {

    // MARK: Finding the sources

    /// The repository, from this file's own path — the route both key-grammar suites
    /// take. `Bundle.module` carries resources, and the sources are the subject.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private static var appSourceDirectory: URL {
        repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
    }

    private static var appSources: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: appSourceDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "swift" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// One source, with its comments already blanked — every assertion in this file
    /// wants it that way, so nothing reads the raw text by accident.
    private static func source(_ name: String) throws -> String {
        let url = appSourceDirectory.appendingPathComponent(name)
        return withoutComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: The scanner

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and the order of two symbols inside one action is still a fact
    /// this file can check.
    ///
    /// One pass rather than two regexes, because a `//` inside a string and a `"` inside
    /// a comment each break the other's pattern.
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

    /// The contents of the first `"…"` in `text`, with `\\` escapes resolved.
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

    /// Every literal chord attached anywhere in `text`.
    ///
    /// Paren depth steps OVER string literals, which is not fussiness: the key itself is
    /// a string literal, and a `"("` key equivalent would otherwise run the scan off the
    /// end of the call. `.defaultAction` and a computed key are not application-wide
    /// chords and are dropped rather than guessed at.
    private static func chords(in text: String) -> [KeyBinding] {
        let source = Array(text)
        let needle = Array(".keyboardShortcut(")
        var found: [KeyBinding] = []
        var i = 0

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
            let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\""), let key = firstStringLiteral(in: trimmed) {
                let modifiers = trimmed.contains("modifiers:")
                    ? String(trimmed[trimmed.range(of: "modifiers:")!.upperBound...])
                    : ""
                found.append(KeyBinding(key,
                                        command: modifiers.contains(".command"),
                                        shift: modifiers.contains(".shift"),
                                        option: modifiers.contains(".option"),
                                        control: modifiers.contains(".control")))
            }
            i = j
        }
        return found
    }

    /// The menu items of `text`, one string each: a line that starts a `Button(`, plus
    /// everything after it up to the next one.
    ///
    /// Deliberately crude, and it holds because of how this menu is written — an item's
    /// action and its `.keyboardShortcut` and its `.disabled` are one chain, and the
    /// only thing that ends the chain is the next item. A block therefore contains
    /// exactly one action and the chord that fires it, which is the pair every assertion
    /// below is about. Anything before the first `Button(` is not an item and is dropped.
    private static func buttonBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("Button(") {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = [String(line)]
            } else if !current.isEmpty {
                current.append(String(line))
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    /// The one item that attaches `binding`, or nil.
    private static func block(carrying binding: KeyBinding, in text: String) -> String? {
        buttonBlocks(in: text).first { chords(in: $0).contains(binding) }
    }

    // MARK: The scanner has to be able to see

    func testTheScannerReadsItemsAndTheChordsTheyCarry() throws {
        // The parser, pinned against hand-written examples of every form this menu
        // actually uses: a one-line action, a multi-line action with the chord below the
        // closing brace, a key equivalent that is itself an open paren, and a sheet's
        // Return button, which is not an application-wide chord at all.
        let sample = Self.withoutComments("""
        Button("Cut") { _ = TextEditingFocus.cut() }
            .keyboardShortcut("x", modifiers: [.command])
        Button("Copy Settings") {
            if TextEditingFocus.copy() { return }
            state.copySettings()
        }
        .keyboardShortcut("c", modifiers: [.command])
        Button("Open Paren") { }
            .keyboardShortcut("(", modifiers: [.command, .option])
        Button("Done") { }
            .keyboardShortcut(.defaultAction)
        """)

        let blocks = Self.buttonBlocks(in: sample)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(Self.chords(in: blocks[0]), [KeyBinding("x", command: true)])
        XCTAssertEqual(Self.chords(in: blocks[1]), [KeyBinding("c", command: true)])
        XCTAssertEqual(Self.chords(in: blocks[2]),
                       [KeyBinding("(", command: true, option: true)])
        XCTAssertEqual(Self.chords(in: blocks[3]), [],
                       "a sheet's Return button was read as an application-wide chord")
        XCTAssertTrue(blocks[1].contains("state.copySettings()"),
                      "the block lost the action its chord fires")
    }

    /// THE STRIPPER IS WHAT MAKES THIS SUITE FALSIFIABLE, so it is pinned on its own.
    ///
    /// `LumenApp.swift` argues for this carve-out in prose that names `TextEditingFocus`
    /// and the four chords by hand. Delete the fix and leave the paragraph — which is
    /// exactly what a half-finished revert looks like — and a scan over raw text still
    /// finds every symbol it wants. Every assertion in this file reads comment-blanked
    /// source for that reason, and this is the test that says so.
    func testTheScannerIgnoresACommentThatNamesTheFix() {
        let sample = Self.withoutComments("""
        // The carve-out: `if TextEditingFocus.copy() { return }` before the settings
        // verb, so ⌘C reaches the text field first.
        Button("Copy Settings") { state.copySettings() }
            .keyboardShortcut("c", modifiers: [.command])
        """)
        let block = Self.block(carrying: KeyBinding("c", command: true), in: sample)
        XCTAssertNotNil(block)
        XCTAssertFalse(block?.contains("TextEditingFocus") ?? true,
                       "a doc comment naming the fix was read as the fix, which would "
                           + "make every assertion in this file pass over a tree where "
                           + "the carve-out had been deleted")
    }

    // MARK: The carve-out itself

    /// EVERY STANDARD EDITING CHORD REACHES WHATEVER IS TYPING.
    ///
    /// Red before this shipped, on ⌘X with
    ///
    ///     ⌘X is attached nowhere in LumenApp.swift — replacing the .pasteboard group
    ///     deleted AppKit's Cut item and nothing put it back
    ///
    /// and on the other three with "…attaches no TextEditingFocus.copy()", which is the
    /// item answering the chord with a recipe while somebody is editing a filename.
    func testEveryStandardEditingChordReachesTheTextField() throws {
        let menu = try Self.source("LumenApp.swift")
        XCTAssertGreaterThan(Self.buttonBlocks(in: menu).count, 15,
                             "almost no menu items read — the scanner is not scanning, "
                                 + "and every assertion below would pass on nothing")

        let carveOuts: [(KeyBinding, String)] = [
            (KeyBinding("x", command: true), "TextEditingFocus.cut()"),
            (KeyBinding("c", command: true), "TextEditingFocus.copy()"),
            (KeyBinding("v", command: true), "TextEditingFocus.paste()"),
            (KeyBinding("a", command: true), "TextEditingFocus.selectAll()"),
        ]
        for (binding, forward) in carveOuts {
            guard let block = Self.block(carrying: binding, in: menu) else {
                XCTFail("\(binding.display) is attached nowhere in LumenApp.swift — "
                            + "replacing the .pasteboard group deletes AppKit's own "
                            + "item, so a chord with no item here is a chord the whole "
                            + "application has lost")
                continue
            }
            XCTAssertTrue(block.contains(forward),
                          "\(binding.display) attaches no \(forward), so the menu bar "
                              + "answers it before the responder chain ever sees it — "
                              + "and a photographer typing into a keyword field gets the "
                              + "photo verb instead of the text one")
        }
    }

    /// AND THE DEVELOP-SETTINGS MEANING IS GATED ON A NON-TEXT FOCUS — the other half,
    /// which "the symbol is present somewhere in the block" does not prove.
    ///
    /// An item that runs `state.copySettings()` and THEN offers the key to the text
    /// field has copied a recipe over the photographer's clipboard on the way past. So
    /// the order is the assertion: the carve-out must sit before the photo verb, which
    /// is what makes the photo verb the fall-through rather than the default.
    func testTheDevelopSettingsVerbsRunOnlyWhenNoTextFieldHasFocus() throws {
        let menu = try Self.source("LumenApp.swift")
        let pairs: [(KeyBinding, String, String)] = [
            (KeyBinding("c", command: true), "TextEditingFocus.copy()",
             "state.copySettings()"),
            (KeyBinding("v", command: true), "TextEditingFocus.paste()",
             "state.pasteSettings()"),
            (KeyBinding("a", command: true), "TextEditingFocus.selectAll()",
             "state.selectAll()"),
        ]
        for (binding, forward, photoVerb) in pairs {
            guard let block = Self.block(carrying: binding, in: menu),
                  let guardRange = block.range(of: forward),
                  let verbRange = block.range(of: photoVerb) else {
                XCTFail("\(binding.display) does not carry both \(forward) and "
                            + "\(photoVerb) in one item")
                continue
            }
            XCTAssertLessThan(guardRange.lowerBound, verbRange.lowerBound,
                              "\(binding.display) runs \(photoVerb) before it offers the "
                                  + "chord to the text field, so the recipe on the "
                                  + "clipboard is already gone by the time the carve-out "
                                  + "is consulted")
        }
    }

    /// ⌘X IS THE TEXT FIELD'S ALONE, and that is a decision rather than an omission.
    ///
    /// Lumen has no cut: the folder is the library, files are never moved or modified,
    /// and taking a frame out of an album is a right-click verb on a row rather than a
    /// pasteboard operation. Inventing a photo meaning to fill the item would put a
    /// chord nobody asked for in front of the one every Mac user expects. This asserts
    /// the item forwards and does nothing else, so a later photo verb has to argue with
    /// this comment before it lands.
    func testCutBelongsToTheTextFieldAlone() throws {
        let menu = try Self.source("LumenApp.swift")
        guard let block = Self.block(carrying: KeyBinding("x", command: true),
                                     in: menu) else {
            return XCTFail("⌘X is attached nowhere in LumenApp.swift")
        }
        let action = block.components(separatedBy: ".keyboardShortcut(").first ?? block
        XCTAssertTrue(action.contains("TextEditingFocus.cut()"))
        XCTAssertFalse(action.contains("state."),
                       "⌘X grew a photo meaning. Lumen has no cut — if that changed, "
                           + "the keyboard reference and this test change with it")
    }

    // MARK: One answer to "is the photographer typing"

    /// THE PREDICATE HAS ONE HOME. `KeyDispatcher` had the only copy, written out inline,
    /// which was correct for as long as its `NSEvent` monitor was the only thing standing
    /// in front of a text field. The menu bar stands further in front — `NSMenu` offers a
    /// key equivalent before the key window's responder chain sees the event — so a
    /// second copy would have been two hand-rolled answers to one question, which is the
    /// shape every drift this codebase has closed began as.
    func testThereIsOneAnswerToWhetherATextFieldHasFocus() throws {
        let focus = try Self.source("LumenFocus.swift")
        XCTAssertTrue(focus.contains("enum TextEditingFocus"),
                      "the focus model has left LumenFocus.swift")
        XCTAssertTrue(focus.contains("responder is NSTextView"),
                      "TextEditingFocus no longer asks the first responder anything")

        let keymap = try Self.source("Keymap.swift")
        XCTAssertTrue(keymap.contains("TextEditingFocus.isActive"),
                      "the dispatcher has stopped standing down through the shared "
                          + "predicate")

        let sources = Self.appSources
        XCTAssertGreaterThan(sources.count, 20,
                             "Sources/LumenApp not found at \(Self.repositoryRoot)")
        for url in sources where url.lastPathComponent != "LumenFocus.swift" {
            let text = Self.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(text.contains("is NSTextView"),
                           "\(url.lastPathComponent) hand-rolls a second first-responder "
                               + "test. There is one, in LumenFocus.swift, and both the "
                               + "dispatcher and the menu bar have to ask it the same "
                               + "question or they will disagree about who is typing")
        }
    }

    // MARK: The three chords ⌥⌘S used to kill

    /// A CHORD THAT LIVES IN THE SIDEBAR DIES WITH THE SIDEBAR.
    ///
    /// `NavigationSplitView` at `.detailOnly` takes the whole column out of the view
    /// tree, and a `.keyboardShortcut` on a view that is not in the hierarchy is never
    /// registered — the rule this app has now paid for four times. ⌘G, ⇧⌘G and ⇧⌘K were
    /// attached to buttons inside that column, so ⌥⌘S killed all three at once while the
    /// Help sheet went on printing them. A `Scene`'s commands are always registered,
    /// which is why ⌘1–⌘5 and ⌘K already live there.
    ///
    /// Both directions, because only checking the Scene would pass while a second copy
    /// sat in the sidebar — and two attachments of one chord is a dead shortcut with the
    /// menu winning, which `KeyGrammarAttachmentTests` fails on separately.
    func testTheSidebarsChordsAreAttachedInTheSceneAndNowhereElse() throws {
        let menu = try Self.source("LumenApp.swift")
        let hoisted = [KeyBinding("g", command: true),
                       KeyBinding("g", command: true, shift: true),
                       KeyBinding("k", command: true, shift: true)]
        let inTheScene = Self.chords(in: menu)
        XCTAssertGreaterThan(inTheScene.count, 15,
                             "only \(inTheScene.count) chords read out of LumenApp.swift "
                                 + "— the scanner has stopped seeing the call sites")

        for binding in hoisted {
            XCTAssertTrue(inTheScene.contains(binding),
                          "\(binding.display) is not attached in the Scene's commands, "
                              + "so it is registered only while whatever view holds it "
                              + "is on screen")
        }
        for url in Self.appSources where url.lastPathComponent != "LumenApp.swift" {
            let text = Self.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            for binding in hoisted where Self.chords(in: text).contains(binding) {
                XCTFail("\(binding.display) is still attached in "
                            + "\(url.lastPathComponent). The main menu wins that chord, "
                            + "so this site is a dead shortcut — and if it sits in the "
                            + "sources sidebar it is also the one that ⌥⌘S switches off")
            }
        }
    }

    /// ⇧⌘K IS "LET ME TYPE A KEYWORD", so hoisting it is only half a fix: the chord has
    /// to bring the column back before it asks for the cursor, or the photographer gets
    /// a focus request aimed at a field that is not on screen.
    func testKeywordingShowsTheSidebarBeforeItAsksForTheCursor() throws {
        let menu = try Self.source("LumenApp.swift")
        guard let block = Self.block(carrying: KeyBinding("k", command: true,
                                                          shift: true), in: menu) else {
            return XCTFail("⇧⌘K is attached nowhere in LumenApp.swift")
        }
        guard let showRange = block.range(of: "state.sidebarVisible = true"),
              let askRange = block.range(of: "KeywordEntry.shared.request()") else {
            return XCTFail("⇧⌘K no longer both shows the sidebar and asks for the "
                               + "keyword field — pressed with the sidebar hidden it "
                               + "aims the cursor at a column that is not in the tree")
        }
        XCTAssertLessThan(showRange.lowerBound, askRange.lowerBound,
                          "the request is raised before the column is put back, so the "
                              + "section that answers it is not there to hear it")
    }
}

#endif
