import Foundation
import CoreImage
import ImageIO
import LumenCore
@testable import LumenPipeline

// Only the format predicate used by the unchanged RenderCoordinator.swift is needed.
enum PhotoFormats {
    static func isRendered(_ url: URL) -> Bool {
        ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }
}
enum AppState { static let maskThumbnailLongEdge = 96 }

final class SyntheticSource: ImageSource {
    let url: URL
    let image: CIImage
    var onDecode: (() -> Void)?
    init(url: URL, image: CIImage) { self.url = url; self.image = image }
    var nativeLongEdge: Double { max(image.extent.width, image.extent.height) }
    var nativePixelSize: (width: Int, height: Int) { (Int(image.extent.width), Int(image.extent.height)) }
    let asShotTemperature = 5500.0
    let asShotTint = 0.0
    let statisticsProvenance: RawStatistics.Provenance = .unspecified
    var captureMetadata: CaptureMetadata {
        CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                        decoderVersion: nil, pixelSize: nativePixelSize)
    }
    func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
        onDecode?(); return image
    }
}

@main struct Probe {
    static func emit(_ name: String, _ values: [String: Any]) throws {
        print(String(data: try JSONSerialization.data(withJSONObject: ["case": name, "values": values],
                         options: [.sortedKeys]), encoding: .utf8)!)
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func writeFixture(_ url: URL, width: Int, height: Int, red: Bool) throws {
            let image = CIImage(color: CIColor(red: red ? 0.75 : 0.05, green: red ? 0.05 : 0.75, blue: 0.05))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
        }
        let original = root.appendingPathComponent("original.png")
        try writeFixture(original, width: 32, height: 24, red: true)
        let coordinator = RenderCoordinator()
        let first = await coordinator.nativeSize(for: original)!
        var recipe = Recipe(); recipe.develop.denoise.mode = .off
        let before = await coordinator.sampleSceneLinear(url: original, recipe: recipe, sourceX: 0.5, sourceY: 0.5)!
        try writeFixture(original, width: 64, height: 48, red: false)
        let stillCached = await coordinator.nativeSize(for: original)!
        let after = await coordinator.sampleSceneLinear(url: original, recipe: recipe, sourceX: 0.5, sourceY: 0.5)!
        await coordinator.invalidate(url: original)
        let reloaded = await coordinator.nativeSize(for: original)!
        let refreshed = await coordinator.sampleSceneLinear(url: original, recipe: recipe, sourceX: 0.5, sourceY: 0.5)!
        try emit("cached-original-changed-on-disk", ["initialSize": [first.width, first.height],
            "onDiskSize": [64,48], "cachedSizeAfterRewrite": [stillCached.width, stillCached.height],
            "sizeAfterExplicitInvalidation": [reloaded.width, reloaded.height],
            "beforePixel": [before.r,before.g,before.b], "afterRewritePixel": [after.r,after.g,after.b],
            "afterInvalidationPixel": [refreshed.r,refreshed.g,refreshed.b]])

        let source = SyntheticSource(url: original, image: CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)))
        let renderer = PipelineRenderer()
        try emit("kernel-availability", ["core": renderer.isGPUPathAvailable,
                                         "missing": renderer.unavailableKernels])
        guard renderer.isGPUPathAvailable else { return }
        let destination = root.appendingPathComponent("collision.jpg")
        let claimed = ExportRecipe.disambiguated(destination) { fm.fileExists(atPath: $0.path) }
        let sentinel = Data("Other process created an important file after export claimed this name".utf8)
        source.onDecode = { try! sentinel.write(to: claimed) }
        _ = try renderer.export(source: source, recipe: recipe, to: claimed, using: ExportRecipe(name: "probe"))
        source.onDecode = nil
        let delivered = try Data(contentsOf: claimed)
        try emit("destination-appears-during-render", ["sentinelSurvived": delivered == sentinel,
            "deliveredBytes": delivered.count, "deliveredHeader": Array(delivered.prefix(3)),
            "files": try fm.contentsOfDirectory(atPath: root.path).sorted()])

        for format in ExportFormat.allCases {
            for depth in (format == .png || format == .tiff ? [8,16] : (format == .heif ? [8,10] : [8])) {
                let destination = root.appendingPathComponent("export-\(depth).\(format.fileExtension)")
                let start = Date()
                do {
                    _ = try renderer.export(source: source, recipe: recipe, to: destination,
                            using: ExportRecipe(name: "probe", format: format, bitDepth: depth, colorSpace: .displayP3))
                    let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(destination as CFURL, nil)!, 0, nil)! as NSDictionary
                    try emit("export-format", ["format": format.rawValue, "requestedDepth": depth,
                        "depth": props[kCGImagePropertyDepth] ?? "missing", "profile": props[kCGImagePropertyProfileName] ?? "missing",
                        "width": props[kCGImagePropertyPixelWidth] ?? "missing", "height": props[kCGImagePropertyPixelHeight] ?? "missing",
                        "elapsedSeconds": Date().timeIntervalSince(start)])
                } catch { try emit("export-format-error", ["format": format.rawValue, "requestedDepth": depth, "error": String(describing: error)]) }
            }
        }
    }
}
