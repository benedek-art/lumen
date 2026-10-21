// PickTapParityTests.swift — the global Point Colour / Mixer eyedropper reads the image
// the colour stage actually receives (docs/quality/lanes/WS-02/SPEC.md A1).
//
// `sampleColorStageInput` used to stage with `maskSource: true`, which skips S3 denoise
// and S8 presence — right for a mask's raster, wrong for the colour stage, whose input
// carries both. With Dehaze or Clarity set the stored swatch sat off the pixel S9
// compares. The test builds the expected value from `RenderGraph.colorStageInput(
// maskSource: false)` itself, read over the same window through a context configured as
// the renderer's, and proves it is not vacuous by showing the `maskSource: true` read is
// a different number on the same frame.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class PickTapParityTests: XCTestCase {

    /// The renderer's own context options (`PipelineRenderer.init`), so the expected
    /// value goes through the same half-float intermediates as the sampler's.
    private let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = working
        }
        return CIContext(options: options)
    }()

    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        // `.unspecified`: no decoder produced these numbers (see KernelGoldenTests).
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

    /// Texture everywhere, so Clarity's local contrast has something to move, and a
    /// haze-like lifted floor for Dehaze.
    private func scene(_ width: Int, _ height: Int) -> CIImage {
        let buffer = ImageBuffer(width: width, height: height) { u, v in
            let ripple = 0.08 * sin(u * 60) * cos(v * 45)
            return RGB(0.25 + 0.4 * u + ripple, 0.3 + 0.25 * v - ripple, 0.35 + 0.15 * u * v)
        }
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: nil)
    }

    /// `PipelineRenderer.sampleMean`'s window, restated: the mean of the `2r + 1` square
    /// about a normalized top-down point, read back in linear Rec.2020.
    private func windowMean(_ image: CIImage, x: Double, y: Double, radius: Int) -> RGB? {
        let extent = image.extent
        let px = extent.minX + x * extent.width
        let py = extent.minY + (1 - y) * extent.height
        let side = CGFloat(radius * 2 + 1)
        let rect = CGRect(x: (px - CGFloat(radius)).rounded(.down),
                          y: (py - CGFloat(radius)).rounded(.down),
                          width: side, height: side).intersection(extent)
        let width = Int(rect.width.rounded(.down)), height = Int(rect.height.rounded(.down))
        guard width > 0, height > 0,
              let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        else { return nil }
        let bounds = CGRect(x: rect.origin.x, y: rect.origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: working)
        }
        var sum = RGB(0, 0, 0)
        for i in 0..<(width * height) {
            sum = RGB(sum.r + Double(pixels[i * 4]), sum.g + Double(pixels[i * 4 + 1]),
                      sum.b + Double(pixels[i * 4 + 2]))
        }
        let n = Double(width * height)
        return RGB(sum.r / n, sum.g / n, sum.b / n)
    }

    func testPointColourTapReadsThePresenceAppliedStageInput() throws {
        let input = scene(192, 128)
        let source = StubSource(input)
        var recipe = Recipe()
        recipe.develop.detail.dehaze = 60
        recipe.develop.detail.clarity = 40
        XCTAssertFalse(ColorEngine.needsMeasuredBandHues(recipe.develop.mixer),
                       "the default mixer needs no measured hues — the expected value "
                           + "below passes none")
        let (x, y, radius) = (0.3, 0.6, 2)
        let tap = ColorEngine.SelectionTap.pointColor(index: 0)

        let sampled = try XCTUnwrap(PipelineRenderer().sampleColorStageInput(
            source: source, recipe: recipe, sourceX: x, sourceY: y, tap: tap,
            radius: radius))

        let plan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint, bandMeanHues: nil)
        let engine = ColorEngine(mixer: plan.recipe.develop.mixer,
                                 pointColors: plan.recipe.develop.pointColors,
                                 color: plan.recipe.develop.color,
                                 primaries: plan.recipe.look.primaries,
                                 bw: plan.recipe.look.bw,
                                 bandMeanHues: plan.bandMeanHues)
        func read(maskSource: Bool) throws -> RGB {
            let staged = RenderGraph().colorStageInput(
                input, plan: plan,
                options: RenderGraph.Options(longEdge: 192, maskSource: maskSource))
            let mean = try XCTUnwrap(windowMean(staged.cropped(to: input.extent),
                                                x: x, y: y, radius: radius))
            return engine.selectionInput(mean, for: tap)
        }
        let render = try read(maskSource: false)
        let maskTap = try read(maskSource: true)

        for (got, want, name) in [(sampled.r, render.r, "R"), (sampled.g, render.g, "G"),
                                  (sampled.b, render.b, "B")] {
            XCTAssertEqual(got, want, accuracy: 1e-4,
                           "\(name): the eyedropper read \(sampled), the colour stage "
                               + "receives \(render)")
        }
        let apart = max(abs(render.r - maskTap.r), abs(render.g - maskTap.g),
                        abs(render.b - maskTap.b))
        XCTAssertGreaterThan(apart, 1e-3,
                             "Dehaze +60 and Clarity +40 moved nothing at the sample "
                                 + "point, so this test cannot tell the two taps apart")
    }
}

#endif
