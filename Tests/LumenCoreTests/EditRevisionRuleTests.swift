// EditRevisionRuleTests.swift
// The rule `EditRevision.swift` states in its own header, enforced (I1-07).
//
// `AppState.recipes` is not `@Published`, deliberately: publishing it re-bodied the whole
// window on every mouse event of every drag, which is the "every single slider in the app
// is updating little by little" the owner reported. `EditRevision` is what says an edit
// happened, and only the views that show an edit observe it.
//
// The cost of that design is a rule, and the file says so: "if it reads
// `state.currentRecipe`, `state.recipe(for:)` or `state.strokeSets(for:)`, it must also
// declare `@EnvironmentObject var edits: EditRevision`, or it will render once and then
// never again notice an edit."
//
// It was enforced by that sentence and nothing else. Run over `Sources/LumenApp`, 19
// declarations read one of the three accessors and 16 declared the object — and the one
// genuine violation was `ContentView`, whose `showsMaskPanel` gates the floating Masks
// box on `!state.currentRecipe.masks.isEmpty`. The box appeared anyway, because `addMask`
// happens to write published selection state too; that is a coincidence holding up a
// contract, and the transition it covers least reliably is the empty → non-empty one the
// line exists for.
//
// THE CARVE-OUT IS THE INTERESTING PART. Two of the three non-declaring types are not
// views at all — `RecipeBinder` and `ViewerRenderKey` are helpers that read a recipe on
// behalf of a caller, and every one of their callers declares the object. A checker
// without that exemption reports two false positives forever and gets switched off, which
// is the failure mode of every rule nobody can satisfy.

import XCTest
@testable import LumenCore

final class EditRevisionRuleTests: XCTestCase {

    /// Non-`View` helpers that read a recipe for a caller. Each is listed with the
    /// callers that make it safe, because that is the fact being asserted — if a caller
    /// is added that does NOT declare the object, this list is the lie.
    private static let helpers: Set<String> = [
        // Callers: BasicPanel, CropPanel, DetailPanel, EffectsPanel, ZonesPanel.
        "RecipeBinder",
        // Callers: LoupeView, CompareView.
        "ViewerRenderKey",
    ]

    private static let accessors = ["state.currentRecipe",
                                    "state.recipe(for:",
                                    "state.strokeSets(for:"]

    /// THE CLAUSE THIS RULE WAS MISSING, and its absence cost the owner a sixth report
    /// of the same bug.
    ///
    /// The rule above is one-directional: read a recipe ⇒ observe the signal. It says
    /// nothing about WHERE, and `@EnvironmentObject` subscribes a view to an object
    /// whether or not it ever reads it. Satisfied on a leaf that costs one small
    /// invalidation, it is free. Satisfied on the window's ROOT it re-bodies the split
    /// view, the sidebar, the centre pane, the develop column and the filmstrip — once
    /// per MOUSE EVENT, because `EditRevision` is bumped from `updateRecipe`.
    ///
    /// That is the defect `EditRevision` was created to remove, and it came back through
    /// this very test: the scan found `ContentView` as its one genuine violation, and
    /// the violation was closed by adding the declaration to the root. The owner's
    /// report was "it isn't a smooth update while I drag but more so an incremental
    /// flash updating" — the main actor no longer fitting a window pass between two
    /// motion events, so AppKit coalesces the ones it cannot deliver.
    ///
    /// The fix at the call site is always the same: move the recipe read DOWN into a
    /// small view that can afford to be invalidated (`MaskFloatingPanelHost`), never up
    /// into the shell. These types must therefore never observe the signal, and adding a
    /// name here is a claim that its body lays out a large part of the window.
    private static let mustNotObserve: Set<String> = [
        // The window's root: `NavigationSplitView`, sidebar, centre pane, develop
        // column, filmstrip and status bar all hang off its body.
        "ContentView",
    ]

