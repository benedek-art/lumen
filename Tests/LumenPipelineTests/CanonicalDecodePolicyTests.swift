#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

final class CanonicalDecodePolicyTests: XCTestCase {
    private func image(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testEligibilityKeepsExistingByteAndLongEdgeCaps() {
        XCTAssertTrue(DecodeMaterializer.isEligible(image(width: 8192, height: 8192)))
        XCTAssertFalse(DecodeMaterializer.isEligible(image(width: 8193, height: 8192)))
        XCTAssertTrue(DecodeMaterializer.isEligible(image(width: 16384, height: 1)))
        XCTAssertFalse(DecodeMaterializer.isEligible(image(width: 16385, height: 1)))
        XCTAssertTrue(DecodeMaterializer.isEligible(image(width: 7008, height: 4672)))
        XCTAssertTrue(DecodeMaterializer.isEligible(image(width: 4592, height: 3056)))
    }

    func testOversizedLegacyPolicyReturnsLazyWithoutAttemptingAllocation() throws {
        for input in [image(width: 8193, height: 8192), image(width: 16385, height: 1)] {
            var attempts = 0
            let stored = try XCTUnwrap(DecodeMaterializer.prepareForCache(input,
                evaluatingIn: .pipeline, materializer: { _, _ in attempts += 1; return nil }))
            XCTAssertEqual(stored.bytes, 0)
            XCTAssertTrue(stored.image === input)
            XCTAssertEqual(attempts, 0, "deterministic refusal must never attempt the allocation")
        }
    }

    func testOversizedRaw9StillRequiresItsColourBoundaryAndRefuses() {
        var attempts = 0
        XCTAssertNil(DecodeMaterializer.prepareForCache(image(width: 8193, height: 8192),
            evaluatingIn: .raw9LinearSRGB, materializer: { _, _ in attempts += 1; return nil }))
        XCTAssertEqual(attempts, 0)
    }

    func testInvalidExtentNeverBecomesAnOversizedLazyFallback() {
        let unbounded = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        XCTAssertFalse(DecodeMaterializer.isEligible(unbounded))
        var attempts = 0
        XCTAssertNil(DecodeMaterializer.prepareForCache(unbounded, evaluatingIn: .pipeline,
            materializer: { _, _ in attempts += 1; return nil }))
        XCTAssertEqual(attempts, 0)
    }

    func testEligibleRaw9FailureCannotReturnLazyPixels() {
        var attempts = 0
        XCTAssertNil(DecodeMaterializer.prepareForCache(image(width: 8, height: 8),
            evaluatingIn: .raw9LinearSRGB, materializer: { _, evaluation in
                attempts += 1
                switch evaluation {
                case .raw9LinearSRGB: break
                case .pipeline: XCTFail("RAW9 lost its evaluation-space boundary")
                }
                return nil
            }))
        XCTAssertEqual(attempts, 1)
    }

    func testEligibleFailureNeverReturnsLazyPixelsAndSubsequentAttemptCanSucceed() throws {
        let input = image(width: 8, height: 8)
        var attempts = 0
        let materializer: DecodeMaterializer.Materializer = { image, evaluation in
            attempts += 1
            return attempts == 1 ? nil : DecodeMaterializer.materialize(image, evaluatingIn: evaluation)
        }
        XCTAssertNil(DecodeMaterializer.prepareForCache(input, evaluatingIn: .pipeline,
                                                       materializer: materializer))
        let stored = try XCTUnwrap(DecodeMaterializer.prepareForCache(input,
            evaluatingIn: .pipeline, materializer: materializer))
        XCTAssertEqual(stored.bytes, 8 * 8 * 8)
        XCTAssertEqual(attempts, 2)
    }

    /// Real source/cache regression, opt-in to public/licensed RAWs on hosted macOS.
    /// Unlike an allocator unit test this proves a failed first decode did not poison
    /// the cache and a successful retry never re-enters the materializer on a hit.
    func testPublicRawEligibleFailureRetriesWithoutCachingAnAlternateImage() throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"],
              !directory.isEmpty else { throw XCTSkip("Public RAW directory is not configured") }
        let root = URL(fileURLWithPath: directory)
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).filter {
                ["arw", "rw2", "nef", "dng", "cr2", "cr3", "raf", "orf", "pef"].contains($0.pathExtension.lowercased())
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var tested = false
        for file in files {
            guard let filter = CIRAWFilter(imageURL: file),
                  RawParams.selectsRawDecoder(filter.decoderVersion.rawValue),
                  !AppleRawSource.needsRaw9Boundary(filter.decoderVersion),
                  let candidate = filter.outputImage,
                  RawDecodeAcceptance.accepts(extent: candidate.extent, nativeSize: filter.nativeSize),
                  DecodeMaterializer.isEligible(candidate) else { continue }
            var attempts = 0
            let source = try AppleRawSource(url: file, materializer: { image, evaluation in
                attempts += 1
                return attempts == 1 ? nil : DecodeMaterializer.materialize(image, evaluatingIn: evaluation)
            })
            var recipe = Recipe()
            recipe.develop.denoise.mode = .off
            recipe.develop.detail.capture.auto = false
            recipe.develop.geometry.lens.profile = false
            XCTAssertNil(source.decode(recipe: recipe, draft: false, scaleFactor: 1),
                         "eligible failure must not publish a lazy substitute")
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(source.heldDecodeBytes, 0)
            let retry = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
            XCTAssertEqual(attempts, 2)
            XCTAssertGreaterThan(source.heldDecodeBytes, 0)
            let repeated = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
            XCTAssertTrue(retry === repeated)
            XCTAssertEqual(attempts, 2, "a hit must not retry or change the canonical plane")
            fputs("\ncanonical-decode-retry: attempts=\(attempts) held=\(source.heldDecodeBytes) first-refused retry-canonical cache-identical\n", stdout)
            fflush(stdout)
            tested = true
            break
        }
        try XCTSkipUnless(tested, "No supported legacy RAW in configured directory")
    }
}
#endif
