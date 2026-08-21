// DenoiseEngine.swift
// The two denoise tiers, in f64 reference form: S3 profiled classical NR (VST + à-trous
// wavelet shrinkage + hot pixels) and the S2 AI splice (cached artifact, Amount blend,
// tile plan). Spec: docs/07-spec-denoise.md; pipeline placement docs/14 §S2–S3.
//
// Reference-implementation policy (docs/14 §1.4): the math is DEFINED here and the Metal
// kernels are measured against it. Nothing in this file may import a platform framework.
//
// What the spec pins, and what this file had to pin for it (docs/07 §12 open items):
//  - §12.3 wavelet level count is implied, never stated: the S3 export halo is 24 px =
//    "wavelet support at deepest level", and the B3-spline à-trous support at level L is
//    2^(L+1) − 1 taps, so 5 levels (31 px support, 16 px hole spacing) is the top of the
//    implementable 4–5 band. `defaultLevels` = 5, clamped down on small extents.
//  - §12.4 the generalized Anscombe VST is named, not written: `VST` below writes both the
//    forward transform and Makitalo–Foi's exact-unbiased inverse.
//  - §12.5 the Hot Pixels k curve is undefined: `ClassicalDenoise.hotPixelK` defines it.
//  - §12.6 the slider→threshold calibration against LR feel is unmeasured: the mappings in
//    `lumaK` / `chromaK` / the band scalers are the shipped first cut, and every constant
//    that a calibration pass would move is a named `public static let` here.
//  - §12.7 `ClassicNR` carries only luma/chroma/hotPixels on the wire. The four LR-parity
//    sub-sliders (Luminance Detail / Luminance Contrast / Color Detail / Color Smoothness)
//    are engine parameters with documented defaults until the recipe schema grows them —
//    this file does not invent wire format.
//
// Everything here is per-pixel f64 over f32 storage, single-threaded, allocation-simple.
// The spatial primitives (à-trous analysis/synthesis, guided filter, blurs) live in
// SpatialOps.swift and are called, never re-implemented.

import Foundation

// MARK: - Noise profile

/// The Poisson–Gaussian sensor noise model (docs/07 §2.2): `variance = a·signal + b`,
/// with `a` the shot (signal-proportional) term and `b` the read (signal-independent)
/// term, both in the units of the linear working image. One profile per (camera, ISO).
///
/// The same `(a, b)` store conditions the Tier-2 network's noise map (docs/07 §3.3), so
/// this type is a shared dependency of S2 and S3 — build it once, in Tier 1.
public struct NoiseProfile: Sendable, Equatable {

    /// Shot term: variance contributed per unit of signal.
    public let a: Double
    /// Read term: variance floor at zero signal.
    public let b: Double

    /// Variance never reaches exactly zero — a zero σ would make every threshold and
    /// every hot-pixel test degenerate.
    public static let minimumVariance: Double = 1e-12

    public init(a: Double, b: Double) {
        self.a = a.isFinite ? Swift.max(a, 0) : 0
        self.b = b.isFinite ? Swift.max(b, NoiseProfile.minimumVariance) : NoiseProfile.minimumVariance
    }

    /// Modelled variance at a signal level (clamped non-negative).
    public func variance(at signal: Double) -> Double {
        let s = signal.isFinite ? Swift.max(signal, 0) : 0
        return Swift.max(a * s + b, NoiseProfile.minimumVariance)
    }

    /// Modelled standard deviation at a signal level.
    public func sigma(at signal: Double) -> Double {
        variance(at: signal).squareRoot()
    }

    // MARK: Anchored per-ISO profiles

    // Seed curve for a full-frame body in the linear working space, expressed as anchors
    // in log2(ISO) with log2(a) and log2(b) interpolated linearly between them (both terms
    // are power laws in gain, so log-log is the interpolation that keeps the shape).
    //
    // Provenance discipline (docs/07 §2.4, §10): darktable's noiseprofiles.json is GPL, so
    // its NUMBERS may be read as calibration facts for our own bodies but the file is never
    // bundled and never copied wholesale. These anchors are a physically-derived generic
    // seed — a ≈ ISO¹ (shot noise scales with gain), b ≈ ISO^1.5 (read noise between the
    // ISO-invariant and the fully-analog cases) — and every real body replaces them with a
    // measured profile or with `estimate(from:)`. No profile UI is ever shown (§2.4).

    private static let shotAnchors: [(x: Double, y: Double)] = [
        (x: log2(100.0), y: log2(1.00e-5)),
        (x: log2(400.0), y: log2(4.00e-5)),
        (x: log2(1600.0), y: log2(1.60e-4)),
        (x: log2(6400.0), y: log2(6.40e-4)),
        (x: log2(25600.0), y: log2(2.56e-3)),
        (x: log2(102400.0), y: log2(1.024e-2)),
    ]

    private static let readAnchors: [(x: Double, y: Double)] = [
        (x: log2(100.0), y: log2(1.0e-8)),
        (x: log2(400.0), y: log2(6.0e-8)),
        (x: log2(1600.0), y: log2(4.0e-7)),
        (x: log2(6400.0), y: log2(3.0e-6)),
        (x: log2(25600.0), y: log2(2.4e-5)),
        (x: log2(102400.0), y: log2(2.0e-4)),
    ]

    /// The profile for an ISO, interpolated between the documented anchors in log2(ISO)
    /// and clamped beyond the ends (the same clamped-lerp rule §4 fixes for every anchor
    /// table in the engine).
    public static func forISO(_ iso: Double) -> NoiseProfile {
        let clean = (iso.isFinite && iso > 0) ? iso : 100.0
        let l = log2(Swift.max(clean, 1.0))
        let a = exp2(Num.interpolateAnchors(shotAnchors, at: l))
        let b = exp2(Num.interpolateAnchors(readAnchors, at: l))
        return NoiseProfile(a: a, b: b)
    }

    // MARK: Self-calibration from the image itself

    /// Block side for the local-statistics estimator. 64 samples per block is enough for a
    /// stable variance and small enough that a block usually lands inside one flat region.
    public static let estimatorBlock: Int = 8

    /// Number of signal-level bins the (mean, variance) cloud is bucketed into.
    public static let estimatorBins: Int = 16

    /// The estimator takes the 10th percentile of block variances inside each signal bin as
    /// "this bin's flat-region variance". Under pure noise the block variance is χ²-
    /// distributed with 63 degrees of freedom, whose 10th percentile sits at ≈0.78 of the
    /// true variance, so the percentile is divided back out by this factor.
    public static let flatBlockCorrection: Double = 1.0 / 0.78

    /// Estimate `(a, b)` from one plane's own local variance-vs-mean statistics — the
    /// "unknown (camera, ISO) pair" path of docs/07 §2.4, which measures on first encounter
    /// and caches in the catalog so every later frame from that body is free.
    ///
    /// Estimator, in full:
    ///  1. Tile the plane into non-overlapping 8×8 blocks; for each, take the sample mean μ
    ///     and the unbiased sample variance v.
    ///  2. Bucket the blocks into 16 bins by μ across the observed range. Texture only ever
    ///     *raises* a block's variance, so within a bin the low-variance blocks are the flat
    ///     ones: take the 10th percentile of v as the bin's noise variance and undo the
    ///     percentile's own χ² bias (`flatBlockCorrection`).
    ///  3. Weighted least squares of the surviving (μ, v) points against `v = a·μ + b`,
    ///     weighted by bin population.
    ///  4. Clamp `a ≥ 0`, `b ≥ minimumVariance`. Degenerate inputs (too few blocks, a flat
    ///     plane, a singular normal equation) fall back to `a = 0` with `b` set from the
    ///     10th percentile of all block variances.
    public static func estimate(from plane: Plane) -> NoiseProfile {
        let w = plane.width
        let h = plane.height
        let block = estimatorBlock
        guard w >= block && h >= block else {
            return NoiseProfile(a: 0, b: planeVariance(plane))
        }

        let bx = w / block
        let by = h / block
        var means: [Double] = []
        var variances: [Double] = []
        means.reserveCapacity(bx * by)
        variances.reserveCapacity(bx * by)

        let n = Double(block * block)
        for j in 0..<by {
            let y0 = j * block
            for i in 0..<bx {
                let x0 = i * block
                var s = 0.0
                var s2 = 0.0
                for y in y0..<(y0 + block) {
                    let row = y * w
                    for x in x0..<(x0 + block) {
                        let v = Double(plane.values[row + x])
                        let f = v.isFinite ? v : 0
                        s += f
                        s2 += f * f
                    }
                }
                let m = s / n
                let variance = Swift.max((s2 - n * m * m) / (n - 1), 0)
                means.append(m)
                variances.append(variance)
            }
        }

        guard means.count >= 4 else {
            return NoiseProfile(a: 0, b: percentile(variances, 0.1) * flatBlockCorrection)
        }

        var lo = Double.infinity
        var hi = -Double.infinity
        for m in means {
            lo = Swift.min(lo, m)
            hi = Swift.max(hi, m)
        }
        let span = hi - lo
        guard span > 0 && span.isFinite else {
            return NoiseProfile(a: 0, b: percentile(variances, 0.1) * flatBlockCorrection)
        }

        let binCount = Swift.max(estimatorBins, 1)
        var binVariances = [[Double]](repeating: [], count: binCount)
        var binMeanSum = [Double](repeating: 0, count: binCount)
        var binPopulation = [Int](repeating: 0, count: binCount)
        for i in 0..<means.count {
            var idx = Int((means[i] - lo) / span * Double(binCount))
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            binVariances[idx].append(variances[i])
            binMeanSum[idx] += means[i]
            binPopulation[idx] += 1
        }

        var px: [Double] = []
        var py: [Double] = []
        var pw: [Double] = []
        for k in 0..<binCount {
            let c = binPopulation[k]
            if c < 6 { continue }
            let flat = percentile(binVariances[k], 0.1) * flatBlockCorrection
            px.append(binMeanSum[k] / Double(c))
            py.append(flat)
            pw.append(Double(c))
        }

        guard px.count >= 2 else {
            return NoiseProfile(a: 0, b: percentile(variances, 0.1) * flatBlockCorrection)
        }

        var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
        for i in 0..<px.count {
            let wt = pw[i]
            sw += wt
            swx += wt * px[i]
            swy += wt * py[i]
            swxx += wt * px[i] * px[i]
            swxy += wt * px[i] * py[i]
        }
        guard sw > 0 else {
            return NoiseProfile(a: 0, b: percentile(variances, 0.1) * flatBlockCorrection)
        }
        let den = sw * swxx - swx * swx
        guard abs(den) > 1e-30 && den.isFinite else {
            return NoiseProfile(a: 0, b: swy / sw)
        }
        var slope = (sw * swxy - swx * swy) / den
        if !slope.isFinite || slope < 0 { slope = 0 }
        var intercept = (swy - slope * swx) / sw
        if !intercept.isFinite { intercept = 0 }
        if intercept < 0 {
            // A negative read term is physically impossible; refit the shot term through
            // the origin instead of shipping a profile that under-estimates the floor.
            intercept = 0
            if swxx > 1e-30 { slope = Swift.max(swxy / swxx, 0) }
        }
        return NoiseProfile(a: slope, b: intercept)
    }

