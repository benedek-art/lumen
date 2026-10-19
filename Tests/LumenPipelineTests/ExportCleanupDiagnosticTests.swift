#if os(macOS)
import CoreImage
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

/// Diagnostic twins of the two unchanged KernelGolden export tests. These expose
/// the original export error separately from cleanup, without changing publication
/// guards, encoder availability, pixel tolerances or the original control tests.
final class ExportCleanupDiagnosticTests: XCTestCase {
    private enum SourceAxis: String {
        case device, missingPlaceholder, stablePNG
    }

    private final class BitmapSource: ImageSource {
        let url: URL
        let asShotTemperature = 5500.0
        let asShotTint = 0.0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage
        init(url: URL, image: CIImage) { self.url = url; self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    private func bitmap(_ buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func logError(_ error: Error, label: String) {
        let cocoa = error as NSError
        print("EXPORT-DIAGNOSTIC \(label) type=\(String(reflecting: type(of: error))) error=\(String(reflecting: error)) domain=\(cocoa.domain) code=\(cocoa.code) userInfo=\(cocoa.userInfo)")
    }

    /// Explicitly nonthrowing: record cleanup's own error instead of replacing the
    /// export error under investigation. The original try?-defer controls stay intact.
    private func cleanup(_ url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
            print("EXPORT-DIAGNOSTIC cleanup \(label) removed=\(url.path)")
        } catch { logError(error, label: "cleanup \(label) path=\(url.path)") }
    }

    private func snapshot(source: URL, destination: URL, label: String) {
        let manager = FileManager.default
        let token = SourceFileIdentity.read(source)?.token ?? "nil"
        print("EXPORT-DIAGNOSTIC \(label) source=\(source.path) token=\(token) destination=\(destination.path) exists=\(manager.fileExists(atPath: destination.path))")
        do {
            let prefix = "." + destination.lastPathComponent + "."
            let partials = try manager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".part") }.sorted()
            print("EXPORT-DIAGNOSTIC \(label) partials=\(partials)")
        } catch { logError(error, label: "\(label) partial inventory") }
    }

    private func source(_ axis: SourceAxis, image: CIImage, root: URL) throws -> BitmapSource {
        let url: URL
        switch axis {
        case .device: url = URL(fileURLWithPath: "/dev/null")
        case .missingPlaceholder: url = URL(fileURLWithPath: "/dev/null/export-cleanup-diagnostic")
        case .stablePNG:
            url = root.appendingPathComponent("stable-source.png")
            do {
                try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            } catch {
                logError(error, label: "stable PNG fixture encoding")
                throw error
            }
        }
        return BitmapSource(url: url, image: image)
    }

    private func export(_ renderer: PipelineRenderer, source: BitmapSource, destination: URL,
                        recipe: ExportRecipe, overwrite: Bool, label: String) throws -> [String] {
        snapshot(source: source.url, destination: destination, label: "\(label) before")
        do {
            let unavailable = try renderer.export(source: source, recipe: Recipe(), to: destination,
                using: recipe, allowOverwrite: overwrite)
            snapshot(source: source.url, destination: destination, label: "\(label) success")
            print("EXPORT-DIAGNOSTIC \(label) unavailable=\(unavailable)")
            return unavailable
        } catch {
            logError(error, label: "\(label) export caught")
            snapshot(source: source.url, destination: destination, label: "\(label) failure")
            throw error // The exact export error, without wrapping or substituting it.
        }
    }

    private func png(_ axis: SourceAxis) throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-cleanup-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-diagnostic-\(axis.rawValue)-\(UUID()).png")
        defer { cleanup(destination, label: "PNG \(axis.rawValue)"); cleanup(root, label: "fixture") }
        let flat = ImageBuffer(width: 32, height: 24) { _, _ in RGB(gray: 0.18) }
        let input = try source(axis, image: bitmap(flat), root: root)
        let renderer = PipelineRenderer()
        let recipe = ExportRecipe(name: "t", format: .png)
        let clean = try export(renderer, source: input, destination: destination, recipe: recipe,
                               overwrite: false, label: "PNG \(axis.rawValue) clean")
        XCTAssertEqual(clean, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "a clean export wrote nothing")
        renderer.availability = KernelAvailability(coreAvailable: true, unavailable: ["grain", "vignette"])
        let reduced = try export(renderer, source: input, destination: destination, recipe: recipe,
                                 overwrite: true, label: "PNG \(axis.rawValue) overwrite")
        XCTAssertEqual(reduced, ["grain", "vignette"])
    }

    private func heic(_ axis: SourceAxis) throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-cleanup-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-diagnostic-\(axis.rawValue)-\(UUID()).heic")
        defer { cleanup(destination, label: "HEIC \(axis.rawValue)"); cleanup(root, label: "fixture") }
        let ramp = ImageBuffer(width: 96, height: 64) { u, _ in RGB(gray: 0.1 + 0.8 * u) }
        let input = try source(axis, image: bitmap(ramp), root: root)
        let recipe = ExportRecipe(name: "ten", format: .heif, quality: 100,
                                  bitDepth: 10, colorSpace: .displayP3, resizeMode: .none)
        XCTAssertEqual(recipe.effectiveBitDepth, 10)
        let renderer = PipelineRenderer()
        let capable = PipelineRenderer.canWriteTenBitHEIC
        print("EXPORT-DIAGNOSTIC HEIC \(axis.rawValue) canWriteTenBitHEIC=\(capable)")
        guard capable else {
            XCTAssertThrowsError(try export(renderer, source: input, destination: destination, recipe: recipe,
                overwrite: false, label: "HEIC \(axis.rawValue) expected refusal"),
                "an encoder that declined the probe must refuse, not deliver 8 bits")
            return
        }
        _ = try export(renderer, source: input, destination: destination, recipe: recipe,
                       overwrite: false, label: "HEIC \(axis.rawValue) ten-bit")
        guard let container = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
              let depth = properties[kCGImagePropertyDepth as String] as? Int else {
            return XCTFail("the delivered 10-bit HEIC could not be read back")
        }
        print("EXPORT-DIAGNOSTIC HEIC \(axis.rawValue) deliveredDepth=\(depth)")
        XCTAssertGreaterThan(depth, 8, "the recipe said 10 and the container reports \(depth)")
    }

    func testDevicePNGCleanAndOverwrite() throws { try png(.device) }
    func testMissingPlaceholderPNGCleanAndOverwrite() throws { try png(.missingPlaceholder) }
    func testStablePNGSourceCleanAndOverwrite() throws { try png(.stablePNG) }
    func testDeviceTenBitHEIC() throws { try heic(.device) }
    func testMissingPlaceholderTenBitHEIC() throws { try heic(.missingPlaceholder) }
    func testStablePNGSourceTenBitHEIC() throws { try heic(.stablePNG) }
}
#endif
