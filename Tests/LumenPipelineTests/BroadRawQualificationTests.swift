#if os(macOS)
import Foundation
import CoreImage
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

/// Broad compatibility pass, separate from detailed calibration of selected copies.
/// Input is a private list of read-only originals; this path never writes sidecars.
final class BroadRawQualificationTests: XCTestCase {
    func testBroadCameraDecodeAndDefaultPreview() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inventory = env["LUMEN_RAW_PATH_LIST"],
              let output = env["LUMEN_BROAD_RAW_EVIDENCE"] else {
            throw XCTSkip("Private broad RAW compatibility pass is opt-in")
        }
        let all = try String(contentsOfFile: inventory, encoding: .utf8).split(separator: "\n").map(String.init)
        let strideBy = max(1, Int(env["LUMEN_BROAD_RAW_STRIDE"] ?? "13") ?? 13)
        let offset = max(0, Int(env["LUMEN_BROAD_RAW_OFFSET"] ?? "0") ?? 0)
        let limit = max(1, Int(env["LUMEN_BROAD_RAW_LIMIT"] ?? "1200") ?? 1200)
        let selected = Array(all.enumerated().filter { $0.offset % strideBy == offset % strideBy }.prefix(limit))
        XCTAssertFalse(selected.isEmpty)
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("broad-\(offset).jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        for (index, path) in selected {
            autoreleasepool {
                let start = Date()
                var record: [String:Any] = ["ordinal": index, "status": "error"]
                defer {
                    record["seconds"] = Date().timeIntervalSince(start)
                    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                        try? handle.write(contentsOf: data); try? handle.write(contentsOf: Data([10]))
                    }
                    print("broad-raw ordinal=\(index) status=\(record["status"]!) seconds=\(Date().timeIntervalSince(start))"); fflush(stdout)
                }
                do {
                    let source = try AppleRawSource(url: URL(fileURLWithPath: path))
                    let renderer = PipelineRenderer()
                    var recipe = Recipe()
                    recipe.develop.denoise = ISODefaults.startingDenoise(forISO: source.captureISO)
                    let image = try renderer.renderPreview(source: source, recipe: recipe,
                                   maxLongEdge: 384, draft: false, coarseDecode: false)
                    XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
                    XCTAssertLessThanOrEqual(max(image.width, image.height), 385)
                    XCTAssertTrue(renderer.availability.unavailable.isEmpty)
                    record["width"] = image.width; record["height"] = image.height
                    record["nativeWidth"] = source.nativePixelSize.width
                    record["nativeHeight"] = source.nativePixelSize.height
                    record["iso"] = source.captureISO ?? -1
                    record["decoder"] = source.pinnedDecoderVersion ?? -1
                    record["status"] = "rendered"
                } catch {
                    // Report an ordinal only: errors can embed private absolute paths.
                    XCTFail("RAW ordinal \(index) could not open/render")
                }
            }
        }
    }
}
#endif
