// One file on disk, one photo row — whichever registered folder the file is opened under.
//
// V7 decision 6, reproduced here: a picked set of photographs is rooted at their common
// parent, and the catalog keys a photo on (folder, path relative to the folder). The same
// file opened as part of its own folder (`/shoot/day1`, name `a.NEF`) and then as part of
// a picked set (`/shoot`, name `day1/a.NEF`) got a SECOND row: new rating, no recipe, no
// albums, its own history. The same thing happened opening a parent folder after a child.
// The scan now finds the row by the file's absolute path in a related (ancestor or
// descendant) folder and moves it, with everything on it, into the folder being scanned.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogPathIdentityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-path-identity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    private func file(_ name: String, size: Int64 = 41_000_000) -> ScannedFile {
        ScannedFile(filename: name, fileSize: size, fileMTime: 1_700_000_000, ext: "nef")
    }

    private func rowCount(_ store: CatalogStore, _ folders: [Int64]) throws -> Int {
        try folders.reduce(0) { $0 + (try store.photos(folderID: $1).count) }
    }

    /// The picked-set case: folder first, then the same file under its parent.
    func testTheSameFileOpenedUnderItsParentKeepsItsOneRow() throws {
        let store = try makeStore()
        let day1 = try store.registerFolder(path: "/Volumes/Shoots/day1")
        _ = try store.scan(folderID: day1, files: [file("a.NEF"), file("b.NEF", size: 42_000_000)])
        let original = try XCTUnwrap(store.photo(folderID: day1, filename: "a.NEF"))
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.6
        try store.saveRecipe(recipe, photoID: original.id, isCurrent: true)
        try store.setRating(4, photoID: original.id)

        // Open... a.NEF together with a frame from day2: rooted at /Volumes/Shoots.
        let shoots = try store.registerFolder(path: "/Volumes/Shoots")
        let result = try store.scan(folderID: shoots,
                                    files: [file("day1/a.NEF"), file("day2/c.NEF", size: 43_000_000)],
                                    completeListing: false)

        XCTAssertEqual(result.added.count, 1, "only day2/c.NEF is new to the catalog")
        let day2 = try store.registerFolder(path: "/Volumes/Shoots/day2")
        XCTAssertEqual(try rowCount(store, [day1, shoots, day2]), 3,
                       "the same file on disk got a second photo row")
        let landed = try XCTUnwrap(store.photo(folderID: shoots, filename: "day1/a.NEF"))
        XCTAssertEqual(landed.id, original.id, "the row was not carried over")
        XCTAssertEqual(landed.rating, 4)
        XCTAssertEqual(try store.currentRecipe(photoID: landed.id), recipe)
        XCTAssertTrue(result.relocated.contains(original.id))

        // b.NEF was not in the picked set and stays where it was, unmissing.
        let b = try XCTUnwrap(store.photo(folderID: day1, filename: "b.NEF"))
        XCTAssertFalse(b.missing)

        // And opening day1 again brings the row home, still one row.
        _ = try store.scan(folderID: day1, files: [file("a.NEF"), file("b.NEF", size: 42_000_000)])
        let home = try XCTUnwrap(store.photo(folderID: day1, filename: "a.NEF"))
        XCTAssertEqual(home.id, original.id)
        XCTAssertEqual(try rowCount(store, [day1, shoots, day2]), 3)
        XCTAssertEqual(try store.currentRecipe(photoID: home.id), recipe)
    }

    /// The other direction: a parent folder opened after its child.
    func testAParentFolderOpenedAfterItsChildDoesNotDuplicate() throws {
        let store = try makeStore()
        let child = try store.registerFolder(path: "/Volumes/Card/DCIM/100NIKON")
        _ = try store.scan(folderID: child, files: [file("DSC_0001.NEF")])
        let original = try XCTUnwrap(store.photo(folderID: child, filename: "DSC_0001.NEF"))

        let card = try store.registerFolder(path: "/Volumes/Card")
        let result = try store.scan(folderID: card, files: [file("DCIM/100NIKON/DSC_0001.NEF")])
        XCTAssertTrue(result.added.isEmpty, "the parent's scan inserted a duplicate row")
        XCTAssertEqual(try store.photo(folderID: card, filename: "DCIM/100NIKON/DSC_0001.NEF")?.id,
                       original.id)
        XCTAssertEqual(try rowCount(store, [child, card]), 1)
    }

    /// Only the same ABSOLUTE path is the same file. A sibling whose name is a string
    /// prefix (`day1` / `day10`) or an unrelated folder with the same relative layout
    /// must not lend its row.
    func testOnlyTheSameAbsolutePathIsTheSameFile() throws {
        let store = try makeStore()
        let day10 = try store.registerFolder(path: "/Volumes/Shoots/day10")
        _ = try store.scan(folderID: day10, files: [file("a.NEF")])
        let other = try store.registerFolder(path: "/Volumes/Other/day1")
        _ = try store.scan(folderID: other, files: [file("a.NEF")])

        let day1 = try store.registerFolder(path: "/Volumes/Shoots/day1")
        let result = try store.scan(folderID: day1, files: [file("a.NEF")])
        XCTAssertEqual(result.added.count, 1, "a different file was taken for this one")
        XCTAssertNotNil(try store.photo(folderID: day10, filename: "a.NEF"))
        XCTAssertNotNil(try store.photo(folderID: other, filename: "a.NEF"))

        // Rooted at "/" (frames picked from two volumes): the row under /Volumes/Shoots/day1
        // is the same file as "Volumes/Shoots/day1/a.NEF" under "/".
        let root = try store.registerFolder(path: "/")
        let rooted = try store.scan(folderID: root, files: [file("Volumes/Shoots/day1/a.NEF")],
                                    completeListing: false)
        XCTAssertTrue(rooted.added.isEmpty)
        XCTAssertEqual(try rowCount(store, [day10, other, day1, root]), 3)
    }

    /// The prefix trap INSIDE a related folder. `/shoot/day1` is a real descendant of
    /// `/shoot`, so it passes the folder-level relation; the name `day10/a.NEF` under
    /// `/shoot` must still not be read as `a.NEF` under `day1` just because "day10"
    /// starts with "day1". Compared as strings, day1's rated row moved onto day10's
    /// frame and day1's own `a.NEF` got a fresh, unrated row.
    func testASiblingWhoseNameExtendsARelatedFolderDoesNotTakeItsRow() throws {
        let store = try makeStore()
        let day1 = try store.registerFolder(path: "/Volumes/Shoots/day1")
        _ = try store.scan(folderID: day1, files: [file("a.NEF")])
        let original = try XCTUnwrap(store.photo(folderID: day1, filename: "a.NEF"))
        try store.setRating(5, photoID: original.id)

        let shoots = try store.registerFolder(path: "/Volumes/Shoots")
        let result = try store.scan(folderID: shoots,
                                    files: [file("day10/a.NEF", size: 40_000_000),
                                            file("day1/a.NEF")])
        let day10Frame = try XCTUnwrap(store.photo(folderID: shoots, filename: "day10/a.NEF"))
        XCTAssertNotEqual(day10Frame.id, original.id,
                          "day1's row was taken for day10/a.NEF, a different file")
        XCTAssertEqual(day10Frame.rating, 0)
        let day1Frame = try XCTUnwrap(store.photo(folderID: shoots, filename: "day1/a.NEF"))
        XCTAssertEqual(day1Frame.id, original.id)
        XCTAssertEqual(day1Frame.rating, 5)
        XCTAssertEqual(result.added.count, 1, "only day10/a.NEF is new")
        XCTAssertEqual(try rowCount(store, [day1, shoots]), 2)
    }
}

#endif
