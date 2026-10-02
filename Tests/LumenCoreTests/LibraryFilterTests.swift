// LibraryFilterTests.swift
// The library query grammar, pinned on the lane that actually runs.
//
// docs/10 §10.8 and D39 state one boolean rule and treat it as a product
// differentiator: **multi-value within one criterion is OR, criteria AND with each
// other, and the All/Any toggle flips only the join BETWEEN criteria.** Until this file
// existed, none of that was asserted anywhere — `LibraryFilter` lived in
// `LumenApp/AppState.swift` behind `#if os(macOS)`, so the Linux lane where every other
// rule in this project is pinned never even compiled it.
//
// First written against the grammar of late August (36354d7, never landed), and ported
// to the grammar as it stands now: the filter has since gained `hiddenCriteriaCount` for
// the Filter button's badge, and its sentence moved to the status bar. Both are pinned
// below beside the rules the original file pinned.
//
// Deliberately not gated on `canImport(SQLite3)`: `PhotoQuery` and the two vocabulary
// enums are declared above that gate in `CatalogStore.swift`, so the grammar is
// checkable even in the configuration that has no catalog at all.

import XCTest
@testable import LumenCore

final class LibraryFilterTests: XCTestCase {

    /// The five things the memory path can ask a photo. A struct rather than the app's
    /// `PhotoItem`, which is what `LibraryFilterable` exists to make possible.
    private struct TestPhoto: LibraryFilterable {
        var flag: PhotoFlag = .unflagged
        var rating: Int = 0
        var label: ColorLabel?
        var isRaw: Bool = false
        var filename: String = "DSC_0001.jpg"
    }

    // MARK: - OR within a criterion

    func testMultipleValuesInOneCriterionOr() {
        var filter = LibraryFilter()
        filter.flags = [.pick, .reject]

        XCTAssertTrue(filter.matches(TestPhoto(flag: .pick)))
        XCTAssertTrue(filter.matches(TestPhoto(flag: .reject)))
        XCTAssertFalse(filter.matches(TestPhoto(flag: .unflagged)),
                       "two lit flag chips means picked OR rejected — not everything")
    }

    func testMultipleLabelsInOneCriterionOr() {
        var filter = LibraryFilter()
        filter.labels = [.red, .blue]

        XCTAssertTrue(filter.matches(TestPhoto(label: .red)))
        XCTAssertTrue(filter.matches(TestPhoto(label: .blue)))
        XCTAssertFalse(filter.matches(TestPhoto(label: .green)))
        XCTAssertFalse(filter.matches(TestPhoto(label: nil)))
    }

    /// The Unlabelled chip ORs into the colour criterion rather than forming a second
    /// one — it is one more answer to "what label?", not a separate question.
    func testUnlabelledOrsWithTheColoursRatherThanAndingAgainstThem() {
        var filter = LibraryFilter()
        filter.labels = [.red]
        filter.includeUnlabeled = true

        XCTAssertTrue(filter.matches(TestPhoto(label: .red)))
        XCTAssertTrue(filter.matches(TestPhoto(label: nil)))
        XCTAssertFalse(filter.matches(TestPhoto(label: .green)))
        XCTAssertEqual(filter.activeCriteriaCount, 1,
                       "colour and unlabelled are one criterion, not two")
    }

    func testUnlabelledAloneMatchesOnlyUnlabelled() {
        var filter = LibraryFilter()
        filter.includeUnlabeled = true

        XCTAssertTrue(filter.matches(TestPhoto(label: nil)))
        XCTAssertFalse(filter.matches(TestPhoto(label: .red)))
    }

    // MARK: - AND across criteria

    func testCriteriaAndWithEachOther() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 3

