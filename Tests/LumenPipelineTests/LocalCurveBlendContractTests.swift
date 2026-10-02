#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Exercise S15b itself: testing the earlier local-adjustment pass cannot prove
/// that a later curve honours the same user-selected mask blend contract.
final class LocalCurveBlendContractTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
    private let base = RGB(0.30, 0.18, 0.11)

    private var curves: [CurveSet] {
        [CurveSet(r: [[0, 0], [0.5, 0.8], [1, 1]], preserveLuminance: false),
         CurveSet(luma: [[0, 0], [0.5, 0.7], [1, 1]], preserveLuminance: false),
         CurveSet(parametric: ParametricCurve(lights: 35), preserveLuminance: false)]
    }

    /// Independent blend algebra. This does not call MaskAlgebra.blended or either
    /// renderer's composite helper. Fixtures remain above the zero-luminance floor.
    private func expected(_ input: RGB, mask: Mask, alpha: Double, white: Double) -> RGB {
        let curved = LocalCurve(curve: mask.adjust.curve, amount: mask.amount,
                                white: white).apply(input)
        return blendTarget(input, curved: curved, mode: mask.blend, alpha: alpha)
    }

    private func blendTarget(_ input: RGB, curved: RGB, mode: MaskBlend, alpha: Double) -> RGB {
        let before = RGBColorSpace.rec2020.luminance(input)
        let after = RGBColorSpace.rec2020.luminance(curved)
        let result: RGB
        switch mode {
        case .normal: result = curved
        case .luminosity: result = input * (after / before)
        case .color: result = curved * (before / after)
        }
        return input.mix(result, alpha)
    }

    private func run(_ masks: [Mask], alpha: [Double]) throws
        -> (cpu: RGB, gpu: RGB, expected: RGB, gpuExpected: RGB) {
        let input = ImageBuffer(width: 4, height: 4) { _, _ in self.base }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.masks = masks
        let plan = RenderPlan(recipe: recipe, lutSize: 65)
        let planes = zip(masks, alpha).map { mask, value in
            (mask: mask, alpha: Plane(width: 4, height: 4, fill: value))
        }
        let cpu = ReferenceRenderer.applyLocalCurves(input, alphas: planes,
            plan: plan, space: .rec2020)[0, 0]
        let actual = try gpu(input, masks: masks, planes: planes.map(\.alpha), plan: plan)
        XCTAssertTrue(cpu.isFinite && actual.isFinite)
        XCTAssertGreaterThan(actual.maxComponent, 0.01, "GPU execution must produce real pixels")
        var target = input[0, 0]
        var gpuTarget = input[0, 0]
        for (mask, value) in zip(masks, alpha) {
            target = expected(target, mask: mask, alpha: value, white: plan.finishScale)
            // Isolate compositing from the unchanged local-curve LUT approximation.
            // Its normal/unmasked output is measured independently, then subjected
            // to the intended blend algebra above. This is NOT a LUT fidelity gate.
            var normal = mask
            normal.blend = .normal
            var controlRecipe = recipe
            controlRecipe.masks = [normal]
            let controlPlan = RenderPlan(recipe: controlRecipe, lutSize: 65)
            let controlInput = ImageBuffer(width: 4, height: 4) { _, _ in gpuTarget }
            let curved = try gpu(controlInput, masks: [normal],
                planes: [Plane(width: 4, height: 4, fill: 1)], plan: controlPlan)
            gpuTarget = blendTarget(gpuTarget, curved: curved, mode: mask.blend, alpha: value)
        }
        return (cpu, actual, target, gpuTarget)
    }

    private func gpu(_ input: ImageBuffer, masks: [Mask], planes: [Plane],
                     plan: RenderPlan) throws -> RGB {
        let source = input.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: 64,
                    size: CGSize(width: 4, height: 4), format: .RGBAf, colorSpace: nil)
        }
        var graph = RenderGraph()
        for (mask, plane) in zip(masks, planes) {
            graph.maskImages[mask.id] = try XCTUnwrap(PipelineRenderer.image(
                from: plane, targetExtent: source.extent))
        }
        let rendered = graph.applyLocalCurves(source, plan: plan,
            options: RenderGraph.Options(longEdge: 4, lutSize: 65))
        return try XCTUnwrap(PipelineRenderer.buffer(from: rendered, context: context))[0, 0]
    }

    func testAllCurveKindsHonourBlendBeforePartialAlphaAndStrength() throws {
        for (index, curve) in curves.enumerated() {
            for mode in [MaskBlend.normal, .luminosity, .color] {
                for amount in [50.0, 100, 200] {
                    var mask = Mask(id: "curve", amount: amount)
                    mask.blend = mode
                    mask.adjust.curve = curve
                    let result = try run([mask], alpha: [0.6])
                    let label = "curve=\(index), mode=\(mode), amount=\(amount)"
                    XCTAssertLessThan(result.cpu.maxAbsDifference(result.expected), 1e-6, label)
                    XCTAssertLessThan(result.gpu.maxAbsDifference(result.gpuExpected), 1e-6, label)
                }
            }
        }
    }

    func testBrightnessOnlyPreservesChromaticityAndColourOnlyPreservesLuminance() throws {
        for mode in [MaskBlend.luminosity, .color] {
            var mask = Mask(id: "invariant")
            mask.blend = mode
            mask.adjust.curve = curves[0]
            let result = try run([mask], alpha: [1])
            for pixel in [result.cpu, result.gpu] {
                if mode == .luminosity {
                    XCTAssertEqual(pixel.r / pixel.g, base.r / base.g, accuracy: 0.001)
                    XCTAssertEqual(pixel.b / pixel.g, base.b / base.g, accuracy: 0.001)
                } else {
                    XCTAssertEqual(RGBColorSpace.rec2020.luminance(pixel),
                                   RGBColorSpace.rec2020.luminance(base), accuracy: 1e-6)
                }
            }
        }
    }

    func testZeroAlphaZeroAmountAndIdentityCurvesPreserveInput() throws {
        var mask = Mask(id: "neutral")
        mask.blend = .color
        mask.adjust.curve = curves[0]
        for (amount, alpha, curve) in [(100.0, 0.0, curves[0]),
                                      (0.0, 1.0, curves[0]), (100.0, 1.0, CurveSet())] {
            mask.amount = amount
            mask.adjust.curve = curve
            let result = try run([mask], alpha: [alpha])
            XCTAssertLessThan(result.cpu.maxAbsDifference(base), 1e-7)
            XCTAssertLessThan(result.gpu.maxAbsDifference(base), 1e-7)
        }
    }

    func testStackedCurvesBlendAgainstTheirOwnStageInput() throws {
        var first = Mask(id: "first")
        first.blend = .luminosity
        first.adjust.curve = curves[0]
        var second = Mask(id: "second")
        second.blend = .color
        second.adjust.curve = CurveSet(b: [[0, 0], [0.5, 0.75], [1, 1]],
                                      preserveLuminance: false)
        let result = try run([first, second], alpha: [0.65, 0.4])
        XCTAssertLessThan(result.cpu.maxAbsDifference(result.expected), 1e-6)
        XCTAssertLessThan(result.gpu.maxAbsDifference(result.gpuExpected), 1e-6)
    }
}
#endif
