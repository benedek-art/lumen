#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class SidecarByteObservationServiceTests: XCTestCase {
    private func fixture(_ body: (URL, URL, Int64, CatalogService) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-xmp-observation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: photo)
        let directory = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: directory)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        seed.saveRecipe(Recipe(), url: photo, catalogID: id)
        XCTAssertEqual(seed.close(), [])
        let service = try CatalogService(directory: directory)
        try await body(directory, photo, id, service)
    }

    private func external(_ exposure: Double) throws -> (Recipe, Data) {
        var recipe = Recipe(); recipe.develop.tone.exposure = exposure
        return (recipe, Data(XMPSidecar.serialize(SidecarContent(
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(recipe))).utf8))
    }

    func testSameTimestampExternalConflictIsPreservedBeforePendingRecipePublishes() async throws {
        try await fixture { directory, photo, id, service in
            let sidecar = CatalogService.sidecarURL(for: photo)
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: photo, catalogID: id)
            _ = try await service.querySource(scope: .everywhere, folderPath: photo.deletingLastPathComponent().path)
            let (incoming, bytes) = try self.external(-1)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: sidecar.path)
            service.flushSidecars()
            let snapshots = try await service.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(snapshots.first)
            let restored = try await service.photoSnapshotRecipe(id: snapshot.id, photoID: id)
            XCTAssertEqual(restored, incoming)
            let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == bytes })
            XCTAssertEqual(service.close(), [])
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            XCTAssertEqual(try db.currentRecipe(photoID: id), local)
        }
    }

    func testSameTimestampExternalRecipeIsImportedAfterReopen() async throws {
        try await fixture { _, photo, _, service in
            defer { _ = service.close() }
            let sidecar = CatalogService.sidecarURL(for: photo)
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            let (incoming, bytes) = try self.external(1.5)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: sidecar.path)
            let state = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
            XCTAssertEqual(state[photo]?.recipe, incoming)
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }
    func testLegacyBootstrapArchivesDivergenceWithoutInventingChronology() async throws {
        try await fixture { directory, photo, id, service in
            defer { _ = service.close() }
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            try db.setMetaValue("sidecar_bytes_v1:\(id)", nil)
            let sidecar = CatalogService.sidecarURL(for: photo)
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            let (incoming, bytes) = try self.external(-1.5)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: sidecar.path)
            let state = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
            XCTAssertEqual(state[photo]?.recipe, Recipe(), "legacy timestamp precedence stays intact")
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            let snapshots = try await service.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(snapshots.first)
            let restored = try await service.photoSnapshotRecipe(id: snapshot.id, photoID: id)
            XCTAssertEqual(restored, incoming)
            XCTAssertNotNil(try db.metaValue("sidecar_bytes_v1:\(id)"))
        }
    }

    func testMalformedObservationRefusesPendingPublicationAndRetainsDebt() async throws {
        try await fixture { directory, photo, id, service in
            let sidecar = CatalogService.sidecarURL(for: photo)
            let before = try Data(contentsOf: sidecar)
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            try db.setMetaValue("sidecar_bytes_v1:\(id)", "not-a-valid-observation")
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: photo, catalogID: id)
            XCTAssertEqual(service.close(), [sidecar.lastPathComponent])
            XCTAssertEqual(try Data(contentsOf: sidecar), before)
            XCTAssertEqual(try db.currentRecipe(photoID: id), local)
            XCTAssertEqual(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)).count, 1)
        }
    }

    func testScanAcknowledgesCapturedBytesRatherThanAConcurrentReplacement() async throws {
        try await fixture { _, photo, _, service in
            defer { _ = service.close() }
            let sidecar = CatalogService.sidecarURL(for: photo)
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            let (first, firstBytes) = try self.external(0.5)
            let (second, secondBytes) = try self.external(1.5)
            try firstBytes.write(to: sidecar)
            service.sidecarDataReader = { path in
                let captured = try Data(contentsOf: path)
                try secondBytes.write(to: path)
                try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path)
                return captured
            }
            let firstState = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
            XCTAssertEqual(firstState[photo]?.recipe, first)
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            let secondState = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
            XCTAssertEqual(secondState[photo]?.recipe, second,
                           "the replacement's bytes were not the document imported by the first scan")
        }
    }

    func testRatingOnlyPublicationDoesNotAcknowledgeAnUnimportedExternalRecipe() async throws {
        try await fixture { directory, photo, id, service in
            defer { _ = service.close() }
            let sidecar = CatalogService.sidecarURL(for: photo)
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            let priorObservation = try db.metaValue("sidecar_bytes_v1:\(id)")
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            let (incoming, bytes) = try self.external(1.5)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: sidecar.path)
            var photoState = PhotoItem(id: photo); photoState.catalogID = id; photoState.rating = 4
            service.saveCullingState(photoState, labelChanged: false)
            _ = try await service.querySource(scope: .everywhere, folderPath: photo.deletingLastPathComponent().path)
            service.flushSidecars()
            let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
            XCTAssertEqual(published.rating, 4)
            XCTAssertEqual(published.recipeJSON, try CanonicalJSON.canonicalRecipeJSON(incoming))
            XCTAssertEqual(try db.currentRecipe(photoID: id), Recipe())
            XCTAssertEqual(try db.metaValue("sidecar_bytes_v1:\(id)"), priorObservation,
                           "a rating does not acknowledge an external recipe as imported")
            let loaded = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
            XCTAssertEqual(loaded[photo]?.recipe, incoming)
            XCTAssertEqual(loaded[photo]?.rating, 4)
        }
    }

    func testKeywordOnlyPublicationLeavesExternalRecipeDetectableBeforeLaterLocalEdit() async throws {
        try await fixture { directory, photo, id, service in
            let sidecar = CatalogService.sidecarURL(for: photo)
            let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
            let (incoming, bytes) = try self.external(-1.5)
            try bytes.write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: sidecar.path)
            await service.addKeyword("Kept", targets: [(id, photo)])
            service.flushSidecars()
            let externalAfterKeyword = try Data(contentsOf: sidecar)
            XCTAssertEqual(XMPSidecar.parse(externalAfterKeyword)?.keywords, ["Kept"])
            var local = Recipe(); local.develop.tone.exposure = 2
            service.saveRecipe(local, url: photo, catalogID: id)
            _ = try await service.querySource(scope: .everywhere, folderPath: photo.deletingLastPathComponent().path)
            service.flushSidecars()
            let snapshots = try await service.photoSnapshots(photoID: id)
            let snapshot = try XCTUnwrap(snapshots.first)
            let restored = try await service.photoSnapshotRecipe(id: snapshot.id, photoID: id)
            XCTAssertEqual(restored, incoming)
            let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == externalAfterKeyword })
            XCTAssertEqual(service.close(), [])
        }
    }

    func testUnadoptedUnknownOrMalformedRecipeIsArchivedBeforeObservationAdvances() async throws {
        for json in ["{\"pipelineVersion\":2,\"unknownFutureField\":{\"painting\":99}}", "{broken"] {
            try await fixture { directory, photo, id, service in
                defer { _ = service.close() }
                let sidecar = CatalogService.sidecarURL(for: photo)
                let bytes = Data(XMPSidecar.serialize(SidecarContent(recipeJSON: json)).utf8)
                try bytes.write(to: sidecar)
                let loaded = service.registerAndLoad(folder: photo.deletingLastPathComponent(), files: [photo])
                XCTAssertEqual(loaded[photo]?.recipe, Recipe())
                let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
                XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == bytes },
                               "a baseline must not acknowledge bytes omitted from the catalog without preserving them")
                let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
                defer { db.close() }
                XCTAssertEqual(try db.currentRecipe(photoID: id), Recipe())
                XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            }
        }
    }

}
#endif
