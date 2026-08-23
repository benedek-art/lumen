// SavedLookCatalogTests.swift
// Saved looks against a real SQLite file: the schema, the migration, the writes and
// the reads all execute.
//
// docs/19 Phase 3 asks for looks "stored in the catalog, applied to any photo in any
// folder". Both halves of that sentence are load-bearing and both are asserted here —
// what existed before was an in-memory Copy Look that died at quit (audit FILM-15), so
// a test that only proves a struct can be encoded would have passed against the
// feature's absence.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class SavedLookCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-looks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    /// One photo in its own folder, so "any photo in any folder" can be tested with two
    /// folders rather than asserted about one.
    @discardableResult
    private func seedPhoto(_ store: CatalogStore, folder: String,
                           filename: String) throws -> Int64 {
        let folderID = try store.registerFolder(path: folder)
        let file = ScannedFile(filename: filename, fileSize: 41_000_000,
                               fileMTime: 1_700_000_000, ext: "arw")
        _ = try store.scan(folderID: folderID, files: [file], at: CatalogStore.now())
        guard let row = try store.photo(folderID: folderID, filename: filename) else {
            throw CatalogError.notFound("seeded photo \(filename)")
        }
        return row.id
    }

    // MARK: - The exit test, for looks

    /// Save a look off one photograph, quit, relaunch, and put it on a photograph in a
    /// different folder. This is docs/19's sentence, executed.
    func testALookSavedOffOnePhotoReachesAPhotoInAnotherFolderAfterAReopen() throws {
        let store = try makeStore()
        let graded = try seedPhoto(store, folder: "/Volumes/Shoots/wedding",
                                   filename: "DSC0001.ARW")
        let untouched = try seedPhoto(store, folder: "/Volumes/Shoots/portraits",
                                      filename: "DSC9000.ARW")

        var source = Recipe(develop: SavedLookTests.loadedDevelop(),
                            look: SavedLookTests.loadedLook(),
                            masks: [SavedLookTests.perFrameMask()])
        source.develop.tone.exposure = 1.4
        try store.saveRecipe(source, photoID: graded, isCurrent: true)

        var ownWork = Recipe()
        ownWork.develop.tone.exposure = -0.9
        ownWork.develop.raw.temp = 3100
        ownWork.develop.geometry.crop = Crop(x: 0.1, y: 0, w: 0.8, h: 1)
        try store.saveRecipe(ownWork, photoID: untouched, isCurrent: true)

        try store.saveLook(name: "Portra warm",
                           subset: LookSubset.extracted(from: source))
        store.close()

        // Relaunch.
        let reopened = try makeStore()
        let stored = try reopened.looks()
        XCTAssertEqual(stored.map(\.name), ["Portra warm"])
        guard let row = stored.first else { return XCTFail("the look did not come back") }

        guard let target = try reopened.currentRecipe(photoID: untouched) else {
            return XCTFail("the target photo has no recipe")
        }
        let graded2 = try row.subset().applied(to: target)
        try reopened.saveRecipe(graded2, photoID: untouched, isCurrent: true)
        reopened.close()

        // And a second relaunch, because the point is that it is on disk.
        let third = try makeStore()
        guard let final = try third.currentRecipe(photoID: untouched) else {
            return XCTFail("the graded recipe did not persist")
        }
        XCTAssertEqual(final.look, source.look,
                       "the look did not survive the catalog")
        XCTAssertEqual(final.develop, ownWork.develop,
                       "the look overwrote the target photograph's own develop")
        XCTAssertEqual(final.masks, [], "the look brought the source photo's masks")
        third.close()
    }

    func testASavedLookKeepsEveryFieldOfTheLookLayerThroughSQLite() throws {
        let store = try makeStore()
        let subset = LookSubset(look: SavedLookTests.loadedLook())
        let id = try store.saveLook(name: "Everything", subset: subset)
        store.close()

        let reopened = try makeStore()
        guard let row = try reopened.look(id: id) else {
            return XCTFail("the look did not come back")
        }
        XCTAssertEqual(try row.subset(), subset)
        reopened.close()
    }

    // MARK: - Create, rename, delete, list

    func testSavingUnderAnExistingNameUpdatesThatLookRatherThanAddingASecond() throws {
        let store = try makeStore()
        let first = try store.saveLook(name: "Cool", subset: LookSubset(
            look: Look(vignette: -0.5)))
        let second = try store.saveLook(name: "Cool", subset: LookSubset(
            look: Look(vignette: -1.5)))

        XCTAssertEqual(first, second, "saving over a name created a second row")
        let all = try store.looks()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(try all[0].subset().look.vignette, -1.5)
        store.close()
    }

    /// Whitespace around a name is not part of the name, so it cannot be used to hold
    /// two looks the browser would draw identically.
    func testAWhitespaceVariantOfANameIsTheSameName() throws {
        let store = try makeStore()
        let first = try store.saveLook(name: "Cool", subset: LookSubset())
        let second = try store.saveLook(name: "  Cool  ", subset: LookSubset())
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.looks().count, 1)
        store.close()
    }

    func testALookNeedsAName() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.saveLook(name: "   ", subset: LookSubset()))
        XCTAssertEqual(try store.looks().count, 0)
        store.close()
    }

    func testTheSameNameInTwoGroupsIsTwoLooks() throws {
        let store = try makeStore()
        try store.saveLook(name: "Base", subset: LookSubset(look: Look(vignette: -0.1)),
                           group: "Weddings")
        try store.saveLook(name: "Base", subset: LookSubset(look: Look(vignette: -0.2)),
                           group: "Sport")
        let all = try store.looks()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.group), ["Sport", "Weddings"],
                       "looks are listed by group then name")
        store.close()
    }

    func testRenamingALook() throws {
        let store = try makeStore()
        let id = try store.saveLook(name: "Untitled", subset: LookSubset(
            look: Look(vignette: -0.7)))
        try store.renameLook(id: id, to: "  Golden hour ")
        store.close()

        let reopened = try makeStore()
        let all = try reopened.looks()
        XCTAssertEqual(all.map(\.name), ["Golden hour"])
        XCTAssertEqual(try all[0].subset().look.vignette, -0.7,
                       "the rename disturbed the look itself")
        reopened.close()
    }

    /// A rename onto a taken name is refused rather than silently swallowing the look
    /// already sitting there.
    func testRenamingOntoATakenNameIsRefusedAndDamagesNeitherLook() throws {
        let store = try makeStore()
        let keep = try store.saveLook(name: "Keep", subset: LookSubset(
            look: Look(vignette: -0.3)))
        let other = try store.saveLook(name: "Other", subset: LookSubset(
            look: Look(vignette: -0.9)))

        XCTAssertThrowsError(try store.renameLook(id: other, to: "Keep"))

        XCTAssertEqual(try store.look(id: keep)?.name, "Keep")
        XCTAssertEqual(try store.look(id: keep)?.subset().look.vignette, -0.3)
        XCTAssertEqual(try store.look(id: other)?.name, "Other")
        XCTAssertEqual(try store.look(id: other)?.subset().look.vignette, -0.9)
        store.close()
    }

    func testDeletingALookLeavesTheOthersAndTheEditsAlone() throws {
        let store = try makeStore()
        let photo = try seedPhoto(store, folder: "/Volumes/Shoots/x",
                                  filename: "DSC0001.ARW")
        let subset = LookSubset(look: SavedLookTests.loadedLook())
        let doomed = try store.saveLook(name: "Doomed", subset: subset)
        try store.saveLook(name: "Kept", subset: LookSubset(look: Look(vignette: -0.4)))

        try store.saveRecipe(subset.applied(to: Recipe()), photoID: photo,
                             isCurrent: true)
        try store.deleteLook(id: doomed)
        store.close()

        let reopened = try makeStore()
        XCTAssertEqual(try reopened.looks().map(\.name), ["Kept"])
        XCTAssertNil(try reopened.look(id: doomed))
        XCTAssertEqual(try reopened.currentRecipe(photoID: photo)?.look,
                       SavedLookTests.loadedLook(),
                       "throwing a look away un-graded a photograph that used it")
        reopened.close()
    }

    /// Lookup by name is exact apart from the whitespace normalization every name goes
    /// through on the way in. Case is part of a look's name, the way it is part of a
    /// keyword's here — the browser hands back the stored string, so nothing in the app
    /// ever has to guess at capitalization, and a photographer who deliberately keeps
    /// "Portra warm" and "PORTRA WARM" is allowed to.
    func testLookupByName() throws {
        let store = try makeStore()
        try store.saveLook(name: "Portra warm", subset: LookSubset(
            look: Look(vignette: -0.25)))
        XCTAssertEqual(try store.look(named: " Portra warm ")?.subset().look.vignette,
                       -0.25)
        XCTAssertNil(try store.look(named: "portra warm"))
        XCTAssertNil(try store.look(named: "Nothing"))
        store.close()
    }

    // MARK: - The migration

    /// The constraint the browser's identity rests on actually exists in the file, on a
    /// catalog created by this build. Read straight out of `sqlite_master`, because a
    /// unique index that the store's own look-then-write path never happens to collide
    /// with would otherwise be indistinguishable from an index that was never created.
    func testTheCatalogCarriesTheLookIdentityIndex() throws {
        let store = try makeStore()
        try store.saveLook(name: "Anything", subset: LookSubset())
        store.close()

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("lumen.db").path)
        defer { raw.close() }
        XCTAssertEqual(try raw.userVersion(), 3, "the catalog is not at schema 3")
        let sql = try raw.scalarText(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'look_identity';")
        guard let sql else { return XCTFail("look_identity index is missing") }
        XCTAssertTrue(sql.contains("UNIQUE"), "look_identity is not unique: \(sql)")
        XCTAssertTrue(sql.contains("COALESCE"),
                      "look_identity does not fold NULL groups together, so ungrouped "
                      + "looks — the common case — are unconstrained: \(sql)")

        // And it bites: two rows with one identity cannot both exist.
        XCTAssertThrowsError(try raw.execute("""
        INSERT INTO look (name, grp, kind, subset, updated_at)
        VALUES ('Anything', NULL, 'look', '{}', 0);
        """), "a duplicate look name was accepted")
    }
}

#endif
