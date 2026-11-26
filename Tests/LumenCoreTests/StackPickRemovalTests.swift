// StackPickRemovalTests.swift
// A collapsed stack shows only its pick. Removing the pick from the catalog (the reject
// sweep: reject the frame the collapsed stack shows, then ⌘⌫) set `pick_photo_id` to
// NULL, and `collapsedTopsOnly` then matched none of the survivors: every other frame of
// the burst left the grid, with nothing on screen to bring it back.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class StackPickRemovalTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-stackpick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func collapsedTops(_ store: CatalogStore, _ folderID: Int64) throws -> [Int64] {
        var filter = LibraryFilter()
        filter.stackState = .collapsedTops
        let query = filter.query(sortKey: .filename, ascending: true, albumID: nil)
        return try store.photoOrder(matching: query, folderID: folderID).map(\.id)
    }

    func testRemovingACollapsedStacksPickKeepsTheRestOfTheStackVisible() throws {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        defer { store.close() }
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/burst")
        let names = ["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW", "DSC0004.ARW"]
        _ = try store.scan(folderID: folderID, files: names.enumerated().map {
            ScannedFile(filename: $0.element, fileSize: Int64(100 + $0.offset), fileMTime: 1,
                        ext: "arw")
        })
        let ids = try names.map { try XCTUnwrap(store.photo(folderID: folderID, filename: $0)).id }
        let stack = try store.createStack(origin: "burst-auto", photoIDs: Array(ids[0...2]))
        XCTAssertEqual(try collapsedTops(store, folderID), [ids[0], ids[3]])

        try store.deletePhoto(id: ids[0])

        XCTAssertEqual(try collapsedTops(store, folderID), [ids[1], ids[3]],
                       "the burst's two remaining frames vanished from the collapsed grid")
        XCTAssertEqual(try store.stack(containing: ids[1])?.id, stack)
        XCTAssertEqual(try store.stack(containing: ids[1])?.pickPhotoID, ids[1])

        // Removing a frame that is not the pick leaves the pick alone.
        try store.deletePhoto(id: ids[2])
        XCTAssertEqual(try store.stack(containing: ids[1])?.pickPhotoID, ids[1])
        XCTAssertEqual(try collapsedTops(store, folderID), [ids[1], ids[3]])

        try store.deletePhoto(id: ids[1])
        XCTAssertEqual(try store.stackMembers(stackID: stack), [])
        XCTAssertEqual(try collapsedTops(store, folderID), [ids[3]])
    }
}

#endif
