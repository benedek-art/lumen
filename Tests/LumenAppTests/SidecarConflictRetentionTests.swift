#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class SidecarConflictRetentionTests: XCTestCase {
    private func fixture(_ body: (URL, URL, Int64, CatalogService, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3, 4]).write(to: original)
        let directory = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: directory)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [original])[original]?.catalogID)
        seed.saveRecipe(Recipe(), url: original, catalogID: id)
        _ = seed.close()
        let service = try CatalogService(directory: directory)
        _ = service.registerAndLoad(folder: root, files: [original])
        try await body(root, original, id, service, directory)
    }

    func testConflictingSidecarPreservesExactBytesAndRestorableBrushSnapshotAcrossReopen() async throws {
        try await fixture { root, original, id, service, directory in
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: original, catalogID: id)
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            let painting = BrushStrokeSet(strokes: [BrushStroke(points: [
                BrushPoint(x: 0.2, y: 0.3, pressure: 0.6),
                BrushPoint(x: 0.7, y: 0.6, pressure: 0.9, t: 120)
            ], size: 0.1, feather: 35, flow: 70)])
            let ref = try painting.blobRef()
            var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = ref
            var external = Recipe(); external.develop.tone.exposure = -1
            external.masks = [Mask(id: "external", components: [component])]
            let payload = try XCTUnwrap(BrushStrokeSidecar.payload(for: external, blob: { $0 == ref ? painting : nil }))
            let content = SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external), strokesPayload: payload)
            let bytes = Data(XMPSidecar.serialize(content).utf8)
            let sidecar = CatalogService.sidecarURL(for: original)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sidecar.path)
            for _ in 0..<2 { _ = service.registerAndLoad(folder: root, files: [original]) }
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            let snapshots = try await service.photoSnapshots(photoID: id)
            XCTAssertEqual(snapshots.count, 1, "repeated scan must not duplicate a conflict")
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
            _ = service.close()
            let reopened = try CatalogService(directory: directory)
            defer { _ = reopened.close() }
            let reopenedSnapshots = try await reopened.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(reopenedSnapshots.first)
            let restored = try await reopened.photoSnapshotRecipe(id: snapshot.id, photoID: id)
            XCTAssertEqual(restored, external)
            XCTAssertEqual(reopened.blobs.strokeSet(for: ref), painting)
            reopened.saveRecipe(restored, url: original, catalogID: id)
            let entries = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertEqual(entries.first?.state.recipe, external)
            XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3, 4]))
        }
    }

    func testFlushPreservesExternalRecipeWithoutAnInterveningScan() async throws {
        try await fixture { root, original, id, service, directory in
            defer { _ = service.close() }
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: original, catalogID: id)
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            var external = Recipe(); external.develop.tone.exposure = -1
            let bytes = Data(XMPSidecar.serialize(SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external))).utf8)
            let sidecar = CatalogService.sidecarURL(for: original)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sidecar.path)
            service.flushSidecars()
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
            let snapshots = try await service.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(snapshots.first)
            let restored = try await service.photoSnapshotRecipe(id: snapshot.id, photoID: id)
            XCTAssertEqual(restored, external)
            let published = try XCTUnwrap(XMPSidecar.parse(String(contentsOf: sidecar, encoding: .utf8))?.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(published.utf8)), local)
        }
    }

    func testOwedRecipeRecoveryDoesNotDowngradeUnreadableOrFutureEdits() async throws {
        for (json, version) in [("{broken", supportedPipelineVersion),
                                ("{}", supportedPipelineVersion + 10),
                                ("{\"pipelineVersion\":\(supportedPipelineVersion + 10)}", supportedPipelineVersion)] {
            try await fixture { root, original, id, service, directory in
                _ = service.close()
                let sidecar = CatalogService.sidecarURL(for: original)
                let before = try Data(contentsOf: sidecar)
                let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
                defer { db.close() }
                try db.debugExecute("UPDATE edit SET recipe = '\(json)', pipeline_version = \(version) WHERE photo_id = \(id) AND is_current = 1;")
                let edit = try XCTUnwrap(db.currentEdit(photoID: id))
                let debt = UnsavedSidecarRecord(photoPath: original.path, photoID: id,
                                               stated: [.recipe, .strokes])
                try db.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([debt]))
                let reopened = try CatalogService(directory: directory)
                XCTAssertNotNil(reopened.unsavedSidecarNotice)
                XCTAssertEqual(reopened.close(), [sidecar.lastPathComponent],
                               "quit must report debt refused before it could be queued")
                XCTAssertEqual(try Data(contentsOf: sidecar), before)
                XCTAssertEqual(try db.currentEdit(photoID: id), edit)
                XCTAssertEqual(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)), [debt],
                               "an unsafe recipe must remain owed for a compatible recovery")
            }
        }
    }

    func testFailedCullingCatalogWriteDoesNotPublishSidecar() async throws {
        try await fixture { root, original, id, service, directory in
            defer { _ = service.close() }
            let sidecar = CatalogService.sidecarURL(for: original)
            let before = try Data(contentsOf: sidecar)
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            try db.debugExecute("CREATE TRIGGER reject_rating BEFORE UPDATE OF rating ON photo WHEN NEW.rating != OLD.rating BEGIN SELECT RAISE(ABORT, 'injected rating refusal'); END;")
            var photo = PhotoItem(id: original); photo.catalogID = id; photo.rating = 5
            service.saveCullingState(photo, labelChanged: false)
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            service.flushSidecars()
            XCTAssertEqual(try db.photo(id: id)?.rating, 0)
            XCTAssertEqual(try Data(contentsOf: sidecar), before)
        }
    }

    func testFailedConflictPreservationRefusesOverwriteUntilRecoveryIsWritable() async throws {
        try await fixture { root, original, id, service, directory in
            defer { _ = service.close() }
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: original, catalogID: id)
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            var external = Recipe(); external.develop.tone.exposure = -1
            let bytes = Data(XMPSidecar.serialize(SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external))).utf8)
            let sidecar = CatalogService.sidecarURL(for: original)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sidecar.path)
            service.conflictBackupWriter = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
            _ = service.registerAndLoad(folder: root, files: [original])
            service.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            let failedSnapshots = try await service.photoSnapshots(photoID: id)
            XCTAssertTrue(failedSnapshots.isEmpty)
            service.conflictBackupWriter = { try $0.write(to: $1, options: .atomic) }
            service.flushSidecars()
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
            let recoveredSnapshots = try await service.photoSnapshots(photoID: id)
            XCTAssertEqual(recoveredSnapshots.count, 1)
        }
    }
}
#endif
