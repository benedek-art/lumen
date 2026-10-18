#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class CatalogUnavailableExportTests: XCTestCase {
    private enum OpenFailure: Error { case injected }

    @MainActor
    private func withFixture(_ body: (URL, URL, URL, Recipe) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-unavailable-export-\(UUID())")
        let input = root.appendingPathComponent("input")
        let output = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let key = "dev.lumenapp.exportRecipes"
        let oldPresets = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldPresets { UserDefaults.standard.set(oldPresets, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let photo = input.appendingPathComponent("source.PNG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        var saved = Recipe()
        saved.develop.tone.exposure = 1.25
        saved.masks = [Mask(id: "external-mask", components: [MaskComponent(op: .add, kind: .linear)],
                            adjust: LocalAdjust(exposure: 0.5))]
        let bytes = Data(XMPSidecar.serialize(SidecarContent(
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(saved))).utf8)
        try bytes.write(to: CatalogService.sidecarURL(for: photo))
        try await body(root, photo, output, saved)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "synthetic browse/export did not finish")
    }

    @MainActor
    func testFailedCatalogStillBrowsesAndPreviewsButCannotStartAnExport() async throws {
        try await withFixture { root, photo, output, saved in
            let original = try Data(contentsOf: photo)
            let sidecar = CatalogService.sidecarURL(for: photo)
            let portable = try Data(contentsOf: sidecar)
            let state = AppState(catalogDirectory: { throw OpenFailure.injected },
                previewDirectory: { root.appendingPathComponent("previews-failed") })
            defer { state.prepareToQuit() }
            XCTAssertNil(state.catalog)
            XCTAssertTrue(state.catalogStatus?.contains("Saved edits and masks were not loaded") == true)
            state.openFolder(photo.deletingLastPathComponent())
            try await self.waitUntil { !state.isScanning }
            let browsable = try XCTUnwrap(state.allPhotos.first)
            XCTAssertEqual(browsable.id, photo.resolvingSymlinksInPath())
            state.primarySelection = browsable
            XCTAssertNotEqual(state.recipe(for: browsable), saved,
                              "failure browsing must not claim the saved recipe was recovered")
            state.updateRecipe { $0.develop.tone.exposure = 0.5 }
            XCTAssertEqual(state.recipe(for: browsable).develop.tone.exposure, 0.5,
                           "volatile preview editing remains available by policy")
            let reportsBefore = state.operationReports
            state.exportRecipes = [ExportRecipe(name: "Refused", format: .png, filenameTemplate: "refused")]
            state.export(to: output)
            XCTAssertFalse(state.isExporting)
            XCTAssertTrue(state.statusMessage?.contains("Export unavailable") == true)
            XCTAssertEqual(state.operationReports, reportsBefore, "no export job may be claimed")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
            XCTAssertEqual(try Data(contentsOf: photo), original)
            XCTAssertEqual(try Data(contentsOf: sidecar), portable)
        }
    }

    @MainActor
    func testHealthyCatalogWarningDoesNotBlockExportOfRecoveredEditsAndMasks() async throws {
        try await withFixture { root, photo, output, saved in
            let original = try Data(contentsOf: photo)
            let sidecar = CatalogService.sidecarURL(for: photo)
            let portable = try Data(contentsOf: sidecar)
            let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                previewDirectory: { root.appendingPathComponent("previews") })
            defer { state.prepareToQuit() }
            XCTAssertNotNil(state.catalog)
            state.openFolder(photo.deletingLastPathComponent())
            try await self.waitUntil { !state.isScanning }
            let browsable = try XCTUnwrap(state.allPhotos.first)
            state.primarySelection = browsable
            XCTAssertEqual(state.recipe(for: browsable), saved)
            state.catalogStatus = "A recoverable catalog warning"
            state.exportRecipes = [ExportRecipe(name: "Healthy", format: .png, filenameTemplate: "healthy")]
            state.export(to: output)
            try await self.waitUntil { !state.isExporting }
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("healthy.png").path))
            let report = try XCTUnwrap(state.operationReports.first { $0.kind == .export })
            XCTAssertEqual(report.records.map(\.outcome), [.delivered])
            XCTAssertEqual(try Data(contentsOf: photo), original)
            XCTAssertEqual(try Data(contentsOf: sidecar), portable)
        }
    }
}
#endif