    private static func planeVariance(_ plane: Plane) -> Double {
        let n = plane.values.count
        guard n > 1 else { return minimumVariance }
        var s = 0.0
        var s2 = 0.0
        for v in plane.values {
            let f = Double(v)
            let g = f.isFinite ? f : 0
            s += g
            s2 += g * g
        }
        let m = s / Double(n)
        return Swift.max((s2 - Double(n) * m * m) / Double(n - 1), minimumVariance)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return minimumVariance }
        var sorted = values
        sorted.sort()
        var idx = Int(Num.saturate(p) * Double(sorted.count - 1))
        if idx < 0 { idx = 0 }
        if idx >= sorted.count { idx = sorted.count - 1 }
        return Swift.max(sorted[idx], minimumVariance)
    }
}

// MARK: - Variance-stabilizing transform

/// The generalized Anscombe transform (docs/07 §2.2). Shrinkage runs in VST space, where
/// the Poisson–Gaussian noise of `NoiseProfile` is approximately additive white Gaussian
/// with unit variance; the inverse restores linearity on the way out.
///
/// Forward (the standard GAT for `var = a·x + b`):
/// ```
/// f(x) = (2/a)·sqrt(a·x + 3a²/8 + b)
/// ```
/// Derivation of the inverse: with `Y = X/a + b/a²`, `E[Y] = Var[Y] = λ = x/a + b/a²`, so
/// `f` is exactly the classical Anscombe transform `2·sqrt(Y + 3/8)` of a Poisson variate
/// with mean λ. The algebraic inverse `λ = D²/4 − 3/8` is biased for small λ; docs/07
/// requires the *exact unbiased* inverse, which is Makitalo–Foi's closed form:
/// ```
/// λ̂(D) = D²/4 + ¼·sqrt(3/2)·D⁻¹ − 11/8·D⁻² + 5/8·sqrt(3/2)·D⁻³ − 1/8
/// x̂    = a·λ̂ − b/a
/// ```
/// `λ̂` is exactly 0 at `D = 2·sqrt(3/8)` (the smallest value the forward transform can
/// produce) and the negative powers blow up below it, so D is clamped there first.
///
/// Degenerate profiles are handled rather than divided by: `a ≈ 0` is pure read noise and
/// collapses to the plain scaling `x/sqrt(b)`; `a ≈ 0 ∧ b ≈ 0` is the identity.
public enum VST {

    /// Below this shot term the transform degenerates and the Gaussian branch is used.
    public static let minimumShot: Double = 1e-12

    /// The smallest value `forward` can return: `2·sqrt(3/8)`.
    public static let minimumForward: Double = 1.2247448713915889

    /// Linear value → variance-stabilized value.
    public static func forward(_ x: Double, profile: NoiseProfile) -> Double {
        guard x.isFinite else { return 0 }
        let a = profile.a
        let b = profile.b
        if a <= minimumShot {
            guard b > NoiseProfile.minimumVariance else { return x }
            let s = b.squareRoot()
            return s > 0 ? x / s : x
        }
        let u = a * x + 0.375 * a * a + b
        guard u > 0 else { return 0 }
        return (2.0 / a) * u.squareRoot()
    }

    /// The inverse to use when only `shrinkage` of the full denoising strength was
    /// actually applied, 0…1.
    ///
    /// The unbiased inverse is the right one for a coefficient that has been
    /// *estimated* — it compensates the forward transform's bias, and its correction
    /// tends to a constant `a/4` in the highlights. Applied where nothing was shrunk,
    /// that constant is not a debias, it is a pedestal: at ISO 102400 pure black came
    /// back at 2.3e-3 linear, a milky lift that appeared in full the instant the
    /// Luminance slider left zero. Blending toward the algebraic inverse in proportion
    /// to how much shrinking actually happened makes the slider a slider again, and at
    /// full strength this is exactly the inverse docs/07 mandates.
    public static func inverse(_ y: Double, profile: NoiseProfile,
                               shrinkage: Double) -> Double {
        let t = Num.saturate(shrinkage)
        if t >= 1 { return inverse(y, profile: profile) }
        if t <= 0 { return algebraicInverse(y, profile: profile) }
        return Num.mix(algebraicInverse(y, profile: profile),
                       inverse(y, profile: profile), t)
    }

    /// Variance-stabilized value → linear value, using the exact unbiased inverse.
    /// This is the inverse docs/07 mandates; it is deliberately NOT the algebraic inverse,
    /// so `inverse(forward(x))` differs from `x` by the (small) debiasing term. The
    /// round-trip identity golden runs against `algebraicInverse`.
    public static func inverse(_ y: Double, profile: NoiseProfile) -> Double {
        guard y.isFinite else { return 0 }
        let a = profile.a
        let b = profile.b
        if a <= minimumShot {
            guard b > NoiseProfile.minimumVariance else { return y }
            return y * b.squareRoot()
        }
        let d = Swift.max(y, minimumForward)
        guard d > 0 else { return -b / a }
        let inv1 = 1.0 / d
        let inv2 = inv1 * inv1
        let inv3 = inv2 * inv1
        let root32 = 1.224744871391589      // sqrt(3/2)
        var lambda = 0.25 * d * d
            + 0.25 * root32 * inv1
            - 1.375 * inv2
            + 0.625 * root32 * inv3
            - 0.125
        if !lambda.isFinite || lambda < 0 { lambda = 0 }
        return a * lambda - b / a
    }

    /// The plain algebraic inverse of `forward`. Round-trips exactly (to f64 rounding) and
    /// exists for the zero-shrinkage identity golden docs/07 §12.4 asks for.
    public static func algebraicInverse(_ y: Double, profile: NoiseProfile) -> Double {
        guard y.isFinite else { return 0 }
        let a = profile.a
        let b = profile.b
        if a <= minimumShot {
            guard b > NoiseProfile.minimumVariance else { return y }
            return y * b.squareRoot()
        }
        return 0.25 * a * y * y - 0.375 * a - b / a
    }
}

// MARK: - Tier 1: profiled classical NR

/// S3 (docs/07 §2): VST → à-trous decomposition in a decorrelating luma/chroma basis →
/// per-scale edge-aware soft shrinkage → reconstruct → inverse VST, plus a separate
/// hot-pixel median-deviation pass.
///
/// **Slider → threshold mapping**, in one place (docs/07 §2.3; calibration is §12.6's open
/// item, so every constant below is named and tunable):
///
/// | Slider | Symbol | Effect on the soft threshold `T(level, x)` |
/// |---|---|---|
/// | Luminance | `k_L = 4·(luma/100)^0.7` | Master luma shrink scale, in units of the per-scale noise σ. Gentle by doctrine: even at 100 it tops out at 4σ. |
/// | Luminance Detail | `1.5 − detail/100` | Multiplies the luma threshold. 50 ⇒ ×1.0; higher ⇒ lower threshold ⇒ texture (and noise) survives. This slider *is* the threshold. |
/// | Luminance Contrast | `1 − 0.9·(contrast/100)·coarse(level)` | Biases shrinkage away from the coarse luma bands — preserves luminance contrast at the cost of mottling, LR's own tradeoff. |
/// | Color | `k_C = 8·(chroma/100)^0.6` | Master chroma shrink scale. Aggressive by doctrine: reaches 8σ, and chroma shrinkage is visually nearly free. |
/// | Color Detail | `1 − (detail/100)·edge(x)` | Spatially reduces the chroma threshold on chroma edges, so thin colour edges survive. |
/// | Color Smoothness | `1 + 3·(smooth/100)·coarse(level)`, plus a guided-filter blotch pass | Extends shrinkage into the coarsest chroma bands, which is where blotches live. |
/// | Hot Pixels | `k = 2 + 10·(1 − h/100)²` | Median-deviation gate, separate pass. See `hotPixelK`. |
///
/// `coarse(level)` is 0 at the finest band and 1 at the coarsest; `edge(x)` is the
/// smoothstepped, blur-stabilized gradient magnitude in [0,1]. Luma additionally carries a
/// fixed `lumaEdgeProtection` so the luma pass is edge-aware per §2.3.
public struct ClassicalDenoise: Sendable {

    // MARK: Stored parameters

    /// Luminance, 0…100.
    public let luma: Double
    /// Color, 0…100.
    public let chroma: Double
    /// Hot Pixels, 0…100.
    public let hotPixels: Double
    /// Luminance Detail, 0…100 (engine parameter; docs/07 default 50).
    public let lumaDetail: Double
    /// Luminance Contrast, 0…100 (engine parameter; docs/07 default 0).
    public let lumaContrast: Double
    /// Color Detail, 0…100 (engine parameter; docs/07 default 50).
    public let colorDetail: Double
    /// Color Smoothness, 0…100 (engine parameter; docs/07 default 50).
    public let colorSmoothness: Double
    /// The (camera, ISO) noise model driving every threshold.
    public let profile: NoiseProfile
    /// Requested à-trous level count; clamped to what the extent supports.
    public let levels: Int

    // MARK: Named constants (the calibration surface, docs/07 §12.6)

    /// 5 levels ⇒ 31 px support at the deepest band, the top of the 4–5 band the 24 px S3
    /// halo allows (docs/07 §12.3).
    public static let defaultLevels: Int = 5
    /// Hardest level count the engine will honour, so a bad caller cannot blow the halo.
    public static let maximumLevels: Int = 6

