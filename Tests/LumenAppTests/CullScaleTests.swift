// CullScaleTests.swift — the cull path at the size of a real shoot.
//
// The subject is one gesture: a folder of 500 to 2,000 frames is open, an arrow key is
// held down, and ratings are going in as the frames go past. macOS repeats a held key
// at roughly 25–30 events a second, so every per-keystroke cost on the main actor is
// paid thirty times a second in front of the photograph the photographer is judging.
//
// Three of these read the sources as text, which is the same instrument
// `LumenAppTests/KeyGrammarTests.swift` uses and for the same reason: the things being
// pinned are the ABSENCE of work — no array of the whole roll built per keystroke, no
// linear search for the cursor, no timer between a key and the frame it selects — and
// an absence has no API to call. `withoutComments` below is ported from that file
// unchanged, and it is not optional: every property asserted here is one this file's
// own prose names, so a scan over unstripped text would find the words in the comments
// arguing FOR the fix and pass whether or not the fix was there.
//
// The arithmetic half of the same work — the memo that replaced the linear search — is
// `RollCursor` in LumenCore, and it is tested for real in
// `LumenCoreTests/RollCursorTests.swift`, on a machine with no window server. What is
// left here is the part that is a fact about these four files.
#if os(macOS)
import XCTest
import LumenCore

final class CullScaleTests: XCTestCase {

    // MARK: Reading the sources

    /// The repository, from this file's own path — the route every scanning test in
    /// this package takes. `Bundle.module` carries resources, not sources.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private static func appSource(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// A source file with its comments blanked out.
    private func code(_ name: String) throws -> String {
        let url = Self.appSource(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.withoutComments(text)
    }

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and a line number can still be counted off the result.
    /// Ported verbatim from `KeyGrammarTests`; see its header for why the two constructs
    /// have to be handled in one pass rather than by two regexes.
    private static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }

    /// Every brace-delimited body that follows an occurrence of `marker`.
    ///
    /// The `{` is found by walking forward with a PAREN depth count, so a default
    /// argument or a trailing-closure signature between the marker and the body cannot
    /// be mistaken for the body's opening brace. Braces inside string literals are not
    /// handled and do not need to be: no declaration scanned here contains one.
    private func bodies(after marker: String, in code: String) -> [String] {
        let characters = Array(code)
        let needle = Array(marker)
        var found: [String] = []
        guard !needle.isEmpty, characters.count >= needle.count else { return [] }
        for start in 0...(characters.count - needle.count) {
            guard Array(characters[start..<(start + needle.count)]) == needle else {
                continue
            }
            var i = start + needle.count
            var parens = 0
            var open: Int?
            while i < characters.count {
                let c = characters[i]
                if c == "(" { parens += 1 }
                if c == ")" { parens -= 1 }
                if c == "{" && parens <= 0 { open = i; break }
                i += 1
            }
            guard let opening = open else { continue }
            var depth = 0
            var j = opening
            while j < characters.count {
                if characters[j] == "{" { depth += 1 }
                if characters[j] == "}" {
                    depth -= 1
                    if depth == 0 {
                        found.append(String(characters[opening...j]))
                        break
                    }
                }
                j += 1
            }
        }
        return found
    }

    // MARK: The roll is not rebuilt per keystroke

    func testNoCursorSurfaceProjectsTheWholeRollOnAKeystroke() throws {
        // `AppState.photos` has been memoised for a while. Its URL PROJECTION was not:
        // the grid and the strip each wrote `photos.map(\.id)` into their prefetch call,
        // so the one array the contact sheet is backed by was rebuilt twice per cursor
        // move — 2,000 URLs each, thirty times a second, to hand the ring eleven of
        // them. Neither surface is allowed to name that projection again.
        for name in ["GridView.swift", "FilmstripView.swift"] {
            let source = try code(name)
            for projection in ["map(\\.id)", "map { $0.id }", "map({ $0.id })"] {
                XCTAssertFalse(source.contains(projection),
                               "\(name) builds a fresh array of every URL in the roll "
                                   + "with \(projection) — at 2,000 frames that is the "
                                   + "whole folder projected on every key repeat")
            }
            XCTAssertTrue(source.contains("in: photos,"),
                          "\(name) no longer hands the roll itself to the prefetch")
        }
    }

    // MARK: The cursor is found without walking the roll

