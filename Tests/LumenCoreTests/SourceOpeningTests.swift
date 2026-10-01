// What an open request becomes (V7 D7), decided in LumenCore so it runs here.
//
// The defect: when directory expansion moved off the main actor (b8d6d4f), the
// "Nothing there Lumen can open" guard went with it and nothing filtered non-file URLs.
// A web link dropped on the window closed the open folder, opened an empty roll rooted
// at the link's path, and remembered that for relaunch.
import XCTest
@testable import LumenCore

final class SourceOpeningTests: XCTestCase {

    private static let extensions: Set<String> = ["nef", "jpg", "dng"]

    /// A fake filesystem: anything ending in "/" is a directory.
    private func plan(_ urls: [URL]) -> SourceOpening.Plan {
        SourceOpening.plan(urls, extensions: Self.extensions,
                           isDirectory: { $0.hasDirectoryPath })
    }

    private func file(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    func testAWebLinkIsNotASource() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/y"))
        XCTAssertEqual(plan([link]), .nothing,
                       "a dropped web link must leave the open roll alone")
        // Not even alongside a real photograph: the link is dropped, the photo opens.
        XCTAssertEqual(plan([link, file("/shoot/a.NEF")]),
                       .files(root: dir("/shoot"), files: [file("/shoot/a.NEF")]))
    }

    /// The link that the type filter alone cannot refuse. Dragging a picture out of a
    /// browser drops `https://…/a.jpg`, whose extension IS one Lumen opens; and a link
    /// ending in "/" has a directory path, which the app's `isDirectory` answers from the
    /// LOCAL filesystem at that path (`https://host/Users/` names `/Users`). Only the
    /// file-URL filter keeps either from replacing the roll.
    func testAWebLinkToAPhotographOrAFolderIsNotASource() throws {
        let photo = try XCTUnwrap(URL(string: "https://example.com/shoot/a.jpg"))
        XCTAssertEqual(plan([photo]), .nothing,
                       "a browser image drag opened a picked set rooted at the link's path")
        let folder = try XCTUnwrap(URL(string: "https://example.com/shoot/"))
        XCTAssertEqual(plan([folder]), .nothing,
                       "a folder-shaped web link opened as a folder")
        XCTAssertEqual(plan([photo, folder, file("/card/b.NEF")]),
                       .files(root: dir("/card"), files: [file("/card/b.NEF")]))
    }

    func testNothingOpenableIsNothing() {
        XCTAssertEqual(plan([]), .nothing)
        XCTAssertEqual(plan([file("/docs/notes.txt"), file("/docs/readme.md")]), .nothing)
    }

    func testOneFolderIsTheFolderOpenItAlwaysWas() {
        XCTAssertEqual(plan([dir("/shoot/day1")]), .folder(dir("/shoot/day1")))
        // A stray unsupported file beside it does not turn it into a picked set.
        XCTAssertEqual(plan([dir("/shoot/day1"), file("/shoot/notes.txt")]),
                       .folder(dir("/shoot/day1")))
    }

    func testPhotographsBecomeAPickedSetAtTheirCommonParent() {
        let a = file("/shoot/day1/a.NEF"), b = file("/shoot/day2/b.jpg")
        XCTAssertEqual(plan([a, b]), .files(root: dir("/shoot"), files: [a, b]))
    }

    func testADirectoryAmongTheSourcesWaitsForItsWalk() {
        let a = file("/shoot/day1/a.NEF")
        let d = dir("/shoot/day2"), e = dir("/shoot/day3")
        XCTAssertEqual(plan([a, d]), .expand(root: dir("/shoot"), sources: [a, d]))
        XCTAssertEqual(plan([d, e]), .expand(root: dir("/shoot"), sources: [d, e]))
    }

    /// The walk's answer, not the request, decides whether the roll is replaced.
    func testAnEmptyWalkOpensNothing() {
        XCTAssertNil(SourceOpening.expansionOutcome(root: dir("/shoot"), found: []))
        let a = file("/shoot/day2/a.NEF")
        XCTAssertEqual(SourceOpening.expansionOutcome(root: dir("/shoot"), found: [a]),
                       .files(root: dir("/shoot"), files: [a]))
    }

    func testCommonParentStopsAtTheFirstDifferentComponent() {
        let a = file("/r/day1/photos/x.NEF"), b = file("/r/day2/photos/x.NEF")
        XCTAssertEqual(SourceOpening.commonParent(of: [a, b], isDirectory: { $0.hasDirectoryPath })?.path,
                       "/r")
        XCTAssertNil(SourceOpening.commonParent(of: [], isDirectory: { _ in false }))
    }

    // MARK: - Relaunch (V7 D6)

