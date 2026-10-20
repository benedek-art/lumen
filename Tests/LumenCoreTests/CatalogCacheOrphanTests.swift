// CatalogCacheOrphanTests.swift
//
// photo.id has no AUTOINCREMENT, so a lumen.db restored from backup, opened beside
// the existing cache.db, reuses ids the cache still describes. Those rows must not be
// inherited by a different frame.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogCacheOrphanTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String, _ size: Int64) -> ScannedFile {
        ScannedFile(filename: name, fileSize: size, fileMTime: 1_700_000_000, ext: "arw")
    }

    func testARestoredCatalogDoesNotLetANewPhotoInheritAnotherFramesRows() throws {
        let main = directory.appendingPathComponent("lumen.db")
        let cache = directory.appendingPathComponent("cache.db").path
        let backup = directory.appendingPathComponent("backup.db")
        let store = try CatalogStore(path: main.path, cachePath: cache)
        let folder = try store.registerFolder(path: "/Volumes/Shoots/A")
        _ = try store.scan(folderID: folder, files: [file("EARLY.ARW", 40_000_000)],
                           at: CatalogStore.now())
        try store.backup(to: backup.path)
        _ = try store.scan(folderID: folder, files: [file("EARLY.ARW", 40_000_000),
                                                     file("LATE.ARW", 41_000_000)],
                           at: CatalogStore.now())
        let late = try XCTUnwrap(store.photo(folderID: folder, filename: "LATE.ARW")).id
        try store.recordFrameScore(FrameScoreRow(photoID: late, sharpness: 0.97, noise: 0.01,
                                                 perceptualHash: 0xDEAD, analysedLongEdge: 1024))
        store.close()

        // What `recoverIfNeeded` does: the backup replaces lumen.db, cache.db stays.
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: main.path + suffix) }
        try fm.copyItem(at: backup, to: main)

        let restored = try CatalogStore(path: main.path, cachePath: cache)
        _ = try restored.scan(folderID: folder, files: [file("EARLY.ARW", 40_000_000),
                                                        file("OTHER.ARW", 42_000_000)],
                              at: CatalogStore.now())
        let other = try XCTUnwrap(restored.photo(folderID: folder, filename: "OTHER.ARW")).id
        XCTAssertEqual(other, late, "precondition: the id is reused")
        XCTAssertNil(try restored.frameScore(photoID: other), "another frame's score was inherited")
        XCTAssertTrue(try restored.photosMissingFrameScore(folderID: folder).contains(other),
                      "the new frame must be queued for measurement")
    }
}

#endif
