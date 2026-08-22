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

        XCTAssertEqual(try order(.captureTime), Array(ids.reversed()),
                       "capture time did not order by capture_at")
        XCTAssertEqual(try order(.filename), ids)
        XCTAssertEqual(try order(.rating, ascending: false).first, ids[3])
        XCTAssertEqual(try order(.rating).first, ids[1],
                       "an unrated photo should sort below a 1-star one")
        // Aspect: three 3:2 frames and one square, so the square leads ascending. This
        // is the assertion that catches `aspect` never being recomputed when EXIF
        // arrives — with it NULL for every row the sort degrades to row id and passes
        // nothing.
        XCTAssertEqual(try order(.aspectRatio).first, ids[3])
        XCTAssertEqual(try store.photo(id: ids[0])?.aspect, 1.5)
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

    /// LIB-26b: the subsecond field's DIGIT WIDTH is part of its value.
    ///
    /// The test above uses three-digit subseconds throughout, which is why it stayed
    /// green while the reader was calling `Int(_:)` on the raw string. EXIF
    /// SubsecTimeOriginal is a fraction with its decimal point left out, so "7" is
    /// 0.7 s and "070" is 0.07 s — and read as plain integers they sort 7 before 70,
    /// which is backwards. Mixed widths across one burst invert the whole run.
    func testSubSecondsAreFractionsSoADigitWidthCannotInvertABurst() {
        // The case the old reading gets backwards: 0.07 s is earlier than 0.7 s, and
        // "070" is the longer string.
        let early = PhotoMetadata.parseEXIFSubsec("070")
        let late = PhotoMetadata.parseEXIFSubsec("7")
        XCTAssertNotNil(early)
        XCTAssertNotNil(late)
        XCTAssertLessThan(early ?? 0, late ?? 0,
                          "\"070\" is 0.07 s and \"7\" is 0.7 s, so the first is earlier "
                              + "— read as integers they come back the other way round")

        // The whole width ladder for one fraction: every spelling of seven tenths is
        // the same instant, whatever the field's width.
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("7"), 700_000)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("70"), 700_000)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("700"), 700_000)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("700000"), 700_000)

        // Ordinary two- and three-digit fields keep their meaning.
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("07"), 70_000)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("123"), 123_000)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("0"), 0)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("000"), 0)

        // Below a camera's clock, and truncated rather than rounded so that a pair
        // truncation leaves in order cannot be carried into a tie.
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("1234567"), 123_456)
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec("1234569"), 123_456)

        // A field that is not a run of ASCII digits sorts as "no subsecond", which ties
        // the way a pre-EXIF burst does, rather than as a guess that orders confidently
        // and wrongly.
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec(""))
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec("   "))
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec("12x"))
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec("-1"))
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec("1.5"))
        XCTAssertNil(PhotoMetadata.parseEXIFSubsec("٧"))  // Arabic-Indic 7: isNumber, not ASCII
        XCTAssertEqual(PhotoMetadata.parseEXIFSubsec(" 45 "), 450_000)
    }

    /// The same defect where the user meets it: one burst, one second, mixed widths.
    func testABurstWithMixedSubSecondWidthsStillSortsForwards() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 3)
        // As three cameras spell the same run of frames: 0.07 s, 0.4 s, 0.7 s.
        let asWritten = ["070", "40", "7"]
        for (offset, id) in ids.enumerated() {
            try store.setMetadata(
                PhotoMetadata(captureAt: 1_700_000_000,
                              captureSubsec: PhotoMetadata.parseEXIFSubsec(asWritten[offset])),
                photoID: id)
        }
        var query = PhotoQuery()
        query.sortKey = .captureTime
        XCTAssertEqual(try store.photos(matching: query, folderID: folderID).map(\.id),
                       [ids[0], ids[1], ids[2]],
                       "the burst inverted: the widest subsecond string is the SMALLEST "
                           + "fraction, and reading the field as an integer says otherwise")
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
                              lens: offset == 0 ? "FE 35mm F1.4 GM" : "FE 85mm F1.4 GM",
                              iso: [100, 6400, 12_800, 200][offset]),
                photoID: id)
        }

        var camera = PhotoQuery()
        camera.cameras = ["Sony A7 IV"]
        XCTAssertEqual(try store.countPhotos(matching: camera, folderID: folderID), 3)

        var noisy = PhotoQuery()
        noisy.isoRanges = [6401...4_000_000]
        XCTAssertEqual(try store.photos(matching: noisy, folderID: folderID).map(\.id),
                       [ids[2]])

        // Two DISJOINT bands are a union, not the interval that spans them. The ISO
        // values in this folder are 100, 6400, 12800 and 200, so "≤ 400" and "≥ 6401"
        // must return the two low frames and the 12800 one, and must NOT return 6400.
        // Collapsing the chips to min...max returned all four.
        var disjoint = PhotoQuery()
        disjoint.isoRanges = [0...400, 6401...4_000_000]
        let matched = try store.photos(matching: disjoint, folderID: folderID).map(\.id)
        XCTAssertEqual(Set(matched), Set([ids[0], ids[3], ids[2]]),
                       "disjoint ISO bands did not stay disjoint")
        XCTAssertFalse(matched.contains(ids[1]),
                       "ISO 6400 sits in the gap between the two lit bands and was "
                           + "returned anyway — the bands were collapsed to their span")

        // Two criteria AND by default...
        var both = camera
        both.isoRanges = [6401...4_000_000]
        XCTAssertEqual(try store.countPhotos(matching: both, folderID: folderID), 1)

        // ...and OR when the bar's Any toggle is on (D39).
        both.matchAny = true
        XCTAssertEqual(try store.countPhotos(matching: both, folderID: folderID), 3)

        var wideOpen = PhotoQuery()
        wideOpen.lenses = ["FE 35mm F1.4 GM"]
        XCTAssertEqual(try store.photos(matching: wideOpen, folderID: folderID).map(\.id),
                       [ids[0]])

        // The chip's own menu: values with live counts, most-used first.
        let cameras = try store.facetCounts(.camera, folderID: folderID)
        XCTAssertEqual(cameras.first, FacetValue(value: "Sony A7 IV", count: 3))
        XCTAssertEqual(cameras.count, 2)
        XCTAssertEqual(try store.facetCounts(.lens, folderID: folderID).first,
                       FacetValue(value: "FE 85mm F1.4 GM", count: 3))
        store.close()
    }

    /// LIB-10: the text chip's fast path has to learn what the backfill learned.
    ///
    /// The FTS row is built at upsert time, minutes before any EXIF exists, so
    /// `camera` and `lens` were indexed as empty strings and stayed that way — while
    /// the chip's placeholder promises "Name, camera, keyword" and the FTS branch is
    /// preferred whenever FTS5 is compiled in. The LIKE fallback found "sony"; the
    /// fast path could not, which is the worst shape of this bug: the search got
    /// worse on the machines where it was supposed to get faster.
    func testTextSearchFindsACameraTheBackfillFilledInAfterTheScan() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 3)
        try XCTSkipUnless(store.isTextIndexAvailable,
                          "this SQLite has no FTS5, so the query under test is the "
                              + "LIKE fallback and proves nothing about the index")

        for (offset, id) in ids.enumerated() {
            try store.setMetadata(
                PhotoMetadata(camera: offset == 0 ? "Sony A7 IV" : "Nikon Z8",
                              lens: offset == 0 ? "FE 35mm F1.4 GM" : "Z 50mm f/1.8 S"),
                photoID: id)
        }

        var camera = PhotoQuery()
        camera.text = "sony"
        XCTAssertEqual(try store.photos(matching: camera, folderID: folderID).map(\.id),
                       [ids[0]],
                       "the text index never learned the camera the backfill wrote")

        var lens = PhotoQuery()
        lens.text = "35mm"
        XCTAssertEqual(try store.photos(matching: lens, folderID: folderID).map(\.id),
                       [ids[0]],
                       "the text index never learned the lens the backfill wrote")

        // The batch writer is the one the app actually calls, and it took a different
        // route into the same UPDATE — so it gets its own assertion rather than
        // trusting that the two paths stayed in step.
        try store.setMetadata([(photoID: ids[1], metadata: PhotoMetadata(camera: "Leica M11")),
                               (photoID: ids[2], metadata: PhotoMetadata(camera: "Leica Q3"))])
        var leica = PhotoQuery()
        leica.text = "leica"
        XCTAssertEqual(Set(try store.photos(matching: leica, folderID: folderID).map(\.id)),
                       Set([ids[1], ids[2]]),
                       "the batch metadata writer left the text index behind")

        // And the row it replaced must be gone: re-indexing has to be a replace, not
        // an append, or "nikon" keeps matching a photo that is now a Leica.
        var nikon = PhotoQuery()
        nikon.text = "nikon"
        XCTAssertTrue(try store.photos(matching: nikon, folderID: folderID).isEmpty,
                      "a stale camera survived in the text index after it was overwritten")
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

    // MARK: - Integrity and recovery (LIB-04)

    /// Overwrite the middle of a SQLite file with garbage, leaving the header intact so
    /// it still opens. That is what `PRAGMA quick_check` exists to notice, and it is a
    /// fair model of the damage a bad sector or a half-written page actually leaves.
    private func corrupt(_ path: String) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        XCTAssertGreaterThan(size, 40_000, "the seeded catalog is too small to damage")
        // Past the header and the schema, across several pages.
        try handle.seek(toOffset: 16_384)
        handle.write(Data(repeating: 0x5A, count: 16_384))
    }

    private func backupDirectory() -> URL {
        directory.appendingPathComponent("backups", isDirectory: true)
    }

    func testAnOpenTimeCheckPassesAHealthyCatalogWithoutTouchingIt() throws {
        let store = try makeStore()
        let (folderID, _) = try seed(store)
        store.close()

        let path = directory.appendingPathComponent("lumen.db").path
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let recovery = CatalogStore.recoverIfNeeded(
            path: path, backupDirectory: backupDirectory().path)

        XCTAssertEqual(recovery.outcome, .healthy)
        XCTAssertNil(recovery.notice, "a healthy catalog must not tell the user anything")
        XCTAssertFalse(recovery.isDamaged)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before,
                       "a passing check rewrote the catalog")

        let reopened = try makeStore()
        XCTAssertEqual(try reopened.photos(folderID: folderID).count, 5)
        reopened.close()
    }

    func testAFirstRunHasNothingToCheckAndSaysSo() {
        let recovery = CatalogStore.recoverIfNeeded(
            path: directory.appendingPathComponent("lumen.db").path,
            backupDirectory: backupDirectory().path)
        XCTAssertEqual(recovery.outcome, .firstRun)
        XCTAssertNil(recovery.notice)
        XCTAssertFalse(recovery.isDamaged)

        // A path that is not there must not probe as healthy. `SQLiteDatabase` opens
        // with SQLITE_OPEN_CREATE, so without the existence guard an absent file becomes
        // an empty database and passes `quick_check` — and a backup that vanished
        // between the directory listing and the probe would then be restored, empty,
        // over a catalog that was only damaged.
        XCTAssertFalse(CatalogStore.probeQuickCheck(
            path: directory.appendingPathComponent("never-existed.db").path),
                       "a missing file was reported as a readable catalog")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("never-existed.db").path),
                       "probing a missing path created a database at it")
    }

    /// The whole promise of §15.8 in one test: a catalog that fails its check at open is
    /// replaced by the newest backup that passes, the damaged file is kept, and the user
    /// is told afterwards.
    func testACorruptCatalogIsRestoredFromTheNewestBackupThatPasses() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backupDirectory(), withIntermediateDirectories: true)

        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        try store.setRating(4, photoID: ids[0])

        // Two backups. The newer one is deliberately unreadable, so a restore that
        // simply took the newest name would put a corrupt file back and the assertions
        // below would fail — the walk has to keep going.
        let older = backupDirectory().appendingPathComponent("lumen-2026-08-20T09-00-00Z.db")
        try store.backup(to: older.path)
        let newer = backupDirectory().appendingPathComponent("lumen-2026-08-21T09-00-00Z.db")
        try store.backup(to: newer.path)
        store.close()
        try corrupt(newer.path)

        let path = directory.appendingPathComponent("lumen.db").path
        try corrupt(path)
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: path),
                       "the damage did not take, so the rest of this test proves nothing")

        let recovery = CatalogStore.recoverIfNeeded(
            path: path, backupDirectory: backupDirectory().path)

        guard case .restored(let from, let setAside) = recovery.outcome else {
            return XCTFail("a corrupt catalog was not restored: \(recovery.outcome)")
        }
        XCTAssertEqual(URL(fileURLWithPath: from).lastPathComponent,
                       older.lastPathComponent,
                       "the restore took the newest NAME rather than the newest name "
                           + "that passes its own check")
        XCTAssertTrue(manager.fileExists(atPath: setAside),
                      "the damaged catalog was destroyed instead of set aside")
        XCTAssertNotNil(recovery.notice, "the user was not told the catalog was restored")
        XCTAssertFalse(recovery.isDamaged)

        // And the catalog the caller now opens is the backup, readable, with its rows.
        let reopened = try makeStore()
        XCTAssertTrue(try reopened.quickCheck())
        XCTAssertEqual(try reopened.photos(folderID: folderID).count, 5)
        reopened.close()
    }

    /// A restore must not leave the damaged catalog's WAL beside the snapshot that
    /// replaced it: SQLite would replay that journal straight back over the good file,
    /// which turns a successful restore into data loss with no error anywhere.
    ///
    /// This pins the OUTCOME, not one mechanism, and the distinction is worth stating.
    /// Measured on this platform, SQLite's own close-time cleanup during the integrity
    /// probe removes `-wal` and `-shm` before the restore reaches them, so the rename in
    /// `setAsideCatalog` is the fallback for the case the probe could not open the file
    /// at all — a case this test does not reach. What it does assert is the thing the
    /// user's data depends on, under whichever mechanism gets there first.
    func testARestoreLeavesNoStaleJournalBesideTheCatalogItPutBack() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backupDirectory(), withIntermediateDirectories: true)
        let store = try makeStore()
        let (folderID, _) = try seed(store)
        let backup = backupDirectory().appendingPathComponent("lumen-2026-08-20T09-00-00Z.db")
        try store.backup(to: backup.path)
        store.close()

        let path = directory.appendingPathComponent("lumen.db").path
        try corrupt(path)
        // A leftover WAL from the damaged catalog, of the kind a crash leaves behind.
        try Data(repeating: 0x11, count: 4096).write(to: URL(fileURLWithPath: path + "-wal"))

        let recovery = CatalogStore.recoverIfNeeded(
            path: path, backupDirectory: backupDirectory().path)
        guard case .restored = recovery.outcome else {
            return XCTFail("a corrupt catalog was not restored: \(recovery.outcome)")
        }
        XCTAssertFalse(manager.fileExists(atPath: path + "-wal"),
                       "the damaged catalog's WAL was left beside the restored one, "
                           + "where SQLite will replay it over the snapshot")
        XCTAssertFalse(manager.fileExists(atPath: path + "-shm"),
                       "the damaged catalog's shared-memory file outlived it")

        // And the restored catalog still reads, which is the only way to know the
        // journal did not come back through it.
        let reopened = try makeStore()
        XCTAssertTrue(try reopened.quickCheck())
        XCTAssertEqual(try reopened.photos(folderID: folderID).count, 5)
        reopened.close()
    }

    /// No backup that passes means nothing is moved and nothing is replaced. The caller
    /// opens the file it was always going to open — and now it knows.
    func testACorruptCatalogWithNoUsableBackupIsReportedAndLeftAlone() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backupDirectory(), withIntermediateDirectories: true)
        let store = try makeStore()
        _ = try seed(store)
        let backup = backupDirectory().appendingPathComponent("lumen-2026-08-20T09-00-00Z.db")
        try store.backup(to: backup.path)
        store.close()
        try corrupt(backup.path)

        let path = directory.appendingPathComponent("lumen.db").path
        try corrupt(path)
        let damaged = try Data(contentsOf: URL(fileURLWithPath: path))

        let recovery = CatalogStore.recoverIfNeeded(
            path: path, backupDirectory: backupDirectory().path)
        XCTAssertEqual(recovery.outcome, .unrecoverable(backupsTried: 1))
        XCTAssertTrue(recovery.isDamaged)
        XCTAssertNotNil(recovery.notice)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), damaged,
                       "a catalog that could not be restored was modified anyway")
        XCTAssertTrue(manager.fileExists(atPath: backup.path),
                      "a backup that failed its check was deleted rather than skipped")
    }

    /// `integrityCheck` gates the backup, and this is what it is for: a corrupt catalog
    /// that backs itself up rotates the last readable snapshot out of existence, and
    /// then there is nothing left for `recoverIfNeeded` to restore from.
    func testAFullIntegrityCheckAnswersForBothAHealthyAndADamagedCatalog() throws {
        let store = try makeStore()
        _ = try seed(store)
        XCTAssertTrue(try store.integrityCheck())
        XCTAssertTrue(try store.quickCheck())
        store.close()

        let path = directory.appendingPathComponent("lumen.db").path
        try corrupt(path)
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: path))

        let damaged = try CatalogStore(path: path, cachePath: nil)
        XCTAssertFalse(try damaged.integrityCheck(),
                       "the pre-backup gate passed a catalog SQLite cannot read")
        damaged.close()
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

    // MARK: - Move safety (LIB-01)

    /// `quick_sig` had a column, an index and a whole relocation branch in `scan`, and
    /// no producer anywhere: every `ScannedFile` was built with `quickSig == nil`, the
    /// match always saw nil, and a renamed original became a fresh row while its rating,
    /// flag, label, album membership, keywords, edits and history stayed stranded on a
    /// row marked missing. No test in this file could fail, because none had ever passed
    /// a signature into `scan` — the relocation branch was untested code guarding an
    /// unwritten column.
    ///
    /// These two are the proof that the branch reaches the work in the sense docs/20 P1
    /// means it: from a signature the producer really computes, through the store, to
    /// the row the edits are on.
    func testARenameInsideAFolderRelocatesTheRowWithItsEditsIntact() throws {
        let store = try makeStore()
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")
        let signature = QuickSignature.signature(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                                 fileSize: 41_000_000)

        let original = ScannedFile(filename: "DSC0001.ARW", fileSize: 41_000_000,
                                   fileMTime: 1_700_000_000, quickSig: signature,
                                   ext: "arw")
        _ = try store.scan(folderID: folderID, files: [original], at: CatalogStore.now())
        guard let row = try store.photo(folderID: folderID, filename: "DSC0001.ARW")
        else { return XCTFail("the scan did not insert the file") }

        // A frame with a day's work on it.
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.25
        try store.saveRecipe(recipe, photoID: row.id, isCurrent: true)
        try store.setRating(4, photoID: row.id)
        try store.setFlag(.pick, photoID: row.id)
        let album = try store.createCollection(name: "Selects")
        try store.addToCollection(album, photoIDs: [row.id])
        _ = try store.addKeyword("harbour", photoIDs: [row.id])

        // The user renames it in Finder. Same bytes, same size, new name.
        let renamed = ScannedFile(filename: "harbour-dawn.ARW", fileSize: 41_000_000,
                                  fileMTime: 1_700_000_000, quickSig: signature,
                                  ext: "arw")
        let result = try store.scan(folderID: folderID, files: [renamed],
                                    at: CatalogStore.now())

        XCTAssertEqual(result.relocated, [row.id],
                       "a rename was not recognised as a relocation")
        XCTAssertTrue(result.added.isEmpty, "the rename inserted a second photo row")
        XCTAssertTrue(result.missing.isEmpty, "the renamed original was marked missing")

        guard let moved = try store.photo(folderID: folderID,
                                          filename: "harbour-dawn.ARW")
        else { return XCTFail("the renamed file has no row") }
        XCTAssertEqual(moved.id, row.id, "the work moved to a different row")
        XCTAssertFalse(moved.missing)
        XCTAssertEqual(moved.rating, 4)
        XCTAssertEqual(moved.flag, .pick)
        XCTAssertEqual(try store.currentRecipe(photoID: moved.id), recipe,
                       "the rename lost the edit")
        XCTAssertEqual(try store.keywords(photoID: moved.id), ["harbour"])

        var inAlbum = PhotoQuery()
        inAlbum.albumID = album
        XCTAssertEqual(try store.photos(matching: inAlbum, folderID: folderID).map(\.id),
                       [row.id], "the rename dropped the album membership")

        // And nothing was left behind: one row, not two.
        XCTAssertEqual(try store.photos(folderID: folderID).count, 1)
        store.close()
    }

    /// The cross-folder half. Here the row is already `missing = 1` from the scan of the
    /// folder the file left, and the scan of the folder it arrived in has to find it by
    /// signature alone — no filename in common, no shared folder id.
    func testAMoveAcrossFoldersRelocatesTheRowWithItsEditsIntact() throws {
        let store = try makeStore()
        let source = try store.registerFolder(path: "/Volumes/Shoots/inbox")
        let destination = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")
        let signature = QuickSignature.signature(prefix: Data([0x01, 0x02, 0x03]),
                                                 fileSize: 52_000_000)

        let arrived = ScannedFile(filename: "DSC0007.ARW", fileSize: 52_000_000,
                                  fileMTime: 1_700_000_500, quickSig: signature,
                                  ext: "arw")
        _ = try store.scan(folderID: source, files: [arrived], at: CatalogStore.now())
        guard let row = try store.photo(folderID: source, filename: "DSC0007.ARW")
        else { return XCTFail("the scan did not insert the file") }

        var recipe = Recipe()
        recipe.develop.tone.exposure = -0.75
        try store.saveRecipe(recipe, photoID: row.id, isCurrent: true)
        try store.setRating(5, photoID: row.id)
        try store.setLabel(.red, photoID: row.id)

        // Scanning the source folder empty is what marks the row missing — exactly what
        // the launch after the file was dragged out of it does.
        let emptied = try store.scan(folderID: source, files: [], at: CatalogStore.now())
        XCTAssertEqual(emptied.missing, [row.id])

        // The same bytes, under a new name, in a different registered folder.
        let moved = ScannedFile(filename: "keepers/DSC0007.ARW", fileSize: 52_000_000,
                                fileMTime: 1_700_000_500, quickSig: signature,
                                ext: "arw")
        let result = try store.scan(folderID: destination, files: [moved],
                                    at: CatalogStore.now())

        XCTAssertEqual(result.relocated, [row.id],
                       "a move across folders was not recognised as a relocation")
        XCTAssertTrue(result.added.isEmpty, "the move inserted a second photo row")

        guard let landed = try store.photo(folderID: destination,
                                           filename: "keepers/DSC0007.ARW")
        else { return XCTFail("the moved file has no row in its new folder") }
        XCTAssertEqual(landed.id, row.id)
        XCTAssertEqual(landed.folderID, destination)
        XCTAssertFalse(landed.missing, "the moved file is still marked missing")
        XCTAssertEqual(landed.rating, 5)
        XCTAssertEqual(landed.label, "red")
        XCTAssertEqual(try store.currentRecipe(photoID: landed.id), recipe,
                       "the move lost the edit")
        XCTAssertNil(try store.photo(folderID: source, filename: "DSC0007.ARW"),
                     "the row stayed behind in the folder the file left")
        store.close()
    }

    /// What the producer actually hashes. A signature that ignored the length would give
    /// a truncated copy the same identity as the file it was truncated from, and the
    /// relocation branch would then move a shoot's edits onto the wrong frame.
    func testAQuickSignatureNamesItsAlgorithmAndCoversLengthAsWellAsPrefix() throws {
        let head = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x11])

        let a = QuickSignature.signature(prefix: head, fileSize: 41_000_000)
        XCTAssertEqual(a, QuickSignature.signature(prefix: head, fileSize: 41_000_000),
                       "the signature is not deterministic")
        XCTAssertTrue(a.hasPrefix("xxh64:"),
                      "the algorithm has to name itself, exactly as recipe_fp does")
        XCTAssertEqual(a.count, "xxh64:".count + 16)

        // Same prefix, different length: a truncated copy must not share an identity.
        XCTAssertNotEqual(a, QuickSignature.signature(prefix: head, fileSize: 41_000_001))
        // Same length, different prefix.
        let nudged = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x12])
        XCTAssertNotEqual(a, QuickSignature.signature(prefix: nudged,
                                                      fileSize: 41_000_000))

        // The file-reading half agrees with the pure half, stops at the cap, and takes
        // the length from the whole file rather than from what it read. A file of
        // 1 MB + 32 bytes proves both at once.
        let big = directory.appendingPathComponent("big.arw")
        var bytes = Data(repeating: 0x5A, count: QuickSignature.prefixByteCount)
        bytes.append(Data(repeating: 0x7E, count: 32))
        try bytes.write(to: big)
        XCTAssertEqual(try QuickSignature.compute(url: big),
                       QuickSignature.signature(
                        prefix: bytes.prefix(QuickSignature.prefixByteCount),
                        fileSize: Int64(bytes.count)),
                       "compute(url:) does not agree with signature(prefix:fileSize:)")

        // Two files differing only past the first megabyte hash the same. That is the
        // declared cost of reading a prefix, and it is why `scan` still requires a
        // candidate to have disappeared before it will move anything.
        let sibling = directory.appendingPathComponent("sibling.arw")
        var other = Data(repeating: 0x5A, count: QuickSignature.prefixByteCount)
        other.append(Data(repeating: 0x01, count: 32))
        try other.write(to: sibling)
        XCTAssertEqual(try QuickSignature.compute(url: big),
                       try QuickSignature.compute(url: sibling))
    }

    /// The producer only hashes what could match, because a megabyte of every file in a
    /// 5,000-frame folder is gigabytes of I/O in front of the first grid — the one path
    /// docs/10 §10.1 gates under a second.
    func testTheRelocationProbeOffersNothingToHashOnAFirstOpen() throws {
        let store = try makeStore()
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")

        // Nothing registered yet: nothing known, nothing to match, nothing to hash.
        let cold = try store.relocationProbe(folderID: folderID, listed: ["DSC0001.ARW"])
        XCTAssertTrue(cold.known.isEmpty)
        XCTAssertTrue(cold.candidateSizes.isEmpty,
                      "a first open would have hashed the whole card")

        let files = (0..<3).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0), fileMTime: 1_700_000_000,
                        quickSig: String(format: "xxh64:%016x", $0 + 1), ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())

        // Everything still present: known, and still nothing to hash.
        let steady = try store.relocationProbe(
            folderID: folderID, listed: Set(files.map(\.filename)))
        XCTAssertEqual(steady.known, Set(files.map(\.filename)))
        XCTAssertTrue(steady.candidateSizes.isEmpty,
                      "an unchanged folder would have hashed on every open")

        // One name gone from the listing: that row's size, and only that one, becomes
        // worth hashing for.
        let renamed = try store.relocationProbe(
            folderID: folderID, listed: ["DSC0001.ARW", "DSC0002.ARW", "new.ARW"])
        XCTAssertEqual(renamed.candidateSizes, [40_000_000])
        XCTAssertFalse(renamed.known.contains("new.ARW"))

        // A row missing in ANOTHER folder is a candidate for this one, which is what
        // makes a cross-folder move detectable at all.
        let elsewhere = try store.registerFolder(path: "/Volumes/Shoots/inbox")
        _ = try store.scan(folderID: elsewhere,
                           files: [ScannedFile(filename: "gone.ARW",
                                               fileSize: 99_000_000,
                                               fileMTime: 1_700_000_000,
                                               quickSig: "xxh64:00000000000000ff",
                                               ext: "arw")],
                           at: CatalogStore.now())
        _ = try store.scan(folderID: elsewhere, files: [], at: CatalogStore.now())
        let across = try store.relocationProbe(
            folderID: folderID, listed: Set(files.map(\.filename)))
        XCTAssertEqual(across.candidateSizes, [99_000_000])
        store.close()
    }

    /// LIB-26a. The backfill asked once, with a 5,000 default limit, and never asked
    /// again — a 20,000-frame folder needed four launches before its sort order was
    /// right. Paging by id is what makes the caller's loop both complete and finite: a
    /// photo whose EXIF cannot be read keeps `capture_at IS NULL` forever, so a loop
    /// that re-asked for "everything still missing" would never end.
    func testTheBackfillPassesPageForwardPastRowsTheyCannotFillIn() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store, count: 5)

        let firstPage = try store.photosMissingMetadata(folderID: folderID, limit: 2)
        XCTAssertEqual(firstPage.map(\.id), Array(ids.prefix(2)))

        // The page after the second row, with NOTHING written in between — two files
        // whose EXIF would not parse. It must move on, not repeat.
        let secondPage = try store.photosMissingMetadata(
            folderID: folderID, afterID: firstPage[1].id, limit: 2)
        XCTAssertEqual(secondPage.map(\.id), Array(ids[2..<4]))

        let thirdPage = try store.photosMissingMetadata(
            folderID: folderID, afterID: secondPage[1].id, limit: 2)
        XCTAssertEqual(thirdPage.map(\.id), [ids[4]])
        XCTAssertTrue(try store.photosMissingMetadata(
            folderID: folderID, afterID: ids[4], limit: 2).isEmpty,
                      "the pass would not terminate")

        // The signature backfill is the same shape with its own resume marker, and it
        // is the writer `quick_sig` never had.
        XCTAssertEqual(try store.photosMissingQuickSig(folderID: folderID).map(\.id), ids)
        try store.setQuickSig("xxh64:0123456789abcdef", photoID: ids[0])
        XCTAssertEqual(try store.photosMissingQuickSig(folderID: folderID).map(\.id),
                       Array(ids.dropFirst()))
        XCTAssertEqual(try store.photo(folderID: folderID,
                                       filename: "DSC0000.ARW")?.quickSig,
                       "xxh64:0123456789abcdef")
        store.close()
    }

    // MARK: - Raw-truth statistics (`cache.raw_stats`)

    /// A measurement worth 150–400 ms of decode has to survive a relaunch, or the
    /// second look at a photograph pays for it again. The table has existed since the
    /// first schema with nothing writing to it; these are the tests behind the writer.
    private func measurement(
        clippedR: Double = 2.1,
        provenance: RawStatistics.Provenance = .sceneLinearDecode,
        revision: UInt16 = RawStatistics.currentAnalyzerRevision) -> RawStatistics {
        RawStatistics(bins: (0..<(RawStatistics.channelCount * RawStatistics.binCount))
                          .map { UInt32($0 * 7 + 3) },
                      clippedHighPercent: [clippedR, 0.25, 0.5, 0.75],
                      nearClippedHighPercent: [4.5, 5.5, 6.5, 7.5],
                      clippedLowPercent: [0.125, 0.25, 0.375, 0.5],
                      nearClippedLowPercent: [1.5, 2.5, 3.5, 4.5],
                      sampleCount: 2_796_032,
                      subsample: 4,
                      blackLevel: 512,
                      saturation: [16383, 16383, 16383, 16383],
                      analyzerRevision: revision,
                      sourceIsCFA: provenance == .sensorCFA,
                      provenance: provenance)
    }

    func testRawStatisticsSurviveAReopen() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }

        XCTAssertNil(try store.rawStatistics(photoID: photo,
                                             provenance: .sceneLinearDecode),
                     "an unmeasured photo must not report a cached measurement")

        let stats = measurement()
        XCTAssertTrue(try store.recordRawStatistics(stats, photoID: photo))
        store.close()

        let reopened = try makeStore()
        guard let read = try reopened.rawStatistics(photoID: photo,
                                                    provenance: .sceneLinearDecode) else {
            return XCTFail("the measurement did not survive the reopen")
        }
        XCTAssertEqual(read.bins, stats.bins)
        XCTAssertEqual(read.sampleCount, stats.sampleCount)
        XCTAssertEqual(read.subsample, 4)
        XCTAssertEqual(read.provenance, .sceneLinearDecode)
        for channel in 0..<4 {
            XCTAssertEqual(read.clippedHighPercent[channel],
                           stats.clippedHighPercent[channel], accuracy: 1e-4)
            XCTAssertEqual(read.nearClippedLowPercent[channel],
                           stats.nearClippedLowPercent[channel], accuracy: 1e-4)
        }

        // And the JSON column, which had no writer either. It is the cheap read: the
        // percentages without decoding 2 KB of bins.
        let json = try reopened.rawStatisticsClippedJSON(photoID: photo)
        XCTAssertEqual(json, stats.clippedPercentJSON)
        XCTAssertTrue(json?.contains("\"high\":2.1000") ?? false, json ?? "nil")
        XCTAssertTrue(json?.contains("\"nearLow\":4.5000") ?? false, json ?? "nil")
        reopened.close()
    }

    func testRecordingTwiceReplacesRatherThanFailing() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }

        try store.recordRawStatistics(measurement(clippedR: 2.1), photoID: photo)
        try store.recordRawStatistics(measurement(clippedR: 9.5), photoID: photo)
        let read = try store.rawStatistics(photoID: photo, provenance: .sceneLinearDecode)
        XCTAssertEqual(read?.clippedHighPercent[0] ?? 0, 9.5, accuracy: 1e-4,
                       "a recompute must replace the row, not lose to it")
        store.close()
    }

    func testAStaleAnalyzerRevisionReadsAsMissingRatherThanAsAnAnswer() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }

        let old: UInt16 = RawStatistics.currentAnalyzerRevision &- 1
        try store.recordRawStatistics(measurement(revision: old), photoID: photo)

        XCTAssertNil(try store.rawStatistics(photoID: photo,
                                             provenance: .sceneLinearDecode),
                     "a row binned by a different analyzer is not this build's answer")
        XCTAssertNotNil(try store.rawStatistics(photoID: photo, revision: old,
                                                provenance: .sceneLinearDecode),
                        "and it is still readable by anything that asks for that "
                            + "revision, or the check is just a delete")

        // Which is what makes a revision bump a recompute: the backlog query sees it.
        XCTAssertTrue(try store.photosMissingRawStatistics(folderID: folderID)
            .contains(photo))
        store.close()
    }

    func testARowMeasuredOnSomethingElseIsNotAnAnswerEither() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }

        try store.recordRawStatistics(measurement(provenance: .renderedProxy),
                                      photoID: photo)
        XCTAssertNil(try store.rawStatistics(photoID: photo,
                                             provenance: .sceneLinearDecode),
                     "a measurement of the rendered picture must not be served to a "
                         + "caller asking for the scene-linear one — that is the "
                         + "histogram this instrument exists to beat, handed over "
                         + "under the better name")
        XCTAssertNotNil(try store.rawStatistics(photoID: photo,
                                                provenance: .renderedProxy))
        store.close()
    }

    func testAMeasurementThatCannotSayWhatItMeasuredIsNotCached() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }

        XCTAssertFalse(try store.recordRawStatistics(measurement(provenance: .unspecified),
                                                     photoID: photo),
                       "an unlabelled measurement was accepted into the cache")
        XCTAssertNil(try store.rawStatisticsClippedJSON(photoID: photo))
        XCTAssertTrue(try store.photosMissingRawStatistics(folderID: folderID)
            .contains(photo),
                      "and the photo stays on the worker's queue, so the honest "
                          + "measurement still gets taken")
        store.close()
    }

    func testTheBacklogQueryPagesAndTerminates() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        XCTAssertEqual(try store.photosMissingRawStatistics(folderID: folderID), ids)

        let first = try store.photosMissingRawStatistics(folderID: folderID, limit: 2)
        XCTAssertEqual(first, Array(ids.prefix(2)))
        let second = try store.photosMissingRawStatistics(folderID: folderID,
                                                          afterID: first[1], limit: 2)
        XCTAssertEqual(second, Array(ids[2..<4]))

        for id in ids { try store.recordRawStatistics(measurement(), photoID: id) }
        XCTAssertTrue(try store.photosMissingRawStatistics(folderID: folderID).isEmpty,
                      "the worker would never stop")
        store.close()
    }

    func testAMissingFileIsNotQueuedForMeasurement() throws {
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }
        try store.setMissing(true, photoID: photo)
        XCTAssertFalse(try store.photosMissingRawStatistics(folderID: folderID)
            .contains(photo),
                       "a worker cannot decode a file that is not there, and a queue "
                           + "that keeps handing it one never drains")
        store.close()
    }

    func testDeletingAPhotoTakesItsMeasurementWithIt() throws {
        let store = try makeStore()
        let (_, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }
        try store.recordRawStatistics(measurement(), photoID: photo)
        _ = try store.deletePhoto(id: photo)
        XCTAssertNil(try store.rawStatisticsClippedJSON(photoID: photo),
                     "the row outlived the photograph, so the next photo to take that "
                         + "id would inherit somebody else's histogram")
        store.close()
    }

    func testACorruptBlobReadsAsMissingRatherThanThrowing() throws {
        // cache.db is disposable and self-healing (D52). A truncated or garbage blob is
        // a recompute, never an error the user sees.
        let store = try makeStore()
        let (folderID, ids) = try seed(store)
        guard let photo = ids.first else { return XCTFail("no photos seeded") }
        try store.recordRawStatistics(measurement(), photoID: photo)
        let cachePath = store.cachePath
        store.close()

        // Corrupted from outside, the way a truncated write or a bad sector would.
        let cache = try SQLiteDatabase(path: cachePath)
        try cache.run("UPDATE raw_stats SET bins = ? WHERE photo_id = ?;",
                      [.blob(Data([0x00, 0x01, 0x02])), .integer(photo)])
        cache.close()

        let reopened = try makeStore()
        XCTAssertNil(try reopened.rawStatistics(photoID: photo,
                                                provenance: .sceneLinearDecode),
                     "a blob that does not decode was served as a measurement")
        XCTAssertFalse(try reopened.photosMissingRawStatistics(folderID: folderID)
            .contains(photo),
                       "the row is present at the right revision, so the backlog query "
                           + "cannot see it — the reader is what heals this, which is "
                           + "why the reader decodes rather than trusting the column")
        reopened.close()
    }
}

#endif
