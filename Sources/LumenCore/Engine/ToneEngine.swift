// ToneEngine.swift
// The six-slider tone contract and the Zones panel as ONE engine (docs/04 §3.5,
// docs/14 §S7): every tonal control compiles to a per-pixel gain, in stops, over the
// zonal coordinate `t = log2(luminance / 0.18)`.
//
// One property is structural rather than enforced, and it changed in WS-05:
//   · Every slider here is a scalar GAIN on scene-linear RGB, except that Blacks also
//     moves the black anchor. Whites used to move the white anchor as well, and that
//     was not free: the display transform's path-to-white blend reads the anchor
//     (`shoulderU` in `DisplayTransform.apply`), so Whites ±100 re-hued saturated blues
//     it applied no gain to — 14.05° on rec709 blue at +2 EV, 2.35° mean over the
//     whole midtone hue wheel (WS-05 SPEC H6/H1). Whites now moves the white CLIP POINT
//     with gain alone — `whiteWeight` saturates below the anchor, so a tone that much
//     under white is carried onto it — and the transform stays the default one. A
//     slider that is a pure gain renders a colour exactly as Exposure would at the same
//     luminance, which is the only hue promise a tone control can make.
//
// A second one used to be, and this file said so for longer than it was true. The claim
// was that Highlights' weight window "tapers to zero at the white anchor, so Highlights
// can never push a pixel past display white — LrC's most load-bearing hidden rule,
// implemented as geometry". It is not geometry any more. The bump became a shelf for
// the reasons `highlightShelfEndEV` gives at length, and a shelf saturates:
// `smoothstep(0, 5, t)` is 1 AT the +5 EV anchor and 1 above it, so Highlights ±100
// applies its full ±2 EV to pixels already at and beyond white.
// That was the point of the rework — a bump left a blown sky exactly where it was — and
// the words simply did not follow.
//
// The invariant it claimed is still TRUE, and it is now the display transform's: the
// scene→display curve saturates at the white anchor, so nothing this engine hands it
// can render above display white. That is a different mechanism with a different
// failure mode, and it is not free — it holds because `normalizedCurve` clamps its
// argument, and would stop holding the moment the transform gained headroom above the
// anchor without a matching guard here. `testHighlightsCannotRenderPastDisplayWhite`
// asserts it end to end rather than leaving it to a sentence.
//
// The luminance driving `t` is an edge-aware guided-filter mask, not raw pixel luma
// (SpatialOps.guidedFilter) — which is why zone edits follow edges instead of haloing.
// That is the pipeline's business; this file is the pure 1-D response.

import Foundation

public struct ToneEngine: Sendable {

    public let tone: Tone
    public let zones: Zones

    /// Scene EV of the display transform's anchors. Blacks moves the black one; the white
    /// one is the base anchor at every Whites value (see the file header and
    /// `anchors(for:)`).
    public let whiteAnchorEV: Double
    public let blackAnchorEV: Double

    /// ±100 on Highlights ⇒ this many stops of peak zonal gain (docs/04 §3.4).
    public static let highlightShadowRangeEV: Double = 2.0
    /// ±100 on Blacks ⇒ this many stops of black-anchor shift. It used to move the white
    /// anchor for Whites too; Whites is now a gain (`whiteToneEV`), see the file header.
    public static let whiteBlackRangeEV: Double = 1.5

    /// How far past the white anchor the Highlights shelf reaches full strength, in EV.
    /// It SATURATES rather than returning to zero.
    ///
    /// These were raised cosines of a sine — bumps, peaking halfway to the anchor and
    /// falling back to zero AT it. Two things followed, both bad. A bump means
    /// Highlights −100 does nothing at all to the brightest values, so the one control
    /// a photographer reaches for to recover a blown sky left the sky exactly where it
    /// was and pulled the tones below it down instead. And a bump of height `h` over
    /// support `W` has a maximum slope near `4.35h/W`, which at 2 EV over 5 EV is 1.74
    /// against the identity's 1.0 — so the monotonicity limiter had to cap the amount
    /// at roughly 0.56, and the cap moved with the contrast slope and with the anchors.
    /// Measured, that made Highlights spend 79% of its travel in its first half and
    /// vary in strength by 3.6x across the Contrast range.
    ///
    /// A shelf has one transition instead of two: `smoothstep` maxes out at `1.5h/W`,
    /// which at 2 EV over 5 EV is 0.6. Monotone at full deflection with margin, so the
    /// limiter no longer binds and the slider means the same thing wherever its
    /// neighbours are.
    ///
    /// WHY AN ABSOLUTE EV AND NOT A FRACTION OF THE ANCHOR. This was `highlightShelfEnd`,
    /// 1.0 x the white anchor, which is the same 0 … +5 EV on the factory +5 EV anchor
    /// and is unchanged there. Since WS-05 no slider moves the white anchor any more (the
    /// file header), so the fraction bought nothing — and it would have cost the shelf if
    /// the default anchor moves (WS-13's request for +3 EV): 1.0 x 3 EV is a 2 EV rise
    /// over 3 EV, slope 1.0, which binds the limiter on Highlights −100 alone at
    /// Contrast 0. In EV the shelf keeps its 0.6 slope and the place where full
    /// Highlights −100 (2 EV) carries a tone back onto white (SPEC R1) on either anchor.
    public static let highlightShelfEndEV: Double = 5.0

    /// Where Shadows −100's shelf reaches full strength, as a fraction of |black anchor|.
    /// Darkening only: Shadows +100 is the bump below (`shadowLiftRangeEV`).
    ///
    /// Not 1.0, because the two ends of the range are not symmetric in what a viewer
    /// can see. The black anchor is 9 stops below mid-grey and the display transform's
    /// toe puts −9 EV at sRGB code 0.5, −7.25 at 0.6, −5.5 at 2.5. A shelf that only
    /// reaches full strength at the anchor spends itself where there is nothing to
    /// move: measured, Shadows +100 was worth 9.1 code values because at −4 EV — where
    /// a photograph's shadows actually live, code 8 — the shelf had only reached 0.42.
    /// Saturating at half the anchor puts full strength at −4.5 EV instead.
    public static let shadowShelfEnd: Double = 0.5

    /// Shadows +100: a BUMP below mid-grey, not the shelf −100 uses.
    ///
    /// Lifting with the shelf gave the full +2 EV from −4.5 EV all the way down to the
    /// black anchor, so the darkest pixels got the largest lift: on the A7 IV frame
    /// Shadows +100 raised the 1st percentile 29.4 codes against 23.6 for the quartile —
    /// a veil over the black point, not opened shadows (WS-05 AUDIT F5). Lightroom's
    /// Shadows opens the quarter tones and leaves the darkest values where Blacks puts
    /// them; Blacks owns zone 0. So the lift rises over 0 … `shadowPeak` and then TAPERS
    /// by `shadowTaperDepth` between `shadowTaperStart` and `shadowTaperEnd` toward the
    /// black anchor (fractions of |black anchor|).
    ///
    /// Darkening keeps the shelf, and the asymmetry is deliberate. Pushing the deep
    /// shadows further down is harmless — the toe already holds them near black — and
    /// the shelf only rises, so Shadows −100 is never eased and keeps its measured
    /// behaviour (and halos) exactly. The taper exists for one direction only.
    ///
    /// The lift's rising side is bounded by monotonicity, as the shelves are: it falls
    /// toward mid-grey at most 1.5 x `shadowLiftRangeEV` / peak stops per stop, which has
    /// to stay under `zonalKnee`'s 0.8 so a single Shadows move is never scaled at
    /// Contrast 0. The taper side RISES with `t`, so its steepness costs no monotonicity.
    ///
    /// The numbers, on the default anchors, and what holds each one where it is
    /// (WS-05 SPEC §1, measured with `lumen-render sweep` on eight raw frames):
    ///   · height 1.5 EV, peak at −3.5 EV: the rising side falls toward mid-grey at
    ///     1.5 x 1.5 / 3.5 = 0.64 stops per stop. That is the binding number: against
    ///     Contrast −100's 0.4 it solves to 0.615, over the 0.60 floor
    ///     `RobustnessTests` holds one tone control paired with Contrast to; a peak at
    ///     −3.0 EV (0.75) solved to 0.53. The quarter tones still open more than the
    ///     shelf did (6929 p25/p50 +20.5 codes against +17.9, 4213 +29.8 against +28.1).
    ///   · taper from −3.15 to −4.15 EV, down to 5 % of the height: the 1st percentile
    ///     of 6929 and 4213 sits near −3.9 EV and now rises 7.6 / 7.2 codes, not 29.4 /
    ///     29.2; the −6 EV ramp code stays at 2 and zone 0 moves 3.6 codes against
    ///     Blacks' 7.1. The taper's slope, 1.5 x 0.95 x 1.5 / 1.0 = 2.1 stops per stop,
    ///     EXPANDS the band it crosses rather than flattening it.
    ///   · the two pull against each other on the darkest frames, whose shadow mass is at
    ///     −3 EV, right where the taper starts: 1840's shadow pixels rise 19.6 codes,
    ///     just over the 0.6 x 31.2 the spec holds as an authority floor (S6). Moving
    ///     the taper 0.15 EV either way fails one of S1 or S6. And no setting of this
    ///     family keeps every border between a shadow and a brighter neighbour at 95 %
    ///     of its contrast (S3) while also lifting those frames that far — BUILD-NOTES.md
    ///     has the trade measured.
    public static let shadowLiftRangeEV: Double = 1.5
    public static let shadowPeak: Double = 3.5 / 9
    public static let shadowTaperStart: Double = 3.15 / 9
    public static let shadowTaperEnd: Double = 4.15 / 9
    public static let shadowTaperDepth: Double = 0.95

