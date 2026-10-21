// DetailEngine.swift
// Presence (S8: Texture / Clarity / Dehaze) and the two sharpening stages that bracket the
// pipeline (S4 capture, S12 manual), plus the S13 vignette — every one of them reading
// ONE cached base–detail decomposition.
//
// The structure is the feature (docs/14 §5.3, docs/06 §10.1). `Decomposition` is a pure
// function of the image, never of a slider: a guided-filter base, an à-trous stack, a
// local gradient-structure gate, the lazily-built presence log-luminance plane, and a
// lazily-built dark-channel transmission map. Dragging Texture, Clarity, or Dehaze
// re-weights planes that are cached or cheap to rebuild, and only an upstream WB/tone
// change rebuilds the node
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
//   · Texture and Clarity are difference-of-Gaussians bands of the detail ABOVE a
//     morphological base (open/close), which keeps every edge, corner and junction —
//     so none of them gets a rim, whatever its orientation (§ Presence).
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

/// The presence planes Texture and Clarity read, built on first use and shared by both,
/// so a recipe with both sliders set computes the log-luminance plane once. Same
/// single-render, single-threaded contract as `DehazeCache`.
fileprivate final class PresenceCache: @unchecked Sendable {
    var ev: Plane?
    init() {}
}

public struct DetailEngine: Sendable {

    public init() {}

    // MARK: - Tuning constants

    /// Number of à-trous scales. Level `i` carries ~`2^(i+1)` px of structure, so five
    /// levels span 2–64 px. The stack feeds manual sharpening's fine band (S12); Texture
    /// no longer reads it (see `textureBand`).
    public static let waveletLevels: Int = 5
    /// Guided-filter regularization for the base, in EV². √0.01 = 0.1 EV: anything flatter
    /// than a tenth of a stop across the window is one surface.
    public static let baseEpsilon: Double = 0.01

    // MARK: Presence (Texture / Clarity) — WS-14
    //
    // Both controls are one construction at two scales, and every number below is shared
    // with the GPU twin (`RenderGraph.applyDetailBands`) rather than restated there.
    //
    //   v     = presence log luminance, EV around mid-grey (`presenceEV`, LumenLog's toe)
    //   v'    = v (Texture); for Clarity v with features narrower than ~0.8·σ1 removed by
    //           an alternating open/close (`clarityPrefilter`): thin lines and specks
    //           are Texture's, not mid-scale contrast
    //   base  = (open(v') + close(v')) / 2 over a square of radius round(4·σ1)
    //           (`morphologicalBase`). Opening and closing leave every MONOTONE profile
    //           where it is — a step, a soft edge, a ramp, a corner of a square — and
    //           take away what is narrower than the square: texture, strands, pores,
    //           the mid-scale mottling Clarity is for
    //   d     = v' − base                    the detail; an isolated edge has none
    //   b     = G(σ1)·d − G(σ2)·d            the band; σ ∝ the long edge, never rounded
    //   B     = max(|b|, 2·G(σ2)·|b|)         the local peak of the band
    //   w     = 1 / (1 + (B/τ)^p)            range compression (· tone weight, Clarity)
    //   Δ     = k·a·b·w                      (Texture both signs; Clarity a > 0)
    //         = −min(1, |a|·k·w)·b            (Clarity a < 0: removes up to the whole
    //                                         band, never past it — no sign flip)
    //   Δ    −= log2(G(2^(γ(v+Δ))) / G(2^(γv))) / γ,  γ = 0.4   local brightness held
    //   out   = RGB · 2^clamp(Δ, ±4)          luma ratio: hue and chroma ratios fixed
    //
    // Why a morphological base and not an edge gate. A halo is the band's response on
    // the flat side of an ISOLATED step, where the picture has nothing at the band's
    // scale. The band of `d` has no such response, because the step is all in `base`;
    // the strokes of hair, a fine grating, weave and pores are narrower than the square
    // and all in `d`, whatever their orientation or contrast. Round 1 gated on the
    // orientation of a structure tensor instead, which also shut on a regular grating
    // and on dense parallel strands at normal contrast (spec S9).
    //
    // There is no image-global statistic anywhere. Every Gaussian is a continuous
    // fraction of the long edge; the morphology squares are whole pixels and so are
    // rounded (`presenceRadius`), the only rounded quantity, and a one-pixel step of a
    // square moves neither band: it only decides whether a feature exactly as wide as
    // the square counts as detail or as base.

