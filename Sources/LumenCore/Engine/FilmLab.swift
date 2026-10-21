// FilmLab.swift
// The Film Lab's engine core (D18, docs/05-spec-color.md §Film Lab, docs/14 §5.7).
//
// A film stock is not a preset: it is a *model*. Three physical stages in series —
// negative characteristic curve → inversion (transmittance) → print characteristic
// curve — each a per-channel curve in log-exposure→density space. Because the curve
// lives in log exposure, Film Exposure moves the scene *along the stock* and the lab
// prints it back to mid-grey (overexposed: clean shadows, pastel highlights;
// underexposed: muddy, fogged shadows), and because the image leaves each stage as
// density → transmittance, colour is inherently subtractive.
//
// The equations (docs/quality/lanes/WS-38 rebuilt them; docs/14 §5.7 for the frame):
//
//   negative  D = Dmin + γ·soft(log10 E − toe, τ_low), rolled into a shoulder far
//             above grey — straight over ~10 stops, as the Portra/Ektar/Vision curves
//   print     Dp = γp·log10(T·lamp), rolled into paper white (τ_low) and paper
//             black (τ_high): the print's S-curve is the picture's
//   T = 10^(−D)                              density → transmittance
//   levels    paper white (Dmin + a hair) → 1, paper black → the display floor
//   lamp      solved per channel so scene mid-grey prints at 0.18 — the printer lights
//
// Colour on top of that tone: the path to white (ratios through the mid-tones,
// per-channel into the shoulder), hue anchored to the neutral rendering plus each
// stock's authored lobes, stock saturation relative to the sRGB boundary, then the
// display-gamut map. See `FilmColor`.
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
// grain is a density-domain plate; both have global/neighbourhood support, so this file
// exposes their *parameters* (`HalationProfile`, `FilmGrainProfile`) and the image
// module owns the convolution and the sampling.
//
// Clean-room posture (docs/05 §Licensing, docs/17 ledger): implemented from the
// equations and constants above plus the primary literature they cite (Giorgianni &
// Madden; Hunt 6e ch. 15). No GPL reference implementation was consulted; the stock
// parameterizations below are Lumen's own interpretations, named as such.

import Foundation

/// Rec.2020 luma weights, resolved once — the luminance the colour stages anchor greys to.
private let filmLumaWeights: RGB = RGBColorSpace.rec2020.luminanceWeights

// MARK: - Characteristic curve

/// One stage's per-channel characteristic curve, in density against log10 exposure.
///
/// A real colour negative is nearly STRAIGHT over a very long range — Kodak's Portra and
/// Ektar curves run straight from about four stops under mid-grey to well past six over
/// — and the picture's S-curve is the PRINT's (paper or print film). So a stage here is
/// a straight line of slope `gamma` (density per decade) whose two ends are rolled off
/// separately:
///
///   · the LOW end, toward `dMin`: a negative's toe (base + fog), a paper's or slide's
///     clear highlights. `lowSoftness` is how gradually it gets there, in density.
///   · the HIGH end: a negative's shoulder (`shoulderStops` over mid-grey), a paper's
///     maximum black (`dMax`), a slide's maximum density (`toneCeiling ?? dMax`).
///     `highSoftness` likewise.
///
/// Positive softness is a softplus (exponential approach — a definite knee); negative
/// selects the hyperbolic form (algebraic approach — a long tail, which is what gives
/// a slide its "rich but not empty" shadows). Both are C∞ and monotone, so every curve
/// built from them is too.
///
/// `dMin`/`dMax` also feed the grain stage (`FilmGrainProfile.dMax`, `grainDMax`), so
/// they keep the measured stock values; the tone uses `toneCeiling` where a slide's
/// usable density range differs from the emulsion's nominal maximum.
public struct FilmCharacteristic: Sendable {

    /// `−log10(0.18)`: log10 exposure of scene mid-grey, negated.
    public static let midGreyAnchor: Double = 0.7447274948966939

    /// Density per decade of log exposure along the straight section, per channel.
    public var gamma: RGB
    /// Base + fog (negative), paper white (print), clear film (slide).
    public var dMin: RGB
    /// The emulsion's maximum density (grain reads this one).
    public var dMax: RGB
    /// Per-channel trim of the toe position, in stops (+ moves the toe toward grey).
    /// Where a layer runs out of speed first is what colours underexposed shadows.
    public var logOffset: RGB
    /// Negative only: stops under mid-grey where the toe bends.
    public var toeStops: Double
    /// Negative only: stops over mid-grey where the shoulder bends.
    public var shoulderStops: Double
    /// Roll-off into `dMin`, density units (negative = hyperbolic).
    public var lowSoftness: Double
    /// Roll-off into the high end, density units (negative = hyperbolic).
    public var highSoftness: Double
    /// A slide's tonal density ceiling, when it differs from `dMax`.
    public var toneCeiling: RGB?
    /// The last stage's white: the density, above `dMin`, that prints as paper white.
    /// The approach to `dMin` is asymptotic; a lab calls "white" a hair before it, and
    /// that is what lets the shoulder land on white at a finite exposure with a gentle
    /// slope instead of creeping toward it forever (a dead range of 251…254 codes).
    public var whiteDelta: Double

    public init(gamma: RGB,
                dMin: RGB = RGB(gray: 0.01),
                dMax: RGB = RGB(gray: 4.0),
                logOffset: RGB = RGB.zero,
                toeStops: Double = 4.0,
                shoulderStops: Double = 7.0,
                lowSoftness: Double = 0.3,
                highSoftness: Double = 0.3,
                toneCeiling: RGB? = nil,
                whiteDelta: Double = 0.004) {
        self.gamma = gamma
        self.dMin = dMin
        self.dMax = dMax
        self.logOffset = logOffset
        self.toeStops = toeStops
        self.shoulderStops = shoulderStops
        self.lowSoftness = lowSoftness
        self.highSoftness = highSoftness
        self.toneCeiling = toneCeiling
        self.whiteDelta = whiteDelta
    }
}

// MARK: - Crossover / colour couplers

/// The parts of a stock's colour that live in density: the tonal crossover it carries
/// at rest, the direction it moves under push, and the inter-layer couplers.
///
/// Sign convention — tints are stated in the stock's OWN density domain. A
/// negative→print chain inverts twice, so a positive density offset prints as *more* of
/// that channel; a transparency inverts once, so a positive offset reads as *less*.
///
/// The tints are weighted by the stage's own mean density (not by scene exposure), so a
/// tint is a function of density added to density: `D + t·f(D)` stays monotone in `D`
/// for any tint the tables hold, at every exposure and push.
public struct FilmCrossover: Sendable {

    /// Density offset in the shadows (full weight `FilmChain.tintReach` below grey).
    public var shadowTint: RGB
    /// Density offset in the highlights.
    public var highlightTint: RGB
    /// Additional shadow density offset per stop of push.
    public var pushTint: RGB
    /// DIR inter-layer inhibition, 0…0.6 (acts in the per-channel highlight branch).
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

// MARK: - Stock colour rendering

/// One hue-local adjustment: a Gaussian lobe in OKLab hue (degrees).
public struct FilmHueLobe: Sendable, Equatable {
    public var hue: Double
    public var width: Double
    public var amount: Double
    public init(_ hue: Double, _ width: Double, _ amount: Double) {
        self.hue = hue
        self.width = width
        self.amount = amount
    }

    func weight(at h: Double) -> Double {
        let d = Num.wrapHue(h - hue + 180) - 180
        let w = Swift.max(width, 1e-3)
        return exp(-0.5 * (d / w) * (d / w))
    }
}

/// How a stock renders colour on top of its tone curve.
///
/// The density chain sets lightness, the path to white and the crossover. What it does
/// NOT set is hue and saturation through the mid-tones: a per-channel log curve scales
/// chroma by its local slope, so it boosts dark and muted colours (dark skin went burnt
/// orange at ×2) and drains light ones (light skin went ashen at ×0.5) — a vibrance
/// curve, not a stock. So the colour is anchored instead:
///
///   · hue follows the neutral rendering's hue of the same scene colour, plus the
///     stock's authored lobes (`hueShifts`: Velvia's violet blues, Ektar's cyan sky,
///     Gold's golden skin);
///   · chroma is the film's own, scaled by `chroma` (× `chromaShifts`) relative to the
///     sRGB gamut boundary — the full gain on muted colours, falling to none at the
///     boundary as `(1 − x)^saturationFalloff` of the headroom `x` used, so saturated
///     skies keep their gradation instead of piling up against the edge;
///   · `highlightPastel` takes that much of the gain back in the light tones — the
///     soft, pastel highlights of a portrait negative;
///   · the extra purity fades out in the deepest tones (`darkFade…`): dense dyes go
///     muddy, they do not glow;
///   · near neutral (reference chroma below `lobeChromaTaper`, OKLab) the lobes fade
///     out and the hue follows the film's own: a near-grey has no meaningful hue, and
///     hue-dependent gains around it make a cone the finish LUT cannot interpolate.
public struct FilmColor: Sendable {
    public var chroma: Double
    public var saturationFalloff: Double
    public var highlightPastel: Double
    public var hueShifts: [FilmHueLobe]
    public var chromaShifts: [FilmHueLobe]
    /// Spectral overlap of the layers, as the AgX-style primaries inset (purity toward
    /// white, rotation in radians). It is what lets a saturated colour bleach to white
    /// through the per-channel shoulder rather than clip.
    public var insetAttenuation: RGB
    public var insetRotation: RGB
    public var darkFadeLow: Double
    public var darkFadeHigh: Double
    public var lobeChromaTaper: Double

