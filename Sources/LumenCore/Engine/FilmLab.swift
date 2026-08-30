// FilmLab.swift
// The Film Lab's engine core (D18, docs/05-spec-color.md §Film Lab, docs/14 §5.7).
//
// A film stock is not a preset: it is a *model*. Three physical stages in series —
// negative characteristic curve → inversion (transmittance) → print characteristic
// curve — each a per-channel sigmoid in log-exposure→density space. Because the curve
// lives in log exposure, pre-curve EV overexposes *into the stock* (the pastel latitude
// of +1.5 EV into Portra) rather than merely brightening the picture, and because the
// image leaves each stage as density → transmittance, colour is inherently subtractive:
// saturated colours darken as they saturate. That is the whole "expensive film" trick,
// and no display-referred profile can express it.
//
// The equations (docs/14 §5.7, treated as measured physical facts, not expression):
//
//   D = Dmin + (Dmax − Dmin) · sigmoid( k · (log10 E + offset) )
//   k = γ / ( 0.25 · (Dmax − Dmin) )        ⇒ dD/dlog10E at mid-grey is exactly γ
//   T = 10^(−D)                              density → transmittance
//   mid-grey anchored at E = 0.18
//
// Placement (docs/14 §5.7, §2): when a stock is active the negative+print chain
// OCCUPIES the single S14 display-transform slot in place of the AgX-class sigmoid —
// one transform stage, parameterized, never two tone mappers in series. `FilmChain`
// therefore honours the same contract as `DisplayTransform.apply`: scene-linear in,
// display-linear out, with 1.0 = SDR white scaled by `displayWhite`.
//
// What is NOT here, by design: anything spatial. Halation is an S13 pre-curve blur and
// grain is a density-domain plate; both have global/neighbourhood support, so this file
// exposes their *parameters* (`HalationProfile`, `FilmGrainProfile`) and the image
// module owns the convolution and the sampling.
//
// Clean-room posture (docs/05 §Licensing, docs/17 ledger): implemented from the
// equations and constants above plus the primary literature they cite (Giorgianni &
// Madden; Hunt 6e ch. 15). No GPL reference implementation was consulted; the stock
// parameterizations below are Lumen's own interpretations, named as such.

import Foundation

/// Rec.2020 luma weights, resolved once — the monochrome stocks' scene→exposure rule.
private let filmLumaWeights: RGB = RGBColorSpace.rec2020.luminanceWeights

// MARK: - Characteristic curve

/// One stage's per-channel characteristic curve: the sigmoid's slope at mid-grey
/// (`gamma`, in density per decade of exposure), its density floor and ceiling, and a
/// per-channel horizontal trim of the log-exposure axis.
///
/// Per-channel divergence in `gamma` is what produces crossover — a cast that changes
/// sign between shadows and highlights — and per-channel `logOffset` slides the toe and
/// shoulder relative to the scene while leaving mid-grey where the chain's calibration
/// gains put it. Those two knobs are the entire colour personality of a stock.
public struct FilmCharacteristic: Sendable {

    /// `log10(0.18) + midGreyAnchor == 0`: scene mid-grey sits on the sigmoid's centre
    /// before any per-channel trim. (= −log10(0.18).)
    public static let midGreyAnchor: Double = 0.7447274948966939

    /// Density per decade of log exposure at mid-grey, per channel.
    public var gamma: RGB
    /// Base + fog. A colour negative's is the orange mask, hence non-neutral.
    public var dMin: RGB
    /// Maximum density the emulsion reaches.
    public var dMax: RGB
    /// Per-channel log10-exposure trim, added to the mid-grey anchor.
    public var logOffset: RGB

    public init(gamma: RGB,
                dMin: RGB = RGB(gray: 0.01),
                dMax: RGB = RGB(gray: 4.0),
                logOffset: RGB = RGB.zero) {
        self.gamma = gamma
        self.dMin = dMin
        self.dMax = dMax
        self.logOffset = logOffset
    }

    /// The sigmoid's steepness constant, `k = γ / (0.25·(Dmax − Dmin))`.
    public func k(_ channel: Int) -> Double {
        let i: Int = Swift.min(Swift.max(channel, 0), 2)
        let span: Double = Swift.max(dMax[i] - dMin[i], 1e-6)
        return gamma[i] / (0.25 * span)
    }
}

// MARK: - Crossover / colour couplers

/// The parts of a stock's colour that are not curve shape: the tonal crossover it
/// carries at rest, the direction it moves under push, and the two coupler mechanisms
/// that give film its hue skews.
///
/// Sign convention — tints are stated in the stock's OWN density domain. A
/// negative→print chain inverts twice, so a positive density offset prints as *more* of
/// that channel; a transparency inverts once, so a positive offset reads as *less*.
/// The stock tables below are authored with their own kind's sign in mind.
public struct FilmCrossover: Sendable {

    /// Density offset applied in the toe (weight 1 at the deepest shadow, 0 by mid-grey).
    public var shadowTint: RGB
    /// Density offset applied in the shoulder.
    public var highlightTint: RGB
    /// Additional shadow density offset per stop of push — the crossover colour a
    /// pushed stock walks its shadows toward.
    public var pushTint: RGB
    /// DIR inter-layer inhibition, 0…0.6. Developing silver in one layer releases an
    /// inhibitor that suppresses its neighbours, so channel densities spread apart from
    /// their mean: the source of film's chroma and of its edge micro-contrast.
    public var interlayer: Double
    /// Masking-coupler residue, −0.5…0.5: a small rotation of the density triple about
    /// the neutral axis. Row sums stay zero, so neutrals never move.
    public var coupler: Double

    public init(shadowTint: RGB = RGB.zero,
                highlightTint: RGB = RGB.zero,
                pushTint: RGB = RGB.zero,
                interlayer: Double = 0,
                coupler: Double = 0) {
        self.shadowTint = shadowTint
        self.highlightTint = highlightTint
        self.pushTint = pushTint
        self.interlayer = interlayer
        self.coupler = coupler
    }
}

// MARK: - Film stock

/// A deeply parameterized stock. Six at launch: 5–10 deep beats 60 shallow (D18).
///
/// These are Lumen's own interpretations, honestly named — they are built from our
/// datasheet digitization and the model above, not from anyone's emulsion samples, and
/// the display names say "Lumen" for exactly that reason.
public struct FilmStock: Sendable {

    public enum Kind: String, Sendable {
        /// Density rises with exposure; needs a print stage to become a picture.
        case negative
        /// Density falls with exposure; the transparency *is* the picture.
        case reversal
    }

    /// Recipe id, e.g. `"lumen/portra400"` — matches `FilmLab.stock`.
    public let id: String
    /// Display name for the stock cards.
    public let name: String
    public let kind: Kind
    /// True for B&W stocks: the exposure is the scene's Rec.2020 luma, and grain has no
    /// chromatic structure.
    public let monochrome: Bool

    /// The camera-stage curve.
    public let negative: FilmCharacteristic
    /// The paper / print-film stage, or nil for a transparency.
    public let printCurve: FilmCharacteristic?
    /// Display name of the paired print stock, if any.
    public let printName: String?

    public let crossover: FilmCrossover

    /// Per-channel halation strength before amount/redness. The measured RGB set is
    /// (0.05, 0.015, 0.0) — red-dominant because red penetrates to the film base and
    /// reflects, while the anti-halation layer kills the rest.
    public let halationStrength: RGB
    /// Stock's default halation Amount, 0…100 (0 for transparencies).
    public let halationDefault: Double
    /// Stock's default halation Redness, 0…100.
    public let halationRedness: Double

    /// Stock's default grain Amount, 0…100.
    public let grainDefault: Double
    /// Per-channel plate size scale. (0.8, 1.0, 2.0) RGB: the blue record is coarsest,
    /// which is why film grain is chromatically structured and a noise overlay is not.
    public let grainSizeScale: RGB
    /// Grain pitch at the gate, in µm, at `FilmGrain.size == 1`.
    public let grainPitchMicrons: Double

    /// Gate long edge in mm — 36 for 35mm stills, 24.9 for a Super 35 cine gate.
    /// The magnification denominator for both halation σ and grain pitch.
    public let gateLongEdgeMM: Double

    public init(id: String,
                name: String,
                kind: Kind,
                monochrome: Bool,
                negative: FilmCharacteristic,
                printName: String?,
                printCurve: FilmCharacteristic?,
                crossover: FilmCrossover,
                halationStrength: RGB,
                halationDefault: Double,
                halationRedness: Double,
                grainDefault: Double,
                grainSizeScale: RGB,
                grainPitchMicrons: Double,
                gateLongEdgeMM: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.monochrome = monochrome
        self.negative = negative
        self.printName = printName
        self.printCurve = printCurve
        self.crossover = crossover
        self.halationStrength = halationStrength
        self.halationDefault = halationDefault
        self.halationRedness = halationRedness
        self.grainDefault = grainDefault
        self.grainSizeScale = grainSizeScale
        self.grainPitchMicrons = grainPitchMicrons
        self.gateLongEdgeMM = gateLongEdgeMM
    }

    /// System gamma per channel: the log-log slope of scene → picture at mid-grey.
    /// Negative × print for a print chain, the emulsion's own γ for a transparency.
    public var systemGamma: RGB {
        guard let p = printCurve else { return negative.gamma }
        return RGB(negative.gamma.r * p.gamma.r,
                   negative.gamma.g * p.gamma.g,
                   negative.gamma.b * p.gamma.b)
    }

    // MARK: The launch six

