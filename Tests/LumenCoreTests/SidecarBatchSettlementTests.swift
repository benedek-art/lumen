#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class SidecarBatchSettlementTests: XCTestCase {
    private func withStore(_ body: (CatalogStore, [Int64], [UnsavedSidecarRecord], URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-settle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        let files = (0..<3).map { ScannedFile(filename: "\($0).JPG", fileSize: 1, fileMTime: 1, ext: "jpg") }
        _ = try store.scan(folderID: folder, files: files)
        let ids = try files.map { try XCTUnwrap(store.photo(folderID: folder, filename: $0.filename)).id }
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.5
        for id in ids { try store.saveRecipe(recipe, photoID: id, isCurrent: true) }
        let records = ids.enumerated().map { index, id in
            UnsavedSidecarRecord(photoPath: root.appendingPathComponent("\(index).JPG").path,
                photoID: id, stated: [.recipe, .strokes], generation: index == 1 ? nil : "generation-\(index)")
        }
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode(records))
        try body(store, ids, records, root)
    }

    private func publication(_ record: UnsavedSidecarRecord, observe: Bool = true) -> SidecarIntentPublication {
        SidecarIntentPublication(photoPath: record.photoPath, photoID: record.photoID, generation: record.generation,
            observation: observe ? .init(modificationTime: 42, digest: "sha256:written-\(record.photoPath)") : nil)
    }

    func testExactPathPhotoIDAndOptionalGenerationMatchIncludingExplicitLegacyNil() throws {
        try withStore { store, ids, records, root in
            let edits = try ids.map { try store.currentEdit(photoID: $0) }
            let wrongID = SidecarIntentPublication(photoPath: records[2].photoPath, photoID: ids[0],
                generation: records[2].generation, observation: .init(modificationTime: 999, digest: "must-not-observe"))
            let absentNil = SidecarIntentPublication(photoPath: root.appendingPathComponent("absent.JPG").path,
                photoID: ids[2], generation: nil, observation: .init(modificationTime: 999, digest: "must-not-observe"))
            let result = try store.settleSidecarIntents([self.publication(records[0]), self.publication(records[1]), wrongID, absentNil])
            XCTAssertEqual(result.settled.map(\.photoPath), records.prefix(2).map(\.photoPath))
            XCTAssertEqual(result.debt, [records[2]])
            for id in ids.prefix(2) { XCTAssertEqual(try store.photo(id: id)?.sidecarMTime, 42) }
            XCTAssertNil(try store.photo(id: ids[2])?.sidecarMTime)
            XCTAssertNil(try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[2])))
            XCTAssertEqual(try ids.map { try store.currentEdit(photoID: $0) }, edits)
            // Explicit nil ceased to exist after settlement; absent nil cannot match.
            XCTAssertTrue(try store.settleSidecarIntents([self.publication(records[1])]).settled.isEmpty)
        }
    }

    func testNewerIntentCannotBeObservedOrSettledByPreparedOlderPublication() throws {
        try withStore { store, ids, records, _ in
            let old = self.publication(records[0])
            var newer = records[0]; newer.generation = "newer" // keep full old intent fields
            _ = try store.withSidecarIntent { ((), [newer]) }
            let result = try store.settleSidecarIntents([old])
            XCTAssertTrue(result.settled.isEmpty)
            XCTAssertEqual(result.debt.first?.generation, "newer")
            XCTAssertNil(try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[0])))
            XCTAssertNil(try store.photo(id: ids[0])?.sidecarMTime)
            XCTAssertEqual(try store.settleSidecarIntents([self.publication(newer)]).settled.count, 1)
        }
    }

    func testUnacknowledgedExternalRecipeKeepsPreviousObservationWhileSettlingPublication() throws {
        try withStore { store, ids, records, _ in
            let key = SidecarIntentPublication.observationKey(photoID: ids[0])
            try store.setMetaValue(key, "sha256:previous")
            try store.setSidecarMTime(7, photoID: ids[0])
            XCTAssertEqual(try store.settleSidecarIntents([self.publication(records[0], observe: false)]).settled.count, 1)
            XCTAssertEqual(try store.metaValue(key), "sha256:previous")
            XCTAssertEqual(try store.photo(id: ids[0])?.sidecarMTime, 7)
        }
    }

    func testObservationAndJournalSQLFailuresRollBackWholeGroupAndRetainWrittenFilesForRetry() throws {
        for failObservation in [true, false] {
            try withStore { store, ids, records, _ in
                let before = try XCTUnwrap(store.metaValue(UnsavedSidecarRecord.metaKey))
                let payload = Data("exact successfully written portable bytes".utf8)
                // Physical publication precedes SQL and is intentionally not rolled back.
                for record in records { try payload.write(to: URL(fileURLWithPath: record.photoPath + ".xmp"), options: .atomic) }
                let key = failObservation ? SidecarIntentPublication.observationKey(photoID: ids[1]) : UnsavedSidecarRecord.metaKey
                let operation = failObservation ? "INSERT" : "DELETE"
                let column = failObservation ? "NEW" : "OLD"
                try store.debugExecute("CREATE TRIGGER reject_batch BEFORE \(operation) ON meta WHEN \(column).key = '\(key)' BEGIN SELECT RAISE(ABORT, 'injected batch SQL refusal'); END;")
                XCTAssertThrowsError(try store.settleSidecarIntents(records.map { self.publication($0) }))
                XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), before)
                for id in ids {
                    XCTAssertNil(try store.photo(id: id)?.sidecarMTime)
                    XCTAssertNil(try store.metaValue(SidecarIntentPublication.observationKey(photoID: id)))
                }
                for record in records { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.photoPath + ".xmp")), payload) }
                try store.debugExecute("DROP TRIGGER reject_batch;")
                XCTAssertEqual(try store.settleSidecarIntents(records.map { self.publication($0) }).settled.count, 3)
                XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
            }
        }
    }

    func testPartialGroupJournalUpsertFailureRollsBackObservationsAndPreservesExactRemainder() throws {
        try withStore { store, ids, records, _ in
            let before = try store.metaValue(UnsavedSidecarRecord.metaKey)
            try store.debugExecute("CREATE TRIGGER reject_partial BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected partial journal refusal'); END;")
            XCTAssertThrowsError(try store.settleSidecarIntents(records.prefix(2).map { self.publication($0) }))
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), before)
            for id in ids {
                XCTAssertNil(try store.photo(id: id)?.sidecarMTime)
                XCTAssertNil(try store.metaValue(SidecarIntentPublication.observationKey(photoID: id)))
            }
            try store.debugExecute("DROP TRIGGER reject_partial;")
            let result = try store.settleSidecarIntents(records.prefix(2).map { self.publication($0) })
            XCTAssertEqual(result.settled.count, 2)
            XCTAssertEqual(result.debt, [records[2]])
        }
    }

    func testMalformedJournalAndDuplicatePublicationPathsRefuseWithoutObservationOrDebtLoss() throws {
        try withStore { store, ids, records, _ in
            let raw = "[{\"photoPath\":\"/future\",\"stated\":64}]"
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, raw)
            XCTAssertThrowsError(try store.settleSidecarIntents([self.publication(records[0])]))
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), raw)
            XCTAssertNil(try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[0])))
            let valid = UnsavedSidecarRecord.encode(records)
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, valid)
            XCTAssertThrowsError(try store.settleSidecarIntents([self.publication(records[0]), self.publication(records[0])]))
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), valid)
        }
    }
}
#endif
