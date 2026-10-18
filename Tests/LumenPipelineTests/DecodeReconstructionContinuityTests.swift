#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Opt-in causal evidence for cache RECONSTRUCTION, distinct from a cache hit.
/// New decoder/renderer instances per file deliberately retain process-wide contexts.
final class DecodeReconstructionContinuityTests: XCTestCase {
    private struct ReconstructionFixture {
        let url: URL
        let label: String
    }
    private struct ReconstructionCapture {
        let displayed: [Data]
        let scene: [[Float]]
    }
    private func fixtures() throws -> [ReconstructionFixture] {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUMEN_DECODE_RECONSTRUCTION"] == "1", "opt-in decode reconstruction/order diagnostic")
        let path = env["LUMEN_AUDIT_RAW_DIR"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "LUMEN_AUDIT_RAW_DIR unset")
        let root = URL(fileURLWithPath: path)
        let manifest = root.appendingPathComponent("corpus.tsv")
        let limit = min(16, max(1, Int(env["LUMEN_DECODE_RECONSTRUCTION_LIMIT"] ?? "5") ?? 5))
        if FileManager.default.fileExists(atPath: manifest.path) {
            let selected = Set((env["LUMEN_DECODE_RECONSTRUCTION_IDS"] ?? "1346,5812,2349,2607,4671").split(separator: ",").map(String.init))
            let rows = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map {
                $0.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            }.filter { $0.count == 10 && !$0[6].contains("negative") && selected.contains($0[0]) }
            XCTAssertFalse(rows.isEmpty, "configured manifest must contain selected public fixture IDs")
            return rows.prefix(limit).map { ReconstructionFixture(url: root.appendingPathComponent($0[1]), label: "corpus" + $0[0]) }
        }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ["arw", "rw2", "nef", "cr2", "cr3", "dng", "orf", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty)
        return urls.prefix(limit).enumerated().map { ReconstructionFixture(url: $0.element, label: "fixture\($0.offset + 1)") }
    }
    private func emit(_ row: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        var bytes = Data("DECODE-RECONSTRUCTION ".utf8); bytes.append(json); bytes.append(10)
        FileHandle.standardOutput.write(bytes)
    }
    private func diagnostic(_ row: [String: Any]) {
        do {
            let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            var bytes = Data("DECODE-RECONSTRUCTION-DIAGNOSTIC ".utf8)
            bytes.append(json); bytes.append(10)
            FileHandle.standardOutput.write(bytes)
        } catch {
            XCTFail("diagnostic JSON serialization failed: \(error)")
        }
    }
    private func diagnosticDescription(_ error: NSError) -> String {
        // Error text can include original paths. Hosted CI opts in only after its
        // SHA-pinned CC0 manifest is verified; private/local runs withhold it.
        guard ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1" else {
            return "withheld (public-fixture error descriptions not enabled)"
        }
        return error.localizedDescription
    }
    /// Test-only bounded NSError traversal. No userInfo values are serialized.
    static func boundedErrorChain(_ error: NSError, includeDescriptions: Bool) -> [String: Any] {
        var current: NSError? = error
        var seen = Set<ObjectIdentifier>()
        var nodes: [[String: Any]] = []
        var termination = "none"
        while let next = current {
            if nodes.count == 4 { termination = "depth-limit"; break }
            guard seen.insert(ObjectIdentifier(next)).inserted else {
                termination = "cycle"; break
            }
            let underlying = next.userInfo[NSUnderlyingErrorKey]
            let nested = underlying as? NSError
            nodes.append(["level": nodes.count, "domain": next.domain, "code": next.code,
                "underlyingPresent": underlying != nil, "underlyingIsNSError": nested != nil,
                "description": includeDescriptions ? next.localizedDescription : "withheld"])
            if underlying != nil && nested == nil { termination = "non-error-underlying" }
            current = nested
        }
        return ["errorChain": nodes, "errorChainTermination": termination,
                "errorChainTruncated": termination == "depth-limit" || termination == "cycle"]
    }

    func testBoundedErrorChainWithholdsDescriptionsAndCapsDepth() throws {
        let secret = "synthetic-private-path-not-for-output"
        var error = NSError(domain: "synthetic-leaf", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: secret, "unrelatedPrivateValue": secret])
        for level in 0..<6 {
            error = NSError(domain: "synthetic-level", code: level,
                userInfo: [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: secret])
        }
        let redacted = Self.boundedErrorChain(error, includeDescriptions: false)
        let nodes = try XCTUnwrap(redacted["errorChain"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 4)
        XCTAssertEqual(redacted["errorChainTermination"] as? String, "depth-limit")
        XCTAssertTrue(nodes.allSatisfy { $0["underlyingPresent"] as? Bool == true })
        let serialized = try JSONSerialization.data(withJSONObject: redacted)
        XCTAssertNil(serialized.range(of: Data(secret.utf8)), "private descriptions/userInfo must stay withheld")
        let disclosed = try JSONSerialization.data(withJSONObject: Self.boundedErrorChain(error, includeDescriptions: true))
        XCTAssertNotNil(disclosed.range(of: Data(secret.utf8)), "explicit public opt-in must preserve descriptions")
    }

    private func diagnosticError(_ error: Error, event: String, context: [String: Any]) {
        let native = error as NSError
        var row = context
        row["event"] = event
        row["errorDomain"] = native.domain
        row["errorCode"] = native.code
        row["errorDescription"] = diagnosticDescription(native)
        row.merge(Self.boundedErrorChain(native, includeDescriptions:
            ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1")) { _, new in new }
        diagnostic(row)
    }
    private func diagnosticMaterializationFailure(_ failure: DecodeMaterializer.MaterializationFailure,
                                                  context: [String: Any]) {
        var row = context
        row["event"] = "materializer-failure-reason"
        switch failure {
        case .contextUnavailable: row["reason"] = "context-unavailable"
        case .admissionRefused: row["reason"] = "admission-refused"
        case .workingColorSpaceUnavailable: row["reason"] = "working-color-space-unavailable"
        case .pixelBufferCreation(let status):
            row["reason"] = "CVPixelBufferCreate"
            row["CVReturn"] = status
        case .missingPixelBuffer: row["reason"] = "missing-pixel-buffer-after-success"
        case .renderTask(let phase, let error):
            row["reason"] = "render-task"
            row["renderPhase"] = phase.rawValue
            row["errorDomain"] = error.domain
            row["errorCode"] = error.code
            row["errorDescription"] = diagnosticDescription(error)
            row.merge(Self.boundedErrorChain(error, includeDescriptions:
                ProcessInfo.processInfo.environment["LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS"] == "1")) { _, new in new }
        }
        diagnostic(row)
    }

    func testMaterializerFailureReporterPreservesOriginalWrapperRefusal() {
        let infinite = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        var failures: [DecodeMaterializer.MaterializationFailure] = []
        let observed = DecodeMaterializer.materialize(infinite, evaluatingIn: .pipeline,
                                                       reportFailure: { failures.append($0) })
        XCTAssertNil(observed)
        XCTAssertEqual(failures.count, 1, "one refusal must report exactly one cause")
        if let failure = failures.first, case .admissionRefused = failure {} else {
            XCTFail("invalid extent must be classified before allocation")
        }
        // The original signature still satisfies the unchanged production alias.
        let original: DecodeMaterializer.Materializer = DecodeMaterializer.materialize
        XCTAssertNil(original(infinite, .pipeline))
    }

    private func packed(_ image: CGImage) throws -> Data {
        var result = Data(count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
    func testOrderedNativeOffReturnAndExplicitReconstructionRemainIdentical() throws {
        let files = try fixtures()
        let beginUptime = ProcessInfo.processInfo.systemUptime
        let working = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let readContext = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAf,
                                              .cacheIntermediates: false])
        let centers = [0.5, 0.18, 0.82]
        var off = Recipe(); off.develop.denoise = Denoise(mode: .off)
        var priorPass: [String: ReconstructionCapture] = [:]
        var exactPairs: [(String, Data, Data, [Float], [Float])] = []
        var renderCount = 0, filePasses = 0
        var sceneBridgeControlPerformed = false
        var sceneBridgeControlPassed = false
        var materializerPhase = "before-first-render"
        func render(_ source: AppleRawSource, _ renderer: PipelineRenderer, _ recipe: Recipe,
                    fixture: ReconstructionFixture, pass: Int, state: String, allRegions: Bool) throws -> ReconstructionCapture {
            var displayed: [Data] = []
            let regions = allRegions ? centers : [0.5]
            for (index, center) in regions.enumerated() {
                let start = DispatchTime.now().uptimeNanoseconds
                materializerPhase = state + "/region\(index)"
                let diagnosticContext: [String: Any] = ["fixture": fixture.label, "pass": pass,
                    "state": state, "region": index, "heldBytes": source.heldDecodeBytes,
                    "nativeLongEdge": source.nativeLongEdge, "uptime": ProcessInfo.processInfo.systemUptime]
                diagnostic(diagnosticContext.merging(["event": "before-render"]) { _, new in new })
                let delivery: PipelineRenderer.PreviewDelivery
                do {
                    delivery = try renderer.renderPreviewDelivery(source: source, recipe: recipe,
                        maxLongEdge: Int(source.nativeLongEdge.rounded(.up)), draft: false,
                        coarseDecode: false, region: CGRect(x: center - 0.0175, y: center - 0.0175,
                                                           width: 0.035, height: 0.035))
                } catch {
                    diagnosticError(error, event: "render-threw", context: diagnosticContext)
                    throw error
                }
                _ = try XCTUnwrap(delivery.regionUnit, "must remain a bounded native ROI")
                let bytes = try packed(delivery.image)
                XCTAssertFalse(bytes.isEmpty)
                displayed.append(bytes)
                try emit(["tap": "render", "fixture": fixture.label, "pass": pass, "state": state,
                    "region": index, "width": delivery.image.width, "height": delivery.image.height,
                    "heldBytes": source.heldDecodeBytes, "decodeMilliseconds": delivery.decodeMilliseconds,
                    "totalMilliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6])
                renderCount += 1
            }
            if !allRegions { return ReconstructionCapture(displayed: displayed, scene: []) }
            // The render has already made the canonical plane. This is a HIT, not an
            // eager decode that would change the first displayed request's history.
            materializerPhase = state + "/scene-source-hit"
            diagnostic(["event": "before-scene-source-hit", "fixture": fixture.label,
                "pass": pass, "state": state, "heldBytes": source.heldDecodeBytes])
            let image = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
            var scene: [[Float]] = []
            for (index, center) in centers.enumerated() {
                let bounds = CGRect(x: (image.extent.minX + image.extent.width * center).rounded(),
                                    y: (image.extent.minY + image.extent.height * center).rounded(), width: 32, height: 32)
                let diagnosticContext: [String: Any] = ["fixture": fixture.label, "pass": pass,
                    "state": state, "region": index, "heldBytes": source.heldDecodeBytes,
                    "sourceExtent": String(describing: image.extent), "readBounds": String(describing: bounds)]
                diagnostic(diagnosticContext.merging(["event": "before-scene-read"]) { _, new in new })
                // NaN makes an unwritten buffer explicit. The old void render API
                // cannot report a failed command and left its zero initializer intact.
                var values = [Float](repeating: .nan, count: 32 * 32 * 4)
                var destinationFlipped = false
                do {
                    try values.withUnsafeMutableBytes { raw in
                        let destination = CIRenderDestination(bitmapData: raw.baseAddress!, width: 32,
                            height: 32, bytesPerRow: 32 * 16, format: .RGBAf)
                        destination.colorSpace = working
                        destination.isClamped = false
                        destinationFlipped = destination.isFlipped
                        let task = try readContext.startTask(toRender: image, from: bounds,
                                                             to: destination, at: .zero)
                        _ = try task.waitUntilCompleted()
                    }
                } catch {
                    diagnosticError(error, event: "scene-read-threw", context: diagnosticContext)
                    throw error
                }
                let nonfinite = values.filter { !$0.isFinite }.count
                let alpha = values.enumerated().filter { $0.offset % 4 == 3 && $0.element.isFinite }.map { $0.element }
                diagnostic(diagnosticContext.merging(["event": "scene-read-completed",
                    "nonfiniteSamples": nonfinite, "defaultDestinationFlipped": destinationFlipped,
                    "finiteAlphaSamples": alpha.count, "alphaMin": alpha.min() ?? 0,
                    "alphaMax": alpha.max() ?? 0]) { _, new in new })
                XCTAssertTrue(values.allSatisfy { $0.isFinite })
                if !sceneBridgeControlPerformed && nonfinite == 0 {
                    // One bounded serial-start control qualifies orientation, alpha
                    // and explicit output space against the original bridge. It does
                    // not turn a failed or blank later readback into valid pixels.
                    var original = [Float](repeating: .nan, count: 32 * 32 * 4)
                    original.withUnsafeMutableBytes { raw in
                        readContext.render(image, toBitmap: raw.baseAddress!, rowBytes: 32 * 16,
                                           bounds: bounds, format: .RGBAf, colorSpace: working)
                    }
                    let originalFinite = original.allSatisfy { $0.isFinite }
                    let maximum = zip(original, values).compactMap { pair -> Double? in
                        guard pair.0.isFinite, pair.1.isFinite else { return nil }
                        return abs(Double(pair.0) - Double(pair.1))
                    }.max() ?? 0
                    diagnostic(diagnosticContext.merging(["event": "scene-bridge-control",
                        "originalFinite": originalFinite, "exactIdentity": original == values,
                        "maximumAbsoluteDifference": maximum, "defaultDestinationFlipped": destinationFlipped]) { _, new in new })
                    XCTAssertTrue(originalFinite, "original bridge must actually write its serial control buffer")
                    XCTAssertTrue(original == values, "checked scene bridge must preserve exact orientation/alpha/output-space; max=\(maximum)")
                    sceneBridgeControlPassed = originalFinite && original == values
                    sceneBridgeControlPerformed = true
                }
                scene.append(values)
            }
            let nonzeroRGB = scene.contains { tile in
                tile.enumerated().contains { offset, value in offset % 4 != 3 && abs(value) > 0 }
            }
            XCTAssertTrue(nonzeroRGB, "scene RGB tiles must carry nonzero signal, excluding alpha")
            return ReconstructionCapture(displayed: displayed, scene: scene)
        }
        func compare(_ label: String, _ a: ReconstructionCapture, _ b: ReconstructionCapture) throws {
            XCTAssertEqual(a.displayed.count, 3); XCTAssertEqual(b.displayed.count, 3)
            XCTAssertEqual(a.scene.count, 3); XCTAssertEqual(b.scene.count, 3)
            for index in 0..<3 {
                let deltas = zip(a.displayed[index], b.displayed[index]).map { abs(Int($0.0) - Int($0.1)) }
                let sceneDelta = zip(a.scene[index], b.scene[index]).map { abs(Double($0.0) - Double($0.1)) }.max() ?? 0
                try emit(["tap": "pair", "label": label, "region": index,
                    "changedDisplayBytes": deltas.filter { $0 != 0 }.count, "maximumDisplayCode": deltas.max() ?? 0,
                    "displayByteCounts": [a.displayed[index].count, b.displayed[index].count],
                    "sceneMaximumAbsoluteDifference": sceneDelta,
                    "sceneChangedSamples": zip(a.scene[index], b.scene[index]).filter { $0.0 != $0.1 }.count])
                exactPairs.append((label + "/region\(index)", a.displayed[index], b.displayed[index], a.scene[index], b.scene[index]))
            }
        }
        for pass in 0..<2 {
            let ordered = pass == 0 ? files : Array(files.reversed())
            for fixture in ordered {
                try autoreleasepool {
                    var materializations = 0
                    let source = try AppleRawSource(url: fixture.url, materializer: { image, evaluation in
                        materializations += 1
                        let context: [String: Any] = ["fixture": fixture.label, "pass": pass,
                            "phase": materializerPhase, "call": materializations,
                            "extent": String(describing: image.extent), "eligible": DecodeMaterializer.isEligible(image),
                            "evaluation": String(describing: evaluation), "uptime": ProcessInfo.processInfo.systemUptime]
                        self.diagnostic(context.merging(["event": "materializer-begin"]) { _, new in new })
                        let result = DecodeMaterializer.materialize(image, evaluatingIn: evaluation,
                            reportFailure: { self.diagnosticMaterializationFailure($0, context: context) })
                        self.diagnostic(context.merging(["event": result == nil ? "materializer-nil" : "materializer-success",
                            "allocatedBytes": result?.bytes ?? 0]) { _, new in new })
                        return result
                    })
                    defer { _ = source.releaseDecodes() }
                    let renderer = PipelineRenderer()
                    XCTAssertTrue(renderer.availability.unavailable.isEmpty)
                    let first = try render(source, renderer, off, fixture: fixture, pass: pass, state: "off-first", allRegions: true)
                    if let previous = priorPass[fixture.label] {
                        try compare(fixture.label + "/ordered-first-vs-prior-pass", previous, first)
                    } else { priorPass[fixture.label] = first }
                    for amount in [25.0, 50.0, 100.0] {
                        var recipe = off
                        recipe.develop.denoise = Denoise(mode: .classic, classic: ClassicNR(luma: amount, chroma: amount))
                        _ = try render(source, renderer, recipe, fixture: fixture, pass: pass,
                                       state: "classic\(amount)", allRegions: false)
                    }
                    for amount in [0.0, 25.0, 50.0, 100.0] {
                        var recipe = off; recipe.develop.denoise = Denoise(mode: .ai, amount: amount)
                        _ = try render(source, renderer, recipe, fixture: fixture, pass: pass,
                                       state: "ai\(amount)", allRegions: false)
                    }
                    let returned = try render(source, renderer, off, fixture: fixture, pass: pass, state: "off-return", allRegions: true)
                    try compare(fixture.label + "/pass\(pass)/off-return", first, returned)
                    let freed = source.releaseDecodes()
                    XCTAssertEqual(source.heldDecodeBytes, 0)
                    let rebuilt = try render(source, renderer, off, fixture: fixture, pass: pass, state: "off-release-rebuild", allRegions: true)
                    try compare(fixture.label + "/pass\(pass)/release-rebuild", first, rebuilt)
                    _ = source.releaseDecodes()
                    let fresh = try AppleRawSource(url: fixture.url, materializer: { image, evaluation in
                        let context: [String: Any] = ["fixture": fixture.label, "pass": pass,
                            "phase": materializerPhase, "source": "fresh", "extent": String(describing: image.extent),
                            "eligible": DecodeMaterializer.isEligible(image), "evaluation": String(describing: evaluation)]
                        self.diagnostic(context.merging(["event": "materializer-begin"]) { _, new in new })
                        let result = DecodeMaterializer.materialize(image, evaluatingIn: evaluation,
                            reportFailure: { self.diagnosticMaterializationFailure($0, context: context) })
                        self.diagnostic(context.merging(["event": result == nil ? "materializer-nil" : "materializer-success",
                            "allocatedBytes": result?.bytes ?? 0]) { _, new in new })
                        return result
                    })
                    defer { _ = fresh.releaseDecodes() }
                    let freshResult = try render(fresh, PipelineRenderer(), off, fixture: fixture, pass: pass, state: "fresh-source-renderer", allRegions: true)
                    try compare(fixture.label + "/pass\(pass)/fresh-source-renderer", first, freshResult)
                    try emit(["tap": "file-summary", "fixture": fixture.label, "pass": pass,
                        "sourceMaterializations": materializations, "releasedBytes": freed,
                        "accuracyAcceptance": false, "classicHistoryRegionsPerMode": 1,
                        "aiHistoryRegionsPerMode": 1, "offRegionsPerState": 3])
                    filePasses += 1
                }
            }
        }
        try emit(["tap": "summary", "files": files.count, "filePasses": filePasses,
            "sceneBridgeControlPerformed": sceneBridgeControlPerformed,
            "sceneBridgeControlPassed": sceneBridgeControlPassed,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "beginUptime": beginUptime, "endUptime": ProcessInfo.processInfo.systemUptime,
            "renderRecords": renderCount, "exactPairRecords": exactPairs.count,
            "expectedRenderRecords": files.count * 2 * 19, "expectedExactPairRecords": files.count * 21,
            "privatePhotosUploaded": false, "productionChanges": false])
        XCTAssertTrue(sceneBridgeControlPerformed && sceneBridgeControlPassed,
                      "the checked scene bridge requires a successful exact serial-start control")
        XCTAssertEqual(filePasses, files.count * 2)
        XCTAssertEqual(renderCount, files.count * 2 * 19)
        XCTAssertEqual(exactPairs.count, files.count * 21)
        // All causal measurements are written before reporting any strict failure.
        for (label, a, b, sceneA, sceneB) in exactPairs {
            let displayMaximum = zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
            let sceneMaximum = zip(sceneA, sceneB).map { abs(Double($0.0) - Double($0.1)) }.max() ?? 0
            XCTAssertTrue(a == b, label + " exact displayed identity failed; maximumCode=\(displayMaximum)")
            XCTAssertTrue(sceneA == sceneB, label + " exact scene identity failed; maximumAbsolute=\(sceneMaximum)")
        }
    }
}
#endif