    /// Wide latitude, low contrast, warm shadows and clean highlights — the portrait
    /// default. Divergence between the channel gammas is deliberately tiny: Portra's
    /// character is latitude, not crossover.
    public static let portra400: FilmStock = FilmStock(
        id: "lumen/portra400",
        name: "Lumen Portra 400",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.545, 0.550, 0.560),
                                     dMin: RGB(0.06, 0.14, 0.22),
                                     dMax: RGB(2.06, 2.14, 2.22),
                                     logOffset: RGB(0.000, 0.000, -0.010)),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.48, 2.48, 2.48),
                                       dMin: RGB(0.05, 0.06, 0.07),
                                       dMax: RGB(2.15, 2.20, 2.25),
                                       logOffset: RGB.zero),
        crossover: FilmCrossover(shadowTint: RGB(0.015, 0.005, -0.015),
                                 highlightTint: RGB(-0.005, 0.000, 0.010),
                                 pushTint: RGB(-0.020, 0.010, 0.025),
                                 interlayer: 0.14,
                                 coupler: 0.05),
        halationStrength: RGB(0.050, 0.015, 0.000),
        halationDefault: 35,
        halationRedness: 25,
        grainDefault: 45,
        grainSizeScale: RGB(0.8, 1.0, 2.0),
        grainPitchMicrons: 12.0,
        gateLongEdgeMM: 36.0)

    /// The consumer emulsion: steeper red than blue, so highlights run golden and
    /// shadows cool — a real crossover, authored rather than apologized for.
    public static let gold200: FilmStock = FilmStock(
        id: "lumen/gold200",
        name: "Lumen Gold 200",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.605, 0.590, 0.578),
                                     dMin: RGB(0.06, 0.14, 0.22),
                                     dMax: RGB(2.06, 2.14, 2.22),
                                     logOffset: RGB(0.012, 0.000, -0.016)),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.52, 2.50, 2.48),
                                       dMin: RGB(0.05, 0.06, 0.07),
                                       dMax: RGB(2.10, 2.15, 2.20),
                                       logOffset: RGB.zero),
        crossover: FilmCrossover(shadowTint: RGB(0.020, 0.006, -0.022),
                                 highlightTint: RGB(0.022, 0.010, -0.020),
                                 pushTint: RGB(-0.018, 0.012, 0.026),
                                 interlayer: 0.18,
                                 coupler: 0.09),
        halationStrength: RGB(0.060, 0.020, 0.000),
        halationDefault: 45,
        halationRedness: 35,
        grainDefault: 55,
        grainSizeScale: RGB(0.8, 1.0, 2.0),
        grainPitchMicrons: 14.0,
        gateLongEdgeMM: 36.0)

    /// Fine grain, high system gamma, strong inter-layer inhibition: saturation that
    /// arrives as density rather than as separation, which is why it darkens as it
    /// saturates instead of going neon.
    public static let ektar100: FilmStock = FilmStock(
        id: "lumen/ektar100",
        name: "Lumen Ektar 100",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.665, 0.665, 0.670),
                                     dMin: RGB(0.06, 0.14, 0.22),
                                     dMax: RGB(2.06, 2.14, 2.22),
                                     logOffset: RGB(-0.006, 0.000, 0.006)),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.50, 2.50, 2.50),
                                       dMin: RGB(0.05, 0.05, 0.06),
                                       dMax: RGB(2.20, 2.24, 2.28),
                                       logOffset: RGB.zero),
        crossover: FilmCrossover(shadowTint: RGB(-0.008, 0.000, 0.012),
                                 highlightTint: RGB(0.004, 0.000, 0.002),
                                 pushTint: RGB(-0.015, 0.008, 0.020),
                                 interlayer: 0.26,
                                 coupler: 0.06),
        halationStrength: RGB(0.030, 0.010, 0.000),
        halationDefault: 15,
        halationRedness: 15,
        grainDefault: 15,
        grainSizeScale: RGB(0.8, 1.0, 2.0),
        grainPitchMicrons: 7.0,
        gateLongEdgeMM: 36.0)

    /// Monochrome negative on a graded paper. No dye layers, so no chromatic grain
    /// structure and no red-dominant halation — the halo here is neutral.
    public static let triX400: FilmStock = FilmStock(
        id: "lumen/trix400",
        name: "Lumen Tri-X 400",
        kind: .negative,
        monochrome: true,
        negative: FilmCharacteristic(gamma: RGB(0.620, 0.620, 0.620),
                                     dMin: RGB(0.10, 0.10, 0.10),
                                     dMax: RGB(2.10, 2.10, 2.10),
                                     logOffset: RGB.zero),
        printName: "Lumen Grade 2 Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.35, 2.35, 2.35),
                                       dMin: RGB(0.06, 0.06, 0.06),
                                       dMax: RGB(2.20, 2.20, 2.20),
                                       logOffset: RGB.zero),
        crossover: FilmCrossover(shadowTint: RGB.zero,
                                 highlightTint: RGB.zero,
                                 pushTint: RGB.zero,
                                 interlayer: 0,
                                 coupler: 0),
        halationStrength: RGB(0.040, 0.040, 0.040),
        halationDefault: 20,
        halationRedness: 0,
        grainDefault: 70,
        grainSizeScale: RGB(1.0, 1.0, 1.0),
        grainPitchMicrons: 18.0,
        gateLongEdgeMM: 36.0)

    /// Transparency: one inversion, inside the emulsion, and no print stage. High
    /// gamma and a short exposure scale — the stock that punishes exposure error and
    /// rewards it. Halation is zero: slide stocks have an effective backing.
    public static let velvia50: FilmStock = FilmStock(
        id: "lumen/velvia50",
        name: "Lumen Velvia 50",
        kind: .reversal,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(1.720, 1.750, 1.800),
                                     dMin: RGB(0.12, 0.14, 0.16),
                                     dMax: RGB(3.40, 3.45, 3.50),
                                     logOffset: RGB(0.004, 0.000, -0.004)),
        printName: nil,
        printCurve: nil,
        crossover: FilmCrossover(shadowTint: RGB(0.020, 0.000, -0.020),
                                 highlightTint: RGB(-0.008, 0.000, 0.006),
                                 pushTint: RGB(0.014, -0.004, -0.012),
                                 interlayer: 0.30,
                                 coupler: 0.04),
        halationStrength: RGB.zero,
        halationDefault: 0,
        halationRedness: 0,
        grainDefault: 12,
        grainSizeScale: RGB(0.8, 1.0, 2.0),
        grainPitchMicrons: 6.0,
        gateLongEdgeMM: 36.0)

    /// Daylight cine negative through a print-film stage: a low-gamma camera stock
    /// carrying the whole scale, and a steep print that puts the contrast back. The
    /// gate is Super 35, so grain and halation are coarser per pixel than the stills
    /// stocks at the same scan resolution — as they are in reality.
    public static let cine250D: FilmStock = FilmStock(
        id: "lumen/cine250d",
        name: "Lumen Cine 250D",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.500, 0.505, 0.510),
                                     dMin: RGB(0.10, 0.20, 0.30),
                                     dMax: RGB(2.00, 2.10, 2.20),
                                     logOffset: RGB(0.000, 0.000, 0.008)),
        printName: "Lumen Print Film 2K",
        printCurve: FilmCharacteristic(gamma: RGB(2.62, 2.62, 2.62),
                                       dMin: RGB(0.06, 0.06, 0.07),
                                       dMax: RGB(2.60, 2.65, 2.70),
                                       logOffset: RGB.zero),
        crossover: FilmCrossover(shadowTint: RGB(-0.010, 0.000, 0.014),
                                 highlightTint: RGB(0.008, 0.004, -0.006),
                                 pushTint: RGB(-0.016, 0.010, 0.024),
                                 interlayer: 0.20,
                                 coupler: 0.07),
        halationStrength: RGB(0.050, 0.015, 0.000),
        halationDefault: 30,
        halationRedness: 20,
        grainDefault: 30,
        grainSizeScale: RGB(0.8, 1.0, 2.0),
        grainPitchMicrons: 10.0,
        gateLongEdgeMM: 24.9)

    public static let all: [FilmStock] = [
        FilmStock.portra400,
        FilmStock.gold200,
        FilmStock.ektar100,
        FilmStock.triX400,
        FilmStock.velvia50,
        FilmStock.cine250D
    ]

    private static let index: [String: FilmStock] = {
        var m: [String: FilmStock] = [:]
        for s in FilmStock.all { m[s.id.lowercased()] = s }
        return m
    }()

    /// Resolve a recipe's `stock` string. Accepts the full id (`"lumen/portra400"`)
    /// and, for convenience, the bare id (`"portra400"`). Unknown ids return nil and
    /// the chain falls back to the neutral rendering — an unrecognized stock must never
    /// silently become a different look.
    public static func named(_ id: String) -> FilmStock? {
        let key: String = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        if let s = FilmStock.index[key] { return s }
        if let s = FilmStock.index["lumen/" + key] { return s }
        return nil
    }
}

// MARK: - Halation

/// The S13 halation parameters for one stock at one image size (docs/14 §5.7).
///
/// Physics, and why the placement matters: the lens vignettes light before it strikes
/// the film, and halation is the film base reflecting that light back up through the
/// emulsion. Both therefore precede the characteristic curve — which is exactly why a
/// post-curve digital "glow" slider looks wrong no matter how it is tuned.
///
/// This type owns the *parameters* and the pointwise highlight-energy reconstruction.
/// The convolution is the image module's (quarter-res, upsampled; global support, so it
/// follows the proxy-field rule in tiled export — docs/14 §6.3).
public struct HalationProfile: Sendable {

