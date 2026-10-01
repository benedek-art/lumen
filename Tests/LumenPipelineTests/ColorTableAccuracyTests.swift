#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Accuracy against the intended operations, NOT parity with another sampled LUT.
/// AI-03 remains unresolved. Only the four measured fidelity assertions below are
/// expected failures; malformed inputs, unavailable/zero GPU output and nonfinite
/// pixels are ordinary failures. Strict expected failures force revisiting this
/// quarantine when a repair actually reaches the unchanged three-code bound.
final class ColorTableAccuracyTests: XCTestCase {
    func testAquaLuminancePositiveInputAndOutput() throws {
        var recipe = Recipe()
        recipe.develop.mixer.bands[4].lum = -100
        try check(recipe, input: RGB(0.38413364324424248, 0.59591710513566343,
                                    0.64828909901873966))
    }

    func testSaturationPositiveInputAndOutput() throws {
        var recipe = Recipe()
        recipe.develop.color.saturation = 100
        try check(recipe, input: RGB(0.78994447795661316, 0.51750730037644888,
                                    0.21031789665386302))
    }

    private func check(_ original: Recipe, input: RGB) throws {
        var recipe = original
        recipe.develop.denoise.mode = .off
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        let sourceBytes: [Float] = [Float(input.r), Float(input.g), Float(input.b), 1]
        let data = sourceBytes.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = CIImage(bitmapData: data, bytesPerRow: 16,
                             size: CGSize(width: 1, height: 1), format: .RGBAf,
                             colorSpace: space)
        let colour = ColorEngine(mixer: recipe.develop.mixer,
                                 pointColors: recipe.develop.pointColors,
                                 color: recipe.develop.color, primaries: recipe.look.primaries,
                                 bw: recipe.look.bw)
        let grade = GradeEngine(wheels: recipe.look.wheels,
                                printerLights: recipe.look.printerLights)
        XCTAssertGreaterThan(input.minComponent, 0)
        XCTAssertGreaterThan(grade.apply(colour.apply(input)).minComponent, 0,
                             "This is not the separate negative-domain clipping defect")
        for size in [33, 65] {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            let output = RenderGraph().build(source, plan: plan,
                                              options: RenderGraph.Options(longEdge: 1))
            var bytes = [Float](repeating: 0, count: 4)
            context.render(output, toBitmap: &bytes, rowBytes: 16, bounds: source.extent,
                           format: .RGBAf, colorSpace: space)
            let actual = RGB(Double(bytes[0]), Double(bytes[1]), Double(bytes[2]))
            let exact = plan.exactColor(input)
            XCTAssertTrue(actual.isFinite)
            XCTAssertGreaterThan(actual.maxComponent, 0.01, "Detect an unavailable GPU")
            // Encoded Rec2020-channel code equivalents, not DeltaE or a final sRGB
            // primary conversion. A tight accuracy guard, not a copied LUT golden.
            let error = 255 * TransferFunction.srgb.encode(actual)
                .maxAbsDifference(TransferFunction.srgb.encode(exact))
            print("COLOR_ACCURACY size=\(size) input=\(input) exact=\(exact) actual=\(actual) codeError=\(error)")
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            XCTExpectFailure("Unresolved AI-03: \(size)-cube colour fidelity; see EXECUTION-04-colour-lut.md",
                             options: options) {
                XCTAssertLessThan(error, 3, "\(size)-cube: intended colour versus actual GPU")
            }
        }
    }
}
#endif
