// Kernels.swift
// The complete custom-shader surface of Lumen's render path: thirty-two small kernels.
//
// That number is the point. Nearly every colour-bearing stage is a pure RGB→RGB
// function, so the engine evaluates it once in LumenCore's reference implementation
// and bakes it into a lookup table that the stock colour-cube filter applies
// (docs/14 §5, adapted: Core Image is used as a graph compiler, and the graph's
// per-pixel colour work is one table fetch rather than nine hand-ported shaders).
// What remains here is only what a table cannot express: the log shaper that makes an
// unbounded scene fit a bounded table, image-by-image arithmetic for the guided
// filter, mask compositing, grain, and the vignette's dependence on position.
//
// Every kernel has a Swift twin in LumenCore, and PipelineGoldenTests renders both to
// compare them. A kernel that fails to compile leaves `KernelLibrary.isAvailable`
// false and the renderer falls back to the CPU reference path — slower, identical
// pixels, and honest about it in the UI rather than silently wrong.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

public enum KernelLibrary {

    // MARK: - Sources

    /// Scene-linear → the shaper's [0,1] log domain. The twin of `LumenLog.encode`.
    static let logEncodeSource = LumenLog.encodeKernelSource

    /// The shaper's domain → scene-linear. The twin of `LumenLog.decode`.
    static let logDecodeSource = LumenLog.decodeKernelSource

    /// Per-channel product of two images. Used for tone gain, vignette and any other
    /// "multiply by a field" stage; unlike CIMultiplyBlendMode it does not clamp,
    /// which matters when both sides are scene-referred and unbounded.
    static let multiplySource = """
    kernel vec4 lumenMultiply(__sample a, __sample b) {
        return vec4(a.rgb * b.rgb, a.a);
    }
    """

    /// Per-channel square — the guided filter's correlation term.
    static let squareSource = """
    kernel vec4 lumenSquare(__sample a) {
        return vec4(a.rgb * a.rgb, a.a);
    }
    """

    /// Luminance broadcast to all three channels. The weights are passed in so the
    /// working space is never assumed.
    static let luminanceSource = """
    kernel vec4 lumenLuminance(__sample a, vec3 w) {
        float y = dot(a.rgb, w);
        return vec4(y, y, y, a.a);
    }
    """

    /// Guided filter, coefficient step: from the local mean of I and of I², produce
    /// the per-pixel (a, b) that make the filter edge-aware.
    ///   a = var / (var + eps),  b = meanI · (1 − a),  var = meanII − meanI²
    static let guidedCoefficientsSource = """
    kernel vec4 lumenGuidedCoefficients(__sample meanI, __sample meanII, float eps) {
        float mi = meanI.r;
        float v = max(meanII.r - mi * mi, 0.0);
        float a = v / (v + eps);
        float b = mi * (1.0 - a);
        return vec4(a, b, 0.0, 1.0);
    }
    """

    /// Guided filter, CROSS-guided coefficient step: the filtered signal `p` and the
    /// guide `I` are different images, so the numerator is the covariance, not the
    /// variance. Collapsing the two makes `a → 0` in flat regions and the output
    /// becomes the guide instead of the signal — which is how a refined dehaze
    /// transmission quietly turns into a dark channel.
    ///   a = cov(I,p)/(var(I) + eps),  b = mean(p) − a·mean(I)
    static let guidedCrossCoefficientsSource = """
    kernel vec4 lumenGuidedCross(__sample meanI, __sample meanII, __sample meanP,
                                 __sample meanIP, float eps) {
        float mi = meanI.r;
        float v = max(meanII.r - mi * mi, 0.0);
        float cov = meanIP.r - mi * meanP.r;
        float a = cov / (v + eps);
        float b = meanP.r - a * mi;
        return vec4(a, b, 0.0, 1.0);
    }
    """

    /// Guided filter, apply step: q = mean(a)·I + mean(b).
    static let guidedApplySource = """
    kernel vec4 lumenGuidedApply(__sample coefficients, __sample guide) {
        float q = coefficients.r * guide.r + coefficients.g;
        return vec4(q, q, q, 1.0);
    }
    """

    /// Presence: turn a band of the base–detail decomposition into a gain field.
    /// `hi` and `lo` are two log-luminance scales from the guided filter, so the
    /// difference is a band of detail and the gain is halo-free by construction —
    /// the guided filter has no gradient reversal, which is the whole reason it beats
    /// a bilateral base for this job.
    static let detailGainSource = """
    kernel vec4 lumenDetailGain(__sample hi, __sample lo, float k) {
        float g = exp2(k * (hi.r - lo.r));
        return vec4(g, g, g, 1.0);
    }
    """

