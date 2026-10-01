// ExportRecipesSectionTests.swift
// G1-04: the Export Recipes section's one sentence was never drawn.
//
// `DevelopNote` draws NOTHING unless `prominent: true` — "not prominent means not
// drawn", its own comment says — and `ExportRecipesSection` called it with the default.
// The section rendered as its own heading over a bare accent link. It was repaired in
// the tree with `prominent: true` and nothing held it there; this does, on every lane,
// because the view is macOS-only and a source contract is the test that can run.

import XCTest

final class ExportRecipesSectionTests: XCTestCase {

    private static func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The premise: a note that is not prominent is not drawn. If `DevelopNote` ever
    /// starts drawing its default form again, the section below is safe either way and
    /// this test should be rewritten rather than the section's argument deleted.
    func testANoteThatIsNotProminentDrawsNothing() throws {
        let panel = try Self.appSource("DevelopPanel")
        let start = try XCTUnwrap(panel.range(of: "struct DevelopNote: View {"))
        let note = String(panel[start.upperBound...].prefix(2500))
        XCTAssertTrue(note.contains("init(_ text: String, prominent: Bool = false)"))
        XCTAssertTrue(note.contains("if prominent {\n            Text(text)"),
                      "DevelopNote's body no longer gates its text on `prominent`")
    }

    /// The repair: the section's sentence is a prominent note, so the heading has a
    /// body under it. Drop `prominent: true` and this goes red.
    func testTheExportRecipesSentenceIsDrawn() throws {
        let column = try Self.appSource("DevelopColumn")
        let start = try XCTUnwrap(column.range(of: "private struct ExportRecipesSection: View {"))
        let section = String(column[start.upperBound...].prefix(3000))
        XCTAssertTrue(section.contains("DevelopNote(\"Export recipes are edited in the export sheet.\",\n"
                                       + "                        prominent: true)"),
                      "ExportRecipesSection's note is not prominent, so it draws nothing "
                      + "and the section is a heading over a bare link (G1-04)")
    }
}
