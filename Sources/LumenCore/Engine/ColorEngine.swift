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
    /// Each band's resolved Hue move in degrees (`resolvedHueShifts`), and whether they
    /// are all zero.
    private let hueShifts: [Double]
    private let hueIsFlat: Bool
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
    /// WS-31. Lightroom's eight names, and now they are true: the bands moved (see
    /// `bandHueCentres`), so the band called Green holds foliage and sRGB green, and the
    /// band called Blue holds skies and sRGB blue. The interim names "Mint" and "Azure"
    /// (B1-08) described where the old equal-spaced 45° centres happened to sit; they
    /// are gone with that geometry. These strings are not in the wire format — the
    /// recipe stores bands POSITIONALLY — so the rename itself costs nothing; what costs
    /// a `pipelineVersion` pin is the geometry move (docs/quality/lanes/WS-31/NEEDS.md).
    public static let bandNames: [String] = [
        "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"
    ]

    /// The LEGACY equal-spaced grid: 45° apart, anchored on the OKLCh hue of sRGB red.
    ///
    /// The Mixer no longer uses it. It is kept, unchanged, because the B&W mix is
    /// denominated in it (`uniformBandWeights(hue:)`, the GPU finish pass) and the B&W
    /// lane has not moved; and because recipes rendered before WS-31 were made on it,
    /// which is what a `pipelineVersion` pin has to reproduce.
    public static let bandAnchorDegrees: Double = 29.23
    public static let bandSpacingDegrees: Double = 45.0

    /// The legacy grid's eight centres (see `bandAnchorDegrees`). B&W only.
    public static let uniformBandHueCentres: [Double] = {
        var v: [Double] = []
        v.reserveCapacity(ColorEngine.bandCount)
        for i in 0..<ColorEngine.bandCount {
            v.append(Num.wrapHue(ColorEngine.bandAnchorDegrees
                                 + ColorEngine.bandSpacingDegrees * Double(i)))
        }
        return v
    }()

    /// The Mixer's band centres, OKLCh degrees, wire order Red…Magenta (WS-31).
    ///
    /// UNEVEN, the way Lightroom's are, because the colours photographs are made of are
    /// uneven: sRGB red, orange and skin crowd into 25° of OKLCh hue while green to cyan
    /// spans 50°. The equal 45° grid this replaces put sRGB orange and sRGB green on
    /// exact 50/50 seams, gave ColorChecker light skin 86% to Red, and left foliage 84%
    /// in Yellow with "Green" holding nothing (WS-31 audit M4/M5).
    ///
    /// Solved numerically against the acceptance spec rather than transcribed: every
    /// sRGB primary and secondary sits ≥ 0.8 in its own band, ColorChecker skins and
    /// MST 5–8 ≥ 0.6 in Orange, skies ≥ 0.9 in Blue, foliage mostly Green, and every gap
    /// ≥ 40° so a full hue move (`hueRangeDegrees`) never folds the circle.
    ///
    /// DERIVED, not listed: a centre is the middle of the band's plateau — halfway
    /// between where the hand-over from the previous band ends and the hand-over to the
    /// next begins (`bandCrossoverDegrees`, `bandTransitionDegrees`). So every default
    /// core is symmetric, `BandArc.coreCentre` is the centre, Uniformity converges on
    /// it, and the centre is the knot the band's Hue slider moves.
    public static let bandHueCentres: [Double] = (0..<ColorEngine.bandCount).map { i in
        let n = ColorEngine.bandCount
        let j = (i + n - 1) % n
        let start = ColorEngine.bandCrossoverDegrees[j] + ColorEngine.bandTransitionDegrees[j] / 2
        let end = ColorEngine.bandCrossoverDegrees[i] - ColorEngine.bandTransitionDegrees[i] / 2
        return Num.wrapHue(start + Num.wrapHue(end - start) / 2)
    }

    /// Where band `i` hands over to band `i + 1` (weight 0.5 each), OKLCh degrees, and
    /// how wide that hand-over is. These ARE the default geometry: band `i`'s upper core ends `bandTransitionDegrees[i] / 2` before the
    /// crossover and its upper feather spans the whole transition, and band `i + 1`'s
    /// lower side mirrors it. Two complementary raised cosines over the same interval
    /// sum to exactly 1, so at the default geometry the normalised weight IS that raised
    /// cosine: C¹, no wedge, and no slope steeper than π/(2·width).
    public static let bandCrossoverDegrees: [Double] = [37.7, 83.5, 121.0, 173.3, 228.5, 276.0, 316.0, 356.6]
    public static let bandTransitionDegrees: [Double] = [31.8, 30.5, 30.5, 46.2, 35.0, 31.0, 32.0, 32.0]

    /// The WIRE UNITS of the ring handles, and nothing else.
    ///
    /// `MixerBand.core`/`feather` are stored relative to the band's own default
    /// geometry: a stored core side of 22.5 means "this band's default core on this
    /// side", 11.25 half of it, 45 twice it. That is what lets the default become
    /// per-band without a migration of the wire value: every recipe that never touched
    /// a handle stores `[22.5, 22.5]`/`[15, 15]` and resolves to the new per-band
    /// default, and a dragged handle keeps its proportion. `bandArcs` turns wire values
    /// into degrees and `wireHandles(for:band:)` turns degrees back.
    public static let bandCoreDegrees: Double = 22.5
    public static let bandFeatherDegrees: Double = 15.0

    /// Bounds on the user's four ring handles, in resolved DEGREES (docs/05: draggable
    /// core + per-side feather, "fully visual, no hidden numeric range").
    ///
    /// The feather floor is 12°, not the old 2°. A raised-cosine feather of extent F has
    /// a second derivative up to (π/F)²/2 per deg²; at 2° that is a 1.2/deg² kink, a
    /// visible crease in any gradient that crosses the band edge. At 12° the worst arc
    /// set the sanitizer can produce stays under 0.05/deg² (`MixerBandGeometryTests`).
    public static let bandCoreMinDegrees: Double = 3.4
    public static let bandCoreMaxDegrees: Double = 44.0
    public static let bandFeatherMinDegrees: Double = 12.0
    public static let bandFeatherMaxDegrees: Double = 60.0

    /// The invariant that keeps the partition of unity a partition: every band reaches
    /// at least half the gap to its neighbour on that side, plus this margin.
    ///
    /// `bandWeights` has a fallback for the case where every band's weight at some hue
    /// is zero — it hands the whole weight to the nearest band. That branch is a HARD
    /// EDGE, the one thing this band model exists not to have. With uneven centres a
    /// single reach cannot close that door for every gap, so the floor is per side: two
    /// neighbours that each reach past the midpoint of their gap by this margin overlap
    /// by twice it, every hue is strictly inside some band's falloff, and the sum is
    /// never zero. The fallback stays as a guard against a corrupt decode only.
    public static let bandMinReachMarginDegrees: Double = 8.0

    /// The degrees between band `i`'s centre and the next band's, going up.
    public static func bandGapAbove(_ i: Int) -> Double {
        let n = bandCount
        let k = ((i % n) + n) % n
        return Num.wrapHue(bandHueCentres[(k + 1) % n] - bandHueCentres[k])
    }

    /// The degrees between band `i`'s centre and the previous band's, going down.
    public static func bandGapBelow(_ i: Int) -> Double { bandGapAbove(i - 1) }

    /// The minimum reach of band `i` to each side, in degrees (see
    /// `bandMinReachMarginDegrees`).
    public static func bandMinReach(_ i: Int) -> (below: Double, above: Double) {
        (bandGapBelow(i) / 2 + bandMinReachMarginDegrees,
         bandGapAbove(i) / 2 + bandMinReachMarginDegrees)
    }

    /// Band `i`'s default geometry in degrees, derived from the centres, crossovers and
    /// transition widths above (see `bandCrossoverDegrees`).
    public static func defaultArc(_ i: Int) -> BandArc {
        let n = bandCount
        let k = ((i % n) + n) % n
        let j = (k + n - 1) % n
        let centre = bandHueCentres[k]
        let up = bandTransitionDegrees[k]
        let down = bandTransitionDegrees[j]
        let coreAbove = Num.wrapHue(bandCrossoverDegrees[k] - up / 2 - centre)
        let coreBelow = Num.wrapHue(centre - bandCrossoverDegrees[j] - down / 2)
        return BandArc(centre: centre, coreBelow: coreBelow, coreAbove: coreAbove,
                       featherBelow: down, featherAbove: up)
    }

    /// The largest Hue move, in degrees, at ±100 (SPEC H3: 25–35° at the centre).
    ///
    /// It was 45° — "±100 lands exactly on the adjacent band centre" — and with a 25°
    /// transition that folded the hue circle: 14–20° of input hue on every band came
    /// out in reverse order, a crease on every gradient that crossed a band edge (audit
    /// M1). Lightroom's ±100 is about 30° of HSV, well short of the neighbour.
    public static let hueRangeDegrees: Double = 35.0
    /// The smallest slope of output hue against input hue any Hue setting may produce.
    /// Each band's move is limited so that it alone keeps this slope, and a recipe whose
    /// moves combine to squeeze some hue further is scaled down as a whole until it
    /// reaches this floor, so the hue circle is never folded (`resolvedHueShifts`).
    public static let hueMinSlope: Double = 0.25
    /// The hue move's falloff eases in and out over this fraction of its length at each
    /// end (`hueTransfer`), so it leaves the band's core and arrives at zero with slope 0.
    public static let hueRampFraction: Double = 0.1
    /// How far past the band's own reach (core + feather, the Band range ring) its Hue
    /// move falls off: 1.35 × the reach on each side. A hue move cannot be as narrow as
    /// a Saturation or Luminance move — turning a hue 30° needs about 40° of hue
    /// to hand back over without folding — so the ring scales it rather than clipping it:
    /// a narrower ring moves fewer hues, a wider one more (SPEC R6).
    public static let hueReachFactor: Double = 1.35
    /// Head-room under `hueMinSlope` for what the 0.05° grid in `resolvedHueShifts` can
    /// miss between samples; a single band is limited with the same margin, so it is
    /// never scaled and ±100 stay equal and opposite.
    public static let hueSlopeMargin: Double = 0.01

    /// The length of band `arc`'s hue falloff below and above, in degrees: from the core
    /// edge to `hueReachFactor` × (core + feather).
    public static func hueFalloff(_ arc: BandArc) -> (below: Double, above: Double) {
        (hueReachFactor * (arc.coreBelow + arc.featherBelow) - arc.coreBelow,
         hueReachFactor * (arc.coreAbove + arc.featherAbove) - arc.coreAbove)
    }

    /// Band `arc`'s Hue move at ±100, in degrees: the same both ways, so a move and its
    /// opposite are equal and opposite on every pixel; capped by `hueRangeDegrees` and
    /// by the shorter falloff, so that the band alone never squeezes the circle below
    /// `hueMinSlope` (its steepest falloff slope is 1/(1 − ramp) per falloff length).
    public static func bandHueShiftLimit(_ arc: BandArc) -> Double {
        let f = hueFalloff(arc)
        let peak = 1 / (1 - hueRampFraction)
        return Swift.min(hueRangeDegrees,
                         (1 - hueMinSlope - hueSlopeMargin) * Swift.min(f.below, f.above) / peak)
    }

    /// The chroma-preserving lightness kernel's constant for POINT COLOUR. The Mixer has
    /// its own, multiplicative, kernel (`mixerLightness`); this one is shared with
    /// nothing else now and is unchanged.
    public static let lumKappa: Double = 1.0

    /// The Mixer's Luminance, per band: at ±100 OKLab L is scaled by 2^(stops·ω(L)),
    /// chroma held. `mixerLumStopsDown[i]` is band i's stops at −100, `…Up[i]` at +100.
    ///
    /// MULTIPLICATIVE, so it can never reach black and it is a move in stops rather
    /// than the old additive 0.25 of L, which took 983's dark sky 6 EV down with 11% of
    /// it crushed to code 0 while 2545's bright sky moved 2.3 EV (audit M3). OKLab L is
    /// close to Y^(1/3), so 2^s on L is about 3s stops of luminance.
    ///
    /// Tuned through the default display transform to Lightroom's range: Blue −100 about
    /// −1.1…−1.5 EV and +100 about +0.9…+1.1 EV on the corpus skies, and Orange gentler,
    /// because skin sits where the default rendering is steepest — the same scene stops
    /// read 1.4× as many display stops on mid skin as on a bright, saturated sky.
    public static let mixerLumStopsDown: [Double] = [0.30, 0.27, 0.30, 0.30,
                                                     0.33, 0.345, 0.33, 0.30]
    public static let mixerLumStopsUp: [Double] = [0.32, 0.29, 0.32, 0.32,
                                                   0.35, 0.36, 0.35, 0.32]

    /// ω(L) = (min(L, cap) / reference)^exponent: the stops scale with lightness.
    ///
    /// Dark colours move fewer stops and bright ones more. Through a rendering with a
    /// shoulder the same scene stops read far fewer display stops on a bright sky than
    /// on a dark one (2545's against 983's: 0.68×), so a flat stop count made Blue +100
    /// either blow a dark sky out or barely touch a bright one. Capped at L = 1 (about
    /// +2.5 EV over mid-grey) so it stays monotone in L at every setting: d ln L′/d ln L
    /// = 1 + stops·ln2·exponent·ω ≥ 1 − 0.36·0.69·0.9·1.87 > 0.5.
    public static let mixerLumReferenceLightness: Double = 0.5
    public static let mixerLumLightnessExponent: Double = 0.9
    public static let mixerLumLightnessCap: Double = 1.0

    /// The Mixer's chroma gate: full authority from C 0.04, nothing below 0.022.
    ///
    /// Not `chromaGate` (0.02…0.06), which Point Colour and Skin keep. Skies sit at C
    /// 0.047–0.064, inside that ramp, so per-pixel chroma noise modulated a Blue move
    /// and came out as luminance noise — 4.7× the sky grain on 1840 at Blue −100 —
    /// plus a pale fringe on every low-chroma sky/leaf edge pixel (audit M3). Fully open
    /// by 0.04, the whole sky is inside the flat top and its chroma noise no longer
    /// reaches luminance. The low end cannot come down: at C 0.012–0.023 (the hue
    /// wheel's near-neutral ring) any gate above ~0.2 moves near-greys by more than 0.03
    /// under an all-bands edit, and the same gate would turn a grey wall's chroma noise
    /// into luminance mottling under a single band. The cost, measured and recorded in
    /// docs/quality/lanes/WS-31/BUILD-NOTES.md: the palest and darkest skin (MST 1, 2, 9,
    /// 10, C 0.011–0.021) is still below the gate.
    public static let mixerGateLoChroma: Double = 0.022
    public static let mixerGateHiChroma: Double = 0.04

    /// Saturation +100 rolls off toward the edge of the display-primaries cone.
    ///
    /// A push used to be a flat C × 2, and on the ColorChecker that sent 28.6% of the
    /// pixels to a code-0 channel (audit M6). Now the push's gain is 1 + p·(1 − r/R),
    /// where r is the colour's chroma as a fraction of the most an sRGB-primaries colour
    /// of that lightness and hue can have (`mixerReferenceSaturation`) and R is this
    /// ceiling. A dull colour still doubles at +100; one at the display's edge does not
    /// move; and r′ = r(1 + p(1 − r/R)) rises with r at every p ≤ 1, so the push never
    /// reverses chroma order.
    ///
    /// The cone is scale-free — sRGB channels ≥ 0 only, no upper face — so this is not a
    /// display-referred clip in a scene-referred stage: it reads hue and the ratio C/L,
    /// both of which exposure leaves alone.
    public static let mixerSatCeiling: Double = 1.10

    /// ln σ(h) as a 6-harmonic Fourier series in the working OKLab hue: σ is the largest
    /// C/L whose sRGB-primaries linear value has no negative channel (the scale-free
    /// cone `mixerSatCeiling` is measured against). Order: a0, then (cos kh, sin kh) for
    /// k = 1…6. Fitted by least squares to the exact cone on a 0.25° grid
    /// (docs/quality/lanes/WS-31/BUILD-NOTES.md); the true σ has corners at the
    /// primaries and secondaries, the series rounds them, which is what keeps a push
    /// free of hue seams. Within 3% of the exact cone on 15 of the 18 ColorChecker
    /// colours; below it (a gentler push) at the blue corner.
    public static let mixerSatReferenceCoefficients: [Double] = [
        -1.2100707970194082,
        0.3863056409922535, -0.26126513638081733,
        -0.06590516437000735, -0.2252915900015586,
        0.0039556156251049236, 0.21429153012149343,
        0.013591315069540694, 0.03513436518353367,
        0.03159289841278413, -0.04054023126330382,
        -0.0693018124744145, 0.01715000897423165,
    ]

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

    public static let primaryRotationDegrees: Double = 20.0
    public static let primaryPurityScale: Double = 0.5
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
        let shifts = Self.resolvedHueShifts(sanitized, arcs: self.arcs)
        self.hueShifts = shifts
        self.hueIsFlat = shifts.allSatisfy { $0 == 0 }
        self.uniformity = Num.clamp(mixer.uniformity, 0, 100)
        var mixerFlat = true
        for b in sanitized where b.hue != 0 || b.sat != 0 || b.lum != 0 { mixerFlat = false }
        self.mixerIsIdentity = mixerFlat && Num.clamp(mixer.uniformity, 0, 100) == 0

        self.swatches = Self.compiledSwatches(pointColors, context: context)

        let m: Mat3 = Self.primariesMatrix(primaries, space: Self.workingSpace)
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
                        hueShifts[i],
                        Num.clamp(band.sat, -100, 100) / 100,
                        Self.bandLumStops(band.lum, band: i),
                        bandTargetHue(i)]
            }
            resolved.mixer = (bandRows, -uniformity / 100)
        }
        resolved.swatches = swatches.map { s in
            [s.target.L, s.target.C, s.target.h, s.sigmaL, s.sigmaC, s.sigmaH,
             s.shiftH, s.shiftS, s.shiftL * Self.lumKappa, s.q]
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

    /// The default geometry, as arcs: `defaultArc(i)` for every band, which is also
    /// exactly what `bandArcs` resolves an untouched recipe to. What `bandWeights(hue:)`
    /// uses. (The B&W mix does NOT: it stays on the legacy grid, `uniformBandWeights`.)
    public static let canonicalArcs: [BandArc] =
        ColorEngine.bandArcs(Array(repeating: MixerBand(), count: ColorEngine.bandCount))

    /// Resolve the wire format's per-band handles into arcs in degrees, clamped so the
    /// partition of unity survives any file (see `bandMinReachMarginDegrees`).
    ///
    /// The wire values are RELATIVE to the band's own default (see `bandCoreDegrees`):
    /// degrees = wire / 22.5 × the default core on that side, and likewise for the
    /// feather against 15. So the old wire default `[22.5, 22.5]`/`[15, 15]` — what every
    /// recipe that never dragged a handle stores — resolves to the new per-band default,
    /// and a handle dragged to half the old default keeps half the new one.
    public static func bandArcs(_ bands: [MixerBand]) -> [BandArc] {
        var out: [BandArc] = []
        out.reserveCapacity(bandCount)
        for i in 0..<bandCount {
            let band: MixerBand = i < bands.count ? bands[i] : MixerBand()
            let d = defaultArc(i)
            let reach = bandMinReach(i)
            func side(_ v: [Double], _ index: Int, _ unit: Double, _ fallback: Double,
                      _ lo: Double, _ hi: Double) -> Double {
                guard index < v.count, v[index].isFinite else { return fallback }
                // An exact wire default is the exact default arc, with no rounding
                // through the division, so `canonicalArcs` IS `defaultArc`.
                let degrees = v[index] == unit ? fallback : v[index] / unit * fallback
                return Num.clamp(degrees, lo, hi)
            }
            let cb: Double = side(band.core, 0, bandCoreDegrees, d.coreBelow,
                                  bandCoreMinDegrees, bandCoreMaxDegrees)
            let ca: Double = side(band.core, 1, bandCoreDegrees, d.coreAbove,
                                  bandCoreMinDegrees, bandCoreMaxDegrees)
            var fb: Double = side(band.feather, 0, bandFeatherDegrees, d.featherBelow,
                                  bandFeatherMinDegrees, bandFeatherMaxDegrees)
            var fa: Double = side(band.feather, 1, bandFeatherDegrees, d.featherAbove,
                                  bandFeatherMinDegrees, bandFeatherMaxDegrees)
            // Widen the FEATHER, never the core, to meet the minimum reach: the core is
            // what the user drew and the feather is how it lets go, so a narrow
            // selection stays narrow and only its falloff is forced to stay smooth.
            fb = Swift.max(fb, reach.below - cb)
            fa = Swift.max(fa, reach.above - ca)
            out.append(BandArc(centre: bandHueCentres[i],
                               coreBelow: cb, coreAbove: ca,
                               featherBelow: fb, featherAbove: fa))
        }
        return out
    }

    /// The wire values that `bandArcs` resolves to `arc` for band `i` — the inverse the
    /// panel needs to write a dragged handle back. Degrees in, wire units out (see
    /// `bandCoreDegrees`). An arc that is already legal round-trips exactly:
    /// `bandArcs` of the result is `arc`.
    public static func wireHandles(for arc: BandArc, band i: Int)
        -> (core: [Double], feather: [Double]) {
        let d = defaultArc(i)
        func wire(_ degrees: Double, _ fallback: Double, _ unit: Double) -> Double {
            degrees == fallback ? unit : degrees / fallback * unit
        }
        return ([wire(arc.coreBelow, d.coreBelow, bandCoreDegrees),
                 wire(arc.coreAbove, d.coreAbove, bandCoreDegrees)],
                [wire(arc.featherBelow, d.featherBelow, bandFeatherDegrees),
                 wire(arc.featherAbove, d.featherAbove, bandFeatherDegrees)])
    }

    // MARK: - Band weights

    /// The 8-band partition of unity at `hue`, in wire order, at the Mixer's DEFAULT
    /// geometry (`canonicalArcs`). It must not move when a Mixer handle does.
    public static func bandWeights(hue: Double) -> [Double] {
        bandWeights(hue: hue, arcs: canonicalArcs)
    }

    /// The LEGACY partition: the equal 45° grid (`uniformBandHueCentres`) with the old
    /// ±22.5° core and 15° feather. The B&W mix is denominated in it and has not moved
    /// (WS-31 changed only the Mixer; docs/quality/lanes/WS-31/NEEDS.md), and it is what
    /// a pinned pre-WS-31 recipe's Mixer used.
    public static let uniformArcs: [BandArc] = uniformBandHueCentres.map {
        BandArc(centre: $0, coreBelow: 22.5, coreAbove: 22.5,
                featherBelow: 15, featherAbove: 15)
    }

    /// `bandWeights` on the legacy grid (see `uniformArcs`). B&W only.
    public static func uniformBandWeights(hue: Double) -> [Double] {
        bandWeights(hue: hue, arcs: uniformArcs)
    }

    /// The 8-band partition of unity at `hue`, in wire order. Σw = 1 exactly, on every
    /// path including the degenerate one. Exposed so the UI's ring and the "show reach"
    /// overlay draw the weights the engine actually uses, not a redrawn approximation.
    public static func bandWeights(hue: Double, arcs: [BandArc]) -> [Double] {
        var w: [Double] = [Double](repeating: 0, count: bandCount)
        var sum: Double = 0
        for i in 0..<bandCount {
            let arc: BandArc = i < arcs.count ? arcs[i] : canonicalArcs[i]
            let v = rawBandWeight(hue: hue, arc: arc)
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
                let centre: Double = i < arcs.count ? arcs[i].centre : bandHueCentres[i]
                let score = abs(Num.hueDelta(centre, hue)) / reach
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

    /// One band's membership BEFORE normalisation: 1 on the core, a raised-cosine
    /// feather to 0 beyond it. At the default geometry adjacent feathers are
    /// complementary, so these already sum to 1 (`bandCrossoverDegrees`).
    static func rawBandWeight(hue: Double, arc: BandArc) -> Double {
        let d = Num.hueDelta(arc.centre, hue)          // signed wrap180(hue − centre)
        let below = Swift.max(0, -d - arc.coreBelow)
        let above = Swift.max(0, d - arc.coreAbove)
        if below > 0 { return featherFalloff(below, extent: arc.featherBelow) }
        if above > 0 { return featherFalloff(above, extent: arc.featherAbove) }
        return 1
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
    /// is a true answer and a cheap one to say. The gate is the MIXER's (`mixerGate`),
    /// so a pick answers exactly where the sliders it selects can act.
    public static func dominantBand(
        for colour: RGB,
        arcs: [BandArc],
        context: OKLabTransform.Context = OKLabTransform.working) -> Int? {
        guard colour.isFinite else { return nil }
        let lch = context.toLCh(colour)
        guard lch.C.isFinite, lch.h.isFinite, mixerGate(lch.C) > 0 else { return nil }
        return dominantBand(hue: lch.h, arcs: arcs)
    }

    /// Chroma gate. Multiplies adjustment magnitude, never membership.
    public static func chromaGate(_ chroma: Double) -> Double {
        Num.smoothstep(gateLoChroma, gateHiChroma, chroma)
    }

    /// The Mixer's own chroma gate (`mixerGateLoChroma…mixerGateHiChroma`). Scales the
    /// magnitude of every gated Mixer move — Hue, a Saturation push, Luminance and
    /// Uniformity — and never membership. Point Colour and Skin keep `chromaGate`.
    public static func mixerGate(_ chroma: Double) -> Double {
        Num.smoothstep(mixerGateLoChroma, mixerGateHiChroma, chroma)
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

    /// Rotate and rescale each primary's chromaticity about the white point, then rebuild
    /// the RGB→XYZ matrix. The rebuild renormalizes so `M · (1,1,1)` is the white point:
    /// **greys are preserved by construction**, at any setting. That is the property that
    /// beats LrC Calibration, where extreme primary moves drag neutrals off-axis.
    private static func primariesMatrix(_ p: Primaries, space: RGBColorSpace) -> Mat3 {
        let hues: [Double] = [p.rHue, p.gHue, p.bHue]
        let purities: [Double] = [p.rPurity, p.gPurity, p.bPurity]
        let base: [Chromaticity] = [space.red, space.green, space.blue]
        var flat = true
        for i in 0..<3 where hues[i] != 0 || purities[i] != 0 { flat = false }
        if flat { return .identity }

        let w = space.white
        var moved: [Chromaticity] = []
        moved.reserveCapacity(3)
        for i in 0..<3 {
            let theta = Num.clamp(hues[i], -100, 100) / 100 * primaryRotationDegrees * .pi / 180
            let rho = 1 + Num.clamp(purities[i], -100, 100) / 100 * primaryPurityScale
            let dx = base[i].x - w.x
            let dy = base[i].y - w.y
            let ct = cos(theta)
            let st = sin(theta)
            let ox = rho * (ct * dx - st * dy)
            let oy = rho * (st * dx + ct * dy)
            moved.append(safeChromaticity(white: w, offsetX: ox, offsetY: oy, fallback: base[i]))
        }

        let remapped = RGBColorSpace(name: "primaries", red: moved[0], green: moved[1],
                                     blue: moved[2], white: w)
        let toXYZ = remapped.toXYZ
        guard abs(toXYZ.determinant) > 1e-9 else { return .identity }
        let full = space.fromXYZ * toXYZ
        guard abs(full.determinant) > 1e-9 else { return .identity }
        for row in full.m {
            for value in row where !value.isFinite { return .identity }
        }
        return full
    }

    /// Purity at ±100 can push a primary off the chromaticity plane entirely (Rec.2020's
    /// blue leaves y > 0 well before the slider ends). Shrink the offset along its own
    /// direction until it lands somewhere a matrix can be built from, rather than letting
    /// the derivation trap or emit garbage.
    private static func safeChromaticity(white w: Chromaticity,
                                         offsetX: Double, offsetY: Double,
                                         fallback: Chromaticity) -> Chromaticity {
        func valid(_ s: Double) -> Bool {
            let x = w.x + s * offsetX
            let y = w.y + s * offsetY
            return x.isFinite && y.isFinite && y > 0.002 && x > 0.001 && (x + y) < 0.999
        }
        if valid(1) { return Chromaticity(w.x + offsetX, w.y + offsetY) }
        var lo: Double = 0
        var hi: Double = 1
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if valid(mid) { lo = mid } else { hi = mid }
        }
        // A primary collapsed onto the white point would make the matrix singular.
        guard lo > 0.05 else { return fallback }
        return Chromaticity(w.x + lo * offsetX, w.y + lo * offsetY)
    }

    // MARK: - Colour Mixer (D13)

    /// The chroma-preserving lightness kernel of POINT COLOUR's Luminance. Chroma is not
    /// an argument and never moves (invariant #1). The Mixer used to share it and no
    /// longer does: see `mixerLightness`.
    ///
    /// Rises from a true zero at black to full authority at `lumShapePeak`, then holds.
    /// See `lumShapePeak` for why it holds rather than falling back to zero at 1.0.
    public static func lumShape(_ lightness: Double) -> Double {
        guard lightness.isFinite else { return 0 }
        let t = Num.clamp(lightness, 0, lumShapePeak)
        return t * (1 - t)
    }

    /// The Mixer's chroma-preserving lightness move: OKLab L scaled by 2^(stops·ω(L)),
    /// where `stops` is the gated, membership-weighted sum of the bands' Luminance in
    /// stops (`mixerLumStopsDown`/`Up`) and ω is `mixerLumLightnessExponent`'s scale.
    ///
    /// A ratio: black stays black, nothing is ever crushed through zero, and the move is
    /// monotone in `stops` and in L. A non-positive L (out-of-gamut input) is left alone.
    public static func mixerLightness(_ lightness: Double, stops: Double) -> Double {
        guard lightness > 0, stops != 0 else { return lightness }
        let omega = pow(Swift.min(lightness, mixerLumLightnessCap) / mixerLumReferenceLightness,
                        mixerLumLightnessExponent)
        return lightness * exp2(stops * omega)
    }

    /// Band i's Luminance slider in stops: slider/100 times its down or up strength.
    public static func bandLumStops(_ slider: Double, band i: Int) -> Double {
        let v = Num.clamp(slider, -100, 100) / 100
        return v * (v < 0 ? mixerLumStopsDown[i] : mixerLumStopsUp[i])
    }

    /// σ(h): the largest C/L an sRGB-primaries colour of OKLab hue `hue` can have before
    /// one of its linear channels goes negative, from the Fourier fit
    /// `mixerSatReferenceCoefficients` (smooth on purpose; see there).
    public static func mixerReferenceSaturation(hue: Double) -> Double {
        let t = hue * .pi / 180
        let a = mixerSatReferenceCoefficients
        var x = a[0]
        for k in 1...6 {
            let kt = Double(k) * t
            x += a[2 * k - 1] * cos(kt) + a[2 * k] * sin(kt)
        }
        return exp(x)
    }

    /// The chroma GAIN of a Saturation push `push` (≥ 0, the gated weighted sum in 0…1)
    /// on a colour at (L, C, h): 1 + push·(1 − r/R), r = C / (L·σ(h)), R =
    /// `mixerSatCeiling`, and 1 at or beyond the ceiling. +100 still doubles a muted
    /// sky; a colour already at the display's edge stays where it is.
    ///
    /// Monotone in `push`, and C·gain is monotone in C: dr′/dr = 1 + p(1 − 2r/R) ≥ 1 − p.
    public static func mixerSatGain(chroma: Double, lightness: Double, hue: Double,
                                    push: Double) -> Double {
        guard push > 0 else { return 1 }
        guard chroma > 0 else { return 1 + push }
        let reference = lightness * mixerReferenceSaturation(hue: hue)
        // Black (or a negative lightness) has no room in the cone at all: the limit of
        // the gain as L falls to zero is 1, so that is what it gets.
        guard reference > 1e-9 else { return 1 }
        let room = 1 - chroma / (reference * mixerSatCeiling)
        return 1 + push * Swift.max(0, room)
    }

    /// Each band's Hue move in degrees, as the recipe's sliders resolve it: slider/100 ×
    /// `bandHueShiftLimit` of the band's own arc, then the whole set scaled down
    /// together, only if needed, so that the composed warp's slope stays at least
    /// `hueMinSlope` everywhere. A single band never needs the scale; neighbours pushed
    /// toward each other can. The slope is linear in the moves, so the scale is exact:
    /// it is measured on a 0.05° grid of the warp's derivative.
    public static func resolvedHueShifts(_ bands: [MixerBand], arcs: [BandArc]) -> [Double] {
        var d = [Double](repeating: 0, count: bandCount)
        var moved = false
        for i in 0..<bandCount where i < bands.count && i < arcs.count {
            d[i] = Num.clamp(bands[i].hue, -100, 100) / 100 * bandHueShiftLimit(arcs[i])
            if d[i] != 0 { moved = true }
        }
        guard moved, d.allSatisfy({ $0.isFinite }) else { return d }
        var steepest: Double = 0           // most negative d(displacement)/d(hue)
        let step = 0.05
        var previous = hueDisplacement(0, shifts: d, arcs: arcs)
        var h = step
        while h <= 360 {
            let next = hueDisplacement(h, shifts: d, arcs: arcs)
            steepest = Swift.min(steepest, (next - previous) / step)
            previous = next
            h += step
        }
        let room = 1 - hueMinSlope - hueSlopeMargin
        if -steepest > room {
            let scale = room / -steepest
            for i in 0..<bandCount { d[i] *= scale }
        }
        return d
    }

    /// The falloff of a hue move, 0 → 1 over t ∈ 0…1, with slope 0 at both ends: a
    /// quadratic ease over `hueRampFraction` at each end and a straight line between (its
    /// slope, 1/(1 − ramp), is the least any shape with flat ends can have).
    public static func hueTransfer(_ t: Double) -> Double {
        let ramp = hueRampFraction
        let peak = 1 / (1 - ramp)
        if t <= ramp { return peak * t * t / (2 * ramp) }
        if t >= 1 - ramp { return 1 - peak * (1 - t) * (1 - t) / (2 * ramp) }
        return peak * (t - ramp / 2)
    }

    /// THE HUE MOVE: a monotone warp of the hue circle, as a displacement in degrees.
    ///
    /// Band k turns its whole core by `shifts[k]`, and beyond the core the move falls off
    /// through `hueTransfer` over `hueFalloff` — the band's own Band range ring scaled by
    /// `hueReachFactor`, so a narrowed ring narrows which hues move (SPEC R6), exactly as
    /// it narrows Saturation and Luminance. Output hue against input hue has slope
    /// 1 + Σ dₖ·Bₖ′, and `bandHueShiftLimit` with `resolvedHueShifts` keep that at least
    /// `hueMinSlope` for every recipe: the circle can be stretched and squeezed but never
    /// folded.
    ///
    /// It replaced `Σ wᵢ·shiftᵢ` over the normalised membership weights. That form put a
    /// 45° move through a 25° raised-cosine transition, and its slope went to −1.6: 14–20°
    /// of input hue on every band came out reversed (audit M1). The membership weights'
    /// transitions are as narrow as Lightroom-like band selectivity needs, which is too
    /// narrow to carry a 25–35° move, so the hue move falls off over the longer reach.
    ///
    /// A sum of per-band bases with no interval search, so the GPU twin evaluates the
    /// same expression.
    public static func hueDisplacement(_ hue: Double, shifts d: [Double],
                                       arcs: [BandArc]) -> Double {
        var out: Double = 0
        for k in 0..<bandCount where d[k] != 0 && k < arcs.count {
            let arc = arcs[k]
            let delta = Num.hueDelta(arc.centre, hue)
            let f = hueFalloff(arc)
            let core = delta >= 0 ? arc.coreAbove : arc.coreBelow
            let fall = delta >= 0 ? f.above : f.below
            let s = Num.clamp((abs(delta) - core) / fall, 0, 1)
            out += d[k] * (1 - hueTransfer(s))
        }
        return out
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
        let gate = Self.mixerGate(lch.C)
        // Uniformity's neighbourhood. Equal to `lch.h` on the flat path.
        let meanHue: Double = {
            guard uniformity > 0, localMean != c else { return lch.h }
            let m = context.toLCh(localMean)
            return m.h.isFinite ? m.h : lch.h
        }()

        // Sum all attributes across bands BEFORE applying any of them. Applying
        // band-serially would double-count in the overlap regions, which is exactly
        // where the smooth band model is supposed to be invisible.
        var pullSum: Double = 0
        var pushSum: Double = 0
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
            // pull rendered C·(1 − gate(C)), non-monotone in chroma: the palest
            // members of a band kept their tint while stronger ones went grey.
            // Ungated, C' = C·(1 + Σw·s) is monotone and −100 removes the colour at
            // every chroma. Pushes, Hue, Luminance and Uniformity stay gated.
            // `HuePreservationTests.testBandSaturationPullIsMonotoneInChromaAndRemovesTheColour`,
            // `…testABandPullOnIsotropicLowChromaNoiseLeavesOnlyAFaintCast`.
            let sat = Num.clamp(band.sat, -100, 100) / 100
            if sat < 0 { pullSum += w[i] * sat }
            let weight = w[i] * gate
            if weight == 0 { continue }
            if sat > 0 { pushSum += weight * sat }
            lumSum += weight * Self.bandLumStops(band.lum, band: i)
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
        // Uniformity first, then the hue warp evaluated AT THE CONVERGED HUE: the two
        // moves compose (slope = warp′ · uniformity′, both ≥ 0) instead of adding two
        // displacements read off the same input hue, which folded the circle when a
        // band's Hue and Uniformity were both set (WS-31 verify R7). Gated like every
        // hue-selective move: below the gate a pixel's hue is noise.
        let converged = Num.wrapHue(lch.h + converge)
        let hueMove: Double = hueIsFlat || gate == 0
            ? 0 : gate * Self.hueDisplacement(converged, shifts: hueShifts, arcs: arcs)

        // A pull scales chroma linearly; a push goes through the cone roll-off. The two
        // multiply, so chroma stays monotone in each slider and in the input chroma.
        let gC = Swift.max(0, 1 + pullSum)
            * Self.mixerSatGain(chroma: lch.C, lightness: lch.L, hue: lch.h, push: pushSum)
        // Chroma is carried through the luminance move literally unchanged — invariant
        // #1 — and the move itself is a ratio (see `mixerLightness`).
        let L = Self.mixerLightness(lch.L, stops: lumSum)
        let h = Num.wrapHue(converged + hueMove)
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
            // The wire format carries one master Range; the per-axis refine ranges are a
            // documented format gap (brief §2.1), so all three axes share it.
            let r = Num.clamp(pc.range, 0, 100) / 100
            // Sub-linear, so neither end of the slider is a degenerate case. See
            // `pointRangeBase`.
            let scale = pointRangeBase + (1 - pointRangeBase) * r
            out.append(Swatch(target: target,
                              sigmaL: Swift.max(pointSigmaL * scale, pointSigmaFloor),
                              sigmaC: Swift.max(pointSigmaC * scale, pointSigmaFloor),
                              sigmaH: Swift.max(pointSigmaH * scale, pointSigmaFloor),
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

        let tL = dL / s.sigmaL
        let tC = dC / s.sigmaC
        let tH = dH / s.sigmaH
        let d = (tL * tL + tC * tC + tH * tH).squareRoot()
        guard d.isFinite else { return c }
        // Flat plateau out to half the radius, C¹ rolloff to nothing at the edge.
        let weight = 1 - Num.smoothstep(0.5, 1.0, d)
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
            let tHk = tH / k
            hueWeight = 1 - Num.smoothstep(0.5, 1.0, (tL * tL + tC * tC + tHk * tHk).squareRoot())
        } else {
            hueWeight = weight
        }
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
            // Lightness deviation participates at half weight — which is why evening out
            // a blotchy sky does not flatten its luminance texture.
            L = Self.varianceCompress(value: L, localMean: mu.L, target: s.target.L,
                                      q: s.q, beta: 0.5, weight: weight, axis: .lightness)
        }

        h += hueWeight * gate * s.shiftH
        C = Swift.max(0, C * (1 + weight * s.shiftS / 100))
        // Same chroma-preserving lightness kernel as the Mixer: C is untouched here.
        L += weight * (s.shiftL / 100) * Self.lumKappa * Self.lumShape(L)
        return context.toRGB(OKLCh(L: L, C: C, h: Num.wrapHue(h)))
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
                // On the LEGACY equal-spaced grid: WS-31 moved the Mixer's bands, not
                // the B&W mix's (docs/quality/lanes/WS-31/NEEDS.md).
                let w = Self.uniformBandWeights(hue: lch.h)
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
