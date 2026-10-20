#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// The CPU reference frame (`renderReference`, shown when the core kernels will not
/// compile) is encoded to 8 bits by `PipelineRenderer.cgImage(from:)`. Quantising an
/// encoded value v to N bits is round(v * (2^N - 1)) — IEC 61966-2-1, and what Core
/// Image's RGBA8 render does on the GPU path. The encoder used to call the bare
/// `UInt8(Double)` conversion, which truncates, so every channel of the fallback frame
/// sat up to a code (half a code on average) darker than the GPU frame of the same
/// recipe. These pin the rounding, both on the quantiser and through the whole encode.
final class ReferencePreviewQuantiserTests: XCTestCase {
    func testTheReferenceQuantiserRoundsToTheNearestCodeRatherThanTruncating() {
        XCTAssertEqual(PipelineRenderer.byte(0.5), 128, "127.5 rounds half away from zero to 128")
        XCTAssertEqual(PipelineRenderer.byte(254.6 / 255), 255, "254.6 is nearest to 255")
        XCTAssertEqual(PipelineRenderer.byte(117.4 / 255), 117, "117.4 is nearest to 117")
        // The ends and the poisoned pixel are unchanged: saturate first, NaN to 0.
        XCTAssertEqual(PipelineRenderer.byte(0), 0)
        XCTAssertEqual(PipelineRenderer.byte(1), 255)
        XCTAssertEqual(PipelineRenderer.byte(-0.3), 0)
        XCTAssertEqual(PipelineRenderer.byte(1.7), 255)
        XCTAssertEqual(PipelineRenderer.byte(.nan), 0)
        XCTAssertEqual(PipelineRenderer.byte(.infinity), 0)
    }

    func testTheReferenceFrameEncodesLinearMidGreyAsTheSameCodeTheGPUFrameShows() throws {
        // Linear 0.18 encodes to sRGB 0.46136, i.e. 117.65 — code 118. Truncation gave 117.
        let grey: Float = 0.18
        let buffer = ImageBuffer(width: 2, height: 2,
                                 pixels: [Float](repeating: 0, count: 16).enumerated().map {
                                     $0.offset % 4 == 3 ? 1 : grey })
        let image = try XCTUnwrap(PipelineRenderer.cgImage(from: buffer, space: .srgb))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let expected = UInt8((TransferFunction.srgb.encode(Double(grey)) * 255).rounded())
        XCTAssertEqual(expected, 118)
        for pixel in 0..<4 {
            for channel in 0..<3 {
                XCTAssertEqual(data[pixel * 4 + channel], expected,
                               "pixel \(pixel) channel \(channel) is not the rounded code")
            }
        }
    }
}
#endif