    /// A presence band: a difference of Gaussians whose response peaks at `centreCPI`
    /// cycles per image long edge, applied to the detail above a morphological base, with
    /// a range compression on the band's local peak.
    public struct PresenceBand: Sendable, Equatable {
        /// Peak of the band's response, in cycles per image long edge.
        public let centreCPI: Double
        /// σ2 / σ1 of the difference of Gaussians.
        public let ratio: Double
        /// Radius of the morphological base's square, as a multiple of σ1.
        public let baseRatio: Double
        /// τ of the range compression, in EV of the band's local peak.
        public let rangeEV: Double
        /// Exponent p of the range compression `1 / (1 + (B/τ)^p)`.
        public let rangePower: Double

        public init(centreCPI: Double, ratio: Double, baseRatio: Double,
                    rangeEV: Double, rangePower: Double) {
            self.centreCPI = centreCPI
            self.ratio = ratio
            self.baseRatio = baseRatio
            self.rangeEV = rangeEV
            self.rangePower = rangePower
        }

        /// σ1 · f0 for a DoG with this ratio: the peak of
        /// `exp(−2π²σ1²f²) − exp(−2π²σ2²f²)` sits where `2π²σ1²f² = 2·ln(r)/(r² − 1)`.
        public var innerSigmaTimesPeak: Double {
            let r = ratio
            return (2 * log(r) / ((r * r - 1) * 2 * Double.pi * Double.pi)).squareRoot()
        }

        /// σ1 as a fraction of the long edge.
        public var innerFraction: Double { innerSigmaTimesPeak / centreCPI }

        /// The two blur scales, in pixels of a render whose long edge is `longEdge`.
        /// Continuous in the long edge: nothing here is rounded.
        public func sigmas(longEdge: Int) -> (inner: Double, outer: Double) {
            let l = Double(Swift.max(longEdge, 1))
            let inner = innerFraction * l
            return (inner, inner * ratio)
        }

        /// The morphological base's square radius at this long edge (whole pixels).
        public func baseRadius(longEdge: Int) -> Int {
            DetailEngine.presenceRadius(baseRatio * sigmas(longEdge: longEdge).inner)
        }

        /// The DoG's analytic response at `cpi` (0 at DC and at infinity), for tests.
        public func response(cpi: Double) -> Double {
            let f = cpi * innerFraction
            let a = 2 * Double.pi * Double.pi * f * f
            return exp(-a) - exp(-a * ratio * ratio)
        }

        /// The range compression's weight at a band peak `peak` (EV).
        public func compression(peak: Double) -> Double {
            1 / (1 + pow(Swift.max(peak, 0) / rangeEV, rangePower))
        }
    }

    /// Texture: centred on 750 cycles per image long edge — an 8 px period at 6000 px,
    /// i.e. 2–8 px features on a 24 MP file — one octave between σ1 and σ2, so the
    /// half-power band runs about 375–1500 cpi and leaves both the pixel level (noise)
    /// and the Clarity band alone. σ1 = 1.22 px at 6000, 0.33 px at 1600. The base's
    /// square is 4·σ1 in radius (5 px at 6000: features up to ~10 px wide are detail).
    /// τ = 0.25 EV with p = 4: a 0.3 EV strand or grating (band peak ≤ 0.13 EV) keeps
    /// ≥ 93 % of the gain, a −1.5 EV lash or a 4-stop line next to nothing.
    public static let textureBand = PresenceBand(centreCPI: 750, ratio: 2, baseRatio: 4,
                                                 rangeEV: 0.25, rangePower: 4)
    /// Clarity: centred on 60 cpi — a 100 px period at 6000 px, Lightroom's "radius of
    /// tens to about 150 px" — with σ2 = 4·σ1 (9.7 / 38.7 px at 6000), two octaves below
    /// Texture. The base's square is 4·σ1 (39 px at 6000, 10 px at 1600), so features up
    /// to about one band period wide are detail. τ = 0.2 EV, p = 2: mottling, clouds and
    /// foliage masses (band peaks 0.02–0.15 EV) take the slider; a one- or two-stop
    /// bar of a sign or a glyph, whose band peak is 0.3–1 EV, is held to a rim of a few
    /// codes (spec H8).
    public static let clarityBand = PresenceBand(centreCPI: 60, ratio: 4, baseRatio: 4,
                                                 rangeEV: 0.2, rangePower: 2)

