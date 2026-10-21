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
// display-linear out, with 1.0 = SDR white and mid-grey on 0.18 ABSOLUTE at every
// display peak (D8). The film picture itself tops out at print paper white, which is
// SDR white (`FilmChain.paperWhite`), and is never scaled by `displayWhite`: any HDR
// headroom comes from the base rendering only.
//
// What is NOT here, by design: anything spatial. Halation is an S13 pre-curve blur and
// grain is a density-domain noise field; both have global/neighbourhood support, so this file
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
/// WHAT THE STAGE ADDS (WS-39). Only the SPREAD part of the reflected light:
/// `strength · max(F − H, 0)`, where `H` is the highlight energy and `F` the same energy
/// after the bounce blurs. A stock's characteristic curve is measured on flat fields,
/// which already contain the light the base sends back to the same spot, so a flat
/// field must come out of this stage untouched. The stage used to add `strength · F`,
/// and since `F = H` on any flat area that was a red cast on every bright wall, lawn and
/// sky (+4…+7 sRGB codes at Amount 100) rather than a halo. The clamp keeps the core of a
/// highlight from going cyan where `F < H`: halation only ever adds light.
///
/// This type owns the *parameters* and the pointwise highlight-energy reconstruction.
/// The convolutions run at full resolution in both renderers.
public struct HalationProfile: Sendable {

    /// First-bounce sigma at gate scale, in µm, at Size = 1×.
    public static let firstSigmaMicrons: Double = 65.0
    /// Bounces summed. Radii are `σ₁ · bounceSpread[k]`.
    public static let bounceCount: Int = 3
    /// Each bounce's radius against the first. The base is ~125 µm of acetate or
    /// polyester: light that totally reflects at its back face lands a ring of a couple
    /// of base thicknesses out, and each further bounce lands further. 1 : 3 : 8 gives
    /// the tight core plus long soft tail of real halation (195 and 520 µm at the gate);
    /// the old `√k` series stopped at 113 µm and read as a thin red outline.
    public static let bounceSpread: [Double] = [1.0, 3.0, 8.0]
    /// Geometric decay between bounces.
    public static let bounceDecay: Double = 0.5
    /// Highlight gate: EV below the clip at which the energy ramp reaches zero. Two
    /// stops, so mid grey (−2.5 EV under a 1.0 clip) and anything darker contributes
    /// nothing at all; it was four, which let mid grey in at a third of full weight.
    public static let protectEV: Double = 2.0
    /// Reconstruction: stops of energy restored to a clipped sample. A light source or a
    /// blown sky is recorded AT the clip, but carried many stops more light onto the
    /// film; a diffuse white just under the clip did not. Two stops is a conservative
    /// floor for what a clipped sample really carried (a lamp in a night exposure is
    /// six to ten), chosen so that the stock defaults stay subtle. It was 0.3 stop,
    /// which let a lamp glow no more than a white wall.
    public static let boostRange: Double = 2.0
    /// Reconstruction: the band below the clip, in EV, over which a sample is read as
    /// clipped. A clipped sample in a decoded RAW sits within a few thousandths of the
    /// clip; 0.1 EV holds those and leaves a diffuse white at 0.9 alone.
    public static let clipBandEV: Double = 0.1
    /// The physically measured per-channel strengths, RGB.
    public static let measuredStrength: RGB = RGB(0.05, 0.015, 0.0)
    /// The gain that turns a stock's `halationStrength` into the gain on the
    /// NORMALIZED bounce field — 1.75, the raw sum `1 + 0.5 + 0.25` of the three-bounce
    /// series every stock's strength was authored against (N-006 / C1-09). A literal,
    /// not `weightSum`, so Amount's meaning does not follow `bounceCount`.
    public static let strengthCalibration: Double = 1.75
    /// The radius of the green and blue records' halo against red's, for a stock whose
    /// halation is fully chromatic. The light that reaches the base and comes back
    /// exposes the red-sensitive layer first (it sits on the base); what reaches green
    /// is the part scattered at short range. So the glow is orange near the source and
    /// red further out. Scaled toward 1 by the stock's own chroma, so a neutral
    /// (black-and-white) stock keeps one radius and no colour fringe.
    public static let chromaticNarrowing: Double = 0.55