    func testEveryViewThatReadsARecipeObservesEditRevision() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return XCTFail("Sources/LumenApp not found") }

        var readers = 0
        var offenders: [String] = []
        for name in names.filter({ $0.hasSuffix(".swift") }).sorted() {
            guard let raw = try? String(contentsOf: root.appendingPathComponent(name),
                                        encoding: .utf8) else { continue }
            // COMMENTS OUT FIRST, and this is not a detail: the first draft of this test
            // did not strip them, and its own substitution proof passed — because the
            // doc comment ABOVE `ContentView`'s declaration explains the rule and
            // contains the word `EditRevision`. Deleting the property left the prose
            // that justifies it, and the check went on being satisfied by an
            // explanation of the thing it was meant to find missing.
            for (type, code) in Self.declarations(in: raw) {
                guard Self.accessors.contains(where: { code.contains($0) }) else { continue }
                readers += 1
                guard !Self.helpers.contains(type) else { continue }
                if !code.contains("EditRevision") {
                    offenders.append("\(name): \(type)")
                }
            }
        }

        XCTAssertGreaterThan(readers, 10,
                             "only \(readers) recipe readers found — the scan has "
                                 + "stopped seeing the declarations it is checking, "
                                 + "which is worse than a violation")
        XCTAssertTrue(offenders.isEmpty,
                      "a view reads a recipe and does not observe EditRevision, so it "
                          + "renders once and never notices an edit again — the exact "
                          + "failure EditRevision.swift's header exists to prevent:\n"
                          + offenders.joined(separator: "\n"))
    }

    /// The other direction: the shell must not subscribe to a per-mouse-event signal.
    ///
    /// Scanned as text over the whole file rather than per declaration block, because
    /// what is being forbidden is the DECLARATION — `@EnvironmentObject var edits:
    /// EditRevision` — and a declaration sits in the type's stored-property list, not
    /// inside any expression the block splitter reasons about. Comments are stripped
    /// first for the reason the test above records in full: `ContentView` carries prose
    /// explaining this rule, and a scan that reads comments is satisfied by an
    /// explanation of the thing it is meant to find.
    func testTheWindowShellDoesNotObserveThePerEventEditSignal() {
        for type in Self.mustNotObserve {
            let raw = Self.source(named: "\(type).swift")
            guard !raw.isEmpty else {
                XCTFail("\(type).swift not found — if it moved, move this scan with it "
                            + "rather than deleting it")
                continue
            }
            // THE TYPE'S OWN BLOCK, not the file. `MaskFloatingPanelHost` — the leaf the
            // recipe read was moved INTO — lives in `ContentView.swift` and observes the
            // signal correctly, so a whole-file scan reports the fix as the violation.
            guard let code = Self.declarations(in: raw)
                .first(where: { $0.type == type })?.code else {
                XCTFail("no top-level `\(type)` in \(type).swift")
                continue
            }
            XCTAssertFalse(
                code.contains("EditRevision"),
                "\(type) observes EditRevision. It is bumped once per mouse event of "
                    + "every slider drag, and this type lays out the window — so every "
                    + "event now costs a whole-window pass, the main actor stops "
                    + "fitting one between two motion events, AppKit coalesces the rest, "
                    + "and the picture arrives in flashes instead of following the hand. "
                    + "Move the recipe read DOWN into a small view that can afford the "
                    + "invalidation (see MaskFloatingPanelHost), never up into the shell.")
        }
    }

    /// `Sources/LumenApp/<name>`, or "" when it is not there.
    private static func source(named name: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return (try? String(contentsOf: root.appendingPathComponent(name),
                            encoding: .utf8)) ?? ""
    }

    /// A file's top-level declarations as (type name, code), COMMENTS STRIPPED.
    ///
    /// Both tests here run on this, and stripping first is not a detail: the first draft
    /// of the rule test did not strip, and its own substitution proof passed — because
    /// the doc comment above `ContentView`'s declaration explained the rule and contained
    /// the word `EditRevision`. Deleting the property left the prose that justified it,
    /// and the check went on being satisfied by an explanation of the thing it was meant
    /// to find missing. `ContentView` today carries a comment saying it deliberately does
    /// NOT observe, which would satisfy an unstripped scan the same way.
    ///
    /// A line beginning in column zero with `struct`/`final class`/`class`/`extension`
    /// opens a new declaration.
    private static func declarations(in raw: String) -> [(type: String, code: String)] {
        let text = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[..<slashes.lowerBound]
            }
            .joined(separator: "\n")
        var current = "", body = ""
        var blocks: [(type: String, code: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let opens = ["struct ", "final class ", "class ", "extension ",
                         "private struct ", "private final class "]
            if let kw = opens.first(where: { line.hasPrefix($0) }) {
                if !current.isEmpty { blocks.append((current, body)) }
                let rest = line.dropFirst(kw.count)
                current = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                body = ""
            } else {
                body += line + "\n"
            }
        }
        if !current.isEmpty { blocks.append((current, body)) }
        return blocks
    }
}
