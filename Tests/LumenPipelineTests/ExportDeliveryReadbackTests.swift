// ExportDeliveryReadbackTests.swift
// docs/11 output gaps closed by the F6 stream, read back through ImageIO from files the
// real export path wrote — the same instrument `AuditExportMetadataTests` uses.

#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

final class ExportDeliveryReadbackTests: XCTestCase {

    /// A small rendered source in its own temporary folder. `value` is the fill.
    private func fixture(value: CGFloat = 0.4) throws -> (root: URL, source: RenderedImageSource) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: value * 0.5, green: value * 0.5, blue: value * 0.5,
                                     alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        // A bright patch: the part of the frame a gain map has something to say about.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 16, y: 12, width: 32, height: 24))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (root, try RenderedImageSource(url: url))
    }

    private func recipe(exposure: Double = 0) -> Recipe {
        var recipe = Recipe.asImported(from: Recipe.SourceFile(isRendered: true))
        recipe.develop.denoise.mode = .off
        recipe.develop.tone.exposure = exposure
        return recipe
    }

    // MARK: - Collision policy: Overwrite

    /// `ExportRecipe.placement` hands the batch `replacing: true` only for an Overwrite
    /// recipe on a file that was there before the run; this is the renderer half —
    /// that flag really does replace, and leaves no temporary behind.
    func testOverwriteReplacesTheFileThatWasThereAndLeavesNoPartial() throws {
        let (root, source) = try fixture()
        let url = root.appendingPathComponent("delivery.jpg")
        let sentinel = Data("an older delivery".utf8)
        try sentinel.write(to: url)
        let output = ExportRecipe(name: "overwrite", format: .jpeg, collision: .overwrite)
        _ = try PipelineRenderer().export(source: source, recipe: recipe(), to: url,
                                          using: output, allowOverwrite: true)
        let written = try Data(contentsOf: url)
        XCTAssertNotEqual(written, sentinel, "the older file was not replaced")
        XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) },
                        "what replaced it is not a picture")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".") }, "a temporary leaked: \(files)")
    }
}
#endif
