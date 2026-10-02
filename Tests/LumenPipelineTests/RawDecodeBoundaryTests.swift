#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import LumenPipeline

/// Always-on proof of the RAW9 boundary's output contract, independent of camera files.
final class RawDecodeBoundaryTests: XCTestCase {
    func testRaw9BoundaryPreservesSignedHighlightsTagAndOrigin() throws {
        try checkBoundary(.raw9LinearSRGB)
    }

    func testOrdinaryBoundaryPreservesPixelsNotJustTheNonzeroExtent() throws {
        try checkBoundary(.pipeline)
    }

    private func checkBoundary(_ evaluation: DecodeMaterializer.EvaluationSpace) throws {
        let working = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let input: [Float] = [4, 2.5, 1.75, 1, -0.25, 0.5, 1, 1,
                              0.18, 0.18, 0.18, 1, 0.25, 0.5, 0.75, 1]
        let data = input.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 32,
                            size: CGSize(width: 2, height: 2), format: .RGBAf,
                            colorSpace: working)
            .transformed(by: CGAffineTransform(translationX: 7, y: 11))
        let result = try XCTUnwrap(DecodeMaterializer.materialize(image, evaluatingIn: evaluation))
        XCTAssertEqual(result.image.extent, image.extent)
        XCTAssertEqual(result.bytes, 2 * 2 * 8)
        // A tagged boundary must give the same Rec2020 values to either consumer,
        // not depend again on the next graph's working colour space.
        for name in [CGColorSpace.extendedLinearITUR_2020, CGColorSpace.extendedLinearSRGB] {
            let context = CIContext(options: [
                .workingColorSpace: try XCTUnwrap(CGColorSpace(name: name)),
                .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
            ])
            var actual = [Float](repeating: 0, count: input.count)
            actual.withUnsafeMutableBytes { bytes in
                context.render(result.image, toBitmap: bytes.baseAddress!, rowBytes: 32,
                               bounds: image.extent, format: .RGBAf, colorSpace: working)
            }
            for (a, expected) in zip(actual, input) {
                XCTAssertTrue(a.isFinite)
                XCTAssertEqual(a, expected, accuracy: 0.006)
            }
            XCTAssertGreaterThan(actual[0], 3.99, "Do not clamp highlights to display white")
            XCTAssertLessThan(actual[4], -0.24, "Do not clip signed working colours")
        }
    }

    /// AI-01's residual gap. The boundary was chosen by `rawValue == "9"`, and Apple
    /// spells DNG decoders with a suffix (`version8DNG` is "8.dng"), so a RAW9 DNG
    /// decoder "9.dng" skipped it. Built from the platform type itself, so this goes red
    /// if the predicate reverts to comparing the spelling.
    func testTheRaw9BoundaryIsChosenByDecoderNumberNotSpelling() {
        XCTAssertTrue(AppleRawSource.needsRaw9Boundary(CIRAWDecoderVersion(rawValue: "9")))
        XCTAssertTrue(AppleRawSource.needsRaw9Boundary(CIRAWDecoderVersion(rawValue: "9.dng")),
                      "A DNG RAW9 decoder must be evaluated through the colour boundary")
        XCTAssertFalse(AppleRawSource.needsRaw9Boundary(CIRAWDecoderVersion(rawValue: "8")))
        XCTAssertFalse(AppleRawSource.needsRaw9Boundary(CIRAWDecoderVersion(rawValue: "8.dng")))
    }

    func testRequiredRaw9BoundaryDeclinesInvalidAndOverBudgetImages() throws {
        let working = try XCTUnwrap(DecodeMaterializer.workingSpace)
        let colour = try XCTUnwrap(CIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1,
                                           colorSpace: working))
        let infinite = CIImage(color: colour)
        XCTAssertNil(DecodeMaterializer.materialize(infinite, evaluatingIn: .raw9LinearSRGB))
        // Under the long-edge limit, but 648MB at8bytes/pixel exceeds the512MiB cap.
        // No allocation is attempted and callers must not substitute the lazy RAW9.
        let tooLarge = infinite.cropped(to: CGRect(x: 0, y: 0, width: 9000, height: 9000))
        XCTAssertNil(DecodeMaterializer.materialize(tooLarge, evaluatingIn: .raw9LinearSRGB))
    }
}
#endif
