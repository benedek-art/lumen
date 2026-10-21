// ColorEngine.swift
// The colour-correction stage (docs/14 S9) as one engine: primaries remap, the 8-band
// Colour Mixer, Point Colour swatches, Vibrance/Saturation, and the B&W mix — in the
// pipeline's order, as a single pure RGB→RGB function.
//
// Why one engine rather than five: every tool here shares the same three pieces of
// machinery, and splitting them is how colour stacks drift. They share
//   · the band partition of unity (Mixer and B&W are literally the same 8 weights),
//   · the chroma gate, so near-neutral pixels — whose hue is numerically noise — are
//     never rotated by a hue-selective tool,
//   · the variance-compression kernel, which is Mixer Uniformity and Point Colour
//     Variance seen from two sides (docs/06 brief §2.4).
//
// Which perceptual model each tool uses is a decision, not a detail (docs/14 §5.4):
//   · Hue-selective tools (Mixer, Point Colour) work in OKLCh. Their luminance moves
//     hold C *literally* constant — darkening a blue sky must not desaturate it, which
//     is invariant #1 and the single most visible differentiator vs LrC.
//   · Saturation-class tools (Vibrance, Saturation) work in Lumen UCS, where chroma
//     moves hold H-K-corrected perceived brightness constant — invariant #2, and the
//     reason saturated blues here do not read as if they dimmed.
// The one deliberate exception is the subtractive branch of Saturation, which darkens
// as it saturates *on purpose*: that is the whole point of the density model, and it is
// reached only through the user's `density` dial. The additive path it blends against
// still holds J exactly, so `density = 0` is a chroma move at strictly constant H-K
// brightness J. J is not working-space luminance Y: see the negative-Saturation note in
// `applyVibranceSaturation`.
//
// The stage does NOT clip to gamut. Display-gamut mapping is the last colour
// operation inside S14 (docs/14 §2) and belongs there, where "the display" finally
// means something and values are display-normalized. Doing it here ran a
// display-domain operation on unbounded scene-referred data, and `Gamut.softClip`'s
// own `L < 1` guard turned it into a step function of exposure.

import Foundation

public struct ColorEngine: Sendable {

    // MARK: - Inputs

    public let mixer: Mixer
    public let pointColors: [PointColor]
    public let color: ColorAdjust
    public let primaries: Primaries
    public let bw: BlackAndWhite?
    public let context: OKLabTransform.Context

    /// The B&W band mix, always 8 sanitized values, present whether or not the
    /// treatment is on. The engine-side half of the state-preservation fix (docs/06
    /// brief §7.3): nothing in the colour path reads or writes Mixer state on behalf of
    /// B&W — the Mixer runs identically in both treatments — so toggling the treatment
    /// is lossless as far as rendering is concerned.
    ///
    /// The recipe now holds the other half. `BlackAndWhite.enabled` is what says whether
    /// the mix renders, so the mix stays in `look.bw` while it is switched off instead of
    /// being kept alive by whichever panel happened to be on screen.
    public let blackAndWhiteBands: [Double]

    /// Measured chroma-weighted mean hue per band, if the renderer has image statistics
    /// (docs/06 brief §1.6). `nil` falls back to the user's own core arc — see
    /// `bandTargetHue(_:)`.
    ///
    /// WIRED, at last (docs/23 audit queue item 12; it spent two audits as a let with
    /// a reader and no writer): `PipelineRenderer.measuredBandMeanHues` measures each
    /// file once off a small neutral decode and threads the result through
    /// `RenderPlan(bandMeanHues:)` into both this engine and the colour-grade table's
    /// cache key, on every path that renders pixels — preview, export, HDR pair, the
    /// reference fallback, and both mask-stage taps. So Uniformity converges on the
    /// sky's own 250° blues instead of dragging them toward the 254.2° band centre as
    /// a body. The basis (a NEUTRAL decode, so the target holds still while editing)
    /// and its limitation (a strong user WB change shifts hues off the measured
    /// basis) are recorded at the producer and in docs/27 §2.
    public let bandMeanHues: [Double]?

    // MARK: - Derived state

    private let bands: [MixerBand]
    /// The eight bands' ring geometry, resolved once. The Mixer reads these; B&W does
    /// not — see `applyBlackAndWhite`.
    public let arcs: [BandArc]
    private let uniformity: Double
    private let mixerIsIdentity: Bool
    private let swatches: [Swatch]
    private let remap: Mat3
    private let remapIsIdentity: Bool
    private let tintA: Double
    private let tintB: Double
    private let tintIsIdentity: Bool
    private let bwEnabled: Bool
    private let bwHasBands: Bool
    private let lumaWeights: RGB

    // MARK: - Band model (docs/06 brief §1.1–1.2)

    public static let bandCount: Int = 8

    /// What each band is CALLED, in the wire format's fixed structural order.
    ///
    /// B1-08. These were LrC's eight names, and two of them named a colour their band is
    /// nowhere near. The bands sit 45° apart in OKLCh anchored on sRGB red; the names were
    /// inherited from a different product with a different geometry, and nothing had ever
    /// checked one against the other. Measured — HSV hue of `ProofFrames.bandCentreSRGB`,
    /// the sRGB that sits on each centre, against the conventional sRGB of the name it
    /// carried:
    ///
    ///     band  centre       was       off by    is now    off by
    ///     0     #FF0000      Red         0.0°    Red         0.0°
    ///     1     #FFAC00      Orange     10.4°    Orange     10.4°
    ///     2     #DCFF00      Yellow      8.2°    Yellow      8.2°
    ///     3     #00FFB8      Green      43.3°    Mint        1.4°
    ///     4     #00E5FF      Aqua        6.1°    Aqua        6.1°
    ///     5     #0087FF      Blue       31.8°    Azure       1.9°
    ///     6     #9000FF      Purple      3.8°    Purple      3.8°
    ///     7     #FF00BD      Magenta    15.5°    Magenta    15.5°
    ///
    /// TWO RENAMES AND NOT EIGHT, on a rule rather than on taste: a band is renamed when
    /// its name sits more than HALF A BAND (22.5°) from the centre, because past that the
    /// name is describing the neighbouring band's territory. "Green" was almost a whole
    /// band out. The five left alone are all inside half a band, and for Magenta no
    /// candidate is materially better — Pink is 8.5° and Rose 14.6°, so it is a swap, not
    /// a fix, and Magenta is the established vocabulary for a mixer.
    ///
    /// THE CENTRES DO NOT MOVE, and that is the whole point of doing it this way. Moving
    /// them is the fix docs/audit-2026-09/w2/B1.md:297 describes, and it costs a
    /// `pipelineVersion` bump with a badged per-photo migration, because every recipe that
    /// ever touched the mixer would render differently. Renaming costs nothing: these
    /// strings reach `ColorPanel` and one status message and are not in the wire format —
    /// the recipe stores bands POSITIONALLY. The owner chose this trade explicitly.
    ///
    /// WHAT IT DOES NOT FIX, said here because a truthful label is not the same as a
    /// complete instrument: there is now no band called Green, and that is honest rather
    /// than sloppy — the centres are 68.2° and 163.3° in HSV terms, and ordinary green
    /// sits in the 95° gap between them, belonging to neither. Only re-anchoring closes
    /// that, and re-anchoring is the migration above. The way to find the band for a
    /// colour meanwhile is the picker — click the colour in the photograph and the band
    /// selects itself (`dominantBand(for:)`), which is exactly the affordance that exists
    /// because these names were never reliable.
    public static let bandNames: [String] = [
        "Red", "Orange", "Yellow", "Mint", "Aqua", "Azure", "Purple", "Magenta"
    ]

    /// Anchor: the OKLCh hue of sRGB pure red. Golden-locked — changing this or the 45°
    /// step is a pipelineVersion bump, because it moves what every saved recipe means.
    public static let bandAnchorDegrees: Double = 29.23
    public static let bandSpacingDegrees: Double = 45.0

    /// Band centres, 45° apart so the Mixer and the Hue Equalizer are one parameter set
    /// viewed two ways (D3: the Equalizer's "8 fixed, equally spaced hues").
    public static let bandHueCentres: [Double] = {
        var v: [Double] = []
        v.reserveCapacity(ColorEngine.bandCount)
        for i in 0..<ColorEngine.bandCount {
            v.append(Num.wrapHue(ColorEngine.bandAnchorDegrees
                                 + ColorEngine.bandSpacingDegrees * Double(i)))
        }
        return v
    }()

    /// Core half-arc and feather extent, at the DEFAULT geometry. Cores tile the circle
    /// exactly (±22.5° at 45° spacing) and the feathers overlap the neighbours, which is
    /// what makes the normalized weights C¹ everywhere: no wedge edges exist, so the LrC
    /// PV6 banding class of artifact is structurally impossible rather than merely
    /// mitigated. `MixerBand.defaultCore`/`defaultFeather` are derived from these.
    public static let bandCoreDegrees: Double = 22.5
    public static let bandFeatherDegrees: Double = 15.0

    /// Bounds on the user's four ring handles (docs/05: draggable core + per-side
    /// feather, "fully visual, no hidden numeric range").
    public static let bandCoreMinDegrees: Double = 5.0
    public static let bandCoreMaxDegrees: Double = 44.0
    public static let bandFeatherMinDegrees: Double = 2.0
    public static let bandFeatherMaxDegrees: Double = 60.0

    /// The invariant that keeps the partition of unity a partition: every band must
    /// reach at least this far to each side.
    ///
    /// `bandWeights` has a fallback for the case where every band's weight at some hue
    /// is zero — it hands the whole weight to the nearest band. That branch is a HARD
    /// EDGE, the one thing this band model exists not to have, and with fixed geometry
    /// it was unreachable. Draggable handles make it reachable, so the sanitizer closes
    /// the door instead: cores sit 45° apart, so a reach of more than 22.5° per side
    /// means every hue is strictly inside at least one band's falloff and the sum is
    /// never zero. The fallback stays as a guard against a corrupt decode, not as a
    /// state the ring can be dragged into.
    public static let bandMinReachDegrees: Double = 27.5

    /// ±100 on a Hue slider lands exactly on the adjacent band centre.
    public static let hueRangeDegrees: Double = 45.0
    /// Luminance shaping constant: ±100 moves L by at most ±0.25, at and above L = 0.5.
    public static let lumKappa: Double = 1.0

    /// Where the chroma-preserving lightness kernel reaches full authority and HOLDS it.
    ///
    /// The kernel is `t·(1−t)`: zero at t = 0, peaking at t = 0.5. The zero is a real
    /// fixed point — there is nothing below black to darken toward, and evaluating at
    /// the pixel's own lightness there makes `L − shape` come out as `L²`, so full
    /// negative deflection cannot drive a pixel through zero.
    ///
    /// The argument used to be `saturate(L)`, which gave the kernel a SECOND zero at
    /// L = 1 and put the peak in the middle of the two. That is the display-referred
    /// mistake this file's own note on `satRolloffHi0` describes: the Mixer and Point
    /// Colour lightness stages run before the display transform, on unbounded
    /// scene-referred data, where 1.0 is not white and not an endpoint — it is about
    /// +2.5 EV over mid-grey and entirely ordinary. Every pixel at or above it moved
    /// not at all, and one at L ≈ 0.9 moved at a third of authority: bright sky, lit
    /// cloud, sunlit skin, the three subjects a Luminance slider exists for.
    ///
    /// Clamping the ARGUMENT at the peak instead of at 1.0 keeps the black fixed point
    /// and the `L²` bound exactly as they were below the peak, keeps the response
    /// monotone in L at both extremes of deflection, and leaves the control at full
    /// authority everywhere above it. There is no taper: a taper would need a highlight
    /// to converge to, and scene-referred data does not have one.
    public static let lumShapePeak: Double = 0.5
    /// B&W band gain constant: −100 on a band takes that colour's grey to zero.
    public static let bwKappa: Double = 1.0

    /// Chroma gate thresholds. Below `gateLo` a pixel's hue is noise; the gate scales
    /// the *magnitude* of every hue-selective adjustment and is deliberately never
    /// folded into band membership — doing that would break the partition of unity for
    /// neutrals and let hue rotation leak into greys. The one exception is a Mixer
    /// band Saturation PULL, which only scales chroma towards zero and runs ungated
    /// so it stays monotone in chroma (see `applyMixer`).
    public static let gateLoChroma: Double = 0.02
    public static let gateHiChroma: Double = 0.06

