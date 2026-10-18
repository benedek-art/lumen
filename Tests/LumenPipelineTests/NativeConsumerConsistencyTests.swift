#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

/// Opt-in first-native/cache-promotion evidence through shipping consumers. A fresh
/// AppleRawSource is used for EVERY consumer/policy. Policies are experiments at the
/// ImageSource seam, not production changes. Exact identity remains mandatory;
/// synthetic parity and public fixtures do not certify camera aesthetics.
final class NativeConsumerConsistencyTests: XCTestCase {
    private enum Policy: String, CaseIterable {
        case unchanged, intermediate, eager
    }

    private final class BoundarySource: ImageSource {
        let base: AppleRawSource
        let policy: Policy
        init(url: URL, policy: Policy) throws {
            base = try AppleRawSource(url: url)
            self.policy = policy
        }
        var url: URL { base.url }
        var nativeLongEdge: Double { base.nativeLongEdge }
        var nativePixelSize: (width: Int, height: Int) { base.nativePixelSize }
        var asShotTemperature: Double { base.asShotTemperature }
        var asShotTint: Double { base.asShotTint }
        var captureMetadata: CaptureMetadata { base.captureMetadata }
        var statisticsProvenance: RawStatistics.Provenance { base.statisticsProvenance }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            guard let decoded = base.decode(recipe: recipe, draft: draft,
                                             scaleFactor: scaleFactor) else { return nil }
            switch policy {
            case .unchanged: return decoded
            case .intermediate: return decoded.insertingIntermediate(cache: false)
            case .eager: return DecodeMaterializer.materialize(decoded)?.image
            }
        }
    }

    private struct Snapshot {
        var bytes = Data()
        var values: [Double] = []
        var shape: String
    }

    private var quietRecipe: Recipe {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail.capture.auto = false
        recipe.develop.geometry.lens.profile = false
        return recipe
    }

    private static func emit(_ line: String) {
        fputs("\n" + line + "\n", stdout)
        fflush(stdout)
    }

    /// Default to two fixtures; an explicit bounded opt-in may qualify up to five.
    /// Directory enumeration and setup errors never print original names/paths.
    private func fixtures() throws -> [URL] {
        let path = (ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset") }
        let configuredLimit = (ProcessInfo.processInfo.environment["LUMEN_AUDIT_NATIVE_CONSUMER_LIMIT"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit: Int
        if configuredLimit.isEmpty {
            limit = 2
        } else if let requested = Int(configuredLimit), (1...5).contains(requested) {
            limit = requested
        } else {
            XCTFail("LUMEN_AUDIT_NATIVE_CONSUMER_LIMIT must be an integer from 1 through 5")
            return []
        }
        let root = URL(fileURLWithPath: path)
        let extensions: Set<String> = ["arw", "nef", "cr3", "dng", "raf", "cr2", "rw2", "orf", "pef", "iiq", "gpr"]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            XCTFail("Configured native-consumer directory could not be enumerated")
            return []
        }
        XCTAssertFalse(urls.isEmpty, "Configured native-consumer directory contains no RAW fixtures")
        Self.emit("native-consumer-fixtures: available=\(urls.count) limit=\(limit) selected=\(min(limit, urls.count))")
        return Array(urls.prefix(limit))
    }

    /// Copy active pixel components, excluding row padding and explicit unused X
    /// components. No conversion: half-float/16-bit component bytes stay untouched.
    /// For 8-bpc 32Little, the four component positions reverse in memory. For
    /// 16Little, only the two bytes WITHIN each component reverse, not its position.
    private func packed(_ image: CGImage) throws -> Snapshot {
        guard image.bitsPerPixel % 8 == 0, image.bitsPerComponent % 8 == 0,
              image.bitsPerComponent > 0,
              image.bitsPerPixel % image.bitsPerComponent == 0 else {
            XCTFail("Consumer image must have byte-aligned component storage")
            return Snapshot(shape: "invalid")
        }
        let pixelBytes = image.bitsPerPixel / 8
        let componentBytes = image.bitsPerComponent / 8
        let components = image.bitsPerPixel / image.bitsPerComponent
        let row = image.width * pixelBytes
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        guard image.bytesPerRow >= row, data.count >= image.bytesPerRow * image.height else {
            XCTFail("Image provider has insufficient storage for active pixel rows")
            return Snapshot(shape: "invalid")
        }
        var unusedComponent: Int?
        switch image.alphaInfo {
        case .noneSkipFirst: unusedComponent = 0
        case .noneSkipLast: unusedComponent = components - 1
        default: break
        }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if let unused = unusedComponent, image.bitsPerComponent == 8,
           image.bitsPerPixel == 32, order == .byteOrder32Little {
            unusedComponent = components - 1 - unused
        }
        var active = Data(capacity: row * image.height)
        for y in 0..<image.height {
            let rowStart = y * image.bytesPerRow
            if let unused = unusedComponent {
                for x in 0..<image.width {
                    let pixelStart = rowStart + x * pixelBytes
                    for component in 0..<components where component != unused {
                        let start = pixelStart + component * componentBytes
                        active.append(data[start..<(start + componentBytes)])
                    }
                }
            } else {
                active.append(data[rowStart..<(rowStart + row)])
            }
        }
        let shapeParts: [String] = [
            "\(image.width)x\(image.height)",
            "bpc\(image.bitsPerComponent)", "bpp\(image.bitsPerPixel)",
            "bitmap\(image.bitmapInfo.rawValue)",
        ]
        return Snapshot(bytes: active, shape: shapeParts.joined(separator: ":"))
    }

    /// Harness regression: vary ALL unused bytes while keeping semantic components
    /// fixed. Also mutate a real component to prove the reader does not ignore pixels.
    func testPackingExcludesSkippedComponentsAndRowPaddingAtBothDepths() throws {
        let configurations: [(bits: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo,
                              skippedByteRange: Range<Int>)] = [
            (8, .noneSkipFirst, .byteOrder32Little, 3..<4),
            (8, .noneSkipLast, .byteOrder32Little, 0..<1),
            (8, .noneSkipFirst, .byteOrder32Big, 0..<1),
            (8, .noneSkipLast, .byteOrder32Big, 3..<4),
            (16, .noneSkipFirst, .byteOrder16Little, 0..<2),
            (16, .noneSkipLast, .byteOrder16Little, 6..<8),
        ]
        for configuration in configurations {
            let pixelBytes = configuration.bits / 8 * 4
            let rowBytes = pixelBytes * 2 + 4
            func fixture(unused: UInt8, mutateActive: Bool = false) throws -> CGImage {
                var bytes = Data(repeating: unused, count: rowBytes * 2)
                for y in 0..<2 {
                    for x in 0..<2 {
                        for byte in 0..<pixelBytes where !configuration.skippedByteRange.contains(byte) {
                            bytes[y * rowBytes + x * pixelBytes + byte] = UInt8(10 + byte)
                        }
                    }
                }
                if mutateActive {
                    let firstActive = (0..<pixelBytes).first { !configuration.skippedByteRange.contains($0) }!
                    bytes[firstActive] += 1
                }
                let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
                let info = configuration.order.union(CGBitmapInfo(rawValue: configuration.alpha.rawValue))
                return try XCTUnwrap(CGImage(width: 2, height: 2,
                    bitsPerComponent: configuration.bits, bitsPerPixel: configuration.bits * 4,
                    bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: info, provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
            }
            let a = try packed(fixture(unused: 0x13))
            let b = try packed(fixture(unused: 0xE7))
            let mutation = try packed(fixture(unused: 0x13, mutateActive: true))
            let expectedPixel = (0..<pixelBytes)
                .filter { !configuration.skippedByteRange.contains($0) }.map { UInt8(10 + $0) }
            let expected = Data(Array(repeating: expectedPixel, count: 4).flatMap { $0 })
            XCTAssertEqual(a.bytes, expected)
            XCTAssertEqual(a.bytes, b.bytes, "Unused pixel/row bytes must not affect identity")
            XCTAssertNotEqual(a.bytes, mutation.bytes, "An active component mutation must be detected")
        }
    }

    private func compare(_ a: Snapshot, _ b: Snapshot, label: String,
                         failures: inout [String]) {
        let byteDeltas = zip(a.bytes, b.bytes).map { abs(Int($0) - Int($1)) }
        let changed = byteDeltas.filter { $0 != 0 }.count
        let maximum = zip(a.values, b.values).map { abs($0 - $1) }.max()
        let sampleDifference = maximum.map { String($0) } ?? "not-applicable"
        let report: [String] = [
            "native-consumer-pair:", label, "shape=\(a.shape)/\(b.shape)",
            "bytes=\(a.bytes.count)/\(b.bytes.count)", "changedBytes=\(changed)",
            "maxByteDifference=\(byteDeltas.max() ?? 0)", "maxSampleDifference=\(sampleDifference)",
        ]
        Self.emit(report.joined(separator: " "))
        if a.shape != b.shape || a.bytes != b.bytes || a.values != b.values {
            failures.append(label)
        }
    }

    private func matrix(_ consumer: String, compareProductionFirstToEager: Bool = false,
                        measure: (BoundarySource, PipelineRenderer, Recipe, Int) throws -> Snapshot) throws {
        // Optional selectors let the workflow launch one cell in a fresh process.
        // The default still measures the complete matrix in the original order.
        let environment = ProcessInfo.processInfo.environment
        let policyName = (environment["LUMEN_AUDIT_NATIVE_CONSUMER_POLICY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let policies: [Policy]
        if policyName.isEmpty {
            policies = Policy.allCases
        } else if let selected = Policy.allCases.first(where: { $0.rawValue == policyName }) {
            policies = [selected]
        } else {
            XCTFail("LUMEN_AUDIT_NATIVE_CONSUMER_POLICY must be unchanged, intermediate or eager")
            return
        }
        let consumerName = (environment["LUMEN_AUDIT_NATIVE_CONSUMER_NAME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let consumerNames: Set<String> = [
            "dehazeSDR", "EDRhalf", "sample-scene", "sample-color", "sample-mask", "croppedTIFF16",
            "sample-point-color",
        ]
        if !consumerName.isEmpty {
            guard consumerNames.contains(consumerName) else {
                XCTFail("LUMEN_AUDIT_NATIVE_CONSUMER_NAME must name one of the seven supported consumers")
                return
            }
            if consumerName != consumer { return }
        }
        var failures: [String] = []
        for (index, url) in try fixtures().enumerated() {
            let ordinal = "fixture\(index + 1)"
            var results: [Policy: (Snapshot, Snapshot)] = [:]
            for policy in policies {
                do {
                    var pair: (Snapshot, Snapshot)?
                    try autoreleasepool { () throws -> Void in
                        let constructStarted = DispatchTime.now().uptimeNanoseconds
                        let source = try BoundarySource(url: url, policy: policy)
                        let renderer = PipelineRenderer()
                        let constructMs = Double(DispatchTime.now().uptimeNanoseconds - constructStarted) / 1e6
                        let firstStarted = DispatchTime.now().uptimeNanoseconds
                        let first = try measure(source, renderer, quietRecipe, 0)
                        let firstMs = Double(DispatchTime.now().uptimeNanoseconds - firstStarted) / 1e6
                        let firstHeld = source.base.heldDecodeBytes
                        let repeatStarted = DispatchTime.now().uptimeNanoseconds
                        let repeated = try measure(source, renderer, quietRecipe, 1)
                        let repeatMs = Double(DispatchTime.now().uptimeNanoseconds - repeatStarted) / 1e6
                        let timing: [String] = [
                            "native-consumer-timing:", ordinal, "consumer=\(consumer)",
                            "policy=\(policy.rawValue)", "decoder=\(source.base.pinnedDecoderVersion ?? -1)",
                            "edge=\(source.nativeLongEdge)", "constructMs=\(constructMs)",
                            "firstMs=\(firstMs)", "repeatMs=\(repeatMs)",
                            "firstHeld=\(firstHeld)", "repeatHeld=\(source.base.heldDecodeBytes)",
                        ]
                        Self.emit(timing.joined(separator: " "))
                        pair = (first, repeated)
                    }
                    guard let pair else {
                        failures.append("\(ordinal) \(consumer) \(policy.rawValue) missing measurement pair")
                        continue
                    }
                    results[policy] = pair
                    compare(pair.0, pair.1,
                            label: "\(ordinal) \(consumer) \(policy.rawValue) first-repeat", failures: &failures)
                } catch {
                    // Do not interpolate error descriptions: decoder/ImageIO errors
                    // can carry the user's private original's complete path.
                    Self.emit("native-consumer-error: \(ordinal) consumer=\(consumer) policy=\(policy.rawValue)")
                    failures.append("\(ordinal) \(consumer) \(policy.rawValue) failed to produce measurements")
                }
            }
            if let candidate = results[.intermediate], let canonical = results[.eager] {
                compare(candidate.0, canonical.0,
                        label: "\(ordinal) \(consumer) intermediate-eager first", failures: &failures)
                compare(candidate.1, canonical.1,
                        label: "\(ordinal) \(consumer) intermediate-eager repeat", failures: &failures)
            }
            if compareProductionFirstToEager,
               let production = results[.unchanged], let canonical = results[.eager] {
                // This additional public Point Colour check compares the production
                // source boundary with an explicit plane before either is reused.
                compare(production.0, canonical.0,
                        label: "\(ordinal) \(consumer) production-eager first", failures: &failures)
            }
            Self.emit("native-consumer-file: \(ordinal) consumer=\(consumer) policies=\(results.count)")
        }
        // Emit every policy/fixture measurement before aggregate exact-identity
        // failures, so a known-red baseline does not suppress candidate evidence.
        for failure in failures { XCTFail("Exact native consumer identity: " + failure) }
    }

    func testNonzeroDehazeSDRFirstRepeatAndBoundaryPolicies() throws {
        try matrix("dehazeSDR") { source, renderer, recipe, _ in
            var edited = recipe
            edited.develop.detail.dehaze = 35
            let delivery = try renderer.renderPreviewDelivery(source: source, recipe: edited,
                maxLongEdge: Int(source.nativeLongEdge.rounded(.up)), draft: false, coarseDecode: false,
                region: CGRect(x: 0.4825, y: 0.4825, width: 0.035, height: 0.035))
            XCTAssertNotNil(delivery.regionUnit, "Dehaze qualification must deliver bounded native ROI")
            return try packed(delivery.image)
        }
    }

    func testEDRHalfFloatFirstRepeatAndBoundaryPolicies() throws {
        try matrix("EDRhalf") { source, renderer, recipe, _ in
            let delivery = try renderer.renderPreviewEDR(source: source, recipe: recipe,
                maxLongEdge: Int(source.nativeLongEdge.rounded(.up)), draft: false, coarseDecode: false,
                region: CGRect(x: 0.4825, y: 0.4825, width: 0.035, height: 0.035),
                displayWhiteTarget: 200)
            XCTAssertNotNil(delivery.regionUnit, "EDR qualification must deliver bounded native ROI")
            XCTAssertEqual(delivery.image.bitsPerComponent, 16)
            XCTAssertTrue(delivery.image.bitmapInfo.contains(.floatComponents))
            return try packed(delivery.image)
        }
    }

    private enum Sample: String, CaseIterable {
        case scene, color, mask
        case pointColor = "point-color"
    }

    func testSceneColorAndMaskStageSamplersFirstRepeatAndBoundaryPolicies() throws {
        for sample in Sample.allCases {
            try matrix("sample-" + sample.rawValue,
                       compareProductionFirstToEager: sample == .pointColor) { source, renderer, recipe, _ in
                let picked: RGB?
                switch sample {
                case .scene:
                    picked = renderer.sampleSceneLinear(source: source, recipe: recipe,
                        sourceX: 0.5, sourceY: 0.5, radius: 2)
                case .color:
                    picked = renderer.sampleColorStageInput(source: source, recipe: recipe,
                        sourceX: 0.5, sourceY: 0.5, tap: .pointColor(index: 0), radius: 2)
                case .mask:
                    picked = renderer.sampleMaskStageInput(source: source, recipe: recipe,
                        sourceX: 0.5, sourceY: 0.5, radius: 2)
                case .pointColor:
                    // Exercise the shipping S3/S8 global picker path with actual
                    // presence before S9. Denoise remains Off to isolate Dehaze;
                    // this measures identity and completed sample cost, not camera
                    // colour calibration or subjective denoise quality.
                    var edited = recipe
                    edited.develop.denoise.mode = .off
                    edited.develop.detail.dehaze = 35
                    picked = renderer.sampleColorStageInput(source: source, recipe: edited,
                        sourceX: 0.5, sourceY: 0.5, tap: .pointColor(index: 0), radius: 2)
                }
                let rgb = try XCTUnwrap(picked, "Native sampler must produce a value")
                XCTAssertTrue(rgb.isFinite)
                return Snapshot(values: [rgb.r, rgb.g, rgb.b], shape: "RGB-double:5x5-native-window")
            }
        }
    }

    /// Native decode, actual TIFF16 write and ImageIO readback, bounded to a small
    /// central crop. This is deliberately NOT a full-frame export performance claim.
    /// Separate opt-in prevents ordinary corpus jobs paying six full native decodes.
    func testCroppedNativeTIFF16WriteReadbackFirstRepeatAndBoundaryPolicies() throws {
        guard ProcessInfo.processInfo.environment["LUMEN_AUDIT_NATIVE_EXPORT16"] == "1" else {
            throw XCTSkip("LUMEN_AUDIT_NATIVE_EXPORT16=1 required for actual TIFF16 consumer lane")
        }
        try matrix("croppedTIFF16") { source, renderer, recipe, _ in
            var edited = recipe
            edited.develop.geometry.crop = Crop(x: 0.475, y: 0.475, w: 0.05, h: 0.05)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-native-consumer-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("delivery.tif")
            let delivery = ExportRecipe(name: "Native consumer TIFF16", format: .tiff,
                                        bitDepth: 16, colorSpace: .srgb)
            let unavailable = try renderer.export(source: source, recipe: edited, to: output, using: delivery)
            XCTAssertTrue(unavailable.isEmpty, "Actual export must not silently omit unavailable stages")
            let container = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(container, 0, nil))
            XCTAssertEqual(decoded.bitsPerComponent, 16, "ImageIO must read actual sixteen-bit delivery")
            return try packed(decoded)
        }
    }
}
#endif