    /// Red's Gaussian sigmas in pixels, `σ₁ · bounceSpread[k]`.
    public let sigmas: [Double]
    /// Green's and blue's sigmas in pixels: `sigmas × channelSpread`.
    public let narrowSigmas: [Double]
    /// Green/blue radius against red's, 1 for a neutral stock.
    public let channelSpread: Double
    /// Bounce weights, `decay^(k−1)` — the series' raw shape, 1, ½, ¼.
    public let weights: [Double]
    /// Per-channel gain applied to `max(F − H, 0)` on the NORMALIZED field: stock
    /// strength, blended toward pure red by Redness, scaled by Amount and by
    /// `strengthCalibration`.
    public let strength: RGB
    /// Amount, normalized to 0…1.
    public let amount: Double
    /// Redness, normalized to 0…1.
    public let redness: Double
    /// Size multiplier, 0.5×…2×.
    public let sizeMultiplier: Double
    /// Scene-linear level treated as the clip (seeded by S1's clipping mask).
    public let clipLevel: Double
    public let longEdgePixels: Int
    public let gateLongEdgeMM: Double

    public init(stock: FilmStock,
                amount: Double,
                size: Double = 1.0,
                redness: Double? = nil,
                longEdgePixels: Int,
                clipLevel: Double = 1.0,
                exposureGain: Double = 1.0) {
        let a: Double = Num.clamp(amount / 100.0, 0, 1)
        let sz: Double = Num.clamp(size, 0.5, 2.0)
        let red: Double = Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
        let gate: Double = Swift.max(stock.gateLongEdgeMM, 1e-3)
        let px: Int = Swift.max(longEdgePixels, 1)

        let base: RGB = stock.halationStrength
        let pureRed: RGB = RGB(base.r, 0, 0)
        // `exposureGain` is the light onto the film against the scene's, 2^(Film Lab
        // Exposure): the base reflects a fixed fraction of whatever arrives, so a lamp
        // the stock is given two stops less of throws a quarter of the glow. The clip
        // that reconstruction reads stays the SENSOR's, because that is where the
        // recording stopped.
        self.strength = base.mix(pureRed, red) * a * HalationProfile.strengthCalibration
            * Swift.max(exposureGain, 0)

        // The stock's own chroma (before Redness): 0 for equal records, 1 when one
        // record carries none of it.
        let hi: Double = Swift.max(base.r, Swift.max(base.g, base.b))
        let lo: Double = Swift.min(base.r, Swift.min(base.g, base.b))
        let chroma: Double = hi > 0 ? Num.clamp(1 - Swift.max(lo, 0) / hi, 0, 1) : 0
        let spread: Double = 1 - (1 - HalationProfile.chromaticNarrowing) * chroma
        self.channelSpread = spread

        // 65 µm at the gate, expressed in pixels of this render.
        let sigma1: Double = (HalationProfile.firstSigmaMicrons / 1000.0) * sz / gate * Double(px)
        var sig: [Double] = []
        var narrow: [Double] = []
        var w: [Double] = []
        for k in 0..<HalationProfile.bounceCount {
            let s: Double = sigma1 * HalationProfile.bounceSpread[k]
            sig.append(s)
            narrow.append(s * spread)
            w.append(pow(HalationProfile.bounceDecay, Double(k)))
        }
        self.sigmas = sig
        self.narrowSigmas = narrow
        self.weights = w

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

    /// Bounce weights normalized to sum 1 — what both renderers accumulate with, so a
    /// flat field's `F` equals its `H` exactly and `strength` is the only gain.
    public var normalizedWeights: [Double] {
        let s: Double = weightSum
        guard s > 1e-12 else { return weights }
        var out: [Double] = []
        for w in weights { out.append(w / s) }
        return out
    }

    /// The working space the renderers hand this stage (`RGBColorSpace.rec2020`, every
    /// stage's) to the space the halo's colour lives in, and back.
    ///
    /// WHY THE HALO HAS ITS OWN PRIMARIES. A stock's `halationStrength` is a colour —
    /// "mostly red with a little green" — and it was applied on the working space's
    /// channels. Rec.2020's red primary is a 630 nm laser no print dye can make: a halo
    /// of `(1, 0.22, 0)` in Rec.2020 is far outside sRGB and P3, the film chain's
    /// interlayer pushed it further, and the display clamp rendered it as pure primary
    /// red with green and blue at code 0 (measured beside a clipped disk at Amount 100:
    /// RGB 194, 45, 0 → 139, 0, 0). In sRGB primaries the same strengths are the
    /// red-orange of a real print's halo, and the stage stays neutral-preserving
    /// because both spaces share D65.
    public static let layersToWorking: Mat3 = RGBColorSpace.srgb.matrix(to: .rec2020)
    public static let workingToLayers: Mat3 = layersToWorking.inverse

    /// The energy that "penetrates to the base", per channel, in the halo's (sRGB)
    /// primaries — the field the bounce Gaussians are convolved with.
    ///
    /// One gate per PIXEL, on its brightest working-space record `b = max(r, g, b)`, so
    /// the glow keeps the source's colour (a red lamp throws red, a sodium lamp orange):
    ///   `t = smoothstep(−protectEV, 0, log2(b / clip))` — zero two stops down;
    ///   `s = smoothstep(−clipBandEV, 0, log2(b / clip))` — 1 for a clipped sample;
    ///   `k = t · max(1, s · 2^boostRange · clip / b)`;
    ///   `out = max(workingToLayers · (c⁺ · k), 0)`.
    /// The `max(1, …)` floors a clipped sample at `2^boostRange · clip` of energy while
    /// leaving a genuine HDR value above that floor at its own (linear) energy. C⁰ and
    /// monotone non-decreasing in exposure; exactly zero at and below `clip / 4`.
    public func highlightEnergy(_ c: RGB) -> RGB {
        let r: Double = Swift.max(c.r, 0), g: Double = Swift.max(c.g, 0)
        let bl: Double = Swift.max(c.b, 0)
        let b: Double = Swift.max(r, Swift.max(g, bl))
        guard b > 0 else { return RGB.zero }
        let ev: Double = log2(b / clipLevel)
        let t: Double = Num.smoothstep(-HalationProfile.protectEV, 0, ev)
        guard t > 0 else { return RGB.zero }
        let s: Double = Num.smoothstep(-HalationProfile.clipBandEV, 0, ev)
        let floor: Double = s * pow(2.0, HalationProfile.boostRange) * clipLevel / b
        let k: Double = t * Swift.max(1.0, floor)
        let e: RGB = HalationProfile.workingToLayers.apply(RGB(r * k, g * k, bl * k))
        return RGB(Swift.max(e.r, 0), Swift.max(e.g, 0), Swift.max(e.b, 0))
    }

    /// The per-channel apply, once the image module has produced the normalized field
    /// `F = Σ normalizedWeights[k] · G_k ∗ H` (red at `sigmas`, green and blue at
    /// `narrowSigmas`, all in the halo's primaries):
    /// `out = in + layersToWorking · (strength · max(F − H, 0))`.
    public func combine(_ base: RGB, field: RGB, energy: RGB) -> RGB {
        let d: RGB = RGB(Swift.max(field.r - energy.r, 0),
                         Swift.max(field.g - energy.g, 0),
                         Swift.max(field.b - energy.b, 0))
        return base + HalationProfile.layersToWorking.apply(strength * d)
    }

    // MARK: The GPU form

    // The shader (`KernelLibrary.halationEnergy`) evaluates `highlightEnergy` itself —
    // the same gate, from `clipLevel`, `protectEV`, `clipBandEV` and `boostRange` — so
    // there is ONE gate, not a reference and a stand-in (M09 / C1-01), and applies
    // `workingToLayers` and its clamp itself. The clamp of `combine` is `subtract` then
    // `highlightEnergy(·, 0, 1)` = `max(F − H, 0)`, and its gain is the single matrix
    // `layersToWorking · diag(strength)`.

    /// Per-channel strengths, under the name the spatial stage uses.
    public var strengths: RGB { strength }

    /// Red's blur radii in pixels, under the name the spatial stage uses.
    public var sigmasInPixels: [Double] { sigmas }
}

// MARK: - Grain

/// Density-domain grain (docs/14 §5.7), the model that makes grain *film* rather than
/// a noise overlay: it lives in density, its amplitude follows √(p(1−p)) so it peaks at
/// mid densities and vanishes at both Dmin and Dmax, and its size is denominated at the
/// gate rather than in pixels.
///
/// The noise itself is `GrainField` (WS-40): stateless per-pixel sparse convolution of
/// small grains, evaluated at each output pixel from a hash of its neighbouring cells.
/// There is no plate, no texture and no tiling. The tiled 128-texel value-noise plate
/// this replaced repeated every 64-283 px and read as "a texture I put on there".
public struct FilmGrainProfile: Sendable {