    /// First-bounce sigma at gate scale, in µm, at Size = 1×.
    public static let firstSigmaMicrons: Double = 65.0
    /// Bounces summed. Radii go as σ₁·√k.
    public static let bounceCount: Int = 3
    /// Geometric decay between bounces.
    public static let bounceDecay: Double = 0.5
    /// Highlight reconstruction: stops of energy restored to a fully clipped sample.
    public static let boostRange: Double = 0.3
    /// Highlight reconstruction: EV below the clip at which the ramp reaches zero.
    public static let protectEV: Double = 4.0
    /// The physically measured per-channel strengths, RGB.
    public static let measuredStrength: RGB = RGB(0.05, 0.015, 0.0)

    /// Gaussian sigmas in pixels, σ_k = σ₁·√k, k = 1…3.
    public let sigmas: [Double]
    /// Bounce weights, `decay^(k−1)` — raw, so `strength` keeps its measured meaning.
    public let weights: [Double]
    /// Per-channel gain applied to the summed field: stock strength, blended toward
    /// pure red by Redness, scaled by Amount.
    public let strength: RGB
    /// Amount, normalized to 0…1.
    public let amount: Double
    /// Redness, normalized to 0…1.
    public let redness: Double
    /// Size multiplier, 0.5×…2×.
    public let sizeMultiplier: Double
    /// Geometric decay between bounces, carried per-instance so the spatial stage can
    /// walk `sigmas` and scale as it goes without reaching for a type constant.
    public let decay: Double
    /// Scene-linear level treated as the clip (seeded by S1's clipping mask).
    public let clipLevel: Double
    public let longEdgePixels: Int
    public let gateLongEdgeMM: Double

    public init(stock: FilmStock,
                amount: Double,
                size: Double = 1.0,
                redness: Double? = nil,
                longEdgePixels: Int,
                clipLevel: Double = 1.0) {
        let a: Double = Num.clamp(amount / 100.0, 0, 1)
        let sz: Double = Num.clamp(size, 0.5, 2.0)
        let red: Double = Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
        let gate: Double = Swift.max(stock.gateLongEdgeMM, 1e-3)
        let px: Int = Swift.max(longEdgePixels, 1)

        // 65 µm at the gate, expressed in pixels of this render.
        let sigma1: Double = (HalationProfile.firstSigmaMicrons / 1000.0) * sz / gate * Double(px)
        var sig: [Double] = []
        var w: [Double] = []
        var k: Int = 1
        while k <= HalationProfile.bounceCount {
            sig.append(sigma1 * Double(k).squareRoot())
            w.append(pow(HalationProfile.bounceDecay, Double(k - 1)))
            k += 1
        }
        self.sigmas = sig
        self.weights = w
        self.decay = HalationProfile.bounceDecay

        let base: RGB = stock.halationStrength
        let pureRed: RGB = RGB(base.r, 0, 0)
        self.strength = base.mix(pureRed, red) * a

        self.amount = a
        self.redness = red
        self.sizeMultiplier = sz
        self.clipLevel = Swift.max(clipLevel, 1e-6)
        self.longEdgePixels = px
        self.gateLongEdgeMM = gate
    }

    /// Nothing to convolve: no amount, or a stock with no measured strength.
    public var isIdentity: Bool {
        amount <= 0 || (strength.r <= 0 && strength.g <= 0 && strength.b <= 0)
    }

    public var weightSum: Double {
        var s: Double = 0
        for w in weights { s += w }
        return s
    }

    /// Bounce weights normalized to sum 1 — the form an energy-preserving blur set
    /// wants, so `strength` stays the only gain in the path.
    public var normalizedWeights: [Double] {
        let s: Double = weightSum
        guard s > 1e-12 else { return weights }
        var out: [Double] = []
        for w in weights { out.append(w / s) }
        return out
    }

    /// The energy that "penetrates to the base", per channel — the field the three
    /// Gaussians are convolved with.
    ///
    /// Reconstruction rule (the engine's reading of boost range 0.3 / protect 4.0 EV):
    /// a soft gate `t` opens across the last `protectEV` stops below the clip, so
    /// nothing four stops down contributes at all; at and above the clip the recorded
    /// value understates the true energy, so it is extended by up to `boostRange`
    /// stops. C¹ everywhere, and exactly zero over the protected range.
    public func highlightEnergy(_ c: RGB) -> RGB {
        var out: RGB = RGB.zero
        for i in 0..<3 {
            let e: Double = Swift.max(c[i], 0)
            guard e > 0 else { continue }
            let ev: Double = log2(e / clipLevel)
            let t: Double = Num.smoothstep(-HalationProfile.protectEV, 0, ev)
            guard t > 0 else { continue }
            out[i] = t * e * pow(2.0, HalationProfile.boostRange * t)
        }
        return out
    }

    /// The per-channel apply, once the image module has produced the blurred field:
    /// `out_c = in_c + strength_c · H_c`.
    public func combine(_ base: RGB, blurred: RGB) -> RGB {
        base + strength * blurred
    }

    // MARK: The GPU stand-in

    // The shader form of the reconstruction is a hard pedestal — `max(E − threshold, 0)
    // · boost` — because a smoothstep in log space is not worth a per-pixel `log2` in
    // the glow pass. The two are matched at the reference ramp's half-power point
    // rather than at its foot, which is where a linear stand-in and a smoothstep agree
    // best (docs/14 §1.4: the GPU kernel approximates this file, within tolerance).

    /// Scene-linear onset for the shader's pedestal.
    public var threshold: Double {
        clipLevel * pow(2.0, -HalationProfile.protectEV / 2.0)
    }

    /// Multiplier for the shader's pedestal — the reconstruction headroom.
    public var boost: Double {
        pow(2.0, HalationProfile.boostRange)
    }

    /// Per-channel strengths, under the name the spatial stage uses.
    public var strengths: RGB { strength }

    /// Blur radii in pixels, under the name the spatial stage uses.
    public var sigmasInPixels: [Double] { sigmas }
}

// MARK: - Grain

/// Density-domain grain (docs/14 §5.7), the model that makes grain *film* rather than
/// a noise overlay: it lives in density, its amplitude follows √(p(1−p)) so it peaks at
/// mid densities and vanishes at both Dmin and Dmax, and its pitch is denominated in
/// the print rather than in pixels.
public struct FilmGrainProfile: Sendable {

    /// The plate seed both render paths use.
    ///
    /// Named here because it was written twice with different values — the GPU plate
    /// used 0x5DEECE66D while the reference defaulted to this one — so the two paths
    /// produced different grain from the same recipe and no golden could ever compare
    /// it. Grain is meant to be deterministic for a given photo; two deterministic
    /// answers is the same problem as none.
    public static let defaultPlateSeed: UInt64 = 0x9E3779B97F4A7C15

    /// Density units of grain at Amount 100 and peak amplitude (p = 0.5).
    public static let densityScale: Double = 0.12

    /// How the unit-variance plate is packed into the texture the GPU samples:
    /// `stored = plate / plateEncodeScale + 0.5`, recovered as
    /// `(stored − 0.5) × plateEncodeScale`.
    ///
    /// Named once, here, because the two halves lived in different files and did not
    /// agree: the store used 0.25 and the kernel recovered with ×2, so the GPU saw HALF
    /// the amplitude the reference defines — grain was worth half as much on screen and
    /// in export as the golden said. The store also clamped to 0…1, which flattened the
    /// 3.4% of the plate beyond ±2σ, exactly the strongest grains.
    ///
    /// 8 keeps a 4σ plate inside 0…1 without clamping. The texture is `RGBAf`, so there
    /// is no precision cost to the headroom and no clamp is needed for a rare outlier.
    public static let plateEncodeScale: Double = 8.0
    /// The particle model's authored grain area, µm² — the plate generator's premise.
    public static let particleAreaMicronsSquared: Double = 0.2
    /// Long edge, in inches, when no print size is chosen.
    public static let defaultPrintLongEdgeInches: Double = 10.0

    /// Amount, normalized, after push scaling — may exceed 1 at +2 stops of push.
    public let amount: Double
    /// Per-channel plate size scale, (0.8, 1.0, 2.0) RGB for a colour stock.
    public let sizeScale: RGB
    /// Grain pitch at the gate, µm, after the recipe's Size and push scaling.
    public let pitchMicrons: Double
    /// Per-channel Dmax — the denominator of `p = D / Dmax`.
    public let dMax: RGB
    public let gateLongEdgeMM: Double
    /// Carried from the stock so grain can ask whether there are dye layers to be
    /// grainy independently. A monochrome negative has one emulsion, so its three
    /// channels must share a single noise field — three independent ones would put
    /// coloured speckle on a black-and-white photograph.
    public let monochrome: Bool
    /// The plate's octave persistence — the amplitude ratio between successive octaves
    /// of the value noise the plate sums. 0.5 for every film stock, which is the number
    /// `plate(size:seed:sigma:persistence:)` defaults to, so a stock's plate is
    /// bit-for-bit what it always was. The creative grain's Roughness moves it.
    public let persistence: Double

    /// The gate a CREATIVE grain's pitch is denominated on: 35 mm, long edge 36 mm.
    ///
    /// `plateScale` reaches pixels through pixels-per-gate-millimetre, so a pitch in
    /// micrometres is meaningless without a negative to sit on. There is no negative
    /// here, so one is named: 35 mm is the format the word "grain" means to most
    /// photographers, it is the gate of four of the six shipped stocks, and it makes the
    /// Size slider's numbers directly comparable with theirs. Anchoring at the gate
    /// rather than in pixels is what keeps a creative grain the same fraction of the
    /// picture on a 2560 px preview and a 6000 px export — the property
    /// `testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize` pins for the film path
    /// and which a pixel-denominated grain would have thrown away.
    public static let creativeGateLongEdgeMM: Double = 36.0

