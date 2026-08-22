// ToneEngine.swift
// The six-slider tone contract and the Zones panel as ONE engine (docs/04 §3.5,
// docs/14 §S7): every tonal control compiles to a per-pixel gain, in stops, over the
// zonal coordinate `t = log2(luminance / 0.18)`.
//
// One property is structural rather than enforced:
//   · Whites and Blacks do not gain anything — they move the anchors the display
//     transform maps to display white and black. That is what "Whites owns the white
//     point" means when you build it instead of writing it down.
//
// A second one used to be, and this file said so for longer than it was true. The claim
// was that Highlights' weight window "tapers to zero at the white anchor, so Highlights
// can never push a pixel past display white — LrC's most load-bearing hidden rule,
// implemented as geometry". It is not geometry any more. The bump became a shelf for
// the reasons `highlightShelfEnd` gives at length, and a shelf saturates: `smoothstep(0,
// whiteAnchorEV, t)` is 1 AT the anchor and 1 above it, so Highlights ±100 applies its
// full ±2 EV to pixels already at and beyond white. That was the point of the rework —
// a bump left a blown sky exactly where it was — and the words simply did not follow.
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

    /// Scene EV of the display transform's anchors after Whites/Blacks move them.
    public let whiteAnchorEV: Double
    public let blackAnchorEV: Double

    /// ±100 on Highlights/Shadows ⇒ this many stops of peak zonal gain (docs/04 §3.4).
    public static let highlightShadowRangeEV: Double = 2.0
    /// ±100 on Whites/Blacks ⇒ this many stops of end-point shift.
    public static let whiteBlackRangeEV: Double = 1.5

    /// Where the Highlights and Shadows shelves reach full strength, as a fraction of
    /// the anchor. They SATURATE rather than returning to zero.
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
    public static let highlightShelfEnd: Double = 1.0

    /// The same for Shadows, as a fraction of |black anchor|.
    ///
    /// Not 1.0, because the two ends of the range are not symmetric in what a viewer
    /// can see. The black anchor is 9 stops below mid-grey and the display transform's
    /// toe puts −9 EV at sRGB code 0.5, −7.25 at 0.6, −5.5 at 2.5. A shelf that only
    /// reaches full strength at the anchor spends itself where there is nothing to
    /// move: measured, Shadows +100 was worth 9.1 code values because at −4 EV — where
    /// a photograph's shadows actually live, code 8 — the shelf had only reached 0.42.
    /// Saturating at half the anchor puts full strength at −4.5 EV instead.
    public static let shadowShelfEnd: Double = 0.5

    /// Where the Whites and Blacks shelves run, as a fraction of the anchor. They start
    /// above where Highlights and Shadows have already saturated, so the two controls
    /// act on different parts of the range instead of fighting for the same one.
    public static let endShelfStart: Double = 0.20
    public static let endShelfEnd: Double = 0.80

    /// Blacks' shelf, as a fraction of |black anchor|. Deeper than Shadows' and wider,
    /// so the two controls act on different tones and their slopes do not peak
    /// together — Shadows' steepest point is around −2.2 EV, Blacks' around −5.9.
    public static let blackShelfStart: Double = 0.15
    public static let blackShelfEnd: Double = 0.62

    /// ±100 on Whites/Blacks ⇒ this many stops of tonal shift at the extreme, on top of
    /// the anchor move. Sized so the shelf's slope (1.5 / (0.8 x anchor) x range) plus
    /// the Highlights shelf's stays under the identity's 1.0 at every point.
    public static let whiteToneEV: Double = 1.3
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

    public init(tone: Tone = Tone(), zones: Zones = Zones()) {
        self.tone = tone
        self.zones = zones
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        let hi = Self.defaultWhiteAnchorEV - Self.whiteBlackRangeEV * whites
        let lo = Self.defaultBlackAnchorEV - Self.whiteBlackRangeEV * blacks
        self.whiteAnchorEV = hi
        self.blackAnchorEV = lo
        // ONE scale over the whole zonal sum, found by bisection, rather than a cap per
        // window.
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
        // Scoped to the zonal sum, this binds only when the windows genuinely conflict.
        // A single slider at full deflection is monotone on its own — the shelves are
        // shaped so it is — so it is never scaled, and the coupling that remains is
        // between settings that cannot both be honoured.
        let scale = Self.solveZonalScale(tone: tone, whiteAnchorEV: hi, blackAnchorEV: lo)
        self.zonalScale = scale
        self.effectiveHighlights = Num.clamp(tone.highlights, -100, 100) / 100 * scale
        self.effectiveShadows = Num.clamp(tone.shadows, -100, 100) / 100 * scale
    }

    /// The scale actually applied to the zonal contribution — Highlights, Shadows,
    /// Whites and Blacks together.
    ///
    /// 1.0 unless the four windows, at the values asked for, cannot all be honoured
    /// without the tone response running downhill somewhere. Exposed for the same
    /// reason `effectiveHighlights` is: a slider that has quietly stopped meaning what
    /// it says should be able to show it.
    public let zonalScale: Double

    /// Fraction of the limit below which the request is applied exactly.
    static let zonalKnee: Double = 0.8

    /// Sweep step for the monotonicity solve, in stops. The windows are smoothsteps
    /// spanning whole stops, so nothing narrower can hide inside one; `bakeGainLUT`'s
    /// forward clamp is the backstop for anything that does.
    static let monotoneStepEV: Double = 0.05

    /// Above this the request is treated as having room to spare and left alone. It has
    /// to sit above `1 / zonalKnee`, or a setting that is comfortably safe would still
    /// be eased.
    static let searchCeiling: Double = 4

    /// The largest scale on the zonal contribution that keeps `t + stops(t)` increasing,
    /// then eased onto that limit so the top of every slider still moves.
    ///
    /// Two parts, and both are load-bearing.
    ///
    /// The LIMIT is closed-form, not searched. Writing the mapping as
    /// `mapped(t) = contrastMapped(t) + scale x zonalRaw(t)` makes it LINEAR in `scale`,
    /// so "mapped never falls" is one inequality per sample interval —
    /// `Δcontrast + scale x Δzonal ≥ 0` — and only the intervals where `Δzonal` is
    /// negative constrain anything. The smallest ratio over those is the limit exactly.
    /// This started as a bisection over the same monotonicity predicate; it agreed to
    /// six figures and cost 23 sweeps and 23 throwaway engines per slider move, which
    /// on the interactive path is 10 ms of a 33 ms frame spent rediscovering a number
    /// one pass already knows.
    ///
    /// The KNEE exists because a hard limit is a dead control. The limit is inversely
    /// proportional to the requested magnitude — push a conflicting pair harder and it
    /// shrinks by exactly the factor you pushed — so `scale x request` is CONSTANT the
    /// moment a hard cap binds, and the rest of the travel does nothing at all. That is
    /// what `Num.softKnee` is for, and it takes the reciprocal form here for the same
    /// reason the grading wheels do: `1 / limit` is the request measured in units of the
    /// largest safe one, so `limit x softKnee(1/limit)` is exact while the request is
    /// under `zonalKnee x limit` and approaches the limit without reaching it after.
    static func solveZonalScale(tone: Tone, whiteAnchorEV: Double,
                                blackAnchorEV: Double) -> Double {
        let limit = solveZonalLimit(tone: tone, whiteAnchorEV: whiteAnchorEV,
                                    blackAnchorEV: blackAnchorEV)
        guard limit > 0 else { return 0 }
        return Swift.min(1, limit * Num.softKnee(1 / limit, knee: Self.zonalKnee))
    }

    /// The limit itself, before the knee. Split out so a test can assert the thing that
    /// matters about it — that the response still rises AT it and stops rising just
    /// above it — which is the only way to tell a correct limiter from a timid one.
    static func solveZonalLimit(tone: Tone, whiteAnchorEV: Double,
                                blackAnchorEV: Double) -> Double {
        let highlights = Num.clamp(tone.highlights, -100, 100) / 100
        let shadows = Num.clamp(tone.shadows, -100, 100) / 100
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        guard highlights != 0 || shadows != 0 || whites != 0 || blacks != 0 else {
            return Self.searchCeiling
        }

        // The zonal sum at scale 1. Built through the private init so this measures the
        // same code the renderer runs, rather than a second copy of the same arithmetic
        // that can drift away from it.
        let unit = ToneEngine(tone: tone, zones: Zones(),
                              effectiveHighlights: highlights, effectiveShadows: shadows,
                              zonalScale: 1)

        let step = Self.monotoneStepEV
        // Two stops past each anchor: the shelves have saturated out there, but an
        // inversion sitting on the last half stop of the range is still an inversion.
        var t = blackAnchorEV - 2
        let end = whiteAnchorEV + 2
        var previousZonal = unit.zonalStops(t)
        var previousFixed = unit.contrastMapped(t)
        var limit = Self.searchCeiling
        while t < end {
            t += step
            let zonal = unit.zonalStops(t)
            let fixed = unit.contrastMapped(t)
            let dZonal = zonal - previousZonal
            // Only a falling zonal contribution can pull the mapping downhill, and
            // `dFixed` is the contrast slope, which is positive for every legal
            // contrast — so the ratio is always a real bound, never a sign trap.
            if dZonal < 0 {
                limit = Swift.min(limit, Swift.max((fixed - previousFixed) / -dZonal, 0))
            }
            previousZonal = zonal
            previousFixed = fixed
        }
        return limit
    }

    /// A probe at a scale it did not solve for itself. Internal, and only a test has any
    /// business calling it: the point of the limiter is that the scale is derived from
    /// the settings, so an engine holding an unrelated one renders a picture nothing
    /// asked for.
    init(tone: Tone, forcingZonalScale scale: Double) {
        self.init(tone: tone, zones: Zones(),
                  effectiveHighlights: Num.clamp(tone.highlights, -100, 100) / 100 * scale,
                  effectiveShadows: Num.clamp(tone.shadows, -100, 100) / 100 * scale,
                  zonalScale: scale)
    }

    /// The probe the solver bisects on. Private because a `ToneEngine` whose scale was
    /// not solved for its own settings is a half-built object — it exists to be
    /// measured, never to render.
    private init(tone: Tone, zones: Zones,
                 effectiveHighlights: Double, effectiveShadows: Double,
                 zonalScale: Double) {
        self.tone = tone
        self.zones = zones
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        self.whiteAnchorEV = Self.defaultWhiteAnchorEV - Self.whiteBlackRangeEV * whites
        self.blackAnchorEV = Self.defaultBlackAnchorEV - Self.whiteBlackRangeEV * blacks
        self.effectiveHighlights = effectiveHighlights
        self.effectiveShadows = effectiveShadows
        self.zonalScale = zonalScale
    }

    /// The Highlights + Shadows contribution, at the amounts actually applied.
    func zonalStops(_ t: Double) -> Double {
        var s = 0.0
        if effectiveHighlights != 0 {
            s += effectiveHighlights * Self.highlightShadowRangeEV * highlightWeight(t)
        }
        if effectiveShadows != 0 {
            s += effectiveShadows * Self.highlightShadowRangeEV * shadowWeight(t)
        }
        let whites = Num.clamp(tone.whites, -100, 100) / 100 * zonalScale
        if whites != 0 {
            s += whites * Self.whiteToneEV * whiteWeight(t)
        }
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100 * zonalScale
        if blacks != 0 {
            s += blacks * Self.blackToneEV * blackWeight(t)
        }
        return s
    }

    /// Scene-linear multiplier from the Exposure slider. Applied at S6, upstream of
    /// everything here, which is why it never invalidates the decode cache.
    public var exposureGain: Double { pow(2, Num.clamp(tone.exposure, -10, 10)) }

    // MARK: - Zonal windows

    /// Highlights window: a SHELF that rises from zero at mid-grey, reaches full
    /// strength at the white anchor and stays there above it.
    ///
    /// It was a raised-cosine bump returning to zero at the anchor, and this comment
    /// went on saying so after `highlightShelfEnd` replaced it. Full strength above the
    /// anchor is the behaviour: a blown sky is the one thing Highlights exists to pull
    /// down, and a window that shuts at white is a window that cannot reach it.
    public func highlightWeight(_ t: Double) -> Double {
        let hi = whiteAnchorEV
        guard hi > 0 else { return 0 }
        return Num.smoothstep(0, hi * Self.highlightShelfEnd, t)
    }

    /// Whites: a shelf in the top of the range, above where Highlights has saturated.
    ///
    /// Whites used to move the white ANCHOR and nothing else. Measured on a -9…+5 EV
    /// grey ramp, full travel was worth 26.7 code values up and 12.3 down — and Blacks,
    /// on the same measurement, was worth 0.20. The anchor sets where the transform's
    /// endpoint lands, which is a real thing to control, but the toe and shoulder have
    /// already compressed those regions, so on its own it is a slider a photographer
    /// would call dead. The anchor move is kept; this adds the tonal authority.
    public func whiteWeight(_ t: Double) -> Double {
        let hi = whiteAnchorEV
        guard hi > 0 else { return 0 }
        return Num.smoothstep(hi * Self.endShelfStart, hi * Self.endShelfEnd, t)
    }

    /// Shadows window: mirror image below mid-grey, zero at the black anchor.
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

    /// Blacks: the mirror of Whites, a shelf in the bottom of the range.
    public func blackWeight(_ t: Double) -> Double {
        let lo = blackAnchorEV
        guard lo < 0 else { return 0 }
        return Num.smoothstep(-lo * Self.blackShelfStart, -lo * Self.blackShelfEnd, -t)
    }

    /// Where the slope starts and finishes relaxing back to 1, in stops from the
    /// pivot. The window has to be this wide: relaxing a slope over a narrow band
    /// makes the mapping itself non-monotone, because the falling gain beats the
    /// rising distance. Over 4→8 stops the derivative goes negative at contrast ≈ 85,
    /// which would render a brighter input darker — an inversion, never a look. Over
    /// 4→12 the derivative stays positive past contrast 128, with margin.
    public static let contrastRelaxStartEV: Double = 4
    public static let contrastRelaxEndEV: Double = 12

    /// Contrast: slope around an explicit pivot in log-exposure space, with the slope
    /// relaxing back to 1 far from the pivot so extremes compress rather than explode
    /// (the toe and shoulder of S14 finish the job).
    public func contrastMapped(_ t: Double) -> Double {
        let c = Num.clamp(tone.contrast, -100, 100)
        guard c != 0 else { return t }
        let pivot = Num.clamp(tone.contrastPivot, -4, 4)
        let slope = 1 + 0.6 * (c / 100)
        let d = t - pivot
        let relax = Num.smoothstep(Self.contrastRelaxStartEV, Self.contrastRelaxEndEV,
                                   abs(d))
        let effective = Num.mix(slope, 1, relax)
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
        // The forward clamp below is a BACKSTOP, not the mechanism. `solveZonalScale`
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
        let count = Swift.max(size, 2)
        var samples = [Double](repeating: 1, count: count)
        var mapped = [Double](repeating: 0, count: count)
        var domain = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let y = Double(i) / Double(count - 1)
            let t = Num.safeLog2(LumenLog.decode(y) / 0.18)
            domain[i] = t
            mapped[i] = t + stops(at: t)
        }
        // One forward pass: never let the mapped value fall below the one before it.
        // The domain is increasing, so this is exactly "no brighter input renders
        // darker", and it touches nothing that was already monotone.
        for i in 1..<mapped.count where mapped[i] < mapped[i - 1] {
            mapped[i] = mapped[i - 1]
        }
        for i in 0..<count {
            samples[i] = pow(2, mapped[i] - domain[i])
        }
        return LUT1D(samples: samples)
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

    /// Feed the anchors into the display transform. This is the seam that makes
    /// Whites/Blacks mean "white point" and "black point" rather than "more gain".
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