    /// The seed both render paths use (`ReferenceRenderer.Inputs.grainSeed` defaults to
    /// it, and the GPU field is built from it). Named once because it was once written
    /// twice with different values, so the two paths drew different grain.
    public static let defaultPlateSeed: UInt64 = 0x9E3779B97F4A7C15

    /// Density units of grain at Amount 100 and peak amplitude (p = 0.5), per unit of
    /// RESOLVED field σ (`GrainField` is normalised to σ = 1 for grains that a pixel
    /// resolves; sub-pixel grains average down below 1, as an export downsampled
    /// would).
    ///
    /// 0.30, tuned to WS-40 SPEC line 4a: Amount 100, Size 25, on mid grey, at a
    /// 6000 px frame is 10-14 sRGB codes of luma σ (measured 12.1). The old 0.12 laid
    /// about 6 codes, all of it in 6-36 px blobs; with grain at grain size the same
    /// visibility needs more density. One scale for the stocks and the creative grain,
    /// so the two Amount sliders keep one denomination.
    public static let densityScale: Double = 0.30
    /// Long edge, in inches, when no print size is chosen.
    public static let defaultPrintLongEdgeInches: Double = 10.0

    /// Amount, normalized, after push scaling — may exceed 1 at +2 stops of push.
    public let amount: Double
    /// Per-channel grain size scale, (0.8, 1.0, 2.0) RGB for a colour stock.
    public let sizeScale: RGB
    /// Grain pitch (grain DIAMETER) at the gate, µm, after the recipe's Size and push
    /// scaling. The mean grain radius is half of it (`grainRadiusPixels`).
    public let pitchMicrons: Double
    /// Per-channel Dmax — the denominator of `p = D / Dmax`.
    public let dMax: RGB
    public let gateLongEdgeMM: Double
    /// Carried from the stock so grain can ask whether there are dye layers to be
    /// grainy independently. A monochrome negative has one emulsion, so its three
    /// channels must share a single noise field — three independent ones would put
    /// coloured speckle on a black-and-white photograph. The creative grain sets it
    /// too: it is luminance grain (`luminanceOnly`).
    public let monochrome: Bool
    /// The grain's irregularity, 0…1 — the creative Roughness, or `stockRoughness`.
    /// 0 is dense, even grains of one size; 1 is sparse grains whose radius spreads
    /// ±0.8 stops, plus a coarser clump layer (`GrainField`).
    public let roughness: Double
    /// True for the creative grain: one field, laid as a LUMINANCE density offset on
    /// all three channels with the envelope taken from the pixel's luminance, so hue
    /// and chroma ratios are untouched (SPEC line 10b). A stock grains per channel.
    public let luminanceOnly: Bool

