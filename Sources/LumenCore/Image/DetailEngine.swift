// DetailEngine.swift
// Presence (S8: Texture / Clarity / Dehaze) and the two sharpening stages that bracket the
// pipeline (S4 capture, S12 manual), plus the S13 vignette — every one of them a
// recombination of ONE cached base–detail decomposition.
//
// The structure is the feature (docs/14 §5.3, docs/06 §10.1). `Decomposition` is a pure
// function of the image, never of a slider: a guided-filter base, an à-trous stack, a
// Gaussian pyramid, a local gradient-structure gate, and a lazily-built dark-channel
// transmission map. Dragging Texture, Clarity, or Dehaze re-weights coefficients that are
// already in memory (≤5 ms), and only an upstream WB/tone change rebuilds the node
// (≤35 ms at 2560-px working resolution). LrC recomputes per drag; that difference is why
// all three sliders can be live at once.
//
// One convention runs through the whole file: presence works on **log2 luminance in EV**
// relative to mid-grey, and every tool's result is expressed as a per-pixel ΔEV plane that
// is applied to RGB as a single multiply `2^Δ`. Chroma is never touched, so no presence
// tool can shift a hue — the "recombination scales RGB by the luma ratio" rule from
// docs/06, implemented once rather than per tool.
//
// Two anti-halo commitments, both structural rather than tuned:
//   · Clarity is a local Laplacian (§ applyClarity) — a per-level remap that cannot
//     reverse a gradient, so there is no overshoot to feather away.
//   · Dehaze never subtracts the airlight's colour and turns each pixel about an
//     edge-following pivot with a bounded exponent (§ applyDehaze), which is what keeps
//     skies their hue and treelines free of bands.

import Foundation

/// The lazily-built halves of a decomposition. A reference box so the value-typed
/// `Decomposition` can be copied around a render without rebuilding a dark channel, and so
/// the airlight is literally the same number on every tile of a tiled export
/// (docs/14 §6.3, the proxy-field rule). Single-threaded by contract: a decomposition
/// belongs to one render pass.
fileprivate final class DehazeCache: @unchecked Sendable {
    var field: DetailEngine.DehazeField?
    var transmission: Plane?
    init() {}
}

public struct DetailEngine: Sendable {

    public init() {}

    // MARK: - Tuning constants

    /// Number of à-trous scales. Level `i` carries ~`2^(i+1)` px of structure, so five
    /// levels span 2–64 px — the whole range Texture and manual sharpening address.
    public static let waveletLevels: Int = 5
    /// Gaussian-pyramid depth for the local Laplacian. Deeper buys nothing for Clarity,
    /// whose remap is midtone-weighted and dies out at the coarse end anyway.
    /// Pyramid depth at the reference resolution. See `pyramidLevels(longEdge:)`.
    public static let basePyramidLevels: Int = 5

    /// The resolution `basePyramidLevels` is calibrated at, shared with the Texture
    /// band's own centre so the two presence stages track the frame the same way.
    public static let pyramidReferenceLongEdge: Double = 2560

    /// Pyramid depth for Clarity, tracked to the FRAME rather than fixed.
    ///
    /// It was a constant 5, so the local Laplacian reached 16 px whatever the picture
    /// was — 5% of a 300 px preview and 1.3% of a 1200 px render. Clarity therefore
    /// acted on a different fraction of the PICTURE at every resolution, which is
    /// exactly the promise a fit preview makes and cannot keep: measured, a 4x scale
    /// change moved the render by 7.4 code values, where every per-pixel stage moves by
    /// 0.5 and Texture — which tracks the long edge on purpose — moves by 2.8.
    ///
    /// One level per doubling, because a Gaussian pyramid's reach doubles per level.
    /// That is the same relationship `bandCenter` uses for Texture, written the same way
    /// so the two cannot drift apart in intent.
    public static func pyramidLevels(longEdge: Int) -> Int {
        let steps = log2(Double(Swift.max(longEdge, 1)) / pyramidReferenceLongEdge)
        guard steps.isFinite else { return basePyramidLevels }
        return Int(Num.clamp((Double(basePyramidLevels) + steps.rounded()), 2, 9))
    }
    /// Guided-filter regularization for the base, in EV². √0.01 = 0.1 EV: anything flatter
    /// than a tenth of a stop across the window is one surface.
    public static let baseEpsilon: Double = 0.01
    /// Clarity's detail/edge threshold in EV. Excursions below this are "texture" and get
    /// remapped; anything above is an edge and passes through untouched.
    public static let clarityDetailEV: Double = 0.7
    /// Width in EV of the midtone weight on Clarity's remap, so Clarity expands local
    /// contrast without reaching the white and black points docs/04 owns.
    public static let clarityMidtoneEV: Double = 3.0
    /// Where positive Texture's edge gate starts and finishes closing, on the
    /// structure tensor's coherence.
    ///
    /// Positive Texture is a gain on a band that still contains hard edges, so an
    /// ungated gain rims them — measured on a clean 3 EV step, 0.43 EV of trench at
    /// +25 and 1.39 EV at +100, against the 0.30 EV bar the presence golden holds
    /// Clarity to. The negative side was gated by `1 − coherence` from the start and
    /// the positive side was not, which is the whole defect.
    ///
    /// The gate cannot simply mirror the negative one: `1 − coherence` at full depth
    /// would also flatten hair, fabric weave and foliage, which are the subjects
    /// positive Texture exists for. Measured coherence separates them cleanly — fine
    /// parallel lines sit at 0.19, a smooth ramp at 0.00, and a hard step at 1.00 —
    /// so a gate that only starts closing at 0.35 leaves the first two at full
    /// authority and shuts on the third.
    public static let texturePositiveGateLo: Double = 0.35
    public static let texturePositiveGateHi: Double = 0.85
    /// He et al.'s haze-retention constant: keep 5% of the haze so distance still reads.
    public static let dehazeOmega: Double = 0.95
    /// docs/06's Distance disclosure default (0–100). Caps the transmission floor.
    public static let dehazeDistance: Double = 20

    // MARK: - Decomposition

    /// The one base–detail node, computed per render at working resolution.
    ///
    /// Everything here is a function of the image alone. Nothing in this type knows what
    /// Texture, Clarity, or Dehaze are set to, which is exactly what makes a slider drag a
    /// recombination — the API cannot express "rebuild on drag" because the sliders are not
    /// inputs to the constructor.
    public struct Decomposition: Sendable {

        public let width: Int
        public let height: Int
        public let space: RGBColorSpace
        /// Guided-filter radius in pixels at this working resolution.
        public let workingRadius: Int

        /// log2(luminance / 0.18), in EV — the same zonal coordinate S7 uses, so the tone
        /// and presence stages address one axis.
        public let logLuminance: Plane
        /// Edge-aware base: the guided filter's piecewise-smooth surface.
        public let base: Plane
        /// À-trous detail bands of `logLuminance`, finest first. Texture's band.
        public let details: [Plane]
        /// What the à-trous stack could not explain — the coarse residual.
        public let residual: Plane
        /// Gaussian pyramid of `logLuminance`, finest first. Feeds the local Laplacian.
        public let pyramid: [Plane]
        /// Structure-tensor gradient magnitude in EV/px. Drives sharpening's edge mask and
        /// dehaze's sky floor.
        public let gradient: Plane
        /// 0 = isotropic mid-frequency texture (pores, noise-adjacent detail);
        /// 1 = a coherent high-contrast edge (eyelashes, jawline, horizon).
        /// Negative Texture attenuates through `1 − coherence`, which is what makes it a
        /// skin smoother instead of a negative-Clarity glow.
        public let coherence: Plane

        /// The stage input, kept for the lazily-built dehaze primitives.
        public let source: ImageBuffer

        fileprivate let cache: DehazeCache

        /// Build the node. This is the ≤35 ms half of the budget; everything downstream is
        /// the ≤5 ms half.
        public init(image: ImageBuffer, workingRadius: Int, space: RGBColorSpace = .rec2020) {
            let w = image.width
            let h = image.height
            let radius = Swift.min(Swift.max(workingRadius, 1), Swift.max(w, h))

            self.width = w
            self.height = h
            self.space = space
            self.workingRadius = radius
            self.source = image
            self.cache = DehazeCache()

            let lum = image.luminancePlane(space: space)
            // safeLog2 floors at −20 EV, so a zero or negative luminance (legal in
            // scene-referred data) lands on the bottom of the axis instead of at −∞.
            let logLum = lum.map { Num.safeLog2($0 / 0.18) }
            self.logLuminance = logLum

            self.base = SpatialOps.guidedFilter(input: logLum, guide: logLum,
                                                radius: radius,
                                                epsilon: DetailEngine.baseEpsilon)

            let stack = SpatialOps.atrousWavelet(logLum, levels: DetailEngine.waveletLevels)
            self.details = stack.details
            self.residual = stack.residual

            self.pyramid = DetailEngine.gaussianPyramid(
                logLum, levels: DetailEngine.pyramidLevels(longEdge: Swift.max(w, h)))

            let structure = DetailEngine.structureTensor(logLum, radius: Swift.max(radius / 4, 1))
            self.gradient = structure.magnitude
            self.coherence = structure.coherence
        }

        /// Atmospheric light, estimated once on the fixed-size dehaze proxy and frozen.
        ///
        /// It used to be the mean colour of the top 0.1 % of a full-resolution dark
        /// channel. That rule picks whatever is brightest-and-greyest, which on real
        /// frames was a ColorChecker's white patches, the pink lid of a tank and a white
        /// house wall — and which one won depended on the render size (WS-15 AUDIT §8,
        /// §12). The estimate now lives in `DetailEngine.dehazeAirlightEstimate`, shared
        /// with the GPU, on a proxy whose size does not depend on the render's.
        public func airlight() -> RGB { dehazeField().airlight }

        /// The transmission `t = 1 − V/P` (veil over local white) at this decomposition's
        /// resolution: the proxy fields, upsampled edge-aware against this image's own
        /// log luminance. Kept for callers that want the map itself;
        /// `applyDehaze` reads the same field through the same upsampling.
        public func transmission() -> Plane {
            if let t = cache.transmission { return t }
            let field = dehazeField()
            let guide = DetailEngine.dehazeGuidePlane(source, space: space)
            var t = Plane(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width {
                    let f = DetailEngine.dehazeUpsample(field, x: x, y: y, width: width,
                                                        height: height, guide: guide[x, y])
                    t[x, y] = Num.clamp(1 - DetailEngine.dehazeVeilFraction(veil: f.veil,
                                                                             white: f.white),
                                        0.02, 1)
                }
            }
            cache.transmission = t
            return t
        }

        /// Every slider-independent dehaze field, built once per decomposition on the
        /// proxy and cached. See `DetailEngine.DehazeField`.
        public func dehazeField() -> DehazeField {
            if let f = cache.field { return f }
            let guide = DetailEngine.dehazeGuidePlane(source, space: space)
            let size = DetailEngine.dehazeProxySize(width: width, height: height)
            let proxy = DetailEngine.dehazeAreaDownsample(source, width: size.width,
                                                          height: size.height)
            let proxyGuide = DetailEngine.dehazeAreaDownsample(guide, width: size.width,
                                                               height: size.height)
            let proxySquare = DetailEngine.dehazeAreaDownsample(guide.zip(guide) { $0 * $1 },
                                                                width: size.width,
                                                                height: size.height)
            let air = DetailEngine.dehazeAirlightEstimate(proxy, space: space)
            let f = DetailEngine.dehazeField(proxy: proxy, guide: proxyGuide,
                                             guideSquare: proxySquare, airlight: air,
                                             space: space)
            cache.field = f
            return f
        }
    }

