import Foundation
@testable import LumenCore

/// Opt-in evidence for comparing the same proof on different CPU runtimes. This is
/// a diagnostic, not a new tolerance: an output-ULP sensitivity experiment cannot
/// establish the error bound of an upstream transcendental function or LUT bake.
enum ProofNumericalDiagnostics {
    static func nudgedAway(_ image: ImageBuffer, from baseline: ImageBuffer) -> ImageBuffer {
        precondition(image.width == baseline.width && image.height == baseline.height)
        var result = image
        for i in result.pixels.indices where i % 4 != 3 {
            let value = image.pixels[i]
            guard value.isFinite else { continue }
            result.pixels[i] = value >= baseline.pixels[i] ? value.nextUp : value.nextDown
        }
        return result
    }

    static func description(_ spec: ControlSpec, steps: Int = 21) throws -> [String: Any] {
        guard spec.frameName == "colourChart", !spec.denoisedFirst else {
            return ["unavailable": "stage fingerprints require a non-spatial colourChart probe"]
        }
        let frame = spec.frame()
        // The current 21-step ruler stores 20 cumulative differences, so index
        // count/2 selects sweep step 11 (55% travel), not step 10 (50%). Keep
        // this diagnostic aligned with the existing record, not its rounded prose.
        precondition(steps >= 2)
        let frontIndex = (steps - 1) / 2 + 1
        let frontSetting = spec.low + (spec.high - spec.low)
            * Double(frontIndex) / Double(steps - 1)
        let settings = [spec.low, frontSetting, spec.authorityEnd]
        let renders = settings.map { ProofRunner.render(spec, at: $0, frame: frame) }
        var samples: [[String: Any]] = []
        for (settingIndex, setting) in settings.enumerated() {
            var recipe = Recipe()
            spec.apply(&recipe, setting)
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize,
                                  captureISO: spec.captureISO)
            let render = renders[settingIndex]
            for patch in 1...24 {
                let p = ProofFrames.chartPatchCentre(patch)
                let source = frame[p.x, p.y]
                var tone = plan.linear.apply(source)
                if !plan.toneIsIdentity {
                    let lum = max(RGBColorSpace.rec2020.luminance(tone), 0)
                    tone = tone * plan.tone.gain(at: Num.safeLog2(lum / 0.18))
                }
                let graded = plan.colorGraded(tone)
                let finishEncoded = LumenLog.encode(graded)
                var sample: [String: Any] = [
                    "setting": setting, "patch": patch,
                    "source": channels(source), "linearAndTone": channels(tone),
                    "exactColorTwin": channels(plan.colorStage.apply(tone)),
                    "grade": channels(graded),
                    "finishEncoded": channels(finishEncoded),
                    "finishSampled": channels(plan.finishedColor(encoded: finishEncoded)),
                    "referenceColor": channels(plan.referenceColor(source)),
                    "renderedFloat": channels(render[p.x, p.y])
                ]
                // The first exact-source Linux/Darwin comparison isolated all drift
                // to chart patch 2, before grade/finish. Trace only that patch's twin
                // arithmetic, not a second implementation of the renderer.
                if patch == 2 { sample["twinArithmetic"] = twinArithmetic(plan.colorStage, tone) }
                samples.append(sample)
            }
        }
        let low = renders[0], mid = renders[1], high = renders[2]
        let mean = ProofMetrics.meanSeparation(low, high)
        let authority = ProofMetrics.authority(low, high)
        let midpointAuthority = ProofMetrics.authority(low, mid)
        let nudgedHigh = nudgedAway(high, from: low)
        let nudgedMid = nudgedAway(mid, from: low)
        #if os(macOS)
        let platform = "Darwin"
        #elseif os(Linux)
        let platform = "Linux"
        #else
        let platform = "other"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "other"
        #endif
        return [
            "platform": platform, "architecture": architecture,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "id": spec.id, "samples": samples,
            "settings": settings, "frontLoadingSetting": frontSetting,
            "sampleScope": "24 patch-centre scalar color predictions plus final full-grid rendered values; scalar aliases do not substitute for the full-grid proof",
            "outputULPSensitivity": [
                "meanSeparation": mean,
                "meanSeparationDelta": ProofMetrics.meanSeparation(low, nudgedHigh) - mean,
                "authority": authority,
                "authorityDelta": ProofMetrics.authority(low, nudgedHigh) - authority,
                "frontLoading": midpointAuthority / authority,
                "midpointNudgeFrontDelta":
                    ProofMetrics.authority(low, nudgedMid) / authority - midpointAuthority / authority,
                "endpointNudgeFrontDelta":
                    midpointAuthority / ProofMetrics.authority(low, nudgedHigh) - midpointAuthority / authority
            ],
            "interpretation": "Every finite RGB output is moved one Float32 ULP away from the low endpoint. This measures sensitivity only; it does not establish an upstream platform error bound. Alpha is unchanged."
        ]
    }

    private static func twinArithmetic(_ stage: ExactColorStage, _ input: RGB) -> [[String: Any]] {
        let original = SIMD3<Float>(Float(input.r), Float(input.g), Float(input.b))
        var traces: [[String: Any]] = []
        for (index, pass) in stage.passes.enumerated() {
            let before = ExactColorTwin.run(Array(stage.passes.prefix(index)), original)
            let after = ExactColorTwin.run(Array(stage.passes.prefix(index + 1)), original)
            let lms = ExactColorTwin.mul(pass.uniforms, 0, before)
            let exponent: Float = 0.333333333
            let seeds = SIMD3<Float>(
                ExactColorTwin.sgn(lms.x) * pow(abs(lms.x), exponent),
                ExactColorTwin.sgn(lms.y) * pow(abs(lms.y), exponent),
                ExactColorTwin.sgn(lms.z) * pow(abs(lms.z), exponent))
            let doubleSeeds = SIMD3<Float>(
                ExactColorTwin.sgn(lms.x) * Float(pow(Double(abs(lms.x)), Double(exponent))),
                ExactColorTwin.sgn(lms.y) * Float(pow(Double(abs(lms.y)), Double(exponent))),
                ExactColorTwin.sgn(lms.z) * Float(pow(Double(abs(lms.z)), Double(exponent))))
            let roots = ExactColorTwin.cbrt3(lms)
            let lab = ExactColorTwin.mul(pass.uniforms, 9, roots)
            let lch = ExactColorTwin.lch(lab)
            let radians = lch.z * Float(0.0174532925)
            traces.append([
                "kernel": String(describing: pass.kernel),
                "uniformBits": pass.uniforms.flatMap { [$0.x.bitPattern, $0.y.bitPattern,
                                                       $0.z.bitPattern, $0.w.bitPattern] },
                "before": floats(before), "after": floats(after),
                "LMS": floats(lms), "powExponent": scalar(exponent),
                "powSeeds": floats(seeds), "doublePowSeeds": floats(doubleSeeds),
                "NewtonRoots": floats(roots), "Lab": floats(lab), "LCh": floats(lch),
                "atan2": scalar(atan2(lab.z, lab.y)),
                "doubleAtan2": scalar(portableAngle(y: lab.z, x: lab.y)),
                "radians": scalar(radians), "cos": scalar(cos(radians)),
                "sin": scalar(sin(radians))
            ])
        }
        return traces
    }

    private static func floats(_ value: SIMD3<Float>) -> [String: Any] {
        channels(RGB(Double(value.x), Double(value.y), Double(value.z)))
    }

    private static func scalar(_ value: Float) -> [String: Any] {
        ["double": Double(value), "floatBits": value.bitPattern]
    }

    /// Proposed precision experiment only; production keeps its existing Float call.
    static func portableAngle(y: Float, x: Float) -> Float {
        Float(atan2(Double(y), Double(x)))
    }

    static func frontLoadingFraction(steps: Int) -> Double {
        precondition(steps >= 2)
        return Double((steps - 1) / 2 + 1) / Double(steps - 1)
    }

    private static func channels(_ rgb: RGB) -> [String: Any] {
        let values = [rgb.r, rgb.g, rgb.b]
        return ["double": values, "floatBits": values.map { Float($0).bitPattern }]
    }
}
