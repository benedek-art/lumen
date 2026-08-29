// WorkspaceEntryTests.swift
// The mechanism behind "there is one way into a workspace".
//
// THIS DEFECT SHIPPED THREE TIMES, in three different clothes, and each time it was fixed
// at the call site where it was noticed:
//
//   1. ⌘1 selected the Cull workspace and left the photographer in the loupe, looking at
//      one photograph with 320 points of empty space where the develop column had been.
//      Fixed by pairing `select` with `showGrid` — at the menu item.
//   2. ⌘3 selected the Crop workspace without arming the crop tool, so the rectangle never
//      appeared. Fixed by pairing `select` with `showCrop` — at the menu item.
//   3. And then the owner clicked the Crop TAB, which calls neither of those pairs because
//      both were written into the menu, and reported the tool missing: "I don't really
//      know how to edit it by hand." Nothing was missing. The tab did not arm it.
//
// The pattern is not "three bugs". It is one bug: **a workspace is a place, `select` moves
// only the furniture, and every caller was left to remember the rest.** Callers do not
// remember. `AppState.enter` and `AppState.jump` are the remembering, and this file is
// what stops a fourth route from being added beside them.
//
// A TEXT SCAN, in LumenCore's suite, for the reason `KeyGrammarTests` gives at length:
// `Sources/LumenApp` is `#if os(macOS)`, it compiles on one CI lane and nowhere else, and
// it has no test target that runs here. Every defect in the interaction audit was
// invisible for exactly that reason. Reading the sources as text is the only assertion
// available, and it is enough for this one, because the claim is about which files call
// which verb.

import XCTest
@testable import LumenCore

final class WorkspaceEntryTests: XCTestCase {

    // MARK: Finding the sources

    private static var appSources: [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
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
    /// The same walk `KeyGrammarTests` uses and for the same reason: a `//` inside a
    /// string and a `"` inside a comment each break the other's regex, so one pass that
    /// understands both is the only correct shape. Copied rather than shared because the
    /// two files assert unrelated things and a shared helper between two scanners is a
    /// third thing to keep true.
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

    private static func source(named name: String) -> String {
        guard let url = appSources.first(where: { $0.lastPathComponent == name }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return withoutComments(text)
    }

    // MARK: The single door

    /// `PanelLayout`'s three navigation verbs are called from ONE file.
    ///
    /// `select`, `reveal` and `expose` move the column's arrangement and, by design, can
    /// reach nothing else — `PanelLayout`'s own header states that nothing in it touches
    /// `AppState`, and `WorkspaceLayout` lives in LumenCore where `AppState` does not
    /// exist. That separation is right and it is exactly why calling them directly is
    /// wrong: the arrangement is one third of what arriving somewhere means.
    ///
    /// Two files may hold these calls. `PanelLayout.swift` declares them. `WorkspaceEntry.swift`
    /// is the layer above that pairs each with the view mode and the crop tool. A third
    /// file naming one of them is a route that will be missing whatever gets added next.
    func testTheColumnsNavigationVerbsAreCalledFromExactlyOnePlace() {
        let allowed: Set<String> = ["PanelLayout.swift", "WorkspaceEntry.swift"]
        let verbs = [".select(", ".reveal(", ".expose("]
        var offenders: [String] = []

        for url in Self.appSources where !allowed.contains(url.lastPathComponent) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = Self.withoutComments(raw)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // Anchored on the receiver as well as the verb: `.select(` alone would
                // catch a set's own `select`, a text field's, or any future member with
                // that name on an unrelated type. Only a call on the layout is the claim.
                guard line.contains("PanelLayout.shared") || line.contains("panel.") else {
                    continue
                }
                for verb in verbs where line.contains(verb) {
                    offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "A workspace is a place, not an arrangement — go through "
                      + "AppState.enter or AppState.jump so the view mode and the crop "
                      + "tool come with it:\n" + offenders.joined(separator: "\n"))
    }

    /// The tab strip goes through the verb.
    ///
    /// This is the one that would have caught the bug the owner reported. The strip is
    /// the control a photographer actually uses and it was the only route with no pairing
    /// written into it, because the two fixes before it were written into the menu.
    func testTheWorkspaceStripEntersRatherThanSelects() {
        let strip = Self.source(named: "DevelopColumn.swift")
        XCTAssertFalse(strip.isEmpty, "DevelopColumn.swift not found")
        XCTAssertTrue(strip.contains("state.enter("),
                      "The workspace tab strip must call AppState.enter — clicking a tab "
                      + "is how a photographer changes workspace, and `select` alone "
                      + "leaves Cull in the loupe and Crop without its rectangle.")
    }

    /// Every ⌘-digit names the same verb.
    ///
    /// Five buttons, five workspaces, and the scan asks for each by name rather than
    /// counting: a renumbering that dropped one would still count five.
    func testEveryWorkspaceMenuItemEntersRatherThanSelects() {
        let menu = Self.source(named: "LumenApp.swift")
        XCTAssertFalse(menu.isEmpty, "LumenApp.swift not found")
        for workspace in Workspace.allCases {
            XCTAssertTrue(menu.contains("enter(.\(workspace.rawValue))"),
                          "The menu item for \(workspace.rawValue) must call "
                          + "AppState.enter(.\(workspace.rawValue))")
        }
    }

    /// The verb itself settles all three things.
    ///
    /// Not a proof — a text scan cannot be one — but it fails loudly if somebody deletes
    /// the part of `enter` that made the Crop tab work, which is the specific line this
    /// whole file exists because of.
    func testEnteringAWorkspaceSettlesTheViewModeAndTheCropTool() {
        let entry = Self.source(named: "WorkspaceEntry.swift")
        XCTAssertFalse(entry.isEmpty, "WorkspaceEntry.swift not found")
        XCTAssertTrue(entry.contains("showGrid()"),
                      "Cull is the grid; entering it from the loupe must say so.")
        XCTAssertTrue(entry.contains("showLoupe()"),
                      "The other four workspaces adjust a photograph and cannot be used "
                      + "from a contact sheet.")
        XCTAssertTrue(entry.contains("showCrop = true"),
                      "Entering Crop must arm the crop tool. Without this line the "
                      + "workspace opens onto a photograph with no rectangle on it, "
                      + "which is what the owner reported.")
        XCTAssertTrue(entry.contains("showCrop = false"),
                      "Leaving Crop must disarm it — a crop rectangle over the Grade "
                      + "workspace is a control from a room you walked out of.")
    }
}