    // MARK: - Apply

    /// Run the recipe's whole Detail subtree in pipeline order.
    ///
    /// Stage honesty: capture sharpening is S4 and manual sharpening is S12 — they bracket
    /// the presence stage rather than living inside it, and in the real graph capture
    /// sharpening is cached with the decode so toggling it is a cache splice. Applying them
    /// here in one call is the reference path's convenience; when a caller wants the exact
    /// graph, it should build the `Decomposition` from `captureSharpen(...)`'s output and
    /// call the per-tool entries below.
    ///
    /// None of these rebuild the decomposition. A slider drag is one pass of coefficient
    /// re-weighting over planes that are already resident.
    /// Stage S8 — presence, and ONLY presence.
    ///
    /// Capture sharpening is S4 (it runs on the cleanest estimate of the optical
    /// image, immediately after denoise) and creative sharpening is S12 (after local
    /// adjustments, so masked clarity is never double-sharpened). Folding either into
    /// this call would put it after tone, which is the wrong place for both. Callers
    /// invoke `captureSharpen` and `applySharpen` at their own stages; on the Apple
    /// RAW path S4 is Apple's at-demosaic sharpener.
    public static func apply(_ image: ImageBuffer, detail: Detail,
                             decomposition: Decomposition) -> ImageBuffer {
        var out = applyTexture(image, amount: detail.texture, decomposition: decomposition)
        out = applyClarity(out, amount: detail.clarity, decomposition: decomposition)
        out = applyDehaze(out, amount: detail.dehaze, decomposition: decomposition)
        return out
    }

    // MARK: - Texture

    /// Texture: a gain on the mid scales of the à-trous stack (docs/06 §10.2).
    ///
    /// The band is a raised-cosine window over scale index, centered where ~2–8 px of
    /// structure lives, with smooth edges so adjacent scales blend rather than seam. The
    /// centre shifts with resolution so the band means the same physical detail size on a
    /// 61 MP file as on a 24 MP one.
    ///
    /// Positive values multiply band coefficients. Negative values attenuate them through
    /// `1 − coherence`, so coherent high-contrast edges keep their energy while isotropic
    /// mid-frequency texture loses it: −Texture smooths skin without dissolving eyelashes,
    /// and without negative Clarity's glow.
    /// Texture/Clarity controls retain their ±100 domain; a local mask can scale
    /// that resolved control up to 200%. Do not clamp again after multiplication.
    public static func scaledPresenceAmount(_ amount: Double, strength: Double = 1) -> Double {
        Num.clamp(amount, -100, 100) * Num.clamp(strength, 0, 2)
    }

    public static func applyTexture(_ image: ImageBuffer, amount: Double,
                                    strength: Double = 1,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = scaledPresenceAmount(amount, strength: strength) / 100
        guard a != 0, !d.details.isEmpty else { return image }

        let w = image.width
        let h = image.height
        let coherence = fit(d.coherence, width: w, height: h)
        let center = bandCenter(width: w, height: h)
        let halfWidth = 1.6

        // Normalize by the weight the window ACTUALLY realizes. The band centre
        // tracks resolution correctly, but the window is truncated at level 0, so a
        // preview whose centre sits at level 0 keeps only the levels above it. The
        // weights summed to 1.617 at 2560 px and 1.309 at 1280 px, which made the same
        // Texture setting 19 % weaker in a fit view than in the export — a scale
        // honesty failure, and this stage's whole claim is scale honesty.
        var realized = 0.0
        for i in 0..<d.details.count {
            realized += bandWeight(level: i, center: center, halfWidth: halfWidth)
        }
        guard realized > 1e-9 else { return image }
        let normalization = referenceBandWeight(halfWidth: halfWidth) / realized

        var delta = Plane(width: w, height: h)
        for i in 0..<d.details.count {
            let weight = bandWeight(level: i, center: center, halfWidth: halfWidth)
                * normalization
            if weight <= 0 { continue }
            let band = fit(d.details[i], width: w, height: h)
            for y in 0..<h {
                for x in 0..<w {
                    // Both signs are gated by local structure, for opposite reasons:
                    // negative Texture must not dissolve an edge, positive Texture must
                    // not rim one. Negative closes fully because smoothing an edge is
                    // never wanted; positive closes only on genuine coherent edges, so
                    // hair and weave keep the whole slider (see the gate constants).
                    let c = Num.saturate(coherence[x, y])
                    let gate = a >= 0
                        ? 1.0 - Num.smoothstep(Self.texturePositiveGateLo,
                                               Self.texturePositiveGateHi, c)
                        : 1.0 - c
                    delta[x, y] = delta[x, y] + a * weight * gate * band[x, y]
                }
            }
        }
        return applyLumaRatio(image, deltaEV: delta, limit: 4)
    }

    // MARK: - Clarity

    /// Clarity: fast local Laplacian filtering (Paris/Hasinoff 2011, Aubry variant) on
    /// log2 luminance — darktable's `locallaplacian.c` parameterization.
    ///
    /// **Why this construction is halo-free, and what "halo-free" means here.** USM and
    /// bilateral clarity both build a single blurred reference and add back the difference;
    /// near a strong edge the reference is wrong on both sides, so the difference reverses
    /// the gradient and you get a bright rim on the dark side and vice versa. The local
    /// Laplacian never forms a global reference. For each of six sampled reference levels
    /// γ it remaps the *whole* image through a monotone point function anchored at γ, builds
    /// that image's Laplacian pyramid, and then reads each output coefficient from the
    /// remapped pyramid whose γ matches the pixel's own local average. Because every remap
    /// is monotone in the input, no coefficient can change sign relative to its neighbours:
    /// gradient reversal — the thing a halo *is* — is unrepresentable.
    ///
    /// The remap is `r(x) = γ + sign(d)·σ·(|d|/σ)^α` for `|d| ≤ σ` and the identity beyond,
    /// where `d = x − γ`. `α < 1` expands sub-σ detail (positive Clarity), `α > 1`
    /// compresses it (negative Clarity, clean soft-focus with no bloom leak). The identity
    /// branch is why edges above σ pass through at unit slope, and the coarsest pyramid
    /// level is copied from the input untouched — together those two facts are what keep
    /// Clarity off the white and black points.
    ///
    /// α is weighted by a Gaussian on γ centred at mid-grey (`clarityMidtoneEV`), so the
    /// effect concentrates where the eye reads local contrast and fades toward the endpoints.
    ///
    /// Recombination is by RGB ratio: zero saturation change — docs/06's **Natural** mode.
    /// **Punch** (chroma gain at ~35% of the amount, in OKLCh with skin protection) is not
    /// implemented here because the recipe's `Detail` has no mode field yet; adding it is a
    /// wire-format change (D52).
    public static func applyClarity(_ image: ImageBuffer, amount: Double,
                                    strength: Double = 1,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = scaledPresenceAmount(amount, strength: strength) / 100
        guard a != 0 else { return image }
        let w = image.width
        let h = image.height

        let input = fit(d.logLuminance, width: w, height: h)
        // The cached pyramid is reused whenever the decomposition and the render target
        // agree on extent; a fit-view/full-res mismatch rebuilds it at the target size.
        let pyramid: [Plane]
        if d.pyramid.count >= 2 && d.pyramid[0].width == w && d.pyramid[0].height == h {
            pyramid = d.pyramid
        } else {
            pyramid = gaussianPyramid(input,
                                      levels: pyramidLevels(longEdge: Swift.max(w, h)))
        }
        guard pyramid.count >= 2 else { return image }

        let remapped = localLaplacian(input, pyramid: pyramid, amount: a,
                                      sigma: clarityDetailEV, midtoneEV: clarityMidtoneEV)
        let delta = remapped.zip(input) { $0 - $1 }
        return applyLumaRatio(image, deltaEV: delta, limit: 4)
    }

    // MARK: - Dehaze

    /// Dehaze: the haze model `I = J·t + A·(1−t)` on **scene-linear** data (docs/06
    /// §10.4), with every slider-independent field measured once on a fixed-size proxy
    /// by a function the GPU twin calls too.
    ///
    /// WS-15 rewrote this stage against a measured spec (docs/quality/lanes/WS-15/SPEC.md).
    /// What the old single-luminance-ratio form did on real frames, and what replaced it:
    ///
    /// · **Airlight.** The brightest 0.1 % of a full-resolution dark channel picked a
    ///   ColorChecker's white patches, a pink tank lid and a white wall, and flipped
    ///   between wall and sky with the render size. It is now the brightest LARGE region
    ///   of the upper frame on the proxy (`dehazeAirlightEstimate`).
    ///
    /// · **Recovery, about each surface's own level.** He's inversion
    ///   `J = (I − A·(1−t))/t` holds the AIRLIGHT fixed and pulls everything darker than
    ///   it down by the veil, so a frame whose sky is the airlight lost 1.5 EV at +100 and
    ///   every grey card, snow field or overcast cloud darker than the airlight was read
    ///   as veil and crushed. Here the model sets an exponent instead: removing the veil
    ///   `V` (ω × the dark channel) from a surface at level `P` has log-slope `P/(P − V)`,
    ///   and that slope, capped, is applied as a power law about `P` (see
    ///   `dehazePositivePixel` for why this shape and not the subtraction itself). The
    ///   relative contrast of every detail rises — the detail a veil hides — while each
    ///   surface keeps its exposure. A sky guard eases the exponent on bright flat
    ///   regions, where the dark channel reads full veil and full expansion made storm
    ///   skies.
    ///
    /// · **Fields are region-faithful.** `V` and `P` are a range-restricted minimum and
    ///   maximum: only samples within `dehazeRegionEV` of the pixel's own level count, so
    ///   each surface keeps its own black and white right up to its edge, and the trees
    ///   next to a sky do not inherit the sky's numbers or vice versa (the patch-wide halo
    ///   of the old min filter). They are
    ///   carried to full resolution by joint-bilateral upsampling against the
    ///   full-resolution log luminance, which is what lets a 256 px field follow a
    ///   6000 px treeline.
    ///
    /// · **Colour.** Luminance is a ratio multiply (no hue change); chroma is then
    ///   restored in OKLab at FIXED hue, by the stretch — the model's `(I − Y)/t` that the
    ///   ratio form could not do, which is why +Dehaze used to DESATURATE. The airlight's
    ///   colour is never subtracted, so neutrals stay neutral and no sky turns magenta.
    ///
    /// Negative Dehaze runs the model forwards toward a near-neutral veil at the
    /// airlight's level, weighted by distance: the larger of the local veil fraction
    /// `V/P` (low local contrast reads far) and the sky signal (bright and flat), times
    /// the ground-plane cue that the lower frame is nearer.