    /// HOW MUCH OF THE THREE LAYERS' INDEPENDENCE REACHES THE PICTURE. 1 is three
    /// fully decorrelated fields; 0 is one shared field wearing three amplitude
    /// envelopes.
    ///
    /// Three independent unit fields laid at full amplitude give σ(luma) = A/√3 and
    /// σ(R−G) = A√2, so the chroma noise would be 2.45× the luminance noise: coloured
    /// speckle, the same defect the owner rejected in the creative grain ("rainbow
    /// splotches"). A stock's layers ARE its character, so it gets a fraction instead.
    /// Below 1 the mix takes noise OUT of colour rather than moving it into luminance:
    /// it is scaled to hold the luminance grain where it was (`noiseMixWeights`).
    public let chroma: Double

    /// Dye-layer decorrelation surviving into the picture, by stock kind. A colour
    /// NEGATIVE is printed, and the print's own emulsion re-integrates the three
    /// records; a REVERSAL is the taking film itself, viewed directly, where the grain
    /// is finer to begin with. Taste, named once, so they move for every stock together.
    ///
    /// Halved from 0.30 / 0.15 by WS-40: with grain at grain size (rather than in
    /// blobs) the three records' own structure is fully visible, and at 0.30 Portra 400's
    /// grain measured 0.80 / 0.61 (R−G / B−G) of its luma grain at a 6000 px frame —
    /// magenta/green speckle. SPEC line 10c bounds it at 0.10-0.50 × luma: faint colour
    /// at the grain's own scale, no blotches.
    public static let dyeLayerChromaNegative: Double = 0.15
    public static let dyeLayerChromaReversal: Double = 0.075

    /// The roughness every film stock is grained at — the middle of the creative
    /// control, so a stock's grain has the same character as creative Roughness 50.
    public static let stockRoughness: Double = 0.5

    /// The two scalars the grain stage mixes the three fields with:
    /// `n'ᵢ = luma·(n_R + n_G + n_B) + own·nᵢ`.
    ///
    /// Write the mix as `n'ᵢ = (1−χ)·n_L + χ·nᵢ` with `n_L = k·Σn`, `k = 1/√Var(Σn)`,
    /// then divide by `M`, where `M` holds the LUMINANCE amplitude: the mix's luminance
    /// is `Σn·[(1−χ)k + χ/3]`, whose σ is `(1−χ) + χ/(3k)`; at χ = 1 that is `1/(3k)`.
    /// So `M = 3k(1−χ) + χ` — `√3(1−χ) + χ` for three independent layers and exactly 1
    /// for a monochrome profile. χ = 1 gives luma 0, own 1: the expression is `nᵢ`.
    /// The `GrainField` layers are independent by construction (distinct hash seeds;
    /// `GrainSpecTests.testSeedChangesPattern` measures |r| < 0.05), so the premise holds.
    public var noiseMixWeights: (luma: Double, own: Double) {
        let x: Double = Num.clamp(chroma, 0, 1)
        // Three independent unit fields sum to variance 3; three identical ones to 9.
        let k: Double = monochrome ? 1.0 / 3.0 : 1.0 / 3.0.squareRoot()
        let m: Double = 3 * k * (1 - x) + x
        guard m > 1e-12 else { return (luma: 0, own: 1) }
        return (luma: (1 - x) * k / m, own: x / m)
    }

