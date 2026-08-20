// Kernels.swift
// The complete custom-shader surface of Lumen's render path: fifteen small kernels.
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

        float edge = smoothstep(0.02 + 0.10 * masking,
                                0.10 + 0.25 * masking,
                                gradient.r * range);
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
    static let structureTensorSource = """
    kernel vec4 lumenStructureTensor(__sample gx, __sample gy) {
        float x = gx.r / 8.0;
        float y = gy.r / 8.0;
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
    static let coherenceSource = """
    kernel vec4 lumenCoherence(__sample tensor) {
        float jxx = tensor.r;
        float jyy = tensor.g;
        float jxy = tensor.b;
        float trace = jxx + jyy;
        float d = jxx - jyy;
        float spread = sqrt(d * d + 4.0 * jxy * jxy);
        // A flat region has a trace of essentially zero and no orientation to speak
        // of, so it must read as ISOTROPIC. Dividing by it would say the opposite.
        float c = spread / max(trace, 1e-8);
        c = c * c * step(1e-8, trace);
        return vec4(vec3(clamp(c, 0.0, 1.0)), 1.0);
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

    /// Gradient magnitude by Sobel, in the units of whatever plane it is given.
    ///
    /// The 3x3 Sobel responds with eight times the derivative on a linear ramp, which
    /// is where the /8 comes from — without it the magnitude is eight times too large
    /// and every threshold expressed against it is meaningless.
    static let sobelMagnitudeSource = """
    kernel vec4 lumenSobelMagnitude(__sample gx, __sample gy) {
        float x = gx.r / 8.0;
        float y = gy.r / 8.0;
        return vec4(vec3(sqrt(x * x + y * y)), 1.0);
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
    public static let structureTensor = make(structureTensorSource)
    public static let coherence = make(coherenceSource)
    public static let detailGainGated = make(detailGainGatedSource)
    public static let lumaRatio = make(lumaRatioSource)
    public static let sobelMagnitude = make(sobelMagnitudeSource)
    public static let dehaze = make(dehazeSource)
    public static let addGlow = make(addGlowSource)
    public static let highlightEnergy = make(highlightEnergySource)

    /// Every kernel compiled. False means this macOS build rejected the kernel
    /// language and the renderer must use the CPU reference path.
    public static var isAvailable: Bool { unavailableKernels.isEmpty }

    /// Names of the kernels that failed, for the diagnostic the UI shows rather than
    /// pretending everything is fine.
    public static var unavailableKernels: [String] {
        let all: [(String, CIColorKernel?)] = [
            ("logEncode", logEncode), ("logDecode", logDecode),
            ("multiply", multiply), ("square", square), ("luminance", luminance),
            ("guidedCoefficients", guidedCoefficients),
            ("guidedCrossCoefficients", guidedCrossCoefficients),
            ("guidedApply", guidedApply),
            ("blendMask", blendMask), ("grain", grain), ("vignette", vignette),
            ("detailGain", detailGain), ("dehaze", dehaze), ("addGlow", addGlow),
            ("sharpenDelta", sharpenDelta), ("lumaRatio", lumaRatio),
            ("subtract", subtract), ("structureTensor", structureTensor),
            ("coherence", coherence), ("detailGainGated", detailGainGated),
            ("sobelMagnitude", sobelMagnitude),
            ("highlightEnergy", highlightEnergy),
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

    // MARK: - Convenience application

    public static func apply(_ kernel: CIColorKernel?, extent: CGRect,
                             _ arguments: [Any]) -> CIImage? {
        guard let kernel else { return nil }
        return kernel.apply(extent: extent, arguments: arguments)
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
