// A folder renamed or moved in Finder keeps its photographs' catalog rows.
//
// The app reopens a renamed folder through its bookmark under the NEW path, which is a
// new folder row. The old folder's rows are never rescanned, so they never become
// `missing`, so the relocation probe asked for no signatures and every file came back
// as a fresh photo: snapshots, collections and stacks stayed on rows nothing shows, and
// the relink tool could not reach them either.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogRenamedFolderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-renamed-folder-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path,
                         cachePath: root.appendingPathComponent("catalog/cache.db").path)
    }

    private func writePhoto(_ url: URL, seed: UInt8, size: Int = 4096) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0) &+ seed }).write(to: url)
    }

    /// The scan exactly as `CatalogService.registerAndLoad` drives it: signatures only
    /// for listed files the probe names as possible relocations.
    @discardableResult
    private func open(_ store: CatalogStore, _ folder: URL) throws -> (Int64, ScanResult) {
        let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "NEF" }
            .sorted { $0.path < $1.path }
        let folderID = try store.registerFolder(path: folder.path)
        let names = files.map { ScannedFile.catalogName(for: $0, in: folder) }
        let probe = try store.relocationProbe(folderID: folderID, listed: Set(names))
        let scanned = try zip(files, names).map { file, name -> ScannedFile in
            let size = Int64(try XCTUnwrap(
                try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
                .int64Value)
            var signature: String? = nil
            if !probe.known.contains(name), probe.candidateSizes.contains(size) {
                signature = try QuickSignature.compute(url: file)
            }
            return ScannedFile(filename: name, fileSize: size, fileMTime: 1_700_000_000,
                               quickSig: signature, ext: "nef")
        }
        let result = try store.scan(folderID: folderID, files: scanned)
        // The backfill gives every row its signature after the grid is up.
        for row in try store.photos(folderID: folderID) where row.quickSig == nil {
            try store.setQuickSig(
                QuickSignature.compute(url: folder.appendingPathComponent(row.filename)),
                photoID: row.id)
        }
        return (folderID, result)
    }

    func testARenamedFolderKeepsItsPhotosRows() throws {
        let store = try makeStore()
        let before = root.appendingPathComponent("Pictures/DCIM_100", isDirectory: true)
        try writePhoto(before.appendingPathComponent("A.NEF"), seed: 1)
        try writePhoto(before.appendingPathComponent("B.NEF"), seed: 2)
        let (oldFolder, _) = try open(store, before)

        let a = try XCTUnwrap(store.photo(folderID: oldFolder, filename: "A.NEF"))
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.7
        try store.saveRecipe(recipe, photoID: a.id, isCurrent: true)
        try store.setRating(5, photoID: a.id)
        try store.createNamedSnapshot(recipe, photoID: a.id, name: "Client pick")
        let album = try store.createCollection(name: "Wedding")
        try store.addToCollection(album, photoIDs: [a.id])

        let after = root.appendingPathComponent("Pictures/2026-11-26 Wedding", isDirectory: true)
        try FileManager.default.moveItem(at: before, to: after)

        let (newFolder, result) = try open(store, after)
        XCTAssertEqual(result.added, [], "a renamed folder's photos came back as new rows")
        let moved = try XCTUnwrap(store.photo(folderID: newFolder, filename: "A.NEF"))
        XCTAssertEqual(moved.id, a.id)
        XCTAssertEqual(moved.rating, 5)
        XCTAssertEqual(try store.currentRecipe(photoID: moved.id), recipe)
        XCTAssertEqual(try store.namedSnapshots(photoID: moved.id).compactMap(\.name), ["Client pick"])
        XCTAssertEqual(try store.photos(folderID: newFolder).count, 2)
        XCTAssertEqual(try store.photos(folderID: oldFolder).count, 0)
    }

    /// A folder on a volume that is not mounted has not vanished: an independent copy
    /// of its files opened elsewhere must not take its rows.
    func testAnUnmountedVolumesFolderKeepsItsRows() throws {
        let store = try makeStore()
        let offline = try store.registerFolder(path: "/Volumes/lumen-not-mounted-\(UUID().uuidString)/DCIM")
        let copy = root.appendingPathComponent("Copy", isDirectory: true)
        try writePhoto(copy.appendingPathComponent("A.NEF"), seed: 1)
        let signature = try QuickSignature.compute(url: copy.appendingPathComponent("A.NEF"))
        let original = try store.upsertPhoto(PhotoRow(folderID: offline, filename: "A.NEF",
                                                      fileSize: 4096, fileMTime: 1_700_000_000,
                                                      quickSig: signature, ext: "nef"))

        let (copyFolder, result) = try open(store, copy)
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(try store.photo(id: original)?.folderID, offline)
        XCTAssertNotEqual(try store.photo(folderID: copyFolder, filename: "A.NEF")?.id, original)
    }

    /// A folder that is still there is not a relocation source: a copy of one of its
    /// files is a second photograph.
    func testACopyFromAFolderThatStillExistsIsANewPhoto() throws {
        let store = try makeStore()
        let first = root.appendingPathComponent("Shoot", isDirectory: true)
        try writePhoto(first.appendingPathComponent("A.NEF"), seed: 1)
        let (firstFolder, _) = try open(store, first)
        let a = try XCTUnwrap(store.photo(folderID: firstFolder, filename: "A.NEF"))

        let second = root.appendingPathComponent("Shoot copy", isDirectory: true)
        try FileManager.default.copyItem(at: first, to: second)
        let (_, result) = try open(store, second)
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(try store.photo(id: a.id)?.folderID, firstFolder)
    }
}

#endif
