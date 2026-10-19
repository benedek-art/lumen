#if os(macOS)
import CoreImage
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

final class ExportSourceGenerationTests: XCTestCase {
    private final class ExportGenerationSource: ImageSource {
        let url: URL
        let asShotTemperature = 5500.0
        let asShotTint = 0.0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        let nativePixelSize = (width: 16, height: 16)
        let nativeLongEdge = 16.0
        var decodeCount = 0
        var onDecode: (() -> Void)?
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
        init(url: URL) { self.url = url }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            decodeCount += 1
            onDecode?()
            return CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    private func fixture(_ run: (URL, ExportGenerationSource, URL, URL, Data, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.png")
        let context = CIContext()
        try context.writePNGRepresentation(of: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)),
            to: original, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let destination = root.appendingPathComponent("delivery.jpg")
        let xmp = root.appendingPathComponent("source.xmp")
        let oldDelivery = Data("previous completed delivery".utf8)
        let oldXMP = Data("sidecar preservation sentinel".utf8)
        try oldDelivery.write(to: destination)
        try oldXMP.write(to: xmp)
        try run(root, ExportGenerationSource(url: original), destination, xmp, oldDelivery, oldXMP)
    }

    private var recipe: Recipe {
        var recipe = Recipe.asImported(from: Recipe.SourceFile(isRendered: true))
        recipe.develop.denoise.mode = .off
        return recipe
    }

    func testExplicitStaleGenerationRefusesBeforeDecodeAndPreservesDelivery() throws {
        try fixture { root, source, destination, xmp, oldDelivery, oldXMP in
            let expected = try XCTUnwrap(SourceFileIdentity.read(source.url))
            let replacement = Data("replacement bytes".utf8)
            try replacement.write(to: source.url, options: .atomic)
            XCTAssertThrowsError(try PipelineRenderer().export(source: source, recipe: recipe,
                to: destination, using: ExportRecipe(name: "binding"), allowOverwrite: true,
                expectedSourceIdentity: expected)) { error in
                    XCTAssertTrue(error is ExportSourceChangedError, "\(error)")
                }
            XCTAssertEqual(source.decodeCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), oldDelivery)
            XCTAssertEqual(try Data(contentsOf: source.url), replacement)
            XCTAssertEqual(try Data(contentsOf: xmp), oldXMP)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".delivery") })
        }
    }

    func testReplacementDuringDecodeRefusesPublicationWithImplicitRealFileBinding() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        try fixture { root, source, destination, xmp, oldDelivery, oldXMP in
            let replacement = Data("different source appeared during decode".utf8)
            var injected = false
            source.onDecode = {
                if !injected {
                    do { try replacement.write(to: source.url, options: .atomic); injected = true }
                    catch { XCTFail("Could not inject source replacement: \(error)") }
                }
            }
            // No explicit token: direct real-file export binds at entry for compatibility.
            XCTAssertThrowsError(try PipelineRenderer().export(source: source, recipe: recipe,
                to: destination, using: ExportRecipe(name: "binding"), allowOverwrite: true)) { error in
                    XCTAssertTrue(error is ExportSourceChangedError, "\(error)")
                }
            XCTAssertTrue(injected)
            XCTAssertGreaterThan(source.decodeCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), oldDelivery)
            XCTAssertEqual(try Data(contentsOf: source.url), replacement)
            XCTAssertEqual(try Data(contentsOf: xmp), oldXMP)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".delivery") })
        }
    }

    func testStableGenerationPublishesHealthyDeliveryWithoutChangingSourceOrXMP() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        try fixture { root, source, destination, xmp, oldDelivery, oldXMP in
            let original = try Data(contentsOf: source.url)
            let expected = try XCTUnwrap(SourceFileIdentity.read(source.url))
            _ = try PipelineRenderer().export(source: source, recipe: recipe, to: destination,
                using: ExportRecipe(name: "binding"), allowOverwrite: true, expectedSourceIdentity: expected)
            XCTAssertGreaterThan(source.decodeCount, 0)
            XCTAssertNotEqual(try Data(contentsOf: destination), oldDelivery)
            XCTAssertNotNil(CGImageSourceCreateWithURL(destination as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(try Data(contentsOf: source.url), original)
            XCTAssertEqual(try Data(contentsOf: xmp), oldXMP)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".delivery") })
        }
    }
    func testGenerationValidationRefusesReplacementAndMissingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-token-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.bin")
        try Data([1, 2, 3, 4]).write(to: url)
        let expected = try XCTUnwrap(SourceFileIdentity.read(url))
        XCTAssertNoThrow(try PipelineRenderer.validateExportSource(url: url, expected: expected))
        try Data([5, 6, 7, 8]).write(to: url, options: .atomic)
        XCTAssertThrowsError(try PipelineRenderer.validateExportSource(url: url, expected: expected)) {
            XCTAssertTrue($0 is ExportSourceChangedError)
        }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try PipelineRenderer.validateExportSource(url: url, expected: expected)) {
            XCTAssertTrue($0 is ExportSourceChangedError)
        }
        // Existing non-file synthetic sources remain explicitly unbound.
        XCTAssertNoThrow(try PipelineRenderer.validateExportSource(url: url, expected: nil))
    }

    func testReplacementAfterEncoderCompletionRefusesFinalPublicationAndRemovesPartial() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        try fixture { root, source, destination, xmp, oldDelivery, oldXMP in
            let original = try Data(contentsOf: source.url)
            let expected = try XCTUnwrap(SourceFileIdentity.read(source.url))
            let replacement = Data("replacement after encoder completed".utf8)
            var boundaryCalls = 0
            var encodedPartial: URL?
            let renderer = PipelineRenderer(beforeExportPublication: { partial in
                boundaryCalls += 1
                encodedPartial = partial
                // Prove this seam is after the encoder, rather than an onDecode
                // replacement that the earlier postdecode check would also catch.
                XCTAssertNotNil(CGImageSourceCreateWithURL(partial as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                XCTAssertEqual(try Data(contentsOf: destination), oldDelivery)
                XCTAssertEqual(try Data(contentsOf: source.url), original)
                try replacement.write(to: source.url, options: .atomic)
            })
            XCTAssertThrowsError(try renderer.export(source: source, recipe: recipe,
                to: destination, using: ExportRecipe(name: "binding"), allowOverwrite: true,
                expectedSourceIdentity: expected)) { error in
                    XCTAssertTrue(error is ExportSourceChangedError, "\(error)")
                }
            XCTAssertEqual(boundaryCalls, 1)
            XCTAssertGreaterThan(source.decodeCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), oldDelivery)
            XCTAssertEqual(try Data(contentsOf: source.url), replacement)
            XCTAssertEqual(try Data(contentsOf: xmp), oldXMP)
            let partial = try XCTUnwrap(encodedPartial)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".delivery") })
        }
    }

}
#endif
