#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenPipeline

/// Same destination sizes/format/context, a DIFFERENT (constant synthetic) graph.
/// A pass does not exonerate RAW graph memory, decoder scheduling or device pressure.
final class SyntheticMaterializationLoadTests: XCTestCase {
    private func emit(_ record: [String: Any], diagnostic: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        var line = Data((diagnostic ? "MATERIALIZATION-SYNTHETIC-DIAGNOSTIC " : "MATERIALIZATION-SYNTHETIC ").utf8)
        line.append(data); line.append(10); FileHandle.standardOutput.write(line)
    }
    func testSameSizeConstantGraphSharedMaterializerUnderLoad() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_MATERIALIZATION_SYNTHETIC"] == "1",
                          "opt-in same-size synthetic constant-graph materialization")
        let begin = ProcessInfo.processInfo.systemUptime
        // Exact actual first-plane extents archived from c21's public serial run.
        let dimensions: [(String, Int, Int)] = [("1346", 4368, 2912), ("2349", 3056, 4592),
            ("2607", 3680, 2760), ("4671", 3888, 2592), ("5812", 3712, 5568)]
        let working = try XCTUnwrap(DecodeMaterializer.workingSpace)
        let pixel: [Float] = [-0.25, 0.5, 4, 1]
        let bitmap = pixel.withUnsafeBufferPointer { Data(buffer: $0) }
        let onePixel = CIImage(bitmapData: bitmap, bytesPerRow: 16, size: CGSize(width: 1, height: 1),
                               format: .RGBAf, colorSpace: working)
        let reader = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAf,
                                         .cacheIntermediates: false])
        var attempts = 0, success = 0, materializationFailures = 0, readFailures = 0
        for pass in 0..<2 {
            let ordered = pass == 0 ? dimensions : Array(dimensions.reversed())
            for (identifier, width, height) in ordered {
                for iteration in 0..<6 {
                    try autoreleasepool {
                        let metadata: [String: Any] = ["fixture": "synthetic-size-" + identifier,
                            "width": width, "height": height, "pass": pass, "iteration": iteration,
                            "graph": "1x1 signed/HDR RGBAf working-tagged bitmap clamped/cropped to full size",
                            "rawGraphMemoryEquivalent": false]
                        try emit(metadata.merging(["event": "before-materialize"]) { _, new in new }, diagnostic: true)
                        let start = ProcessInfo.processInfo.systemUptime
                        var reasons: [[String: Any]] = []
                        let input = onePixel.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                        let result = DecodeMaterializer.materialize(input, evaluatingIn: .pipeline, reportFailure: { failure in
                            var row: [String: Any] = [:]
                            switch failure {
                            case .contextUnavailable: row["reason"] = "context-unavailable"
                            case .admissionRefused: row["reason"] = "admission-refused"
                            case .workingColorSpaceUnavailable: row["reason"] = "working-color-space-unavailable"
                            case .pixelBufferCreation(let status): row["reason"] = "CVPixelBufferCreate"; row["CVReturn"] = status
                            case .missingPixelBuffer: row["reason"] = "missing-pixel-buffer-after-success"
                            case .renderTask(let phase, let error):
                                row["reason"] = "render-task"; row["renderPhase"] = phase.rawValue
                                row.merge(DecodeReconstructionContinuityTests.boundedErrorChain(error,
                                    includeDescriptions: ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1")) { _, new in new }
                            }
                            reasons.append(row)
                        })
                        attempts += 1
                        var row = metadata
                        row["materializeSeconds"] = ProcessInfo.processInfo.systemUptime - start
                        row["failureReports"] = reasons
                        guard let result else {
                            materializationFailures += 1
                            row["outcome"] = "materializer-nil"
                            try emit(row)
                            XCTFail("synthetic materialization refused size " + identifier + "/pass\(pass)/iteration\(iteration)")
                            return
                        }
                        row["allocatedBytes"] = result.bytes
                        XCTAssertTrue(reasons.isEmpty, "a successful materialization must not report a failure")
                        var values = [Float](repeating: .nan, count: 32 * 32 * 4)
                        do {
                            try values.withUnsafeMutableBytes { bytes in
                                let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: 32,
                                    height: 32, bytesPerRow: 32 * 16, format: .RGBAf)
                                destination.colorSpace = working; destination.isClamped = false
                                let task = try reader.startTask(toRender: result.image,
                                    from: CGRect(x: width / 2, y: height / 2, width: 32, height: 32),
                                    to: destination, at: .zero)
                                _ = try task.waitUntilCompleted()
                            }
                            let finite = values.allSatisfy { $0.isFinite }
                            let exact = values.enumerated().allSatisfy { $0.element == pixel[$0.offset % 4] }
                            let maximum = values.enumerated().compactMap { pair -> Double? in
                                pair.element.isFinite ? abs(Double(pair.element - pixel[pair.offset % 4])) : nil
                            }.max() ?? 0
                            row["outcome"] = "materialized-and-read"
                            row["finite"] = finite; row["exactKnownConstant"] = exact
                            row["maximumAbsoluteError"] = maximum
                            // All four values are exactly representable in half float;
                            // alpha is 1 and all tags/spaces are the same working space.
                            XCTAssertTrue(finite && exact, "known signed/HDR constant changed; max=\(maximum)")
                            if finite && exact { success += 1 }
                        } catch {
                            readFailures += 1
                            row["outcome"] = "checked-readback-threw"
                            row.merge(DecodeReconstructionContinuityTests.boundedErrorChain(error as NSError,
                                includeDescriptions: ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1")) { _, new in new }
                            XCTFail("synthetic checked readback threw; see bounded NSError record")
                        }
                        try emit(row)
                        // The plane/reader destination leave this autoreleasepool
                        // before the next attempt. No planes or images are archived.
                    }
                }
            }
        }
        try emit(["tap": "summary", "attempts": attempts, "exactKnownConstantSuccesses": success,
            "materializationFailures": materializationFailures, "readbackFailures": readFailures,
            "processID": ProcessInfo.processInfo.processIdentifier, "beginUptime": begin,
            "endUptime": ProcessInfo.processInfo.systemUptime, "rawGraphMemoryEquivalent": false])
        XCTAssertEqual(attempts, 60)
        XCTAssertEqual(success, 60)
    }
}
#endif