    /// Long edge of the proxy every dehaze field is measured on. Fixed, so a 512 px
    /// preview and a 6000 px export measure the same picture.
    public static let dehazeProxyLongEdge: Int = 256
    /// Airlight search window (an erosion of luminance), as fractions of the proxy's long
    /// edge. Wide and short, because haze and sky are wide bands while the white objects
    /// that used to win (chart patches, lamp glass, a lid) are compact.
    public static let dehazeAirlightReachX: Double = 0.05
    public static let dehazeAirlightReachY: Double = 0.02
    /// Upper-frame preference: a gentle tilt, then a strong cut over the lower frame.
    public static let dehazeAirlightTilt: Double = 0.3
    public static let dehazeAirlightLowerStart: Double = 0.5
    public static let dehazeAirlightLowerEnd: Double = 0.65
    public static let dehazeAirlightLowerWeight: Double = 0.1
    /// Pixels scoring within this fraction of the best score form the selection.
    public static let dehazeAirlightSelect: Double = 0.95
    /// Most saturation (`(max − min)/max`) the airlight may carry. Scattered light is the
    /// illuminant's colour plus a little blue; a strongly coloured estimate means the
    /// selection sits on a coloured sky or object, and its colour is pulled toward its
    /// own luminance until it is this saturated.
    public static let dehazeAirlightMaxSaturation: Double = 0.3
    /// Window of the veil and local-white fields, fraction of the proxy's long edge,
    /// and their range limit: only window samples within this many EV of the centre's
    /// guide count, so each surface keeps its OWN black and white. A plain closing
    /// filled the dark tree tops between sky gaps with sky and pinned the fringe of a
    /// forest to the sky's white (−1 EV along every canopy, WS-15 build notes r5).
    public static let dehazeDarkReach: Double = 0.03
    public static let dehazeRegionEV: Double = 1.5
    /// Flatness (for the negative branch's sky term): quadrant-std window and EV band.
    public static let dehazeFlatReach: Double = 0.008
    public static let dehazeFlatLoEV: Double = 0.05
    public static let dehazeFlatHiEV: Double = 0.25
    /// The pivot's guided filter: window as a fraction of the long edge, and ε in EV².
    public static let dehazePivotReach: Double = 0.01
    public static let dehazePivotEpsilonEV: Double = 0.25
    /// Joint-bilateral upsampling: the guide distance, in EV, at which a proxy sample's
    /// weight has fallen to e^−½. Texture inside one surface spans about ±1 EV; the
    /// edges that must not be crossed (sky/treeline, wall/shadow) span three or more.
    public static let dehazeUpsampleSigmaEV: Double = 0.75
    /// Purity of a proxy sample: the spread (EV) of the full-resolution guide inside its
    /// block at which its weight has fallen to e^−½. A block that straddles an edge
    /// carries a blend of two surfaces' fields that belongs to neither, so it gives way
    /// to its pure neighbours.
    public static let dehazePuritySigmaEV: Double = 0.5
    /// Sky terms. "Bright" is luminance relative to the airlight's, per pixel.
    public static let dehazeSkyBrightLo: Double = 0.35
    public static let dehazeSkyBrightHi: Double = 0.8
    /// The sky guard: the share of the exponent a bright, flat region (sky, snow, a
    /// white wall) gives up. Flat bright regions read as heavily veiled to the dark
    /// channel, and full contrast expansion there is what made storm skies.
    public static let dehazeSkyGuard: Double = 0.7
    /// The largest exponent positive Dehaze applies at +100, and the black reference:
    /// the floor protects pixels below `dehazeToeReach ×` the frame's 1st-percentile
    /// proxy luminance.
    public static let dehazeMaxGamma: Double = 2.25
    public static let dehazeToeReach: Double = 1.5
    /// Share of the exponent applied below and above the pivot, and the most any pixel
    /// is brightened (`J ≤ dehazeMaxBrighten × Y`, a min of two rising curves, so the
    /// tone curve stays monotone). The darkest tail of a texture takes the smaller
    /// share: a log-ratio there is the largest change in the picture and the first thing
    /// to read as a dark band along an edge, while the visible detail (measured as
    /// encoded contrast) lives mostly in the brighter half.
    public static let dehazeShadowShare: Double = 0.5
    /// The shape of the expansion: a deviation `x = ln(Y/P)` from the pivot gains
    /// `(γ − 1)·x·(1 − e^(−(x/x1)²))/(1 + |x|/x2)` (`dehazeDetailCurve`). The structure
    /// a veil flattens — paths, hedges, roof lines, a trunk against a meadow — sits
    /// several tenths of a stop from its pivot and gets close to the full slope; the
    /// fine low-amplitude texture of a dark canopy (and the noise in it) sits within
    /// `x1` and is spared, because amplifying it is what drew bands along every
    /// treeline once the display transform's shadow contrast was applied on top
    /// (measured 1.8× on 4213's forest). `x2` bounds the largest move.
    public static let dehazeDetailFloor: Double = 0.05
    public static let dehazeDetailSoftness: Double = 2.0
    public static let dehazeDetailRelease: Double = 1.0
    public static let dehazeHighlightShare: Double = 1.0
    public static let dehazeMaxBrighten: Double = 1.25
    /// Scale on the dark channel's veil at +100.
    public static let dehazeStrength: Double = 1.25
    /// The black floor: at +100 a pixel near the frame's black keeps at least this
    /// fraction of itself; it scales with the amount (`1 − a·(1 − floor)`), so a small
    /// amount cannot snap the deepest shadows to the floor.
    public static let dehazeToeFloor: Double = 0.65
    /// OKLab chroma restoration `1 + gain·(γ − 1)`, capped, and gated off below a
    /// small fraction of the airlight's luminance, where the "colour" is noise and a
    /// boost only pushes a channel into the black clip.
    public static let dehazeChromaGain: Double = 0.5
    public static let dehazeChromaMax: Double = 1.25
    public static let dehazeChromaGateLo: Double = 0.01
    public static let dehazeChromaGateHi: Double = 0.05
    /// The boost also eases off for colours already near full saturation: they sit at
    /// the display gamut's edge, where more chroma is clipped and the clip turns hue
    /// (ColorChecker cyan by 5° in the first build).
    public static let dehazeChromaSatLo: Double = 0.5
    public static let dehazeChromaSatHi: Double = 0.9
    /// Negative branch: the share of the airlight's chroma in the veil's tint; how far
    /// chroma moves toward that tint per unit of compression; the most log-contrast
    /// compression at −100; the quantile of `V/P` that reads fully distant; the
    /// near-ground weight.
    public static let dehazeVeilChroma: Double = 0.3
    public static let dehazeVeilChromaBlend: Double = 0.4
    public static let dehazeVeilMax: Double = 0.6
    /// Share of the compression that also lifts each surface toward the airlight's
    /// level as a whole (the rest is contrast lost about the surface's own level).
    public static let dehazeVeilLift: Double = 0.12
    /// The veil's level relative to the airlight: a little above it, so a bright
    /// distant surface (a snow field, a pale sky) goes milky too rather than being the
    /// one thing the veil cannot lift.
    public static let dehazeVeilLevel: Double = 1.5
    public static let dehazeVeilReferenceQuantile: Double = 0.9
    public static let dehazeVeilNearStart: Double = 0.35
    public static let dehazeVeilNearEnd: Double = 0.95
    public static let dehazeVeilNearWeight: Double = 0.3

    /// The airlight and the proxy pixels it was read from.
    public struct DehazeAirlight: Sendable {
        public let rgb: RGB
        /// Proxy-resolution selection mask, 1 where the pixel took part.
        public let selection: Plane
    }

    /// Everything the dehaze stage measures from the image, at proxy resolution.
    ///
    /// The three fields reach full resolution by joint-bilateral upsampling
    /// (`dehazeUpsample`): each pixel takes its four nearest proxy samples, weighted
    /// bilinearly AND by how close each sample's guide value is to the pixel's own. A
    /// guided-filter (linear-model) upsampling was tried first and drew the halos it
    /// exists to prevent: across a sky/forest edge its fit `a·guide + b` has a steep
    /// slope, so the bright texture INSIDE the forest next to the sky read as sky-level
    /// veil and was crushed (WS-15 build notes, r3).
    public struct DehazeField: Sendable {
        public let airlight: RGB
        public let airLuma: Double
        public let selection: Plane
        public let proxy: ImageBuffer
        public let proxyGuide: Plane
        /// Raw proxy fields: veil `V` (absolute), the surface's level `P` (absolute; the
        /// pivot positive Dehaze turns about), flatness.
        public let veil: Plane
        public let white: Plane
        public let flat: Plane
        /// Per-sample purity weight, `exp(−var/(2σ²))` of the full-resolution guide
        /// inside the block (1 when the proxy is the image itself).
        public let purity: Plane
        /// The `V/P` that reads fully distant for negative Dehaze.
        public let veilReference: Double
        /// The frame's black reference: the 1st percentile of proxy luminance.
        public let blackReference: Double
    }

    /// The range weight's exponent scale for guide values in LumenLog-encoded units.
    public static var dehazeUpsampleRangeScale: Double {
        let sigma = dehazeUpsampleSigmaEV / LumenLog.range
        return 1 / (2 * sigma * sigma)
    }

    /// Joint-bilateral upsampling of the three proxy fields to a `width`×`height` frame,
    /// at the pixel whose own guide value is `g`. The four proxy samples around the
    /// pixel's centre (border repeated) are weighted bilinearly times
    /// `exp(−(g − gᵢ)²·scale)·purityᵢ + 1e-6`; the small floor keeps the bilinear answer
    /// where no neighbour resembles the pixel. `V` and `P` blend in LOG space: they are
    /// luminances, and a dark surface's veil must not be lifted by a bright neighbour's
    /// in proportion to the neighbour's level.
    @inline(__always)
    static func dehazeUpsample(_ f: DehazeField, x: Int, y: Int, width: Int, height: Int,
                               guide g: Double) -> (veil: Double, white: Double, flat: Double) {
        let pw = f.veil.width, ph = f.veil.height
        let qx = (Double(x) + 0.5) * Double(pw) / Double(width) - 0.5
        let qy = (Double(y) + 0.5) * Double(ph) / Double(height) - 0.5
        let bx = Int(qx.rounded(.down)), by = Int(qy.rounded(.down))
        let fx = qx - Double(bx), fy = qy - Double(by)
        let scale = dehazeUpsampleRangeScale
        var sv = 0.0, sp = 0.0, sf = 0.0, sw = 0.0
        for (j, wy) in [(0, 1 - fy), (1, fy)] {
            let yy = Swift.min(Swift.max(by + j, 0), ph - 1)
            for (i, wx) in [(0, 1 - fx), (1, fx)] {
                let xx = Swift.min(Swift.max(bx + i, 0), pw - 1)
                let d = g - f.proxyGuide[xx, yy]
                let w = wx * wy * (exp(-d * d * scale) * f.purity[xx, yy] + 1e-6)
                sv += w * log(Swift.max(f.veil[xx, yy], 1e-6))
                sp += w * log(Swift.max(f.white[xx, yy], 1e-6))
                sf += w * f.flat[xx, yy]
                sw += w
            }
        }
        return (exp(sv / sw), exp(sp / sw), sf / sw)
    }

    /// Proxy size for a frame: `dehazeProxyLongEdge` on the long edge, rounded the way
    /// `lumen-render` rounds its own downsample; frames already smaller are used as-is.
    public static func dehazeProxySize(width: Int, height: Int) -> (width: Int, height: Int) {
        let long = Swift.max(width, height)
        guard long > dehazeProxyLongEdge else { return (Swift.max(width, 1), Swift.max(height, 1)) }
        let s = Double(dehazeProxyLongEdge) / Double(long)
        return (Swift.max(1, Int((Double(width) * s).rounded())),
                Swift.max(1, Int((Double(height) * s).rounded())))
    }

