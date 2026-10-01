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

    // MARK: - REL-06 regression: a token change is a suspicion, not a verdict

    /// One photo with a quick signature, EXIF and a preview, scanned once with
    /// `identity` (nil models a row from before tokens existed).
    private func seeded(identity: String?) throws -> (CatalogStore, Int64, Int64, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-source-suspicion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
                                     cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: root.path)
        _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "a.nef", fileSize: 100, fileMTime: 10,
                                                                  quickSig: "sig-A", sourceIdentity: identity)])
        let id = try XCTUnwrap(store.photo(folderID: folder, filename: "a.nef")).id
        try store.setMetadata(PhotoMetadata(captureAt: 1_700_000_000, camera: "Z 8", width: 32, height: 24), photoID: id)
        try store.recordPreview(PreviewRow(photoID: id, level: .grid, path: "kept.jpg", bytes: 20))
        return (store, folder, id, root)
    }

    private func assertKept(_ store: CatalogStore, _ id: Int64, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(store.photo(id: id), file: file, line: line)
        XCTAssertEqual(row.quickSig, "sig-A", "quick signature wiped", file: file, line: line)
        XCTAssertEqual(row.width, 32, "EXIF wiped", file: file, line: line)
        XCTAssertEqual(try store.previews(photoID: id).count, 1, "previews wiped", file: file, line: line)
    }

    /// (a) The first scan after upgrading: no stored token. Adopt it; read nothing.
    func testRowWithoutStoredIdentityAdoptsTheTokenInsteadOfBeingWiped() throws {
        let (store, folder, id, root) = try seeded(identity: nil)
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let file = ScannedFile(filename: "a.nef", fileSize: 100, fileMTime: 10, sourceIdentity: "7:100:10:0:10:0")
        let result = try store.scan(folderID: folder, files: [file], signature: { _ in reads += 1; return "sig-A" })
        XCTAssertEqual(result.unchanged, 1)
        XCTAssertEqual(result.changed, [])
        XCTAssertEqual(reads, 0, "adopting a legacy row must not cost a read")
        try assertKept(store, id)
        XCTAssertEqual(try store.metaValue("source_identity_\(id)"), "7:100:10:0:10:0")
    }

    /// (b) A remount: the stored token carries a device number the current one does
    /// not, or another one. The device field never decides.
    func testDeviceNumberAloneNeverInvalidates() throws {
        XCTAssertTrue(SourceFileIdentity.sameGeneration(stored: "16777234:7:100:10:0:10:0",
                                                        current: "7:100:10:0:10:0"))
        XCTAssertTrue(SourceFileIdentity.sameGeneration(stored: "16777234:7:100:10:0:10:0",
                                                        current: "16777240:7:100:10:0:10:0"))
        XCTAssertFalse(SourceFileIdentity.sameGeneration(stored: "16777234:7:100:10:0:10:0",
                                                         current: "8:100:10:0:10:0"))
        let (store, folder, id, root) = try seeded(identity: "16777234:7:100:10:0:10:0")
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let file = ScannedFile(filename: "a.nef", fileSize: 100, fileMTime: 10, sourceIdentity: "7:100:10:0:10:0")
        XCTAssertEqual(try store.scan(folderID: folder, files: [file],
                                      signature: { _ in reads += 1; return "sig-A" }).unchanged, 1)
        XCTAssertEqual(reads, 0)
        try assertKept(store, id)
    }

    /// The token as read from disk has no device field: its first field is the inode.
    func testTokenDoesNotCarryTheDeviceNumber() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-source-dev-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 1, count: 64).write(to: url)
        let token = try XCTUnwrap(SourceFileIdentity.read(url)).token
        let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
        let fields = token.split(separator: ":")
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(fields.first.map(String.init), inode.stringValue)
    }

    /// A ctime-only change (a Finder tag) is confirmed by the signature and kept; the
    /// new token is stored, so the next scan does not read again.
    func testSuspicionConfirmedUnchangedBySignatureKeepsEverything() throws {
        let (store, folder, id, root) = try seeded(identity: "7:100:10:0:10:0")
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let file = ScannedFile(filename: "a.nef", fileSize: 100, fileMTime: 10, sourceIdentity: "7:100:10:0:99:0")
        XCTAssertEqual(try store.scan(folderID: folder, files: [file],
                                      signature: { _ in reads += 1; return "sig-A" }).unchanged, 1)
        XCTAssertEqual(reads, 1)
        try assertKept(store, id)
        XCTAssertEqual(try store.scan(folderID: folder, files: [file],
                                      signature: { _ in reads += 1; return "sig-A" }).unchanged, 1)
        XCTAssertEqual(reads, 1, "a confirmed token is adopted, not re-read every scan")
    }

    /// A real same-size rewrite still invalidates: its signature differs, and the new
    /// signature is recorded rather than left for the backfill.
    func testSuspicionConfirmedChangedBySignatureInvalidates() throws {
        let (store, folder, id, root) = try seeded(identity: "7:100:10:0:10:0")
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let file = ScannedFile(filename: "a.nef", fileSize: 100, fileMTime: 10, sourceIdentity: "9:100:10:0:12:0")
        XCTAssertEqual(try store.scan(folderID: folder, files: [file], signature: { _ in "sig-B" }).changed, [id])
        XCTAssertEqual(try store.photo(id: id)?.quickSig, "sig-B")
        XCTAssertNil(try store.photo(id: id)?.width)
        XCTAssertTrue(try store.previews(photoID: id).isEmpty)
    }
}
