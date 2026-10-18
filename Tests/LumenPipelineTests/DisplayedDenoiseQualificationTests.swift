#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import LumenCore
@testable import LumenPipeline

/// Actual tone-mapped SDR loupe output. AI labels mean Apple RAW decoder stand-in,
/// not a bundled learned model. No-reference response is not a quality score.
final class DisplayedDenoiseQualificationTests: XCTestCase {
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    private func delta(_ a: [UInt8], _ b: [UInt8]) -> (Double, Int) {
        guard a.count == b.count, !a.isEmpty else { return (255, 255) }
        var squared = 0.0, largest = 0, count = 0
        for i in a.indices where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i])); largest = max(largest, d)
            squared += Double(d * d); count += 1
        }
        return ((squared / Double(count)).squareRoot(), largest)
    }

    func testActualDisplayedNativeDenoiseModes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["LUMEN_DENOISE_RAW_DIR"],
              let output = env["LUMEN_DENOISE_EVIDENCE_DIR"] else {
            throw XCTSkip("Private displayed denoise requires configured input and evidence directories")
        }
        let folder = URL(fileURLWithPath: output).appendingPathComponent("displayed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        Actual PipelineRenderer native-resolution SDR loupe output, including display
        tone mapping, color management and dithering. AI-Apple-standin means Apple's
        decoder denoise; Lumen has no bundled learned denoiser. All photos are local.
        RMS code difference is response only, not a noise-removal or quality score.
        Off return checks exercise recipe/decode-cache restoration, not UI undo.
        """.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: input), includingPropertiesForKeys: nil)
            .filter { ["arw", "rw2", "dng", "nef", "cr3", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        let limit = max(1, Int(env["LUMEN_DENOISE_LIMIT"] ?? "16") ?? 16)
        var rows: [[String: Any]] = []
        for (ordinal, url) in files.prefix(limit).enumerated() {
            try autoreleasepool {
                let source = try AppleRawSource(url: url)
                let renderer = PipelineRenderer()
                XCTAssertTrue(renderer.availability.unavailable.isEmpty)
                let edge = Int(source.nativeLongEdge.rounded(.up))
                let zero = ClassicNR(luma: 0, chroma: 0, hotPixels: 0,
                                     lumaUserSet: false, chromaUserSet: false)
                var modes: [(String, Denoise)] = [
                    ("off", Denoise(mode: .off)),
                    ("imported-classic-default", ISODefaults.startingDenoise(forISO: source.captureISO))
                ]
                for v in [25.0, 50.0, 100.0] {
                    modes.append(("classic\(Int(v))", Denoise(mode: .classic, classic: ClassicNR(luma: v, chroma: v))))
                }
                for v in [0.0, 25.0, 50.0, 100.0] {
                    modes.append(("AI-Apple-standin\(Int(v))", Denoise(mode: .ai, amount: v, classic: zero)))
                }
                modes.append(("off-return", Denoise(mode: .off)))
                var offByRegion = [[UInt8]](repeating: [], count: 3)
                // Consecutive regions share the same decoder key, allowing its
                // materialized native decode to serve all three loupe requests.
                for (name, denoise) in modes {
                    for (regionIndex, center) in [(0.5, 0.5), (0.18, 0.18), (0.82, 0.82)].enumerated() {
                    // Unit region preserves native sampling regardless of orientation.
                    // Actual raster and whole-frame dimensions are recorded below.
                    let region = CGRect(x: center.0 - 0.0175, y: center.1 - 0.0175, width: 0.035, height: 0.035)
                        try autoreleasepool {
                            var recipe = Recipe(); recipe.develop.denoise = denoise
                            let start = Date()
                            let delivery = try renderer.renderPreviewDelivery(source: source, recipe: recipe,
                                maxLongEdge: edge, draft: false, coarseDecode: false, region: region)
                            let actual = try bytes(delivery.image)
                            if name == "off" { offByRegion[regionIndex] = actual }
                            XCTAssertEqual(actual.count, offByRegion[regionIndex].count,
                                           "native mode changed delivered region dimensions")
                            let difference = delta(offByRegion[regionIndex], actual)
                            if name == "AI-Apple-standin0" || name == "off-return" {
                                XCTAssertEqual(difference.1, 0, "fixture\(ordinal + 1) region\(regionIndex) \(name) changed displayed pixels")
                            }
                            XCTAssertNotNil(delivery.regionUnit, "native loupe request unexpectedly rendered whole frame")
                            let label = "fixture\(ordinal + 1)-region\(regionIndex)-\(name).png"
                            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(label) as CFURL,
                                UTType.png.identifier as CFString, 1, nil))
                            CGImageDestinationAddImage(destination, delivery.image, nil)
                            XCTAssertTrue(CGImageDestinationFinalize(destination))
                            rows.append(["fixture": ordinal + 1, "region": regionIndex, "mode": name,
                                "iso": source.captureISO ?? -1, "width": delivery.image.width, "height": delivery.image.height,
                                "fullWidth": delivery.fullPixelSize.width, "fullHeight": delivery.fullPixelSize.height,
                                "rmsCodeDifferenceFromOff": difference.0, "maxCodeDifferenceFromOff": difference.1,
                                "seconds": Date().timeIntervalSince(start), "decodeMilliseconds": delivery.decodeMilliseconds])
                            print("displayed-denoise fixture\(ordinal + 1) region=\(regionIndex) mode=\(name) rmsCodes=\(difference.0)")
                            fflush(stdout)
                        }
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("displayed-denoise-metrics.json"), options: .atomic)
        }
    }
}
#endif