    /// Where Protect Skin's attenuation fades in, in chroma, eased over LOG chroma.
    ///
    /// It used to be `chromaGate`, through `skinWeight`, and that ramp is too steep to
    /// sit under a gain. The output chroma is C · G(1 − P · g(C)), so as the protection
    /// rises the gain falls, and a linear-chroma smoothstep across 0.02…0.06 rises at
    /// up to 1.5 per ln C — faster than the input grows. At Vibrance and Saturation
    /// +100 and Protect 100 a skin-hued C 0.040 left at 0.088 and a C 0.054 at 0.061:
    /// the MORE colourful pixel came out flatter, a chroma contour on a pale face (0.011
    /// at the shipped Protect 70). Keeping chroma order at full gain needs the ramp no
    /// steeper than 1 − g/2 per ln C; no ramp that opens and closes inside 0.02…0.06
    /// can manage that, and a smoothstep needs a decade. So it starts at 0.006 and is
    /// full by the same 0.06 as before. At C ≥ 0.06 protection is unchanged; between
    /// 0.006 and 0.06 it is STRONGER than before — and that span holds pale skin as
    /// well as skin-hued near-greys: at C 0.04 the guard rises from 0.5 to about 0.92.
    /// That is what moved the color.protectSkin / saturation / vibrance / density proof
    /// records when this ramp landed.
    /// `skinWeight`, the shared meaning of "skin", is not touched.
    /// Mirrored in `ExactColorTwin.vibranceSaturation` and the GLSL colour finish.
    /// (ProtectSkinChromaOrderTests)
    public static let protectLoChroma: Double = 0.006
    public static let protectHiChroma: Double = 0.06

    // MARK: - Point Colour (docs/06 brief §2.2)

    // THE SELECTION AXES, AND THEY ARE PHOTOGRAPHIC TOLERANCES NOW.
    //
    // They were 0.60 / 0.25 / 0.30, and each of those spans most or all of its own
    // axis: OKLab L runs 0…1, so a sigma of 0.60 cannot exclude anything by lightness,
    // and photographic chroma tops out near 0.25, so neither could C. Measured on a
    // swatch sampled on a blue sky at Range 100, the selection weights were 1.000 on
    // the sampled colour, **1.000 on pure neutral grey**, 0.953 ninety degrees away in
    // hue, and 0.692 on skin. That is not a selection — it is a global slider with a
    // colour picker attached, and the photographer has no way to attribute the result:
    // click a sky, pull Luminance to −100 to deepen it, and the concrete, the wall and
    // the faces in the same frame darken with it.
    //
    // Now: 0.30 of L is about a stop and a half, 0.09 of C is a real chroma tolerance,
    // and the hue term below is normalized so 0.46 is about 80° of arc. Measured on the
    // same swatch, every one of grey, near-neutral, ninety-degrees-away, skin and
    // foliage now weighs 0.000 at EVERY Range, while a blue 30° along still weighs 1.00
    // and one a stop darker 0.74.
    public static let pointSigmaL: Double = 0.30
    public static let pointSigmaC: Double = 0.09
    /// In NORMALIZED ANGULAR units — see `applySwatch`, where the hue term became
    /// `gate · Δh/180` rather than a chord. 0.46 is roughly 80° of arc at full Range.
    public static let pointSigmaH: Double = 0.46

    /// What Range = 0 leaves of the tolerances, as a fraction of Range = 100.
    ///
    /// BOTH ENDS OF THIS SLIDER WERE DEAD and this is the half of the fix nobody was
    /// looking for. The scale was `range/100` straight, floored at 1e-4 — so Range 0
    /// selected only a bit-exact match, which is no pixels, and Range 100 selected
    /// everything. A control whose declared 0…100 travel is inert at the bottom and
    /// non-selective at the top has no useful setting anywhere.
    ///
    /// `0.55 + 0.45·r` makes the whole travel a tolerance: Range 0 reaches about 30° of
    /// hue and a stop of lightness, Range 100 about 60° and two stops, and neither end
    /// is a degenerate case. It is what lets the sigmas above be tight enough to
    /// exclude at MAXIMUM range while the default still selects a sky rather than a
    /// pixel — with a straight `r` those two are not simultaneously satisfiable, which
    /// is why the first attempt at this fix made Range 50 a point sample.
    public static let pointRangeBase: Double = 0.55

    /// Kept as a guard on the divisor. With `pointRangeBase` above it can no longer be
    /// reached from the wire format — the smallest scale is 0.55 — and a floor that
    /// cannot fire is exactly what this constant used to be relied on to do.
    public static let pointSigmaFloor: Double = 1e-4
    public static let pointHueShiftLimit: Double = 60.0

    /// A PIXEL IS ALSO READ AS A MIXTURE: how much of the swatch's colour is in it.
    ///
    /// A soft edge between the swatch's colour and a neutral — a defocused red petal on
    /// a white plate, a blue sky fading into haze, a cheek into a white collar — is a
    /// MIXTURE: its pixels keep the swatch's hue while chroma falls toward zero and
    /// lightness moves toward the neutral's. Measured on frame 2062 (ISO 6400) at the
    /// default Range, the selection held 1.0 down to a 85% petal mix and was 0.00 at
    /// 40%, so a −100 Saturation left a fully saturated red ring round every petal and
    /// a −80 Luminance cut each one out with a jagged, noise-driven edge, half a blend
    /// width inside the edge the photograph actually has.
    ///
    /// That share is measured in LINEAR light, where it is exact: a pixel that is `α`
    /// of the swatch's colour and `1 − α` of any neutral has a linear opponent chroma
    /// vector exactly `α` times the swatch's, whatever the neutral's level. So the
    /// projection `r = χ·χₜ / |χₜ|²` IS the blend fraction, and the selection can fade
    /// with it instead of cutting through it. (The first draft used the OKLab chroma
    /// ratio; toward a bright neutral that falls far faster than the blend, and a 50%
    /// mix with a light grey still read as unselected.)
    ///
    /// This tolerance is the ratio's sigma at Range 100 (scaled by Range and the
    /// Saturation refinement like the others) and is capped at 1, so a pure neutral
    /// (`r = 0`) is at mixture distance ≥ 1 and never selected by this reading.
    public static let pointRatioTolerance: Double = 0.9

    // MARK: - Skin (docs/06 brief §5.3)

    /// The NTSC vectorscope I-bar — the axis all human skin hues cluster on regardless
    /// of ethnicity (blood and melanin fix the hue; luminance is what varies) —
    /// transported into the OKLab a/b plane. Golden-locked constant, never re-derived at
    /// runtime, because the vectorscope graticule and the Skin tools must agree exactly.
    ///
    /// **Measured from +a**, which is the frame both consumers read it in:
    /// `skinWeight` compares it against `OKLCh.h`, and the scope's graticule plots it
    /// with `OKLab.hue`. It was 33.0, which is this same line measured from **+b** —
    /// the traditional vectorscope orientation with the yellow–blue axis horizontal.
    /// `Vectorscope`'s header already recorded that mismatch and left it unresolved
    /// because both consumers had to move together; this is that move.
    ///
    /// What 33° cost, and why it was not merely cosmetic: `skinWeight` scored **zero**
    /// on every representative skin tone and a high weight on brick and fire-engine
    /// red. So `Protect Skin` — which defaults to 70 and says it "attenuates both
    /// sliders inside the skin-tone band" — held back reds at full strength while
    /// letting Saturation and Vibrance hit faces unattenuated. The exact inverse of the
    /// control's stated job, on by default, on every photo with a person in it.
    ///
    /// The value is corroborated two independent ways, which matters because it is a
    /// number this project treats as golden: `Vectorscope.deriveSkinToneLineDegrees`
    /// re-derives the I-bar through the working space and documents ≈56.4°, and the
    /// measured OKLCh hues of real skin in that same space run 43°–63° with a centroid
    /// near 55°. `testSkinWeightActuallyScoresSkin` pins the behaviour rather than the
    /// number, so a future re-derivation is checked against what the constant is FOR.
    public static let skinLineDegrees: Double = 56.4
    /// Half-width, matching the UI's literal "±10°" label.
    public static let skinBandDegrees: Double = 10.0

    // MARK: - Vibrance / Saturation (docs/06 brief §5.5)

    public static let lowChromaLo: Double = 0.05
    public static let lowChromaHi: Double = 0.25
    /// Sat-vs-Sat compression: the knee above which further push resists, and the
    /// chroma the curve is asymptotic to. Internal machinery — never a user curve.
    public static let satKneeChroma: Double = 0.18
    public static let satCeilingChroma: Double = 0.34
    /// Lum-vs-Sat rolloff: the tonal window inside which a *push* has full effect.
    ///
    /// The low end is a true floor — below `satRolloffLo0` there is no colour to push,
    /// only chroma noise — and it sits about fourteen stops under mid-grey, so nothing
    /// a photograph contains lives there.
    ///
    /// The high end is a TAPER, not a window. It used to be a second smoothstep
    /// closing at brightness 1.0, which is roughly two and a half stops over mid-grey:
    /// above that, Saturation and positive Vibrance did exactly nothing. Every bright
    /// sky, every lit skin highlight, every white shirt in sun. Scene-referred data is
    /// unbounded, so a display-referred number like "1.0" cannot be an endpoint in a
    /// stage that runs before the display transform.
    public static let satRolloffLo0: Double = 0.02
    public static let satRolloffLo1: Double = 0.20
    /// Where the highlight taper starts, and the scale over which it falls.
    public static let satRolloffHi0: Double = 0.86
    public static let satRolloffHiWidth: Double = 0.35
    /// What the taper approaches as brightness rises without bound. Never zero: the
    /// point is that highlights saturate LESS, not that they stop being colours.
    public static let satRolloffFloor: Double = 0.35
    /// Full positive Saturation raises the dye-density gamma to this above 1.
    public static let densityGammaRange: Double = 1.0

    // MARK: - Primaries (docs/06 brief §6.2)

    /// A primary's chroma turn at ±100, in the linear opponent plane
    /// (`primariesMatrix`). 12° there carries the chart's red patch about 25° round
    /// OKLab's wheel each way, green 15° and blue 23°.
    public static let primaryRotationDegrees: Double = 12.0
    /// Purity at ±100 scales a primary's chroma by `2^±stops`, per primary (R, G, B).
    /// Blue's is longer because the white rescale hands most of a blue push back: at
    /// 0.6 the chart's blue patch moved under 7%, against red's 22% and green's 37%.
    /// No longer than 1.0, though: past it Blue −100 starts to lift the blue's own
    /// lightness (+0.047 OKLab L at 1.2, +0.057 at 1.4) and turn it (6° at 1.4) — a
    /// tone move in disguise. At 1.0 a saturated blue gains 10% and loses 15%.
    public static let primaryPurityStops: [Double] = [0.6, 0.6, 1.0]
    /// Shadows Tint: a pinned shadow window (NOT the user's grading pivot) and the
    /// maximum a/b offset at ±100.
    public static let tintPivotEV: Double = -3.0
    public static let tintHalfWidthEV: Double = 1.5
    public static let tintAmplitude: Double = 0.05
    /// OKLab hue of the green↔magenta opponent axis; +tint is toward magenta.
    public static let tintAxisDegrees: Double = 328.36

    /// The working space the stage operates in (docs/14 §1.3). The primaries remap needs
    /// chromaticities, which `OKLabTransform.Context` does not carry; this is the space
    /// `OKLabTransform.working` is built from.
    public static let workingSpace: RGBColorSpace = .rec2020

    // MARK: - Init

