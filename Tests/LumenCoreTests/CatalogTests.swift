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

    // MARK: - Sort orders

    /// Every sort key the UI offers has to order by the column it names. Four of the
    /// twelve existed before this, and "capture time" was the file's modification time
    /// — which is when the card was copied, not when the shutter opened. These assert
    /// against metadata deliberately arranged to disagree with filename order, so a
    /// sort that quietly fell back to scan order fails.
    func testEachSortKeyOrdersByTheColumnItNames() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 4)
        XCTAssertEqual(ids.count, 4)

        // Capture times run backwards against the filenames.
        for (offset, id) in ids.enumerated() {
            try store.setMetadata(
                PhotoMetadata(captureAt: 1_700_000_000 - Int64(offset * 60),
                              camera: offset < 2 ? "Sony A7 IV" : "Nikon Z8",
                              iso: offset < 2 ? 200 : 12_800,
                              width: 6000, height: offset == 3 ? 6000 : 4000),
                photoID: id)
        }
        try store.setRating(5, photoID: ids[3])
        try store.setRating(1, photoID: ids[0])

        func order(_ key: PhotoQuery.SortKey, ascending: Bool = true) throws -> [Int64] {
            var query = PhotoQuery()
            query.sortKey = key
            query.ascending = ascending
            return try store.photos(matching: query, folderID: folderID).map(\.id)
        }

        XCTAssertEqual(try order(.captureTime), ids.reversed(),
                       "capture time did not order by capture_at")
        XCTAssertEqual(try order(.filename), ids)
        XCTAssertEqual(try order(.rating, ascending: false).first, ids[3])
        XCTAssertEqual(try order(.rating).first, ids[1],
                       "an unrated photo should sort below a 1-star one")
        // Aspect: three 3:2 frames and one square, so the square leads ascending.
        XCTAssertEqual(try order(.aspectRatio).first, ids[3])
        store.close()
    }

    /// Nine frames a second all carry the same whole second. Ordering a burst by
    /// `capture_at` alone hands them back in index order, which is right by luck on one
    /// card and wrong on the next.
    func testABurstIsOrderedBySubSecond() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 3)
        let subseconds = [700, 100, 400]
        for (offset, id) in ids.enumerated() {
            try store.setMetadata(
                PhotoMetadata(captureAt: 1_700_000_000,
                              captureSubsec: subseconds[offset]), photoID: id)
        }
        var query = PhotoQuery()
        query.sortKey = .captureTime
        XCTAssertEqual(try store.photos(matching: query, folderID: folderID).map(\.id),
                       [ids[1], ids[2], ids[0]],
                       "the burst came back in index order, not in shooting order")
        store.close()
    }

    /// The edit-time sort reads `edit.updated_at`, which only `saveRecipe` writes.
    func testEditTimeSortsByWhenTheRecipeWasLastSaved() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 3)
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        try store.saveRecipe(recipe, photoID: ids[2], kind: .working, name: nil,
                             isCurrent: true, at: 1_000)
        try store.saveRecipe(recipe, photoID: ids[0], kind: .working, name: nil,
                             isCurrent: true, at: 2_000)

        var query = PhotoQuery()
        query.sortKey = .editTime
        let ordered = try store.photos(matching: query, folderID: folderID).map(\.id)
        // Unedited photos have no edit row at all and sort last in both directions.
        XCTAssertEqual(Array(ordered.prefix(2)), [ids[2], ids[0]])
        XCTAssertEqual(ordered.last, ids[1])
        store.close()
    }

    // MARK: - The chips that had no SQL

    func testTheEditedChipFindsOnlyRecipesThatChangeThePicture() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 3)

        // A default recipe is not an edit, however many times it is saved.
        try store.saveRecipe(Recipe(), photoID: ids[0], isCurrent: true)
        var worked = Recipe()
        worked.develop.tone.exposure = 1.1
        try store.saveRecipe(worked, photoID: ids[1], isCurrent: true)

        var edited = PhotoQuery()
        edited.edited = true
        XCTAssertEqual(try store.photos(matching: edited, folderID: folderID).map(\.id),
                       [ids[1]])

        var untouched = PhotoQuery()
        untouched.edited = false
        XCTAssertEqual(try store.countPhotos(matching: untouched, folderID: folderID), 2)
        store.close()
    }

    func testCameraAndISOChipsNarrowTheGrid() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 4)
        for (offset, id) in ids.enumerated() {
            try store.setMetadata(
                PhotoMetadata(camera: offset < 3 ? "Sony A7 IV" : "Nikon Z8",
                              iso: [100, 6400, 12_800, 200][offset]),
                photoID: id)
        }

        var camera = PhotoQuery()
        camera.cameras = ["Sony A7 IV"]
        XCTAssertEqual(try store.countPhotos(matching: camera, folderID: folderID), 3)

        var noisy = PhotoQuery()
        noisy.isoRange = 6401...4_000_000
        XCTAssertEqual(try store.photos(matching: noisy, folderID: folderID).map(\.id),
                       [ids[2]])

        // Two criteria AND by default...
        var both = camera
        both.isoRange = 6401...4_000_000
        XCTAssertEqual(try store.countPhotos(matching: both, folderID: folderID), 1)

        // ...and OR when the bar's Any toggle is on (D39).
        both.matchAny = true
        XCTAssertEqual(try store.countPhotos(matching: both, folderID: folderID), 3)

        // The chip's own menu: values with live counts, most-used first.
        let cameras = try store.facetCounts(.camera, folderID: folderID)
        XCTAssertEqual(cameras.first, FacetValue(value: "Sony A7 IV", count: 3))
        XCTAssertEqual(cameras.count, 2)
        store.close()
    }

    // MARK: - Albums, keywords, stacks

    func testAnAlbumScopesTheGridAndCountsItsOwnMembership() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 5)

        let tray = try store.createCollection(name: "Tray")
        try store.setTargetCollection(tray)
        XCTAssertEqual(try store.targetCollectionID(), tray)
        try store.addToCollection(tray, photoIDs: [ids[1], ids[3]])

        var inAlbum = PhotoQuery()
        inAlbum.albumID = tray
        XCTAssertEqual(try store.photos(matching: inAlbum, folderID: folderID).map(\.id),
                       [ids[1], ids[3]])
        XCTAssertEqual(try store.countPhotos(matching: inAlbum), 2)

        // Adding the same photo twice is one membership, not two rows.
        try store.addToCollection(tray, photoIDs: [ids[1]])
        XCTAssertEqual(try store.countPhotos(matching: inAlbum), 2)

        try store.removeFromCollection(tray, photoIDs: [ids[1]])
        XCTAssertEqual(try store.photos(matching: inAlbum, folderID: folderID).map(\.id),
                       [ids[3]])
        store.close()
    }

    func testKeywordsAreAddedListedFilteredAndRemoved() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 4)
        _ = try store.addKeyword("harbour", photoIDs: [ids[0], ids[2]])
        _ = try store.addKeyword("dawn", photoIDs: [ids[0]])

        XCTAssertEqual(try store.keywords(photoID: ids[0]), ["dawn", "harbour"])
        XCTAssertEqual(try store.allKeywords(),
                       [FacetValue(value: "dawn", count: 1),
                        FacetValue(value: "harbour", count: 2)])

        var tagged = PhotoQuery()
        tagged.keywords = ["harbour"]
        XCTAssertEqual(try store.photos(matching: tagged, folderID: folderID).map(\.id),
                       [ids[0], ids[2]])

        try store.removeKeyword("harbour", photoIDs: [ids[0]])
        XCTAssertEqual(try store.photos(matching: tagged, folderID: folderID).map(\.id),
                       [ids[2]])
        // The vocabulary survives losing its last photo — a shoot's words are worth
        // keeping even when nothing is tagged with them right now.
        XCTAssertEqual(try store.allKeywords().map(\.value), ["dawn", "harbour"])
        store.close()
    }

    /// Collapsing 3,000 frames into 400 decisions is the whole point of stacks, and it
    /// is a pure index operation: one row per collapsed stack, everything unstacked,
    /// and every member of anything expanded.
    func testACollapsedStackShowsOnlyItsPick() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 6)
        let burst = Array(ids.prefix(3))
        let stackID = try store.createStack(origin: "manual", photoIDs: burst,
                                            pickPhotoID: burst[0])

        var tops = PhotoQuery()
        tops.stackState = .collapsedTopsOnly
        XCTAssertEqual(try store.photos(matching: tops, folderID: folderID).map(\.id),
                       [ids[0], ids[3], ids[4], ids[5]])

        // Promote a different frame and the collapsed stack shows that one instead.
        try store.setStackPick(burst[2], stackID: stackID)
        XCTAssertEqual(try store.photos(matching: tops, folderID: folderID).map(\.id),
                       [ids[2], ids[3], ids[4], ids[5]])
        do {
            try store.setStackPick(ids[5], stackID: stackID)
            XCTFail("a frame outside the stack must not be allowed to become its pick")
        } catch {
            // Expected: pointing a stack at a thumbnail from elsewhere in the library
            // is how a collapsed stack ends up showing the wrong photograph.
        }

        // Expanded, every member is back.
        try store.setStackCollapsed(false, stackID: stackID)
        XCTAssertEqual(try store.countPhotos(matching: tops, folderID: folderID), 6)

        var unstacked = PhotoQuery()
        unstacked.stackState = .unstacked
        XCTAssertEqual(try store.countPhotos(matching: unstacked, folderID: folderID), 3)

        XCTAssertEqual(try store.stack(containing: burst[1])?.id, stackID)
        XCTAssertEqual(try store.stackMembers(stackID: stackID), burst)

        // Unstacking loses the grouping and no photographs.
        try store.dissolveStack(id: stackID)
        XCTAssertNil(try store.stack(containing: burst[1]))
        XCTAssertEqual(try store.countPhotos(matching: unstacked, folderID: folderID), 6)
        XCTAssertEqual(try store.photos(folderID: folderID).count, 6)
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

    // MARK: - A photo's identity inside its folder

    /// The folder scan is recursive and `photo` is UNIQUE(folder_id, filename), so if
    /// the name is the basename then two frames are one row. Camera counters wrap and
    /// DCIM folders reuse names, so one card routinely holds `day1/DSC_0001.NEF` and
    /// `day2/DSC_0001.NEF`.
    func testTwoFilesWithTheSameBasenameGetDifferentCatalogNames() {
        let folder = URL(fileURLWithPath: "/Shoot", isDirectory: true)
        let first = URL(fileURLWithPath: "/Shoot/day1/DSC_0001.NEF")
        let second = URL(fileURLWithPath: "/Shoot/day2/DSC_0001.NEF")

        let a = ScannedFile.catalogName(for: first, in: folder)
        let b = ScannedFile.catalogName(for: second, in: folder)
        XCTAssertNotEqual(a, b,
                          "both frames resolve to \(a) — they will share one catalog "
                              + "row, and the second edit will overwrite the first")
        XCTAssertEqual(a, "day1/DSC_0001.NEF")
        XCTAssertEqual(b, "day2/DSC_0001.NEF")
    }

    /// The common case has to keep working unchanged: a file sitting directly in the
    /// opened folder is still named by its basename, so nothing about a flat folder's
    /// catalog rows moves.
    func testAFileDirectlyInTheFolderIsStillNamedByItsBasename() {
        let folder = URL(fileURLWithPath: "/Shoot", isDirectory: true)
        let file = URL(fileURLWithPath: "/Shoot/DSC_0001.NEF")
        XCTAssertEqual(ScannedFile.catalogName(for: file, in: folder), "DSC_0001.NEF")
    }

    func testCatalogNameHandlesTrailingSlashesAndDotSegments() {
        let plain = URL(fileURLWithPath: "/Shoot", isDirectory: true)
        let file = URL(fileURLWithPath: "/Shoot/day1/DSC_0001.NEF")
        XCTAssertEqual(ScannedFile.catalogName(for: file, in: plain),
                       "day1/DSC_0001.NEF")
        XCTAssertEqual(
            ScannedFile.catalogName(for: URL(fileURLWithPath: "/Shoot/./day1/DSC_0001.NEF"),
                                    in: plain),
            "day1/DSC_0001.NEF",
            "a dot segment produced a different identity for the same file")
    }

    /// A file that is not under the folder at all has no relative name. Falling back to
    /// the basename is wrong in the same bounded way the old behaviour was; returning
    /// an empty string would make every such stray collide with every other.
    func testAFileOutsideTheFolderFallsBackToItsBasename() {
        let folder = URL(fileURLWithPath: "/Shoot", isDirectory: true)
        let stray = URL(fileURLWithPath: "/Elsewhere/DSC_0002.NEF")
        XCTAssertEqual(ScannedFile.catalogName(for: stray, in: folder), "DSC_0002.NEF")
    }

    /// Deep nesting is ordinary on a card that has been organised by date.
    func testNestedSubfoldersKeepTheirWholePath() {
        let folder = URL(fileURLWithPath: "/Shoot", isDirectory: true)
        let deep = URL(fileURLWithPath: "/Shoot/2026/05/01/DSC_0001.NEF")
        XCTAssertEqual(ScannedFile.catalogName(for: deep, in: folder),
                       "2026/05/01/DSC_0001.NEF")
    }

    /// The name still has to yield the right extension — the catalog derives `ext`
    /// from it, and that is what tells RAW from rendered.
    func testTheExtensionStillFallsOutOfARelativeName() {
        XCTAssertEqual(CatalogStore.fileExtension(of: "day1/DSC_0001.NEF"), "nef")
        XCTAssertEqual(CatalogStore.fileExtension(of: "2026/05/01/a.b.CR3"), "cr3")
    }
}

#endif
