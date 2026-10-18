#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class CatalogSidecarIntentTests: XCTestCase {
    private func withStore(_ body: (CatalogStore, Int64, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "frame.ARW", fileSize: 1, fileMTime: 1, ext: "arw")])
        let id = try XCTUnwrap(store.photo(folderID: folder, filename: "frame.ARW")).id
        try body(store, id, root.appendingPathComponent("frame.ARW"))
    }

    func testIntentWriteFailureRollsBackRecipeCullingAndKeywords() throws {
        try withStore { store, id, photo in
            var baseline = Recipe(); baseline.develop.tone.exposure = 0.5
            try store.saveRecipe(baseline, photoID: id, isCurrent: true)
            let before = try store.currentEdit(photoID: id)
            try store.debugExecute("CREATE TRIGGER reject_intent BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected intent refusal'); END;")
            var changed = baseline; changed.develop.tone.exposure = 2
            XCTAssertThrowsError(try store.withSidecarIntent {
                try store.saveRecipe(changed, photoID: id, isCurrent: true)
                try store.setCullingState(flag: .pick, rating: 4, label: .red, photoID: id)
                _ = try store.addKeyword("ShouldRollBack", photoIDs: [id])
                return ((), [UnsavedSidecarRecord(photoPath: photo.path, photoID: id,
                    stated: [.recipe, .rating, .flag, .label, .keywords], generation: "new")])
            })
            XCTAssertEqual(try store.currentEdit(photoID: id), before)
            let row = try XCTUnwrap(store.photo(id: id))
            XCTAssertEqual(row.rating, 0); XCTAssertEqual(row.flag, .unflagged); XCTAssertNil(row.label)
            XCTAssertEqual(try store.keywords(photoID: id), [])
            XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        }
    }

    func testOlderPublicationCannotSettleNewerCommittedIntent() throws {
        try withStore { store, id, photo in
            let older = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe], generation: "older")
            _ = try store.withSidecarIntent { ((), [older]) }
            let newer = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.rating], generation: "newer")
            let committed = try store.withSidecarIntent {
                try store.setRating(4, photoID: id)
                return ((), [newer])
            }
            XCTAssertEqual(committed.debt.first?.statedFields, [.recipe, .rating])
            XCTAssertFalse(try store.settleSidecarIntent(photoPath: photo.path, generation: "older"))
            let owed = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(owed.first?.generation, "newer")
            XCTAssertEqual(owed.first?.statedFields, [.recipe, .rating])
            XCTAssertTrue(try store.settleSidecarIntent(photoPath: photo.path, generation: "newer"))
            XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        }
    }

    func testLegacyDebtRetainsFieldsAndKeywordRemovalWhenNewIntentMerges() throws {
        try withStore { store, id, photo in
            let legacy = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.keywords],
                keywordEdit: SidecarKeywordEdit(removed: ["Private"]))
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([legacy]))
            let oldBytes = try XCTUnwrap(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertFalse(oldBytes.contains("generation"))
            let committed = try store.withSidecarIntent {
                ((), [UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe], generation: "new")])
            }
            XCTAssertEqual(committed.debt.first?.keywordEdit?.removed, ["Private"])
            XCTAssertEqual(committed.debt.first?.statedFields, [.keywords, .recipe])
            XCTAssertFalse(try store.settleSidecarIntent(photoPath: photo.path, generation: nil))
        }
    }

    func testMalformedExistingDebtRefusesMutationInsteadOfDiscardingIt() throws {
        try withStore { store, id, photo in
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, "not-json")
            XCTAssertThrowsError(try store.withSidecarIntent {
                try store.setRating(4, photoID: id)
                return ((), [UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.rating], generation: "new")])
            })
            XCTAssertEqual(try store.photo(id: id)?.rating, 0)
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), "not-json")
        }
    }
    func testUnknownFutureFieldsAndKeysRefuseMutationWithoutRewritingJournal() throws {
        try withStore { store, id, photo in
            let documents = [
                "[{\"photoPath\":\"/fixture\",\"stated\":8},{\"photoPath\":\"/fixture\",\"stated\":32}]",
                "[{\"photoPath\":\"\",\"stated\":8}]",
                "[{\"photoPath\":\"relative.JPG\",\"stated\":8}]",
                "[{\"photoPath\":\"/fixture\",\"stated\":64}]",
                "[{\"photoPath\":\"/fixture\",\"stated\":-1}]",
                "[{\"photoPath\":\"/fixture\",\"stated\":8,\"futurePainting\":\"opaque\"}]",
                "[{\"photoPath\":\"/fixture\",\"stated\":32,\"keywordEdit\":{\"added\":[],\"removed\":[],\"futureOperation\":true}}]"
            ]
            for raw in documents {
                try store.setMetaValue(UnsavedSidecarRecord.metaKey, raw)
                XCTAssertThrowsError(try store.withSidecarIntent {
                    try store.setRating(4, photoID: id)
                    return ((), [UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.rating], generation: "new")])
                })
                XCTAssertEqual(try store.photo(id: id)?.rating, 0)
                XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), raw)
            }
        }
    }

    func testGenerationBearingIntentRelinksWithFieldsAndKeywordRemovalAcrossReopen() throws {
        try withStore { store, id, photo in
            try Data([1]).write(to: photo)
            try store.setQuickSig(QuickSignature.compute(url: photo), photoID: id)
            var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
            _ = try store.withSidecarIntent {
                try store.saveRecipe(recipe, photoID: id, isCurrent: true)
                return ((), [UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe, .keywords],
                    keywordEdit: SidecarKeywordEdit(removed: ["Private"]), generation: "original-generation")])
            }
            let before = try store.currentEdit(photoID: id)
            let target = try store.originalRelinkTarget(photoID: id)
            let moved = photo.deletingLastPathComponent().appendingPathComponent("moved/frame.ARW")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: photo, to: moved)
            let candidate = try OriginalRelinkCandidate.inspect(moved)
            _ = try store.relinkOriginal(target, candidate: candidate,
                additionalSidecarDebt: [UnsavedSidecarRecord(photoPath: photo.path, photoID: id,
                    stated: [.rating], generation: "relink-generation")])
            XCTAssertEqual(try store.currentEdit(photoID: id), before)
            store.close()
            let reopened = try CatalogStore(path: photo.deletingLastPathComponent().appendingPathComponent("lumen.db").path)
            defer { reopened.close() }
            XCTAssertEqual(try reopened.originalRelinkTarget(photoID: id).original, moved)
            let debt = try UnsavedSidecarRecord.decodeValidated(reopened.metaValue(UnsavedSidecarRecord.metaKey))
            let owed = try XCTUnwrap(debt.first)
            XCTAssertEqual(owed.photoPath, moved.path)
            XCTAssertEqual(owed.photoID, id)
            XCTAssertEqual(owed.generation, "relink-generation")
            XCTAssertEqual(owed.statedFields, [.recipe, .keywords, .rating])
            XCTAssertEqual(owed.keywordEdit?.removed, ["Private"])
        }
    }

}
#endif
