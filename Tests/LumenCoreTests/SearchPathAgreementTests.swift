// SearchPathAgreementTests.swift
//
// The search box has three evaluators: the FTS index, the LIKE fallback, and the
// in-memory filter. They disagreed on two common inputs: a frame number ("0003",
// which unicode61 buries inside the token `dsc0003`) and text with stray spaces.

import XCTest
@testable import LumenCore

final class SearchPathAgreementTests: XCTestCase {

    private struct Photo: LibraryFilterable {
        var flag: PhotoFlag = .unflagged
        var rating = 0
        var label: ColorLabel? = nil
        var isRaw = true
        var filename: String
    }

    func testTheMemoryPathTrimsTextLikeTheCatalogPath() {
        var filter = LibraryFilter()
        filter.text = "  beach  "
        XCTAssertTrue(filter.matches(Photo(filename: "beach-042.arw")))
        filter.text = " "
        XCTAssertNil(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).text)
        XCTAssertTrue(filter.matches(Photo(filename: "DSC_0001.jpg")),
                      "whitespace is no search, on both paths")
        filter.matchAny = true
        filter.minRating = 5
        filter.text = " beach "
        XCTAssertTrue(filter.matches(Photo(filename: "beach-042.arw")))
    }

    #if canImport(SQLite3)
    func testAFrameNumberIsFoundOnTheIndexedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        try XCTSkipUnless(store.isTextIndexAvailable, "needs FTS5")
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/x")
        let files = (0..<5).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0), fileSize: Int64(100 + $0),
                        fileMTime: 1)
        }
        _ = try store.scan(folderID: folderID, files: files)
        let three = try XCTUnwrap(store.photo(folderID: folderID, filename: "DSC0003.ARW")).id
        var query = PhotoQuery()
        query.text = "0003"
        XCTAssertEqual(try store.photos(matching: query, folderID: folderID).map(\.id), [three])
        query.text = "DSC0003"
        XCTAssertEqual(try store.photos(matching: query, folderID: folderID).map(\.id), [three])
    }
    #endif
}
