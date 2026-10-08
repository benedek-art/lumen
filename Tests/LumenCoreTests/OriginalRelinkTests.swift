#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class OriginalRelinkTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-relink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ root: URL) throws -> CatalogStore {
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
            cachePath: root.appendingPathComponent("cache.db").path)
        addTeardownBlock { store.close() }
        return store
    }
    private func seed(_ store: CatalogStore, root: URL, name: String = "a.JPG", bytes: Data = Data(repeating: 17, count: 256), fullHash: Bool = false) throws -> OriginalRelinkTarget {
        let old = root.appendingPathComponent("old").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: old)
        let identity = try OriginalRelinkCandidate.inspect(old, fullHashRequired: fullHash)
        let folder = try store.registerFolder(path: old.deletingLastPathComponent().path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: name, fileSize: identity.fileSize,
            fileMTime: identity.fileMTime, quickSig: identity.quickSignature, fullHash: identity.fullHash, missing: true))
        try store.setMetaValue("source_identity_\(id)", identity.identity.token)
        return try store.originalRelinkTarget(photoID: id)
    }
    private func move(_ target: OriginalRelinkTarget, root: URL) throws -> OriginalRelinkCandidate {
        let destination = root.appendingPathComponent("new/renamed-" + target.original.lastPathComponent)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target.original, to: destination)
        return try OriginalRelinkCandidate.inspect(destination, fullHashRequired: target.fullHash != nil)
    }

    func testTwoPhotosKeepIDsEditsVersionsHistoryMembershipAndBlobAcrossReopen() throws {
        let root = try scratch(), catalog = try store(root)
        let first = try seed(catalog, root: root)
        let second = try seed(catalog, root: root, name: "b.JPG", bytes: Data(repeating: 42, count: 300))
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        _ = try catalog.saveRecipe(recipe, photoID: first.photoID, kind: .working, name: nil, isCurrent: true)
        _ = try catalog.saveRecipe(Recipe(), photoID: first.photoID, kind: .version, name: "Before", isCurrent: false)
        var other = Recipe(); other.develop.tone.exposure = -0.5
        _ = try catalog.saveRecipe(other, photoID: second.photoID, kind: .working, name: nil, isCurrent: true)
        try catalog.setRating(4, photoID: first.photoID)
        let album = try catalog.createCollection(name: "Keep")
        try catalog.addToCollection(album, photoIDs: [first.photoID, second.photoID])
        _ = try catalog.addKeyword("harbour", photoIDs: [first.photoID])
        try catalog.debugExecute("INSERT INTO history(photo_id,seq,at,label,delta) VALUES (\(first.photoID),1,1,'Exposure',X'1234');")
        try catalog.debugExecute("INSERT INTO blob(hash,bytes,data,created_at) VALUES ('brush-fixture',2,X'ABCD',1);")
        try catalog.recordPreview(PreviewRow(photoID: first.photoID, level: .grid, path: "old-preview.jpg"))
        let originalEdits = try catalog.edits(photoID: first.photoID)
        let candidate = try move(first, root: root)
        let result = try catalog.relinkOriginal(first, candidate: candidate)
        XCTAssertEqual(result.photoID, first.photoID)
        XCTAssertEqual(result.invalidatedPreviews.count, 1)
        XCTAssertTrue(try catalog.previews(photoID: first.photoID).isEmpty)
        XCTAssertEqual(try catalog.edits(photoID: first.photoID), originalEdits)
        XCTAssertEqual(try catalog.currentRecipe(photoID: second.photoID), other)
        XCTAssertEqual(try catalog.originalRelinkTarget(photoID: second.photoID), second)
        XCTAssertEqual(try catalog.keywords(photoID: first.photoID), ["harbour"])
        XCTAssertEqual(try catalog.photo(id: first.photoID)?.rating, 4)
        XCTAssertFalse(try XCTUnwrap(catalog.photo(id: first.photoID)).missing)
        catalog.close()
        let reopened = try store(root)
        XCTAssertEqual(try reopened.originalRelinkTarget(photoID: first.photoID).original, candidate.url)
        XCTAssertEqual(try reopened.currentRecipe(photoID: first.photoID), recipe)
        let raw = try SQLiteDatabase(path: root.appendingPathComponent("catalog.db").path, readOnly: true)
        XCTAssertEqual(try raw.scalarInt("SELECT COUNT(*) FROM history WHERE photo_id = \(first.photoID) AND delta = X'1234';"), 1)
        XCTAssertEqual(try raw.scalarInt("SELECT COUNT(*) FROM album_photo WHERE album_id = \(album);"), 2)
        XCTAssertEqual(try raw.scalarInt("SELECT COUNT(*) FROM blob WHERE hash = 'brush-fixture' AND data = X'ABCD';"), 1)
    }

    func testWrongFileSizeAndSameSizeWrongSignaturePreserveOriginalMapping() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        try FileManager.default.removeItem(at: target.original)
        let wrong = root.appendingPathComponent("wrong.JPG")
        for bytes in [Data(repeating: 1, count: 256), Data(repeating: 17, count: 257)] {
            try bytes.write(to: wrong)
            let candidate = try OriginalRelinkCandidate.inspect(wrong)
            XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate))
            XCTAssertEqual(try catalog.originalRelinkTarget(photoID: target.photoID), target)
        }
    }

    func testDuplicateSignatureOwnersAndAlreadyRegisteredDestinationAreRefused() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        let duplicate = try seed(catalog, root: root, name: "duplicate.JPG")
        let candidate = try move(target, root: root)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate)) { XCTAssertEqual($0 as? OriginalRelinkError, .ambiguous) }
        try catalog.debugExecute("UPDATE photo SET quick_sig = 'different' WHERE id = \(duplicate.photoID);")
        let folder = try catalog.registerFolder(path: candidate.url.deletingLastPathComponent().path)
        _ = try catalog.upsertPhoto(PhotoRow(folderID: folder, filename: candidate.url.lastPathComponent,
            fileSize: candidate.fileSize, quickSig: "different"))
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate)) { XCTAssertEqual($0 as? OriginalRelinkError, .alreadyRegistered) }
        XCTAssertEqual(try catalog.originalRelinkTarget(photoID: target.photoID), target)
    }

    func testPresentOriginalMissingCandidateAndChangedCandidateAreRefused() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        let original = try OriginalRelinkCandidate.inspect(target.original)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: original)) { XCTAssertEqual($0 as? OriginalRelinkError, .originalAvailable) }
        XCTAssertThrowsError(try OriginalRelinkCandidate.inspect(root.appendingPathComponent("absent.JPG")))
        let candidate = try move(target, root: root)
        try Data(repeating: 18, count: 256).write(to: candidate.url)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate)) { XCTAssertEqual($0 as? OriginalRelinkError, .candidateChanged) }
        XCTAssertEqual(try catalog.originalRelinkTarget(photoID: target.photoID), target)
    }

    func testSQLFailureRollsBackFolderPathIdentityDebtAndCacheTogether() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        let debt = UnsavedSidecarRecord(photoPath: target.original.path, photoID: target.photoID, stated: [.recipe, .keywords],
            keywordEdit: SidecarKeywordEdit(added: ["New"], removed: ["Old"]))
        let encoded = UnsavedSidecarRecord.encode([debt])
        try catalog.setMetaValue(UnsavedSidecarRecord.metaKey, encoded)
        try catalog.recordPreview(PreviewRow(photoID: target.photoID, level: .grid, path: "cached.jpg"))
        let token = try catalog.metaValue("source_identity_\(target.photoID)")
        let candidate = try move(target, root: root)
        try catalog.debugExecute("CREATE TEMP TRIGGER refuse_relink BEFORE UPDATE OF folder_id ON photo BEGIN SELECT RAISE(ABORT,'injected'); END;")
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate))
        XCTAssertEqual(try catalog.originalRelinkTarget(photoID: target.photoID), target)
        XCTAssertEqual(try catalog.metaValue("source_identity_\(target.photoID)"), token)
        XCTAssertEqual(try catalog.metaValue(UnsavedSidecarRecord.metaKey), encoded)
        XCTAssertEqual(try catalog.previews(photoID: target.photoID).count, 1)
        XCTAssertEqual(try catalog.folders().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
    }

    func testCompatibleDebtMovesAndMalformedDebtIsNeverRewritten() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        let candidate = try move(target, root: root)
        let malformed = "{unknown pending evidence}"
        try catalog.setMetaValue(UnsavedSidecarRecord.metaKey, malformed)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate))
        XCTAssertEqual(try catalog.metaValue(UnsavedSidecarRecord.metaKey), malformed)
        let unknown = "[{\"photoPath\":\"keep\",\"photoID\":null,\"stated\":1,\"newerField\":\"never erase\"}]"
        try catalog.setMetaValue(UnsavedSidecarRecord.metaKey, unknown)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate))
        XCTAssertEqual(try catalog.metaValue(UnsavedSidecarRecord.metaKey), unknown)
        let debt = UnsavedSidecarRecord(photoPath: target.original.path, photoID: target.photoID, stated: [.keywords],
            keywordEdit: SidecarKeywordEdit(added: ["New"], removed: ["Old"]))
        try catalog.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([debt]))
        _ = try catalog.relinkOriginal(target, candidate: candidate)
        let moved = UnsavedSidecarRecord.decode(try catalog.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].photoPath, candidate.url.path)
        XCTAssertEqual(moved[0].keywordEdit, debt.keywordEdit)
        XCTAssertEqual(moved[0].photoID, target.photoID)
    }

    func testStoredFullHashRejectsSamePrefixSizeButDifferentTail() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root, bytes: Data(repeating: 17, count: QuickSignature.prefixByteCount + 64), fullHash: true)
        let candidate = try move(target, root: root)
        var changed = try Data(contentsOf: candidate.url); changed[changed.count - 1] = 99
        try changed.write(to: candidate.url)
        let inspected = try OriginalRelinkCandidate.inspect(candidate.url, fullHashRequired: true)
        XCTAssertEqual(inspected.quickSignature, target.quickSignature)
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: inspected)) { XCTAssertEqual($0 as? OriginalRelinkError, .mismatch) }
    }

    func testAbsentStoredSignatureAndStalePreflightMappingAreRefused() throws {
        let root = try scratch(), catalog = try store(root)
        let target = try seed(catalog, root: root)
        let candidate = try move(target, root: root)
        try catalog.debugExecute("UPDATE photo SET quick_sig = NULL WHERE id = \(target.photoID);")
        let unknown = try catalog.originalRelinkTarget(photoID: target.photoID)
        XCTAssertThrowsError(try catalog.relinkOriginal(unknown, candidate: candidate)) { XCTAssertEqual($0 as? OriginalRelinkError, .unavailableIdentity) }
        XCTAssertThrowsError(try catalog.relinkOriginal(target, candidate: candidate)) { XCTAssertEqual($0 as? OriginalRelinkError, .changedMapping) }
    }
}
#endif