    /// Where the Whites +100 shelf runs, in EV BELOW the white anchor: +1.2 … +4.4 EV on
    /// the default anchor. Full strength 0.6 EV under white, so Whites +100
    /// (`whiteToneEV`) carries the tones from about +4 EV past white: on `top_steps` the
    /// +4.0 EV step clips under +100 against +5.0 at 0 — the white clip point moved one
    /// stop, inside Lightroom's 0.5 … 1.5 (SPEC W2) — and it is moved by gain, so the
    /// display transform does not change (file header).
    ///
    /// IT OVERLAPS HIGHLIGHTS, as it always has (`highlightShelfEndEV` rises over
    /// 0 … +5 EV), but it is now confined to the top. The old shelf ran +1 … +4 EV at
    /// 1.3 EV PLUS a 1.5 EV anchor move, so +100 clipped from +2.5 EV — half the
    /// headroom — and moved the ramp's zone 7 by 25.7 codes against Highlights' 16.5.
    /// Starting 3.8 EV under white keeps zone 6 still and zone 7 to about 2 codes, and
    /// still moves C0 − 2 EV (+3 EV) by 12 codes (SPEC W4/W5). The width keeps the
    /// slope at 1.5 x 1.2 / 3.2 = 0.56 stops per stop.
    /// `EngineTests.testTheEndShelvesOverlapTheZonalOnesAsTheCommentSays` holds these
    /// numbers. Whites −100 uses its own two shelves (`whiteRecoveryEV`).
    public static let whiteShelfStartBelowAnchorEV: Double = 3.8
    public static let whiteShelfEndBelowAnchorEV: Double = 0.6

    /// Blacks' shelf, as a fraction of |black anchor|: −1.35 … −5.58 EV on the default
    /// anchors. Shadows −100's shelf saturates at −4.5 EV and Blacks' steepest point is
    /// −3.47 EV, the shelf's midpoint; Shadows +100's lift tapers away from −3.15 EV,
    /// so below about −4 EV Blacks +100 is the stronger of the two (SPEC S5).
    public static let blackShelfStart: Double = 0.15
    public static let blackShelfEnd: Double = 0.62

    /// ±100 on Whites ⇒ this many stops of gain at the top of the range. It used to be
    /// 1.3 EV on top of a 1.5 EV anchor move; it is the whole move now.
    public static let whiteToneEV: Double = 1.2

    /// Whites −100 is not the mirror of +100, and the reason is Contrast's shoulder.
    ///
    /// Mirrored, −100 would fall at up to 0.56 stops per stop across +2 … +4 EV, which is
    /// where Contrast +100's shoulder is flattest (its slope bottoms out at 0.41 at
    /// +3.85 EV, 0.77 of the reach) and where Highlights −100 is still steep. The limiter
    /// has to share that 0.41 between them: measured, Highlights −100 with Whites −100
    /// under Contrast +100 solved to 0.42 — past the 0.62 floor `RobustnessTests` holds
    /// the four controls to. So −100 is two shelves that stay off that band:
    ///   · a HOLD of `whiteHoldEV` from `whiteShelfStartBelowAnchorEV` to
    ///     `whiteHoldEndBelowAnchorEV` under white (+1.2 … +3.2 EV), which pulls the upper
    ///     tones down and is flat by the time Contrast is;
    ///   · a RECOVERY of `whiteRecoveryEV` from `whiteRecoveryStartBelowAnchorEV` under
    ///     the anchor to `whiteRecoveryEndAboveAnchorEV` over it (+3.8 … +6.6 EV), most of
    ///     it where Contrast is the identity again, which carries tones up to 1.9 EV over
    ///     white back under it — the clip point moved the other way, as the old anchor
    ///     move did, without moving the anchor.
    /// They fall at most 0.68 and 0.54 stops per stop, so a single Whites −100 is still
    /// never scaled at Contrast 0, and the four-way corner solves to 0.687.
    public static let whiteHoldEV: Double = 0.9
    public static let whiteHoldEndBelowAnchorEV: Double = 1.8
    public static let whiteRecoveryEV: Double = 1.0
    public static let whiteRecoveryStartBelowAnchorEV: Double = 1.2
    public static let whiteRecoveryEndAboveAnchorEV: Double = 1.6
    /// Blacks needs more stops than Whites for the same visible authority, because the
    /// toe compresses far harder than the shoulder: one stop at +4 EV is worth about 12
    /// code values, one stop at −5 EV about 4.
    public static let blackToneEV: Double = 2.2

    /// Default anchors with all sliders at zero: 5 stops of highlight headroom above
    /// mid-grey and 9 stops of shadow range below it — the working latitude of a
    /// modern full-frame sensor.
    public static let defaultWhiteAnchorEV: Double = 5.0
    public static let defaultBlackAnchorEV: Double = -9.0

    /// What the Highlights slider actually applies, normalized to −1…1.
    ///
    /// Equal to `highlights / 100` until the monotonicity limit binds, then approaching
    /// that limit smoothly. Exposed so the panel can show the applied value the way it
    /// shows a resolved denoise default — a slider whose top half does nothing is bad,
    /// and a slider whose top half does nothing *silently* is worse.
    public let effectiveHighlights: Double
    /// The same for Shadows. Solved separately, because the two windows are disjoint.
    public let effectiveShadows: Double
    /// And for Whites and Blacks, which carry a tonal shelf of their own and are eased
    /// by the same solve.
    ///
    /// These were not exposed and were not solved for separately — `zonalStops` read
    /// `tone.whites * zonalScale` inline. Two sliders being eased by an amount the type
    /// would not report is the same silence `effectiveHighlights` exists to break, and
    /// it hid the coupling: the number that scaled them was solved against windows they
    /// do not touch.
    public let effectiveWhites: Double
    public let effectiveBlacks: Double

    /// Where Whites and Blacks put the live anchors, without building the engine.
    ///
    /// The initialiser below reads its anchors from here, so this is not a second copy
    /// of the arithmetic but the only one. It exists because the anchors are also the
    /// grading wheels' zone axis (`RenderPlan` hands them to `GradeEngine`), and the
    /// Colour Grading strip has to draw on that axis on every redraw: a whole engine
    /// solves the zonal limits, which is a sweep the strip has no use for. The strip
    /// used to dodge the cost by assuming the factory −9 … +5 EV — a fixed 14 EV span —
    /// so with Whites at +100 it drew the crossfades 10.7 % narrower than the ones being
    /// rendered and dropped a Balance-shifted handle 0.21 EV from where it was released
    /// (B2-05). `GradeStripAxisTests` pins the agreement.
    ///
    /// The white anchor is the base one at every Whites value. Whites moved it by
    /// 1.5 EV per 100 until WS-05, and the display transform's path-to-white blend is
    /// normalised by it, so the move re-hued colours Whites applied no gain to (file
    /// header). The white clip point still moves — by gain, in `whiteWeight`.
    public static func anchors(for tone: Tone,
                               baseWhiteAnchorEV: Double = ToneEngine.defaultWhiteAnchorEV,
                               baseBlackAnchorEV: Double = ToneEngine.defaultBlackAnchorEV)
        -> (white: Double, black: Double) {
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        return (white: baseWhiteAnchorEV,
                black: baseBlackAnchorEV - Self.whiteBlackRangeEV * blacks)
    }

