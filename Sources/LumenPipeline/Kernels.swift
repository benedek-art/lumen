// Kernels.swift
// The complete custom-shader surface of Lumen's render path: thirty-three small kernels.
// (A count that was "thirty-two" in three places while the registry held 33 — if you add
// a kernel, grep for the number word and update all of them, or better, stop counting.)
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
    ///
    /// The exponent is CLAMPED at ±4 EV — the twin of the reference's
    /// `DetailEngine.applyLumaRatio(limit: 4)`, which bounds every presence tool's
    /// excursion "so a pathological coefficient cannot turn into an infinity
    /// downstream" (docs/31 round two §15). This kernel had no limit at all: `k` at
    /// Texture ±100 is 21.6 per encoded unit, so a pathological band drove
    /// `exp2(unbounded)` while the reference stopped at 2^±4.
    static let detailGainSource = """
    kernel vec4 lumenDetailGain(__sample hi, __sample lo, float k) {
        float e = clamp(k * (hi.r - lo.r), -4.0, 4.0);
        float g = exp2(e);
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
    ///
    /// `negative` picks which of the two gate shapes `DetailEngine.applyTexture` uses,
    /// and the two are not the same function for a reason. Negative Texture closes on
    /// any structure at all (`1 − coherence`), because smoothing an edge is never
    /// wanted. Positive Texture closes only on genuine coherent edges, because an
    /// ungated gain on a band that still contains the edge rims it: measured against
    /// the reference on a clean 3 EV step, 1.39 EV of trench at +100 against the
    /// 0.30 EV bar the presence golden holds Clarity to. Mirroring the negative gate
    /// instead would have flattened hair and fabric weave — measured at 0.19 coherence
    /// where a hard step measures 1.00 — which are the subjects the positive control
    /// exists for, so the gate only starts closing above them.
    /// The exponent carries the same ±4 EV clamp as `detailGain` — the twin of the
    /// reference's `applyLumaRatio(limit: 4)`; see that kernel's comment.
    static let detailGainGatedSource = """
    kernel vec4 lumenDetailGainGated(__sample hi, __sample lo, __sample gate,
                                     float k, float negative,
                                     float gateLo, float gateHi) {
        float c = clamp(gate.r, 0.0, 1.0);
        float closed = mix(smoothstep(gateLo, gateHi, c), c, negative);
        float open = 1.0 - closed;
        float e = clamp(k * open * (hi.r - lo.r), -4.0, 4.0);
        float g = exp2(e);
        return vec4(g, g, g, 1.0);
    }
    """

    /// Keep the pixels where a plane is at or above a threshold, zero elsewhere, and
    /// carry the selection weight in alpha so a masked mean can be recovered from two
    /// area averages.
    /// Clarity, as the reference parameterizes it: the Aubry remap on the detail band,
    /// applied at one scale.
    ///
    /// `DetailEngine.applyClarity` is a local Laplacian. Every one of its six reference
    /// levels remaps the image through `r(x) = γ + sign(d)·σ·(|d|/σ)^α` for `|d| ≤ σ`
    /// and the identity beyond, with `α = max(1 − 0.7·amount·w, 0.05)` and `w` a
    /// Gaussian on the tone. `α < 1` expands sub-σ detail; the identity branch is why
    /// an edge larger than σ passes at unit slope. This applies that same point
    /// function to a single band, which is what a Core Image graph can afford.
    ///
    /// What it replaces: `exp2(k · Δ)` with `k = amount/100 · 1.1 · range`, a linear
    /// gain on the band with an amplitude nobody had checked against the reference.
    /// Measured against `applyClarity` on five frames, that construction applied
    /// between 1/2.6 and 1/48 of the reference's gain — Clarity +30 on the spatial
    /// golden's own frame moved it 0.00098 where the reference moves it 0.0096. The
    /// remap lands between 0.5x and 1.3x instead, because a power law with α < 1
    /// expands a SMALL band much harder than a linear gain does: at Δ = 0.1 EV and
    /// Clarity +30 it adds 50% where `k` adds 33%, and the edge-preserving base leaves
    /// exactly such small bands.
    ///
    /// The tone weight is computed here rather than passed in as an image, which drops
    /// a filter node and the `tonalFalloff` kernel that fed it.
    ///
    /// Halo, measured on a clean 3 EV step: 0.0117 EV at +30 and 0.127 EV at +100,
    /// against the reference local Laplacian's 0.0014 and 0.0049 and against 0.72 EV
    /// for the two-base construction that preceded the current one. The multi-scale
    /// pyramid suppresses the rim in a way one band cannot — it selects each output
    /// coefficient by the pixel's own local average, so `d` never sweeps through the
    /// sub-σ range on the way across an edge. Closing that gap is the local Laplacian
    /// on the GPU, and it is not this change.
    static let detailRemapSource = """
    kernel vec4 lumenDetailRemap(__sample hi, __sample lo, float amount, float sigmaEV,
                                 float centre, float range, float midtoneEV) {
        float dEV = (hi.r - lo.r) * range;
        float gammaEV = (hi.r - centre) * range;
        float w = exp(-(gammaEV * gammaEV) / (2.0 * midtoneEV * midtoneEV));
        float alpha = max(1.0 - 0.7 * amount * w, 0.05);
        float mag = abs(dEV);
        float t = min(mag / sigmaEV, 1.0);
        // `pow` is undefined at 0 on some drivers; the branch also skips the whole
        // remap for the edges it is defined to pass through untouched.
        float added = (mag >= sigmaEV || mag < 1e-7)
            ? 0.0
            : (sigmaEV * pow(t, alpha) - mag) * sign(dEV);
        float g = exp2(added);
        return vec4(g, g, g, 1.0);
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

    // MARK: Parametric mask alpha — the tail's fix (docs/35 §5.1)
    //
    // Linear and radial gradients are closed-form per-pixel functions: a smoothstep
    // along an axis, and a signed distance to an ellipse. They were rasterized on the
    // CPU into a `Plane` like everything else, so dragging one missed the raster cache
    // on every mouse event, was served the PREVIOUS raster, and the picture arrived a
    // gesture behind the handle — the tail. Evaluated here they cost a pass over the
    // pixels the frame was going to touch anyway, and there is nothing to cache or miss.
    //
    // COORDINATES ARE LONG-EDGE UNITS, exactly as `MaskRaster.linearPlane` and
    // `radialPlane` use them, because pixels are square and normalized coordinates are
    // not: a rotation applied to (fraction of width, fraction of height) mixes two units
    // and renders a 45° ellipse at 33.7°. `w`, `h` and the derived long edge are passed
    // in rather than read from `destCoord`'s extent so the two implementations cannot
    // disagree about which pixel centre they are asking about.
    //
    // THE LONG EDGE IS SPELLED `edge`, NOT `long`, and the spelling is load-bearing.
    // `long` is a reserved word in the Core Image Kernel Language — it inherits GLSL's
    // keyword list — so `float long = max(w, h)` is a parse error, not a variable.
    // Both kernels below shipped with it, both failed to compile on every macOS build
    // ("4 errors generated" in the gpu-parity log), `parametricMasksAvailable` was
    // therefore false, and `MaskGPU` fell back to `MaskRaster` on the CPU for every
    // gradient mask ever drawn — which is why dragging a radial gradient trailed the
    // hand no matter how the overlay was coalesced. Nothing said so, because the
    // sentinel test's roster did not include these four kernels; see
    // `unavailableMaskKernels`.
    //
    // Every constant below is `MaskRaster`'s. `MaskGPUParityTests` compares the two at
    // three resolutions and fails on a worst-pixel difference past 1e-4.

    /// A linear gradient's raw alpha.
    static let maskLinearSource = """
    kernel vec4 lumenMaskLinear(float x0, float y0, float x1, float y1,
                                float w, float h, float ox, float oy) {
        float edge = max(w, h);
        vec2 p = (destCoord() - vec2(ox, oy)) / edge;
        vec2 a = vec2(x0 * w / edge, y0 * h / edge);
        vec2 b = vec2(x1 * w / edge, y1 * h / edge);
        vec2 ab = b - a;
        float dd = dot(ab, ab);
        if (dd < 1e-12) { return vec4(0.0, 0.0, 0.0, 1.0); }
        float t = clamp(dot(p - a, ab) / dd, 0.0, 1.0);
        float v = t * t * (3.0 - 2.0 * t);
        return vec4(v, v, v, 1.0);
    }
    """

    /// A radial gradient's raw alpha. `rin` is the flat core, computed on the CPU side
    /// with the same pixel guard the reference applies, so the shader carries no policy.
    static let maskRadialSource = """
    kernel vec4 lumenMaskRadial(float cx, float cy, float rx, float ry,
                                float ct, float st, float rin,
                                float w, float h, float ox, float oy) {
        float edge = max(w, h);
        vec2 p = (destCoord() - vec2(ox, oy)) / edge;
        vec2 q = p - vec2(cx * w / edge, cy * h / edge);
        float qx = q.x * ct - q.y * st;
        float qy = q.x * st + q.y * ct;
        float nx = qx / max(rx * w / edge, 1e-12);
        float ny = qy / max(ry * h / edge, 1e-12);
        float r = sqrt(nx * nx + ny * ny);
        float v;
        if (r <= rin) { v = 1.0; }
        else if (r >= 1.0) { v = 0.0; }
        else {
            float t = clamp((r - rin) / max(1.0 - rin, 1e-12), 0.0, 1.0);
            v = 1.0 - t * t * (3.0 - 2.0 * t);
        }
        return vec4(v, v, v, 1.0);
    }
    """

    /// One fold step. `op` is `MaskOp`'s ordinal — 0 add, 1 subtract, 2 intersect — and
    /// `invert`/`amount` are the component's, applied in `MaskAlgebra.componentAlpha`'s
    /// order: clamp, invert, scale. The accumulator seeds at zero, so a stack opening
    /// with subtract or intersect stays empty, which is the property maskalgebra.json
    /// pins for the CPU fold.
    static let maskFoldSource = """
    kernel vec4 lumenMaskFold(__sample acc, __sample raw,
                              float op, float invert, float amount) {
        float v = clamp(raw.r, 0.0, 1.0);
        if (invert > 0.5) { v = 1.0 - v; }
        v = v * clamp(amount, 0.0, 100.0) / 100.0;
        float a = clamp(acc.r, 0.0, 1.0);
        float out;
        if (op > 1.5) { out = a * v; }
        else if (op > 0.5) { out = min(a, 1.0 - v); }
        else { out = max(a, v); }
        return vec4(out, out, out, 1.0);
    }
    """

    /// The whole-mask invert, which runs after the fold and before the refinement chain.
    static let maskInvertSource = """
    kernel vec4 lumenMaskInvert(__sample a) {
        float v = 1.0 - clamp(a.r, 0.0, 1.0);
        return vec4(v, v, v, 1.0);
    }
    """

    /// The same composite, through a mask's BLEND MODE (docs/36 §3, bet 1).
    ///
    /// `mode` is `MaskBlend`'s ordinal — 0 normal, 1 luminosity, 2 colour — and
    /// `lr/lg/lb` are the working space's luminance coefficients, passed in rather than
    /// hardcoded so this kernel cannot disagree with `RGBColorSpace.luminance`, which is
    /// what `MaskAlgebra.blended` uses on the CPU side.
    ///
    /// Both non-normal modes are luminance-RATIO rescales, so they are exact on
    /// scene-referred values and need no white point. The guards match the reference's
    /// `luminanceFloor` and its fallbacks: a pixel with no luminance has no colour ratio
    /// to preserve, so Luminosity falls through to the adjusted pixel and Colour to the
    /// base, rather than to a division.
    static let blendMaskModeSource = """
    kernel vec4 lumenBlendMaskMode(__sample base, __sample over, __sample mask,
                                   float mode, float lr, float lg, float lb) {
        float m = clamp(mask.r, 0.0, 1.0);
        vec3 result = over.rgb;
        vec3 coef = vec3(lr, lg, lb);
        float floorY = 1e-7;
        if (mode > 1.5) {
            float from = dot(over.rgb, coef);
            float to = dot(base.rgb, coef);
            result = (from > floorY) ? over.rgb * (to / from) : base.rgb;
        } else if (mode > 0.5) {
            float from = dot(base.rgb, coef);
            float to = dot(over.rgb, coef);
            result = (from > floorY) ? base.rgb * (to / from) : over.rgb;
        }
        return vec4(mix(base.rgb, result, m), base.a);
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
    /// `noise` is a tiled dither plate carrying (−0.5, +0.5) in its red channel and
    /// `ditherEV` is one half-float quantum of the LOG-ENCODED plane, expressed in
    /// EV — together they add ±half a quantum of ordered noise to the burn's
    /// exponent wherever the vignette is active (docs/31 round two §7's
    /// change-of-denomination arithmetic, applied as a dither). Why: the working
    /// format is RGBAh, and the log-encoded plane the finish table samples parks
    /// the picture where one fp16 step is 0.0117 EV. A strong burn is a slow,
    /// noise-free synthetic ramp — exactly the signal that quantum turns into
    /// visible rings at −3 EV, which the owner reported. Randomising the exponent
    /// by half a quantum makes the encoded plane's rounding land on the code above
    /// or below in the proportion the true value asks for, so the local MEAN of
    /// the ramp survives fp16 the way the output dither preserves it through
    /// 8-bit. Gated on `t > 0` so the untouched centre stays bit-identical, and
    /// zero-mean so the reference — which quantises nowhere — is approached, not
    /// left.
    static let vignetteSource = """
    kernel vec4 lumenVignette(__sample image, __sample noise, vec2 centre,
                              vec2 invRadius, float ev, float feather,
                              vec3 lumaWeights, float threshold,
                              float protection, float ditherEV) {
        vec2 d = (destCoord() - centre) * invRadius;
        float r = length(d);
        float t = smoothstep(1.0 - feather, 1.0, r);
        float lum = dot(image.rgb, lumaWeights);
        float protect = protection * smoothstep(threshold, threshold * 2.0, lum);
        float dith = noise.r * ditherEV * step(1e-6, t);
        float gain = exp2(ev * t * (1.0 - protect) + dith);
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
    public static let blendMaskMode = make(blendMaskModeSource)
    // GENERAL kernels, not colour ones: they take no `__sample` at all, and a colour
    // kernel is defined as a function of the pixel it is given. `applyGenerator` gives
    // them an extent and nothing else.
    public static let maskLinear = makeGeneral(maskLinearSource)
    public static let maskRadial = makeGeneral(maskRadialSource)
    public static let maskFold = make(maskFoldSource)
    public static let maskInvert = make(maskInvertSource)
    public static let grain = make(grainSource)
    public static let vignette = make(vignetteSource)
    public static let detailGain = make(detailGainSource)
    public static let sharpenDelta = make(sharpenDeltaSource)
    public static let subtract = make(subtractSource)
    public static let thresholdMask = make(thresholdMaskSource)
    public static let detailRemap = make(detailRemapSource)
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
            ("subtract", subtract), ("thresholdMask", thresholdMask), ("detailRemap", detailRemap),
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

    /// The parametric-mask fast path. Without all four the graph falls back to
    /// `MaskRaster`, which is correct and slower — never to a wrong mask.
    public static var parametricMasksAvailable: Bool { unavailableMaskKernels.isEmpty }

    /// Names of the mask kernels that failed. Separate from `unavailableKernels` on
    /// purpose: that list gates the whole GPU path (`KernelAvailability.coreAvailable`)
    /// and a mask kernel has its own honest fallback, so it must not take the picture
    /// down with it. But it MUST be loud somewhere — these four were absent from every
    /// roster, so two of them failed to compile on every build without a single test
    /// noticing, and the fast path this file exists to provide never ran.
    /// `testEveryKernelCompiles` asserts this list is empty too.
    public static var unavailableMaskKernels: [String] {
        let all: [(String, CIKernel?)] = [
            ("maskLinear", maskLinear), ("maskRadial", maskRadial),
            ("maskFold", maskFold), ("maskInvert", maskInvert),
        ]
        return all.filter { $0.1 == nil }.map { $0.0 }
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

    /// Apply a kernel that reads no input image at all — a generator.
    ///
    /// Separate from `applyNeighbourhood` because the region-of-interest question does
    /// not arise: there is no input to ask about. Core Image is given the extent and the
    /// scalars, and every pixel is a closed form of `destCoord()`.
    public static func applyGenerator(_ kernel: CIKernel?, extent: CGRect,
                                      _ arguments: [Any]) -> CIImage? {
        guard let kernel else { return nil }
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                            arguments: arguments)
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

    /// A table already converted to the bytes `CIColorCube` wants, so a cube whose
    /// CONTENTS never change is copied once rather than once per frame.
    ///
    /// The memcpy in `filter(_ lut:image:)` below is nothing at the sizes most of this
    /// graph uses and is not nothing at 64. `DitherStepCube` is 64 cubed in RGBA floats
    /// — 4 MB — and the dither is not an export-only stage: `renderPreview` dithers
    /// every frame it shows, draft and settle alike, so that the loupe does not band
    /// where the delivered file will not. At the frame rate a slider drag produces that
    /// was several hundred megabytes a second of transient allocation for a table that
    /// is the same four bytes at a time as it was on the previous frame — and a freshly
    /// allocated `Data` every frame also denies Core Image any chance of recognising an
    /// upload it already holds and reusing the texture behind it.
    ///
    /// WHY THE BYTES AND NOT THE WHOLE FILTER, which would save the last allocation too.
    /// A `CIColorCube` is a mutable Objective-C object, and the first thing any caller
    /// does to one is `setValue(image, forKey: kCIInputImageKey)`. A cached filter is
    /// therefore shared MUTABLE state, and `ColorCube.filter` is a public static that
    /// any thread may call. `RenderCoordinator` being a serial actor does not settle it:
    /// `PipelineRenderer` is a plain `final class` with no isolation of its own, the
    /// export path does not go through the coordinator at all, and the app runs pipeline
    /// work off `Task.detached` workers while `MaskRasterCache` bakes on its own
    /// `DispatchQueue`. Two renders overlapping on one shared filter would race on
    /// `inputImage`, and the failure that buys is a frame of the wrong photograph — a
    /// picture bug, produced by a performance fix, which is a bad trade at any speed.
    ///
    /// Caching the bytes leaves nothing mutable to share. `Data` is a `Sendable` value
    /// type and this struct holds nothing else, so a `static let` of one is safe to read
    /// from anywhere with no lock and no `@unchecked`. What remains per call is an
    /// object header and three `setValue`s; the 4 MB was the whole of the cost.
    public struct Baked: Sendable {
        public let size: Int
        public let data: Data

        public init(_ lut: LUT3D) {
            self.size = lut.size
            self.data = lut.data.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    /// Wrap a baked table in the stock colour-cube filter. The data layout LUT3D
    /// produces (red fastest, then green, then blue; RGBA floats) is exactly what
    /// Core Image wants, so this is a memcpy and a filter, not a conversion.
    ///
    /// This stays the right call for every table the PLAN owns — the finish and
    /// colour-grade tables, the tone gain cube, a mask's local point curve, the fallback
    /// tone cube. Every one of those is keyed to the recipe and is rebuilt the moment a
    /// number moves, so caching one would freeze the photographer's edit on screen,
    /// which is a far worse defect than the copy it would save. Only a table that is
    /// invariant for the life of the process takes the overload below.
    public static func filter(_ lut: LUT3D, image: CIImage) -> CIImage? {
        filter(Baked(lut), image: image)
    }

    /// The same wrap, over bytes that were copied once. Same dimension, same bytes, same
    /// filter, same place in the graph as `filter(_ lut:image:)` — the only difference is
    /// that the table is not re-copied.
    public static func filter(_ cube: Baked, image: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cube.size, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        return filter.outputImage
    }
}

#endif