    /// `bandMeanHues` is the one input that is not a recipe field: it is a MEASUREMENT
    /// of this image, so it arrives from the renderer rather than from the user, and
    /// `nil` means "nobody measured" rather than "zero".
    public init(mixer: Mixer,
                pointColors: [PointColor],
                color: ColorAdjust,
                primaries: Primaries,
                bw: BlackAndWhite?,
                bandMeanHues: [Double]? = nil,
                context: OKLabTransform.Context = OKLabTransform.working) {
        self.mixer = mixer
        self.pointColors = pointColors
        self.color = color
        self.primaries = primaries
        self.bw = bw
        self.context = context
        self.bandMeanHues = bandMeanHues

        let sanitized: [MixerBand] = Self.sanitizedBands(mixer.bands)
        self.bands = sanitized
        self.arcs = Self.bandArcs(sanitized)
        self.uniformity = Num.clamp(mixer.uniformity, 0, 100)
        var mixerFlat = true
        for b in sanitized where b.hue != 0 || b.sat != 0 || b.lum != 0 { mixerFlat = false }
        self.mixerIsIdentity = mixerFlat && Num.clamp(mixer.uniformity, 0, 100) == 0

        self.swatches = Self.compiledSwatches(pointColors, context: context)

        let m: Mat3 = Self.primariesMatrix(primaries, context: context)
        self.remap = m
        self.remapIsIdentity = m.maxAbsDifference(.identity) < 1e-12

        let tintAngle: Double = Self.tintAxisDegrees * .pi / 180
        let hueAmount: Double = Num.clamp(primaries.tintHue, -100, 100) / 100
        let purityAmount: Double = Num.clamp(primaries.tintPurity, -100, 100) / 100
        // tintHue rides the green↔magenta axis (the spec's one Shadows Tint slider);
        // tintPurity rides its perpendicular, because a shadow cast is not always on
        // the green–magenta axis (docs/06 brief §6.1, the seven-vs-eight-field conflict).
        self.tintA = Self.tintAmplitude
            * (hueAmount * cos(tintAngle) - purityAmount * sin(tintAngle))
        self.tintB = Self.tintAmplitude
            * (hueAmount * sin(tintAngle) + purityAmount * cos(tintAngle))
        self.tintIsIdentity = hueAmount == 0 && purityAmount == 0

        var bandsOut: [Double] = [Double](repeating: 0, count: Self.bandCount)
        if let b = bw {
            for i in 0..<Self.bandCount where i < b.bands.count {
                bandsOut[i] = Num.clamp(b.bands[i], -100, 100)
            }
        }
        self.blackAndWhiteBands = bandsOut
        // The slot being present is no longer the treatment being on: a mix the user
        // has switched off stays in the recipe so it is still there tomorrow, and it
        // must render as colour while it waits.
        self.bwEnabled = bw?.enabled == true
        var anyBand = false
        for v in bandsOut where v != 0 { anyBand = true }
        self.bwHasBands = anyBand

        self.lumaWeights = Self.workingSpace.luminanceWeights
    }

    // MARK: - The stage

    /// The whole of S9 at one pixel, with no neighbourhood — the flat-neighbourhood
    /// case of `apply(_:localMean:)`, and the entry point every shipping caller uses.
    public func apply(_ c: RGB) -> RGB {
        apply(c, localMean: c)
    }

    /// The whole of S9, in pipeline order. Pure, closed-form, one pass: primaries remap
    /// → Mixer → Point Colour → Vibrance/Saturation → B&W. No gamut clip: see below.
    ///
    /// `localMean` is the guided-filter mean of the STAGE INPUT around this pixel, and
    /// only the two variance-compression controls read it — Mixer Uniformity and Point
    /// Colour Variance. With `localMean == c` they compress the pixel itself, which
    /// converges the colour correctly and takes the texture with it; with a real
    /// neighbourhood mean they compress the low-frequency blotch and leave `(v − μ)` —
    /// pores, grain, sky texture — untouched, which is the half of "three surfaces, one
    /// kernel" docs/05 is actually selling.
    ///
    /// **What it would take to supply a real one, precisely.** This stage is no longer
    /// baked into a 3D LUT (AI-03): it runs as `ExactColorStage`'s kernels, whose
    /// `point` pass already takes a SECOND image — the fixed pre-Mixer reference. So
    /// the table obstacle that used to head this list is gone; what remains is:
    ///   1. a mean image to hand those kernels instead of the pixel itself (the Mixer
    ///      pass would need the same second input for Uniformity);
    ///   2. the renderer computes a guided-filter mean of the stage input once per
    ///      frame at preview resolution — `SpatialOps` already has the filter, and
    ///      `RenderGraph.guidedFilter` already runs it on the GPU for the tone mask —
    ///      and caches it against the recipe prefix, as docs/05 requires ("the
    ///      guided-filter local mean is computed once per image at preview res and
    ///      cached");
    ///   3. that mean and the image go into a two-input kernel calling this entry point.
    /// Until then the flat case is what runs, and it is documented rather than implied.
    public func apply(_ c: RGB, localMean: RGB) -> RGB {
        guard c.isFinite else { return c }
        // A stage that does nothing must do NOTHING. Without this the always-on soft
        // gamut clip below still ran on a default recipe, compressing the chroma of
        // any saturated or above-white value — a scene-referred clamp inside a no-op,
        // and a disagreement with `RenderPlan`, which swaps the whole stage out when
        // `isIdentity` is true. GradeEngine has had the same guard from the start.
        guard !isIdentity else { return c }
        var out: RGB = c
        // The neighbourhood is measured on the STAGE INPUT and travels through the
        // primaries remap with the pixel — the remap is a matrix, so it maps the mean
        // the same way it maps the pixel, and remapping only one of the two would put an
        // artificial deviation between them.
        let source: RGB = localMean.isFinite ? localMean : c
        out = applyPrimaries(out)
        // On the flat path this is the same value, and reusing it rather than
        // recomputing keeps the no-neighbourhood case exactly as cheap as it was.
        let mean: RGB = source == c ? out : applyPrimaries(source)
        out = applyMixer(out, localMean: mean)
        out = applyPointColors(out, localMean: mean)
        // THE B&W MIX READS ITS BANDS OFF THE COLOUR BEFORE THE CHROMA SCALE.
        //
        // Saturation is a chroma scale, and the mix's per-band gain is multiplied by
        // the chroma gate of the pixel it is handed — so reading it off the
        // post-saturation value drove the gate to zero as Saturation went down. At
        // −75 the eight band sliders were 84% dead; at −100, exactly inert, with no
        // message. "Desaturate, then mix the sky down in B&W" is the ordinary route
        // into a black-and-white edit and it produced a flat conversion and eight
        // sliders that moved nothing.
        //
        // The value captured here is the colour AFTER the Mixer and Point Colour and
        // BEFORE Saturation: a deliberate hue edit still steers which band a pixel
        // falls in (turn a blue sky cyan and mix the cyan band, as you would expect),
        // while a chroma scale — which changes no hue and selects nothing — cannot
        // switch the instrument off. The luminance the mix scales is still the
        // saturated pixel's own.
        let bandSource: RGB = out
        out = applyVibranceSaturation(out)
        out = applyBlackAndWhite(out, bandSource: bandSource)
        guard out.isFinite else { return c }
        // NO gamut clip here. Display-gamut mapping is the last colour operation
        // inside S14 (docs/14 §2), and `DisplayTransform.apply` does it there, on
        // display-normalized values, hue-preserving.
        //
        // Running it here ran it on scene-referred data, which is unbounded — and
        // `Gamut.softClip` bails out on `L >= 1`, so it was a step function of
        // exposure: a colour got compressed below about three and a half stops over
        // mid-grey and passed through untouched above it. That is a discontinuity in
        // the middle of the working range. It made a gradient across that exposure
        // jump, and it made this stage impossible to bake accurately, because a cube
        // cell straddling the switch interpolates between clipped and unclipped
        // corners — which is what showed up as a 0.17 error between the tables and the
        // exact evaluation.
        //
        // Pushing chroma past the display gamut is what a saturation slider is FOR.
        // S14 compresses it back, once, at the point where "the display" finally means
        // something.
        return out
    }

    /// True when nothing in the stage would change a pixel, so the renderer can skip S9
    /// entirely rather than round-tripping 45 megapixels through OKLab for no reason.
    public var isIdentity: Bool {
        remapIsIdentity && tintIsIdentity && mixerIsIdentity && swatches.isEmpty
            && Num.clamp(color.vibrance, -100, 100) == 0
            && Num.clamp(color.saturation, -100, 100) == 0
            && !bwEnabled
    }

    /// The whole stage, resolved for exact evaluation — what every renderer runs instead
    /// of baking this engine into a table (AI-03; `ExactColorStage`'s header). Built from
    /// exactly the sanitized state `apply` reads, so the two cannot disagree about what
    /// the recipe means: the same clamps, the same arcs, the same compiled swatch list
    /// (dead swatches already dropped), the same Uniformity targets.
    public var exactStage: ExactColorStage {
        var resolved = ExactColorStage.Resolved(
            isIdentity: isIdentity, context: context,
            remap: remapIsIdentity ? nil : remap,
            tint: tintIsIdentity ? nil : (tintA, tintB),
            luma: lumaWeights, mixer: nil, swatches: [],
            vibranceSaturation: nil, blackAndWhite: nil)
        if !mixerIsIdentity {
            let bandRows: [[Double]] = (0..<Self.bandCount).map { i in
                let arc = arcs[i]
                let band = bands[i]
                return [arc.centre, arc.coreBelow, arc.coreAbove,
                        arc.featherBelow, arc.featherAbove,
                        Num.clamp(band.hue, -100, 100) / 100 * Self.hueRangeDegrees,
                        Num.clamp(band.sat, -100, 100) / 100,
                        Num.clamp(band.lum, -100, 100) / 100 * Self.lumKappa,
                        bandTargetHue(i)]
            }
            resolved.mixer = (bandRows, -uniformity / 100)
        }
        resolved.swatches = swatches.map { s in
            [s.target.L, s.target.C, s.target.h, s.sigmaL, s.sigmaC, s.sigmaH,
             s.shiftH, s.shiftS, s.shiftL * Self.lumKappa, s.q, s.sigmaR,
             s.chiA, s.chiB, s.chiInverseNorm]
        }
        let vibrance = Num.clamp(color.vibrance, -100, 100) / 100
        let saturation = Num.clamp(color.saturation, -100, 100) / 100
        if vibrance != 0 || saturation != 0 {
            resolved.vibranceSaturation = (vibrance, saturation,
                                           Num.clamp(color.protectSkin, 0, 100) / 100,
                                           Num.clamp(color.density, 0, 100) / 100)
        }
        if bwEnabled {
            resolved.blackAndWhite = blackAndWhiteBands.map { $0 / 100 * Self.bwKappa }
        }
        return ExactColorStage(resolved)
    }

    // MARK: - What a picker must sample (AI-02)

    /// Which selection a colour picker is feeding.
    public enum SelectionTap: Equatable, Sendable {
        /// The Mixer's band picker: band membership is read after the primaries remap
        /// and Shadows Tint.
        case mixerBand
        /// Point Colour swatch `index` (the next index when adding one). A swatch
        /// compares the pixel after the primaries, the Mixer, and every swatch BEFORE
        /// it in creation order.
        case pointColor(index: Int)
    }

    /// The value the selection behind `tap` actually compares, given the colour stage's
    /// input `c` — what a picker has to store for the swatch to select the pixel that
    /// was clicked.
    ///
    /// AI-02. The picker stored the stage INPUT while `applySwatch` compared the pixel
    /// after the primaries and the Mixer, so with Red Mixer Hue +100 a red picked and
    /// pulled to Saturation −100 kept 0.1198 of its 0.12 chroma at Range 0: the swatch
    /// sat a whole band away from the colour it was meant to be. This is the same
    /// sequence `apply` runs, stopped where the selection reads: never a second copy of
    /// the stage order.
    public func selectionInput(_ c: RGB, for tap: SelectionTap) -> RGB {
        guard c.isFinite else { return c }
        let primed = applyPrimaries(c)
        guard case .pointColor(let index) = tap else { return primed }
        var out = applyMixer(primed, localMean: primed)
        // The swatches that precede `index` in the RECIPE, compiled the same way the
        // render compiles them, so a dead swatch before it is skipped exactly as the
        // render skips it.
        let earlier = Self.compiledSwatches(Array(pointColors.prefix(Swift.max(index, 0))),
                                            context: context)
        for s in earlier { out = applySwatch(s, to: out, localMean: primed) }
        return out
    }

    // MARK: - Band geometry (the four ring handles, D13)

    /// One band's four ring handles, resolved to degrees and already sanitized.
    ///
    /// Absolute rather than relative, because two consumers have to agree about the
    /// same arc: the pixel loop's membership function and the ring the user drags. A
    /// panel that re-derived the arc from the wire values would be a second copy of
    /// this arithmetic and would drift from it.
    public struct BandArc: Equatable, Sendable {
        /// The band's canonical hue centre. Not user-adjustable: it is the wire
        /// format's structural identity for the band, and moving it would change what
        /// "Green" means in every saved recipe.
        public let centre: Double
        public let coreBelow: Double
        public let coreAbove: Double
        public let featherBelow: Double
        public let featherAbove: Double

        public init(centre: Double, coreBelow: Double, coreAbove: Double,
                    featherBelow: Double, featherAbove: Double) {
            self.centre = centre
            self.coreBelow = coreBelow
            self.coreAbove = coreAbove
            self.featherBelow = featherBelow
            self.featherAbove = featherAbove
        }

        /// The MIDPOINT of the core arc — where the band actually sits after the user
        /// has dragged its inner handles, and therefore where Uniformity converges when
        /// no measured mean is available. Equal to `centre` at the default geometry, so
        /// nothing about an untouched recipe changes.
        public var coreCentre: Double { Num.wrapHue(centre + (coreAbove - coreBelow) / 2) }