    /// `baseWhiteAnchorEV` / `baseBlackAnchorEV` are where Whites and Blacks at zero put
    /// the anchors. The global engine leaves them at the factory 5 / −9 EV. A MASK's
    /// engine passes the global plan's live anchors, because its sub-recipe is a delta
    /// evaluated against the picture the global stage already formed (docs/08 §8.4),
    /// and the display transform downstream clips at the GLOBAL anchors. Built from the
    /// factory ones, a masked Contrast +100 under global Whites +100 held its fixed
    /// point at 5 EV while display white sat at 3.5, carried 3.5 EV to 4.16 and clipped
    /// every tone from 2.47 EV up inside the mask — the local grade had already adopted
    /// the global anchors for the same reason (COLOR-16).
    /// `MaskingTests.testAMaskedContrastPinsTheGlobalDisplayAnchorsNotTheFactoryOnes`.
    public init(tone: Tone = Tone(), zones: Zones = Zones(),
                baseWhiteAnchorEV: Double = ToneEngine.defaultWhiteAnchorEV,
                baseBlackAnchorEV: Double = ToneEngine.defaultBlackAnchorEV) {
        self.tone = tone
        self.zones = zones
        let highlights = Num.clamp(tone.highlights, -100, 100) / 100
        let shadows = Num.clamp(tone.shadows, -100, 100) / 100
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        let anchors = Self.anchors(for: tone, baseWhiteAnchorEV: baseWhiteAnchorEV,
                                   baseBlackAnchorEV: baseBlackAnchorEV)
        let hi = anchors.white
        let lo = anchors.black
        self.whiteAnchorEV = hi
        self.blackAnchorEV = lo
        // A scale over the zonal contribution, found in closed form, rather than a cap
        // per window.
        //
        // Per-window caps were never a guarantee about the total — each solved against
        // the contrast slope and ignored the other three windows — and they coupled
        // what they did constrain: Highlights' applied amount moved from 0.218 to 0.857
        // across the Contrast range, a 3.9x swing in what one slider meant depending on
        // where a different one sat.
        //
        // A clamp on the baked curve alone removes the coupling but pays for it in flat
        // patches, and the measurement is decisive: two sliders at full opposing
        // deflection — Highlights −100 with Shadows +100, an ordinary "flatten it" move
        // — left 160 of 1024 samples flat, which is 16% of the tonal axis rendering as
        // one value. `CurveStack.bakeParametric` reached the same conclusion for the
        // parametric curve first, and its comment says why: a global scale keeps the
        // curve's SHAPE instead of flattening it in patches.
        //
        // For one round this was ONE scale over the whole zonal sum, and one scale is
        // exactly as wrong as a per-window cap, in the other direction. It multiplied
        // Highlights, Shadows, Whites and Blacks together, so a window that could not
        // reach a tone still had its say about what that tone rendered as. Measured at
        // `Tone(contrast: -100, shadows: -100, whites: -100, blacks: -100)`, dragging
        // Highlights from −100 to +40 lightened a shadow at −2 EV by 24.4 sRGB code
        // values — a tone where `highlightWeight` is EXACTLY zero, so Highlights was
        // moving a pixel it does not touch — and the last 60 points of its travel were
        // byte-identical there. `solveZonalLimits` says what replaced it.
        //
        // What this file used to claim at this point, and what is actually true. The
        // claim was "a single slider at full deflection is monotone on its own — the
        // shelves are shaped so it is — so it is never scaled, and the coupling that
        // remains is between settings that cannot both be honoured". The first half is
        // FALSE whenever Contrast is negative, and has been since the shelves landed.
        // `Tone(contrast: -100, blacks: 100)` is ONE slider and solves to 0.592;
        // `Tone(contrast: -100, highlights: -100)` to 0.656, `shadows: 100` to 0.594.
        // `RobustnessTests` names the first of those in its own list of cases expected
        // to bind, three screens above, so the sentence and the suite contradicted each
        // other across one file pair. The arithmetic is not subtle: a shelf's steepest
        // point is `1.5 x range / width`, which for Blacks is 1.5 x 2.2 / 4.94 = 0.669
        // stops per stop, and `mapped` only rises while the contrast slope exceeds it.
        // Against the identity's 1.0 it does, with margin — which is the margin the
        // shelves were shaped for. Against Contrast −100's 0.4 it does not, and the
        // limiter is right to bind. What is true is the narrower claim the shelves
        // actually bought: a single slider is never scaled AT CONTRAST 0.
        //
        // The SECOND half is true and is now true for a stated reason rather than by
        // luck: what remains is a shared scale between two windows in the SAME half
        // that both run downhill, which is exactly a pair of requests that cannot both
        // be honoured. Nothing crosses mid-grey and nothing that helps is scaled.
        //
        // That residue is real and it is measurable rather than hand-waved: at
        // `Tone(contrast: -100, contrastPivot: 3, whites: -100, ...)`, five points of
        // Highlights still move Whites' applied amount by 0.037, because both are
        // pulling the top of the range down harder than a slope of 0.4 will carry. It
        // never renders as a wrong-way step — over a 972-setting sweep of the other
        // five controls, no Highlights step darkens any tone anywhere, above mid-grey
        // or below — and no design that keeps both requests can do better than share.
        let limits = Self.solveZonalLimits(tone: tone, whiteAnchorEV: hi,
                                           blackAnchorEV: lo)
        let upper = Self.easedScale(limit: limits.upper)
        let lower = Self.easedScale(limit: limits.lower)
        // Only a window that runs DOWNHILL is eased, and only by its own half's scale.
        self.effectiveHighlights = highlights * (highlights < 0 ? upper : 1)
        self.effectiveWhites = whites * (whites < 0 ? upper : 1)
        self.effectiveShadows = shadows * (shadows > 0 ? lower : 1)
        self.effectiveBlacks = blacks * (blacks > 0 ? lower : 1)
        var eased = 1.0
        if highlights < 0 || whites < 0 { eased = Swift.min(eased, upper) }
        if shadows > 0 || blacks > 0 { eased = Swift.min(eased, lower) }
        self.zonalScale = eased
    }

    /// The smallest scale any window is actually being held to — 1.0 when every slider
    /// is applied exactly.
    ///
    /// A SUMMARY, not the mechanism: there are two scales, one per half of the range,
    /// and a window that does not run downhill is not scaled at all. `effectiveHighlights`
    /// and its three siblings are the per-window truth; this is the one number a panel
    /// needs to answer "is anything being held back at all".
    ///
    /// Exposed for the same reason `effectiveHighlights` is: a slider that has quietly
    /// stopped meaning what it says should be able to show it.
    public let zonalScale: Double

    /// Fraction of the limit below which the request is applied exactly.
    static let zonalKnee: Double = 0.8

    /// Sweep step for the monotonicity solve, in stops. The windows are smoothsteps
    /// spanning whole stops, so nothing narrower can hide inside one; `bakeGainLUT`'s
    /// forward clamp is the backstop for anything that does.
    static let monotoneStepEV: Double = 0.05

    /// What the solved limit gives back for the sweep being a set of secants.
    ///
    /// The ratio is exact for the 0.05 EV intervals it measures, but a window's slope
    /// peaks INSIDE an interval, where the secant under-reads it by a second-order
    /// amount. The shelves never showed it; the Shadows lift (WS-05), whose rising side
    /// is the binding window against Contrast −100, did: `Tone(contrast: −100,
    /// shadows: 100, blacks: −100)` left one 1024-sample bake step at −1.09 EV
    /// 8.7e-6 EV below its neighbour, and the forward clamp flattened it
    /// (`ZoneFlatteningTests`). 0.1 % of the limit is four times what that needs, and
    /// a thousand times less than the 2 % `RobustnessTests` holds the limiter to.
    static let secantMargin: Double = 1e-3

    /// Above this the request is treated as having room to spare and left alone. It has
    /// to sit above `1 / zonalKnee`, or a setting that is comfortably safe would still
    /// be eased.
    static let searchCeiling: Double = 4

    /// A limit, eased so the top of every slider still moves.
    ///
    /// A hard limit is a dead control. The limit is inversely proportional to the
    /// requested magnitude — push a conflicting pair harder and it shrinks by exactly
    /// the factor you pushed — so `scale x request` is CONSTANT the moment a hard cap
    /// binds, and the rest of the travel does nothing at all. That is what
    /// `Num.softKnee` is for, and it takes the reciprocal form here for the same reason
    /// the grading wheels do: `1 / limit` is the request measured in units of the
    /// largest safe one, so `limit x softKnee(1/limit)` is exact while the request is
    /// under `zonalKnee x limit` and approaches the limit without reaching it after.
    static func easedScale(limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return Swift.min(1, limit * Num.softKnee(1 / limit, knee: Self.zonalKnee))
    }