    /// The finest and coarsest pitch the Size slider reaches, µm at the gate.
    ///
    /// 7 µm at the bottom is about the finest grain in the shipped stocks — Velvia 50 is
    /// 6, Ektar 100 is 7 — so Size 0 is "as fine as a real emulsion gets" rather than an
    /// arbitrary small number. It also lands, not by accident but worth knowing, exactly
    /// on `plateScale`'s half-pixel floor at `RenderGraph.workingLongEdge`: 0.5 × 36000 ÷
    /// 2560 = 7.03 µm. Below that there is nothing for a preview to draw, and a slider
    /// whose bottom third rendered one identical picture would be the dead travel docs/19
    /// found three times.
    ///
    /// 56 µm at the top is coarser than any emulsion, deliberately. This is a creative
    /// control and Lightroom's Size 100 is chunky; a range that stopped at a real film's
    /// coarsest grain would be a physics lesson rather than a tool.
    public static let creativePitchMinMicrons: Double = 7.0
    public static let creativePitchMaxMicrons: Double = 56.0

    /// Size 0…100 → pitch in µm, geometric: `7 · 2^(3·size/100)`. The pitch doubles
    /// every 33 points, which is what makes the slider feel even — a pitch axis is a
    /// ratio axis, and a linear one would spend most of its travel between 7 and 10 µm
    /// where nothing separates and cross the whole visible range in its last quarter.
    /// The same argument `SliderScale.reciprocal` makes for Temp, one control over.
    public static func creativePitchMicrons(size: Double) -> Double {
        let s = Num.clamp(size, 0, 100) / 100
        return creativePitchMinMicrons
            * pow(creativePitchMaxMicrons / creativePitchMinMicrons, s)
    }

    /// Roughness 0…100 → the plate's octave persistence, `0.25 + 0.005·roughness`.
    ///
    /// 50 is 0.5, which is EXACTLY the persistence `plate(size:seed:sigma:)` has always
    /// used and therefore exactly the plate every film stock has always been given. That
    /// is not a coincidence to be tidied up later: it is what lets Roughness exist
    /// without changing one pixel of any film-grained photograph, and it is what makes
    /// the neutral of a new control a real neutral rather than a number somebody liked.
    public static func creativePersistence(roughness: Double) -> Double {
        0.25 + 0.005 * Num.clamp(roughness, 0, 100)
    }

    /// A creative grain's profile — the SAME struct the film path builds, filled from
    /// the three sliders instead of from an emulsion.
    ///
    /// Everything the stage reads is here: a normalized amount in the film path's own
    /// denomination, a pitch, a per-channel crystal size, a Dmax and a monochrome flag.
    /// The two that need an argument rather than a number:
    ///
    ///   · `sizeScale` is the colour stock's (0.8, 1.0, 2.0). Three physically separate
    ///     dye layers with their own crystals is most of what makes grain read as film
    ///     rather than as a noise overlay (`plateSeed(channel:)` says why at length), and
    ///     a creative grain that threw that away would be exactly the "luminance overlay
    ///     wearing film's amplitude envelope" this file already convicted itself of once.
    ///   · `monochrome` is the CALLER's, and the caller passes the recipe's
    ///     black-and-white treatment. Three decorrelated layers on a black-and-white
    ///     photograph is coloured speckle on a picture that has no colour — the same
    ///     defect Tri-X's `monochrome` flag exists to prevent, arriving through a
    ///     different door. There is no control for it because there is no question:
    ///     `look.bw.enabled` already says whether this photograph has dye layers to be
    ///     grainy independently.
    ///
    /// `dMax` is flat 4.0 across the three channels — `FilmChain.grainDMax`'s own
    /// stockless fallback, which is where the number comes from rather than from taste.
    /// It is the denominator of `p = D/Dmax` in the amplitude envelope, so it sets where
    /// the grain peaks: D = 2.0, one part in a hundred of display white, with the
    /// envelope vanishing at Dmin and at Dmax exactly as it does on film.
    public init(creative: CreativeGrain, monochrome: Bool) {
        self.amount = Num.clamp(creative.amount, 0, 100) / 100.0
        // ONE CRYSTAL SIZE AND ONE SEED — creative grain is LUMINANCE grain, and the
        // paragraph above arguing for three decorrelated dye layers is what the owner
        // tested. His verdict: "the grain is absolutely ridiculously bad. It just turns
        // into rainbow splotches. It looks like noise, not grain."
        //
        // He is right, and the reason the film path gets away with what this could not
        // is a number, not a principle. A stock's pitch is a few microns, so all three
        // of its layers land SUB-PIXEL at any preview resolution and average back into
        // something the eye reads as luminance with a hint of colour. `Size` here runs
        // to 56 µm by design, and the blue layer's 2.0x crystal doubles that again: at a
        // 36 mm gate on a laptop preview that is an eight-pixel blob of pure blue beside
        // a one-pixel red one, three times over with independent seeds. Rainbow
        // splotches is an exact description of that arithmetic.
        //
        // Equalizing the crystal sizes alone would not have fixed it: independent seeds
        // per channel ARE the colour, whatever size they are drawn at. So the layers
        // collapse to one field, which is also what a photographer means by a grain
        // slider — dye-layer structure is a property of a named emulsion, and it stays
        // where the emulsion's own pitch keeps it honest.
        self.sizeScale = RGB(1, 1, 1)
        self.pitchMicrons = Swift.max(
            FilmGrainProfile.creativePitchMicrons(size: creative.size), 0.1)
        self.dMax = RGB(gray: FilmGrainProfile.creativeDMax)
        self.gateLongEdgeMM = FilmGrainProfile.creativeGateLongEdgeMM
        // True for a colour photograph too: this flag selects ONE plate and one seed
        // (`plateSeed`), which is exactly the luminance grain argued for above — and it
        // is a third of the plate work as a side effect. The parameter is kept because
        // the caller genuinely knows whether the photograph is black-and-white and a
        // later chroma component, if one is ever argued for, needs to ask.
        _ = monochrome
        self.monochrome = true
        self.persistence = FilmGrainProfile.creativePersistence(
            roughness: creative.roughness)
    }

    /// The stockless Dmax, kept where `FilmChain.grainDMax` can be read beside it.
    public static let creativeDMax: Double = 4.0

    public init(stock: FilmStock, size: Double, amount: Double, pushPull: Double) {
        let push: Double = Num.clamp(pushPull, -1, 2)
        // Push scales grain amount and plate scale together — one slider, coherent
        // consequences (docs/05 §Push/Pull).
        let amountScale: Double = Swift.max(1.0 + 0.35 * push, 0)
        let pitchScale: Double = Swift.max(1.0 + 0.15 * push, 0.05)
        self.amount = Num.clamp(amount / 100.0, 0, 1) * amountScale
        self.sizeScale = stock.grainSizeScale
        self.pitchMicrons = Swift.max(stock.grainPitchMicrons * Swift.max(size, 0.05) * pitchScale, 0.1)
        self.dMax = stock.negative.dMax
        self.gateLongEdgeMM = Swift.max(stock.gateLongEdgeMM, 1e-3)
        self.monochrome = stock.monochrome
        // The plate a stock has always been given. Written as the named default rather
        // than as 0.5 so that if the plate's own default ever moves, the emulsions move
        // with it instead of silently keeping a number that used to be the default.
        self.persistence = FilmGrainProfile.defaultPersistence
    }

    /// The seed for one emulsion layer's plate.
    ///
    /// Colour film's three dye layers are physically separate, with their own crystals,
    /// so their grain is uncorrelated — that decorrelation is most of what makes film
    /// grain read as film rather than as a noise overlay laid over the picture, and
    /// docs/05 says so. Both render paths wrote ONE noise value into all three
    /// channels, which is a luminance overlay wearing film's amplitude envelope.
    ///
    /// A monochrome stock returns the base seed for every channel, so its layers stay
    /// perfectly correlated and the grain has no colour. `stock.monochrome` is the test
    /// rather than "are the three grain sizes equal": those coincide for the stocks
    /// shipped today, but a colour stock whose layers happened to share a crystal size
    /// would silently lose its chromatic structure under the size test.
    public func plateSeed(channel: Int,
                          base: UInt64 = FilmGrainProfile.defaultPlateSeed) -> UInt64 {
        guard !monochrome else { return base }
        let i = UInt64(Swift.min(Swift.max(channel, 0), 2))
        // The golden-ratio constant is the same one the lattice hash uses; the point is
        // only that three seeds are far apart in the generator's state space.
        return base &+ i &* 0x9E3779B97F4A7C15
    }

    public var isIdentity: Bool { amount <= 0 }

    /// Grain amplitude, in density units, at a given density.
    /// `A(p) = amount · scale · √(p(1−p))`, `p = D / Dmax` — zero at Dmin and at Dmax.
    public func amplitude(density: Double, channel: Int) -> Double {
        let i: Int = Swift.min(Swift.max(channel, 0), 2)
        let dm: Double = Swift.max(dMax[i], 1e-6)
        let p: Double = Num.clamp(density / dm, 0, 1)
        return amount * FilmGrainProfile.densityScale * (p * (1 - p)).squareRoot()
    }

    /// Enlargement factor from the gate to the print.
    public func magnification(printSizeInches: Double) -> Double {
        let printLongEdgeMM: Double = Swift.max(printSizeInches, 0.1) * 25.4
        return printLongEdgeMM / gateLongEdgeMM
    }

