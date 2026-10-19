#if os(macOS)
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Experimental task partitioning only. Never selects RAW9 or changes production.
final class NativeMaterializationPartitionTests: XCTestCase {
    private enum PartitionFixtureError: Error { case invalidArm, refused, allocation(Int32), failedTask, syntheticMismatch }
    private func emit(_ row: [String: Any]) {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("MATERIALIZATION-PARTITION ".utf8) + bytes + Data([10]))
        } catch { XCTFail("partition diagnostic JSON failed") }
    }
    private func chain(_ error: Error) -> [String: Any] {
        DecodeReconstructionContinuityTests.boundedErrorChain(error as NSError,
            includeDescriptions: ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1")
    }
    private func materialize(_ image: CIImage, evaluation: DecodeMaterializer.EvaluationSpace,
                             tile: Int?, context: [String: Any]) throws -> DecodeMaterializer.Plane {
        // The experimental path cannot access RAW9's private evaluation context.
        switch evaluation {
        case .pipeline: break
        case .raw9LinearSRGB:
            emit(context.merging(["event": "unsupported-raw9"]) { _, n in n })
            throw PartitionFixtureError.refused
        }
        guard DecodeMaterializer.isEligible(image), let working = DecodeMaterializer.workingSpace else {
            throw PartitionFixtureError.refused
        }
        let extent = image.extent
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        let start = ProcessInfo.processInfo.systemUptime
        emit(context.merging(["event": "materialization-begin", "beginUptime": start]) { _, n in n })
        guard let tile else {
            var failureRows: [[String: Any]] = []
            let result = DecodeMaterializer.materialize(image, evaluatingIn: evaluation, reportFailure: { failure in
                var row: [String: Any] = ["event": "whole-production-failure"]
                switch failure {
                case .renderTask(let phase, let error):
                    row["phase"] = phase.rawValue
                    row.merge(self.chain(error)) { _, n in n }
                case .pixelBufferCreation(let status): row["CVReturn"] = status
                default: row["reason"] = String(describing: failure)
                }
                failureRows.append(row)
                self.emit(context.merging(row) { _, n in n })
            })
            guard let result else { throw PartitionFixtureError.refused }
            var row = context
            row.merge(["event": "materialized", "taskCount": 1, "nominalBytes": result.bytes,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                "beginUptime": start, "endUptime": ProcessInfo.processInfo.systemUptime]) { _, n in n }
            if let buffer = result.image.pixelBuffer {
                row["actualRowBytes"] = CVPixelBufferGetBytesPerRow(buffer)
                row["actualDataBytes"] = CVPixelBufferGetDataSize(buffer)
                row["defaultDestinationFlipped"] = CIRenderDestination(pixelBuffer: buffer).isFlipped
            } else { row["actualBufferMetadataAvailable"] = false }
            XCTAssertTrue(failureRows.isEmpty)
            emit(row)
            return result
        }
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            emit(context.merging(["event": "tile-allocation-failed", "CVReturn": status]) { _, n in n })
            throw PartitionFixtureError.allocation(status)
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = working
        destination.isClamped = false
        var count = 0
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let bounds = CGRect(x: extent.minX + CGFloat(x), y: extent.minY + CGFloat(y),
                    width: CGFloat(min(tile, width - x)), height: CGFloat(min(tile, height - y)))
                let taskStart = ProcessInfo.processInfo.systemUptime
                var phase = "startTask"
                do {
                    let task = try DecodeMaterializer.context.startTask(toRender: image, from: bounds,
                        to: destination, at: CGPoint(x: x, y: y))
                    phase = "waitUntilCompleted"
                    _ = try task.waitUntilCompleted()
                } catch {
                    var row = context
                    row.merge(["event": "tile-task-failed", "phase": phase, "tileX": x, "tileY": y,
                        "tileWidth": bounds.width, "tileHeight": bounds.height,
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - taskStart]) { _, n in n }
                    row.merge(chain(error)) { _, n in n }; emit(row)
                    throw error
                }
                count += 1
                emit(context.merging(["event": "tile-task-completed", "tileX": x, "tileY": y,
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - taskStart]) { _, n in n })
            }
        }
        let out = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: working])
        let restored = extent.origin == .zero ? out :
            out.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let bytes = width * height * DecodeMaterializer.bytesPerPixel
        emit(context.merging(["event": "materialized", "taskCount": count, "nominalBytes": bytes,
            "actualRowBytes": CVPixelBufferGetBytesPerRow(buffer), "actualDataBytes": CVPixelBufferGetDataSize(buffer),
            "defaultDestinationFlipped": destination.isFlipped,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "beginUptime": start, "endUptime": ProcessInfo.processInfo.systemUptime]) { _, n in n })
        return (restored, bytes)
    }
    private func read(_ image: CIImage, bounds: CGRect, reader: CIContext,
                      working: CGColorSpace) throws -> [Float] {
        let width = Int(bounds.width), height = Int(bounds.height)
        var values = [Float](repeating: .nan, count: width * height * 4)
        do {
        try values.withUnsafeMutableBytes { raw in
            let destination = CIRenderDestination(bitmapData: raw.baseAddress!, width: width, height: height,
                bytesPerRow: width * 16, format: .RGBAf)
            destination.colorSpace = working; destination.isClamped = false
            let task = try reader.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        }
        } catch {
            emit(["event": "readback-threw", "bounds": String(describing: bounds)].merging(chain(error)) { _, n in n })
            throw error
        }
        guard values.allSatisfy({ $0.isFinite }) else {
            emit(["event": "readback-nonfinite", "bounds": String(describing: bounds)])
            throw PartitionFixtureError.failedTask
        }
        return values
    }
    private func packed(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress!, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    func testSharedContextTaskPartitionPreservesSampledNativeOff() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUMEN_MATERIALIZATION_PARTITION"] == "1", "opt-in public task partition diagnostic")
        let arm = env["LUMEN_MATERIALIZATION_PARTITION_ARM"] ?? "whole"
        guard ["whole", "tile1024", "tile2048"].contains(arm) else { throw PartitionFixtureError.invalidArm }
        let tile: Int? = arm == "whole" ? nil : (arm == "tile1024" ? 1024 : 2048)
        let begin = ProcessInfo.processInfo.systemUptime
        let working = try XCTUnwrap(DecodeMaterializer.workingSpace)
        let reader = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAf,
                                         .cacheIntermediates: false])
        // FULL synthetic-plane comparison qualifies coordinates, flip and partial
        // edges before RAW; identical input/warmup in all arms. Not RAW memory equivalence.
        try autoreleasepool {
            let width = 2053, height = 1031
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = Float(x % 257) / 256 - 0.5
                pixels[i + 1] = Float(y % 257) / 128
                pixels[i + 2] = Float((x + 3 * y) % 513) / 128
            } }
            let bytes = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let input = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: working)
                .transformed(by: CGAffineTransform(translationX: 13, y: -7))
            let whole = try materialize(input, evaluation: .pipeline, tile: nil,
                context: ["arm": arm, "kind": "synthetic", "policy": "whole"])
            let reference = try read(whole.image, bounds: whole.image.extent, reader: reader, working: working)
            XCTAssertTrue(reference.contains { $0 < 0 } && reference.contains { $0 > 1 }, "synthetic must retain signed/HDR signal")
            for size in [1024, 2048] {
                let tiled = try materialize(input, evaluation: .pipeline, tile: size,
                    context: ["arm": arm, "kind": "synthetic", "policy": "tile\(size)"])
                let actual = try read(tiled.image, bounds: tiled.image.extent, reader: reader, working: working)
                let changed = zip(reference, actual).filter { $0.0 != $0.1 }.count
                emit(["event": "synthetic-control", "arm": arm, "tile": size, "components": actual.count,
                    "changedComponents": changed, "sameExtent": whole.image.extent == tiled.image.extent,
                    "nonzeroOrigin": true, "partialEdges": true])
                guard reference == actual && whole.image.extent == tiled.image.extent else {
                    XCTFail("task partition changed full synthetic plane"); throw PartitionFixtureError.syntheticMismatch
                }
            }
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["LUMEN_AUDIT_RAW_DIR"]))
        let rows = try String(contentsOf: root.appendingPathComponent("corpus.tsv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: ";", omittingEmptySubsequences: false).map(String.init) }
        let wanted = Set(["1346", "2349", "2607", "4671", "5812"])
        let fixtures = rows.filter { $0.count == 10 && wanted.contains($0[0]) && $0[7] == "CC0" }
        XCTAssertEqual(Set(fixtures.map { $0[0] }), wanted)
        XCTAssertEqual(fixtures.count, 5)
        var recipe = Recipe(); recipe.develop.denoise = Denoise(mode: .off)
        var prior: [String: [Data]] = [:]
        var files = 0, samples = 0, pairs = 0
        let rawBegin = ProcessInfo.processInfo.systemUptime
        for pass in 0..<2 {
            for row in (pass == 0 ? fixtures : Array(fixtures.reversed())) {
                try autoreleasepool {
                    let id = row[0]
                    let source = try AppleRawSource(url: root.appendingPathComponent(row[1]), materializer: { image, evaluation in
                        do { return try self.materialize(image, evaluation: evaluation, tile: tile,
                            context: ["kind": "raw", "arm": arm, "fixture": id, "pass": pass]) }
                        catch { self.emit(["event": "materialization-threw", "arm": arm, "fixture": id, "pass": pass]
                            .merging(self.chain(error)) { _, n in n }); return nil }
                    })
                    defer { _ = source.releaseDecodes() }
                    let renderer = PipelineRenderer()
                    XCTAssertTrue(renderer.availability.unavailable.isEmpty)
                    var captured: [Data] = []
                    for (index, center) in [0.5, 0.18, 0.82].enumerated() {
                        let delivery = try renderer.renderPreviewDelivery(source: source, recipe: recipe,
                            maxLongEdge: Int(source.nativeLongEdge.rounded(.up)), draft: false, coarseDecode: false,
                            region: CGRect(x: center - 0.0175, y: center - 0.0175, width: 0.035, height: 0.035))
                        _ = try XCTUnwrap(delivery.regionUnit)
                        let bytes = try packed(delivery.image); XCTAssertFalse(bytes.isEmpty)
                        captured.append(bytes)
                        emit(["event": "sample", "arm": arm, "fixture": id, "pass": pass, "sample": "display-\(index)",
                            "bytes": bytes.count, "sha256": digest(bytes), "width": delivery.image.width,
                            "height": delivery.image.height, "bitsPerComponent": delivery.image.bitsPerComponent,
                            "bitsPerPixel": delivery.image.bitsPerPixel,
                            "displayDigestScope": "8bpc sRGB redraw", "fullSensorIdentity": false])
                        samples += 1
                    }
                    let image = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
                    var points: [(String, CGFloat, CGFloat)] = [("scene-center", image.extent.midX, image.extent.midY)]
                    // Common seam windows in EVERY arm: cover a halo on both sides.
                    for edge in [1024, 2048] {
                        for x in stride(from: edge, to: Int(image.extent.width), by: edge) {
                            points.append(("seam-x-\(edge)-\(x)", image.extent.minX + CGFloat(x), image.extent.midY))
                        }
                        for y in stride(from: edge, to: Int(image.extent.height), by: edge) {
                            points.append(("seam-y-\(edge)-\(y)", image.extent.midX, image.extent.minY + CGFloat(y)))
                        }
                    }
                    var nonzero = false
                    for (name, x, y) in points {
                        let bounds = CGRect(x: min(max(x - 32, image.extent.minX), image.extent.maxX - 64).rounded(),
                            y: min(max(y - 32, image.extent.minY), image.extent.maxY - 64).rounded(), width: 64, height: 64)
                        let values = try read(image, bounds: bounds, reader: reader, working: working)
                        nonzero = nonzero || values.enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 }
                        let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
                        captured.append(bytes)
                        emit(["event": "sample", "arm": arm, "fixture": id, "pass": pass, "sample": name,
                            "bytes": bytes.count, "sha256": digest(bytes), "finite": true,
                            "bounds": String(describing: bounds), "fullSensorIdentity": false])
                        samples += 1
                    }
                    XCTAssertTrue(nonzero, "RAW scene samples must carry nonzero RGB")
                    let expectedSamples = ["1346": 13, "2349": 13, "2607": 11, "4671": 11, "5812": 15]
                    XCTAssertEqual(captured.count, expectedSamples[id] ?? -1)
                    if let previous = prior[id] {
                        XCTAssertEqual(previous.count, captured.count)
                        for (a, b) in zip(previous, captured) {
                            XCTAssertTrue(a == b, "cross-order exact sampled identity failed: " + id)
                            pairs += 1
                        }
                    } else { prior[id] = captured }
                    files += 1
                    emit(["event": "file-summary", "arm": arm, "fixture": id, "pass": pass,
                        "sampleCount": captured.count, "nonzeroSceneRGB": nonzero, "heldNominalBytes": source.heldDecodeBytes])
                }
            }
        }
        emit(["event": "summary", "arm": arm, "files": files, "sampleRecords": samples, "crossOrderPairs": pairs,
            "processID": ProcessInfo.processInfo.processIdentifier, "beginUptime": begin,
            "endUptime": ProcessInfo.processInfo.systemUptime,
            "rawBeginUptime": rawBegin, "rawEndUptime": ProcessInfo.processInfo.systemUptime,
            "fullSensorIdentity": false])
        XCTAssertEqual(files, 10)
        XCTAssertEqual(samples, 126)
        XCTAssertEqual(pairs, 63)
    }
}
#endif
