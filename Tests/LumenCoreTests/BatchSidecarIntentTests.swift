#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class BatchSidecarIntentTests: XCTestCase {
    private func withStore(count: Int = 3, _ body: (CatalogStore, [Int64], URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        let files = (0..<count).map { ScannedFile(filename: "\($0).ARW", fileSize: 1, fileMTime: 1, ext: "arw") }
        _ = try store.scan(folderID: folder, files: files)
        let ids = try files.map { try XCTUnwrap(store.photo(folderID: folder, filename: $0.filename)).id }
        var old = Recipe(); old.develop.tone.exposure = 0.25
        for id in ids { try store.saveRecipe(old, photoID: id, isCurrent: true) }
        try body(store, ids, root)
    }

    func testRejectedMiddleSavepointPreservesItsOldCurrentEditWhileOtherRowsCommit() throws {
        try withStore { store, ids, root in
            let before = try store.currentEdit(photoID: ids[1])
            try store.debugExecute("CREATE TRIGGER reject_middle BEFORE UPDATE OF recipe ON edit WHEN OLD.photo_id = \(ids[1]) BEGIN SELECT RAISE(ABORT, 'injected middle refusal'); END;")
            var rejected: [Int64] = []
            let result = try store.withSidecarIntent {
                var intents: [UnsavedSidecarRecord] = []
                for (index, id) in ids.enumerated() {
                    var recipe = Recipe(); recipe.develop.tone.exposure = Double(index + 1)
                    do {
                        try store.saveRecipe(recipe, photoID: id, isCurrent: true)
                        intents.append(UnsavedSidecarRecord(photoPath: root.appendingPathComponent("\(index).ARW").path,
                            photoID: id, stated: [.recipe, .strokes], generation: "batch-\(id)"))
                    } catch { rejected.append(id) }
                }
                return ((), intents)
            }
            XCTAssertEqual(rejected, [ids[1]])
            XCTAssertEqual(try store.currentEdit(photoID: ids[1]), before,
                           "the failed UPDATE must roll back its earlier is_current demotion")
            XCTAssertEqual(try store.currentRecipe(photoID: ids[0])?.develop.tone.exposure, 1)
            XCTAssertEqual(try store.currentRecipe(photoID: ids[2])?.develop.tone.exposure, 3)
            XCTAssertEqual(Set(result.debt.compactMap(\.photoID)), [ids[0], ids[2]])
        }
    }

    func testOneFinalJournalFailureRollsBackEveryAcceptedRecipe() throws {
        try withStore { store, ids, root in
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            try store.debugExecute("CREATE TRIGGER reject_batch_intent BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected final journal refusal'); END;")
            XCTAssertThrowsError(try store.withSidecarIntent {
                var intents: [UnsavedSidecarRecord] = []
                for (index, id) in ids.enumerated() {
                    var recipe = Recipe(); recipe.develop.tone.exposure = Double(index + 1)
                    try store.saveRecipe(recipe, photoID: id, isCurrent: true)
                    intents.append(UnsavedSidecarRecord(photoPath: root.appendingPathComponent("\(index).ARW").path,
                        photoID: id, stated: [.recipe], generation: "batch-\(id)"))
                }
                return ((), intents)
            })
            XCTAssertEqual(try ids.map { try store.currentEdit(photoID: $0) }, before)
            XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        }
    }

    func testBatchPreservesOlderFieldsKeywordRemovalAndGenerationSettlement() throws {
        try withStore { store, ids, root in
            let path = root.appendingPathComponent("0.ARW").path
            let older = UnsavedSidecarRecord(photoPath: path, photoID: ids[0], stated: [.rating, .keywords],
                keywordEdit: SidecarKeywordEdit(removed: ["Private"]), generation: "older")
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([older]))
            let result = try store.withSidecarIntent {
                var intents: [UnsavedSidecarRecord] = []
                for (index, id) in ids.enumerated() {
                    var recipe = Recipe(); recipe.develop.tone.exposure = Double(index + 1)
                    try store.saveRecipe(recipe, photoID: id, isCurrent: true)
                    intents.append(UnsavedSidecarRecord(photoPath: root.appendingPathComponent("\(index).ARW").path,
                        photoID: id, stated: [.recipe, .strokes], generation: "new-\(id)"))
                }
                return ((), intents)
            }
            let owed = try XCTUnwrap(result.debt.first { $0.photoID == ids[0] })
            XCTAssertEqual(owed.statedFields, [.rating, .keywords, .recipe, .strokes])
            XCTAssertEqual(owed.keywordEdit?.removed, ["Private"])
            XCTAssertEqual(owed.generation, "new-\(ids[0])")
            XCTAssertFalse(try store.settleSidecarIntent(photoPath: path, generation: "older"))
            XCTAssertEqual(try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey)).count, 3)
        }
    }
    func testLaterChunkJournalFailureKeepsCommittedPrefixAndRollsBackOnlyCurrentChunk() throws {
        try withStore(count: 130) { store, ids, root in
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            try store.debugExecute("CREATE TRIGGER reject_second_chunk BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' AND instr(NEW.value, '/64.ARW') > 0 BEGIN SELECT RAISE(ABORT, 'injected second chunk refusal'); END;")
            var failureCount = 0
            for start in stride(from: 0, to: ids.count, by: 64) {
                do {
                    _ = try store.withSidecarIntent {
                        var intents: [UnsavedSidecarRecord] = []
                        for index in start..<min(start + 64, ids.count) {
                            var recipe = Recipe(); recipe.develop.tone.exposure = 1.5
                            try store.saveRecipe(recipe, photoID: ids[index], isCurrent: true)
                            intents.append(UnsavedSidecarRecord(photoPath: root.appendingPathComponent("\(index).ARW").path,
                                photoID: ids[index], stated: [.recipe], generation: "chunk-\(index)"))
                        }
                        return ((), intents)
                    }
                } catch { failureCount += 1; break }
            }
            XCTAssertEqual(failureCount, 1)
            for index in ids.indices {
                if index < 64 {
                    XCTAssertEqual(try store.currentRecipe(photoID: ids[index])?.develop.tone.exposure, 1.5)
                } else { XCTAssertEqual(try store.currentEdit(photoID: ids[index]), before[index]) }
            }
            let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(Set(debt.compactMap(\.photoID)), Set(ids.prefix(64)))
        }
    }

}
#endif