    /// Dehaze recombination, in the colour-stable form the reference uses.
    ///
    /// The old kernel did `I' = (I − A)/max(t, t0) + A` per channel, which is a
    /// different scale factor for each channel and therefore a hue rotation — exactly
    /// the magenta sky docs/06 claims is "impossible by construction". It was
    /// impossible only on `ReferenceRenderer`, which renders no user pixels; every
    /// preview and every export took the per-channel form.
    ///
    /// This scales the colour by a single LUMINANCE ratio, so channel ratios survive
    /// untouched and a recovered sky comes back the colour it was.
    ///
    /// Two guards carried over from the reference, both load-bearing. `trust` is
    /// RELATIVE, not absolute: shadow noise after white balance makes triples like
    /// (−0.02, +0.009, −0.01) whose luminance cancels while the channels do not, and
    /// scaling those by a luminance ratio turns them into saturated speckles that
    /// flicker with the noise — while a saturated blue carries only six percent of its
    /// peak channel as luminance and must still dehaze fully. And `ratio` is clamped,
    /// because y1 is a fixed negative number as y0 approaches zero, so the ratio
    /// diverges and its sign flips across zero.
    ///
    /// Branchless, like every other kernel here: `positive` selects, and the unselected
    /// branch collapses to the identity on its own because its own amount term is zero.
    ///
    /// Still missing versus the reference: the sky guard, which lifts the transmission
    /// floor toward 0.9 where the frame is bright and flat. It needs the gradient and
    /// log-luminance planes this kernel is not given. Tracked in BUILDING.md.
    static let dehazeSource = """
    kernel vec4 lumenDehaze(__sample image, __sample transmission, vec3 gain,
                            vec3 lumaWeights, vec3 airlight, float airLuma,
                            float floorT, float amount) {
        vec3 c = image.rgb;
        float raw = transmission.r;
        float t = max(raw, floorT);

        vec3 neutral = c * gain;
        float y0 = dot(neutral, lumaWeights);
        float y1 = (y0 - airLuma) / t + airLuma;
        float magnitude = max(abs(c.r), max(abs(c.g), abs(c.b)));
        float trust = smoothstep(0.01, 0.05, abs(y0) / max(magnitude, 1e-8));
        float live = step(1e-9, abs(y0));
        float denominator = mix(1.0, y0, live);
        float ratio = clamp(y1 / denominator, 0.05, 20.0);
        float k = mix(1.0, mix(1.0, ratio, trust), max(amount, 0.0));
        vec3 lifted = c * k;

        // Adding haze: more of it the FURTHER away the pixel reads, and low
        // transmission is what "far" looks like without a depth map.
        float distant = clamp(1.0 - raw, 0.0, 1.0);
        float s = clamp(-min(amount, 0.0) * distant * 0.9, 0.0, 1.0);
        vec3 hazed = mix(c, airlight, s);

        return vec4(mix(hazed, lifted, step(0.0, amount)), image.a);
    }
    """

    /// Sharpening as a log-luminance delta in EV, with the two sliders the stock
    /// unsharp mask had no expression for.
    ///
    /// `CIUnsharpMask` on RGB was the whole sharpen path, so Masking and Halo
    /// Suppression — one of which docs/06 calls "the fifth slider Adobe never shipped"
    /// — were live controls that no preview and no export ever read, and Detail was
    /// folded into a radius because a stock USM has nowhere else to put it.
    ///
    /// The unit matters and has bitten this codebase before. `logLuminance` is
    /// LumenLog-ENCODED, which squeezes 24 stops into [0,1], so a difference taken on
    /// that plane is EV/24 and every threshold the reference states in EV must be
    /// multiplied back by `range` before it means anything. Texture spent its whole
    /// life doing one twenty-fourth of what it said for exactly this reason.
    ///
    /// Halo damping is one-sided by design: only the BRIGHT overshoot is a rim, and
    /// only once it is large enough to read as one rather than as edge definition.
    /// `step(0.0, v)` selects that side branchlessly.
    static let sharpenDeltaSource = """
    kernel vec4 lumenSharpenDelta(__sample lum, __sample blurred, __sample fine,
                                  __sample gradient, float amount, float detail,
                                  float masking, float halo, float range) {
        float usm = (lum.r - blurred.r) * range;
        float fineEV = fine.r * range;
        float v = amount * mix(usm, fineEV, detail);

        float bright = step(0.0, v) * halo;
        v = v * (1.0 - bright * smoothstep(0.15, 0.60, usm));

        // `gradient` arrives in EV/px already — `structureTensor` scales at the source
        // so one quantity is not denominated two different ways in two kernels. `range`
        // still converts `lum` and `fine`, which are encoded.
        float edge = smoothstep(0.02 + 0.10 * masking,
                                0.10 + 0.25 * masking,
                                gradient.r);
        v = v * mix(1.0, edge, masking);
        return vec4(v, v, v, 1.0);
    }
    """

    /// Apply a per-pixel EV delta as a LUMINANCE ratio, so sharpening cannot shift hue
    /// or saturation the way a per-channel unsharp mask does. Limited, because an
    /// unbounded gain on a specular highlight is how a sharpener makes white holes.
    static let lumaRatioSource = """
    kernel vec4 lumenLumaRatio(__sample image, __sample deltaEV, float limit) {
        float d = clamp(deltaEV.r, -limit, limit);
        return vec4(image.rgb * exp2(d), image.a);
    }
    """

