// CatalogUnicodeNameTests.swift
//
// scan() keys rows in Swift collections, which compare strings by canonical
// equivalence; every SQL lookup compares bytes. A folder listed in the other Unicode
// normalization (NFC vs NFD, e.g. a tree copied by a tool that normalizes) matched
// its row in scan() but could not be found by photo(folderID:filename:), so the
// photo opened with no catalog link and its edits were neither loaded nor saved.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogUnicodeNameTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAListingInTheOtherNormalizationStillFindsItsRow() throws {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/x")
        let nfc = "Caf\u{E9}/DSC0001.ARW"
        let nfd = "Cafe\u{301}/DSC0001.ARW"
        XCTAssertEqual(nfc, nfd)
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))

        _ = try store.scan(folderID: folderID,
                           files: [ScannedFile(filename: nfc, fileSize: 100, fileMTime: 1)])
        let id = try XCTUnwrap(store.photo(folderID: folderID, filename: nfc)).id
        try store.setRating(4, photoID: id)

        let second = try store.scan(folderID: folderID,
                                    files: [ScannedFile(filename: nfd, fileSize: 100, fileMTime: 1)])
        XCTAssertEqual(second.unchanged, 1)
        XCTAssertTrue(second.added.isEmpty)
        XCTAssertTrue(second.missing.isEmpty)
        let row = try XCTUnwrap(store.photo(folderID: folderID, filename: nfd),
                                "the listed spelling must find the row")
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.rating, 4)
        XCTAssertEqual(try store.photos(folderID: folderID).count, 1)
    }
}

#endif