    public init(chroma: Double,
                saturationFalloff: Double = 2.0,
                highlightPastel: Double = 0.0,
                hueShifts: [FilmHueLobe] = [],
                chromaShifts: [FilmHueLobe] = [],
                insetAttenuation: RGB = RGB(0.14, 0.18, 0.12),
                insetRotation: RGB = RGB(0.02, -0.03, 0.06),
                darkFadeLow: Double = 0.0,
                darkFadeHigh: Double = 0.2,
                lobeChromaTaper: Double = 0.0) {
        self.chroma = chroma
        self.saturationFalloff = saturationFalloff
        self.highlightPastel = highlightPastel
        self.hueShifts = hueShifts
        self.chromaShifts = chromaShifts
        self.insetAttenuation = insetAttenuation
        self.insetRotation = insetRotation
        self.darkFadeLow = darkFadeLow
        self.darkFadeHigh = darkFadeHigh
        self.lobeChromaTaper = lobeChromaTaper
    }

    func hueShift(at h: Double) -> Double {
        var s = 0.0
        for l in hueShifts { s += l.amount * l.weight(at: h) }
        return s
    }

    func chromaGain(at h: Double) -> Double {
        chroma * lobeGain(at: h)
    }

    /// The product of the chroma lobes alone, without the stock's overall `chroma`.
    func lobeGain(at h: Double) -> Double {
        var k = 1.0
        for l in chromaShifts { k *= 1 + (l.amount - 1) * l.weight(at: h) }
        return k
    }
}

/// What push/pull processing does to a stock.
///
/// Push is underexposure (`underexposurePerStop` stops less light on the film per stop)
/// developed longer: the gammas steepen, the print's highlight roll-off hardens, and the
/// shadows the underexposure never recorded print as black (`shadowCrushPerStop`, the
/// display level a lab prints down to black per stop). The lab still prints mid-grey
/// to mid-grey. Pull is the reverse, without the crush, and with its own rates
/// (`pullGammaPerStop`, `printToePerPullStop`): overexposed, held-back negatives print
/// with a long soft highlight roll-off while the mid-tone contrast drops less.
public struct FilmPushResponse: Sendable {
    /// The datasheet's range, in stops. Velvia 50: −½…+1.
    public var range: ClosedRange<Double>
    public var gammaPerStop: Double
    public var printToePerStop: Double
    public var pullGammaPerStop: Double
    public var printToePerPullStop: Double
    public var shadowCrushPerStop: Double
    public var underexposurePerStop: Double

    public init(range: ClosedRange<Double> = -1...2,
                gammaPerStop: Double,
                printToePerStop: Double = 0.1,
                pullGammaPerStop: Double? = nil,
                printToePerPullStop: Double? = nil,
                shadowCrushPerStop: Double = 0.006,
                underexposurePerStop: Double = 1.0) {
        self.range = range
        self.gammaPerStop = gammaPerStop
        self.printToePerStop = printToePerStop
        self.pullGammaPerStop = pullGammaPerStop ?? gammaPerStop
        self.printToePerPullStop = printToePerPullStop ?? printToePerStop
        self.shadowCrushPerStop = shadowCrushPerStop
        self.underexposurePerStop = underexposurePerStop
    }
}

// MARK: - Film stock

/// A deeply parameterized stock. Six at launch: 5–10 deep beats 60 shallow (D18).
///
/// These are Lumen's own interpretations, honestly named — they are built from our
/// datasheet digitization and the model above, not from anyone's emulsion samples, and
/// the display names say "Lumen" for exactly that reason. The tone constants were fitted
/// (docs/quality/lanes/WS-38) so each stock's contrast, white point and black sit where
/// the datasheets and the spec put them; `scripts/gen-fixtures.py` mirrors the tables.
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
    /// True for B&W stocks: the exposure is the scene through `panchromatic`, and grain
    /// has no chromatic structure.
    public let monochrome: Bool

    /// The camera-stage curve.
    public let negative: FilmCharacteristic
    /// The paper / print-film stage, or nil for a transparency.
    public let printCurve: FilmCharacteristic?
    /// Display name of the paired print stock, if any.
    public let printName: String?

