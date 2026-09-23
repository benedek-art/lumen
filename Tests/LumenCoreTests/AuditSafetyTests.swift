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
    func testReadOnlyIntegrityProbeCannotCreateMissingBackups() throws {
        let path = try scratch().appendingPathComponent("missing.db").path
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try SQLiteDatabase(path: path, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testExtendedSQLiteResultsRetainTheirCorruptionClassification() {
        // SQLite result codes: CORRUPT=11, BUSY=5, IOERR=10; low byte is primary.
        for code: Int32 in [11, 11 | (1 << 8), 26] {
            XCTAssertTrue(SQLiteError.step(code: code, message: "test", sql: "").indicatesCorruptDatabase)
        }
        for code: Int32 in [5, 5 | (2 << 8), 10, 10 | (3 << 8), 14] {
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
