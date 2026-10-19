#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Real RAW native-pixel centre ROI through the shipping local S11 and S15b stages.
/// Runs the full graph with explicit mask planes, including the display transform.
/// This qualifies adjustment/compositing contracts, not pointer undo, mask rasterization,
/// or spatial quality at the artificial ROI border.
final class LocalRawControlSweepTests: XCTestCase {
    private struct LocalRawAuditControl {
        let name: String
        let values: [Double]
        let set: (inout LocalAdjust, Double) -> Void
    }
    private var controls: [LocalRawAuditControl] {
        var result: [LocalRawAuditControl] = []
        let scalar: [(String, WritableKeyPath<LocalAdjust, Double>, [Double])] = [
            ("exposure", \.exposure, [-4, -1, 0, 1, 4]),
            ("contrast", \.contrast, [-100, -50, 0, 50, 100]),
            ("highlights", \.highlights, [-100, -50, 0, 50, 100]),
            ("shadows", \.shadows, [-100, -50, 0, 50, 100]),
            ("whites", \.whites, [-100, -50, 0, 50, 100]),
            ("blacks", \.blacks, [-100, -50, 0, 50, 100]),
            ("temp", \.temp, [-100, -50, 0, 50, 100]),
            ("tint", \.tint, [-100, -50, 0, 50, 100]),
            ("hue", \.hue, [-180, -90, 0, 90, 180]),
            ("sat", \.sat, [-100, -50, 0, 50, 100]),
            ("vibrance", \.vibrance, [-100, -50, 0, 50, 100]),
            ("texture", \.texture, [-100, -50, 0, 50, 100]),
            ("clarity", \.clarity, [-100, -50, 0, 50, 100]),
            ("dehaze", \.dehaze, [-100, -50, 0, 50, 100]),
            ("sharpness", \.sharpness, [-100, -50, 0, 50, 100])
        ]
        for (name, key, values) in scalar {
            result.append(LocalRawAuditControl(name: name, values: values, set: { $0[keyPath: key] = $1 }))
        }
        result.append(LocalRawAuditControl(name: "kelvin", values: [2000, 3000, 5500, 9000, 50000], set: { $0.kelvin = $1 }))
        result.append(LocalRawAuditControl(name: "kelvinTint", values: [-150, -75, 0, 75, 150], set: { $0.kelvin = 5500; $0.kelvinTint = $1 }))
        result.append(LocalRawAuditControl(name: "colorize", values: [0, 25, 50, 75, 100], set: { $0.colorTint = [0.6, 0.2, 0.1]; $0.colorTintStrength = $1 }))
        for channel in ["luma", "r", "g", "b"] {
            result.append(LocalRawAuditControl(name: "curve.\(channel)", values: [0.2, 0.35, 0.5, 0.65, 0.8], set: { adjust, value in
                let points = [[0.0, 0.0], [0.5, value], [1.0, 1.0]]
                var curve = CurveSet()
                switch channel { case "r": curve.r = points; case "g": curve.g = points; case "b": curve.b = points; default: curve.luma = points }
                adjust.curve = curve
            }))
        }
        let regions: [(String, WritableKeyPath<ParametricCurve, Double>)] = [("shadows", \.shadows), ("darks", \.darks), ("lights", \.lights), ("highlights", \.highlights)]
        for (name, key) in regions {
            result.append(LocalRawAuditControl(name: "parametric.\(name)", values: [-100, -50, 0, 50, 100], set: { adjust, value in
                var curve = CurveSet(); curve.parametric[keyPath: key] = value; adjust.curve = curve
            }))
        }
        let zones: [(String, WritableKeyPath<GradingWheels, Wheel>)] = [("global", \.global), ("shadows", \.shadows), ("mid", \.mid), ("high", \.high)]
        let axes: [(String, WritableKeyPath<Wheel, Double>, [Double])] = [("hue", \.hue, [0, 90, 180, 270, 360]), ("sat", \.sat, [0, 0.25, 0.5, 0.75, 1]), ("lum", \.lum, [-1, -0.5, 0, 0.5, 1])]
        for (zone, zoneKey) in zones {
            for (axis, axisKey, values) in axes {
                result.append(LocalRawAuditControl(name: "wheel.\(zone).\(axis)", values: values, set: { adjust, value in
                    var wheels = GradingWheels()
                    if axis == "hue" { wheels[keyPath: zoneKey].sat = 0.5 }
                    wheels[keyPath: zoneKey][keyPath: axisKey] = value; adjust.wheels = wheels
                }))
            }
        }
        for axis in ["hue", "sat", "lum", "range", "variance"] {
            let values: [Double]
            if axis == "range" { values = [0, 25, 50, 75, 100] }
            else if axis == "hue" { values = [-60, -30, 0, 30, 60] }
            else { values = [-100, -50, 0, 50, 100] }
            result.append(LocalRawAuditControl(name: "point.\(axis)", values: values, set: { adjust, value in
                var point = PointColor(sample: [0.3, 0.18, 0.1], range: 100)
                switch axis { case "hue": point.shift.h = value; case "sat": point.shift.s = value; case "lum": point.shift.l = value; case "range": point.shift.s = 50; point.range = value; default: point.shift.s = 50; point.variance = value }
                adjust.pointColors = [point]
            }))
        }
        return result
    }

