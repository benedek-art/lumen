// The seam that lets a test build an `AppState` at all.
//
// Until this file existed, `AppState.init()` reached `FileManager`'s
// `.applicationSupportDirectory` and `PreviewStore.defaultDirectory()` directly, so
// constructing the app's state hub CREATED `~/Library/Application Support/Lumen` and
// `~/Library/Caches/Lumen` and opened the owner's real catalog. `Package.swift` says
// what that cost, in the LumenAppTests target's own header: tests here exercise "pure
// app logic (counts, keys, gesture bookkeeping) — never a full `AppState`". And an
// `AppState` is the `@EnvironmentObject` every view in this application takes, so a hub
// no test could construct is a UI layer no test could host — which is why every UI
// check in this tree reads source text instead of measuring a rendered layout.
//
// So this file is deliberately not about layout. It is about the one precondition
// layout tests need: that `AppState(catalogDirectory:previewDirectory:)` exists, that
// production still reaches Application Support through the defaults, and that a test
// handed a temporary directory gets a hub which uses THAT directory and leaves the
// owner's Library alone.
#if os(macOS)

import XCTest
@testable import LumenApp

final class AppStateSeamTests: XCTestCase {

    // MARK: Temporary locations

    /// A directory of this test's own, removed at teardown. Named after the test so a
    /// leaked one says which test leaked it.
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-seam-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `~/Library/Application Support/Lumen` — WITHOUT creating anything on the way.
    ///
    /// `create: false` is the whole point: a test that asks where the real catalog
    /// would live must not be the thing that brings it into being, or the assertion
    /// below would be measuring its own side effect.
    private var applicationSupportLumen: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        return support.appendingPathComponent("Lumen", isDirectory: true)
    }

    /// Every path under `url`, or the empty set when it does not exist. Absence and
    /// emptiness compare equal here on purpose — both mean "nothing of ours is there".
    private func contents(of url: URL) -> Set<String> {
        guard let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil) else { return [] }
        return Set(walk.compactMap { ($0 as? URL)?.standardizedFileURL.path })
    }

    // MARK: The seam itself

    /// THE ASSERTION THIS WHOLE FILE EXISTS FOR: an `AppState` can be constructed by a
    /// test, and the catalog it opens is the one it was handed.
    ///
    /// `lumen.db` in the temporary directory is the proof that the seam is load-bearing
    /// rather than decorative. An `init` that accepted the closure and then went on
    /// finding its own directory would still construct, still leave `catalog` non-nil,
    /// and still pass every check but this one.
    @MainActor
    func testAnAppStateOpensTheCatalogDirectoryItWasHanded() throws {
        let catalogDirectory = try temporaryDirectory("catalog")
        let previewDirectory = try temporaryDirectory("previews")

        let state = AppState(catalogDirectory: { catalogDirectory },
                             previewDirectory: { previewDirectory })

        XCTAssertNotNil(state.catalog,
                        "the catalog failed to open in a writable temporary directory "
                            + "— status: \(state.catalogStatus ?? "none")")
        let database = catalogDirectory.appendingPathComponent("lumen.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path),
                      "no catalog appeared at \(database.path) — openCatalog is still "
                          + "finding its own directory instead of using the one it was "
                          + "given")
        XCTAssertNotNil(state.previews,
                        "the disk preview cache was not attached to the directory the "
                            + "seam supplied")
    }

    /// The other half of the same claim: building one costs the owner's Library
    /// nothing. Contents before and after, compared — not "the directory is absent",
    /// which would be false on any machine that has ever run the app.
    @MainActor
    func testConstructingAnAppStateLeavesApplicationSupportAlone() throws {
        let real = try XCTUnwrap(applicationSupportLumen,
                                 "could not resolve Application Support to compare it")
        let before = contents(of: real)

        let catalogDirectory = try temporaryDirectory("untouched")
        let previewDirectory = try temporaryDirectory("untouched-previews")
        _ = AppState(catalogDirectory: { catalogDirectory },
                     previewDirectory: { previewDirectory })

        XCTAssertEqual(contents(of: real), before,
                       "constructing an AppState against a temporary directory changed "
                           + "\(real.path) — the production route is still being taken")
    }

    // MARK: The route production takes

    /// The defaults are not decoration either: `AppState()` — the call `LumenApp` makes
    /// — has to still land on Application Support. This asserts the default *is* the
    /// production route by calling that route directly and reading the path it names,
    /// which is the same expression the initializer defaults to.
    ///
    /// Said plainly, because the test above claims the opposite for itself: this one
    /// DOES touch the owner's Library. It creates `Application Support/Lumen` and
    /// nothing inside it — the same empty directory the app creates on every launch,
    /// and no catalog, because no `CatalogService` is opened here. There is no way to
    /// check that a route with `create: true` in it still points at Application Support
    /// without taking the route, and a seam whose production default has quietly moved
    /// is worth more than the directory.
    func testTheProductionRouteStillNamesApplicationSupportLumen() throws {
        let directory = try AppState.applicationSupportCatalogDirectory()
        XCTAssertEqual(directory.lastPathComponent, "Lumen")
        let parent = directory.deletingLastPathComponent().standardizedFileURL
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).standardizedFileURL
        XCTAssertEqual(parent, support,
                       "the production catalog route no longer resolves to "
                           + "Application Support")
    }

    // MARK: `openCatalog` reads its locations from the seam

    /// `openCatalog` must take BOTH locations from the injected closures. The catalog
    /// half is proved above by a file appearing in a temporary directory; the preview
    /// half cannot be — `PreviewStore` writes nothing at construction — so the only
    /// falsifiable statement left about it is the one in the source.
    ///
    /// Comments and string bodies are blanked before this reads a character. Without
    /// that, the paragraph above `openCatalog` explaining that it no longer calls
    /// `PreviewStore.defaultDirectory` would itself contain the name being searched
    /// for, and this test would report a regression that had not happened — the
    /// mirror image of a scan that passes on its own doc comment.
    func testOpenCatalogTakesBothLocationsFromTheSeam() throws {
        let body = try XCTUnwrap(Self.openCatalogBody(),
                                 "openCatalog was not found in AppState.swift — this "
                                     + "scanner has stopped seeing its subject")

        // The scanner can see: openCatalog still opens a catalog. An absence check
        // whose haystack silently became empty passes forever.
        XCTAssertTrue(body.contains("CatalogService(directory:"),
                      "scanned \(body.count) characters and found no catalog open — "
                          + "the extracted body is not openCatalog's")

        XCTAssertTrue(body.contains("catalogDirectory()"),
                      "openCatalog no longer asks the injected closure where the "
                          + "catalog lives")
        XCTAssertTrue(body.contains("previewDirectory()"),
                      "openCatalog no longer asks the injected closure where the "
                          + "preview cache lives")
        XCTAssertFalse(body.contains("applicationSupportDirectory"),
                       "openCatalog hard-codes Application Support again — the seam is "
                           + "back to being decoration")
        XCTAssertFalse(body.contains("PreviewStore.defaultDirectory"),
                       "openCatalog hard-codes the real preview cache again, so a test "
                           + "that redirects only the catalog still writes to "
                           + "~/Library/Caches")
    }

    // MARK: Reading the source

    /// The repository, from this file's own path — the same route `KeyGrammarTests`
    /// takes. `Bundle.module` carries resources, and the sources are the subject.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    /// `openCatalog`'s body, comments and string bodies blanked, or nil if it is not
    /// there under that name any more.
    private static func openCatalogBody() -> String? {
        let url = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent("AppState.swift")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = Array(blanked(raw))
        guard var i = firstIndex(of: Array("func openCatalog()"), in: text) else {
            return nil
        }
        while i < text.count && text[i] != "{" { i += 1 }
        guard i < text.count else { return nil }
        var depth = 0
        let open = i
        while i < text.count {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...i]) }
            }
            i += 1
        }
        return nil
    }

    /// Where `needle` first appears in `text`, or nil. A plain scan over characters,
    /// because the haystack has already been flattened to an array and rebuilding a
    /// `String` to use `range(of:)` would put the two index spaces back in play.
    private static func firstIndex(of needle: [Character],
                                   in text: [Character]) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        for start in 0...(text.count - needle.count) {
            var k = 0
            while k < needle.count && text[start + k] == needle[k] { k += 1 }
            if k == needle.count { return start }
        }
        return nil
    }

    /// Comments AND string bodies blanked, length and newlines preserved — the same
    /// single pass `KeyGrammarTests.withoutComments` makes, plus the string half,
    /// because this scanner brace-matches and a `"}"` inside a literal would end the
    /// body early.
    private static func blanked(_ source: String) -> String {
        var out = Array(source)
        let n = out.count
        var i = 0
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
                blank(i + 1, Swift.max(i + 1, Swift.min(j - 1, n)))
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }
}

#endif
