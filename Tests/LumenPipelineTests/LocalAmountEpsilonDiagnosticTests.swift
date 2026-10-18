#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Opt-in unresolved accuracy diagnostic. It measures current behavior and asserts
/// actual CPU/GPU agreement separately from an independent LUT-domain equation.
/// It deliberately does not turn a known discrepancy into an expected failure.
final class LocalAmountEpsilonDiagnosticTests: XCTestCase {
    func testCurrentPositiveAmountDomainAndCPUAgreement() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_LOCAL_AMOUNT_EPSILON"] == "1",
                          "opt-in positive local/group Amount diagnostic")
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
            .workingFormat: CIFormat.RGBAf,
        ])
        let patches = [RGB(-0.01, 0.18, 0.3), RGB(1024, 128, 256),
                       RGB(0.18, 0.3, 0.5), RGB(-0.0000001, 0.2, 0.3)]
        var input = ImageBuffer(width: 16, height: 16)
        for y in 0..<16 { for x in 0..<16 { input[x, y] = patches[x / 4] } }
        let bytes = input.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = CIImage(bitmapData: bytes, bytesPerRow: 16 * 16,
                            size: CGSize(width: 16, height: 16), format: .RGBAf, colorSpace: nil)
        let centers = [2, 6, 10, 14]
        let observedInput = centers.map { input[$0, 8] }
        // Independent expansion of the declared shaper endpoints, not a call to
        // LUT.sample or LumenLog.decode: toe offset/slope and +12EV scene white.
        let cut = 0.18 * pow(2.0, -10.5)
        let lower = cut * (1 - 1.5 * log(2.0))
        let upper = 0.18 * pow(2.0, 12.0)
        func clampedDomain(_ c: RGB) -> RGB {
            RGB(min(max(c.r, lower), upper), min(max(c.g, lower), upper), min(max(c.b, lower), upper))
        }
        func triples(_ values: [RGB]) -> [[Double]] { values.map { [$0.r, $0.g, $0.b] } }
        func read(_ image: CIImage) throws -> ImageBuffer {
            try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
        }
        func emit(_ record: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("LOCAL-AMOUNT-EPSILON " + String(decoding: data, as: UTF8.self))
        }
        var independentFailures: [String] = []
        var parityFailures: [String] = []
        var stageRecords = 0, compositeRecords = 0
        for size in [33, 65] {
            let kind = "grade"
            do {
                for axis in ["mask", "group"] {
                    for amount in [0.0, 1e-8, 0.0001, 0.01, 1.0] {
                        var mask = Mask(id: "epsilon", amount: axis == "mask" ? amount : 50)
                        var wheels = GradingWheels()
                        wheels.global = Wheel(hue: 123, sat: 0.4, lum: 0.1)
                        mask.adjust.wheels = wheels
                        var recipe = Recipe()
                        recipe.develop.denoise.mode = .off
                        if axis == "group" {
                            mask.group = "g"
                            recipe.maskGroups = [MaskGroup(id: "g", amount: 2 * amount)]
                        }
                        recipe.masks = [mask]
                        // The metadata plan supplies actual group strength and tonal
                        // anchors. Global tables are not evaluated in this S11 test;
                        // local table fidelity below is explicitly 33/65.
                        let plan = RenderPlan(recipe: recipe, lutSize: 17)
                        let resolved = try XCTUnwrap(plan.masks.first)
                        let adjusted = RenderGraph.applyLocalAdjust(source, mask: resolved, plan: plan,
                            longEdge: input.width, lutSize: size)
                        let gpu = try read(adjusted)
                        let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: resolved,
                                                                     plan: plan, space: .rec2020)
                        let key = "\(kind)/\(axis)/cube\(size)/amount\(amount)"
                        if !gpu.pixels.allSatisfy({ $0.isFinite }) || !cpu.pixels.allSatisfy({ $0.isFinite }) {
                            independentFailures.append(key + " nonfinite stage")
                            continue
                        }
                        let gpuValues = centers.map { gpu[$0, 8] }
                        let cpuValues = centers.map { cpu[$0, 8] }
                        let parity = zip(gpuValues, cpuValues).map { pair in pair.0.maxAbsDifference(pair.1) }.max() ?? 0
                        let discontinuity = zip(gpuValues, observedInput).map { pair in pair.0.maxAbsDifference(pair.1) }.max() ?? 0
                        if parity > 1e-3 { parityFailures.append(key + " stage CPU/GPU error=\(parity)") }
                        if amount == 0 && (gpu.pixels != input.pixels || cpu.pixels != input.pixels) {
                            independentFailures.append(key + " zero stage identity")
                        }
                        var expected: [RGB]? = nil
                        if kind == "grade" && amount == 1e-8 { expected = observedInput.map(clampedDomain) }
                        if let expected {
                            // Only out-of-domain R endpoints are independently exact.
                            // In-domain channels include finite log-cube interpolation
                            // error and remain logged/strictly CPU-compared below.
                            let error = [0, 1].map { abs(gpuValues[$0].r - expected[$0].r) }.max() ?? 0
                            // Existing 1e-3 stage readback bound, not an expanded HDR
                            // tolerance or a newly accepted continuity jump.
                            if error > 1e-3 { independentFailures.append(key + " independent equation error=\(error)") }
                        }
                        var record: [String: Any] = ["tap": "stage", "kind": kind, "axis": axis,
                            "cube": size, "amount": amount, "effectiveAmount": resolved.amount,
                            "gpu": triples(gpuValues), "cpu": triples(cpuValues),
                            "maxCPUvsGPU": parity, "maxGPUvsInput": discontinuity]
                        if let expected { record["independentEquation"] = triples(expected); record["independentEquationScope"] = "R only, patches0/1, out-of-domain endpoints" }
                        try emit(record)
                        stageRecords += 1
                        // Twenty grade stage configurations plus four soft-alpha S11
                        // composites plus one alpha-zero control.
                        if amount != 1e-8 { continue }
                        let softAlpha = size == 33
                            ? (axis == "mask" ? 0.25 : 0.75)
                            : (axis == "mask" ? 0.75 : 0.25)
                        let alphas = size == 33 && axis == "mask" ? [softAlpha, 0.0] : [softAlpha]
                        for alpha in alphas {
                            var graph = RenderGraph()
                            graph.maskImages[resolved.id] = CIImage(color: CIColor(red: alpha, green: alpha, blue: alpha))
                                .cropped(to: source.extent)
                            let composed = graph.applyLocal(source, plan: plan,
                                options: RenderGraph.Options(longEdge: input.width, lutSize: size))
                            let actual = try read(composed)
                            let reference = ReferenceRenderer.applyMasks(input, plan: plan,
                                alphas: [(mask: resolved, alpha: Plane(width: 16, height: 16, fill: alpha))], space: .rec2020)
                            let actualValues = centers.map { actual[$0, 8] }
                            let referenceValues = centers.map { reference[$0, 8] }
                            if !actual.pixels.allSatisfy({ $0.isFinite }) || !reference.pixels.allSatisfy({ $0.isFinite }) {
                                independentFailures.append(key + " nonfinite composite alpha=\(alpha)")
                                continue
                            }
                            let compositeError = zip(actualValues, referenceValues).map { pair in pair.0.maxAbsDifference(pair.1) }.max() ?? 0
                            if compositeError > 1e-3 { parityFailures.append(key + " composite alpha=\(alpha) CPU/GPU error=\(compositeError)") }
                            let endpoint = amount == 0 ? observedInput : observedInput.map(clampedDomain)
                            let equation = zip(observedInput, endpoint).map { pair in pair.0 * (1 - alpha) + pair.1 * alpha }
                            let equationError = [0, 1].map { abs(actualValues[$0].r - equation[$0].r) }.max() ?? 0
                            if equationError > 1e-3 { independentFailures.append(key + " normal alpha equation error=\(equationError)") }
                            if (amount == 0 || alpha == 0) && actual.pixels != input.pixels {
                                independentFailures.append(key + " composite zero identity alpha=\(alpha)")
                            }
                            let compositeDiscontinuity = zip(actualValues, observedInput).map { pair in
                                pair.0.maxAbsDifference(pair.1)
                            }.max() ?? 0
                            let compositeRecord: [String: Any] = ["tap": "fullS11", "kind": kind, "axis": axis, "cube": size,
                                "amount": amount, "effectiveAmount": resolved.amount, "alpha": alpha,
                                "gpu": triples(actualValues), "cpu": triples(referenceValues),
                                "independentEquation": triples(equation), "maxCPUvsGPU": compositeError,
                                "maxEquationError": equationError,
                                "independentEquationScope": "R only, patches0/1, out-of-domain endpoints",
                                "maxGPUvsInput": compositeDiscontinuity]
                            try emit(compositeRecord)
                            compositeRecords += 1
                        }
                    }
                }
            }
        }
        // Exposure-only positive-epsilon control: this path has direct gain,
        // with no local grade/post-LUT domain clamp.
        for size in [33, 65] {
            var mask = Mask(id: "exposure-control", amount: 1e-8)
            mask.adjust.exposure = 1
            var recipe = Recipe()
            recipe.develop.denoise.mode = .off
            recipe.masks = [mask]
            let plan = RenderPlan(recipe: recipe, lutSize: 17)
            let resolved = try XCTUnwrap(plan.masks.first)
            let image = RenderGraph.applyLocalAdjust(source, mask: resolved, plan: plan,
                                                    longEdge: input.width, lutSize: size)
            let gpu = try read(image)
            let cpu = ReferenceRenderer.applyLocalAdjust(input, mask: resolved, plan: plan, space: .rec2020)
            let actual = centers.map { gpu[$0, 8] }
            let reference = centers.map { cpu[$0, 8] }
            let equation = observedInput.map { $0 * pow(2.0, 1e-10) }
            let parity = zip(actual, reference).map { $0.0.maxAbsDifference($0.1) }.max() ?? 0
            let error = zip(actual, equation).map { $0.0.maxAbsDifference($0.1) }.max() ?? 0
            if !gpu.pixels.allSatisfy({ $0.isFinite }) || !cpu.pixels.allSatisfy({ $0.isFinite }) {
                independentFailures.append("exposure-only nonfinite cube\(size)")
            }
            if parity > 1e-3 { parityFailures.append("exposure-only cube\(size) CPU/GPU error=\(parity)") }
            if error > 1e-3 { independentFailures.append("exposure-only cube\(size) gain error=\(error)") }
            try emit(["tap": "stage", "kind": "exposure-only", "axis": "mask", "cube": size,
                      "amount": 1e-8, "gpu": triples(actual), "cpu": triples(reference),
                      "independentEquation": triples(equation), "maxCPUvsGPU": parity, "maxEquationError": error])
            stageRecords += 1
        }
        try emit(["tap": "summary", "stageRecords": stageRecords, "compositeRecords": compositeRecords,
                  "independentFailures": independentFailures, "cpuGPUFailures": parityFailures,
                  "qualityAcceptance": false, "continuityAcceptance": false])
        XCTAssertEqual(stageRecords, 22)
        XCTAssertEqual(compositeRecords, 5)
        XCTAssertTrue(independentFailures.isEmpty, independentFailures.joined(separator: "\n"))
        XCTAssertTrue(parityFailures.isEmpty, parityFailures.joined(separator: "\n"))
    }
}
#endif