    func testTheRingFindsTheCursorWithoutWalkingTheRoll() throws {
        let source = try code("ThumbnailLoader.swift")
        XCTAssertTrue(source.contains("RollCursor()"),
                      "the loader no longer holds the memoised roll index; the ring is "
                          + "back to searching for its anchor on every cursor move")

        let prefetches = bodies(after: "func prefetch(", in: source)
        XCTAssertEqual(prefetches.count, 3,
                       "expected the two entry points and the shared core")
        for body in prefetches {
            // Three ways to walk an array looking for one element. The `enumerated()`
            // that IS in the core walks `ThumbnailLadder.warmSizes` — two cache levels,
            // not two thousand photographs — so it is deliberately not on this list.
            for search in ["firstIndex(of:", "firstIndex(where:", "first(where:"] {
                XCTAssertFalse(body.contains(search),
                               "prefetch walks the roll with \(search) — that is the "
                                   + "linear search per keystroke this replaced")
            }
        }
        XCTAssertTrue(prefetches.contains { $0.contains("roll.index(of:") },
                      "no prefetch asks the memo where the cursor is")
    }

    // MARK: Nothing between the key and the frame it selects

    func testNothingOnTheCursorPathIsPutOnATimer() throws {
        // The guard rail on every optimisation in this area. Coalescing work is allowed;
        // coalescing the ANSWER is not. If a keystroke's selection, or the scroll that
        // brings it into view, is ever deferred to a timer or a later run loop turn,
        // then during a fast arrow-through the frame on screen is not the frame that is
        // selected — and a rating typed at that moment lands on a photograph the
        // photographer never saw.
        //
        // `withAnimation` is deliberately not on this list. It defers the strip's
        // TRAVEL, never its target: `scrollTo` is called on this pass either way, and
        // the frame that is selected is the frame being scrolled to. The next test pins
        // the case where even the travel has to be given up.
        let delays = ["asyncAfter", "Task.sleep", "DispatchQueue.main.async",
                      "Timer.scheduledTimer", "Timer.publish", "debounce", "throttle"]
        for name in ["GridView.swift", "FilmstripView.swift"] {
            let source = try code(name)
            for delay in delays {
                XCTAssertFalse(source.contains(delay),
                               "\(name) puts \(delay) on the path between a keystroke "
                                   + "and the frame it selects — the displayed frame "
                                   + "can now lag the selected one")
            }
        }
    }

    func testTheStripCutsToTheSelectedFrameWhenKeysOutrunTheAnimation() throws {
        // A 120 ms centring animation restarted every 35 ms never arrives: the strip
        // chases the cursor for the whole of a held arrow key and the cell on the centre
        // line is never the selected one. Above the rate one animation can settle the
        // strip stops animating and cuts, so the selected frame is under the centre line
        // on the keystroke that selected it.
        let source = try code("FilmstripView.swift")
        let handlers = bodies(after: "onChange(of: state.primarySelection?.id)",
                              in: source)
        XCTAssertEqual(handlers.count, 1)
        let handler = try XCTUnwrap(handlers.first)

        XCTAssertTrue(handler.contains("arrivals.outrunsAnimation("),
                      "the strip animates its centring scroll unconditionally again")
        XCTAssertEqual(handler.components(separatedBy: "proxy.scrollTo(").count - 1, 2,
                       "expected two scrolls — one animated, one cut")
        XCTAssertEqual(handler.components(separatedBy: "withAnimation(").count - 1, 1,
                       "expected exactly one of the two scrolls to be animated")
        // And the gate is a rate, not a delay: it answers on the keystroke it is asked.
        XCTAssertTrue(source.contains("EventRate"),
                      "the strip measures the key-repeat rate with something other than "
                          + "the meter LumenCore already has")
    }

    // MARK: A rating lands on the photograph it was aimed at

    func testARatingFromTheSheetNamesTheCellsOwnPhotograph() throws {
        // The other half of "ratings applied during a fast arrow-through land on the
        // right photos". A cell rates ITSELF: the star button passes the `PhotoItem`
        // the cell was built from, so a cull decision names a photograph even when the
        // cursor has already moved on. That is only true while the cell observes
        // nothing — the moment it reads `AppState`, the value under the pointer and the
        // value it rates are two different reads of a moving target, and the cell also
        // re-bodies on every keystroke anywhere in the roll.
        let source = try code("GridView.swift")
        let cells = bodies(after: "struct PhotoCell: View", in: source)
        XCTAssertEqual(cells.count, 1)
        let cell = try XCTUnwrap(cells.first)

        XCTAssertTrue(cell.contains("onRate(photo, index)"),
                      "the star button no longer names the cell's own photograph")
        for observation in ["@EnvironmentObject", "@ObservedObject", "@StateObject",
                            "AppState"] {
            XCTAssertFalse(cell.contains(observation),
                           "PhotoCell reads \(observation) — a cell that observes shared "
                               + "state re-bodies on every cursor move in the roll, and "
                               + "its rating no longer names a fixed photograph")
        }
    }