    /// The gate a CREATIVE grain's size is denominated on: 35 mm, long edge 36 mm.
    /// Anchoring at the gate rather than in pixels keeps a creative grain the same
    /// fraction of the picture on a 2560 px preview and a 6000 px export.
    public static let creativeGateLongEdgeMM: Double = 36.0

    /// The finest and coarsest pitch (grain diameter) the Size slider reaches, µm at
    /// the gate: 7.2 µm at Size 0 and 72 µm at Size 100, geometric.
    ///
    /// On a 6000 px frame (about 24 MP, Lightroom's reference scale) one pixel is 6 µm
    /// of a 36 mm gate, so the grain radius runs 0.6 px → 6 px and the measured 1/e
    /// correlation length 0.8 / 1.2 / 1.8 / 5.0 px at Size 0 / 25 / 50 / 100 (WS-40 SPEC
    /// line 6b: 0.6-0.9 / 1.0-1.5 / 1.6-2.5 / 4.0-5.5). Size 0 is about the finest real
    /// emulsion (Velvia 50 is 6 µm, Ektar 100 7 µm); Size 100 is chunky on purpose.
    public static let creativePitchMinMicrons: Double = 7.2
    public static let creativePitchMaxMicrons: Double = 72.0

    /// Size 0…100 → pitch in µm, geometric: `7.2 · 10^(size/100)`. A pitch axis is a
    /// ratio axis: every 25 points is ×1.78, so each step looks as different as the last.
    public static func creativePitchMicrons(size: Double) -> Double {
        let s = Num.clamp(size, 0, 100) / 100
        return creativePitchMinMicrons
            * pow(creativePitchMaxMicrons / creativePitchMinMicrons, s)
    }

    /// Roughness 0…100 → the field's irregularity, 0…1.
    public static func creativeRoughness(_ roughness: Double) -> Double {
        Num.clamp(roughness.isFinite ? roughness : 50, 0, 100) / 100
    }

    /// A creative grain's profile — the SAME struct the film path builds, filled from
    /// the three sliders instead of from an emulsion.
    ///
    /// ONE FIELD, LUMINANCE ONLY. Three decorrelated dye layers at creative sizes are
    /// rainbow splotches — the owner's verdict on the build that tried it: "the grain
    /// is absolutely ridiculously bad. It just turns into rainbow splotches." So the
    /// creative grain is one field, and it is laid as one density offset on all three
    /// channels from the pixel's luminance (`luminanceOnly`), which also keeps it from
    /// moving hue on a coloured pixel (the per-channel envelope did: SPEC line 10b
    /// measured 0.37 log-chroma per log-luma before).
    ///
    /// `dMax` is flat 4.0 — `FilmChain.grainDMax`'s own stockless fallback. It is the
    /// denominator of `p = D/Dmax`, so the grain peaks at D = 2.0.
    public init(creative: CreativeGrain, monochrome: Bool) {
        self.amount = Num.clamp(creative.amount, 0, 100) / 100.0
        self.sizeScale = RGB(1, 1, 1)
        self.pitchMicrons = Swift.max(
            FilmGrainProfile.creativePitchMicrons(size: creative.size), 0.1)
        self.dMax = RGB(gray: FilmGrainProfile.creativeDMax)
        self.gateLongEdgeMM = FilmGrainProfile.creativeGateLongEdgeMM
        // The caller knows whether the photograph is black-and-white; the answer is
        // one field either way, because this grain is luminance grain.
        _ = monochrome
        self.monochrome = true
        // One field means there is nothing to decorrelate, so the mix is the identity.
        self.chroma = 1
        self.roughness = FilmGrainProfile.creativeRoughness(creative.roughness)
        self.luminanceOnly = true
    }

    /// The stockless Dmax, kept where `FilmChain.grainDMax` can be read beside it.
    public static let creativeDMax: Double = 4.0

