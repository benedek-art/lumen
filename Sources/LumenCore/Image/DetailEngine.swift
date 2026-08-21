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
//   · Dehaze neutralizes the estimated airlight cast before inverting the haze model
//     (§ applyDehaze), which is what stops LR's magenta skies at the algorithm level.

import Foundation

/// The lazily-built halves of a decomposition. A reference box so the value-typed
/// `Decomposition` can be copied around a render without rebuilding a dark channel, and so
/// the airlight is literally the same number on every tile of a tiled export
/// (docs/14 §6.3, the proxy-field rule). Single-threaded by contract: a decomposition
/// belongs to one render pass.
fileprivate final class DehazeCache: @unchecked Sendable {
    var airlight: RGB?
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
    public static let pyramidLevels: Int = 5
    /// Guided-filter regularization for the base, in EV². √0.01 = 0.1 EV: anything flatter
    /// than a tenth of a stop across the window is one surface.
    public static let baseEpsilon: Double = 0.01
    /// Clarity's detail/edge threshold in EV. Excursions below this are "texture" and get
    /// remapped; anything above is an edge and passes through untouched.
    public static let clarityDetailEV: Double = 0.7
    /// Width in EV of the midtone weight on Clarity's remap, so Clarity expands local
    /// contrast without reaching the white and black points docs/04 owns.
    public static let clarityMidtoneEV: Double = 3.0
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

            self.pyramid = DetailEngine.gaussianPyramid(logLum, levels: DetailEngine.pyramidLevels)

            let structure = DetailEngine.structureTensor(logLum, radius: Swift.max(radius / 4, 1))
            self.gradient = structure.magnitude
            self.coherence = structure.coherence
        }

        /// Atmospheric light, estimated once and frozen. Cached on first use so a Dehaze
        /// drag pays for it exactly once per render.
        public func airlight() -> RGB {
            if let a = cache.airlight { return a }
            let radius = Swift.max(Swift.min(width, height) / 100, 3)
            let dc = SpatialOps.darkChannel(source, radius: radius)
            let a = SpatialOps.estimateAirlight(source, darkChannel: dc, topFraction: 0.001)
            cache.airlight = a
            return a
        }

        /// Transmission map `t = 1 − ω · darkChannel(I/A)`, refined by the same guided
        /// filter the base uses so it follows edges instead of blocking up along the patch
        /// grid. Built on first non-zero Dehaze drag, then cached with the decomposition.
        ///
        /// ω is baked in and the *slider* is a recovery blend applied at recombination
        /// time — which is what keeps this map slider-independent and therefore cacheable.
        public func transmission() -> Plane {
            if let t = cache.transmission { return t }
            let a = airlight()
            let normalized = source.map { c in
                RGB(c.r / a.r, c.g / a.g, c.b / a.b)
            }
            let radius = Swift.max(Swift.min(width, height) / 100, 3)
            let dc = SpatialOps.darkChannel(normalized, radius: radius)
            let raw = dc.map { 1.0 - DetailEngine.dehazeOmega * Num.saturate($0) }
            // Guide with the log-luminance node we already have: the transmission inherits
            // the base's edges for free, which is the "reuses the shared decomposition's
            // guided-filter machinery" clause in docs/06 §10.4.
            let refined = SpatialOps.guidedFilter(input: raw, guide: logLuminance,
                                                  radius: Swift.max(workingRadius, 8),
                                                  epsilon: 0.02)
            let clamped = refined.map { Num.clamp($0, 0.02, 1.0) }
            cache.transmission = clamped
            return clamped
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
    public static func applyTexture(_ image: ImageBuffer, amount: Double,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = Num.clamp(amount, -100, 100) / 100
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
                    // Positive: uniform gain. Negative: gated by local structure.
                    let gate = a >= 0 ? 1.0 : (1.0 - Num.saturate(coherence[x, y]))
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
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = Num.clamp(amount, -100, 100) / 100
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
            pyramid = gaussianPyramid(input, levels: pyramidLevels)
        }
        guard pyramid.count >= 2 else { return image }

        let remapped = localLaplacian(input, pyramid: pyramid, amount: a,
                                      sigma: clarityDetailEV, midtoneEV: clarityMidtoneEV)
        let delta = remapped.zip(input) { $0 - $1 }
        return applyLumaRatio(image, deltaEV: delta, limit: 4)
    }

    // MARK: - Dehaze

    /// Dehaze: He/Sun/Tang dark-channel prior, inverted on **scene-linear** data where the
    /// haze model `I = J·t + A·(1−t)` is actually valid (docs/06 §10.4).
    ///
    /// **The magenta-sky fix, stated plainly.** Haze is rarely neutral — the estimated
    /// airlight A is typically blue-cyan. Inverting `J = (I − A)/t + A` per channel
    /// subtracts more blue than red, and the residual after amplification is a magenta cast
    /// that lands hardest in the sky, where t is smallest. Lumen neutralizes first: the
    /// image is white-balanced against A (multiply by `A_luma / A`, so the veil becomes
    /// achromatic at level `A_luma`), the inversion runs on the *neutralized luminance*
    /// only, and the resulting scalar ratio is applied back to the untouched original RGB.
    /// The subtraction therefore happens in a frame where the haze has no hue to leave
    /// behind, and the output is hue-preserving by construction — a ratio multiply cannot
    /// rotate a colour.
    ///
    /// Two floors keep skies honest:
    ///   · `t_min` from docs/06's Distance disclosure (default 20): low Distance corrects
    ///     only nearby haze and leaves distant atmosphere as a depth cue.
    ///   · A raised floor on bright, low-gradient regions — the sky itself — so the largest
    ///     flat area in the frame does not take the largest correction.
    ///
    /// Negative Dehaze runs the model **forwards**: `out = J·t' + A·(1−t')` with a
    /// synthetic `t'` from the same transmission map. Synthesizing haze in scene-linear
    /// adds no noise, because it is a blend toward a constant rather than a lift.
    public static func applyDehaze(_ image: ImageBuffer, amount: Double,
                                   decomposition d: Decomposition) -> ImageBuffer {
        let a = Num.clamp(amount, -100, 100) / 100
        guard a != 0 else { return image }
        let w = image.width
        let h = image.height

        let airlight = d.airlight()
        let space = d.space
        let airLuma = Swift.max(space.luminance(airlight), 1e-5)
        // Neutralization gains: after this multiply the veil is grey at level `airLuma`.
        let gain = RGB(airLuma / Swift.max(airlight.r, 1e-5),
                       airLuma / Swift.max(airlight.g, 1e-5),
                       airLuma / Swift.max(airlight.b, 1e-5))

        let t = fit(d.transmission(), width: w, height: h)
        let gradient = fit(d.gradient, width: w, height: h)
        let logLum = fit(d.logLuminance, width: w, height: h)

        let distance = Num.clamp(dehazeDistance, 0, 100) / 100
        let tMin = Num.mix(0.55, 0.05, distance)

        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let c = image[x, y]
                // Sky guard: bright and flat ⇒ raise the transmission floor toward 1.
                let bright = Num.smoothstep(0.5, 2.0, logLum[x, y])
                let flat = 1.0 - Num.smoothstep(0.05, 0.35, gradient[x, y])
                let floorT = Num.mix(tMin, 0.9, Num.saturate(bright * flat))
                let tv = Swift.max(t[x, y], floorT)

                if a > 0 {
                    let neutral = c * gain
                    let y0 = space.luminance(neutral)
                    let y1 = (y0 - airLuma) / tv + airLuma
                    // Trust the luminance ratio only when the luminance is a real
                    // fraction of the colour's own magnitude.
                    //
                    // `y1` is a fixed negative number as `y0` approaches zero, so the
                    // ratio diverges and its SIGN flips across zero — the 0.05 clamp on
                    // one side, the 20 clamp on the other. Scaling by it is a 400×
                    // swing decided by a quantity that is essentially zero. The
                    // original guard substituted a signed epsilon, which chose a side
                    // arbitrarily; a first fix faded to identity over an absolute
                    // window, which was far too narrow for a factor of twenty and still
                    // stepped.
                    //
                    // The measure that works is relative. Near-zero luminance is not
                    // near-zero colour: shadow noise after white balance produces
                    // triples like (−0.02, +0.009, −0.01) whose luminance cancels while
                    // the channels do not, and scaling those by a luminance ratio is
                    // meaningless — they became saturated speckles that flickered with
                    // the noise. A saturated blue, by contrast, carries only six percent
                    // of its peak channel as luminance and must still dehaze fully,
                    // which is why the window sits an order of magnitude below that.
                    let magnitude = Swift.max(abs(c.r), Swift.max(abs(c.g), abs(c.b)))
                    let trust = magnitude > 0
                        ? Num.smoothstep(0.01, 0.05, abs(y0) / magnitude)
                        : 0
                    let ratio = y0 != 0 ? Num.clamp(y1 / y0, 0.05, 20) : 1.0
                    out[x, y] = c * Num.mix(1.0, Num.mix(1.0, ratio, trust), a)
                } else {
                    // Forward model: blend toward A, with more haze the FURTHER away
                    // the pixel reads.
                    //
                    // This used to reuse `tv`, and `tv` carries the sky guard — which
                    // exists to stop the positive branch from stripping haze out of a
                    // sky. Reused here it does the opposite of what it means: a high
                    // floor made `1 − tv` small, so the sky got the LEAST added haze and
                    // the near foreground got the most. Measured across a scene, Dehaze
                    // −100 put 0.09 on a clear sky and 0.495 on dark foreground — 5.5×
                    // more haze on the subject than on the distance, which is the exact
                    // inverse of atmosphere.
                    //
                    // Distance has no depth map here, so it is estimated from the two
                    // signals that already exist: the dark channel's own transmission
                    // (low = already hazy = far) and the bright-and-flat sky signal.
                    // Either one saying "far" is enough.
                    let skyness = Num.saturate(bright * flat)
                    let distant = Swift.max(1 - t[x, y], skyness)
                    let s = Num.saturate(-a * distant * 0.9)
                    out[x, y] = c.mix(airlight, s)
                }
            }
        }
        return out
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
        guard params.auto || params.radius != nil else { return image }
        let w = image.width
        let h = image.height

        let lum = image.luminancePlane(space: space)
        let sigma: Double
        if let r = params.radius {
            sigma = Num.clamp(r, SpatialOps.minPSFSigma, SpatialOps.maxPSFSigma)
        } else {
            sigma = SpatialOps.estimatePSFSigma(lum)
        }
        let strength = Num.clamp((params.amount ?? 100) / 100, 0, CaptureSharpen.maxStrength)
        guard strength > 0 else { return image }

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
        let blurred = SpatialOps.gaussianBlur(logLum, sigma: radius)

        // Fine-scale component: the two finest à-trous bands, which is where a
        // deconvolution-weighted sharpener puts its energy.
        var fine = Plane(width: w, height: h)
        if d.details.count >= 2 {
            let f0 = fit(d.details[0], width: w, height: h)
            let f1 = fit(d.details[1], width: w, height: h)
            fine = f0.zip(f1) { $0 + 0.5 * $1 }
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
    /// The falloff is radial on the frame's own aspect (docs/06's Roundness 0), with the
    /// Midpoint/Feather/Highlight-protection disclosures at their documented defaults of
    /// 50/50/50 — the recipe stores only the amount, so those are constants here rather than
    /// parameters. Highlight protection blends the multiply back toward identity above half
    /// the default scene white (0.18 · 2^5 ÷ 2), which is what keeps a burn off a bright sky
    /// while it still shapes the corners.
    /// Disclosure defaults, named so the GPU stand-in can use the same numbers. It did
    /// not: the kernel was handed `feather = 0.7`, giving an inner radius of 0.3
    /// against this path's 0.375.
    public static let vignetteMidpoint: Double = 0.5
    public static let vignetteFeather: Double = 0.5
    /// Highlights disclosure default (docs/06 §12), named for the same reason the two
    /// above are: the GPU kernel has to use the same number. It did not use one at all
    /// — bright corners took the full burn there and half of it here.
    public static let vignetteHighlightProtection: Double = 0.5
    /// Where the falloff starts, on the normalized radius whose 1 is the frame corner.
    public static var vignetteInnerRadius: Double {
        Num.clamp(vignetteMidpoint * (1 - 0.5 * vignetteFeather), 0, 0.98)
    }

    public static func vignette(_ image: ImageBuffer, ev: Double) -> ImageBuffer {
        let amount = Num.clamp(ev, -3.0, 1.0)
        guard amount != 0 else { return image }
        let w = image.width
        let h = image.height
        let space = RGBColorSpace.rec2020

        // Disclosure defaults (docs/06 §12): Midpoint 50, Feather 50, Highlight 50.
        // Midpoint and Feather now live on the type as named constants, because the
        // GPU stand-in has to start its falloff in the same place; `vignetteInnerRadius`
        // is what they combine to.
        let protection = DetailEngine.vignetteHighlightProtection
        let inner = DetailEngine.vignetteInnerRadius
        let outer = 1.0
        // Default scene white is mid-grey + 5 stops (ToneEngine.defaultWhiteAnchorEV).
        let highlightThreshold = 0.18 * pow(2.0, 5.0) / 2.0

        let halfW = Double(w) * 0.5
        let halfH = Double(h) * 0.5
        // Normalize so the frame corner sits at r = 1 regardless of aspect: Roundness 0 is
        // the ellipse inscribed in the crop rectangle.
        let norm = 1.0 / (2.0 as Double).squareRoot()

        var out = image
        for y in 0..<h {
            let v = (Double(y) + 0.5 - halfH) / Swift.max(halfH, 1e-6)
            for x in 0..<w {
                let u = (Double(x) + 0.5 - halfW) / Swift.max(halfW, 1e-6)
                let r = (u * u + v * v).squareRoot() * norm
                let falloff = Num.smoothstep(inner, outer, r)
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