    /// The three products of a structure tensor, packed into one plane so a single box
    /// blur smooths all of them: (gx², gy², gx·gy).
    ///
    /// The 3x3 Sobel responds with eight times the derivative on a linear ramp, which
    /// is where the /8 comes from — without it every threshold expressed against this
    /// tensor is off by a factor of 64. Normalised this way a Sobel and the reference's
    /// central difference agree exactly on a ramp and to within a pixel of smoothing
    /// elsewhere, which the box blur below then dwarfs.
    ///
    /// `scale` converts the incoming derivative into the units the thresholds downstream
    /// are written in. The plane this reads is `LumenLog`-encoded, so one EV arrives as
    /// 1/24 of a unit, while the reference's tensor is built on a plane in EV and every
    /// threshold against it — sharpening's 0.02…0.35 EV/px mask, the coherence strength
    /// gate — is stated in EV per pixel. Scaling HERE rather than at each reader also
    /// keeps the products out of half-float's subnormal range: at the bottom of the
    /// masking band a squared derivative is 6.9e-7 unscaled, below the smallest normal
    /// half (6.1e-5) and quantised to about 8%, against 4.0e-4 once scaled. The band's
    /// low end is exactly where the smoothstep decides, so that is not spare precision.
    static let structureTensorSource = """
    kernel vec4 lumenStructureTensor(__sample gx, __sample gy, float scale) {
        float x = gx.r / 8.0 * scale;
        float y = gy.r / 8.0 * scale;
        return vec4(x * x, y * y, x * y, 1.0);
    }
    """

    /// Coherence from the blurred tensor: 0 where structure is isotropic (pores, film
    /// grain, noise-adjacent detail), 1 on a coherent edge (an eyelash, a jawline, a
    /// horizon).
    ///
    /// From the eigenvalues of the 2x2 tensor, ((l1 − l2)/(l1 + l2))², which reduces to
    /// the form below without ever solving for l1 and l2 separately:
    ///   l1 − l2 = sqrt((Jxx − Jyy)² + 4·Jxy²)
    ///   l1 + l2 = Jxx + Jyy
    ///
    /// This is what makes NEGATIVE Texture a skin smoother rather than a
    /// negative-Clarity glow: without the gate it attacks an eyelash as readily as a
    /// pore, and the face goes waxy while the edges go soft. docs/06 names the gate as
    /// the whole difference, and the shipping path had neither it nor the bands.
    /// The ratio is NOT squared, and it is gated by strength. Both of those were wrong
    /// here, in opposite directions, and between them they came close to inverting the
    /// control this gate exists to make possible.
    ///
    /// Squaring `(λ₁−λ₂)/(λ₁+λ₂)` — which the comment above described and the reference
    /// does not do — only ever lowers a value already in [0,1], so an edge read as less
    /// coherent than it is and negative Texture softened it harder than it should.
    /// Omitting the strength gate is the larger error: a gently shaded cheek or a clear
    /// sky has a tiny gradient pointing consistently one way, so the ratio alone is
    /// near 1 and the region reads as a "coherent edge" to be protected. Measured on a
    /// frame with an edge, isotropic texture and a smooth ramp, against the reference:
    /// on the texture the reference opens the gate fully (coherence 0.000) and this
    /// returned 0.596; on the smooth ramp 0.000 against 0.715; and on the actual edge
    /// it protected LESS than the reference, 0.503 against 0.611. Negative Texture was
    /// therefore doing about a third of its work on skin while softening edges more
    /// than specified — the waxy-face-and-soft-edges failure docs/06 names the gate to
    /// prevent, produced by the gate itself.
    ///
    /// With the strength gate restored and the square dropped the three regions land on
    /// 0.611 / 0.000 / 0.000 against the reference's 0.611 / 0.000 / 0.000.
    static let coherenceSource = """
    kernel vec4 lumenCoherence(__sample tensor, float lo, float hi) {
        float jxx = tensor.r;
        float jyy = tensor.g;
        float jxy = tensor.b;
        float trace = jxx + jyy;
        float d = jxx - jyy;
        float spread = sqrt(d * d + 4.0 * jxy * jxy);
        // A flat region has a trace of essentially zero and no orientation to speak
        // of, so it must read as ISOTROPIC. Dividing by it would say the opposite.
        float c = clamp(spread / max(trace, 1e-12), 0.0, 1.0) * step(1e-12, trace);
        // Strength: direction means nothing without contrast behind it.
        float magnitude = sqrt(max(0.5 * (trace + spread), 0.0));
        return vec4(vec3(c * smoothstep(lo, hi, magnitude)), 1.0);
    }
    """

    /// √λ₁ of the smoothed tensor — the gradient strength along the dominant local
    /// direction, in the units `structureTensor` was scaled into.
    ///
    /// This replaces a per-pixel `sqrt(gx² + gy²)`, which is the same quantity only in
    /// the limit of no smoothing at all: an unsmoothed tensor is rank-1, so λ₂ = 0 and
    /// λ₁ = gx² + gy². The smoothing is the entire point. Without it the edge mask was
    /// one pixel wide where the reference's is a band, and sharpening's Masking slider
    /// kept 17.8% of its delta on an edge where the reference keeps 73.7% — it was not
    /// protecting flat areas so much as deleting the sharpening everywhere. It also
    /// made the mask resolution-dependent in a way the reference is not, which is why
    /// a fit preview and a full-resolution export disagreed about the same photograph.
    static let tensorMagnitudeSource = """
    kernel vec4 lumenTensorMagnitude(__sample tensor) {
        float trace = tensor.r + tensor.g;
        float d = tensor.r - tensor.g;
        float spread = sqrt(d * d + 4.0 * tensor.b * tensor.b);
        float m = sqrt(max(0.5 * (trace + spread), 0.0));
        return vec4(vec3(m), 1.0);
    }
    """

