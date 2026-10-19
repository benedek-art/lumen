#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Opt-in attribution, not colour or denoise quality certification. All file names
/// and images remain local. Unlike the small reconstruction taps, each checked
/// scene read covers the entire displayed default-geometry ROI plus a 64px halo.
final class OwnerPhotoFootprintContinuityTests: XCTestCase {
    private struct Capture {
        var display: [[UInt8]] = []
        var scene: [[Float]] = []
        var bounds: [CGRect] = []
        var fullSize: CGSize = .zero
    }

    private func emit(_ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        var line = Data("OWNER-FOOTPRINT ".utf8); line.append(data); line.append(10)
        FileHandle.standardOutput.write(line)
    }

    private func packed(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func read(_ image: CIImage, bounds: CGRect, context: CIContext,
                      working: CGColorSpace) throws -> [Float] {
        let width = Int(bounds.width), height = Int(bounds.height)
        XCTAssertGreaterThan(width, 0); XCTAssertGreaterThan(height, 0)
        var values = [Float](repeating: .nan, count: width * height * 4)
        try values.withUnsafeMutableBytes { raw in
            let destination = CIRenderDestination(bitmapData: raw.baseAddress!,
                width: width, height: height, bytesPerRow: width * 16, format: .RGBAf)
            destination.colorSpace = working; destination.isClamped = false
            let task = try context.startTask(toRender: image, from: bounds,
                to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        }
        XCTAssertTrue(values.allSatisfy(\.isFinite), "checked scene read must write every sample")
        return values
    }

    func testDefaultGeometryFullFootprintAcrossDenoiseHistory() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUMEN_OWNER_FOOTPRINT"] == "1", "opt-in owner footprint attribution")
        let path = env["LUMEN_AUDIT_RAW_DIR"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "LUMEN_AUDIT_RAW_DIR unset")
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil).filter {
                ["arw", "rw2", "dng", "nef", "cr3", "raf"].contains($0.pathExtension.lowercased())
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        let limit = min(16, max(1, Int(env["LUMEN_OWNER_FOOTPRINT_LIMIT"] ?? "16") ?? 16))
        let working = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: working,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var failures: [String] = []
        for (index, file) in files.prefix(limit).enumerated() {
            try autoreleasepool {
                let source = try AppleRawSource(url: file)
                defer { _ = source.releaseDecodes() }
                let renderer = PipelineRenderer()
                XCTAssertTrue(renderer.availability.unavailable.isEmpty)
                let edge = Int(source.nativeLongEdge.rounded(.up))
                let zero = ClassicNR(luma: 0, chroma: 0, hotPixels: 0,
                    lumaUserSet: false, chromaUserSet: false)
                var modes: [(String, Denoise)] = [("off", Denoise(mode: .off)),
                    ("imported-classic", ISODefaults.startingDenoise(forISO: source.captureISO))]
                for value in [25.0, 50.0, 100.0] {
                    modes.append(("classic", Denoise(mode: .classic,
                        classic: ClassicNR(luma: value, chroma: value))))
                }
                for value in [0.0, 25.0, 50.0, 100.0] {
                    modes.append((value == 0 ? "ai-zero" : "ai", Denoise(mode: .ai,
                        amount: value, classic: zero)))
                }
                modes.append(("off-return", Denoise(mode: .off)))
                var baseline: Capture?
                for (state, denoise) in modes {
                    try autoreleasepool {
                        var recipe = Recipe(); recipe.develop.denoise = denoise
                        let inspectScene = state == "off" || state == "ai-zero" || state == "off-return"
                        var capture = Capture()
                        for center in [0.5, 0.18, 0.82] {
                            let unit = CGRect(x: center - 0.0175, y: center - 0.0175,
                                width: 0.035, height: 0.035)
                            let delivery = try renderer.renderPreviewDelivery(source: source,
                                recipe: recipe, maxLongEdge: edge, draft: false,
                                coarseDecode: false, region: unit)
                            XCTAssertNotNil(delivery.regionUnit)
                            capture.fullSize = delivery.fullPixelSize
                            capture.display.append(try packed(delivery.image))
                        }
                        // Display first, then sample an already-materialized cache hit.
                        // Default geometry only: no crop/rotation/resize interpolation.
                        if inspectScene {
                            let decoded = try XCTUnwrap(source.decode(recipe: recipe,
                                draft: false, scaleFactor: 1))
                            let extent = decoded.extent
                            XCTAssertEqual(extent.size, capture.fullSize,
                                "default-geometry source footprint requires unscaled native dimensions")
                            for center in [0.5, 0.18, 0.82] {
                                let rect = CGRect(x: extent.minX + (center - 0.0175) * extent.width,
                                    y: extent.minY + (1 - center - 0.0175) * extent.height,
                                    width: 0.035 * extent.width, height: 0.035 * extent.height)
                                    .integral.insetBy(dx: -64, dy: -64).intersection(extent).integral
                                capture.bounds.append(rect)
                                capture.scene.append(try read(decoded, bounds: rect,
                                    context: context, working: working))
                            }
                        }
                        if state == "off" { baseline = capture }
                        else if inspectScene, let baseline {
                            XCTAssertEqual(capture.bounds, baseline.bounds)
                            for region in 0..<3 {
                                let a = baseline.display[region], b = capture.display[region]
                                let sa = baseline.scene[region], sb = capture.scene[region]
                                XCTAssertEqual(a.count, b.count); XCTAssertEqual(sa.count, sb.count)
                                let displayChanged = zip(a, b).filter { $0 != $1 }.count
                                let sceneChanged = zip(sa, sb).filter { $0 != $1 }.count
                                try emit(["fixture": index + 1, "state": state, "region": region,
                                    "displayChangedComponents": displayChanged,
                                    "displayMaximumCode": zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0,
                                    "sceneChangedComponents": sceneChanged,
                                    "sceneMaximumAbsolute": zip(sa, sb).map { abs(Double($0) - Double($1)) }.max() ?? 0,
                                    "sceneComponents": sa.count, "haloPixels": 64])
                                if a != b { failures.append("fixture\(index + 1)/\(state)/region\(region) displayed identity") }
                                if sa != sb { failures.append("fixture\(index + 1)/\(state)/region\(region) scene footprint identity") }
                            }
                        }
                    }
                }
            }
        }
        // Preserve every diagnostic before reporting strict identity failures.
        for failure in failures { XCTFail(failure) }
    }
}
#endif
