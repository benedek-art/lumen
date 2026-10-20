#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

/// Round-3 catalog correctness regressions: keyword removal by the spelling the sidebar
/// shows, a text index switched off mid-session, relinking through a symlinked folder.
final class CatalogCorrectnessRound3Tests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-round3-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func openStore(_ root: URL) throws -> CatalogStore {
        try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
                         cachePath: root.appendingPathComponent("cache.db").path)
    }

    private func seed(_ store: CatalogStore, names: [String]) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: "/Volumes/S/f")
        _ = try store.scan(folderID: folderID, files: names.enumerated().map {
            ScannedFile(filename: $0.element, fileSize: 10 + Int64($0.offset), fileMTime: 1, ext: "raf")
        })
        let ids = try names.map { try XCTUnwrap(store.photo(folderID: folderID, filename: $0)?.id) }
        return (folderID, ids)
    }

    // MARK: #0 — a root keyword's bare name is that root, not every namesake

    func testRemovingRootKeywordKeepsSameNamedNestedKeyword() throws {
        let root = try scratch()
        let store = try openStore(root)
        defer { store.close() }
        let (_, ids) = try seed(store, names: ["A.RAF"])
        let p = ids[0]
        try store.addKeyword("Iceland", photoIDs: [p])           // root, created first
        try store.addKeyword("Places > Iceland", photoIDs: [p])  // a distinct nested keyword
        let before = try store.keywords(photoID: p)
        XCTAssertEqual(before, ["Iceland", "Places > Iceland"])

        try store.removeKeyword(before[0], photoIDs: [p])        // the root row's x
        let after = try store.keywords(photoID: p)
        XCTAssertEqual(after, ["Places > Iceland"])

        // The sidecar delta must not strip the leaf the photo still carries.
        let edit = try SidecarKeywordEdit.removal(before: before, after: after,
                                                  synonyms: store.synonyms(ofKeyword:))
        XCTAssertEqual(edit.apply(to: ["Iceland"]), ["Iceland"])
    }

    func testABareNameWithNoRootStillDetachesTheNestedKeyword() throws {
        let root = try scratch()
        let store = try openStore(root)
        defer { store.close() }
        let (_, ids) = try seed(store, names: ["A.RAF"])
        try store.addKeyword("Places > Iceland", photoIDs: [ids[0]])
        try store.removeKeyword("Iceland", photoIDs: [ids[0]])
        XCTAssertEqual(try store.keywords(photoID: ids[0]), [])
    }
}
#endif
