import XCTest
@testable import LumenCore

final class AuditSafetyTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-audit-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAlreadyPresentStillChecksThePlannedByteCount() throws {
        let root = try scratch()
        let source = root.appendingPathComponent("source.RAF")
        let destination = root.appendingPathComponent("destination.RAF")
        let prefix = Data(repeating: 7, count: 100)
        try prefix.write(to: source)
        try prefix.write(to: destination)
        let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: 5000,
            destinations: [IngestPlannedDestination(url: destination, role: .primary)])])
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertFalse(report.allVerified, "REL-03: identical truncations are not the planned original")
        XCTAssertEqual(report.alreadyPresent.count, 0)
        XCTAssertEqual(try Data(contentsOf: destination), prefix, "Do not destroy the existing partial file")
    }

    #if canImport(SQLite3)
    func testPartialScanCannotRelocateAnUnseenTwinOrRemoveAlbumMembership() throws {
        let root = try scratch()
        let store = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        let a = ScannedFile(filename: "a.ARW", fileSize: 100, fileMTime: 1, quickSig: "same-bytes", ext: "arw")
        let b = ScannedFile(filename: "b.ARW", fileSize: 100, fileMTime: 1, quickSig: "same-bytes", ext: "arw")
        _ = try store.scan(folderID: folder, files: [a], at: 100)
        let original = try XCTUnwrap(store.photo(folderID: folder, filename: a.filename))
        let album = try store.createCollection(name: "Keep")
        try store.addToCollection(album, photoIDs: [original.id])
        _ = try store.scan(folderID: folder, files: [], at: 200, completeListing: false)
        _ = try store.scan(folderID: folder, files: [b], at: 201, completeListing: false)
        let rows = try store.photos(folderID: folder, includeMissing: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try store.photo(folderID: folder, filename: a.filename)?.id, original.id)
        XCTAssertNotEqual(try store.photo(folderID: folder, filename: b.filename)?.id, original.id)
        var query = PhotoQuery(); query.albumID = album; query.includeMissing = false
        XCTAssertEqual(try store.photos(matching: query).map(\.id), [original.id])
        _ = try store.scan(folderID: folder, files: [b], at: 300)
        XCTAssertEqual(try store.photos(folderID: folder, includeMissing: false).count, 1)
        query.includeMissing = true
        XCTAssertEqual(try store.photos(matching: query).map(\.id), [original.id], "Even true missing state preserves album identity")
    }

    func testRecoverySkipsLegacySnapshotWithMissingBrushPayload() throws {
        let root = try scratch()
        let path = root.appendingPathComponent("lumen.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        let old = backups.appendingPathComponent("lumen-2026-09-20T12-00-00Z.db")
        try store.backup(to: old.path)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:xxh64:0123456789abcdef"
        var recipe = Recipe()
        recipe.masks = [Mask(id: "missing-paint", name: "Paint", components: [brush])]
        try store.saveRecipe(recipe, photoID: id, isCurrent: true)
        try store.setRating(5, photoID: id)
        try store.backup(to: backups.appendingPathComponent("lumen-2026-09-21T12-00-00Z.db").path)
        store.close()
        try Data("damaged isolated catalog".utf8).write(to: URL(fileURLWithPath: path))
        let result = CatalogStore.recoverIfNeeded(path: path, backupDirectory: backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, old.path, "A database without its brush is not a usable snapshot")
    }

    func testReadOnlyIntegrityProbeCannotCreateMissingBackups() throws {
        let path = try scratch().appendingPathComponent("missing.db").path
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try SQLiteDatabase(path: path, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testExtendedSQLiteResultsRetainTheirCorruptionClassification() {
        // SQLite result codes: CORRUPT=11, BUSY=5, IOERR=10; low byte is primary.
        let corruptCodes: [Int32] = [11, 11 | (1 << 8), 26]
        for code in corruptCodes {
            XCTAssertTrue(SQLiteError.step(code: code, message: "test", sql: "").indicatesCorruptDatabase)
        }
        let operationalCodes: [Int32] = [5, 5 | (2 << 8), 10, 10 | (3 << 8), 14]
        for code in operationalCodes {
            XCTAssertFalse(SQLiteError.step(code: code, message: "test", sql: "").indicatesCorruptDatabase)
        }
    }

    func testBusyCatalogIsNotReplacedByAnOlderBackup() throws {
        let root = try scratch()
        let db = root.appendingPathComponent("lumen.db").path
        let cache = root.appendingPathComponent("cache.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = try CatalogStore(path: db, cachePath: cache)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        try store.backup(to: backups.appendingPathComponent("lumen-2026-09-21.db").path)
        try store.setRating(5, photoID: id)
        store.close()
        let lock = try SQLiteDatabase(path: db)
        defer { lock.close() }
        try lock.execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;")
        let recovery = CatalogStore.recoverIfNeeded(path: db, backupDirectory: backups.path)
        try lock.execute("ROLLBACK;")
        lock.close()
        if case .restored = recovery.outcome { XCTFail("REL-01: BUSY is not corruption") }
        XCTAssertFalse(recovery.isDamaged)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(".damaged-") })
        let reopened = try CatalogStore(path: db, cachePath: cache)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.photo(id: id)?.rating, 5)
    }
    #endif
}
