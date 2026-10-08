// AlbumLifecycleTests.swift
// An album can be renamed and deleted, and deleting one never costs a photograph.
//
// Against a real SQLite file: the point of `deleteCollection` is what the foreign keys
// and the other rows referencing an album do when it goes, and only the engine can say.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class AlbumLifecycleTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-albums-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    private func seed(_ store: CatalogStore, count: Int) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-09-30")
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "IMG_%04d.CR3", $0),
                        fileSize: Int64(30_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "cr3")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try files.compactMap {
            try store.photo(folderID: folderID, filename: $0.filename)?.id
        }
        return (folderID, ids)
    }

    func testRenamingAnAlbumKeepsItsMembershipAndRefusesAnEmptyName() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store, count: 3)
        let album = try store.createCollection(name: "Slects")
        try store.addToCollection(album, photoIDs: [ids[0], ids[2]])

        XCTAssertTrue(try store.renameCollection(id: album, to: "  Selects \n"))
        XCTAssertEqual(try store.collection(id: album)?.name, "Selects",
                       "the rename did not land, or kept the whitespace it was typed with")
        var query = PhotoQuery()
        query.albumID = album
        XCTAssertEqual(try store.countPhotos(matching: query), 2,
                       "renaming an album changed what is in it")

        XCTAssertFalse(try store.renameCollection(id: album, to: "   "))
        XCTAssertEqual(try store.collection(id: album)?.name, "Selects",
                       "a blank name was written over a real one")
        XCTAssertThrowsError(try store.renameCollection(id: 9_999, to: "Ghost"))
        store.close()
    }

    /// The deletion the sidebar offers. Under `foreign_keys=ON` the album row cannot
    /// go while `album_photo` still references it, so a delete that forgot the
    /// membership rows throws and leaves the album on screen forever.
    func testDeletingAnAlbumKeepsEveryPhotographAndEveryOtherAlbum() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 4)
        let doomed = try store.createCollection(name: "Maybe")
        let kept = try store.createCollection(name: "Portfolio")
        try store.setTargetCollection(doomed)
        try store.addToCollection(doomed, photoIDs: ids)
        try store.addToCollection(kept, photoIDs: [ids[1]])

        try store.deleteCollection(id: doomed)

        XCTAssertNil(try store.collection(id: doomed), "the album is still there")
        XCTAssertEqual(try store.collections().map(\.id), [kept])
        XCTAssertEqual(try store.photos(folderID: folderID).count, 4,
                       "deleting an album deleted photographs")
        var inKept = PhotoQuery()
        inKept.albumID = kept
        XCTAssertEqual(try store.photos(matching: inKept, folderID: folderID).map(\.id),
                       [ids[1]], "deleting one album touched another's membership")
        XCTAssertNil(try store.targetCollectionID(),
                     "the deleted album is still the target, so B writes into nothing")

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("lumen.db").path)
        defer { raw.close() }
        XCTAssertEqual(try raw.scalarInt("SELECT COUNT(*) FROM album_photo WHERE album_id = ?;",
                                         [.integer(doomed)]), 0,
                       "membership rows outlived their album")
        XCTAssertThrowsError(try store.deleteCollection(id: doomed),
                             "deleting an album twice reported success")
        store.close()
    }

    /// Sets nest one level: the children of a deleted set move up, and a smart album
    /// scoped to the deleted album keeps its reference and refuses to widen.
    func testDeletingASetReparentsItsChildrenAndPreservesUnavailableScopes() throws {
        let store = try makeStore()
        let set = try store.createCollection(name: "2026")
        let child = try store.createCollection(name: "Iceland", parentID: set)
        let smart = try store.createCollection(name: "Iceland picks", kind: "smart",
                                               query: "{}", scope: "album", scopeID: set)
        let elsewhere = try store.createCollection(name: "Other picks", kind: "smart",
                                                   query: "{}", scope: "folder",
                                                   scopeID: set)

        try store.deleteCollection(id: set)

        XCTAssertEqual(try store.collection(id: child)?.parentID, nil,
                       "a child album was orphaned under a parent that no longer exists")
        let scoped = try store.collection(id: smart)
        XCTAssertEqual(scoped?.scope, "album")
        XCTAssertEqual(scoped?.scopeID, set)
        var query = PhotoQuery(); query.sourceScope = .album(set)
        XCTAssertThrowsError(try store.countPhotos(matching: query))
        // A FOLDER scope that happens to carry the same number is not this album.
        XCTAssertEqual(try store.collection(id: elsewhere)?.scope, "folder")
        XCTAssertEqual(try store.collection(id: elsewhere)?.scopeID, set)
        store.close()
    }
}

#endif