        /// Ring drawing: the four handle positions, in absolute degrees.
        public var coreStart: Double { Num.wrapHue(centre - coreBelow) }
        public var coreEnd: Double { Num.wrapHue(centre + coreAbove) }
        public var featherStart: Double { Num.wrapHue(centre - coreBelow - featherBelow) }
        public var featherEnd: Double { Num.wrapHue(centre + coreAbove + featherAbove) }
    }

    /// The default geometry, as arcs. What `bandWeights(hue:)` and the B&W mix use.
    public static let canonicalArcs: [BandArc] =
        ColorEngine.bandArcs(Array(repeating: MixerBand(), count: ColorEngine.bandCount))

    /// Resolve the wire format's per-band handles into arcs, clamped so the partition
    /// of unity survives any file (see `bandMinReachDegrees`).
    public static func bandArcs(_ bands: [MixerBand]) -> [BandArc] {
        var out: [BandArc] = []
        out.reserveCapacity(bandCount)
        for i in 0..<bandCount {
            let band: MixerBand = i < bands.count ? bands[i] : MixerBand()
            func side(_ v: [Double], _ index: Int, _ fallback: Double,
                      _ lo: Double, _ hi: Double) -> Double {
                guard index < v.count, v[index].isFinite else { return fallback }
                return Num.clamp(v[index], lo, hi)
            }
            let cb: Double = side(band.core, 0, bandCoreDegrees,
                                  bandCoreMinDegrees, bandCoreMaxDegrees)
            let ca: Double = side(band.core, 1, bandCoreDegrees,
                                  bandCoreMinDegrees, bandCoreMaxDegrees)
            var fb: Double = side(band.feather, 0, bandFeatherDegrees,
                                  bandFeatherMinDegrees, bandFeatherMaxDegrees)
            var fa: Double = side(band.feather, 1, bandFeatherDegrees,
                                  bandFeatherMinDegrees, bandFeatherMaxDegrees)
            // Widen the FEATHER, never the core, to meet the minimum reach: the core is
            // what the user drew and the feather is how it lets go, so a narrow
            // selection stays narrow and only its falloff is forced to stay smooth.
            fb = Swift.max(fb, bandMinReachDegrees - cb)
            fa = Swift.max(fa, bandMinReachDegrees - ca)
            out.append(BandArc(centre: bandHueCentres[i],
                               coreBelow: cb, coreAbove: ca,
                               featherBelow: fb, featherAbove: fa))
        }
        return out
    }

    // MARK: - Band weights

    /// The 8-band partition of unity at `hue`, in wire order, at the DEFAULT geometry.
    /// Kept as the canonical-geometry entry point: the B&W mix and the goldens are
    /// denominated in it, and it must not move when a Mixer handle does.
    public static func bandWeights(hue: Double) -> [Double] {
        bandWeights(hue: hue, arcs: canonicalArcs)
    }

    /// The 8-band partition of unity at `hue`, in wire order. Σw = 1 exactly, on every
    /// path including the degenerate one. Exposed so the UI's ring and the "show reach"
    /// overlay draw the weights the engine actually uses, not a redrawn approximation.
    public static func bandWeights(hue: Double, arcs: [BandArc]) -> [Double] {
        var w: [Double] = [Double](repeating: 0, count: bandCount)
        var sum: Double = 0
        for i in 0..<bandCount {
            let arc: BandArc = i < arcs.count ? arcs[i] : canonicalArcs[i]
            let d = Num.hueDelta(arc.centre, hue)          // signed wrap180(hue − centre)
            let below = Swift.max(0, -d - arc.coreBelow)
            let above = Swift.max(0, d - arc.coreAbove)
            var v: Double = 1
            if below > 0 {
                v = featherFalloff(below, extent: arc.featherBelow)
            } else if above > 0 {
                v = featherFalloff(above, extent: arc.featherAbove)
            }
            w[i] = v
            sum += v
        }
        if sum < 1e-6 {
            // Every band has been shrunk away from this hue. Never emit an all-zero
            // membership vector: hand the whole weight to the nearest band, measured in
            // units of its own reach.
            var best: Int = 0
            var bestScore: Double = .infinity
            let reach = Swift.max(bandCoreDegrees + bandFeatherDegrees, 1e-6)
            for i in 0..<bandCount {
                let score = abs(Num.hueDelta(bandHueCentres[i], hue)) / reach
                if score < bestScore {
                    bestScore = score
                    best = i
                }
            }
            var fallback: [Double] = [Double](repeating: 0, count: bandCount)
            fallback[best] = 1
            return fallback
        }
        for i in 0..<bandCount { w[i] /= sum }
        return w
    }

    /// Raised-cosine feather: 1 at the core edge, 0 at the feather extent, derivative 0
    /// at both ends. `Num.raisedCosine` runs the other way, hence the complement — one
    /// shape family for tone zones and colour bands alike.
    private static func featherFalloff(_ distance: Double, extent: Double) -> Double {
        guard extent > 0 else { return 0 }
        return 1 - Num.raisedCosine(Num.saturate(distance / extent))
    }

    // MARK: - Which band owns a colour (docs/28 Phase 5, the picker-first mixer)

    /// The band a hue reads as: the one whose membership at that hue is largest.
    ///
    /// The engine grades every hue through ALL eight bands — that is what the partition
    /// of unity is for — so "which band is this orange" is a question about what the
    /// photographer should reach for, not about what the maths does, and the honest
    /// answer is the band carrying most of the weight. Asking `bandWeights` rather than
    /// comparing against `bandHueCentres` is the point: the arcs are draggable, so a
    /// widened Blue really does own a hue that the default geometry gives to Aqua, and
    /// an answer derived from the centres would contradict the ring the user drew.
    ///
    /// Ties go to the lower index, which is only reachable at an exact midpoint between
    /// two equally-shaped neighbours; determinism matters more there than the choice.
    public static func dominantBand(hue: Double, arcs: [BandArc]) -> Int {
        let w = bandWeights(hue: hue, arcs: arcs)
        var best = 0
        var bestWeight = -Double.infinity
        for i in 0..<bandCount where w[i] > bestWeight {
            bestWeight = w[i]
            best = i
        }
        return best
    }

    /// The band a sampled COLOUR reads as, or nil when it has no colour to read.
    ///
    /// Near-greys are the reason this is optional. Below the chroma gate a pixel's hue
    /// angle is numerical noise — the same noise `skinWeight` refuses to act on — so
    /// selecting a band from it would be selecting at random and then showing the
    /// photographer three sliders for a decision nobody made. "There is no colour there"
    /// is a true answer and a cheap one to say.
    public static func dominantBand(
        for colour: RGB,
        arcs: [BandArc],
        context: OKLabTransform.Context = OKLabTransform.working) -> Int? {
        guard colour.isFinite else { return nil }
        let lch = context.toLCh(colour)
        guard lch.C.isFinite, lch.h.isFinite, chromaGate(lch.C) > 0 else { return nil }
        return dominantBand(hue: lch.h, arcs: arcs)
    }

    /// Chroma gate. Multiplies adjustment magnitude, never membership.
    public static func chromaGate(_ chroma: Double) -> Double {
        Num.smoothstep(gateLoChroma, gateHiChroma, chroma)
    }

    // MARK: - The shared variance-compression kernel

    public enum VarianceAxis: Sendable {
        case hue
        case chroma
        case lightness
    }

    /// `v' = v + q · β · W · (μ − τ)` — one kernel, three faces (D13 Mixer Uniformity,
    /// D14 Point Colour Variance, D17 Skin Uniformity).
    ///
    /// The quantity scaled is the deviation of the *local mean* from the target, never
    /// the deviation of the raw pixel. That is the entire trick: `q < 0` compresses the
    /// low-frequency blotch toward `τ` while `(v − μ)` — pores, grain, sky texture —
    /// survives untouched, and `q > 0` amplifies real colour structure instead of chroma
    /// noise. Callers fold the chroma gate into `weight` for the hue axis.
    ///
    /// `μ` is the guided-filter local mean of the axis (brief §2.4). It reaches this
    /// kernel from `apply(_:localMean:)`, whose second argument is the whole seam: hand
    /// it a guided-filter-smoothed copy of the stage input and this is the full,
    /// texture-preserving kernel; hand it the pixel — which is what the one-argument
    /// `apply` does, and what every shipping caller does today — and it degrades to the
    /// flat-neighbourhood case, which keeps the algebra and the direction of the move
    /// exactly right and gives up only the texture-preservation half.
    ///
    /// Why the shipping path is still flat, precisely: S9 used to be compiled to a 3D
    /// LUT over log-encoded RGB, which is by construction a function of ONE colour. It
    /// runs exactly now (`ExactColorStage`, AI-03), so a second, spatially varying input
    /// is a kernel argument rather than an impossibility — but nothing computes that
    /// mean yet. See the note above `apply(_:localMean:)`.
    public static func varianceCompress(value v: Double,
                                        localMean mu: Double,
                                        target: Double,
                                        q: Double,
                                        beta: Double,
                                        weight: Double,
                                        axis: VarianceAxis) -> Double {
        guard q != 0, weight != 0, beta != 0 else { return v }
        switch axis {
        case .hue:
            let deviation = Num.hueDelta(target, mu)      // wrap180(μ − τ)
            return Num.wrapHue(v + q * beta * weight * deviation)
        case .chroma, .lightness:
            return v + q * beta * weight * (mu - target)
        }
    }

    /// WHETHER A MEASUREMENT OFF THE IMAGE IS NEEDED AT ALL.
    ///
    /// `bandMeanHues` is consulted from exactly one place — `bandTargetHue`, under
    /// `if q != 0`, where `q` is Uniformity. Uniformity defaults to 0, so on every
    /// photograph nobody has moved that slider on, the measurement is computed and
    /// never read.
    ///
    /// That would be a harmless waste if it were cheap, and it is the opposite of
    /// cheap. The renderer measures it by DECODING THE RAW AGAIN at 512 px under a
    /// neutral recipe, and a RAW decode at any scale reads the WHOLE FILE — a 512 px
    /// measurement costs what a full-size one costs on the bus. The owner's HUD, on a
    /// 33 MP ARW on an external drive: one decode 2578 ms, and the first draft of a
    /// newly opened photograph 5580 ms. Two file reads, one of them for eight numbers
    /// nothing was going to look at.
    ///
    /// So the renderer asks first. The predicate lives here, beside its one consumer,
    /// so "does this recipe read the measurement" has a single answer that the GPU path
    /// and the CPU reference cannot disagree about — and so that the day Uniformity
    /// stops being the only reader, this function is what fails to compile.
    public static func needsMeasuredBandHues(_ mixer: Mixer) -> Bool {
        mixer.uniformity != 0
    }

    /// Uniformity's convergence target for band `i`: the measured chroma-weighted mean
    /// hue when the renderer supplied one, otherwise the midpoint of the band's own core
    /// arc — the hue the user's two inner ring handles bracket.
    ///
    /// The fallback used to be `bandHueCentres[i]`, a constant, which made Uniformity a
    /// pull toward eight fixed hues no control could move. The core midpoint is the same
    /// number at the default geometry and a USER-WRITABLE one after that: drag the core
    /// handles onto the blues you actually have and Uniformity converges on them.
    private func bandTargetHue(_ i: Int) -> Double {
        if let means = bandMeanHues, i < means.count, means[i].isFinite {
            return means[i]
        }
        guard i < arcs.count else { return Self.bandHueCentres[i] }
        return arcs[i].coreCentre
    }

