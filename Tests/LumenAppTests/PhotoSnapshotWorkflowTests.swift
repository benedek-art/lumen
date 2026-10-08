#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class PhotoSnapshotWorkflowTests: XCTestCase {
    @MainActor
    private func waitForSnapshots(_ state: AppState, photoID: Int64) async throws {
        let deadline = Date().addingTimeInterval(3)
        while (state.photoSnapshots.rows.isEmpty || state.photoSnapshots.rows.contains { $0.photoID != photoID }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(state.photoSnapshots.rows.isEmpty)
        XCTAssertTrue(state.photoSnapshots.rows.allSatisfy { $0.photoID == photoID })
    }

    @MainActor
    func testActualStateCreateTargetedRestoreUndoDeleteAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["a.JPG", "b.JPG"].map { root.appendingPathComponent($0) }
        for url in urls { try Data([1, 2, 3]).write(to: url) }
        let directory = root.appendingPathComponent("catalog")
        let state = AppState(catalogDirectory: { directory }, previewDirectory: { root.appendingPathComponent("previews") })
        let catalog = try XCTUnwrap(state.catalog)
        let stored = catalog.registerAndLoad(folder: root, files: urls)
        let photos = try urls.map { url -> PhotoItem in
            var photo = PhotoItem(id: url); photo.catalogID = try XCTUnwrap(stored[url]?.catalogID); return photo
        }
        state.primarySelection = photos[0]
        state.updateRecipe(targets: [photos[0]]) { _, recipe in recipe.develop.tone.exposure = 1 }
        await state.createPhotoSnapshot(named: "Keeper")
        XCTAssertNil(state.photoSnapshots.error)
        let aSnapshots = try await catalog.photoSnapshots(photoID: try XCTUnwrap(photos[0].catalogID))
        let saved = try XCTUnwrap(aSnapshots.first)
        try await waitForSnapshots(state, photoID: saved.photoID)
        state.primarySelection = photos[1]
        await state.createPhotoSnapshot(named: "Keeper")
        // Both loads are in flight before the main actor yields: A's delayed rows
        // must never appear under B after a quick selection switch.
        state.primarySelection = photos[0]
        state.primarySelection = photos[1]
        try await waitForSnapshots(state, photoID: try XCTUnwrap(photos[1].catalogID))
        state.updateRecipe(targets: [photos[1]]) { _, recipe in recipe.develop.tone.exposure = -1 }
        state.primarySelection = photos[0]
        state.updateRecipe(targets: [photos[0]]) { _, recipe in recipe.develop.tone.exposure = 2 }
        await state.restorePhotoSnapshot(saved)
        XCTAssertEqual(state.recipe(for: photos[0]).develop.tone.exposure, 1)
        XCTAssertEqual(state.recipe(for: photos[1]).develop.tone.exposure, -1)
        state.undo()
        XCTAssertEqual(state.recipe(for: photos[0]).develop.tone.exposure, 2)
        state.redo()
        XCTAssertEqual(state.recipe(for: photos[0]).develop.tone.exposure, 1)
        state.prepareToQuit()
        let reopened = AppState(catalogDirectory: { directory }, previewDirectory: { root.appendingPathComponent("previews2") })
        defer { reopened.prepareToQuit() }
        let service = try XCTUnwrap(reopened.catalog)
        let loaded = service.registerAndLoad(folder: root, files: urls)
        XCTAssertEqual(loaded[urls[0]]?.recipe?.develop.tone.exposure, 1)
        let a = try await service.photoSnapshots(photoID: saved.photoID)
        XCTAssertEqual(a.map(\.id), [saved.id])
        reopened.primarySelection = photos[0]
        try await waitForSnapshots(reopened, photoID: saved.photoID)
        await reopened.deletePhotoSnapshot(saved)
        let afterDelete = try await service.photoSnapshots(photoID: saved.photoID)
        XCTAssertTrue(afterDelete.isEmpty)
        let b = try await service.photoSnapshots(photoID: try XCTUnwrap(photos[1].catalogID))
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(loaded[urls[1]]?.recipe?.develop.tone.exposure, -1)
    }

    @MainActor
    func testMissingPayloadRefusesSnapshotWithoutWritingNamedRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-missing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.JPG"); try Data([1]).write(to: url)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { root.appendingPathComponent("previews") })
        defer { state.prepareToQuit() }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: url)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        state.primarySelection = photo
        var component = MaskComponent(op: .add, kind: .brush)
        component.strokesRef = "blob:xxh64:0123456789abcdef"
        state.updateRecipe(targets: [photo]) { _, recipe in recipe.masks = [Mask(id: "m", components: [component])] }
        await state.createPhotoSnapshot(named: "Unsafe")
        XCTAssertNotNil(state.photoSnapshots.error)
        let rows = try await catalog.photoSnapshots(photoID: try XCTUnwrap(photo.catalogID))
        XCTAssertTrue(rows.isEmpty)
    }
    @MainActor
    func testMissingSnapshotPaintingRefusesRestoreAndDeletionKeepsSharedPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.JPG"); try Data([1]).write(to: url)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { root.appendingPathComponent("previews") })
        defer { state.prepareToQuit() }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: url)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        state.primarySelection = photo
        let painting = BrushStrokeSet()
        let ref = try catalog.blobs.store(painting)
        var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = ref
        state.updateRecipe(targets: [photo]) { _, recipe in recipe.masks = [Mask(id: "m", components: [component])] }
        await state.createPhotoSnapshot(named: "Painted")
        let rows = try await catalog.photoSnapshots(photoID: try XCTUnwrap(photo.catalogID))
        let snapshot = try XCTUnwrap(rows.first)
        state.updateRecipe(targets: [photo]) { _, recipe in recipe.develop.tone.exposure = 2 }
        let before = state.recipe(for: photo)
        let blobURL = try XCTUnwrap(catalog.blobs.url(for: ref))
        try FileManager.default.removeItem(at: blobURL)
        await state.restorePhotoSnapshot(snapshot)
        XCTAssertNotNil(state.photoSnapshots.error)
        XCTAssertEqual(state.recipe(for: photo), before)
        _ = try catalog.blobs.store(painting)
        await state.deletePhotoSnapshot(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path), "working edit still needs these bytes")
        XCTAssertEqual(state.recipe(for: photo), before)
    }

}
#endif
