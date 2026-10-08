import XCTest
@testable import LumenCore

#if canImport(SQLite3)
final class SmartAlbumScopeTests: XCTestCase {
    private func fixture(_ body: (CatalogStore, URL, [Int64], [Int64]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-scope-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        // Photos can be registered either under a nested folder or with a relative
        // path in an ancestor scan. Siblings and wildcard-looking names are distinct.
        let paths = ["shoot", "shoot/day_1%", "shoot/day_1%/child", "shoot/dayX1other", "elsewhere"]
        let folders = try paths.map { try store.registerFolder(path: root.appendingPathComponent($0).path) }
        let names = [["top.JPG", "day_1%/nested.JPG", "dayX1other/out.JPG"], ["day.JPG"], ["child.JPG"], ["sibling.JPG"], ["other.JPG"]]
        var ids: [Int64] = []
        for (folder, filenames) in zip(folders, names) {
            _ = try store.scan(folderID: folder, files: filenames.map { ScannedFile(filename: $0, fileSize: 10, fileMTime: 10, ext: "jpg") }, at: 20)
            ids += try filenames.map { try XCTUnwrap(store.photo(folderID: folder, filename: $0)?.id) }
        }
        for id in ids { try store.setRating(4, photoID: id) }
        try store.setMetadata(PhotoMetadata(camera: "Inside"), photoID: ids[1])
        try store.setMetadata(PhotoMetadata(camera: "Outside"), photoID: ids.last!)
        try body(store, root, folders, ids)
    }

    func testAllSourceScopesShareRowsOrderCountsAndFacetDomains() throws {
        try fixture { store, _, folders, ids in
            var query = PhotoQuery(); query.sortKey = .filename
            query.sourceScope = .folderSubtree(folders[1])
            let expected = Set([ids[1], ids[3], ids[4]])
            XCTAssertEqual(Set(try store.photos(matching: query).map(\.id)), expected)
            XCTAssertEqual(Set(try store.photoOrder(matching: query).map(\.id)), expected)
            XCTAssertEqual(try store.countPhotos(matching: query), expected.count)
            XCTAssertEqual(try store.facetCounts(for: query).cameras.map(\.value), ["Inside"])
            query.sourceScope = .everywhere
            XCTAssertEqual(try store.countPhotos(matching: query, folderID: folders[1]), ids.count)
            query.sourceScope = .currentFolder
            XCTAssertEqual(try store.countPhotos(matching: query, folderID: folders[1]), 1)
            XCTAssertThrowsError(try store.countPhotos(matching: query))
            query.sourceScope = nil
            XCTAssertEqual(try store.countPhotos(matching: query), ids.count, "ordinary catalog-wide queries stay compatible")
        }
    }

    func testManualAlbumScopeAlwaysAndsWithMatchAnyAndSurvivesReopenOffline() throws {
        try fixture { store, root, folders, ids in
            let manual = try store.createCollection(name: "Manual")
            try store.addToCollection(manual, photoIDs: [ids.last!, ids[1]])
            let smart = try store.createCollection(name: "Scoped", kind: CollectionRow.smartKind, query: LibraryFilter().savedJSON(), scope: "album", scopeID: manual)
            try store.setFolderOnline(false, folderID: folders.last!)
            try store.setMissing(true, photoID: ids.last!)
            store.close()
            let reopened = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
            defer { reopened.close() }
            let row = try XCTUnwrap(reopened.collection(id: smart))
            var query = PhotoQuery(); query.sourceScope = try CollectionQueryScope(stored: row.scope, id: row.scopeID)
            query.matchAny = true; query.rating = 4; query.flags = [.pick]
            XCTAssertEqual(Set(try reopened.photoOrder(matching: query).map(\.id)), Set([ids[1], ids.last!]))
            query.sortKey = .userOrder
            XCTAssertEqual(try reopened.photoOrder(matching: query).map(\.id), [ids.last!, ids[1]])
            XCTAssertEqual(try reopened.photos(matching: query).map(\.id), [ids.last!, ids[1]])
            query.includeMissing = false
            XCTAssertEqual(try reopened.countPhotos(matching: query), 1)
            XCTAssertEqual(try reopened.facetCounts(for: query).cameras.map(\.value), ["Inside"])
        }
    }

    func testLegacyNullUnknownDeletedAndRecursiveScopesNeverWiden() throws {
        XCTAssertEqual(try CollectionQueryScope(stored: nil, id: nil), .currentFolder)
        for (name, id) in [("future", nil), ("album", nil), ("everywhere", Int64(3)), (nil, Int64(3))] {
            XCTAssertThrowsError(try CollectionQueryScope(stored: name, id: id))
        }
        try fixture { store, _, folders, _ in
            let smart = try store.createCollection(name: "Legacy", kind: CollectionRow.smartKind, query: LibraryFilter().savedJSON())
            let row = try XCTUnwrap(store.collection(id: smart))
            var query = PhotoQuery(); query.sourceScope = try CollectionQueryScope(stored: row.scope, id: row.scopeID)
            XCTAssertEqual(try store.countPhotos(matching: query, folderID: folders[1]), 1)
            for scope in [CollectionQueryScope.album(smart), .album(99_999), .folderSubtree(99_999)] {
                query.sourceScope = scope
                XCTAssertThrowsError(try store.photos(matching: query))
                XCTAssertThrowsError(try store.countPhotos(matching: query))
                XCTAssertThrowsError(try store.facetCounts(for: query))
                XCTAssertThrowsError(try store.updateCollectionScope(id: smart, scope: scope))
            }
            let emptyFolder = try store.registerFolder(path: "/missing-empty-scope")
            try store.updateCollectionScope(id: smart, scope: .folderSubtree(emptyFolder))
            try store.debugExecute("DELETE FROM folder WHERE id = \(emptyFolder);")
            query.sourceScope = .folderSubtree(emptyFolder)
            XCTAssertThrowsError(try store.photoOrder(matching: query))
        }
    }
}
#endif
