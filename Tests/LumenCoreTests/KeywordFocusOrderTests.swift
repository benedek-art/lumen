// V7 D2: ⇧⌘K on the CLOSED Keywords section opened it with no caret.
//
// The keyword field lives inside the fold (`if keywordsExpanded`). The request handler
// set `keywordsExpanded = true` and `keywordFieldFocused = true` in the same update,
// before the TextField existed, and a `@FocusState` write to a view that is not mounted
// yet is commonly dropped. Keywords ships closed, so that was the ordinary case.
//
// The rule pinned here: when the section is closed, the handler parks the request and
// does NOT write the focus itself; the field's own `.onAppear` consumes the request and
// sets the focus on the next runloop turn. When the section is already open, the field
// is mounted and focusing at once is correct.
import XCTest

final class KeywordFocusOrderTests: XCTestCase {

    private func sidebarCode() throws -> String {
        try ShellSource.code("Sources/LumenApp/ContentView.swift")
    }

    func testOpeningTheSectionParksTheFocusInsteadOfWritingIt() throws {
        let code = try sidebarCode()
        let handler = try XCTUnwrap(
            ShellSource.body(after: ".onChange(of: keywordRequests.requests)", in: code),
            "the ⇧⌘K handler is gone or renamed; re-point this pin")
        let closedBranch = try XCTUnwrap(
            ShellSource.body(after: "} else", in: handler),
            "the handler no longer distinguishes an open section from a closed one, so "
                + "it writes the focus before the field is mounted")
        let flat = ShellSource.squashed(closedBranch)
        XCTAssertTrue(flat.contains("keywordFocusPending = true"))
        XCTAssertTrue(flat.contains("keywordsExpanded = true"))
        XCTAssertFalse(flat.contains("keywordFieldFocused = true"),
                       "focusing in the same update that mounts the field is the dropped "
                           + "write V7 D2 describes")
    }

    func testTheFieldTakesTheFocusWhenItAppears() throws {
        let code = try sidebarCode()
        let section = try XCTUnwrap(ShellSource.body(after: "private var keywordsSection", in: code))
        let appear = try XCTUnwrap(
            ShellSource.body(after: ".onAppear", in: section),
            "nothing in the Keywords section consumes a parked focus request when the "
                + "field mounts")
        let flat = ShellSource.squashed(appear)
        guard let consumed = flat.range(of: "keywordFocusPending = false"),
              let deferred = flat.range(of: "DispatchQueue.main.async { keywordFieldFocused = true }")
        else {
            return XCTFail("the field's onAppear must consume the request and focus on the "
                               + "next runloop turn: \(flat)")
        }
        XCTAssertLessThan(consumed.lowerBound, deferred.lowerBound)
        XCTAssertTrue(flat.contains("guard keywordFocusPending"),
                      "an ordinary expand by the triangle must not steal the caret")
    }
}