    /// TWO limits — one for the windows above mid-grey, one for the windows below —
    /// before the knee. Split out so a test can assert the thing that matters about
    /// them: that the response still rises AT a limit and stops rising just above it,
    /// which is the only way to tell a correct limiter from a timid one.
    ///
    /// Three facts about the four windows make this exact rather than a policy choice,
    /// and all three are asserted by tests rather than left to this comment.
    ///
    /// · **The two halves have EXACTLY disjoint support.** `highlightWeight` and
    ///   `whiteWeight` are `smoothstep`s whose lower edge is at or above mid-grey, so
    ///   both return a hard zero for every `t <= 0`; `shadowWeight` and `blackWeight`
    ///   are the mirror image and return a hard zero for every `t >= 0`. Not "nearly
    ///   zero" — `Num.smoothstep` saturates its argument, so the value is 0.0 exactly.
    ///   A response that is monotone on each side of mid-grey and continuous at it is
    ///   monotone, so the two halves can be solved independently with no lost margin,
    ///   and Highlights cannot reach a shadow through the scale any more than it can
    ///   through its own weight.
    ///
    /// · **A window that can fall is decided by its slider's sign.** A shelf times a
    ///   scalar is monotone, so Highlights below zero falls across its whole support and
    ///   never rises; Whites below zero the same; Blacks ABOVE zero falls, because its
    ///   shelf ascends toward the black anchor. Shadows below zero is a shelf that only
    ///   rises; ABOVE zero it is a bump (`shadowLiftRangeEV`) whose slope has both signs —
    ///   it rises out of the deep shadows and falls toward mid-grey — so it sits in the
    ///   eased set. That is still exact: on an interval where an eased window rises,
    ///   `Δfalling ≥ 0` and the interval constrains nothing; where it falls, the ratio
    ///   below is the bound. So "which windows can pull the mapping downhill" is decided
    ///   by four signs before the sweep starts, and is the same at every `t`.
    ///
    /// · **A window that cannot fall cannot cause an inversion**, so it is never scaled
    ///   and its full contribution is available as slack to the ones that can. That is
    ///   what removes the second coupling: with Whites held at its requested amount,
    ///   `scale x request` for Highlights stops being a ratio of two things that both
    ///   shrink, and the applied amount rises over the whole slider again instead of
    ///   peaking at −90 and falling back.
    ///
    /// The LIMIT is closed-form, not searched. Writing the mapping as
    /// `mapped(t) = contrastMapped(t) + rising(t) + scale x falling(t)` makes it LINEAR
    /// in `scale`, so "mapped never falls" is one inequality per sample interval —
    /// `Δcontrast + Δrising + scale x Δfalling ≥ 0` — and only the intervals where
    /// `Δfalling` is negative constrain anything. The smallest ratio over those is the
    /// limit exactly. This started as a bisection over the same monotonicity predicate;
    /// it agreed to six figures and cost 23 sweeps and 23 throwaway engines per slider
    /// move, which on the interactive path is 10 ms of a 33 ms frame spent rediscovering
    /// a number one pass already knows. Two half-sweeps cover the same stops as the one
    /// sweep they replaced, so this costs what the single scale cost.
    static func solveZonalLimits(tone: Tone, whiteAnchorEV: Double,
                                 blackAnchorEV: Double) -> (upper: Double, lower: Double) {
        let highlights = Num.clamp(tone.highlights, -100, 100) / 100
        let shadows = Num.clamp(tone.shadows, -100, 100) / 100
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        let upperFalls = highlights < 0 || whites < 0
        let lowerFalls = shadows > 0 || blacks > 0
        guard upperFalls || lowerFalls else {
            return (Self.searchCeiling, Self.searchCeiling)
        }

        // The zonal sum at scale 1. Built through the private init so this measures the
        // same code the renderer runs, rather than a second copy of the same arithmetic
        // that can drift away from it.
        let unit = ToneEngine(tone: tone, zones: Zones(),
                              whiteAnchorEV: whiteAnchorEV, blackAnchorEV: blackAnchorEV,
                              effectiveHighlights: highlights, effectiveShadows: shadows,
                              effectiveWhites: whites, effectiveBlacks: blacks,
                              zonalScale: 1)
        // Two stops past each anchor: the shelves have saturated out there, but an
        // inversion sitting on the last half stop of the range is still an inversion.
        // Mid-grey is the shared end of both sweeps because it is where all four
        // windows are exactly zero, so no interval ever straddles the two halves.
        return (upperFalls ? unit.zonalLimit(from: 0, to: whiteAnchorEV + 2, upper: true)
                           : Self.searchCeiling,
                lowerFalls ? unit.zonalLimit(from: blackAnchorEV - 2, to: 0, upper: false)
                           : Self.searchCeiling)
    }

    /// One half's limit. Called on the unit engine, which holds the REQUESTED amounts,
    /// so `falling` and `rising` here are the contributions at scale 1.
    func zonalLimit(from start: Double, to end: Double, upper: Bool) -> Double {
        let step = Self.monotoneStepEV
        var t = start
        var parts = zonalParts(t, upper: upper)
        var fixed = contrastMapped(t)
        var limit = Self.searchCeiling
        while t < end {
            t = Swift.min(t + step, end)
            let next = zonalParts(t, upper: upper)
            let nextFixed = contrastMapped(t)
            let dFalling = next.falling - parts.falling
            // Only a falling window can pull the mapping downhill. The contrast term in
            // `slack` is the contrast slope over one step, positive for every legal
            // contrast, and the rising term is non-negative by construction — so the
            // ratio is always a real bound, never a sign trap.
            if dFalling < 0 {
                let slack = (nextFixed - fixed) + (next.rising - parts.rising)
                limit = Swift.min(limit, Swift.max(slack / -dFalling, 0))
            }
            parts = next
            fixed = nextFixed
        }
        return limit < Self.searchCeiling ? limit * (1 - Self.secantMargin) : limit
    }

    /// One half's zonal contribution, split by whether the window runs downhill.
    struct ZonalParts {
        var falling: Double = 0
        var rising: Double = 0
    }

    /// The two windows of one half, sorted into the pair above. Which side a window
    /// lands on is decided by the sign of its own applied amount and by which way its
    /// shelf ascends, never by the value of `t` — see `solveZonalLimits`.
    func zonalParts(_ t: Double, upper: Bool) -> ZonalParts {
        var parts = ZonalParts()
        if upper {
            let h = effectiveHighlights * Self.highlightShadowRangeEV * highlightWeight(t)
            if effectiveHighlights < 0 { parts.falling += h } else { parts.rising += h }
            let w = effectiveWhites * whiteStops(t, lifting: effectiveWhites > 0)
            if effectiveWhites < 0 { parts.falling += w } else { parts.rising += w }
        } else {
            // Above zero a bump, eased as a whole (see `solveZonalLimits`); below zero a
            // shelf that only rises.
            let s = effectiveShadows * shadowStops(t, lifting: effectiveShadows > 0)
            if effectiveShadows > 0 { parts.falling += s } else { parts.rising += s }
            let b = effectiveBlacks * Self.blackToneEV * blackWeight(t)
            if effectiveBlacks > 0 { parts.falling += b } else { parts.rising += b }
        }
        return parts
    }

    /// A probe at scales it did not solve for itself. Internal, and only a test has any
    /// business calling it: the point of the limiter is that the scales are derived from
    /// the settings, so an engine holding unrelated ones renders a picture nothing asked
    /// for. The scales reach the same windows the solve would ease and no others.
    init(tone: Tone, forcingUpperScale upper: Double, forcingLowerScale lower: Double) {
        let highlights = Num.clamp(tone.highlights, -100, 100) / 100
        let shadows = Num.clamp(tone.shadows, -100, 100) / 100
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        let anchors = Self.anchors(for: tone)
        self.init(tone: tone, zones: Zones(),
                  whiteAnchorEV: anchors.white,
                  blackAnchorEV: anchors.black,
                  effectiveHighlights: highlights * (highlights < 0 ? upper : 1),
                  effectiveShadows: shadows * (shadows > 0 ? lower : 1),
                  effectiveWhites: whites * (whites < 0 ? upper : 1),
                  effectiveBlacks: blacks * (blacks > 0 ? lower : 1),
                  zonalScale: Swift.min(upper, lower))
    }

    /// The probe the solver measures on. Private because a `ToneEngine` whose scales
    /// were not solved for its own settings is a half-built object — it exists to be
    /// measured, never to render.
    ///
    /// It takes the anchors already resolved rather than re-deriving them from the
    /// factory ones: a mask's engine sits on the global anchors, and a probe measured
    /// on different windows than the engine it solves for would solve the wrong curve.
    private init(tone: Tone, zones: Zones,
                 whiteAnchorEV: Double, blackAnchorEV: Double,
                 effectiveHighlights: Double, effectiveShadows: Double,
                 effectiveWhites: Double, effectiveBlacks: Double,
                 zonalScale: Double) {
        self.tone = tone
        self.zones = zones
        self.whiteAnchorEV = whiteAnchorEV
        self.blackAnchorEV = blackAnchorEV
        self.effectiveHighlights = effectiveHighlights
        self.effectiveShadows = effectiveShadows
        self.effectiveWhites = effectiveWhites
        self.effectiveBlacks = effectiveBlacks
        self.zonalScale = zonalScale
    }

