#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Optional generated-fixture timing evidence. Completion includes graph assembly,
/// synchronous airlight reads and full float readback; it is not enqueue latency.
/// No performance threshold or claim about private RAW/native GUI latency is made.
final class DehazeCompletionCostTests: XCTestCase {
    func testGeneratedChangingAmountCompletedFrames() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_DEHAZE_COST"] == "1",
                          "opt-in completed-frame Dehaze measurement")
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let label = ProcessInfo.processInfo.environment["LUMEN_DEHAZE_COST_LABEL"] ?? "unspecified"
        for width in [256, 1024] {
            let height = width / 2
            let fixture = ImageBuffer(width: width, height: height) { u, v in
                let fine = 0.015 * sin(u * 96) * sin(v * 80)
                if u > 0.85 { return RGB(0.82, 0.9, 1.0) }
                if v > 0.5 { return RGB(0.62 + fine, 0.7 + fine, 0.8 + fine) }
                return RGB(0.12 + u * 0.25 + fine, 0.2 + u * 0.25 + fine,
                           0.16 + u * 0.2 + fine)
            }
            let bytes = fixture.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let source = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                                 size: CGSize(width: width, height: height),
                                 format: .RGBAf, colorSpace: nil)
            let context = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
                .workingFormat: CIFormat.RGBAf,
            ])
            var output = [Float](repeating: 0, count: width * height * 4)
            // Amount changes every frame; repeated rendering of a single unchanged
            // CIImage would instead measure cached-output retrieval.
            for (index, amount) in [-50.0, -25, -10, 10, 25, 50].enumerated() {
                let start = ProcessInfo.processInfo.systemUptime
                let graph = RenderGraph.applyDehaze(source, amount: amount, longEdge: width)
                let assembled = ProcessInfo.processInfo.systemUptime
                output.withUnsafeMutableBytes { raw in
                    context.render(graph, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                                   bounds: source.extent, format: .RGBAf, colorSpace: nil)
                }
                let completed = ProcessInfo.processInfo.systemUptime
                XCTAssertEqual(graph.extent, source.extent)
                XCTAssertTrue(output.allSatisfy { $0.isFinite })
                let center = ((height / 2) * width + width / 2) * 4
                let sample = Double(output[center])
                XCTAssertGreaterThan(abs(sample - fixture[width / 2, height / 2].r), 1e-5,
                                     "measurement must actually apply nonzero Dehaze")
                let record: [String: Any] = [
                    "label": label, "width": width, "height": height,
                    "frame": index, "amount": amount, "firstContextFrame": index == 0,
                    "assemblySeconds": assembled - start,
                    "readbackSeconds": completed - assembled,
                    "completedSeconds": completed - start,
                    "centerR": sample, "finite": true,
                    "privatePhotoAcceptance": false, "nativeGUIAcceptance": false,
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                var line = Data("DEHAZE-COMPLETION-COST ".utf8)
                line.append(data)
                line.append(10)
                FileHandle.standardOutput.write(line)
            }
        }
    }
}
#endif