    public init(stock: FilmStock, size: Double, amount: Double, pushPull: Double) {
        let push: Double = Num.clamp(pushPull, -1, 2)
        // Push scales grain amount and grain size together — one slider, coherent
        // consequences (docs/05 §Push/Pull).
        let amountScale: Double = Swift.max(1.0 + 0.35 * push, 0)
        let pitchScale: Double = Swift.max(1.0 + 0.15 * push, 0.05)
        self.amount = Num.clamp(amount / 100.0, 0, 1) * amountScale
        self.sizeScale = stock.grainSizeScale
        self.pitchMicrons = Swift.max(stock.grainPitchMicrons * Swift.max(size, 0.05) * pitchScale, 0.1)
        self.dMax = stock.negative.dMax
        self.gateLongEdgeMM = Swift.max(stock.gateLongEdgeMM, 1e-3)
        self.monochrome = stock.monochrome
        self.chroma = stock.monochrome ? 1
            : (stock.kind == .reversal ? FilmGrainProfile.dyeLayerChromaReversal
                                       : FilmGrainProfile.dyeLayerChromaNegative)
        self.roughness = FilmGrainProfile.stockRoughness
        self.luminanceOnly = false
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

    /// One emulsion layer's mean grain RADIUS in render pixels: half the pitch, from
    /// the gate to the print (×magnification) to pixels (×the render's
    /// pixels-per-print-mm). The print size appears in both factors and cancels, so a
    /// bigger print from the same pixels keeps the grain's pixel footprint; change the
    /// GATE (35 mm → 120) and it moves, exactly as it does in a darkroom.
    ///
    /// NO FLOOR. The plate needed a half-pixel floor because a texel finer than that
    /// aliased; the grain field has a pixel aperture (`GrainField.pixelAperture`)
    /// instead, so a sub-pixel grain is averaged by its pixel the way an export's
    /// downsample would average it (SPEC line 8), and every Size step stays live.
    public func grainRadiusPixels(longEdgePixels: Int, printSizeInches: Double,
                                  channel: Int) -> Double {
        let i: Int = Swift.min(Swift.max(channel, 0), 2)
        let printLongEdgeMM: Double = Swift.max(printSizeInches, 0.1) * 25.4
        let mag: Double = printLongEdgeMM / gateLongEdgeMM
        let pitchOnPrintMM: Double = (pitchMicrons / 1000.0) * mag
        let pixelsPerPrintMM: Double = Double(Swift.max(longEdgePixels, 1)) / printLongEdgeMM
        return 0.5 * pitchOnPrintMM * pixelsPerPrintMM * Swift.max(sizeScale[i], 0.05)
    }

    /// The long edge to hand the grain for a file that has been CROPPED, RESIZED,
    /// or both on its way out.
    ///
    /// The grain's size is relative to the long edge, which is assumed to span the whole
    /// gate. A delivered file often does not, and the two ways of losing pixels are not
    /// the same:
    ///
    ///   - a RESIZE keeps the same piece of negative and puts fewer pixels on it, so
    ///     the grain's pixel footprint shrinks with them;
    ///   - a CROP keeps fewer pixels AND less negative, and those cancel exactly. The
    ///     footprint does not move.
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
}

// MARK: - The grain stage, resolved

/// Everything the grain stage needs, resolved once by the plan, so that neither renderer
/// has to know where the grain came from.
///
/// Grain used to be gated on `plan.filmChain` in four places, so "is there grain on this
/// photograph" was a question four files answered independently. It is answered once,
/// here, and both renderers read the answer.
///
/// The precedence is stated in one line of `RenderPlan`: **a live film chain's grain
/// wins.** A stock's grain is a property of the emulsion the photographer chose; the
/// creative grain is what renders when there is no chain, which includes Film Lab
/// Strength at 0.
public struct GrainPlan: Sendable, Equatable {

    /// The particle model — pitch, per-channel crystal size, Dmax, roughness.
    public let profile: FilmGrainProfile
    /// Amplitude in density units at the envelope's peak: `profile.amount ×
    /// FilmGrainProfile.densityScale`. The scalar the kernel multiplies √(p(1−p)) by.
    public let amount: Double
    /// The denominator of `p = D / Dmax`.
    public let dMax: Double
    /// The print the grain's footprint is anchored to. Print size cancels out of
    /// `grainRadiusPixels` algebraically, so this only ever matters as the same number on
    /// both paths.
    public let printLongEdgeInches: Double
    /// True when this grain came from `look.grain` rather than from a stock. The GPU
    /// graph reads it to decide whether it may build its own field — see
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

    /// The stage does nothing, so the plan can drop it before a field is built.
    public var isIdentity: Bool { !(amount > 0) }

    /// The two scalars the grain stage mixes the three fields with — the profile's,
    /// surfaced on the plan because the plan is what both renderers hold.
    /// `RenderGraph` hands them to `lumenGrain` and `ReferenceRenderer` performs the
    /// same multiply-add; they must be the same two numbers or gpu-parity fails.
    public var noiseLumaWeight: Double { profile.noiseMixWeights.luma }
    public var noiseOwnWeight: Double { profile.noiseMixWeights.own }

