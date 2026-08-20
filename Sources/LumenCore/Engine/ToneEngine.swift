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

    /// Default anchors with all sliders at zero: 5 stops of highlight headroom above
    /// mid-grey and 9 stops of shadow range below it — the working latitude of a
    /// modern full-frame sensor.
    public static let defaultWhiteAnchorEV: Double = 5.0
    public static let defaultBlackAnchorEV: Double = -9.0

    /// What the Highlights and Shadows contributions are multiplied by so the tone
    /// response cannot invert. 1 whenever the sliders are already safe, which is
    /// almost always.
    public let zonalScale: Double

    public init(tone: Tone = Tone(), zones: Zones = Zones()) {
        self.tone = tone
        self.zones = zones
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        let hi = Self.defaultWhiteAnchorEV - Self.whiteBlackRangeEV * whites
        let lo = Self.defaultBlackAnchorEV - Self.whiteBlackRangeEV * blacks
        self.whiteAnchorEV = hi
        self.blackAnchorEV = lo
        self.zonalScale = Self.solveZonalScale(tone: tone, whiteAnchorEV: hi,
                                               blackAnchorEV: lo)
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
    /// Rather than shrink the range for everybody, this solves for the largest scale
    /// that stays monotone. Every contribution but the zonal one is fixed, and the
    /// zonal one is linear in the scale, so one pass over the domain gives it in
    /// closed form. At every default and most real settings it returns 1.
    static func solveZonalScale(tone: Tone, whiteAnchorEV: Double,
                                blackAnchorEV: Double) -> Double {
        let h = Num.clamp(tone.highlights, -100, 100) / 100
        let sh = Num.clamp(tone.shadows, -100, 100) / 100
        guard h != 0 || sh != 0 else { return 1 }

        let probe = ToneEngine(tone: tone, zones: Zones(), zonalScale: 1)
        let step = 0.02
        let margin = 0.02
        var scale = 1.0
        var t = blackAnchorEV
        while t <= whiteAnchorEV {
            let a = t + step
            // `t + stops(t)` is `contrastMapped(t) + scale·zonal(t) + zonePanel(t)`,
            // so the slope splits into a part the scale does not touch and a part
            // that is linear in it. The Zones panel is deliberately outside this
            // guarantee: it is the explicit power tool, and clamping it would be
            // taking away the thing it is for.
            let fixedSlope = (probe.contrastMapped(a) - probe.contrastMapped(t)) / step
            let zonal = (probe.zonalStops(a) - probe.zonalStops(t)) / step
            if zonal < 0 {
                scale = Swift.min(scale, Swift.max((fixedSlope - margin) / -zonal, 0))
            }
            t += step
        }
        return Num.clamp(scale, 0, 1)
    }

    private init(tone: Tone, zones: Zones, zonalScale: Double) {
        self.tone = tone
        self.zones = zones
        let whites = Num.clamp(tone.whites, -100, 100) / 100
        let blacks = Num.clamp(tone.blacks, -100, 100) / 100
        self.whiteAnchorEV = Self.defaultWhiteAnchorEV - Self.whiteBlackRangeEV * whites
        self.blackAnchorEV = Self.defaultBlackAnchorEV - Self.whiteBlackRangeEV * blacks
        self.zonalScale = zonalScale
    }

    /// The Highlights + Shadows contribution alone, before `zonalScale`.
    func zonalStops(_ t: Double) -> Double {
        var s = 0.0
        let h = Num.clamp(tone.highlights, -100, 100) / 100
        let sh = Num.clamp(tone.shadows, -100, 100) / 100
        if h != 0 { s += h * Self.highlightShadowRangeEV * highlightWeight(t) }
        if sh != 0 { s += sh * Self.highlightShadowRangeEV * shadowWeight(t) }
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
        if t <= 0 || t >= hi { return 0 }
        return Num.raisedCosine(sin(.pi * (t / hi)))
    }

    /// Shadows window: mirror image below mid-grey, zero at the black anchor.
    public func shadowWeight(_ t: Double) -> Double {
        let lo = blackAnchorEV
        guard lo < 0 else { return 0 }
        if t >= 0 || t <= lo { return 0 }
        return Num.raisedCosine(sin(.pi * (t / lo)))
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
        var s = zonalStops(t) * zonalScale
        s += contrastMapped(t) - t
        s += zonePanelStops(t)
        return s
    }

    /// Linear multiplier at `t` — what the shader multiplies the pixel by.
    public func gain(at t: Double) -> Double { pow(2, stops(at: t)) }

    /// Bake gain against the shaper's encoded domain: the GPU reads the guided mask,
    /// log-encodes it, and fetches this. One texture fetch replaces the whole panel.
    public func bakeGainLUT(size: Int = 1024) -> LUT1D {
        LUT1D(size: size) { y in
            let lum = LumenLog.decode(y)
            let t = Num.safeLog2(lum / 0.18)
            return gain(at: t)
        }
    }

    /// True when nothing in the tone stack changes a pixel — lets the renderer skip
    /// the stage entirely rather than multiplying by 1.0 across 45 megapixels.
    public var isIdentity: Bool {
        tone.contrast == 0 && tone.highlights == 0 && tone.shadows == 0
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
