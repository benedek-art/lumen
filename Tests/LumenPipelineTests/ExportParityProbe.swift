// ExportParityProbe.swift
// Diagnostics for export failures and viewer/export parity on real RAWs. Inert unless
// LUMEN_PARITY_PROBE_PHOTOS names a directory holding the render lab's photos.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class ExportParityProbe: XCTestCase {

    static let context: CIContext = {
        var options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh,
                                               .cacheIntermediates: true]
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = space
        }
        return CIContext(options: options)
    }()

    func say(_ s: String) { print("PROBE: " + s) }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var s = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        for (k, v) in ns.userInfo where k != NSLocalizedDescriptionKey {
            s += " | \(k)=\(v)"
        }
        return s
    }

    /// Renders through a render task, which throws Core Image's own error where
    /// `createCGImage` and the write calls answer nil or a generic failure.
    static let uncachedContext: CIContext = {
        var options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh,
                                               .cacheIntermediates: false]
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = space
        }
        return CIContext(options: options)
    }()

    func renderTask(_ image: CIImage, label: String, context: CIContext = ExportParityProbe.context) -> Bool {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let started = Date()
        var ok = false
        bytes.withUnsafeMutableBytes { raw in
            let dest = CIRenderDestination(bitmapData: raw.baseAddress!, width: w, height: h,
                                           bytesPerRow: w * 4, format: .RGBA8)
            dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            do {
                let task = try context.startTask(toRender: image, from: extent,
                                                      to: dest, at: .zero)
                _ = try task.waitUntilCompleted()
                ok = true
            } catch {
                say("\(label): render task FAILED after "
                    + String(format: "%.1f s", Date().timeIntervalSince(started))
                    + ": " + Self.describe(error))
            }
        }
        if ok {
            say("\(label): render task ok \(w)x\(h) in "
                + String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
        return ok
    }

    func photo(_ id: String, in dir: URL) throws -> URL {
        try RenderLabShippingHarness.photoURL(id, in: dir)
    }

    func testProbe() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["LUMEN_PARITY_PROBE_PHOTOS"],
              !dirPath.isEmpty else {
            throw XCTSkip("set LUMEN_PARITY_PROBE_PHOTOS")
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        if let device = MTLCreateSystemDefaultDevice() {
            say("device \(device.name) unified=\(device.hasUnifiedMemory) "
                + "workingSet=\(device.recommendedMaxWorkingSetSize / 1_048_576) MB "
                + "maxBuffer=\(device.maxBufferLength / 1_048_576) MB "
                + "physical=\(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB")
        }
        try chartBlackClipStudy()
        for id in ["6929", "5812"] {
            let url = try photo(id, in: dir)
            let src = try AppleRawSource(url: url)
            let base = Recipe.asImported(from: Recipe.SourceFile(
                isRendered: false, iso: src.captureMetadata.iso.map { Int($0) }))
            let meta = CIRAWFilter(imageURL: url)
            say("\(id): nativeSize \(String(describing: meta?.nativeSize)) "
                + "nativeLongEdge \(src.nativeLongEdge) "
                + "decoder \(meta?.decoderVersion.rawValue ?? "?") "
                + "iso \(String(describing: src.captureISO)) "
                + "full outputImage extent \(String(describing: meta?.outputImage?.extent))")
            decodeScaleStudy(id: id, src: src, recipe: base)
            exportFailureStudy(id: id, src: src, recipe: base)
        }
    }

    // MARK: - Chart black clip

    static func zeroFraction(_ cg: CGImage) -> (any0: Double, mean: Double) {
        guard let img = try? RenderLabShippingHarness.rgba8(cg) else { return (-1, -1) }
        var zeros = 0, sum = 0
        let n = img.width * img.height
        for i in 0..<n {
            let r = img.rgba[i * 4], g = img.rgba[i * 4 + 1], b = img.rgba[i * 4 + 2]
            if r == 0 || g == 0 || b == 0 { zeros += 1 }
            sum += Int(r) + Int(g) + Int(b)
        }
        return (Double(zeros) / Double(n), Double(sum) / Double(3 * n))
    }

    func chartBlackClipStudy() throws {
        let chart = try RenderLabCharts.make("greyRamp", longEdge: 1536)
        let src = RenderLabShippingHarness.ChartSource(name: chart.name, buffer: chart.image)
        let recipe = Recipe.asImported(from: Recipe.SourceFile())
        guard let decoded = src.decode(recipe: recipe, draft: false, scaleFactor: 1) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for size in [LUT3D.interactiveSize, LUT3D.exportSize] {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            let graph = RenderGraph(healStrokesOf: recipe, strokeSets: [:])
            let built = graph.build(decoded, plan: plan,
                                    options: RenderGraph.Options(longEdge: 1536, lutSize: size))
            for dither in [false, true] {
                let image = dither
                    ? PipelineRenderer.applyDither(built, colorSpace: .srgb, bitDepth: 8) : built
                if let cg = Self.context.createCGImage(image, from: image.extent,
                                                      format: .RGBA8, colorSpace: srgb) {
                    let z = Self.zeroFraction(cg)
                    say(String(format: "chart lut %d dither %@ createCGImage: zero %.4f mean %.3f",
                               size, dither ? "on" : "off", z.any0, z.mean))
                }
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("probe-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    try Self.context.writePNGRepresentation(of: image, to: file, format: .RGBA8,
                                                            colorSpace: srgb, options: [:])
                    if let c = CGImageSourceCreateWithURL(file as CFURL, nil),
                       let cg = CGImageSourceCreateImageAtIndex(c, 0, nil) {
                        let z = Self.zeroFraction(cg)
                        say(String(format: "chart lut %d dither %@ writePNG: zero %.4f mean %.3f",
                                   size, dither ? "on" : "off", z.any0, z.mean))
                    }
                } catch {
                    say("chart writePNG failed: \(Self.describe(error))")
                }
            }
        }
        let renderer = PipelineRenderer()
        let settled = try renderer.renderPreviewDelivery(source: src, recipe: recipe,
                                                         maxLongEdge: 1536, draft: false,
                                                         coarseDecode: false)
        let zs = Self.zeroFraction(settled.image)
        say(String(format: "chart settled: zero %.4f mean %.3f", zs.any0, zs.mean))
        let exported = try renderer.exportedImage(
            source: src, recipe: recipe,
            using: ExportRecipe(name: "probe", format: .png, bitDepth: 8, colorSpace: .srgb,
                                resizeMode: .longEdge, resizeValue: 1536))
        if let cg = Self.context.createCGImage(exported, from: exported.extent,
                                               format: .RGBA8, colorSpace: srgb) {
            let z = Self.zeroFraction(cg)
            say(String(format: "chart exportedImage createCGImage: zero %.4f mean %.3f",
                       z.any0, z.mean))
        }
    }

    // MARK: - Decode scale

    struct Stats: CustomStringConvertible {
        var mean: [Double], yP: [Double], neg: Double, w: Int, h: Int
        var description: String {
            "\(w)x\(h) mean " + mean.map { String(format: "%.4f", $0) }.joined(separator: ",")
                + " Y p0.1/p1/p50/p99/p99.9 " + yP.map { String(format: "%.5f", $0) }.joined(separator: "/")
                + String(format: " Y<=0 %.4f", neg)
        }
    }

    static func stats(_ b: ImageBuffer) -> Stats {
        let n = b.width * b.height
        var mean = [0.0, 0.0, 0.0]
        var ys = [Double](repeating: 0, count: n)
        var neg = 0
        let wts = RGBColorSpace.rec2020.luminanceWeights
        for i in 0..<n {
            let r = Double(b.pixels[i * 4]), g = Double(b.pixels[i * 4 + 1]),
                bl = Double(b.pixels[i * 4 + 2])
            mean[0] += r; mean[1] += g; mean[2] += bl
            let y = wts.r * r + wts.g * g + wts.b * bl
            ys[i] = y
            if y <= 0 { neg += 1 }
        }
        ys.sort()
        func p(_ q: Double) -> Double { ys[min(n - 1, Int(q * Double(n)))] }
        return Stats(mean: mean.map { $0 / Double(n) },
                     yP: [p(0.001), p(0.01), p(0.5), p(0.99), p(0.999)],
                     neg: Double(neg) / Double(n), w: b.width, h: b.height)
    }

    /// Mean |Δ| in a gamma-2.4 encoding, overall and over the darkest decile of `ref`.
    static func diff(_ a: ImageBuffer, _ ref: ImageBuffer) -> String {
        guard a.width == ref.width, a.height == ref.height else {
            return "size mismatch \(a.width)x\(a.height) vs \(ref.width)x\(ref.height)"
        }
        func enc(_ v: Float) -> Double { Double(v) <= 0 ? 0 : pow(Double(v), 1 / 2.4) * 255 }
        let n = a.width * a.height
        var all = 0.0, signed = [0.0, 0.0, 0.0]
        var refY = [(Double, Int)]()
        refY.reserveCapacity(n)
        for i in 0..<n {
            var y = 0.0
            for c in 0..<3 {
                let d = enc(a.pixels[i * 4 + c]) - enc(ref.pixels[i * 4 + c])
                all += abs(d); signed[c] += d
                y += enc(ref.pixels[i * 4 + c])
            }
            refY.append((y, i))
        }
        refY.sort { $0.0 < $1.0 }
        var dark = 0.0
        let k = n / 10
        for j in 0..<k {
            let i = refY[j].1
            for c in 0..<3 { dark += enc(a.pixels[i * 4 + c]) - enc(ref.pixels[i * 4 + c]) }
        }
        return String(format: "mean|d| %.2f signed %.2f,%.2f,%.2f darkest-decile signed %.2f codes",
                      all / Double(n * 3), signed[0] / Double(n), signed[1] / Double(n),
                      signed[2] / Double(n), dark / Double(k * 3))
    }

    func decodeScaleStudy(id: String, src: AppleRawSource, recipe: Recipe) {
        let native = src.nativeLongEdge
        let target = 1536
        let viewer = Double(target) / native
        var ref: ImageBuffer?
        for scale in [1.0, 0.5, 0.35, 0.25, viewer] {
            guard let decoded = src.decode(recipe: recipe, draft: false, scaleFactor: scale) else {
                say("\(id) decode @\(scale) FAILED"); continue
            }
            let e = decoded.extent
            let small = RenderGraph.scaledToProxy(decoded, longEdge: target)
            guard let b = PipelineRenderer.buffer(from: small, context: Self.context) else {
                say("\(id) readback @\(scale) failed"); continue
            }
            var line = "\(id) decode @" + String(format: "%.4f", scale)
                + " extent \(Int(e.minX)),\(Int(e.minY)) \(Int(e.width))x\(Int(e.height)) -> \(Self.stats(b))"
            if let ref { line += "  vs @1: " + Self.diff(b, ref) } else { ref = b }
            say(line)
        }
    }

    // MARK: - Export failure

    func exportFailureStudy(id: String, src: AppleRawSource, recipe base: Recipe) {
        let renderer = PipelineRenderer()
        let exportRecipe = ExportRecipe(name: "probe", format: .png, bitDepth: 8,
                                        colorSpace: .srgb, resizeMode: .longEdge,
                                        resizeValue: 1536)
        var recipe = base
        recipe.develop.tone.contrast = 50
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let started = Date()
        do {
            _ = try renderer.export(source: src, recipe: recipe, to: file, using: exportRecipe)
            say("\(id) export contrast+50: ok in "
                + String(format: "%.1f s", Date().timeIntervalSince(started)))
        } catch {
            say("\(id) export contrast+50: FAILED after "
                + String(format: "%.1f s", Date().timeIntervalSince(started)) + ": \(error)")
        }
        if let image = try? renderer.exportedImage(source: src, recipe: recipe,
                                                   using: exportRecipe) {
            _ = renderTask(image, label: "\(id) exportedImage contrast+50")
            _ = renderTask(image, label: "\(id) exportedImage contrast+50 uncached",
                           context: Self.uncachedContext)
        }
        // Which primitive: the tone stage's box blur and guided filter on the full decode.
        guard let decoded = src.decode(recipe: base, draft: false, scaleFactor: 1.0),
              let lum = RenderGraph.logLuminance(decoded) else { return }
        let longEdge = Int(max(decoded.extent.width, decoded.extent.height))
        let toneRadius = max(Int(Double(longEdge) * 0.02), 2)
        // The same radii on a 1536 px plane: radius-bound or size-bound.
        let smallLum = RenderGraph.scaledToProxy(lum, longEdge: 1536)
        for r in [toneRadius / 2, toneRadius] {
            if let blurred = RenderGraph.boxBlur(smallLum, radius: r) {
                _ = renderTask(blurred, label: "\(id) boxBlur r=\(r) on 1536 px")
            }
        }
        for r in [toneRadius / 4, toneRadius / 2, toneRadius] {
            if let blurred = RenderGraph.boxBlur(lum, radius: r) {
                _ = renderTask(RenderGraph.scaledToProxy(blurred, longEdge: 1536),
                               label: "\(id) boxBlur r=\(r) on \(longEdge) px")
            }
            if let guided = RenderGraph.guidedSelfFilter(lum, radius: r,
                                                         epsilon: ReferenceRenderer.toneMaskEpsilon) {
                _ = renderTask(RenderGraph.scaledToProxy(guided, longEdge: 1536),
                               label: "\(id) guided r=\(r) on \(longEdge) px")
            }
        }
    }
}

#endif
