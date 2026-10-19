#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Exact local-tone boundary, independently checked against scalar equations and
/// the unchanged Double reference. No tolerance, creative default or golden change.
final class ExactLocalToneBoundaryTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private let patches = [RGB(-0.01, 0.18, 0.3), RGB(-0.2, -0.1, -0.3),
        RGB(gray: 0), RGB(gray: 1e-10), RGB(0.18, 0.3, 0.5),
        RGB(1024, 128, 256), RGB(gray: 0.18 * pow(2, -4)), RGB(gray: 0.18 * pow(2, 3))]
    private func input() -> ImageBuffer {
        ImageBuffer(width: 32, height: 4) { u, _ in self.patches[min(Int(u * 8), 7)] }
    }
    private func image(_ buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
            size: CGSize(width: buffer.width, height: buffer.height), format: .RGBAf, colorSpace: nil)
    }
    private func read(_ image: CIImage) throws -> ImageBuffer {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: .nan, count: width * height * 4)
        try values.withUnsafeMutableBytes { raw in
            let destination = CIRenderDestination(bitmapData: raw.baseAddress!, width: width,
                height: height, bytesPerRow: width * 16, format: .RGBAf)
            destination.isClamped = false
            let task = try context.startTask(toRender: image, from: image.extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        }
        XCTAssertTrue(values.allSatisfy { $0.isFinite }, "completed readback must be finite and written")
        var buffer = ImageBuffer(width: width, height: height)
        buffer.pixels = values
        return buffer
    }
    private func plan(_ mask: Mask, groups: [MaskGroup] = []) -> RenderPlan {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.raw.temp = 5500
        recipe.develop.raw.tint = 0
        recipe.masks = [mask]
        recipe.maskGroups = groups
        return RenderPlan(recipe: recipe, lutSize: 17)
    }
    private func adjustment(_ kind: String) -> LocalAdjust {
        var a = LocalAdjust()
        switch kind {
        case "contrast": a.contrast = 45
        case "highlights": a.highlights = -85
        case "shadows": a.shadows = 90
        case "whites": a.whites = 80
        case "blacks": a.blacks = -75
        case "mixed": a.contrast = 70; a.highlights = -100; a.shadows = 100; a.whites = -70; a.blacks = 65
        case "opposing": a.contrast = -100; a.highlights = 100; a.shadows = -100; a.whites = 100; a.blacks = -100
        default: break
        }
        return a
    }
    private func engine(_ a: LocalAdjust, scale: Double) -> ToneEngine {
        ToneEngine(tone: Tone(contrast: a.contrast * scale, highlights: a.highlights * scale,
            shadows: a.shadows * scale, whites: a.whites * scale, blacks: a.blacks * scale))
    }
    /// Independent scalar expansion. The engine's existing solved coefficients
    /// remain authoritative; this oracle calls neither gain/stops nor the new stage.
    private func equation(_ c: RGB, _ tone: ToneEngine) -> RGB {
        func smooth(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
            if hi <= lo { return x >= lo ? 1 : 0 }
            let u = min(max((x - lo) / (hi - lo), 0), 1)
            return u * u * (3 - 2 * u)
        }
        let w = RGBColorSpace.rec2020.luminanceWeights
        let y = max(w.r * c.r + w.g * c.g + w.b * c.b, 0)
        let t = y > 0 ? max(log2(y / 0.18), -20) : -20
        let hi = tone.whiteAnchorEV, lo = -tone.blackAnchorEV
        var stops = tone.effectiveHighlights * ToneEngine.highlightShadowRangeEV
            * smooth(0, hi * ToneEngine.highlightShelfEnd, t)
        stops += tone.effectiveShadows * ToneEngine.highlightShadowRangeEV
            * smooth(0, lo * ToneEngine.shadowShelfEnd, -t)
        stops += tone.effectiveWhites * ToneEngine.whiteToneEV
            * smooth(hi * ToneEngine.endShelfStart, hi * ToneEngine.endShelfEnd, t)
        stops += tone.effectiveBlacks * ToneEngine.blackToneEV
            * smooth(lo * ToneEngine.blackShelfStart, lo * ToneEngine.blackShelfEnd, -t)
        let contrast = min(max(tone.tone.contrast, -100), 100)
        let pivot = min(max(tone.tone.contrastPivot, -4), 4)
        let d = t - pivot
        let reach = d >= 0 ? hi - pivot : pivot + lo
        if contrast != 0 && reach > ToneEngine.minContrastReachEV {
            let shoulder = smooth(ToneEngine.contrastShoulderStart, 1, abs(d) / reach)
            let slope = 1 + 0.6 * contrast / 100
            let mapped = pivot + d * (slope * (1 - shoulder) + shoulder)
            stops += mapped - t
        }
        return c * pow(2, stops)
    }
    private func error(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var maximum = 0.0
        for y in 0..<a.height { for x in 0..<a.width {
            maximum = max(maximum, a[x, y].maxAbsDifference(b[x, y]))
        } }
        return maximum
    }
    private func emit(_ row: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        var line = Data("EXACT-LOCAL-TONE ".utf8)
        line.append(json); line.append(10)
        FileHandle.standardOutput.write(line)
    }

    func testSignedHDRToneAmountsMatchIndependentEquationAndCPU() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let input = input(), source = image(input)
        XCTAssertEqual(try read(source).pixels, input.pixels)
        var configurations = 0, worstEquation = 0.0, worstCPU = 0.0
        for kind in ["contrast", "highlights", "shadows", "whites", "blacks", "mixed", "opposing"] {
            for axis in ["mask", "group"] {
                for amount in [0.0, 1e-8, 0.0001, 1.0, 25.0, 50.0, 100.0, 200.0] {
                    var original = Mask(id: "tone", amount: axis == "mask" ? amount : 100)
                    original.adjust = adjustment(kind)
                    var groups: [MaskGroup] = []
                    if axis == "group" {
                        original.group = "tone-group"
                        groups = [MaskGroup(id: "tone-group", amount: amount)]
                    }
                    let plan = plan(original, groups: groups)
                    let mask = try XCTUnwrap(plan.masks.first)
                    XCTAssertEqual(mask.amount, amount)
                    let tone = engine(mask.adjust, scale: amount / 100)
                    let expected = input.map { self.equation($0, tone) }
                    let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
                    XCTAssertLessThanOrEqual(error(cpu, expected), 1e-3, "independent equation versus unchanged reference")
                    var prior: ImageBuffer?
                    for size in [33, 65] {
                        let label = "\(kind)/\(axis)/\(amount)/cube\(size)"
                        let actual = try read(RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                            longEdge: input.width, lutSize: size))
                        let eqError = error(actual, expected), cpuError = error(actual, cpu)
                        worstEquation = max(worstEquation, eqError); worstCPU = max(worstCPU, cpuError)
                        XCTAssertLessThanOrEqual(eqError, 1e-3, label + " independent equation")
                        XCTAssertLessThanOrEqual(cpuError, 1e-3, label + " CPU")
                        if amount == 0 { XCTAssertEqual(actual.pixels, input.pixels, label) }
                        if let prior { XCTAssertEqual(actual.pixels, prior.pixels, label + " tone has no cube-size dependence") }
                        prior = actual
                        configurations += 1
                    }
                }
            }
        }
        try emit(["tap": "amount-summary", "configurations": configurations,
            "maximumEquationError": worstEquation, "maximumCPUError": worstCPU,
            "mathTolerance": 1e-3, "wheelAcceptance": false])
        XCTAssertEqual(configurations, 224)
    }

    func testToneMaskAlphaAndExposureWhiteBalanceColorOrder() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let input = input(), source = image(input)
        var configurations = 0, maximum = 0.0
        for mixed in [false, true] {
            for amount in [0.0, 1e-8, 1.0, 100.0, 200.0] {
                var mask = Mask(id: "tone-order", amount: amount)
                mask.adjust = adjustment("mixed")
                if mixed {
                    mask.adjust.exposure = 0.25
                    mask.adjust.temp = 20
                    mask.adjust.tint = 13
                    mask.adjust.sat = 35
                    mask.adjust.vibrance = 20
                }
                let plan = plan(mask)
                let resolved = try XCTUnwrap(plan.masks.first)
                let reference = ReferenceRenderer.applyLocalAdjust(input, mask: resolved, plan: plan, space: .rec2020)
                for size in [33, 65] {
                    for alpha in [0.0, 0.25, 0.75, 1.0] {
                        let scalar = ImageBuffer(width: input.width, height: input.height) { _, _ in RGB(gray: alpha) }
                        let alphaImage = image(scalar)
                        XCTAssertEqual(try read(alphaImage)[2, 1].r, alpha)
                        var graph = RenderGraph()
                        graph.maskImages[resolved.id] = alphaImage
                        let actual = try read(graph.applyLocal(source, plan: plan,
                            options: RenderGraph.Options(longEdge: input.width, lutSize: size)))
                        var expected = input
                        for y in 0..<input.height { for x in 0..<input.width {
                            expected[x, y] = input[x, y] * (1 - alpha) + reference[x, y] * alpha
                        } }
                        let difference = error(actual, expected)
                        maximum = max(maximum, difference)
                        XCTAssertLessThanOrEqual(difference, 1e-3, "mixed=\(mixed) amount=\(amount) alpha=\(alpha) cube=\(size)")
                        if alpha == 0 || amount == 0 { XCTAssertEqual(actual.pixels, input.pixels) }
                        configurations += 1
                    }
                }
            }
        }
        try emit(["tap": "alpha-order-summary", "configurations": configurations, "maximumCPUError": maximum])
        XCTAssertEqual(configurations, 80)
    }

    func testFormerToneWBColorTableFixtureIsNowCubeIndependent() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let input = input(), source = image(input)
        var mask = Mask(id: "former-table", amount: 100)
        mask.adjust.contrast = 45
        mask.adjust.temp = 30
        mask.adjust.sat = 35
        mask.adjust.vibrance = 20
        let plan = plan(mask)
        let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
        var previous: ImageBuffer?
        for size in [33, 65] {
            let actual = try read(RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                longEdge: input.width, lutSize: size))
            XCTAssertLessThanOrEqual(error(actual, cpu), 1e-3)
            if let previous { XCTAssertEqual(actual.pixels, previous.pixels) }
            previous = actual
        }
    }

    func testNonopaqueSignedHDRStoragePreservesAlphaAndScalarEquation() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let original = input()
        for alpha in [0.0, 0.25, 0.75, 1.0] {
            var input = original
            for y in 0..<input.height { for x in 0..<input.width {
                input[x, y] = original[x, y] * alpha
                input.pixels[input.index(x, y) + 3] = Float(alpha)
            } }
            let source = image(input)
            XCTAssertEqual(try read(source).pixels, input.pixels)
            var mask = Mask(id: "nonopaque-tone", amount: 100)
            mask.adjust = adjustment("shadows")
            let plan = plan(mask), tone = engine(mask.adjust, scale: 1)
            let actual = try read(RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                longEdge: input.width, lutSize: 65))
            for y in 0..<input.height { for x in 0..<input.width {
                let expected = equation(input[x, y], tone)
                XCTAssertLessThanOrEqual(actual[x, y].maxAbsDifference(expected), 1e-3)
                XCTAssertEqual(actual.pixels[actual.index(x, y) + 3], Float(alpha))
            } }
        }
    }

    func testNeutralControlsRetainExactIdentity() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let input = input(), source = image(input)
        for size in [33, 65] {
            let neutral = Mask(id: "neutral", amount: 100)
            let plan = plan(neutral)
            let actual = try read(RenderGraph.applyLocalAdjust(source, mask: neutral, plan: plan,
                longEdge: input.width, lutSize: size))
            XCTAssertEqual(actual.pixels, input.pixels)
        }
    }

    func testChangingAmountCompletedCosts() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "core kernels unavailable")
        let input = input(), source = image(input)
        // Actual graph construction AND checked completed GPU readback. Tiny generated
        // fixture, one ordered host; these measurements are not GUI/RAW speed claims.
        for (index, amount) in [1.0, 25.0, 50.0, 100.0, 200.0, 1e-8, 1.0, 25.0, 50.0, 100.0, 200.0, 1e-8].enumerated() {
            var mask = Mask(id: "cost", amount: amount)
            mask.adjust = adjustment("contrast")
            let plan = plan(mask)
            let start = ProcessInfo.processInfo.systemUptime
            let output = RenderGraph.applyLocalAdjust(source, mask: mask, plan: plan,
                longEdge: input.width, lutSize: 65)
            let assembled = ProcessInfo.processInfo.systemUptime
            let actual = try read(output)
            let completed = ProcessInfo.processInfo.systemUptime
            let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: mask, plan: plan, space: .rec2020)
            let difference = error(actual, cpu)
            XCTAssertLessThanOrEqual(difference, 1e-3)
            try emit(["tap": "completed-cost", "iteration": index, "amount": amount,
                "graphAssemblySeconds": assembled - start, "completedSeconds": completed - start,
                "maximumCPUError": difference, "scope": "32x4 generated fixture, changing Amount, ordered host"])
        }
    }
}
#endif
