// The graph-cost table behind docs/23 M1a: every draft now runs the FULL pipeline at
// reduced resolution (the stage gates are gone), and this prints what a frame costs at
// the DraftLadder's candidate sizes into the gpu-parity lane's log on every
// pipeline-touching push. The assertion is a sanity ceiling only — the real budget
// (≤ ~35 ms p95 on the owner's machine) is judged from the printed numbers and the
// owner's HUD, not from a shared runner whose GPU varies.
//
// The first recorded run (gpu-parity #2, before the gates went): full pipeline
// 25.1 ms @1024, 36.3 ms @1536, 44.8 ms @2048 on a runner VM — the measurement that
// cleared the no-stage-gating design in the first place.
//
// What it deliberately leaves out, so the numbers mean one thing:
//   · decode — the app decodes at target scale; this probe generates at target scale
//   · masks — their CPU raster cost is measured separately (docs/23 M0 probe b) and
//     amortized by MaskRasterCache; the GPU-side apply is one kernel pass per mask
//   · the film chain — no stock is loaded, so halation and grain are off; their cost
//     is two gaussians and a tiled plate when a stock is on
//
// The second probe (EXPORTPROBE) times what the first leaves out at the other end:
// export at sensor size, render and encoder apart, and a fresh renderer's first
// preview. Same rule — a ceiling, and the numbers judged from the log.
#if os(macOS)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import LumenCore
@testable import LumenPipeline

final class PerfProbeTests: XCTestCase {

    /// A synthetic frame with gradients and fine structure, generated on the GPU so
    /// the probe times rendering rather than a CPU fill.
    private func syntheticFrame(longEdge: Int) -> CIImage {
        let w = longEdge, h = longEdge * 2 / 3
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: w, y: h)
        gradient.color0 = CIColor(red: 0.02, green: 0.03, blue: 0.05)
        gradient.color1 = CIColor(red: 0.9, green: 0.8, blue: 0.6)

