#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Every baked table's GPU lookup must return the table at float precision.
///
/// `CIColorCube` was handed Float32 RGBA and answered at 8 bits: gpu-parity measured a
/// lifted black's finish value of 0.033596 as exactly 9/255 (0.0352941), and ~8.06/255
/// between two knots. On a log-encoded table one 1/255 step is 0.094 EV. `ColorCube`
/// now looks up through `KernelLibrary.cubeLookup`; this suite holds it to the table,
/// and to the reference's interpolant: the expected value is `LUT3D.sample` itself, the
/// tetrahedral fetch the kernel now restates branch for branch. (It was a trilinear
/// restatement while the kernel was trilinear, which is how a GPU that sampled every
/// table differently from the CPU passed a suite named for precision.)
///
/// The values are chosen OFF the 1/255 grid, so an 8-bit store misses every one of them
/// by up to half a step (2e-3), against a 2e-4 bound that leaves room for a half-float
/// texture and no room for 8 bits.
final class ColorCubePrecisionTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    /// A smooth, non-separable table whose every entry sits between 8-bit codes.
    private func table(_ n: Int) -> LUT3D {
        LUT3D(size: n) { c in
            let base = RGB(0.05 + 0.8 * c.r * c.r, 0.1 + 0.7 * c.g * (0.5 + 0.5 * c.b),
                           0.2 + 0.6 * (c.r + c.b) / 2)
            return base + RGB(gray: 0.37 / 255)
        }
    }

    private func render(_ lut: LUT3D, _ inputs: [RGB]) throws -> [RGB] {
        let bytes = inputs.flatMap { [Float($0.r), Float($0.g), Float($0.b), Float(1)] }
        let source = CIImage(bitmapData: bytes.withUnsafeBufferPointer { Data(buffer: $0) },
                             bytesPerRow: inputs.count * 16,
                             size: CGSize(width: inputs.count, height: 1), format: .RGBAf,
                             colorSpace: space)
        let out = try XCTUnwrap(ColorCube.filter(lut, image: source))
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        var px = [Float](repeating: 0, count: inputs.count * 4)
        context.render(out, toBitmap: &px, rowBytes: inputs.count * 16,
                       bounds: source.extent, format: .RGBAf, colorSpace: space)
        return (0..<inputs.count).map {
            RGB(Double(px[$0 * 4]), Double(px[$0 * 4 + 1]), Double(px[$0 * 4 + 2]))
        }
    }

    func testTheLookupKernelCompiles() {
        XCTAssertNotNil(KernelLibrary.cubeLookup)
    }

    func testKnotsAndInteriorPointsComeBackAtFloatPrecision() throws {
        for n in [2, 17, LUT3D.interactiveSize, LUT3D.exportSize] {
            let lut = table(n)
            var inputs: [RGB] = []
            // Every corner and a spread of exact knots: these test the atlas addressing
            // (a wrong row or column order is a wrong KNOT, not a small error).
            for b in [0, n / 3, n - 1] {
                for g in [0, n / 2, n - 1] {
                    for r in [0, 1, n - 1] {
                        inputs.append(RGB(Double(r), Double(g), Double(b)) / Double(n - 1))
                    }
                }
            }
            // Interior points, plus out-of-range ones the lookup must clamp.
            var state: UInt64 = 7
            for _ in 0..<200 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let a = Double(state >> 40) / Double(1 << 24)
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let b = Double(state >> 40) / Double(1 << 24)
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let c = Double(state >> 40) / Double(1 << 24)
                inputs.append(RGB(a, b, c))
            }
            inputs += [RGB(-0.5, 0.3, 1.7), RGB(2, 2, 2), RGB(-1, -1, -1)]
            inputs = inputs.map { RGB(Double(Float($0.r)), Double(Float($0.g)), Double(Float($0.b))) }
            let gpu = try render(lut, inputs)
            var worst = 0.0
            var at = ""
            for (c, out) in zip(inputs, gpu) {
                let expected = lut.sample(c)
                let error = out.maxAbsDifference(expected)
                if error > worst { worst = error; at = "\(c): GPU \(out) table \(expected)" }
            }
            print("CUBE_PRECISION n=\(n) worst \(worst) at \(at)")
            XCTAssertLessThan(worst, 2e-4, "n=\(n): \(at)")
        }
    }
}
#endif