    /// `detailGain` with a per-pixel gate on the band before it is exponentiated.
    ///
    /// The gate multiplies the BAND, not the result: gating the gain afterwards would
    /// pull the whole multiply toward zero rather than toward one, which darkens
    /// wherever the gate closes instead of leaving the pixel alone.
    static let detailGainGatedSource = """
    kernel vec4 lumenDetailGainGated(__sample hi, __sample lo, __sample gate,
                                     float k, float useGate) {
        float open = mix(1.0, 1.0 - clamp(gate.r, 0.0, 1.0), useGate);
        float g = exp2(k * open * (hi.r - lo.r));
        return vec4(g, g, g, 1.0);
    }
    """

    /// Keep the pixels where a plane is at or above a threshold, zero elsewhere, and
    /// carry the selection weight in alpha so a masked mean can be recovered from two
    /// area averages.
    /// How far a tone is from mid-grey, as the complement of the reference's Gaussian
    /// midtone weight. 0 in the midtones, approaching 1 at both ends.
    ///
    /// `DetailEngine`'s local Laplacian weights each remap level by
    /// `exp(−gamma^2 / (2 * clarityMidtoneEV^2))`, so Clarity acts on the midtones and
    /// tapers out of the deep shadows and the blown highlights. The GPU had no such
    /// term at all: `exp2` of a log-domain difference is exposure-invariant by
    /// construction, so a shadow at −6 EV got exactly the same local-contrast boost as
    /// a face — which is how Clarity ends up amplifying shadow noise and fighting the
    /// highlight rolloff at the same time.
    ///
    /// Returned as the complement because `detailGainGated` takes a gate that CLOSES
    /// the gain: `open = 1 − gate` recovers the reference's weight exactly.
    static let tonalFalloffSource = """
    kernel vec4 lumenTonalFalloff(__sample plane, float centre, float range,
                                  float sigmaEV) {
        float dEV = (plane.r - centre) * range;
        float w = exp(-(dEV * dEV) / (2.0 * sigmaEV * sigmaEV));
        float f = 1.0 - w;
        return vec4(f, f, f, 1.0);
    }
    """

    static let thresholdMaskSource = """
    kernel vec4 lumenThresholdMask(__sample image, __sample plane, float threshold) {
        float keep = step(threshold, plane.r);
        return vec4(image.rgb * keep, keep);
    }
    """

    /// a − b on a plane, signed.
    ///
    /// A kernel rather than `CISubtractBlendMode`, because the blend modes are defined
    /// over display-referred colour and clamp at zero. A detail band is signed by
    /// nature — half of it is the dark side of every edge — and clamping it would
    /// sharpen only the bright half of the picture.
    static let subtractSource = """
    kernel vec4 lumenSubtract(__sample a, __sample b) {
        return vec4(a.rgb - b.rgb, a.a);
    }
    """

    /// Add a blurred glow field back into the image in linear light — halation's
    /// recombination, and the same shape any additive bloom needs.
    static let addGlowSource = """
    kernel vec4 lumenAddGlow(__sample image, __sample glow, vec3 strength) {
        return vec4(image.rgb + glow.rgb * strength, image.a);
    }
    """

    /// Highlight energy above the clip point, which is what actually scatters in the
    /// film base. Everything below `threshold` contributes nothing.
    static let highlightEnergySource = """
    kernel vec4 lumenHighlightEnergy(__sample image, float threshold, float boost) {
        vec3 e = max(image.rgb - vec3(threshold), vec3(0.0)) * boost;
        return vec4(e, 1.0);
    }
    """

    /// Composite an adjusted image over a base through a single-channel mask.
    /// Linear interpolation, unclamped — the local stage blends scene-referred values.
    static let blendMaskSource = """
    kernel vec4 lumenBlendMask(__sample base, __sample over, __sample mask) {
        float m = clamp(mask.r, 0.0, 1.0);
        return vec4(mix(base.rgb, over.rgb, m), base.a);
    }
    """

    /// Density-domain grain (docs/14 §5.7). Amplitude peaks at mid densities and
    /// vanishes at Dmin and Dmax, which is why film grain lives in the midtones and
    /// clean film blacks stay clean — the property a constant-sigma RGB overlay
    /// cannot reproduce.
    /// The recovery factor MUST be `FilmGrainProfile.plateEncodeScale` — the same
    /// number `grainPlate` divides by. It used to be hardcoded as 2.0 against a store
    /// that divided by 4, so the GPU saw half the amplitude the reference defines.
    /// Interpolated rather than written out, so the pair cannot drift again.
    static let grainSource = """
    kernel vec4 lumenGrain(__sample image, __sample noise, float amount, float dmax) {
        vec3 c = max(image.rgb, vec3(1e-5));
        vec3 d = -log(c) / log(10.0);
        vec3 p = clamp(d / dmax, 0.0, 1.0);
        vec3 amp = sqrt(max(p * (vec3(1.0) - p), vec3(0.0)));
        vec3 n = (noise.rgb - vec3(0.5)) * \(Float(FilmGrainProfile.plateEncodeScale));
        vec3 d2 = d + amp * n * amount;
        vec3 shifted = pow(vec3(10.0), -d2);
        return vec4(shifted, image.a);
    }
    """

