#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class DehazeSkyFieldTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
        .workingFormat: CIFormat.RGBAf])

    private func image(_ input: ImageBuffer) -> CIImage {
        input.pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: input.width * 16,
                size: CGSize(width: input.width, height: input.height), format: .RGBAf, colorSpace: nil)
        }
    }
    private func read(_ image: CIImage) throws -> ImageBuffer {
        try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
    }

    func testExactEVAndCentralTensorAgainstIndependentFiniteSums() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let w = 19, h = 13
        for longEdge in [19, 800] {
            var input = ImageBuffer(width: w, height: h)
            for y in 0..<h { for x in 0..<w {
                let ev = -1.5 + Double(x) * 0.08 + Double(y) * 0.12
                    + 0.3 * sin(Double(x + 2 * y) * Double.pi / 2)
                input[x, y] = RGB(gray: 0.18 * pow(2.0, ev))
            } }
            // Include zero/negative luminance: reference maps both to -20EV.
            input[0, 0] = RGB(gray: 0)
            input[w - 1, h - 1] = RGB(gray: -0.01)
            let fields = try XCTUnwrap(RenderGraph.dehazeSkyFields(image(input), longEdge: longEdge))
            let ev = try read(fields.logEV), gradient = try read(fields.magnitude)
            XCTAssertTrue(ev.pixels.allSatisfy { $0.isFinite })
            XCTAssertTrue(gradient.pixels.allSatisfy { $0.isFinite })
            let working = min(max(Int(Double(longEdge) * 0.02), 3), max(w, h))
            let radius = max(working / 4, 1)
            func logAt(_ x: Int, _ y: Int) -> Double {
                let c = input[min(max(x, 0), w - 1), min(max(y, 0), h - 1)]
                return log2(max(c.r / 0.18, pow(2.0, -20.0)))
            }
            func derivative(_ x: Int, _ y: Int) -> (Double, Double) {
                let x = min(max(x, 0), w - 1), y = min(max(y, 0), h - 1)
                return ((logAt(x + 1, y) - logAt(x - 1, y)) / 2,
                        (logAt(x, y + 1) - logAt(x, y - 1)) / 2)
            }
            let cpu = DetailEngine.Decomposition(image: input, workingRadius: working)
            var worstEV = 0.0, worstGradient = 0.0
            for y in 0..<h { for x in 0..<w {
                var xx = 0.0, yy = 0.0, xy = 0.0
                for dy in -radius...radius { for dx in -radius...radius {
                    let (a, b) = derivative(x + dx, y + dy)
                    xx += a * a; yy += b * b; xy += a * b
                } }
                let count = Double((2 * radius + 1) * (2 * radius + 1))
                xx /= count; yy /= count; xy /= count
                let magnitude = sqrt(max((xx + yy + sqrt(max((xx - yy) * (xx - yy) + 4 * xy * xy, 0))) / 2, 0))
                XCTAssertEqual(cpu.logLuminance[x, y], logAt(x, y), accuracy: 1e-6)
                XCTAssertEqual(cpu.gradient[x, y], magnitude, accuracy: 1e-3)
                worstEV = max(worstEV, abs(ev[x, y].r - logAt(x, y)))
                worstGradient = max(worstGradient, abs(gradient[x, y].r - magnitude))
            } }
            print("DEHAZE-SKY-FIELDS longEdge=\(longEdge) radius=\(radius) maxEV=\(worstEV) maxGradient=\(worstGradient)")
            XCTAssertLessThan(worstEV, 1e-3)
            XCTAssertLessThan(worstGradient, 1e-3)
        }
    }

    func testPositiveSkyKernelEquationWithColoredAirlight() throws {
        try checkKernelEquations(sign: 1)
    }

    func testNegativeSkyKernelEquationWithColoredAirlight() throws {
        try checkKernelEquations(sign: -1)
    }

    private func checkKernelEquations(sign: Double) throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let c = RGB(0.6, 0.8, 0.9), air = RGB(0.7, 0.9, 1)
        let weights = RGBColorSpace.rec2020.luminanceWeights
        let airLuma = weights.r * air.r + weights.g * air.g + weights.b * air.b
        let gain = RGB(airLuma / air.r, airLuma / air.g, airLuma / air.b)
        let raw = 0.7
        func step(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func constant(_ value: RGB) -> CIImage {
            image(ImageBuffer(width: 1, height: 1) { _, _ in value })
        }
        for ev in [0.0, 1.25, 2.25] { for gradient in [0.0, 0.2, 0.5] {
            let sky = step(0.5, 2, ev) * (1 - step(0.05, 0.35, gradient))
            for strength in [0.35, 1.0] {
                let amount = sign * strength
                let output = try XCTUnwrap(KernelLibrary.apply(KernelLibrary.dehaze,
                    extent: CGRect(x: 0, y: 0, width: 1, height: 1),
                    [constant(c), constant(RGB(gray: raw)), constant(RGB(gray: ev)),
                     constant(RGB(gray: gradient)), CIVector(x: gain.r, y: gain.g, z: gain.b),
                     CIVector(x: weights.r, y: weights.g, z: weights.b),
                     CIVector(x: air.r, y: air.g, z: air.b), Float(airLuma), Float(0.45), Float(amount)]))
                let actual = try read(output)[0, 0]
                let expected: RGB
                if sign > 0 {
                    let t = max(raw, 0.45 + (0.9 - 0.45) * sky)
                    let neutral = c * gain
                    let y0 = weights.r * neutral.r + weights.g * neutral.g + weights.b * neutral.b
                    let y1 = (y0 - airLuma) / t + airLuma
                    let ratio = min(max(y1 / y0, 0.05), 20)
                    expected = c * (1 + (ratio - 1) * strength)
                } else {
                    let distance = max(1 - raw, sky)
                    let a = strength * distance * 0.9
                    expected = c * (1 - a) + air * a
                }
                XCTAssertTrue(actual.r.isFinite && actual.g.isFinite && actual.b.isFinite)
                XCTAssertLessThan(actual.maxAbsDifference(expected), 1e-3,
                    "sign=\(sign) EV=\(ev) gradient=\(gradient) amount=\(amount)")
            }
        } }
    }

    func testPresenceSkySourceIsFrozenBeforeNonzeroDetail() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = ImageBuffer(width: 96, height: 64) { u, v in
            let ev = 1.4 + 0.35 * sin(u * 12 * Double.pi) + 0.12 * cos(v * 8 * Double.pi)
            return RGB(gray: 0.18 * pow(2.0, ev))
        }
        let source = image(input)
        var detail = Detail()
        detail.texture = 100; detail.clarity = 100
        let formed = RenderGraph.applyPresence(source, detail: detail, longEdge: 96)
        detail.dehaze = 100
        let actual = try read(RenderGraph.applyPresence(source, detail: detail, longEdge: 96))
        let expected = try read(RenderGraph.applyDehaze(formed, amount: 100, longEdge: 96, skySource: source))
        let oldStageSource = try read(RenderGraph.applyDehaze(formed, amount: 100, longEdge: 96))
        let correctError = actual.maxAbsDifference(expected)
        let wrongSourceGap = actual.maxAbsDifference(oldStageSource)
        print("DEHAZE-SKY-STAGE correctError=\(correctError) wrongSourceGap=\(wrongSourceGap)")
        XCTAssertLessThan(correctError, 1e-3)
        XCTAssertGreaterThan(wrongSourceGap, 1e-3,
            "fixture must distinguish pre-Presence from post-Presence sky evidence")
    }

    func testFullGraphReadbackTilesAndTranslatedExtent() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = ImageBuffer(width: 128, height: 128) { u, _ in RGB(gray: u < 0.5 ? 0.8 : 1) }
        let source = image(input)
        for amount in [-100.0, 100] {
            let fullGraph = RenderGraph.applyDehaze(source, amount: amount, longEdge: 128)
            let full = try read(fullGraph)
            for rect in [CGRect(x: 0, y: 0, width: 32, height: 32),
                         CGRect(x: 48, y: 48, width: 32, height: 32)] {
                // Crop the completed full-source graph, never rebuild from a tile.
                let tile = try read(fullGraph.cropped(to: rect))
                for y in 0..<tile.height { for x in 0..<tile.width {
                    XCTAssertLessThan(tile[x, y].maxAbsDifference(full[x + Int(rect.minX), y + Int(rect.minY)]), 1e-3)
                } }
            }
            let translated = source.transformed(by: CGAffineTransform(translationX: 11, y: -7))
            let moved = try read(RenderGraph.applyDehaze(translated, amount: amount, longEdge: 128))
            XCTAssertLessThan(moved.maxAbsDifference(full), 1e-3)
        }
    }

    func testGlobalLocalGroupAndSoftMaskSkyContractWithDetailControls() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let input = ImageBuffer(width: 128, height: 128) { u, _ in RGB(gray: u < 0.5 ? 0.8 : 1) }
        let source = image(input)
        for amount in [-100.0, -35, 0, 35, 100] {
            let expected = amount >= 0
                ? 0.8 + (1 - 0.2 / 0.9 - 0.8) * amount / 100
                : 0.8 + 0.2 * 0.9 * (-amount / 100)
            for withDetail in [false, true] {
                var detail = Detail()
                detail.dehaze = amount
                if withDetail { detail.texture = 20; detail.clarity = -15 }
                let start = ProcessInfo.processInfo.systemUptime
                let global = try read(RenderGraph.applyPresence(source, detail: detail, longEdge: 128))
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                XCTAssertEqual(global[24, 64].r, expected, accuracy: 1e-3)
                print("DEHAZE-SKY-GLOBAL amount=\(amount) detail=\(withDetail) value=\(global[24, 64].r) firstMs=\(elapsed)")
                for alpha in [0.25, 0.75] {
                    var mask = Mask(id: "sky", amount: 50)
                    mask.group = "sky-group"
                    mask.adjust.dehaze = amount
                    if withDetail { mask.adjust.texture = 20; mask.adjust.clarity = -15 }
                    var recipe = Recipe()
                    recipe.masks = [mask]
                    recipe.maskGroups = [MaskGroup(id: "sky-group", amount: 200)]
                    let plan = RenderPlan(recipe: recipe, lutSize: 17)
                    let resolved = try XCTUnwrap(plan.masks.first)
                    XCTAssertEqual(resolved.amount, 100)
                    let alphaInput = ImageBuffer(width: 128, height: 128) { _, _ in RGB(gray: alpha) }
                    var graph = RenderGraph()
                    graph.maskImages[resolved.id] = image(alphaInput)
                    let output = try read(graph.applyLocal(source, plan: plan,
                        options: RenderGraph.Options(longEdge: 128, lutSize: 33)))
                    XCTAssertEqual(output[24, 64].r, 0.8 * (1 - alpha) + expected * alpha, accuracy: 1e-3)
                }
            }
        }
    }
}
#endif
