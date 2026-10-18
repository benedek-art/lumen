#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// Private, opt-in native RAW region evidence. Metrics are NO-REFERENCE proxies:
/// less gradient/laplacian energy can mean either noise removal or lost detail.
final class NativeDenoiseQualificationTests: XCTestCase {
    private let controls: [(String, WritableKeyPath<ClassicNR, Double>)] = [
        ("luma", \.luma), ("chroma", \.chroma), ("hotPixels", \.hotPixels),
        ("lumaDetail", \.lumaDetail), ("lumaContrast", \.lumaContrast),
        ("colorDetail", \.colorDetail), ("colorSmoothness", \.colorSmoothness)
    ]

    func testNativeDenoiseRegions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["LUMEN_DENOISE_RAW_DIR"],
              let output = env["LUMEN_DENOISE_EVIDENCE_DIR"] else {
            throw XCTSkip("Configure LUMEN_DENOISE_RAW_DIR and LUMEN_DENOISE_EVIDENCE_DIR for private native crops")
        }
        XCTAssertTrue(KernelLibrary.denoiseAvailable, "denoise GPU kernels unavailable")
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        Diagnostic native-resolution S3 denoise crops. PNGs convert scene-linear Rec.2020
        directly to sRGB with no display tone mapping. Highlights may clip; do not infer
        aesthetic rendering quality or highlight preservation from these PNGs. Numeric
        metrics are scene-linear before PNG conversion. Lower Laplacian energy may mean
        either removed noise OR removed real detail. Originals are not modified.
        """.write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: input), includingPropertiesForKeys: nil)
            .filter { ["arw", "rw2", "dng", "nef", "cr3", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "configured RAW directory is empty")
        let limit = Int(env["LUMEN_DENOISE_LIMIT"] ?? "12") ?? 12
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let display = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh,
                                          .cacheIntermediates: false])
        var rows: [[String: Any]] = []
        for (ordinal, url) in files.prefix(max(1, limit)).enumerated() {
            try autoreleasepool {
                let source = try AppleRawSource(url: url)
                var recipe = Recipe()
                recipe.develop.denoise.mode = .off
                guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1) else {
                    XCTFail("native-denoise fixture\(ordinal + 1) decode failed"); return
                }
                // Force demosaic once, bounded to one source at a time. A lazy RAW
                // CIImage can otherwise repeat demosaic for every region/variant.
                let nativeWidth = Int(decoded.extent.width)
                let nativeHeight = Int(decoded.extent.height)
                var nativeBytes = Data(count: nativeWidth * nativeHeight * 8)
                nativeBytes.withUnsafeMutableBytes { raw in
                    context.render(decoded, toBitmap: raw.baseAddress!, rowBytes: nativeWidth * 8,
                                   bounds: decoded.extent, format: .RGBAh, colorSpace: linear)
                }
                let materialized = CIImage(bitmapData: nativeBytes, bytesPerRow: nativeWidth * 8,
                                           size: CGSize(width: nativeWidth, height: nativeHeight),
                                           format: .RGBAh, colorSpace: linear)
                let iso = source.captureMetadata.iso ?? 100
                let extent = materialized.extent
                let side = min(192.0, min(extent.width, extent.height))
                let positions = [(0.5, 0.5), (0.18, 0.18), (0.82, 0.82)]
                var variants: [(String, Denoise)] = [
                    ("off", Denoise(mode: .off)),
                    ("zero", Denoise(mode: .classic, classic: ClassicNR(luma: 0, chroma: 0))),
                    ("default", Denoise(mode: .classic, classic: ISODefaults.classic(forISO: iso)))
                ]
                for strength in [25.0, 50.0, 100.0] {
                    variants.append(("both\(Int(strength))", Denoise(mode: .classic, classic: ClassicNR(luma: strength, chroma: strength))))
                }
                for (name, key) in controls {
                    for endpoint in [0.0, 100.0] {
                        var settings = ClassicNR(luma: 50, chroma: 50)
                        settings[keyPath: key] = endpoint
                        variants.append(("\(name)\(Int(endpoint))", Denoise(mode: .classic, classic: settings)))
                    }
                }
                for (region, position) in positions.enumerated() {
                    let rect = CGRect(x: floor(extent.minX + (extent.width - side) * position.0),
                                      y: floor(extent.minY + (extent.height - side) * position.1), width: side, height: side)
                    var off: [Float] = []
                    for (name, denoise) in variants {
                        let start = Date()
                        recipe.develop.denoise = denoise
                        let plan = RenderPlan(recipe: recipe, captureISO: iso)
                        let image = RenderGraph().applyDenoise(materialized, plan: plan,
                            options: RenderGraph.Options(longEdge: Int(max(extent.width, extent.height))))
                        let w = Int(side), h = Int(side)
                        var pixels = [Float](repeating: 0, count: w * h * 4)
                        pixels.withUnsafeMutableBytes { raw in
                            context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                                           bounds: rect, format: .RGBAf, colorSpace: nil)
                        }
                        XCTAssertTrue(pixels.allSatisfy { $0.isFinite }, "fixture\(ordinal + 1) \(name)")
                        if name == "off" { off = pixels }
                        var delta = 0.0, energy = 0.0, mean = 0.0
                        for y in 1..<(h - 1) {
                            for x in 1..<(w - 1) {
                                let i = (y * w + x) * 4
                                for c in 0..<3 {
                                    let p = Double(pixels[i + c])
                                    mean += p
                                    delta += abs(p - Double(off[i + c]))
                                    energy += abs(4 * p - Double(pixels[i - 4 + c]) - Double(pixels[i + 4 + c])
                                                  - Double(pixels[i - w * 4 + c]) - Double(pixels[i + w * 4 + c]))
                                }
                            }
                        }
                        let count = Double((w - 2) * (h - 2) * 3)
                        if name == "zero" { XCTAssertLessThan(delta / count, 1e-7, "off/zero identity") }
                        rows.append(["fixture": ordinal + 1, "region": region, "variant": name,
                                     "iso": iso, "width": w, "height": h, "meanLinearRGB": mean / count,
                                     "meanAbsoluteDeltaFromOff": delta / count,
                                     "laplacianAbsoluteEnergyProxy": energy / count,
                                     "seconds": Date().timeIntervalSince(start)])
                        let label = "fixture\(ordinal + 1)-region\(region)-\(name).png"
                        let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                        try context.writePNGRepresentation(of: crop, to: root.appendingPathComponent(label),
                                                           format: .RGBA8, colorSpace: display)
                        print("native-denoise fixture\(ordinal + 1) ISO=\(iso) region=\(region) variant=\(name) delta=\(delta / count) energyProxy=\(energy / count)")
                    }
                }
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("native-denoise-metrics.json"), options: .atomic)
        }
    }
}
#endif
