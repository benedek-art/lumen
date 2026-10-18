#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class FutureSidecarContainmentTests: XCTestCase {
    func testFutureEnvelopeOrEmbeddedRecipeRemainsUnavailableAcrossReopenAndStaleSaves() async throws {
        for futureEnvelope in [true, false] {
            for hasCatalogEdit in [true, false] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-future-xmp-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let photo = root.appendingPathComponent("frame.NEF")
                let original = Data([1, 2, 3]); try original.write(to: photo)
                let directory = root.appendingPathComponent("catalog")
                let seed = try CatalogService(directory: directory)
                let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
                var existing = Recipe(); existing.develop.tone.exposure = 0.75
                if hasCatalogEdit { seed.saveRecipe(existing, url: photo, catalogID: id) }
                XCTAssertEqual(seed.close(), [])
                let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
                defer { db.close() }
                let historyBefore = try db.edits(photoID: id)
                let currentBefore = try db.currentEdit(photoID: id)
                var incoming = Recipe(); incoming.develop.tone.exposure = -1.5
                if !futureEnvelope { incoming.pipelineVersion = supportedPipelineVersion + 10 }
                let futureBytes = Data(XMPSidecar.serialize(SidecarContent(
                    pipelineVersion: futureEnvelope ? supportedPipelineVersion + 10 : supportedPipelineVersion,
                    recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming),
                    strokesPayload: "opaque-future-painting-v99")).utf8)
                let sidecar = CatalogService.sidecarURL(for: photo)
                try futureBytes.write(to: sidecar)
                let service = try CatalogService(directory: directory)
                let loaded = service.registerAndLoad(folder: root, files: [photo])
                XCTAssertTrue(try XCTUnwrap(loaded[photo]).recipeUnavailable)
                XCTAssertNil(loaded[photo]?.recipe)
                let unavailableEntries = try await service.querySource(scope: .everywhere, folderPath: root.path)
                XCTAssertTrue(unavailableEntries.isEmpty)
                var staleDefault = Recipe(); staleDefault.develop.tone.exposure = 2
                service.saveRecipe(staleDefault, url: photo, catalogID: id)
                XCTAssertEqual(service.close(), [])
                XCTAssertEqual(try db.currentEdit(photoID: id), currentBefore)
                XCTAssertEqual(try db.edits(photoID: id), historyBefore)
                XCTAssertEqual(try Data(contentsOf: sidecar), futureBytes)
                let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
                XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == futureBytes })
                let reopened = try CatalogService(directory: directory)
                let reopenedEntries = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
                XCTAssertTrue(reopenedEntries.isEmpty, "the unavailable state must survive without a scan")
                reopened.saveRecipe(Recipe(), url: photo, catalogID: id)
                _ = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
                XCTAssertEqual(try db.currentEdit(photoID: id), currentBefore)
                // Neither a damaged document nor its absence authorizes default editing.
                try Data("<broken>".utf8).write(to: sidecar)
                XCTAssertTrue(try XCTUnwrap(reopened.registerAndLoad(folder: root, files: [photo])[photo]).recipeUnavailable)
                try FileManager.default.removeItem(at: sidecar)
                XCTAssertTrue(try XCTUnwrap(reopened.registerAndLoad(folder: root, files: [photo])[photo]).recipeUnavailable)
                XCTAssertEqual(try db.edits(photoID: id), historyBefore)
                // A supported recipe whose painting cannot be resolved is not a
                // complete recovery and must not discard the unavailable marker.
                var incomplete = Recipe()
                var missingBrush = MaskComponent(op: .add, kind: .brush)
                missingBrush.strokesRef = "blob:xxh64:0123456789abcdef"
                incomplete.masks = [Mask(id: "unavailable-painting", components: [missingBrush])]
                try Data(XMPSidecar.serialize(SidecarContent(
                    recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incomplete))).utf8).write(to: sidecar)
                XCTAssertTrue(try XCTUnwrap(reopened.registerAndLoad(folder: root, files: [photo])[photo]).recipeUnavailable)
                XCTAssertEqual(try db.edits(photoID: id), historyBefore)
                // Only a clean, supported, decodable replacement can clear the marker.
                var supported = Recipe(); supported.develop.tone.exposure = 1.25
                let supportedBytes = Data(XMPSidecar.serialize(SidecarContent(
                    recipeJSON: try CanonicalJSON.canonicalRecipeJSON(supported))).utf8)
                try supportedBytes.write(to: sidecar)
                let recovered = reopened.registerAndLoad(folder: root, files: [photo])
                XCTAssertFalse(try XCTUnwrap(recovered[photo]).recipeUnavailable)
                XCTAssertEqual(recovered[photo]?.recipe, supported)
                let entries = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
                XCTAssertEqual(entries.first?.state.recipe, supported)
                XCTAssertEqual(reopened.close(), [])
                XCTAssertEqual(try db.currentRecipe(photoID: id), supported)
                XCTAssertEqual(try Data(contentsOf: photo), original)
            }
        }
    }
    func testUndecodableRecipeStillHonoursItsDeclaredFutureVersion() async throws {
        for version in ["\(supportedPipelineVersion + 10)", "1e100"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-future-version-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let photo = root.appendingPathComponent("frame.NEF")
            try Data([1, 2, 3]).write(to: photo)
            let directory = root.appendingPathComponent("catalog")
            let seed = try CatalogService(directory: directory)
            let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
            seed.saveRecipe(Recipe(), url: photo, catalogID: id)
            XCTAssertEqual(seed.close(), [])
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            let before = try db.currentEdit(photoID: id)
            let badJSON = "{\"pipelineVersion\":\(version),\"develop\":{\"tone\":{\"exposure\":[]}}}"
            XCTAssertThrowsError(try CanonicalJSON.decodeRecipe(from: Data(badJSON.utf8)))
            let bytes = Data(XMPSidecar.serialize(SidecarContent(
                pipelineVersion: supportedPipelineVersion, recipeJSON: badJSON)).utf8)
            let sidecar = CatalogService.sidecarURL(for: photo)
            try bytes.write(to: sidecar)
            let service = try CatalogService(directory: directory)
            let loaded = service.registerAndLoad(folder: root, files: [photo])
            XCTAssertTrue(try XCTUnwrap(loaded[photo]).recipeUnavailable)
            let entries = try await service.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertTrue(entries.isEmpty)
            service.saveRecipe(Recipe(), url: photo, catalogID: id)
            XCTAssertEqual(service.close(), [])
            XCTAssertEqual(try db.currentEdit(photoID: id), before)
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }

    func testMalformedNumericBooleanIsArchivedRatherThanAcknowledgedAsAnIdenticalRecipe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-json-types-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: photo)
        let directory = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: directory)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var existing = Recipe(); existing.develop.geometry.flipH = true
        seed.saveRecipe(existing, url: photo, catalogID: id)
        XCTAssertEqual(seed.close(), [])
        let json = try CanonicalJSON.canonicalRecipeJSON(existing)
        XCTAssertTrue(json.contains("\"flipH\":true"))
        let malformed = json.replacingOccurrences(of: "\"flipH\":true", with: "\"flipH\":1")
        XCTAssertThrowsError(try CanonicalJSON.decodeRecipe(from: Data(malformed.utf8)))
        let bytes = Data(XMPSidecar.serialize(SidecarContent(recipeJSON: malformed)).utf8)
        let sidecar = CatalogService.sidecarURL(for: photo)
        try bytes.write(to: sidecar)
        let service = try CatalogService(directory: directory)
        let loaded = service.registerAndLoad(folder: root, files: [photo])
        XCTAssertEqual(loaded[photo]?.recipe, existing)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == bytes },
                      "JSON booleans and numbers are different persisted document content")
        XCTAssertEqual(service.close(), [])
    }

    func testStartupRecipeDebtCannotOverwriteOrAcknowledgeFuturePortableEditsBeforeAnyScan() async throws {
        for futureEnvelope in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-future-startup-debt-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let photo = root.appendingPathComponent("frame.NEF")
            try Data([1, 2, 3]).write(to: photo)
            let directory = root.appendingPathComponent("catalog")
            let seed = try CatalogService(directory: directory)
            let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
            var existing = Recipe(); existing.develop.tone.exposure = 0.75
            seed.saveRecipe(existing, url: photo, catalogID: id)
            XCTAssertEqual(seed.close(), [])
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            let current = try db.currentEdit(photoID: id)
            let history = try db.edits(photoID: id)
            let debt = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe, .strokes])
            try db.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([debt]))
            var incoming = Recipe(); incoming.develop.tone.exposure = -1.5
            if !futureEnvelope { incoming.pipelineVersion = supportedPipelineVersion + 10 }
            let bytes = Data(XMPSidecar.serialize(SidecarContent(
                pipelineVersion: futureEnvelope ? supportedPipelineVersion + 10 : supportedPipelineVersion,
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming),
                strokesPayload: "opaque-future-painting-v99")).utf8)
            let sidecar = CatalogService.sidecarURL(for: photo)
            try bytes.write(to: sidecar)
            let startup = try CatalogService(directory: directory)
            XCTAssertNotNil(startup.unsavedSidecarNotice)
            // Deliberately no registerAndLoad: close drains init's queued recovery.
            XCTAssertEqual(startup.close(), [sidecar.lastPathComponent])
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            XCTAssertEqual(try db.currentEdit(photoID: id), current)
            XCTAssertEqual(try db.edits(photoID: id), history)
            XCTAssertEqual(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)), [debt])
            XCTAssertNotNil(try db.metaValue("sidecar_unavailable_v1:\(id)"))
            let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == bytes })
            let reopened = try CatalogService(directory: directory)
            let entries = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertTrue(entries.isEmpty, "startup must persist the unavailable marker before any scan")
            XCTAssertEqual(reopened.close(), [sidecar.lastPathComponent])
            XCTAssertEqual(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)), [debt])
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }

}
#endif
