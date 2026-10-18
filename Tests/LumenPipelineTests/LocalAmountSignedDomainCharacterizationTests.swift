#if os(macOS)
import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Supplemental measurements, not an accuracy qualification. The existing strict
/// LocalAmountEpsilonDiagnosticTests remains unchanged and continues to own its RED
/// CPU/GPU parity gate. This fixture adds practical signed/mixed-channel inputs.
final class LocalAmountSignedDomainCharacterizationTests: XCTestCase {
    func testSignedWheelAmountStageAndNormalCompositeCharacterization() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_LOCAL_AMOUNT_SIGNED"] == "1",
                          "opt-in signed local Amount characterization")
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
            .workingFormat: CIFormat.RGBAf,
        ])
        // Independent shaper-domain equation, not LUT.sample or LumenLog.decode.
        let cut = 0.18 * pow(2.0, -10.5)
        let lower = cut * (1 - 1.5 * log(2.0))
        let upper = 0.18 * pow(2.0, 12.0)
        let red = [-0.03, -0.01, -0.003, -0.001, -0.0001, -0.00001,
                   lower - 1e-8, lower, lower + 1e-8, -1e-7]
        let patches = red.map { RGB($0, 0.18, 0.3) } + [
            RGB(0, 0.2, 0.3), RGB(0.18, 0.3, 0.5), RGB(0.001, 0.1, 0.9),
            RGB(-0.01, 0.9, 0.02), RGB(1, 0.5, 0.1), RGB(16, 4, 1),
        ]
        let width = patches.count * 4, height = 16
        var input = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { input[x, y] = patches[x / 4] } }
        func image(_ buffer: ImageBuffer) -> CIImage {
            let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                           size: CGSize(width: buffer.width, height: buffer.height),
                           format: .RGBAf, colorSpace: nil)
        }
        func read(_ value: CIImage) throws -> ImageBuffer {
            try XCTUnwrap(PipelineRenderer.buffer(from: value, context: context))
        }
        func emit(_ record: [String: Any]) throws {
            let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            var output = Data("LOCAL-AMOUNT-SIGNED ".utf8)
            output.append(json); output.append(10)
            FileHandle.standardOutput.write(output)
        }
        func triples(_ values: [RGB]) -> [[Double]] { values.map { [$0.r, $0.g, $0.b] } }
        let source = image(input)
        let sourceReadback = try read(source)
        XCTAssertEqual(sourceReadback.pixels, input.pixels, "fixture input must preserve signed Float values")
        let centers = (0..<patches.count).map { $0 * 4 + 2 }
        let originals = centers.map { input[$0, 8] }
        var stageRecords = 0, compositeRecords = 0, zeroStages = 0
        var maximumMeasuredParity = 0.0
        var observedStageParityBeyondExistingBound = 0
        for size in [33, 65] {
            for axis in ["mask", "group"] {
                for amount in [0.0, 1e-8, 0.01, 1.0, 25.0, 100.0] {
                    var mask = Mask(id: "signed-wheel", amount: axis == "mask" ? amount : 100)
                    var wheels = GradingWheels()
                    wheels.global = Wheel(hue: 123, sat: 0.4, lum: 0.1)
                    mask.adjust.wheels = wheels
                    var recipe = Recipe()
                    recipe.develop.denoise.mode = .off
                    recipe.masks = [mask]
                    if axis == "group" {
                        recipe.masks[0].group = "group"
                        recipe.maskGroups = [MaskGroup(id: "group", amount: amount)]
                    }
                    let plan = RenderPlan(recipe: recipe, lutSize: 17)
                    let resolved = try XCTUnwrap(plan.masks.first)
                    XCTAssertEqual(resolved.amount, amount, "mask/group fixture strengths must agree")
                    let adjusted = RenderGraph.applyLocalAdjust(source, mask: resolved, plan: plan,
                                                                longEdge: width, lutSize: size)
                    let stage = try read(adjusted)
                    let reference = ReferenceRenderer.applyLocalAdjust(input, mask: resolved,
                                                                       plan: plan, space: .rec2020)
                    XCTAssertTrue(stage.pixels.allSatisfy { $0.isFinite })
                    XCTAssertTrue(reference.pixels.allSatisfy { $0.isFinite })
                    let actual = centers.map { stage[$0, 8] }
                    let cpu = centers.map { reference[$0, 8] }
                    let errors = zip(actual, cpu).map { pair in pair.0.maxAbsDifference(pair.1) }
                    let maxError = errors.max() ?? 0
                    maximumMeasuredParity = max(maximumMeasuredParity, maxError)
                    if maxError > 1e-3 { observedStageParityBeyondExistingBound += 1 }
                    if amount == 0 {
                        XCTAssertEqual(stage.pixels, input.pixels)
                        XCTAssertEqual(reference.pixels, input.pixels)
                        zeroStages += 1
                    }
                    var row: [String: Any] = ["tap": "stage", "axis": axis, "amount": amount,
                        "cube": size, "effectiveAmount": resolved.amount, "input": triples(originals),
                        "gpu": triples(actual), "cpu": triples(cpu), "perPatchMaxCPUvsGPU": errors,
                        "maxCPUvsGPU": maxError, "lowerDomainEndpoint": lower, "upperDomainEndpoint": upper,
                        "accuracyAcceptance": false, "savedLookCompatibilityAcceptance": false]
                    if amount == 1e-8 {
                        // As strength tends to zero the LIVE bounded cube tends to
                        // projection P, whereas Amount=0 bypasses it. This validates
                        // the current mechanism; it does not approve that behavior.
                        let projected = originals.map { RGB(min(max($0.r, lower), upper),
                            min(max($0.g, lower), upper), min(max($0.b, lower), upper)) }
                        let endpointError = zip(actual.prefix(red.count), projected.prefix(red.count))
                            .map { pair in abs(pair.0.r - pair.1.r) }.max() ?? 0
                        XCTAssertLessThanOrEqual(endpointError, 1e-3,
                            "same existing stage-readback bound for independent R projection equation")
                        row["independentProjectedInput"] = triples(projected)
                        row["independentEquationScope"] = "R only, first ten signed/boundary patches, epsilon strength"
                        row["independentProjectionMaxError"] = endpointError
                    }
                    try emit(row)
                    stageRecords += 1
                    if amount != 1e-8 && amount != 100 { continue }
                    for alpha in [0.25, 0.75] {
                        var scalar = ImageBuffer(width: width, height: height)
                        for y in 0..<height { for x in 0..<width { scalar[x, y] = RGB(gray: alpha) } }
                        let maskImage = image(scalar)
                        XCTAssertEqual(try read(maskImage)[2, 8].r, alpha)
                        var graph = RenderGraph()
                        graph.maskImages[resolved.id] = maskImage
                        let result = try read(graph.applyLocal(source, plan: plan,
                            options: RenderGraph.Options(longEdge: width, lutSize: size)))
                        let referenceComposite = ReferenceRenderer.applyMasks(input, plan: plan,
                            alphas: [(mask: resolved, alpha: Plane(width: width, height: height, fill: alpha))],
                            space: .rec2020)
                        XCTAssertTrue(result.pixels.allSatisfy { $0.isFinite })
                        XCTAssertTrue(referenceComposite.pixels.allSatisfy { $0.isFinite })
                        let actualComposite = centers.map { result[$0, 8] }
                        let cpuComposite = centers.map { referenceComposite[$0, 8] }
                        let equation = zip(originals, actual).map { pair in pair.0 * (1 - alpha) + pair.1 * alpha }
                        let equationError = zip(actualComposite, equation).map { pair in pair.0.maxAbsDifference(pair.1) }.max() ?? 0
                        XCTAssertLessThanOrEqual(equationError, 1e-3,
                            "same existing readback bound for independent normal-alpha equation")
                        try emit(["tap": "fullS11", "axis": axis, "amount": amount, "cube": size,
                            "alpha": alpha, "input": triples(originals), "gpu": triples(actualComposite),
                            "cpu": triples(cpuComposite), "independentNormalBlend": triples(equation),
                            "maxNormalEquationError": equationError,
                            "maxCPUvsGPU": zip(actualComposite, cpuComposite).map { pair in pair.0.maxAbsDifference(pair.1) }.max() ?? 0,
                            "accuracyAcceptance": false])
                        compositeRecords += 1
                    }
                }
            }
        }
        XCTAssertEqual(stageRecords, 24)
        XCTAssertEqual(compositeRecords, 16)
        XCTAssertEqual(zeroStages, 4)
        try emit(["tap": "summary", "stageRecords": stageRecords, "compositeRecords": compositeRecords,
            "zeroStagesExact": zeroStages, "observedStageParityBeyondExisting1eMinus3Bound": observedStageParityBeyondExistingBound,
            "maximumMeasuredCPUvsGPU": maximumMeasuredParity, "accuracyAcceptance": false,
            "existingStrictRedDiagnosticUnchanged": true, "productionRemedyImplemented": false])
    }
}
#endif
