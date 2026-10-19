#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class LocalWhiteBalanceExactMatrixTests: XCTestCase {
    private let patches = [RGB(-0.01, 0.18, 0.3), RGB(0.18, 0.3, 0.5), RGB(1024, 128, 256)]
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
    private func input() -> ImageBuffer {
        ImageBuffer(width: 12, height: 4) { u, _ in self.patches[min(Int(u * 3), 2)] }
    }
    private func image(_ buffer: ImageBuffer) -> CIImage {
        let bytes = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: bytes, bytesPerRow: buffer.width * 16,
            size: CGSize(width: buffer.width, height: buffer.height), format: .RGBAf, colorSpace: nil)
    }
    private func read(_ image: CIImage) throws -> ImageBuffer {
        try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
    }
    private func mask(_ mode: String, amount: Double, contrast: Double = 0) -> Mask {
        var mask = Mask(id: "exact-wb", amount: amount)
        if mode == "absolute" { mask.adjust.kelvin = 3200; mask.adjust.kelvinTint = 17 }
        else { mask.adjust.temp = 20; mask.adjust.tint = 13 }
        mask.adjust.contrast = contrast
        return mask
    }
    private func plan(_ mask: Mask, groups: [MaskGroup] = []) -> RenderPlan {
        var recipe = Recipe(); recipe.develop.raw.temp = 5500; recipe.develop.raw.tint = 0
        recipe.masks = [mask]
        recipe.maskGroups = groups
        return RenderPlan(recipe: recipe, lutSize: 17)
    }
    /// Independent row-dot-product oracle, not matrix.apply, LUT.sample or CPU render.
    private func multiply(_ m: Mat3, _ c: RGB) -> RGB {
        RGB(m.m[0][0] * c.r + m.m[0][1] * c.g + m.m[0][2] * c.b,
            m.m[1][0] * c.r + m.m[1][1] * c.g + m.m[1][2] * c.b,
            m.m[2][0] * c.r + m.m[2][1] * c.g + m.m[2][2] * c.b)
    }
    private func local(_ mask: Mask, _ plan: RenderPlan, size: Int) -> LocalPlan {
        LocalPlan(adjust: mask.adjust, scale: mask.amount / 100,
            whiteAnchorEV: plan.tone.whiteAnchorEV, blackAnchorEV: plan.tone.blackAnchorEV,
            size: size, globalColor: plan.recipe.develop.color,
            globalWheels: plan.recipe.look.wheels, balanced: plan.balancedNeutral)
    }

    func testWhiteBalanceOnlyMatchesIndependentSignedInteriorHDRMatrixAndAlpha() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = input(), source = image(input)
        XCTAssertEqual(try read(source).pixels, input.pixels)
        for axis in ["mask", "group"] { for mode in ["relative", "absolute"] { for amount in [0.0, 1e-8, 1.0, 25.0, 50.0, 100.0, 200.0] {
            var original = mask(mode, amount: axis == "mask" ? amount : 100)
            let groups: [MaskGroup]
            if axis == "group" {
                original.group = "exact-wb-group"
                groups = [MaskGroup(id: "exact-wb-group", amount: amount)]
            } else { groups = [] }
            let plan = plan(original, groups: groups)
            let mask = try XCTUnwrap(plan.masks.first)
            XCTAssertEqual(mask.amount, amount, "mask and group must resolve the same strength")
            let balance = ReferenceRenderer.LocalWhiteBalance.resolve(mask.adjust,
                amount: amount / 100, balanced: plan.balancedNeutral, space: .rec2020)
            let expected = input.map { multiply(balance.matrix, $0) }
            let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
            for size in [33, 65] {
                let label = "\(axis), \(mode), amount=\(amount), cube=\(size)"
                let actual = try read(RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                    longEdge: input.width, lutSize: size))
                let global = try read(RenderGraph.applyMatrix(source, balance.matrix))
                var maximum = 0.0, cpuMaximum = 0.0, globalMaximum = 0.0
                for y in 0..<input.height { for x in 0..<input.width {
                    XCTAssertTrue(actual[x, y].isFinite, label)
                    XCTAssertTrue(global[x, y].isFinite, label)
                    maximum = max(maximum, actual[x, y].maxAbsDifference(expected[x, y]))
                    cpuMaximum = max(cpuMaximum, actual[x, y].maxAbsDifference(cpu[x, y]))
                    globalMaximum = max(globalMaximum, global[x, y].maxAbsDifference(expected[x, y]))
                } }
                XCTAssertLessThanOrEqual(maximum, 1e-3, label + " independent matrix")
                XCTAssertLessThanOrEqual(cpuMaximum, 1e-3, label + " direct CPU")
                XCTAssertLessThanOrEqual(globalMaximum, 1e-3, label + " global matrix")
                if amount == 0 { XCTAssertEqual(actual.pixels, input.pixels, label) }
                for alpha in [0.0, 0.25, 0.75, 1.0] {
                    let scalar = ImageBuffer(width: input.width, height: input.height) { _, _ in RGB(gray: alpha) }
                    let alphaImage = image(scalar)
                    XCTAssertEqual(try read(alphaImage)[2, 1].r, alpha)
                    var graph = RenderGraph(); graph.maskImages[mask.id] = alphaImage
                    let composed = try read(graph.applyLocal(source, plan: plan,
                        options: RenderGraph.Options(longEdge: input.width, lutSize: size)))
                    var error = 0.0
                    for y in 0..<input.height { for x in 0..<input.width {
                        XCTAssertTrue(composed[x, y].isFinite, label)
                        let value = input[x, y] * (1 - alpha) + expected[x, y] * alpha
                        error = max(error, composed[x, y].maxAbsDifference(value))
                    } }
                    XCTAssertLessThanOrEqual(error, 1e-3, label + " alpha=\(alpha)")
                    if alpha == 0 || amount == 0 { XCTAssertEqual(composed.pixels, input.pixels, label) }
                }
            }
        } } }
        // A linear RGB matrix also acts on premultiplied storage linearly:
        // M(alpha*c) = alpha*M(c), with alpha itself unchanged. Exercise signed
        // nonopaque data, not only opaque photographs, through the shared helper.
        let probe = mask("relative", amount: 1)
        let balance = ReferenceRenderer.LocalWhiteBalance.resolve(probe.adjust,
            amount: 0.01, balanced: plan(probe).balancedNeutral, space: .rec2020)
        for alpha in [0.25, 0.75] {
            var premultiplied = input
            for y in 0..<input.height { for x in 0..<input.width {
                premultiplied[x, y] = input[x, y] * alpha
                premultiplied.pixels[premultiplied.index(x, y) + 3] = Float(alpha)
            } }
            let source = image(premultiplied)
            XCTAssertEqual(try read(source).pixels, premultiplied.pixels)
            let actual = try read(RenderGraph.applyMatrix(source, balance.matrix))
            var error = 0.0
            for y in 0..<input.height { for x in 0..<input.width {
                XCTAssertTrue(actual[x, y].isFinite)
                error = max(error, actual[x, y].maxAbsDifference(multiply(balance.matrix, premultiplied[x, y])))
                XCTAssertEqual(actual.pixels[actual.index(x, y) + 3], Float(alpha))
            } }
            XCTAssertLessThanOrEqual(error, 1e-3, "premultiplied RGBA alpha=\(alpha)")
        }
    }

    func testNeutralAndZeroBalanceRetainExactIdentity() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = input(), source = image(input)
        for size in [33, 65] {
            var neutral = Mask(id: "neutral", amount: 100)
            neutral.adjust.kelvin = 5500; neutral.adjust.kelvinTint = 0
            let cases = [neutral, mask("relative", amount: 0), mask("absolute", amount: 0)]
            for mask in cases {
                let plan = plan(mask)
                XCTAssertNil(local(mask, plan, size: size).preLUT)
                let actual = try read(RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                    longEdge: input.width, lutSize: size))
                XCTAssertEqual(actual.pixels, input.pixels)
                let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
                XCTAssertEqual(cpu.pixels, input.pixels)
            }
        }

    }

    func testCompatibilityRecordsCompareOldFusedNewSequentialAndDirectCPU() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = input(), source = image(input)
        for mode in ["relative", "absolute"] { for contrast in [0.0, 30.0] {
            for amount in [1e-8, 1.0, 100.0] { for size in [33, 65] {
                let mask = mask(mode, amount: amount, contrast: contrast), plan = plan(mask)
                let scale = amount / 100
                let tone = ToneEngine(tone: Tone(contrast: contrast * scale))
                let balance = ReferenceRenderer.LocalWhiteBalance.resolve(mask.adjust,
                    amount: scale, balanced: plan.balancedNeutral, space: .rec2020)
                // Exact historical fused pre-LUT definition, retained ONLY for
                // compatibility measurements. Its result is not an approved golden.
                let historical = LUT3D(size: size) { encoded in
                    var c = LumenLog.decode(encoded)
                    let luminance = max(RGBColorSpace.rec2020.luminance(c), 0)
                    c = c * tone.gain(at: Num.safeLog2(luminance / 0.18))
                    return LumenLog.encode(balance.apply(c))
                }
                let oldImage = try XCTUnwrap(RenderGraph.throughShaper(source) {
                    ColorCube.filter(historical, image: $0)
                })
                let old = try read(oldImage)
                // Counterfactual old-table construction/readback above is excluded.
                // This tiny ordered fixture measures completed actual shipping work,
                // not native RAW/GUI latency or a statistical performance result.
                let start = ProcessInfo.processInfo.systemUptime
                let shipping = RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                    longEdge: input.width, lutSize: size)
                let assembled = ProcessInfo.processInfo.systemUptime
                let new = try read(shipping)
                let completed = ProcessInfo.processInfo.systemUptime
                let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
                var rows: [[String: Any]] = []
                for x in [2, 6, 10] {
                    let a = old[x, 1], b = new[x, 1], c = cpu[x, 1]
                    XCTAssertTrue(a.isFinite && b.isFinite && c.isFinite)
                    rows.append(["input": [input[x, 1].r, input[x, 1].g, input[x, 1].b],
                        "old": [a.r, a.g, a.b], "new": [b.r, b.g, b.b], "cpu": [c.r, c.g, c.b],
                        "oldVsNew": a.maxAbsDifference(b), "oldVsCPU": a.maxAbsDifference(c),
                        "newVsCPU": b.maxAbsDifference(c)])
                }
                let record: [String: Any] = ["mode": mode, "contrast": contrast, "amount": amount,
                    "cube": size, "patches": rows, "savedLookIdentityClaim": false,
                    "mixedToneAccuracyAcceptance": false,
                    "graphAssemblySeconds": assembled - start,
                    "completedSeconds": completed - start,
                    "timingScope": "tiny generated fixture, ordered, not GUI/RAW/statistical speed proof"]
                let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                var line = Data("LOCAL-WB-COMPATIBILITY ".utf8); line.append(json); line.append(10)
                FileHandle.standardOutput.write(line)
            } }
        } }
    }
}
#endif