    /// Luminance-only application (the creative grain): one density offset on all three
    /// channels, from the luminance's envelope. `lumenGrain` reads it as its `mode`.
    public var luminanceOnly: Bool { profile.luminanceOnly }

    /// The luminance weights the luminance-only envelope is taken with: the working
    /// space's (Rec.2020), the space both renderers form the picture in.
    public static let luminanceWeights: RGB = RGBColorSpace.rec2020.luminanceWeights

    /// One layer's mean grain radius in pixels at a render's long edge.
    public func grainRadiusPixels(longEdgePixels: Int, channel: Int) -> Double {
        profile.grainRadiusPixels(longEdgePixels: longEdgePixels,
                                  printSizeInches: printLongEdgeInches, channel: channel)
    }

    /// The noise field for a render whose long edge is `longEdge` — the ONE place both
    /// renderers get their grain from. `ReferenceRenderer.applyGrain` evaluates it on
    /// the CPU, `RenderGraph.grainPlate` hands its layers to the `lumenGrainField`
    /// generator; the hash and the kernel are one formula (`GrainField`).
    public func field(longEdge: Int,
                      seed: UInt64 = FilmGrainProfile.defaultPlateSeed) -> GrainField {
        let channels = profile.monochrome ? 1 : 3
        return GrainField(
            radii: (0..<channels).map { grainRadiusPixels(longEdgePixels: longEdge,
                                                          channel: $0) },
            roughness: profile.roughness, seed: seed)
    }

    /// The film path's plan: exactly the four values `ReferenceRenderer.applyGrain` and
    /// `RenderGraph.applyGrain` used to read off `FilmChain`.
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
    /// that reach no pixel. So the question is asked once, here, and the panel and the
    /// plan both read it.
    ///
    /// IT DELIBERATELY DOES NOT ASK WHETHER THE STOCK'S GRAIN AMOUNT IS ABOVE ZERO: that
    /// made a slider that deletes itself — drag the stock's grain Amount down to 0 and
    /// the two rows you are dragging vanish, replaced by three different ones,
    /// mid-gesture. Ownership is decided by the CHAIN, and a stock whose grain is at 0
    /// simply lays down no grain.
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
    /// film recipe with no print size chosen uses. It cancels out of the grain radius,
    /// so this is a statement about nothing observable; it is written as the named
    /// constant so the two grains are anchored to one invisible number, not two.
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
            && a.roughness == b.roughness && a.luminanceOnly == b.luminanceOnly
            && a.chroma == b.chroma
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
/// display-linear out with 1.0 = SDR white and mid-grey on 0.18 ABSOLUTE at every
/// display peak (docs/04 D8) — because when a stock is active this chain *is* the S14
/// slot (docs/14 §5.7). The film picture itself tops out at print paper white, which
/// is diffuse (SDR) white; HDR headroom above it comes from the base rendering only.
/// `amount` blends the chain against the neutral rendering, which is the AgX-class transform at the same display
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

