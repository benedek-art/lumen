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

    // MARK: #1 — an index switched off mid-session is rebuilt on the next open

    func testATextIndexDisabledMidSessionIsRebuiltOnReopen() throws {
        let root = try scratch()
        let store = try openStore(root)
        let (folderID, ids) = try seed(store, names: ["A.RAF", "B.RAF"])
        guard store.isTextIndexAvailable else {
            store.close()
            throw XCTSkip("no FTS5 in this SQLite")
        }
        // Briefly unwritable WITHOUT being emptied: a transient cache error.
        try store.debugExecute("ALTER TABLE cache.photo_fts RENAME TO photo_fts_off;")
        try store.addKeyword("Reykjavik", photoIDs: [ids[0]])
        XCTAssertFalse(store.isTextIndexAvailable)
        try store.debugExecute("ALTER TABLE cache.photo_fts_off RENAME TO photo_fts;")
        store.close()

        let reopened = try openStore(root)
        defer { reopened.close() }
        XCTAssertTrue(reopened.isTextIndexAvailable)
        var query = PhotoQuery(); query.text = "Reykjavik"
        XCTAssertEqual(try reopened.photos(matching: query, folderID: folderID).map(\.id), [ids[0]],
                       "a keyword written while the index was off must be searchable after reopen")
        XCTAssertEqual(try reopened.countPhotos(matching: query, folderID: folderID), 1)
        XCTAssertNil(try reopened.metaValue(CatalogStore.textIndexStaleKey),
                     "the stale marker is cleared once the rebuild has run")
    }

    // MARK: #2 — relink through a symlinked registered folder reuses that folder

    func testRelinkThroughSymlinkedFolderDoesNotDuplicateOnRescan() throws {
        let fm = FileManager.default
        let root = try scratch()
        let store = try openStore(root)
        defer { store.close() }
        let real = root.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let folderID = try store.registerFolder(path: link.path)
        let original = link.appendingPathComponent("orig.raf")
        try Data((0..<4096).map { UInt8($0 & 0xff) }).write(to: original)
        let signature = try QuickSignature.compute(url: original)
        _ = try store.scan(folderID: folderID, files: [ScannedFile(
            filename: "orig.raf", fileSize: 4096, fileMTime: 1, quickSig: signature, ext: "raf")])
        let id = try XCTUnwrap(store.photo(folderID: folderID, filename: "orig.raf")?.id)
        let foldersBefore = try store.folders().count

        let renamed = link.appendingPathComponent("x.raf")
        try fm.moveItem(at: original, to: renamed)                 // the original goes missing
        let target = try store.originalRelinkTarget(photoID: id)
        let candidate = try OriginalRelinkCandidate.inspect(renamed) // resolves to real/x.raf
        _ = try store.relinkOriginal(target, candidate: candidate)
        XCTAssertEqual(try store.folders().count, foldersBefore)

        let result = try store.scan(folderID: folderID, files: [ScannedFile(
            filename: "x.raf", fileSize: 4096, fileMTime: candidate.fileMTime,
            quickSig: signature, ext: "raf")])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(try store.photo(folderID: folderID, filename: "x.raf")?.id, id)
        XCTAssertEqual(try store.photos(folderID: folderID).count, 1)
    }
}
#endif

#if canImport(XCTest)
import XCTest
@testable import LumenCore

/// #3 — an EXIF stamp naming a day past the end of its month is not a date.
final class EXIFDateCalendarTests: XCTestCase {
    func testParseEXIFDateRejectsDayPastEndOfMonth() {
        XCTAssertNil(PhotoMetadata.parseEXIFDate("2025:02:29 10:00:00"))   // not a leap year
        XCTAssertNil(PhotoMetadata.parseEXIFDate("2026:04:31 12:00:00"))   // April has 30
        XCTAssertNil(PhotoMetadata.parseEXIFDate("1900:02:29 00:00:00"))   // century, not leap
        XCTAssertNil(PhotoMetadata.parseEXIFDateComponents("2025:02:29 10:00:00"))
        // Real month ends and leap days still parse.
        XCTAssertNotNil(PhotoMetadata.parseEXIFDate("2024:02:29 10:00:00"))
        XCTAssertNotNil(PhotoMetadata.parseEXIFDate("2000:02:29 10:00:00"))
        XCTAssertNotNil(PhotoMetadata.parseEXIFDate("2026:01:31 10:00:00"))
        XCTAssertNotNil(PhotoMetadata.parseEXIFDate("2026:12:31 23:59:60"))  // leap second kept
        XCTAssertEqual(PhotoMetadata.parseEXIFDateComponents("2024:02:29 10:00:00")?.day, 29)
        for text in ["2025:02:29 10:00:00", "2024:02:29 10:00:00", "2026:04:31 00:00:00",
                     "2026:06:30 00:00:00"] {
            XCTAssertEqual(PhotoMetadata.parseEXIFDate(text) == nil,
                           PhotoMetadata.parseEXIFDateComponents(text) == nil, text)
        }
    }
}
#endif