    // MARK: - S3, profiled classical noise reduction

    /// Scene-linear → the variance-stabilized plane the shrinkage runs in, expressed
    /// relative to mid-grey and scaled (`ClassicalDenoise.GPUPlan`).
    ///
    /// **Units.** Everything here is in the LINEAR working image's own units, not in
    /// EV and not in `LumenLog`'s encoded domain: `shot` and `offset` come straight
    /// from a `NoiseProfile`, whose `variance = a·signal + b` is a statement about
    /// linear signal. Nothing on this path may carry a `LumenLog.range`.
    ///
    /// The output plane's unit is one standard deviation of sensor noise — that is what
    /// a variance-stabilizing transform is for — so every threshold downstream is a
    /// number of σ and means the same thing at every brightness.
    ///
    /// Written as `2(x − x₀)/(√u + √u₀)` rather than as `(2/a)(√u − √u₀)`. The two are
    /// algebraically identical, and the second computes 2.0e8 minus 2.0e8 in a float32
    /// shader for a read-noise-dominated profile. See `GPUPlan` for the derivation and
    /// for why the same expression covers the `a → 0` case with no branch.
    static let denoiseForwardSource = """
    kernel vec4 lumenDenoiseForward(__sample c, float shot, float offset,
                                    float pedestal, float sqrtPedestal,
                                    float signalFloor, float scale) {
        vec3 x = max(c.rgb, vec3(signalFloor));
        vec3 u = max(shot * x + vec3(offset), vec3(0.0));
        vec3 g = scale * 2.0 * (x - vec3(pedestal)) / (sqrt(u) + vec3(sqrtPedestal));
        return vec4(g, c.a);
    }
    """

    /// The variance-stabilized plane back to scene-linear, blending the algebraic and
    /// the exact-unbiased inverses in proportion to how much shrinking actually
    /// happened — the correction is a debias for an estimated coefficient and a milky
    /// pedestal for an unshrunk one.
    ///
    /// `d` is floored at 1.0 rather than at the transform's own 1.2247 minimum. On the
    /// live branch `d` is already above that, so the floor is a no-op; on the
    /// degenerate branch — pure read noise, where `unbiasedGain` is zero — it is what
    /// keeps `0 · (1/0)` from producing a NaN across the whole frame.
    static let denoiseInverseSource = """
    kernel vec4 lumenDenoiseInverse(__sample g, float shot, float pedestal,
                                    float sqrtPedestal, float invScale,
                                    float minRelative, float reference,
                                    float unbiasedGain, float shrinkage) {
        vec3 v = g.rgb * invScale;
        vec3 w = max(v, vec3(minRelative));
        vec3 algebraic = vec3(pedestal) + 0.25 * shot * v * v + v * sqrtPedestal;
        vec3 clamped = vec3(pedestal) + 0.25 * shot * w * w + w * sqrtPedestal;
        vec3 d = max(w + vec3(reference), vec3(1.0));
        vec3 i1 = vec3(1.0) / d;
        vec3 i2 = i1 * i1;
        vec3 correction = vec3(0.25) + 0.25 * 1.224744871391589 * i1
            - 1.375 * i2 + 0.625 * 1.224744871391589 * i2 * i1;
        vec3 x = algebraic
            + shrinkage * (clamped - algebraic + unbiasedGain * correction);
        return vec4(x, g.a);
    }
    """

    /// One separable pass of the à-trous transform's B3-spline row, `[1,4,6,4,1]/16`,
    /// with the taps `tap` pixels apart — the "holes" the transform is named for. Level
    /// `j` passes `tap = 2^j` along one axis.
    ///
    /// **A general kernel, not a colour kernel, and that is the whole point.** The first
    /// version of this passed five translated copies of the image into a `CIColorKernel`
    /// and let each `__sample` pick up its own offset. A colour kernel's contract is
    /// that it reads exactly the pixel it is producing — that contract is what lets Core
    /// Image concatenate a colour kernel with a geometry node and hoist the transform
    /// out — so handing one five differently-translated inputs is asking it to break its
    /// own rule. Measured on the macOS runner, the five-level stack built that way
    /// differed from `ClassicalDenoise.apply` by 71% of the stage's own effect, where the
    /// numpy model of the same arithmetic agrees to 6e-16 in double and 5e-4 in half.
    ///
    /// A general kernel says where it samples, and `roiCallback` tells Core Image how
    /// much of the input each output tile needs. Nothing is left to infer.
    static let bSpline5Source = """
    kernel vec4 lumenBSpline5(sampler src, vec2 tap) {
        vec2 p = destCoord();
        vec4 t0 = sample(src, samplerTransform(src, p - 2.0 * tap));
        vec4 t1 = sample(src, samplerTransform(src, p - tap));
        vec4 t2 = sample(src, samplerTransform(src, p));
        vec4 t3 = sample(src, samplerTransform(src, p + tap));
        vec4 t4 = sample(src, samplerTransform(src, p + 2.0 * tap));
        vec3 v = (t0.rgb + t4.rgb + 4.0 * (t1.rgb + t3.rgb) + 6.0 * t2.rgb) / 16.0;
        return vec4(v, t2.a);
    }
    """

