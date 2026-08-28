// The permanent lock on the draft-render redesign (docs/23 M1a): a draft frame and a
// settle frame at the SAME size must be the same picture.
//
// This test was unwritable by design before the stage gates came out of
// `RenderGraph.build`: a draft omitted denoise, presence, every mask, sharpening,
// halation, local curves and grain, so "the picture during a drag" and "the picture at
// rest" were different pictures — the owner's first complaint in both Mac sessions,
// verbatim. Now the only sanctioned draft/settle differences are the decode (a stub
// here, identical by construction) and the resolution (held equal here on purpose), so
// per-pixel agreement is the contract, and any future gate someone slips back into the
// graph fails this file before it reaches a photographer.
//
// The film chain is exercised elsewhere (halation goldens); it stays out of this
// recipe so the comparison does not hinge on grain-plate determinism.
#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class DraftTruthfulnessTests: XCTestCase {

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh,
                                              .cacheIntermediates: false])

    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null/draft-truthfulness")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage
        init(_ image: CIImage) { self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        // Ignores `draft` and `scaleFactor` so the decode cannot explain any
        // difference the assertion finds: whatever differs came from the graph.
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// Gradients plus structure plus a hard edge — something for every stage to act on.
    private func sourceImage(width: Int, height: Int) -> CIImage {
        let buffer = ImageBuffer(width: width, height: height) { u, v in
            let ramp = 0.18 * pow(2.0, -6 + u * 10)
            let texture = 1.0 + 0.2 * sin(u * 97.0) * sin(v * 61.0)
            let edge: Double = v > 0.5 ? 1.6 : 0.6
            return RGB(ramp * texture * edge, ramp * texture * edge * 0.95,
                       ramp * texture * edge * 1.08)
        }
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: nil)
    }

    /// Every formerly-gated stage, live: denoise, presence, a refined mask carrying
    /// local exposure, clarity and a local point curve, and creative sharpening.
    private func fullRecipe() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.5
        r.develop.tone.highlights = -30
        r.develop.color.saturation = 15
        r.develop.detail.texture = 30
        r.develop.detail.clarity = 25
        r.develop.detail.dehaze = 10
        r.develop.detail.sharpen.amount = 80
        r.develop.denoise.mode = .classic

        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.5, 0.5]
        radial.radii = [0.35, 0.25]
        radial.feather = 40
        var mask = Mask(id: "truthfulness-mask", name: "probe",
                        components: [radial])
        mask.refine = MaskRefine(feather: 25)   // forces the source-reading raster path
        mask.adjust.exposure = 0.8
        mask.adjust.clarity = 30
        mask.adjust.curve = CurveSet(point: [[0, 0], [0.45, 0.55], [1, 1]])
        r.masks = [mask]
        return r
    }

    private func bytes(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }

    func testADraftFrameIsTheSettleFramesPicture() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        PlanTableCache.clear()

        let stub = StubSource(sourceImage(width: 384, height: 256))
        let renderer = PipelineRenderer()
        let recipe = fullRecipe()

        // Draft first, on a cold renderer: the mask raster and both colour tables hit
        // their first-request-bakes-synchronously rules, so this draft is EXACT — the
        // stale machinery only ever serves a follow-up frame of a drag.
        //
        // `coarseDecode: false` on BOTH, which is what the viewer now asks for on both
        // and is the claim this test locks: a draft differs from a settle in what it
        // may serve stale, and in nothing else.
        //
        // The decode quality used to ride along with `draft`, and this test could not
        // have caught it — the stub ignores the flag by construction (see `decode`
        // above), so the two frames agreed here at 2/255 while the app's real drafts
        // were visibly softer than its settles. Worth stating plainly: the same
        // property that makes this file a clean test of the GRAPH makes it blind to
        // the decode, and the decode is where the last three rounds of blur lived.
        let draft = try renderer.renderPreview(source: stub, recipe: recipe,
                                               maxLongEdge: 384, draft: true,
                                               coarseDecode: false)
        let settle = try renderer.renderPreview(source: stub, recipe: recipe,
                                                maxLongEdge: 384, draft: false,
                                                coarseDecode: false)

        guard let d = bytes(draft), let s = bytes(settle), d.count == s.count else {
            return XCTFail("draft and settle rendered different formats "
                               + "(\(draft.width)×\(draft.height) vs "
                               + "\(settle.width)×\(settle.height))")
        }
        var worst = 0
        for i in 0..<d.count { worst = Swift.max(worst, abs(Int(d[i]) - Int(s[i]))) }
        XCTAssertLessThanOrEqual(worst, 2,
            "a draft and a settle of the same recipe at the same size differ by "
                + "\(worst)/255 — a stage is being gated out of one of them")

        // And the frame being compared actually CONTAINS the stages: against a neutral
        // recipe the full one must move the picture substantially, or the agreement
        // above could be two identically-empty renders.
        var neutral = Recipe()
        neutral.develop.denoise.mode = .off
        let plain = try renderer.renderPreview(source: stub, recipe: neutral,
                                               maxLongEdge: 384, draft: true,
                                               coarseDecode: false)
        guard let p = bytes(plain), p.count == d.count else {
            return XCTFail("neutral render failed")
        }
        var moved = 0
        for i in 0..<d.count { moved = Swift.max(moved, abs(Int(d[i]) - Int(p[i]))) }
        XCTAssertGreaterThan(moved, 20,
            "the full recipe moved the draft by only \(moved)/255 — the stages this "
                + "test exists to lock are not reaching the draft at all")
    }
}
#endif
