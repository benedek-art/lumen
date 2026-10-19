#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class InflightKeywordScanTests: XCTestCase {
    func testScanDuringInflightRemovalCannotResurrectCatalogKeyword() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-inflight-keyword-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let directory = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: directory)
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
        defer { service.close(); store.close() }
        await service.addKeyword("Private", targets: [(id, photo)])
        await service.addKeyword("Kept", targets: [(id, photo)])
        service.flushSidecars()
        XCTAssertEqual(Set(CatalogService.readSidecar(for: photo)?.keywords ?? []), ["Private", "Kept"])
        await service.removeKeyword("Private", targets: [(id, photo)])
        XCTAssertEqual(try store.keywords(photoID: id), ["Kept"])
        let owed = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed[0].keywordEdit?.removed, ["Private"])
        XCTAssertNotNil(owed[0].generation)
        var reads = 0
        var duringScanKeywords: [String]?
        service.sidecarDataReader = { path in
            reads += 1
            // Make the publication callback one-shot before a scan uses the same
            // reader. No newer local edit reconstructs pendingSidecars for us.
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            _ = service.registerAndLoad(folder: root, files: [photo])
            duringScanKeywords = try store.keywords(photoID: id)
            return try Data(contentsOf: path)
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(duringScanKeywords, ["Kept"], "an old sidecar cannot undo a committed in-flight removal")
        XCTAssertEqual(try store.keywords(photoID: id), ["Kept"])
        XCTAssertEqual(CatalogService.readSidecar(for: photo)?.keywords, ["Kept"])
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(service.close(), [])
        let reopened = try CatalogService(directory: directory)
        defer { reopened.close() }
        _ = reopened.registerAndLoad(folder: root, files: [photo])
        XCTAssertEqual(try store.keywords(photoID: id), ["Kept"])
        XCTAssertEqual(CatalogService.readSidecar(for: photo)?.keywords, ["Kept"])
    }
    func testInflightLegacyAdditionThatOutlivedCatalogMembershipIsNotReimported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-inflight-legacy-tag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let directory = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: directory)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await seed.addKeyword("Kept", targets: [(id, photo)])
        XCTAssertEqual(seed.close(), [])
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let legacy = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.keywords],
            keywordEdit: SidecarKeywordEdit(added: ["Removed"]))
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([legacy]))
        let service = try CatalogService(directory: directory)
        defer { service.close() }
        try await service.requireAvailablePhoto(photoID: id)
        var reads = 0
        service.sidecarDataReader = { path in
            reads += 1
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            _ = service.registerAndLoad(folder: root, files: [photo])
            return try Data(contentsOf: path)
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try store.keywords(photoID: id), ["Kept"])
        XCTAssertEqual(CatalogService.readSidecar(for: photo)?.keywords, ["Kept"])
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

}
#endif