    /// One separable pass of a radius-1 box blur. Three of these on each axis is
    /// exactly what `SpatialOps.gaussianBlur(_:sigma: 1.5)` does — Kovesi's box widths
    /// for σ = 1.5 are [1, 1, 1] — and it is a kernel rather than `CIBoxBlur` because
    /// that filter returns its input unchanged at radius 1.
    static let box3Source = """
    kernel vec4 lumenBox3(sampler src, vec2 tap) {
        vec2 p = destCoord();
        vec4 centre = sample(src, samplerTransform(src, p));
        vec3 lo = sample(src, samplerTransform(src, p - tap)).rgb;
        vec3 hi = sample(src, samplerTransform(src, p + tap)).rgb;
        return vec4((lo + centre.rgb + hi) / 3.0, centre.a);
    }
    """

    /// Chroma magnitude √(U0² + V0²) of the decorrelated plane, broadcast. The chroma
    /// edge map is built on this rather than on either chroma channel alone, so a
    /// saturated edge across flat luminance still protects itself.
    static let chromaMagnitudeSource = """
    kernel vec4 lumenChromaMagnitude(__sample p) {
        float m = sqrt(p.g * p.g + p.b * p.b);
        return vec4(m, m, m, 1.0);
    }
    """

    /// Gradient-magnitude edge map in [0,1] from four central-difference taps.
    ///
    /// The knees arrive already denominated in the plane they are applied to: they are
    /// stated in units of the blurred plane's own noise σ and multiplied through by
    /// `1/(2√π·σ_blur)` and the encoded scale on the way in, so the map means the same
    /// thing at every noise level and at every profile.
    static let edgeMapSource = """
    kernel vec4 lumenEdgeMap(sampler src, float lo, float hi) {
        vec2 p = destCoord();
        float xp = sample(src, samplerTransform(src, p + vec2(1.0, 0.0))).r;
        float xm = sample(src, samplerTransform(src, p - vec2(1.0, 0.0))).r;
        float yp = sample(src, samplerTransform(src, p + vec2(0.0, 1.0))).r;
        float ym = sample(src, samplerTransform(src, p - vec2(0.0, 1.0))).r;
        float gx = (xp - xm) * 0.5;
        float gy = (yp - ym) * 0.5;
        float e = smoothstep(lo, hi, sqrt(gx * gx + gy * gy));
        return vec4(e, e, e, 1.0);
    }
    """

    /// What soft thresholding REMOVES from one à-trous band: `clamp(d, −t, t)`.
    ///
    /// Soft thresholding is `d − clamp(d, −t, t)`, so returning the clamp and
    /// subtracting it from the running image reconstructs identically — and does it
    /// without ever summing five full-range planes back together. In a half-float
    /// working format that matters: the correction is small and bounded, while the
    /// planes are not.
    ///
    /// One kernel for all three channels, with the thresholds and the edge protections
    /// carried per channel: luma reads the luma edge map, both chroma channels read the
    /// chroma one. A zero threshold removes nothing, which is exactly what the
    /// reference does when a band's threshold is zero.
    static let denoiseRemovedSource = """
    kernel vec4 lumenDenoiseRemoved(__sample detail, __sample lumaEdge,
                                    __sample chromaEdge, vec3 threshold,
                                    vec3 protection) {
        vec3 e = clamp(vec3(lumaEdge.r, chromaEdge.r, chromaEdge.r), 0.0, 1.0);
        vec3 t = threshold * (vec3(1.0) - protection * e);
        return vec4(clamp(detail.rgb, -t, t), 1.0);
    }
    """

    /// Blend two separately filtered chroma planes back into the decorrelated image,
    /// leaving luma alone — the large-scale chroma blotch pass's recombination.
    static let mixChromaSource = """
    kernel vec4 lumenMixChroma(__sample base, __sample u, __sample v, float amount) {
        return vec4(base.r, mix(base.g, u.r, amount), mix(base.b, v.r, amount), base.a);
    }
    """

