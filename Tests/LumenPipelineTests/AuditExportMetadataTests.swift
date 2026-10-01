#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

final class AuditExportMetadataTests: XCTestCase {
    private func fixture(format: ExportFormat = .jpeg) throws -> (root: URL, source: RenderedImageSource, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-export-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.\(format.fileExtension)")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Synthetic Camera",
                kCGImagePropertyTIFFXResolution: 72, kCGImagePropertyTIFFYResolution: 72,
                kCGImagePropertyTIFFResolutionUnit: 2],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2000:01:02 03:04:05",
                kCGImagePropertyExifBodySerialNumber: "SYNTHETIC-BODY"],
            kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxSerialNumber: "SYNTHETIC-AUX"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31,
                kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 32,
                kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["source-keyword"],
                kCGImagePropertyIPTCCreatorContactInfo: [kCGImagePropertyIPTCContactInfoEmails: "source@example.invalid"]],
        ]
        let types: [ExportFormat: String] = [.jpeg: "public.jpeg", .heif: "public.heic", .tiff: "public.tiff", .png: "public.png"]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, types[format]! as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (root, try RenderedImageSource(url: url), try Data(contentsOf: url))
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func nested(_ properties: [String: Any], _ key: CFString) -> [String: Any] {
        properties[key as String] as? [String: Any] ?? [:]
    }

    private func export(_ source: RenderedImageSource, to url: URL, format: ExportFormat,
                        ppi: Double = 240, policy: MetadataPolicy, bitDepth: Int? = nil) throws {
        var recipe = Recipe.asImported(from: Recipe.SourceFile(isRendered: true))
        recipe.develop.denoise.mode = .off
        let output = ExportRecipe(name: "metadata proof", format: format, quality: 100,
            bitDepth: bitDepth ?? (format == .tiff || format == .png ? 16 : 8), resizeMode: .none,
            resolutionPPI: ppi, metadata: policy)
        _ = try PipelineRenderer().export(source: source, recipe: recipe, to: url, using: output)
    }

    func testRequestedPrintDensityIsWrittenWithoutChangingPixelDimensions() throws {
        let fixture = try fixture()
        for format in ExportFormat.allCases {
            for keep in [true, false] {
                let url = fixture.root.appendingPathComponent("density-\(keep).\(format.fileExtension)")
                try export(fixture.source, to: url, format: format,
                    policy: MetadataPolicy(includeEXIF: keep, includeKeywords: false))
                let properties = try read(url)
                print("METADATA DENSITY \(format) EXIF=\(keep) DPI=\(properties[kCGImagePropertyDPIWidth as String] ?? "absent")")
                XCTAssertEqual((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? -1, 240, accuracy: 0.02)
                XCTAssertEqual((properties[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue ?? -1, 240, accuracy: 0.02)
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 32)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 24)
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
    }

    func testExplicitEmailAndWebsiteSurviveWithSourceMetadataStripped() throws {
        let fixture = try fixture()
        for format in ExportFormat.allCases {
            for (name, contact, field) in [("email", "studio@example.invalid", kCGImagePropertyIPTCContactInfoEmails),
                ("website", "https://example.invalid/studio?x=1&y=2", kCGImagePropertyIPTCContactInfoWebURLs)] {
                let url = fixture.root.appendingPathComponent("\(name).\(format.fileExtension)")
                try export(fixture.source, to: url, format: format,
                    policy: MetadataPolicy(includeEXIF: false, includeKeywords: false,
                        copyright: "Copyright Synthetic", contact: contact))
                let properties = try read(url)
                let iptc = nested(properties, kCGImagePropertyIPTCDictionary)
                let creator = nested(iptc, kCGImagePropertyIPTCCreatorContactInfo)
                XCTAssertEqual(creator[field as String] as? String, contact, "REL-11: \(format) dropped \(name)")
                let copyright = iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String
                    ?? nested(properties, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFCopyright as String] as? String
                XCTAssertEqual(copyright, "Copyright Synthetic")
                // Adding copyright recreates TIFF even with EXIF off. That newly
                // created dictionary also used to make JPEG synthesize 72 ppi.
                XCTAssertEqual((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? -1, 240, accuracy: 0.02)
                XCTAssertEqual((properties[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue ?? -1, 240, accuracy: 0.02)
                XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
                XCTAssertNil(iptc[kCGImagePropertyIPTCKeywords as String])
                XCTAssertNil(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifDateTimeOriginal as String])
                XCTAssertNil(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifBodySerialNumber as String])
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
    }

    func testFractionalPrintDensityOverridesEverySourceContainer() throws {
        for format in ExportFormat.allCases {
            let fixture = try fixture(format: format)
            let original = try read(fixture.source.url)
            XCTAssertEqual((original[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? -1, 72, accuracy: 0.02)
            let url = fixture.root.appendingPathComponent("fractional.jpg")
            try export(fixture.source, to: url, format: .jpeg, ppi: 300.5, policy: MetadataPolicy())
            let properties = try read(url)
            XCTAssertEqual((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? -1, 300.5, accuracy: 0.02, "source \(format)")
            XCTAssertEqual((properties[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue ?? -1, 300.5, accuracy: 0.02, "source \(format)")
            XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
        }
    }

    func testDensityOnlyChangeDoesNotResampleDeliveredPixels() throws {
        let fixture = try fixture()
        var decoded: [Data] = []
        for ppi in [72.0, 300.5] {
            let url = fixture.root.appendingPathComponent("pixels-\(ppi).png")
            try export(fixture.source, to: url, format: .png, ppi: ppi, policy: MetadataPolicy())
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 24)
            decoded.append(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(decoded[0], decoded[1], "A density tag is not a request to resample")
    }

    func testNilAndBlankContactDoNotReintroduceStrippedMetadata() throws {
        let fixture = try fixture()
        for format in ExportFormat.allCases {
            for (name, contact) in [("nil", Optional<String>.none), ("blank", Optional(" \n\t"))] {
                let url = fixture.root.appendingPathComponent("\(name).\(format.fileExtension)")
                try export(fixture.source, to: url, format: format,
                    policy: MetadataPolicy(includeEXIF: false, includeKeywords: false, contact: contact))
                let properties = try read(url)
                let iptc = nested(properties, kCGImagePropertyIPTCDictionary)
                XCTAssertNil(iptc[kCGImagePropertyIPTCCreatorContactInfo as String])
                XCTAssertNil(iptc[kCGImagePropertyIPTCContact as String])
                XCTAssertNil(iptc[kCGImagePropertyIPTCCopyrightNotice as String])
                XCTAssertNil(iptc[kCGImagePropertyIPTCKeywords as String])
                XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
                XCTAssertNil(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifBodySerialNumber as String])
                XCTAssertNil(nested(properties, kCGImagePropertyExifAuxDictionary)[kCGImagePropertyExifAuxSerialNumber as String])
                XCTAssertNil(nested(properties, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFModel as String])
            }
        }
    }

    func testOptInSourceMetadataSurvivesWithoutMutatingOriginal() throws {
        let fixture = try fixture()
        let original = try read(fixture.source.url)
        XCTAssertNotNil(original[kCGImagePropertyGPSDictionary as String])
        for format in ExportFormat.allCases {
            let url = fixture.root.appendingPathComponent("keep.\(format.fileExtension)")
            try export(fixture.source, to: url, format: format,
                policy: MetadataPolicy(includeEXIF: true, includeCameraSerial: true,
                    includeGPS: true, includeKeywords: true))
            let properties = try read(url)
            XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary as String])
            XCTAssertEqual(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifBodySerialNumber as String] as? String, "SYNTHETIC-BODY")
            let iptc = nested(properties, kCGImagePropertyIPTCDictionary)
            XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords as String] as? [String], ["source-keyword"])
            XCTAssertEqual(nested(iptc, kCGImagePropertyIPTCCreatorContactInfo)[kCGImagePropertyIPTCContactInfoEmails as String] as? String, "source@example.invalid")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
    }

    func testMetadataExportCannotOverwriteExistingDestinationAndLeavesNoPartial() throws {
        let fixture = try fixture()
        for format in ExportFormat.allCases {
            let url = fixture.root.appendingPathComponent("existing.\(format.fileExtension)")
            let sentinel = Data("existing synthetic delivery".utf8)
            try sentinel.write(to: url)
            XCTAssertThrowsError(try export(fixture.source, to: url, format: format,
                policy: MetadataPolicy(contact: "studio@example.invalid")))
            XCTAssertEqual(try Data(contentsOf: url), sentinel)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".") }, "Temporary output leaked: \(files)")
        XCTAssertEqual(files.count, 5)
        XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
    }

    func testUnsupportedContactRefusesExportWithoutWritingOrMutatingSource() throws {
        let fixture = try fixture()
        let url = fixture.root.appendingPathComponent("invalid.jpg")
        XCTAssertThrowsError(try export(fixture.source, to: url, format: .jpeg,
            policy: MetadataPolicy(contact: "ask the studio"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Contact must be"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["source.jpg"])
        XCTAssertEqual(try Data(contentsOf: fixture.source.url), fixture.bytes)
    }

    func testExplicitContactReplacesInheritedIdentityWhileOtherOptedInMetadataSurvives() throws {
        let fixture = try fixture()
        for format in ExportFormat.allCases {
            let url = fixture.root.appendingPathComponent("replace-contact.\(format.fileExtension)")
            try export(fixture.source, to: url, format: format,
                policy: MetadataPolicy(includeEXIF: true, includeKeywords: true, contact: "example.invalid/studio"))
            let properties = try read(url)
            let iptc = nested(properties, kCGImagePropertyIPTCDictionary)
            let creator = nested(iptc, kCGImagePropertyIPTCCreatorContactInfo)
            XCTAssertEqual(creator[kCGImagePropertyIPTCContactInfoWebURLs as String] as? String, "example.invalid/studio")
            XCTAssertNil(creator[kCGImagePropertyIPTCContactInfoEmails as String], "Do not mix the original owner's email with the new contact")
            XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords as String] as? [String], ["source-keyword"])
            XCTAssertEqual(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2000:01:02 03:04:05")
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
            XCTAssertNil(nested(properties, kCGImagePropertyExifDictionary)[kCGImagePropertyExifBodySerialNumber as String])
            XCTAssertNil(nested(properties, kCGImagePropertyExifAuxDictionary)[kCGImagePropertyExifAuxSerialNumber as String])
        }
    }

    func testTenBitHEICRetainsContactAndDensityOrRefusesUnsupportedEncoding() throws {
        let fixture = try fixture()
        let url = fixture.root.appendingPathComponent("ten-bit.heic")
        let policy = MetadataPolicy(includeEXIF: false, includeKeywords: false, contact: "studio@example.invalid")
        guard PipelineRenderer.canWriteTenBitHEIC else {
            XCTAssertThrowsError(try export(fixture.source, to: url, format: .heif, policy: policy, bitDepth: 10))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            return
        }
        try export(fixture.source, to: url, format: .heif, policy: policy, bitDepth: 10)
        let properties = try read(url)
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 10)
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? -1, 240, accuracy: 0.02)
        let creator = nested(nested(properties, kCGImagePropertyIPTCDictionary), kCGImagePropertyIPTCCreatorContactInfo)
        XCTAssertEqual(creator[kCGImagePropertyIPTCContactInfoEmails as String] as? String, "studio@example.invalid")
    }
}
#endif
