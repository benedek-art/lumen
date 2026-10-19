#if os(macOS)
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Opt-in PRIVATE camera evidence. A zero-response on a photograph is a measurement,
/// not necessarily a defect: there may be no pixels in the selected hue/tone range.
/// The synthetic registry retains its authority assertions. This test exercises the
/// actual preview path, including decoder, camera metadata, plan and quantization.
final class RealRawControlQualificationTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func configuration() throws -> (files: [URL], output: URL) {
        guard let path = env["LUMEN_REAL_RAW_DIR"], !path.isEmpty,
              let output = env["LUMEN_REAL_RAW_EVIDENCE"], !output.isEmpty else {
            throw XCTSkip("Private real-RAW sweep is opt-in; set both corpus and evidence directories")
        }
        let root = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: root,
                         includingPropertiesForKeys: nil)
            .filter { ["arw", "rw2", "nef", "cr2", "cr3", "dng", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "Configured private corpus contains no RAW files")
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (files, destination)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var result = [UInt8](repeating: 0, count: width * height * 4)
        let success = result.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(success)
        return result
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (rms: Double, max: Int) {
        guard a.count == b.count, !a.isEmpty else { return (.infinity, 255) }
        var squared = 0.0, maximum = 0, count = 0
        for i in a.indices where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i]))
            maximum = max(maximum, d); squared += Double(d * d); count += 1
        }
        return ((squared / Double(count)).squareRoot(), maximum)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                    UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func append(_ row: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10]))
    }

    func testEveryRegisteredControlOnPrivateCameraPhotographs() throws {
        let config = try configuration()
        XCTAssertTrue(KernelLibrary.isAvailable, "Never certify fallback-only camera sweeps")
        let steps = max(3, Int(env["LUMEN_REAL_RAW_STEPS"] ?? "21") ?? 21)
        let edge = max(128, Int(env["LUMEN_REAL_RAW_EDGE"] ?? "768") ?? 768)
        let selected = env["LUMEN_REAL_RAW_CONTROLS"].map { Set($0.split(separator: ",").map(String.init)) }
        let specs = ProofRegistry.all.filter { selected == nil || selected!.contains($0.id) }
        XCTAssertFalse(specs.isEmpty)
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count)
        let log = config.output.appendingPathComponent("preview-sweeps.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        for (fileIndex, file) in config.files.enumerated() {
            let fileID = String(format: "photo%03d", fileIndex + 1)
            try autoreleasepool {
                let source = try AppleRawSource(url: file)
                let renderer = PipelineRenderer()
                let folder = config.output.appendingPathComponent(fileID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for spec in specs {
                    var previous: [UInt8]?, first: [UInt8]?, last: [UInt8]?
                    var jumps = [Double](), timings = [Double](), worst = 0
                    for step in 0..<steps {
                        try autoreleasepool {
                            let setting = spec.low + (spec.high - spec.low) * Double(step) / Double(steps - 1)
                            var recipe = Recipe()
                            recipe.develop.denoise = ISODefaults.startingDenoise(forISO: source.captureISO)
                            spec.apply(&recipe, setting)
                            let start = DispatchTime.now().uptimeNanoseconds
                            let image = try renderer.renderPreview(source: source, recipe: recipe,
                                       maxLongEdge: edge, draft: false, coarseDecode: false)
                            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                            XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
                            XCTAssertLessThanOrEqual(max(image.width, image.height), edge + 1)
                            let bytes = try pixels(image)
                            if let previous { let d = difference(previous, bytes); jumps.append(d.rms); worst = max(worst, d.max) }
                            previous = bytes
                            if step == 0 { first = bytes }
                            if step == steps - 1 { last = bytes }
                            if step == 0 || step == steps / 2 || step == steps - 1 {
                                try write(image, to: folder.appendingPathComponent("\(spec.id)-\(step).png"))
                            }
                        }
                    }
                    let endpoint = difference(first!, last!)
                    try append(["photo": fileID, "control": spec.id, "panel": spec.panel,
                        "low": spec.low, "high": spec.high, "steps": steps,
                        "iso": source.captureISO ?? -1, "nativeWidth": source.nativePixelSize.width,
                        "nativeHeight": source.nativePixelSize.height,
                        "adjacentRMSCodes": jumps, "endpointRMSCodes": endpoint.rms,
                        "maxAdjacentCode": worst, "renderMilliseconds": timings,
                        "circular": spec.isCircular], to: handle)
                    print("real-raw-control: \(fileID) \(spec.id) \(steps) renders, endpoint RMS \(endpoint.rms)")
                    fflush(stdout)
                }
                let unavailable = renderer.availability.unavailable
                XCTAssertTrue(unavailable.isEmpty, "Missing rendering capabilities: \(unavailable)")
            }
        }
    }
}
#endif
