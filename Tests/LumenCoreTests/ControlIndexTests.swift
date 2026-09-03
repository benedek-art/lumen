// The ⌘K palette's ranking, which is exactly the kind of rule that is wrong in ways
// only examples reveal.
import XCTest
@testable import LumenCore

final class ControlIndexTests: XCTestCase {

    private func titles(_ query: String) -> [String] {
        ControlIndex.search(query).map(\.title)
    }

    /// A palette that opens blank and shows nothing looks broken. The first thing it
    /// should do is say what there is.
    func testAnEmptyQueryShowsEverything() {
        XCTAssertEqual(ControlIndex.search("").count, ControlIndex.all.count)
        XCTAssertEqual(ControlIndex.search("   ").count, ControlIndex.all.count)
    }

    /// THE CASE THE RANKING EXISTS FOR. "sat" is a subsequence of "Capture Sharpening"
    /// — s, a, t all appear in order — so a naive matcher offers it alongside
    /// Saturation. A photographer typing three letters means the control those three
    /// letters START.
    func testAPrefixBeatsACoincidentalSubsequence() {
        let results = titles("sat")
        XCTAssertEqual(results.first, "Saturation",
                       "got \(results.prefix(3)) — 'sat' must mean Saturation")
        if let sharpening = results.firstIndex(of: "Capture Sharpening"),
           let saturation = results.firstIndex(of: "Saturation") {
            XCTAssertLessThan(saturation, sharpening)
        }
    }

    /// An abbreviation people actually type, which is the whole reason aliases exist.
    func testTheAbbreviationsPeopleTypeFindTheControl() {
        XCTAssertEqual(titles("temp").first, "Temperature")
        XCTAssertEqual(titles("nr").first, "Noise Reduction")
        XCTAssertEqual(titles("bw").first, "Black & White")
        XCTAssertEqual(titles("b&w").first, "Black & White",
                       "punctuation is how people write this one")
    }

    /// An alias may beat a title, because the alias is what was meant: "wb" is an exact
    /// alias of Temperature's and only a coincidental subsequence of several titles.
    func testAnExactAliasOutranksALooseTitleMatch() {
        let results = ControlIndex.search("wb")
        XCTAssertEqual(results.first?.section, .whiteBalance,
                       "got \(results.prefix(3).map(\.title))")
    }

    /// A word inside a name is findable without typing the words before it.
    func testAWordPrefixMatchesInsideAName() {
        XCTAssertTrue(titles("bal").contains("Colour Grading"),
                      "'bal' should reach Colour Grading through its balance alias")
        XCTAssertEqual(titles("light").first, "Printer Lights")
    }

    /// Typos and dropped vowels still land, which is what a subsequence match is for —
    /// it just must never outrank something better.
    func testDroppedVowelsStillFindTheControl() {
        XCTAssertTrue(titles("clrty").contains("Clarity"))
        XCTAssertTrue(titles("expsr").contains("Exposure"))
    }

    /// Case is not a question the photographer should have to think about.
    func testMatchingIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(titles("  DEHAZE ").first, "Dehaze")
    }

    /// Equally-good matches come back in the order the panel draws them, not in the
    /// order this table happens to be written — otherwise the palette's list and the
    /// column's list disagree about what comes first, for no reason a reader could see.
    func testEquallyGoodMatchesFollowTheCanonicalPanelOrder() {
        // WITHIN a strength, not across it. Match strength is the primary sort and has
        // to be: a prefix match in Deliver must still beat a coincidental subsequence in
        // Develop, so the section ranks of the whole list are correctly not ascending.
        // What the ranking promises is that ties are broken by the order the panel draws
        // in, so the palette's list and the column's list never disagree for no reason a
        // reader could see.
        let needle = ControlIndex.normalize("colour")
        let results = ControlIndex.search("colour")
        XCTAssertGreaterThan(results.count, 2, "the case needs several matches")

        var seen: [ControlIndex.Match: [Int]] = [:]
        for control in results {
            guard let match = ControlIndex.strength(of: needle, against: control) else {
                return XCTFail("\(control.title) was returned but does not match")
            }
            seen[match, default: []].append(control.section.canonicalRank)
        }
        for (match, ranks) in seen {
            XCTAssertEqual(ranks, ranks.sorted(),
                           "\(match) matches came back out of panel order: \(ranks)")
        }
    }

    /// A query that means nothing returns nothing, rather than everything ranked badly.
    func testAQueryThatMatchesNothingReturnsNothing() {
        XCTAssertTrue(ControlIndex.search("zzqqxx").isEmpty)
    }

    /// EVERY SECTION MUST BE REACHABLE BY NAME. A section with no control in the index
    /// is a place the palette can never send anybody, which is worse than not having
    /// the palette — it would be findable for some of the app and silently not for the
    /// rest.
    func testEverySectionIsReachableFromThePalette() {
        let reachable = Set(ControlIndex.all.map(\.section))
        let missing = Set(WorkspaceSection.allCases).subtracting(reachable)
        XCTAssertTrue(missing.isEmpty, "no control indexes these sections: \(missing)")
    }

    /// Two controls with the same id would make "go to this one" ambiguous, and an id
    /// that does not match `ProofRegistry`'s is a catalogue that cannot be cross-checked
    /// against the one that proves the controls work.
    func testIdsAreUnique() {
        let ids = ControlIndex.all.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        XCTAssertTrue(duplicates.isEmpty, "duplicate ids: \(duplicates)")
    }

    /// A control whose title does not find itself is unreachable by the most obvious
    /// query there is.
    func testEveryControlIsFoundByItsOwnTitle() {
        for control in ControlIndex.all {
            let found = ControlIndex.search(control.title)
            XCTAssertEqual(found.first?.id, control.id,
                           "\(control.title) does not rank first for its own name; got "
                               + "\(found.first?.title ?? "nothing")")
        }
    }
}
