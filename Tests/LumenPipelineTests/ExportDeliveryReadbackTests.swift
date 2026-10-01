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

    // MARK: - Gain-map HDR export (docs/11 §HDR export)

    /// The brightest component of the file decoded the way an HDR-aware reader decodes
    /// it (`expandToHDR`, extended-linear sRGB — 1.0 is SDR white).
    private func hdrPeak(_ url: URL) throws -> Float {
        let image = try XCTUnwrap(CIImage(contentsOf: url, options: [.expandToHDR: true]))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let extent = image.extent.integral
        var pixels = [Float](repeating: 0, count: Int(extent.width * extent.height) * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16,
                           bounds: extent, format: .RGBAf, colorSpace: space)
        var peak: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            peak = Swift.max(peak, pixels[i], pixels[i + 1], pixels[i + 2])
        }
        return peak
    }

    /// The primary image, decoded plainly to 8-bit sRGB — what a reader that knows
    /// nothing about gain maps shows.
    private func primaryPixels(_ url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        let count = image.width * image.height * 4
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: count))
    }

    /// A gain-map recipe's file carries an ISO 21496-1 gain map, decodes above SDR
    /// white where the plain export does not, and its primary IS the plain export.
    ///
    /// Red before this change on all three: `write` attached no second plane, so the
    /// auxiliary-data lookup came back nil and the expanded decode peaked at SDR white.
    func testAGainMapRecipeWritesAnISOGainMapOverTheUnchangedSDRPicture() throws {
        let (root, source) = try fixture()
        // +1.5 EV pushes the bright patch well past diffuse white in scene-linear, so
        // the SDR transform rolls it off and the +2 EV rendition has room to place it.
        let develop = recipe(exposure: 1.5)
        for format in [ExportFormat.heif, .jpeg] {
            let plainURL = root.appendingPathComponent("plain.\(format.fileExtension)")
            let hdrURL = root.appendingPathComponent("hdr.\(format.fileExtension)")
            let plain = ExportRecipe(name: "plain", format: format, quality: 100,
                                     colorSpace: .displayP3, resizeMode: .none)
            var hdr = plain
            hdr.hdr = HDRSettings(headroomEV: 2)
            XCTAssertTrue(hdr.hdrIsWritable)
            _ = try PipelineRenderer().export(source: source, recipe: develop, to: plainURL,
                                              using: plain)
            _ = try PipelineRenderer().export(source: source, recipe: develop, to: hdrURL,
                                              using: hdr)

            let container = try XCTUnwrap(CGImageSourceCreateWithURL(hdrURL as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                container, 0, kCGImageAuxiliaryDataTypeISOGainMap),
                            "\(format): no ISO 21496-1 gain map in the file")
            let plainContainer = try XCTUnwrap(CGImageSourceCreateWithURL(plainURL as CFURL,
                                                                          nil))
            XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                plainContainer, 0, kCGImageAuxiliaryDataTypeISOGainMap),
                         "\(format): a recipe without HDR settings grew a gain map")

            let withMap = try hdrPeak(hdrURL)
            let plainPeak = try hdrPeak(plainURL)
            print("GAINMAP \(format) peak hdr=\(withMap) plain=\(plainPeak)")
            XCTAssertLessThanOrEqual(plainPeak, 1.02, "\(format): the plain file is SDR")
            XCTAssertGreaterThan(withMap, 1.5,
                                 "\(format): the gain map adds no headroom above SDR white")

            // The deliberate SDR picture: the primary is the plain export. One code of
            // slack for the encoder; the HDR rendition must not have leaked into it.
            let a = try primaryPixels(plainURL), b = try primaryPixels(hdrURL)
            XCTAssertEqual(a.count, b.count)
            let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255
            XCTAssertLessThanOrEqual(worst, 2,
                                     "\(format): the primary is not the SDR export")
        }
    }
}
#endif
