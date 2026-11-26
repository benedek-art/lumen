// A catalog restored from a backup owes no sidecars.
//
// The backup can carry `sidecar_unsaved`: the quit backup runs after the quit flush,
// so a flush that failed on an offline volume is in it. At launch `CatalogService`
// rebuilds every owed sidecar from the catalog and writes it. After a restore that
// catalog is the BACKUP, so the rebuild wrote backup-era ratings and recipes over
// sidecars saved since, which are the copies the restore notice says the newer edits
// come back from.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogRestoreSidecarDebtTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-restore-debt-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var catalogPath: String { directory.appendingPathComponent("lumen.db").path }
    private var backups: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: catalogPath,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    func testARestoredCatalogOwesNoSidecarsTheBackupOwed() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = try makeStore()
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/day1")
        try store.scan(folderID: folderID, files: (0..<200).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0), fileMTime: 1_700_000_000, ext: "arw")
        })
        let photo = try XCTUnwrap(store.photo(folderID: folderID, filename: "DSC0000.ARW"))
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.3
        try store.saveRecipe(recipe, photoID: photo.id, isCurrent: true)
        // The quit flush failed (volume offline), so the quit backup carries the debt.
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([
            UnsavedSidecarRecord(photoPath: "/Volumes/Shoots/day1/DSC0000.ARW",
                                 photoID: photo.id, stated: [.rating, .recipe]),
        ]))
        try store.backup(to: backups.appendingPathComponent("lumen-2026-11-20T09-00-00Z.db").path)
        // The next launch paid it; editing went on and reached the sidecar.
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, nil)
        store.close()

        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: catalogPath))
        try handle.seek(toOffset: 16_384)
        handle.write(Data(repeating: 0x5A, count: 16_384))
        try handle.close()
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: catalogPath))

        let recovery = CatalogStore.recoverIfNeeded(path: catalogPath,
                                                    backupDirectory: backups.path)
        guard case .restored = recovery.outcome else {
            return XCTFail("not restored: \(recovery.outcome)")
        }
        let restored = try makeStore()
        XCTAssertEqual(UnsavedSidecarRecord.decode(
            try restored.metaValue(UnsavedSidecarRecord.metaKey)), [],
            "the restored catalog would rewrite sidecars from backup-era state")
        XCTAssertEqual(try restored.currentRecipe(photoID: photo.id), recipe)
        restored.close()

        let backup = try SQLiteDatabase(
            path: backups.appendingPathComponent("lumen-2026-11-20T09-00-00Z.db").path,
            readOnly: true)
        XCTAssertNotNil(try backup.scalarText("SELECT value FROM meta WHERE key = ?;",
                                              [.text(UnsavedSidecarRecord.metaKey)]),
                        "the backup itself must be left as it was")
        backup.close()
    }
}

#endif
