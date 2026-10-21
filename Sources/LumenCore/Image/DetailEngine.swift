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

    /// Post-crop vignette: Lightroom's six controls — Style, Amount, Midpoint, Roundness,
    /// Feather, Highlights — on scene-linear RGB before the display transform (docs/06
    /// §12), laid out on the CROP (`VignetteField`, shared with the GPU twin).
    ///
    /// Amount stays EV at the crop's corner: a −0.7 EV burn means the same thing on every
    /// exposure. The model, normative for both renderers (WS-41 SPEC "Model"):
    ///
    ///   · ρ, the roundness-dependent radius (`vignetteShape`, `vignetteRadius`), is 1 at
    ///     the four crop corners for every roundness and is the historical
    ///     `sqrt((u² + v²)/2)` at roundness 0;
    ///   · the share of Amount delivered at ρ is `smoothstep(c − s/2, c + s/2, ρ)`, with
    ///     the CENTRE c from Midpoint (`vignetteCentre`) and the WIDTH s from Feather
    ///     (`vignetteWidth`). Feather no longer moves the 50 % contour — that coupling
    ///     was the audit's F1 — and at (50, 50) the edges are exactly the historical
    ///     0.375 and 1;
    ///   · beyond the corner the profile is NOT renormalised, so the corner receives
    ///     `Amount · frac(1)` ≥ ½ when c + s/2 > 1. Renormalising would move the 50 %
    ///     contour with Feather again;
    ///   · each style turns (luminance, frac) into stops (`vignetteStops`), and Color
    ///     Priority additionally holds the colour (`vignetteChromaScale`).
    ///
    /// Every default reproduces the historical render to the bit, including the fixed
    /// half-strength highlight protection above scene Y 2.88 (`vignetteProtection`).
    ///
    /// The historical midpoint constant, kept because tests and the GPU's history name it.
    public static let vignetteMidpoint: Double = 0.5
    /// The legacy highlight protection's weight: the burn is halved, smoothly, between
    /// half the default scene white and the white itself. Applied at every Amount in
    /// Highlight Priority and at negative Amounts in Color Priority, exactly as it always
    /// was, which is what keeps the defaults byte-identical. The Highlights slider adds
    /// to it (`vignetteProtection`); it never replaces it.
    public static let vignetteHighlightProtection: Double = 0.5
    /// Scene mid-grey, the level every EV statement here is relative to.
    public static let vignetteMidGrey: Double = 0.18
    /// Where the legacy protection starts: half the default scene white (mid-grey + 5
    /// stops, `ToneEngine.defaultWhiteAnchorEV`). Spelled as the engine always spelled
    /// it so the Double is the same one.
    public static let vignetteLegacyThreshold: Double =
        vignetteMidGrey * pow(2.0, ToneEngine.defaultWhiteAnchorEV) / 2.0

    // Profile: centre and width.

    /// The 50 % contour at the default midpoint — the historical `smoothstep(0.375, 1, r)`
    /// has its middle here.
    public static let vignetteDefaultCentre: Double = 0.6875
    /// Midpoint 0 and 100. 0.25 reaches about the middle third of the frame; 0.95 keeps
    /// the burn in the corners and still gives the corner more than half of Amount.
    public static let vignetteCentreRange: ClosedRange<Double> = 0.25...0.95
    /// The transition width at the default feather: the historical 1 − 0.375.
    public static let vignetteDefaultWidth: Double = 0.625
    /// Feather 100: 0.608 half-diagonals from 10 % to 90 % — at least the historical
    /// widest (0.609 at the old feather 100) while the 90 % point still lies inside the
    /// corner at the default midpoint.
    public static let vignetteMaxWidth: Double = 1.0
    /// The width at feather 25. As wide as it can be while every 10 of feather above it
    /// still widens the 10-90 % span by at least 0.02 half-diagonals (0.0036 per unit).
    public static let vignetteQuarterFeatherWidth: Double = 0.535
    /// The width's slope (per unit of feather) at feather 10, where the gentle hard end
    /// hands over to the bump that reaches `vignetteQuarterFeatherWidth`.
    public static let vignetteFeatherLowSlope: Double = 0.015
    /// The narrowest the transition may be, in OUTPUT PIXELS measured along the gradient
    /// of ρ at the pixel itself: feather 0 is a hard edge anti-aliased over 0.608 × 2.5
    /// = 1.5 px (10-90 %) in every direction, on every crop aspect. It used to be 2.5 px
    /// of the crop's half-diagonal, which on the short axis of a 6:1 crop is 0.27 px —
    /// an aliased staircase (WS-41 VERIFY D4, SPEC line 29).
    public static let vignetteHardEdgePixels: Double = 2.5
    /// ρ below which the gradient is evaluated as if at this radius, so a superellipse's
    /// ρ^(1−n) cannot overflow at the centre, where no edge is ever drawn.
    public static let vignetteGradientRadiusFloor: Double = 1e-3
    /// The transition is never narrower than this in ρ, so the smoothstep's edges are
    /// always ordered (on the GPU, `smoothstep` is undefined for equal edges).
    public static let vignetteMinimumWidth: Double = 1e-6

    // Roundness.

    /// Superellipse exponent at roundness −100: a rounded rectangle whose edge midpoints
    /// sit at ρ = 2^(−1/8) = 0.917, so the band hugs the crop's sides.
    public static let vignetteSquarestExponent: Double = 8

    // Highlights (HP and CP, Amount < 0).

    /// The Highlights knee in EV relative to mid-grey: bright content starts to be held
    /// half a stop under mid-grey and is fully held two stops over it, measured on the
    /// scene-linear luminance arriving at S13 — so it follows Exposure, which is what a
    /// photographer's "bright" means at this point of the pipeline.
    public static let vignetteHighlightsKneeEV: ClosedRange<Double> = -0.5...2.0
    /// Below this a luminance is treated as this, so log2 never sees zero.
    public static let vignetteLuminanceFloor: Double = 1e-10

    // Color Priority.

    /// OKLab chroma scale per stop of burn, as a power of two: a −4 EV corner keeps
    /// 2^(−4·0.01) = 97 % of its scene chroma relative to lightness, which offsets the
    /// display transform's toe lifting C/L by up to 15 % on blues (WS-41 AUDIT F5). The
    /// scale is applied about the OKLab lightness axis, so the scene hue is held exactly.
    public static let vignetteColourBurnChroma: Double = 0.01
    /// OKLab chroma scale per stop of lift: what the display transform's path to white
    /// takes back, given back in scene-linear so a lifted sky stays blue (AUDIT F6). It
    /// is weighted by where the LIFTED pixel lands on `vignetteColourShoulderEV`, because
    /// the path to white only desaturates near white: a dark corner lifted to mid-grey
    /// keeps its chroma under HP already and must not be pushed past it.
    public static let vignetteColourLiftChroma: Double = 1.0
    /// OKLab chroma scale per stop of lift BELOW the shoulder, as 2^(−0.08·stops): a
    /// lifted mid-tone keeps its display chroma (the display transform raises it as it
    /// brightens) instead of overshooting it into a clipped channel.
    public static let vignetteColourLiftHold: Double = 0.08
    /// The lift key's fade from the brightest sRGB channel (below) to luminance (above),
    /// in EV over mid-grey (`vignetteLiftKey`).
    public static let vignetteColourKeyEV: ClosedRange<Double> = 0.8...1.5
    /// Paint Overlay's white: a lift paints toward it, so above it nothing is lifted and
    /// between mid-grey and it the lift tapers in log space (contrast compressed toward
    /// white). Below mid-grey a PO lift is exactly HP's — never more — so a near-black or
    /// negative-luminance pixel cannot be multiplied past 2^Amount (VERIFY-R2 D4, SPEC
    /// line 33: the old cover grew without bound as Y fell, ×2^14 at the floor). 2.5 EV
    /// over mid-grey is scene 1.02, about display white on the default transform.
    public static let vignettePaintWhiteEV: Double = 2.5
    /// The display shoulder, in EV over mid-grey of the lifted scene luminance, across
    /// which the lift's chroma restoration fades in.
    public static let vignetteColourShoulderEV: ClosedRange<Double> = 1.5...4.5
    /// A Color Priority LIFT rolls off above mid-grey over this many stops, down to
    /// `vignetteColourLiftFloor` of Amount, so bright corners are not lifted into the
    /// display's shoulder where no chroma survives. Mid-grey itself gets all of Amount,
    /// so on neutrals CP and HP agree.
    public static let vignetteColourLiftRolloffEV: Double = 3
    public static let vignetteColourLiftFloor: Double = 0.25

    /// Where the falloff starts, on the normalized radius whose 1 is the frame corner,
    /// for a recipe feather in 0…100 at the DEFAULT midpoint on an unbounded frame:
    /// `vignetteEdges(…).lower`. At feather 50 it is exactly the 0.375 both renderers
    /// carried as a constant while the geometry was fixed. Feather now sets a WIDTH
    /// around a fixed midpoint, so this falls from 0.6875 (feather 0, a hard edge at the
    /// midpoint) to 0.1875 (feather 100).
    public static func vignetteInnerRadius(feather: Double) -> Double {
        vignetteEdges(midpoint: Look.vignetteMidpointDefault, feather: feather,
                      pixelHalfDiagonal: .infinity).lower
    }

    /// The inner radius at the DEFAULT feather — 0.375. Neither renderer reads it.
    public static var vignetteInnerRadius: Double {
        vignetteInnerRadius(feather: Look.vignetteFeatherDefault)
    }

    /// The historical falloff, `smoothstep(inner, 1, r)`: the profile with its outer edge
    /// pinned at the corner. Kept as a named shape for the tests that measure it; the
    /// renderers call `vignetteProfile`.
    public static func vignetteFalloff(radius: Double, inner: Double) -> Double {
        Num.smoothstep(inner, 1.0, radius)
    }

    /// The 50 % contour's radius for a midpoint in 0…100: piecewise linear through
    /// (0, 0.25), (50, 0.6875) and (100, 0.95). Exactly 0.6875 at 50.
    public static func vignetteCentre(midpoint: Double) -> Double {
        let m = midpoint.isFinite ? Num.clamp(midpoint, 0, 100) : Look.vignetteMidpointDefault
        let d = (m - 50) / 50
        let span = d < 0 ? vignetteDefaultCentre - vignetteCentreRange.lowerBound
                         : vignetteCentreRange.upperBound - vignetteDefaultCentre
        return vignetteDefaultCentre + d * span
    }

    /// The transition's width in ρ (lower to upper edge of the smoothstep) for a feather
    /// in 0…100, before anti-aliasing. Defined by its SLOPE, which is continuous
    /// everywhere, so the width has no kink (SPEC line 34) — the round-2 curve met its
    /// linear segment at 25 with a 12× slope break:
    ///
    ///   · 0…10: slope rises as (f/10)² to `vignetteFeatherLowSlope` — the hard end is
    ///     gentle (line 30: a unit there moves the width at most ~2× the median unit);
    ///   · 10…25: a smooth bump (half a sine on top of a linear blend) that carries the
    ///     width to `vignetteQuarterFeatherWidth` at 25, wide enough that a −4 EV ramp
    ///     steps at most 1 code per pixel in 8-bit (line 21);
    ///   · 25…50: constant slope to exactly 0.625 at 50, the historical default;
    ///   · 50…100: slope rising linearly so the width reaches 1.0 at 100.
    public static func vignetteFeatherWidth(feather: Double) -> Double {
        let f = feather.isFinite ? Num.clamp(feather, 0, 100) : Look.vignetteFeatherDefault
        let quarter = vignetteQuarterFeatherWidth
        let mid = (vignetteDefaultWidth - quarter) / 25
        if f >= 50 {
            let top = 2 * (vignetteMaxWidth - vignetteDefaultWidth) / 50 - mid
            return vignetteDefaultWidth + mid * (f - 50) + (top - mid) * (f - 50) * (f - 50) / 100
        }
        if f >= 25 { return quarter + mid * (f - 25) }
        let low = vignetteFeatherLowSlope
        let atTen = low * 10 / 3
        if f >= 10 {
            let t = (f - 10) / 15
            let bump = (quarter - atTen - 15 * (mid + (low - mid) / 2)) * Double.pi / 30
            return atTen + 15 * (mid * t + (low - mid) * (t - t * t / 2)
                                 + bump * (1 - cos(Double.pi * t)) / Double.pi)
        }
        return low * f * f * f / 300
    }

    /// The width a pixel actually gets: the feather's, or `vignetteHardEdgePixels` output
    /// pixels along the local gradient of ρ (`vignetteRadiusGradient`), whichever is
    /// wider. At feather ≥ 1 on any real frame the feather's width wins and this is it
    /// exactly — at the default it is exactly 0.625.
    @inline(__always)
    public static func vignetteEffectiveWidth(_ width: Double, gradient: Double) -> Double {
        Swift.max(Swift.max(width, Swift.min(vignetteHardEdgePixels * gradient,
                                             vignetteDefaultWidth)),
                  vignetteMinimumWidth)
    }

    /// The width along a ray where |∇ρ| is one over the crop's half-diagonal (the
    /// diagonal of a crop at roundness 0, closely) — the analytic stand-in the tests and
    /// the tooltips quote. The renderers use `vignetteEffectiveWidth` per pixel.
    public static func vignetteWidth(feather: Double, pixelHalfDiagonal: Double) -> Double {
        vignetteEffectiveWidth(vignetteFeatherWidth(feather: feather),
                               gradient: 1 / Swift.max(pixelHalfDiagonal, 1))
    }

    /// The smoothstep's two edges, c ∓ s/2, with s from `vignetteWidth`.
    public static func vignetteEdges(midpoint: Double, feather: Double,
                                     pixelHalfDiagonal: Double)
        -> (lower: Double, upper: Double) {
        let c = vignetteCentre(midpoint: midpoint)
        let s = vignetteWidth(feather: feather, pixelHalfDiagonal: pixelHalfDiagonal)
        return (c - s / 2, c + s / 2)
    }

    /// The share of Amount delivered at radius ρ. NOT renormalised beyond the corner.
    @inline(__always)
    public static func vignetteProfile(radius: Double, lower: Double, upper: Double)
        -> Double {
        Num.smoothstep(lower, upper, radius)
    }

    /// The radius's shape for a roundness in −100…+100 on a crop with these half extents:
    /// a superellipse exponent and the weight of v. ρ = ((|u|ⁿ + w·|v|ⁿ)/(1 + w))^(1/n).
    ///
    ///   · −100…0: n rises geometrically from 2 to `vignetteSquarestExponent`, w = 1 —
    ///     the ellipse squares off toward a rounded rectangle on the crop's edges;
    ///   · 0: n = 2, w = 1 — the crop-aspect ellipse through the corners, historically;
    ///   · 0…+100: n = 2, w = (halfHeight/halfWidth)^(2r) — the aspect relaxes toward 1
    ///     and at +100 ρ is the pixel distance over the half-diagonal: a circle.
    /// Every one of them is 1 at the corners.
    public static func vignetteShape(roundness: Double, halfWidth: Double,
                                     halfHeight: Double) -> (exponent: Double, weight: Double) {
        let r = roundness.isFinite ? Num.clamp(roundness, -100, 100) / 100 : 0
        if r < 0 {
            return (2 * pow(vignetteSquarestExponent / 2, -r), 1)
        }
        if r > 0, halfWidth > 0, halfHeight > 0 {
            return (2, pow(halfHeight / halfWidth, 2 * r))
        }
        return (2, 1)
    }

    /// ρ at normalized delivered coordinates (u, v) for a shape from `vignetteShape`. At
    /// roundness 0 this is the historical expression, operation for operation.
    @inline(__always)
    public static func vignetteRadius(u: Double, v: Double, exponent: Double,
                                      weight: Double) -> Double {
        if exponent == 2 {
            if weight == 1 {
                return (u * u + v * v).squareRoot() * (1.0 / (2.0 as Double).squareRoot())
            }
            return ((u * u + weight * v * v) / (1 + weight)).squareRoot()
        }
        return pow((pow(abs(u), exponent) + weight * pow(abs(v), exponent)) / (1 + weight),
                   1 / exponent)
    }

    /// |∇ρ| per OUTPUT PIXEL at (u, v): the analytic derivative of `vignetteRadius`,
    /// ∂ρ/∂u = ρ^(1−n)·|u|^(n−1)/(1+w) and ∂ρ/∂v = ρ^(1−n)·w·|v|^(n−1)/(1+w), each divided
    /// by its half extent in pixels (u = Δx/halfWidth). The orientation is a rotation or
    /// a mirror, so one oriented unit is one output pixel in every direction.
    @inline(__always)
    public static func vignetteRadiusGradient(u: Double, v: Double, radius: Double,
                                              exponent: Double, weight: Double,
                                              halfWidth: Double, halfHeight: Double)
        -> Double {
        let rho = Swift.max(radius, vignetteGradientRadiusFloor)
        let q = pow(rho, 1 - exponent) / (1 + weight)
        let du = q * pow(abs(u), exponent - 1) / Swift.max(halfWidth, 1e-6)
        let dv = q * weight * pow(abs(v), exponent - 1) / Swift.max(halfHeight, 1e-6)
        return (du * du + dv * dv).squareRoot()
    }

    /// Everything the per-pixel transfer reads, resolved once per frame. The GPU kernel's
    /// uniforms are these numbers and nothing else (`RenderGraph.applyVignette`).
    public struct VignetteUniforms: Equatable, Sendable {
        /// Amount, clamped to `vignetteAmountRange`.
        public let amount: Double
        public let style: VignetteStyle
        /// The profile's centre (Midpoint) and its feather width, before anti-aliasing.
        public let centre: Double
        public let width: Double
        /// The crop's half extents in output pixels, for the gradient of ρ.
        public let halfWidth: Double
        public let halfHeight: Double
        public let exponent: Double
        public let weight: Double
        /// The legacy protection: starts at `threshold`, full `protection` at twice it.
        public let threshold: Double
        public let protection: Double
        /// Highlights as a fraction, and its knee as log2 scene luminance.
        public let highlights: Double
        public let kneeLow: Double
        public let kneeHigh: Double
        /// Color Priority: chroma per stop of burn / lift, and the lift's roll-off.
        public let burnChroma: Double
        public let liftChroma: Double
        public let log2MidGrey: Double
        public let liftRolloff: Double
        public let liftFloor: Double
        public let shoulderLow: Double
        public let liftHold: Double
        public let keyLow: Double
        public let keyHigh: Double
        public let shoulderHigh: Double
        /// Paint Overlay: the black and white anchors as log2 scene luminance, and the
        /// reciprocal of each one's distance from mid-grey.
        public let log2Black: Double
        public let burnSpanInverse: Double
        public let log2White: Double
        public let liftSpanInverse: Double
    }

    /// The uniforms for these settings over this field.
    public static func vignetteUniforms(_ s: VignetteSettings,
                                        field: VignetteField) -> VignetteUniforms {
        let amount = s.amount.isFinite
            ? Num.clamp(s.amount, vignetteAmountRange.lowerBound,
                        vignetteAmountRange.upperBound) : 0
        let shape = vignetteShape(roundness: s.roundness, halfWidth: field.halfWidth,
                                  halfHeight: field.halfHeight)
        let log2Mid = log2(vignetteMidGrey)
        let h = s.highlights.isFinite ? Num.clamp(s.highlights, 0, 100) / 100 : 0
        let log2Black = log2Mid + ToneEngine.defaultBlackAnchorEV
        let log2White = log2Mid + vignettePaintWhiteEV
        return VignetteUniforms(
            amount: amount, style: s.style,
            centre: vignetteCentre(midpoint: s.midpoint),
            width: vignetteFeatherWidth(feather: s.feather),
            halfWidth: field.halfWidth, halfHeight: field.halfHeight,
            exponent: shape.exponent, weight: shape.weight,
            threshold: vignetteLegacyThreshold, protection: vignetteHighlightProtection,
            highlights: h,
            kneeLow: log2Mid + vignetteHighlightsKneeEV.lowerBound,
            kneeHigh: log2Mid + vignetteHighlightsKneeEV.upperBound,
            burnChroma: vignetteColourBurnChroma, liftChroma: vignetteColourLiftChroma,
            log2MidGrey: log2Mid, liftRolloff: vignetteColourLiftRolloffEV,
            liftFloor: vignetteColourLiftFloor,
            shoulderLow: log2Mid + vignetteColourShoulderEV.lowerBound,
            liftHold: vignetteColourLiftHold,
            keyLow: log2Mid + vignetteColourKeyEV.lowerBound,
            keyHigh: log2Mid + vignetteColourKeyEV.upperBound,
            shoulderHigh: log2Mid + vignetteColourShoulderEV.upperBound,
            log2Black: log2Black, burnSpanInverse: 1 / (log2Mid - log2Black),
            log2White: log2White, liftSpanInverse: 1 / (log2White - log2Mid))
    }

    /// The share of the burn held back at a scene luminance (HP and CP). The legacy term
    /// at every Amount; for a NEGATIVE Amount the Highlights slider adds a monotone knee
    /// through `1 − (1 − legacy)(1 − held)`, which is continuous at Highlights 0 and
    /// nondecreasing in both luminance and Highlights. Being a share of a NEGATIVE
    /// exponent, it can only brighten brighter pixels more: no tone inversion.
    @inline(__always)
    public static func vignetteProtection(luminance lum: Double,
                                          _ k: VignetteUniforms) -> Double {
        let legacy = k.protection * Num.smoothstep(k.threshold, k.threshold * 2, lum)
        guard k.amount < 0, k.highlights > 0 else { return legacy }
        let held = k.highlights * Num.smoothstep(
            k.kneeLow, k.kneeHigh, log2(Swift.max(lum, vignetteLuminanceFloor)))
        return legacy + held * (1 - legacy)
    }

    /// The stops applied at a pixel of scene luminance `lum` receiving `falloff` of the
    /// profile. One switch per style, written line for line like the kernel.
    ///
    ///   · HP (and CP's burn): `amount · falloff · (1 − protection)` — historical;
    ///   · CP lift: `amount · falloff · lift(Y)`, all of Amount up to mid-grey and rolling
    ///     off to `liftFloor` over `liftRolloff` stops above it;
    ///   · PO: `amount · falloff · cover(Y)`, the log-space mix toward the black (burn) or
    ///     white (lift) anchor that lands mid-grey exactly where HP does: contrast in
    ///     stops shrinks by `amount/9` (burn) or `amount/5` (lift) — paint, not exposure.
    @inline(__always)
    public static func vignetteStops(luminance lum: Double, falloff: Double,
                                     _ k: VignetteUniforms, colour: RGB? = nil) -> Double {
        let ev = k.amount
        switch k.style {
        case .paintOverlay:
            let l2 = log2(Swift.max(lum, vignetteLuminanceFloor))
            let cover = ev < 0 ? Swift.max(l2 - k.log2Black, 0) * k.burnSpanInverse
                               : Swift.min(Swift.max(k.log2White - l2, 0) * k.liftSpanInverse,
                                           1)
            return ev * falloff * cover
        case .colorPriority where ev > 0:
            let key = colour.map { vignetteLiftKey($0, luminance: lum, k) } ?? lum
            let l2 = log2(Swift.max(key, vignetteLuminanceFloor))
            let lift = 1 - (1 - k.liftFloor)
                * Num.smoothstep(k.log2MidGrey, k.log2MidGrey + k.liftRolloff, l2)
            return ev * falloff * lift
        default:
            let protect = vignetteProtection(luminance: lum, k)
            return ev * falloff * (1 - protect)
        }
    }

    /// Color Priority's OKLab chroma scale for a pixel of luminance `lum` taking `stops`.
    /// Burn: a power of two in the stops. Lift: the same, faded in by where the lifted
    /// luminance lands on the display shoulder.
    @inline(__always)
    public static func vignetteChromaScale(stops: Double, luminance lum: Double,
                                           _ k: VignetteUniforms) -> Double {
        if k.amount < 0 { return pow(2.0, stops * k.burnChroma) }
        let lifted = log2(Swift.max(lum * pow(2.0, stops), vignetteLuminanceFloor))
        let shoulder = Num.smoothstep(k.shoulderLow, k.shoulderHigh, lifted)
        return pow(2.0, -stops * k.liftHold)
            * (1 + (pow(2.0, stops * k.liftChroma) - 1) * shoulder)
    }

    /// The working space's OKLab matrices, as the GPU kernel receives them: RGB → LMS,
    /// the lightness row of nonlinear LMS → Lab, and LMS → RGB.
    public static let vignetteColourRGBToLMS: Mat3 = OKLabTransform.working.rgbToLMS
    public static let vignetteColourLightnessRow: RGB = {
        let row = OKLabTransform.lmsToLab.m[0]
        return RGB(row[0], row[1], row[2])
    }()
    public static let vignetteColourLMSToRGB: Mat3 = OKLabTransform.working.lmsToRGB

    /// `c` with its OKLab chroma scaled by `phi` about its own lightness: hue and L held.
    /// Done in nonlinear LMS, where scaling (a, b) about L is `L + φ·(n − L)` because
    /// OKLab's chroma rows sum to zero. A channel that the scale would push below zero
    /// is held at zero (or at its own value if it was already negative).
    @inline(__always)
    public static func vignetteHoldColour(_ c: RGB, phi: Double) -> RGB {
        let lms = vignetteColourRGBToLMS.apply(c)
        let n = RGB(Num.spow(lms.r, 1.0 / 3.0), Num.spow(lms.g, 1.0 / 3.0),
                    Num.spow(lms.b, 1.0 / 3.0))
        let w = vignetteColourLightnessRow
        let lightness = w.r * n.r + w.g * n.g + w.b * n.b
        let m = RGB(lightness + phi * (n.r - lightness),
                    lightness + phi * (n.g - lightness),
                    lightness + phi * (n.b - lightness))
        let out = vignetteColourLMSToRGB.apply(RGB(m.r * m.r * m.r, m.g * m.g * m.g,
                                                   m.b * m.b * m.b))
        return vignetteFitGamut(out, floor: Swift.min(Swift.min(c.r, Swift.min(c.g, c.b)), 0))
    }

    /// `c` pulled straight toward its own luminance, in linear RGB, just far enough that
    /// no channel is below `floor` — luminance kept exactly, so a lift that pushed a
    /// saturated colour's minor channels negative can no longer DARKEN it.
    ///
    /// It replaced a per-channel clamp to zero, which threw the negative part away: on a
    /// bright red under the CP lift that removed luminance and turned the hue 12° in one
    /// 0.25 EV step (VERIFY-R2 D2, SPEC line 31). The straight line to the neutral of the
    /// same luminance is the closed-form answer — one division, no search — and the same
    /// arithmetic is the kernel's.
    @inline(__always)
    public static func vignetteFitGamut(_ c: RGB, floor: Double) -> RGB {
        let y = RGBColorSpace.rec2020.luminance(c)
        let lowest = Swift.min(c.r, Swift.min(c.g, c.b))
        guard lowest < floor, y - lowest > 1e-12 else { return c }
        let beta = Swift.max(y - floor, 0) / (y - lowest)
        return RGB(y + beta * (c.r - y), y + beta * (c.g - y), y + beta * (c.b - y))
    }

    /// Working (Rec.2020) linear → sRGB linear, for Color Priority's lift key: the
    /// display a picture is judged on is sRGB, and a colour near ITS gamut wall is the
    /// one a lift drives into a clipped channel.
    public static let vignetteWorkingToSRGB: Mat3 =
        RGBColorSpace.srgb.fromXYZ * RGBColorSpace.rec2020.toXYZ

    /// What a Color Priority LIFT rolls off on: luminance, raised toward the brightest
    /// sRGB channel for pixels that are not already bright. A saturated red at Y 0.15
    /// has an sRGB red of 0.62: lifted on luminance alone it took the full Amount and
    /// its red channel clipped on every pixel of the box (VERIFY D2). Bright pixels
    /// (from `vignetteColourKeyEV.upperBound` over mid-grey) keep the luminance key, so
    /// a sky still lifts by 60 % of HP's ΔL. Neutrals: the key IS luminance, so CP = HP.
    @inline(__always)
    public static func vignetteLiftKey(_ c: RGB, luminance lum: Double,
                                       _ k: VignetteUniforms) -> Double {
        let display = vignetteWorkingToSRGB.apply(c)
        let brightest = Swift.max(display.r, Swift.max(display.g, display.b))
        let bright = Num.smoothstep(k.keyLow, k.keyHigh,
                                    log2(Swift.max(lum, vignetteLuminanceFloor)))
        return lum + (1 - bright) * Swift.max(brightest - lum, 0)
    }

    /// The vignette at one pixel, or nil where it changes nothing.
    @inline(__always)
    public static func vignetteApply(_ c: RGB, falloff: Double,
                                     _ k: VignetteUniforms) -> RGB? {
        let space = RGBColorSpace.rec2020
        let lum = space.luminance(c)
        let stops = vignetteStops(luminance: lum, falloff: falloff, k, colour: c)
        if stops == 0 { return nil }
        let gain = pow(2.0, stops)
        guard k.style == .colorPriority else { return c * gain }
        let phi = vignetteChromaScale(stops: stops, luminance: lum, k)
        return vignetteHoldColour(c, phi: phi) * gain
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

    /// The historical entry point: Amount and Feather, every other control at its
    /// default, on the full frame.
    public static func vignette(_ image: ImageBuffer, ev: Double,
                                feather: Double = Look.vignetteFeatherDefault)
        -> ImageBuffer {
        vignette(image, VignetteSettings(amount: ev, feather: feather))
    }

    /// The vignette over `image`, laid out on `geometry`'s crop of it.
    ///
    /// `image` is the uncropped source at S13: the crop, straighten and flip only place
    /// the vignette (`VignetteField`), exactly as on the GPU, where `applyGeometry`
    /// selects the crop afterwards.
    public static func vignette(_ image: ImageBuffer, _ settings: VignetteSettings,
                                geometry: Geometry = Geometry()) -> ImageBuffer {
        let w = image.width
        let h = image.height
        let field = VignetteField(geometry: geometry, sourceWidth: Double(w),
                                  sourceHeight: Double(h))
        let k = vignetteUniforms(settings, field: field)
        guard k.amount != 0 else { return image }

        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let p = field.uv(column: x, row: y)
                let r = vignetteRadius(u: p.u, v: p.v, exponent: k.exponent,
                                       weight: k.weight)
                let g = vignetteRadiusGradient(u: p.u, v: p.v, radius: r,
                                               exponent: k.exponent, weight: k.weight,
                                               halfWidth: k.halfWidth,
                                               halfHeight: k.halfHeight)
                let s = vignetteEffectiveWidth(k.width, gradient: g)
                let falloff = vignetteProfile(radius: r, lower: k.centre - s / 2,
                                              upper: k.centre + s / 2)
                if falloff <= 0 { continue }
                guard let c = vignetteApply(image[x, y], falloff: falloff, k) else {
                    continue
                }
                out[x, y] = c
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
