import Foundation
import XCTest
@testable import LumenCore

final class AuditSourceIdentityTests: XCTestCase {
    func testChangedOriginalDropsObsoleteIdentityMetadataAndAllPreviewRungs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-source-identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
                                     cachePath: root.appendingPathComponent("cache.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "a.jpg", fileSize: 100, fileMTime: 10, quickSig: "old")])
        let id = try XCTUnwrap(store.photo(folderID: folder, filename: "a.jpg")).id
        var recipe = Recipe(); recipe.develop.tone.exposure = 1
        try store.saveRecipe(recipe, photoID: id, isCurrent: true)
        try store.setRating(4, photoID: id)
        try store.setMetadata(PhotoMetadata(width: 32, height: 24), photoID: id)
        for rung in [PreviewLevel.thumb, .grid, .fit, .oneToOne] {
            try store.recordPreview(PreviewRow(photoID: id, level: rung, path: "old.jpg", bytes: 20))
        }
        _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "a.jpg", fileSize: 200, fileMTime: 20)])
        XCTAssertNil(try store.photo(id: id)?.quickSig, "REL-06: obsolete signature must be recomputed")
        XCTAssertEqual(try store.photosMissingQuickSig(folderID: folder).count, 1)
        XCTAssertTrue(try store.previews(photoID: id).isEmpty, "REL-06: every rung depicts old source pixels")
        XCTAssertEqual(try store.currentRecipe(photoID: id), recipe)
        XCTAssertEqual(try store.photo(id: id)?.rating, 4)
        XCTAssertNil(try store.photo(id: id)?.width)
    }

    func testRapidSameSizeWriteRestoringMTimeStillChangesIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-source-stat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 1, count: 256).write(to: url)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let first = try XCTUnwrap(SourceFileIdentity.read(url))
        let firstRenderIdentity = PlanTableCache.renderIdentity(for: url)
        XCTAssertEqual(SourceFileIdentity.read(url), first)
        XCTAssertEqual(PlanTableCache.renderIdentity(for: url), firstRenderIdentity)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 2, count: 256))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        XCTAssertNotEqual(SourceFileIdentity.read(url), first, "ctime must detect same-inode/size/restored-mtime writes")
        XCTAssertNotEqual(PlanTableCache.renderIdentity(for: url), firstRenderIdentity)
        let unavailable = url.appendingPathExtension("not-created")
        XCTAssertEqual(PlanTableCache.renderIdentity(for: unavailable), unavailable.absoluteString)
    }

    func testIdentityChangeWithinSameMTimeSecondInvalidatesOnceNotEveryScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-source-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
                                     cachePath: root.appendingPathComponent("cache.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        var file = ScannedFile(filename: "a.jpg", fileSize: 100, fileMTime: 10, quickSig: "old", sourceIdentity: "generation1")
        _ = try store.scan(folderID: folder, files: [file])
        let id = try XCTUnwrap(store.photo(folderID: folder, filename: "a.jpg")).id
        try store.recordPreview(PreviewRow(photoID: id, level: .thumb, path: "old.jpg", bytes: 20))
        XCTAssertEqual(try store.scan(folderID: folder, files: [file]).unchanged, 1)
        XCTAssertEqual(try store.previews(photoID: id).count, 1)
        let old = try XCTUnwrap(store.previews(photoID: id).first)
        var new = old; new.path = "newer-generation.jpg"
        try store.recordPreview(new)
        XCTAssertTrue(try store.discardPreviews([old]).isEmpty,
                      "A late cleanup may not delete a replacement with the same primary key")
        XCTAssertEqual(try store.previews(photoID: id).first?.path, new.path)
        file.sourceIdentity = "generation2"; file.quickSig = nil
        XCTAssertEqual(try store.scan(folderID: folder, files: [file]).changed, [id])
        XCTAssertNil(try store.photo(id: id)?.quickSig)
        XCTAssertTrue(try store.previews(photoID: id).isEmpty)
        try store.recordPreview(PreviewRow(photoID: id, level: .thumb, path: "new.jpg", bytes: 20))
        XCTAssertEqual(try store.scan(folderID: folder, files: [file]).unchanged, 1)
        XCTAssertEqual(try store.previews(photoID: id).count, 1)
    }
}
