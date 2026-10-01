// SmartAlbumTests.swift
// A smart album is a saved filter-bar state (docs/10 §10.8, D39). `album.kind` and
// `album.query` have been in the schema since the base DDL with nothing writing them.

import XCTest
@testable import LumenCore

final class SavedLibraryFilterTests: XCTestCase {

    /// Every criterion lit, each to a non-default value.
    private func everything() -> LibraryFilter {
        var f = LibraryFilter()
        f.flags = [.pick, .reject]
        f.minRating = 3
        f.labels = [.red, .purple]
        f.includeUnlabeled = true
        f.text = "harbour \"quoted\" / slash"
        f.rawOnly = true
        f.edited = false
        f.cameras = ["ILCE-7M4", "X-T5"]
        f.lenses = ["FE 35mm F1.4 GM"]
        f.isoBands = [.upTo400, .above6400]
        f.stackState = .collapsedTops
        f.keywords = ["dawn", "Iceland"]
        f.matchAny = true
        return f
    }

    func testEveryCriterionSurvivesTheRoundTrip() throws {
        let saved = everything().savedJSON()
        XCTAssertEqual(LibraryFilter(savedJSON: saved), everything(), saved)
        XCTAssertEqual(LibraryFilter(savedJSON: LibraryFilter().savedJSON()), LibraryFilter())
        var edited = LibraryFilter()
        edited.edited = true
        XCTAssertEqual(LibraryFilter(savedJSON: edited.savedJSON())?.edited, true)
    }

    /// The codec names its fields by hand. A criterion added to `LibraryFilter` without
    /// a line here would save as "off" and come back off — a smart album that quietly
    /// shows more than it was saved to show. This fails the day the field list moves.
    func testTheCodecCoversEveryStoredField() {
        let fields = Mirror(reflecting: LibraryFilter()).children.compactMap(\.label).sorted()
        XCTAssertEqual(fields, ["cameras", "edited", "flags", "includeUnlabeled",
                                "isoBands", "keywords", "labels", "lenses", "matchAny",
                                "minRating", "rawOnly", "stackState", "text"],
                       "LibraryFilter gained or lost a field: teach savedJSON and "
                       + "init(savedJSON:) about it, then update this list")
    }

    /// Sets have no order, so the same filter must not save as different bytes run to
    /// run — a smart album "changed" by being re-saved unchanged.
    func testTheSameFilterAlwaysSavesTheSameBytes() {
        let a = everything().savedJSON()
        for _ in 0..<20 { XCTAssertEqual(everything().savedJSON(), a) }
        XCTAssertTrue(a.hasPrefix("{\"any\":true,"), "keys are not sorted: \(a)")
    }

    func testANewerOrDamagedDocumentIsRefusedWhole() {
        XCTAssertNil(LibraryFilter(savedJSON: "{\"v\":2,\"minRating\":3}"),
                     "a newer format was half-read")
        XCTAssertNil(LibraryFilter(savedJSON: "{\"v\":1,\"labels\":[\"teal\"]}"),
                     "an unknown label was dropped instead of refusing the album")
        XCTAssertNil(LibraryFilter(savedJSON: "{\"v\":1,\"flags\":[7]}"))
        XCTAssertNil(LibraryFilter(savedJSON: "not json"))
        XCTAssertEqual(LibraryFilter(savedJSON: "{\"v\":1,\"minRating\":99}")?.minRating, 5)
    }
}

#if canImport(SQLite3)

final class SmartAlbumCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-smart-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Saved, reopened, and run: the stored album answers with exactly the rows the
    /// live filter does.
    func testASmartAlbumReturnsWhatItsFilterReturns() throws {
        let path = directory.appendingPathComponent("lumen.db").path
        let cache = directory.appendingPathComponent("cache.db").path
        var store = try CatalogStore(path: path, cachePath: cache)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-10-01")
        let files = (0..<6).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(20_000_000 + $0), fileMTime: 1_700_000_000, ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try files.compactMap { try store.photo(folderID: folderID, filename: $0.filename)?.id }
        try store.setFlag(.pick, photoIDs: [ids[0], ids[3]])
        try store.setRating(4, photoIDs: [ids[1], ids[3]])

        var live = LibraryFilter()
        live.flags = [.pick]
        live.minRating = 4
        live.matchAny = true
        let albumID = try store.createCollection(name: "Picks or 4+",
                                                 kind: CollectionRow.smartKind,
                                                 query: live.savedJSON())
        store.close()

        store = try CatalogStore(path: path, cachePath: cache)
        defer { store.close() }
        let row = try XCTUnwrap(store.collection(id: albumID))
        XCTAssertEqual(row.kind, "smart")
        let saved = try XCTUnwrap(LibraryFilter(savedJSON: try XCTUnwrap(row.query)))
        let fromAlbum = try store.photos(
            matching: saved.query(sortKey: .filename, ascending: true, albumID: nil),
            folderID: folderID).map(\.id)
        XCTAssertEqual(fromAlbum, [ids[0], ids[1], ids[3]])

        // Updating the query is how "save the bar over this album" works; a manual
        // album has no query to update.
        var narrower = live
        narrower.matchAny = false
        try store.updateCollectionQuery(id: albumID, query: narrower.savedJSON())
        let updated = try XCTUnwrap(LibraryFilter(savedJSON:
            try XCTUnwrap(store.collection(id: albumID)?.query)))
        XCTAssertEqual(try store.photos(
            matching: updated.query(sortKey: .filename, ascending: true, albumID: nil),
            folderID: folderID).map(\.id), [ids[3]])
        let manual = try store.createCollection(name: "Tray")
        XCTAssertThrowsError(try store.updateCollectionQuery(id: manual, query: "{}"))

        // And a smart album is never where `B` writes.
        XCTAssertThrowsError(try store.setTargetCollection(albumID))
        try store.setTargetCollection(manual)
        XCTAssertThrowsError(try store.setTargetCollection(albumID))
        XCTAssertEqual(try store.targetCollectionID(), manual,
                       "a refused smart target displaced the real one")
    }
}

#endif
