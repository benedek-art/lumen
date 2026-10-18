#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Independent flat-quadrant donor colours make a painted clone's centre an exact
/// known colour. This tests the public pickers, not just StrokeHeal/graph parity.
final class PaintedRetouchPickerTests: XCTestCase {
    private let target = RGB(0.5, 0.125, 0.0625)
    private let donor = RGB(0.0625, 0.5, 0.125)
    private let spotDonor = RGB(0.125, 0.0625, 0.5)

    private final class PaintedPickerSource: ImageSource {
        let url = URL(fileURLWithPath: "/fixture/painted-picker.tif")
        let nativePixelSize = (width: 256, height: 256)
        let nativeLongEdge = 256.0
        let asShotTemperature = 5500.0
        let asShotTint = 0.0
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        let image: CIImage
        init(_ input: ImageBuffer) {
            image = input.pixels.withUnsafeBytes {
                CIImage(bitmapData: Data($0), bytesPerRow: input.width * 16,
                    size: CGSize(width: input.width, height: input.height),
                    format: .RGBAf, colorSpace: nil)
            }
        }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
    }

    private var input: ImageBuffer {
        ImageBuffer(width: 256, height: 256) { u, v in
            if u < 0.5 { return target }
            return v < 0.5 ? spotDonor : donor
        }
    }

    private func fixture(withSpot: Bool) throws -> (Recipe, String, BrushStrokeSet) {
        let stroke = BrushStroke(points: [BrushPoint(x: 0.25, y: 0.25)], size: 0.20,
            feather: 0, density: 100, retouch: StrokeRetouch(mode: .clone, dx: 0.5, dy: 0.5))
        let set = BrushStrokeSet(strokes: [stroke])
        let ref = try set.blobRef()
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail.capture.auto = false
        recipe.develop.heal.strokesRef = ref
        recipe.develop.heal.count = 1
        if withSpot {
            recipe.develop.heal.spots = [HealSpot(id: "before-paint", mode: .clone,
                x: 0.25, y: 0.25, sourceX: 0.75, sourceY: 0.25,
                radius: 0.08, feather: 0, opacity: 100)]
        }
        var local = Mask(id: "local-colour")
        local.adjust.exposure = 1
        recipe.masks = [local]
        return (recipe, ref, set)
    }

    private func equal(_ value: RGB?, _ expected: RGB, label: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(value, label, file: file, line: line)
        XCTAssertTrue(actual.isFinite, file: file, line: line)
        // Same bound as the existing painted-retouch GPU/reference parity contract.
        XCTAssertLessThan(actual.maxAbsDifference(expected), 1e-3, label, file: file, line: line)
    }

    /// Same known 5x5 native target as the public pickers. Output is Float32, but
    /// working intermediates stay at the shipping RGBAh precision, explicitly.
    private func oldExpressionSample(_ image: CIImage) -> RGB {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let context = CIContext(options: [.workingColorSpace: working,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
        var pixels = [Float](repeating: 0, count: 5 * 5 * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: 5 * 16,
                bounds: CGRect(x: 62, y: 190, width: 5, height: 5),
                format: .RGBAf, colorSpace: working)
        }
        var sum = RGB.zero
        for index in 0..<25 {
            sum = sum + RGB(Double(pixels[index * 4]), Double(pixels[index * 4 + 1]),
                            Double(pixels[index * 4 + 2]))
        }
        return sum / 25
    }

    func testPaintedCloneReachesGlobalMaskAndLocalSwatchPickersAfterSpots() throws {
        try XCTSkipUnless(KernelLibrary.strokeRetouchAvailable && KernelLibrary.retouchAvailable
                          && KernelLibrary.isAvailable, "retouch/colour kernels unavailable")
        for withSpot in [false, true] {
            let (recipe, ref, set) = try fixture(withSpot: withSpot)
            let source = PaintedPickerSource(input)
            let sets = [ref: set]
            // The clone centre is fully covered, and its source is the flat green
            // quadrant. A preceding spot samples blue and must be replaced by paint.
            let cpu = StrokeHeal.apply(input, strokes: set.strokes)
            XCTAssertEqual(cpu[64, 64], donor)
            // Verbatim pre-fix graph expressions: empty healStrokes despite the
            // recipe's paint reference. This is an executed old-expression witness
            // when run on macOS, not execution of an older released application.
            let plan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                  asShotTint: source.asShotTint)
            let options = RenderGraph.Options(longEdge: 256, maskSource: true)
            let oldColor = RenderGraph().colorStageInput(source.image, plan: plan, options: options)
            let oldMask = RenderGraph().localStageInput(source.image, plan: plan, options: options)
            let prepaint = withSpot ? spotDonor : target
            for (name, image) in [("color", oldColor), ("mask", oldMask)] {
                let old = oldExpressionSample(image)
                try equal(old, prepaint, label: "old empty-stroke graph reads prepaint pixels")
                XCTAssertGreaterThan(old.maxAbsDifference(donor), 0.1,
                                     "old expression must demonstrably disagree with the painted donor")
                print("PAINTED-PICK-OLD stage=\(name) precedingSpot=\(withSpot) donorDifference=\(old.maxAbsDifference(donor))")
            }
            let renderer = PipelineRenderer()
            try equal(renderer.sampleColorStageInput(source: source, recipe: recipe,
                sourceX: 0.25, sourceY: 0.25, tap: .pointColor(index: 0), strokeSets: sets),
                donor, label: "global picker omitted painted clone; preceding spot=\(withSpot)")
            try equal(renderer.sampleMaskStageInput(source: source, recipe: recipe,
                sourceX: 0.25, sourceY: 0.25, strokeSets: sets),
                donor, label: "mask range picker omitted painted clone; preceding spot=\(withSpot)")
            try equal(renderer.sampleMaskStageInput(source: source, recipe: recipe,
                sourceX: 0.25, sourceY: 0.25, pointColorSwatch: ("local-colour", 0), strokeSets: sets),
                donor * 2, label: "mask swatch must apply its own exposure after painted clone")
        }
    }