    /// The four zonal windows, at the amounts actually applied.
    func zonalStops(_ t: Double) -> Double {
        var s = 0.0
        if effectiveHighlights != 0 {
            s += effectiveHighlights * Self.highlightShadowRangeEV * highlightWeight(t)
        }
        if effectiveShadows != 0 {
            s += effectiveShadows * shadowStops(t, lifting: effectiveShadows > 0)
        }
        if effectiveWhites != 0 {
            s += effectiveWhites * whiteStops(t, lifting: effectiveWhites > 0)
        }
        if effectiveBlacks != 0 {
            s += effectiveBlacks * Self.blackToneEV * blackWeight(t)
        }
        return s
    }

    /// Scene-linear multiplier from the Exposure slider. Applied at S6, upstream of
    /// everything here, which is why it never invalidates the decode cache.
    public var exposureGain: Double { pow(2, Num.clamp(tone.exposure, -10, 10)) }

    // MARK: - Zonal windows

    /// Highlights window: a SHELF that rises from zero at mid-grey, reaches full
    /// strength at `highlightShelfEndEV` (+5 EV) and stays there above it.
    ///
    /// It was a raised-cosine bump returning to zero at the anchor, and this comment
    /// went on saying so after the shelf replaced it. Full strength above the anchor is
    /// the behaviour: a blown sky is the one thing Highlights exists to pull down, and a
    /// window that shuts at white is a window that cannot reach it.
    public func highlightWeight(_ t: Double) -> Double {
        let hi = whiteAnchorEV
        guard hi > 0 else { return 0 }
        return Num.smoothstep(0, Self.highlightShelfEndEV, t)
    }

    /// Whites +100's window: a shelf at the top of the range that carries the tones just
    /// under white onto it — the white clip point, moved by gain. See
    /// `whiteShelfStartBelowAnchorEV` for where it sits and why; −100 uses
    /// `whiteRecoveryStops`.
    ///
    /// Whites used to move the white ANCHOR, first alone and then with a shelf on top.
    /// Alone it was a slider a photographer would call dead (26.7 codes up and 12.3 down
    /// on a −9 … +5 EV ramp), and with the shelf it was both too strong (clipping from
    /// +2.5 EV of a +5 EV anchor) and a hue control nobody asked for (file header).
    public func whiteWeight(_ t: Double) -> Double {
        let hi = whiteAnchorEV
        return Num.smoothstep(hi - Self.whiteShelfStartBelowAnchorEV,
                              hi - Self.whiteShelfEndBelowAnchorEV, t)
    }

    /// Whites −100's window, in stops at full deflection: a small shelf under white
    /// and the recovery shelf over it — see `whiteRecoveryEV` for why it is two.
    public func whiteRecoveryStops(_ t: Double) -> Double {
        let hi = whiteAnchorEV
        return Self.whiteHoldEV * Num.smoothstep(hi - Self.whiteShelfStartBelowAnchorEV,
                                                 hi - Self.whiteHoldEndBelowAnchorEV, t)
            + Self.whiteRecoveryEV * Num.smoothstep(hi - Self.whiteRecoveryStartBelowAnchorEV,
                                                    hi + Self.whiteRecoveryEndAboveAnchorEV, t)
    }

    /// Stops per unit of applied Whites: the clip-point shelf when pushing, the hold and
    /// recovery shelves when pulling.
    func whiteStops(_ t: Double, lifting: Bool) -> Double {
        lifting ? Self.whiteToneEV * whiteWeight(t) : whiteRecoveryStops(t)
    }

    /// Shadows −100's window: the mirror image of Highlights' shelf below mid-grey, full
    /// from `shadowShelfEnd` of the way to the black anchor down. Shadows +100 lifts with
    /// `shadowLiftWeight` instead; `shadowStops` picks.
    public func shadowWeight(_ t: Double) -> Double {
        let lo = blackAnchorEV
        guard lo < 0 else { return 0 }
        // Mirrored into ASCENDING form. `Num.smoothstep` degenerates to a step when
        // `e1 <= e0` (`ColorMath.swift:226`), so writing the shadow shelf as
        // `smoothstep(0, lo, t)` with a negative anchor returned 0 below mid-grey and 1
        // above it — the exact inverse of a shadow window, which made Shadows +100
        // behave as a global two-stop lift. Negating both the bounds and the argument
        // keeps the range ascending and the shelf where its name says it is.
        return Num.smoothstep(0, -lo * Self.shadowShelfEnd, -t)
    }

    /// Shadows +100's window: a bump that peaks in the quarter tones and tapers toward
    /// the black anchor — see `shadowLiftRangeEV`. Its peak is 1 and it does not return
    /// to zero: `shadowTaperDepth` leaves a fraction of the lift in the deepest shadows,
    /// so they still separate a little, but the black point stays Blacks'.
    public func shadowLiftWeight(_ t: Double) -> Double {
        let lo = blackAnchorEV
        guard lo < 0 else { return 0 }
        let depth = -lo
        let rise = Num.smoothstep(0, depth * Self.shadowPeak, -t)
        let taper = Num.smoothstep(depth * Self.shadowTaperStart,
                                   depth * Self.shadowTaperEnd, -t)
        return rise * (1 - Self.shadowTaperDepth * taper)
    }

    /// Stops per unit of applied Shadows: the bump when lifting, the shelf when not.
    func shadowStops(_ t: Double, lifting: Bool) -> Double {
        lifting ? Self.shadowLiftRangeEV * shadowLiftWeight(t)
                : Self.highlightShadowRangeEV * shadowWeight(t)
    }

    /// Blacks: the mirror of Whites, a shelf in the bottom of the range.
    public func blackWeight(_ t: Double) -> Double {
        let lo = blackAnchorEV
        guard lo < 0 else { return 0 }
        return Num.smoothstep(-lo * Self.blackShelfStart, -lo * Self.blackShelfEnd, -t)
    }

    /// No room between the pivot and an anchor means that side of the picture is
    /// already past the end of the scale, and contrast leaves it alone rather than
    /// dividing by a reach of zero. Reachable in the shipped ranges: the pivot clamps
    /// to ±4 and the white anchor is a base the caller may set below it.
    public static let minContrastReachEV: Double = 1e-6

    /// How far toward the anchor the full slope holds before the shoulder starts, as a
    /// fraction of the reach. This is the number that decides whether Contrast still
    /// FEELS like contrast, so it is set from measurements and not from taste.
    ///
    /// WHY IT IS NOT ZERO. The first version of the A1-01 fix started the shoulder at
    /// the pivot (`smoothstep(0, 1, u)`). That pins the anchor correctly, but it dilutes
    /// the slope everywhere — including the midtones, where the subject of a photograph
    /// lives — and the proof priced it: `tone.contrast` authority 81.42 → 54.83, mean
    /// separation 45.25 → 24.63. 54.83 is BELOW this control's own declared
    /// `authorityFloor` of 55. The registry rejected the fix, which is what a floor is
    /// for: a control may not be quietly weakened to make a different bug go away.
    ///
    /// So the slope holds undiluted across the inner fraction of the reach and eases
    /// only over the outer part — the straight section, shoulder and toe a film curve
    /// has always had. At 0.2 the straight section runs to +1.0 EV of a default +5 EV
    /// white anchor and to −1.8 EV of a −9 EV black one.
    ///
    /// WHY IT IS NOT MORE, and this is the real cost, stated in full because the first
    /// version of this comment understated a regression and that is how it got shipped.
    /// A steeper middle with the ends nailed down means a flatter shoulder, and a
    /// flatter shoulder is slope the four zonal windows can no longer borrow, so
    /// `solveZonalLimits` scales Highlights, Shadows, Whites and Blacks down further:
    ///
    ///     hold   authority   Highlights −100    Shadows +100    four-way
    ///                        at contrast +100   at contrast −100  corner
    ///     0.00      54.83         0.9894            0.8439        0.7565
    ///     0.15      64.88         0.9067            0.6833        0.6841
    ///     0.20      68.38         0.8460            0.6192        0.6468
    ///     0.30      74.96         0.6347            0.5937        0.5272
    ///
    /// The paired case falls through 0.60 at a hold of about 0.225, so 0.2 is the last
    /// setting where a single tone control pushed to its end against contrast pushed to
    /// its end still applies more than 60% of what it asks. Inside the daily-use band
    /// (five sliders within ±60, the end points within ±40) the limiter takes 0.6% at
    /// its worst — which is to say, nothing. The generator asserts all three numbers.
    ///
    /// That the limiter binds at all is not slack being given away. It solves for the
    /// LARGEST scale that keeps the composed tone map monotone and `RobustnessTests`
    /// checks the response stops rising 2% above the solved limit, so a bigger number
    /// there would be an inverting picture, not a stronger slider.
    ///
    /// Monotonicity is what bounds the hold from above. With
    /// `f(d) = d·mix(slope, 1, S(u))` and `S = smoothstep(hold, 1, u)`, the derivative
    /// in u is `slope + (1−slope)·[S + u·S′]`, and the bracket's maximum grows with the
    /// hold: 1.687 at 0.0, 1.983 at 0.2, 2.519 at 0.4. At contrast +100 (slope 1.6) the
    /// derivative is `1.6 − 0.6·max`, so it reaches zero just past a hold of 0.44 and a
    /// hold of 0.5 INVERTS the picture. At 0.2 the minimum derivative is 0.41, which is
    /// the same order as the 0.4 contrast −100 has always had at the pivot.
    /// `testContrastIsMonotoneAcrossTheWholeScaleAtEverySetting` measures it rather than
    /// trusting this paragraph.
    public static let contrastShoulderStart: Double = 0.2

