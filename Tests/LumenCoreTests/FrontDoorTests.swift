// The three doors a photograph can come in by, and the pairs of facts each one needs.
//
// Each door is TWO edits in two different files, and either one alone is inert:
//
//   · Finder's "Open With", a double-click, and a drop on the dock icon need
//     `CFBundleDocumentTypes` in the bundle AND `application(_:open:)` on the app
//     delegate. Declare the types with no method and the open silently does nothing;
//     write the method with no declaration and Finder never offers Lumen at all.
//   · A drop on the window needs `.dropDestination` AND `openSources` to accept a
//     mixed list of files and folders.
//   · The Open panel needs `canChooseFiles` AND `allowsMultipleSelection`.
//
// Text assertions, because the two halves live in a shell script and in a file Linux
// compiles to nothing: `LumenApp.swift` is inside `#if os(macOS)`, so no Linux
// compiler ever type-checks it, and `build-app.sh` is not Swift at all. What is
// checkable here is that neither half of any pair has been removed without the other.
import XCTest
@testable import LumenCore

final class FrontDoorTests: XCTestCase {

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// The bundle offers itself to Finder for photographs and for folders.
    func testBundleDeclaresWhatItCanOpen() throws {
        let script = try text("scripts/build-app.sh")
        XCTAssertTrue(script.contains("CFBundleDocumentTypes"),
                      "with no document types Finder never offers Lumen")
        XCTAssertTrue(script.contains("public.camera-raw-image"),
                      "the parent type every vendor RAW conforms to")
        XCTAssertTrue(script.contains("public.image"))
        XCTAssertTrue(script.contains("public.folder"),
                      "a folder is the ordinary thing to hand this app")
    }

    /// And does not make itself the system handler for every JPEG on the machine.
    func testBundleDoesNotClaimToBeTheDefaultHandler() throws {
        let script = try text("scripts/build-app.sh")
        XCTAssertFalse(script.contains("<string>Owner</string>"),
                       "a development build must not take over the photographer's files")
        XCTAssertEqual(
            script.components(separatedBy: "<string>Alternate</string>").count - 1, 2,
            "both declared types stay at Alternate rank")
    }

    /// The method the system delivers those opens to. Without it every one of the
    /// three Finder doors is a no-op that looks like it should work.
    func testTheDelegateReceivesFinderOpens() throws {
        let app = try text("Sources/LumenApp/LumenApp.swift")
        XCTAssertTrue(app.contains("func application(_ application: NSApplication, open urls: [URL])"),
                      "the only hook the system delivers a Finder open to")
        XCTAssertTrue(app.contains("state?.openSources(urls)"),
                      "and it must go through the same verb as every other door")
    }

    /// A drop anywhere in the window.
    func testTheWindowTakesADrop() throws {
        let app = try text("Sources/LumenApp/LumenApp.swift")
        XCTAssertTrue(app.contains(".dropDestination(for: URL.self)"),
                      "URL, not String — the mask panel's drop carries ids as strings")
        XCTAssertTrue(app.contains("state.openSources(urls)"))
    }

    /// The Open panel takes files as well as folders — the owner's ask, and the flag
    /// that greyed every RAW out of the panel until it was flipped.
    func testTheOpenPanelTakesFilesAndFolders() throws {
        let state = try text("Sources/LumenApp/AppState.swift")
        XCTAssertTrue(state.contains("panel.canChooseFiles = true"))
        XCTAssertTrue(state.contains("panel.canChooseDirectories = true"))
        XCTAssertTrue(state.contains("panel.allowsMultipleSelection = true"))
        XCTAssertTrue(state.contains("PhotoFormats.browsableContentTypes"),
                      "the filter list is derived from `browsable`, never written twice")
    }

    /// All four doors converge on one verb, which is what makes them behave alike.
    func testEveryDoorGoesThroughOneVerb() throws {
        let state = try text("Sources/LumenApp/AppState.swift")
        XCTAssertTrue(state.contains("func openSources(_ urls: [URL])"))
        // And it handles the mixed list rather than only the single-folder case.
        XCTAssertTrue(state.contains("commonParent(of: urls)"),
                      "loose frames need a root to hang off")
        XCTAssertTrue(state.contains("openFolder(root, restrictedTo: Set(urls))"))
    }
}
