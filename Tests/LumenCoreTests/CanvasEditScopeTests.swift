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

    /// Comments blanked, string bodies kept, length and newlines preserved.
    ///
    /// The same walk `WorkspaceEntryTests` uses and for the same reason: a `//` inside a
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
                i = Swift.min(j, n)
            } else {
                i += 1
            }
        }
        return String(out)
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