        XCTAssertTrue(filter.matches(TestPhoto(flag: .pick, rating: 4)))
        XCTAssertFalse(filter.matches(TestPhoto(flag: .pick, rating: 2)),
                       "a picked 2-star fails the rating criterion")
        XCTAssertFalse(filter.matches(TestPhoto(flag: .unflagged, rating: 4)),
                       "an unflagged 4-star fails the flag criterion")
    }

    func testEveryMemoryCriterionMustPass() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 2
        filter.labels = [.red]
        filter.rawOnly = true
        filter.text = "beach"

        let passing = TestPhoto(flag: .pick, rating: 3, label: .red,
                                isRaw: true, filename: "beach-042.arw")
        XCTAssertTrue(filter.matches(passing))

        var failsOne = passing
        failsOne.isRaw = false
        XCTAssertFalse(filter.matches(failsOne), "one failed criterion fails the whole")
    }

    func testTextMatchIsCaseInsensitiveAndPartial() {
        var filter = LibraryFilter()
        filter.text = "BEACH"
        XCTAssertTrue(filter.matches(TestPhoto(filename: "seaside-beach-042.arw")))
        XCTAssertFalse(filter.matches(TestPhoto(filename: "forest-042.arw")))
    }

    // MARK: - matchAny flips only the outer join

    /// The toggle changes the join BETWEEN criteria and nothing else. Compiled with it
    /// off and on, every field of the query is identical except `matchAny` itself — in
    /// particular the two flags stay two flags and the two ISO bands stay two ranges,
    /// because OR-within-a-criterion is not the toggle's business.
    func testMatchAnyChangesTheOuterJoinAndNothingElse() {
        var all = fullyLoadedFilter()
        all.matchAny = false
        var any = fullyLoadedFilter()
        any.matchAny = true

        let allQuery = all.query(sortKey: .captureTime, ascending: true, albumID: nil)
        let anyQuery = any.query(sortKey: .captureTime, ascending: true, albumID: nil)

        XCTAssertFalse(allQuery.matchAny)
        XCTAssertTrue(anyQuery.matchAny)

        XCTAssertEqual(allQuery.flags, anyQuery.flags)
        XCTAssertEqual(allQuery.flags.count, 2, "the flag criterion still holds both values")
        XCTAssertEqual(allQuery.labels, anyQuery.labels)
        XCTAssertEqual(allQuery.includeUnlabeled, anyQuery.includeUnlabeled)
        XCTAssertEqual(allQuery.isoRanges, anyQuery.isoRanges)
        XCTAssertEqual(allQuery.isoRanges.count, 2, "the ISO criterion still holds both bands")
        XCTAssertEqual(allQuery.cameras, anyQuery.cameras)
        XCTAssertEqual(allQuery.lenses, anyQuery.lenses)
        XCTAssertEqual(allQuery.keywords, anyQuery.keywords)
        XCTAssertEqual(allQuery.fileTypes, anyQuery.fileTypes)
        XCTAssertEqual(allQuery.rating, anyQuery.rating)
        XCTAssertEqual(allQuery.edited, anyQuery.edited)
        XCTAssertEqual(allQuery.text, anyQuery.text)
        XCTAssertEqual(allQuery.stackState, anyQuery.stackState)
    }

    /// Inside a criterion the sentence says "or" whatever the toggle says; only the glue
    /// between criteria moves.
    func testMatchAnyChangesOnlyTheGlueInTheSentence() {
        var filter = LibraryFilter()
        filter.flags = [.pick, .reject]
        filter.minRating = 3

        XCTAssertEqual(filter.sentence(catalogLive: true),
                       "Picked or Rejected  and  ★ 3 or better")
        filter.matchAny = true
        XCTAssertEqual(filter.sentence(catalogLive: true),
                       "Picked or Rejected  or  ★ 3 or better")
    }

    /// The memory path honours the toggle. It used to AND every criterion whatever the
    /// toggle said, so with no catalog the grid answered "picked AND ★4" under a
    /// sentence reading "Picked  or  ★ 4 or better".
    func testMatchAnyIsHonouredByTheMemoryPath() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 4
        filter.matchAny = true

        XCTAssertTrue(filter.matches(TestPhoto(flag: .pick, rating: 1)),
                      "picked passes the flag criterion, which is enough under Any")
        XCTAssertTrue(filter.matches(TestPhoto(flag: .unflagged, rating: 5)),
                      "★5 passes the rating criterion, which is enough under Any")
        XCTAssertFalse(filter.matches(TestPhoto(flag: .reject, rating: 1)),
                       "a photo that passes no lit criterion still fails")
    }

    /// Under Any, the label criterion is still ONE criterion — colours and Unlabelled
    /// OR inside it — and a criterion that is not lit is not a reason to pass.
    func testMatchAnyCountsOnlyLitCriteria() {
        var filter = LibraryFilter()
        filter.labels = [.red]
        filter.includeUnlabeled = true
        filter.rawOnly = true
        filter.matchAny = true

        XCTAssertTrue(filter.matches(TestPhoto(label: nil, isRaw: false)))
        XCTAssertTrue(filter.matches(TestPhoto(label: .red, isRaw: false)))
        XCTAssertTrue(filter.matches(TestPhoto(label: .blue, isRaw: true)))
        XCTAssertFalse(filter.matches(TestPhoto(flag: .pick, rating: 5, label: .blue,
                                                isRaw: false)),
                       "flag and rating are not lit, so passing them counts for nothing")

        var empty = LibraryFilter()
        empty.matchAny = true
        XCTAssertTrue(empty.matches(TestPhoto()), "no criterion lit, nothing to fail")
    }

    func testTheCompiledQueryCarriesTheToggleToSQL() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 4
        XCTAssertFalse(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).matchAny)
        filter.matchAny = true
        XCTAssertTrue(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).matchAny)
    }

    // MARK: - activeCriteriaCount counts criteria, not lit chips

    func testThreeLitFlagChipsAreOneCriterion() {
        var filter = LibraryFilter()
        filter.flags = [.pick, .reject, .unflagged]

        XCTAssertEqual(filter.activeCriteriaCount, 1,
                       "three chips OR into one question about the flag")
        XCTAssertTrue(filter.isActive)
    }

    func testEachCriterionCountsOnce() {
        XCTAssertEqual(LibraryFilter().activeCriteriaCount, 0)
        XCTAssertFalse(LibraryFilter().isActive)

        XCTAssertEqual(fullyLoadedFilter().activeCriteriaCount, 14,
                       "every criterion the filter has, each counted once")
    }

    func testIsActiveAgreesWithTheCount() {
        for (name, mutate) in Self.everyCriterion {
            var filter = LibraryFilter()
            mutate(&filter)
            XCTAssertEqual(filter.activeCriteriaCount, 1, "\(name) is one criterion")
            XCTAssertTrue(filter.isActive, "\(name) makes the filter active")
        }
    }

    // MARK: - hiddenCriteriaCount badges what the strip does not already show

    /// Search text has its own field in the strip, with its contents visible and its own
    /// ✕; every other criterion lives behind the Filter button. The badge counts only
    /// those, so typing in the search box never sends anyone into an empty popover.
    func testSearchTextIsTheOnlyCriterionTheBadgeDoesNotCount() {
        for (name, mutate) in Self.everyCriterion {
            var filter = LibraryFilter()
            mutate(&filter)
            XCTAssertEqual(filter.hiddenCriteriaCount, name == "text" ? 0 : 1, name)
        }
        XCTAssertEqual(fullyLoadedFilter().hiddenCriteriaCount, 13,
                       "everything but the search text, each criterion once")
    }

    func testTheBadgeCountsCriteriaNotChips() {
        var filter = LibraryFilter()
        filter.labels = [.red, .green]
        filter.includeUnlabeled = true
        filter.isoBands = [.upTo400, .above6400]
        XCTAssertEqual(filter.hiddenCriteriaCount, 2,
                       "three label chips and two ISO chips are two criteria")
    }

    /// A rating of 0 is "no constraint", not "at least zero stars" — the filter is not
    /// active merely because the slider exists.
    func testZeroRatingIsNotACriterion() {
        var filter = LibraryFilter()
        filter.minRating = 0
        XCTAssertEqual(filter.activeCriteriaCount, 0)
    }

    // MARK: - usesCatalogOnlyCriteria is exactly what matches() cannot answer

    /// The sharp version of the claim. For every criterion in turn: either the memory
    /// path visibly responds to it — some sample photo changes verdict — and it is not
    /// catalog-only, or the memory path is blind to it for every sample and it is.
    ///
    /// This is what makes the filter bar's rule ("a chip the running configuration
    /// cannot honour is not drawn") checkable. Adding a criterion and forgetting to
    /// classify it fails here rather than shipping a chip that quietly does nothing.
    func testCatalogOnlyCriteriaAreExactlyTheOnesTheMemoryPathIgnores() {
        let samples = [
            TestPhoto(flag: .pick, rating: 5, label: .red, isRaw: true, filename: "a.arw"),
            TestPhoto(flag: .reject, rating: 0, label: nil, isRaw: false, filename: "b.jpg"),
            TestPhoto(flag: .unflagged, rating: 3, label: .blue, isRaw: true, filename: "c.dng"),
        ]

        for (name, mutate) in Self.everyCriterion {
            var filter = LibraryFilter()
            mutate(&filter)

            let unfiltered = samples.map { LibraryFilter().matches($0) }
            let filtered = samples.map { filter.matches($0) }
            let memoryPathResponds = unfiltered != filtered

            XCTAssertEqual(filter.usesCatalogOnlyCriteria, !memoryPathResponds,
                           "\(name): usesCatalogOnlyCriteria must be true exactly when "
                           + "matches() cannot evaluate the criterion")
        }
    }

    func testCatalogOnlyCriteriaAreNamedIndividually() {
        // Spelled out as well as derived, so a change to the derivation cannot quietly
        // agree with itself.
        for (name, mutate) in Self.everyCriterion {
            var filter = LibraryFilter()
            mutate(&filter)
            let expected = ["edited", "cameras", "lenses", "isoBands",
                            "stackState", "keywords",
                            "softFocus", "closedEyes", "burst"].contains(name)
            XCTAssertEqual(filter.usesCatalogOnlyCriteria, expected, name)
        }
    }

    // MARK: - The sentence

    func testEmptySentenceSaysWhichModeItIsIn() {
        let filter = LibraryFilter()
        XCTAssertEqual(filter.sentence(catalogLive: true),
                       "No filter — showing every photo")
        XCTAssertEqual(filter.sentence(catalogLive: false),
                       "No filter — filtering in memory, without the catalog")
    }

    /// Once a filter is active the sentence is the same either way: it describes the
    /// query, and the query does not change because the catalog is missing. The bar
    /// hides the chips it cannot honour instead.
    func testAnActiveSentenceDoesNotDependOnTheCatalogMode() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        XCTAssertEqual(filter.sentence(catalogLive: true), "Picked")
        XCTAssertEqual(filter.sentence(catalogLive: false), "Picked")
    }

    func testFullyLoadedSentenceReadsInBarOrder() {
        XCTAssertEqual(
            fullyLoadedFilter().sentence(catalogLive: true),
            "Picked or Rejected"
            + "  and  ★ 3 or better"
            + "  and  Unlabelled or Red or Blue"
            + "  and  RAW only"
            + "  and  edited"
            + "  and  Sony A7 IV"
            + "  and  FE 35mm F1.4 GM"
            + "  and  ISO ≤ 400 or ISO 1601–6400"
            + "  and  sunset"
            + "  and  collapsed stacks"
            + "  and  soft focus"
            + "  and  eyes closed"
            + "  and  in a burst"
            + "  and  matching \"beach\"")
    }

    /// Unlabelled leads and the colours follow in key order (`6`–`9`, then purple), so
    /// the sentence reads in the order the chips sit in rather than alphabetically.
    func testLabelsReadInChipOrderNotAlphabetically() {
        var filter = LibraryFilter()
        filter.labels = [.purple, .red, .green]
        XCTAssertEqual(filter.sentence(catalogLive: true), "Red or Green or Purple")

        filter.includeUnlabeled = true
        XCTAssertEqual(filter.sentence(catalogLive: true),
                       "Unlabelled or Red or Green or Purple")
    }

    func testFlagsReadPickedFirst() {
        var filter = LibraryFilter()
        filter.flags = [.unflagged, .reject, .pick]
        XCTAssertEqual(filter.sentence(catalogLive: true), "Picked or Unflagged or Rejected")
    }

    func testUntouchedIsSpelledOutRatherThanShownAsAFalse() {
        var filter = LibraryFilter()
        filter.edited = false
        XCTAssertEqual(filter.sentence(catalogLive: true), "untouched")
    }

    // MARK: - The compiled query

    func testFullyLoadedQueryCompilesEveryCriterion() {
        let query = fullyLoadedFilter().query(sortKey: .rating, ascending: false, albumID: 7)

        XCTAssertEqual(query.flags, [.reject, .pick])
        XCTAssertEqual(query.rating, 3)
        XCTAssertEqual(query.ratingComparison, .atLeast)
        XCTAssertEqual(query.labels, [.red, .blue])
        XCTAssertTrue(query.includeUnlabeled)
        XCTAssertEqual(query.fileTypes, PhotoFormats.raw.sorted())
        XCTAssertEqual(query.edited, true)
        XCTAssertEqual(query.cameras, ["Sony A7 IV"])
        XCTAssertEqual(query.lenses, ["FE 35mm F1.4 GM"])
        XCTAssertEqual(query.keywords, ["sunset"])
        XCTAssertEqual(query.isoRanges, [0...400, 1601...6400])
        XCTAssertEqual(query.stackState, .collapsedTopsOnly)
        XCTAssertTrue(query.softFocus)
        XCTAssertTrue(query.closedEyes)
        XCTAssertEqual(query.burstState, .inBurst)
        XCTAssertEqual(query.text, "beach")
        XCTAssertEqual(query.sortKey, .rating)
        XCTAssertFalse(query.ascending)
        XCTAssertEqual(query.albumID, 7)
        XCTAssertFalse(query.includeMissing,
                       "the contact sheet shows files that are on the disk")
    }

    func testAnEmptyFilterCompilesToNoPredicates() {
        let query = LibraryFilter().query(sortKey: .captureTime, ascending: true, albumID: nil)

        XCTAssertTrue(query.flags.isEmpty)
        XCTAssertNil(query.rating)
        XCTAssertTrue(query.labels.isEmpty)
        XCTAssertFalse(query.includeUnlabeled)
        XCTAssertTrue(query.fileTypes.isEmpty)
        XCTAssertNil(query.edited)
        XCTAssertTrue(query.cameras.isEmpty)
        XCTAssertTrue(query.lenses.isEmpty)
        XCTAssertTrue(query.keywords.isEmpty)
        XCTAssertTrue(query.isoRanges.isEmpty)
        XCTAssertEqual(query.stackState, .any)
        XCTAssertFalse(query.softFocus)
        XCTAssertFalse(query.closedEyes)
        XCTAssertEqual(query.burstState, .any)
        XCTAssertNil(query.text)
    }

    /// The bug this comment in `LibraryFilter` records: two disjoint bands used to
    /// compile to the interval spanning them, which returned every ISO 800 frame
    /// between "≤ 400" and "≥ 6401".
    func testDisjointISOBandsCompileToTwoRangesNotTheSpan() {
        var filter = LibraryFilter()
        filter.isoBands = [.upTo400, .above6400]

        let query = filter.query(sortKey: .captureTime, ascending: true, albumID: nil)
        XCTAssertEqual(query.isoRanges, [0...400, 6401...4_000_000])
        XCTAssertFalse(query.isoRanges.contains { $0.contains(800) },
                       "ISO 800 is in neither lit band")
    }

    func testRatingOfZeroCompilesToNoRatingPredicate() {
        var filter = LibraryFilter()
        filter.minRating = 0
        XCTAssertNil(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).rating)
    }

    /// A search box holding only spaces is not a search.
    func testWhitespaceOnlyTextCompilesToNoTextPredicate() {
        var filter = LibraryFilter()
        filter.text = "   "
        XCTAssertNil(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).text)
    }

    func testTextIsTrimmedOnTheWayIntoTheQuery() {
        var filter = LibraryFilter()
        filter.text = "  beach  "
        XCTAssertEqual(
            filter.query(sortKey: .captureTime, ascending: true, albumID: nil).text, "beach")
    }

    func testStackStateMapsOneForOne() {
        let pairs: [(StackFilter, PhotoQuery.StackState)] = [
            (.any, .any), (.collapsedTops, .collapsedTopsOnly), (.unstacked, .unstacked),
        ]
        for (filterState, queryState) in pairs {
            var filter = LibraryFilter()
            filter.stackState = filterState
            XCTAssertEqual(
                filter.query(sortKey: .captureTime, ascending: true, albumID: nil).stackState,
                queryState)
        }
    }

    /// Set iteration order is unspecified, so the compiled query sorts. Without this the
    /// query is a different value run to run and nothing above could assert on it.
    func testCompiledQueryIsStableAcrossRuns() {
        let first = fullyLoadedFilter().query(sortKey: .rating, ascending: false, albumID: 7)
        for _ in 0..<50 {
            let again = fullyLoadedFilter().query(sortKey: .rating, ascending: false, albumID: 7)
            XCTAssertEqual(first.flags, again.flags)
            XCTAssertEqual(first.labels, again.labels)
            XCTAssertEqual(first.isoRanges, again.isoRanges)
            XCTAssertEqual(first.cameras, again.cameras)
        }
    }

    // MARK: - ISO bands

    func testISOBandsTileTheRangeWithoutOverlapOrGap() {
        let bands = ISOBand.allCases.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        for (lower, upper) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(upper.lowerBound, lower.upperBound + 1,
                           "bands must abut exactly: no ISO falls in two chips or none")
        }
        XCTAssertEqual(bands.first?.lowerBound, 0)
    }

    // MARK: - The two paths agree

    #if canImport(SQLite3)
    /// THE MEMORY PATH AND THE CATALOG ANSWER THE SAME QUESTION THE SAME WAY.
    ///
    /// A real catalog holding every combination of flag x rating x label x file type,
    /// and every combination of the four memory criteria both paths can evaluate, with
    /// the toggle off and on. For each, the rows `CatalogStore` returns for the compiled
    /// query must be exactly the rows `matches` keeps. Search text is left out on
    /// purpose: the SQL text search also reads keywords, camera and lens, which the
    /// memory path has no access to, and that difference is the bar's to declare.
    func testTheMemoryPathAgreesWithTheCatalogOnEveryCombination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-filter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/agreement")

        var files: [ScannedFile] = []
        var photos: [String: TestPhoto] = [:]
        let labels: [ColorLabel?] = [nil, .red, .blue]
        for flag in PhotoFlag.allCases {
            for rating in [0, 2, 4] {
                for (l, label) in labels.enumerated() {
                    for ext in ["arw", "jpg"] {
                        let name = "F\(flag.rawValue + 1)R\(rating)L\(l).\(ext)"
                        files.append(ScannedFile(filename: name, fileSize: 1_000,
                                                 fileMTime: 1_700_000_000, ext: ext))
                        photos[name] = TestPhoto(
                            flag: flag, rating: rating, label: label,
                            isRaw: PhotoFormats.isRaw(URL(fileURLWithPath: "/x/" + name)),
                            filename: name)
                    }
                }
            }
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        for (name, photo) in photos {
            let id = try XCTUnwrap(store.photo(folderID: folderID, filename: name)?.id)
            try store.setFlag(photo.flag, photoID: id)
            try store.setRating(photo.rating, photoID: id)
            try store.setLabel(photo.label, photoID: id)
        }

        var compared = 0
        for flagSet: Set<PhotoFlag> in [[], [.pick], [.pick, .reject]] {
            for minRating in [0, 3] {
                for (labelSet, unlabeled): (Set<ColorLabel>, Bool)
                    in [([], false), ([.red], false), ([], true), ([.red], true)] {
                    for rawOnly in [false, true] {
                        for matchAny in [false, true] {
                            var filter = LibraryFilter()
                            filter.flags = flagSet
                            filter.minRating = minRating
                            filter.labels = labelSet
                            filter.includeUnlabeled = unlabeled
                            filter.rawOnly = rawOnly
                            filter.matchAny = matchAny
                            let query = filter.query(sortKey: .filename, ascending: true,
                                                     albumID: nil)
                            let catalog = Set(try store.photos(matching: query,
                                                               folderID: folderID)
                                .map(\.filename))
                            let memory = Set(photos.values.filter { filter.matches($0) }
                                .map(\.filename))
                            XCTAssertEqual(memory, catalog,
                                           "\(filter.sentence(catalogLive: true))")
                            compared += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(compared, 96)
    }
    #endif

    // MARK: - PhotoFormats, which RAW-only compiles from

    func testRawOnlyMatchesExactlyWhatPhotoFormatsCallsRaw() {
        var filter = LibraryFilter()
        filter.rawOnly = true
        for name in ["a.ARW", "b.cr3", "c.DNG", "d.iiq", "e.jpg", "f.HEIC", "g.tiff"] {
            let url = URL(fileURLWithPath: "/roll/" + name)
            XCTAssertEqual(filter.matches(TestPhoto(isRaw: PhotoFormats.isRaw(url),
                                                    filename: name)),
                           PhotoFormats.isRaw(url), name)
        }
    }

    func testExtensionsAreReadCaseInsensitively() {
        XCTAssertTrue(PhotoFormats.isRaw(URL(fileURLWithPath: "/r/DSC_0001.ARW")))
        XCTAssertTrue(PhotoFormats.isRaw(URL(fileURLWithPath: "/r/DSC_0001.arw")))
        XCTAssertTrue(PhotoFormats.isRendered(URL(fileURLWithPath: "/r/IMG_0001.JPG")))
        XCTAssertTrue(PhotoFormats.isRendered(URL(fileURLWithPath: "/r/IMG_0001.Heic")))
        XCTAssertFalse(PhotoFormats.isRaw(URL(fileURLWithPath: "/r/notes.txt")))
        XCTAssertFalse(PhotoFormats.isRendered(URL(fileURLWithPath: "/r/notes.txt")))
    }

    /// A file is one or the other, never both: `isRendered` is the decoder fork, and an
    /// extension in both sets would be sent down whichever branch is checked first.
    func testRawAndRenderedAreDisjointAndBrowsableIsTheirUnion() {
        XCTAssertTrue(PhotoFormats.raw.isDisjoint(with: PhotoFormats.rendered))
        XCTAssertEqual(PhotoFormats.browsable, PhotoFormats.raw.union(PhotoFormats.rendered))
        XCTAssertTrue(PhotoFormats.raw.allSatisfy { $0 == $0.lowercased() },
                      "the sets are compared against a lowercased extension")
        XCTAssertTrue(PhotoFormats.rendered.allSatisfy { $0 == $0.lowercased() })
    }

    func testRawOnlyCompilesToEveryRawExtensionSorted() {
        var filter = LibraryFilter()
        filter.rawOnly = true
        let types = filter.query(sortKey: .captureTime, ascending: true, albumID: nil).fileTypes
        XCTAssertEqual(types, PhotoFormats.raw.sorted())
        XCTAssertEqual(Set(types), PhotoFormats.raw)
    }

    // MARK: - Helpers

    /// Every criterion the filter has, one mutation each. The two exhaustive tests above
    /// walk this list, so a new criterion has to be added here to be classified.
    private static let everyCriterion: [(String, (inout LibraryFilter) -> Void)] = [
        ("flags", { $0.flags = [.pick] }),
        ("minRating", { $0.minRating = 3 }),
        ("labels", { $0.labels = [.red] }),
        ("includeUnlabeled", { $0.includeUnlabeled = true }),
        ("text", { $0.text = "beach" }),
        ("rawOnly", { $0.rawOnly = true }),
        ("edited", { $0.edited = true }),
        ("cameras", { $0.cameras = ["Sony A7 IV"] }),
        ("lenses", { $0.lenses = ["FE 35mm F1.4 GM"] }),
        ("isoBands", { $0.isoBands = [.upTo400] }),
        ("stackState", { $0.stackState = .collapsedTops }),
        ("keywords", { $0.keywords = ["sunset"] }),
        ("softFocus", { $0.softFocus = true }),
        ("closedEyes", { $0.closedEyes = true }),
        ("burst", { $0.burst = .inBurst }),
    ]

    /// One of every criterion at once, with two values wherever a criterion takes a set,
    /// so both joins are exercised at the same time.
    private func fullyLoadedFilter() -> LibraryFilter {
        var filter = LibraryFilter()
        filter.flags = [.pick, .reject]
        filter.minRating = 3
        filter.labels = [.red, .blue]
        filter.includeUnlabeled = true
        filter.text = "beach"
        filter.rawOnly = true
        filter.edited = true
        filter.cameras = ["Sony A7 IV"]
        filter.lenses = ["FE 35mm F1.4 GM"]
        filter.isoBands = [.upTo400, .to6400]
        filter.stackState = .collapsedTops
        filter.keywords = ["sunset"]
        filter.softFocus = true
        filter.closedEyes = true
        filter.burst = .inBurst
        return filter
    }
}
