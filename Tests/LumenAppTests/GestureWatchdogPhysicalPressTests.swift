#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

@MainActor
final class GestureWatchdogPhysicalPressTests: XCTestCase {
    private func fixture(button: @escaping @MainActor () -> Bool,
                         body: (AppState, CatalogService, PhotoItem, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-held-watchdog-\(UUID())")
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.JPG")
        // Synthetic bytes supply a filesystem/catalog identity. This is not a
        // valid-image or decoder test, and no view or private photo is involved.
        try Data([1, 2, 3]).write(to: file)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
            previewDirectory: { root.appendingPathComponent("previews") }, primaryButtonPressed: button)
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        state.openFolder(folder, restrictedTo: [file])
        let deadline = Date().addingTimeInterval(5)
        while state.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.isScanning)
        let photo = try XCTUnwrap(state.allPhotos.first)
        state.select(photo)
        try await body(state, try XCTUnwrap(state.catalog), photo, folder)
    }

    func testStationaryHeldScalarContinuesOneUndoStepAndDefersWritesUntilNormalRelease() async throws {
        var held = true
        try await fixture(button: { held }) { state, catalog, photo, folder in
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 1 }
            let epoch = try XCTUnwrap(state.recordingEpoch)
            let settle = state.settleTick
            try await Task.sleep(nanoseconds: UInt64((AppState.gestureSilenceTimeout + 0.2) * 1e9))
            XCTAssertEqual(state.recordingEpoch, epoch)
            XCTAssertEqual(state.settleTick, settle)
            let beforeMotion = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
            XCTAssertNotEqual(beforeMotion.first { $0.url == photo.id }?.state.recipe?.develop.tone.exposure, 1)
            // Scalar tracks signal true only at press. A later motion must still use
            // that epoch and keep its new value deferred after the long stationary hold.
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 2 }
            XCTAssertEqual(state.recordingEpoch, epoch)
            XCTAssertEqual(state.history.steps.count, 1)
            let beforeRelease = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
            XCTAssertNotEqual(beforeRelease.first { $0.url == photo.id }?.state.recipe?.develop.tone.exposure, 2)
            held = false
            state.sliderGesture(active: false)
            let released = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
            XCTAssertEqual(released.first { $0.url == photo.id }?.state.recipe?.develop.tone.exposure, 2)
            XCTAssertNil(state.recordingEpoch)
            XCTAssertEqual(state.history.steps.count, 1)
            state.undo()
            XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 0)
        }
    }

    func testLostReleaseFlushesSoonAfterButtonUpWithoutRestartingSilenceClock() async throws {
        var held = true
        try await fixture(button: { held }) { state, catalog, photo, folder in
            state.sliderGesture(active: true)
            state.updateRecipe { $0.develop.tone.exposure = 1.75 }
            let epoch = try XCTUnwrap(state.recordingEpoch)
            try await Task.sleep(nanoseconds: UInt64((AppState.gestureSilenceTimeout + 0.2) * 1e9))
            XCTAssertEqual(state.recordingEpoch, epoch)
            held = false // The physical release arrives, but SwiftUI's onEnded does not.
            let deadline = Date().addingTimeInterval(2)
            while state.recordingEpoch != nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(state.recordingEpoch,
                         "an expired held-press poll must not restart the eight-second silence clock")
            let saved = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
            XCTAssertEqual(saved.first { $0.url == photo.id }?.state.recipe?.develop.tone.exposure, 1.75)
        }
    }

    func testExplicitReleaseStillClosesImmediatelyForPointerAndNonPointerInputs() async throws {
        for physicalPress in [false, true] {
            try await fixture(button: { physicalPress }) { state, catalog, photo, folder in
                state.sliderGesture(active: true)
                state.updateRecipe { $0.develop.tone.exposure = 0.5 }
                state.sliderGesture(active: false)
                XCTAssertNil(state.recordingEpoch)
                let saved = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
                XCTAssertEqual(saved.first { $0.url == photo.id }?.state.recipe?.develop.tone.exposure, 0.5)
            }
        }
    }
}
#endif