    func testAFolderRollReopensAsTheFolder() {
        XCTAssertEqual(SourceOpening.relaunch(remembered: [], exists: { _ in true }), .folder)
    }

    func testAPickedSetReopensAsWhatIsLeftOfIt() {
        let kept = "/Users/me/Desktop/a.NEF", gone = "/Users/me/Downloads/b.NEF"
        XCTAssertEqual(SourceOpening.relaunch(remembered: [kept, gone], exists: { $0 == kept }),
                       .files([URL(fileURLWithPath: kept)]))
    }

    /// The defect: every remembered file gone fell through to "no restriction", and the
    /// remembered root — the picked files' common parent, here the home folder — was
    /// scanned whole.
    func testAPickedSetThatIsAllGoneOpensNothing() {
        let picked = ["/Users/me/Desktop/a.NEF", "/Users/me/Downloads/b.NEF"]
        XCTAssertEqual(SourceOpening.relaunch(remembered: picked, exists: { _ in false }),
                       .nothing,
                       "a vanished selection must never become an unrestricted scan of its root")
    }

    func testReopenLastFolderActsOnTheRelaunchDecision() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let reopen = try XCTUnwrap(ShellSource.body(after: "func reopenLastFolder()", in: code),
                                   "reopenLastFolder is gone or renamed; re-point this pin")
        let flat = ShellSource.squashed(reopen)
        XCTAssertTrue(flat.contains("SourceOpening.relaunch(remembered: remembered"))
        XCTAssertFalse(flat.contains("files.isEmpty ? nil"),
                       "the fall-through to an unrestricted open is back")
        let start = try XCTUnwrap(flat.range(of: "case .nothing:"))
        let rest = String(flat[start.upperBound...])
        XCTAssertFalse(rest.prefix(while: { $0 != "}" }).contains("openFolder("),
                       "a vanished selection must open nothing")
    }

    // MARK: - Opens that arrive before the state (V7 D8)

    func testOpensBeforeTheStateAreHeldThenHandedOverOnceInOrder() {
        var queue = LaunchOpenQueue()
        let a = file("/shoot/a.NEF"), b = file("/shoot/b.NEF"), c = file("/shoot/c.NEF")
        XCTAssertEqual(queue.receive([a]), [], "nothing can be opened before the state exists")
        XCTAssertEqual(queue.receive([b]), [])
        XCTAssertEqual(queue.attach(), [a, b], "a cold-launch open was lost")
        XCTAssertEqual(queue.attach(), [], "held opens are handed over once")
        XCTAssertEqual(queue.receive([c]), [c], "once attached, opens pass straight through")
    }

    func testNoEarlyOpensMeansNothingHeld() {
        var queue = LaunchOpenQueue()
        XCTAssertEqual(queue.attach(), [])
    }

    // MARK: - The app acts on the plan

    /// `openSources` routes through the plan, refuses `.nothing` without touching the
    /// roll, and opens an expanded set only after the walk's outcome says so.
    func testOpenSourcesActsOnThePlan() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let verb = try XCTUnwrap(ShellSource.body(after: "func openSources(_ urls: [URL])", in: code),
                                 "openSources is gone or renamed; re-point this pin")
        let flat = ShellSource.squashed(verb)
        XCTAssertTrue(flat.contains("SourceOpening.plan(urls"),
                      "openSources must decide through SourceOpening.plan")
        let nothingStart = try XCTUnwrap(flat.range(of: "case .nothing:"))
        let nothingEnd = try XCTUnwrap(flat.range(of: "case .folder", range: nothingStart.upperBound..<flat.endIndex))
        let nothing = String(flat[nothingStart.upperBound..<nothingEnd.lowerBound])
        XCTAssertFalse(nothing.contains("openFolder("), "refusing must not open anything")
        XCTAssertTrue(nothing.contains("statusMessage = Self.nothingToOpenMessage"))
        let expand = try XCTUnwrap(ShellSource.body(after: "case .expand(", in: verb))
        let flatExpand = ShellSource.squashed(expand)
        guard let walk = flatExpand.range(of: "Self.expand(sources"),
              let outcome = flatExpand.range(of: "SourceOpening.expansionOutcome("),
              let open = flatExpand.range(of: "self.openFolder(") else {
            return XCTFail("the expand path must walk, consult the outcome, then open: \(flatExpand)")
        }
        XCTAssertLessThan(walk.lowerBound, outcome.lowerBound)
        XCTAssertLessThan(outcome.lowerBound, open.lowerBound)
        XCTAssertFalse(flatExpand[..<walk.lowerBound].contains("openFolder("),
                       "the roll must not be replaced before the walk has answered")
    }
}
