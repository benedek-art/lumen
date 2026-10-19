#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// Exercises capture Amount outside the reference-renderer registry. Private fixtures
/// are ordinal-only in logs, and decoded data never leaves the machine.
final class CaptureDecodeCorpusTests: XCTestCase {
    func testCaptureAmountAndLensCacheAgreeWithFreshDecoders() throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset")
        }
        let extensions: Set<String> = ["arw", "nef", "cr3", "dng", "raf", "cr2", "rw2", "orf", "pef"]
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty)
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        func pixels(_ image: CIImage) -> [Float] {
            // Keep this bounded. Capture sharpness can be legitimately zero for a
            // platform decoder, so require exact cache coherence, not guessed authority.
            let rect = image.extent.integral
            let width = Int(rect.width), height = Int(rect.height)
            var data = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &data, rowBytes: width * 16,
                           bounds: rect, format: .RGBAf, colorSpace: colorSpace)
            return data
        }
        for (index, url) in urls.enumerated() {
            try autoreleasepool {
                let cached = try AppleRawSource(url: url)
                var recipe = Recipe()
                recipe.develop.denoise.mode = .off
                // Revisit earlier states after both capture and lens changes: a key
                // omitting either field would return stale, convincing-looking pixels.
                let states: [(Bool, Double?, Bool)] = [
                    (false, nil, false), (true, 0, false), (true, 100, false),
                    (true, 150, false), (true, 100, true), (true, 100, false),
                    (false, nil, false), (true, nil, false)
                ]
                for (enabled, amount, lens) in states {
                    recipe.develop.detail.capture.auto = enabled
                    recipe.develop.detail.capture.amount = amount
                    recipe.develop.geometry.lens.profile = lens
                    let fresh = try AppleRawSource(url: url)
                    let a = try XCTUnwrap(cached.decode(recipe: recipe, draft: false, scaleFactor: 0.08))
                    let b = try XCTUnwrap(fresh.decode(recipe: recipe, draft: false, scaleFactor: 0.08))
                    XCTAssertEqual(a.extent, b.extent, "fixture\(index + 1)")
                    let actual = pixels(a), expected = pixels(b)
                    XCTAssertEqual(actual.count, expected.count)
                    XCTAssertTrue(actual.allSatisfy(\.isFinite), "fixture\(index + 1): non-finite decode")
                    let maxError = zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
                    XCTAssertLessThanOrEqual(maxError, 0.00001, "fixture\(index + 1): stale capture/lens decode")
                }
                // WB belongs downstream of decode. Extreme legal UI values must not
                // poison a cached raw source or make fresh/cached paths disagree.
                for (temperature, tint) in [(2000.0, -150.0), (2000, 150),
                                             (50000, -150), (50000, 150), (5500, 0)] {
                    recipe.develop.raw.temp = temperature
                    recipe.develop.raw.tint = tint
                    let fresh = try AppleRawSource(url: url)
                    let a = try XCTUnwrap(cached.decode(recipe: recipe, draft: false, scaleFactor: 0.08))
                    let b = try XCTUnwrap(fresh.decode(recipe: recipe, draft: false, scaleFactor: 0.08))
                    let actual = pixels(a), expected = pixels(b)
                    XCTAssertTrue(actual.allSatisfy(\.isFinite))
                    let worst = zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
                    XCTAssertLessThanOrEqual(worst, 0.00001, "fixture\(index + 1): WB cache boundary")
                }
                print("capture-decode-file: fixture\(index + 1) states=13")
            }
        }
    }
}
#endif
