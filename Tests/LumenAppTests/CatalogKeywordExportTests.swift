#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class CatalogKeywordExportTests: XCTestCase {
    @MainActor
    private func withState(_ run: (AppState, PhotoItem, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-keyword-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photoURL = root.appendingPathComponent("source.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(photoURL as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["OldSource"]]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        // Export presets are an existing UserDefaults-backed property. Restore the
        // exact previous object so these isolated deliveries do not change preferences.
        let presetKey = "dev.lumenapp.exportRecipes"
        let original = UserDefaults.standard.object(forKey: presetKey)
        defer {
            state.prepareToQuit()
            if let original { UserDefaults.standard.set(original, forKey: presetKey) }
            else { UserDefaults.standard.removeObject(forKey: presetKey) }
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: photoURL)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [photoURL])[photoURL]?.catalogID)
        state.primarySelection = photo
        try await run(state, photo, root)
    }

    @MainActor
    private func finish(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(30)
        while state.isExporting && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isExporting, "the synthetic export did not finish")
    }

    private func keywords(_ url: URL) throws -> [String] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        return iptc?[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []
    }

    @MainActor
    func testAppExportReadsCatalogTagsAndDeliversThem() async throws {
        try await withState { state, photo, root in
            let catalog = try XCTUnwrap(state.catalog)
            let id = try XCTUnwrap(photo.catalogID)
            await catalog.removeKeyword("OldSource", targets: [(id, photo.id)])
            await catalog.addKeyword("Places > Iceland", targets: [(id, photo.id)])
            state.exportRecipes = [ExportRecipe(name: "Tags", filenameTemplate: "delivery")]
            state.export(to: root)
            try await finish(state)
            XCTAssertEqual(Set(try keywords(root.appendingPathComponent("delivery.jpg"))), ["OldSource", "Iceland"])
        }
    }

    @MainActor
    func testFailedCatalogReadOnlyRefusesKeywordEnabledDelivery() async throws {
        try await withState { state, _, root in
            state.exportRecipes = [
                ExportRecipe(name: "Tags", filenameTemplate: "tags"),
                ExportRecipe(name: "Stripped", metadata: MetadataPolicy(includeKeywords: false),
                             filenameTemplate: "stripped")
            ]
            _ = state.catalog?.close()
            state.export(to: root)
            try await finish(state)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tags.jpg").path))
            XCTAssertEqual(try keywords(root.appendingPathComponent("stripped.jpg")), [])
            XCTAssertTrue((state.statusMessage ?? "").contains("Could not read catalog keywords"))
        }
    }
}
#endif
