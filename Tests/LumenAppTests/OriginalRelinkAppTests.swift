#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenApp

final class OriginalRelinkAppTests: XCTestCase {
    @MainActor
    private func withState(_ body: (AppState, CatalogService, PhotoItem, PhotoItem, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-app-relink-\(UUID())")
        let folder = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let oldDefaults = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, oldDefaults) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for (name, red) in [("a.JPG", 0.2), ("b.JPG", 0.7)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
            let url = folder.appendingPathComponent(name)
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
        }
        state.openFolder(folder)
        let deadline = Date().addingTimeInterval(10)
        while state.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.isScanning)
        let first = try XCTUnwrap(state.allPhotos.first { $0.filename == "a.JPG" })
        let second = try XCTUnwrap(state.allPhotos.first { $0.filename == "b.JPG" })
        let catalog = try XCTUnwrap(state.catalog)
        // The production backfill is asynchronous; establish the known signature on
        // a second real catalog connection so the test is independent of its timing.
        let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        try db.setQuickSig(QuickSignature.compute(url: first.id), photoID: try XCTUnwrap(first.catalogID))
        try db.setQuickSig(QuickSignature.compute(url: second.id), photoID: try XCTUnwrap(second.catalogID))
        db.close()
        state.primarySelection = first; state.selection = [first.id]
        try await body(state, catalog, first, second, root)
    }

    private func move(_ photo: PhotoItem, root: URL) throws -> URL {
        let new = root.appendingPathComponent("new/renamed.JPG")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: photo.id, to: new)
        return new
    }

    @MainActor
    func testGestureStartedDuringRelinkCommitPersistsToMovedPhotoID() async throws {
        try await withState { state, catalog, first, _, root in
            let id = try XCTUnwrap(first.catalogID)
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            // Split the real catalog commit from its main-actor application to
            // deterministically exercise an edit made while relink awaits completion.
            let completion = try await catalog.commitOriginalRelink(prepared)
            let previous = state.recipe(for: first)
            state.sliderGesture(active: true)
            state.updateRecipe { $0.develop.tone.exposure = 1.75 }
            let expected = state.recipe(for: first)
            state.applyOriginalRelink(completion)
            XCTAssertFalse(state.sliderGestureActive)
            XCTAssertEqual(state.recipes[destination], expected)
            _ = try await catalog.exportKeywords(photoID: id)
            catalog.flushSidecars()
            _ = try await catalog.exportKeywords(photoID: id)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            XCTAssertEqual(try db.currentRecipe(photoID: id), expected,
                           "the gesture must remain durable after the old URL disappears from allPhotos")
            let portable = try XCTUnwrap(CatalogService.readSidecar(for: destination)?.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(portable.utf8)), expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.id.appendingPathExtension("xmp").path),
                           "the pending gesture must not recreate a sidecar at the former source")
            let moved = try XCTUnwrap(state.primarySelection)
            state.undo()
            XCTAssertEqual(state.recipe(for: moved), previous)
            state.redo()
            XCTAssertEqual(state.recipe(for: moved), expected)
            _ = try await catalog.exportKeywords(photoID: id)
            XCTAssertEqual(try db.currentRecipe(photoID: id), expected)

        }
    }

    @MainActor
    func testProductionRelinkPreservesTwoPhotoRecipesBrushUndoSelectionAndPreviewJoin() async throws {
        try await withState { state, catalog, first, second, root in
            let otherRecipe = state.recipe(for: second)
            let previous = state.recipe(for: first)
            let brush = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.3, y: 0.4)])])
            let ref = try catalog.blobs.store(brush)
            var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = ref
            state.updateRecipe { recipe in
                recipe.develop.tone.exposure = 1.25
                recipe.masks = [Mask(id: "paint", name: "Paint", components: [component])]
            }
            let edited = state.recipe(for: first)
            _ = try await catalog.exportKeywords(photoID: try XCTUnwrap(first.catalogID))
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let missing = try await catalog.missingOriginals(includePhotoID: first.catalogID)
            XCTAssertTrue(missing.contains { $0.photoID == first.catalogID })
            let prepared = try await catalog.prepareOriginalRelink(photoID: try XCTUnwrap(first.catalogID), candidateURL: destination)
            let revision = state.sourceRevision
            try await state.relinkOriginal(prepared)
            let moved = try XCTUnwrap(state.allPhotos.first { $0.id == destination })
            XCTAssertEqual(moved.catalogID, first.catalogID)
            XCTAssertEqual(state.primarySelection?.id, destination)
            XCTAssertEqual(state.selection, [destination])
            XCTAssertNil(state.recipes[first.id])
            XCTAssertEqual(state.recipe(for: moved), edited)
            XCTAssertEqual(state.recipe(for: second), otherRecipe)
            XCTAssertEqual(catalog.blobs.strokeSet(for: ref), brush)
            XCTAssertGreaterThan(state.sourceRevision, revision)
            XCTAssertNil(state.previews?.photoID(for: first.id))
            XCTAssertEqual(state.previews?.photoID(for: destination), first.catalogID)
            XCTAssertTrue(state.history.steps.allSatisfy { $0.before[first.id] == nil && $0.after[first.id] == nil })
            state.undo()
            XCTAssertEqual(state.recipe(for: moved), previous)
            XCTAssertEqual(state.recipe(for: second), otherRecipe)
            state.redo()
            XCTAssertEqual(state.recipe(for: moved), edited)
        }
    }

    @MainActor
    func testUnreadableOrConflictingCandidateSidecarRefusesWithoutChangingEitherFile() async throws {
        try await withState { state, catalog, first, _, root in
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let sidecar = CatalogService.sidecarURL(for: destination)
            let bad = Data(#"<?xml version="1.0" encoding="UTF-16"?><x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
            try bad.write(to: sidecar)
            do {
                _ = try await catalog.prepareOriginalRelink(photoID: try XCTUnwrap(first.catalogID), candidateURL: destination)
                XCTFail("unreadable sidecar must be refused")
            } catch { XCTAssertEqual(error as? OriginalRelinkError, .incompatibleSidecar) }
            XCTAssertEqual(try Data(contentsOf: sidecar), bad)
            XCTAssertEqual(state.primarySelection?.id, first.id)
            var conflicting = Recipe(); conflicting.develop.tone.exposure = 4
            let conflictingBytes = Data(XMPSidecar.serialize(SidecarContent(recipeFingerprint: try RecipeFingerprint.fingerprint(conflicting),
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(conflicting))).utf8)
            try conflictingBytes.write(to: sidecar)
            do {
                _ = try await catalog.prepareOriginalRelink(photoID: try XCTUnwrap(first.catalogID), candidateURL: destination)
                XCTFail("conflicting recipe must be refused")
            } catch { XCTAssertEqual(error as? OriginalRelinkError, .incompatibleSidecar) }
            XCTAssertEqual(try Data(contentsOf: sidecar), conflictingBytes)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            XCTAssertEqual(IngestLocation.fileIdentity(of: try db.originalRelinkTarget(photoID: try XCTUnwrap(first.catalogID)).original), IngestLocation.fileIdentity(of: first.id))
        }
    }

    @MainActor
    func testPendingDebtMovesAndRetriesAtNewURLWithoutTouchingOldUnsafeSidecar() async throws {
        try await withState { _, catalog, first, _, root in
            let id = try XCTUnwrap(first.catalogID)
            let oldSidecar = CatalogService.sidecarURL(for: first.id)
            let originalBytes = Data(#"<?xml version="1.0" encoding="UTF-16"?><x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
            try originalBytes.write(to: oldSidecar)
            var edited = Recipe(); edited.develop.tone.exposure = 0.75
            catalog.saveRecipe(edited, url: first.id, catalogID: id)
            await catalog.addKeyword("New", targets: [(id, first.id)])
            _ = try await catalog.exportKeywords(photoID: id)
            catalog.flushSidecars()
            _ = try await catalog.exportKeywords(photoID: id)
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            _ = try await catalog.commitOriginalRelink(prepared)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            let owed = UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(owed.map(\.photoPath), [destination.path])
            XCTAssertEqual(owed.first?.keywordEdit?.added, ["New"])
            XCTAssertEqual(try Data(contentsOf: oldSidecar), originalBytes)
            catalog.flushSidecars()
            _ = try await catalog.exportKeywords(photoID: id)
            let written = try XCTUnwrap(CatalogService.readSidecar(for: destination))
            XCTAssertEqual(written.keywords, ["New"])
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(written.recipeJSON).utf8)), edited)
            XCTAssertEqual(try Data(contentsOf: oldSidecar), originalBytes)
            // A delayed save still carrying the former URL follows this same photo ID.
            edited.develop.tone.exposure = 1.5
            catalog.saveRecipe(edited, url: first.id, catalogID: id)
            _ = try await catalog.exportKeywords(photoID: id)
            catalog.flushSidecars()
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(CatalogService.readSidecar(for: destination)?.recipeJSON).utf8)), edited)
            XCTAssertEqual(try Data(contentsOf: oldSidecar), originalBytes)
        }
    }

    @MainActor
    func testCandidateSidecarChangedAfterReviewRefusesCommitAndPreservesMapping() async throws {
        try await withState { state, catalog, first, _, root in
            let id = try XCTUnwrap(first.catalogID)
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            let sidecar = CatalogService.sidecarURL(for: destination)
            let bytes = Data("another tool appeared after review".utf8)
            try bytes.write(to: sidecar)
            do { try await state.relinkOriginal(prepared); XCTFail("changed sidecar must be refused") }
            catch { XCTAssertEqual(error as? OriginalRelinkError, .incompatibleSidecar) }
            XCTAssertEqual(state.primarySelection?.id, first.id)
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }
    @MainActor
    func testAlreadySettledSidecarIsOwedAndPublishedBesideRelinkedOriginal() async throws {
        try await withState { _, catalog, first, _, root in
            let id = try XCTUnwrap(first.catalogID)
            var recipe = Recipe(); recipe.develop.tone.exposure = 0.6
            catalog.saveRecipe(recipe, url: first.id, catalogID: id)
            _ = try await catalog.exportKeywords(photoID: id)
            catalog.flushSidecars()
            let oldSidecar = CatalogService.sidecarURL(for: first.id)
            let oldBytes = try Data(contentsOf: oldSidecar)
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            _ = try await catalog.commitOriginalRelink(prepared)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            XCTAssertEqual(UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey)).map(\.photoPath), [destination.path])
            catalog.flushSidecars()
            let saved = try XCTUnwrap(CatalogService.readSidecar(for: destination)?.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(saved.utf8)), recipe)
            XCTAssertEqual(try Data(contentsOf: oldSidecar), oldBytes)
        }
    }

    @MainActor
    func testFutureEditAndMissingBrushPayloadRefuseBeforeCatalogMappingChanges() async throws {
        try await withState { _, catalog, first, _, root in
            let id = try XCTUnwrap(first.catalogID)
            catalog.saveRecipe(Recipe(), url: first.id, catalogID: id)
            _ = try await catalog.exportKeywords(photoID: id)
            let destination = try move(first, root: root).standardizedFileURL.resolvingSymlinksInPath()
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            try db.debugExecute("UPDATE edit SET pipeline_version = 999 WHERE photo_id = \(id) AND is_current = 1;")
            do { _ = try await catalog.commitOriginalRelink(prepared); XCTFail("future edit must survive untouched") }
            catch { XCTAssertEqual(error as? OriginalRelinkError, .unavailableEditPayload) }
            XCTAssertEqual(try db.currentEdit(photoID: id)?.pipelineVersion, 999)
            XCTAssertEqual(IngestLocation.fileIdentity(of: try db.originalRelinkTarget(photoID: id).original), IngestLocation.fileIdentity(of: first.id))
            try db.debugExecute("UPDATE edit SET pipeline_version = 1 WHERE photo_id = \(id) AND is_current = 1;")
            var component = MaskComponent(op: .add, kind: .brush); component.strokesRef = "blob:xxh64:0000000000000000"
            var recipe = Recipe(); recipe.masks = [Mask(id: "missing", name: "Missing", components: [component])]
            catalog.saveRecipe(recipe, url: first.id, catalogID: id)
            _ = try await catalog.exportKeywords(photoID: id)
            do { _ = try await catalog.commitOriginalRelink(prepared); XCTFail("missing painting must not become an incomplete portable edit") }
            catch { XCTAssertEqual(error as? OriginalRelinkError, .unavailableEditPayload) }
            XCTAssertEqual(try db.currentRecipe(photoID: id), recipe)
            XCTAssertEqual(IngestLocation.fileIdentity(of: try db.originalRelinkTarget(photoID: id).original), IngestLocation.fileIdentity(of: first.id))
        }
    }

}
#endif