    /// Contrast: slope around an explicit pivot in log-exposure space, relaxing back to
    /// 1 as it approaches the anchor so the ends of the scale are FIXED POINTS.
    ///
    /// A1-01, and the fix is a change of denomination. The relax window used to be two
    /// constants — 4 stops to 12 stops from the pivot — while the thing that decides
    /// where a highlight actually clips is the DISPLAY ANCHOR, +5 EV by default and as
    /// low as +3.5 under Whites +100. Those two numbers had nothing to do with each
    /// other, so at contrast +100 the white anchor mapped to +7.87 EV and everything
    /// from +3.125 EV upward landed at or beyond white: measured on the proof ramp, 34
    /// of 256 columns rendered at exactly 255.0 against 0 of 256 at contrast 0, and 40
    /// tied at the darkest value. 1.875 stops of highlight and 3.037 stops of shadow,
    /// flattened to one value each.
    ///
    /// Three things in the tree said that could not happen: this control's own tooltip
    /// ("the ends of the scale stay pinned, so it cannot clip a highlight"), docs/04,
    /// and a green test. The test probed ±`LumenLog.maxEV` — ±12 EV, the extreme of the
    /// log scale, four stops past the anchor and seven past where a photograph lives —
    /// where the old window had relaxed to 1 by construction. It asserted a true thing
    /// about a place nothing renders.
    ///
    /// So the reach is the distance to the anchor on the side being mapped, and the
    /// slope relaxes to exactly 1 there. `d * 1 == d` makes the anchor map to itself, so
    /// the promise is now geometry rather than a wide-enough window: contrast cannot
    /// move a pixel across the end of the scale because the end of the scale is a fixed
    /// point of the mapping.
    ///
    /// AND IT STILL HAS TO FEEL LIKE CONTRAST. Relaxing from the pivot outward pins the
    /// anchor but dilutes the midtones, and the proof said so: authority 81.42 → 54.83
    /// against a declared floor of 55. So the slope holds undiluted across the inner
    /// `contrastShoulderStart` of the reach and eases only over the outer part — the
    /// straight section, shoulder and toe a film curve has always had. See that
    /// constant for why the hold is 0.2 and not more.
    ///
    /// STILL MONOTONE, which is what the old window was wide for. With
    /// `f(d) = d·mix(slope, 1, s(u))` and `u = d/reach`, the derivative in u is
    /// `slope + (1−slope)·[s(u) + u·s'(u)]`, whose bracket peaks at 1.9825 at the
    /// shipped hold of 0.2. At contrast +100 (slope 1.6) the minimum derivative is
    /// 1.6 − 0.6·1.9825 = 0.4105, reached at |d|/reach = 0.770 — on the default anchors,
    /// +3.85 EV. At contrast −100 (slope 0.4) the derivative is smallest at the pivot at
    /// 0.4. Positive across the whole range, so the inversion the old comment feared
    /// ("a brighter input darker, an inversion, never a look") cannot occur here either.
    /// `EngineTests.testContrastIsMonotoneAcrossTheWholeScaleAtEverySetting` measures it
    /// rather than trusting this paragraph — there is no `ToneMonotoneTests`, which is
    /// what this line named until the atlas run went looking for it.
    ///
    /// BOTH NUMBERS IN THIS PARAGRAPH USED TO BE THE ONES FOR A HOLD OF 0.3 — bracket
    /// 2.2069, minimum derivative 0.276 — left behind when the hold was settled at 0.2
    /// and the trade table above was written. Two independent measurements agree on
    /// 0.410481 at +3.8508 EV (140,001 central differences at h = 1e-6 over the default
    /// [−9, +5] EV), which back-solves the bracket to 1.982532 and matches the constant's
    /// own paragraph. A comment that explains a control is part of the control, and this
    /// one was explaining a curve the engine does not run.
    ///
    /// Above the anchor `u` saturates and the mapping is the identity, which is correct
    /// and is the same answer the old window gave: a pixel already past the end of the
    /// scale is not somewhere contrast should be pushing further.
    public func contrastMapped(_ t: Double) -> Double {
        let c = Num.clamp(tone.contrast, -100, 100)
        guard c != 0 else { return t }
        // Inside the LIVE anchors as well as ±4: Whites ≥ +67 pulls the white anchor
        // below 4, and a pivot above it gave the tones between them the black side's
        // long reach — Contrast −100 at pivot 4, Whites +100 mapped the anchor 3.5 to
        // 3.8 and pushed visible tones past white. Clamped, that side's reach is 0
        // and both anchors stay fixed points.
        let pivot = Num.clamp(tone.contrastPivot, Swift.max(-4, blackAnchorEV),
                              Swift.min(4, whiteAnchorEV))
        let slope = 1 + 0.6 * (c / 100)
        let d = t - pivot
        // The LIVE anchors, not the defaults: Whites and Blacks move them, and a reach
        // measured against a default anchor would put the fixed point somewhere the
        // display transform no longer clips.
        let reach = d >= 0 ? whiteAnchorEV - pivot : pivot - blackAnchorEV
        guard reach > Self.minContrastReachEV else { return t }
        let shoulder = Num.smoothstep(Self.contrastShoulderStart, 1, abs(d) / reach)
        let effective = Num.mix(slope, 1, shoulder)
        return pivot + d * effective
    }

    /// Position on the normalized tonal axis the Zones panel and the grading wheels
    /// share. One axis, so a zone means the same thing in every panel.
    public func normalizedAxis(_ t: Double) -> Double {
        let span = whiteAnchorEV - blackAnchorEV
        guard span > 0 else { return 0.5 }
        return Num.saturate((t - blackAnchorEV) / span)
    }

    /// Per-zone exposure from the Zones panel, in stops.
    public func zonePanelStops(_ t: Double) -> Double {
        let ev = [zones.dark.ev, zones.shadow.ev, zones.mid.ev, zones.light.ev, zones.bright.ev]
        guard ev.contains(where: { $0 != 0 }) || zones.global.ev != 0 else { return 0 }
        // Pivots arrive from a sidecar or a catalog row, so their count is untrusted;
        // `exposureStops` requires one per zone and traps otherwise, in release too.
        let pivots = zones.pivots.count == ev.count ? zones.pivots : Zones.defaultPivots
        return ZoneWeights.exposureStops(x: normalizedAxis(t), pivots: pivots,
                                         zoneEV: ev, globalEV: zones.global.ev)
    }

    /// Total gain in stops applied by S7 at zonal coordinate `t`.
    /// The six sliders and the Zones panel compose by summing their stop fields —
    /// one engine, two registers, never two parallel tools.
    public func stops(at t: Double) -> Double {
        // `zonalStops` already carries the solved amounts, per window.
        var s = zonalStops(t)
        s += contrastMapped(t) - t
        s += zonePanelStops(t)
        return s
    }

    /// Linear multiplier at `t` — what the shader multiplies the pixel by.
    public func gain(at t: Double) -> Double { pow(2, stops(at: t)) }