    func testGlobalColourPickerUsesNormalPresenceStageWhileMaskProxyStaysDistinct() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "colour/presence kernels unavailable")
        // Same veiled gradient family as the existing Dehaze hue-preservation
        // regression. Neither grain, masks nor sensor noise are part of this oracle.
        let field = ImageBuffer(width: 256, height: 256) { u, v in
            RGB(0.26 + 0.10 * u, 0.34 + 0.06 * v, 0.52 + 0.06 * u)
        }
        let source = PaintedPickerSource(field)
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail.capture.auto = false
        recipe.develop.detail.dehaze = 35
        let renderer = PipelineRenderer()
        let plan = renderer.previewPlan(source: source, recipe: recipe, draft: false, softProof: nil)
        // Actual normal S9 input is the oracle. The old public picker expression
        // deliberately skipped S8 through maskSource:true, though it was not a mask.
        let normalStage = RenderGraph().colorStageInput(source.image, plan: plan,
            options: RenderGraph.Options(longEdge: 256, maskSource: false))
        let oldStage = RenderGraph().colorStageInput(source.image, plan: plan,
            options: RenderGraph.Options(longEdge: 256, maskSource: true))
        let normal = oldExpressionSample(normalStage)
        let old = oldExpressionSample(oldStage)
        let stageDifference = normal.maxAbsDifference(old)
        XCTAssertGreaterThan(stageDifference, 1e-3,
                             "fixture must distinguish the actual S9 input from the skipped presence stage")
        let picked = renderer.sampleColorStageInput(source: source, recipe: recipe,
            sourceX: 0.25, sourceY: 0.25, tap: .pointColor(index: 0))
        try equal(picked, normal, label: "global picker must sample after normal S3/S8")
        // Mask selections intentionally retain their existing reduced proxy-stage
        // semantics; fixing the global picker must not silently change mask rasters.
        try equal(renderer.sampleMaskStageInput(source: source, recipe: recipe,
            sourceX: 0.25, sourceY: 0.25), old,
            label: "mask proxy convention must remain unchanged")
        print("SPATIAL-PICK-OLD dehaze=35 old-normal-difference=\(stageDifference)")
    }

    func testAbsentPaintedPayloadKeepsExistingUnpaintedPickerBehaviour() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "colour kernels unavailable")
        let (recipe, _, _) = try fixture(withSpot: false)
        let source = PaintedPickerSource(input)
        let renderer = PipelineRenderer()
        try equal(renderer.sampleColorStageInput(source: source, recipe: recipe,
            sourceX: 0.25, sourceY: 0.25, tap: .pointColor(index: 0)), target,
            label: "default empty payload must keep existing source behaviour")
        try equal(renderer.sampleMaskStageInput(source: source, recipe: recipe,
            sourceX: 0.25, sourceY: 0.25), target,
            label: "unresolved paint must not borrow unrelated pixels")
    }
}
#endif
