#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

@MainActor
final class AutoToneSourceIntegrityTests: XCTestCase {
    private func png(_ gray: CGFloat) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(NSColor(white: gray, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func scanned(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(30)
        while state.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.isScanning)
        XCTAssertFalse(state.allPhotos.isEmpty)
    }
    private func fixture(_ body: (AppState, CatalogService, URL, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-auto-source-\(UUID())")
        let first = root.appendingPathComponent("first/frame.png")
        let second = root.appendingPathComponent("second/other.png")
        let previews = root.appendingPathComponent("previews")
        for path in [first.deletingLastPathComponent(), second.deletingLastPathComponent(), previews] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try png(0.2).write(to: first); try png(0.7).write(to: second)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { previews })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = try XCTUnwrap(state.catalog)
        state.openFolder(first.deletingLastPathComponent()); try await scanned(state)
        let item = try XCTUnwrap(state.allPhotos.first)
        state.select(item)
        state.updateRecipe { $0.develop.tone.exposure = 0.25 }
        let id = try XCTUnwrap(item.catalogID)
        try await catalog.requireAvailablePhoto(photoID: id)
        catalog.flushSidecars()
        try await body(state, catalog, first, second, root)
    }
    private func publishedExposure(_ photo: URL) throws -> Double {
        let sidecar = try XCTUnwrap(CatalogService.readSidecar(for: photo))
        return try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(sidecar.recipeJSON).utf8)).develop.tone.exposure
    }

    func testLateAutoAfterFolderSwitchCannotWriteOldSidecarOrEnterNewHistory() async throws {
        try await fixture { state, catalog, first, second, root in
            let oldItem = try XCTUnwrap(state.allPhotos.first)
            let oldID = try XCTUnwrap(oldItem.catalogID)
            let request = try XCTUnwrap(state.captureAutoToneSourceContext(for: state.editTargets))
            let oldBytes = try Data(contentsOf: CatalogService.sidecarURL(for: first))
            state.openFolder(second.deletingLastPathComponent()); try await self.scanned(state)
            let current = try XCTUnwrap(state.allPhotos.first)
            state.select(current)
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 0.6 }
            let historyPosition = state.history.position
            let epoch = state.gestureEpoch
            var auto = Tone(); auto.exposure = 1.5
            // This is the actual production post-measurement landing, with its
            // context captured before the source transition rather than fabricated.
            state.applyAutoToneSuggestions([oldItem.id: auto], sourceContext: request)
            XCTAssertEqual(state.history.position, historyPosition)
            XCTAssertTrue(state.sliderGestureActive)
            XCTAssertEqual(state.gestureEpoch, epoch)
            XCTAssertNil(state.recipes[oldItem.id])
            XCTAssertEqual(state.recipe(for: current).develop.tone.exposure, 0.6)
            try await catalog.requireAvailablePhoto(photoID: oldID)
            catalog.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: first)), oldBytes)
            let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { store.close() }
            XCTAssertEqual(try store.currentRecipe(photoID: oldID)?.develop.tone.exposure, 0.25)
            XCTAssertTrue(state.statusMessage?.contains("discarded") == true)
        }
    }

    func testSameURLReplacementDiscardsAutoBeforeClosingGestureOrPersisting() async throws {
        try await fixture { state, catalog, first, _, root in
            let item = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(item.catalogID)
            let request = try XCTUnwrap(state.captureAutoToneSourceContext(for: state.editTargets))
            let before = try Data(contentsOf: CatalogService.sidecarURL(for: first))
            let replacement = try self.png(0.9)
            try replacement.write(to: first, options: .atomic)
            XCTAssertNotEqual(SourceFileIdentity.read(first), item.sourceIdentity)
            XCTAssertNil(state.captureAutoToneSourceContext(for: [item]),
                         "a known stale photo must also refuse before starting a new analysis")
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 0.6 }
            let position = state.history.position
            let epoch = state.gestureEpoch
            var auto = Tone(); auto.exposure = 1.5
            state.applyAutoToneSuggestions([item.id: auto], sourceContext: request)
            XCTAssertEqual(state.recipe(for: item).develop.tone.exposure, 0.6)
            XCTAssertEqual(state.history.position, position)
            XCTAssertTrue(state.sliderGestureActive)
            XCTAssertEqual(state.gestureEpoch, epoch)
            try await catalog.requireAvailablePhoto(photoID: id); catalog.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: first), replacement)
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: first)), before)
            let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { store.close() }
            XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 0.25)
        }
    }

    func testHealthyCapturedAutoStillWinsMidGestureAndSupportsUndoRedo() async throws {
        try await fixture { state, catalog, first, _, root in
            let item = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(item.catalogID)
            let request = try XCTUnwrap(state.captureAutoToneSourceContext(for: state.editTargets))
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 1 }
            let position = state.history.position
            var auto = Tone(); auto.exposure = 0.75
            state.applyAutoToneSuggestions([item.id: auto], sourceContext: request)
            XCTAssertFalse(state.sliderGestureActive)
            XCTAssertEqual(state.history.position, position + 1)
            XCTAssertEqual(state.recipe(for: item).develop.tone.exposure, 0.75)
            state.sliderGesture(active: false)
            try await catalog.requireAvailablePhoto(photoID: id); catalog.flushSidecars()
            XCTAssertEqual(try self.publishedExposure(first), 0.75)
            state.undo()
            XCTAssertEqual(state.recipe(for: item).develop.tone.exposure, 1)
            try await catalog.requireAvailablePhoto(photoID: id); catalog.flushSidecars()
            XCTAssertEqual(try self.publishedExposure(first), 1)
            state.redo()
            try await catalog.requireAvailablePhoto(photoID: id); catalog.flushSidecars()
            XCTAssertEqual(try self.publishedExposure(first), 0.75)
            let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { store.close() }
            XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 0.75)
        }
    }
}
#endif