    /// The chroma-weighted circular mean hue of each band's members — the target
    /// docs/05 specifies for Uniformity, measured off the image.
    ///
    /// Circular, not arithmetic: hue wraps, and averaging 350° with 10° arithmetically
    /// gives 180°, the opposite colour. Summing unit vectors weighted by `w · gate · C`
    /// gives the right answer and, as a bonus, a resultant length that is small exactly
    /// when the band's hues are spread all the way round and a mean would be meaningless
    /// — which is when this returns the band's canonical centre instead of a number
    /// dressed up as a measurement.
    ///
    /// `nil` when nothing in the image lands in any band with enough chroma to have a
    /// hue at all, so the caller can say "not measured" rather than "measured as grey".
    public static func measureBandMeanHues(_ colors: [RGB],
                                           arcs: [BandArc] = ColorEngine.canonicalArcs,
                                           context: OKLabTransform.Context = OKLabTransform.working)
        -> [Double]? {
        var x: [Double] = [Double](repeating: 0, count: bandCount)
        var y: [Double] = [Double](repeating: 0, count: bandCount)
        var mass: [Double] = [Double](repeating: 0, count: bandCount)
        var any = false
        for c in colors {
            guard c.isFinite else { continue }
            let lch = context.toLCh(c)
            guard lch.C.isFinite, lch.L.isFinite else { continue }
            let gate = chromaGate(lch.C)
            guard gate > 0 else { continue }
            let w = bandWeights(hue: lch.h, arcs: arcs)
            let radians = lch.h * .pi / 180
            let cx = cos(radians)
            let cy = sin(radians)
            for i in 0..<bandCount {
                // Chroma-weighted, exactly as the adjustment itself is: a near-neutral
                // pixel's hue is numerically noise and must not vote on where the
                // band's colour sits.
                let m = w[i] * gate * Swift.max(0, lch.C)
                guard m > 0 else { continue }
                x[i] += m * cx
                y[i] += m * cy
                mass[i] += m
                any = true
            }
        }
        guard any else { return nil }
        var out: [Double] = [Double](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let arcCentre: Double = i < arcs.count ? arcs[i].centre : bandHueCentres[i]
            guard mass[i] > 1e-9 else {
                out[i] = arcCentre
                continue
            }
            let rx = x[i] / mass[i]
            let ry = y[i] / mass[i]
            // Resultant length: 1 when every member agrees on a hue, 0 when they are
            // spread evenly round the circle. Below the floor there is no mean to
            // converge on and pretending otherwise would rotate a rainbow into a stripe.
            let resultant = (rx * rx + ry * ry).squareRoot()
            if resultant < meanHueResultantFloor {
                out[i] = arcCentre
            } else {
                out[i] = Num.wrapHue(atan2(ry, rx) * 180 / .pi)
            }
        }
        return out
    }

    /// Below this resultant length a band's hues are too spread to have a mean.
    public static let meanHueResultantFloor: Double = 0.15

