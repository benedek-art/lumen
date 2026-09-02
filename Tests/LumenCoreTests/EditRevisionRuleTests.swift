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
            let text = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let slashes = line.range(of: "//") else { return line }
                    return line[..<slashes.lowerBound]
                }
                .joined(separator: "\n")
            // Split on top-level declarations: a line that begins in column zero with
            // `struct`/`final class`/`class`/`extension` opens a new one.
            var current = "", body = ""
            var blocks: [(String, String)] = []
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

            for (type, code) in blocks {
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
}