    /// Plate cell size in pixels, anchored to the print.
    ///
    /// The chain is: pitch at the gate → pitch on the print (×magnification) → pixels
    /// (×the render's pixels-per-print-mm). The print size appears in both factors and
    /// cancels — and that cancellation IS the print-size anchoring: ask for a bigger
    /// print from the same pixels and the grain keeps its pixel footprint, because the
    /// enlargement and the print's pixel density scale together. Change the *gate*
    /// (35mm → Super 35 → 120) and it moves, exactly as it does in a darkroom.
    public func plateScale(longEdgePixels: Int, printSizeInches: Double) -> Double {
        let printLongEdgeMM: Double = Swift.max(printSizeInches, 0.1) * 25.4
        let mag: Double = printLongEdgeMM / gateLongEdgeMM
        let pitchOnPrintMM: Double = (pitchMicrons / 1000.0) * mag
        let pixelsPerPrintMM: Double = Double(Swift.max(longEdgePixels, 1)) / printLongEdgeMM
        return Swift.max(pitchOnPrintMM * pixelsPerPrintMM, 0.5)
    }

    /// The long edge to hand `plateScale` for a file that has been CROPPED, RESIZED,
    /// or both on its way out.
    ///
    /// `plateScale` reaches pixels through pixels-per-gate-millimetre, so the long edge
    /// it takes is assumed to span the whole gate. A delivered file often does not, and
    /// the two ways of losing pixels are not the same:
    ///
    ///   - a RESIZE keeps the same piece of negative and puts fewer pixels on it, so
    ///     the grain's pixel footprint shrinks with them;
    ///   - a CROP keeps fewer pixels AND less negative, and those cancel exactly. The
    ///     footprint does not move. In a darkroom the crop is enlarged more and the
    ///     grain gets coarser ON THE PRINT — which is the same statement, since the
    ///     print's pixel density rose by the same factor.
    ///
    /// So the answer is `decode × delivered ÷ cropped`: the delivered long edge for an
    /// uncropped frame, and the decode's own for a native-size export of a crop. It
    /// lives in LumenCore rather than beside the export that uses it because it is
    /// arithmetic, it is easy to get backwards, and it was got backwards once.
    public static func plateLongEdge(decodeLongEdge: Int, croppedLongEdge: Int,
                                     deliveredLongEdge: Int) -> Int {
        guard decodeLongEdge > 0, croppedLongEdge > 0, deliveredLongEdge > 0 else {
            return Swift.max(deliveredLongEdge, 1)
        }
        let scaled: Double = Double(decodeLongEdge) * Double(deliveredLongEdge)
            / Double(croppedLongEdge)
        guard scaled.isFinite, scaled >= 1 else { return Swift.max(deliveredLongEdge, 1) }
        return Swift.max(Int(scaled.rounded()), 1)
    }

    /// Per-channel plate cell size in pixels — the blue record is coarsest.
    public func plateScale(longEdgePixels: Int, printSizeInches: Double, channel: Int) -> Double {
        let i: Int = Swift.min(Swift.max(channel, 0), 2)
        let base: Double = plateScale(longEdgePixels: longEdgePixels, printSizeInches: printSizeInches)
        return Swift.max(base * Swift.max(sizeScale[i], 0.05), 0.5)
    }

    /// Parse a `FilmLab.printSize` string (`"8x10"`, `"16 x 24"`, `"11X14"`) into its
    /// long edge in inches. nil or unparseable falls back to the long-edge default.
    public static func printLongEdgeInches(_ spec: String?) -> Double {
        guard let spec = spec else { return FilmGrainProfile.defaultPrintLongEdgeInches }
        let lowered: String = spec.lowercased()
        let parts: [Substring] = lowered.split(whereSeparator: { $0 == "x" || $0 == "*" })
        var longest: Double = 0
        for p in parts {
            let cleaned: String = String(p).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"in'"))
            if let v = Double(cleaned), v > 0, v.isFinite { longest = Swift.max(longest, v) }
        }
        return longest > 0 ? longest : FilmGrainProfile.defaultPrintLongEdgeInches
    }

    // MARK: Plate generation

    /// A deterministic, tileable, unit-variance noise plate — `size × size` values, row
    /// major, standard deviation `sigma`, mean 0.
    ///
    /// Value noise (a hashed integer lattice with C¹ Hermite interpolation) summed over
    /// four octaves at the given persistence, then rescaled to exact zero mean and the
    /// requested standard deviation. Every lattice index is taken modulo its octave's
    /// frequency, so the plate wraps seamlessly and can be tiled across an image of any
    /// size. The generator is a pure function of `(size, seed, sigma, persistence)` — no
    /// `arc4random`, no `Double.random`, no global state — so a render is reproducible
    /// bit-for-bit on any machine, which is what makes grain part of the recipe rather
    /// than part of the weather.
    ///
    /// `persistence` is the amplitude ratio between successive octaves, and it is the
    /// creative grain's Roughness. It DEFAULTS to the 0.5 that was hard-coded here for
    /// the plate's whole life, so every existing caller — the reference renderer's film
    /// path, the GPU plate builder, every golden that compares them — produces the same
    /// bytes it always did. That is the point of adding a parameter rather than a second
    /// generator: one plate, one set of goldens, and a new control that cannot drift from
    /// the old one because there is nothing for it to drift from.
    ///
    /// The renormalization at the end is what makes Roughness a character control rather
    /// than a second strength: the summed octaves are rescaled to the requested standard
    /// deviation whatever the persistence was, so moving Roughness redistributes the
    /// energy across scales and leaves the amplitude alone.
    public static let defaultPersistence: Double = 0.5

    public static func plate(size: Int, seed: UInt64, sigma: Double,
                             persistence: Double = FilmGrainProfile.defaultPersistence)
        -> [Float] {
        let n: Int = Swift.max(size, 2)
        let count: Int = n * n
        guard sigma.isFinite, sigma > 0 else { return [Float](repeating: 0, count: count) }
        var acc: [Double] = [Double](repeating: 0, count: count)

        let octaves: Int = 4
        // Clamped, not trusted: this is a recipe-derived number, and a persistence of 0
        // would leave one octave standing while a negative one would alternate the sign
        // of every other octave — neither is a grain, and a hand-edited sidecar can say
        // either. The bounds are the Roughness slider's own ends.
        let p: Double = Num.clamp(persistence.isFinite ? persistence : 0.5, 0.05, 0.95)
        let baseFrequency: Int = Swift.max(1, n / 16)
        var octave: Int = 0
        while octave < octaves {
            var freq: Int = baseFrequency << octave
            if freq > n { freq = n }
            if freq < 1 { freq = 1 }
            let amp: Double = pow(p, Double(octave))
            let step: Double = Double(freq) / Double(n)

            var y: Int = 0
            while y < n {
                let py: Double = Double(y) * step
                let yi: Int = Int(py)
                let ty: Double = py - Double(yi)
                let y0: Int = yi % freq
                let y1: Int = (y0 + 1) % freq
                let sy: Double = ty * ty * (3.0 - 2.0 * ty)

                var x: Int = 0
                while x < n {
                    let px: Double = Double(x) * step
                    let xi: Int = Int(px)
                    let tx: Double = px - Double(xi)
                    let x0: Int = xi % freq
                    let x1: Int = (x0 + 1) % freq
                    let sx: Double = tx * tx * (3.0 - 2.0 * tx)

                    let v00: Double = FilmGrainProfile.latticeValue(x0, y0, seed, octave)
                    let v10: Double = FilmGrainProfile.latticeValue(x1, y0, seed, octave)
                    let v01: Double = FilmGrainProfile.latticeValue(x0, y1, seed, octave)
                    let v11: Double = FilmGrainProfile.latticeValue(x1, y1, seed, octave)
                    let a: Double = v00 + (v10 - v00) * sx
                    let b: Double = v01 + (v11 - v01) * sx
                    acc[y * n + x] += amp * (a + (b - a) * sy)
                    x += 1
                }
                y += 1
            }
            octave += 1
        }

        // Exact unit variance by measurement, not by trusting the octave arithmetic.
        var mean: Double = 0
        for v in acc { mean += v }
        mean /= Double(count)
        var variance: Double = 0
        for v in acc {
            let d: Double = v - mean
            variance += d * d
        }
        variance /= Double(count)
        let sd: Double = variance.squareRoot()
        let gain: Double = sd > 1e-12 ? sigma / sd : 0

        var out: [Float] = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = Float((acc[i] - mean) * gain) }
        return out
    }

    /// Bilinear, wrapping sample of a plate produced by `plate(size:seed:sigma:)`.
    /// Coordinates are in plate cells and may be any finite value.
    public static func sample(_ values: [Float], size: Int, x: Double, y: Double) -> Double {
        let n: Int = Swift.max(size, 1)
        guard values.count >= n * n, x.isFinite, y.isFinite else { return 0 }
        // Clamp in Double before converting: past 2^53 the modulo loses all precision
        // and leaves `fx` outside [0, n), which `Int()` would take before the clamp.
        let fx: Double = Num.clamp(x - (x / Double(n)).rounded(.down) * Double(n),
                                   0, Double(n) - 1e-9)
        let fy: Double = Num.clamp(y - (y / Double(n)).rounded(.down) * Double(n),
                                   0, Double(n) - 1e-9)
        let x0: Int = Swift.min(Swift.max(Int(fx), 0), n - 1)
        let y0: Int = Swift.min(Swift.max(Int(fy), 0), n - 1)
        let x1: Int = (x0 + 1) % n
        let y1: Int = (y0 + 1) % n
        let tx: Double = fx - Double(x0)
        let ty: Double = fy - Double(y0)
        let v00: Double = Double(values[y0 * n + x0])
        let v10: Double = Double(values[y0 * n + x1])
        let v01: Double = Double(values[y1 * n + x0])
        let v11: Double = Double(values[y1 * n + x1])
        let a: Double = v00 + (v10 - v00) * tx
        let b: Double = v01 + (v11 - v01) * tx
        return a + (b - a) * ty
    }

    /// SplitMix64-style avalanche of the lattice coordinate, seed and octave into
    /// [−1, 1]. Pure integer arithmetic; identical on every platform.
    private static func latticeValue(_ x: Int, _ y: Int, _ seed: UInt64, _ octave: Int) -> Double {
        var z: UInt64 = seed &+ 0x9E3779B97F4A7C15
        z = z &+ (UInt64(bitPattern: Int64(x)) &* 0xD1B54A32D192ED03)
        z = z &+ (UInt64(bitPattern: Int64(y)) &* 0xABC98388FB8FAC03)
        z = z &+ (UInt64(octave + 1) &* 0x8CB92BA72F3D8DD7)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let unit: Double = Double(z >> 11) * (1.0 / 9007199254740992.0)
        return unit * 2.0 - 1.0
    }
}

