// CullUndoScaleTests.swift
// Undoing a cull over a selection costs one roll copy, not three per photo (J2-02).
//
// `mutateTargets` learned to mutate a local copy of `allPhotos` and assign it once,
// because `allPhotos` is `@Published` and every element write through it copies the
// whole roll and republishes the grid. Undo went the other way through `restore`, once
// per photo: a linear search for the photo, then three element writes — ⌘Z on a
// 200-frame reject in a 20,000-frame folder was 600 whole-roll copies and 600 publishes.
//
// `AppState` compiles on macOS only, so this reads `AppState.swift` as text, comments
// blanked first: the comment above the fix names every construct asserted absent here.
// On the Linux lane, where it actually runs.

import XCTest

final class CullUndoScaleTests: XCTestCase {

    private func appStateCode() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/AppState.swift")
        return Self.withoutComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The body of the first function whose declaration starts with `signature`, found
    /// by brace depth from the first `{` after it.
    /// The braces are compared by ASCII value (123, 125) so this file's own text stays
    /// balanced for `check-swift-surface.py`, whose scope walk counts braces inside
    /// string literals.
    private func body(of signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature) else { return nil }
        guard let open = code[start.upperBound...].firstIndex(where: { $0.asciiValue == 123 }) else {
            return nil
        }
        var depth = 0
        var i = open
        while i < code.endIndex {
            if code[i].asciiValue == 123 { depth += 1 }
            if code[i].asciiValue == 125 {
                depth -= 1
                if depth == 0 { return String(code[open...i]) }
            }
            i = code.index(after: i)
        }
        return nil
    }

    func testUndoRestoresAStepsCullingInOnePass() throws {
        let code = try appStateCode()
        guard let restore = body(of: "private func restore(_ cullings:", in: code) else {
            return XCTFail("restore no longer takes the whole step's cullings at once — "
                           + "a per-photo restore is a whole-roll copy per photo")
        }
        XCTAssertFalse(restore.contains("allPhotos["),
                       "restore writes `allPhotos` element by element: each write copies "
                           + "the roll and republishes the grid")
        for search in ["firstIndex(where:", "firstIndex(of:", "first(where:"] {
            XCTAssertFalse(restore.contains(search),
                           "restore searches the roll per photo with \(search)")
        }
        XCTAssertEqual(restore.components(separatedBy: "allPhotos = ").count - 1, 1,
                       "the restored roll must be published exactly once")

        guard let apply = body(of: "private func apply(_ step:", in: code) else {
            return XCTFail("AppState.apply(_:) moved")
        }
        guard let loop = body(of: "for (url, edit) in step", in: apply) else {
            return XCTFail("apply no longer walks the step")
        }
        XCTAssertFalse(loop.contains("restore("),
                       "apply restores inside its per-photo loop again")
        XCTAssertTrue(apply.contains("restore(cullings)"),
                      "apply never restores the step's culling")
    }

    /// Undo is a culling change like the keystroke it undoes, so it asks the catalog
    /// for the grid again under the same conditions. Under a "Rejected" chip, undoing a
    /// reject left the frame in the grid: the badge changed, the membership did not,
    /// because only `mutateTargets` re-ran the query.
    func testUndoOfACullAsksTheCatalogForTheGridLikeTheKeystrokeDid() throws {
        let code = try appStateCode()
        let rule = "refreshLibraryQueryIfCullingShowsInTheGrid()"
        guard let restore = body(of: "private func restore(_ cullings:", in: code),
              let mutate = body(of: "private func mutateTargets(", in: code),
              let helper = body(of: "private func refreshLibraryQueryIfCullingShowsInTheGrid(",
                                in: code) else {
            return XCTFail("restore, mutateTargets or the shared refresh rule moved")
        }
        XCTAssertTrue(restore.contains(rule),
                      "undo restores flags and ratings and leaves the filtered grid as "
                          + "the keystroke left it")
        XCTAssertTrue(mutate.contains(rule),
                      "the keystroke no longer asks the catalog after a cull")
        for clause in ["filter.isActive", ".rating", ".flag", ".label",
                       "refreshLibraryQuery()"] {
            XCTAssertTrue(helper.contains(clause),
                          "the shared rule lost \(clause)")
        }
    }

    /// Comments blanked, string bodies kept, newlines preserved.
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
}