    /// The guide every dehaze field is upsampled against: LumenLog-encoded luminance,
    /// floored at zero — exactly `RenderGraph.logLuminance` on the GPU.
    public static func dehazeGuidePlane(_ image: ImageBuffer,
                                        space: RGBColorSpace = .rec2020) -> Plane {
        var p = Plane(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                p[x, y] = LumenLog.encode(Swift.max(space.luminance(image[x, y]), 0))
            }
        }
        return p
    }

    /// Coverage weights of an exact area-average resample from `n` to `m` samples.
    private static func dehazeAreaTaps(from n: Int, to m: Int) -> [[(Int, Double)]] {
        let ratio = Double(n) / Double(m)
        return (0..<m).map { i in
            let a = Double(i) * ratio, b = Double(i + 1) * ratio
            var taps: [(Int, Double)] = []
            var j = Int(a.rounded(.down))
            while Double(j) < b && j < n {
                let lo = Swift.max(a, Double(j)), hi = Swift.min(b, Double(j + 1))
                if hi > lo { taps.append((j, (hi - lo) / ratio)) }
                j += 1
            }
            return taps
        }
    }

    /// Exact area-average downsample (the `lumen-render` resampler) to a given size.
    public static func dehazeAreaDownsample(_ image: ImageBuffer, width: Int,
                                            height: Int) -> ImageBuffer {
        guard width != image.width || height != image.height else { return image }
        let tx = dehazeAreaTaps(from: image.width, to: width)
        let ty = dehazeAreaTaps(from: image.height, to: height)
        var rows = [RGB](repeating: .zero, count: width * image.height)
        for y in 0..<image.height {
            for x in 0..<width {
                var acc = RGB.zero
                for (j, wgt) in tx[x] { acc = acc + image[j, y] * wgt }
                rows[y * width + x] = acc
            }
        }
        var out = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var acc = RGB.zero
                for (j, wgt) in ty[y] { acc = acc + rows[j * width + x] * wgt }
                out[x, y] = acc
            }
        }
        return out
    }

    public static func dehazeAreaDownsample(_ plane: Plane, width: Int, height: Int) -> Plane {
        guard width != plane.width || height != plane.height else { return plane }
        let tx = dehazeAreaTaps(from: plane.width, to: width)
        let ty = dehazeAreaTaps(from: plane.height, to: height)
        var rows = [Double](repeating: 0, count: width * plane.height)
        for y in 0..<plane.height {
            for x in 0..<width {
                var acc = 0.0
                for (j, wgt) in tx[x] { acc += plane[j, y] * wgt }
                rows[y * width + x] = acc
            }
        }
        var out = Plane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for (j, wgt) in ty[y] { acc += rows[j * width + x] * wgt }
                out[x, y] = acc
            }
        }
        return out
    }

    /// Rectangular dilation (windowed maximum), border pixels repeated.
    static func dehazeDilate(_ p: Plane, rx: Int, ry: Int) -> Plane {
        dehazeErode(p.map { -$0 }, rx: rx, ry: ry).map { -$0 }
    }

    /// The pivot plane: a self-guided filter of the LumenLog guide (window
    /// `dehazePivotReach` of the long edge, ε `dehazePivotEpsilonEV` EV²), decoded to
    /// linear. It follows any edge stronger than about √ε, so a blurred transition is
    /// its own pivot and is not overshot, and smooths texture below that, which is the
    /// detail the exponent expands. The decomposition's own base (ε 0.01 EV²) follows a
    /// hazy forest's texture too closely to leave any detail to expand.
    public static func dehazePivotPlane(_ image: ImageBuffer,
                                        space: RGBColorSpace = .rec2020) -> Plane {
        let guide = dehazeGuidePlane(image, space: space)
        let long = Double(Swift.max(image.width, image.height))
        let r = Swift.max(1, Int((dehazePivotReach * long).rounded()))
        let eps = dehazePivotEpsilonEV / (LumenLog.range * LumenLog.range)
        return SpatialOps.guidedFilter(input: guide, guide: guide, radius: r, epsilon: eps)
            .map { LumenLog.decode($0) }
    }

    /// Rectangular erosion (windowed minimum), border pixels repeated.
    static func dehazeErode(_ p: Plane, rx: Int, ry: Int) -> Plane {
        let w = p.width, h = p.height
        var tmp = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var m = Double.infinity
                for dx in -rx...rx { m = Swift.min(m, p.clampedSample(x + dx, y)) }
                tmp[x, y] = m
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var m = Double.infinity
                for dy in -ry...ry { m = Swift.min(m, tmp.clampedSample(x, y + dy)) }
                out[x, y] = m
            }
        }
        return out
    }

    /// Local standard deviation, taken as the SMALLEST of the four quadrant windows that
    /// have the pixel as a corner (Kuwahara's trick). A pixel on the boundary between two
    /// flat regions has at least one quadrant entirely inside one of them, so an edge
    /// between flat surfaces reads flat and only real texture reads textured.
    static func dehazeQuadrantStd(_ p: Plane, radius r: Int) -> Plane {
        let w = p.width, h = p.height
        var s1 = [Double](repeating: 0, count: (w + 1) * (h + 1))
        var s2 = s1
        for y in 0..<h {
            var row1 = 0.0, row2 = 0.0
            for x in 0..<w {
                let v = p[x, y]
                row1 += v; row2 += v * v
                s1[(y + 1) * (w + 1) + x + 1] = s1[y * (w + 1) + x + 1] + row1
                s2[(y + 1) * (w + 1) + x + 1] = s2[y * (w + 1) + x + 1] + row2
            }
        }
        func rect(_ s: [Double], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            s[(y1 + 1) * (w + 1) + x1 + 1] - s[y0 * (w + 1) + x1 + 1]
                - s[(y1 + 1) * (w + 1) + x0] + s[y0 * (w + 1) + x0]
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var best = Double.infinity
                for (ox, oy) in [(-r, -r), (0, -r), (-r, 0), (0, 0)] {
                    let x0 = Swift.max(x + ox, 0), x1 = Swift.min(x + ox + r, w - 1)
                    let y0 = Swift.max(y + oy, 0), y1 = Swift.min(y + oy + r, h - 1)
                    let n = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                    let m = rect(s1, x0, y0, x1, y1) / n
                    let v = Swift.max(rect(s2, x0, y0, x1, y1) / n - m * m, 0)
                    best = Swift.min(best, v.squareRoot())
                }
                out[x, y] = best
            }
        }
        return out
    }

    /// Upper-frame weight of the airlight search at vertical position `v` (0 = top).
    static func dehazeAirlightWeight(_ v: Double) -> Double {
        (1 - dehazeAirlightTilt * v)
            * (1 - (1 - dehazeAirlightLowerWeight)
                * Num.smoothstep(dehazeAirlightLowerStart, dehazeAirlightLowerEnd, v))
    }

    /// The airlight: the brightest LARGE region of the upper frame, on the proxy.
    ///
    /// Score = luminance eroded over a wide, short window × an upper-frame weight; the
    /// pixels within `dehazeAirlightSelect` of the best score are the selection, and the
    /// airlight is their window-averaged colour, saturation-capped. The erosion is what
    /// rejects white and specular objects — a chart patch, lamp glass or a lid is
    /// narrower than the window and erodes to its darker surroundings — and the weight is
    /// what keeps a bright foreground wall or card from beating the sky above it.
    public static func dehazeAirlightEstimate(_ proxy: ImageBuffer,
                                              space: RGBColorSpace = .rec2020) -> DehazeAirlight {
        let w = proxy.width, h = proxy.height
        let long = Double(Swift.max(w, h))
        let lum = proxy.luminancePlane(space: space)
        let rx = Swift.max(1, Int((dehazeAirlightReachX * long).rounded()))
        let ry = Swift.max(1, Int((dehazeAirlightReachY * long).rounded()))
        let eroded = dehazeErode(lum, rx: rx, ry: ry)
        var score = Plane(width: w, height: h)
        var best = -Double.infinity
        for y in 0..<h {
            let weight = dehazeAirlightWeight((Double(y) + 0.5) / Double(h))
            for x in 0..<w {
                let s = eroded[x, y] * weight
                score[x, y] = s
                if s.isFinite { best = Swift.max(best, s) }
            }
        }
        let local = SpatialOps.boxBlur(proxy, radius: ry)
        var selection = Plane(width: w, height: h)
        var sum = RGB.zero
        var n = 0.0
        if best > 0, best.isFinite {
            let cut = best * dehazeAirlightSelect
            for y in 0..<h {
                for x in 0..<w where score[x, y] >= cut {
                    selection[x, y] = 1
                    sum = sum + local[x, y]
                    n += 1
                }
            }
        }
        if n <= 0 {
            // Degenerate (black or empty) frame: the global mean.
            for y in 0..<h { for x in 0..<w { sum = sum + proxy[x, y]; n += 1 } }
        }
        var a = n > 0 ? sum / n : RGB(gray: 1)
        let hi = a.maxComponent
        if hi > 0 {
            let sat = (hi - a.minComponent) / hi
            if sat > dehazeAirlightMaxSaturation {
                let y = space.luminance(a)
                // Pull toward grey at the same luminance until saturation is at the cap.
                // Saturation is monotone in the mix, so a short bisection is exact enough.
                var lo = 0.0, up = 1.0
                for _ in 0..<30 {
                    let m = 0.5 * (lo + up)
                    let c = RGB(gray: y) + (a - RGB(gray: y)) * m
                    let s = (c.maxComponent - c.minComponent) / Swift.max(c.maxComponent, 1e-12)
                    if s > dehazeAirlightMaxSaturation { up = m } else { lo = m }
                }
                a = RGB(gray: y) + (a - RGB(gray: y)) * lo
            }
        }
        return DehazeAirlight(rgb: RGB(Swift.max(a.r, 1e-4), Swift.max(a.g, 1e-4),
                                       Swift.max(a.b, 1e-4)),
                              selection: selection)
    }

    /// Every slider-independent dehaze field, from a proxy and its guide.
    public static func dehazeField(proxy: ImageBuffer, guide: Plane, guideSquare: Plane?,
                                   airlight: DehazeAirlight,
                                   space: RGBColorSpace = .rec2020) -> DehazeField {
        let w = proxy.width, h = proxy.height
        let long = Double(Swift.max(w, h))
        let airLuma = Swift.max(space.luminance(airlight.rgb), 1e-4)

        var minimum = Plane(width: w, height: h)
        var lum = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let c = proxy[x, y]
                minimum[x, y] = Swift.max(c.minComponent, 0)
                lum[x, y] = Swift.max(space.luminance(c), 0)
            }
        }
        let r = Swift.max(1, Int((dehazeDarkReach * long).rounded()))
        // V: ω × the range-restricted minimum of the min channel; P: the range-restricted
        // geometric mean of luminance, over the same samples (the centre among them).
        let tau = dehazeRegionEV / LumenLog.range
        var veil = Plane(width: w, height: h)
        var white = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let g0 = guide[x, y]
                var lo = minimum[x, y], logSum = 0.0, n = 0.0
                for yy in Swift.max(y - r, 0)...Swift.min(y + r, h - 1) {
                    for xx in Swift.max(x - r, 0)...Swift.min(x + r, w - 1)
                    where abs(guide[xx, yy] - g0) <= tau {
                        lo = Swift.min(lo, minimum[xx, yy])
                        logSum += log(Swift.max(lum[xx, yy], 1e-9))
                        n += 1
                    }
                }
                veil[x, y] = dehazeOmega * lo
                white[x, y] = Swift.max(exp(logSum / n), lo)
            }
        }

        let rf = Swift.max(1, Int((dehazeFlatReach * long).rounded()))
        let flat = SpatialOps.boxBlur(dehazeQuadrantStd(guide, radius: rf).map {
            1 - Num.smoothstep(dehazeFlatLoEV, dehazeFlatHiEV, $0 * LumenLog.range)
        }, radius: 1)


        // "Fully distant" for the negative branch: a high quantile of the local veil
        // fraction V/P over the frame, so the haziest region gets the full veil whatever
        // the frame's absolute haze level.
        var fractions = [Double]()
        fractions.reserveCapacity(w * h)
        for i in 0..<veil.values.count {
            fractions.append(dehazeVeilFraction(veil: Double(veil.values[i]),
                                                white: Double(white.values[i])))
        }
        fractions.sort()
        var lums = lum.values.map { Double($0) }
        lums.sort()
        let black = Swift.max(lums.isEmpty ? 0 : lums[Int(Double(lums.count - 1) * 0.01)],
                              airLuma * 1e-4)
        var purity = Plane(width: w, height: h, fill: 1)
        if let sq = guideSquare, sq.width == w, sq.height == h {
            let k = LumenLog.range * LumenLog.range / (2 * dehazePuritySigmaEV * dehazePuritySigmaEV)
            for i in 0..<purity.values.count {
                let m = Double(guide.values[i])
                let v = Swift.max(Double(sq.values[i]) - m * m, 0)
                purity.values[i] = Float(exp(-v * k))
            }
        }
        let qi = Swift.min(fractions.count - 1,
                           Int(Double(fractions.count - 1) * dehazeVeilReferenceQuantile))
        let reference = Swift.max(fractions.isEmpty ? 0 : fractions[qi], 0.05)
        return DehazeField(airlight: airlight.rgb, airLuma: airLuma,
                           selection: airlight.selection, proxy: proxy, proxyGuide: guide,
                           veil: veil, white: white, flat: flat, purity: purity,
                           veilReference: reference, blackReference: black)
    }

    public static func applyDehaze(_ image: ImageBuffer, amount: Double,
                                   decomposition d: Decomposition) -> ImageBuffer {
        let a = Num.clamp(amount, -100, 100) / 100
        guard a != 0 else { return image }
        let w = image.width
        let h = image.height
        let space = d.space
        let field = d.dehazeField()
        let airLuma = field.airLuma
        let veilTint = dehazeVeilTint(field.airlight)
        // The pivot each pixel turns about: an edge-preserving base of this image.
        let base = dehazePivotPlane(image, space: space)

        var out = image
        for y in 0..<h {
            let row = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let c = image[x, y]
                let g = LumenLog.encode(Swift.max(space.luminance(c), 0))
                let f = dehazeUpsample(field, x: x, y: y, width: w, height: h, guide: g)
                let pivot = base[x, y]
                if a > 0 {
                    out[x, y] = dehazePositivePixel(c, veil: f.veil, white: f.white, flat: f.flat,
                                                    pivot: pivot, airLuma: airLuma,
                                                    black: field.blackReference, amount: a,
                                                    space: space)
                } else {
                    out[x, y] = dehazeNegativePixel(c, veil: f.veil, white: f.white,
                                                    flat: f.flat, pivot: pivot,
                                                    row: row, airLuma: airLuma,
                                                    reference: field.veilReference,
                                                    veilTint: veilTint, amount: a,
                                                    space: space)
                }
            }
        }
        return out
    }

    /// `V/P`, the local veil fraction: 0 where the region holds a true black, → ω where
    /// its darkest point sits at its white (flat, or fully veiled).
    @inline(__always)
    static func dehazeVeilFraction(veil: Double, white: Double) -> Double {
        let p = Swift.max(white, 1e-6)
        return Num.clamp(veil / p, 0, 1)
    }

    /// Scale OKLab chroma by `s` at fixed hue AND fixed luminance. In cube-root LMS the
    /// OKLab L axis is the grey direction, so the scale is `L + s·(lms′ − L)` there —
    /// exactly hue-preserving — and a ratio multiply then puts the luminance back.
    /// Holding OKLab L instead is not holding luminance: for dark saturated greens the
    /// two part by up to 0.7 EV, which drew bands along every forest edge (r6).
    @inline(__always)
    static func dehazeScaleChroma(_ c: RGB, by s: Double,
                                  space: RGBColorSpace = .rec2020) -> RGB {
        guard s != 1 else { return c }
        let ctx = OKLabTransform.working
        let lms = ctx.rgbToLMS.apply(c)
        let p = RGB(Num.spow(lms.r, 1.0 / 3.0), Num.spow(lms.g, 1.0 / 3.0),
                    Num.spow(lms.b, 1.0 / 3.0))
        let row = OKLabTransform.lmsToLab.m[0]
        let l = row[0] * p.r + row[1] * p.g + row[2] * p.b
        let q = RGB(l + s * (p.r - l), l + s * (p.g - l), l + s * (p.b - l))
        let out = ctx.lmsToRGB.apply(RGB(q.r * q.r * q.r, q.g * q.g * q.g, q.b * q.b * q.b))
        let y0 = space.luminance(c), y1 = space.luminance(out)
        return y0 > 0 && y1 > 0 ? out * (y0 / y1) : out
    }

    /// Positive Dehaze for one pixel.
    ///
    /// A power law about the surface's own level `P` (the range-restricted geometric
    /// mean): `ln(J/P) = γ·ln(Y/P)` below it, a quarter of that above. The exponent is
    /// the haze model's log-slope at that level — removing a veil `V` from `Y` has slope
    /// `P/(P − V)` there — capped at `dehazeMaxGamma`, eased by the sky guard on bright
    /// flat regions and scaled by the amount. So the model decides HOW MUCH contrast a
    /// surface gets back, and every surface keeps its exposure.
    ///
    /// Two earlier forms failed the halo lines, and why is the design. A black-point
    /// subtraction `(Y − V)·…` has an unbounded slope near `V`, so ordinary brightness
    /// variation inside one dark surface became ±0.9 EV bands. Pinning at the surface's
    /// local maximum darkened a textured forest by 0.9 EV and the meadow beside it by
    /// 0.2, and that difference IS a band across their shared edge. A bounded exponent
    /// about each surface's own level turns brightness variation into at most `(γ − 1)`
    /// of itself and treats neighbouring surfaces alike. Below `dehazeToeReach ×` the
    /// frame's black reference the result is floored at a fraction of the input
    /// (`dehazeToeFloor` at +100). Chroma is restored in OKLab at fixed hue and
    /// luminance, by `(γ − 1)`.
    @inline(__always)
    static func dehazePositivePixel(_ c: RGB, veil: Double, white: Double, flat: Double,
                                    pivot: Double, airLuma: Double, black: Double,
                                    amount a: Double, space: RGBColorSpace) -> RGB {
        let y = space.luminance(c)
        let gamma = dehazeGamma(veil: veil, white: Swift.max(white, 1e-6), flat: flat, luma: y,
                                airLuma: airLuma, amount: a)
        let p = Swift.max(pivot, 1e-6)
        let yp = Swift.max(y, p * 1e-6)
        let share = yp < p ? dehazeShadowShare : dehazeHighlightShare
        let x = log(yp / p)
        let r = exp((gamma - 1) * share * dehazeDetailCurve(x))
        // Floor in absolute terms below the frame's black reference, so the J(Y) curve
        // stays monotone (the max of two non-decreasing curves). A smooth maximum was
        // tried and is wrong here: where the curves nearly meet it sits between them,
        // so even +10 darkened every pixel within the floor's reach by ~1 % — a jump at
        // the start of the slider.
        let f = 1 - a * (1 - dehazeToeFloor)
        let j0 = yp * r
        // The floor ramps from identity at true black to `f` at the reach, so the deepest
        // shadows are never pushed into the black clip.
        let reach = dehazeToeReach * black
        let jf = (1 - (1 - f) * Num.smoothstep(0, reach, yp)) * Swift.min(yp, reach)
        let j = Swift.max(j0, jf)
        // Both caps scale with the amount, so the slider stays even to +100 instead of
        // running into a fixed ceiling halfway.
        let k = Swift.min(j / yp, 1 + a * (dehazeMaxBrighten - 1))
        let chroma = Swift.min(1 + dehazeChromaGain * (gamma - 1), 1 + a * (dehazeChromaMax - 1))
        let gate = Num.smoothstep(dehazeChromaGateLo, dehazeChromaGateHi, y / airLuma)
            * (1 - Num.smoothstep(dehazeChromaSatLo, dehazeChromaSatHi, dehazeSaturation(c)))
        let lifted = c * k
        return dehazeGamutSafe(lifted, dehazeScaleChroma(lifted, by: 1 + (chroma - 1) * gate))
    }

    /// `(max − min)/max` of a colour, 0 for black or a colour with no positive channel.
    @inline(__always)
    static func dehazeSaturation(_ c: RGB) -> Double {
        let hi = c.maxComponent
        return hi > 1e-12 ? Num.saturate((hi - Swift.max(c.minComponent, 0)) / hi) : 0
    }

    /// The detail curve. Above the pivot `x·(1 − e^(−(x/x1)²))/(1 + x/x2)`; below it
    /// `x·(1 − e^(−(x/x1)²))·e^(−(x/x3)²)`, which also lets go of LARGE negative
    /// deviations: a dark pixel whose pivot a bright neighbour has pulled up (the forest
    /// just under a sky) is not darkened into a band. `x + k·curve(x)` is strictly
    /// rising for `k ≤ 2` (checked numerically; the shadow side uses
    /// `k = (γ − 1)·dehazeShadowShare ≤ 1.5`).
    @inline(__always)
    static func dehazeDetailCurve(_ x: Double) -> Double {
        let u = x / dehazeDetailFloor
        let rise = x * (1 - exp(-u * u))
        if x >= 0 { return rise / (1 + x / dehazeDetailSoftness) }
        let v = x / dehazeDetailRelease
        return rise * exp(-v * v)
    }

    /// The exponent of positive Dehaze at a pixel (see `dehazePositivePixel`).
    @inline(__always)
    static func dehazeGamma(veil: Double, white p: Double, flat: Double, luma y: Double,
                            airLuma: Double, amount a: Double) -> Double {
        let v = Num.clamp(veil, 0, p * dehazeOmega)
        let slope = p / Swift.max(p - v, 1e-9)
        let bright = Num.smoothstep(dehazeSkyBrightLo, dehazeSkyBrightHi, y / airLuma)
        let skyGuard = Num.saturate(flat) * bright
        let capped = Swift.min(Swift.max(slope, 1), dehazeMaxGamma) - 1
        return 1 + a * dehazeStrength * capped * (1 - dehazeSkyGuard * skyGuard)
    }

    /// Never let the chroma scale push a channel below zero from a colour that was not:
    /// the blend toward the scaled colour stops at the first channel to reach zero.
    @inline(__always)
    static func dehazeGamutSafe(_ lifted: RGB, _ scaled: RGB) -> RGB {
        var w = 1.0
        for (l, s) in [(lifted.r, scaled.r), (lifted.g, scaled.g), (lifted.b, scaled.b)]
        where s <= 0 && l >= 0 && l > s {
            w = Swift.min(w, Num.saturate(l / Swift.max(l - s, 1e-12)))
        }
        return lifted.mix(scaled, w)
    }

    /// The veil's chroma as an offset in cube-root LMS (where OKLab a, b are linear):
    /// `dehazeVeilChroma` of the airlight's own, so the veil leans toward the airlight's
    /// hue without painting its full colour.
    public static func dehazeVeilTint(_ airlight: RGB) -> RGB {
        let ctx = OKLabTransform.working
        let lms = ctx.rgbToLMS.apply(airlight)
        let p = RGB(Num.spow(lms.r, 1.0 / 3.0), Num.spow(lms.g, 1.0 / 3.0),
                    Num.spow(lms.b, 1.0 / 3.0))
        let row = OKLabTransform.lmsToLab.m[0]
        let l = row[0] * p.r + row[1] * p.g + row[2] * p.b
        return (p - RGB(gray: l)) * dehazeVeilChroma
    }

    /// Negative Dehaze for one pixel: a milky veil, the mirror of the positive side.
    /// Contrast is compressed about the surface's own level `P` — `ln(out/P) =
    /// (1 − c)·ln(Y/P)` below it, a quarter of that above — every surface is lifted
    /// toward the airlight's level by `(A/P)^(c·dehazeVeilLift)`, and chroma eases
    /// toward the veil's near-neutral tint. `c = amount × dehazeVeilMax × distance`;
    /// distance has no depth map, so it is the larger of the local veil fraction (low
    /// contrast reads far) and the sky signal (bright and flat), times the ground-plane
    /// cue (the lower frame is nearer). A blend toward a constant — the textbook
    /// forward model — lifted a dark trunk by 2 EV beside a meadow lifted by a few
    /// tenths, which is a band on the trunk's edge; compressing about each surface's
    /// level keeps neighbouring surfaces' changes alike.
    @inline(__always)
    static func dehazeNegativePixel(_ c: RGB, veil: Double, white: Double, flat: Double,
                                    pivot: Double, row v: Double, airLuma: Double, reference: Double,
                                    veilTint: RGB, amount a: Double,
                                    space: RGBColorSpace) -> RGB {
        let y = space.luminance(c)
        let bright = Num.smoothstep(dehazeSkyBrightLo, dehazeSkyBrightHi, y / airLuma)
        let sky = Num.saturate(flat) * bright
        let haze = Num.saturate(dehazeVeilFraction(veil: veil, white: white) / reference)
        let near = 1 - (1 - dehazeVeilNearWeight)
            * Num.smoothstep(dehazeVeilNearStart, dehazeVeilNearEnd, v)
        let distant = Swift.max(haze, sky) * near
        let compress = Num.saturate(-a) * dehazeVeilMax * distant
        let p = Swift.max(pivot, 1e-6)
        let yp = Swift.max(y, p * 1e-6)
        let share = yp < p ? 1 : dehazeHighlightShare
        let m = exp(compress * (share * log(p / yp)
                                + dehazeVeilLift * Swift.max(log(dehazeVeilLevel * airLuma / p), 0)))
        let lifted = c * m
        // Chroma toward the tint in cube-root LMS: (1 − t)·(root − L) + t·tint.
        let t = compress * dehazeVeilChromaBlend
        let ctx = OKLabTransform.working
        let lms = ctx.rgbToLMS.apply(lifted)
        let root = RGB(Num.spow(lms.r, 1.0 / 3.0), Num.spow(lms.g, 1.0 / 3.0),
                       Num.spow(lms.b, 1.0 / 3.0))
        let row = OKLabTransform.lmsToLab.m[0]
        let l = row[0] * root.r + row[1] * root.g + row[2] * root.b
        let q = RGB(gray: l) + (root - RGB(gray: l)) * (1 - t) + veilTint * t
        var out = ctx.lmsToRGB.apply(RGB(q.r * q.r * q.r, q.g * q.g * q.g, q.b * q.b * q.b))
        let y0 = space.luminance(lifted), y1 = space.luminance(out)
        if y0 > 0 && y1 > 0 { out = out * (y0 / y1) }
        return dehazeGamutSafe(lifted, out)
    }

    // MARK: - Capture sharpening (S4)

    /// Capture sharpening: auto-σ Richardson–Lucy deconvolution on luminance (D24).
    ///
    /// σ comes from the image's own pixels (`SpatialOps.estimatePSFSigma`) unless the recipe
    /// pins a radius — the trust device docs/06 builds the whole UI around, because it
    /// measures *this* lens at *this* aperture with no lens database in the loop.
    ///
    /// A noise gate keeps the deconvolution away from low-contrast regions so it can never
    /// amplify noise; the gate rides on the log-domain gradient, which makes its threshold
    /// exposure-invariant. Recombination is by RGB ratio, so a sharpened edge cannot fringe.
    ///
    /// Not modelled here: corner boost (needs the field position of the *uncropped* frame)
    /// and the ISO-adaptive iteration drop (needs the decode's ISO metadata). Both are
    /// pipeline-level inputs this pure function does not receive.
    public static func captureSharpen(_ image: ImageBuffer, _ params: CaptureSharpen,
                                      space: RGBColorSpace = .rec2020) -> ImageBuffer {
        // The strength comes from `CaptureSharpen.strengthFraction`, the ONE mapping both
        // readers share, and `auto` is its on switch. This function used to re-derive it
        // — `auto || radius != nil` to run, `(amount ?? 100) / 100` to scale — which is
        // the exact expression `AppleRawSource` had to have removed: with the toggle off
        // and a radius left over from another build's recipe it sharpened at full
        // strength while the panel said capture sharpening was off (W2/E2-07).
        let strength = params.strengthFraction
        guard strength > 0 else { return image }
        let w = image.width
        let h = image.height

        let lum = image.luminancePlane(space: space)
        let sigma: Double
        if let r = params.radius {
            sigma = Num.clamp(r, SpatialOps.minPSFSigma, SpatialOps.maxPSFSigma)
        } else {
            sigma = SpatialOps.estimatePSFSigma(lum)
        }

        // docs/06 §11.1: 8 iterations by default.
        let sharpened = SpatialOps.richardsonLucy(lum, sigma: sigma, iterations: 8)

        let logLum = lum.map { Num.safeLog2($0 / 0.18) }
        let structure = structureTensor(logLum, radius: 1)
        let gate = structure.magnitude

        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let base = lum[x, y]
                guard base > 1e-6 else { continue }
                // Strength scales the CORRECTION, not the mix fraction. Folding it
                // into a saturated mix meant everything above 100 pinned at 1 wherever
                // the edge gate was open — which is every edge, the only place this
                // stage does anything — so the upper half of the range was inert.
                let ratio = Num.clamp(sharpened[x, y] / base, 0.25, 4)
                let g = Num.smoothstep(0.02, 0.12, gate[x, y])
                let scaled = 1 + (ratio - 1) * strength
                let k = Num.mix(1.0, Num.clamp(scaled, 0.25, 4), g)
                if k != 1 { out[x, y] = image[x, y] * k }
            }
        }
        return out
    }

    // MARK: - Manual sharpening (S12)

    /// Manual/creative sharpening: LR's four-slider contract plus C1's halo suppression
    /// (docs/06 §11.3). Luma-only, in the log domain, applied as an RGB ratio — so no
    /// colour fringing at edges, and Amount means the same thing at any exposure.
    ///
    /// `detail` cross-fades between a halo-damped unsharp component at the user's radius
    /// (detail = 0) and a deconvolution-weighted component built from the finest à-trous
    /// scales of the cached stack (detail = 100). `masking` derives its edge mask from the
    /// same cached gradient the stack already produced — free, per docs/06.
    ///
    /// `haloSuppression` damps only the **bright** side of an overshoot. Asymmetry is the
    /// point: dark-side undershoot reads as edge definition, bright-side overshoot reads as
    /// a halo, and treating them the same is why symmetric clamps make sharpening look dull.
    ///
    /// Note on the cached stack: it was built from the S8 input, while this stage runs after
    /// Texture/Clarity/Dehaze have moved the pixels. The unsharp component is therefore
    /// computed on the *current* image (correct), and only the fine-scale component reuses
    /// the cache (an approximation the shared-stack budget buys, and one that only shifts
    /// the fine band's weighting).
    public static func applySharpen(_ image: ImageBuffer, params: ManualSharpen,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let amount = Num.clamp(params.amount, 0, 150) / 100
        guard amount > 0 else { return image }
        let w = image.width
        let h = image.height

        let radius = Num.clamp(params.radius, 0.5, 3.0)
        let detail = Num.clamp(params.detail, 0, 100) / 100
        let masking = Num.clamp(params.masking, 0, 100) / 100
        let halo = Num.clamp(params.haloSuppression, 0, 100) / 100

        let lum = image.luminancePlane(space: d.space)
        let logLum = lum.map { Num.safeLog2($0 / 0.18) }
        // DENOMINATED IN THE FRAME, not in the buffer this render happens to land in.
        // Radius went into `gaussianBlur` as a pixel count, so the same setting
        // addressed a different FRACTION of the photograph at every render size —
        // measured, a texture 1/200 of the frame wide took +3.81 code values of added
        // contrast at 1600 px and +0.29 at 7008, so a delivered file received 7% of the
        // sharpening the fit preview was judged on. Every neighbouring spatial stage
        // already tracks the long edge (`pyramidLevels`, `bandCenter`,
        // `RenderGraph.structureRadius` — sharpening's own masking gate); this is the
        // one that did not. `frameDenominatedSigma` carries the reference frame and the
        // reasoning; `RenderGraph.applySharpen` reads the same two functions.
        //
        // The long edge is the RENDER's, because `logLum` is this render's own grid and
        // a sigma is a count of its pixels. A 2560 px render is unchanged: that is the
        // frame every one of these stages is quoted at.
        let sigma = SpatialOps.frameDenominatedSigma(radius: radius,
                                                     longEdge: Swift.max(w, h))
        let blurred = SpatialOps.gaussianBlur(logLum, sigma: sigma)

        // Fine-scale component: the two finest à-trous bands the FRAME asks for, which
        // is where a deconvolution-weighted sharpener puts its energy. Fixed at
        // `details[0] + 0.5·details[1]` this was the second half of the same defect —
        // à-trous steps 1 and 2 are fixed pixel scales — and the level is continuous
        // rather than rounded so the band does not step an octave as the preview ladder
        // does (`SpatialOps.fineBandLevel`).
        //
        // The long edge here is the DECOMPOSITION's, not the render's: the level picks
        // an à-trous dilation, which is a fact about the stack's own sampling, and the
        // band is resampled onto the render extent afterwards. At 2560 px the level is
        // 0 and this is the exact expression that stood here before.
        var fine = Plane(width: w, height: h)
        if let band = SpatialOps.fineDetailBand(d.details,
                                                longEdge: Swift.max(d.width, d.height)) {
            fine = fit(band, width: w, height: h)
        }
        let gradient = fit(d.gradient, width: w, height: h)

        var delta = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let usm = logLum[x, y] - blurred[x, y]
                var v = amount * Num.mix(usm, fine[x, y], detail)
                if v > 0 && halo > 0 {
                    // Only the bright overshoot is damped, and only once it is large
                    // enough to read as a rim rather than as edge definition.
                    v *= 1.0 - halo * Num.smoothstep(0.15, 0.60, usm)
                }
                if masking > 0 {
                    let edge = Num.smoothstep(0.02 + 0.10 * masking,
                                              0.10 + 0.25 * masking,
                                              gradient[x, y])
                    v *= Num.mix(1.0, edge, masking)
                }
                delta[x, y] = v
            }
        }
        return applyLumaRatio(image, deltaEV: delta, limit: 2)
    }

    // MARK: - Vignette (S13)

    /// Post-crop vignette: an EV multiply on scene-linear RGB, before the display transform
    /// (docs/06 §12). `ev` is `Look.vignette`, −3.00…+1.00, 0 = off.
    ///
    /// EV denomination is the whole idea: a −0.7 EV edge burn means the same thing on every
    /// exposure, and because the multiply happens upstream of a hue-preserving transform,
    /// darkened corners cannot colour-shift and clipped speculars still punch through the
    /// shoulder — LR's "Highlight Priority" behaviour emerging from pipeline position rather
    /// than from a mode dropdown.
    ///
    /// The falloff is radial on the frame's own aspect (docs/06's Roundness 0). The
    /// Midpoint and Highlight-protection disclosures stay at their documented defaults
    /// of 50/50 — constants here rather than parameters — while FEATHER is the one
    /// knob the recipe now carries (`Look.vignetteFeather`, docs/32 Stream E item 4):
    /// engine geometry was fixed for the vignette's whole life, and the owner asked
    /// for the shape to be adjustable. Highlight protection blends the multiply back
    /// toward identity above half the default scene white (0.18 · 2^5 ÷ 2), which is
    /// what keeps a burn off a bright sky while it still shapes the corners.
    /// Disclosure defaults, named so the GPU stand-in can use the same numbers. It did
    /// not: the kernel was handed `feather = 0.7`, giving an inner radius of 0.3
    /// against this path's 0.375.
    public static let vignetteMidpoint: Double = 0.5
    /// Highlights disclosure default (docs/06 §12), named for the same reason the one
    /// above is: the GPU kernel has to use the same number. It did not use one at all
    /// — bright corners took the full burn there and half of it here.
    public static let vignetteHighlightProtection: Double = 0.5

    /// Where the falloff starts, on the normalized radius whose 1 is the frame corner,
    /// for a recipe feather in 0…100.
    ///
    /// The mapping: `inner = clamp(3 · midpoint · (1 − feather/100) / 2, 0, 0.98)`.
    /// At the default feather of 50 this is `0.75 · 0.5 = 0.375` — EXACTLY the number
    /// both renderers used while the geometry was fixed (then spelt
    /// `midpoint · (1 − 0.5 · featherConstant)` with the constant at 0.5), so every
    /// recipe without the field renders byte-identically. Feather 0 starts the burn at
    /// r = 0.75 — a tight ring against the corner — and feather 100 at the centre, a
    /// falloff spanning the whole frame. The outer edge stays pinned at the corner
    /// (r = 1) at every feather, which is what lets the GPU kernel keep its single
    /// `feather = 1 − inner` scalar unchanged.
    public static func vignetteInnerRadius(feather: Double) -> Double {
        let f = Num.clamp(feather, 0, 100) / 100
        return Num.clamp(1.5 * vignetteMidpoint * (1 - f), 0, 0.98)
    }

    /// The inner radius at the DEFAULT feather — a convenience for tests and for any
    /// reader that has no recipe in hand. Neither renderer reads it: both take the
    /// recipe's feather through `vignetteInnerRadius(feather:)` (`RenderGraph
    /// .applyVignette`, `DetailEngine.vignette`). It used to say the GPU graph read this
    /// "until its half of docs/32 Stream E item 4 lands"; that half landed, and the
    /// sentence left the next reader to work out which of the two the renderers call
    /// (W2/D2-05).
    public static var vignetteInnerRadius: Double {
        vignetteInnerRadius(feather: Look.vignetteFeatherDefault)
    }

    /// The falloff itself: a Hermite smoothstep from the inner radius to the corner,
    /// on a radius normalized so that r = 1 is the frame's CORNER.
    ///
    /// Named and kept rather than changed, and the reason is worth writing down because
    /// the obvious reading of the owner's report points the other way. The Hermite is
    /// flat at BOTH ends by construction — zero derivative at r = inner and at r = 1 —
    /// and on a 3:2 frame at the default feather that measures as:
    ///
    ///   · 38.81% of the frame receives 10% or less of the stated Amount;
    ///   · 3.15% receives 90% or more of it — the stated EV lands on almost nothing;
    ///   · the frame MEAN falloff is 0.2916, so "−3.00 EV" darkens the picture by a
    ///     mean of 0.87 EV;
    ///   · the outer tenth of the radius, which is where the eye reads "the corners",
    ///     carries 6.86% of the burn (2.80% at feather 100). The burn stops deepening
    ///     exactly where a vignette should be deepest.
    ///
    /// So the shape genuinely is soft at both ends. It is kept anyway, because the
    /// alternatives were measured and every one of them makes the vignette WEAKER,
    /// which is the opposite of what was asked for. Frame mean at inner = 0.375, and at
    /// inner = 0 (feather 100), for shapes that all satisfy f(0)=0, f(1)=1 and monotone:
    ///
    ///       shape                 mean @0.375   mean @0     outer tenth @0.375
    ///       3t²−2t³ (this one)      0.2916       0.5565           0.069
    ///       t²                      0.1612       0.3333           0.294
    ///       t^1.5                   0.2188       0.4197           0.230
    ///       5t²−8t³+4t⁴             0.2882       0.5150           0.222
    ///       (3t²−2t³)^0.7           0.3636       0.6428           0.049
    ///
    /// The trade is forced, not incidental: with the support fixed at [inner, 1] and the
    /// corner pinned at exactly the stated Amount, any shape that arrives at r = 1 with a
    /// live slope is below the Hermite EVERYWHERE — for the cubic family with f'(1) = s
    /// the difference is exactly s·t²(1−t) ≥ 0. Buying a live corner costs 20–45% of the
    /// delivered strength, and `t²` cannot reach the Hermite's frame mean even with the
    /// falloff started at the picture's centre (0.3333 against 0.5565). Trading intensity
    /// for corner gradient is the wrong direction for a photographer who says the
    /// vignette is not strong enough, so the shape stays and the RANGE moved instead
    /// (`vignetteAmountRange`).
    ///
    /// What this does mean, and what the Amount row's help now says out loud, is that
    /// the number on the slider is a CORNER number: the frame receives a fraction of it,
    /// and that fraction is what Feather sets — 0.041 of the Amount at feather 0, 0.292
    /// at 50, 0.557 at 100. Feather is the strength control and Amount is its ceiling.
    /// `VignetteResponseTests` pins every number above.
    public static func vignetteFalloff(radius: Double, inner: Double) -> Double {
        Num.smoothstep(inner, 1.0, radius)
    }

    /// The Amount clamp, named once so the GPU kernel's call site cannot pick a
    /// different pair — it already had to be told this once (docs/31 round two §15: the
    /// kernel took the raw value and rendered a deeper corner than the reference for any
    /// out-of-range recipe).
    ///
    /// −4.00 … +2.00 EV, WIDENED FROM −3.00 … +1.00, and the widening is docs/32 Stream E
    /// item 4(c) — "reassess strength range only after banding is fixed" — coming due,
    /// against the owner's report that the vignette "is a little bit soft at both ends".
    ///
    /// It is soft at both ends because the control STOPS while it is still working, and
    /// that is a measurement rather than a judgement. Swept on a flat 0.18 frame through
    /// the whole reference pipeline, in sRGB code values at the display (the unit
    /// `ProofMetrics` insists on, because a scene-referred delta says nothing about what
    /// the eye gets), the mean separation the last 0.2 EV of travel buys:
    ///
    ///       ev      −0.2   −1.0   −2.0   −3.0   −4.0   −5.0   −6.0
    ///       Δmean   2.40   2.80   2.17   1.75   1.39   1.09   0.87
    ///       Δpeak   8.39  10.46   5.15   4.21   1.42   0.82   0.42
    ///
    ///       ev      +0.2   +1.0   +2.0   +3.0
    ///       Δmean   3.59   2.91   2.52   2.13
    ///       Δpeak  11.99   9.30   6.82   4.91
    ///
    /// At the OLD floor of −3 the control was still delivering 1.75 code values per 0.2 EV
    /// — 73% of its rate at zero — and at the old ceiling of +1 it was delivering 2.91,
    /// 81% of its rate at zero and the steepest live end of the whole control. Neither
    /// end had run out of effect; the travel had run out of range. The cumulative mean
    /// separation over the frame goes 35.05 code values at −3 → 42.67 at −4 (+22%), and
    /// 16.02 at +1 → 29.41 at +2 (+84%). That is the "soft at both ends" the owner
    /// reported, and it is the only part of the amount axis that was wrong.
    ///
    /// Why it stops HERE and not further out, both ends measured rather than chosen:
    ///
    ///   · −4.00 is where a step of travel stops paying for itself. The peak separation
    ///     per 0.2 EV falls 4.21 → 1.42 across the fourth stop and 1.42 → 0.82 across the
    ///     fifth; a step worth under a code value is a step nobody can see, and docs/20's
    ///     P2 calls a control that still moves and no longer shows "dead". The corner
    ///     lands at 2⁻⁴ = 6.25% of its own value, which is a burn, not a hole.
    ///   · +2.00 is where the corner would start CLIPPING on a correctly exposed frame.
    ///     Mid-grey is 0.18 scene-linear, so +2 EV puts a corner at 0.72 — inside display
    ///     white — and +3 EV puts it at 1.44, which is white with the picture in it gone.
    ///     The measured peak at +3 (116.8 code values against +2's 89.5) is that clip,
    ///     not an effect.
    ///
    /// WHAT THIS DELIBERATELY DOES NOT CHANGE, because the same sweep exonerated it: the
    /// amount MAPPING. The response is strictly monotone over 401 settings (worst
    /// reversal 0.0 code values), it reaches its stated extreme exactly at the corner
    /// (measured gain 0.12521 against 2⁻³ = 0.125, and 1.99886 against 2⁺¹ = 2), and in
    /// display code values its increments across the negative half run 2.40 → 2.90 →
    /// 1.75, a spread of 1.7:1. A control whose worst and best steps are within 1.7:1 is
    /// not "flat at the ends", and re-denominating this axis away from EV would cost the
    /// property the whole feature is built on — that −0.7 EV means the same burn on every
    /// exposure.
    ///
    /// Every recipe ever written is inside the old range, so widening the clamp cannot
    /// change one pixel of one existing photograph. That is the whole reason this is the
    /// fix and a change to the falloff SHAPE is not — see `vignetteFalloff`.
    public static let vignetteAmountRange: ClosedRange<Double> = -4.0...2.0

    public static func vignette(_ image: ImageBuffer, ev: Double,
                                feather: Double = Look.vignetteFeatherDefault)
        -> ImageBuffer {
        let amount = Num.clamp(ev, vignetteAmountRange.lowerBound,
                               vignetteAmountRange.upperBound)
        guard amount != 0 else { return image }
        let w = image.width
        let h = image.height
        let space = RGBColorSpace.rec2020

        // Midpoint and Highlight protection at the docs/06 §12 disclosure defaults;
        // Feather from the recipe, defaulted to the geometry the engine always had.
        let protection = DetailEngine.vignetteHighlightProtection
        let inner = DetailEngine.vignetteInnerRadius(feather: feather)
        // The outer edge is the frame CORNER, r = 1, at every feather — it is baked into
        // `vignetteFalloff` rather than carried as a local, which is what lets the GPU
        // kernel keep describing the geometry with the single scalar `1 − inner`.
        // Default scene white is mid-grey + 5 stops (ToneEngine.defaultWhiteAnchorEV).
        let highlightThreshold = 0.18 * pow(2.0, 5.0) / 2.0

        let halfW = Double(w) * 0.5
        let halfH = Double(h) * 0.5
        // Normalize per axis, then scale so the frame CORNER sits at r = 1 regardless of
        // aspect — which is what makes "−1 EV" a statement about the corner and what
        // keeps the falloff's level sets elliptical on the crop's own proportions
        // (docs/06's Roundness 0).
        //
        // The comment here used to call r = 1 "the ellipse INSCRIBED in the crop
        // rectangle", and it is the circumscribed one: with u and v each spanning ±1,
        // r = 1 is u² + v² = 2, the ellipse through the four corners. The inscribed one
        // — the one that touches the edge midpoints — sits at r = 0.7071, where the
        // default feather delivers 0.547 of the Amount. The distinction is the whole of
        // why the stated EV lands on 3.15% of a 3:2 frame (see `vignetteFalloff`), so a
        // note naming the wrong ellipse was hiding the audit's own finding.
        let norm = 1.0 / (2.0 as Double).squareRoot()

        var out = image
        for y in 0..<h {
            let v = (Double(y) + 0.5 - halfH) / Swift.max(halfH, 1e-6)
            for x in 0..<w {
                let u = (Double(x) + 0.5 - halfW) / Swift.max(halfW, 1e-6)
                let r = (u * u + v * v).squareRoot() * norm
                // Through the named function, so the shape has one definition and the
                // GPU kernel's comment has something to point at.
                let falloff = DetailEngine.vignetteFalloff(radius: r, inner: inner)
                if falloff <= 0 { continue }
                let c = image[x, y]
                let lum = space.luminance(c)
                let protect = protection * Num.smoothstep(highlightThreshold,
                                                          highlightThreshold * 2, lum)
                let stops = amount * falloff * (1 - protect)
                if stops == 0 { continue }
                out[x, y] = c * pow(2.0, stops)
            }
        }
        return out
    }

    // MARK: - Local Laplacian internals

    /// Number of sampled remap curves. Six is darktable's `locallaplacian.c` count: enough
    /// that the piecewise-linear interpolation between them is invisible, few enough that
    /// the cost is six pyramid builds rather than one per intensity.
    private static let remapLevels: Int = 6

    private static func localLaplacian(_ input: Plane, pyramid: [Plane], amount: Double,
                                       sigma: Double, midtoneEV: Double) -> Plane {
        let levels = pyramid.count
        guard levels >= 2, sigma > 0 else { return input }
        let span = input.range
        let lo = span.min
        let extent = span.max - lo
        guard extent > 1e-6 else { return input }

        let n = remapLevels
        var accumulated: [Plane] = []
        for l in 0..<levels {
            accumulated.append(Plane(width: pyramid[l].width, height: pyramid[l].height))
        }

        for j in 0..<n {
            let gamma = lo + extent * Double(j) / Double(n - 1)
            // Midtone weight: a Gaussian on the reference level, centred at mid-grey.
            let weight = exp(-(gamma * gamma) / (2 * midtoneEV * midtoneEV))
            let alpha = Swift.max(1.0 - 0.7 * amount * weight, 0.05)
            let remapped = input.map { remap($0, gamma: gamma, sigma: sigma, alpha: alpha) }
            let lap = laplacianPyramid(remapped, levels: levels)

            for l in 0..<(levels - 1) {
                // The remapped plane has the input's extent, so its pyramid has the same
                // depth — but bound the index anyway: an out-of-range read here would take
                // the whole render down, and the check costs one comparison per level.
                if l >= lap.count { break }
                let g = pyramid[l]
                let src = lap[l]
                guard src.width == g.width && src.height == g.height else { continue }
                var target = accumulated[l]
                guard target.width == g.width && target.height == g.height else { continue }
                for y in 0..<target.height {
                    for x in 0..<target.width {
                        let t = Num.saturate((g[x, y] - lo) / extent) * Double(n - 1)
                        let contribution = Swift.max(0.0, 1.0 - abs(t - Double(j)))
                        if contribution > 0 {
                            target[x, y] = target[x, y] + contribution * src[x, y]
                        }
                    }
                }
                accumulated[l] = target
            }
        }

        // The coarsest level is copied straight from the input: global tone, and therefore
        // the white and black points, survive Clarity untouched.
        accumulated[levels - 1] = pyramid[levels - 1]
        return collapse(accumulated)
    }

    /// The remap point function. Monotone in `x` for any `alpha > 0`, which is the property
    /// the halo-free claim rests on. Continuous at `|d| = sigma`, where both branches give
    /// `gamma + d`.
    private static func remap(_ x: Double, gamma: Double, sigma: Double, alpha: Double) -> Double {
        let d = x - gamma
        let a = abs(d)
        if a >= sigma { return gamma + d }
        let sign = d < 0 ? -1.0 : 1.0
        let t = Num.saturate(a / sigma)
        return gamma + sign * sigma * pow(t, alpha)
    }

    // MARK: - Pyramids

    /// Gaussian pyramid, finest first. Each level is a binomial-blurred, 2× decimated copy.
    public static func gaussianPyramid(_ plane: Plane, levels: Int) -> [Plane] {
        let n = Swift.min(Swift.max(levels, 1), 12)
        var out: [Plane] = [plane]
        for _ in 1..<Swift.max(n, 1) {
            guard let last = out.last else { break }
            if last.width < 4 || last.height < 4 { break }
            out.append(downsample(last))
        }
        return out
    }

    /// Laplacian pyramid with the same level count as the Gaussian one; the last entry is
    /// the coarse residual, not a difference.
    private static func laplacianPyramid(_ plane: Plane, levels: Int) -> [Plane] {
        let gauss = gaussianPyramid(plane, levels: levels)
        var out: [Plane] = []
        if gauss.count >= 2 {
            for l in 0..<(gauss.count - 1) {
                let up = gauss[l + 1].resized(width: gauss[l].width, height: gauss[l].height)
                out.append(gauss[l].zip(up) { $0 - $1 })
            }
        }
        if let last = gauss.last { out.append(last) }
        return out
    }

    private static func collapse(_ pyramid: [Plane]) -> Plane {
        guard var out = pyramid.last else { return Plane(width: 1, height: 1) }
        var l = pyramid.count - 2
        while l >= 0 {
            let target = pyramid[l]
            let up = out.resized(width: target.width, height: target.height)
            out = target.zip(up) { $0 + $1 }
            l -= 1
        }
        return out
    }

    /// Binomial [1,4,6,4,1]/16 blur then 2× decimation. Both axes floor to at least 1, so
    /// the pyramid never produces an empty extent.
    private static func downsample(_ plane: Plane) -> Plane {
        let w = Swift.max(plane.width / 2, 1)
        let h = Swift.max(plane.height / 2, 1)
        let k: [Double] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]

        var tmp = Plane(width: plane.width, height: plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                var acc = 0.0
                for t in 0..<5 { acc += k[t] * plane.clampedSample(x + t - 2, y) }
                tmp[x, y] = acc
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0..<5 { acc += k[t] * tmp.clampedSample(x * 2, y * 2 + t - 2) }
                out[x, y] = acc
            }
        }
        return out
    }

    // MARK: - Local structure

    /// Structure-tensor analysis of a log-luminance plane.
    ///
    /// `magnitude` is √λ₁ — the gradient strength along the dominant local direction, in
    /// EV per pixel, so a threshold on it is a statement about contrast, not about exposure.
    /// `coherence` is `(λ₁−λ₂)/(λ₁+λ₂)` gated by strength: 1 where the neighbourhood is a
    /// directed, high-contrast edge and 0 where it is isotropic texture. That distinction is
    /// what negative Texture rides on.
    public static func structureTensor(_ plane: Plane, radius: Int)
        -> (magnitude: Plane, coherence: Plane) {
        let w = plane.width
        let h = plane.height
        var jxx = Plane(width: w, height: h)
        var jxy = Plane(width: w, height: h)
        var jyy = Plane(width: w, height: h)

        for y in 0..<h {
            for x in 0..<w {
                let gx = 0.5 * (plane.clampedSample(x + 1, y) - plane.clampedSample(x - 1, y))
                let gy = 0.5 * (plane.clampedSample(x, y + 1) - plane.clampedSample(x, y - 1))
                jxx[x, y] = gx * gx
                jxy[x, y] = gx * gy
                jyy[x, y] = gy * gy
            }
        }
        let r = Swift.max(radius, 1)
        let bxx = SpatialOps.boxBlur(jxx, radius: r)
        let bxy = SpatialOps.boxBlur(jxy, radius: r)
        let byy = SpatialOps.boxBlur(jyy, radius: r)

        var magnitude = Plane(width: w, height: h)
        var coherence = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let a = bxx[x, y]
                let b = bxy[x, y]
                let c = byy[x, y]
                let trace = a + c
                let diff = a - c
                let disc = Swift.max(diff * diff + 4 * b * b, 0).squareRoot()
                let l1 = Swift.max(0.5 * (trace + disc), 0)
                let m = l1.squareRoot()
                magnitude[x, y] = m
                let coh = trace > 1e-12 ? Num.saturate(disc / trace) : 0
                coherence[x, y] = coh * Num.smoothstep(0.05, 0.35, m)
            }
        }
        return (magnitude, coherence)
    }

    // MARK: - Shared recombination

    /// Apply a per-pixel ΔEV plane to RGB as one multiply. This is the single place any
    /// presence or sharpening tool touches pixel values, which is what makes "chroma
    /// untouched, colour cannot shift" a property of the engine rather than a promise
    /// repeated per tool. `limit` bounds the excursion so a pathological coefficient cannot
    /// turn into an infinity downstream.
    private static func applyLumaRatio(_ image: ImageBuffer, deltaEV: Plane,
                                       limit: Double) -> ImageBuffer {
        let w = image.width
        let h = image.height
        let delta = fit(deltaEV, width: w, height: h)
        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let d = Num.clamp(delta[x, y], -limit, limit)
                if d == 0 { continue }
                out[x, y] = image[x, y] * pow(2.0, d)
            }
        }
        return out
    }

    /// Resample a cached plane onto the render target's extent. Fit view and full render
    /// share one decomposition (docs/06 §10.1, "scale honesty"), so a mismatch is expected
    /// rather than exceptional — and resampling here is what keeps every subsequent index
    /// in bounds without a per-call precondition.
    private static func fit(_ plane: Plane, width: Int, height: Int) -> Plane {
        if plane.width == width && plane.height == height { return plane }
        return plane.resized(width: width, height: height)
    }

    /// Texture's band centre in à-trous scale index. Level 1 is ~4 px of structure, the
    /// middle of docs/06's 2–8 px target band at the 2560-px working resolution; the log2
    /// term shifts the band with resolution so the same physical detail is addressed on a
    /// 61 MP file as on a 24 MP one.
    private static func bandCenter(width: Int, height: Int) -> Double {
        let longEdge = Double(Swift.max(width, height))
        guard longEdge > 0 else { return 1.0 }
        return 1.0 + Num.clamp(log2(longEdge / 2560.0), -1.0, 2.0)
    }

    /// Total weight an UNTRUNCATED window carries — what the normalization above
    /// restores every realized window to, so a given Texture setting means the same
    /// amount of texture at every resolution.
    private static func referenceBandWeight(halfWidth: Double) -> Double {
        var total = 0.0
        var level = -32
        while level <= 32 {
            total += bandWeight(level: level, center: 0, halfWidth: halfWidth)
            level += 1
        }
        return total
    }

    /// Raised-cosine window over scale index: 1 at the centre, 0 at the band edges, with a
    /// smooth transition so adjacent scales blend rather than seam.
    private static func bandWeight(level: Int, center: Double, halfWidth: Double) -> Double {
        guard halfWidth > 0 else { return 0 }
        let d = abs(Double(level) - center) / halfWidth
        if d >= 1 { return 0 }
        return 0.5 * (1 + cos(.pi * d))
    }
}
