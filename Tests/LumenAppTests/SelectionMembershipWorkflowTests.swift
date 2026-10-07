#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import LumenApp

@MainActor
final class SelectionMembershipWorkflowTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate(), "isolated AppState workflow did not settle")
    }

    private func withRoll(_ test: (AppState, URL, [PhotoItem]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-selection-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let folder = try makeRoll(root: root, name: "first")
        state.openFolder(folder)
        try await waitUntil { !state.isScanning }
        XCTAssertEqual(state.allPhotos.count, 12)
        try await test(state, root, state.allPhotos)
    }

    private func makeRoll(root: URL, name: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<6 { for x in 0..<8 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 128; pixels[offset + 1] = 128; pixels[offset + 2] = 128; pixels[offset + 3] = 255
        } }
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for index in 0..<12 {
            try bytes.write(to: folder.appendingPathComponent(String(format: "F%02d.png", index)))
        }
        return folder
    }

    func testSparseAndDenseSelectedPhotosKeepUnfilteredSourceOrderAndIgnoreUnknownIDs() async throws {
        try await withRoll { state, root, items in
            let unknown = root.appendingPathComponent("not-in-roll.png")
            state.selection = [items[8].id, items[2].id, unknown]
            XCTAssertEqual(state.selectedPhotos.map(\.id), [items[2].id, items[8].id])
            state.sortOrder = .filename
            state.sortAscending = false
            try await self.waitUntil { state.photos.map(\.id) == items.reversed().map(\.id) }
            XCTAssertEqual(state.selectedPhotos.map(\.id), [items[2].id, items[8].id])
            state.filter.text = "F02"
            try await self.waitUntil { state.photos.map(\.id) == [items[2].id] }
            XCTAssertEqual(state.selectedPhotos.map(\.id), [items[2].id, items[8].id],
                           "hidden selected photos still belong to export/edit targets")
            state.selection = Set(items.map(\.id)).union([unknown])
            XCTAssertEqual(state.selectedPhotos.map(\.id), items.map(\.id),
                           "dense fallback must preserve source order and ignore unknown IDs too")
        }
    }

    func testRatingMutationInvalidatesWarmSelectionAndReturnsFreshPhotoValues() async throws {
        try await withRoll { state, _, items in
            state.primarySelection = items[2]
            state.selection = [items[8].id, items[2].id]
            let cached = state.selectedPhotos
            XCTAssertEqual(cached.map(\.rating), [0, 0])
            state.setRating(4)
            XCTAssertEqual(state.selectedPhotos.map(\.id), [items[2].id, items[8].id])
            XCTAssertEqual(state.selectedPhotos.map(\.rating), [4, 4])
            XCTAssertEqual(state.allPhotos.first { $0.id == items[5].id }?.rating, 0)
            state.undo()
            XCTAssertEqual(state.selectedPhotos.map(\.rating), [0, 0])
            state.redo()
            XCTAssertEqual(state.selectedPhotos.map(\.rating), [4, 4])
        }
    }

    func testReplacementFolderCannotResolveOldSelectionPositionsIntoNewPhotos() async throws {
        try await withRoll { state, root, oldItems in
            state.selection = [oldItems[2].id, oldItems[8].id]
            XCTAssertEqual(state.selectedPhotos.count, 2) // Warm membership index and value cache.
            let replacement = try self.makeRoll(root: root, name: "replacement")
            state.openFolder(replacement)
            XCTAssertTrue(state.selectedPhotos.isEmpty, "folder opening clears the prior selection")
            try await self.waitUntil { !state.isScanning }
            let newItems = state.allPhotos
            XCTAssertEqual(newItems.count, 12)
            XCTAssertTrue(Set(oldItems.map(\.id)).isDisjoint(with: newItems.map(\.id)))
            // Sparse path deliberately includes an old indexed ID. Reusing the old
            // dictionary would return the replacement photo occupying its old slot.
            state.selection = [oldItems[2].id, newItems[7].id]
            XCTAssertEqual(state.selectedPhotos.map(\.id), [newItems[7].id])
            XCTAssertTrue(state.selectedPhotos.allSatisfy { $0.id.deletingLastPathComponent().resolvingSymlinksInPath() == replacement.resolvingSymlinksInPath() })
        }
    }
}
#endif
