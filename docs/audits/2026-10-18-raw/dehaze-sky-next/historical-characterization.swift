#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Characterizes two current algorithms; this is deliberately not CPU/GPU parity
/// acceptance and does not establish which result is more natural for a real sky.
final class DehazeCurrentDivergenceCharacterizationTests: XCTestCase {
    func testCurrentBrightFlatPlateauDivergenceAtBothDehazeSigns() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 128, height = 128
        let source = ImageBuffer(width: width, height: height) { u, _ in
            RGB(gray: u < 0.5 ? 0.8 : 1.0)
        }
        let decomposition = DetailEngine.Decomposition(image: source, workingRadius: 8)
        let x = 24, y = 64
        // Both samples are more than two guided-filter radii plus morphology radius
        // away from the step. A=1, min(I/A)=.8, t=1-.95*.8=.24.
        // log2(.8/.18)>2 and gradient=0 make the reference's skyness exactly1.
        let airlight = decomposition.airlight()
        let transmission = decomposition.transmission()[x, y]
        XCTAssertLessThan(airlight.maxAbsDifference(RGB(gray: 1)), 1e-6)
        XCTAssertEqual(transmission, 0.24, accuracy: 1e-6)
        XCTAssertEqual(decomposition.gradient[x, y], 0, accuracy: 1e-6)
        XCTAssertGreaterThan(decomposition.logLuminance[x, y], 2)
        XCTAssertEqual(DetailEngine.dehazeOmega, 0.95)
        XCTAssertEqual(DetailEngine.dehazeDistance, 20)

        let bytes = source.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: nil)
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
            .workingFormat: CIFormat.RGBAf,
        ])
        // Independently expanded plateau formulas, rather than a second copy of
        // either implementation: CPU uses floor .9, GPU base floor .45.
        // Negative CPU distance=1, GPU distance=1-.24=.76.
        let expectedCPU = [1 - 0.2 / 0.9, 0.8 + 0.2 * 0.9]
        let expectedGPU = [1 - 0.2 / 0.45, 0.8 + 0.2 * 0.76 * 0.9]
        for (i, amount) in [100.0, -100.0].enumerated() {
            let cpu = DetailEngine.applyDehaze(source, amount: amount, decomposition: decomposition)
            let output = RenderGraph.applyDehaze(input, amount: amount, longEdge: width)
            XCTAssertEqual(output.extent, input.extent)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { raw in
                context.render(output, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                               bounds: output.extent, format: .RGBAf, colorSpace: nil)
            }
            let gpu = ImageBuffer(width: width, height: height, pixels: pixels)
            for channel in [cpu[x, y].r, cpu[x, y].g, cpu[x, y].b] {
                XCTAssertEqual(channel, expectedCPU[i], accuracy: 1e-6)
            }
            for channel in [gpu[x, y].r, gpu[x, y].g, gpu[x, y].b] {
                // Existing stage readback bound, against the independently expanded
                // constant, not widened into an acceptance band for path divergence.
                XCTAssertEqual(channel, expectedGPU[i], accuracy: 1e-3)
            }
            XCTAssertLessThan(cpu[100, y].maxAbsDifference(RGB(gray: 1)), 1e-6)
            XCTAssertLessThan(gpu[100, y].maxAbsDifference(RGB(gray: 1)), 1e-3)
            XCTAssertGreaterThan(cpu[x, y].maxAbsDifference(gpu[x, y]), 0.04)
            let record: [String] = ["DEHAZE-CURRENT-DIVERGENCE", "amount=\(amount)",
                "cpu=\(cpu[x, y].r)", "gpu=\(gpu[x, y].r)",
                "expectedCPU=\(expectedCPU[i])", "expectedGPU=\(expectedGPU[i])",
                "maxRGBDifference=\(cpu[x, y].maxAbsDifference(gpu[x, y]))",
                "referenceTransmission=\(transmission)", "referenceAirlight=\(airlight.r)",
                "qualityAcceptance=false", "parityAcceptance=false"]
            print(record.joined(separator: " "))
        }
    }
}
#endif
