#if os(macOS)
import Combine
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class ExportSourceBindingTests: XCTestCase {
    private func png(_ value: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: value, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-fixture-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return try Data(contentsOf: url)
    }

    @MainActor
    func testQueuedExportRefusesSameURLReplacementAndPreservesPriorDeliveryAndXMP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        let xmp = root.appendingPathComponent("source.xmp")
        let destination = root.appendingPathComponent("delivery.jpg")
        let original = try png(0.25), replacement = try png(0.75)
        let priorDelivery = Data("previous completed delivery".utf8)
        let priorXMP = Data("private sidecar sentinel".utf8)
        try original.write(to: source)
        try priorDelivery.write(to: destination)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        let presetsKey = "dev.lumenapp.exportRecipes"
        let previousPresets = UserDefaults.standard.object(forKey: presetsKey)
        defer {
            state.prepareToQuit()
            if let previousPresets { UserDefaults.standard.set(previousPresets, forKey: presetsKey) }
            else { UserDefaults.standard.removeObject(forKey: presetsKey) }
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: source)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [source])[source]?.catalogID)
        photo.sourceIdentity = try XCTUnwrap(SourceFileIdentity.read(source))
        state.primarySelection = photo
        var recipe = Recipe.asImported(from: Recipe.SourceFile(isRendered: true))
        recipe.develop.denoise.mode = .off
        recipe.develop.tone.exposure = 0.7
        state.recipes[source] = recipe
        try priorXMP.write(to: xmp)
        state.exportRecipes = [ExportRecipe(name: "binding", filenameTemplate: "delivery",
                                            collision: .overwrite)]
        var injected = false
        // isExporting=true is published after the job captured A's edits, before its
        // unstructured Task can acquire the source. This uses the actual enqueue seam.
        let subscription = state.$isExporting.sink { exporting in
            MainActor.assumeIsolated {
                if exporting && !injected {
                    do { try replacement.write(to: source, options: .atomic); injected = true }
                    catch { XCTFail("Could not inject source replacement: \(error)") }
                }
            }
        }
        defer { subscription.cancel() }
        state.export(to: root)
        let deadline = Date().addingTimeInterval(30)
        while state.isExporting && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isExporting)
        XCTAssertTrue(injected)
        XCTAssertNotEqual(SourceFileIdentity.read(source), photo.sourceIdentity)
        let report = try XCTUnwrap(state.operationReports.first)
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records.first?.outcome, .failed)
        let detail = report.records.first?.detail?.lowercased() ?? ""
        XCTAssertTrue(detail.contains("source") || detail.contains("original"), detail)
        XCTAssertEqual(try Data(contentsOf: destination), priorDelivery)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try Data(contentsOf: xmp), priorXMP)
        XCTAssertEqual(state.recipe(for: photo), recipe)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".delivery.jpg") })
    }
}
#endif
