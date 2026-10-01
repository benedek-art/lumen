#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class LocalPresenceStrengthTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
    private let plan = RenderPlan(recipe: Recipe(), lutSize: 17)

    private var input: ImageBuffer {
        ImageBuffer(width: 128, height: 128) { u, v in
            let value = 0.18 + 0.04 * sin(2 * .pi * 16 * u) * cos(2 * .pi * 11 * v)
                + 0.015 * sin(2 * .pi * 3 * u)
            return RGB(value * 0.9, value, value * 1.1)
        }
    }

    private func render(_ mask: Mask) throws -> (ImageBuffer, ImageBuffer) {
        let buffer = input
        let ci = buffer.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: buffer.width * 16,
                size: CGSize(width: buffer.width, height: buffer.height),
                format: .RGBAf, colorSpace: nil)
        }
        return (ReferenceRenderer.applyLocalAdjust(buffer, mask: mask, plan: plan,
                                                   space: .rec2020),
                try XCTUnwrap(PipelineRenderer.buffer(from:
                    RenderGraph.applyLocalAdjust(ci, mask: mask, plan: plan,
                        longEdge: buffer.width, lutSize: 17), context: context)))
    }

    private func difference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for y in 4..<a.height - 4 {
            for x in 4..<a.width - 4 {
                XCTAssertTrue(a[x, y].isFinite && b[x, y].isFinite)
                worst = max(worst, a[x, y].maxAbsDifference(b[x, y]))
            }
        }
        return worst
    }

    func testBothRenderersKeepTextureAndClarityLiveAboveOneHundredStrength() throws {
        for texture in [true, false] {
            for sign in [-1.0, 1] {
                var mask = Mask(id: "presence", amount: 100)
                if texture { mask.adjust.texture = sign * 100 }
                else { mask.adjust.clarity = sign * 100 }
                let normal = try render(mask)
                mask.amount = 200
                let exaggerated = try render(mask)
                let cpuDelta = difference(normal.0, exaggerated.0)
                let gpuDelta = difference(normal.1, exaggerated.1)
                print("PRESENCE-STRENGTH texture=\(texture) sign=\(sign) CPU=\(cpuDelta) GPU=\(gpuDelta)")
                XCTAssertGreaterThan(cpuDelta, 1e-5, "CPU strength must not saturate at 100")
                XCTAssertGreaterThan(gpuDelta, 1e-5, "GPU is the existing live-response control")
            }
        }
    }

    func testZeroAndEquivalentBelowLimitCompositionsRemainUnchanged() throws {
        for texture in [true, false] {
            var mask = Mask(id: "presence-control", amount: 0)
            if texture { mask.adjust.texture = 100 }
            else { mask.adjust.clarity = 100 }
            let zero = try render(mask)
            XCTAssertLessThan(difference(zero.0, input), 1e-7)
            XCTAssertLessThan(difference(zero.1, input), 1e-7)
            mask.amount = 50
            let half = try render(mask)
            mask.amount = 100
            if texture { mask.adjust.texture = 50 }
            else { mask.adjust.clarity = 50 }
            let equivalent = try render(mask)
            XCTAssertEqual(half.0.pixels, equivalent.0.pixels)
            XCTAssertEqual(half.1.pixels, equivalent.1.pixels)
        }
    }

    func testGroupMultiplierKeepsExistingTwoHundredAggregateCeiling() throws {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "g", amount: 200)]
        var member = Mask(id: "member", amount: 200)
        member.group = "g"
        member.adjust.texture = 100
        member.adjust.clarity = -100
        recipe.masks = [member]
        let resolved = try XCTUnwrap(RenderPlan(recipe: recipe, lutSize: 17).masks.first)
        XCTAssertEqual(resolved.amount, 400, "recipe composition is retained")
        let group = try render(resolved)
        member.group = nil
        let cap = try render(member)
        XCTAssertEqual(group.0.pixels, cap.0.pixels)
        XCTAssertEqual(group.1.pixels, cap.1.pixels)
    }
}
#endif
