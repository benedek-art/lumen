#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class AuditSidecarOwnershipTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-sidecar-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDNGThenNEFRetainSeparateEditsThroughSiblingChanges() throws {
        try transition(first: "DNG", second: "NEF")
    }

    func testNEFThenDNGRetainSeparateEditsThroughSiblingChanges() throws {
        try transition(first: "NEF", second: "DNG")
    }

    func testTwoNativeRawFormatsRetainSeparateEditsThroughSiblingChanges() throws {
        try transition(first: "NEF", second: "CR3")
    }

    func testLegacyDNGSidecarUsesRecordedOwnershipBeforeImportingNewSibling() throws {
        try transition(first: "DNG", second: "NEF", legacy: true)
    }

    private func transition(first: String, second: String, legacy: Bool = false) throws {
        let root = try scratch()
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let a = photos.appendingPathComponent("frame.\(first)")
        let b = photos.appendingPathComponent("frame.\(second)")
        try Data([1, 2, 3]).write(to: a)
        let catalog = root.appendingPathComponent("catalog")
        let initial = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(initial.registerAndLoad(folder: photos, files: [a])[a]?.catalogID)
        var recipe = Recipe(); recipe.develop.tone.exposure = 2
        initial.saveRecipe(recipe, url: a, catalogID: id)
        initial.close()
        if legacy {
            let bare = a.deletingPathExtension().appendingPathExtension("xmp")
            let attributes = try FileManager.default.attributesOfItem(atPath: bare.path)
            let text = try String(contentsOf: bare, encoding: .utf8)
                .replacingOccurrences(of: "\\s*<lumen:sourceExtension>[^<]*</lumen:sourceExtension>", with: "", options: .regularExpression)
            try Data(text.utf8).write(to: bare)
            // Removing the new ownership field models an old file, not an external
            // edit. Preserve the recorded mtime so migration has real provenance.
            try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: bare.path)
        }
        try Data([4, 5, 6]).write(to: b)
        let added = try CatalogService(directory: catalog)
        let both = added.registerAndLoad(folder: photos, files: [a, b])
        XCTAssertEqual(both[a]?.recipe?.develop.tone.exposure, 2)
        XCTAssertEqual(both[b]?.recipe?.develop.tone.exposure ?? 0, 0, "A new sibling must not inherit another original's recipe")
        recipe.develop.tone.exposure = -1
        added.saveRecipe(recipe, url: b, catalogID: try XCTUnwrap(both[b]?.catalogID))
        added.close()
        try FileManager.default.removeItem(at: a)
        let removed = try CatalogService(directory: catalog)
        XCTAssertEqual(removed.registerAndLoad(folder: photos, files: [b])[b]?.recipe?.develop.tone.exposure, -1)
        removed.close()
        try Data([1, 2, 3]).write(to: a)
        // Sidecars alone, no catalog: this is the portability contract.
        let portable = try CatalogService(directory: root.appendingPathComponent("fresh-catalog"))
        defer { portable.close() }
        let imported = portable.registerAndLoad(folder: photos, files: [a, b])
        XCTAssertEqual(imported[a]?.recipe?.develop.tone.exposure, 2)
        XCTAssertEqual(imported[b]?.recipe?.develop.tone.exposure, -1)
    }

    func testUnknownLegacyOwnershipIsNotGuessedOrOverwritten() throws {
        let root = try scratch()
        let a = root.appendingPathComponent("frame.DNG"), b = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: a); try Data([4, 5, 6]).write(to: b)
        var recipe = Recipe(); recipe.develop.tone.exposure = 2
        let encoded = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let content = SidecarContent(recipeJSON: encoded, writeStamp: "2026-09-01T00:00:00Z")
        let bare = root.appendingPathComponent("frame.xmp")
        let original = Data(XMPSidecar.serialize(content).utf8)
        try original.write(to: bare)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        var notices: [String] = []
        service.onFailure = { notices.append($0) }
        let rows = service.registerAndLoad(folder: root, files: [a, b])
        XCTAssertNil(rows[a]?.recipe)
        XCTAssertNil(rows[b]?.recipe)
        XCTAssertEqual(try Data(contentsOf: bare), original)
        XCTAssertTrue(notices.contains { $0.localizedCaseInsensitiveContains("ownership") })
    }

    func testUnownedAdobeSidecarStillBelongsToNativeRawBesideDNG() throws {
        let root = try scratch()
        let a = root.appendingPathComponent("frame.DNG"), b = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: a); try Data([4, 5, 6]).write(to: b)
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"4\"/></rdf:RDF></x:xmpmeta>"
        try Data(xml.utf8).write(to: root.appendingPathComponent("frame.xmp"))
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let rows = service.registerAndLoad(folder: root, files: [a, b])
        XCTAssertEqual(rows[a]?.rating, 0)
        XCTAssertEqual(rows[b]?.rating, 4)
    }
}
#endif