    /// Bake gain against the shaper's encoded domain: the GPU reads the guided mask,
    /// log-encodes it, and fetches this. One texture fetch replaces the whole panel.
    public func bakeGainLUT(size: Int = 1024) -> LUT1D {
        // The forward clamp below is a BACKSTOP, not the mechanism. `solveZonalLimits`
        // has already made the response monotone; this catches what it deliberately
        // does not cover — the Zones panel, which is the explicit power tool and would
        // stop being one if it were limited — and the fact that this samples the log
        // shaper's domain rather than the solver's sweep.
        //
        // It is worth saying why it is not the mechanism, because for one round it was.
        // A clamp removes the slider coupling too, and costs flat patches instead:
        // measured, Highlights −100 with Shadows +100, an ordinary "flatten it" move,
        // left 160 of 1024 samples reading one identical value, and all five sliders at
        // full opposing deflection left 497. Sixteen percent of the tonal axis
        // posterized is not a gentler failure than an inversion, it is a different one.
        // With the scale solved first the clamp fires on 0 of 1024 samples for every one
        // of the 242 combinations of the five sliders at ±100.
        bakeGainLUTAndFloor(size: size).lut
    }

    /// The bake and, from the same sweep, the floor the forward clamp imposed on it —
    /// `nil` when the clamp moved nothing, which is every recipe the six sliders alone
    /// can produce. `RenderPlan` keeps the floor so its per-pixel twins
    /// (`referenceColor`, `exactColor`) apply the tone the renderers apply instead of
    /// the tone the panel asked for; see `renderedStops(at:floor:)`.
    public func bakeGainLUTAndFloor(size: Int = 1024) -> (lut: LUT1D, floor: [Double]?) {
        let curve = clampedResponse(size: size)
        var samples = [Double](repeating: 1, count: curve.domain.count)
        for i in 0..<curve.domain.count {
            samples[i] = pow(2, curve.mapped[i] - curve.domain[i])
        }
        let clamped = curve.mapped != curve.requested
        return (LUT1D(samples: samples), clamped ? curve.mapped : nil)
    }

    /// Stops S7 RENDERS at `t`: `stops(at:)` with the bake's forward clamp applied
    /// analytically, for a caller that evaluates tone per pixel without the table.
    ///
    /// `floor` is the clamped response from `bakeGainLUTAndFloor`, on the shaper's
    /// encoded domain. The rendered output tone at `t` is never below the clamped
    /// value at the last shaper sample at or below `t` — exactly the running max the
    /// bake takes, evaluated at `t` instead of only at the samples. Without it the
    /// per-pixel twins applied the REQUESTED gain where the renderers apply the
    /// clamped one, so on a Zones recipe that reaches the clamp (Darks +4 EV: up to
    /// 2.2 EV apart) every golden comparing them measured the clamp and called it
    /// table error. Below the shaper's domain, and with no floor, this is `stops(at:)`.
    public func renderedStops(at t: Double, floor: [Double]?) -> Double {
        let requested = stops(at: t)
        guard let floor, floor.count >= 2 else { return requested }
        let y = LumenLog.encode(0.18 * pow(2, t))
        guard y >= 0 else { return requested }
        // `y` is +infinity for a large enough `t` (finite scene values reach it through
        // `exactColor`), and `Int(.infinity)` traps. Anything at or past the shaper's top
        // reads the last floor sample, which is what the running max holds there anyway.
        let i = Int((Swift.min(y, 1) * Double(floor.count - 1)).rounded(.down))
        return Swift.max(t + requested, floor[i]) - t
    }

    /// The baked response before and after the forward clamp, on the shaper's domain.
    /// One function so `bakeGainLUT` and `zoneFlattening` cannot disagree about what
    /// the clamp did.
    private func clampedResponse(size: Int)
        -> (domain: [Double], requested: [Double], mapped: [Double]) {
        let count = Swift.max(size, 2)
        var mapped = [Double](repeating: 0, count: count)
        var domain = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let y = Double(i) / Double(count - 1)
            let t = Num.safeLog2(LumenLog.decode(y) / 0.18)
            domain[i] = t
            mapped[i] = t + stops(at: t)
        }
        let requested = mapped
        // One forward pass: never let the mapped value fall below the one before it.
        // The domain is increasing, so this is exactly "no brighter input renders
        // darker", and it touches nothing that was already monotone.
        for i in 1..<mapped.count where mapped[i] < mapped[i - 1] {
            mapped[i] = mapped[i - 1]
        }
        return (domain, requested, mapped)
    }

    /// Where the bake's forward clamp flattened the tone response, if anywhere.
    ///
    /// Astra AI-07. The clamp is the Zones panel's only limiter, and it limits by
    /// rendering a band of input tones as ONE output value: Darks +2 EV at the default
    /// pivots flattens 1.74 EV of input (−3.53…−1.80 EV) and Darks +4 EV flattens
    /// 3.85 EV, where the rendered tone sits up to 2.20 EV away from what the slider
    /// asked for. Texture inside that band is gone, and nothing said so. This is the
    /// measurement a panel needs to say so; it changes no pixel.
    public struct Flattening: Equatable, Sendable {
        /// Darkest and brightest input tone, in EV from mid-grey, that the clamp moved.
        public var lowEV: Double
        public var highEV: Double
        /// Largest distance between the requested and the rendered tone, in EV.
        public var worstEV: Double
        /// Share of the shaper's samples the clamp moved.
        public var fraction: Double
        public var widthEV: Double { highEV - lowEV }
    }

    /// `nil` when the clamp in `bakeGainLUT` moved nothing — every recipe the six
    /// tone sliders alone can produce, by `solveZonalLimits`.
    public func zoneFlattening(size: Int = 1024) -> Flattening? {
        let curve = clampedResponse(size: size)
        var low = Double.nan, high = Double.nan, worst = 0.0, moved = 0
        for i in 0..<curve.domain.count where curve.mapped[i] != curve.requested[i] {
            moved += 1
            if low.isNaN { low = curve.domain[i] }
            high = curve.domain[i]
            worst = Swift.max(worst, curve.mapped[i] - curve.requested[i])
        }
        guard moved > 0 else { return nil }
        return Flattening(lowEV: low, highEV: high, worstEV: worst,
                          fraction: Double(moved) / Double(curve.domain.count))
    }

    /// True when nothing in the tone stack changes a pixel — lets the renderer skip
    /// the stage entirely rather than multiplying by 1.0 across 45 megapixels.
    public var isIdentity: Bool {
        // Whites and Blacks belong here now, and their absence was silently discarding
        // them. They used to move the display transform's ANCHORS and contribute
        // nothing to the gain LUT, so leaving them out was correct — the anchors are
        // applied separately by `applyAnchors`. The moment they gained a tonal shelf,
        // this guard started collapsing `toneGainLUT` to a 2-sample identity for any
        // recipe that moved only those two, throwing the shelf away before it reached a
        // pixel.
        //
        // It cost three rounds of tuning to notice, because the measured authority came
        // back byte-identical across three different sets of constants — 12.35 code
        // values for Whites every time — while the monotonicity probe, which reads
        // `stops()` directly rather than through the plan, moved as expected. An
        // identity guard that does not know about an input is the same failure as a
        // cache key that does not: it does not error, it just quietly renders the wrong
        // picture.
        tone.contrast == 0 && tone.highlights == 0 && tone.shadows == 0
            && tone.whites == 0 && tone.blacks == 0
            && zonePanelIsIdentity
    }

    private var zonePanelIsIdentity: Bool {
        zones.dark.ev == 0 && zones.shadow.ev == 0 && zones.mid.ev == 0
            && zones.light.ev == 0 && zones.bright.ev == 0 && zones.global.ev == 0
    }

    /// Feed the anchors into the display transform: the base white anchor
    /// (`defaultWhiteAnchorEV`, which is how that constant reaches every render —
    /// `DisplayTransformParams.whiteAnchorEV` defaults to 5 and `DisplayTransform.forRecipe`
    /// overwrites it here) and the black anchor Blacks moves. Whites does not move the
    /// white one any more; its white point is gain (file header).
    public func applyAnchors(to params: inout DisplayTransformParams) {
        params.whiteAnchorEV = whiteAnchorEV
        params.blackAnchorEV = blackAnchorEV
    }
}

// MARK: - Auto tone (D11)

/// Deterministic scene statistics, never a cloud model, and it writes *visible*
/// slider values the user can then argue with (docs/04 §14.3).
public struct AutoTone: Sendable {

    public struct Statistics: Sendable {
        /// Log2 luminance histogram of the (cropped) frame, in stops around mid-grey.
        public var histogram: [Double]
        public var minEV: Double
        public var maxEV: Double
        /// Mean log-luminance of detected faces, if any — Auto is face-weighted.
        public var faceMeanEV: Double?

        public init(histogram: [Double], minEV: Double = -12, maxEV: Double = 12,
                    faceMeanEV: Double? = nil) {
            self.histogram = histogram
            self.minEV = minEV
            self.maxEV = maxEV
            self.faceMeanEV = faceMeanEV
        }

