// LookBrowserVerbTests.swift
// D1-02 and D1-03: the saved-look browser's verbs — that the safe one is reachable and
// that the two destructive ones are guarded.
//
// A TEXT SCAN, and it has to be. `LookPanel` lives in LumenApp, which is macOS-only and
// has no test target that runs here, so there is no way to build the view and press its
// buttons. What can be checked without a compiler is the thing both defects were: a
// verb that is fully implemented underneath and called by nothing, and two verbs wired
// straight from a click to a write. Both are visible in the panel's text.
//
// COMMENTS ARE STRIPPED BEFORE EVERY SCAN. This file's whole subject is symbols that
// exist in prose and nowhere else — `renameLook` was named in four doc comments while
// having zero callers — so a scan that counted a doc comment would pass its own
// substitution proof and certify the exact defect it was written to catch. The helper
// is copied from `DeliveryNameTests` rather than shared, for the reason
// `CaptureSharpenScopeTests` gives: a helper shared between two files that assert
// unrelated things is a third thing to keep true.

import XCTest
@testable import LumenCore

final class LookBrowserVerbTests: XCTestCase {

    // MARK: - D1-02: the safe verb has a caller

    /// Rename is the only non-destructive operation the look library has — it is how a
    /// second variant of a look is kept, which `CatalogStore.saveLook`'s own comment
    /// says outright. It was implemented in the store, the service and `AppState`, and
    /// covered by two catalog tests, and no view called it.
    func testRenameIsReachableFromTheBrowser() throws {
        let panel = Self.strippingComments(try Self.appSource("LookPanel.swift"))
        XCTAssertTrue(panel.contains("state.renameLook("),
                      "the look browser calls nothing that renames a look, so a "
                      + "mistyped name is permanent: the only ways to correct it are "
                      + "to save over the look from a frame that still wears it, or to "
                      + "delete it and start again")
        XCTAssertTrue(panel.contains("title: \"Rename\""),
                      "rename is called from somewhere in the panel but never offered "
                      + "as a word the photographer can find — a verb reachable only "
                      + "by guessing is not reachable")
    }

    // MARK: - D1-03: the destructive verbs ask first

    /// Delete used to be a bare trash glyph one row-height from the full-width Apply
    /// button, wired straight to `DELETE FROM look`. Looks are not in `HistoryStack` —
    /// undo replays recipes, not catalog rows — so the slip is final.
    func testDeletingALookAsksBeforeItThrowsItAway() throws {
        let panel = Self.strippingComments(try Self.appSource("LookPanel.swift"))
        let calls = panel.components(separatedBy: "state.deleteLook(").count - 1
        XCTAssertEqual(calls, 1,
                       "a look library needs exactly one door out; \(calls) call sites "
                       + "means at least one of them is unguarded")
        let row = try Self.body(after: "private func savedLookRow(", in: panel)
        let uptoDelete = try XCTUnwrap(row.range(of: "state.deleteLook("),
                                       "the row that draws a look must be the row that "
                                       + "confirms throwing it away")
        let beforeTheWrite = String(row[row.startIndex..<uptoDelete.lowerBound])
        XCTAssertTrue(beforeTheWrite.contains("pendingDeleteLookID == look.id"),
                      "one click still deletes a saved look. A pointer slip one row "
                      + "high and a look the photographer built over a season is gone, "
                      + "with the status bar telling him so afterwards")
        XCTAssertTrue(row.contains("\"Keep\""),
                      "the armed delete offers no way out but the deletion itself — a "
                      + "question with one answer is not a question")
    }

    /// Save was enabled on "is this a usable name" and nothing else, so typing a name
    /// that was already taken replaced what was stored under it, and the status bar
    /// picked its past tense afterwards.
    func testSavingOverALookIsSaidOutLoudBeforeItHappens() throws {
        let panel = Self.strippingComments(try Self.appSource("LookPanel.swift"))
        let save = try Self.body(after: "private func saveCurrentLook(", in: panel)
        let write = try XCTUnwrap(save.range(of: "state.saveCurrentLook("),
                                  "the panel's save must reach AppState's save")
        let beforeTheWrite = String(save[save.startIndex..<write.lowerBound])
        XCTAssertTrue(beforeTheWrite.contains("collidingName"),
                      "the panel writes without ever asking whether that name is "
                      + "taken, so saving a tweak under the name he has used all year "
                      + "silently overwrites the version he liked")
        let arm = try XCTUnwrap(beforeTheWrite.range(of: "replaceWarnedName"),
                                "the collision is noticed and the write happens "
                                + "anyway: the photographer is told which look he "
                                + "destroyed, not asked")
        // The arm has to STOP the press, not merely record it. `guard canSaveLook else
        // { return }` is already up here, so a scan for any `return` in the whole body
        // is green on a panel that writes unconditionally — this one has to fall after
        // the collision is known.
        XCTAssertTrue(beforeTheWrite[arm.lowerBound...].contains("return"),
                      "nothing stops the first press, so the warning arrives with the "
                      + "overwrite rather than instead of it")
        // Warn and offer, not block: save-over is a real gesture and the store is
        // built for it. What the photographer loses without the offer is the outcome
        // he probably wanted — both versions kept.
        XCTAssertTrue(panel.contains("distinctNameSuggestion"),
                      "the warning refuses the save without offering a free name, so "
                      + "keeping both versions means backing out and inventing one")
    }

    /// The other half of D1-03's row: an unlabelled 10-point glyph is a control you can
    /// only learn by trying it, and trying it is the destructive act.
    func testTheRowsVerbsAreWords() throws {
        let panel = Self.strippingComments(try Self.appSource("LookPanel.swift"))
        let row = try Self.body(after: "private func savedLookRow(", in: panel)
        XCTAssertFalse(row.contains("Image(systemName: \"trash\")"),
                       "the row still hangs a bare trash glyph beside Apply: nothing "
                       + "on it says what it does until it has done it")
        for verb in ["\"Apply\"", "\"Rename\"", "\"Delete\""] {
            XCTAssertTrue(panel.contains("title: " + verb),
                          "the browser offers no \(verb) the photographer can read; a "
                          + "look library whose operations have to be discovered by "
                          + "clicking is one he will not use")
        }
    }

    // MARK: - the one fact the offer rests on, on this side of the module boundary

    /// `LookPanel.distinctName` trims the base before appending " 2" instead of just
    /// appending. This is why: the store truncates at `maximumNameLength`, so a
    /// suggestion that only appended would normalize straight back onto the name it was
    /// offered to avoid — and the button promising to keep both would replace instead.
    func testANameAtTheLimitCannotSimplyGrowATag() {
        let long = String(repeating: "a", count: LookSubset.maximumNameLength)
        XCTAssertEqual(LookSubset.normalizedName(long), long)
        XCTAssertEqual(LookSubset.normalizedName(long + " 2"), long,
                       "the tag is truncated off, so \"save as X 2 instead\" would "
                       + "quietly overwrite X — the photographer asked for both and "
                       + "would be left with one")
    }

    // MARK: - helpers

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The braces of the declaration `anchor` opens, so an assertion about a row cannot
    /// be satisfied by a line somewhere else in a 1400-line file.
    private static func body(after anchor: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: anchor),
                                  "\(anchor) is gone from the panel")
        var index = start.upperBound
        while index < source.endIndex, source[index] != "{" {
            index = source.index(after: index)
        }
        guard index < source.endIndex else { return "" }
        var depth = 0
        let open = index
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return String(source[open...])
    }

    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
