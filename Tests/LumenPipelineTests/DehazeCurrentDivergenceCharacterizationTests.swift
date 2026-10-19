#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Migrated from the archived pre-fix divergence characterization to the documented
/// sky contract. Historical GPU equations remain explicit negative controls below.
/// This is controlled mathematical evidence, not real-sky quality acceptance.
final class DehazeSkyContractTests: XCTestCase {
    func testBrightFlatPlateauMatchesBothDocumentedSkyTerms() throws {
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
        // Independent plateau equations. Historical no-sky GPU formulas are
        // retained as negative controls, not accepted outputs.
        let expectedCPU = [1 - 0.2 / 0.9, 0.8 + 0.2 * 0.9]
        let historicalGPU = [1 - 0.2 / 0.45, 0.8 + 0.2 * 0.76 * 0.9]
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
                XCTAssertEqual(channel, expectedCPU[i], accuracy: 1e-3)
            }
            XCTAssertLessThan(cpu[100, y].maxAbsDifference(RGB(gray: 1)), 1e-6)
            XCTAssertLessThan(gpu[100, y].maxAbsDifference(RGB(gray: 1)), 1e-3)
            XCTAssertLessThan(cpu[x, y].maxAbsDifference(gpu[x, y]), 1e-3)
            XCTAssertGreaterThan(abs(gpu[x, y].r - historicalGPU[i]), 0.04,
                "old no-sky equations must fail this contract")
            let record: [String] = ["DEHAZE-SKY-CONTRACT", "amount=\(amount)",
                "cpu=\(cpu[x, y].r)", "gpu=\(gpu[x, y].r)",
                "expectedCPU=\(expectedCPU[i])", "historicalGPU=\(historicalGPU[i])",
                "maxRGBDifference=\(cpu[x, y].maxAbsDifference(gpu[x, y]))",
                "referenceTransmission=\(transmission)", "referenceAirlight=\(airlight.r)",
                "qualityAcceptance=false", "controlledPlateauParity=true"]
            print(record.joined(separator: " "))
        }
    }
}
#endif
