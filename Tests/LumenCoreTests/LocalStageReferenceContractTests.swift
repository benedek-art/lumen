import XCTest
@testable import LumenCore

/// The CPU-reference halves of three local-stage repairs (Astra M03, M05, M11).
///
/// Each of those fixes changed BOTH renderers, but their regression tests live in
/// `LumenPipelineTests`, which compiles on macOS only. On this lane nothing went red
/// when the reference half was substituted back, so a revert of `ReferenceRenderer`
/// alone would have passed every Linux check while breaking CPU/GPU parity. These
/// cases pin the reference renderer on its own, with algebra written out here rather
/// than borrowed from the code under test.
final class LocalStageReferenceContractTests: XCTestCase {

    // MARK: - M03 · the local curve honours the mask's blend mode

    func testLocalCurveHonoursBrightnessOnlyAndColourOnlyBlend() {
        let base = RGB(0.30, 0.18, 0.11)
        let image = ImageBuffer(width: 4, height: 4) { _, _ in base }
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        let curve = CurveSet(r: [[0, 0], [0.5, 0.8], [1, 1]], preserveLuminance: false)
        let space = RGBColorSpace.rec2020

        func run(_ blend: MaskBlend, alpha: Double) -> RGB {
            var mask = Mask(id: "curve")
            mask.blend = blend
            mask.adjust.curve = curve
            return ReferenceRenderer.applyLocalCurves(
                image, alphas: [(mask: mask, alpha: Plane(width: 4, height: 4, fill: alpha))],
                plan: plan, space: space)[1, 1]
        }

        let curved = LocalCurve(curve: curve, amount: 100, white: plan.finishScale,
                                space: space).apply(base)
        let before = space.luminance(base)
        let after = space.luminance(curved)
        XCTAssertGreaterThan(abs(after - before), 0.01, "the fixture must move luminance")
        XCTAssertGreaterThan(abs(curved.r / curved.g - base.r / base.g), 0.1,
                             "the fixture must move chromaticity")

        for alpha in [1.0, 0.6] {
            // Written out independently of `MaskAlgebra.blended`.
            let luminosity = base.mix(base * (after / before), alpha)
            let colour = base.mix(curved * (before / after), alpha)
            let normal = base.mix(curved, alpha)
            XCTAssertLessThan(run(.luminosity, alpha: alpha).maxAbsDifference(luminosity), 1e-6,
                              "Brightness-only curve, alpha \(alpha)")
            XCTAssertLessThan(run(.color, alpha: alpha).maxAbsDifference(colour), 1e-6,
                              "Colour-only curve, alpha \(alpha)")
            XCTAssertLessThan(run(.normal, alpha: alpha).maxAbsDifference(normal), 1e-6,
                              "Normal curve, alpha \(alpha)")
        }
    }

    // MARK: - M05 · negative local Sharpness is frame-denominated

    private func stripes(_ width: Int) -> ImageBuffer {
        ImageBuffer(width: width, height: 16) { u, _ in
            RGB(gray: 0.18 + 0.03 * sin(2 * .pi * 128 * u))
        }
    }

    private func contrast(_ buffer: ImageBuffer) -> Double {
        let values = (buffer.width / 4..<buffer.width * 3 / 4).map {
            buffer[$0, buffer.height / 2].r
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                        / Double(values.count))
    }

    func testNegativeLocalSharpnessSoftensTheSameSceneDetailAtEveryRenderSize() {
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        var mask = Mask(id: "soften")
        mask.adjust.sharpness = -100
        var retention: [Double] = []
        for width in [512, 1024, 2048, 4096] {
            let input = stripes(width)
            let out = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan,
                                                         space: .rec2020)
            retention.append(contrast(out) / contrast(input))
        }
        // 0.06, not tighter: at 512 px the 0.5 px sigma is sampled by a discrete
        // kernel and retains 0.79 against 0.73 above it. The defect this guards spread
        // these four values from near 0 to near 1.
        XCTAssertLessThan(retention.max()! - retention.min()!, 0.06,
                          "scene-contrast retention per render size: \(retention)")
        XCTAssertLessThan(retention.max()!, 0.9, "the softening must be visible: \(retention)")

        // The 2560 px reference keeps the original 2.5 px look exactly.
        let reference = stripes(2560)
        XCTAssertEqual(ReferenceRenderer.applyLocalAdjust(reference, mask: mask, plan: plan,
                                                          space: .rec2020).pixels,
                       SpatialOps.gaussianBlur(reference, sigma: 2.5).pixels)
    }

    // MARK: - M11 · mask Strength above 100 still scales Texture and Clarity

    func testTextureAndClarityKeepRespondingAboveOneHundredStrength() {
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        let input = ImageBuffer(width: 96, height: 96) { u, v in
            let value = 0.18 + 0.04 * sin(2 * .pi * 16 * u) * cos(2 * .pi * 11 * v)
                + 0.015 * sin(2 * .pi * 3 * u)
            return RGB(value * 0.9, value, value * 1.1)
        }
        for texture in [true, false] {
            for sign in [-1.0, 1] {
                var mask = Mask(id: "presence", amount: 100)
                if texture { mask.adjust.texture = sign * 100 }
                else { mask.adjust.clarity = sign * 100 }
                let normal = ReferenceRenderer.applyLocalAdjust(input, mask: mask,
                                                                plan: plan, space: .rec2020)
                mask.amount = 200
                let doubled = ReferenceRenderer.applyLocalAdjust(input, mask: mask,
                                                                 plan: plan, space: .rec2020)
                var worst = 0.0
                for y in 0..<input.height {
                    for x in 0..<input.width {
                        worst = max(worst, normal[x, y].maxAbsDifference(doubled[x, y]))
                    }
                }
                XCTAssertGreaterThan(worst, 1e-5,
                                     "texture=\(texture) sign=\(sign): Strength 200 equals 100")
            }
        }
    }
}