    /// The display-linear level the print's paper white renders at: SDR white, at
    /// EVERY display peak, never `displayWhite`.
    ///
    /// The chain used to be solved for grey at `0.18 × displayWhite` and to scale its
    /// normalised transmittance by `displayWhite`, which made film(c, w) exactly
    /// w × film(c, 1). On a 400-nit EDR preview or an HDR export the film picture sat
    /// log₂(w) EV above the base rendering it blends with — +2 EV at w = 4 — so the
    /// Strength slider became an exposure ramp, against docs/05 §Film Lab's "same HDR
    /// parameterization (D8)". A print has no headroom above its own paper, so paper
    /// white is diffuse white and grey lands on 0.18 absolute; at w = 1 nothing moves.
    /// (Solving instead for 0.18/w on a [0, w] span would keep specular headroom but
    /// would slide the whole midtone range into the print's toe — a different stock.)
    static let paperWhite: Double = 1.0

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
            let grainScale: Double = profile.amount * FilmGrainProfile.densityScale
            let key: SolveKey = SolveKey(stockID: s.id,
                                         push: push.bitPattern,
                                         grainScale: grainScale.bitPattern,
                                         white: FilmChain.paperWhite.bitPattern)
            self.solved = FilmChain.solveMemo.chain(for: key) {
                FilmChain.build(s, push: push, grainScale: grainScale, white: FilmChain.paperWhite)
            }
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
        let film: RGB = FilmChain.render(scene, s, white: FilmChain.paperWhite, grain: RGB.zero)
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
    /// stock.
    ///
    /// Size and Redness default to THE RECIPE'S, which is what this comment used to say
    /// they could not: "they are arguments here until the wire format catches up". It
    /// has caught up (`FilmLab.halationSize` / `.halationRedness`), and the arguments
    /// stay so that a caller measuring the profile's response to one of them — which is
    /// how `HalationControlTests` proves Size reaches the radius at all — can vary it
    /// without assembling a recipe.
    public func halationProfile(longEdgePixels: Int,
                                size: Double? = nil,
                                redness: Double? = nil,
                                clipLevel: Double = 1.0) -> HalationProfile? {
        guard let s = stock else { return nil }
        return HalationProfile(stock: s,
                               amount: recipe.halation,
                               size: size ?? recipe.effectiveHalationSize,
                               redness: redness ?? recipe.halationRedness,
                               longEdgePixels: longEdgePixels,
                               clipLevel: clipLevel,
                               exposureGain: pow(2.0, filmExposure))
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

    /// Halation parameters at a render size, from this recipe's Amount, Size and
    /// Redness, scaled by the light Film Lab Exposure puts onto the film (WS-39: a lamp
    /// pulled to mid-grey at −2 EV still threw its full glow). Never nil: without a stock the strengths are zero, which the caller's
    /// `strengths.maxComponent > 0` guard already handles.
    ///
    /// THE ONE ACCESSOR BOTH RENDERERS USE, which is why the two new controls had to
    /// arrive here rather than at `halationProfile` above: this is the call
    /// `ReferenceRenderer.applyHalation` and `RenderGraph.applyHalation` each make, and
    /// it hardcoded `size: 1.0, redness: nil`. `HalationProfile.init` has taken both and
    /// used them for real since it was written; nothing could reach them (C2-05).
    public func halation(longEdgePixels: Int) -> HalationProfile {
        HalationProfile(stock: stock ?? FilmStock.portra400,
                        amount: stock == nil ? 0 : recipe.halation,
                        size: recipe.effectiveHalationSize,
                        redness: recipe.halationRedness,
                        longEdgePixels: longEdgePixels,
                        clipLevel: 1.0,
                        exposureGain: pow(2.0, filmExposure))
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

    /// Every input `build` reads, as bits. `stockID` stands for the whole stock because
    /// `found` only ever comes from `FilmStock.named`, i.e. from the static `index` of
    /// `let` constants: one id, one set of curves. The Doubles are the clamped values
    /// handed to `build`, compared by bit pattern so not even ±0 can share an entry.
    fileprivate struct SolveKey: Equatable {
        let stockID: String
        let push: UInt64
        let grainScale: UInt64
        let white: UInt64
    }

    /// The solved chain, remembered while its inputs do not move.
    ///
    /// `RenderPlan.init` builds a `FilmChain` on every plan with a stock loaded — the
    /// finish-table hit path too, since the grain plan and `plan.filmChain` carry it —
    /// and `solveGains` is 6 sweeps × 3 channels × a 52-step bisection: ~970 `render`
    /// calls, measured 0.33 ms of a 0.61 ms warm film plan on a Texture tick, which
    /// moves none of stock, push, grain or white. `build` is a pure function of the
    /// key (no randomness, no global state), so a hit is the exact value a fresh solve
    /// returns and no pixel can move. Four entries, not one: the EDR and SDR preview
    /// plans, and export's HDR/SDR pair, alternate two whites.
    static let solveMemo: SolvedChainMemo = SolvedChainMemo()

    final class SolvedChainMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: SolveKey, chain: SolvedChain)] = []
        private static let capacity: Int = 4
        private var misses: Int = 0

        fileprivate func chain(for key: SolveKey, _ solve: () -> SolvedChain) -> SolvedChain {
            lock.lock()
            if let hit = entries.first(where: { $0.key == key }) {
                lock.unlock()
                return hit.chain
            }
            lock.unlock()
            // Solved outside the lock: two threads missing on one key both solve, and
            // both get the same bits.
            let chain: SolvedChain = solve()
            lock.lock()
            misses += 1
            if !entries.contains(where: { $0.key == key }) {
                if entries.count >= SolvedChainMemo.capacity { entries.removeFirst() }
                entries.append((key, chain))
            }
            lock.unlock()
            return chain
        }

        /// Forget every entry, so the next construction is a cold solve. Test-only.
        func removeAll() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }

        /// Solves actually run — `EngineIntegrationTests` reads it to prove a repeat
        /// construction does not re-solve.
        var missCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return misses
        }
    }

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
        // picture spans exactly [0, white] with no free scaling factor (`paperWhite`).
        var out: RGB = RGB.zero
        for i in 0..<3 {
            let span: Double = last.whiteT[i] - last.blackT[i]
            let v: Double = abs(span) < 1e-12 ? 0 : (finalT[i] - last.blackT[i]) / span
            out[i] = Num.clamp(v, 0, 1) * white
        }
        return out
    }
}