    /// Texture's band gain per unit slider at the two signs. −100 removes up to
    /// 1.9·0.47 ≈ 89 % of the band at its centre, below 1/peak(band) = 2.12, so no
    /// frequency changes sign at any render size.
    public static let textureGainPositive: Double = 2.5
    public static let textureGainNegative: Double = 1.9
    /// Clarity's band gain per unit slider (positive), and the negative side's
    /// gain: −100 removes `1.3·w` of the band (capped at all of it), and a mask at
    /// Strength 200 up to `min(1, 2.6·w)` — never more than the whole band, so nothing
    /// can change sign, and where w < 0.77 a Strength above 100 still responds.
    public static let clarityGainPositive: Double = 1.95
    public static let clarityGainNegative: Double = 1.3
    /// Spread of the band's local peak: `B = max(|b|, presencePeakSpread·G(σ2)·|b|)`, so
    /// the flanks of a strong feature are compressed like the feature itself rather than
    /// like the weak band values they carry.
    public static let presencePeakSpread: Double = 2.0
    /// Clarity's prefilter radius as a multiple of σ1: lines and specks narrower than
    /// about 1.6·σ1 are removed (an opening and a closing, averaged both ways round)
    /// before Clarity measures local contrast, so a thin dark line does not read as a
    /// mid-scale dip that darkens its neighbours.
    public static let clarityPrefilterRatio: Double = 0.8
    /// Width in EV of Clarity's tone weight, a Gaussian on the morphological base around
    /// mid-grey, so the effect fades smoothly toward deep shadows and specular
    /// highlights and is continuous over tone (no reference levels, no image range).
    public static let clarityMidtoneEV: Double = 8.0
    /// Positive Clarity's slider shape: the amount `a` enters as `a·(1 + 0.4·a)`, so
    /// +50 lands near 0.43 and +25 near 0.2 of +100's effect (spec M3: 0.35–0.65 and
    /// 0.15–0.40). Negative Clarity is linear in `a`.
    public static let clarityPositiveCurvature: Double = 0.4

    /// The shaped positive amount (see `clarityPositiveCurvature`); `a` for a ≤ 0.
    public static func clarityShapedAmount(_ a: Double) -> Double {
        a > 0 ? a * (1 + clarityPositiveCurvature * a) : a
    }

    /// Local brightness: the exponent of the power mean the stage holds, and the
    /// window, as a multiple of σ2. A gain on log detail raises the linear mean
    /// (Jensen) and the display's tone curve turns that into a brighter picture;
    /// holding the local mean of Y^0.4 — close to what the display encodes — kept the
    /// 8 test photos within ±0.16 codes at ±100 in the design runs, where doing nothing
    /// moved them +0.6 / −0.4 and holding the LINEAR mean overshot to −1.0 / +0.6.
    public static let presenceMeanExponent: Double = 0.4
    public static let presenceMeanWindow: Double = 4.0
    /// The largest σ the 9-tap discrete Gaussian carries on its own (see `presenceBlur`).
    public static let presenceSmallSigma: Double = 2.0.squareRoot()

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
        /// Structure-tensor gradient magnitude in EV/px. Drives sharpening's edge mask and
        /// dehaze's sky floor.
        public let gradient: Plane
        /// 0 = isotropic mid-frequency texture (pores, noise-adjacent detail);
        /// 1 = a coherent high-contrast edge (eyelashes, jawline, horizon), at the
        /// working-radius scale and with the EV/px strength gate. Texture and Clarity do
        /// NOT read this one: they separate edges from detail with a morphological base
        /// at their own band (`presenceBand`), because a per-pixel strength gate means a
        /// different contrast at every render size.
        public let coherence: Plane

        /// The stage input, kept for the lazily-built dehaze primitives.
        public let source: ImageBuffer

