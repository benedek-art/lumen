// DeliveryNameTests.swift
// J3-02: a filename template that renders empty writes the delivery BESIDE the folder
// the open panel granted, not inside it.
//
// `renderFilename` guarded the literal empty TEMPLATE — `template.isEmpty ? "{name}"` —
// and not the empty RESULT. Those are different questions and only the second one
// reaches the filesystem: `{recipe}` with a cleared recipe name renders nothing, and a
// nothing appended to a directory URL leaves the directory unchanged, so the extension
// lands on the directory itself. Every frame in the batch then writes to that one path,
// each overwriting the last.
//
// `IngestSheet` already refuses exactly this on its own templates ("Filename template
// renders empty for the first file"). The export side, which is where the files the
// photographer delivers come from, had no equivalent.

import XCTest
@testable import LumenCore

final class DeliveryNameTests: XCTestCase {

    // MARK: - The arithmetic that makes it matter

    /// Pinned as a fact rather than described in a comment, because the whole severity
    /// rests on it and it is one line to check. If Foundation ever changed this, the
    /// guard would still be correct and this test would tell us the reason had moved.
    func testAnEmptyComponentPutsTheExtensionOnTheFolderItself() {
        let folder = URL(fileURLWithPath: "/Users/x/Deliveries")
        let escaped = folder.appendingPathComponent("").appendingPathExtension("jpg")
        XCTAssertEqual(escaped.path, "/Users/x/Deliveries.jpg")
        XCTAssertFalse(escaped.path.hasPrefix(folder.path + "/"),
                       "the delivery lands beside the granted folder, not in it")

        // And with a real name it behaves, which is what makes the empty case a defect
        // rather than a property of the API.
        let inside = folder.appendingPathComponent("DSC_0001").appendingPathExtension("jpg")
        XCTAssertTrue(inside.path.hasPrefix(folder.path + "/"))
    }

    // MARK: - The rule

    func testTheThreeResultsThatSurviveSanitiseAndAreNotNames() {
        XCTAssertNil(RenameTemplate.usableBasename(""))
        XCTAssertNil(RenameTemplate.usableBasename("   "))
        XCTAssertNil(RenameTemplate.usableBasename("."))
        XCTAssertNil(RenameTemplate.usableBasename(".."))
    }

    func testASeparatorIsNeverABasename() {
        XCTAssertNil(RenameTemplate.usableBasename("../../secrets/x"))
        XCTAssertNil(RenameTemplate.usableBasename("a/b"))
        XCTAssertNil(RenameTemplate.usableBasename("a\\b"))
    }

    func testARealNameSurvivesAndIsTrimmed() {
        XCTAssertEqual(RenameTemplate.usableBasename("DSC_0001"), "DSC_0001")
        XCTAssertEqual(RenameTemplate.usableBasename("  2026-09-02-0001  "),
                       "2026-09-02-0001")
        // A leading dot is a hidden file, which is surprising but not dangerous, and
        // it IS a name. Rejecting it would refuse a template the photographer chose.
        XCTAssertEqual(RenameTemplate.usableBasename(".hidden"), ".hidden")
    }

    /// `sanitize` maps the separators, so its output is never rejected for one — but it
    /// can still hand back the empty string, which is the whole point.
    func testSanitiseAloneIsNotTheRule() {
        XCTAssertEqual(RenameTemplate.sanitize("   "), "",
                       "sanitise collapses this to nothing and calls it a name")
        XCTAssertNil(RenameTemplate.usableBasename(RenameTemplate.sanitize("   ")))
    }

    // MARK: - The export path has to use it

    /// `AppState.renderFilename` is in LumenApp, which has no test target that runs
    /// here, so this reads it as text — comments stripped, because a doc comment naming
    /// the symbol would let this test pass its own substitution proof.
    func testTheExportNameGoesThroughTheRule() throws {
        let source = Self.strippingComments(try Self.appSource("AppStateActions.swift"))
        XCTAssertTrue(source.contains("RenameTemplate.usableBasename("),
                      "renderFilename must guard what the template RENDERED, not just "
                      + "the literal template")
        // Both callers — the exporter and the sheet's preview — go through
        // `renderFilename`, so guarding it once is what keeps the preview honest about
        // what will actually be written.
        XCTAssertTrue(source.contains("static func renderFilename("))
    }

    // MARK: - KG-02: one entry verb into the mask editor

    /// The overlay keys enter masking rather than toggling it, and expressed that by
    /// calling `PanelLayout.setMasking(true)` and `showLoupe()` directly — the first two
    /// lines of the entry verb and not the rest. The line they skipped tears the crop
    /// tool down, so `O` with the crop armed left `showCrop` on: the picture reverts to
    /// uncropped and unstraightened and the overlay the key was pressed for is never
    /// built.
    func testNothingEntersMaskingPastTheEntryVerb() throws {
        for file in ["Keymap.swift", "WorkspaceEntry.swift", "ContentView.swift"] {
            let source = Self.strippingComments(try Self.appSource(file))
            if file == "WorkspaceEntry.swift" {
                XCTAssertTrue(source.contains("func enterMasking()"),
                              "the entry verb lives here")
                continue
            }
            XCTAssertFalse(source.contains("setMasking(true)"),
                           "\(file) reaches past the entry verb; arriving in the mask "
                           + "editor has to tear the crop tool down, and setMasking "
                           + "alone does not")
        }
    }

    // MARK: - helpers

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
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

// MARK: - G3-02, the same defect one door over

/// KG-02 was the `O` key entering masking without tearing the crop tool down. G3-02 is
/// the mirror: `R` arming the crop tool without leaving the mask editor. The cause is
/// the same in both — masking is a FLAG BESIDE the workspace, so a guard that asks only
/// `workspace == .crop` is satisfied while the mask editor is open.
///
/// The G3 audit found this by re-reading the tree AFTER KG-02's fix landed, which is
/// why it is in this landing rather than the next one.
final class ModeEntryTests: XCTestCase {

    func testArmingTheCropToolLeavesTheMaskEditor() throws {
        let source = Self.stripped(try Self.appSource("WorkspaceEntry.swift"))
        let armAt = try XCTUnwrap(source.range(of: "func toggleCropTool()")).upperBound
        let body = String(source[armAt...].prefix(1200))
        XCTAssertTrue(body.contains("setMasking(false)"),
                      "toggleCropTool must leave masking before it arms the rectangle, "
                      + "or the crop is stranded under MaskCanvas with no panel")
    }

    /// And the state stays unrepresentable even if a third route appears.
    func testTheArmedPredicateCannotBeTrueWhileMasking() throws {
        let source = Self.stripped(try Self.appSource("LoupeView.swift"))
        let atAt = try XCTUnwrap(source.range(of: "private var cropArmed: Bool")).upperBound
        let body = String(source[atAt...].prefix(300))
        XCTAssertTrue(body.contains("!panel.layout.isMasking"),
                      "cropArmed must exclude masking; it is the predicate the overlay, "
                      + "the render request and the panel all share")
    }

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func stripped(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var block = false
        while i < source.endIndex {
            let rest = source[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            out.append(source[i]); i = source.index(after: i)
        }
        return out
    }
}
