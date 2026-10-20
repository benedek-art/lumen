// CatalogCacheOrphanTests.swift
//
// photo.id has no AUTOINCREMENT, so a restored (or fresh) lumen.db opened beside an
// existing cache.db reuses ids the cache still describes. Those rows must not be
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

    func testANewCatalogBesideAnOldCacheDoesNotInheritAnotherFramesRows() throws {
        let cache = directory.appendingPathComponent("cache.db").path
        let old = try CatalogStore(path: directory.appendingPathComponent("old.db").path,
                                   cachePath: cache)
        let oldFolder = try old.registerFolder(path: "/Volumes/Shoots/A")
        _ = try old.scan(folderID: oldFolder, files: [file("LATE.ARW", 41_000_000)],
                         at: CatalogStore.now())
        let late = try XCTUnwrap(old.photo(folderID: oldFolder, filename: "LATE.ARW")).id
        try old.recordFrameScore(FrameScoreRow(photoID: late, sharpness: 0.97, noise: 0.01,
                                               perceptualHash: 0xDEAD, analysedLongEdge: 1024))
        XCTAssertNotNil(try old.frameScore(photoID: late))
        old.close()

        // The catalog the cache belonged to is gone; a different one opens beside it.
        let fresh = try CatalogStore(path: directory.appendingPathComponent("new.db").path,
                                     cachePath: cache)
        let folder = try fresh.registerFolder(path: "/Volumes/Shoots/B")
        _ = try fresh.scan(folderID: folder, files: [file("OTHER.ARW", 42_000_000)],
                           at: CatalogStore.now())
        let other = try XCTUnwrap(fresh.photo(folderID: folder, filename: "OTHER.ARW")).id
        XCTAssertEqual(other, late, "precondition: the id is reused")
        XCTAssertNil(try fresh.frameScore(photoID: other), "another frame's score was inherited")
        XCTAssertTrue(try fresh.photosMissingFrameScore(folderID: folder).contains(other),
                      "the new frame must be queued for measurement")
    }
}

#endif
