// CanvasEditScopeTests.swift
// A gesture on the photograph edits THAT photograph.
//
// `AppState.updateRecipe` defaults its `targets` to `editTargets`, which is the whole
// SELECTION whenever more than one frame is selected. That default is right for a panel
// — moving Exposure with five frames selected is meant to move all five — and wrong for
// the canvas, which shows one photograph and takes gestures about it.
//
// `MaskCanvasEdit.apply` took the default. It needed mask ids to collide across
// photographs to bite, and Paste Settings makes them collide by construction
// (`recipe.masks = source.masks`, ids included), so the sequence that lost work was the
// ordinary one: paste a sky mask and a brush across a shoot, select the shoot, touch up
// the brush on the frame you are looking at, and the other four frames' brush masks
// silently became that frame's painting.
//
// A TEXT SCAN, in LumenCore's suite, for the reason `WorkspaceEntryTests` and
// `KeyGrammarTests` give at length: `Sources/LumenApp` is `#if os(macOS)`, so it compiles
// on one CI lane and cannot be exercised here at all. `AppState` opens a catalog on disk
// in its initializer and no test in the package constructs one — which is exactly why
// this defect was invisible. The claim being asserted is about which call passes which
// argument, and reading the source as text asserts precisely that.

import XCTest
@testable import LumenCore

final class CanvasEditScopeTests: XCTestCase {

    private static var canvasSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp/MaskCanvas.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("MaskCanvas.swift not found at \(url.path) — if the file moved, move "
                    + "this scan with it rather than deleting it")
            return ""
        }
        return withoutComments(text)
    }

    /// The shared `blankingComments(in:)` (CommentBlanking.swift): comments become
    /// spaces, literals are kept, and length and lines match the input.
    private static func withoutComments(_ text: String) -> String {
        blankingComments(in: text)
    }

    /// Every recipe write the canvas makes names its photograph.
    ///
    /// The assertion is on the ARGUMENT, not on the count of calls: a fifth gesture
    /// added tomorrow is welcome, and is caught by this the moment it takes the default.
    func testEveryCanvasRecipeWriteNamesItsPhotograph() {
        let source = Self.canvasSource
        XCTAssertFalse(source.isEmpty, "the scan read nothing, so it proves nothing")

        var unscoped: [String] = []
        var total = 0
        for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("updateRecipe(") {
            total += 1
            if !line.contains("targets:") {
                unscoped.append("MaskCanvas.swift:\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertGreaterThan(total, 0,
                             "no `updateRecipe(` call found in MaskCanvas.swift — the "
                             + "scan has lost its subject and would pass on anything")
        XCTAssertTrue(unscoped.isEmpty,
                      "a canvas gesture writes to every selected photograph:\n"
                      + unscoped.joined(separator: "\n")
                      + "\nPass `targets:` so the gesture lands on the photograph it was "
                      + "made on. Without it `updateRecipe` falls back to `editTargets`, "
                      + "which is the whole selection.")
    }

    /// And it names ONE photograph, resolved before the switch.
    ///
    /// Separate from the assertion above because `targets:` satisfied by
    /// `state.editTargets` would be the same defect wearing the argument's name. What
    /// makes the canvas correct is that its subject is the primary selection.
    func testTheCanvasResolvesItsSubjectBeforeApplyingAnything() {
        let source = Self.canvasSource
        guard let apply = source.range(of: "static func apply(_ edit: MaskCanvasEdit") else {
            XCTFail("MaskCanvasEdit.apply not found — if it was renamed, rename it here")
            return
        }
        let body = String(source[apply.lowerBound...].prefix(2_000))
        XCTAssertTrue(body.contains("state.primarySelection"),
                      "MaskCanvasEdit.apply must resolve the photograph on screen before "
                      + "it writes, so that `targets:` names one frame and not the "
                      + "selection")
    }
}
