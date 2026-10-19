#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenApp

final class FutureSidecarActionSafetyTests: XCTestCase {
    @MainActor
    private func withState(_ body: (AppState, CatalogService, PhotoItem, Recipe, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-future-actions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let presetKey = "dev.lumenapp.exportRecipes"
        let previous = UserDefaults.standard.object(forKey: presetKey)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            if let previous { UserDefaults.standard.set(previous, forKey: presetKey) }
            else { UserDefaults.standard.removeObject(forKey: presetKey) }
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: source)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [source])[source]?.catalogID)
        state.primarySelection = photo
        var existing = state.recipe(for: photo); existing.develop.tone.exposure = 0.75
        state.recipes[source] = existing
        catalog.saveRecipe(existing, url: source, catalogID: photo.catalogID)
        _ = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
        catalog.flushSidecars()
        try await body(state, catalog, photo, existing, root)
    }

    private func writeFuture(for photo: PhotoItem) throws -> Data {
        var incoming = Recipe(); incoming.develop.tone.exposure = -1.5
        let bytes = Data(XMPSidecar.serialize(SidecarContent(pipelineVersion: supportedPipelineVersion + 10,
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming),
            strokesPayload: "opaque-future-painting-v99")).utf8)
        try bytes.write(to: CatalogService.sidecarURL(for: photo.id))
        return bytes
    }

    @MainActor
    private func markUsingCullingFlush(_ catalog: CatalogService, photo: PhotoItem, root: URL) async throws {
        var rated = photo; rated.rating = 4
        catalog.saveCullingState(rated, labelChanged: false)
        _ = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
        catalog.flushSidecars()
    }

    @MainActor
    private func finishExport(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(30)
        while state.isExporting && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.isExporting)
    }

    @MainActor
    func testStaleSelectionCannotExportUnavailableEditWithoutKeywords() async throws {
        try await withState { state, catalog, photo, _, root in
            let delivery = root.appendingPathComponent("delivery")
            try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
            state.exportRecipes = [ExportRecipe(name: "No tags", metadata: MetadataPolicy(includeKeywords: false), filenameTemplate: "baseline")]
            state.export(to: delivery)
            try await self.finishExport(state)
            XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.appendingPathComponent("baseline.jpg").path),
                          "the generated source must be deliverable before it becomes unavailable")
            _ = try self.writeFuture(for: photo)
            try await self.markUsingCullingFlush(catalog, photo: photo, root: root)
            XCTAssertEqual(state.primarySelection?.id, photo.id, "keep the stale AppState selection for this regression")
            state.exportRecipes = [ExportRecipe(name: "No tags", metadata: MetadataPolicy(includeKeywords: false), filenameTemplate: "blocked")]
            state.export(to: delivery)
            try await self.finishExport(state)
            XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.appendingPathComponent("blocked.jpg").path))
            let report = try XCTUnwrap(state.operationReports.first)
            XCTAssertEqual(report.records.first?.outcome, .failed)
            XCTAssertTrue(report.records.first?.detail?.contains("unavailable") == true)
        }
    }

    @MainActor
    func testSnapshotReadCreateAndActualRestoreRefuseMarkedPhotoWithoutChangingMemoryOrHistory() async throws {
        try await withState { state, catalog, photo, existing, root in
            let id = try XCTUnwrap(photo.catalogID)
            await state.createPhotoSnapshot(named: "Safe")
            let snapshots = try await catalog.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(snapshots.first)
            var current = existing; current.develop.tone.exposure = 1.25
            state.recipes[photo.id] = current
            catalog.saveRecipe(current, url: photo.id, catalogID: id)
            _ = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
            catalog.flushSidecars()
            _ = try self.writeFuture(for: photo)
            try await self.markUsingCullingFlush(catalog, photo: photo, root: root)
            await state.restorePhotoSnapshot(snapshot)
            XCTAssertEqual(state.recipe(for: photo), current)
            XCTAssertNotNil(state.photoSnapshots.error)
            do { _ = try await catalog.photoSnapshotRecipe(id: snapshot.id, photoID: id); XCTFail("marked snapshot must not be returned for restore") }
            catch { }
            do { try await catalog.createPhotoSnapshot(recipe: existing, photoID: id, name: "Blocked"); XCTFail("marked photo must not create an apparent current snapshot") }
            catch { }
            let after = try await catalog.photoSnapshots(photoID: id)
            XCTAssertEqual(after, snapshots)
        }
    }

    @MainActor
    func testRelinkPreparationAndPreviouslyPreparedCommitRefuseUnavailablePhoto() async throws {
        try await withState { _, catalog, photo, _, root in
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            try db.setQuickSig(QuickSignature.compute(url: photo.id), photoID: id)
            let moved = root.appendingPathComponent("moved/source.JPG")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: photo.id, to: moved)
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: moved)
            let before = try db.photo(id: id)
            _ = try self.writeFuture(for: photo)
            try await self.markUsingCullingFlush(catalog, photo: photo, root: root)
            do { _ = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: moved); XCTFail("marked photo must not prepare a relink") }
            catch { }
            do { _ = try await catalog.commitOriginalRelink(prepared); XCTFail("a marker discovered after preparation must refuse commit") }
            catch { }
            let after = try db.photo(id: id)
            XCTAssertEqual(after?.folderID, before?.folderID)
            XCTAssertEqual(after?.filename, before?.filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: photo.id.path))
        }
    }

    @MainActor
    func testRejectedMarkerWriteLatchesQuerySaveAndExportRefusalForThisSession() async throws {
        try await withState { state, catalog, photo, _, root in
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            let before = try db.currentEdit(photoID: id)
            let bytes = try self.writeFuture(for: photo)
            try db.debugExecute("CREATE TRIGGER reject_future_marker BEFORE INSERT ON meta WHEN NEW.key LIKE 'sidecar_unavailable_v1:%' BEGIN SELECT RAISE(ABORT, 'injected marker refusal'); END;")
            let loaded = catalog.registerAndLoad(folder: root, files: [photo.id])
            XCTAssertNil(loaded[photo.id], "failed registration must not become an editable default")
            let entries = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertTrue(entries.isEmpty, "in-memory containment must survive marker persistence failure")
            do { try await catalog.requireAvailablePhoto(photoID: id); XCTFail("failed marker write must not authorize action") }
            catch { }
            var rejected = Recipe(); rejected.develop.tone.exposure = 2
            catalog.saveRecipe(rejected, url: photo.id, catalogID: id)
            _ = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertEqual(try db.currentEdit(photoID: id), before)
            XCTAssertNil(try db.metaValue("sidecar_unavailable_v1:\(id)"), "this test cannot claim durable containment when the write was refused")
            let delivery = root.appendingPathComponent("delivery")
            try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
            state.exportRecipes = [ExportRecipe(name: "No tags", metadata: MetadataPolicy(includeKeywords: false), filenameTemplate: "blocked")]
            state.export(to: delivery)
            try await self.finishExport(state)
            XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.appendingPathComponent("blocked.jpg").path))
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photo.id)), bytes)
        }
    }
    @MainActor
    func testFailedMarkerLatchClearsOnlyAfterSupportedRecoveryPersists() async throws {
        try await withState { _, catalog, photo, _, root in
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            _ = try self.writeFuture(for: photo)
            try db.debugExecute("CREATE TRIGGER reject_marker BEFORE INSERT ON meta WHEN NEW.key LIKE 'sidecar_unavailable_v1:%' BEGIN SELECT RAISE(ABORT, 'injected marker refusal'); END;")
            _ = catalog.registerAndLoad(folder: root, files: [photo.id])
            do { try await catalog.requireAvailablePhoto(photoID: id); XCTFail("failed marker must latch unavailable state") }
            catch { }
            var supported = Recipe(); supported.develop.tone.exposure = 1.25
            let supportedBytes = Data(XMPSidecar.serialize(SidecarContent(
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(supported))).utf8)
            try supportedBytes.write(to: CatalogService.sidecarURL(for: photo.id))
            // A valid replacement alone does not authorize release if durable
            // reconciliation fails. ON CONFLICT still executes this INSERT trigger.
            try db.debugExecute("CREATE TRIGGER reject_observation BEFORE INSERT ON meta WHEN NEW.key LIKE 'sidecar_bytes_v1:%' BEGIN SELECT RAISE(ABORT, 'injected observation refusal'); END;")
            let refused = catalog.registerAndLoad(folder: root, files: [photo.id])
            XCTAssertTrue(try XCTUnwrap(refused[photo.id]).recipeUnavailable)
            do { try await catalog.requireAvailablePhoto(photoID: id); XCTFail("failed recovery must not clear the session latch") }
            catch { }
            let unavailable = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertTrue(unavailable.isEmpty)
            try db.debugExecute("DROP TRIGGER reject_observation;")
            try db.debugExecute("DROP TRIGGER reject_marker;")
            let recovered = catalog.registerAndLoad(folder: root, files: [photo.id])
            XCTAssertFalse(try XCTUnwrap(recovered[photo.id]).recipeUnavailable)
            XCTAssertEqual(recovered[photo.id]?.recipe, supported)
            try await catalog.requireAvailablePhoto(photoID: id)
            let available = try await catalog.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertEqual(available.first?.state.recipe, supported)
            XCTAssertNil(try db.metaValue("sidecar_unavailable_v1:\(id)"))
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photo.id)), supportedBytes)
        }
    }

}
#endif
