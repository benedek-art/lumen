#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class SidecarPaintingPublicationTests: XCTestCase {
    private func fixture(_ body: (URL, URL, Int64, CatalogService, Recipe, [String], [BrushStrokeSet]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-paint-publication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: photo)
        let directory = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: directory)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let paintings = [0.2, 0.8].map { x in
            BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: x, y: 0.4)], size: 0.1)])
        }
        let refs = try paintings.map { try seed.blobs.store($0) }
        var recipe = Recipe()
        var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = refs[0]
        recipe.masks = [Mask(id: "paint", components: [component])]
        recipe.develop.heal.strokesRef = refs[1]
        recipe.develop.heal.count = 1
        seed.saveRecipe(recipe, url: photo, catalogID: id)
        XCTAssertEqual(seed.close(), [])
        // No scan: it would restore missing local blobs from the portable painting.
        let service = try CatalogService(directory: directory)
        try await body(directory, photo, id, service, recipe, refs, paintings)
    }

    func testMissingBrushOrHealDependencyPreservesLatestCatalogEditAndPortablePaintingDebt() async throws {
        for missing in [[0], [1], [0, 1]] {
            try await fixture { directory, photo, id, service, originalRecipe, refs, paintings in
                let sidecar = CatalogService.sidecarURL(for: photo)
                let before = try Data(contentsOf: sidecar)
                for index in missing {
                    try FileManager.default.removeItem(at: XCTUnwrap(service.blobs.url(for: refs[index])))
                }
                var edited = originalRecipe; edited.develop.tone.exposure = 1.25
                service.saveRecipe(edited, url: photo, catalogID: id)
                let entries = try await service.querySource(scope: .everywhere, folderPath: photo.deletingLastPathComponent().path)
                XCTAssertEqual(entries.first?.state.recipe, edited)
                XCTAssertEqual(service.close(), [sidecar.lastPathComponent])
                XCTAssertEqual(try Data(contentsOf: sidecar), before)
                let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
                defer { db.close() }
                let debt = UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey))
                XCTAssertEqual(debt.count, 1)
                XCTAssertTrue(try XCTUnwrap(debt.first).statedFields.isSuperset(of: [.recipe, .strokes]))
                XCTAssertEqual(try db.currentRecipe(photoID: id), edited)
                for index in missing {
                    try paintings[index].encode().write(to: XCTUnwrap(service.blobs.url(for: refs[index])))
                }
                let repaired = try CatalogService(directory: directory)
                XCTAssertNotNil(repaired.unsavedSidecarNotice)
                XCTAssertEqual(repaired.close(), [])
                let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
                let json = try XCTUnwrap(content.recipeJSON)
                XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)), edited)
                let payload = try XCTUnwrap(content.strokesPayload)
                XCTAssertEqual(Set(BrushStrokeSidecar.decode(payload).keys), Set(refs))
                XCTAssertTrue(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)).isEmpty)
                XCTAssertEqual(try Data(contentsOf: photo), Data([1, 2, 3]))
            }
        }
    }

    func testDependencyRestoredAfterEnqueueIsRegeneratedBeforePublication() async throws {
        try await fixture { directory, photo, id, service, originalRecipe, refs, paintings in
            let brushPath = try XCTUnwrap(service.blobs.url(for: refs[0]))
            try FileManager.default.removeItem(at: brushPath)
            var edited = originalRecipe; edited.develop.tone.exposure = -0.75
            service.saveRecipe(edited, url: photo, catalogID: id)
            // Drain enqueue while the brush is unavailable: its queued map contains
            // only the heal. Restoring disk bytes must cause a fresh complete map.
            _ = try await service.querySource(scope: .everywhere, folderPath: photo.deletingLastPathComponent().path)
            try paintings[0].encode().write(to: brushPath)
            XCTAssertEqual(service.close(), [])
            let sidecar = CatalogService.sidecarURL(for: photo)
            let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
            let payload = try XCTUnwrap(content.strokesPayload)
            XCTAssertEqual(Set(BrushStrokeSidecar.decode(payload).keys), Set(refs))
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(XCTUnwrap(content.recipeJSON).utf8)), edited)
            let db = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path)
            defer { db.close() }
            XCTAssertTrue(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)).isEmpty)
        }
    }

    func testOversizedButAvailablePaintingKeepsPreviousPayloadWhilePublishingRecipe() async throws {
        try await fixture { directory, photo, id, service, originalRecipe, _, _ in
            let sidecar = CatalogService.sidecarURL(for: photo)
            let before = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar))?.strokesPayload)
            let points = (0..<60_000).map {
                BrushPoint(x: Double($0 % 997) / 997.0, y: Double($0 % 991) / 991.0)
            }
            let painting = BrushStrokeSet(strokes: [BrushStroke(points: points, size: 0.1)])
            let ref = try service.blobs.store(painting)
            var edited = originalRecipe
            edited.masks[0].components[0].strokesRef = ref
            edited.develop.tone.exposure = 0.75
            guard case .tooLarge = BrushStrokeSidecar.decision(for: edited, blob: { service.blobs.strokeSet(for: $0) }) else {
                return XCTFail("fixture must exceed the existing portable payload cap")
            }
            service.saveRecipe(edited, url: photo, catalogID: id)
            XCTAssertEqual(service.close(), [])
            let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
            XCTAssertEqual(content.strokesPayload, before)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(XCTUnwrap(content.recipeJSON).utf8)), edited)
        }
    }
}
#endif
