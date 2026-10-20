// LibraryQueryPacingTests.swift
// A typed word is one grid query (J1-05 / K-055's debounce half).
//
// The rule is pure and pinned here. The wiring is one call in `AppState`, which cannot
// compile on this lane, so the last test reads that function as text — comments
// blanked first, because the comment above the call names the rule it calls and a scan
// over unstripped text would pass with the call deleted.

import XCTest
@testable import LumenCore

final class LibraryQueryPacingTests: XCTestCase {

    private func filter(text: String = "", rating: Int = 0,
                        flags: Set<PhotoFlag> = []) -> LibraryFilter {
        var f = LibraryFilter()
        f.text = text
        f.minRating = rating
        f.flags = flags
        return f
    }

    // MARK: The rule

    func testAKeystrokeWaitsForTheNext() {
        XCTAssertEqual(LibraryQueryPacing.delay(from: filter(text: "por"),
                                                to: filter(text: "port")),
                       LibraryQueryPacing.textDebounce,
                       "every letter of a typed word re-ran the whole roll's query on the "
                           + "queue that serves the thumbnails")
        XCTAssertEqual(LibraryQueryPacing.delay(from: filter(),
                                                to: filter(text: "p")),
                       LibraryQueryPacing.textDebounce,
                       "the first letter is a keystroke like the rest")
        XCTAssertEqual(LibraryQueryPacing.delay(from: filter(text: "ports"),
                                                to: filter(text: "port")),
                       LibraryQueryPacing.textDebounce,
                       "a backspace mid-word is a keystroke too")
    }

    func testAChipIsAnsweredAtOnce() {
        XCTAssertNil(LibraryQueryPacing.delay(from: filter(), to: filter(rating: 3)),
                     "a star is one deliberate click and must not wait")
        XCTAssertNil(LibraryQueryPacing.delay(from: filter(text: "port"),
                                              to: filter(text: "port", flags: [.pick])),
                     "a chip lit while text is present is still a click")
        // A chip and the text moving in ONE write (the Clear button resets both): the
        // chip makes it a click.
        XCTAssertNil(LibraryQueryPacing.delay(from: filter(text: "port", rating: 2),
                                              to: filter()))
    }

    func testClearingTheTextIsAnsweredAtOnce() {
        XCTAssertNil(LibraryQueryPacing.delay(from: filter(text: "port"), to: filter()),
                     "the field's ✕ is one act, and the whole roll coming back is not a "
                         + "burst to wait out")
    }

    func testNoChangeAsksNothing() {
        XCTAssertNil(LibraryQueryPacing.delay(from: filter(text: "a"), to: filter(text: "a")))
    }

    func testTheWaitIsShorterThanAHandLeavingTheKeyboard() {
        // A pacing that never fired would pass every assertion above that compares
        // against `textDebounce` itself.
        XCTAssertGreaterThan(LibraryQueryPacing.textDebounce, .milliseconds(50))
        XCTAssertLessThanOrEqual(LibraryQueryPacing.textDebounce, .milliseconds(300))
    }

    // MARK: The wiring

    func testTheFilterObserverAsksThePacingBeforeItQueries() throws {
        let source = try ShellSource.code("Sources/LumenApp/AppState.swift")
        guard let start = source.range(of: "private func filterOrSortChanged(") else {
            return XCTFail("AppState.filterOrSortChanged is gone; the filter's didSet "
                           + "must still route through one function that paces it")
        }
        let rest = source[start.upperBound...]
        // Up to the next member declared at this indentation.
        let end = ["\n    func ", "\n    private func ", "\n    private var "]
            .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertTrue(body.contains("LibraryQueryPacing.delay(from:"),
                      "the filter observer queries without asking whether this change "
                          + "is a keystroke")
        XCTAssertTrue(body.contains(".cancel()"),
                      "a newer keystroke must supersede the pending query, or a typed "
                          + "word is still one query per letter, only later")
        // The filter's didSet must go through it, not around it. Scoped to the didSet's
        // own braces, so its length does not matter and the next member is not read.
        guard let property = ShellSource.body(after: "@Published var filter = LibraryFilter()",
                                              in: source),
              let observer = ShellSource.body(after: "didSet", in: property) else {
            return XCTFail("the filter property or its didSet moved")
        }
        XCTAssertTrue(observer.contains("filterOrSortChanged(oldValue)"))
        XCTAssertFalse(observer.contains("refreshLibraryQuery()"),
                       "the filter's didSet queries directly, past the pacing")
    }
}
