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

    /// Pins current behaviour rather than blessing it: the in-memory fallback ANDs every
    /// criterion regardless of the toggle, while the SQL path honours it. The two paths
    /// disagree when the toggle is on and more than one memory criterion is lit.
    func testMatchAnyIsNotHonouredByTheMemoryPath() {
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 4
        filter.matchAny = true

        XCTAssertFalse(filter.matches(TestPhoto(flag: .pick, rating: 1)),
                       "documented gap: matches() ANDs even under Match: Any")
        XCTAssertTrue(filter.query(sortKey: .captureTime, ascending: true, albumID: nil).matchAny,
                      "…while the compiled query does carry the toggle to SQL")
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

        XCTAssertEqual(fullyLoadedFilter().activeCriteriaCount, 11,
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
                            "stackState", "keywords"].contains(name)
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
        return filter
    }
}
