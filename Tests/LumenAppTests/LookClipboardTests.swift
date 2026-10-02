// LookClipboardTests.swift
// Copy Look / Paste Look with nothing to copy (W2/D1-04).
//
// `copiedLook` was a plain stored property beside a `@Published copiedRecipe` whose own
// comment explains why it has to be published (the menu greys its items on it), so there
// was no `hasCopiedLook` and Paste Look was always enabled: ⌥⌘V on a fresh launch did
// nothing, with no message. And `copyLook()` was `copiedLook = primarySelection.map {…}`,
// so ⌥⌘C with the selection cleared assigned nil and threw the copied look away —
// `copySettings()` had the same shape.
//
// Substitutions, each red: the `.map` form of either copy → the clipboard is empty after
// the second copy; `hasCopiedLook` does not exist without the fix.
#if os(macOS)

import AppKit
import XCTest
import LumenCore
@testable import LumenApp

final class LookClipboardTests: XCTestCase {

    @MainActor
    private func withSelectedPhoto(_ run: (AppState, PhotoItem) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-look-clipboard-\(UUID().uuidString)")
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
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: photos.appendingPathComponent("frame.png"))
        state.openFolder(photos)
        for _ in 0..<500 where state.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let item = try XCTUnwrap(state.allPhotos.first)
        state.select(item)
        try await run(state, item)
    }

    @MainActor
    func testPasteLookHasNothingToOfferBeforeACopy() async throws {
        try await withSelectedPhoto { state, _ in
            XCTAssertFalse(state.hasCopiedLook,
                           "Paste Look offered itself with nothing on the clipboard")
            state.copyLook()
            XCTAssertTrue(state.hasCopiedLook)
        }
    }

    @MainActor
    func testACopyWithNothingSelectedKeepsTheClipboard() async throws {
        try await withSelectedPhoto { state, _ in
            state.copyLook()
            state.copySettings()
            state.primarySelection = nil
            state.copyLook()
            state.copySettings()
            XCTAssertTrue(state.hasCopiedLook,
                          "⌥⌘C with nothing selected emptied the look clipboard")
            XCTAssertTrue(state.hasCopiedSettings,
                          "⌘C with nothing selected emptied the settings clipboard")
        }
    }
}

#endif
