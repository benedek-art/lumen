import Foundation

/// Analytic per-pixel S11 tone. Resolution uses the existing ToneEngine's solved
/// amounts and local anchors; this is not the global spatial tone-mask operator.
public struct ExactLocalToneStage: Sendable, Equatable {
    public let isIdentity: Bool
    public let amplitudes: SIMD4<Float>
    public let upper: SIMD4<Float>
    public let lower: SIMD4<Float>
    public let contrast: SIMD4<Float>
    public let policy: SIMD4<Float>
    public let luminance: SIMD4<Float>

    public var uniforms: [SIMD4<Float>] {
        [amplitudes, upper, lower, contrast, policy, luminance]
    }

    public init(tone: ToneEngine) {
        // LocalPlan currently constructs a default-neutral Zones(). Do not silently
        // drop a future local Zones operator or inherit the global panel here.
        precondition(tone.zones.dark.ev == 0 && tone.zones.shadow.ev == 0
            && tone.zones.mid.ev == 0 && tone.zones.light.ev == 0
            && tone.zones.bright.ev == 0 && tone.zones.global.ev == 0,
            "ExactLocalToneStage requires neutral local Zones")
        isIdentity = tone.isIdentity
        amplitudes = SIMD4(Float(tone.effectiveHighlights * ToneEngine.highlightShadowRangeEV),
            Float(tone.effectiveShadows * ToneEngine.highlightShadowRangeEV),
            Float(tone.effectiveWhites * ToneEngine.whiteToneEV),
            Float(tone.effectiveBlacks * ToneEngine.blackToneEV))
        let hi = tone.whiteAnchorEV
        let lo = tone.blackAnchorEV
        upper = SIMD4(0, Float(hi * ToneEngine.highlightShelfEnd),
            Float(hi * ToneEngine.endShelfStart), Float(hi * ToneEngine.endShelfEnd))
        lower = SIMD4(0, Float(-lo * ToneEngine.shadowShelfEnd),
            Float(-lo * ToneEngine.blackShelfStart), Float(-lo * ToneEngine.blackShelfEnd))
        let pivot = Num.clamp(tone.tone.contrastPivot, -4, 4)
        let amount = Num.clamp(tone.tone.contrast, -100, 100)
        contrast = SIMD4(Float(pivot), Float(1 + 0.6 * amount / 100),
            Float(hi - pivot), Float(pivot - lo))
        // The floor is Num.safeLog2's existing default, not a LUT domain endpoint.
        policy = SIMD4(Float(ToneEngine.minContrastReachEV),
            Float(ToneEngine.contrastShoulderStart), amount == 0 ? 0 : 1, -20)
        let w = RGBColorSpace.rec2020.luminanceWeights
        luminance = SIMD4(Float(w.r), Float(w.g), Float(w.b), 0.18)
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        if b <= a { return x < a ? 0 : 1 }
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Float twin for kernel qualification. The existing Double ToneEngine remains
    /// the independent accuracy oracle; it must not call this implementation.
    public func apply(_ input: RGB) -> RGB {
        guard !isIdentity else { return input }
        let r = Float(input.r), g = Float(input.g), b = Float(input.b)
        let y = max(r * luminance.x + g * luminance.y + b * luminance.z, 0)
        let t = log2(max(y / luminance.w, exp2(policy.w)))
        var stops = amplitudes.x * Self.smooth(upper.x, upper.y, t)
            + amplitudes.y * Self.smooth(lower.x, lower.y, -t)
            + amplitudes.z * Self.smooth(upper.z, upper.w, t)
            + amplitudes.w * Self.smooth(lower.z, lower.w, -t)
        let d = t - contrast.x
        let reach = d >= 0 ? contrast.z : contrast.w
        if policy.z != 0 && reach > policy.x {
            let shoulder = Self.smooth(policy.y, 1, abs(d) / reach)
            // mapped(t) - t = d * (slope - 1) * (1 - shoulder).
            // Retain exact zero outside the contrast window rather than cancelling
            // two large EV values in the GPU's mapped-value arithmetic.
            stops += d * (contrast.y - 1) * (1 - shoulder)
        }
        let gain = exp2(stops)
        return RGB(Double(r * gain), Double(g * gain), Double(b * gain))
    }

    /// Same resolved uniforms and scalar operations as the Float twin. No shaper,
    /// RGB channel projection, exposure gain or spatial filtering is included.
    public static let kernelSource = """
    float lumenLocalToneSmooth(float a, float b, float x) {
        if (b <= a) { return step(a, x); }
        float u = clamp((x - a) / (b - a), 0.0, 1.0);
        return u * u * (3.0 - 2.0 * u);
    }
    kernel vec4 lumenLocalTone(__sample image, vec4 amplitudes, vec4 upper,
                               vec4 lower, vec4 contrast, vec4 policy,
                               vec4 luminance) {
        vec3 c = image.rgb;
        float y = max(dot(c, luminance.xyz), 0.0);
        float t = log2(max(y / luminance.w, exp2(policy.w)));
        float stops = amplitudes.x * lumenLocalToneSmooth(upper.x, upper.y, t)
            + amplitudes.y * lumenLocalToneSmooth(lower.x, lower.y, -t)
            + amplitudes.z * lumenLocalToneSmooth(upper.z, upper.w, t)
            + amplitudes.w * lumenLocalToneSmooth(lower.z, lower.w, -t);
        float d = t - contrast.x;
        float reach = d >= 0.0 ? contrast.z : contrast.w;
        if (policy.z != 0.0 && reach > policy.x) {
            float shoulder = lumenLocalToneSmooth(policy.y, 1.0, abs(d) / reach);
            stops += d * (contrast.y - 1.0) * (1.0 - shoulder);
        }
        return vec4(c * exp2(stops), image.a);
    }
    """
}
