#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class SidecarBatchPublicationTests: XCTestCase {
    private func fixture(_ body: (CatalogService, CatalogStore, [URL], [Int64], URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-publish-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = (0..<3).map { root.appendingPathComponent("\($0).JPG") }
        for photo in photos { try Data([1]).write(to: photo) }
        let directory = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: directory)
        let loaded = service.registerAndLoad(folder: root, files: photos)
        let ids = try photos.map { try XCTUnwrap(loaded[$0]?.catalogID) }
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
        defer { service.close(); store.close() }
        self.save(service, photos, ids, exposure: 0.25)
        try await service.requireAvailablePhoto(photoID: ids[0])
        service.flushSidecars()
        try await body(service, store, photos, ids, root)
    }

    private func save(_ service: CatalogService, _ photos: [URL], _ ids: [Int64], exposure: Double) {
        var recipe = Recipe(); recipe.develop.tone.exposure = exposure
        service.saveRecipes(zip(photos, ids).map { .init(recipe: recipe, url: $0.0, catalogID: $0.1) })
    }
    private func debt(_ store: CatalogStore) throws -> [UnsavedSidecarRecord] {
        try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
    }
    private func exposure(_ path: URL) throws -> Double {
        let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: path)))
        return try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(content.recipeJSON).utf8)).develop.tone.exposure
    }

    func testLaterAdapterRewriteCannotOverwriteEarlierPreparedExternalBytes() async throws {
        try await fixture { service, store, photos, ids, root in
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            var firstPath: URL?
            var rewritten: Data?
            var reads = 0
            service.sidecarDataReader = { path in
                reads += 1
                if reads == 1 { firstPath = path }
                if reads == 2 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    var external = Recipe(); external.develop.tone.exposure = -1.5
                    let content = SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external))
                    let bytes = Data(XMPSidecar.serialize(content).utf8)
                    try bytes.write(to: XCTUnwrap(firstPath), options: .atomic)
                    rewritten = bytes
                }
                return try Data(contentsOf: path)
            }
            service.flushSidecars()
            XCTAssertEqual(reads, 2)
            let protected = try XCTUnwrap(firstPath)
            XCTAssertEqual(try Data(contentsOf: protected), try XCTUnwrap(rewritten))
            let index = try XCTUnwrap(photos.firstIndex { CatalogService.sidecarURL(for: $0) == protected })
            XCTAssertEqual(try self.debt(store).compactMap(\.photoID), [ids[index]])
            for other in photos.indices where other != index {
                XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photos[other])), 1.5)
            }
            service.flushSidecars()
            XCTAssertEqual(try self.exposure(protected), 1.5)
            XCTAssertTrue(try self.debt(store).isEmpty)
            let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("catalog/sidecar-conflicts"), includingPropertiesForKeys: nil)
            XCTAssertTrue(archives.contains { (try? Data(contentsOf: $0)) == rewritten })
        }
    }

    func testLaterAdapterRemovingEarlierPaintingDependencyPreservesItsPortablePayload() async throws {
        try await fixture { service, store, photos, ids, _ in
            let paintings = [0.2, 0.5, 0.8].map { BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: $0, y: 0.4)], size: 0.1)]) }
            let refs = try paintings.map { try service.blobs.store($0) }
            let recipes = refs.map { ref -> Recipe in
                var recipe = Recipe(); recipe.develop.tone.exposure = 0.25
                var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = ref
                recipe.masks = [Mask(id: "paint", components: [component])]
                return recipe
            }
            for index in photos.indices { service.saveRecipe(recipes[index], url: photos[index], catalogID: ids[index]) }
            try await service.requireAvailablePhoto(photoID: ids[0]); service.flushSidecars()
            let before = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            for index in photos.indices {
                var recipe = recipes[index]; recipe.develop.tone.exposure = 1.5
                service.saveRecipe(recipe, url: photos[index], catalogID: ids[index])
            }
            try await service.requireAvailablePhoto(photoID: ids[0])
            var firstIndex: Int?
            var reads = 0
            service.sidecarDataReader = { path in
                reads += 1
                if reads == 1 { firstIndex = photos.firstIndex { CatalogService.sidecarURL(for: $0) == path } }
                if reads == 2 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    let index = try XCTUnwrap(firstIndex)
                    try FileManager.default.removeItem(at: XCTUnwrap(service.blobs.url(for: refs[index])))
                }
                return try Data(contentsOf: path)
            }
            service.flushSidecars()
            XCTAssertEqual(reads, 2)
            let index = try XCTUnwrap(firstIndex)
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photos[index])), before[index])
            XCTAssertEqual(try store.currentRecipe(photoID: ids[index])?.develop.tone.exposure, 1.5)
            XCTAssertEqual(try self.debt(store).compactMap(\.photoID), [ids[index]])
            try paintings[index].encode().write(to: XCTUnwrap(service.blobs.url(for: refs[index])))
            service.flushSidecars()
            XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photos[index])), 1.5)
            XCTAssertTrue(try self.debt(store).isEmpty)
        }
    }

    func testFailedPhysicalFileKeepsOnlyItsWholeIntentWhileOtherFilesSettle() async throws {
        try await fixture { service, store, photos, ids, _ in
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            var staged: [URL] = []
            var blocked: URL?
            var original: Data?
            service.sidecarDataReader = { path in
                staged.append(path)
                let bytes = try Data(contentsOf: path)
                if staged.count == 3 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    let destination = staged[1]
                    original = try Data(contentsOf: destination)
                    try FileManager.default.removeItem(at: destination)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    blocked = destination
                }
                return bytes
            }
            service.flushSidecars()
            let destination = try XCTUnwrap(blocked)
            let index = try XCTUnwrap(photos.firstIndex { CatalogService.sidecarURL(for: $0) == destination })
            let pending = try self.debt(store)
            XCTAssertEqual(pending.compactMap(\.photoID), [ids[index]])
            XCTAssertTrue(try XCTUnwrap(pending.first).statedFields.isSuperset(of: [.recipe, .strokes]))
            for other in photos.indices where other != index { XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photos[other])), 1.5) }
            try FileManager.default.removeItem(at: destination)
            try XCTUnwrap(original).write(to: destination)
            service.flushSidecars()
            XCTAssertEqual(try self.exposure(destination), 1.5)
            XCTAssertTrue(try self.debt(store).isEmpty)
        }
    }

    func testLaterCatalogImportDoesNotFalselyAcknowledgeEarlierPreparedCullingBytes() async throws {
        try await fixture { service, store, photos, ids, _ in
            for (photo, id) in zip(photos, ids) {
                var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 4
                service.saveCullingState(rated, labelChanged: false)
            }
            try await service.requireAvailablePhoto(photoID: ids[0])
            var firstIndex: Int?
            var previousObservation: String?
            var reads = 0
            service.sidecarDataReader = { path in
                reads += 1
                if reads == 1 {
                    firstIndex = photos.firstIndex { CatalogService.sidecarURL(for: $0) == path }
                    let index = try XCTUnwrap(firstIndex)
                    previousObservation = try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[index]))
                }
                if reads == 2 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    let index = try XCTUnwrap(firstIndex)
                    var imported = Recipe(); imported.develop.tone.exposure = -1.5
                    // Models a catalog import after preparation without creating a
                    // local portable edit or changing this culling generation.
                    try store.saveRecipe(imported, photoID: ids[index], isCurrent: true)
                }
                return try Data(contentsOf: path)
            }
            service.flushSidecars()
            let index = try XCTUnwrap(firstIndex)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(try store.currentRecipe(photoID: ids[index])?.develop.tone.exposure, -1.5)
            XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photos[index])), 0.25)
            XCTAssertEqual(CatalogService.readSidecar(for: photos[index])?.rating, 4)
            XCTAssertEqual(try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[index])), previousObservation)
            XCTAssertTrue(try self.debt(store).isEmpty)
        }
    }

    func testLaterUnavailableMarkerRefusesEarlierPreparedRecipeWithoutChangingItsBytes() async throws {
        try await fixture { service, store, photos, ids, _ in
            let before = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            var firstIndex: Int?
            var reads = 0
            service.sidecarDataReader = { path in
                reads += 1
                if reads == 1 { firstIndex = photos.firstIndex { CatalogService.sidecarURL(for: $0) == path } }
                if reads == 2 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    let index = try XCTUnwrap(firstIndex)
                    try store.setMetaValue("sidecar_unavailable_v1:\(ids[index])", "future-observation")
                }
                return try Data(contentsOf: path)
            }
            service.flushSidecars()
            let index = try XCTUnwrap(firstIndex)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photos[index])), before[index])
            XCTAssertEqual(try self.debt(store).compactMap(\.photoID), [ids[index]])
            try store.setMetaValue("sidecar_unavailable_v1:\(ids[index])", nil)
            service.flushSidecars()
            XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photos[index])), 1.5)
            XCTAssertTrue(try self.debt(store).isEmpty)
        }
    }

    func testObservationOrFinalJournalSQLFailureRetainsEveryWrittenWholeIntentUntilRetry() async throws {
        for failObservation in [true, false] {
            try await fixture { service, store, photos, ids, _ in
                self.save(service, photos, ids, exposure: 1.5)
                try await service.requireAvailablePhoto(photoID: ids[0])
                let owed = try self.debt(store)
                let oldStamps = try ids.map { try store.photo(id: $0)?.sidecarMTime }
                let oldObservations = try ids.map { try store.metaValue(SidecarIntentPublication.observationKey(photoID: $0)) }
                let key = failObservation ? SidecarIntentPublication.observationKey(photoID: ids[1]) : UnsavedSidecarRecord.metaKey
                let operation = failObservation ? "INSERT" : "DELETE"
                let value = failObservation ? "NEW" : "OLD"
                try store.debugExecute("CREATE TRIGGER reject_publication BEFORE \(operation) ON meta WHEN \(value).key = '\(key)' BEGIN SELECT RAISE(ABORT, 'injected publication SQL refusal'); END;")
                service.flushSidecars()
                XCTAssertEqual(try self.debt(store), owed)
                XCTAssertEqual(try ids.map { try store.photo(id: $0)?.sidecarMTime }, oldStamps)
                XCTAssertEqual(try ids.map { try store.metaValue(SidecarIntentPublication.observationKey(photoID: $0)) }, oldObservations)
                for photo in photos { XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photo)), 1.5) }
                try store.debugExecute("DROP TRIGGER reject_publication;")
                service.flushSidecars()
                XCTAssertTrue(try self.debt(store).isEmpty)
                for (photo, id) in zip(photos, ids) {
                    let bytes = try Data(contentsOf: CatalogService.sidecarURL(for: photo))
                    let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    XCTAssertEqual(try store.metaValue(SidecarIntentPublication.observationKey(photoID: id)), digest)
                }
            }
        }
    }
    func testLaterAdapterCloseLeavesAllPreparedAndRemainingEntriesDurablyOwedWithoutWriting() async throws {
        try await fixture { service, store, photos, ids, _ in
            let before = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            let owed = try self.debt(store)
            var reads = 0
            var quitNames: [String] = []
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            service.sidecarDataReader = { path in
                reads += 1
                let bytes = try Data(contentsOf: path)
                if reads == 2 { quitNames = service.close() }
                return bytes
            }
            service.flushSidecars()
            XCTAssertEqual(reads, 2, "close must stop before the third adapter or its catalog preparation")
            XCTAssertEqual(Set(quitNames), Set(photos.map { CatalogService.sidecarURL(for: $0).lastPathComponent }))
            XCTAssertEqual(try self.debt(store), owed)
            XCTAssertEqual(try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }, before)
            XCTAssertEqual(failures, [], "closing cannot turn later preparation into closed-store retry failures")
            service.flushSidecars()
            XCTAssertEqual(try self.debt(store), owed)
            XCTAssertEqual(try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }, before)
        }
    }

    func testPreparedByteBudgetPublishesBoundedGroupsWithoutTruncatingOversizedDocuments() async throws {
        try await fixture { service, store, photos, ids, _ in
            let paddings = [5, 5, 9].enumerated().map { index, mib in
                "<!-- opaque-\(index):" + String(repeating: "x", count: mib * 1_024 * 1_024) + " -->"
            }
            for index in photos.indices {
                let path = CatalogService.sidecarURL(for: photos[index])
                let text = try String(contentsOf: path, encoding: .utf8)
                XCTAssertTrue(text.contains("</rdf:Description>"))
                try text.replacingOccurrences(of: "</rdf:Description>", with: paddings[index] + "</rdf:Description>")
                    .write(to: path, atomically: true, encoding: .utf8)
            }
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            var readPaths: [URL] = []
            var firstExposureAtThirdRead: Double?
            service.sidecarDataReader = { path in
                readPaths.append(path)
                if readPaths.count == 3 {
                    service.sidecarDataReader = { try Data(contentsOf: $0) }
                    firstExposureAtThirdRead = try self.exposure(readPaths[0])
                }
                return try Data(contentsOf: path)
            }
            service.flushSidecars()
            XCTAssertEqual(readPaths.count, 3)
            XCTAssertEqual(firstExposureAtThirdRead, 1.5,
                           "earlier large outputs must publish before retaining the third document")
            for index in photos.indices {
                let path = CatalogService.sidecarURL(for: photos[index])
                XCTAssertEqual(try self.exposure(path), 1.5)
                XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains(paddings[index]),
                              "including a document larger than the staging budget must preserve every external byte")
            }
            XCTAssertTrue(try self.debt(store).isEmpty)
        }
    }

    func testRestartAfterWrittenBatchSQLFailureRetainsDebtAndCompletesPublication() async throws {
        try await fixture { service, store, photos, ids, root in
            for photo in photos {
                let path = CatalogService.sidecarURL(for: photo)
                let text = try String(contentsOf: path, encoding: .utf8)
                try text.replacingOccurrences(of: "</rdf:Description>", with: "<!-- opaque external payload --></rdf:Description>")
                    .write(to: path, atomically: true, encoding: .utf8)
            }
            self.save(service, photos, ids, exposure: 1.5)
            try await service.requireAvailablePhoto(photoID: ids[0])
            let owed = try self.debt(store)
            try store.debugExecute("CREATE TRIGGER reject_restart_settlement BEFORE DELETE ON meta WHEN OLD.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected restart settlement refusal'); END;")
            service.flushSidecars()
            let written = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            for photo in photos { XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photo)), 1.5) }
            XCTAssertEqual(Set(service.close()), Set(photos.map { CatalogService.sidecarURL(for: $0).lastPathComponent }))
            XCTAssertEqual(try self.debt(store), owed)
            try store.debugExecute("DROP TRIGGER reject_restart_settlement;")
            let reopened = try CatalogService(directory: root.appendingPathComponent("catalog"))
            defer { reopened.close() }
            try await reopened.requireAvailablePhoto(photoID: ids[0])
            reopened.flushSidecars()
            XCTAssertTrue(try self.debt(store).isEmpty)
            for (photo, before) in zip(photos, written) {
                let after = try Data(contentsOf: CatalogService.sidecarURL(for: photo))
                XCTAssertNotNil(try XCTUnwrap(XMPSidecar.parse(before)).writeStamp)
                XCTAssertNotNil(try XCTUnwrap(XMPSidecar.parse(after)).writeStamp)
                // Recovery is another publication and legitimately refreshes its
                // write stamp. Every other XML byte must remain exact.
                func withoutWriteStamp(_ bytes: Data) throws -> String {
                    try XCTUnwrap(String(data: bytes, encoding: .utf8)).replacingOccurrences(
                        of: "<lumen:writeStamp>[^<]*</lumen:writeStamp>", with: "<lumen:writeStamp/>", options: .regularExpression)
                }
                XCTAssertEqual(try withoutWriteStamp(after), try withoutWriteStamp(before))
                XCTAssertEqual(try self.exposure(CatalogService.sidecarURL(for: photo)), 1.5)
                let index = try XCTUnwrap(photos.firstIndex(of: photo))
                let digest = "sha256:" + SHA256.hash(data: after).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(try store.metaValue(SidecarIntentPublication.observationKey(photoID: ids[index])), digest)
            }
        }
    }

}
#endif
