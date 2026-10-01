// The HDR preview's GPU half (`PipelineRenderer.renderPreviewEDR`), held to the two
// promises the viewport makes:
//
//   1. The EDR frame is the gain-map export's HDR rendition — `renderHDRPair`'s `hdr`
//      image — at the interactive table size, with real headroom above SDR white.
//   2. The SDR frame does not move. With the preview off nothing calls the EDR pass at
//      all (`RenderCoordinator.produce` reads `edrWhiteTarget` only after the SDR
//      delivery, which is the call it always was). With it on, the EDR pass runs
//      beside the SDR one on the same renderer and the same table cache — and the SDR
//      frame it leaves behind is byte-for-byte the frame rendered with no EDR pass.
//
// The arithmetic (which white, the badge, the round trip through a gain-map decoder)
// is `EDRPreviewTests` in LumenCoreTests and runs on every lane.
#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class EDRPreviewRenderTests: XCTestCase {

    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null/edr-preview")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage
        init(_ image: CIImage) { self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// −6…+5 EV across the frame, so the HDR rendition has speculars to let out.
    private func sourceImage(width: Int, height: Int) -> CIImage {
        let buffer = ImageBuffer(width: width, height: height) { u, v in
            let y = 0.18 * pow(2.0, -6 + u * 11)
            let texture = 1.0 + 0.1 * sin(u * 97.0) * sin(v * 61.0)
            return RGB(y * texture, y * texture * 0.97, y * texture * 1.04)
        }
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func recipe() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.5
        r.develop.color.saturation = 10
        return r
    }

    private func bytes(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }

    /// Linear extended sRGB floats, RGBA, whatever the image's own encoding.
    private func linearFloats(_ image: CIImage, context: CIContext) -> [Float] {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var out = [Float](repeating: 0, count: width * height * 4)
        guard let space = PipelineRenderer.edrColorSpace else { return [] }
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16, bounds: extent,
                           format: .RGBAf, colorSpace: space)
        }
        return out
    }

    private func waitForBakes(_ stub: StubSource) {
        let identity = PlanTableCache.renderIdentity(for: stub.url)
        let deadline = Date().addingTimeInterval(10)
        while (PlanTableCache.anyBakePending(for: identity)
               || PlanTableCache.anyBakePending(
                    for: identity + PipelineRenderer.edrIdentitySuffix)),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Promise 1. `renderHDRPair` bakes at the export table size and the preview at
    /// the interactive one — `previewPlan` and `exportPlan` differ the same way for
    /// SDR — so the comparison carries a table-size tolerance and nothing more.
    func testTheEDRFrameIsTheGainMapExportsHDRRendition() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        PlanTableCache.clear()
        let stub = StubSource(sourceImage(width: 256, height: 96))
        let renderer = PipelineRenderer()
        let settings = HDRSettings(headroomEV: 2)
        guard let white = EDRPreview.whiteTarget(enabled: true, content: settings,
                                                 currentComponentValue: 16,
                                                 potentialComponentValue: 16)
        else { return XCTFail("no EDR target on a 16× display") }
        XCTAssertEqual(white, settings.whiteTargetPercent)

        let edr = try renderer.renderPreviewEDR(source: stub, recipe: recipe(),
                                                maxLongEdge: 256, draft: false,
                                                coarseDecode: false,
                                                displayWhiteTarget: white)
        let pair = try renderer.renderHDRPair(source: stub, recipe: recipe(),
                                              settings: settings)

        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        let previewed = linearFloats(CIImage(cgImage: edr.image), context: context)
        let exported = linearFloats(pair.hdr, context: context)
        XCTAssertEqual(edr.image.width, 256)
        XCTAssertEqual(previewed.count, exported.count,
                       "the EDR frame and the export's HDR rendition differ in size")
        guard previewed.count == exported.count, !previewed.isEmpty else { return }

        var worst: Float = 0, sum: Float = 0, peak: Float = 0
        for i in previewed.indices where i % 4 != 3 {
            let d = abs(previewed[i] - exported[i]) / Swift.max(1, exported[i])
            worst = Swift.max(worst, d)
            sum += d
            peak = Swift.max(peak, previewed[i])
        }
        let mean = sum / Float(previewed.count * 3 / 4)
        // The bounds are the table-size difference, generously: `previewPlan`'s own
        // note measures a 33-point table's p99 error in the tens of 8-bit levels, and
        // the export bakes at 65. What they exclude is a different WHITE — rendered at
        // 100% this frame would differ by about half its value over the quarter of it
        // that sits above SDR white, a mean near 0.13 — and the peak check below
        // excludes a frame that clips.
        XCTAssertLessThan(worst, 0.15, "the EDR frame departs from the export's HDR "
                              + "rendition by \(worst) somewhere")
        XCTAssertLessThan(mean, 0.02, "the EDR frame departs from the export's HDR "
                              + "rendition by \(mean) on average")
        // And it carries the headroom: a frame clipped at SDR white would pass the
        // comparison above only if the export clipped too.
        XCTAssertGreaterThan(peak, 2.0, "the EDR frame peaks at \(peak)× SDR white")
        XCTAssertLessThanOrEqual(peak, Float(white / 100) * 1.02)
    }

    /// Promise 2, at rest: a settle blocks on exact tables, so whatever an EDR pass
    /// left in the cache, the SDR settle beside it is the settle with none.
    func testAnEDRPassLeavesTheSDRSettleByteIdentical() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let stub = StubSource(sourceImage(width: 256, height: 96))

        PlanTableCache.clear()
        let alone = try PipelineRenderer().renderPreviewDelivery(
            source: stub, recipe: recipe(), maxLongEdge: 256, draft: false,
            coarseDecode: false)
        waitForBakes(stub)

        PlanTableCache.clear()
        let renderer = PipelineRenderer()
        _ = try renderer.renderPreviewEDR(source: stub, recipe: recipe(), maxLongEdge: 256,
                                          draft: false, coarseDecode: false,
                                          displayWhiteTarget: 400)
        let beside = try renderer.renderPreviewDelivery(
            source: stub, recipe: recipe(), maxLongEdge: 256, draft: false,
            coarseDecode: false)
        _ = try renderer.renderPreviewEDR(source: stub, recipe: recipe(), maxLongEdge: 256,
                                          draft: false, coarseDecode: false,
                                          displayWhiteTarget: 400)
        waitForBakes(stub)

        XCTAssertEqual(alone.image.bitsPerComponent, 8)
        XCTAssertNotNil(bytes(alone.image))
        XCTAssertEqual(bytes(alone.image), bytes(beside.image),
                       "an EDR pass beside the SDR settle changed the SDR settle's bytes")
    }

    /// Promise 2, under a moving hand — and the reason the EDR pass plans under its
    /// own cache identity (`PipelineRenderer.edrIdentitySuffix`).
    ///
    /// A draft may borrow "the newest finish table this photograph rendered with"
    /// while the exact one bakes. The finish key includes the display white, so an
    /// EDR pass at 400% is a newer finish table for the same photograph — and under a
    /// shared identity the next SDR draft would borrow it and paint the HDR picture
    /// formation into 8 bits. The edit between the two drafts here moves ONLY the
    /// finish key (the render preset's contrast), so with the identities apart the
    /// SDR draft must be exactly the draft rendered with no EDR pass at all.
    func testAnEDRPassNeverLendsTheSDRDraftItsTables() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let stub = StubSource(sourceImage(width: 256, height: 96))
        let first = recipe()
        var second = first
        second.look.render.contrast = 1.6

        // Reference: SDR drafts only.
        PlanTableCache.clear()
        let plain = PipelineRenderer()
        _ = try plain.renderPreviewDelivery(source: stub, recipe: first, maxLongEdge: 256,
                                            draft: true, coarseDecode: false)
        let reference = try plain.renderPreviewDelivery(source: stub, recipe: second,
                                                        maxLongEdge: 256, draft: true,
                                                        coarseDecode: false)
        waitForBakes(stub)

        // The viewer with the HDR preview on: each request renders SDR, then EDR.
        PlanTableCache.clear()
        let viewer = PipelineRenderer()
        _ = try viewer.renderPreviewDelivery(source: stub, recipe: first, maxLongEdge: 256,
                                             draft: true, coarseDecode: false)
        _ = try viewer.renderPreviewEDR(source: stub, recipe: first, maxLongEdge: 256,
                                        draft: false, coarseDecode: false,
                                        displayWhiteTarget: 400)
        let withEDR = try viewer.renderPreviewDelivery(source: stub, recipe: second,
                                                       maxLongEdge: 256, draft: true,
                                                       coarseDecode: false)
        waitForBakes(stub)

        XCTAssertNotNil(bytes(reference.image))
        XCTAssertEqual(bytes(reference.image), bytes(withEDR.image),
                       "the SDR draft after an EDR pass is not the SDR draft — it "
                           + "borrowed the EDR pass's finish table")
    }

    /// The coordinator keeps an EDR frame only when it covers what the SDR frame
    /// covers; the two region computations are separate copies, so they are held to
    /// agree here for whole frames and for the regions a zoomed loupe asks for.
    func testTheEDRFrameCoversTheSDRFramesRegion() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        PlanTableCache.clear()
        let stub = StubSource(sourceImage(width: 256, height: 96))
        let renderer = PipelineRenderer()
        let regions: [CGRect?] = [nil,
                                  CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                  CGRect(x: 0.6, y: 0.1, width: 0.33, height: 0.71),
                                  CGRect(x: 0, y: 0, width: 1, height: 1)]
        for region in regions {
            let sdr = try renderer.renderPreviewDelivery(source: stub, recipe: recipe(),
                                                         maxLongEdge: 256, draft: false,
                                                         coarseDecode: false,
                                                         region: region)
            let edr = try renderer.renderPreviewEDR(source: stub, recipe: recipe(),
                                                    maxLongEdge: 256, draft: false,
                                                    coarseDecode: false, region: region,
                                                    displayWhiteTarget: 400)
            XCTAssertEqual(edr.regionUnit, sdr.regionUnit, "region \(String(describing: region))")
            XCTAssertEqual(edr.fullPixelSize, sdr.fullPixelSize)
            XCTAssertEqual(edr.image.width, sdr.image.width)
            XCTAssertEqual(edr.image.height, sdr.image.height)
            XCTAssertEqual(edr.image.bitsPerComponent, 16, "the EDR frame is not half-float")
        }
        waitForBakes(stub)
    }
}
#endif
