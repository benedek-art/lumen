// ResponsivenessHistoryTests.swift
// Auto Tone's asynchronous landing and the undo stack.
//
// `applyAutoToneSuggestions` lands after a render, so two things can be true by then
// that were not when Auto was pressed: the suggestion may equal the tone the photo
// already has (Auto pressed twice), and the photo may no longer be in the open roll
// (a folder switch during the measurement). The first recorded a no-op "Auto Tone"
// undo step; the second wrote starting-recipe-plus-Auto over a closed photograph's
// real edit and recorded an undo step for it.
#if os(macOS)
import AppKit
import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessHistoryTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-responsiveness-history-\(UUID())")
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
        try await run(state, root)
    }

    @MainActor private func png(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
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
    func testAutoToneLandingTwiceWithTheSameToneIsOneUndoStep() async throws {
        try await withState { state, root in
            let photo = root.appendingPathComponent("photos/frame.png")
            try png(photo)
            state.openFolder(photo.deletingLastPathComponent())
            try await scanned(state)
            let item = try XCTUnwrap(state.allPhotos.first)
            state.select(item)
            let original = state.recipe(for: item)
            var auto = original.develop.tone
            auto.exposure += 0.5
            state.applyAutoToneSuggestions([item.id: auto])
            XCTAssertEqual(state.history.steps.count, 1)
            state.applyAutoToneSuggestions([item.id: auto])
            XCTAssertEqual(state.history.steps.count, 1,
                           "an Auto that changed nothing was recorded as an undo step")
            state.undo()
            XCTAssertEqual(state.recipe(for: item), original,
                           "one undo must take Auto back")
        }
    }

    @MainActor
    func testAutoToneLandingForAPhotoNoLongerOpenWritesNothing() async throws {
        try await withState { state, root in
            let photo = root.appendingPathComponent("photos/frame.png")
            try png(photo)
            state.openFolder(photo.deletingLastPathComponent())
            try await scanned(state)
            let closed = root.appendingPathComponent("elsewhere/gone.png")
            var auto = Tone()
            auto.exposure = 1.5
            state.applyAutoToneSuggestions([closed: auto])
            XCTAssertTrue(state.history.steps.isEmpty,
                          "Auto recorded an undo step for a photo that is not open")
            XCTAssertNil(state.recipes[closed],
                         "Auto wrote a recipe for a photo that is not open")
        }
    }
}
#endif
