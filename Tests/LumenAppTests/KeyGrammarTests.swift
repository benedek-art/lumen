// KeyGrammarTests.swift — the app target's half of "no chord is spent twice".
//
// `LumenCoreTests/KeyGrammarTests.swift` is the parity mechanism: it reads
// `Sources/LumenApp` as text and fails when a chord is attached and not declared, or
// declared and not attached. It ran GREEN, for as long as the defect existed, over ⌘B
// attached TWICE to two different verbs — the sidebar's "Add to target album" button
// and the View menu's Assessment Surround (G3-01 / J2-01).
//
// IT COULD NOT HAVE FAILED, AND THAT IS THE POINT OF THIS FILE. Its scan collects call
// sites into
//
//     var attached: Set<KeyBinding> = []
//
// and a Set answers "WHICH chords are attached". It cannot answer "how many times",
// because answering that is the one thing a set is defined not to do: two files
// claiming ⌘B insert the same element twice and the set still has exactly one member,
// so both directions of its set-equality pass unchanged. The companion diagnostic map
// `whereFound[binding] = file.lastPathComponent` ASSIGNS rather than appends, so even
// if something had noticed, the message would have named only the last file scanned.
// And the suite's one duplicate check, `testNoTwoEntriesClaimTheSameChord`, walks
// `KeyGrammar.groups` — the reference TABLE against itself — and never looks at a call
// site at all. So nothing anywhere asked "is any chord attached twice in the source",
// which is the single question a keymap guard exists to ask.
//
// This file asks it, with a MULTISET: the same scan, collecting into
// `[KeyBinding: [String]]`, failing when any chord's list has more than one site and
// naming every site. The set-based parity tests in LumenCoreTests stay exactly as they
// are — they answer a different and still-correct question — and are not touched here.
//
// The scanner below is ported from that file deliberately rather than shared: these
// are different test targets (LumenCore's suite runs on Linux, this one on the macOS
// lane where LumenApp actually compiles), and the pinning test here fails if the port
// ever stops reading a call site the way the original does.
#if os(macOS)

import XCTest
import LumenCore

final class KeyGrammarAttachmentTests: XCTestCase {

    // MARK: Finding the sources

    /// The repository, from this file's own path — the same route LumenCoreTests takes.
    /// `Bundle.module` carries resources, not sources, and the sources are the subject.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
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

    // MARK: Reading `.keyboardShortcut` call sites

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and a line number can still be counted off the result.
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

