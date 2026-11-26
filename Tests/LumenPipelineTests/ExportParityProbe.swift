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
    func renderTask(_ image: CIImage, label: String) {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let started = Date()
        bytes.withUnsafeMutableBytes { raw in
            let dest = CIRenderDestination(bitmapData: raw.baseAddress!, width: w, height: h,
                                           bytesPerRow: w * 4, format: .RGBA8)
            dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            do {
                let task = try Self.context.startTask(toRender: image, from: extent,
                                                      to: dest, at: .zero)
                _ = try task.waitUntilCompleted()
                say("\(label): render task ok \(w)x\(h) in "
                    + String(format: "%.1f s", Date().timeIntervalSince(started)))
            } catch {
                say("\(label): render task FAILED after "
                    + String(format: "%.1f s", Date().timeIntervalSince(started))
                    + ": " + Self.describe(error))
            }
        }
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
        say("boxPass kernel compiled: \(KernelLibrary.boxPass != nil); "
            + "unavailable: \(KernelLibrary.unavailableKernels)")
        boxParity()
        try chartBlackClipStudy()
        for id in ["6929", "5812"] {
            let url = try RenderLabShippingHarness.photoURL(id, in: dir)
            let src = try AppleRawSource(url: url)
            let base = Recipe.asImported(from: Recipe.SourceFile(
                isRendered: false, iso: src.captureMetadata.iso.map { Int($0) }))
            decodeScaleStudy(id: id, src: src, recipe: base)
            exportStudy(id: id, src: src, recipe: base)
        }
    }

    // MARK: - Box blur

    /// The kernel box against `CIBoxBlur` and against `SpatialOps` on a small plane.
    func boxParity() {
        let w = 96, h = 64
        let buffer = ImageBuffer(width: w, height: h) { u, v in
            let x = 0.3 + 0.5 * sin(u * 23) * cos(v * 17) + (u > 0.5 ? 0.4 : 0)
            return RGB(x, x * 0.5, 1 - x)
        }
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        for r in [1, 3, 8, 20] {
            guard let ours = RenderGraph.boxBlur(image, radius: r),
                  let stock = RenderGraph.boxBlurRaw(image, radius: 2 * r + 1),
                  let a = PipelineRenderer.buffer(from: ours, context: Self.context),
                  let b = PipelineRenderer.buffer(from: stock, context: Self.context)
            else { say("box r=\(r): render failed"); continue }
            let ref = SpatialOps.boxBlur(buffer, radius: r)
            var dStock = 0.0, dRef = 0.0
            for i in 0..<(w * h * 4) where i % 4 != 3 {
                dStock = max(dStock, abs(Double(a.pixels[i]) - Double(b.pixels[i])))
                dRef = max(dRef, abs(Double(a.pixels[i]) - Double(ref.pixels[i])))
            }
            say(String(format: "box r=%d: max|kernel-CIBoxBlur| %.5f max|kernel-SpatialOps| %.5f",
                       r, dStock, dRef))
        }
    }

    // MARK: - Chart black clip

    static func drawnZero(_ cg: CGImage) -> String {
        guard let img = try? RenderLabShippingHarness.rgba8(cg) else { return "draw failed" }
        var zeros = 0, sum = 0
        let n = img.width * img.height
        for i in 0..<n {
            let r = img.rgba[i * 4], g = img.rgba[i * 4 + 1], b = img.rgba[i * 4 + 2]
            if r == 0 || g == 0 || b == 0 { zeros += 1 }
            sum += Int(r) + Int(g) + Int(b)
        }
        return String(format: "drawn zero %.4f mean %.3f", Double(zeros) / Double(n),
                      Double(sum) / Double(3 * n))
    }

    /// Zeros in the CGImage's own bytes, with no colour-matched redraw in between.
    static func rawZero(_ cg: CGImage) -> String {
        guard cg.bitsPerPixel == 32, cg.bitsPerComponent == 8,
              let data = cg.dataProvider?.data as Data? else {
            return "raw n/a bpp \(cg.bitsPerPixel) bpc \(cg.bitsPerComponent)"
        }
        var zeros = 0, sum = 0
        let w = cg.width, h = cg.height, row = cg.bytesPerRow
        data.withUnsafeBytes { raw in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * row + x * 4
                    let r = raw[i], g = raw[i + 1], b = raw[i + 2]
                    if r == 0 || g == 0 || b == 0 { zeros += 1 }
                    sum += Int(r) + Int(g) + Int(b)
                }
            }
        }
        return String(format: "raw zero %.4f mean %.3f", Double(zeros) / Double(w * h),
                      Double(sum) / Double(3 * w * h))
            + " space \((cg.colorSpace?.name as String?) ?? "nil") alpha \(cg.alphaInfo.rawValue)"
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
                let tag = "chart lut \(size) dither \(dither ? "on" : "off")"
                if let cg = Self.context.createCGImage(image, from: image.extent,
                                                      format: .RGBA8, colorSpace: srgb) {
                    say("\(tag) createCGImage: \(Self.drawnZero(cg)) | \(Self.rawZero(cg))")
                }
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("probe-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    try Self.context.writePNGRepresentation(of: image, to: file, format: .RGBA8,
                                                            colorSpace: srgb, options: [:])
                    if let c = CGImageSourceCreateWithURL(file as CFURL, nil),
                       let cg = CGImageSourceCreateImageAtIndex(c, 0, nil) {
                        say("\(tag) writePNG: \(Self.drawnZero(cg)) | \(Self.rawZero(cg))")
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
        say("chart settled: \(Self.drawnZero(settled.image)) | \(Self.rawZero(settled.image))")
    }

    // MARK: - Decode scale

    struct DecodeStats: CustomStringConvertible {
        var mean: [Double], yP: [Double], neg: Double, w: Int, h: Int
        var description: String {
            "\(w)x\(h) mean " + mean.map { String(format: "%.4f", $0) }.joined(separator: ",")
                + " Y p0.1/p1/p50/p99/p99.9 "
                + yP.map { String(format: "%.5f", $0) }.joined(separator: "/")
                + String(format: " Y<=0 %.4f", neg)
        }
    }

    static func stats(_ b: ImageBuffer) -> DecodeStats {
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
        return DecodeStats(mean: mean.map { $0 / Double(n) },
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
        let target = 1536
        let viewer = Double(target) / src.nativeLongEdge
        var ref: ImageBuffer?
        for scale in [1.0, viewer] {
            let started = Date()
            guard let decoded = src.decode(recipe: recipe, draft: false, scaleFactor: scale),
                  let b = PipelineRenderer.buffer(
                      from: RenderGraph.scaledToProxy(decoded, longEdge: target),
                      context: Self.context) else {
                say("\(id) decode @\(scale) FAILED"); continue
            }
            var line = "\(id) decode @" + String(format: "%.4f", scale) + " in "
                + String(format: "%.2f s", Date().timeIntervalSince(started))
                + " extent \(decoded.extent.size) -> \(Self.stats(b))"
            if let ref { line += "  vs @1: " + Self.diff(b, ref) } else { ref = b }
            say(line)
        }
        let started = Date()
        if let settled = src.settledDecode(recipe: recipe, scaleFactor: viewer),
           let b = PipelineRenderer.buffer(
               from: RenderGraph.scaledToProxy(settled, longEdge: target),
               context: Self.context), let ref {
            say("\(id) settledDecode in " + String(format: "%.2f s", Date().timeIntervalSince(started))
                + " extent \(settled.extent.size) -> \(Self.stats(b))  vs @1: " + Self.diff(b, ref))
        }
        let again = Date()
        _ = src.settledDecode(recipe: recipe, scaleFactor: viewer)
        say("\(id) settledDecode again in "
            + String(format: "%.3f s", Date().timeIntervalSince(again)))
        if let draft = src.decode(recipe: recipe, draft: false, scaleFactor: viewer * 0.6),
           let b = PipelineRenderer.buffer(from: draft, context: Self.context) {
            say("\(id) draft-scale decode after a settle: extent \(draft.extent.size) -> \(Self.stats(b))")
        }
    }

    // MARK: - Export

    func exportStudy(id: String, src: AppleRawSource, recipe base: Recipe) {
        let renderer = PipelineRenderer()
        let downsized = ExportRecipe(name: "probe", format: .png, bitDepth: 8,
                                     colorSpace: .srgb, resizeMode: .longEdge,
                                     resizeValue: 1536)
        let fullSize = ExportRecipe(name: "probe", format: .png, bitDepth: 8,
                                    colorSpace: .srgb, resizeMode: .none)
        let variants: [(String, ExportRecipe, (inout Recipe) -> Void)] = [
            ("contrast+50", downsized, { $0.develop.tone.contrast = 50 }),
            ("shadows+50", downsized, { $0.develop.tone.shadows = 50 }),
            ("texture+50", downsized, { $0.develop.detail.texture = 50 }),
            ("clarity+50 sharpen80", downsized, {
                $0.develop.detail.clarity = 50
                $0.develop.detail.sharpen.amount = 80 }),
            ("dehaze+50", downsized, { $0.develop.detail.dehaze = 50 }),
            ("contrast+50 full size", fullSize, { $0.develop.tone.contrast = 50 }),
        ]
        for (label, exportRecipe, apply) in variants {
            var recipe = base
            apply(&recipe)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("probe-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let started = Date()
            do {
                _ = try renderer.export(source: src, recipe: recipe, to: file,
                                        using: exportRecipe)
                say("\(id) export \(label): ok in "
                    + String(format: "%.1f s", Date().timeIntervalSince(started)))
            } catch {
                say("\(id) export \(label): FAILED after "
                    + String(format: "%.1f s", Date().timeIntervalSince(started)) + ": \(error)")
                if let image = try? renderer.exportedImage(source: src, recipe: recipe,
                                                           using: exportRecipe) {
                    renderTask(image, label: "\(id) exportedImage \(label)")
                }
            }
        }
    }
}

#endif