    func testLocalControlsOnNativeRawROIs() throws {
        guard let root = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"], !root.isEmpty else { throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset") }
        let extensions: Set<String> = ["arw", "nef", "cr3", "cr2", "raf", "dng", "rw2", "orf", "pef"]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var records = ["fixture,control,value,max_delta,mean_delta"]
        for (ordinal, url) in urls.enumerated() {
            try autoreleasepool {
                let raw = try AppleRawSource(url: url)
                var recipe = Recipe(); recipe.develop.denoise.mode = .off
                let decoded = try XCTUnwrap(raw.decode(recipe: recipe, draft: false, scaleFactor: 1))
                let side = min(512.0, min(decoded.extent.width, decoded.extent.height))
                let rect = CGRect(x: floor(decoded.extent.midX - side / 2), y: floor(decoded.extent.midY - side / 2), width: side, height: side)
                let lazyInput = decoded.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                let cameraPixels = try XCTUnwrap(PipelineRenderer.buffer(from: lazyInput, context: context))
                let width = cameraPixels.width, height = cameraPixels.height
                let materializedData = cameraPixels.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
                let input = CIImage(bitmapData: materializedData, bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
                let baselinePlan = RenderPlan(recipe: recipe, asShotKelvin: raw.asShotTemperature,
                    asShotTint: raw.asShotTint, lutSize: 65, captureISO: raw.captureISO)
                let baselineGraph = RenderGraph().build(input, plan: baselinePlan,
                    options: RenderGraph.Options(longEdge: Int(raw.nativeLongEdge), lutSize: 65))
                let baseline = try XCTUnwrap(PipelineRenderer.buffer(from: baselineGraph, context: context))
                let nativeLongEdge = Int(max(decoded.extent.width, decoded.extent.height))
                func render(_ adjust: LocalAdjust, alpha: Double, split: Bool = false) throws -> ImageBuffer {
                    var mask = Mask(id: "local-audit"); mask.adjust = adjust
                    var localRecipe = recipe; localRecipe.masks = [mask]
                    let plan = RenderPlan(recipe: localRecipe, asShotKelvin: raw.asShotTemperature,
                        asShotTint: raw.asShotTint, lutSize: 65, captureISO: raw.captureISO)
                    var graph = RenderGraph()
                    var plane = Plane(width: width, height: height, fill: alpha)
                    if split { for y in 0..<height { for x in 0..<width / 2 { plane[x, y] = 0 } } }
                    graph.maskImages[mask.id] = try XCTUnwrap(PipelineRenderer.image(from: plane, targetExtent: input.extent))
                    let options = RenderGraph.Options(longEdge: nativeLongEdge, lutSize: 65)
                    return try XCTUnwrap(PipelineRenderer.buffer(from: graph.build(input, plan: plan, options: options), context: context))
                }
                func error(_ a: ImageBuffer, _ b: ImageBuffer) -> Double { zip(a.pixels, b.pixels).reduce(0) { max($0, abs(Double($1.0) - Double($1.1))) } }
                for control in controls {
                    for value in control.values {
                        try autoreleasepool {
                            var adjust = LocalAdjust(); control.set(&adjust, value)
                            let full = try render(adjust, alpha: 1)
                            XCTAssertTrue(full.pixels.allSatisfy(\.isFinite), "fixture\(ordinal + 1) \(control.name) \(value)")
                            let zero = try render(adjust, alpha: 0)
                            XCTAssertTrue(zero.pixels.allSatisfy(\.isFinite))
                            XCTAssertLessThanOrEqual(error(zero, baseline), 1e-5, "zero alpha \(control.name)")
                            let split = try render(adjust, alpha: 1, split: true)
                            XCTAssertTrue(split.pixels.allSatisfy(\.isFinite))
                            var boundaryError = 0.0
                            for y in 0..<height { for x in 0..<width {
                                let expected = x < width / 2 ? baseline[x, y] : full[x, y]
                                boundaryError = max(boundaryError, split[x, y].maxAbsDifference(expected))
                            } }
                            XCTAssertLessThanOrEqual(boundaryError, 1e-5, "native boundary \(control.name)")
                            let delta = zip(full.pixels, baseline.pixels).map { abs(Double($0.0) - Double($0.1)) }
                            records.append("fixture\(ordinal + 1),\(control.name),\(value),\(delta.max() ?? 0),\(delta.reduce(0, +) / Double(max(delta.count, 1)))")
                        }
                    }
                    // Restoring the baseline recipe must restore native ROI pixels;
                    // this is recipe restoration, not a UI undo interaction claim.
                    XCTAssertLessThanOrEqual(error(try render(LocalAdjust(), alpha: 1), baseline), 1e-5)
                }
                if let destination = ProcessInfo.processInfo.environment["LUMEN_REAL_RAW_EVIDENCE"], !destination.isEmpty {
                    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                    try records.joined(separator: "\n").write(to: URL(fileURLWithPath: destination).appendingPathComponent("local-control-sensitivity.csv"), atomically: true, encoding: .utf8)
                }
                print("local-raw-file: fixture\(ordinal + 1) controls=\(controls.count) native-roi=\(width)x\(height)")
            }
        }
        if let destination = ProcessInfo.processInfo.environment["LUMEN_REAL_RAW_EVIDENCE"], !destination.isEmpty {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try records.joined(separator: "\n").write(to: URL(fileURLWithPath: destination).appendingPathComponent("local-control-sensitivity.csv"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
