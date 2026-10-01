#if os(macOS)
import CoreVideo
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// F5-02 (the half reachable without Vision): `VisionMattes.plane(from:)` is where the
/// matte's row order and stride are decided, and nothing tested it. A vertical mirror
/// here would put every Subject/Background/People adjustment on the wrong half of the
/// photograph and look fine on a centred portrait. Rows are padded deliberately, so a
/// `width`-for-`bytesPerRow` slip also fails.
final class VisionMattesPlaneTests: XCTestCase {
    private func buffer(width: Int, height: Int, float: Bool,
                        value: (Int, Int) -> Double) throws -> (CVPixelBuffer, UnsafeMutableRawPointer) {
        let bytesPerPixel = float ? 4 : 1
        let stride = width * bytesPerPixel + 48
        let memory = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
        memory.initializeMemory(as: UInt8.self, repeating: 0xEE, count: stride * height)
        for y in 0..<height {
            let row = memory.advanced(by: y * stride)
            for x in 0..<width {
                if float {
                    row.assumingMemoryBound(to: Float.self)[x] = Float(value(x, y))
                } else {
                    row.assumingMemoryBound(to: UInt8.self)[x] = UInt8(value(x, y) * 255)
                }
            }
        }
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            nil, width, height,
            float ? kCVPixelFormatType_OneComponent32Float : kCVPixelFormatType_OneComponent8,
            memory, stride, nil, nil, nil, &out)
        XCTAssertEqual(status, kCVReturnSuccess)
        return (try XCTUnwrap(out), memory)
    }

    func testRowZeroIsTheTopAndThePaddingIsNeverRead() throws {
        for float in [false, true] {
            let (w, h) = (37, 9)
            // Top row white, a left-half block in the second row, black elsewhere.
            let (pixels, memory) = try buffer(width: w, height: h, float: float) { x, y in
                y == 0 ? 1 : (y == 1 && x < w / 2 ? 1 : 0)
            }
            defer { memory.deallocate() }
            let plane = try XCTUnwrap(VisionMattes.plane(from: pixels))
            XCTAssertEqual(plane.width, w)
            XCTAssertEqual(plane.height, h)
            for x in 0..<w {
                XCTAssertEqual(plane[x, 0], 1, accuracy: 1e-6, "float=\(float): row 0 is the top")
                XCTAssertEqual(plane[x, h - 1], 0, accuracy: 1e-6, "float=\(float): last row is the bottom")
                XCTAssertEqual(plane[x, 1], x < w / 2 ? 1 : 0, accuracy: 1e-6,
                               "float=\(float): x runs left to right")
            }
            // 0xEE padding would read as 0.93 (8-bit) or garbage (float) if a row's
            // stride were taken as its width.
            XCTAssertLessThanOrEqual(plane.values.max() ?? 0, 1)
            XCTAssertEqual(plane.values.filter { $0 > 0.5 }.count, w + w / 2)
        }
    }
}
#endif
