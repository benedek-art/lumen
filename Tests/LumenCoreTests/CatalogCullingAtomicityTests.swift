#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class CatalogCullingAtomicityTests: XCTestCase {
    func testCullingFieldFailureRollsBackTheWholeGesture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-culling-atomic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("lumen.db").path
        let store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: root.path)
        _ = try store.scan(folderID: folderID, files: [
            ScannedFile(filename: "frame.ARW", fileSize: 1234, fileMTime: 1_700_000_000, ext: "arw")
        ])
        let id = try XCTUnwrap(store.photo(folderID: folderID, filename: "frame.ARW")).id
        try store.setCullingState(flag: .reject, rating: 2, label: .red, photoID: id)
        for field in ["rating", "label"] {
            try store.debugExecute("CREATE TRIGGER reject_culling BEFORE UPDATE OF \(field) ON photo BEGIN SELECT RAISE(ABORT, 'injected culling refusal'); END;")
            XCTAssertThrowsError(try store.setCullingState(flag: .pick, rating: 5, label: .green, photoID: id))
            let row = try XCTUnwrap(store.photo(id: id))
            XCTAssertEqual(row.flag, .reject)
            XCTAssertEqual(row.rating, 2)
            XCTAssertEqual(row.label, "red")
            try store.debugExecute("DROP TRIGGER reject_culling;")
        }
        // Successful clearing and clamping remain durable after the fault is removed.
        try store.setCullingState(flag: .unflagged, rating: 99, label: nil, photoID: id)
        store.close()
        let reopened = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        defer { reopened.close() }
        let row = try XCTUnwrap(reopened.photo(id: id))
        XCTAssertEqual(row.flag, .unflagged)
        XCTAssertEqual(row.rating, 5)
        XCTAssertNil(row.label)
    }
}
#endif
