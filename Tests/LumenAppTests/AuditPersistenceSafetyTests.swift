#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class AuditPersistenceSafetyTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-persistence-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSidecarWriteFailureNotifiesOnceAndRetriesLatestEdit() throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1, 2, 3]).write(to: photo)
        let sidecar = photo.appendingPathExtension("xmp")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var notices: [String] = []
        service.onFailure = { notices.append($0) }
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1
        service.saveRecipe(recipe, url: photo, catalogID: id)
        // Registration is a serial-queue barrier after the asynchronous save.
        _ = service.registerAndLoad(folder: root, files: [photo])
        service.flushSidecars()
        service.flushSidecars()
        XCTAssertEqual(notices.count, 1, "REL-09: report the outage without spamming each retry")
        XCTAssertTrue(notices.first?.contains("frame.JPG.xmp") == true)
        recipe.develop.tone.exposure = 2
        service.saveRecipe(recipe, url: photo, catalogID: id)
        _ = service.registerAndLoad(folder: root, files: [photo])
        try FileManager.default.removeItem(at: sidecar)
        service.flushSidecars()
        let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        let json = try XCTUnwrap(content.recipeJSON)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure, 2)
        // A new outage after success must be reported again.
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        service.saveRecipe(recipe, url: photo, catalogID: id)
        _ = service.registerAndLoad(folder: root, files: [photo])
        service.flushSidecars()
        XCTAssertEqual(notices.count, 2)
    }

    func testBlobCopyFailureDoesNotPublishAnIncompleteBackup() throws {
        let root = try scratch()
        let catalog = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: catalog)
        let brush = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.5, y: 0.5)])])
        let ref = try service.blobs.store(brush)
        let blob = try XCTUnwrap(service.blobs.url(for: ref))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blob.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blob.path) }
        guard !FileManager.default.isReadableFile(atPath: blob.path) else {
            service.close()
            throw XCTSkip("Runner bypasses file permissions; cannot inject unreadable payload")
        }
        var notices: [String] = []
        service.onFailure = { notices.append($0) }
        service.close()
        XCTAssertTrue(notices.contains { $0.contains("backed up") }, "Ensure the injected fault actually reached backup")
        let names = try FileManager.default.contentsOfDirectory(atPath: catalog.appendingPathComponent("backups").path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".db") }, "REL-08: no restore-eligible database before blobs succeed")
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })
    }

    func testClosingCancelsDeferredSidecarWriters() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("closed.JPG")
        try Data([1, 2, 3]).write(to: photo)
        let path = photo.appendingPathExtension("xmp")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1
        service.saveRecipe(recipe, url: photo, catalogID: id)
        service.close()
        try FileManager.default.removeItem(at: path)
        // The original two-second debounce remains enqueued after close. It must
        // not revive a failed write, even if the volume becomes writable again.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testPublishedBackupRestoresItsActualBrushPayload() throws {
        let root = try scratch()
        let catalog = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: catalog)
        let brush = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.2, y: 0.6), BrushPoint(x: 0.8, y: 0.6)])])
        let ref = try service.blobs.store(brush)
        let blob = try XCTUnwrap(service.blobs.url(for: ref))
        let payload = try Data(contentsOf: blob)
        let photo = root.appendingPathComponent("brush.JPG")
        try Data([1, 2, 3]).write(to: photo)
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var component = MaskComponent(op: .add, kind: .brush)
        component.strokesRef = ref
        var recipe = Recipe()
        recipe.masks = [Mask(id: "paint", name: "Paint", components: [component])]
        service.saveRecipe(recipe, url: photo, catalogID: id)
        service.close()
        let snapshots = try FileManager.default.contentsOfDirectory(at: catalog.appendingPathComponent("backups"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "db" }
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNotNil(BackupRetention.timestamp(inBackupName: snapshot.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: snapshot.deletingPathExtension().appendingPathExtension("blobs").appendingPathComponent(blob.lastPathComponent)), payload)
        // Simulate loss of this test's live database and blob, retaining only backup.
        try FileManager.default.removeItem(at: blob)
        try Data("damaged isolated catalog".utf8).write(to: catalog.appendingPathComponent("lumen.db"))
        let recovered = try CatalogService(directory: catalog)
        defer { recovered.close() }
        guard case .restored = recovered.recovery.outcome else { return XCTFail("Expected backup restore") }
        XCTAssertEqual(recovered.blobs.data(for: ref), payload)
        let restoredBrush = try XCTUnwrap(recovered.blobs.strokeSet(for: ref))
        let expectedMask = MaskRaster.rasterize(component: component, size: (64, 64), strokes: brush)
        let restoredMask = MaskRaster.rasterize(component: component, size: (64, 64), strokes: restoredBrush)
        var covered = 0
        for y in 0..<64 { for x in 0..<64 {
            XCTAssertEqual(restoredMask[x, y], expectedMask[x, y])
            if restoredMask[x, y] > 0 { covered += 1 }
        } }
        XCTAssertGreaterThan(covered, 0, "Restoration must recover a painting, not two empty masks")
        let loaded = recovered.registerAndLoad(folder: root, files: [photo])[photo]
        XCTAssertEqual(loaded?.recipe?.masks.first?.components.first?.strokesRef, ref)
    }
}
#endif