    /// Hot Pixels: replace a single-pixel outlier with the median of its eight
    /// neighbours (docs/07 §2.5).
    ///
    /// Two conditions, both required, exactly as the reference states them: the pixel
    /// must deviate from that median by more than `k·σ` with σ read from the noise
    /// profile AT THE MEDIAN — the pixel's own value is the thing under suspicion — and
    /// it must be a strict extremum of the 3×3 neighbourhood. The second is what makes
    /// this single-pixel: an edge or a fine line always has a neighbour on the same
    /// side of the median, so it is never an extremum and never touched.
    ///
    /// The median comes from a Batcher odd-even mergesort, 19 comparators of `min`/`max`
    /// on vec3 — branchless, like every kernel here, and the whole reason the network is
    /// spelled out rather than looped. The comparator list is the data; the shader text
    /// is generated from it so a transcription slip is not possible.
    static let hotPixelSource: String = {
        let network: [(Int, Int)] = [
            (0, 1), (2, 3), (4, 5), (6, 7),
            (0, 2), (1, 3), (4, 6), (5, 7),
            (1, 2), (5, 6),
            (0, 4), (1, 5), (2, 6), (3, 7),
            (2, 4), (3, 5),
            (1, 2), (3, 4), (5, 6),
        ]
        let sort = network.map { pair in
            "    t = min(a\(pair.0), a\(pair.1));"
                + " a\(pair.1) = max(a\(pair.0), a\(pair.1)); a\(pair.0) = t;"
        }.joined(separator: "\n    ")
        return """
        kernel vec4 lumenHotPixel(sampler src, float k, float shot, float variance) {
            vec2 p = destCoord();
            vec3 a0 = sample(src, samplerTransform(src, p + vec2(-1.0, -1.0))).rgb;
            vec3 a1 = sample(src, samplerTransform(src, p + vec2( 0.0, -1.0))).rgb;
            vec3 a2 = sample(src, samplerTransform(src, p + vec2( 1.0, -1.0))).rgb;
            vec3 a3 = sample(src, samplerTransform(src, p + vec2(-1.0,  0.0))).rgb;
            vec3 a4 = sample(src, samplerTransform(src, p + vec2( 1.0,  0.0))).rgb;
            vec3 a5 = sample(src, samplerTransform(src, p + vec2(-1.0,  1.0))).rgb;
            vec3 a6 = sample(src, samplerTransform(src, p + vec2( 0.0,  1.0))).rgb;
            vec3 a7 = sample(src, samplerTransform(src, p + vec2( 1.0,  1.0))).rgb;
            vec4 c = sample(src, samplerTransform(src, p));
            vec3 t;
        \(sort)
            vec3 median = (a3 + a4) * 0.5;
            vec3 v = c.rgb;
            vec3 sigma = sqrt(max(shot * max(median, vec3(0.0)) + vec3(variance),
                                  vec3(1e-12)));
            vec3 outside = max(vec3(1.0) - step(v, a7), vec3(1.0) - step(a0, v));
            vec3 far = vec3(1.0) - step(abs(v - median), k * sigma);
            return vec4(mix(v, median, outside * far), c.a);
        }
        """
    }()

    /// Vignette as an EV multiply in scene-linear (docs/14 §2.1.11: the lens vignettes
    /// the light before it reaches the film, so this belongs upstream of the curve and
    /// gets highlight-priority behaviour free from the transform's shoulder).
    /// The vignette, with the highlight protection the reference has and this kernel
    /// did not.
    ///
    /// `DetailEngine.vignette` blends the burn back toward identity above half the
    /// default scene white, at the documented Highlights-50 disclosure default — it is
    /// what keeps a burn off a bright sky while it still shapes the corners. Without
    /// it, a corner containing a window or a specular took the full amount: measured
    /// against the reference, a corner at or above 5.76 scene-linear got −1.000 EV here
    /// against the reference's −0.500, and at the slider's −3.0 floor that is a 2.8x
    /// difference in gain between the picture the user sees and the one the reference
    /// renders. The panel note quotes the protection as if it were applied.
    static let vignetteSource = """
    kernel vec4 lumenVignette(__sample image, vec2 centre, vec2 invRadius, float ev,
                              float feather, vec3 lumaWeights, float threshold,
                              float protection) {
        vec2 d = (destCoord() - centre) * invRadius;
        float r = length(d);
        float t = smoothstep(1.0 - feather, 1.0, r);
        float lum = dot(image.rgb, lumaWeights);
        float protect = protection * smoothstep(threshold, threshold * 2.0, lum);
        float gain = exp2(ev * t * (1.0 - protect));
        return vec4(image.rgb * gain, image.a);
    }
    """

    // MARK: - Compiled kernels

    public static let logEncode = make(logEncodeSource)
    public static let logDecode = make(logDecodeSource)
    public static let multiply = make(multiplySource)
    public static let square = make(squareSource)
    public static let luminance = make(luminanceSource)
    public static let guidedCoefficients = make(guidedCoefficientsSource)
    public static let guidedCrossCoefficients = make(guidedCrossCoefficientsSource)
    public static let guidedApply = make(guidedApplySource)
    public static let blendMask = make(blendMaskSource)
    public static let grain = make(grainSource)
    public static let vignette = make(vignetteSource)
    public static let detailGain = make(detailGainSource)
    public static let sharpenDelta = make(sharpenDeltaSource)
    public static let subtract = make(subtractSource)
    public static let thresholdMask = make(thresholdMaskSource)
    public static let tonalFalloff = make(tonalFalloffSource)
    public static let structureTensor = make(structureTensorSource)
    public static let coherence = make(coherenceSource)
    public static let detailGainGated = make(detailGainGatedSource)
    public static let lumaRatio = make(lumaRatioSource)
    public static let tensorMagnitude = make(tensorMagnitudeSource)
    public static let dehaze = make(dehazeSource)
    public static let addGlow = make(addGlowSource)
    public static let highlightEnergy = make(highlightEnergySource)
    public static let denoiseForward = make(denoiseForwardSource)
    public static let denoiseInverse = make(denoiseInverseSource)
    public static let chromaMagnitude = make(chromaMagnitudeSource)
    public static let denoiseRemoved = make(denoiseRemovedSource)
    public static let mixChroma = make(mixChromaSource)

