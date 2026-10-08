#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

/// Connected generated-shoot workflow. It exercises app/catalog boundaries rather
/// than asserting individual mask, heal or LUT algorithms again.
@MainActor
final class GeneratedShootLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "generated-shoot workflow did not settle")
    }

    private func makePNG(at url: URL, offset: UInt8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<32 { for x in 0..<48 {
            let p = y * bitmap.bytesPerRow + x * 4
            pixels[p] = UInt8(30 + x * 3) + offset
            pixels[p + 1] = UInt8(40 + y * 4)
            pixels[p + 2] = 90 + offset
            pixels[p + 3] = 255
        } }
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: url)
        return bytes
    }

    private func decodedPixels(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 48); XCTAssertEqual(image.height, 32)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testVerifiedIngestCullPaintHealLUTExportQuitAndReopenPreserveTheShoot() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("lumen-shoot-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files", "dev.lumenapp.exportRecipes"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let card = root.appendingPathComponent("card")
        let primary = root.appendingPathComponent("primary")
        let backup = root.appendingPathComponent("backup")
        for folder in [card, primary, backup] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sources = [card.appendingPathComponent("A.png"), card.appendingPathComponent("B.png")]
        let sourceBytes = try [makePNG(at: sources[0], offset: 0), makePNG(at: sources[1], offset: 20)]
        let request = IngestRequest(files: zip(sources, sourceBytes).map { IngestPlanFile(id: $0.0, byteSize: Int64($0.1.count)) },
            primaryDestination: primary, backupDestination: backup, folderTemplate: "{job}",
            renameTemplate: "{orig}", renameEnabled: false, jobName: "Shoot", verify: true, ejectWhenDone: false)
        let result = await VerifiedCopyIngestDriver().run(request, cancellation: IngestCancellation(), progress: { _ in })
        guard case .finished(let ingest) = result else { return XCTFail("generated ingest was refused") }
        XCTAssertTrue(ingest.allVerified)
        XCTAssertEqual(ingest.framesVerified, 2)
        XCTAssertEqual(ingest.results.count, 4)
        for file in ingest.results {
            let ordinal = try XCTUnwrap(sources.firstIndex(of: file.source))
            XCTAssertEqual(try Data(contentsOf: file.destination), sourceBytes[ordinal])
        }
        let editedURL = try XCTUnwrap(ingest.results.first { $0.source == sources[0] && $0.role == .primary }?.destination)
        let otherURL = try XCTUnwrap(ingest.results.first { $0.source == sources[1] && $0.role == .primary }?.destination)
        let catalogDirectory = root.appendingPathComponent("catalog")
        let state = AppState(catalogDirectory: { catalogDirectory }, previewDirectory: { root.appendingPathComponent("previews") })
        var firstClosed = false
        defer { if !firstClosed { state.prepareToQuit() } }
        var ingestHistory = OperationReport(kind: .ingest, records: sources.enumerated().map {
            OperationFileRecord(id: $0.offset, source: $0.element, label: "Ingest")
        })
        await state.checkpointOperationReport(ingestHistory)
        ingestHistory.finishIngest(ingest, sources: sources)
        await state.checkpointOperationReport(ingestHistory)
        state.openFolder(primary)
        try await waitUntil { !state.isScanning }
        XCTAssertEqual(state.allPhotos.count, 2)
        let catalog = try XCTUnwrap(state.catalog)
        let edited = try XCTUnwrap(state.allPhotos.first { $0.id.resolvingSymlinksInPath() == editedURL.resolvingSymlinksInPath() })
        let other = try XCTUnwrap(state.allPhotos.first { $0.id.resolvingSymlinksInPath() == otherURL.resolvingSymlinksInPath() })
        state.autoAdvance = false // Keep the culling cursor on a frame while rating and flagging it.
        state.select(edited)
        state.setRating(4); state.setFlag(.pick)
        state.select(other); state.setFlag(.reject)
        state.select(try XCTUnwrap(state.allPhotos.first { $0.id.resolvingSymlinksInPath() == editedURL.resolvingSymlinksInPath() }))
        state.sliderGesture(active: true)
        state.updateRecipe(coalescingKey: "tone.exposure") { $0.develop.tone.exposure = 0.6 }
        state.sliderGesture(active: false)
        let paint = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.3, y: 0.4), BrushPoint(x: 0.5, y: 0.6)], size: 0.16)])
        let healing = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.7, y: 0.4), BrushPoint(x: 0.7, y: 0.5)],
            size: 0.06, retouch: StrokeRetouch(mode: .clone, dx: -0.2, dy: 0))])
        let paintRef = try catalog.blobs.store(paint)
        let healRef = try catalog.blobs.store(healing)
        let cube = Data("""
        LUT_3D_SIZE 2
        0 0 0
        0.8 0 0
        0 0.9 0
        0.8 0.9 0
        0 0 1
        0.8 0 1
        0 0.9 1
        0.8 0.9 1
        """.utf8)
        let lut = try CreativeLUTImport.importCube(cube, named: "Generated LUT", into: catalog.blobs)
        state.remember(paint, ref: paintRef); state.remember(healing, ref: healRef)
        var brush = MaskComponent(op: .add, kind: .brush); brush.strokesRef = paintRef
        var mask = Mask(id: "generated-paint", name: "Painted", components: [brush]); mask.adjust.exposure = 0.3
        state.updateRecipe(label: "Paint, Heal and LUT") { recipe in
            recipe.masks = [mask]
            recipe.develop.heal.strokesRef = healRef
            recipe.develop.heal.count = healing.strokes.count
            recipe.develop.heal.spots = [HealSpot(id: "generated-clone", mode: .clone, x: 0.2, y: 0.2,
                sourceX: 0.4, sourceY: 0.2, radius: 0.04)]
            recipe.look.lut = lut
        }
        let finalRecipe = state.recipe(for: edited)
        await state.createPhotoSnapshot(named: "Finished")
        XCTAssertNil(state.photoSnapshots.error)
        let delivery = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        state.exportRecipes = [ExportRecipe(name: "Lifecycle", format: .png, filenameTemplate: "before")]
        state.export(to: delivery)
        try await waitUntil { !state.isExporting }
        let exportReport = try XCTUnwrap(state.operationReports.first { $0.kind == .export })
        guard exportReport.records.map(\.outcome) == [.delivered] else {
            let resolved = state.resolveStrokeSets(for: finalRecipe)
            do {
                _ = try await state.renderCoordinator.export(url: edited.id, recipe: finalRecipe,
                    to: delivery.appendingPathComponent("diagnostic.png"), exportRecipe: state.exportRecipes[0],
                    strokeSets: resolved.sets)
                return XCTFail("App export failed although direct rendering succeeded: \(exportReport.records)")
            } catch {
                return XCTFail("Lifecycle export failed: \(String(reflecting: error)); records=\(exportReport.records)")
            }
        }
        XCTAssertEqual(exportReport.records.first?.reducedKernels, [], "delivery must exercise the complete available graph")
        let before = URL(fileURLWithPath: try XCTUnwrap(exportReport.records.first?.actualDestination))
        let beforePixels = try decodedPixels(before)
        XCTAssertNotEqual(beforePixels, try decodedPixels(editedURL), "combined edits must reach the actual delivered picture")
        let references = [paintRef, healRef, lut.ref]
        let expectedPayloads = try [paint.encode(), healing.encode(), cube]
        state.prepareToQuit(); firstClosed = true
        let backups = try FileManager.default.contentsOfDirectory(at: catalogDirectory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        let catalogBackup = try XCTUnwrap(backups.filter { $0.pathExtension == "db" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first)
        let backupBlobs = catalogBackup.deletingPathExtension().appendingPathExtension("blobs")
        for (ref, bytes) in zip(references, expectedPayloads) {
            let name = try XCTUnwrap(catalog.blobs.url(for: ref)?.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: backupBlobs.appendingPathComponent(name)), bytes,
                           "actual quit backup must carry brush, heal and LUT dependencies")
        }
        let reopened = AppState(catalogDirectory: { catalogDirectory }, previewDirectory: { root.appendingPathComponent("previews-reopened") })
        defer { reopened.prepareToQuit() }
        reopened.openFolder(primary)
        try await waitUntil { !reopened.isScanning }
        let fresh = try XCTUnwrap(reopened.allPhotos.first { $0.id.resolvingSymlinksInPath() == editedURL.resolvingSymlinksInPath() })
        let freshOther = try XCTUnwrap(reopened.allPhotos.first { $0.id.resolvingSymlinksInPath() == otherURL.resolvingSymlinksInPath() })
        XCTAssertEqual(fresh.rating, 4); XCTAssertEqual(fresh.flag, .pick)
        XCTAssertEqual(freshOther.flag, .reject); XCTAssertEqual(freshOther.rating, 0)
        XCTAssertEqual(reopened.recipe(for: fresh), finalRecipe)
        XCTAssertTrue(reopened.recipe(for: freshOther).masks.isEmpty)
        let reopenedCatalog = try XCTUnwrap(reopened.catalog)
        let resolved = reopened.resolveStrokeSets(for: reopened.recipe(for: fresh))
        XCTAssertTrue(resolved.unresolved.isEmpty)
        XCTAssertEqual(resolved.sets[paintRef], paint); XCTAssertEqual(resolved.sets[healRef], healing)
        for (ref, bytes) in zip(references, expectedPayloads) {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopenedCatalog.blobs.url(for: ref))), bytes)
        }
        let snapshots = try await reopenedCatalog.photoSnapshots(photoID: try XCTUnwrap(fresh.catalogID))
        XCTAssertEqual(snapshots.map(\.name), ["Finished"])
        let snapshotRecipe = try await reopenedCatalog.photoSnapshotRecipe(id: XCTUnwrap(snapshots.first?.id), photoID: XCTUnwrap(fresh.catalogID))
        XCTAssertEqual(snapshotRecipe, finalRecipe)
        let sidecar = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: editedURL.appendingPathExtension("xmp"))))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(XCTUnwrap(sidecar.recipeJSON).utf8)), finalRecipe)
        try await waitUntil { reopened.operationReports.contains { $0.id == exportReport.id } }
        XCTAssertTrue(reopened.operationReports.contains { $0.id == ingestHistory.id && $0.state == .completed })
        reopened.select(fresh)
        reopened.exportRecipes = [ExportRecipe(name: "Lifecycle", format: .png, filenameTemplate: "after")]
        reopened.export(to: delivery)
        try await waitUntil { !reopened.isExporting }
        XCTAssertEqual(try decodedPixels(delivery.appendingPathComponent("after.png")), beforePixels,
                       "reconstructed app state must deliver the same edited pixels")
        for (index, source) in sources.enumerated() { XCTAssertEqual(try Data(contentsOf: source), sourceBytes[index]) }
        for file in ingest.results {
            XCTAssertEqual(try Data(contentsOf: file.destination), sourceBytes[try XCTUnwrap(sources.firstIndex(of: file.source))],
                           "edit, export and quit must not rewrite ingested originals or backup copies")
        }
    }
}
#endif
