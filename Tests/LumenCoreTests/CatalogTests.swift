// CatalogTests.swift
// The property the catalog exists to guarantee: quit, relaunch, lose nothing.
//
// These run against a real SQLite file in a temporary directory — the schema, the
// migrations and the queries all execute. A catalog that only compiles is not a
// catalog anybody should trust with three years of edits.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogTests: XCTestCase {

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

    private func seed(_ store: CatalogStore, count: Int = 5) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        var ids: [Int64] = []
        for file in files {
            if let row = try store.photo(folderID: folderID, filename: file.filename) {
                ids.append(row.id)
            }
        }
        return (folderID, ids)
    }

    // MARK: - Opening

    func testOpeningTwiceIsIdempotent() throws {
        let first = try makeStore()
        let (folderID, ids) = try seed(first)
        XCTAssertEqual(ids.count, 5)
        first.close()

        // Reopening must migrate cleanly and find everything.
        let second = try makeStore()
        let rows = try second.photos(folderID: folderID)
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(try second.quickCheck())
        second.close()
    }

    // MARK: - The exit test

    func testEditsAndCullingStateSurviveAReopen() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let first = ids.first else { return XCTFail("no photos seeded") }

        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.25
        recipe.develop.tone.highlights = -60
        recipe.develop.color.saturation = 18
        recipe.look.printerLights = PrinterLights(master: 2, r: -1, g: 0, b: 3)
        try store.saveRecipe(recipe, photoID: first, isCurrent: true)
        try store.setFlag(.pick, photoID: first)
        try store.setRating(4, photoID: first)
        try store.setLabel(.green, photoID: first)
        store.close()

        let reopened = try makeStore()
        guard let restored = try reopened.currentRecipe(photoID: first) else {
            return XCTFail("the recipe did not come back")
        }
        XCTAssertEqual(restored, recipe, "the recipe changed across a reopen")

        guard let row = try reopened.photo(id: first) else { return XCTFail("photo missing") }
        XCTAssertEqual(row.flag, .pick)
        XCTAssertEqual(row.rating, 4)
        XCTAssertEqual(row.label, "green")
        _ = folderID
        reopened.close()
    }

    func testOnlyOneEditIsCurrentPerPhoto() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store, count: 1)
        guard let photo = ids.first else { return XCTFail("no photo") }

        for exposure in [0.5, 1.0, 1.5] {
            var recipe = Recipe()
            recipe.develop.tone.exposure = exposure
            try store.saveRecipe(recipe, photoID: photo, isCurrent: true)
        }
        let current = try store.currentRecipe(photoID: photo)
        XCTAssertEqual(current?.develop.tone.exposure, 1.5)
        // A photo with two current edits is a catalog that has lost track of which
        // version it is showing you.
        let edits = try store.edits(photoID: photo).filter { $0.isCurrent }
        XCTAssertEqual(edits.count, 1)
        store.close()
    }

    // MARK: - Scanning

    func testRescanningIsStableAndMarksRemovalsMissingRatherThanDeleting() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let first = ids.first else { return XCTFail("no photos") }

        var recipe = Recipe()
        recipe.develop.tone.exposure = 2
        try store.saveRecipe(recipe, photoID: first, isCurrent: true)

        // Same files again: nothing added, nothing lost.
        let same = (0..<5).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "arw")
        }
        let second = try store.scan(folderID: folderID, files: same, at: CatalogStore.now())
        XCTAssertTrue(second.added.isEmpty)
        XCTAssertTrue(second.missing.isEmpty)

        // Now the first file is gone from the card. Its edits must survive: a file
        // that is offline is a state, never a deletion.
        let fewer = Array(same.dropFirst())
        let third = try store.scan(folderID: folderID, files: fewer, at: CatalogStore.now())
        XCTAssertEqual(third.missing.count, 1)
        XCTAssertNotNil(try store.currentRecipe(photoID: first),
                        "a missing file lost its edits")
        store.close()
    }

    // MARK: - Filtering

    func testFilterCriteriaORWithinAndANDAcross() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 6)
        XCTAssertEqual(ids.count, 6)

        // Three picks, of which two are rated 4+, and one of those is labelled red.
        try store.setFlag(.pick, photoIDs: Array(ids.prefix(3)))
        try store.setRating(5, photoID: ids[0])
        try store.setRating(4, photoID: ids[1])
        try store.setRating(2, photoID: ids[2])
        try store.setLabel(.red, photoID: ids[0])
        try store.setFlag(.reject, photoID: ids[4])

        var picks = PhotoQuery()
        picks.flags = [.pick]
        XCTAssertEqual(try store.photos(matching: picks, folderID: folderID).count, 3)

        // Two flags OR together.
        var flagged = PhotoQuery()
        flagged.flags = [.pick, .reject]
        XCTAssertEqual(try store.photos(matching: flagged, folderID: folderID).count, 4)

        // A second criterion ANDs with the first.
        var pickedAndRated = PhotoQuery()
        pickedAndRated.flags = [.pick]
        pickedAndRated.rating = 4
        XCTAssertEqual(try store.photos(matching: pickedAndRated, folderID: folderID).count, 2)

        // And a third narrows it again.
        var narrowed = pickedAndRated
        narrowed.labels = [.red]
        XCTAssertEqual(try store.photos(matching: narrowed, folderID: folderID).count, 1)
        store.close()
    }

    // MARK: - Backup

    func testBackupProducesAReadableCatalog() throws {
        let store = try makeStore()
        let (folderID, _) = try seed(store)
        let backup = directory.appendingPathComponent("backup.db")
        try store.backup(to: backup.path)
        store.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let restored = try CatalogStore(path: backup.path, cachePath: nil)
        XCTAssertEqual(try restored.photos(folderID: folderID).count, 5)
        restored.close()
    }

    // MARK: - Sidecars

    func testSidecarRoundTripsARecipe() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = -0.75
        recipe.develop.raw.temp = 4800
        recipe.look.vignette = -1.2

        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let content = SidecarContent(rating: 3, label: "blue",
                                     pipelineVersion: recipe.pipelineVersion,
                                     recipeFingerprint: try RecipeFingerprint.fingerprint(recipe),
                                     recipeJSON: json)
        let text = XMPSidecar.serialize(content)
        guard let parsed = XMPSidecar.parse(text) else {
            return XCTFail("the sidecar did not parse")
        }
        XCTAssertEqual(parsed.rating, 3)
        XCTAssertEqual(parsed.label, "blue")
        guard let restoredJSON = parsed.recipeJSON else {
            return XCTFail("the sidecar carried no recipe")
        }
        let restored = try CanonicalJSON.decodeRecipe(from: Data(restoredJSON.utf8))
        XCTAssertEqual(restored, recipe,
                       "the second copy of the work is not the same as the first")
    }
}

#endif
