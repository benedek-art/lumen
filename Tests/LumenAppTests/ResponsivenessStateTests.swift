// Debounced view state must land under the source it was made in.
//
// The grid's thumbnail slider emits a value per pixel of drag, so `AppState` saves the
// size on an 800 ms debounce. That timer used to read `sourceKey` when it FIRED: resize
// the grid, open another folder inside the window, and the size was never saved for the
// folder it was chosen in — while the folder just opened had its stored row written
// with the previous folder's sort and size. These tests drive the production path
// against an isolated catalog, the way `AuditStateSafetyTests` does.
#if os(macOS)
import AppKit
import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessStateTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-responsiveness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Opening a roll remembers it; keep the user's own defaults out of this.
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, remembered) {
                UserDefaults.standard.set(value, forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try await run(state, root)
    }

    @MainActor private func png(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<4 { for x in 0..<4 { bitmap.setColor(.gray, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }

    @MainActor private func scanned(_ state: AppState) async throws {
        for _ in 0..<500 {
            if !state.isScanning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Isolated scan did not finish")
    }

    @MainActor
    func testGridResizeInsideTheDebounceIsSavedForTheFolderItWasMadeIn() async throws {
        try await withState { state, root in
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            try png(first.appendingPathComponent("a.png"))
            try png(second.appendingPathComponent("b.png"))

            state.openFolder(first)
            try await scanned(state)
            let firstKey = "folder:" + (state.folderURL?.path ?? first.path)

            // A resize, then a folder switch well inside the 800 ms debounce.
            state.gridThumbnailSize = 300
            state.openFolder(second)
            try await scanned(state)
            let secondKey = "folder:" + (state.folderURL?.path ?? second.path)
            let catalog = try XCTUnwrap(state.catalog)

            var stored: CatalogService.SourceViewState?
            for _ in 0..<200 {
                stored = await catalog.sourceState(firstKey)
                if stored != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(stored?.thumbnailSize, 300,
                           "the size chosen in the first folder must be saved for it")

            // Let any stale debounce run out, then check it did not land on the
            // folder that was opened after it.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let leaked = await catalog.sourceState(secondKey)
            XCTAssertNotEqual(leaked?.thumbnailSize, 300,
                              "the first folder's size must not be written under the second")
        }
    }
}
#endif