        let checker = CIFilter.checkerboardGenerator()
        checker.width = 6
        checker.color0 = CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        checker.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)

        return checker.outputImage!.cropped(to: rect)
            .applyingFilter("CIMultiplyCompositing",
                            parameters: [kCIInputBackgroundImageKey:
                                            gradient.outputImage!.cropped(to: rect)])
    }

    /// Every stage the old draft gates used to switch off, on, at working values.
    private func fullRecipe() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.highlights = -40
        r.develop.tone.shadows = 25
        r.develop.raw.temp = 5200
        r.develop.color.saturation = 12
        r.develop.color.vibrance = 10
        r.develop.detail.texture = 30
        r.develop.detail.clarity = 25
        r.develop.detail.dehaze = 15
        r.develop.detail.sharpen.amount = 80
        r.develop.denoise.mode = .classic
        return r
    }

    func testTimeFullPipelineAtDraftSizes() throws {
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let recipe = fullRecipe()

        for longEdge in [1024, 1536, 2048] {
            let source = syntheticFrame(longEdge: longEdge)
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize)
            let opts = RenderGraph.Options(longEdge: longEdge,
                                           lutSize: LUT3D.interactiveSize)
            var best = Double.greatestFiniteMagnitude
            for rep in 0..<4 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let out = RenderGraph().build(source, plan: plan, options: opts)
                let cg = context.createCGImage(out, from: out.extent)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                XCTAssertNotNil(cg)
                if rep > 0 { best = Swift.min(best, ms) } // rep 0 is warm-up
            }
            print(String(format:
                "PERFPROBE longEdge %4d: full pipeline %7.1f ms", longEdge, best))
            XCTAssertLessThan(best, 10_000,
                "a full-pipeline frame at \(longEdge) px took over ten seconds — "
                    + "something is broken, not merely slow")
        }
    }

    // MARK: - Export at sensor size, and a fresh renderer's first frame

    /// Hands back one of two frames materialized before any clock starts: the full
    /// frame at `scaleFactor` 1 (the export's decode), the preview-sized one below it.
    /// The app decodes at target scale, so a 2560 px preview that pushed all 33 MP
    /// through the graph would time a workload nothing ever runs.
    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null/perf-probe-export")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let full: CIImage
        private let preview: CIImage
        init(full: CIImage, preview: CIImage) {
            self.full = full
            self.preview = preview
        }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(full.extent.width), Int(full.extent.height))
        }
        var nativeLongEdge: Double { Double(max(full.extent.width, full.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            scaleFactor < 1 ? preview : full
        }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// The generator rendered once into a half-float bitmap, so no timed render
    /// re-runs it: the probe should time the pipeline, not the checkerboard.
    private func materialized(_ image: CIImage, context: CIContext) -> CIImage {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let rowBytes = w * 8
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: rowBytes,
                           bounds: image.extent, format: .RGBAh, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes,
                       size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: nil)
    }

    /// One warm-up, then the best of two. Two rather than PERFPROBE's three because
    /// each rep here is a 33 MP render with classic denoise on, in the debug build
    /// gpu-parity runs.
    private func bestOfTwo(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        var best = Double.greatestFiniteMagnitude
        for rep in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try body()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if rep > 0 { best = Swift.min(best, ms) } // rep 0 is warm-up
        }
        XCTAssertLessThan(best, 120_000,
            "\(label) at 33 MP took over two minutes — something is broken, "
                + "not merely slow")
        return best
    }

    /// The full-resolution workload nothing else times: `export` at an A7 IV's
    /// 7008×4672, with the render separated from the encoder, plus what a FRESH
    /// `PipelineRenderer` costs to its first 2560 px preview.
    ///
    /// "Fresh" is not "cold". Kernels compile once per process and Metal keeps its
    /// shader cache, so whichever test ran first already paid for them; what
    /// renderer-init and fresh-context-first-frame price is a new CIContext and its
    /// empty intermediate cache, and the number moves with test order. It is an upper
    /// bound on a warm process, not the app's launch-to-first-preview.
    ///
    /// Encode cost is read off the log as tiff-total (or jpeg-total) minus render.
    /// Every assertion is a sanity ceiling; the numbers are the point.
    func testTimeExportAndFreshRendererFirstFrame() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable,
                          "kernels unavailable, and export refuses without them")
        // The renderer's own working options, so the readback below converts from the
        // space the delivered image is actually in.
        var options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh,
                                               .cacheIntermediates: false]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = working
        }
        let context = CIContext(options: options)
        let recipe = fullRecipe()
        let full = materialized(syntheticFrame(longEdge: 7008), context: context)
        let preview = materialized(syntheticFrame(longEdge: 2560), context: context)
        let source = StubSource(full: full, preview: preview)

        // (a) A fresh renderer to its first preview, and the same call again.
        var t0 = DispatchTime.now().uptimeNanoseconds
        let renderer = PipelineRenderer()
        let initMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        var frameMs: [Double] = []
        for _ in 0..<2 {
            t0 = DispatchTime.now().uptimeNanoseconds
            // The delivery's `createCGImage` renders eagerly, so this is the whole
            // frame and not a promise of one.
            let delivery = try renderer.renderPreviewDelivery(
                source: source, recipe: recipe, maxLongEdge: 2560,
                draft: false, coarseDecode: false)
            frameMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            let longEdge = Swift.max(delivery.image.width, delivery.image.height)
            XCTAssertEqual(Double(longEdge), 2560, accuracy: 1)
        }
        print(String(format: "EXPORTPROBE renderer-init %9.1f ms", initMs))
        print(String(format: "EXPORTPROBE fresh-context-first-frame %9.1f ms",
                     frameMs[0]))
        print(String(format: "EXPORTPROBE second-frame %9.1f ms", frameMs[1]))
        for ms in [initMs] + frameMs {
            XCTAssertLessThan(ms, 120_000, "a 2560 px preview took over two minutes")
        }

        // (b) The delivered pixels into ONE reused 16-bit buffer, 262 MB allocated
        // once: a fresh one per rep would time a second sensor-sized allocation the
        // export never makes.
        let w = Int(full.extent.width), h = Int(full.extent.height)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let rowBytes = w * 8
        let readback = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * h,
                                                        alignment: 64)
        defer { readback.deallocate() }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let renderMs = try bestOfTwo("render") {
            let image = try renderer.exportedImage(source: source, recipe: recipe,
                                                   using: ExportRecipe(name: "probe"))
            XCTAssertEqual(image.extent.integral, frame,
                           "the readback buffer is sized for an uncropped, unresized frame")
            context.render(image, toBitmap: readback, rowBytes: rowBytes,
                           bounds: frame, format: .RGBA16, colorSpace: srgb)
        }

        // The whole `export`, encoder and atomic rename included. A fresh name per
        // rep, because `export` refuses to overwrite.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-exportprobe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func total(_ label: String, _ exportRecipe: ExportRecipe) throws -> Double {
            try bestOfTwo(label) {
                let destination = directory.appendingPathComponent(
                    UUID().uuidString + "." + exportRecipe.format.fileExtension)
                defer { try? FileManager.default.removeItem(at: destination) }
                _ = try renderer.export(source: source, recipe: recipe,
                                        to: destination, using: exportRecipe)
            }
        }
        let tiffMs = try total("tiff-total",
                               ExportRecipe(name: "probe-tiff16", format: .tiff,
                                            bitDepth: 16, colorSpace: .srgb,
                                            resizeMode: .none))
        let jpegMs = try total("jpeg-total",
                               ExportRecipe(name: "probe-jpeg", format: .jpeg,
                                            colorSpace: .srgb, resizeMode: .none))

        print(String(format: "EXPORTPROBE 33MP render %9.1f ms", renderMs))
        print(String(format: "EXPORTPROBE 33MP tiff-total %9.1f ms", tiffMs))
        print(String(format: "EXPORTPROBE 33MP jpeg-total %9.1f ms", jpegMs))
    }
}
#endif