        /// EV at the given cumulative fraction of the histogram.
        public func percentileEV(_ fraction: Double) -> Double {
            let total = histogram.reduce(0, +)
            guard total > 0 else { return 0 }
            let target = total * Num.saturate(fraction)
            var acc = 0.0
            for (i, v) in histogram.enumerated() {
                acc += v
                if acc >= target {
                    let t = Double(i) / Double(Swift.max(histogram.count - 1, 1))
                    return Num.mix(minEV, maxEV, t)
                }
            }
            return maxEV
        }

        public var meanEV: Double {
            let total = histogram.reduce(0, +)
            guard total > 0 else { return 0 }
            var acc = 0.0
            for (i, v) in histogram.enumerated() {
                let t = Double(i) / Double(Swift.max(histogram.count - 1, 1))
                acc += v * Num.mix(minEV, maxEV, t)
            }
            return acc / total
        }
    }

    /// Target placement for the subject: faces land near −1 EV under mid-grey-plus,
    /// which is where skin sits in a well-exposed frame.
    public static let faceTargetEV: Double = -0.35
    public static let sceneTargetEV: Double = -0.6

    /// Compute slider values. Every value returned is inside its slider's range and
    /// lands in the UI as a normal, undoable edit.
    public static func suggest(from stats: Statistics) -> Tone {
        var t = Tone()

        // Exposure places the subject: faces if we have them, otherwise the frame's
        // median, which is robust to the specular highlights that fool mean-metering.
        let anchor = stats.faceMeanEV ?? stats.percentileEV(0.5)
        let target = stats.faceMeanEV != nil ? faceTargetEV : sceneTargetEV
        t.exposure = Num.clamp(target - anchor, -5, 5)

        // Highlights recover only what is actually near clipping after that exposure.
        let hi = stats.percentileEV(0.995) + t.exposure
        if hi > 3.0 {
            t.highlights = Num.clamp(-(hi - 3.0) / 2.0 * 100, -100, 0)
        }

        // Shadows lift only what is actually buried.
        let lo = stats.percentileEV(0.005) + t.exposure
        if lo < -7.0 {
            t.shadows = Num.clamp((-7.0 - lo) / 2.5 * 100, 0, 100)
        }

        // Whites/Blacks set the endpoints against the post-exposure spread.
        let spread = hi - lo
        if spread < 8 {
            // Flat scene: open the endpoints to use the display's range.
            let deficit = (8 - spread) / 8
            t.whites = Num.clamp(deficit * 60, 0, 60)
            t.blacks = Num.clamp(-deficit * 50, -60, 0)
        }

        // Contrast responds to how compressed the midtones are, gently — Auto that
        // shouts is Auto the user turns off.
        let mid = stats.percentileEV(0.75) - stats.percentileEV(0.25)
        if mid < 2.0 {
            t.contrast = Num.clamp((2.0 - mid) * 25, 0, 40)
        }
        t.contrastPivot = stats.faceMeanEV.map { Num.clamp($0 + t.exposure, -4, 4) } ?? 0

        return t
    }
}

// MARK: - Scene-referred statistics from a rendered proxy

extension AutoTone {

    /// Builds `Statistics` in SCENE EV from a frame that has already been through the
    /// display transform.
    ///
    /// Auto measures the rendered proxy, because that is the only frame the app has
    /// cheaply to hand. What it did with it was bin `log2(displayLuminance / 0.18)` and
    /// call the result an EV — reading a display-referred number as if it were a
    /// scene-referred one, which is the same class of mistake as the EV-versus-encoded
    /// confusions BUILDING.md catalogues, and it cost the same way.
    ///
    /// The arithmetic: a display-referred value cannot exceed 1.0, so that expression
    /// cannot exceed `log2(1 / 0.18)` = **+2.47 EV**, whatever the scene held.
    /// `AutoTone.suggest` fires highlight recovery on `percentileEV(0.995) + exposure >
    /// 3.0`. The measurement could not reach the threshold, so on a blown sky — the one
    /// frame the branch exists for — Auto wrote Highlights 0, and always had. The same
    /// squeeze at the bottom put the darkest reachable reading at the black target
    /// rather than at the scene value that produced it, so the shadow branch was
    /// reading the transform's toe instead of the photograph.
    ///
    /// The fix is to invert the curve the render applied. Every sample is a scene EV
    /// put THROUGH `transform.tone`, and each pixel is located among them, so the
    /// statistics come back denominated where `suggest`'s thresholds already are.
    ///
    /// Two honest limits, because the render is not an invertible function:
    ///
    /// · **Censoring.** The curve saturates at the anchors: everything at or above the
    ///   white anchor renders to display white and everything at or below the black
    ///   anchor to display black. Those pixels come back AT the anchor, not beyond it.
    ///   That is the correct reading — "at least this bright" — and it is what makes
    ///   the highlight branch reachable: 0.5% of the frame at display white now reads
    ///   +5 EV with the default anchors, not +2.47.
    ///
    /// · **Luminance, not colour.** `tone` is the scalar curve; `apply` runs it per
    ///   channel with hue preservation and a gamut map. Inverting the scalar against a
    ///   pixel's luminance is exact for neutrals and an approximation for saturated
    ///   colour. Auto is placing a scene in EV, not measuring a colour, so this is the
    ///   right approximation to make — but it is one, and a Film Lab chain, which
    ///   replaces the transform outright, is outside what this can invert at all.
    public struct SceneHistogram: Sendable {

        /// Bin centres run from `minEV` to `maxEV` inclusive, which is exactly how
        /// `Statistics.percentileEV` reads a bin index back out. Binning by rounding
        /// rather than by flooring makes this the inverse of that read instead of half
        /// a bin off it.
        public let minEV: Double
        public let maxEV: Double

        public private(set) var bins: [Double]

        /// Scene EV of each sample, ascending, spanning the transform's two anchors.
        private let sampleEV: [Double]
        /// Display-linear luminance of each sample — `tone` applied to `sampleEV`.
        private let sampleDisplay: [Double]

        /// Resolution of the inversion table. 1024 samples over the 14 EV between the
        /// default anchors is 0.014 EV a step, an order under the 0.19 EV a histogram
        /// bin spans, so the table is not what limits the answer.
        public static let inversionSamples: Int = 1024

        public init(transform: DisplayTransform,
                    minEV: Double = -12, maxEV: Double = 12, binCount: Int = 128) {
            self.minEV = minEV
            self.maxEV = maxEV
            self.bins = [Double](repeating: 0, count: Swift.max(binCount, 2))

            // The same guards `DisplayTransform.init` puts on the anchors, so the table
            // spans the interval the curve is actually defined over.
            let lo = Swift.min(transform.params.blackAnchorEV, -0.5)
            let hi = Swift.max(transform.params.whiteAnchorEV, 0.5)
            let n = SceneHistogram.inversionSamples
            var evs = [Double](repeating: 0, count: n)
            var display = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let ev = Num.mix(lo, hi, Double(i) / Double(n - 1))
                evs[i] = ev
                display[i] = transform.tone(DisplayTransform.midGrey * exp2(ev))
            }
            self.sampleEV = evs
            self.sampleDisplay = display
        }

        /// Scene EV that renders to this display-linear luminance, clamped to the
        /// anchors the curve saturates at.
        public func sceneEV(displayLuminance y: Double) -> Double {
            let first = sampleEV[0]
            let lastEV = sampleEV[sampleEV.count - 1]
            guard y.isFinite, y > sampleDisplay[0] else { return first }
            guard y < sampleDisplay[sampleDisplay.count - 1] else { return lastEV }
            // First sample at or above `y`. A lower bound rather than a nearest match,
            // so a value sitting on a flat stretch of the curve — the Linear preset's
            // clip, say — reports the FIRST scene EV that could have produced it rather
            // than the last. Same censoring rule as the two anchors.
            var lo = 0
            var hi = sampleDisplay.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if sampleDisplay[mid] < y { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return first }
            let below = sampleDisplay[lo - 1]
            let above = sampleDisplay[lo]
            guard above > below else { return sampleEV[lo] }
            let t = Num.saturate((y - below) / (above - below))
            return Num.mix(sampleEV[lo - 1], sampleEV[lo], t)
        }

        /// Count one pixel, given its display-linear luminance.
        public mutating func add(displayLuminance y: Double) {
            let ev = sceneEV(displayLuminance: y)
            let t = Num.saturate((ev - minEV) / (maxEV - minEV))
            let index = Int((t * Double(bins.count - 1)).rounded())
            bins[Swift.min(Swift.max(index, 0), bins.count - 1)] += 1
        }

        public var statistics: Statistics {
            Statistics(histogram: bins, minEV: minEV, maxEV: maxEV)
        }
    }
}