    /// Luma master scale at Luminance 100, in σ.
    public static let lumaMaxK: Double = 4.0
    /// Chroma master scale at Color 100, in σ.
    public static let chromaMaxK: Double = 4.0
    /// How much a strong luma edge backs the luma threshold off.
    public static let lumaEdgeProtection: Double = 0.80
    /// How far Luminance Contrast can pull the coarsest luma band's threshold down.
    public static let lumaContrastReach: Double = 0.90
    /// How far Color Smoothness can push the coarsest chroma band's threshold up.
    public static let colorSmoothnessReach: Double = 3.0
    /// Guided-filter radius for the coarse chroma blotch pass.
    public static let blotchRadius: Int = 8
    /// Guided-filter regularization for the blotch pass, in squared luminance units.
    public static let blotchEpsilon: Double = 1e-4
    /// Blur σ stabilizing the edge maps before the gradient is taken.
    public static let edgeBlurSigma: Double = 1.5
    /// Edge smoothstep knees, in units of the blurred plane's own noise σ.
    public static let edgeKneeLow: Double = 3.0
    public static let edgeKneeHigh: Double = 12.0

    /// Per-scale σ of the B3-spline à-trous detail coefficients for unit-variance white
    /// noise (Starck & Murtagh). Because shrinkage runs in VST space the input σ *is* 1, so
    /// the threshold at level j is simply `k · atrousDetailSigma[j]`.
    ///
    /// Assumption on SpatialOps: `atrousWavelet` uses the standard un-normalized scheme
    /// `c_{j+1} = h_j ∗ c_j`, `w_{j+1} = c_j − c_{j+1}`, with the 5-tap B3-spline kernel.
    /// A different normalization would rescale this table, nothing else.
    public static let atrousDetailSigma: [Double] = [0.8907, 0.2007, 0.0856, 0.0413, 0.0205, 0.0103]

    /// darktable's decorrelating Y0U0V0 basis (docs/07 §2.3) in its orthonormal form, so
    /// unit-variance VST noise stays unit-variance in the rotated planes and the inverse is
    /// the transpose — no matrix inversion, no conditioning question.
    public static let toY0U0V0: Mat3 = Mat3(
        0.5773502691896258, 0.5773502691896258, 0.5773502691896258,
        0.7071067811865475, 0.0, -0.7071067811865475,
        0.4082482904638631, -0.8164965809277261, 0.4082482904638631)

    /// Inverse of `toY0U0V0` — the transpose, because the basis is orthonormal.
    public static let fromY0U0V0: Mat3 = ClassicalDenoise.toY0U0V0.transposed

    // MARK: Initialization

    /// Full parameter form. Every slider is clamped to its documented range here, so no
    /// downstream code has to re-check.
    public init(luma: Double, chroma: Double, hotPixels: Double,
                lumaDetail: Double, lumaContrast: Double,
                colorDetail: Double, colorSmoothness: Double,
                profile: NoiseProfile, levels: Int) {
        self.luma = ClassicalDenoise.clampSlider(luma)
        self.chroma = ClassicalDenoise.clampSlider(chroma)
        self.hotPixels = ClassicalDenoise.clampSlider(hotPixels)
        self.lumaDetail = ClassicalDenoise.clampSlider(lumaDetail)
        self.lumaContrast = ClassicalDenoise.clampSlider(lumaContrast)
        self.colorDetail = ClassicalDenoise.clampSlider(colorDetail)
        self.colorSmoothness = ClassicalDenoise.clampSlider(colorSmoothness)
        self.profile = profile
        self.levels = Swift.min(Swift.max(levels, 1), ClassicalDenoise.maximumLevels)
    }

    /// Build from the shipped recipe struct. All seven sliders are on the wire now
    /// (docs/07 §12.7 closed), so this reads every one of them and invents nothing: a
    /// hand-set Luminance Detail reaches the engine, and the ISO-adaptive resolution
    /// of docs/07 §2.1 happens once at import in `ISODefaults.classic(forISO:)` rather
    /// than being re-derived on every render.
    ///
    /// That ordering is the point. Resolving the adaptive defaults here would have made
    /// them un-overridable — the engine would recompute them from the profile and
    /// discard whatever the panel showed — which is precisely how a slider ends up
    /// storing a value nothing reads.
    public init(_ params: ClassicNR, profile: NoiseProfile) {
        self.init(luma: params.luma,
                  chroma: params.chroma,
                  hotPixels: params.hotPixels,
                  lumaDetail: params.lumaDetail,
                  lumaContrast: params.lumaContrast,
                  colorDetail: params.colorDetail,
                  colorSmoothness: params.colorSmoothness,
                  profile: profile,
                  levels: ClassicalDenoise.defaultLevels)
    }

    private static func clampSlider(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Num.clamp(v, 0, 100)
    }

    /// How noisy this profile is, on a 0…1 scale anchored at σ(mid-gray) = 0.004 (clean) and
    /// 0.03 (very noisy). ISO 6400 on the seed curve lands at ≈0.5.
    public static func noisiness(of profile: NoiseProfile) -> Double {
        let s = profile.sigma(at: 0.18)
        let lo = Num.safeLog2(0.004)
        let hi = Num.safeLog2(0.030)
        guard hi > lo else { return 0 }
        return Num.saturate((Num.safeLog2(Swift.max(s, 1e-9)) - lo) / (hi - lo))
    }

    // MARK: Slider mappings

    /// Luminance → master shrink scale in σ. Gentle by doctrine (docs/07 §2.3).
    ///
    /// The exponent is what spreads the control across its travel, and it was 0.7 —
    /// concave, so the curve reached its useful range early and spent the rest of the
    /// slider past it. A soft threshold at kσ leaves roughly this much of a unit band:
    ///
    ///     k      0.5   1.0   1.5   2.0   2.5   3.0   3.5   4.0
    ///     kept  64.7  38.7  21.2  10.6   4.7   1.9   0.7   0.1  %
    ///
    /// so everything past about 3σ is the same picture. At 0.7 the slider reached 2.46σ
    /// by 50 and 3.12σ by 70: measured on an ISO 6400 flat field, luma noise kept ran
    /// 47.8% / 26.9% / 15.4% / 8.9% / 5.4% at sliders 10…50 and then 3.7 / 3.0 / 2.7 /
    /// 2.6 / 2.6 — the top forty points of travel were worth 2.8 points of noise while
    /// continuing to eat texture, since fine-band correlation with real detail falls
    /// from 0.155 at 50 to 0.025 at 100.
    ///
    /// Linear in k spreads it evenly: 38.7% kept at 25, 10.6% at 50, 1.9% at 75, 0.1%
    /// at 100. Every quarter of the slider now buys about as much as the last.
    public static func lumaK(_ slider: Double) -> Double {
        let s = Num.saturate(clampSlider(slider) / 100)
        guard s > 0 else { return 0 }
        return lumaMaxK * pow(s, 1.0)
    }

    /// Color → master shrink scale in σ. Aggressive by doctrine (docs/07 §2.3).
    ///
    /// `chromaMaxK` was 8.0, which is more than twice the point where a soft threshold
    /// has already annihilated the band. The curve crossed 3.5σ at slider 25, so
    /// **three quarters of the Colour slider did nothing at all** — measured, chroma
    /// noise kept went 100% / 10.5% / 2.8% at 0 / 10 / 20 and then sat at 2.0% from 25
    /// to 100. Worse, every ISO-adaptive anchor from ISO 400 up resolves into that dead
    /// zone, so the Colour half of the ISO defaults was decorative.
    ///
    /// Aggressive-by-doctrine is kept, and it is a real constraint rather than a
    /// preference: `testColourRemovesChromaNoiseAndLeavesLumaAlone` requires Colour 25 —
    /// Lightroom's default, and the setting most photographs are edited at — to leave
    /// under a fifth of the chroma noise. An exponent of 0.8 spread the travel nicely
    /// and left 25.9%, so it failed, correctly. 0.65 leaves 18.0% at 25 and still
    /// spreads the rest: 4.4% at 50, 1.0% at 75, 0.1% at 100, against the old curve's
    /// 2.0% flat from 25 upward.
    public static func chromaK(_ slider: Double) -> Double {
        let s = Num.saturate(clampSlider(slider) / 100)
        guard s > 0 else { return 0 }
        return chromaMaxK * pow(s, 0.65)
    }

    /// Hot Pixels → the median-deviation gate `k` (docs/07 §12.5, defined here).
    ///
    /// ```
    /// k(0)   = +∞      (no-op — the caller skips the pass entirely)
    /// k(h)   = 2 + 10·(1 − h/100)²      for h > 0
    /// k(50)  = 4.5,  k(100) = 2.0
    /// ```
    /// Quadratic rather than linear so the top half of the slider's travel is the useful
    /// half: below k ≈ 4.5 the gate starts reaching ordinary specular detail, and the
    /// squared falloff keeps that region spread across 50 points of slider instead of 15.
    public static func hotPixelK(_ slider: Double) -> Double {
        let h = clampSlider(slider)
        guard h > 0 else { return .infinity }
        let t = 1 - h / 100
        return 2.0 + 10.0 * t * t
    }

    /// Per-scale detail σ, extended past the table by the observed halving per octave.
    public static func detailSigma(level: Int) -> Double {
        let table = atrousDetailSigma
        guard !table.isEmpty else { return 1 }
        if level <= 0 { return table[0] }
        if level < table.count { return table[level] }
        var s = table[table.count - 1]
        var remaining = level - (table.count - 1)
        while remaining > 0 {
            s *= 0.5
            remaining -= 1
        }
        return s
    }

    /// Levels actually usable at this extent: a level's 2^(L+1) − 1 tap support must fit
    /// inside the shorter side, or the deepest band is all boundary.
    public func effectiveLevels(width: Int, height: Int) -> Int {
        let m = Swift.min(width, height)
        var l = 0
        while l < levels {
            let support = (1 << (l + 2)) - 1
            if support > m { break }
            l += 1
        }
        return Swift.max(l, 1)
    }

    // MARK: The pass