    // The four that read a neighbourhood are GENERAL kernels. A colour kernel promises
    // to read only the pixel it is producing, and Core Image relies on that promise —
    // so a neighbourhood has to be asked for explicitly, with an ROI to match.
    public static let bSpline5 = makeGeneral(bSpline5Source)
    public static let box3 = makeGeneral(box3Source)
    public static let edgeMap = makeGeneral(edgeMapSource)
    public static let hotPixel = makeGeneral(hotPixelSource)

    /// Every kernel compiled. False means this macOS build rejected the kernel
    /// language and the renderer must use the CPU reference path.
    public static var isAvailable: Bool { unavailableKernels.isEmpty }

    /// Names of the kernels that failed, for the diagnostic the UI shows rather than
    /// pretending everything is fine.
    public static var unavailableKernels: [String] {
        let all: [(String, CIKernel?)] = [
            ("logEncode", logEncode), ("logDecode", logDecode),
            ("multiply", multiply), ("square", square), ("luminance", luminance),
            ("guidedCoefficients", guidedCoefficients),
            ("guidedCrossCoefficients", guidedCrossCoefficients),
            ("guidedApply", guidedApply),
            ("blendMask", blendMask), ("grain", grain), ("vignette", vignette),
            ("detailGain", detailGain), ("dehaze", dehaze), ("addGlow", addGlow),
            ("sharpenDelta", sharpenDelta), ("lumaRatio", lumaRatio),
            ("subtract", subtract), ("thresholdMask", thresholdMask), ("tonalFalloff", tonalFalloff),
            ("structureTensor", structureTensor),
            ("coherence", coherence), ("detailGainGated", detailGainGated),
            ("tensorMagnitude", tensorMagnitude),
            ("highlightEnergy", highlightEnergy),
            ("denoiseForward", denoiseForward), ("denoiseInverse", denoiseInverse),
            ("bSpline5", bSpline5), ("box3", box3),
            ("chromaMagnitude", chromaMagnitude), ("edgeMap", edgeMap),
            ("denoiseRemoved", denoiseRemoved), ("mixChroma", mixChroma),
            ("hotPixel", hotPixel),
        ]
        return all.filter { $0.1 == nil }.map { $0.0 }
    }

    /// The kernels S3 needs. Denoise degrades as a whole rather than in pieces: half a
    /// wavelet shrinkage is not a gentler denoise, it is a wrong picture.
    public static var denoiseAvailable: Bool {
        denoiseForward != nil && denoiseInverse != nil && bSpline5 != nil
            && box3 != nil && chromaMagnitude != nil && edgeMap != nil
            && denoiseRemoved != nil && subtract != nil
    }

    /// The kernels the core colour path cannot run without. Presence, film and mask
    /// stages degrade individually; without these the whole graph is wrong.
    public static var coreAvailable: Bool {
        logEncode != nil && logDecode != nil && multiply != nil && luminance != nil
    }

    private static func make(_ source: String) -> CIColorKernel? {
        CIColorKernel(source: source)
    }

    /// A kernel that reads a neighbourhood. Deliberately a different constructor from
    /// `make`, because the distinction is a contract and not a detail: a `CIColorKernel`
    /// may read only the pixel it is producing, and Core Image is free to rearrange the
    /// graph around one on that basis.
    private static func makeGeneral(_ source: String) -> CIKernel? {
        CIKernel(source: source)
    }

    // MARK: - Convenience application

    public static func apply(_ kernel: CIColorKernel?, extent: CGRect,
                             _ arguments: [Any]) -> CIImage? {
        guard let kernel else { return nil }
        return kernel.apply(extent: extent, arguments: arguments)
    }

    /// Apply a neighbourhood kernel. `reach` is how far, in pixels, the kernel samples
    /// away from the pixel it is producing; it becomes the region-of-interest callback,
    /// which is what Core Image asks in order to render the frame in tiles without a
    /// seam at every tile boundary. Getting it too small is invisible on a small test
    /// frame and ruinous on a 45-megapixel export.
    public static func applyNeighbourhood(_ kernel: CIKernel?, extent: CGRect,
                                          reach: CGFloat,
                                          _ arguments: [Any]) -> CIImage? {
        guard let kernel else { return nil }
        return kernel.apply(extent: extent,
                            roiCallback: { _, rect in rect.insetBy(dx: -reach,
                                                                   dy: -reach) },
                            arguments: arguments)
    }
}

// MARK: - Cube upload

public enum ColorCube {

    /// Wrap a baked table in the stock colour-cube filter. The data layout LUT3D
    /// produces (red fastest, then green, then blue; RGBA floats) is exactly what
    /// Core Image wants, so this is a memcpy and a filter, not a conversion.
    public static func filter(_ lut: LUT3D, image: CIImage) -> CIImage? {
        let data = lut.data.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(lut.size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        return filter.outputImage
    }
}

#endif
