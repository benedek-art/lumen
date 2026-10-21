// MaskSpeedTests.swift
// Lane M9: what a frame with a mask active is allowed to cost, stated as counts rather
// than milliseconds so it holds on any machine.
//
//  · An adjustment-only edit rasterizes nothing, at the settle rung too.
//  · A range mask (luminance, luminosity, colour, with gradients, invert and Levels)
//    never reaches the CPU raster path or the stage readback, and its alpha over the
//    real stage input is the CPU definition's.
//  · A mask whose bake is cheap is never served one frame stale.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskSpeedTests: XCTestCase {

    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull(),
                                              .workingFormat: CIFormat.RGBAf])

    private final class SpeedFixture: ImageSource {
        let url: URL
        let nativeLongEdge: Double
        let nativePixelSize: (width: Int, height: Int)
        let asShotTemperature = 5500.0
        let asShotTint = 0.0
        let captureMetadata: CaptureMetadata
        let statisticsProvenance = RawTruth.provenance(isRenderedFile: true)
        private let image: CIImage

        init(longEdge: Int, name: String) {
            url = URL(fileURLWithPath: "/tmp/lumen-mask-speed-\(name).tif")
            nativeLongEdge = Double(longEdge)
            nativePixelSize = (longEdge, longEdge / 2)
            captureMetadata = CaptureMetadata(asShotTemperature: 5500, asShotTint: 0,
                                               decoderVersion: nil,
                                               pixelSize: nativePixelSize)
            let pixels = ImageBuffer(width: longEdge, height: longEdge / 2) { u, v in
                let l = pow(2, -9 + u * 12)
                return RGB(l * (0.7 + 0.3 * sin(6 * v)), l * (0.6 + 0.3 * cos(4 * v)),
                           l * (0.5 + 0.4 * v))
            }
            image = pixels.pixels.withUnsafeBytes {
                CIImage(bitmapData: Data($0), bytesPerRow: longEdge * 16,
                        size: CGSize(width: longEdge, height: longEdge / 2),
                        format: .RGBAf, colorSpace: nil)
            }
        }

        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            image.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        }
    }

    private func export(_ renderer: PipelineRenderer, _ source: SpeedFixture,
                        _ recipe: Recipe) throws -> ImageBuffer {
        let image = try renderer.exportedImage(source: source, recipe: recipe,
                                               using: ExportRecipe(name: "Mask speed"))
        return try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
    }

    private func worst(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        return zip(a.pixels, b.pixels).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    private func outline() -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .polygon)
        c.path = [[0.1, 0.1], [0.6, 0.15], [0.55, 0.9], [0.15, 0.8]]
        return c
    }

    private func band() -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = 0.35; c.hi = 0.7; c.smooth = 40
        return c
    }

    // MARK: - 1. adjustment-only edits never rasterize, settle rung included

    /// 1100 px is above the 1024 draft proxy, so every raster here is a settle-rung
    /// raster. Before lane M9 the cache refused those, and every settle rasterized every
    /// CPU mask again whatever the edit was.
    func testAdjustmentOnlyEditsNeverRebakeAtSettle() throws {
        let source = SpeedFixture(longEdge: 1100, name: "adjust")
        var r = Recipe()
        r.develop.denoise.mode = .off
        var mask = Mask(id: "outline", components: [outline()])
        mask.refine.feather = 20          // a guided refine: the expensive CPU case
        mask.adjust.exposure = 1
        r.masks = [mask]
        let renderer = PipelineRenderer()
        let first = try export(renderer, source, r)
        let bakes = MaskRasterCache.currentStats.bakes
        for step in 1...3 {
            r.masks[0].adjust.exposure = 1 + 0.25 * Double(step)
            r.masks[0].amount = 100 - 10 * Double(step)
            _ = try export(renderer, source, r)
        }
        XCTAssertEqual(MaskRasterCache.currentStats.bakes, bakes,
                       "an adjustment-only edit rasterized the selection again")

        // And on draft frames, at the 1024 proxy.
        _ = try renderer.renderPreview(source: source, recipe: r, maxLongEdge: 1100,
                                       draft: true, coarseDecode: true)
        let draftBakes = MaskRasterCache.currentStats.bakes
        for step in 1...3 {
            r.masks[0].adjust.exposure = 1 + 0.3 * Double(step)
            _ = try renderer.renderPreview(source: source, recipe: r, maxLongEdge: 1100,
                                           draft: true, coarseDecode: true)
        }
        XCTAssertEqual(MaskRasterCache.currentStats.bakes, draftBakes,
                       "an adjustment-only drag rasterized the selection on a draft")
        r.masks[0].adjust.exposure = 1
        r.masks[0].amount = 100
        let back = try export(renderer, source, r)
        XCTAssertEqual(worst(first, back), 0, "the held raster is not the one it replaced")
        let cold = try export(PipelineRenderer(), source, r)
        XCTAssertEqual(worst(back, cold), 0, "a held settle raster differs from a cold one")
    }

    // MARK: - 2. range masks never reach the CPU

    func testRangeMasksTakeTheGPUPath() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable)
        let source = SpeedFixture(longEdge: 1100, name: "range")
        var linear = MaskComponent(op: .intersect, kind: .linear)
        linear.line = [0.5, 0.1, 0.5, 0.9]
        var colour = MaskComponent(op: .add, kind: .colorRange)
        colour.samples = [[0.05, 0.04, 0.03]]
        var luminosity = MaskComponent(op: .add, kind: .luminosity)
        luminosity.series = .darks
        luminosity.level = 2
        var radial = MaskComponent(op: .subtract, kind: .radial)
        radial.center = [0.7, 0.4]
        radial.radii = [0.15, 0.2]
        var sky = Mask(id: "sky", components: [band(), linear, radial])
        sky.adjust.exposure = -0.7
        var picked = Mask(id: "picked", components: [colour, luminosity])
        picked.invert = true
        picked.refine.levelsGamma = 1.6
        picked.adjust.sat = -30

        var r = Recipe()
        r.develop.denoise.mode = .off
        r.masks = [sky, picked]
        let renderer = PipelineRenderer()
        let bakes = MaskRasterCache.currentStats.bakes
        let reads = LazyStageBuffer.renderCount
        var frames: [ImageBuffer] = []
        for exposure in [0.0, 0.5, 1.0] {
            r.develop.tone.exposure = exposure
            frames.append(try export(renderer, source, r))
        }
        for exposure in [0.2, 0.7] {
            r.develop.tone.exposure = exposure
            _ = try renderer.renderPreview(source: source, recipe: r, maxLongEdge: 1100,
                                           draft: true, coarseDecode: true)
        }
        XCTAssertEqual(MaskRasterCache.currentStats.bakes, bakes,
                       "a range mask was rasterized on the CPU")
        XCTAssertEqual(LazyStageBuffer.renderCount, reads,
                       "a range mask read the stage input back to the CPU")
        XCTAssertGreaterThan(worst(frames[0], frames[2]), 0.01,
                             "the frames must actually differ, or this proves nothing")
    }

    /// The GPU alpha over the REAL stage input — `gpuMaskStage`, the image the frame
    /// samples — against `MaskRaster.combine` over the same stage read back. The
    /// kernel-level parity lives in `MaskRangeGPUParityTests`; this one proves the
    /// pipeline hands the kernels the picture the CPU path would have sampled.
    func testTheRangeAlphaOverTheRealStageIsTheCPUDefinition() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable)
        let source = SpeedFixture(longEdge: 600, name: "stage")
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.develop.tone.exposure = 0.6
        r.develop.tone.contrast = 25
        r.develop.color.saturation = 15
        var colour = MaskComponent(op: .subtract, kind: .colorRange)
        colour.samples = [[0.2, 0.1, 0.05]]
        let mask = Mask(id: "m", components: [band(), colour])
        r.masks = [mask]
        let renderer = PipelineRenderer()
        let plan = RenderPlan(recipe: r, asShotKelvin: 5500, asShotTint: 0)
        let decoded = try XCTUnwrap(source.decode(recipe: r, draft: false, scaleFactor: 1))
        let stage = try XCTUnwrap(renderer.gpuMaskStage(decoded: decoded, plan: plan,
                                                        strokeSets: [:]))
        let extent = decoded.extent
        let alpha = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent, source: stage))
        let buffer = try XCTUnwrap(PipelineRenderer.buffer(from: stage, context: context))
        let w = Int(extent.width), h = Int(extent.height)
        let reference = MaskRaster.combine(mask: mask, size: (width: w, height: h),
                                           source: buffer)
        var bytes = [Float](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            context.render(alpha, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        var past = 0
        for i in 0..<(w * h) where abs(Double(bytes[i * 4]) - reference[i % w, i / w]) > 2e-3 {
            past += 1
        }
        XCTAssertLessThan(Double(past) / Double(w * h), 1e-3)
        XCTAssertGreaterThan(reference.values.max() ?? 0, 0.5, "the fixture selects nothing")
    }

    // MARK: - 3. a cheap bake is never served stale

    func testACheapBrushBakeIsNeverServedStale() {
        let cache = MaskRasterCache(
            synchronousBakeBudget: MaskRasterCache.interactiveSynchronousBakeBudget)
        let a = Plane(width: 64, height: 32, fill: 0.25)
        let b = Plane(width: 64, height: 32, fill: 0.75)
        _ = cache.plane(maskID: "brush", key: "k0", identity: "photo",
                        allowStale: true) { a }
        let stale = MaskRasterCache.currentStats.staleServes
        let served = cache.plane(maskID: "brush", key: "k1", identity: "photo",
                                 allowStale: true) { b }
        XCTAssertEqual(served.values.first, 0.75,
                       "a mask that bakes in microseconds was served its previous raster")
        XCTAssertEqual(MaskRasterCache.currentStats.staleServes, stale)
    }

    /// And the door stays open for the masks it exists for.
    func testAnExpensiveBakeStillServesStaleOnADraft() {
        let cache = MaskRasterCache(
            synchronousBakeBudget: MaskRasterCache.interactiveSynchronousBakeBudget)
        let a = Plane(width: 64, height: 32, fill: 0.25)
        let b = Plane(width: 64, height: 32, fill: 0.75)
        let slow = MaskRasterCache.interactiveSynchronousBakeBudget / 1000 * 3
        _ = cache.plane(maskID: "refined", key: "k0", identity: "photo",
                        allowStale: true) {
            Thread.sleep(forTimeInterval: slow)
            return a
        }
        let served = cache.plane(maskID: "refined", key: "k1", identity: "photo",
                                 allowStale: true) {
            Thread.sleep(forTimeInterval: slow)
            return b
        }
        XCTAssertEqual(served.values.first, 0.25,
                       "an expensive draft bake must ride the previous raster")
        let deadline = Date(timeIntervalSinceNow: 5)
        while cache.hasPendingBake("refined"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(cache.plane(maskID: "refined", key: "k1", identity: "photo",
                                   allowStale: true) { a }.values.first, 0.75,
                       "the background bake landed")
    }
}

#endif