    /// How much of the full shrinking strength is actually in play. The unbiased
    /// inverse's asymptotic correction is a debias for an estimated coefficient and a
    /// pedestal for an unshrunk one, so it is applied in proportion — see
    /// `VST.inverse(_:profile:shrinkage:)`.
    public var shrinkageFraction: Double {
        Num.saturate(Swift.max(ClassicalDenoise.lumaK(luma) / ClassicalDenoise.lumaMaxK,
                               ClassicalDenoise.chromaK(chroma) / ClassicalDenoise.chromaMaxK))
    }

    /// True when this configuration cannot move a pixel, so a caller can skip the whole
    /// stage rather than run an identity through forty graph nodes.
    public var isIdentity: Bool {
        hotPixels <= 0 && ClassicalDenoise.lumaK(luma) <= 0
            && ClassicalDenoise.chromaK(chroma) <= 0
    }

    /// Run Tier 1 over a linear scene-referred buffer. `space` supplies the luminance
    /// weights for the guided-filter guide, so the blotch pass follows real luminance
    /// structure rather than an assumed Rec.709 weighting.
    ///
    /// Alpha is carried through untouched. With every slider at 0 this returns its input
    /// bit-for-bit — the VST round trip is never run for nothing, which is what keeps
    /// "denoise off" free.
    ///
    /// It is also what the first slider step used to cost. Skipping the round trip at
    /// zero is not the same as the round trip being harmless just above zero: at
    /// Luminance 1 the whole image went through it, and the unbiased inverse lifted
    /// every pixel by a constant. `shrinkageFraction` is what makes the step small
    /// instead of the full pedestal.
    public func apply(_ image: ImageBuffer, space: RGBColorSpace = .rec2020) -> ImageBuffer {
        var work = image
        if hotPixels > 0 {
            work = hotPixelPass(work)
        }

        let kL = ClassicalDenoise.lumaK(luma)
        let kC = ClassicalDenoise.chromaK(chroma)
        guard kL > 0 || kC > 0 else { return work }

        let shrinkage = shrinkageFraction

        let w = work.width
        let h = work.height
        let levelCount = effectiveLevels(width: w, height: h)

        // 1. VST per channel, then rotate into the decorrelating basis. Both steps are
        //    per-pixel, so they fuse into one traversal.
        var p0 = Plane(width: w, height: h)
        var p1 = Plane(width: w, height: h)
        var p2 = Plane(width: w, height: h)
        let rotate = ClassicalDenoise.toY0U0V0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let c = work[x, y]
                let v = RGB(VST.forward(c.r, profile: profile),
                            VST.forward(c.g, profile: profile),
                            VST.forward(c.b, profile: profile))
                let d = rotate.apply(v)
                p0.values[row + x] = Float(d.r)
                p1.values[row + x] = Float(d.g)
                p2.values[row + x] = Float(d.b)
            }
        }

        // 2. Edge maps. Luma edges come from the luma plane; chroma edges from the chroma
        //    magnitude, so a saturated edge on flat luma still protects itself.
        let zeroEdge = Plane(width: w, height: h)
        var lumaEdge = zeroEdge
        if kL > 0 {
            lumaEdge = ClassicalDenoise.edgeMap(p0,
                                                blurSigma: ClassicalDenoise.edgeBlurSigma,
                                                lo: ClassicalDenoise.edgeKneeLow,
                                                hi: ClassicalDenoise.edgeKneeHigh)
        }
        var chromaEdge = zeroEdge
        if kC > 0 {
            var magnitude = Plane(width: w, height: h)
            let n = magnitude.values.count
            if p1.values.count == n && p2.values.count == n {
                for i in 0..<n {
                    let u = Double(p1.values[i])
                    let v = Double(p2.values[i])
                    magnitude.values[i] = Float((u * u + v * v).squareRoot())
                }
            }
            chromaEdge = ClassicalDenoise.edgeMap(magnitude,
                                                  blurSigma: ClassicalDenoise.edgeBlurSigma,
                                                  lo: ClassicalDenoise.edgeKneeLow,
                                                  hi: ClassicalDenoise.edgeKneeHigh)
        }

        // 3. Shrinkage, per plane, in VST space.
        if kL > 0 {
            p0 = shrink(p0, thresholds: lumaThresholds(levels: levelCount),
                        edge: lumaEdge, edgeProtection: ClassicalDenoise.lumaEdgeProtection)
        }
        if kC > 0 {
            let smooth = colorSmoothness / 100
            let protection = colorDetail / 100
            let thresholds = chromaThresholds(levels: levelCount)
            p1 = shrink(p1, thresholds: thresholds,
                        edge: chromaEdge, edgeProtection: protection)
            p2 = shrink(p2, thresholds: thresholds,
                        edge: chromaEdge, edgeProtection: protection)

            // Large-scale chroma blotches survive band shrinkage because they *are* the
            // coarse band; a luminance-guided edge-preserving smooth is what removes them
            // without bleeding colour across an edge.
            let blotch = Num.saturate(smooth) * Num.saturate(chroma / 100)
            if blotch > 0 {
                let guide = work.luminancePlane(space: space)
                let mixAmount = 0.5 * blotch
                let f1 = SpatialOps.guidedFilter(input: p1, guide: guide,
                                                 radius: ClassicalDenoise.blotchRadius,
                                                 epsilon: ClassicalDenoise.blotchEpsilon)
                let f2 = SpatialOps.guidedFilter(input: p2, guide: guide,
                                                 radius: ClassicalDenoise.blotchRadius,
                                                 epsilon: ClassicalDenoise.blotchEpsilon)
                p1 = ClassicalDenoise.mixPlanes(p1, f1, mixAmount)
                p2 = ClassicalDenoise.mixPlanes(p2, f2, mixAmount)
            }
        }

        // 4. Rotate back and invert the VST. Alpha rides along in `out`'s untouched slot.
        var out = work
        let unrotate = ClassicalDenoise.fromY0U0V0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let d = RGB(Double(p0.values[row + x]),
                            Double(p1.values[row + x]),
                            Double(p2.values[row + x]))
                let v = unrotate.apply(d)
                out[x, y] = RGB(VST.inverse(v.r, profile: profile, shrinkage: shrinkage),
                                VST.inverse(v.g, profile: profile, shrinkage: shrinkage),
                                VST.inverse(v.b, profile: profile, shrinkage: shrinkage))
            }
        }
        return out
    }

    /// The per-band soft-threshold base for the luma plane, in units of the VST plane's
    /// unit noise σ. **One definition, read by both paths**: the CPU reference shrinks
    /// with exactly this array and the GPU stage uploads exactly this array, so the two
    /// cannot drift into disagreeing about what a slider means.
    ///
    /// `Luminance` sets the master scale, `Luminance Detail` multiplies the threshold
    /// (`1.5 − detail/100`, so 50 ⇒ ×1.0), and `Luminance Contrast` pulls the coarse
    /// bands' thresholds down so coarse luminance structure survives — at the cost of
    /// mottling, which is LR's own tradeoff.
    public func lumaThresholds(levels levelCount: Int) -> [Double] {
        let k = ClassicalDenoise.lumaK(luma)
        let detailScale = 1.5 - lumaDetail / 100
        let contrast = lumaContrast / 100
        let coarseDivisor = Double(Swift.max(levelCount - 1, 1))
        guard k > 0 && detailScale > 0 else {
            return [Double](repeating: 0, count: Swift.max(levelCount, 0))
        }
        return (0..<Swift.max(levelCount, 0)).map { j in
            let coarse = Double(j) / coarseDivisor
            let band = Swift.max(1 - ClassicalDenoise.lumaContrastReach * contrast * coarse, 0)
            return k * detailScale * ClassicalDenoise.detailSigma(level: j) * band
        }
    }

    /// The per-band soft-threshold base for both chroma planes. `Colour Smoothness`
    /// pushes the coarse bands' thresholds up, which is where blotches live.
    public func chromaThresholds(levels levelCount: Int) -> [Double] {
        let k = ClassicalDenoise.chromaK(chroma)
        let smooth = colorSmoothness / 100
        let coarseDivisor = Double(Swift.max(levelCount - 1, 1))
        guard k > 0 else {
            return [Double](repeating: 0, count: Swift.max(levelCount, 0))
        }
        return (0..<Swift.max(levelCount, 0)).map { j in
            let coarse = Double(j) / coarseDivisor
            let band = 1 + ClassicalDenoise.colorSmoothnessReach * smooth * coarse
            return k * ClassicalDenoise.detailSigma(level: j) * band
        }
    }

    private func shrink(_ plane: Plane, thresholds: [Double],
                        edge: Plane, edgeProtection: Double) -> Plane {
        let levelCount = thresholds.count
        guard levelCount > 0 else { return plane }
        let decomposition = SpatialOps.atrousWavelet(plane, levels: levelCount)
        var details: [Plane] = decomposition.details
        let n = details.count
        guard n > 0 else { return plane }
        for j in 0..<n {
            let base = j < thresholds.count ? thresholds[j] : 0
            if !(base > 0) { continue }
            details[j] = ClassicalDenoise.softThreshold(details[j], threshold: base,
                                                        edge: edge, protection: edgeProtection)
        }
        let gains = [Double](repeating: 1.0, count: n)
        return SpatialOps.atrousReconstruct(details: details,
                                            residual: decomposition.residual,
                                            gains: gains)
    }

    /// Soft (not hard) thresholding — hard thresholding rings, which on a wavelet stack
    /// reads as the classic denoise "worm" texture (docs/07 §2.3).
    public static func softThreshold(_ detail: Plane, threshold: Double,
                                     edge: Plane, protection: Double) -> Plane {
        guard threshold > 0 else { return detail }
        var out = detail
        let count = detail.values.count
        let useEdge = (edge.width == detail.width && edge.height == detail.height
                       && edge.values.count == count && protection > 0)
        let p = Num.saturate(protection)
        for i in 0..<count {
            var t = threshold
            if useEdge {
                t = threshold * (1 - p * Num.saturate(Double(edge.values[i])))
            }
            let v = Double(detail.values[i])
            if !(t > 0) { continue }
            let m = abs(v) - t
            if m > 0 {
                out.values[i] = Float(v < 0 ? -m : m)
            } else {
                out.values[i] = 0
            }
        }
        return out
    }

    /// Gradient-magnitude edge map in [0,1], stabilized by a Gaussian pre-blur so that the
    /// map itself is not noise. The smoothstep knees are expressed in units of the blurred
    /// plane's own noise σ — for unit-variance white noise, a σ_s Gaussian leaves
    /// `1/(2·√π·σ_s)` — so the map means the same thing at every noise level.
    public static func edgeMap(_ plane: Plane, blurSigma: Double,
                               lo: Double, hi: Double) -> Plane {
        let usable = blurSigma.isFinite && blurSigma > 0
        // The BOX approximation, deliberately: the GPU twin of this map is three
        // radius-1 box passes per axis, and `testEdgeMapMatchesTheReference` pins the
        // two to 1e-4. Only the identical operator clears that, and an edge map is an
        // internal stabilizer — unlike Sharpen Radius, nothing here is a control whose
        // response has to be continuous in sigma.
        let s = usable ? SpatialOps.boxApproximatedGaussian(plane, sigma: blurSigma) : plane
        let scale = usable ? 1.0 / (2.0 * Double.pi.squareRoot() * blurSigma) : 1.0
        let e0 = lo * scale
        let e1 = hi * scale
        var out = Plane(width: plane.width, height: plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let gx = (s.clampedSample(x + 1, y) - s.clampedSample(x - 1, y)) * 0.5
                let gy = (s.clampedSample(x, y + 1) - s.clampedSample(x, y - 1)) * 0.5
                let g = (gx * gx + gy * gy).squareRoot()
                out[x, y] = Num.smoothstep(e0, e1, g)
            }
        }
        return out
    }

    private static func mixPlanes(_ a: Plane, _ b: Plane, _ t: Double) -> Plane {
        guard a.width == b.width && a.height == b.height else { return a }
        let amount = Num.saturate(t)
        guard amount > 0 else { return a }
        var out = a
        let n = Swift.min(a.values.count, b.values.count)
        for i in 0..<n {
            let av = Double(a.values[i])
            let bv = Double(b.values[i])
            out.values[i] = Float(av + (bv - av) * amount)
        }
        return out
    }

    // MARK: Hot pixels

    /// The Hot Pixels control (docs/07 §2.5), a separate pass rather than a wavelet band:
    /// a single-pixel outlier is not a scale, it is a defect, and the wavelet stack would
    /// smear it across three levels before shrinking any of them.
    ///
    /// Per channel, a pixel is replaced by the median of its 8 neighbours when both:
    ///  1. it deviates from that median by more than `k · σ`, with σ from the noise profile
    ///     evaluated at the *median* (the pixel's own value is the thing under suspicion), and
    ///  2. it is an extremum of the 3×3 neighbourhood — strictly above every neighbour or
    ///     strictly below every one. Condition 2 is what makes this single-pixel: an edge or
    ///     a fine line always has at least one neighbour on the same side of the median.
    ///
    /// v1 runs post-RAW-stage; docs/07 §2.5 moves it to the CFA domain in v2, where hot
    /// pixels actually live and before demosaic can smear one into a cross.
    public func hotPixelPass(_ image: ImageBuffer) -> ImageBuffer {
        let k = ClassicalDenoise.hotPixelK(hotPixels)
        guard k.isFinite && k > 0 else { return image }
        var out = image
        let w = image.width
        let h = image.height
        var neighbours = [Double](repeating: 0, count: 8)
        for y in 0..<h {
            for x in 0..<w {
                let centre = image[x, y]
                var replaced = centre
                var changed = false
                for ch in 0..<3 {
                    var i = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            neighbours[i] = image.clampedSample(x + dx, y + dy)[ch]
                            i += 1
                        }
                    }
                    neighbours.sort()
                    let median = (neighbours[3] + neighbours[4]) * 0.5
                    let lo = neighbours[0]
                    let hi = neighbours[7]
                    let value = centre[ch]
                    guard value.isFinite && median.isFinite else { continue }
                    if !(value > hi || value < lo) { continue }
                    let sigma = profile.sigma(at: median)
                    guard sigma > 0 else { continue }
                    if abs(value - median) > k * sigma {
                        replaced[ch] = median
                        changed = true
                    }
                }
                if changed { out[x, y] = replaced }
            }
        }
        return out
    }

    // MARK: - The GPU stage's parameters

    /// Everything the Core Image stage needs, resolved once per plan, in the units its
    /// kernels work in. Defined here, beside the reference, because the two must not be
    /// able to disagree about what a slider means: the thresholds below are literally
    /// `lumaThresholds`/`chromaThresholds`, and `encodedForward`/`encodedInverse` are
    /// the expressions the shaders evaluate, written once in Swift so a test on a
    /// machine with no GPU can check them against `VST`.
    ///
    /// ## The change of variables, and why there is one
    ///
    /// The GPU works in `g = scale · (f(x) − f(x₀))` rather than in `f(x)` directly,
    /// where `f` is the generalized Anscombe transform and `x₀` is mid-grey. Both parts
    /// cancel exactly — an à-trous detail band is unchanged by a constant offset, and
    /// every threshold is homogeneous in the plane — so this is a numerical device, not
    /// a different operator. It exists for two measured reasons:
    ///
    /// 1. **Range.** `f(x) = (2/a)·√(ax + 3a²/8 + b)` carries a `2/a` factor. For a
    ///    read-noise-dominated profile — which is what `NoiseProfile.estimate` returns
    ///    for a clean plane — that is enormous: at `a = 1e-11, b = 1e-6` the transform
    ///    reaches 2.0e8, against a half-float working format whose largest finite value
    ///    is 65 504. The stage would render infinities. Pedestal-relative, the same
    ///    profile spans 1.6e4 and the `scale` below caps it at `encodedCeiling`.
    /// 2. **Precision.** Half-float error is relative, so a band coefficient of 0.02
    ///    riding on a pedestal of 67 is below the quantum. Modelled against the f64
    ///    reference on a noisy 64×48 frame, the pedestal halves the half-float error of
    ///    the whole stage: worst pixel 9.8e-4 against 1.6e-3, RMS 1.2e-4 against 2.2e-4.
    ///
    /// The forward expression is written as `2(x − x₀) / (√u + √u₀)` rather than as the
    /// difference of two transforms. Those are algebraically the same — `u` and `u₀` are
    /// affine in `x` with the same slope — but the difference form computes `2.0e8` and
    /// subtracts `2.0e8` in a float32 shader, which leaves nothing. The quotient form
    /// never forms the large quantity at all, and it degenerates correctly: as `a → 0`
    /// it becomes `(x − x₀)/√b`, which is exactly `VST`'s own Gaussian branch, so the
    /// kernel needs no branch for it.
    public struct GPUPlan: Sendable {

        /// À-trous levels this extent supports.
        public let levels: Int
        /// The noise model actually in force, already scaled for the render resolution.
        public let profile: NoiseProfile
        /// Linear level the encoded plane is centred on: mid-grey.
        public let pedestalSignal: Double
        /// `√u₀`, with `u₀ = a·x₀ + 3a²/8 + b`.
        public let sqrtPedestal: Double
        /// `x` below which the forward transform's radicand goes negative. The reference
        /// returns 0 there; clamping the input to this value produces the same number,
        /// because `f` of it IS 0.
        public let signalFloor: Double
        /// `f(x₀)`, the level the unbiased inverse's `d` is measured from. Zero on the
        /// Gaussian branch, where there is no `d` clamp at all.
        public let referenceLevel: Double
        /// `a`, or 0 on the Gaussian branch where the unbiased correction vanishes.
        public let unbiasedGain: Double
        /// `minimumForward − f(x₀)`; the clamp expressed in the encoded plane.
        public let minimumForwardRelative: Double
        /// The homogeneous scale `s`.
        public let encodedScale: Double
        /// How much of full strength is in play, for the inverse's blend.
        public let shrinkage: Double
        /// Per-band luma thresholds, already multiplied by `encodedScale`.
        public let lumaThresholds: [Double]
        /// Per-band chroma thresholds, already multiplied by `encodedScale`.
        public let chromaThresholds: [Double]
        /// Edge-map protection: how far a strong edge backs the threshold off.
        public let lumaProtection: Double
        public let chromaProtection: Double
        /// Edge-map smoothstep knees, already multiplied by `encodedScale`.
        public let edgeKneeLow: Double
        public let edgeKneeHigh: Double
        /// Weight of the luminance-guided chroma blotch pass, 0 when it is off.
        public let blotchMix: Double
        /// Hot-pixel gate `k`; infinite when the pass is off.
        public let hotPixelK: Double

        /// The forward transform a shader computes, in Swift. Equal to
        /// `encodedScale · (VST.forward(x) − VST.forward(x₀))` for every finite `x`.
        public func encodedForward(_ x: Double) -> Double {
            let a = profile.a
            let b = profile.b
            let clamped = Swift.max(x.isFinite ? x : 0, signalFloor)
            let u = Swift.max(a * clamped + 0.375 * a * a + b, 0)
            let denominator = u.squareRoot() + sqrtPedestal
            guard denominator > 0 else { return 0 }
            return encodedScale * 2 * (clamped - pedestalSignal) / denominator
        }

        /// The inverse a shader computes, in Swift. Equal to
        /// `VST.inverse(g / encodedScale + VST.forward(x₀), shrinkage:)`.
        ///
        /// `x = x₀ + a·v²/4 + v·√u₀` is the algebraic inverse re-centred on `x₀`; it
        /// follows from `f(x)² − f(x₀)² = (4/a)(x − x₀)` and needs neither `2/a` nor
        /// `b/a`, both of which diverge as the shot term goes to zero.
        public func encodedInverse(_ g: Double) -> Double {
            let a = profile.a
            let v = g.isFinite ? g / encodedScale : 0
            let w = Swift.max(v, minimumForwardRelative)
            let algebraic = pedestalSignal + 0.25 * a * v * v + v * sqrtPedestal
            let clamped = pedestalSignal + 0.25 * a * w * w + w * sqrtPedestal
            // Floored at 1 rather than at the transform's own 1.2247 minimum, exactly
            // as the shader does. On the live branch `d` is already above that, so the
            // floor is a no-op; on the degenerate branch — pure read noise, where
            // `unbiasedGain` is zero — it is what keeps `0 · (1/0)` from being a NaN.
            let d = Swift.max(w + referenceLevel, 1)
            let i1 = 1.0 / d
            let i2 = i1 * i1
            let i3 = i2 * i1
            let root32 = 1.224744871391589
            let correction = 0.25 + 0.25 * root32 * i1 - 1.375 * i2 + 0.625 * root32 * i3
            let t = Num.saturate(shrinkage)
            return algebraic + t * (clamped - algebraic + unbiasedGain * correction)
        }
    }

    /// Largest magnitude the encoded plane is allowed to reach, so `encodedScale` has a
    /// number to solve for. 4096 leaves a 16× margin under half-float's 65 504 ceiling,
    /// which covers speculars several stops above `encodedCeilingSignal`.
    public static let encodedCeiling: Double = 4096
    /// The scene level the ceiling is solved at — six stops above display white.
    public static let encodedCeilingSignal: Double = 64

    /// The same seven settings against a profile scaled for the render resolution.
    ///
    /// `noiseScale` multiplies the profile's variance. The interactive path decodes at
    /// preview resolution, and downsampling averages the noise down with it: a 2560 px
    /// preview of an 8000 px frame carries about a tenth the variance. Without this the
    /// preview would be denoised as though it still had the sensor's full noise — a
    /// heavily smoothed preview and a much lighter export of the same photograph, which
    /// is the same class of lie the sharpening mask had before its structure tensor was
    /// smoothed. It is an approximation: the factor is exact for an area average and
    /// optimistic for whatever resampler the decoder actually used. Above 1 it is
    /// ignored, because a caller bug must not amplify a noise model.
    public func scaled(noiseScale: Double) -> ClassicalDenoise {
        let k = (noiseScale.isFinite && noiseScale > 0) ? Swift.min(noiseScale, 1) : 1
        guard k < 1 else { return self }
        return ClassicalDenoise(luma: luma, chroma: chroma, hotPixels: hotPixels,
                                lumaDetail: lumaDetail, lumaContrast: lumaContrast,
                                colorDetail: colorDetail,
                                colorSmoothness: colorSmoothness,
                                profile: NoiseProfile(a: profile.a * k,
                                                      b: profile.b * k),
                                levels: levels)
    }

    /// Resolve the GPU stage's parameters for one extent and one render scale. The
    /// graph calls this once per frame and reads nothing else — every threshold, knee
    /// and constant the kernels take comes from here, so there is one definition of
    /// what a slider means rather than two that can drift.
    public func gpuPlan(width: Int, height: Int, noiseScale: Double = 1) -> GPUPlan {
        let engine = scaled(noiseScale: noiseScale)
        let scaled = engine.profile
        let a = scaled.a
        let b = scaled.b
        let x0 = 0.18
        let gaussian = a <= VST.minimumShot
        let u0 = Swift.max(a * x0 + 0.375 * a * a + b, 0)
        let sqrtU0 = u0.squareRoot()
        let xFloor = gaussian ? -Double.greatestFiniteMagnitude
                              : -(0.375 * a * a + b) / a
        let reference = gaussian ? 0 : 2 * sqrtU0 / a
        // A value that clamps nothing, for the branch where the reference applies no
        // clamp: the Gaussian path returns `y·√b` before `d` is ever formed.
        let minimumRelative = gaussian ? -Double.greatestFiniteMagnitude
                                       : VST.minimumForward - reference

        // Solve the homogeneous scale against the widest excursion this profile can
        // produce over a plausible scene: black at one end, `encodedCeilingSignal` at
        // the other. Both ends are written as the transform's own quotient form, so
        // `reach` is in the same units as `encodedCeiling` by construction rather than
        // by a comment claiming so.
        let blackU = Swift.max(0.375 * a * a + b, 0)
        let low = 2 * (0 - x0) / (blackU.squareRoot() + sqrtU0)
        let ceilingU = Swift.max(a * ClassicalDenoise.encodedCeilingSignal + 0.375 * a * a + b, 0)
        let high = 2 * (ClassicalDenoise.encodedCeilingSignal - x0) / (ceilingU.squareRoot() + sqrtU0)
        let reach = Swift.max(abs(low), abs(high))
        let scale = (reach.isFinite && reach > ClassicalDenoise.encodedCeiling)
            ? ClassicalDenoise.encodedCeiling / reach
            : 1

        let levelCount = effectiveLevels(width: width, height: height)
        let kL = ClassicalDenoise.lumaK(luma)
        let kC = ClassicalDenoise.chromaK(chroma)
        let knee = 1.0 / (2.0 * Double.pi.squareRoot() * ClassicalDenoise.edgeBlurSigma)
        let blotch = Num.saturate(colorSmoothness / 100) * Num.saturate(chroma / 100)

        return GPUPlan(
            levels: levelCount,
            profile: scaled,
            pedestalSignal: x0,
            sqrtPedestal: sqrtU0,
            signalFloor: xFloor,
            referenceLevel: reference,
            unbiasedGain: gaussian ? 0 : a,
            minimumForwardRelative: minimumRelative,
            encodedScale: scale,
            shrinkage: engine.shrinkageFraction,
            lumaThresholds: engine.lumaThresholds(levels: levelCount).map { $0 * scale },
            chromaThresholds: engine.chromaThresholds(levels: levelCount).map { $0 * scale },
            lumaProtection: kL > 0 ? ClassicalDenoise.lumaEdgeProtection : 0,
            chromaProtection: kC > 0 ? Num.saturate(colorDetail / 100) : 0,
            edgeKneeLow: ClassicalDenoise.edgeKneeLow * knee * scale,
            edgeKneeHigh: ClassicalDenoise.edgeKneeHigh * knee * scale,
            blotchMix: kC > 0 ? 0.5 * blotch : 0,
            hotPixelK: ClassicalDenoise.hotPixelK(hotPixels))
    }

    // MARK: Teaching view

    /// The grayscale noise-only difference view Alt-drag on Luminance shows (docs/07 §2.7):
    /// what is being removed, centred on 0.5 and amplified so it is visible at all.
    public static func noiseOnlyView(original: ImageBuffer, denoised: ImageBuffer,
                                     space: RGBColorSpace = .rec2020,
                                     gain: Double = 8) -> Plane {
        let w = original.width
        let h = original.height
        var out = Plane(width: w, height: h, fill: 0.5)
        guard denoised.width == w && denoised.height == h else { return out }
        let weights = space.luminanceWeights
        for y in 0..<h {
            for x in 0..<w {
                let d = original[x, y] - denoised[x, y]
                let l = weights.r * d.r + weights.g * d.g + weights.b * d.b
                out[x, y] = Num.saturate(0.5 + gain * l)
            }
        }
        return out
    }
}

