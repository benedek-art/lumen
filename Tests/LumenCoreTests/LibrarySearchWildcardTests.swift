// LibrarySearchWildcardTests.swift
// The search field is literal text. `_` and `%` are SQL LIKE wildcards, and camera file
// names are full of underscores: Canon writes `_MG_` for Adobe RGB frames beside `IMG_`
// for sRGB, and "_MG_" matched every `IMG_` frame too. The memory path
// (`LibraryFilter.matches`) never did, so the two paths disagreed about the same filter.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class LibrarySearchWildcardTests: XCTestCase {

    private struct Item: LibraryFilterable {
        var flag: PhotoFlag = .unflagged
        var rating = 0
        var label: ColorLabel? = nil
        var isRaw = true
        var filename: String
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-search-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let names = ["IMG_1234.CR2", "_MG_1235.CR2", "IMGX1236.CR2", "50%_crop.jpg",
                         "500_crop.jpg", "back\\slash.jpg", "backXslash.jpg"]

    private func seeded() throws -> (CatalogStore, Int64, [String: Int64]) {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/canon")
        let files = names.enumerated().map {
            ScannedFile(filename: $0.element, fileSize: Int64(1_000 + $0.offset), fileMTime: 1,
                        ext: URL(fileURLWithPath: $0.element).pathExtension.lowercased())
        }
        _ = try store.scan(folderID: folderID, files: files)
        var ids: [String: Int64] = [:]
        for name in names {
            ids[name] = try XCTUnwrap(store.photo(folderID: folderID, filename: name)).id
        }
        return (store, folderID, ids)
    }

    private func found(_ store: CatalogStore, _ folderID: Int64, _ text: String,
                       _ ids: [String: Int64]) throws -> Set<String> {
        var filter = LibraryFilter()
        filter.text = text
        let query = filter.query(sortKey: .filename, ascending: true, albumID: nil)
        let hits = Set(try store.photoOrder(matching: query, folderID: folderID).map(\.id))
        XCTAssertEqual(try store.countPhotos(matching: query, folderID: folderID), hits.count)
        return Set(ids.filter { hits.contains($0.value) }.keys)
    }

    private func inMemory(_ text: String) -> Set<String> {
        var filter = LibraryFilter()
        filter.text = text
        return Set(names.filter { filter.matches(Item(filename: $0)) })
    }

    private func assertLiteral(_ store: CatalogStore, _ folderID: Int64,
                               _ ids: [String: Int64], lane: String) throws {
        XCTAssertEqual(try found(store, folderID, "_MG_", ids), ["_MG_1235.CR2"],
                       "\(lane): `_` matched any character, so _MG_ found every IMG_ frame")
        XCTAssertEqual(try found(store, folderID, "IMG_", ids), ["IMG_1234.CR2"],
                       "\(lane): IMG_ found IMGX")
        XCTAssertEqual(try found(store, folderID, "50%", ids), ["50%_crop.jpg"],
                       "\(lane): `%` matched any run of characters")
        XCTAssertEqual(try found(store, folderID, "back\\", ids), ["back\\slash.jpg"],
                       "\(lane): the escape character itself must stay literal")
        for text in ["_MG_", "IMG_", "50%", "back\\"] {
            XCTAssertEqual(try found(store, folderID, text, ids), inMemory(text),
                           "\(lane): the catalog and memory paths disagree about \(text)")
        }
    }

    /// The index matches word prefixes by design ("IMG_" is the word "img"), so only
    /// the filename substring OR-ed beside it is held to literal here.
    func testSearchTextIsLiteralThroughTheTextIndex() throws {
        let (store, folderID, ids) = try seeded()
        defer { store.close() }
        try XCTSkipUnless(store.isTextIndexAvailable, "no FTS5 in this SQLite")
        XCTAssertEqual(try found(store, folderID, "_MG_", ids), ["_MG_1235.CR2"],
                       "`_` matched any character, so _MG_ found every IMG_ frame")
    }

    func testSearchTextIsLiteralThroughTheLikeFallback() throws {
        let (store, folderID, ids) = try seeded()
        defer { store.close() }
        if store.isTextIndexAvailable {
            // Unwritable index: the next reindex switches this session to LIKE.
            try store.debugExecute("ALTER TABLE cache.photo_fts RENAME TO photo_fts_off;")
            try store.addKeyword("canon", photoIDs: [ids["IMG_1234.CR2"]!])
            XCTAssertFalse(store.isTextIndexAvailable)
        }
        try assertLiteral(store, folderID, ids, lane: "LIKE fallback")
    }
}

#endif
