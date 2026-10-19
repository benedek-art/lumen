#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// A zero adjustment multiplier must bypass the LUT domain altogether. This is a
/// numerical identity contract, including valid extended scene-linear channels;
/// it does not choose an active grading look or change its existing approximation.
final class ZeroAmountLocalGradeTests: XCTestCase {
    private var recipe: Recipe {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        return recipe
    }

    private func mask(amount: Double) -> Mask {
        var mask = Mask(id: "zero-grade", amount: amount)
        var wheels = GradingWheels()
        wheels.global = Wheel(hue: 123, sat: 0.4, lum: 0.1)
        mask.adjust.wheels = wheels
        return mask
    }

    private func localPlan(_ mask: Mask, plan: RenderPlan, size: Int = 17) -> LocalPlan {
        LocalPlan(adjust: mask.adjust, scale: Num.clamp(mask.amount, 0, 200) / 100,
                  whiteAnchorEV: plan.tone.whiteAnchorEV,
                  blackAnchorEV: plan.tone.blackAnchorEV, size: size,
                  globalColor: plan.recipe.develop.color,
                  globalWheels: plan.recipe.look.wheels, balanced: plan.balancedNeutral)
    }

    func testZeroAmountBypassesAllLocalColourTablesWhilePositiveAmountStaysLive() {
        let plan = RenderPlan(recipe: recipe, lutSize: 17)
        let zero = localPlan(mask(amount: 0), plan: plan)
        XCTAssertTrue(zero.isIdentity)
        XCTAssertNil(zero.preLUT)
        XCTAssertTrue(zero.postLUT == nil, "an identity LUT still clamps its input domain")
        XCTAssertTrue(zero.colorStage.isIdentity)
        let active = localPlan(mask(amount: 100), plan: plan)
        XCTAssertFalse(active.isIdentity)
        XCTAssertNotNil(active.postLUT, "active saved grading must retain its existing path")
    }

    /// Portable causal witness using the actual LocalPlan and core LUT/shaper. It
    /// evaluates the same bounded table domain without claiming GPU execution.
    func testZeroAmountTablePathPreservesExtendedChannels() {
        let plan = RenderPlan(recipe: recipe, lutSize: 17)
        let zero = localPlan(mask(amount: 0), plan: plan)
        for pixel in [RGB(-0.01, 0.18, 0.3), RGB(0.2, 0.3, -0.015), RGB(1024, 128, 256)] {
            let input = ImageBuffer(width: 4, height: 4) { _, _ in pixel }
            let reference = ReferenceRenderer.applyLocalAdjust(input, mask: mask(amount: 0),
                                                               plan: plan, space: .rec2020)
            XCTAssertEqual(reference.pixels, input.pixels)
            let mapped: RGB
            if let table = zero.postLUT {
                mapped = LumenLog.decode(table.sample(LumenLog.encode(pixel)))
            } else {
                mapped = pixel
            }
            XCTAssertEqual(mapped.maxAbsDifference(pixel), 0,
                           "zero strength must not clamp through an unnecessary identity table")
        }
    }

    func testBothRenderersPreserveExtendedPixelsAtZeroAmount() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "colour kernels unavailable")
        let patches = [RGB(-0.01, 0.18, 0.30), RGB(0.18, -0.02, 0.40),
                       RGB(0.15, 0.30, -0.015), RGB(0.18, 0.35, 0.70),
                       RGB(1024, 128, 256)]
        let input = ImageBuffer(width: patches.count * 4, height: 4) { u, _ in
            patches[min(Int(u * Double(patches.count)), patches.count - 1)]
        }
        let source = input.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: input.width * 16,
                    size: CGSize(width: input.width, height: input.height),
                    format: .RGBAf, colorSpace: nil)
        }
        let context = CIContext(options: [.workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        let plan = RenderPlan(recipe: recipe, lutSize: 17)
        for size in [LUT3D.interactiveSize, LUT3D.exportSize] {
            let off = mask(amount: 0)
            let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: off, plan: plan, space: .rec2020)
            XCTAssertEqual(cpu.pixels, input.pixels, "independent reference establishes zero identity")
            let adjusted = RenderGraph.applyLocalAdjust(source, mask: off, plan: plan,
                longEdge: input.width, lutSize: size)
            let gpu = try XCTUnwrap(PipelineRenderer.buffer(from: adjusted, context: context))
            XCTAssertEqual(gpu.pixels, input.pixels,
                           "zero Amount must bypass shaper/cube even for negative and HDR values")
            // Also test the actual S11 composite, rather than assuming an unchanged
            // adjustment remains unchanged after soft-alpha/blend-mode arithmetic.
            for mode: MaskBlend in [.normal, .luminosity, .color] {
                for alpha in [0.25, 0.75] {
                    var compositedMask = off
                    compositedMask.blend = mode
                    var maskedRecipe = recipe
                    maskedRecipe.masks = [compositedMask]
                    let maskedPlan = RenderPlan(recipe: maskedRecipe, lutSize: size)
                    let plane = Plane(width: input.width, height: input.height, fill: alpha)
                    let cpuComposite = ReferenceRenderer.applyMasks(input, plan: maskedPlan,
                        alphas: [(mask: compositedMask, alpha: plane)], space: .rec2020)
                    XCTAssertEqual(cpuComposite.pixels, input.pixels,
                                   "zero-strength CPU composite must preserve the input")
                    let alphaImage = CIImage(color: CIColor(red: alpha, green: alpha, blue: alpha))
                        .cropped(to: source.extent)
                    var graph = RenderGraph()
                    graph.maskImages[compositedMask.id] = alphaImage
                    let composed = graph.applyLocal(source, plan: maskedPlan,
                        options: RenderGraph.Options(longEdge: input.width, lutSize: size))
                    let gpuComposite = try XCTUnwrap(PipelineRenderer.buffer(from: composed, context: context))
                    XCTAssertEqual(gpuComposite.pixels, input.pixels,
                                   "zero-strength S11 composite: mode=\(mode), alpha=\(alpha), cube=\(size)")
                }
            }
        }
    }

    func testGroupZeroKeepsDonorSelectionAndResolvesItsAdjustmentToIdentity() throws {
        var recipe = self.recipe
        recipe.maskGroups = [MaskGroup(id: "off-group", name: "off", amount: 0)]
        var donor = mask(amount: 100)
        donor.group = "off-group"
        var gradient = MaskComponent(op: .add, kind: .linear)
        gradient.line = [0, 0.5, 1, 0.5]
        donor.components = [gradient]
        var reference = MaskComponent(op: .add, kind: .maskRef)
        reference.maskRef = donor.id
        let borrower = Mask(id: "borrower", components: [reference])
        recipe.masks = [donor, borrower]
        let plan = RenderPlan(recipe: recipe, lutSize: 17)
        let resolved = try XCTUnwrap(plan.masks.first { $0.id == donor.id })
        XCTAssertEqual(resolved.amount, 0)
        XCTAssertTrue(localPlan(resolved, plan: plan).isIdentity)
        let selected = MaskRaster.combine(mask: borrower, size: (width: 24, height: 8),
                                          masks: plan.allMasks)
        let direct = MaskRaster.combine(mask: donor, size: (width: 24, height: 8))
        XCTAssertEqual(selected.values, direct.values,
                       "zero adjustment strength must not remove a referenced selection")
        XCTAssertGreaterThan(selected.values.max() ?? 0, 0.9)
        XCTAssertLessThan(selected.values.min() ?? 1, 0.1)
    }
}
#endif
