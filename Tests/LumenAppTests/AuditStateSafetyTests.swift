#if os(macOS)
import AppKit
import XCTest
import LumenCore
@testable import LumenApp

final class AuditStateSafetyTests: XCTestCase {
    @MainActor
    private func withState(quitInBody: Bool = false, _ run: (AppState, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-state-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Opening a roll normally remembers it. Preserve the user's defaults while
        // exercising the production path against an entirely separate catalog.
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            if !quitInBody { state.prepareToQuit() }
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        try await run(state, root)
    }

    @MainActor private func png(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    func testUndoDuringGesturePersistsUndoThroughReleaseAndQuit() async throws {
        try await checkUndo(closeBeforeUndo: false, redo: false)
    }

    @MainActor
    func testUndoAfterGestureStillPersistsCorrectly() async throws {
        try await checkUndo(closeBeforeUndo: true, redo: false)
    }

    @MainActor
    func testRedoDuringGesturePersistsTheRedoneValue() async throws {
        try await checkUndo(closeBeforeUndo: false, redo: true)
    }

    @MainActor private func checkUndo(closeBeforeUndo: Bool, redo: Bool) async throws {
        try await withState(quitInBody: true) { state, root in
            let photo = root.appendingPathComponent("photos/frame.png")
            try png(photo)
            state.openFolder(photo.deletingLastPathComponent())
            try await scanned(state)
            let item = try XCTUnwrap(state.allPhotos.first)
            state.select(item)
            let original = state.recipe(for: item).develop.tone.exposure
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = original + 1 }
            if closeBeforeUndo { state.sliderGesture(active: false) }
            state.undo()
            if redo { state.redo() }
            let expected = redo ? original + 1 : original
            XCTAssertEqual(state.recipe(for: item).develop.tone.exposure, expected)
            state.sliderGesture(active: false)
            state.prepareToQuit()
            let reopened = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path,
                                             cachePath: root.appendingPathComponent("read-cache.db").path)
            defer { reopened.close() }
            let id = try XCTUnwrap(item.catalogID)
            XCTAssertEqual(try reopened.currentRecipe(photoID: id)?.develop.tone.exposure, expected)
            let sidecar = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: photo.appendingPathExtension("xmp"))))
            let json = try XCTUnwrap(sidecar.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure, expected)
        }
    }

    /// UX-01's sibling: Auto's asynchronous measurement lands mid-drag and no further
    /// drag event follows. The release must not flush the slider's older value over
    /// Auto's in the catalog and the sidecar.
    @MainActor
    func testAutoToneLandingMidGestureSurvivesReleaseAndQuit() async throws {
        try await withState(quitInBody: true) { state, root in
            let photo = root.appendingPathComponent("photos/frame.png")
            try png(photo)
            state.openFolder(photo.deletingLastPathComponent())
            try await scanned(state)
            let item = try XCTUnwrap(state.allPhotos.first)
            state.select(item)
            let original = state.recipe(for: item).develop.tone.exposure
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = original + 1 }
            var auto = Tone()
            auto.exposure = original + 0.25
            state.applyAutoToneSuggestions([item.id: auto])
            state.sliderGesture(active: false)
            state.prepareToQuit()
            XCTAssertEqual(state.recipe(for: item).develop.tone.exposure, original + 0.25)
            let reopened = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path,
                                             cachePath: root.appendingPathComponent("read-cache.db").path)
            defer { reopened.close() }
            let id = try XCTUnwrap(item.catalogID)
            XCTAssertEqual(try reopened.currentRecipe(photoID: id)?.develop.tone.exposure, original + 0.25,
                           "the gesture release overwrote Auto in the catalog")
            let sidecar = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: photo.appendingPathExtension("xmp"))))
            let json = try XCTUnwrap(sidecar.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure,
                           original + 0.25)
        }
    }

    @MainActor
    func testCommonParentStopsAtFirstDifferentComponent() async throws {
        try await withState { _, root in
            let a = root.appendingPathComponent("day1/photos/frame.png")
            let b = root.appendingPathComponent("day2/photos/frame.png")
            try png(a); try png(b)
            XCTAssertEqual(AppState.commonParent(of: [a,b])?.standardizedFileURL.path, root.standardizedFileURL.path)
            XCTAssertEqual(AppState.commonParent(of: [a])?.path, a.deletingLastPathComponent().path)
            XCTAssertNil(AppState.commonParent(of: []))
        }
    }

    @MainActor
    func testUndoDoesNotLoseAnotherPhotosPendingEditAndNextGestureWorks() async throws {
        try await withState(quitInBody: true) { state, root in
            let a = root.appendingPathComponent("photos/a.png"), b = root.appendingPathComponent("photos/b.png")
            try png(a); try png(b)
            state.openFolder(a.deletingLastPathComponent())
            try await scanned(state)
            // The scanner normalizes /var to /private/var on macOS.
            let first = try XCTUnwrap(state.allPhotos.first {
                $0.id.resolvingSymlinksInPath() == a.resolvingSymlinksInPath()
            })
            let second = try XCTUnwrap(state.allPhotos.first {
                $0.id.resolvingSymlinksInPath() == b.resolvingSymlinksInPath()
            })
            state.select(first)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 2 }
            state.select(second)
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 1 }
            state.undo()
            state.sliderGesture(active: false)
            XCTAssertEqual(state.recipe(for: first).develop.tone.exposure, 2)
            XCTAssertEqual(state.recipe(for: second).develop.tone.exposure, 0)
            state.sliderGesture(active: true)
            state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = -1 }
            state.sliderGesture(active: false)
            state.prepareToQuit()
            let reopened = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { reopened.close() }
            for (item, expected) in [(first, 2.0), (second, -1.0)] {
                XCTAssertEqual(try reopened.currentRecipe(photoID: XCTUnwrap(item.catalogID))?.develop.tone.exposure, expected)
                let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: item.id.appendingPathExtension("xmp"))))
                let json = try XCTUnwrap(content.recipeJSON)
                XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure, expected)
            }
        }
    }

    @MainActor
    func testSelectedFilesFromSiblingTreesKeepDistinctCatalogIdentity() async throws {
        try await withState { state, root in
            let a = root.appendingPathComponent("day1/photos/frame.png")
            let b = root.appendingPathComponent("day2/photos/frame.png")
            try png(a); try png(b)
            state.openSources([a,b])
            try await scanned(state)
            XCTAssertEqual(state.allPhotos.count, 2)
            XCTAssertEqual(Set(state.allPhotos.compactMap(\.catalogID)).count, 2, "BR-01: distinct originals must not share a row")
        }
    }

    @MainActor
    func testOpeningSubsetDoesNotMarkOtherPhotosMissing() async throws {
        try await withState { state, root in
            let folder = root.appendingPathComponent("photos")
            let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
            try png(a); try png(b)
            state.openFolder(folder)
            try await scanned(state)
            XCTAssertEqual(state.allPhotos.count, 2)
            state.openSources([a])
            try await scanned(state)
            XCTAssertEqual(state.allPhotos.count, 1, "The visible roll is still the chosen subset")
            var query = PhotoQuery()
            query.includeMissing = false
            let rows = await state.catalog?.photos(matching: query, folderPath: folder.path)
            XCTAssertEqual(rows?.count, 2, "BR-02: a partial listing cannot declare an unobserved file absent")
            try FileManager.default.removeItem(at: b)
            state.openFolder(folder)
            try await scanned(state)
            let afterFullScan = await state.catalog?.photos(matching: query, folderPath: folder.path)
            XCTAssertEqual(afterFullScan?.count, 1, "A complete scan must still notice actual deletion")
        }
    }

    /// V7 D6: a remembered picked set whose files are all gone must not reopen as an
    /// unrestricted scan of their common parent (which can be ~ or /).
    @MainActor
    func testRelaunchWithEveryPickedFileGoneOpensNothing() async throws {
        try await withState(quitInBody: true) { state, root in
            let a = root.appendingPathComponent("day1/a.png")
            let b = root.appendingPathComponent("day2/b.png")
            let bystander = root.appendingPathComponent("elsewhere/c.png")
            try png(a); try png(b); try png(bystander)
            state.openSources([a, b])
            try await scanned(state)
            XCTAssertEqual(state.allPhotos.count, 2)
            state.prepareToQuit()

            try FileManager.default.removeItem(at: a)
            try FileManager.default.removeItem(at: b)
            let relaunched = AppState(catalogDirectory: { root.appendingPathComponent("catalog2") },
                                      previewDirectory: { root.appendingPathComponent("previews2") })
            defer { relaunched.prepareToQuit() }
            relaunched.reopenLastFolder()
            XCTAssertNil(relaunched.folderURL,
                         "the vanished selection reopened as a scan of its root")
            XCTAssertFalse(relaunched.isScanning)
            XCTAssertEqual(relaunched.statusMessage, AppState.pickedSetGoneMessage)
        }
    }

    /// V7 D7: a dropped web link, or a folder with nothing Lumen opens in it plus a
    /// stray file, must not replace the open roll or be remembered for the next launch.
    @MainActor
    func testNothingOpenableLeavesTheOpenRollAndTheMemoryAlone() async throws {
        try await withState { state, root in
            let folder = root.appendingPathComponent("photos")
            try png(folder.appendingPathComponent("a.png"))
            state.openFolder(folder)
            try await scanned(state)
            let remembered = UserDefaults.standard.data(forKey: "lumen.lastFolder.bookmark")

            state.openSources([try XCTUnwrap(URL(string: "https://example.com/y"))])
            XCTAssertEqual(state.folderURL, folder, "a web link replaced the open folder")
            XCTAssertEqual(state.statusMessage, AppState.nothingToOpenMessage)

            // Two directories with no photographs in them, beside a file Lumen does not
            // open: only the off-main walk can say they are empty, and it must say so
            // without having replaced the roll first. (ONE folder on its own is still
            // the plain folder open it always was, empty or not.)
            let empty = root.appendingPathComponent("empty")
            let alsoEmpty = root.appendingPathComponent("also-empty")
            for directory in [empty, alsoEmpty] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let notes = root.appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: notes)
            state.statusMessage = ""
            state.openSources([empty, alsoEmpty, notes])
            for _ in 0..<500 where state.statusMessage != AppState.nothingToOpenMessage {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(state.statusMessage, AppState.nothingToOpenMessage)
            XCTAssertEqual(state.folderURL, folder, "an empty expansion replaced the open folder")
            XCTAssertEqual(state.allPhotos.count, 1)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "lumen.lastFolder.bookmark"), remembered,
                           "a refused open was remembered for the next launch")
        }
    }
}
#endif