// MARK: - Tier 2: the AI splice

/// S2 (docs/07 §3): the cached-artifact model. The network never runs here — this type owns
/// what happens *around* a finished artifact: the Amount blend, the cache key, and the tile
/// geometry the inference path is handed.
///
/// Amount semantics are exact and deliberately dull (docs/07 §3.2):
/// ```
/// out = (1 − t)·input + t·artifact      per pixel, linear working space
/// t   = Amount / 100
/// ```
/// A straight linear mix is predictable, trivially maskable, and instant against a resident
/// artifact — one slider means one thing. darktable's wavelet-band-selective texture-restore
/// semantics were considered and rejected as the primary control; re-graining is the grain
/// engine's job (docs/06).
public struct AIDenoiseSplice: Sendable {

    public init() {}

    /// The global Amount blend. Instant, no recompute, ≤16.7 ms budget (docs/07 §3.7).
    /// Alpha blends with the colour channels so a splice never desynchronizes coverage.
    /// A mismatched artifact extent returns the original untouched — the stale-artifact path
    /// falls back to Tier-1 rendering with a badge, never an error (docs/07 §3.5).
    public func blend(original: ImageBuffer, denoised: ImageBuffer, amount: Double) -> ImageBuffer {
        guard original.width == denoised.width && original.height == denoised.height else {
            return original
        }
        guard amount.isFinite else { return original }
        let t = Num.saturate(amount / 100)
        if t <= 0 { return original }
        if t >= 1 { return denoised }
        var out = original
        let n = Swift.min(original.pixels.count, denoised.pixels.count)
        for i in 0..<n {
            let a = Double(original.pixels[i])
            let b = Double(denoised.pixels[i])
            out.pixels[i] = Float(a + (b - a) * t)
        }
        return out
    }

