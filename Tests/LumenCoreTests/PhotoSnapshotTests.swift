#if canImport(SQLite3)
import Foundation
import XCTest
@testable import LumenCore

final class PhotoSnapshotTests: XCTestCase {
    func testTwoPhotosRelaunchNamesDeletionAndBackupKeepIndependentImmutableEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.db").path
        var store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: "/Photos")
        _ = try store.scan(folderID: folder, files: ["a.JPG", "b.JPG"].map {
            ScannedFile(filename: $0, fileSize: 1, fileMTime: 1, ext: "jpg")
        })
        let a = try XCTUnwrap(store.photo(folderID: folder, filename: "a.JPG"))
        let b = try XCTUnwrap(store.photo(folderID: folder, filename: "b.JPG"))
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        try store.saveRecipe(recipe, photoID: a.id, isCurrent: true)
        let snapshot = try store.createNamedSnapshot(recipe, photoID: a.id, name: "Warm")
        _ = try store.createNamedSnapshot(Recipe(), photoID: b.id, name: "Warm")
        XCTAssertThrowsError(try store.createNamedSnapshot(recipe, photoID: a.id, name: " Warm "))
        XCTAssertThrowsError(try store.namedSnapshot(id: snapshot, photoID: b.id))
        XCTAssertThrowsError(try store.deleteNamedSnapshot(id: snapshot, photoID: b.id))
        recipe.develop.tone.exposure = 2.5
        try store.saveRecipe(recipe, photoID: a.id, isCurrent: true)
        XCTAssertTrue(try XCTUnwrap(store.photo(id: a.id)).edited)
        let backup = root.appendingPathComponent("backup.db")
        try store.backup(to: backup.path)
        store.close()
        store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        XCTAssertEqual(try store.namedSnapshots(photoID: a.id).count, 1)
        let saved = try store.namedSnapshot(id: snapshot, photoID: a.id)
        XCTAssertFalse(saved.isCurrent)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(saved.recipeJSON.utf8)).develop.tone.exposure, 1.25)
        XCTAssertEqual(try store.currentRecipe(photoID: a.id)?.develop.tone.exposure, 2.5)
        try store.deleteNamedSnapshot(id: snapshot, photoID: a.id)
        XCTAssertTrue(try store.namedSnapshots(photoID: a.id).isEmpty)
        XCTAssertEqual(try store.namedSnapshots(photoID: b.id).count, 1)
        XCTAssertEqual(try store.currentRecipe(photoID: a.id)?.develop.tone.exposure, 2.5)
        store.close()
        let backedUp = try CatalogStore(path: backup.path, cachePath: root.appendingPathComponent("backup-cache.db").path)
        defer { backedUp.close() }
        XCTAssertEqual(try backedUp.namedSnapshots(photoID: a.id).count, 1)
    }

    func testPayloadValidationUsesDiskAndBackupPreservesSnapshotOnlyPainting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-blobs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(directory: root.appendingPathComponent("blobs"))
        let set = BrushStrokeSet()
        let ref = try blobs.store(set)
        var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = ref
        var recipe = Recipe(); recipe.masks = [Mask(id: "painted", components: [component])]
        try PhotoSnapshotDependencies.validate(recipe, blobs: blobs)
        let store = try CatalogStore(path: root.appendingPathComponent("catalog.db").path,
            cachePath: root.appendingPathComponent("cache.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: "/Photos")
        _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "a.JPG", fileSize: 1, fileMTime: 1, ext: "jpg")])
        let photo = try XCTUnwrap(store.photo(folderID: folder, filename: "a.JPG"))
        let snapshot = try store.createNamedSnapshot(recipe, photoID: photo.id, name: "Painted")
        try store.saveRecipe(Recipe(), photoID: photo.id, isCurrent: true)
        let backedUpDB = root.appendingPathComponent("backup.db")
        try store.backup(to: backedUpDB.path)
        let backup = root.appendingPathComponent("backup.blobs")
        try blobs.backUp(to: backup)
        let location = try XCTUnwrap(blobs.url(for: ref))
        try FileManager.default.removeItem(at: location)
        XCTAssertNotNil(blobs.strokeSet(for: ref), "cache remains warm")
        XCTAssertThrowsError(try PhotoSnapshotDependencies.validate(recipe, blobs: blobs))
        let saved = try CatalogStore(path: backedUpDB.path, cachePath: root.appendingPathComponent("backup-cache.db").path)
        defer { saved.close() }
        let savedRecipe = try CanonicalJSON.decodeRecipe(from: Data(saved.namedSnapshot(id: snapshot, photoID: photo.id).recipeJSON.utf8))
        XCTAssertEqual(savedRecipe.masks.first?.components.first?.strokesRef, ref)
        try blobs.restore(from: backup)
        try PhotoSnapshotDependencies.validate(recipe, blobs: blobs)
        try Data("corrupt".utf8).write(to: location)
        XCTAssertThrowsError(try PhotoSnapshotDependencies.validate(recipe, blobs: blobs))
    }
}
#endif