// MARK: - The grain stage, resolved

/// Everything the grain stage needs, resolved once by the plan, so that neither renderer
/// has to know where the grain came from.
///
/// THIS TYPE IS THE FIX FOR A SHAPE, not just a place to hang three numbers. Grain used
/// to be gated on `plan.filmChain` in four places — `ReferenceRenderer.render`,
/// `RenderGraph.build`, and both of `PipelineRenderer`'s plate call sites — so "is there
/// grain on this photograph" was a question four files answered independently by asking
/// about a film chain. Adding a second source of grain to that shape means adding a
/// second condition to four places and hoping they stay in step, which is the exact
/// arrangement `plateSeed`, `plateEncodeScale` and `defaultPlateSeed` each have a
/// paragraph in this file about surviving. So the question is answered once, here, and
/// both renderers read the answer.
///
/// The precedence is deliberate and it is stated in one line of `RenderPlan`: **a live
/// film chain's grain wins.** A stock's grain is a property of the emulsion the
/// photographer chose, it is already exposed in two panels, and every recipe in every
/// catalog renders through it — so making the new field able to override it would change
/// existing pictures, and making the two STACK would put two independent noise fields on
/// one photograph at twice the cost. The creative grain is what renders when there is no
/// chain, which is every photograph without a stock and also the one case that used to be
/// a dead end: Film Lab Strength at 0, where the chain is not built, the stock's grain
/// could not be laid down, and the Effects panel's only move was a caption apologizing.
public struct GrainPlan: Sendable, Equatable {

    /// The particle model — pitch, per-channel crystal size, Dmax, plate persistence.
    public let profile: FilmGrainProfile
    /// Amplitude in density units at the envelope's peak: `profile.amount ×
    /// FilmGrainProfile.densityScale`. The scalar the kernel multiplies √(p(1−p)) by.
    public let amount: Double
    /// The denominator of `p = D / Dmax`.
    public let dMax: Double
    /// The print the plate's footprint is anchored to. Print size cancels out of
    /// `plateScale` algebraically (see its comment), so this only ever matters as the
    /// same number on both paths.
    public let printLongEdgeInches: Double
    /// True when this grain came from `look.grain` rather than from a stock. The GPU
    /// graph reads it to decide whether it may build its own plate — see
    /// `RenderGraph.build`, where getting that wrong would grain an export twice.
    public let isCreative: Bool

    public init(profile: FilmGrainProfile, amount: Double, dMax: Double,
                printLongEdgeInches: Double, isCreative: Bool) {
        self.profile = profile
        self.amount = amount
        self.dMax = Swift.max(dMax, 0.1)
        self.printLongEdgeInches = printLongEdgeInches
        self.isCreative = isCreative
    }

    /// The stage does nothing, so the plan can drop it before a plate is built.
    public var isIdentity: Bool { !(amount > 0) }

    /// One emulsion layer's plate, at this plan's own persistence and seed.
    ///
    /// Both renderers call THIS rather than `FilmGrainProfile.plate` directly, which is
    /// what makes Roughness reach the GPU: the persistence lives on the profile, and a
    /// caller that assembled the arguments itself would have had to remember it. The GPU
    /// builder in `PipelineRenderer` predates this and still assembles its own; it
    /// produces the same bytes for a film profile by construction (persistence 0.5,
    /// `defaultPlateSeed`) and `GrainPlateTests` pins that it does.
    public func plate(channel: Int, size: Int = GrainPlan.plateSize,
                      seed: UInt64 = FilmGrainProfile.defaultPlateSeed) -> [Float] {
        FilmGrainProfile.plate(size: size,
                               seed: profile.plateSeed(channel: channel, base: seed),
                               sigma: 1.0,
                               persistence: profile.persistence)
    }

    /// The plate's cell size in pixels for one layer, at a render's long edge.
    public func plateScale(longEdgePixels: Int, channel: Int) -> Double {
        Swift.max(profile.plateScale(longEdgePixels: longEdgePixels,
                                     printSizeInches: printLongEdgeInches,
                                     channel: channel), 0.5)
    }

    /// 128, the plate edge both renderers have always used. Named because the GPU
    /// builder and the reference renderer each had their own literal `128` and a plate
    /// of a different size is a different grain.
    public static let plateSize: Int = 128

    /// The film path's plan: exactly the four values `ReferenceRenderer.applyGrain` and
    /// `RenderGraph.applyGrain` used to read off `FilmChain`, so routing them through
    /// this type is byte-identical by construction.
    public static func film(_ chain: FilmChain) -> GrainPlan {
        GrainPlan(profile: chain.grain, amount: chain.grainAmount,
                  dMax: chain.grainDMax,
                  printLongEdgeInches: chain.printLongEdgeInches, isCreative: false)
    }

    /// Whether the FILM CHAIN owns the grain stage on this recipe — the three conditions
    /// `RenderPlan` builds a chain under, asked without building one.
    ///
    /// The Effects panel has to draw either the stock's two rows or the creative three,
    /// and a panel that guessed differently from the renderer would be offering controls
    /// that reach no pixel — the shape of the trap this whole change exists to close. So
    /// the question is asked once, here, and the panel and the plan both read it.
    ///
    /// IT DELIBERATELY DOES NOT ASK WHETHER THE STOCK'S GRAIN AMOUNT IS ABOVE ZERO, and
    /// that is a UI constraint reaching back into the model rather than an oversight. It
    /// did ask, briefly, and the consequence was a slider that deletes itself: drag the
    /// stock's grain Amount down to 0 and the two rows you are dragging vanish, replaced
    /// by three different ones, mid-gesture. A control that disappears at the bottom of
    /// its own travel is worse than one that does nothing there. So ownership is decided
    /// by the CHAIN — an emulsion is loaded and rendering — and a stock whose grain is
    /// at 0 simply lays down no grain, which is what its own slider says it will do.
    ///
    /// The photographer who wants creative grain over a film rendering has the move the
    /// owner himself described: pull Film Lab's Strength to 0 and keep the texture
    /// without the palette. That case used to render nothing at all.
    ///
    /// `testThePanelAndThePlanAgreeAboutWhichGrainRenders` walks the matrix.
    public static func filmOwnsTheGrain(_ look: Look) -> Bool {
        guard let film = look.filmLab, film.amount > 0,
              FilmStock.named(film.stock) != nil else { return false }
        return true
    }

    /// The creative plan. `monochrome` is the recipe's black-and-white treatment — see
    /// `FilmGrainProfile.init(creative:monochrome:)` for why it is not a control.
    ///
    /// The print anchor is `FilmGrainProfile.defaultPrintLongEdgeInches`, the same 10″ a
    /// film recipe with no print size chosen uses. It cancels out of `plateScale`, so
    /// this is a statement about nothing observable; it is written as the named constant
    /// anyway, because the day print size stops cancelling, two grains anchored to two
    /// different invisible numbers would be a very bad afternoon.
    public static func creative(_ grain: CreativeGrain, monochrome: Bool) -> GrainPlan {
        let profile = FilmGrainProfile(creative: grain, monochrome: monochrome)
        return GrainPlan(profile: profile,
                         amount: profile.amount * FilmGrainProfile.densityScale,
                         dMax: FilmGrainProfile.creativeDMax,
                         printLongEdgeInches:
                            FilmGrainProfile.defaultPrintLongEdgeInches,
                         isCreative: true)
    }
}

extension FilmGrainProfile: Equatable {
    public static func == (a: FilmGrainProfile, b: FilmGrainProfile) -> Bool {
        a.amount == b.amount && a.sizeScale == b.sizeScale
            && a.pitchMicrons == b.pitchMicrons && a.dMax == b.dMax
            && a.gateLongEdgeMM == b.gateLongEdgeMM && a.monochrome == b.monochrome
            && a.persistence == b.persistence
    }
}

// MARK: - One solved stage of the chain

/// A characteristic curve with its per-channel constants resolved once.
private struct FilmStage: Sendable {
    let dMin: RGB
    let dMax: RGB
    let delta: RGB
    let k: RGB
    let offset: RGB
    /// True when density rises with exposure (a negative); false for a transparency.
    let rising: Bool
    let whiteT: RGB
    let blackT: RGB