    /// The spatially-modulated form (docs/07 §5): a per-pixel weight plane replaces the
    /// scalar `t`. Costs zero extra inference, because the artifact is already resident —
    /// this is the whole reason local AI Denoise is possible at all.
    public func blend(original: ImageBuffer, denoised: ImageBuffer, weights: Plane) -> ImageBuffer {
        guard original.width == denoised.width && original.height == denoised.height else {
            return original
        }
        guard weights.width == original.width && weights.height == original.height else {
            return original
        }
        var out = original
        let w = original.width
        let h = original.height
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let t = Num.saturate(Double(weights.values[row + x]))
                if t <= 0 { continue }
                let i = original.index(x, y)
                for c in 0..<4 {
                    let a = Double(original.pixels[i + c])
                    let b = Double(denoised.pixels[i + c])
                    out.pixels[i + c] = Float(a + (b - a) * t)
                }
            }
        }
        return out
    }

    /// The Amount a recipe asks of Tier 2, or nil when Tier 2 is not the active mode — the
    /// toggle of docs/07 §3.1. Nil is "do not splice", which is distinct from Amount 0: the
    /// toggle staying on through an invalidation is what keeps the stale badge honest.
    public static func amount(for denoise: Denoise) -> Double? {
        guard denoise.mode == .ai else { return nil }
        guard denoise.amount.isFinite else { return nil }
        return Num.clamp(denoise.amount, 0, 100)
    }

    /// The artifact cache key, exactly the tuple docs/15 §15.7 and docs/07 §3.5 specify:
    /// `(photo_id, kind, component_id, model_id + model_version, prefix_hash, pipeline_version)`.
    ///
    /// `prefixHash` is the fingerprint of the upstream parameters that change the network's
    /// *input pixels*; downstream edits are not in it. Note docs/07 §12.2's unresolved
    /// conflict over whether white balance belongs in that prefix — this type stores whatever
    /// hash it is handed and takes no position.
    ///
    /// `pipelineVersion` sits inside the key, so an engine upgrade invalidates stale caches
    /// wholesale and automatically (D52). A model swap changes `modelID`/`modelVersion` and
    /// therefore the key, which is the entire invalidation mechanism for §3.1's model picker.
    public struct ArtifactKey: Hashable, Sendable {
        public let photoID: String
        public let kind: String
        /// nil for the global artifact; a mask component id for a per-component one.
        public let componentID: String?
        public let modelID: String
        public let modelVersion: String
        public let prefixHash: String
        public let pipelineVersion: Int

        public static let denoiseAtlasKind: String = "denoise-atlas"

        public init(photoID: String,
                    kind: String = ArtifactKey.denoiseAtlasKind,
                    componentID: String? = nil,
                    modelID: String,
                    modelVersion: String,
                    prefixHash: String,
                    pipelineVersion: Int = currentPipelineVersion) {
            self.photoID = photoID
            self.kind = kind
            self.componentID = componentID
            self.modelID = modelID
            self.modelVersion = modelVersion
            self.prefixHash = prefixHash
            self.pipelineVersion = pipelineVersion
        }

        /// Filesystem-safe rendering of the key, for on-disk payload naming. Every field is
        /// reduced to `[A-Za-z0-9._-]` so a model id like "nafnet/2.1" cannot walk a path.
        public var stringValue: String {
            let parts: [String] = [
                ArtifactKey.sanitize(photoID),
                ArtifactKey.sanitize(kind),
                ArtifactKey.sanitize(componentID ?? "global"),
                ArtifactKey.sanitize(modelID) + "-" + ArtifactKey.sanitize(modelVersion),
                ArtifactKey.sanitize(prefixHash),
                "p\(pipelineVersion)",
            ]
            return parts.joined(separator: "_")
        }

        /// Payload location under the cache store: `artifacts/xx/…` (docs/07 §3.5), sharded
        /// on the first two characters of the prefix hash so no directory grows unbounded.
        public var relativePath: String {
            let hash = ArtifactKey.sanitize(prefixHash)
            var shard = String(hash.prefix(2))
            if shard.count < 2 { shard = "00" }
            return "artifacts/\(shard)/\(stringValue).atlas"
        }

        private static func sanitize(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            for ch in s.unicodeScalars {
                let ok = (ch >= "a" && ch <= "z")
                    || (ch >= "A" && ch <= "Z")
                    || (ch >= "0" && ch <= "9")
                    || ch == "." || ch == "-" || ch == "_"
                if ok {
                    out.append(Character(ch))
                } else {
                    out.append(Character("-"))
                }
            }
            return out.isEmpty ? "-" : out
        }
    }
}

