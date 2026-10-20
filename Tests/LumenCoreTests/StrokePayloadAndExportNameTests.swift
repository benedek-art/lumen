// StrokePayloadAndExportNameTests.swift
// Two places where a value the engine could not account for was treated as harmless.
//
// 1. A recipe that references stroke blobs this machine cannot read was reported to the
//    sidecar writer as "no brush masking", and the next flush deleted the .xmp's copy of
//    the painting — in that state the only intact copy.
// 2. An export name whose "/" was followed by a combining mark passed both the
//    renderer's cleanup and `usableBasename`, because both compared graphemes, and the
//    delivery landed in a new subfolder or outside the granted one.

import XCTest
@testable import LumenCore

final class StrokePayloadAndExportNameTests: XCTestCase {

    // MARK: - Unresolvable stroke blobs

    private func set(_ x: Double) -> BrushStrokeSet {
        BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: x, y: 0.2),
                                                      BrushPoint(x: x + 0.2, y: 0.3)])])
    }

    private func painted(_ refs: [String]) -> Recipe {
        var r = Recipe()
        r.masks = refs.enumerated().map { i, ref in
            var c = MaskComponent(op: .add, kind: .brush)
            c.strokesRef = ref
            return Mask(id: "m\(i)", name: "Painted \(i)", components: [c])
        }
        return r
    }

    func testAnUnresolvableBrushBlobIsNotReportedAsNoBrushMasking() throws {
        let ref = try set(0.2).blobRef()
        let decision = BrushStrokeSidecar.decision(for: painted([ref]), blob: { _ in nil })
        XCTAssertNotEqual(decision, .none,
                          "a recipe that references strokes must not tell the writer to drop the key")
        guard case .unresolved(let missing, let partial) = decision else {
            return XCTFail("expected .unresolved, got \(decision)")
        }
        XCTAssertEqual(missing, [ref])
        XCTAssertNil(partial)
    }

    func testAnUnresolvableHealBlobIsNotReportedAsNoBrushMasking() throws {
        let ref = try set(0.2).blobRef()
        var r = Recipe()
        r.develop.heal.strokesRef = ref
        guard case .unresolved(let missing, _) =
                BrushStrokeSidecar.decision(for: r, blob: { _ in nil }) else {
            return XCTFail("a heal-only recipe with a missing blob must not be .none")
        }
        XCTAssertEqual(missing, [ref])
    }

    func testAPartlyResolvedPaintingIsNotAPlainOverwrite() throws {
        let good = set(0.6)
        let goodRef = try good.blobRef()
        let lostRef = try set(0.1).blobRef()
        let decision = BrushStrokeSidecar.decision(for: painted([goodRef, lostRef]),
                                                   blob: { $0 == goodRef ? good : nil })
        if case .payload = decision {
            XCTFail("a payload missing a referenced set would overwrite the sidecar's copy of it")
        }
        guard case .unresolved(let missing, let partial) = decision else {
            return XCTFail("expected .unresolved, got \(decision)")
        }
        XCTAssertEqual(missing, [lostRef])
        // The sets that did resolve are still carried, for callers that want them.
        XCTAssertEqual(Array(BrushStrokeSidecar.decode(try XCTUnwrap(partial)).keys), [goodRef])
    }

    func testFullyResolvedAndUnpaintedRecipesKeepTheirAnswers() throws {
        let s = set(0.3)
        let ref = try s.blobRef()
        guard case .payload = BrushStrokeSidecar.decision(for: painted([ref]),
                                                          blob: { $0 == ref ? s : nil }) else {
            return XCTFail("a fully resolved painting is still a payload")
        }
        XCTAssertEqual(BrushStrokeSidecar.decision(for: Recipe(), blob: { _ in nil }), .none)
        // A component that has no strokes yet is "no strokes", not "unreadable".
        var empty = MaskComponent(op: .add, kind: .brush)
        empty.strokesRef = ""
        var r = Recipe()
        r.masks = [Mask(id: "m", name: "unpainted", components: [empty])]
        XCTAssertEqual(BrushStrokeSidecar.decision(for: r, blob: { _ in nil }), .none)
    }

    // MARK: - Export names and combining marks

    func testACombiningMarkCannotSmuggleASeparatorIntoAnExportName() {
        let ctx = ExportNamingContext(source: URL(fileURLWithPath: "/card/DSC_0001.NEF"),
                                      recipeName: "a/\u{0301}b", camera: "c:\u{0301}d",
                                      lens: "../\u{0301}x")
        let folder = URL(fileURLWithPath: "/Users/x/Deliveries", isDirectory: true)
        for template in ["{lens}", "{recipe}", "{camera}"] {
            let out = ExportNaming.render(template: template, context: ctx)
            XCTAssertFalse(out.unicodeScalars.contains("/"), "\(template) -> \(out.debugDescription)")
            XCTAssertFalse(out.unicodeScalars.contains(":"), "\(template) -> \(out.debugDescription)")
            XCTAssertEqual(folder.appendingPathComponent(out).deletingLastPathComponent()
                               .standardizedFileURL.path, folder.path)
        }
        // Only the separator scalar is mapped; the mark that followed it stays.
        XCTAssertEqual(ExportNaming.render(template: "{recipe}", context: ctx), "a-\u{0301}b")
    }

    func testUsableBasenameRejectsASeparatorScalarInsideAGrapheme() {
        XCTAssertNil(RenameTemplate.usableBasename("a/\u{0301}b"))
        XCTAssertNil(RenameTemplate.usableBasename("../\u{0301}x"))
        XCTAssertNil(RenameTemplate.usableBasename("a\\\u{0301}b"))
        XCTAssertEqual(RenameTemplate.usableBasename("cafe\u{0301}"), "cafe\u{0301}")
    }
}