    public let crossover: FilmCrossover
    public let color: FilmColor
    public let push: FilmPushResponse
    /// A B&W emulsion's spectral sensitivity as Rec.2020 weights (sum 1, so a grey is
    /// its own exposure). Panchromatic film sees more blue and a little less red than
    /// the eye: skies print lighter than luminance would put them.
    public let panchromatic: RGB

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
                color: FilmColor,
                push: FilmPushResponse,
                panchromatic: RGB = RGBColorSpace.rec2020.luminanceWeights,
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
        self.color = color
        self.push = push
        self.panchromatic = panchromatic
        self.halationStrength = halationStrength
        self.halationDefault = halationDefault
        self.halationRedness = halationRedness
        self.grainDefault = grainDefault
        self.grainSizeScale = grainSizeScale
        self.grainPitchMicrons = grainPitchMicrons
        self.gateLongEdgeMM = gateLongEdgeMM
    }

    /// Nominal system gamma per channel: negative × print slope along the straight
    /// sections, or the slide's own.
    public var systemGamma: RGB {
        guard let p = printCurve else { return negative.gamma }
        return RGB(negative.gamma.r * p.gamma.r,
                   negative.gamma.g * p.gamma.g,
                   negative.gamma.b * p.gamma.b)
    }

    // MARK: The launch six

    /// Wide latitude, low contrast, warm-neutral and gentle colour, clean highlights — the
    /// portrait default. Its character is latitude: a long straight negative printed soft.
    public static let portra400: FilmStock = FilmStock(
        id: "lumen/portra400",
        name: "Lumen Portra 400",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.5478, 0.5478, 0.5478),
                                     dMin: RGB(0.0600, 0.1400, 0.2200),
                                     dMax: RGB(2.0600, 2.1400, 2.2200),
                                     logOffset: RGB(-0.8000, 0.0000, 0.0000),
                                     toeStops: 5.432,
                                     shoulderStops: 5.207,
                                     lowSoftness: 0.1881,
                                     highSoftness: 0.4158),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.6388, 2.6388, 2.6388),
                                       dMin: RGB(0.0500, 0.0600, 0.0700),
                                       dMax: RGB(2.1500, 2.2000, 2.2500),
                                       lowSoftness: 0.8981,
                                       highSoftness: 0.9646,
                                       whiteDelta: 0.008),
        crossover: FilmCrossover(shadowTint: RGB(0.0350, 0.0100, -0.0350),
                                 highlightTint: RGB(0.0300, 0.0160, -0.0250),
                                 pushTint: RGB(-0.0100, 0.0050, 0.0120),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 1.38,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.22,
                         hueShifts: [FilmHueLobe(60.0, 25.0, 2.0), FilmHueLobe(135.0, 30.0, -6.0), FilmHueLobe(245.0, 35.0, -5.0), FilmHueLobe(20.0, 20.0, 0.5)],
                         chromaShifts: [FilmHueLobe(65.0, 35.0, 1.08), FilmHueLobe(135.0, 35.0, 0.8), FilmHueLobe(245.0, 40.0, 0.82), FilmHueLobe(25.0, 20.0, 1.05)],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.0),
        push: FilmPushResponse(range: -1.0...2.0, gammaPerStop: 0.1737, printToePerStop: 0.1, pullGammaPerStop: 0.1425, printToePerPullStop: 0.32, shadowCrushPerStop: 0.0065, underexposurePerStop: 1.0),
        halationStrength: RGB(0.0500, 0.0150, 0.0000),
        halationDefault: 35,
        halationRedness: 25,
        grainDefault: 45,
        grainSizeScale: RGB(0.8000, 1.0000, 2.0000),
        grainPitchMicrons: 12.0,
        gateLongEdgeMM: 36.0)

    /// The consumer emulsion: golden-warm throughout, punchier reds and yellows, medium
    /// contrast.
    public static let gold200: FilmStock = FilmStock(
        id: "lumen/gold200",
        name: "Lumen Gold 200",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.6875, 0.6875, 0.6875),
                                     dMin: RGB(0.0600, 0.1400, 0.2200),
                                     dMax: RGB(2.0600, 2.1400, 2.2200),
                                     logOffset: RGB(-0.8000, 0.0000, 0.0000),
                                     toeStops: 5.7305,
                                     shoulderStops: 5.4492,
                                     lowSoftness: 0.4514,
                                     highSoftness: 0.434),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.7200, 2.7200, 2.7200),
                                       dMin: RGB(0.0500, 0.0600, 0.0700),
                                       dMax: RGB(2.1000, 2.1500, 2.2000),
                                       lowSoftness: 1.0423,
                                       highSoftness: 1.2986,
                                       whiteDelta: 0.0038),
        crossover: FilmCrossover(shadowTint: RGB(0.0360, 0.0120, -0.0360),
                                 highlightTint: RGB(0.0550, 0.0200, -0.0600),
                                 pushTint: RGB(-0.0100, 0.0050, 0.0120),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 1.95,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.0,
                         hueShifts: [FilmHueLobe(60.0, 30.0, 2.0), FilmHueLobe(95.0, 25.0, 5.0), FilmHueLobe(250.0, 30.0, -4.0), FilmHueLobe(140.0, 25.0, -10.0), FilmHueLobe(20.0, 20.0, 4.0)],
                         chromaShifts: [FilmHueLobe(95.0, 25.0, 1.0), FilmHueLobe(140.0, 30.0, 1.0), FilmHueLobe(250.0, 30.0, 0.85), FilmHueLobe(55.0, 25.0, 0.88)],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.0),
        push: FilmPushResponse(range: -1.0...2.0, gammaPerStop: 0.1909, printToePerStop: 0.1, pullGammaPerStop: 0.1565, printToePerPullStop: 0.32, shadowCrushPerStop: 0.0057, underexposurePerStop: 1.0),
        halationStrength: RGB(0.0600, 0.0200, 0.0000),
        halationDefault: 45,
        halationRedness: 35,
        grainDefault: 55,
        grainSizeScale: RGB(0.8000, 1.0000, 2.0000),
        grainPitchMicrons: 14.0,
        gateLongEdgeMM: 36.0)

    /// Fine grain, the highest contrast and saturation of the Kodak negatives: red-forward,
    /// a deep slightly cyan sky, vivid greens.
    public static let ektar100: FilmStock = FilmStock(
        id: "lumen/ektar100",
        name: "Lumen Ektar 100",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.9700, 0.9700, 0.9700),
                                     dMin: RGB(0.0600, 0.1400, 0.2200),
                                     dMax: RGB(2.0600, 2.1400, 2.2200),
                                     logOffset: RGB(-0.5000, 0.0000, 0.0000),
                                     toeStops: 5.3141,
                                     shoulderStops: 5.4824,
                                     lowSoftness: 0.3703,
                                     highSoftness: 0.566),
        printName: "Lumen Type-C Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.5512, 2.5512, 2.5512),
                                       dMin: RGB(0.0500, 0.0500, 0.0600),
                                       dMax: RGB(2.2000, 2.2400, 2.2800),
                                       lowSoftness: 1.4,
                                       highSoftness: 1.75,
                                       whiteDelta: 0.005),
        crossover: FilmCrossover(shadowTint: RGB(-0.0080, 0.0000, 0.0120),
                                 highlightTint: RGB(0.0000, 0.0000, 0.0000),
                                 pushTint: RGB(-0.0100, 0.0050, 0.0120),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 2.75,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.0,
                         hueShifts: [FilmHueLobe(25.0, 25.0, -2.0), FilmHueLobe(50.0, 20.0, -1.5), FilmHueLobe(85.0, 20.0, -3.0), FilmHueLobe(250.0, 30.0, -7.0), FilmHueLobe(140.0, 30.0, -4.0), FilmHueLobe(200.0, 25.0, -3.0)],
                         chromaShifts: [FilmHueLobe(25.0, 25.0, 1.12), FilmHueLobe(150.0, 30.0, 1.05), FilmHueLobe(95.0, 25.0, 0.88), FilmHueLobe(55.0, 25.0, 0.66), FilmHueLobe(250.0, 30.0, 1.1), FilmHueLobe(40.0, 20.0, 1.08)],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.05),
        push: FilmPushResponse(range: -1.0...2.0, gammaPerStop: 0.2, printToePerStop: 0.1, pullGammaPerStop: 0.164, printToePerPullStop: 0.32, shadowCrushPerStop: 0.0075, underexposurePerStop: 1.0),
        halationStrength: RGB(0.0300, 0.0100, 0.0000),
        halationDefault: 15,
        halationRedness: 15,
        grainDefault: 15,
        grainSizeScale: RGB(0.8000, 1.0000, 2.0000),
        grainPitchMicrons: 7.0,
        gateLongEdgeMM: 36.0)

    /// Monochrome negative on a graded paper. Panchromatic: skies print lighter than eye
    /// luminance, deep reds a little darker. No dye layers, so the halo here is neutral.
    public static let triX400: FilmStock = FilmStock(
        id: "lumen/trix400",
        name: "Lumen Tri-X 400",
        kind: .negative,
        monochrome: true,
        negative: FilmCharacteristic(gamma: RGB(0.7651, 0.7651, 0.7651),
                                     dMin: RGB(0.1000, 0.1000, 0.1000),
                                     dMax: RGB(2.1000, 2.1000, 2.1000),
                                     logOffset: RGB(0.0000, 0.0000, 0.0000),
                                     toeStops: 5.8406,
                                     shoulderStops: 4.9824,
                                     lowSoftness: 0.4541,
                                     highSoftness: 0.4775),
        printName: "Lumen Grade 2 Paper",
        printCurve: FilmCharacteristic(gamma: RGB(2.5700, 2.5700, 2.5700),
                                       dMin: RGB(0.0600, 0.0600, 0.0600),
                                       dMax: RGB(2.2000, 2.2000, 2.2000),
                                       lowSoftness: 1.0327,
                                       highSoftness: 1.3809,
                                       whiteDelta: 0.004),
        crossover: FilmCrossover(shadowTint: RGB(0.0000, 0.0000, 0.0000),
                                 highlightTint: RGB(0.0000, 0.0000, 0.0000),
                                 pushTint: RGB(0.0000, 0.0000, 0.0000),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 1.0,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.0,
                         hueShifts: [],
                         chromaShifts: [],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.0),
        push: FilmPushResponse(range: -1.0...2.0, gammaPerStop: 0.19, printToePerStop: 0.1, pullGammaPerStop: 0.1558, printToePerPullStop: 0.32, shadowCrushPerStop: 0.0065, underexposurePerStop: 1.0),
        panchromatic: RGB(0.2500, 0.5500, 0.2000),
        halationStrength: RGB(0.0400, 0.0400, 0.0400),
        halationDefault: 20,
        halationRedness: 0,
        grainDefault: 70,
        grainSizeScale: RGB(1.0000, 1.0000, 1.0000),
        grainPitchMicrons: 18.0,
        gateLongEdgeMM: 36.0)

    /// Transparency: one inversion, inside the emulsion, and no print stage. High gamma,
    /// a short exposure scale with dense, rich (not empty) shadows; emerald greens and
    /// deep violet-leaning blues. Halation is zero: slide stocks have an effective backing.
    public static let velvia50: FilmStock = FilmStock(
        id: "lumen/velvia50",
        name: "Lumen Velvia 50",
        kind: .reversal,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(2.2800, 2.2800, 2.2800),
                                     dMin: RGB(0.1200, 0.1400, 0.1600),
                                     dMax: RGB(3.4000, 3.4500, 3.5000),
                                     lowSoftness: 0.6312,
                                     highSoftness: -2.35,
                                     toneCeiling: RGB(3.9878, 4.0377, 4.0877),
                                     whiteDelta: 0.004),
        printName: nil,
        printCurve: nil,
        crossover: FilmCrossover(shadowTint: RGB(-0.0120, 0.0120, -0.0120),
                                 highlightTint: RGB(0.0000, 0.0000, 0.0000),
                                 pushTint: RGB(0.0000, 0.0000, 0.0000),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 3.4,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.0,
                         hueShifts: [FilmHueLobe(268.0, 30.0, 3.0), FilmHueLobe(150.0, 30.0, 8.0), FilmHueLobe(330.0, 25.0, 5.0), FilmHueLobe(95.0, 20.0, -3.0), FilmHueLobe(10.0, 10.0, -2.0)],
                         chromaShifts: [FilmHueLobe(150.0, 30.0, 1.08), FilmHueLobe(330.0, 30.0, 1.0), FilmHueLobe(55.0, 25.0, 0.55), FilmHueLobe(95.0, 25.0, 1.0), FilmHueLobe(258.0, 15.0, 0.8)],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.04),
        push: FilmPushResponse(range: -0.5...1.0, gammaPerStop: 0.12, printToePerStop: 0.0, pullGammaPerStop: 0.12, printToePerPullStop: 0.0, shadowCrushPerStop: 0.006, underexposurePerStop: 0.0),
        halationStrength: RGB(0.0000, 0.0000, 0.0000),
        halationDefault: 0,
        halationRedness: 0,
        grainDefault: 12,
        grainSizeScale: RGB(0.8000, 1.0000, 2.0000),
        grainPitchMicrons: 6.0,
        gateLongEdgeMM: 36.0)

    /// Daylight cine negative through a print-film stage: the Kodak print look — deep
    /// blacks, bright neutral highlights, teal-leaning shadows and warm skin. The gate is
    /// Super 35, so grain and halation are coarser per pixel than the stills stocks.
    public static let cine250D: FilmStock = FilmStock(
        id: "lumen/cine250d",
        name: "Lumen Cine 250D",
        kind: .negative,
        monochrome: false,
        negative: FilmCharacteristic(gamma: RGB(0.6703, 0.6703, 0.6703),
                                     dMin: RGB(0.1000, 0.2000, 0.3000),
                                     dMax: RGB(2.0000, 2.1000, 2.2000),
                                     logOffset: RGB(-0.3000, 0.0000, 0.0000),
                                     toeStops: 5.7562,
                                     shoulderStops: 5.0,
                                     lowSoftness: 0.3857,
                                     highSoftness: 0.383),
        printName: "Lumen Print Film 2K",
        printCurve: FilmCharacteristic(gamma: RGB(2.3950, 2.3950, 2.3950),
                                       dMin: RGB(0.0600, 0.0600, 0.0700),
                                       dMax: RGB(2.6000, 2.6500, 2.7000),
                                       lowSoftness: 1.05,
                                       highSoftness: 0.9586,
                                       whiteDelta: 0.007),
        crossover: FilmCrossover(shadowTint: RGB(-0.0500, -0.0050, 0.0500),
                                 highlightTint: RGB(0.0450, 0.0160, -0.0450),
                                 pushTint: RGB(-0.0100, 0.0050, 0.0120),
                                 interlayer: 0.1,
                                 coupler: 0.0),
        color: FilmColor(chroma: 1.15,
                         saturationFalloff: 2.0,
                         highlightPastel: 0.1,
                         hueShifts: [FilmHueLobe(50.0, 25.0, 2.5), FilmHueLobe(25.0, 20.0, 4.0), FilmHueLobe(140.0, 35.0, 9.0), FilmHueLobe(240.0, 30.0, -5.0), FilmHueLobe(95.0, 25.0, -6.0)],
                         chromaShifts: [FilmHueLobe(140.0, 35.0, 0.8), FilmHueLobe(240.0, 30.0, 0.85), FilmHueLobe(40.0, 25.0, 1.05)],
                         insetAttenuation: RGB(0.1400, 0.1800, 0.1200),
                         insetRotation: RGB(0.0200, -0.0300, 0.0600),
                         darkFadeLow: 0.0,
                         darkFadeHigh: 0.2,
                         lobeChromaTaper: 0.0),
        push: FilmPushResponse(range: -1.0...2.0, gammaPerStop: 0.1781, printToePerStop: 0.1, pullGammaPerStop: 0.1461, printToePerPullStop: 0.32, shadowCrushPerStop: 0.005, underexposurePerStop: 1.0),
        halationStrength: RGB(0.0500, 0.0150, 0.0000),
        halationDefault: 30,
        halationRedness: 20,
        grainDefault: 30,
        grainSizeScale: RGB(0.8000, 1.0000, 2.0000),
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
    /// The gain that turns a stock's `halationStrength` into the gain on the
    /// NORMALIZED bounce field — 1.75, the raw sum `1 + 0.5 + 0.25` of the three-bounce
    /// series every stock's strength was authored against.
    ///
    /// N-006 / C1-09. Both renderers used to walk raw weights `decay^(k−1)`, so the field
    /// they multiplied by `strength` summed to 1.75 and `normalizedWeights` had no caller.
    /// The picture was the same on both paths, but Amount's meaning was hostage to
    /// `bounceCount`: a fourth bounce would have raised every stock's glow by 7% with no
    /// stock edited. `strength` is now the gain on the NORMALIZED field (weights summing
    /// to 1, whatever the count — see `fieldGain` for how the renderers apply it), and
    /// this constant carries the old sum into the gain instead — a LITERAL, not
    /// `weightSum`, because the point is that it no longer follows the series. Folded
    /// here rather than into six stock literals so `halationStrength` keeps reading as
    /// the measured number it is. Pixels are unchanged: byte-identical on every
    /// halation proof render, and `HalationControlTests.testNormalizingTheBouncesMovesNoPixel`
    /// holds the stage to the pre-change one at zero difference.
    public static let strengthCalibration: Double = 1.75

    /// Gaussian sigmas in pixels, σ_k = σ₁·√k, k = 1…3.
    public let sigmas: [Double]
    /// Bounce weights, `decay^(k−1)` — the series' raw SHAPE, 1, ½, ¼. The renderers
    /// accumulate with these (they are dyadic, so they scale an f32 field exactly) and
    /// apply `fieldGain`, which is what makes the result `strength` times the
    /// `normalizedWeights` sum. The raw sum the stocks were calibrated against lives in
    /// `strengthCalibration`, not here.
    public let weights: [Double]
    /// Per-channel gain applied to the NORMALIZED summed field: stock strength, blended
    /// toward pure red by Redness, scaled by Amount and by `strengthCalibration`.
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

        let base: RGB = stock.halationStrength
        let pureRed: RGB = RGB(base.r, 0, 0)
        self.strength = base.mix(pureRed, red) * a * HalationProfile.strengthCalibration

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
    /// wants, so `strength` stays the only gain in the path. What the renderers APPLY,
    /// per unit of `strength`: `fieldGain · weights[k] == strength · normalizedWeights[k]`.
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

    /// The gain on the field the renderers accumulate, `Σ weights[k] · G_k ∗ H`:
    /// `strength / weightSum`, so the glow they add is exactly
    /// `strength · Σ normalizedWeights[k] · G_k ∗ H` — `strength` on a unit-sum field.
    ///
    /// WHY THE NORMALIZATION IS FOLDED HERE AND NOT INTO EACH BOUNCE (N-006). The
    /// obvious form multiplies each blurred bounce by `normalizedWeights[k]` — 4/7,
    /// 2/7, 1/7 — and that is what was tried first. The reference accumulates the field
    /// in an f32 `ImageBuffer`, and 4/7 is not dyadic, so every pixel's field rounded
    /// differently from the shipped one: measured, 51 of the 63 halation proof-sweep
    /// renders changed, by one f32 ULP (5.96e-8). Accumulating with the raw
    /// dyadic weights keeps the f32 field bit-for-bit what it was, and dividing the
    /// gain by `weightSum` in f64 cancels `strengthCalibration` to within an f64 ULP,
    /// which the f32 store does not see. Same arithmetic, no pixel moved.
    public var fieldGain: RGB {
        let s: Double = weightSum
        guard s > 1e-12 else { return strength }
        return strength * (1.0 / s)
    }

    /// The per-channel apply, once the image module has produced the accumulated field
    /// `Σ weights[k] · G_k ∗ H`: `out_c = in_c + fieldGain_c · field_c`.
    public func combine(_ base: RGB, blurred: RGB) -> RGB {
        base + fieldGain * blurred
    }

    // MARK: The GPU form

    // The shader (`KernelLibrary.halationEnergy`) evaluates `highlightEnergy` itself —
    // the same smoothstep in log2 space, from `clipLevel`, `protectEV` and `boostRange`
    // — so there is ONE gate, not a reference and a stand-in.
    //
    // There used to be a stand-in: a hard pedestal `max(E − clip·2⁻², 0)·2^0.3`, said
    // to be "matched at the reference ramp's half-power point". It was matched nowhere.
    // Above the onset it sat a constant 0.308 below the reference, so the GPU rendered
    // 0.612 of the reference's glow at E = 0.5, 0.750 at the clip and NONE at all at
    // E ≤ 0.25, where the reference still returns 0.139 (M09 / C1-01). A sky two stops
    // under the clip glowed in the reference and not in the app. One `log2` and one
    // `exp2` per pixel in a quarter-res glow pass was never worth that.

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

    /// HOW MUCH OF THE THREE LAYERS' INDEPENDENCE REACHES THE PICTURE. 1 is three
    /// fully decorrelated fields; 0 is one shared field wearing three amplitude
    /// envelopes.
    ///
    /// `plateSeed(channel:)` gives a colour stock three independent unit-variance
    /// fields, because that is the physics — three dye layers, three sets of crystals.
    /// What it does not say is how much of that survives development, the print, and
    /// a scan. Laid at full amplitude the answer is arithmetic: three independent
    /// unit fields give σ(luma) = A/√3 and σ(R−G) = A√2, so the chroma noise is
    /// **2.45×** the luminance noise in the model — and **2.06× (R−G) and 2.28×
    /// (B−G)** when measured through the real stage on Portra 400, which is a little
    /// below the model because the per-channel Dmax and the three cell sizes differ.
    /// Portra 400's cells are 0.68/0.85/1.71 px at a
    /// 2560 px preview — sub-display-pixel, so they integrate back to luminance and
    /// the screen never shows it — and 2.13/2.67/5.33 px at 8000. The delivered file
    /// carries coloured speckle that no preview in the app can display.
    ///
    /// Which is the same thing the owner rejected in the creative grain: "the grain is
    /// absolutely ridiculously bad. It just turns into rainbow splotches." That path
    /// answered by collapsing to one field. A stock cannot — its layers ARE its
    /// character — so it gets a fraction instead.
    ///
    /// 1 is what shipped and is reproduced bit-for-bit (see `noiseMixWeights`), so
    /// this is a dial with an identity setting, not a rewrite — and below 1 it takes
    /// the noise OUT of colour rather than moving it into luminance: the mix is scaled
    /// to hold the luminance grain where it was, so the picture's grain looks the same
    /// and its speckle is gone.
    public let chroma: Double

    /// Dye-layer decorrelation surviving into the picture, by stock kind.
    ///
    /// A colour NEGATIVE is printed, and the print's own emulsion re-integrates the
    /// three records; a REVERSAL is the taking film itself, viewed directly, where the
    /// layers stay more separate but the grain is finer to begin with — so the
    /// reversal number is lower because a lot less of it is visible at all. These are
    /// the audit's proposed defaults (docs C2 §3) and they are the first two numbers
    /// in this file that are taste rather than measurement; they are named here, once,
    /// so that when they move they move for every stock at the same time.
    public static let dyeLayerChromaNegative: Double = 0.30
    public static let dyeLayerChromaReversal: Double = 0.15

    /// The two scalars the grain stage mixes the three sampled fields with:
    /// `n'ᵢ = luma·(n_R + n_G + n_B) + own·nᵢ`.
    ///
    /// Derived rather than chosen. Write the mix as `n'ᵢ = (1−χ)·n_L + χ·nᵢ` with
    /// `n_L = k·Σn`, `k = 1/√Var(Σn)`, then divide by `M` — and the whole design is in
    /// what `M` is chosen to hold constant.
    ///
    /// **`M` holds the LUMINANCE amplitude, and the picture's grain therefore does not
    /// change at all — only its colour goes.** That is the point. Removing noise from
    /// colour has to put it somewhere or take it away; there is no convention that
    /// leaves both halves alone. The obvious one, holding each layer's own amplitude,
    /// was tried first and is wrong: the luminance noise rises 51%, because the three
    /// layers stop cancelling each other, and every colour stock's grain gets loudly
    /// more visible at its shipped default. `film.grain.size`'s proof record caught it
    /// — authority 40.1 → 44.1 and the non-monotone hand-back 14.9 → 33.7, both from a
    /// sweep metric that reads luminance. Holding the luminance instead, a photographer
    /// sees exactly what they saw, minus the speckle.
    ///
    /// The arithmetic. The mix's luminance is `Σn·[(1−χ)k + χ/3]`, whose σ is
    /// `(1−χ) + χ/(3k)` since `σ(Σn) = 1/k`; at χ = 1 that is `1/(3k)`. So
    /// `M = 3k(1−χ) + χ`, one expression that gives `√3(1−χ) + χ` for three
    /// independent layers and exactly 1 for a monochrome profile, whose three "layers"
    /// are one field and whose luminance the mix cannot move.
    ///
    /// Folding `k` and `M` into the two weights leaves the kernel one multiply-add per
    /// channel and no square roots, and χ = 1 gives `M = 1`, luma = 0, own = 1 — the
    /// expression is `nᵢ`, bit-for-bit, so the sum of the three samples is not even
    /// formed. A monochrome stock is therefore untouched twice over: it ships at χ = 1,
    /// and `M = 1` would leave it alone at any χ.
    ///
    /// What this convention does cost is per-layer amplitude: 0.60 of what it was at
    /// χ = 0.3, which is the noise that WAS the colour speckle, now not being laid.
    ///
    /// One measured departure from the model, for honesty. The premise is three
    /// INDEPENDENT unit-variance fields; the shipped plates are not quite that.
    /// `plateSeed(channel:)` separates the three seeds by adding a golden-ratio
    /// constant, and the shipped plates come back correlated at r ≈ 0.088 / 0.046 /
    /// −0.038, and a bilinearly sampled plate does not carry exactly the plate's
    /// variance — 1.025 / 1.023 / 0.982 at a 2560 px render. So the luminance is held to
    /// a few percent rather than exactly.
    ///
    /// THE CORRELATION IS SAMPLING NOISE, NOT STRUCTURE, and this comment used to say
    /// the opposite ("16 384 samples, so the first is real"). The 16 384 pixels are not
    /// 16 384 independent samples: the plate's coarsest octave is a lattice of about
    /// 8 × 8 cells and carries most of its variance, so the effective sample count is
    /// about 100 and the null distribution of r has σ ≈ 0.11. Measured over 200 draws
    /// each: plates from UNRELATED random seeds give mean r −0.013, σ 0.106, with 35%
    /// of pairs at |r| ≥ 0.088; plates from `plateSeed` offsets of random bases give
    /// mean −0.00005, σ 0.112, 40.5% at |r| ≥ 0.088. The offset scheme adds no
    /// correlation; the shipped plate is one fixed draw whose r happens to be +0.088
    /// (N-005, retired in the October 2026 verification, V5). Choosing a different
    /// `defaultPlateSeed` for a smaller r would move every grain golden and proof
    /// record for a cosmetic number, and is not done.
    public var noiseMixWeights: (luma: Double, own: Double) {
        let x: Double = Num.clamp(chroma, 0, 1)
        // Three independent unit fields sum to variance 3; three identical ones to 9.
        let k: Double = monochrome ? 1.0 / 3.0 : 1.0 / 3.0.squareRoot()
        let m: Double = 3 * k * (1 - x) + x
        guard m > 1e-12 else { return (luma: 0, own: 1) }
        return (luma: (1 - x) * k / m, own: x / m)
    }

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
        // One field means there is nothing to decorrelate, so the mix is the identity
        // at every value. 1 is written rather than 0 because 1 is the value whose
        // weights are exactly (0, 1) — the sum of the three samples is not even
        // formed, so a creative grain is bit-for-bit what it was.
        self.chroma = 1
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
        // A monochrome emulsion's three "layers" are one field (`plateSeed`), so it
        // takes the identity setting; the two colour numbers are named constants above.
        self.chroma = stock.monochrome ? 1
            : (stock.kind == .reversal ? FilmGrainProfile.dyeLayerChromaReversal
                                       : FilmGrainProfile.dyeLayerChromaNegative)
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
        Swift.max(rawPlateScale(longEdgePixels: longEdgePixels,
                                printSizeInches: printSizeInches), 0.5)
    }

    /// The same cell size WITHOUT the half-pixel floor.
    ///
    /// The floor belongs at the end of the chain, once, on the number that is actually
    /// going to be sampled — not in the middle of it. The per-channel form multiplies
    /// this by `sizeScale`, and the blue record's is 2.0, so flooring first and scaling
    /// after took a sub-half-pixel base up to 0.5 and then doubled it to a full pixel
    /// where one floor gives 0.85. A pixel-wide blue cell at 2560 against 2.67 at 8000
    /// is a 17% coarser blue grain in the fit view than in the delivered file, on
    /// exactly the two stocks a photographer picks for their fineness.
    ///
    /// Private, and the two public forms below floor their own results, so no caller
    /// can accidentally sample an un-floored scale.
    private func rawPlateScale(longEdgePixels: Int, printSizeInches: Double) -> Double {
        let printLongEdgeMM: Double = Swift.max(printSizeInches, 0.1) * 25.4
        let mag: Double = printLongEdgeMM / gateLongEdgeMM
        let pitchOnPrintMM: Double = (pitchMicrons / 1000.0) * mag
        let pixelsPerPrintMM: Double = Double(Swift.max(longEdgePixels, 1)) / printLongEdgeMM
        return pitchOnPrintMM * pixelsPerPrintMM
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
    ///
    /// ONE FLOOR, at the end. This used to read the already-floored `plateScale` and
    /// floor its own product on top, which is a no-op for the red and green records
    /// (`sizeScale` 0.8 and 1.0 — scaling a floored value down still lands on the
    /// floor) and a real distortion for the blue one at 2.0. See `rawPlateScale`.
    public func plateScale(longEdgePixels: Int, printSizeInches: Double, channel: Int) -> Double {
        let i: Int = Swift.min(Swift.max(channel, 0), 2)
        let base: Double = rawPlateScale(longEdgePixels: longEdgePixels,
                                         printSizeInches: printSizeInches)
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

    /// - Parameter renderPixelsPerCell: how many RENDER pixels one plate texel spans,
    ///   or nil to build every octave regardless.
    ///
    ///   BAND-LIMITING, and it is the difference between a preview that is the
    ///   low-pass of the export and one that is a different pattern (C2-01b).
    ///
    ///   The plate is four octaves of value noise on a 128 texel field: octave `k` has
    ///   features spanning `128 / (8 << k)` texels, so 16, 8, 4 and 2. Multiplied by
    ///   this scale they become render pixels, and an octave whose features fall below
    ///   two render pixels is past Nyquist — it cannot be sampled, so what reaches the
    ///   screen is aliasing rather than grain.
    ///
    ///   That is not a hypothetical. Velvia 50's green record is 0.5 render pixels per
    ///   texel at the 2560 px working resolution, so its finest octave has ONE-pixel
    ///   features in the fit view; at 8000 the same octave is 2.67 pixels and resolves
    ///   cleanly. The preview was showing false high-frequency detail the delivered file
    ///   does not contain, which is most of the parity loss the grain audit measured.
    ///
    ///   Dropping an octave costs no amplitude: the plate is renormalised to unit
    ///   variance by measurement at the end, so the surviving octaves are scaled back up
    ///   to the same energy. The texture gets coarser and correct rather than quieter.
    public static func plate(size: Int, seed: UInt64, sigma: Double,
                             persistence: Double = FilmGrainProfile.defaultPersistence,
                             renderPixelsPerCell: Double? = nil)
        -> [Float] {
        let n: Int = Swift.max(size, 2)
        let count: Int = n * n
        guard sigma.isFinite, sigma > 0 else { return [Float](repeating: 0, count: count) }
        // Every preview graph build bakes this plate again — three channels, up to four
        // octaves of 128² lattice hashes — for arguments that do not move during a drag:
        // the seed and persistence are the profile's, sigma is 1 and the cell size only
        // changes with the ladder rung. The bake is a pure function of exactly these
        // arguments, so a remembered one is the same Floats. Keyed on the RAW arguments,
        // before the clamps below, which is at least as fine as the output.
        let memoKey = GrainPlateMemo.Key(size: size, seed: seed, sigma: sigma.bitPattern,
                                         persistence: persistence.bitPattern,
                                         perCell: renderPixelsPerCell?.bitPattern)
        if let remembered = FilmGrainProfile.plateMemo.lookup(memoKey) { return remembered }
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
            // Past Nyquist for the resolution this plate will be sampled at? Then it is
            // aliasing, not grain. See `renderPixelsPerCell`.
            if let perCell = renderPixelsPerCell, perCell.isFinite, perCell > 0,
               Double(n) / Double(freq) * perCell < 2 {
                octave += 1
                continue
            }
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
        FilmGrainProfile.plateMemo.store(out, for: memoKey)
        return out
    }

    /// The baked plates `plate(size:seed:sigma:persistence:renderPixelsPerCell:)` has
    /// handed out recently. See `GrainPlateMemo`.
    static let plateMemo = GrainPlateMemo()

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

/// A small, locked memo of baked grain plates, keyed on the exact bits of every argument
/// the bake reads. Both renderers and every thread share it: `PipelineRenderer` builds
/// graphs from the preview, EDR and export paths at once, which is why it is locked the
/// way `PlanKeyMemo` is. The bake runs OUTSIDE the lock, so two threads missing on the
/// same key both bake and the second store is a no-op — the same bytes either way.
///
/// Sixteen entries, first in first out: three channels times a few ladder rungs is what
/// a session revisits, and a 128² plate is 64 KB, so the whole memo is about 1 MB. A
/// returned `[Float]` is copy-on-write, so no caller can change what is remembered.
final class GrainPlateMemo: @unchecked Sendable {
    struct Key: Hashable {
        let size: Int
        let seed: UInt64
        let sigma: UInt64
        let persistence: UInt64
        let perCell: UInt64?
    }

    static let capacity: Int = 16

    private let lock = NSLock()
    private var entries: [Key: [Float]] = [:]
    private var order: [Key] = []

    func lookup(_ key: Key) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ values: [Float], for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[key] == nil else { return }
        entries[key] = values
        order.append(key)
        while order.count > GrainPlateMemo.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    /// How many plates are held — for the tests that hold the bound.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
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
    /// - Parameter renderPixelsPerCell: this layer's own `plateScale` at the resolution
    ///   being rendered, or nil to build every octave. Both renderers must pass the SAME
    ///   value or their plates differ and gpu-parity fails — which is the check that
    ///   keeps them honest.
    public func plate(channel: Int, size: Int = GrainPlan.plateSize,
                      seed: UInt64 = FilmGrainProfile.defaultPlateSeed,
                      renderPixelsPerCell: Double? = nil) -> [Float] {
        FilmGrainProfile.plate(size: size,
                               seed: profile.plateSeed(channel: channel, base: seed),
                               sigma: 1.0,
                               persistence: profile.persistence,
                               renderPixelsPerCell: renderPixelsPerCell)
    }

    /// The two scalars the grain stage mixes the three sampled fields with — the
    /// profile's, surfaced on the plan because the plan is what both renderers hold.
    /// `RenderGraph` hands them to `lumenGrain` and `ReferenceRenderer` performs the
    /// same multiply-add; they must be the same two numbers or gpu-parity fails.
    public var noiseLumaWeight: Double { profile.noiseMixWeights.luma }
    public var noiseOwnWeight: Double { profile.noiseMixWeights.own }

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

// MARK: - The chain's shape functions

/// The roll-offs every stage is built from. `soft(u, τ)`: softplus in log10 units for
/// τ > 0 (→ u for u ≫ 0, → 0 exponentially for u ≪ 0), the hyperbola
/// (u + √(u² + τ²))/2 for τ < 0 (→ 0 like τ²/4|u|). `softMin`/`softMax` clamp `a` to
/// `b` through them. All monotone and C∞.
enum FilmShape {
    @inline(__always) static func soft(_ u: Double, _ tau: Double) -> Double {
        if tau < 0 {
            return 0.5 * (u + (u * u + tau * tau).squareRoot())
        }
        let t: Double = Swift.max(tau, 1e-6)
        let z: Double = u / t
        if z > 30 { return u }
        return t * log10(1 + pow(10.0, z))
    }

    @inline(__always) static func softMin(_ a: Double, _ b: Double, _ tau: Double) -> Double {
        b - soft(b - a, tau)
    }

    @inline(__always) static func softMax(_ a: Double, _ b: Double, _ tau: Double) -> Double {
        b + soft(a - b, tau)
    }

    /// Hyperbolic softplus with an explicit ε, for the push shadow crush.
    @inline(__always) static func hyper(_ u: Double, _ eps: Double) -> Double {
        0.5 * (u + (u * u + eps * eps).squareRoot())
    }
}

/// Everything the per-pixel chain needs, resolved at build time.
private struct SolvedChain: Sendable {
    var reversal: Bool
    var monochrome: Bool
    // Taking stage.
    var gamma: RGB
    var dMin: RGB
    /// Negative: log10 exposure of each channel's toe. Reversal: unused.
    var toeLog: RGB
    /// Negative: shoulder density. Reversal: tone ceiling.
    var top: RGB
    var lowSoftness: Double
    var highSoftness: Double
    // Print stage (negatives).
    var printGamma: RGB
    var printDMin: RGB
    var printDMax: RGB
    var printLow: Double
    var printHigh: Double
    // Colour in density.
    var coupling: Mat3
    var shadowTint: RGB
    var highlightTint: RGB
    /// Mid-grey's density on the taking stage, per channel — the tint weights' origin.
    var greyDensity: RGB
    /// The taking stage's deepest-black density per channel (a negative's coupled fog,
    /// a slide's ceiling), where the shadow tint has faded back out.
    var blackDensity: RGB
    // Exposure.
    var inset: Mat3
    var panchromatic: RGB
    /// Stops of light into the taking stage (film exposure − push underexposure); 0 for
    /// a slide, whose film exposure is applied to the scene instead.
    var shift: Double
    /// Push crush: display level printed down to black (0 = none).
    var crush: Double
    var color: FilmColor
    // Calibration.
    var gain: RGB
    var black: RGB
    var white: RGB
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
    /// EV into the stock, −2…+3. On a negative it is NOT display brightness: the lab
    /// prints mid-grey back to mid-grey and only the stock's latitude shows (pastel
    /// highlights over, fogged shadows under). On a slide it is scene exposure.
    public let filmExposure: Double
    /// Push / pull in stops, inside the stock's range (`FilmPushResponse.range`).
    /// Underexposure developed longer: steeper, harder highlights, the unrecorded
    /// shadows printed down to black; scales grain amount and plate scale.
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

    /// The display floor the film picture's black sits on — the neutral rendering's own
    /// black target (`DisplayTransformParams.blackTarget`, 0.0152 % of SDR white), so a
    /// stock's deepest black is the same black as the base rendering's, not a
    /// lifted grey and not a crushed 0.
    static let blackFloor: Double = 0.0152 / 100.0

    /// Density span over which the crossover tints reach full weight either side of
    /// mid-grey.
    static let tintReach: Double = 1.2

    /// Push crush softness, as a fraction of the crush level.
    static let crushSoftness: Double = 0.7

    /// The path to white, in stops of exposure into the stock: through the mid-tones the
    /// colour rides the stock's own tone curve with its ratios kept, and over this
    /// range it hands over to the per-channel curve, so a highlight bleaches to white
    /// the way a print does instead of staying saturated at paper white.
    static let pathToWhiteStart: Double = 0.0
    static let pathToWhiteEnd: Double = 5.0

    /// Mid-grey's density on a slide (it transmits 18 %).
    static let reversalGreyDensity: Double = FilmCharacteristic.midGreyAnchor

    /// The hue reference: the Neutral display transform at SDR white. Through the
    /// mid-tones it keeps a colour's ratios (its hue is the inset/outset primaries'),
    /// and toward white it walks the per-channel path — so a film colour sits on the
    /// hue the neutral rendering gives the same scene colour, plus the stock's own
    /// authored shifts. Fixed — never the recipe's base transform — so the film
    /// picture at Strength 100 is the same on every base.
    static let hueReference: DisplayTransform = DisplayTransform(DisplayTransformParams.neutral,
                                                                 space: .rec2020)

    /// The sRGB gamut in OKLab, for the stock saturation's reach, on a deliberately
    /// COARSE grid (30° × 0.2 L): sRGB because that is the gamut nearly every print,
    /// scan and export ends up in (a boost relative to Rec.2020's edge pushed skies
    /// through sRGB and the encoder clipped them flat), coarse because the gain is
    /// baked into a 33-point finish table and an exact boundary's cusps put creases in
    /// it the table cannot follow. The fine boundary still does the actual gamut map.
    static let saturationBoundary: Gamut.Boundary =
        Gamut.Boundary(hueSteps: 12, lightnessSteps: 6,
                       context: OKLabTransform.Context(space: .srgb))

    /// Paper black is neutral: over the last few codes above the floor the picture's
    /// chroma fades out (to the floor × this), so a dark tint cannot turn into a
    /// channel below black on the way to the display's primaries.
    static let neutralBlackSpan: Double = 20.0

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
        let found: FilmStock? = FilmStock.named(recipe.stock)
        // Push is clamped to the STOCK's range (Velvia 50: −½…+1 per its datasheet).
        let range: ClosedRange<Double> = found?.push.range ?? -1...2
        let push: Double = Num.clamp(recipe.pushPull, range.lowerBound, range.upperBound)
        let blend: Double = Num.clamp(recipe.amount / 100.0, 0, 1)
        let exposure: Double = Num.clamp(filmExposure, -2, 3)

        self.recipe = recipe
        self.stock = found
        self.displayWhite = white
        self.filmExposure = exposure
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
            // A negative is printed to mid-grey whatever its exposure, so the exposure
            // is part of the solve; a slide's exposure is scene brightness, applied in
            // `apply`, and the same solved slide serves every exposure.
            let solvedExposure: Double = s.kind == .negative ? exposure : 0
            let key: SolveKey = SolveKey(stockID: s.id,
                                         push: push.bitPattern,
                                         exposure: solvedExposure.bitPattern,
                                         grainScale: grainScale.bitPattern,
                                         white: FilmChain.paperWhite.bitPattern)
            self.solved = FilmChain.solveMemo.chain(for: key) {
                FilmChain.build(s, push: push, exposure: solvedExposure,
                                grainScale: grainScale)
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
        // display-gamut map that goes with one. At partial film strength the base is
        // most of what you see.
        let base: RGB = neutral.apply(c, gamut: Gamut.sharedBoundary)
        guard let s = solved else { return base }
        // A slide's Film Exposure is scene exposure (there is no print to re-level
        // it); a negative's is inside the solve, where the printer re-levels it.
        let scene: RGB = s.reversal ? c * pow(2.0, filmExposure) : c
        let film: RGB = FilmChain.picture(scene, s)
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

    /// Halation parameters at a render size, from this recipe's Amount, Size and
    /// Redness. Never nil: without a stock the strengths are zero, which the caller's
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

    /// Every input `build` reads, as bits. `stockID` stands for the whole stock because
    /// `found` only ever comes from `FilmStock.named`, i.e. from the static `index` of
    /// `let` constants: one id, one set of curves. The Doubles are the clamped values
    /// handed to `build`, compared by bit pattern so not even ±0 can share an entry.
    fileprivate struct SolveKey: Equatable {
        let stockID: String
        let push: UInt64
        let exposure: UInt64
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
                              exposure: Double,
                              grainScale: Double) -> SolvedChain {
        let reversal: Bool = stock.kind == .reversal
        let n: FilmCharacteristic = stock.negative
        let gammaScale: Double = 1.0 + (push >= 0 ? stock.push.gammaPerStop : stock.push.pullGammaPerStop) * push
        let gamma: RGB = RGB(Swift.max(n.gamma.r * gammaScale, 0.02),
                             Swift.max(n.gamma.g * gammaScale, 0.02),
                             Swift.max(n.gamma.b * gammaScale, 0.02))
        let shift: Double = reversal ? 0 : exposure - push * stock.push.underexposurePerStop
        let log2: Double = log10(2.0)
        let greyLog: Double = -FilmCharacteristic.midGreyAnchor

        var toeLog: RGB = RGB.zero
        var top: RGB = RGB.zero
        for i in 0..<3 {
            let toe: Double = n.toeStops - n.logOffset[i]
            toeLog[i] = greyLog - toe * log2
            top[i] = reversal
                ? (n.toneCeiling ?? n.dMax)[i]
                // The shoulder density is the emulsion's, set at normal development:
                // pulling flattens the slope but does not take away the densest
                // highlight the lab prints to white (that was grey whites at pull −1).
                : n.dMin[i] + n.gamma[i] * (toe + n.shoulderStops) * log2
        }

        let p: FilmCharacteristic = stock.printCurve ?? n
        let printLow: Double = p.lowSoftness
            * (1.0 - (push >= 0 ? stock.push.printToePerStop : stock.push.printToePerPullStop) * push)

        let a: FilmColor = stock.color
        let inset: RGBColorSpace = DisplayTransform.insetSpace(.rec2020,
                                                               attenuation: a.insetAttenuation,
                                                               rotation: a.insetRotation)

        var s: SolvedChain = SolvedChain(
            reversal: reversal,
            monochrome: stock.monochrome,
            gamma: gamma,
            dMin: n.dMin,
            toeLog: toeLog,
            top: top,
            lowSoftness: n.lowSoftness,
            highSoftness: n.highSoftness,
            printGamma: p.gamma,
            printDMin: p.dMin,
            printDMax: p.dMax,
            printLow: printLow,
            printHigh: p.highSoftness,
            coupling: FilmChain.couplingMatrix(interlayer: stock.crossover.interlayer,
                                               coupler: stock.crossover.coupler),
            shadowTint: stock.crossover.shadowTint + stock.crossover.pushTint * push,
            highlightTint: stock.crossover.highlightTint,
            greyDensity: RGB.zero,
            blackDensity: RGB.zero,
            inset: inset.matrix(to: .rec2020),
            panchromatic: stock.panchromatic,
            shift: shift,
            crush: stock.push.shadowCrushPerStop * Swift.max(push, 0),
            color: stock.color,
            gain: RGB.zero,
            black: RGB.zero,
            white: RGB.zero,
            grainScale: Swift.max(grainScale, 0))

        if reversal {
            s.greyDensity = RGB(gray: FilmChain.reversalGreyDensity)
            s.blackDensity = top
            s.black = RGB(pow(10.0, -top.r), pow(10.0, -top.g), pow(10.0, -top.b))
            let w: RGB = n.dMin + n.whiteDelta
            s.white = RGB(pow(10.0, -w.r), pow(10.0, -w.g), pow(10.0, -w.b))
        } else {
            let greyX: Double = log10(DisplayTransform.midGrey) + shift * log2
            var dg: RGB = RGB.zero
            for i in 0..<3 {
                dg[i] = FilmChain.negativeDensity(greyX, s, i)
            }
            s.greyDensity = s.coupling.apply(dg)
            s.blackDensity = s.coupling.apply(n.dMin)
            s.black = RGB(pow(10.0, -p.dMax.r), pow(10.0, -p.dMax.g), pow(10.0, -p.dMax.b))
            let w: RGB = p.dMin + p.whiteDelta
            s.white = RGB(pow(10.0, -w.r), pow(10.0, -w.g), pow(10.0, -w.b))
        }
        return FilmChain.solveGains(s)
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
    /// For a print chain the gain is the enlarger lamp (the printer lights), downstream
    /// of every channel-mixing step, so one bisection per channel is exact — and,
    /// because Film Exposure is part of the solve, an over- or underexposed negative is
    /// printed back to mid-grey the way a lab prints it. For a transparency the gain is
    /// scene-side and the couplers mix channels after it, so the sweeps iterate; six
    /// land every shipped stock inside 1e-9. Build-time only.
    private static func solveGains(_ base: SolvedChain) -> SolvedChain {
        var s: SolvedChain = base
        let grey: RGB = RGB(gray: DisplayTransform.midGrey)
        let target: Double = DisplayTransform.midGrey
        let sweeps: Int = s.reversal ? 6 : 1
        var sweep: Int = 0
        while sweep < sweeps {
            for i in 0..<3 {
                let x: Double = FilmChain.bisect(target: target, lo: -12, hi: 12, steps: 60) { logGain in
                    var trial: SolvedChain = s
                    trial.gain[i] = logGain
                    return FilmChain.tone(grey, trial)[i]
                }
                s.gain[i] = x
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

    /// A negative's density at log10 exposure `x`, channel `i`: fog, a toe into the
    /// straight line, and a shoulder far above grey.
    @inline(__always)
    private static func negativeDensity(_ x: Double, _ s: SolvedChain, _ i: Int) -> Double {
        let d: Double = s.dMin[i] + s.gamma[i] * FilmShape.soft(x - s.toeLog[i], s.lowSoftness)
        return FilmShape.softMin(d, s.top[i], s.highSoftness)
    }

    /// A slide's density at log10 exposure `x` (gain applied): falling through mid-grey
    /// at its gamma into clear film, rising into its tonal ceiling.
    @inline(__always)
    private static func reversalDensity(_ x: Double, _ s: SolvedChain, _ i: Int) -> Double {
        let lin: Double = FilmChain.reversalGreyDensity
            - s.gamma[i] * (x + FilmCharacteristic.midGreyAnchor)
        let d: Double = FilmShape.softMin(lin, s.top[i], s.highSoftness)
        return FilmShape.softMax(d, s.dMin[i], s.lowSoftness)
    }

    /// Scene → the stock's per-channel picture, display-linear, before colour anchoring.
    /// Negative → couplers → crossover → transmittance → print → black/white levels.
    private static func tone(_ scene: RGB, _ s: SolvedChain) -> RGB {
        let c: RGB = RGB(Swift.max(scene.r, 0), Swift.max(scene.g, 0), Swift.max(scene.b, 0))
        var e: RGB
        if s.monochrome {
            let y: Double = s.panchromatic.r * c.r + s.panchromatic.g * c.g + s.panchromatic.b * c.b
            e = RGB(gray: Swift.max(y, 0))
        } else {
            let m: RGB = s.inset.apply(c)
            e = RGB(Swift.max(m.r, 0), Swift.max(m.g, 0), Swift.max(m.b, 0))
        }
        let scale: Double = pow(2.0, s.shift)
        var d: RGB = RGB.zero
        for i in 0..<3 {
            var x: Double = log10(Swift.max(e[i] * scale, 1e-30))
            if s.reversal {
                x += s.gain[i]
                d[i] = FilmChain.reversalDensity(x, s, i)
            } else {
                d[i] = FilmChain.negativeDensity(x, s, i)
            }
        }
        d = s.coupling.apply(d)

        // Crossover, each channel weighted by its own density (see `FilmCrossover`):
        // `pos` is the density distance from mid-grey toward the highlights. The
        // shadow tint fades back out over the last 0.3 density into the deepest black,
        // because paper black is neutral.
        for i in 0..<3 {
            let pos: Double = s.reversal ? s.greyDensity[i] - d[i] : d[i] - s.greyDensity[i]
            let floorPos: Double = s.reversal ? s.greyDensity[i] - s.blackDensity[i]
                                              : s.blackDensity[i] - s.greyDensity[i]
            let shadow: Double = (1.0 - Num.smoothstep(-FilmChain.tintReach, 0, pos))
                * Num.smoothstep(floorPos, floorPos + 0.3, pos)
            let highlight: Double = Num.smoothstep(0, FilmChain.tintReach, pos)
            d[i] += s.shadowTint[i] * shadow + s.highlightTint[i] * highlight
        }

        // Density → transmittance. This is the step that makes colour subtractive.
        var t: RGB = RGB(pow(10.0, -d.r), pow(10.0, -d.g), pow(10.0, -d.b))
        if !s.reversal {
            // The print: exposure = the light the printer pushes through the negative.
            for i in 0..<3 {
                let y: Double = log10(Swift.max(t[i], 1e-30)) + s.gain[i]
                var pd: Double = s.printGamma[i] * y
                pd = FilmShape.softMin(pd, s.printDMax[i], s.printHigh)
                pd = FilmShape.softMax(pd, s.printDMin[i], s.printLow)
                t[i] = pow(10.0, -pd)
            }
        }

        // Levels: paper (or clear film) is white, maximum density is the black floor.
        var out: RGB = RGB.zero
        for i in 0..<3 {
            let span: Double = s.white[i] - s.black[i]
            var v: Double = abs(span) < 1e-15 ? 0 : Swift.min((t[i] - s.black[i]) / span, 1)
            if s.crush > 0 {
                let eps: Double = s.crush * FilmChain.crushSoftness
                let zero: Double = FilmShape.hyper(-s.crush, eps)
                v = (FilmShape.hyper(v - s.crush, eps) - zero)
                    / (FilmShape.hyper(1 - s.crush, eps) - zero)
            }
            out[i] = v * (1 - FilmChain.blackFloor) + FilmChain.blackFloor
        }
        return out
    }

    /// The stock's picture of `scene`: its tone, its path to white, its colour, inside
    /// the display gamut. Spans [floor, paper white] — paper white is SDR white at every
    /// display peak (`paperWhite`).
    private static func picture(_ scene: RGB, _ s: SolvedChain) -> RGB {
        let v: RGB = FilmChain.tone(scene, s)
        let formed: RGB = s.monochrome ? v : FilmChain.colour(scene, v, s)
        // Inside paper white and paper black, with black itself neutral.
        let floor: Double = FilmChain.blackFloor
        let out: RGB = RGB(Num.clamp(formed.r, floor, 1), Num.clamp(formed.g, floor, 1),
                           Num.clamp(formed.b, floor, 1))
        let y: Double = filmLumaWeights.r * out.r + filmLumaWeights.g * out.g
            + filmLumaWeights.b * out.b
        let k: Double = Num.smoothstep(floor, floor * FilmChain.neutralBlackSpan, y)
        return RGB(gray: y) + (out - RGB(gray: y)) * k
    }

    /// The path to white and the stock's colour on top of its tone `v`.
    private static func colour(_ scene: RGB, _ v: RGB, _ s: SolvedChain) -> RGB {
        let c: RGB = RGB(Swift.max(scene.r, 0), Swift.max(scene.g, 0), Swift.max(scene.b, 0))
        // A grey stays exactly the stock's grey (with its crossover).
        if c.r == c.g && c.g == c.b { return v }

        // The path to white: ratio-preserving on the stock's own tone through the
        // mid-tones, per-channel by the shoulder.
        let m: RGB = s.inset.apply(c)
        let ins: RGB = RGB(Swift.max(m.r, 0), Swift.max(m.g, 0), Swift.max(m.b, 0))
        let peak: Double = ins.maxComponent
        var formed: RGB = v
        if peak > 1e-12 {
            let greyTone: RGB = FilmChain.tone(RGB(gray: peak), s)
            let ratio: RGB = (ins / peak) * greyTone
            let ev: Double = log2(peak / DisplayTransform.midGrey) + s.shift
            let u: Double = Num.saturate((ev - FilmChain.pathToWhiteStart)
                                         / (FilmChain.pathToWhiteEnd - FilmChain.pathToWhiteStart))
            formed = v.mix(ratio, 1 - u * u)
        }

        // Colour anchoring, relative to the stock's own (tinted) grey of the same
        // luminance: hue from the neutral rendering plus the stock's lobes, chroma the
        // film's own times the stock's saturation.
        let ctx: OKLabTransform.Context = OKLabTransform.working
        let luma: Double = filmLumaWeights.r * c.r + filmLumaWeights.g * c.g + filmLumaWeights.b * c.b
        let grey: RGB = FilmChain.tone(RGB(gray: luma), s)
        let lab: OKLab = ctx.toLab(RGB(Swift.max(formed.r, 0), Swift.max(formed.g, 0),
                                       Swift.max(formed.b, 0)))
        let labGrey: OKLab = ctx.toLab(grey)
        let da: Double = lab.a - labGrey.a
        let db: Double = lab.b - labGrey.b
        var chroma: Double = (da * da + db * db).squareRoot()
        guard chroma > 1e-12 else {
            return Gamut.softClip(formed, boundary: Gamut.sharedBoundary)
        }

        let ref: OKLab = ctx.toLab(FilmChain.hueReference.apply(c))
        let refHue: Double = atan2(ref.b, ref.a) * 180 / .pi
        let look: FilmColor = s.color
        // Near neutral the lobes fade out and the hue follows the film's own delta.
        let w: Double = look.lobeChromaTaper > 0
            ? Num.smoothstep(0, look.lobeChromaTaper, (ref.a * ref.a + ref.b * ref.b).squareRoot())
            : 1.0
        let filmHue: Double = atan2(db, da) * 180 / .pi
        let target: Double = refHue + w * look.hueShift(at: refHue)
        var turn: Double = (target - filmHue + 180).truncatingRemainder(dividingBy: 360)
        if turn < 0 { turn += 360 }
        let hue: Double = filmHue + w * (turn - 180)
        var k: Double = look.chroma * (1 + (look.lobeGain(at: refHue) - 1) * w)
        k = 1 + (k - 1) * Num.smoothstep(look.darkFadeLow, look.darkFadeHigh, lab.L)
        k *= 1 - look.highlightPastel * Num.smoothstep(0.62, 0.95, lab.L)
        if k > 1 {
            let edge: Double = FilmChain.saturationBoundary.maxChroma(
                L: Num.clamp(lab.L, 1e-4, 1 - 1e-4), hue: Num.wrapHue(hue))
            let x: Double = Swift.min(chroma / Swift.max(edge, 1e-6), 1.0)
            chroma *= 1 + (k - 1) * pow(1 - x, look.saturationFalloff)
        } else {
            chroma *= k
        }
        let h: Double = hue * .pi / 180
        let out: RGB = ctx.toRGB(OKLab(L: lab.L,
                                       a: labGrey.a + chroma * cos(h),
                                       b: labGrey.b + chroma * sin(h)))
        let clamped: RGB = RGB(Swift.max(out.r, 0), Swift.max(out.g, 0), Swift.max(out.b, 0))
        return Gamut.softClip(clamped, boundary: Gamut.sharedBoundary)
    }
}
