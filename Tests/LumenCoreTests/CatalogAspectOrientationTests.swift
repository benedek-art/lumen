// CatalogAspectOrientationTests.swift
//
// photo.aspect drives the aspect-ratio sort. It was width ÷ height of the STORED
// sensor extent, so a camera-rotated vertical frame (orientation 6 or 8) sorted with
// the landscapes.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogAspectOrientationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    private func seed(_ store: CatalogStore) throws -> [Int64] {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/x")
        let files = (0..<4).map {
            ScannedFile(filename: "DSC\($0).ARW", fileSize: Int64(100 + $0), fileMTime: 1)
        }
        _ = try store.scan(folderID: folderID, files: files)
        return try files.map { try XCTUnwrap(store.photo(folderID: folderID, filename: $0.filename)).id }
    }

    func testAspectHonoursAQuarterTurningOrientation() throws {
        let store = try makeStore()
        let ids = try seed(store)
        for (id, orientation) in zip(ids, [nil, 6, 8, 3] as [Int?]) {
            try store.setMetadata(PhotoMetadata(width: 6000, height: 4000, orientation: orientation),
                                  photoID: id)
        }
        let aspects = try ids.map { try XCTUnwrap(store.photo(id: $0)?.aspect) }
        XCTAssertEqual(aspects[0], 1.5, accuracy: 1e-9)
        XCTAssertEqual(aspects[1], 4000.0 / 6000.0, accuracy: 1e-9)
        XCTAssertEqual(aspects[2], 4000.0 / 6000.0, accuracy: 1e-9)
        XCTAssertEqual(aspects[3], 1.5, accuracy: 1e-9, "a half turn keeps the ratio")
    }

    func testRowsWrittenBeforeTheFixAreRepairedOnOpen() throws {
        let store = try makeStore()
        let ids = try seed(store)
        try store.setMetadata(PhotoMetadata(width: 6000, height: 4000, orientation: 6), photoID: ids[0])
        try store.setMetadata(PhotoMetadata(width: 4000, height: 4000, orientation: 6), photoID: ids[1])
        // What an older build stored.
        try store.debugExecute("UPDATE photo SET aspect = 1.5 WHERE id = \(ids[0]);")
        store.close()
        for _ in 0..<2 {
            let reopened = try makeStore()
            XCTAssertEqual(try XCTUnwrap(reopened.photo(id: ids[0])?.aspect), 4000.0 / 6000.0,
                           accuracy: 1e-9, "repaired once, and not turned back on the next open")
            XCTAssertEqual(try XCTUnwrap(reopened.photo(id: ids[1])?.aspect), 1, accuracy: 1e-9)
            reopened.close()
        }
    }
}

#endif
