#if os(macOS)
import AppKit
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class AuditPreviewReliabilityTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-preview-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pixels(width: Int, height: Int, green: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: green ? 0 : 1, green: green ? 1 : 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let type = url.pathExtension == "tif" ? "public.tiff" : "public.png"
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(target, image,
            [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
    }

    func testSourceReplacementRefreshesDimensionsAndDecodedPixels() async throws {
        let url = try scratch().appendingPathComponent("original.png")
        try write(pixels(width: 32, height: 24), to: url)
        let coordinator = RenderCoordinator()
        let before = await coordinator.nativeSize(for: url)
        let red = await coordinator.sampleSceneLinear(url: url, recipe: Recipe(), sourceX: 0.5, sourceY: 0.5)
        try write(pixels(width: 64, height: 48, green: true), to: url)
        let after = await coordinator.nativeSize(for: url)
        let green = await coordinator.sampleSceneLinear(url: url, recipe: Recipe(), sourceX: 0.5, sourceY: 0.5)
        XCTAssertEqual(before?.width, 32)
        XCTAssertEqual(after?.width, 64, "REL-06: URL is not a source generation")
        XCTAssertNotEqual(red, green)
    }

    func testRapidSameByteSizeImageReplacementWithRestoredMTimeRefreshesPixels() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("source.tif")
        let replacement = root.appendingPathComponent("replacement.tif")
        try write(pixels(width: 32, height: 24), to: url)
        try write(pixels(width: 32, height: 24, green: true), to: replacement)
        let oldBytes = try Data(contentsOf: url)
        let newBytes = try Data(contentsOf: replacement)
        XCTAssertEqual(oldBytes.count, newBytes.count)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let coordinator = RenderCoordinator()
        let before = await coordinator.sampleSceneLinear(url: url, recipe: Recipe(), sourceX: 0.5, sourceY: 0.5)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: newBytes)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let after = await coordinator.sampleSceneLinear(url: url, recipe: Recipe(), sourceX: 0.5, sourceY: 0.5)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "Same size, inode and mtime still changed pixels; ctime must invalidate")
    }

    func testActualExactRenderCarriesProvenanceAndDraftDoesNot() async throws {
        let url = try scratch().appendingPathComponent("source.png")
        try write(pixels(width: 256, height: 192), to: url)
        let coordinator = RenderCoordinator()
        var recipe = Recipe(); recipe.develop.tone.exposure = 1
        let rendered = await coordinator.renderOneShot(url: url, recipe: recipe, maxLongEdge: 256, draft: false)
        let exact = try XCTUnwrap(rendered)
        XCTAssertFalse(exact.usedEmbeddedPreview)
        XCTAssertEqual(exact.previewIdentity?.source, SourceFileIdentity.read(url))
        XCTAssertEqual(exact.previewIdentity?.recipeFingerprint, try RecipeFingerprint.fingerprint(recipe))
        let draft = await coordinator.renderOneShot(url: url, recipe: recipe, maxLongEdge: 256, draft: true)
        XCTAssertNil(draft?.previewIdentity)
    }

    @MainActor func testThumbnailReplacementDoesNotReuseOldDimensions() async throws {
        let url = try scratch().appendingPathComponent("original.png")
        try write(pixels(width: 32, height: 24), to: url)
        let loader = ThumbnailLoader()
        let before = await loader.image(for: url, size: 256)
        try write(pixels(width: 64, height: 48, green: true), to: url)
        let after = await loader.image(for: url, size: 256)
        XCTAssertEqual(before?.width, 32)
        XCTAssertEqual(after?.width, 64, "REL-06: memory thumbnail must follow source replacement")
    }

    @MainActor func testDevelopedPixelsCannotAcquireLaterRecipeFingerprint() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("original.png")
        try write(pixels(width: 32, height: 24), to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        let previews = PreviewStore(catalog: service, directory: root.appendingPathComponent("cache"))
        previews.register([url: id])
        let loader = ThumbnailLoader()
        loader.attach(previews: previews)
        let old = Recipe()
        var newer = old
        newer.develop.tone.exposure = 2
        service.saveRecipe(old, url: url, catalogID: id)
        _ = await service.previewState(photoID: id)
        // No MainActor suspension between these calls: recordDeveloped's Task can
        // only query the catalog after the newer save has already been enqueued.
        let publication = loader.recordDeveloped(url: url, image: try pixels(width: 2560, height: 8),
                               identity: DevelopedPreviewIdentity(source: try XCTUnwrap(SourceFileIdentity.read(url)),
                                   recipeFingerprint: try RecipeFingerprint.fingerprint(old)))
        service.saveRecipe(newer, url: url, catalogID: id)
        await publication?.value
        await previews.flushWrites()
        let rows = await service.previewState(photoID: id)?.rows ?? []
        let newerFP = try RecipeFingerprint.fingerprint(newer)
        XCTAssertFalse(rows.contains { $0.source == .lumen && $0.recipeFP == newerFP },
                       "REL-07: exposure-0 pixels must not be certified as exposure +2")
    }

    @MainActor func testUnchangedThumbnailIsActuallyReused() async throws {
        let url = try scratch().appendingPathComponent("same.png")
        try write(pixels(width: 32, height: 24), to: url)
        let loader = ThumbnailLoader()
        let first = await loader.image(for: url, size: 256)
        let second = await loader.image(for: url, size: 256)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "The fix must retain the unchanged-source fast path")
    }

    @MainActor func testCurrentDevelopedPreviewPersistsAndSourceReplacementRejectsIt() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("source.png")
        try write(pixels(width: 32, height: 24), to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        let previews = PreviewStore(catalog: service, directory: root.appendingPathComponent("cache"))
        previews.register([url: id])
        let loader = ThumbnailLoader(); loader.attach(previews: previews)
        // No saved edit: provenance must agree with the actual imported defaults,
        // not an empty catalog recipe_fp that cannot identify any rendered recipe.
        let identity = DevelopedPreviewIdentity(source: try XCTUnwrap(SourceFileIdentity.read(url)),
            recipeFingerprint: try RecipeFingerprint.fingerprint(AppState.startingRecipe(for: url)))
        await loader.recordDeveloped(url: url, image: try pixels(width: 2560, height: 8), identity: identity)?.value
        await previews.flushWrites()
        let plan = await previews.plan(for: url, pixels: 2560)
        XCTAssertNotNil(plan?.payload, "Negative control: current exact pixels must really be cached")
        XCTAssertEqual(plan?.payload?.recipeFP, identity.recipeFingerprint)
        XCTAssertTrue(plan?.payload?.file.path.contains("render-v\(PreviewCache.renderingRevision)") == true)
        // Replace without rescanning. Disk cache must independently reject its old
        // source namespace, not depend on the UI having noticed a changed folder.
        try write(pixels(width: 64, height: 48, green: true), to: url)
        let replacedPlan = await previews.plan(for: url, pixels: 2560)
        XCTAssertNil(replacedPlan?.payload)
        await previews.flushWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(plan?.payload?.file).path),
                       "Rejected source generations must not become budget-invisible files")
        if let plan { previews.record(plan, image: try pixels(width: 2560, height: 8), source: .lumen) }
        await previews.flushWrites()
        let stillMiss = await previews.plan(for: url, pixels: 2560)
        XCTAssertNil(stillMiss?.payload, "A late old-source writer must not poison the new namespace")
    }

    @MainActor func testRecipeChangesAfterWritePlanCannotPublishObsoletePixels() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("source.png")
        try write(pixels(width: 32, height: 24), to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        let previews = PreviewStore(catalog: service, directory: root.appendingPathComponent("cache"))
        previews.register([url: id])
        let old = Recipe()
        service.saveRecipe(old, url: url, catalogID: id)
        let plan = await previews.plan(for: url, pixels: 2560)
        var newer = old; newer.develop.tone.exposure = 2
        service.saveRecipe(newer, url: url, catalogID: id)
        previews.record(try XCTUnwrap(plan), image: try pixels(width: 2560, height: 8), source: .lumen)
        await previews.flushWrites()
        let rows = await service.previewState(photoID: id)?.rows ?? []
        XCTAssertTrue(rows.isEmpty, "Publication itself must recheck; planning-time validation is insufficient")
    }

    @MainActor func testLegacyRenderingRevisionIsNeverServed() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("source.png")
        try write(pixels(width: 32, height: 24), to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        let directory = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(pixels(width: 32, height: 24), to: directory.appendingPathComponent("legacy.png"))
        service.recordPreview(PreviewRow(photoID: id, level: .thumb, path: "legacy.png", bytes: 100))
        let previews = PreviewStore(catalog: service, directory: directory)
        previews.register([url:id])
        let plan = await previews.plan(for: url, pixels: 256)
        XCTAssertNil(plan?.payload, "Old RAW-rendered previews predate the corrected pixel basis")
        await previews.flushWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("legacy.png").path))
        // A corrupt cache row is not authority to unlink an original outside cache.
        service.recordPreview(PreviewRow(photoID: id, level: .thumb, path: "../source.png", bytes: 100))
        _ = await previews.plan(for: url, pixels: 256)
        await previews.flushWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testRescanDeletesInvalidatedPayloadAndRetainsNewSourceMiss() async throws {
        let root = try scratch()
        let url = root.appendingPathComponent("source.png")
        try write(pixels(width: 32, height: 24), to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [url])[url]?.catalogID)
        let previews = PreviewStore(catalog: service, directory: root.appendingPathComponent("cache"))
        previews.register([url:id])
        let firstPlan = await previews.plan(for: url, pixels: 256)
        previews.record(try XCTUnwrap(firstPlan), image: try pixels(width: 256, height: 192))
        await previews.flushWrites()
        let stored = await previews.plan(for: url, pixels: 256)
        let file = try XCTUnwrap(stored?.payload?.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try write(pixels(width: 64, height: 48, green: true), to: url)
        _ = service.registerAndLoad(folder: root, files: [url])
        await previews.flushWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let rows = await service.previewState(photoID: id)?.rows ?? []
        XCTAssertTrue(rows.isEmpty)
    }
}
#endif