        fileprivate let cache: DehazeCache
        fileprivate let presence: PresenceCache

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
            self.presence = PresenceCache()

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

            let structure = DetailEngine.structureTensor(logLum, radius: Swift.max(radius / 4, 1))
            self.gradient = structure.magnitude
            self.coherence = structure.coherence
        }

        /// The presence log-luminance plane (`DetailEngine.presenceEV` of the stage
        /// input's luminance), built once per decomposition and shared by Texture and
        /// Clarity — both read the PRE-Texture picture, like the GPU graph's one `lum`.
        public func presenceLogLuminance() -> Plane {
            if let ev = presence.ev { return ev }
            let lum = source.luminancePlane(space: space)
            let ev = lum.map { DetailEngine.presenceEV($0) }
            presence.ev = ev
            return ev
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

    /// Texture/Clarity controls retain their ±100 domain; a local mask can scale
    /// that resolved control up to 200%. Do not clamp again after multiplication.
    public static func scaledPresenceAmount(_ amount: Double, strength: Double = 1) -> Double {
        Num.clamp(amount, -100, 100) * Num.clamp(strength, 0, 2)
    }

    /// Texture: a gain on the 2–8 px@24 MP band (`textureBand`, 375–1500 cycles per
    /// image long edge) of the detail above a morphological base.
    ///
    ///   d = v − (open(v) + close(v))/2,   square radius round(4·σ1)
    ///   b = G(σ1)·d − G(σ2)·d,   σ1 = 0.153·L/750, σ2 = 2·σ1   (1.22 / 2.45 px at 6000)
    ///   Δ = k·a·b / (1 + (B/0.25)⁴),   B = max(|b|, 2·G(σ2)·|b|)
    ///
    /// with k = 2.5 for a > 0 and 1.9 for a < 0, then the local-brightness hold.
    ///
    /// The base keeps every monotone profile — a step of any height, a soft edge, the
    /// corner of a square — so positive Texture cannot rim an isolated edge and
    /// negative Texture cannot soften one; strands, gratings, weave and pores are
    /// narrower than the square and take the whole slider, whatever their orientation.
    /// Above the render's Nyquist the band simply does not exist, so at a small preview
    /// the visible part of the export's effect is what the preview shows, and −100 can
    /// never reverse a frequency: k·max(b) = 1.9·0.47 < 1 at every size.
    public static func applyTexture(_ image: ImageBuffer, amount: Double,
                                    strength: Double = 1,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = scaledPresenceAmount(amount, strength: strength) / 100
        guard a != 0 else { return image }
        let v = d.presenceLogLuminance()
        let longEdge = Swift.max(d.width, d.height)
        let planes = presenceBand(v, band: textureBand, longEdge: longEdge)
        var delta = Plane(width: v.width, height: v.height)
        for i in 0..<delta.values.count {
            delta.values[i] = Float(textureDelta(band: Double(planes.band.values[i]),
                                                 peak: Double(planes.peak.values[i]),
                                                 amount: a))
        }
        let s = textureBand.sigmas(longEdge: longEdge)
        holdLocalBrightness(&delta, v: v, window: presenceMeanWindow * s.outer)
        return applyLumaRatio(image, deltaEV: delta, limit: 4)
    }

    /// Texture's per-pixel law, shared by the reference and (spelt out in the kernel
    /// source) by the GPU: `k·a·b·w(B)`.
    public static func textureDelta(band b: Double, peak: Double, amount a: Double) -> Double {
        let k = a > 0 ? textureGainPositive : textureGainNegative
        return k * a * b * textureBand.compression(peak: peak)
    }

    // MARK: - Clarity

    /// Clarity: local contrast in the 20–160 cpi band (`clarityBand`, a 100 px period
    /// at 6000 px) of the mid-scale detail, continuous over tone.
    ///
    ///   v'   = (close(open(v)) + open(close(v))) / 2, square radius round(0.8·σ1)
    ///   base = (open(v') + close(v')) / 2,            square radius round(4·σ1)
    ///   b    = G(σ1)·(v' − base) − G(σ2)·(v' − base),  σ1 = 0.0968·L/60, σ2 = 4·σ1
    ///                                                  (9.7 / 38.7 px at 6000)
    ///   w    = exp(−base² / (2·8²)) / (1 + (B/0.2)²),  B = max(|b|, 2·G(σ2)·|b|)
    ///   Δ    = 1.95·a'·b·w,  a' = a(1 + 0.4a)      a > 0
    ///        = −min(1, |a|·1.3·w)·b                 a < 0
    ///   then the local-brightness hold.
    ///
    /// The pixel-level and Texture-scale detail is never touched — the prefilter takes
    /// thin lines and specks out of what Clarity measures, and the band starts at σ1 —
    /// which is why Clarity leaves pores and noise alone. Edges, corners and junctions
    /// of any contrast stay in the base, so neither sign rims, blurs or marks them; a
    /// soft blob narrower than the square is detail and gets local contrast, with no
    /// ring because the band of a smooth bump has none to speak of after compression.
    ///
    /// What this replaced, and why: a local Laplacian sampled at SIX reference levels
    /// spread over the image's global min..max (a 1.8×/0.6× comb over tone, a single
    /// black pixel moving every level, posterised soft gradients, a high-pass shelf
    /// that amplified noise, a rounded pyramid depth); then in round 1 a DoG gated by
    /// the orientation of a structure tensor, which marked corners and junctions where
    /// two orientations meet.
    public static func applyClarity(_ image: ImageBuffer, amount: Double,
                                    strength: Double = 1,
                                    decomposition d: Decomposition) -> ImageBuffer {
        let a = scaledPresenceAmount(amount, strength: strength) / 100
        guard a != 0 else { return image }
        let v = d.presenceLogLuminance()
        let longEdge = Swift.max(d.width, d.height)
        let s = clarityBand.sigmas(longEdge: longEdge)
        let prefiltered = clarityPrefilter(v, sigma: s.inner)
        let planes = presenceBand(prefiltered, band: clarityBand, longEdge: longEdge)
        var delta = Plane(width: v.width, height: v.height)
        for i in 0..<delta.values.count {
            delta.values[i] = Float(clarityDelta(band: Double(planes.band.values[i]),
                                                 peak: Double(planes.peak.values[i]),
                                                 base: Double(planes.base.values[i]),
                                                 amount: a))
        }
        holdLocalBrightness(&delta, v: v, window: presenceMeanWindow * s.outer)
        return applyLumaRatio(image, deltaEV: delta, limit: 4)
    }

    /// Clarity's per-pixel law.
    public static func clarityDelta(band b: Double, peak: Double, base: Double,
                                    amount a: Double) -> Double {
        let tone = exp(-(base * base) / (2 * clarityMidtoneEV * clarityMidtoneEV))
        let w = tone * clarityBand.compression(peak: peak)
        if a > 0 { return clarityGainPositive * clarityShapedAmount(a) * b * w }
        let s = Swift.min(1, -a * clarityGainNegative * w)
        return -s * b
    }

    /// A square window radius from a length in pixels: rounded, at least 1. The one
    /// rounded quantity in either control — a min/max window has to be a whole number
    /// of pixels — and `CIMorphologyRectangle*` gets the same `2r + 1`.
    public static func presenceRadius(_ length: Double) -> Int {
        Swift.max(Int(length.rounded()), 1)
    }

    /// Local brightness hold: `Δ −= log2(G(2^(γ(v+Δ))) / G(2^(γv))) / γ`, γ =
    /// `presenceMeanExponent`, G = `presenceBlur(window)`. The local mean of Y^γ is
    /// what the stage leaves where it found it.
    static func holdLocalBrightness(_ delta: inout Plane, v: Plane, window: Double) {
        let g = presenceMeanExponent
        var after = Plane(width: v.width, height: v.height)
        var before = Plane(width: v.width, height: v.height)
        for i in 0..<v.values.count {
            let e = Double(v.values[i])
            after.values[i] = Float(pow(2.0, g * (e + Double(delta.values[i]))))
            before.values[i] = Float(pow(2.0, g * e))
        }
        let num = presenceBlur(after, sigma: window)
        let den = presenceBlur(before, sigma: window)
        for i in 0..<delta.values.count {
            let n = Swift.max(Double(num.values[i]), 1e-30)
            let m = Swift.max(Double(den.values[i]), 1e-30)
            delta.values[i] = Float(Double(delta.values[i]) - log2(n / m) / g)
        }
    }

    /// Clarity's prefilter: an opening and a closing over a square of radius
    /// round(`clarityPrefilterRatio`·σ1), each followed by the other, averaged. Unlike
    /// the base's plain average, this removes a thin line or speck completely.
    public static func clarityPrefilter(_ v: Plane, sigma: Double) -> Plane {
        let r = presenceRadius(clarityPrefilterRatio * sigma)
        func erode(_ p: Plane) -> Plane { localExtremum(p, radius: r, maximum: false) }
        func dilate(_ p: Plane) -> Plane { localExtremum(p, radius: r, maximum: true) }
        let opened = dilate(erode(v))
        let closed = erode(dilate(v))
        let a = erode(dilate(opened))
        let b = dilate(erode(closed))
        return a.zip(b) { 0.5 * ($0 + $1) }
    }

    /// The morphological base: `(open(v) + close(v)) / 2` over a (2r+1)² square.
    /// Both leave a monotone profile exactly where it is (a step, a soft edge, a ramp, a
    /// convex corner), and between them take away anything narrower than the square.
    public static func morphologicalBase(_ v: Plane, radius r: Int) -> Plane {
        let eroded = localExtremum(v, radius: r, maximum: false)
        let dilated = localExtremum(v, radius: r, maximum: true)
        let opened = localExtremum(eroded, radius: r, maximum: true)
        let closed = localExtremum(dilated, radius: r, maximum: false)
        return opened.zip(closed) { 0.5 * ($0 + $1) }
    }

    /// The planes both controls read: the morphological base of `v`, the band `b` of
    /// the detail above it, and the band's local peak `B`.
    public static func presenceBand(_ v: Plane, band: PresenceBand, longEdge: Int)
        -> (base: Plane, band: Plane, peak: Plane) {
        let s = band.sigmas(longEdge: longEdge)
        let base = morphologicalBase(v, radius: band.baseRadius(longEdge: longEdge))
        let detail = v.zip(base) { $0 - $1 }
        let fine = presenceBlur(detail, sigma: s.inner)
        let coarse = presenceBlur(detail, sigma: s.outer)
        let b = fine.zip(coarse) { $0 - $1 }
        let spread = presenceBlur(b.map { abs($0) }, sigma: s.outer)
        let peak = b.zip(spread) { Swift.max(abs($0), presencePeakSpread * $1) }
        return (base, b, peak)
    }

    // MARK: - Presence primitives

    /// Presence log luminance: EV around mid-grey on LumenLog's axis (log2 above the
    /// shaper's linear toe at 0.18·2^−10.5, linear below it, negatives clamped to 0).
    /// The GPU's `RenderGraph.logLuminance` is `LumenLog.encode(max(Y, 0))`; this is the
    /// same number re-centred and in stops, so both paths threshold the same quantity.
    /// The old −20 EV `safeLog2` floor is gone with the global-range sampling it fed.
    public static func presenceEV(_ y: Double) -> Double {
        (LumenLog.encode(Swift.max(y, 0)) - LumenLog.encode(LumenLog.midGrey))
            * LumenLog.range
    }

    /// Nine taps of the discrete Gaussian kernel of variance `t` (Lindeberg's
    /// `e^−t·I_n(t)`), normalized over the taps kept. Unlike a sampled Gaussian it has
    /// the requested variance at ANY σ, sub-pixel included, and its response
    /// `exp(−2t·sin²(ω/2))` is a Gaussian in a warped frequency — so a difference of two
    /// of them is never larger than the continuous band's peak, which is what keeps
    /// −Texture from reversing the finest frequency of a small preview.
    public static func presenceKernel(variance t: Double) -> [Double] {
        let tv = Swift.max(t, 0)
        var weights = [Double](repeating: 0, count: 9)
        var total = 0.0
        for n in 0...4 {
            // I_n(t) by its power series; 40 terms is far past convergence for t ≤ 2.
            var term = pow(tv / 2, Double(n))
            var fact = 1.0
            if n > 0 { for k in 1...n { fact *= Double(k) } }
            term /= fact
            var sum = term
            if tv > 0 {
                for k in 1..<40 {
                    term *= (tv / 2) * (tv / 2) / (Double(k) * Double(k + n))
                    sum += term
                    if term < 1e-17 * sum { break }
                }
            }
            let w = exp(-tv) * sum
            weights[4 + n] = w
            weights[4 - n] = w
            total += n == 0 ? w : 2 * w
        }
        guard total > 0 else { return [0, 0, 0, 0, 1, 0, 0, 0, 0] }
        return weights.map { $0 / total }
    }

    /// The Gaussian blur both presence controls use, continuous in σ from 0 up:
    /// σ ≤ √2: one separable 9-tap discrete Gaussian of variance σ²;
    /// σ > √2: the 9-tap kernel of variance 1, then a Gaussian of σ' = √(σ² − 1)
    /// (`SpatialOps.gaussianBlur`: exact taps to σ' = 8, three boxes above). Variances
    /// add, so the result has variance σ² in both branches. The GPU twin is the same
    /// 9 taps through `CIConvolution9Horizontal/Vertical` and `CIGaussianBlur(σ')`.
    public static func presenceBlur(_ plane: Plane, sigma: Double) -> Plane {
        guard sigma > 0, sigma.isFinite else { return plane }
        if sigma <= presenceSmallSigma {
            return convolve9(plane, presenceKernel(variance: sigma * sigma))
        }
        let pre = convolve9(plane, presenceKernel(variance: 1))
        return SpatialOps.gaussianBlur(pre, sigma: (sigma * sigma - 1).squareRoot())
    }

    /// Separable 9-tap convolution with clamp-to-edge sampling.
    static func convolve9(_ plane: Plane, _ k: [Double]) -> Plane {
        let w = plane.width
        let h = plane.height
        var horizontal = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0..<9 { acc += k[t] * plane.clampedSample(x + t - 4, y) }
                horizontal[x, y] = acc
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0..<9 { acc += k[t] * horizontal.clampedSample(x, y + t - 4) }
                out[x, y] = acc
            }
        }
        return out
    }

    /// Running minimum or maximum over a (2r+1)² square, clamp-to-edge, separable —
    /// the twin of `CIMorphologyRectangleMinimum/Maximum` with width = height = 2r+1.
    /// van Herk / Gil-Werman: O(1) per pixel in r.
    static func localExtremum(_ plane: Plane, radius r: Int, maximum: Bool) -> Plane {
        guard r > 0 else { return plane }
        let pick: (Float, Float) -> Float = maximum ? { Swift.max($0, $1) } : { Swift.min($0, $1) }
        func pass(_ line: [Float]) -> [Float] {
            let n = line.count
            let win = 2 * r + 1
            // Padded line with clamp-to-edge.
            var padded = [Float](repeating: 0, count: n + 2 * r)
            for i in 0..<padded.count {
                padded[i] = line[Swift.min(Swift.max(i - r, 0), n - 1)]
            }
            let m = padded.count
            var forward = [Float](repeating: 0, count: m)
            var backward = [Float](repeating: 0, count: m)
            for i in 0..<m {
                forward[i] = i % win == 0 ? padded[i] : pick(forward[i - 1], padded[i])
            }
            var i = m - 1
            while i >= 0 {
                backward[i] = (i == m - 1 || (i + 1) % win == 0)
                    ? padded[i] : pick(backward[i + 1], padded[i])
                i -= 1
            }
            var out = [Float](repeating: 0, count: n)
            for x in 0..<n {
                // Window [x, x + win − 1] in padded coordinates.
                out[x] = pick(backward[x], forward[x + win - 1])
            }
            return out
        }
        let w = plane.width
        let h = plane.height
        var rows = Plane(width: w, height: h)
        for y in 0..<h {
            let line = Array(plane.values[(y * w)..<((y + 1) * w)])
            let o = pass(line)
            for x in 0..<w { rows.values[y * w + x] = o[x] }
        }
        var out = Plane(width: w, height: h)
        for x in 0..<w {
            var column = [Float](repeating: 0, count: h)
            for y in 0..<h { column[y] = rows.values[y * w + x] }
            let o = pass(column)
            for y in 0..<h { out.values[y * w + x] = o[y] }
        }
        return out
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
}
