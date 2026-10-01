// UpdaterMainActorTests.swift
// The updater does not block the main actor while it unpacks and verifies (K-034).
//
// `AppUpdater` is `@MainActor`, and its `run` waited for `ditto` (the whole archive) and
// `codesign --verify --deep --strict` (every nested binary) with `waitUntilExit()` — an
// unbounded synchronous wait on the main thread. The file is macOS-only, so this reads
// it as text, line comments stripped, on the lane that runs.

import XCTest

final class UpdaterMainActorTests: XCTestCase {

    func testTheUpdaterWaitsForItsToolsWithoutBlockingTheMainActor() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/AppUpdater.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // `//` inside a string literal would cut the line short; this file has
                // URLs in strings, so only strip a `//` that starts the trimmed line or
                // follows whitespace outside quotes — conservatively, whole-line comments.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") ? "" : String(line)
            }
        let code = lines.joined(separator: "\n")

        XCTAssertTrue(code.contains("@MainActor"),
                      "the premise: the updater is main-actor isolated")
        XCTAssertFalse(code.contains("waitUntilExit()"),
                       "a synchronous wait for ditto or codesign inside a @MainActor "
                           + "class freezes the window for as long as they run")
        XCTAssertTrue(code.contains("private func run(_ tool: String, _ arguments: String...) "
                                        + "async throws"),
                      "the tool runner is no longer a suspension")
        XCTAssertTrue(code.contains("terminationHandler"),
                      "nothing reports the tool's exit except a blocking wait")
        for tool in ["/usr/bin/ditto", "/usr/bin/codesign"] {
            XCTAssertTrue(code.contains("try await run(\"\(tool)\""),
                          "\(tool) is not awaited")
        }
    }
}