// MARK: - Tiling

/// One tile: the full rectangle the network sees, plus the apron-free rectangle that is the
/// only part of its output anybody is allowed to keep.
public struct TileRect: Hashable, Sendable {
    /// Tile origin and extent in image coordinates — apron included.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// The apron-free region, in image coordinates. Always inside the tile.
    public let validX: Int
    public let validY: Int
    public let validWidth: Int
    public let validHeight: Int

    public init(x: Int, y: Int, width: Int, height: Int,
                validX: Int, validY: Int, validWidth: Int, validHeight: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.validX = validX
        self.validY = validY
        self.validWidth = validWidth
        self.validHeight = validHeight
    }

    /// Apron widths on each side, in pixels. Zero on a frame edge, where there is nothing
    /// beyond the border to discard.
    public var apronLeft: Int { validX - x }
    public var apronTop: Int { validY - y }
    public var apronRight: Int { (x + width) - (validX + validWidth) }
    public var apronBottom: Int { (y + height) - (validY + validHeight) }

    /// The valid region expressed in the tile's own coordinates — what a stitcher crops.
    public var validOriginInTile: (x: Int, y: Int) { (validX - x, validY - y) }
}

/// The tile plan for a stage that cannot process a 45MP frame in one bite (docs/07 §3.4 for
/// S2, docs/14's 2048 px classical export tiles for S3).
///
/// **The stitching rule, which is the whole point of this type.** Tiles are laid out so
/// their *valid* regions tile the image exactly — no gaps, no overlaps — while their full
/// extents overlap by the apron. On stitch, only the valid region of each tile is copied and
/// the apron is discarded outright. This is exact halo-crop, not Hann feathering: where the
/// apron is at least the stage's receptive field it is bit-stable, and docs/07 §3.4 prefers
/// it for exactly that reason. Feathering hides an under-sized apron; discarding does not,
/// which is what you want from the classic silent corrupter.
///
/// Tile extent is held fixed at `min(tile, imageExtent)` for every tile in a row or column,
/// including the last: fixed shapes are what the ANE compiler wants, so the final tile is
/// slid back against the frame edge rather than shrunk.
public struct TilePlan: Sendable {

    public let width: Int
    public let height: Int
    public let tile: Int
    public let overlap: Int
    public let tiles: [TileRect]

    /// S2 defaults. docs/07 §3.4 says 512–768 px fixed shapes; docs/14 §6.3 says 512–1024
    /// (the §12.1 conflict). 768 is the safer ANE-compile ceiling and is what ships until the
    /// measured compile + throughput test settles it. Overlap is S2's declared 32 px halo.
    public static let aiTile: Int = 768
    public static let aiOverlap: Int = 32
    /// S3 defaults: docs/14's 2048 px classical export tiles with the declared 24 px halo.
    public static let classicTile: Int = 2048
    public static let classicOverlap: Int = 24

    public init(width: Int, height: Int, tile: Int, overlap: Int) {
        self.width = Swift.max(width, 0)
        self.height = Swift.max(height, 0)
        self.tile = Swift.max(tile, 1)
        self.overlap = Swift.max(overlap, 0)
        self.tiles = TilePlan.plan(width: width, height: height, tile: tile, overlap: overlap)
    }

    /// Lay out the tiles. `overlap` is clamped below `tile/2`, because an apron that eats the
    /// whole tile would leave no valid region to keep.
    public static func plan(width: Int, height: Int, tile: Int, overlap: Int) -> [TileRect] {
        guard width > 0 && height > 0 else { return [] }
        let t = Swift.max(tile, 1)
        let ov = Swift.max(0, Swift.min(overlap, (t - 1) / 2))
        let xs = spans(extent: width, tile: t, overlap: ov)
        let ys = spans(extent: height, tile: t, overlap: ov)
        var out: [TileRect] = []
        out.reserveCapacity(xs.count * ys.count)
        for sy in ys {
            for sx in xs {
                out.append(TileRect(x: sx.origin, y: sy.origin,
                                    width: sx.extent, height: sy.extent,
                                    validX: sx.validOrigin, validY: sy.validOrigin,
                                    validWidth: sx.validExtent, validHeight: sy.validExtent))
            }
        }
        return out
    }

    private struct Span {
        let origin: Int
        let extent: Int
        let validOrigin: Int
        let validExtent: Int
    }

    private static func spans(extent: Int, tile: Int, overlap: Int) -> [Span] {
        guard extent > 0 else { return [] }
        let t = Swift.min(tile, extent)
        let core = Swift.max(t - 2 * overlap, 1)
        var out: [Span] = []
        var cursor = 0
        while cursor < extent {
            // Tile origin: back off by the apron, then slide inside the frame. The clamp to
            // `extent - t` is what keeps every tile the same fixed size.
            var origin = cursor - overlap
            if origin < 0 { origin = 0 }
            if origin > extent - t { origin = extent - t }
            if origin < 0 { origin = 0 }
            // Valid region: this tile's share of the core, never reaching past the tile.
            var end = cursor + core
            if end > origin + t { end = origin + t }
            if end > extent { end = extent }
            if end <= cursor { end = Swift.min(cursor + 1, extent) }
            out.append(Span(origin: origin, extent: t,
                            validOrigin: cursor, validExtent: end - cursor))
            cursor = end
        }
        return out
    }

    /// Stitch processed tiles back into one frame, discarding every apron. Tiles whose
    /// buffer extent does not match their rect are skipped rather than mis-copied — a
    /// short tile is a bug upstream, and writing it at the wrong stride would hide it.
    public static func stitch(_ pieces: [(rect: TileRect, pixels: ImageBuffer)],
                              width: Int, height: Int) -> ImageBuffer {
        precondition(width > 0 && height > 0, "TilePlan.stitch needs a non-empty extent")
        var out = ImageBuffer(width: width, height: height)
        for piece in pieces {
            let r = piece.rect
            let src = piece.pixels
            guard src.width == r.width && src.height == r.height else { continue }
            let x0 = Swift.max(r.validX, Swift.max(r.x, 0))
            let y0 = Swift.max(r.validY, Swift.max(r.y, 0))
            let x1 = Swift.min(Swift.min(r.validX + r.validWidth, r.x + r.width), width)
            let y1 = Swift.min(Swift.min(r.validY + r.validHeight, r.y + r.height), height)
            guard x1 > x0 && y1 > y0 else { continue }
            for y in y0..<y1 {
                let sy = y - r.y
                if sy < 0 || sy >= src.height { continue }
                for x in x0..<x1 {
                    let sx = x - r.x
                    if sx < 0 || sx >= src.width { continue }
                    let si = src.index(sx, sy)
                    let di = out.index(x, y)
                    out.pixels[di] = src.pixels[si]
                    out.pixels[di + 1] = src.pixels[si + 1]
                    out.pixels[di + 2] = src.pixels[si + 2]
                    out.pixels[di + 3] = src.pixels[si + 3]
                }
            }
        }
        return out
    }

    /// Whether every pixel of the frame is covered by exactly one valid region — the
    /// assertion a stitching golden should make before it trusts an output.
    public static func coversExactly(_ tiles: [TileRect], width: Int, height: Int) -> Bool {
        guard width > 0 && height > 0 else { return tiles.isEmpty }
        var hits = [Int](repeating: 0, count: width * height)
        for r in tiles {
            let x0 = Swift.max(r.validX, 0)
            let y0 = Swift.max(r.validY, 0)
            let x1 = Swift.min(r.validX + r.validWidth, width)
            let y1 = Swift.min(r.validY + r.validHeight, height)
            if x1 <= x0 || y1 <= y0 { continue }
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 { hits[row + x] += 1 }
            }
        }
        for h in hits where h != 1 { return false }
        return true
    }
}

