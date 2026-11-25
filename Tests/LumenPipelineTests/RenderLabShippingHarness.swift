// RenderLabShippingHarness.swift
// The render lab's macOS side: manifest jobs rendered through the app's own render
// entries (PipelineRenderer.export, renderPreviewDelivery draft and settled) on real
// RAW files and synthetic charts. Also writes decoded plates for the Linux lane, and
// diffs reference against shipping on a sample. Inert unless its variables are set;
// see renderlab/README.md.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class RenderLabShippingHarness: XCTestCase {

    static func flag(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return ["0", "false", "no", "off"].contains(v.lowercased()) ? nil : v
    }

    /// A chart handed to the graph as a decode: scene-linear working-space floats.
    final class ChartSource: ImageSource {
        let url: URL
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage

        init(name: String, buffer: ImageBuffer) {
            url = URL(fileURLWithPath: "/renderlab/chart-\(name)-\(buffer.width)x\(buffer.height)")
            let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            image = CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                            size: CGSize(width: buffer.width, height: buffer.height),
                            format: .RGBAf, colorSpace: nil)
        }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            let scale = min(max(scaleFactor, 0.01), 1.0)
            guard scale < 1 else { return image }
            return image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// Same working space and format as `PipelineRenderer`'s own context.
    static let workingContext: CIContext = {
        var options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh,
                                               .cacheIntermediates: false]
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = space
        }
        return CIContext(options: options)
    }()

    static func photoURL(_ id: String, in dir: URL) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = files.sorted().first(where: {
            $0.hasPrefix(id + ".") && !$0.hasSuffix(".tsv") && !$0.hasSuffix(".plate")
        }) else {
            throw RenderLabError.missingPhoto("no file \(id).* in \(dir.path)")
        }
        return dir.appendingPathComponent(name)
    }

    static func rgba8(_ image: CGImage) throws -> RenderLabImage {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RenderLabError.render("no sRGB colour space")
        }
        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw RenderLabError.render("could not read back pixels") }
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return RenderLabImage(width: w, height: h, rgba: bytes)
    }

    static func pngData(_ image: RenderLabImage) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: image.width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { throw RenderLabError.render("could not build a CGImage") }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderlab-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
        else { throw RenderLabError.render("no PNG encoder") }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderLabError.render("PNG encode failed") }
        return try Data(contentsOf: file)
    }

    // MARK: - Shipping backend

    final class ShippingBackend: RenderLabBackend {
        let kind = "shipping"
        let photos: URL?
        let renderer = PipelineRenderer()
        let scratch: URL
        private var sources: [String: any ImageSource] = [:]
        private var chartPatches: [String: [RenderLabPatch]] = [:]

        init(photos: URL?, scratch: URL) {
            self.photos = photos
            self.scratch = scratch
        }

        func resolve(path: String) -> String? { path == "reference" ? nil : path }

        func source(_ photo: String, longEdge: Int) throws -> any ImageSource {
            let key = photo.hasPrefix("chart:") ? "\(photo)@\(longEdge)" : photo
            if let s = sources[key] { return s }
            let s: any ImageSource
            if photo.hasPrefix("chart:") {
                let chart = try RenderLabCharts.make(String(photo.dropFirst(6)), longEdge: longEdge)
                s = ChartSource(name: chart.name, buffer: chart.image)
            } else {
                guard let photos else {
                    throw RenderLabError.missingPhoto("\(photo): LUMEN_RENDERLAB_PHOTOS is not set")
                }
                s = try AppleRawSource(url: RenderLabShippingHarness.photoURL(photo, in: photos))
            }
            sources[key] = s
            return s
        }

        func baseRecipe(photo: String, base: String) throws -> Recipe {
            if base == "blank" { return Recipe() }
            if photo.hasPrefix("chart:") { return Recipe.asImported(from: Recipe.SourceFile()) }
            let s = try source(photo, longEdge: 0)
            return Recipe.asImported(from: Recipe.SourceFile(
                isRendered: false, iso: s.captureMetadata.iso.map { Int($0) }))
        }

        func patches(photo: String) -> [RenderLabPatch]? {
            guard photo.hasPrefix("chart:") else { return nil }
            return try? RenderLabCharts.make(String(photo.dropFirst(6)), longEdge: 48).patches
        }

        func render(photo: String, recipe: Recipe, path: String, longEdge: Int,
                    draftLongEdge: Int?, crop: [Double]?) throws -> RenderLabRender {
            let src = try source(photo, longEdge: longEdge)
            var recipe = recipe
            var longEdge = longEdge
            var region: CGRect?
            var cropNote = ""
            if let crop {
                // 1:1: export crops in the recipe and delivers the crop's native pixels;
                // the viewer renders the same rectangle as a region of the native frame.
                let native = Int(src.nativeLongEdge.rounded())
                if path == "export" {
                    recipe.develop.geometry.crop = try RenderLabJSON.object([
                        "x": .number(crop[0]), "y": .number(crop[1]),
                        "w": .number(crop[2]), "h": .number(crop[3]),
                    ]).decoded(as: Crop.self)
                    longEdge = Int((Double(native) * max(crop[2], crop[3])).rounded())
                } else {
                    longEdge = native
                    region = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
                }
                cropNote = "; 1:1 crop \(crop)"
            }
            let started = DispatchTime.now().uptimeNanoseconds
            func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
            switch path {
            case "export":
                let file = scratch.appendingPathComponent("export-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: file) }
                let exportRecipe = ExportRecipe(name: "renderlab", format: .png, bitDepth: 8,
                                                colorSpace: .srgb, resizeMode: .longEdge,
                                                resizeValue: Double(longEdge))
                let missing = try renderer.export(source: src, recipe: recipe, to: file,
                                                  using: exportRecipe, allowOverwrite: true)
                let total = ms()
                guard let container = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(container, 0, nil)
                else { throw RenderLabError.render("the exported PNG did not read back") }
                return RenderLabRender(
                    image: try RenderLabShippingHarness.rgba8(cg), timings: ["total": total],
                    note: (missing.isEmpty ? "PipelineRenderer.export, PNG 8-bit sRGB"
                        : "kernels unavailable: \(missing)") + cropNote)
            case "settled", "draft":
                let draft = path == "draft"
                let edge = draft && crop == nil ? (draftLongEdge ?? longEdge) : longEdge
                let d = try renderer.renderPreviewDelivery(source: src, recipe: recipe,
                                                           maxLongEdge: edge, draft: draft,
                                                           coarseDecode: false, region: region)
                let total = ms()
                return RenderLabRender(
                    image: try RenderLabShippingHarness.rgba8(d.image),
                    timings: ["total": total, "decode": d.decodeMilliseconds,
                              "plan": d.planMilliseconds, "graph": d.graphMilliseconds,
                              "render": d.renderMilliseconds],
                    note: (draft ? "renderPreviewDelivery draft=true (stale tables allowed, "
                        + "as during a drag)" : "renderPreviewDelivery draft=false") + cropNote)
            default:
                throw RenderLabError.render("unknown path \(path)")
            }
        }

        func encodePNG(_ image: RenderLabImage) throws -> Data {
            try RenderLabShippingHarness.pngData(image)
        }

        /// The scene-linear decode Lumen's stages start from, as a plate.
        func plate(_ photo: String, longEdge: Int?, crop: [Double]?) throws -> RenderLabPlate {
            guard let raw = try source(photo, longEdge: 0) as? AppleRawSource else {
                throw RenderLabError.missingPhoto("\(photo) is not a RAW file")
            }
            let recipe = try baseRecipe(photo: photo, base: "imported")
            let native = raw.nativeLongEdge
            let scale = longEdge.map { min(1.0, Double($0) / native) } ?? 1.0
            guard var image = raw.decode(recipe: recipe, draft: false, scaleFactor: scale) else {
                throw RenderLabError.render("\(photo): decode failed")
            }
            var id = photo
            if let crop {
                let e = image.extent
                let rect = CGRect(x: e.minX + crop[0] * e.width,
                                  y: e.minY + (1 - crop[1] - crop[3]) * e.height,
                                  width: crop[2] * e.width, height: crop[3] * e.height).integral
                image = image.cropped(to: rect)
                id = photo + "-" + RenderLabShippingHarness.cropName(crop)
            }
            guard let buffer = PipelineRenderer.buffer(from: image,
                                                       context: RenderLabShippingHarness.workingContext)
            else { throw RenderLabError.render("\(photo): readback failed") }
            let meta = raw.captureMetadata
            let header = RenderLabPlate.Header(
                id: id, width: buffer.width, height: buffer.height,
                sourceFile: raw.url.lastPathComponent, decoder: "AppleRawSource (CIRAWFilter)",
                decoderVersion: meta.decoderVersion,
                asShotTemperature: raw.asShotTemperature, asShotTint: raw.asShotTint,
                iso: meta.iso, nativeWidth: meta.pixelSize.width,
                nativeHeight: meta.pixelSize.height, scale: scale, crop: crop,
                decodeRecipe: try? RenderLabJSON.of(recipe))
            return RenderLabPlate(header: header, image: buffer)
        }
    }

    static let crops: [[Double]] = [[0.4, 0.4, 0.2, 0.2], [0.15, 0.2, 0.2, 0.2], [0.65, 0.6, 0.2, 0.2]]

    static func cropName(_ c: [Double]) -> String {
        "crop\(Int(c[0] * 100))-\(Int(c[1] * 100))"
    }

    static func outDir() -> URL {
        URL(fileURLWithPath: flag("LUMEN_RENDERLAB_OUT") ?? "renderlab-out/shipping", isDirectory: true)
    }

    static func manifests() throws -> [(URL, RenderLabManifest)] {
        guard let list = flag("LUMEN_RENDERLAB") else { return [] }
        return try list.split(separator: ",").map { item in
            let url = URL(fileURLWithPath: item.trimmingCharacters(in: .whitespaces))
            return (url, try RenderLabManifest(data: Data(contentsOf: url),
                                               defaultName: url.deletingPathExtension().lastPathComponent))
        }
    }

    // MARK: - Tests

    func testRunManifestOnTheShippingPath() throws {
        let list = try Self.manifests()
        guard !list.isEmpty else {
            throw XCTSkip("set LUMEN_RENDERLAB=<manifest.json>[,<more>] to run the render lab")
        }
        let photos = Self.flag("LUMEN_RENDERLAB_PHOTOS").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("renderlab-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var errors: [String] = []
        for (url, manifest) in list {
            let backend = ShippingBackend(photos: photos, scratch: scratch)
            let out = Self.outDir().appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            let runner = RenderLabRunner(backend: backend, manifest: manifest, out: out)
            runner.manifestDirectory = url.deletingLastPathComponent()
            try runner.run()
            errors += runner.errors
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }

    /// Writes `<id>.plate` (working size) and native crops for each RAW in
    /// LUMEN_RENDERLAB_PLATE_IDS into LUMEN_RENDERLAB_PLATES_OUT.
    func testWriteDecodedPlates() throws {
        guard let outPath = Self.flag("LUMEN_RENDERLAB_PLATES_OUT") else {
            throw XCTSkip("set LUMEN_RENDERLAB_PLATES_OUT to write decoded plates")
        }
        let photos = try XCTUnwrap(Self.flag("LUMEN_RENDERLAB_PHOTOS"), "LUMEN_RENDERLAB_PHOTOS")
        let ids = try XCTUnwrap(Self.flag("LUMEN_RENDERLAB_PLATE_IDS"), "LUMEN_RENDERLAB_PLATE_IDS")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let longEdge = Int(Self.flag("LUMEN_RENDERLAB_PLATE_EDGE") ?? "") ?? 2048
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let backend = ShippingBackend(photos: URL(fileURLWithPath: photos, isDirectory: true),
                                      scratch: FileManager.default.temporaryDirectory)
        var headers: [RenderLabPlate.Header] = []
        for id in ids {
            let started = Date()
            var plates = [try backend.plate(id, longEdge: longEdge, crop: nil)]
            for crop in Self.crops {
                plates.append(try backend.plate(id, longEdge: nil, crop: crop))
            }
            for p in plates {
                try p.encoded().write(to: out.appendingPathComponent(p.header.id + ".plate"))
                headers.append(p.header)
            }
            print("renderlab-plate: \(id) \(plates.map { "\($0.header.id) \($0.header.width)x\($0.header.height)" }) "
                + "\(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(headers).write(to: out.appendingPathComponent("plates.json"))
    }

    /// Renders the same manifest on both paths and records how far reference drifts
    /// from shipping (export path), per render. LUMEN_RENDERLAB_DRIFT=<manifest.json>.
    func testReferenceAgainstShippingDrift() throws {
        guard let manifestPath = Self.flag("LUMEN_RENDERLAB_DRIFT") else {
            throw XCTSkip("set LUMEN_RENDERLAB_DRIFT=<manifest.json> to diff reference against shipping")
        }
        let url = URL(fileURLWithPath: manifestPath)
        let manifest = try RenderLabManifest(data: Data(contentsOf: url))
        let photos = Self.flag("LUMEN_RENDERLAB_PHOTOS").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("renderlab-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shipping = ShippingBackend(photos: photos, scratch: scratch)
        let plateEdge = Int(Self.flag("LUMEN_RENDERLAB_PLATE_EDGE") ?? "") ?? 2048
        let reference = RenderLabReferenceBackend(
            lutSize: LUT3D.exportSize, maxLongEdge: 4096,
            plateLoader: { id in try shipping.plate(id, longEdge: plateEdge, crop: nil) })
        let out = Self.outDir().appendingPathComponent("drift")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("sheets"),
                                                withIntermediateDirectories: true)
        var lines = ["job\tphoto\tlabel\tsize\tdMAE\tp99\tmax\tdLuma\tdHue\tdChroma"]
        for job in manifest.jobs {
            for photo in job.photos {
                let sBase = try shipping.baseRecipe(photo: photo, base: job.base)
                for variant in job.variants {
                    let recipe = try RecipePatch.apply(variant.patch, to: sBase).recipe
                    let s = try shipping.render(photo: photo, recipe: recipe, path: "export",
                                                longEdge: job.longEdge, draftLongEdge: nil, crop: nil)
                    let r = try reference.render(photo: photo, recipe: recipe, path: "reference",
                                                 longEdge: job.longEdge, draftLongEdge: nil, crop: nil)
                    var ri = r.image
                    if ri.width != s.image.width || ri.height != s.image.height {
                        ri = RenderLabSheet.downscale(ri, to: s.image.width, s.image.height)
                    }
                    let d = RenderLabDelta(ri, against: s.image)
                    lines.append([job.id, photo, variant.label, "\(s.image.width)x\(s.image.height)",
                                  String(format: "%.2f", d.meanAbs), String(format: "%.0f", d.p99Abs),
                                  "\(d.maxAbs)", String(format: "%+.2f", d.meanLumaShift),
                                  String(format: "%.2f", d.meanAbsHueShift),
                                  String(format: "%+.4f", d.meanChromaShift)].joined(separator: "\t"))
                    let sheet = RenderLabSheet.compose(
                        title: ["DRIFT  \(job.id)  \(photo)  \(variant.label)",
                                "left: SHIPPING export   right: REFERENCE (ReferenceRenderer)"],
                        cells: [RenderLabSheet.Cell(image: s.image, lines: ["SHIPPING"]),
                                RenderLabSheet.Cell(image: ri, lines: [
                                    "REFERENCE",
                                    String(format: "ΔMAE %.2f P99 %.0f ΔL %+.2f", d.meanAbs, d.p99Abs,
                                           d.meanLumaShift)])],
                        columns: 2, tile: 640)
                    let name = "\(job.id)__\(RenderLabManifest.slug(photo))__\(RenderLabManifest.slug(variant.label)).png"
                    try Self.pngData(sheet).write(to: out.appendingPathComponent("sheets/" + name))
                }
            }
        }
        let table = lines.joined(separator: "\n") + "\n"
        try table.write(to: out.appendingPathComponent("drift.tsv"), atomically: true, encoding: .utf8)
        print("RENDERLAB_DRIFT_BEGIN")
        print(table)
        print("RENDERLAB_DRIFT_END")
    }
}

#endif