    init(_ c: FilmCharacteristic, rising: Bool, anchor: Double) {
        var span: RGB = RGB.zero
        var slope: RGB = RGB.zero
        var off: RGB = RGB.zero
        for i in 0..<3 {
            let d: Double = Swift.max(c.dMax[i] - c.dMin[i], 1e-6)
            span[i] = d
            slope[i] = Swift.max(c.gamma[i], 0.02) / (0.25 * d)
            off[i] = c.logOffset[i] + anchor
        }
        self.dMin = c.dMin
        self.dMax = c.dMax
        self.delta = span
        self.k = slope
        self.offset = off
        self.rising = rising
        self.whiteT = RGB(pow(10.0, -c.dMin.r), pow(10.0, -c.dMin.g), pow(10.0, -c.dMin.b))
        self.blackT = RGB(pow(10.0, -c.dMax.r), pow(10.0, -c.dMax.g), pow(10.0, -c.dMax.b))
    }

    /// `D = Dmin + (Dmax−Dmin)·sigmoid(k·(log10 E + offset))`, plus the sigmoid value
    /// itself, which the crossover weights use as a tonal position that rises with
    /// exposure for both kinds of stock.
    func response(_ e: RGB) -> (density: RGB, tone: RGB) {
        var d: RGB = RGB.zero
        var t: RGB = RGB.zero
        for i in 0..<3 {
            let x: Double = Num.clamp(k[i] * (log10(Swift.max(e[i], 1e-12)) + offset[i]), -60, 60)
            let s: Double = 1.0 / (1.0 + exp(-x))
            t[i] = s
            d[i] = dMin[i] + delta[i] * (rising ? s : 1.0 - s)
        }
        return (d, t)
    }
}

/// Everything the per-pixel chain needs, resolved at build time.
private struct SolvedChain: Sendable {
    var negative: FilmStage
    var printStage: FilmStage?
    var coupling: Mat3
    var shadowTint: RGB
    var highlightTint: RGB
    var filmGain: RGB
    var printGain: RGB
    var monochrome: Bool
    /// Density units of grain per unit plate value at peak amplitude.
    var grainScale: Double
}

// MARK: - The chain

/// The Film Lab as one transform: negative → inversion → print, in series, ending
/// display-linear.
///
/// Same contract as `DisplayTransform.apply` — scene-linear working-space RGB in,
/// display-linear out with 1.0 = SDR white × `displayWhite` — because when a stock is
/// active this chain *is* the S14 slot (docs/14 §5.7). `amount` blends the chain
/// against the neutral rendering, which is the AgX-class transform at the same display
/// white, so Strength 0 is bit-identical to having no film block at all.
public struct FilmChain: Sendable {

    public let recipe: FilmLab
    /// nil when `recipe.stock` names nothing we ship — the chain then degrades to the
    /// neutral rendering rather than to a different look.
    public let stock: FilmStock?
    public let displayWhite: Double
    /// EV into the stock, −2…+3, pre-curve. Not display brightness: this is the knob
    /// that produces pastel latitude instead of a brighter picture.
    public let filmExposure: Double
    /// Push / pull in stops, −1…+2. Steepens the gammas with divergence, scales grain
    /// amount and plate scale, and walks the shadows toward the stock's crossover.
    public let pushPull: Double
    /// Strength, normalized to 0…1 (`FilmLab.amount`).
    public let strength: Double
    /// The rendering the chain blends against: the recipe's own SOLVED display
    /// transform when the caller provides one, and the Neutral fallback otherwise.
    ///
    /// This used to be BUILT here, always, as `DisplayTransformParams.neutral` with
    /// only `whiteTarget` copied across — which discarded the user's transform whole:
    /// preset, contrast, skew, hue preservation, Black target, and the scene anchors
    /// Whites and Blacks had moved (docs/31 round two §2). Because `RenderPlan`'s gate
    /// is `amount > 0`, that was a discontinuity, not a blend: Strength 0 rendered
    /// through your transform and Strength 1 rendered 99% Neutral. On the "Linear"
    /// preset — the show-me-the-data control — one point of Strength moved the picture
    /// 51 code values, and Black target was dropped outright. The base is now the
    /// recipe's solved transform, so Strength walks from YOUR rendering to the film's
    /// with no jump at either end.
    public let neutral: DisplayTransform
    /// Grain parameters for this recipe; the plate sampling belongs to the image module.
    public let grain: FilmGrainProfile

    private let solved: SolvedChain?

    /// Divergence of the push gamma multiplier across R/G/B. Divergent gammas are what
    /// create push crossover; without the divergence a push is just more contrast.
    private static let pushDivergence: RGB = RGB(0.03, 0.0, -0.03)

    // MARK: Construction

    public init(_ recipe: FilmLab, displayWhite: Double = 1.0) {
        self.init(recipe, filmExposure: 0, displayWhite: displayWhite)
    }

    /// `base` is the display transform the chain blends against — pass the recipe's
    /// SOLVED transform (`RenderPlan` does; see `neutral`). nil keeps the historical
    /// Neutral-at-this-white fallback for callers that have no recipe transform in
    /// hand, which is also what every pre-fix test was written against.
    public init(_ recipe: FilmLab, filmExposure: Double, displayWhite: Double = 1.0,
                base: DisplayTransform? = nil) {
        let white: Double = Swift.max(displayWhite, 0.01)
        let push: Double = Num.clamp(recipe.pushPull, -1, 2)
        let blend: Double = Num.clamp(recipe.amount / 100.0, 0, 1)
        let found: FilmStock? = FilmStock.named(recipe.stock)

        self.recipe = recipe
        self.stock = found
        self.displayWhite = white
        self.filmExposure = Num.clamp(filmExposure, -2, 3)
        self.pushPull = push
        self.strength = blend

        if let base {
            self.neutral = base
        } else {
            var np: DisplayTransformParams = DisplayTransformParams.neutral
            np.whiteTarget = white * 100.0
            self.neutral = DisplayTransform(np, space: .rec2020)
        }

        let grainStock: FilmStock = found ?? FilmStock.portra400
        let profile: FilmGrainProfile = FilmGrainProfile(stock: grainStock,
                                       size: recipe.grain.size,
                                       amount: recipe.grain.amount,
                                       pushPull: push)
        self.grain = profile

        if let s = found, blend > 0 {
            self.solved = FilmChain.build(s,
                                          push: push,
                                          grainScale: profile.amount * FilmGrainProfile.densityScale,
                                          white: white)
        } else {
            self.solved = nil
        }
    }

    /// A recipe seeded with the stock's own defaults — what picking a stock card does.
    public static func defaultRecipe(for stock: FilmStock) -> FilmLab {
        FilmLab(stock: stock.id,
                amount: 100,
                pushPull: 0,
                halation: stock.halationDefault,
                grain: FilmGrain(size: 1.0, amount: stock.grainDefault),
                printSize: nil)
    }

    /// True when the chain reduces to the neutral rendering: no stock, or Strength 0.
    public var isIdentity: Bool { solved == nil }

    // MARK: Per-pixel

    /// Scene-linear → display-linear. The whole chain, blended against the neutral
    /// rendering by Strength.
    public func apply(_ c: RGB) -> RGB {
        // The base rendition is a display transform like any other, so it gets the
        // display-gamut map that goes with one. It used to be handed no boundary at
        // all, which was survivable only while the colour stages were clipping
        // upstream — a scene-referred clip in the wrong place, now removed. At partial
        // film strength the base is most of what you see.
        let base: RGB = neutral.apply(c, gamut: Gamut.sharedBoundary)
        guard let s = solved else { return base }
        let scene: RGB = c * pow(2.0, filmExposure)
        let film: RGB = FilmChain.render(scene, s, white: displayWhite, grain: RGB.zero)
        return base.mix(film, strength)
    }

    // `applyWithGrain(_:densityNoise:)` and `negativeDensity(_:)` are deliberately
    // GONE. Both described grain injected inside the negative+print chain — the
    // original docs/14 §5.7 design — and neither had a caller on any path: what
    // ships (ReferenceRenderer.applyGrain and the lumenGrain kernel, in lockstep)
    // grains the FORMED picture in its own density domain, D = −log₁₀(v), with the
    // same √(p(1−p)) envelope. A public entry point whose doc-comment promises a
    // wiring that does not exist is exactly the FAKE class the audits keep
    // convicting, and this one had already gone stale once — its comment called
    // itself "the entry point the image module uses" while the image module used
    // nothing of the kind. docs/14 §5.7 now describes the shipped tap point.

    /// Halation parameters for this recipe at a given render size, or nil without a
    /// stock. Size and Redness are the format additions docs/05 §8.1 flags as missing
    /// from `FilmLab`; they are arguments here until the wire format catches up.
    public func halationProfile(longEdgePixels: Int,
                                size: Double = 1.0,
                                redness: Double? = nil,
                                clipLevel: Double = 1.0) -> HalationProfile? {
        guard let s = stock else { return nil }
        return HalationProfile(stock: s,
                               amount: recipe.halation,
                               size: size,
                               redness: redness,
                               longEdgePixels: longEdgePixels,
                               clipLevel: clipLevel)
    }

    /// The print long edge this recipe's grain is anchored to, in inches.
    public var printLongEdgeInches: Double {
        FilmGrainProfile.printLongEdgeInches(recipe.printSize)
    }

    // MARK: Scalars the spatial stages read

    /// Halation Amount, normalized. Zero without a stock, and zero for a stock whose
    /// measured strengths are all zero (the transparencies), so the spatial stage can
    /// skip the whole glow pass on one comparison.
    public var halationAmount: Double {
        guard let s = stock else { return 0 }
        let m: Double = Swift.max(s.halationStrength.r,
                                  Swift.max(s.halationStrength.g, s.halationStrength.b))
        guard m > 0 else { return 0 }
        return Num.clamp(recipe.halation / 100.0, 0, 1)
    }

