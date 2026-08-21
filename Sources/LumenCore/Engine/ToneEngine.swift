// ToneEngine.swift
// The six-slider tone contract and the Zones panel as ONE engine (docs/04 §3.5,
// docs/14 §S7): every tonal control compiles to a per-pixel gain, in stops, over the
// zonal coordinate `t = log2(luminance / 0.18)`.
//
// Two properties are structural rather than enforced:
//   · Highlights' weight window tapers to zero at the white anchor, so Highlights can
//     never push a pixel past display white. LrC's most load-bearing hidden rule,
//     implemented as geometry.
//   · Whites and Blacks do not gain anything — they move the anchors the display
//     transform maps to display white and black. That is what "Whites owns the white
//     point" means when you build it instead of writing it down.
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
        self.effectiveHighlights = Self.solveEffective(
            .highlights, tone: tone, whiteAnchorEV: hi, blackAnchorEV: lo)
        self.effectiveShadows = Self.solveEffective(
            .shadows, tone: tone, whiteAnchorEV: hi, blackAnchorEV: lo)
    }

    /// The largest multiple of the Highlights/Shadows contribution that keeps
    /// `t + stops(t)` strictly increasing.
    ///
    /// The windows are raised cosines of a sine, whose steepest slope is
    /// `4.3535 / anchor` — so at the default white anchor of 5 EV, Highlights at −100
    /// contributes a slope of −2 × 0.871 = −1.74 against the +1 the identity brings.
    /// The composed response therefore ran DOWNHILL just above mid-grey: a brighter
    /// part of the scene rendered darker than a dimmer one. Not a look, an inversion,
    /// and the same failure the contrast relax window was widened to prevent — this
    /// one simply lives on a different slider.
    ///
    /// Shadows is safer only by accident: the black anchor sits nine stops down where
    /// the same window is nearly twice as wide, so its slope is 0.97 and it inverts
    /// only once Blacks pulls the anchor in.
    ///
    /// Rather than shrink the range for everybody, this solves for the largest amount
    /// that stays monotone, and eases the slider onto it.
    ///
    /// PER WINDOW, and that matters. A single scale over the whole zonal sum was the
    /// first version of this, and it coupled two sliders that share no domain:
    /// Highlights' window lives above mid-grey and Shadows' below, so the constraint
    /// that binds is always in one of them — and multiplying the sum then cut the
    /// *other* one down with it. Highlights at −100 turned a Shadows setting of +60
    /// into an effective +33.8, and Contrast and Whites moved the same lever, so the
    /// Highlights slider's meaning depended on three other sliders. Shadows' own cap at
    /// the defaults is exactly 1.0 — it was never the one at risk.
    ///
    /// SOFT, and that matters too. Capping hard at the limit made the top of the slider
    /// dead: the cap at the defaults is 0.563, so 57 through 100 all applied exactly
    /// 0.563 — identical to the last bit, over the top 43% of the control. The knee is
    /// exact up to 80% of the cap (slider 45 at the defaults) and then approaches it
    /// without reaching it, so every setting is distinct, the response never falls, and
    /// 100 is the strongest setting. It costs at most 7% against the old hard clip, and
    /// only between 45 and 100 where the old behaviour was a flat line anyway.
    enum ZonalWindow { case highlights, shadows }

    /// Fraction of the cap below which the slider is applied exactly.
    static let zonalKnee: Double = 0.8

    static func solveEffective(_ window: ZonalWindow, tone: Tone,
                               whiteAnchorEV: Double,
                               blackAnchorEV: Double) -> Double {
        let raw = Num.clamp(window == .highlights ? tone.highlights : tone.shadows,
                            -100, 100) / 100
        guard raw != 0 else { return 0 }

        let probe = ToneEngine(tone: tone, zones: Zones(),
                               effectiveHighlights: 0, effectiveShadows: 0)
        let step = 0.02
        let margin = 0.02
        // Each window's own domain. They meet only at mid-grey, where both weights are
        // zero, so nothing is missed by splitting the sweep here.
        let from = window == .highlights ? 0.0 : blackAnchorEV
        let through = window == .highlights ? whiteAnchorEV : 0.0

        var cap = 1.0
        var t = from
        while t <= through {
            let a = t + step
            // `t + stops(t)` is `contrastMapped(t) + zonal(t) + zonePanel(t)`, so the
            // slope splits into a part this amount does not touch and a part linear in
            // it. The Zones panel is deliberately outside the guarantee: it is the
            // explicit power tool, and clamping it would be taking away the thing it
            // is for.
            let fixedSlope = (probe.contrastMapped(a) - probe.contrastMapped(t)) / step
            let weight = window == .highlights
                ? (probe.highlightWeight(a) - probe.highlightWeight(t))
                : (probe.shadowWeight(a) - probe.shadowWeight(t))
            let unit = weight / step * Self.highlightShadowRangeEV
            // `unit` is the slope this window contributes per unit of amount. Only the
            // direction that fights the identity's rise can invert anything.
            let contribution = unit * (raw < 0 ? -1 : 1)
            if contribution < 0 {
                cap = Swift.min(cap, Swift.max((fixedSlope - margin) / -contribution, 0))
            }
            t += step
        }
        return Self.softLimited(raw, cap: Num.clamp(cap, 0, 1))
    }

    /// Exact below `zonalKnee × cap`, then approaching `cap` asymptotically. Shared with
    /// the grading wheels, which hit the identical problem.
    static func softLimited(_ amount: Double, cap: Double) -> Double {
        Num.softLimit(amount, cap: cap, knee: Self.zonalKnee)
    }

    private init(tone: Tone, zones: Zones,
                 effectiveHighlights: Double, effectiveShadows: Double) {
        self.tone = tone
        self.zones = zones
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        self.whiteAnchorEV = Self.defaultWhiteAnchorEV - Self.whiteBlackRangeEV * whites
        self.blackAnchorEV = Self.defaultBlackAnchorEV - Self.whiteBlackRangeEV * blacks
        self.effectiveHighlights = effectiveHighlights
        self.effectiveShadows = effectiveShadows
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
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        if whites != 0 {
            s += whites * Self.whiteToneEV * whiteWeight(t)
        }
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        if blacks != 0 {
            s += blacks * Self.blackToneEV * blackWeight(t)
        }
        return s
    }

    /// Scene-linear multiplier from the Exposure slider. Applied at S6, upstream of
    /// everything here, which is why it never invalidates the decode cache.
    public var exposureGain: Double { pow(2, Num.clamp(tone.exposure, -10, 10)) }

    // MARK: - Zonal windows

    /// Highlights window: a raised-cosine bump that rises from zero at mid-grey and
    /// returns to zero exactly at the white anchor.
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
        // Monotonicity is enforced HERE, on the baked curve, rather than by capping
        // each window's amount in isolation.
        //
        // `solveEffective` caps Highlights and Shadows so that each one alone keeps
        // `t + stops(t)` increasing. That was never a guarantee about the total: with
        // Whites and Blacks now contributing tonal shelves of their own, a plausible
        // flat-look recipe — Highlights −100, Shadows +100, Whites −100, Blacks +100,
        // Contrast −100 — drove the slope to −0.57, and a negative slope means a
        // brighter input renders darker. On a photograph that is solarization.
        //
        // Capping the windows against each other would have worked and would have cost
        // the thing this whole pass exists to fix: an amount that depends on its
        // neighbours is a slider whose meaning changes under the hand, which is what
        // made Highlights vary 3.6x with Contrast. Enforcing it on the curve instead
        // leaves every slider independent through its normal range and degrades
        // gracefully only where the combination genuinely cannot be honoured — and
        // there it flattens rather than inverting, which is the right failure.
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
