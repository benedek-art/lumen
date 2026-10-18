#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class NeutralAbsoluteWhiteBalanceGPUIdentityTests: XCTestCase {
    func testNeutralAbsoluteWhiteBalancePreservesSignedAndHDRPixels() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "colour kernels unavailable")
        let input = ImageBuffer(width: 12, height: 4) { u, _ in
            if u < 1.0 / 3 { return RGB(-0.01, 0.18, 0.3) }
            if u < 2.0 / 3 { return RGB(1024, 128, 256) }
            return RGB(0.18, 0.3, 0.5)
        }
        let source = input.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: input.width * 16,
                size: CGSize(width: input.width, height: input.height), format: .RGBAf, colorSpace: nil)
        }
        let context = CIContext(options: [.workingColorSpace:
            CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
            .workingFormat: CIFormat.RGBAf])
        for tint: Double? in [nil, 0] {
            var mask = Mask(id: "neutral-kelvin", amount: 100)
            mask.adjust.kelvin = 5500
            mask.adjust.kelvinTint = tint
            var recipe = Recipe()
            recipe.develop.raw.temp = 5500
            recipe.develop.raw.tint = 0
            recipe.masks = [mask]
            let plan = RenderPlan(recipe: recipe, lutSize: 17)
            XCTAssertEqual(plan.balancedNeutral.kelvin, 5500)
            XCTAssertEqual(plan.balancedNeutral.tint, 0)
            for size in [33, 65] {
                let local = LocalPlan(adjust: mask.adjust, scale: 1,
                    whiteAnchorEV: plan.tone.whiteAnchorEV, blackAnchorEV: plan.tone.blackAnchorEV,
                    size: size, globalColor: plan.recipe.develop.color,
                    globalWheels: plan.recipe.look.wheels, balanced: plan.balancedNeutral)
                XCTAssertNil(local.preLUT)
                let output = RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                    longEdge: input.width, lutSize: size)
                let actual = try XCTUnwrap(PipelineRenderer.buffer(from: output, context: context))
                XCTAssertTrue(actual.pixels.allSatisfy { $0.isFinite })
                XCTAssertEqual(actual.pixels, input.pixels,
                    "neutral absolute WB must not clamp through an identity table, cube\(size)")
                let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
                XCTAssertEqual(cpu.pixels, input.pixels)
            }
        }
    }
}
#endif