    /// Grain amplitude in density units at peak — the scalar the density-domain grain
    /// kernel multiplies √(p(1−p)) by. Zero when the chain is identity, since grain
    /// belongs to picture formation and there is no picture formation to put it in.
    public var grainAmount: Double {
        guard solved != nil else { return 0 }
        return grain.amount * FilmGrainProfile.densityScale
    }

    /// Scalar Dmax of the picture-forming stage — the denominator of `p = D / Dmax`
    /// when grain is applied against the *printed* density rather than the negative's.
    public var grainDMax: Double {
        guard let s = stock else { return 4.0 }
        let d: RGB = s.printCurve?.dMax ?? s.negative.dMax
        return Swift.max((d.r + d.g + d.b) / 3.0, 1e-6)
    }

    /// Halation parameters at a render size, using this recipe's Amount and the
    /// stock's own Redness. Never nil: without a stock the strengths are zero, which
    /// the caller's `strengths.maxComponent > 0` guard already handles.
    public func halation(longEdgePixels: Int) -> HalationProfile {
        HalationProfile(stock: stock ?? FilmStock.portra400,
                        amount: stock == nil ? 0 : recipe.halation,
                        size: 1.0,
                        redness: nil,
                        longEdgePixels: longEdgePixels,
                        clipLevel: 1.0)
    }

    // MARK: Baking

    /// Bake the chain over the `LumenLog` domain — the 3-D LUT the GPU stage fetches
    /// (65³ for export, 33³ for interaction; docs/05 §Bake strategy).
    public func bakeLUT(size: Int = LUT3D.exportSize) -> LUT3D {
        let n: Int = Swift.max(size, 2)
        return LUT3D(size: n) { coord in
            self.apply(LumenLog.decode(coord))
        }
    }

    // MARK: - Build

    private static func build(_ stock: FilmStock,
                              push: Double,
                              grainScale: Double,
                              white: Double) -> SolvedChain {
        // Push steepens the per-channel gammas with slight divergence.
        var negative: FilmCharacteristic = stock.negative
        for i in 0..<3 {
            let factor: Double = 1.0 + 0.18 * push * (1.0 + FilmChain.pushDivergence[i])
            negative.gamma[i] = Swift.max(negative.gamma[i] * factor, 0.02)
        }

        let negStage: FilmStage = FilmStage(negative,
                                 rising: stock.kind == .negative,
                                 anchor: FilmCharacteristic.midGreyAnchor)
        // The print's own log-exposure origin is absorbed by the calibration gain, so
        // its anchor is 0 and only its per-channel gamma/density span carry character.
        var printStage: FilmStage? = nil
        if let p = stock.printCurve {
            printStage = FilmStage(p, rising: true, anchor: 0)
        }

        let shadow: RGB = stock.crossover.shadowTint + stock.crossover.pushTint * push

        let seed: SolvedChain = SolvedChain(negative: negStage,
                               printStage: printStage,
                               coupling: FilmChain.couplingMatrix(interlayer: stock.crossover.interlayer,
                                                                  coupler: stock.crossover.coupler),
                               shadowTint: shadow,
                               highlightTint: stock.crossover.highlightTint,
                               filmGain: RGB.one,
                               printGain: RGB.one,
                               monochrome: stock.monochrome,
                               grainScale: Swift.max(grainScale, 0))
        return FilmChain.solveGains(seed, white: white)
    }

    /// DIR inhibition + masking-coupler residue as one 3×3 on the density triple.
    /// Both terms have unit row sums, so a neutral density triple is preserved exactly
    /// and the chain's grey calibration cannot be disturbed by colour couplers.
    private static func couplingMatrix(interlayer: Double, coupler: Double) -> Mat3 {
        let a: Double = Num.clamp(interlayer, 0, 0.6)
        let b: Double = Num.clamp(coupler, -0.5, 0.5)
        let third: Double = 1.0 / 3.0
        let diagonal: Double = 1.0 + a * (1.0 - third)
        let off: Double = -a * third
        let k: Double = b * 0.5
        return Mat3(diagonal, off - k, off + k,
                    off + k, diagonal, off - k,
                    off - k, off + k, diagonal)
    }

    /// Solve the per-channel calibration gain so scene mid-grey lands exactly on
    /// display mid-grey, in every channel — the anchor that makes "0.18 → 0.18" a
    /// property of construction rather than of tuning.
    ///
    /// For a print chain the gain is the enlarger lamp, downstream of every
    /// channel-mixing step, so the first bisection per channel is already exact. For a
    /// transparency the gain is scene-side and the couplers mix channels after it, so
    /// the sweeps iterate; six lands every shipped stock inside 1e-6. Build-time only.
    private static func solveGains(_ base: SolvedChain, white: Double) -> SolvedChain {
        var s: SolvedChain = base
        let grey: RGB = RGB(gray: DisplayTransform.midGrey)
        let target: Double = DisplayTransform.midGrey * white
        let usePrintGain: Bool = base.printStage != nil

        var sweep: Int = 0
        while sweep < 6 {
            for i in 0..<3 {
                let x: Double = FilmChain.bisect(target: target, lo: -14, hi: 14, steps: 52) { logGain in
                    var trial: SolvedChain = s
                    let g: Double = pow(2.0, logGain)
                    if usePrintGain { trial.printGain[i] = g } else { trial.filmGain[i] = g }
                    return FilmChain.render(grey, trial, white: white, grain: RGB.zero)[i]
                }
                let g: Double = pow(2.0, x)
                if usePrintGain { s.printGain[i] = g } else { s.filmGain[i] = g }
            }
            sweep += 1
        }
        return s
    }

    /// Bisection on a monotone scalar function whose direction is discovered from its
    /// endpoints — the print path decreases with gain, the transparency path increases.
    private static func bisect(target: Double,
                               lo: Double,
                               hi: Double,
                               steps: Int,
                               _ f: (Double) -> Double) -> Double {
        var a: Double = lo
        var b: Double = hi
        let fa: Double = f(a)
        let fb: Double = f(b)
        guard fa.isFinite, fb.isFinite else { return 0 }
        let increasing: Bool = fb >= fa
        if increasing {
            if target <= fa { return a }
            if target >= fb { return b }
        } else {
            if target >= fa { return a }
            if target <= fb { return b }
        }
        var i: Int = 0
        while i < steps {
            let m: Double = 0.5 * (a + b)
            let fm: Double = f(m)
            if !fm.isFinite { return m }
            if (increasing && fm < target) || (!increasing && fm > target) {
                a = m
            } else {
                b = m
            }
            i += 1
        }
        return 0.5 * (a + b)
    }

    // MARK: - Render

    /// Negative → couplers → crossover → grain → transmittance → print → paper white.
    private static func render(_ scene: RGB,
                               _ s: SolvedChain,
                               white: Double,
                               grain: RGB) -> RGB {
        var e: RGB = RGB(Swift.max(scene.r, 0), Swift.max(scene.g, 0), Swift.max(scene.b, 0))
        if s.monochrome {
            let y: Double = filmLumaWeights.r * e.r + filmLumaWeights.g * e.g + filmLumaWeights.b * e.b
            e = RGB(gray: Swift.max(y, 0))
        }
        e = e * s.filmGain

        let neg: (density: RGB, tone: RGB) = s.negative.response(e)
        var d: RGB = s.coupling.apply(neg.density)

        // Crossover: the toe and shoulder casts the stock carries, plus whatever push
        // has added to the toe. Tonal position is the sigmoid's own value, which rises
        // with exposure for both a negative and a transparency.
        let tone: Double = (neg.tone.r + neg.tone.g + neg.tone.b) / 3.0
        let shadowWeight: Double = 1.0 - Num.smoothstep(0.0, 0.6, tone)
        let highlightWeight: Double = Num.smoothstep(0.4, 1.0, tone)
        d = d + s.shadowTint * shadowWeight + s.highlightTint * highlightWeight

        // Grain, in density, during "development" — amplitude ∝ √(p(1−p)), p = D/Dmax.
        if s.grainScale > 0 {
            for i in 0..<3 {
                let noise: Double = grain[i]
                if noise == 0 { continue }
                let dm: Double = Swift.max(s.negative.dMax[i], 1e-6)
                let p: Double = Num.clamp(d[i] / dm, 0, 1)
                d[i] += s.grainScale * (p * (1 - p)).squareRoot() * noise
            }
        }

        // Density → transmittance. This is the step that makes colour subtractive.
        let t: RGB = RGB(pow(10.0, -d.r), pow(10.0, -d.g), pow(10.0, -d.b))

        let finalT: RGB
        let last: FilmStage
        if let p = s.printStage {
            // Print exposure = the light the enlarger pushes through the negative.
            let printExposure: RGB = t * s.printGain
            let pd: RGB = p.response(printExposure).density
            finalT = RGB(pow(10.0, -pd.r), pow(10.0, -pd.g), pow(10.0, -pd.b))
            last = p
        } else {
            finalT = t
            last = s.negative
        }

        // Normalize against the final stage's own paper white and maximum black, so the
        // picture spans exactly [0, displayWhite] with no free scaling factor.
        var out: RGB = RGB.zero
        for i in 0..<3 {
            let span: Double = last.whiteT[i] - last.blackT[i]
            let v: Double = abs(span) < 1e-12 ? 0 : (finalT[i] - last.blackT[i]) / span
            out[i] = Num.clamp(v, 0, 1) * white
        }
        return out
    }
}