    /// Measure straight off an image, sampling on a stride so a 45-megapixel frame costs
    /// a few tens of thousands of conversions rather than forty-five million. Hue
    /// statistics converge fast; this is a mean, not a percentile.
    public static func measureBandMeanHues(_ image: ImageBuffer,
                                           arcs: [BandArc] = ColorEngine.canonicalArcs,
                                           targetSamples: Int = 40_000,
                                           context: OKLabTransform.Context = OKLabTransform.working)
        -> [Double]? {
        let total = image.width * image.height
        guard total > 0 else { return nil }
        let stride = Swift.max(1, Int((Double(total) / Double(Swift.max(targetSamples, 1))).squareRoot()))
        var samples: [RGB] = []
        samples.reserveCapacity((image.width / stride + 1) * (image.height / stride + 1))
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                samples.append(image[x, y])
                x += stride
            }
            y += stride
        }
        return measureBandMeanHues(samples, arcs: arcs, context: context)
    }

    // MARK: - Skin membership

    /// Vectorscope skin-band membership in 0…1: how much this colour reads as skin.
    /// The Skin tools' selection and the scope read this. Vibrance/Saturation's
    /// `protectSkin` attenuation reads `skinProtectionWeight` instead: the same hue band
    /// and plausibility, but a gentler log-chroma gate (see `protectLoChroma`), so for
    /// skin hues between C 0.006 and 0.06 the guardrail protects more than this weight
    /// selects. At C ≥ 0.06 the two agree.
    public static func skinWeight(_ c: RGB,
                                  context: OKLabTransform.Context = OKLabTransform.working) -> Double {
        guard c.isFinite else { return 0 }
        let lch = context.toLCh(c)
        guard lch.C.isFinite, lch.L.isFinite else { return 0 }
        let offAxis = abs(Num.hueDelta(skinLineDegrees, lch.h))
        let inBand = 1 - Num.smoothstep(skinBandDegrees, skinBandDegrees * 1.5, offAxis)
        guard inBand > 0 else { return 0 }
        return Num.saturate(inBand * chromaGate(lch.C) * plausibility(L: lch.L, C: lch.C))
    }

    /// How much Protect Skin spares this colour: `skinWeight` with its chroma gate
    /// swapped for the log-chroma `protectLoChroma…protectHiChroma` ramp, so the
    /// attenuation can never fold chroma order (see those constants). Selection is
    /// still `skinWeight`'s; only the strength of the guard eases in more gently.
    static func skinProtectionWeight(_ c: RGB,
                                     context: OKLabTransform.Context = OKLabTransform.working)
        -> Double {
        guard c.isFinite else { return 0 }
        let lch = context.toLCh(c)
        guard lch.C.isFinite, lch.L.isFinite else { return 0 }
        let offAxis = abs(Num.hueDelta(skinLineDegrees, lch.h))
        let inBand = 1 - Num.smoothstep(skinBandDegrees, skinBandDegrees * 1.5, offAxis)
        guard inBand > 0 else { return 0 }
        let gate = Num.smoothstep(Foundation.log(protectLoChroma), Foundation.log(protectHiChroma),
                                  Foundation.log(Swift.max(lch.C, 1e-9)))
        return Num.saturate(inBand * gate * plausibility(L: lch.L, C: lch.C))
    }

    /// Skin is a *plausible* colour, not just an angle: crushed blacks, blown highlights
    /// and fire-engine chroma sit on the I-bar too, and unifying them is the failure the
    /// band alone cannot prevent.
    private static func plausibility(L: Double, C: Double) -> Double {
        let lo = Num.smoothstep(0.05, 0.20, L)
        let hi = 1 - Num.smoothstep(0.85, 0.98, L)
        let chroma = 1 - Num.smoothstep(0.16, 0.26, C)
        return Num.saturate(lo * hi * chroma)
    }

    // MARK: - Primaries (S9's first move: redefine what R, G and B mean)

    private func applyPrimaries(_ c: RGB) -> RGB {
        var out: RGB = c
        if !remapIsIdentity { out = remap.apply(c) }
        guard !tintIsIdentity else { return out }
        let y = lumaWeights.r * out.r + lumaWeights.g * out.g + lumaWeights.b * out.b
        let w = Self.shadowWindow(luminance: y)
        guard w > 0 else { return out }
        var lab = context.toLab(out)
        guard lab.L.isFinite else { return out }
        lab.a += w * tintA
        lab.b += w * tintB
        return context.toRGB(lab)
    }

    /// The pinned shadow window Shadows Tint rides — deliberately NOT the user's grading
    /// pivot, so retuning a grade never silently moves the primaries' shadow cast.
    private static func shadowWindow(luminance y: Double) -> Double {
        let x = Num.safeLog2(y / 0.18)
        let u = (x - tintPivotEV) / tintHalfWidthEV
        return 1 - stepC1(u)
    }

    /// Raised-cosine step on [−1, +1]: 0 below, 1 above, C¹ throughout. Same family as
    /// ZoneWeights, so zone edges look the same wherever they appear.
    private static func stepC1(_ u: Double) -> Double {
        if u <= -1 { return 0 }
        if u >= 1 { return 1 }
        return Num.raisedCosine((u + 1) / 2)
    }

    /// Rotate and rescale each primary's CHROMA about the neutral axis, then put white
    /// back: the remap that moves what R, G and B mean.
    ///
    /// THE PLANE IS LINEAR OPPONENT SPACE, NOT xy — and that is the whole fix.
    ///
    /// This used to rotate and scale each primary's xy chromaticity and rebuild an
    /// RGB→XYZ matrix from the result, which needs every moved primary to be a REAL
    /// chromaticity (y > 0, x + y < 1). Rec.2020's primaries are laser lines on the
    /// spectral locus, so they have no room outward at all: Red Purity's whole positive
    /// half was a clamp (byte-identical renders from +10 to +100, ProofRegistry's
    /// declared plateau, PROOF-03), Green's died past about +25 and Blue's past +31.
    /// Measured on the chart's red patch: Purity +25, +50, +100 all left it at OKLab C
    /// 0.155. Rotating did the same trick in reverse — a red turned toward orange slid
    /// off the locus and came back desaturated (C 0.155 → 0.108 at Hue +100).
    ///
    /// A remap matrix does not need physical primaries. Each primary's column is taken
    /// into linear opponent coordinates — OKLab's two matrices without the cube root
    /// between them, so `a`/`b` point where OKLab's hues do and the lightness row is
    /// left alone — its (a, b) is turned by up to `primaryRotationDegrees` and scaled by
    /// `2^(purity · primaryPurityStops)`, and it comes back to RGB. Nothing there can
    /// leave a valid domain, so every slider runs its whole travel.
    ///
    /// **Greys are preserved by construction**, as before: the columns are rescaled by
    /// `s = P⁻¹·(1,1,1)` so the matrix maps (1,1,1) to itself, at any setting. That
    /// rescale is also why a primary's move reaches every colour containing it — the
    /// Calibration behaviour a colourist reaches for (Blue Saturation lifting the whole
    /// palette, Red Hue warming skin) rather than the Mixer's "pixels that look red".
    /// Every corner of the eight-slider cube keeps every `s` above 0.13 (white stays
    /// inside the moved primaries' triangle); the guard below refuses the matrix
    /// rather than invert through a degenerate one if a future constant breaks that.
    private static func primariesMatrix(_ p: Primaries,
                                        context: OKLabTransform.Context) -> Mat3 {
        let hues: [Double] = [p.rHue, p.gHue, p.bHue]
        let purities: [Double] = [p.rPurity, p.gPurity, p.bPurity]
        var flat = true
        for i in 0..<3 where hues[i] != 0 || purities[i] != 0 { flat = false }
        if flat { return .identity }

        let toOpponent = OKLabTransform.lmsToLab * context.rgbToLMS
        let fromOpponent = toOpponent.inverse
        var columns: [RGB] = []
        columns.reserveCapacity(3)
        for i in 0..<3 {
            let theta = Num.clamp(hues[i], -100, 100) / 100 * primaryRotationDegrees * .pi / 180
            let rho = Foundation.pow(2, Num.clamp(purities[i], -100, 100) / 100
                                         * primaryPurityStops[i])
            let unit = RGB(i == 0 ? 1 : 0, i == 1 ? 1 : 0, i == 2 ? 1 : 0)
            let o = toOpponent.apply(unit)
            let a = rho * (cos(theta) * o.g - sin(theta) * o.b)
            let b = rho * (sin(theta) * o.g + cos(theta) * o.b)
            columns.append(fromOpponent.apply(RGB(o.r, a, b)))
        }
        let moved = Mat3(columns[0].r, columns[1].r, columns[2].r,
                         columns[0].g, columns[1].g, columns[2].g,
                         columns[0].b, columns[1].b, columns[2].b)
        guard abs(moved.determinant) > 1e-9 else { return .identity }
        let scale = moved.inverse.apply(RGB(1, 1, 1))
        guard scale.r > 0.05, scale.g > 0.05, scale.b > 0.05 else { return .identity }
        let full = moved * Mat3.diagonal(scale)
        for row in full.m {
            for value in row where !value.isFinite { return .identity }
        }
        return full
    }

    // MARK: - Colour Mixer (D13)

    /// The chroma-preserving lightness kernel, shared by the Mixer's Luminance sliders
    /// and Point Colour's. Chroma is not an argument and never moves (invariant #1).
    ///
    /// Rises from a true zero at black to full authority at `lumShapePeak`, then holds.
    /// See `lumShapePeak` for why it holds rather than falling back to zero at 1.0.
    public static func lumShape(_ lightness: Double) -> Double {
        guard lightness.isFinite else { return 0 }
        let t = Num.clamp(lightness, 0, lumShapePeak)
        return t * (1 - t)
    }

    private static func sanitizedBands(_ input: [MixerBand]) -> [MixerBand] {
        var out: [MixerBand] = [MixerBand](repeating: MixerBand(), count: bandCount)
        for i in 0..<bandCount where i < input.count { out[i] = input[i] }
        return out
    }

    private func applyMixer(_ c: RGB, localMean: RGB) -> RGB {
        guard !mixerIsIdentity else { return c }
        let lch = context.toLCh(c)
        guard lch.L.isFinite, lch.C.isFinite else { return c }
        // The user's own arcs, not the canonical ones: the ring the panel draws and the
        // membership the pixel loop uses are the same four handles.
        let w = Self.bandWeights(hue: lch.h, arcs: arcs)
        let gate = Self.chromaGate(lch.C)
        // Uniformity's neighbourhood. Equal to `lch.h` on the flat path.
        let meanHue: Double = {
            guard uniformity > 0, localMean != c else { return lch.h }
            let m = context.toLCh(localMean)
            return m.h.isFinite ? m.h : lch.h
        }()

        // Sum all three attributes across bands BEFORE applying any of them. Applying
        // band-serially would double-count in the overlap regions, which is exactly
        // where the smooth band model is supposed to be invisible.
        var hueSum: Double = 0
        var satSum: Double = 0
        var lumSum: Double = 0
        let q = -uniformity / 100
        // Uniformity converges on ONE blended target — the weighted circular mean of
        // the member bands' targets — not on a sum of per-band pulls. The summed form
        // shipped first and `SliderContractTests`' probe convicted its field: each
        // band scaled the FULL deviation to its own centre, so at a seam two large
        // opposing pulls nearly cancelled and slightly overshot — hues 20° from a
        // centre moved backwards, and the wheel-wide aggregate convergence of
        // uniformity 100 measured +0.1° on 54°. The blended target makes the field a
        // smooth monotone staircase: flat near each centre (strong convergence),
        // steep only at seams (a boundary hue belongs to both sides and stays), no
        // anti-convergent pockets. Hue is a circle, so the blend is a vector sum —
        // averaging 350° and 10° arithmetically is the opposite colour.
        var targetX: Double = 0
        var targetY: Double = 0
        for i in 0..<Self.bandCount {
            let band = bands[i]
            // A Saturation PULL is the one band move the chroma gate must not scale.
            // The gate exists to keep noise hue from being rotated or amplified; a
            // pull does neither — it only scales chroma towards zero. Gated, a −100
            // pull rendered C·(1 − gate(C)), which rises to 0.025 at C = 0.03 and
            // falls back to zero at 0.06: the palest members of a band kept their
            // tint while stronger ones went grey, non-monotone in chroma.
            // Ungated, C' = C·(1 + Σw·s) is monotone and −100 removes the colour at
            // every chroma. Pushes, Hue, Luminance and Uniformity stay gated.
            // No softer gate fits between the two: at the band centre −100 must give
            // C' = 0 for every C ≥ gateLo, and a C'(C) that is non-decreasing and zero
            // at gateLo is zero below it too, so any gate opening from 0 (e.g.
            // smoothstep(0, gateLo, C)) brings the fold back. The price, paid below the
            // gate: the band-hued part of near-neutral chroma noise goes to zero and the
            // rest stays, a cast of ~0.12 × the noise chroma (≤ 0.0024 at the gate,
            // about a tenth of a JND), and a slightly cool neutral is neutralised by a
            // Blue pull.
            // `HuePreservationTests.testBandSaturationPullIsMonotoneInChromaAndRemovesTheColour`,
            // `…testABandPullOnIsotropicLowChromaNoiseLeavesOnlyAFaintCast`.
            let sat = Num.clamp(band.sat, -100, 100) / 100
            if sat < 0 { satSum += w[i] * sat }
            let weight = w[i] * gate
            if weight == 0 { continue }
            hueSum += weight * (Num.clamp(band.hue, -100, 100) / 100) * Self.hueRangeDegrees
            if sat > 0 { satSum += weight * sat }
            lumSum += weight * (Num.clamp(band.lum, -100, 100) / 100)
            if q != 0 {
                let radians = bandTargetHue(i) * .pi / 180
                targetX += weight * cos(radians)
                targetY += weight * sin(radians)
            }
        }
        var converge: Double = 0
        if q != 0, targetX * targetX + targetY * targetY > 1e-12 {
            let blendedTarget = atan2(targetY, targetX) * 180 / .pi
            // Still evaluated against the STAGE INPUT hue (invariant #4: a selection
            // never sees the move it is driving), through the same shared kernel.
            let moved = Self.varianceCompress(value: lch.h, localMean: meanHue,
                                              target: blendedTarget,
                                              q: q, beta: 1, weight: gate, axis: .hue)
            converge = Num.hueDelta(lch.h, moved)
        }

        let gC = Swift.max(0, 1 + satSum)
        // Chroma is carried through the luminance move literally unchanged — invariant
        // #1. The shaping term holds the black fixed point and keeps full authority on
        // the above-white values scene-referred data reaches.
        let L = lch.L + lumSum * Self.lumKappa * Self.lumShape(lch.L)
        let h = Num.wrapHue(lch.h + hueSum + converge)
        return context.toRGB(OKLCh(L: L, C: lch.C * gC, h: h))
    }

    // MARK: - Point Colour (D14)

    /// One compiled swatch. Ranges resolve to tolerances once, at init, because the
    /// per-pixel cost of eight swatches is the thing that keeps this inside one pass.
    private struct Swatch: Sendable {
        let target: OKLCh
        let sigmaL: Double
        let sigmaC: Double
        let sigmaH: Double
        /// The mixture tolerance (`pointRatioTolerance`, scaled), ≤ 1.
        let sigmaR: Double
        /// The sample's linear opponent chroma (a, b) and `1/|(a, b)|²` (0 for a
        /// sample with none) — what a pixel's own is projected onto.
        let chiA: Double
        let chiB: Double
        let chiInverseNorm: Double
        let shiftH: Double
        let shiftS: Double
        let shiftL: Double
        let q: Double
    }

    private static func compiledSwatches(_ input: [PointColor],
                                         context: OKLabTransform.Context) -> [Swatch] {
        var out: [Swatch] = []
        out.reserveCapacity(input.count)
        for pc in input {
            guard pc.sample.count >= 3 else { continue }
            let sample = RGB(pc.sample[0], pc.sample[1], pc.sample[2])
            guard sample.isFinite else { continue }
            let shiftH = Num.clamp(pc.shift.h, -pointHueShiftLimit, pointHueShiftLimit)
            let shiftS = Num.clamp(pc.shift.s, -100, 100)
            let shiftL = Num.clamp(pc.shift.l, -100, 100)
            let q = Num.clamp(pc.variance, -100, 100) / 100
            if shiftH == 0 && shiftS == 0 && shiftL == 0 && q == 0 { continue }
            let target = context.toLCh(sample)
            guard target.L.isFinite, target.C.isFinite else { continue }
            let chi = linearChroma(sample, context: context)
            let norm = chi.a * chi.a + chi.b * chi.b
            // The wire format carries one master Range; the per-axis refine ranges are a
            // documented format gap (brief §2.1), so all three axes share it.
            let r = Num.clamp(pc.range, 0, 100) / 100
            // Sub-linear, so neither end of the slider is a degenerate case. See
            // `pointRangeBase`.
            let scale = pointRangeBase + (1 - pointRangeBase) * r
            // The per-axis refinements multiply the master on their own axis only.
            let hue = scale * PointColor.axisFactor(pc.hueRange)
            let sat = scale * PointColor.axisFactor(pc.satRange)
            let lum = scale * PointColor.axisFactor(pc.lumRange)
            out.append(Swatch(target: target,
                              sigmaL: Swift.max(pointSigmaL * lum, pointSigmaFloor),
                              sigmaC: Swift.max(pointSigmaC * sat, pointSigmaFloor),
                              sigmaH: Swift.max(pointSigmaH * hue, pointSigmaFloor),
                              // Capped at 1 whatever the refinement: past it a true
                              // neutral would fall inside the selection.
                              sigmaR: Swift.max(Swift.min(pointRatioTolerance * sat, 1),
                                                pointSigmaFloor),
                              chiA: chi.a, chiB: chi.b,
                              chiInverseNorm: norm > 1e-12 ? 1 / norm : 0,
                              shiftH: shiftH, shiftS: shiftS, shiftL: shiftL, q: q))
        }
        return out
    }

    private func applyPointColors(_ c: RGB, localMean: RGB) -> RGB {
        guard !swatches.isEmpty else { return c }
        var out: RGB = c
        // Compose in creation order; each swatch is closed-form, so all eight evaluate
        // in one pass with no intermediate buffers.
        //
        // Every swatch measures its Variance against the SAME stage-input neighbourhood
        // rather than a mean re-derived after the previous swatch moved the pixel. That
        // is an approximation once two swatches overlap, and a deliberate one: swatches
        // select different colours by construction, and re-filtering between them would
        // need a second spatial pass per swatch — eight passes for a control the panel
        // sells as costing one.
        for s in swatches { out = applySwatch(s, to: out, localMean: localMean) }
        return out
    }

    private func applySwatch(_ s: Swatch, to c: RGB, localMean: RGB) -> RGB {
        let lch = context.toLCh(c)
        guard lch.L.isFinite, lch.C.isFinite else { return c }

        let weights = Self.selectionWeights(lch, Self.linearChroma(c, context: context), s)
        let weight = weights.weight
        let hueWeight = weights.hueWeight
        guard hueWeight > 0 else { return c }

        var L = lch.L
        var C = lch.C
        var h = lch.h

        // THE CHROMA GATE IS THIS ENGINE'S LAW, not Variance's local variable.
        //
        // The file's own header states it: every hue-selective tool shares the gate, so
        // near-neutral pixels — whose hue is numerically noise — are never rotated by
        // one. `applyMixer` obeys it. Point Colour computed it INSIDE the Variance
        // branch and left the three shift lines below ungated, so a swatch could rotate
        // the hue of a pixel the Mixer refuses to touch: measured on a warm grey at
        // C = 0.02, exactly `gateLoChroma`, a +60° hue shift arrived as +59.8° and
        // swung sRGB (138,126,117) to (126,130,117) — twelve code values from warm to
        // green, on a pixel with no hue to speak of.
        //
        // Hue only. Saturation on a near-neutral is already almost a no-op (it scales a
        // chroma near zero), and lightness is legitimate — dodging a grey is a real
        // thing to want, and the gate exists to protect hue from noise, not to make
        // neutrals untouchable.
        let gate = Self.chromaGate(lch.C)

        if s.q != 0 {
            // The neighbourhood, in the same coordinates the deviations are measured in.
            // Identical to `lch` on the flat path, so this costs one comparison there.
            let mu: OKLCh = localMean == c ? lch : {
                let m = context.toLCh(localMean)
                return m.L.isFinite && m.C.isFinite ? m : lch
            }()
            h = Self.varianceCompress(value: h, localMean: mu.h, target: s.target.h,
                                      q: s.q, beta: 1.0, weight: weight * gate, axis: .hue)
            C = Self.varianceCompress(value: C, localMean: mu.C, target: s.target.C,
                                      q: s.q, beta: 1.0, weight: weight, axis: .chroma)
            // LIGHTNESS DOES NOT TAKE PART. It did, at half weight, on the theory that
            // a neighbourhood mean would leave the texture alone — but every shipping
            // path runs the flat case, where the "mean" is the pixel itself, so −100
            // halved the lightness detail of everything it selected: measured on a
            // blotchy-skin frame, pore texture fell to 0.50 of itself and the skin went
            // to plastic. Uneven skin is uneven in hue and colourfulness (redness,
            // sallowness); its lightness variation IS its texture. Hue and chroma
            // converge, lightness is the photograph's.
        }

        h += hueWeight * gate * s.shiftH
        C = Swift.max(0, C * (1 + weight * s.shiftS / 100))
        // Same chroma-preserving lightness kernel as the Mixer: C is untouched here.
        L += weight * (s.shiftL / 100) * Self.lumKappa * Self.lumShape(L)
        return context.toRGB(OKLCh(L: L, C: C, h: Num.wrapHue(h)))
    }

    /// The swatch's selection at one colour: `weight` for Saturation, Luminance and
    /// Variance, and `hueWeight` (≥ `weight`) for the hue rotation.
    private static func selectionWeights(_ lch: OKLCh, _ chi: (a: Double, b: Double),
                                         _ s: Swatch)
        -> (weight: Double, hueWeight: Double) {
        let dL = lch.L - s.target.L
        let dC = lch.C - s.target.C
        let dh = Num.hueDelta(s.target.h, lch.h)
        // ANGULAR ΔH, GATED — not the chord.
        //
        // The chordal CIEDE form is `2√(C·C_t)·sin(Δh/2)`, and it has the right
        // behaviour near the neutral axis: hue distance shrinks as either colour
        // approaches grey, where hue stops meaning anything. What it cannot do is
        // EXCLUDE. At ordinary photographic chroma its maximum — a full 180° reversal
        // — is about 0.24, so against any sigma large enough to admit a real
        // neighbourhood, the opposite hue was still inside the selection. Measured:
        // 0.953 at ninety degrees away, on the old sigmas.
        //
        // The angular form says what the control means — "how far round the wheel" —
        // and the chroma gate restores the property the chord was bought for: at
        // `gateLoChroma` and below the term is exactly zero, so a near-neutral is never
        // excluded BY ITS HUE, which is noise there. `min` of the two chromas, so a
        // grey pixel and a grey sample are both admitted, and a grey pixel against a
        // saturated sample is judged on chroma instead — which is the axis that
        // actually separates them.
        //
        // `abs`, because `hueDelta` is signed and this is a distance. The square below
        // would cancel the sign anyway; writing it out is the difference between an
        // expression that happens to be right and one that says what it means.
        let dH = Self.chromaGate(Swift.min(lch.C, s.target.C)) * (abs(dh) / 180)

        // A MIXTURE WITH A NEUTRAL IS STILL THE SWATCH'S COLOUR, IN PART. See
        // `pointRatioTolerance`. A pixel has two readings and is as selected as the
        // more generous one says:
        //
        //   absolute — the selection as it always was: ΔL, ΔC and hue against the
        //              tolerances, flat to half the radius, C¹ rolloff to the edge;
        //   mixture  — the share `r` of the swatch's colour in it (linear light),
        //              ramped smoothly from `1 − σR` (nothing) to 1 (all), times the
        //              same rolloff on hue and on lightness counted at `r` — a tint or a
        //              shade of the swatch is judged mostly on how much of the colour it
        //              kept, not on how far a white or a black carried its lightness.
        //              (At `r²` the Luminance refinement lost its grip: a darker red
        //              read as a shade whatever Lum range said.)
        //
        // WHY A RAMP OF ITS OWN and not one more term in the distance: the first draft
        // put `(1 − r)/σR` into the distance, which sends the share through the
        // plateau-and-cliff falloff — fully selected above r ≈ 0.65 and nothing below
        // 0.3 at the default Range, the steepest stretch exactly where a warm
        // off-white backdrop sits (frame 2062's plate reads r ≈ 0.37 against its
        // petals). Chroma noise there flipped plate pixels in and out at full
        // strength. The ramp has a third of that slope, so the backdrop gets a few
        // per cent, smoothly, and a half blend gets a fifth.
        //
        // WHOLE READINGS, NOT AXES: combining per axis (the second draft) let a grey
        // borrow the absolute chroma term and the mixture's zero lightness term and
        // come along at 0.06 under a skin swatch. A neutral has r = 0 and a mixture
        // weight of exactly 0.
        //
        // The mixture reading fades in below `r = 1` (fully on by 0.85) and is scaled
        // by the SAMPLE's chroma gate, so it is continuous everywhere, absent for
        // anything more colourful than the swatch, and absent for a near-neutral
        // sample, whose "share of its colour" is noise.
        let tL = dL / s.sigmaL
        let tC = dC / s.sigmaC
        let share = (chi.a * s.chiA + chi.b * s.chiB) * s.chiInverseNorm
        let g = chromaGate(s.target.C) * (1 - Num.smoothstep(0.85, 1.0, share))
        let r = Num.clamp(share, 0, 1)
        let mL = tL * r
        let ramp = g > 0 ? g * Num.smoothstep(1 - s.sigmaR, 1, r) : 0
        func selection(_ tH: Double) -> Double {
            let absolute = 1 - Num.smoothstep(0.5, 1.0, (tL * tL + tC * tC + tH * tH).squareRoot())
            guard ramp > 0 else { return absolute }
            let mixture = ramp * (1 - Num.smoothstep(0.5, 1.0, (mL * mL + tH * tH).squareRoot()))
            return Swift.max(absolute, mixture)
        }
        let tH = dH / s.sigmaH
        guard (tL * tL + tC * tC + tH * tH).isFinite else { return (0, 0) }
        let weight = selection(tH)
        // THE HUE ROTATION GETS ITS OWN, WIDER REACH — along hue, ahead of the swatch,
        // and only when the shift needs it.
        //
        // Rotating by `weight · shift` with the selection's own falloff folded the
        // wheel: the smoothstep's steepest slope is 3 per unit of `d`, and `d` grows at
        // most 1/(180·σH) per degree of hue, so along the hue line the map's slope is
        // `1 − 3·shift/(180·σH)` — negative once |shift| > 60·σH, which is 21° at the
        // default Range against a slider that runs to 60°. Measured at +60° there: a
        // pixel 40–60° from the swatch overtook ones nearer it by 31°, a band running
        // backwards through any smooth sky or skin gradient. Clamping the shift instead
        // would leave two thirds of the slider dead.
        //
        // Three things bound the cure, and each was learned the hard way:
        //
        // - ONLY THE HUE TERM is stretched. The fold lives on the hue axis, so the
        //   rotation measures distance with `tH / k` in place of `tH` and keeps `tL`
        //   and `tC` as they are. Widening the edge on the whole of `d` instead (the
        //   first version of this fix) let a +60° turn on mid-tone skin also turn dark
        //   hair and saturated clothing of the same hue — pixels Saturation and
        //   Luminance correctly left unselected.
        // - ONLY THE LEADING SIDE is stretched — the side the shift turns toward. On the
        //   trailing side the weight RISES as a pixel nears the swatch, so the map's
        //   slope there is `1 + |w′|·|shift|`, never below one: nothing can be
        //   overtaken. Stretching both sides made every big shift claim the same width
        //   whatever the Range, and took Range from 56 to 16 code values of authority
        //   on the colour chart (`ControlProofTests`, floor 46): Range stopped deciding
        //   what a hue turn reaches. The two halves meet at `dh = 0`, where `tH = 0`
        //   makes both distances equal with zero slope in `tH`, so the join is C¹.
        // - `k` reaches the antipode and NO FURTHER. With `tH / k`, the steepest slope
        //   along hue is `3·|shift| / (180·σH·k)`, which `k = |shift| / (0.98·60·σH)`
        //   holds to 0.98. That would carry a 60° turn 184° round — past the opposite
        //   hue, where the trailing side's zero weight would meet a nonzero one in a
        //   seam. So `k ≤ 1/σH` (the stretched distance is at least 1 at 180°), which
        //   binds only for |shift| above 58.8° and there still holds the slope to
        //   |shift|/60 ≤ 1: flat at worst, never reversed.
        //
        // Below the fold `k` is exactly 1 and the rotation is the selection's own
        // `weight`, so saved looks there render as before. Saturation, Luminance and
        // Variance always keep `weight`. `hueWeight ≥ weight` everywhere, so it is the
        // one the early-out reads.
        let hueWeight: Double
        if dh * s.shiftH > 0 {
            let k = Swift.min(Swift.max(1, abs(s.shiftH) / (0.98 * 60 * s.sigmaH)),
                              Swift.max(1, 1 / s.sigmaH))
            hueWeight = selection(tH / k)
        } else {
            hueWeight = weight
        }
        return (weight, hueWeight)
    }

    /// The linear opponent chroma of `c` — OKLab's two matrices with no cube root
    /// between them, (a, b) rows only. Linear, so a mixture's is the mixture of its
    /// parts', and a neutral's is zero.
    static func linearChroma(_ c: RGB,
                             context: OKLabTransform.Context) -> (a: Double, b: Double) {
        let lms = context.rgbToLMS.apply(c)
        let m = OKLabTransform.lmsToLab.m
        return (m[1][0] * lms.r + m[1][1] * lms.g + m[1][2] * lms.b,
                m[2][0] * lms.r + m[2][1] * lms.g + m[2][2] * lms.b)
    }

    /// How strongly `swatch` selects the colour `c` (a colour-stage value, as
    /// `selectionInput` returns it), 0…1 — the weight its Saturation and Luminance
    /// moves are multiplied by. Read through the compiled swatch the render uses, so a
    /// picture of the selection (the panel's range strip) cannot disagree with what the
    /// sliders do. The swatch's own shifts are ignored: a swatch nobody has moved yet
    /// still has a selection to show.
    public static func pointSelectionWeight(_ c: RGB, of swatch: PointColor,
                                            context: OKLabTransform.Context
                                                = OKLabTransform.working) -> Double {
        var probe = swatch
        probe.shift = HSLShift(h: 0, s: 0, l: 1)
        probe.variance = 0
        guard c.isFinite,
              let compiled = compiledSwatches([probe], context: context).first else { return 0 }
        let lch = context.toLCh(c)
        guard lch.L.isFinite, lch.C.isFinite else { return 0 }
        return selectionWeights(lch, linearChroma(c, context: context), compiled).weight
    }

    /// One axis of a swatch's selection, for the panel to draw (`PointSelectionStrip`).
    public enum PointAxis: Sendable, CaseIterable {
        /// ±90° round the wheel from the sample, at its lightness and chroma.
        case hue
        /// Chroma from 0 to twice the sample's (at least 0.12), at its lightness and hue.
        case saturation
        /// Lightness ±0.4 from the sample's, at its chroma and hue.
        case luminance
    }

    /// `steps + 1` colours evenly along `axis` through the swatch's sample, each with the
    /// weight the swatch gives it, and the position (0…1) of the sample itself. The
    /// colours are colour-stage values in the working space, like the sample.
    public static func pointSelectionStrip(_ swatch: PointColor, axis: PointAxis,
                                           steps: Int = 48,
                                           context: OKLabTransform.Context
                                               = OKLabTransform.working)
        -> (colours: [RGB], weights: [Double], samplePosition: Double) {
        guard swatch.sample.count >= 3, steps > 0 else { return ([], [], 0.5) }
        let t = context.toLCh(RGB(swatch.sample[0], swatch.sample[1], swatch.sample[2]))
        guard t.L.isFinite, t.C.isFinite else { return ([], [], 0.5) }
        let cMax = Swift.max(2 * t.C, 0.12)
        let lLow = Swift.max(0.02, t.L - 0.4)
        let lHigh = Swift.min(0.98, t.L + 0.4)
        var colours: [RGB] = []
        var weights: [Double] = []
        colours.reserveCapacity(steps + 1)
        weights.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            var p = t
            switch axis {
            case .hue: p.h = Num.wrapHue(t.h - 90 + 180 * u)
            case .saturation: p.C = cMax * u
            case .luminance: p.L = lLow + (lHigh - lLow) * u
            }
            let c = context.toRGB(p)
            colours.append(c)
            weights.append(pointSelectionWeight(c, of: swatch, context: context))
        }
        let position: Double
        switch axis {
        case .hue: position = 0.5
        case .saturation: position = t.C / cMax
        case .luminance: position = lHigh > lLow ? (t.L - lLow) / (lHigh - lLow) : 0.5
        }
        return (colours, weights, Num.clamp(position, 0, 1))
    }

    // MARK: - Vibrance and Saturation (D21)

    /// Low-chroma prioritization: Vibrance spends itself on the colours that have least.
    public static func lowChroma(_ chroma: Double) -> Double {
        1 - Num.smoothstep(lowChromaLo, lowChromaHi, chroma)
    }

    /// Sat-vs-Sat compression. Monotone, C¹ at the knee, asymptotic to the ceiling:
    /// already-saturated colours resist further push. Applied to the *increment* so an
    /// untouched colour is an exact fixed point.
    public static func satCompress(_ chroma: Double) -> Double {
        guard chroma > satKneeChroma else { return chroma }
        let room = satCeilingChroma - satKneeChroma
        guard room > 0 else { return chroma }
        return satCeilingChroma - room * exp(-(chroma - satKneeChroma) / room)
    }

    /// Lum-vs-Sat rolloff: no chroma-noise shadows, no neon highlights. Together with
    /// the compression above this is the actual mechanism of "expensive" colour — film's
    /// apparent richness is saturation rolloff at the extremes. Both are internal and
    /// always on; exposing them as user curves would violate the one-intent rule.
    public static func lumSatRolloff(_ brightness: Double) -> Double {
        guard brightness.isFinite else { return 0 }
        // Squared so the taper leaves the knee with zero slope: it meets the flat
        // full-effect region C¹, and a kink in this factor is a crease across a
        // gradient in the finished picture.
        let u = Swift.max(0, brightness - satRolloffHi0) / satRolloffHiWidth
        let taper = satRolloffFloor + (1 - satRolloffFloor) / (1 + u * u)
        return Num.smoothstep(satRolloffLo0, satRolloffLo1, brightness) * taper
    }

    /// The subtractive branch: per-channel gamma on the chromaticity ratios against the
    /// density-weighted norm. Colour intensifies by *densifying* — the absorbing layers
    /// deepen while the transmitting one holds, so the colour darkens as it saturates,
    /// the way stacked dye does, instead of pushing channels apart toward neon.
    /// Neutrals have unit ratios and are therefore exact fixed points.
    ///
    /// Only POSITIVE ratios are densified. Nothing between S6 and this stage clamps or
    /// gamut-maps (that is S14's job), so a colour outside the working gamut — a
    /// narrow-band LED through a 3x3 camera matrix — arrives with a negative channel,
    /// and a negative ratio is not an absorbing dye layer: the model has nothing to say
    /// about it. The old signed power (`spow`) pulled it TOWARD zero, walking the colour
    /// back into the gamut, so positive Saturation at the default Density took chroma
    /// AWAY — 17% from a 490 nm cyan at +100, more the further the slider went.
    /// Negatives are now held where they are; every all-positive colour is bit-identical
    /// to before. The cost is a C0 (not C1) join where a ratio crosses zero, which only
    /// an out-of-gamut gradient can reach. Once negatives are gamut-mapped before S9
    /// (docs/23 #13) this guard becomes a no-op. Mirrored in `ExactColorTwin.subtractive`
    /// and the GLSL `lumenSubtractive`.
    /// (SaturationOutOfGamutChromaTests)
    public static func subtractivePush(_ c: RGB, amount: Double) -> RGB {
        guard amount > 0 else { return c }
        let norm = c.maxComponent
        guard norm > 1e-9, norm.isFinite else { return c }
        let gamma = 1 + amount * densityGammaRange
        guard gamma > 0 else { return c }
        func densify(_ ratio: Double) -> Double { ratio > 0 ? Foundation.pow(ratio, gamma) : ratio }
        let r = densify(c.r / norm)
        let g = densify(c.g / norm)
        let b = densify(c.b / norm)
        let out = RGB(r * norm, g * norm, b * norm)
        return out.isFinite ? out : c
    }

    private func applyVibranceSaturation(_ c: RGB) -> RGB {
        let vibrance = Num.clamp(color.vibrance, -100, 100) / 100
        let saturation = Num.clamp(color.saturation, -100, 100) / 100
        guard vibrance != 0 || saturation != 0 else { return c }

        let input = LumenUCS.fromRGB(c, context: context)
        guard input.J.isFinite, input.C.isFinite else { return c }

        // Selection and shaping weights are read off the stage input, never the output.
        let skin = Self.skinProtectionWeight(c, context: context)
        let protection = 1 - Num.clamp(color.protectSkin, 0, 100) / 100 * skin
        let rolloff = Self.lumSatRolloff(input.J)

        // The rolloff tapers *pushes* only. Negative Saturation still reaches true B&W
        // at −100 everywhere in the frame, including the extremes.
        //
        // Skin protection now obeys the same rule on Saturation, and did not: it
        // multiplied the negative amount too, so at the shipped default of 70 a full
        // desaturation left every skin-hued pixel at 30% of its chroma — a face still
        // in colour inside a black-and-white frame. The wire format says "−100 reaches
        // true B&W" (Recipe.swift), the comment directly above says it, Lightroom does
        // it, and the code did not. A guard on a PUSH is a preference; a guard that
        // stops a pull from reaching its stated endpoint is a broken control.
        //
        // Vibrance keeps protection at both signs on purpose. Its negative end is not
        // an endpoint anybody is promised — `lowChroma` already means a saturated
        // colour barely moves — so there is no contract for the guard to break, and
        // "leave skin alone" is exactly what the dial is named for. Saturation at −100
        // still wins over it: gain 0 zeroes chroma whatever Vibrance did first.
        let vibAmount = (vibrance >= 0 ? vibrance * rolloff : vibrance)
            * Self.lowChroma(input.C) * protection
        let satAmount = saturation >= 0 ? saturation * rolloff * protection : saturation

        var mid: RGB = c
        if vibAmount != 0 {
            mid = shapedChromaScale(c, gain: 1 + vibAmount)
        }
        guard satAmount != 0 else { return mid }

        let additive = shapedChromaScale(mid, gain: 1 + satAmount)
        // Only the positive side is subtractive; a negative move is a plain walk toward
        // the neutral axis at constant Lumen UCS J (H-K brightness, D21) — NOT at
        // constant luminance. This used to say "exactly luminance-preserving", which is
        // what Black & White does (it mixes by Rec.2020 Y) and not what this does. At
        // C = 0 the H-K factor is 1, so the −100 grey's OKLab L is the input's J, and
        // OKLab L over-predicts the lightness of saturated blues and reds relative to Y:
        // the sRGB blue primary lands ≈0.42 EV above its luminance, sRGB red ≈0.26 EV,
        // green ≈0.09 EV below. Holding perceived brightness is the deliberate design
        // (docs/24 §3); it just means Saturation −100 and the B&W panel are two
        // different greys. Pinned by testSaturationMinus100HoldsHKBrightnessNotLuminance.
        guard satAmount > 0 else { return additive }
        let density = Num.clamp(color.density, 0, 100) / 100
        guard density > 0 else { return additive }
        let subtractive = Self.subtractivePush(mid, amount: satAmount)
        let blended = additive.mix(subtractive, density)

        // THE DENSITY MODEL IS ABOUT LIGHTNESS AND CHROMA. IT IS NOT ABOUT HUE.
        //
        // The photographic idea is real and worth keeping: colour intensifies by
        // DENSIFYING, the absorbing layers deepening while the transmitting one holds,
        // so a saturated colour darkens instead of pushing its channels apart toward
        // neon. That is a statement about how light and how colourful the result is.
        // Nothing in the docs, the panel, or this file's own header claims it is a
        // statement about WHICH colour it is.
        //
        // The rotation was never the model. It is an artefact of how the model is
        // implemented: `subtractivePush` raises the channel ratios to a power in linear
        // RGB, which multiplies all three log-ratios by the same gamma — and a log-RGB
        // ray is not an iso-hue line in OKLab. Only the six primaries and secondaries
        // lie on one. Everything between them turns.
        //
        // WHAT IT COST, measured over 720 colours (36 hues x 5 lightnesses x 4 gamut
        // fills) at the SHIPPED Density default, before this line existed:
        //
        //     Saturation  +10 -> 2.14 deg   +25 -> 4.71   +50 -> 7.83   +100 -> 11.57
        //     on the skin band            +25 -> 2.21     +50 -> 4.15   +100 ->  7.29
        //
        // Read charitably as film-likeness it still fails on its own terms. It is
        // UNBOUNDED — gamma is 1 + satAmount, so the rotation grows with the slider and
        // never reaches a ceiling in range. It is ASYMMETRIC — exactly zero below zero,
        // so +50 and -50 are not one instrument seen from two sides. And it is not what
        // any dye actually does: stacked dye darkens, it does not walk skin four degrees
        // toward orange.
        //
        // So keep the darkening and drop the turn. The hue is restored ONCE, after the
        // blend, on the colour the two branches are two renderings of — one restore
        // rather than one per branch, cheaper than either, and exactly zero rotation by
        // construction rather than approximately zero.
        //
        // EASED ACROSS THE GATE, not switched at it — `chromaGate` is this file's own
        // idiom and its comment states the rule: it "multiplies adjustment magnitude,
        // never membership". The hue of a near-neutral is the arctangent of two
        // nearly-zero numbers and carries nothing to preserve, so the restore has to
        // fade out down there; but fading it out with a `guard` puts a STEP in the
        // transform at chroma 0.02, and a step is the one thing a colour cube cannot
        // represent at any lattice size.
        //
        // AND THE MEASUREMENT REFUTED THE REASON. The switched form was caught by
        // `testTheColourTableConverges`, which measures the composed transform at 33,
        // 65 and 129 — it left the 129-cube at 0.020475 EV against a 0.02 bound. The
        // obvious reading was "the step is why", since interpolation error falls with
        // lattice size and a discontinuity does not. That reading is WRONG, and easing
        // it is what proved so: the eased form measures 0.020462. The step was worth
        // about 1.3e-5 EV. What actually costs is the CURVATURE — a hue restore is a
        // nonlinear correction, and tabulating it is simply harder.
        //
        // The easing stays anyway, on principle rather than on that number: a transform
        // that gets baked into a cube should not carry a step, whether or not this
        // particular metric happens to notice one. But the honest cost of this fix is
        // written where the bounds are, not here, and it is a bound that moved rather
        // than a discontinuity that was removed.
        //
        // So the hue is rotated from where the blend put it TOWARD the source hue by
        // a weight that is 1 from `gateLoChroma` up, eases to 0 at chroma 0, and is
        // smooth throughout. `hueDelta` takes the short way round, so the
        // interpolation crosses the 0/360 seam correctly rather than travelling the
        // long way when the two hues straddle it.
        //
        // THE WEIGHT USED TO BE `chromaGate` ITSELF, which only opens fully at
        // `gateHiChroma` (0.06) — and 0.02…0.06 is not "near-neutral". It is every
        // coloured surface a few stops under mid-grey, because OKLab chroma falls with
        // the cube root of exposure. On `tonalColourWedge` at the SHIPPED Density the
        // turn survived there at 3.05° for Saturation +50 and 6.03° for +100, and
        // 12.94° at Density 100 (September audit B1-05). The fade now lives entirely
        // below 0.02, where the proof metric and `HuePreservationTests` stop calling
        // an angle a hue, and `testTheColourTableConverges` still passes at all three
        // lattice sizes with the steeper ease.
        let source = context.toLCh(mid)
        let out = context.toLCh(blended)
        guard source.h.isFinite, out.h.isFinite,
              out.L.isFinite, out.C.isFinite else { return blended }
        let weight = Num.smoothstep(0, Self.gateLoChroma, source.C)
        guard weight > 0 else { return blended }
        let hue = Num.wrapHue(out.h + Num.hueDelta(out.h, source.h) * weight)
        let held = context.toRGB(OKLCh(L: out.L, C: out.C, h: hue))
        return held.isFinite ? held : blended
    }

    /// Scale chroma in Lumen UCS — holding H-K-corrected perceived brightness and hue
    /// — with the sat-vs-sat curve applied as a RATIO against the untouched colour's
    /// own compressed chroma.
    ///
    /// It used to apply as an increment: `base + (compress(base·gain) − compress(base))`.
    /// That makes an untouched colour an exact fixed point, which is the property it
    /// was written for, and it does reach zero for anything under the compression
    /// knee. Above the knee it does not: at gain 0 it leaves `base − compress(base)`,
    /// which is 0.10 of chroma at base 0.40 and 0.66 at base 1.0. Since OKLab chroma
    /// scales as the cube root of exposure, a colour six stops up carries four times
    /// the chroma of the same colour at mid-grey — so Saturation at −100 left more and
    /// more colour behind the brighter the pixel was, in flat contradiction of the
    /// range comment on the slider and of `true B&W at −100`.
    ///
    /// The ratio form keeps every property the increment form had and fixes that one.
    /// Gain 1 returns `base` exactly, so an untouched colour is still a fixed point.
    /// Gain 0 returns exactly zero at every chroma. It is monotone and smooth in gain
    /// with no branch at 1. And a colour already past the knee still resists: as gain
    /// grows the result approaches `ceiling · base / compress(base)`, which for a
    /// colour at 0.5 is 0.535 — it can be pushed, barely, which is the point.
    private func shapedChromaScale(_ c: RGB, gain: Double) -> RGB {
        var u = LumenUCS.fromRGB(c, context: context)
        guard u.C.isFinite, u.J.isFinite else { return c }
        let base = Swift.max(0, u.C)
        let g = Swift.max(0, gain)
        let reference = Self.satCompress(base)
        u.C = reference > 1e-12 ? Self.satCompress(base * g) * base / reference : base * g
        let out = LumenUCS.toRGB(u, context: context)
        return out.isFinite ? out : c
    }

    // MARK: - Black & White (D20)

    /// - Parameter bandSource: the colour whose hue and chroma choose the band — the
    ///   pre-Saturation pixel, so a chroma scale cannot gate the mix off. See `apply`.
    private func applyBlackAndWhite(_ c: RGB, bandSource: RGB) -> RGB {
        guard bwEnabled else { return c }
        let base = lumaWeights.r * c.r + lumaWeights.g * c.g + lumaWeights.b * c.b
        guard base.isFinite else { return c }
        var gain: Double = 1
        if bwHasBands {
            let lch = context.toLCh(bandSource.isFinite ? bandSource : c)
            if lch.C.isFinite, lch.L.isFinite {
                // The same smooth periodic band model as the Mixer, which is why an
                // aggressive mix (Blue −80 skies) darkens cleanly instead of banding —
                // but at the CANONICAL geometry, not the Mixer's handles.
                //
                // The split is the develop/look line (D4). The B&W mix lives in `look`
                // and travels to eight hundred frames; the Mixer's ring handles live in
                // `develop` and belong to one photo. Reading them here would make a
                // pasted Look render differently on every frame depending on how that
                // frame's Mixer happened to be shaped, which is exactly the
                // non-portability the Look layer exists to prevent.
                let w = Self.bandWeights(hue: lch.h)
                let gate = Self.chromaGate(lch.C)
                for i in 0..<Self.bandCount {
                    gain += w[i] * gate * (blackAndWhiteBands[i] / 100) * Self.bwKappa
                }
            }
        }
        // The working space's luminance weights sum to one, so an equal-energy triple of
        // this value is a true neutral at exactly the mixed luminance.
        return RGB(gray: Swift.max(0, base * Swift.max(0, gain)))
    }
}