// MARK: - ISO-adaptive defaults

/// The shipped adaptive-default curve (docs/07 §4). Interpolation is linear in log2(ISO),
/// clamped beyond the anchors — LR-compatible semantics, kept deliberately.
///
/// These values are resolved to concrete slider numbers at import and written into the
/// recipe, so later anchor edits never silently shift already-imported photos; the other
/// intent is served by the explicit "re-apply current defaults" batch command.
public enum ISODefaults {

    /// Luminance: 0 at ISO ≤ 400 → 25 at 6400 → 40 at ISO ≥ 25600. Worked example from
    /// docs/07 §4: ISO 3200 is at log2 = 11.6439, three quarters of the way from log2 400
    /// to log2 6400, so Luminance = 18.75.
    public static let luminanceAnchors: [(x: Double, y: Double)] = [
        (x: log2(400.0), y: 0.0),
        (x: log2(6400.0), y: 25.0),
        (x: log2(25600.0), y: 40.0),
    ]

    /// Color "follows profile" in docs/07 §4 without a stated curve, so this is the shipped
    /// seed: LR's flat 25 lands at ISO 1600 (where it is roughly right) and the curve moves
    /// in both directions from there, which is exactly the departure §2.1 claims — "LR's flat
    /// Color 25 is a guess that happens to be acceptable". Shown resolved in the UI as
    /// e.g. "25 auto" per D11.
    public static let colorAnchors: [(x: Double, y: Double)] = [
        (x: log2(100.0), y: 10.0),
        (x: log2(1600.0), y: 25.0),
        (x: log2(6400.0), y: 40.0),
        (x: log2(25600.0), y: 55.0),
    ]

    /// Amount is pinned at 50 for every ISO by docs/07 §3.1 — the AI slider means one thing
    /// and starts in the same place regardless of gain, which is what makes the auto-queue
    /// rule safe ("computes, never auto-commits"). The table exists so a measured curve is a
    /// one-line edit rather than a signature change; it is deliberately flat today.
    public static let aiAmountAnchors: [(x: Double, y: Double)] = [
        (x: log2(400.0), y: 50.0),
        (x: log2(25600.0), y: 50.0),
    ]

    /// The suggested (off by default) auto-queue threshold from docs/07 §4.
    public static let suggestedAutoQueueISO: Double = 6400

    private static func logISO(_ iso: Double) -> Double {
        let clean = (iso.isFinite && iso > 0) ? iso : 100.0
        return log2(Swift.max(clean, 1.0))
    }

    /// Tier-1 Luminance for an ISO.
    public static func luminance(forISO iso: Double) -> Double {
        Num.clamp(Num.interpolateAnchors(luminanceAnchors, at: logISO(iso)), 0, 100)
    }

    /// Tier-1 Color for an ISO.
    public static func color(forISO iso: Double) -> Double {
        Num.clamp(Num.interpolateAnchors(colorAnchors, at: logISO(iso)), 0, 100)
    }

    /// The full Tier-1 default block for an ISO. Hot Pixels stays at 0: it is a defect
    /// control, not a noise control, and defects do not scale with gain.
    ///
    /// The four sub-sliders resolve here too, which is docs/07 §2.1's first departure
    /// from Lightroom: with `n = ClassicalDenoise.noisiness(of:)` in [0,1] measured from
    /// the profile's σ at mid-grey, Luminance Detail falls to `50 − 10n` (less texture
    /// to preserve where there is more noise than texture) and Colour Smoothness rises
    /// to `50 + 40n` (blotches grow with gain). Contrast and Colour Detail stay at LR's
    /// defaults, where nothing measured says otherwise.
    ///
    /// Resolved to concrete numbers ONCE, at import, and written into the recipe — so
    /// the panel shows what will render, a later edit to these anchors cannot silently
    /// restyle photographs already in the catalog, and a hand-set value is never
    /// recomputed out from under the user.
    public static func classic(forISO iso: Double) -> ClassicNR {
        let n = ClassicalDenoise.noisiness(of: NoiseProfile.forISO(iso))
        return ClassicNR(luma: luminance(forISO: iso),
                         chroma: color(forISO: iso),
                         hotPixels: 0,
                         lumaDetail: Num.clamp(50 - 10 * n, 0, 100),
                         lumaContrast: 0,
                         colorDetail: 50,
                         colorSmoothness: Num.clamp(50 + 40 * n, 0, 100))
    }

    /// The Tier-1 block an unedited photo starts with, given what its EXIF says. A file
    /// with no ISO recorded keeps the flat wire defaults rather than being handed a
    /// guess: an invented profile is worse than an honest absence.
    ///
    /// This is the import-time caller docs/07 §4 describes. It is also the only place
    /// the anchors are read, so "ISO-adaptive defaults" is a claim with one traceable
    /// implementation rather than a table nobody calls.
    public static func startingDenoise(forISO iso: Double?) -> Denoise {
        guard let iso, iso.isFinite, iso > 0 else { return Denoise() }
        return Denoise(mode: .classic, amount: aiAmount(forISO: iso),
                       model: nil, classic: classic(forISO: iso))
    }

    /// The Tier-2 Amount default for an ISO.
    public static func aiAmount(forISO iso: Double) -> Double {
        Num.clamp(Num.interpolateAnchors(aiAmountAnchors, at: logISO(iso)), 0, 100)
    }

    /// The auto-queue rule: queue Tier 2 in the background for imports at or above the
    /// threshold. Off unless a threshold is supplied.
    public static func shouldAutoQueue(forISO iso: Double, threshold: Double?) -> Bool {
        guard let t = threshold, t.isFinite, iso.isFinite else { return false }
        return iso >= t
    }

    /// The auto-zero coupling of docs/14: when AI Denoise is on, ISO-adaptive Tier-1
    /// defaults drop to zero — the noise they compensated for is gone — *unless* the user
    /// hand-set them. `userSet` bits do not exist in the recipe yet (docs/07 §12.7), so they
    /// are passed in explicitly rather than guessed at.
    public static func coupled(_ params: ClassicNR, aiEnabled: Bool,
                               lumaUserSet: Bool, chromaUserSet: Bool) -> ClassicNR {
        guard aiEnabled else { return params }
        return ClassicNR(luma: lumaUserSet ? params.luma : 0,
                         chroma: chromaUserSet ? params.chroma : 0,
                         hotPixels: params.hotPixels)
    }

    /// The Tier-1 block a whole `Denoise` recipe resolves to, honouring `mode`:
    ///  - `.off` — Tier 1 is off, including Hot Pixels. Off means off.
    ///  - `.classic` — the recipe's own `classic` block, untouched.
    ///  - `.ai` — the auto-zero coupling above, so Tier 1 runs as a finishing pass over an
    ///    already-denoised image rather than compensating twice.
    ///
    /// `userSet` bits are parameters because the recipe does not carry them yet (docs/07 §12.7).
    public static func classic(for denoise: Denoise,
                               lumaUserSet: Bool = false,
                               chromaUserSet: Bool = false) -> ClassicNR {
        switch denoise.mode {
        case .off:
            return ClassicNR(luma: 0, chroma: 0, hotPixels: 0)
        case .classic:
            return denoise.classic
        case .ai:
            return coupled(denoise.classic, aiEnabled: true,
                           lumaUserSet: lumaUserSet, chromaUserSet: chromaUserSet)
        }
    }
}

// MARK: - Local (masked) noise reduction

/// The two rows local NR adds to the per-mask adjustment stack (docs/07 §5). Both are cheap
/// per-pixel operations against data that is already resident: the Tier-1 wavelet
/// decomposition is shared with the global pass and computed once, and local AI costs zero
/// extra inference because Amount is a linear blend against a cached artifact.
public struct LocalNoiseAdjust: Sendable, Equatable {

    /// Local Tier-1 strength, 0…100 (LR mask-Noise parity).
    public var noise: Double
    /// Offset applied to the Tier-2 Amount inside the mask, −100…+100. Requires the artifact.
    public var aiOffset: Double

    public init(noise: Double = 0, aiOffset: Double = 0) {
        self.noise = noise.isFinite ? Num.clamp(noise, 0, 100) : 0
        self.aiOffset = aiOffset.isFinite ? Num.clamp(aiOffset, -100, 100) : 0
    }

    /// The blend-weight formula, verbatim from docs/07 §5:
    /// ```
    /// t(x) = clamp( t_global + mask(x)·offset )      offset ∈ [−1, +1]
    /// ```
    /// Composited at S11 LOCAL. This is what lets one slider solve the DxO astro complaint:
    /// +40 AI over a starscape's foreground, −60 over the stars so faint stars survive.
    public func aiWeight(globalAmount: Double, maskAlpha: Double) -> Double {
        let global = globalAmount.isFinite ? Num.saturate(globalAmount / 100) : 0
        let alpha = maskAlpha.isFinite ? Num.saturate(maskAlpha) : 0
        return Num.saturate(global + alpha * (aiOffset / 100))
    }

    /// `aiWeight` over a whole mask raster — the plane `AIDenoiseSplice.blend(…weights:)` wants.
    public func aiWeights(globalAmount: Double, mask: Plane) -> Plane {
        var out = Plane(width: mask.width, height: mask.height)
        let n = Swift.min(out.values.count, mask.values.count)
        for i in 0..<n {
            out.values[i] = Float(aiWeight(globalAmount: globalAmount,
                                           maskAlpha: Double(mask.values[i])))
        }
        return out
    }

    /// The Tier-1 lift: the mask raises local shrinkage strength above the global value,
    /// clamped to the slider range. Same additive shape as the AI offset, one-sided because
    /// the mask-Noise row is 0…100 rather than signed.
    public func classicStrength(globalStrength: Double, maskAlpha: Double) -> Double {
        let global = globalStrength.isFinite ? Num.clamp(globalStrength, 0, 100) : 0
        let alpha = maskAlpha.isFinite ? Num.saturate(maskAlpha) : 0
        return Num.clamp(global + alpha * noise, 0, 100)
    }
}