    // MARK: The memo's own contract, from the app layer's side

    func testTheMemoAnswersTheSameIndexTheSearchDid() {
        // The loader's correctness in one line, against the search it replaced. The
        // exhaustive version — reorders, shortenings, duplicates, the build count —
        // is `RollCursorTests` in LumenCore, which runs on every lane.
        let ids = (0..<64).map { URL(fileURLWithPath: "/roll/DSC\($0).arw") }
        var cursor = RollCursor()
        for id in ids {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] },
                           ids.firstIndex(of: id))
        }
        XCTAssertEqual(cursor.rebuilds, 1)
    }

    // MARK: The keystroke path, past the two surfaces

    /// The other three whole-roll walks, closed after the fact.
    ///
    /// `RollCursor` landed in the grid and the strip first. Three more surfaces were
    /// still doing the linear thing on the same keystroke: `AppState` itself, in six
    /// places — `comparisonSet`, both halves of a shift-extended `select`,
    /// `moveSelection` on every arrow press, `advanceIfNeeded` after a cull and
    /// `cursorIndex` — and the loupe's two warms, which each built a whole `[URL]` on
    /// top of the search. `PhotoItem`'s `==` is `a.id == b.id` and nothing else, so
    /// routing them through the memo is the same comparison and not an approximation of
    /// it; that equivalence is what makes this substitution safe, and it is why this
    /// test may demand the search be gone outright rather than merely rarer.
    func testTheRollIsNotWalkedToFindTheCursor() throws {
        let state = try code("AppState.swift")
        XCTAssertFalse(state.contains("photos.firstIndex(of:"),
                       "AppState searches the roll linearly for the cursor again — "
                           + "that is up to three scans of the whole folder on a single "
                           + "arrow press, on the main actor, in front of the render")
        XCTAssertTrue(state.contains("rollCursor.index(of:"),
                      "AppState no longer keeps a RollCursor, so nothing memoises the "
                          + "cursor's position between keystrokes")

        let loupe = try code("LoupeView.swift")
        for projection in ["map(\\.id)", "map { $0.id }", "map({ $0.id })"] {
            XCTAssertFalse(loupe.contains(projection),
                           "LoupeView builds a fresh array of every URL in the roll "
                               + "with \(projection) — it did this twice per advance, "
                               + "once to warm the decode and once to warm the ring")
        }
        XCTAssertTrue(loupe.contains("state.rollIndex(of: photo)"),
                      "the loupe's decode warm no longer asks the memo where the "
                          + "cursor is")
    }

    // MARK: One publish per cull keystroke, not one per frame

    /// `allPhotos` is `@Published` with `didSet { invalidatePhotoCache() }`, so a write
    /// per element is a republish of the whole grid per element AND a throw-away of the
    /// contact sheet the next iteration rebuilds. `mutateTargets` is the cull path: one
    /// keystroke over a forty-frame selection went through it forty times. Rating a
    /// selection is one edit and must be one publish.
    ///
    /// `adoptCaptureISO` in the same file already documents the pattern and the reason;
    /// this pins that the cull path uses it too.
    func testACullKeystrokeRepublishesTheGridOnce() throws {
        let state = try code("AppState.swift")
        let body = try Self.functionBody(named: "mutateTargets", in: state)
        XCTAssertFalse(body.contains("body(&allPhotos["),
                       "mutateTargets mutates the published array element by element "
                           + "again — forty frames rated in one keystroke is forty "
                           + "objectWillChange publishes and forty contact sheets "
                           + "thrown away")
        XCTAssertTrue(body.contains("allPhotos = updated"),
                      "mutateTargets no longer assigns the roll exactly once")
        XCTAssertEqual(body.components(separatedBy: "allPhotos = ").count - 1, 1,
                       "mutateTargets writes the published roll more than once — the "
                           + "whole point of the local copy is that there is a single "
                           + "publish at the end")
    }

    /// The body of a function, by brace matching from its declaration. Used only on
    /// comment-and-string-blanked text, which is what makes the brace count honest.
    private static func functionBody(named name: String, in code: String) throws -> String {
        guard let decl = code.range(of: "func \(name)(") else {
            throw XCTSkip("\(name) is no longer in the file under that name")
        }
        guard let open = code[decl.upperBound...].firstIndex(of: "{") else {
            throw XCTSkip("\(name) has no body")
        }
        var depth = 0
        var i = open
        while i < code.endIndex {
            if code[i] == "{" { depth += 1 }
            if code[i] == "}" {
                depth -= 1
                if depth == 0 { return String(code[open...i]) }
            }
            i = code.index(after: i)
        }
        throw XCTSkip("\(name)'s body does not close")
    }
}
#endif
