// UnsavedSidecarRecordTests.swift
// REL-09, the quit half: the record of sidecars the last quit could not write.

import XCTest
@testable import LumenCore

final class UnsavedSidecarRecordTests: XCTestCase {

    func testRecordSurvivesTheCatalogClosingAndReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-unsaved-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("catalog.db").path
        let cache = root.appendingPathComponent("cache.db").path
        let owed = [
            UnsavedSidecarRecord(photoPath: "/Volumes/Card/b.NEF", photoID: 2, stated: [.rating]),
            UnsavedSidecarRecord(photoPath: "/Volumes/Card/a.NEF", photoID: 1, stated: [.recipe, .strokes]),
        ]
        let store = try CatalogStore(path: db, cachePath: cache)
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode(owed))
        store.close()

        let reopened = try CatalogStore(path: db, cachePath: cache)
        defer { reopened.close() }
        let read = UnsavedSidecarRecord.decode(try reopened.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(read.map(\.photoPath).sorted(), ["/Volumes/Card/a.NEF", "/Volumes/Card/b.NEF"])
        XCTAssertEqual(read.first { $0.photoID == 1 }?.statedFields, [.recipe, .strokes])
        XCTAssertEqual(read.first { $0.photoID == 2 }?.statedFields, [.rating])

        // Settling every debt clears the key rather than leaving "[]" behind.
        try reopened.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([]))
        XCTAssertNil(try reopened.metaValue(UnsavedSidecarRecord.metaKey))
    }

    func testMergeOwesEveryFieldEitherWriteOwed() {
        let a = UnsavedSidecarRecord(photoPath: "/p/a.NEF", photoID: nil, stated: [.rating])
        let b = UnsavedSidecarRecord(photoPath: "/p/a.NEF", photoID: 7, stated: [.recipe])
        let merged = a.merged(with: b)
        XCTAssertEqual(merged.statedFields, [.rating, .recipe])
        XCTAssertEqual(merged.photoID, 7)
    }

    func testUnreadableValueDecodesToNothing() {
        XCTAssertEqual(UnsavedSidecarRecord.decode(nil), [])
        XCTAssertEqual(UnsavedSidecarRecord.decode("not json"), [])
    }

    func testNoticeNamesThePhotos() throws {
        XCTAssertNil(UnsavedSidecarRecord.notice(for: []))
        let notice = try XCTUnwrap(UnsavedSidecarRecord.notice(for: [
            UnsavedSidecarRecord(photoPath: "/Volumes/Card/DSC_0001.NEF", photoID: 1, stated: [.rating])]))
        XCTAssertTrue(notice.contains("DSC_0001.NEF"))
        let many = (1...7).map {
            UnsavedSidecarRecord(photoPath: "/p/f\($0).NEF", photoID: Int64($0), stated: [.flag])
        }
        XCTAssertTrue(try XCTUnwrap(UnsavedSidecarRecord.notice(for: many)).contains("and 2 more"))
    }
    func testKeywordDeltasSurviveCodecAndComposeInTimeOrder() throws {
        let a = UnsavedSidecarRecord(photoPath: "/p/a.JPG", photoID: 1, stated: [.keywords],
            keywordEdit: SidecarKeywordEdit(added: ["A"], removed: ["B"]))
        let b = UnsavedSidecarRecord(photoPath: "/p/a.JPG", photoID: 1, stated: [.keywords],
            keywordEdit: SidecarKeywordEdit(added: ["B"], removed: ["A"]))
        let decoded = try XCTUnwrap(UnsavedSidecarRecord.decode(UnsavedSidecarRecord.encode([a.merged(with: b)])).first)
        XCTAssertEqual(decoded.keywordEdit?.apply(to: ["A", "Other"]), ["Other", "B"])
        let legacy = UnsavedSidecarRecord.decode("[{\"photoPath\":\"/p/a.JPG\",\"photoID\":1,\"stated\":32}]")
        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy.first?.keywordEdit)
    }

}
