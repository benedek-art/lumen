// LocalNoise.swift
// The mask panel's Noise and Colour Noise rows: the global classical engine, run
// inside a mask at S11.
//
// One definition of the engine a mask runs, read by both renderers. The CPU reference
// applies it with `ClassicalDenoise.scaled(noiseScale:).apply`, the GPU graph hands it to
// the same `gpuPlan` the S3 stage reads, so the two paths cannot disagree about what
// "local Noise 50" means — the arithmetic below exists once.
//
// It is the GLOBAL engine with two numbers changed, not a second denoiser. Luminance and
// Color come from the mask; Detail, Contrast and Smoothness are the photographer's own
// global settings, so a masked Noise row shrinks noise the way the Detail panel already
// does, only harder and only here. Hot pixels stay a whole-frame job (S3) — a stuck
// photosite is not a regional property.

import Foundation

public enum LocalNoise {

    /// The classical engine a mask's Noise / Colour Noise rows ask for, at full render
    /// scale, or nil when neither row can move a pixel.
    ///
    /// Unscaled on purpose: the caller applies the preview rule the same way S3 does
    /// (`scaled(noiseScale:)` on the CPU, `gpuPlan(noiseScale:)` on the GPU), so local
    /// and global noise reduction switch off together below
    /// `ClassicalDenoise.contributingNoiseScale` and never one without the other.
    ///
    /// Mask Amount scales both rows like every other local slider, and the product is
    /// clamped to the slider's own 0…100: Amount 200 does not reach a strength the
    /// global row cannot.
    public static func engine(for mask: Mask, plan: RenderPlan) -> ClassicalDenoise? {
        let scale = Num.clamp(mask.amount, 0, 200) / 100.0
        let luma = strength(mask.adjust.noise, scale: scale)
        let chroma = strength(mask.adjust.noiseChroma, scale: scale)
        guard luma > 0 || chroma > 0 else { return nil }
        let global = plan.classicalDenoise
        let engine = ClassicalDenoise(luma: luma, chroma: chroma, hotPixels: 0,
                                      lumaDetail: global.lumaDetail,
                                      lumaContrast: global.lumaContrast,
                                      colorDetail: global.colorDetail,
                                      colorSmoothness: global.colorSmoothness,
                                      profile: profile(for: mask, plan: plan),
                                      levels: global.levels)
        return engine.isIdentity ? nil : engine
    }

    /// The plan's sensor noise profile carried to the signal level S11 sees.
    ///
    /// The profile is calibrated on the decode (S3): Var(x) = a·x + b. By S11 the
    /// pixel has been multiplied by the global exposure (S6) and the mask's own exposure,
    /// so x' = g·x and Var(x') = g²(a·x + b) = (g·a)·x' + g²·b. Without this a mask
    /// over a frame pushed +2 EV would be denoised as though its noise were four times
    /// smaller than it is.
    ///
    /// AN APPROXIMATION, and the parts it leaves out are named so nobody reads more
    /// into it: the tone curve (S7), Highlights/Shadows, the colour stage's saturation
    /// gains and the grade (S9/S10) all reshape noise too, per pixel and per hue, and a
    /// single (a, b) pair cannot carry that. Exposure is the one gain that is uniform
    /// across the frame and large enough to matter, so it is the one modelled. White
    /// balance and printer-light gains are per channel and near one around neutral, and
    /// are left out for the same reason.
    public static func profile(for mask: Mask, plan: RenderPlan) -> NoiseProfile {
        let g = signalGain(for: mask, plan: plan)
        let p = plan.classicalDenoise.profile
        return NoiseProfile(a: g * p.a, b: g * g * p.b)
    }

    /// Global exposure gain × the mask's own exposure gain. The local half is
    /// `ToneEngine.exposureGain`'s rule (2^EV, clamped at ±10 EV) on the mask's scaled
    /// Exposure, which is what `ReferenceRenderer.LocalColourFront.exposureGain` and the
    /// GPU's local exposure matrix both apply.
    public static func signalGain(for mask: Mask, plan: RenderPlan) -> Double {
        let scale = Num.clamp(mask.amount, 0, 200) / 100.0
        let ev = mask.adjust.exposure.isFinite ? mask.adjust.exposure * scale : 0
        return plan.tone.exposureGain * pow(2, Num.clamp(ev, -10, 10))
    }

    private static func strength(_ slider: Double, scale: Double) -> Double {
        guard slider.isFinite else { return 0 }
        return Num.clamp(slider * scale, 0, 100)
    }
}