    /// The chord an argument list names, or `nil` when it does not name one.
    ///
    /// `nil` covers the two forms that are NOT an application-wide chord and must never
    /// be counted as duplicates of each other: `.defaultAction` / `.cancelAction`, which
    /// are one sheet's Return and Escape and legitimately appear in every sheet in the
    /// app; and a key computed at the call site, which `LookPanel` does in a loop and
    /// which no scanner can read.
    private static func chord(in argument: String) -> KeyBinding? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""), let key = firstStringLiteral(in: trimmed) else {
            return nil
        }
        let modifiers = trimmed.contains("modifiers:")
            ? String(trimmed[trimmed.range(of: "modifiers:")!.upperBound...])
            : ""
        return KeyBinding(key,
                          command: modifiers.contains(".command"),
                          shift: modifiers.contains(".shift"),
                          option: modifiers.contains(".option"),
                          control: modifiers.contains(".control"))
    }

    /// Every literal chord attached in `text`, with the 1-based line it sits on.
    ///
    /// The walk steps OVER string literals rather than blanking them, for two reasons
    /// that pull opposite ways: the key itself IS a string literal, so blanking would
    /// make every binding unreadable — and a `.keyboardShortcut(` written inside a
    /// string, as this file's own sample does, is prose rather than a call site. Paren
    /// depth skips strings too, so a `"("` key equivalent cannot run the scan off the
    /// end of the call.
    private static func attachments(in text: String) -> [(binding: KeyBinding, line: Int)] {
        let source = Array(withoutComments(text))
        let needle = Array(".keyboardShortcut(")
        var found: [(binding: KeyBinding, line: Int)] = []
        var i = 0
        var line = 1

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

        /// Newlines between `from` and `to`, so `line` tracks a jumping cursor.
        func advance(_ from: Int, _ to: Int) {
            var k = from
            while k < Swift.min(to, source.count) {
                if source[k] == "\n" { line += 1 }
                k += 1
            }
        }

        while i < source.count {
            if source[i] == "\"" {
                let end = endOfString(i)
                advance(i, end)
                i = end
                continue
            }
            guard i + needle.count <= source.count,
                  Array(source[i..<(i + needle.count)]) == needle else {
                if source[i] == "\n" { line += 1 }
                i += 1
                continue
            }
            let siteLine = line
            var j = i + needle.count
            advance(i, j)
            var depth = 1
            var argument = ""
            while j < source.count && depth > 0 {
                if source[j] == "\"" {
                    let end = endOfString(j)
                    argument += String(source[j..<Swift.min(end, source.count)])
                    advance(j, end)
                    j = end
                    continue
                }
                let c = source[j]
                if c == "\n" { line += 1 }
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                argument.append(c)
                j += 1
            }
            if let binding = chord(in: argument) { found.append((binding, siteLine)) }
            i = j
        }
        return found
    }

    /// THE MULTISET. Every chord in the app, mapped to EVERY site that attaches it.
    ///
    /// This is the whole difference from the parity scan: `[KeyBinding: [String]]`
    /// where that one has `Set<KeyBinding>`. A dictionary of arrays keeps the second
    /// attachment; a set discards it and reports success.
    private static func attachmentSites(
        in files: [(name: String, text: String)]
    ) -> [KeyBinding: [String]] {
        var sites: [KeyBinding: [String]] = [:]
        for file in files {
            for site in attachments(in: file.text) {
                sites[site.binding, default: []].append("\(file.name):\(site.line)")
            }
        }
        return sites
    }

    private static func loadedAppSources() -> [(name: String, text: String)] {
        appSources.compactMap { url -> (name: String, text: String)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return (name: url.lastPathComponent, text: text)
        }
    }

    // MARK: The scanner has to be able to see

    func testTheScannerFindsTheAppSourcesAndReadsChordsOutOfThem() {
        // A duplicate check whose scanner silently matches nothing passes forever. This
        // is the assertion that cannot be satisfied by finding nothing — the failure
        // shape this entire file exists to close, arriving through its own front door.
        let files = Self.loadedAppSources()
        XCTAssertGreaterThan(files.count, 20,
                             "Sources/LumenApp not found at \(Self.repositoryRoot)")
        let sites = Self.attachmentSites(in: files)
        let total = sites.values.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThanOrEqual(total, 15,
                                    "only \(total) literal chords read — the scanner "
                                        + "has stopped seeing the call sites")
    }

    func testTheDuplicateCheckActuallyDetectsADuplicate() {
        // The check, pinned against a hand-written pair. Written the way the defect was
        // written: one chord, two files, two different verbs — plus a third chord that
        // is attached once and must NOT be reported, and a `.defaultAction` in each
        // file, which every sheet in the app has and which is not a chord at all.
        let sidebar = """
        Button("Add to Album") { }
            .keyboardShortcut("b", modifiers: [.command])
            .help("Add the selection to the target album")
        Button("Stack") { }
            .keyboardShortcut("g", modifiers: [.command])
        Button("Done") { }
            .keyboardShortcut(.defaultAction)
        """
        let menu = """
        Button("Assessment Surround") { }
            .keyboardShortcut("b", modifiers: [.command])
        Button("OK") { }
            .keyboardShortcut(.defaultAction)
        """
        let sites = Self.attachmentSites(in: [(name: "Sidebar.swift", text: sidebar),
                                              (name: "Menu.swift", text: menu)])

        XCTAssertEqual(sites[KeyBinding("b", command: true)] ?? [],
                       ["Sidebar.swift:2", "Menu.swift:2"],
                       "the multiset lost one of the two ⌘B sites, which is exactly "
                           + "what the Set-based scan does")
        XCTAssertEqual(sites[KeyBinding("g", command: true)] ?? [], ["Sidebar.swift:5"])
        XCTAssertEqual(sites.filter { $0.value.count > 1 }.count, 1,
                       "the sheets' Return buttons were counted as a duplicated chord")
    }

    // MARK: The check that was missing

    /// NO CHORD IS ATTACHED TWICE — the question `Set<KeyBinding>` cannot be asked.
    ///
    /// Red before G3-01 / J2-01 was fixed, with
    ///
    ///     ⌘B is attached in 2 places: ContentView.swift:514, LumenApp.swift:245.
    ///
    /// Two attachments of one chord is never a duplicate of a decision — it is a chord
    /// that does one of two things, and nothing in the tree decides which. A menu
    /// item's key equivalent is offered by the main menu before the window's view
    /// hierarchy sees the event, so the menu wins and the other site is a dead
    /// shortcut, usually still wearing a `.help` that promises it. ⌘B's other site
    /// wrote to the catalog through `addSelectionToTargetCollection`, which does not
    /// `history.record`, so the branch that lost was also the unundoable one.
    func testNoChordIsAttachedTwiceAnywhereInTheApp() {
        let files = Self.loadedAppSources()
        XCTAssertGreaterThan(files.count, 20,
                             "Sources/LumenApp not found — this test cannot pass by "
                                 + "scanning nothing")
        let sites = Self.attachmentSites(in: files)
        XCTAssertGreaterThanOrEqual(sites.count, 15,
                                    "only \(sites.count) distinct chords read — the "
                                        + "scanner has stopped seeing the call sites")

        let ordered = sites.sorted { $0.key.display < $1.key.display }
        for (binding, places) in ordered where places.count > 1 {
            XCTFail("\(binding.display) is attached in \(places.count) places: "
                        + "\(places.joined(separator: ", ")). One chord, one verb — "
                        + "the main menu wins and every other site is a dead shortcut. "
                        + "Delete the ones the keymap did not decide on, and fix any "
                        + "`.help` that still advertises the chord.")
        }
    }
}

#endif
