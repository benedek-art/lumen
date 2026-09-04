// GradeEngine.swift
// S10 GRADE (docs/14 §2, docs/05 §D15): the creative grading stage — four wheels over
// three VISIBLE tonal zones, plus the color-balance disclosure (chroma / saturation /
// brilliance × zones) that sits under them.
//
// What the spec actually specifies, and what this file therefore implements, is neither
// ASC-CDL (slope/offset/power) nor lift/gamma/gain:
//
//   · a wheel tint is a CONSTANT-LUMINANCE hue/chroma offset — a translation of the
//     OKLab (a, b) pair, weighted by the zone windows. L is not touched, so tinting a
//     zone carries no luminance contamination and a wheel at sat = 0 is an exact no-op.
//   · a wheel's Luminance is a PER-ZONE PERCEPTUAL LIGHTNESS GAIN through Lumen UCS
//     (LumenUCS.scaleBrightness), not a linear multiply — so the move holds the colour's
//     chroma ratio and its H-K corrected brightness reads evenly across hues.
//
// Equivalence note for colorists (a tooltip, not the maths): the shadow-weighted offset
// behaves like lift, the mid-weighted one like gamma, the high-weighted one like gain.
// The difference is that here the zone boundaries are visible, draggable, and shared
// with the tone panel — `ZoneWindows` is built on `ZoneWeights`, the same raised-cosine
// crossfade kernel the six-slider tone stack and the Zones panel use, so "shadows" means
// exactly one thing in this application.
//
// Two placement facts the file depends on:
//   · Printer lights are S6 — three scene-linear multiplies immediately after WB and
//     exposure (docs/05 §D16). They are EXPOSED here as `printerLightGains` because the
//     recipe carries them in the Look subtree, but they are deliberately NOT folded into
//     `apply`; folding them in would move them past S7–S9 and change what they mean.
//   · Zone weights are computed from the STAGE INPUT (docs/14 §5.4 invariant 4) — the
//     `t` handed to `zoneWeights(at:)`/`apply` is the input pixel's tonal position, so
//     grading a zone never moves the zone out from under itself.
//
// The stage does NOT clip to gamut: that is S14's job, on display-normalized values.
// Invariant 3 is satisfied there, once, rather than by every colour tool separately
// running a display-domain operation on unbounded scene-referred data.

import Foundation

// MARK: - Zone windows

/// The two visible pivots of the grading panel, resolved into three weights that sum to
/// exactly 1 at every tonal position.
///
/// Axis: the normalized tonal axis `x = (t − blackAnchorEV) / (whiteAnchorEV − blackAnchorEV)`
/// over `t = log2(luminance / 0.18)` — the axis `ToneEngine.normalizedAxis` defines, so a
/// pivot dragged in the tone panel and a pivot dragged in the grading panel are the same
/// coordinate. `GradingWheels.pivots` is denominated on that normalized axis.
///
/// Shape (docs/05 §D15, one raised-cosine crossfade per pivot):
/// ```
/// w_shadow = 1 − step((x − p_s)/hw)      step = the ZoneWeights crossfade
/// w_high   =     step((x − p_h)/hw)
/// w_mid    = 1 − w_shadow − w_high       ⇒ Σ = 1 exactly
/// ```
/// `hw` is clamped to at most half the pivot separation, which is the invariant that
/// keeps `w_mid ≥ 0` when the two pivots are dragged together.
public struct ZoneWindows: Sendable {

    /// Balance translates BOTH pivots; ±100 = ±this many stops.
    public static let balanceRangeEV: Double = 2.0
    /// Crossfade half-width at Blending = 50 (falloff 0.5 × 3.0 EV) — docs/05 §D15.
    public static let nominalHalfWidthEV: Double = 1.5
    /// Never let a crossfade collapse to a hard edge; that is where banding lives.
    public static let minimumHalfWidthEV: Double = 0.05

    /// Fraction of the half-width ceiling below which Blending is applied exactly.
    /// Same knee as the tone engine, the parametric curve and the Luminance ring.
    public static let blendingKnee: Double = 0.8
    /// Minimum separation between the pivots on the normalized axis.
    public static let minimumPivotGap: Double = 0.02

    /// Shadow/mid boundary on the normalized axis, after Balance.
    public let shadowPivot: Double
    /// Mid/highlight boundary on the normalized axis, after Balance.
    public let highlightPivot: Double
    /// Crossfade half-widths, normalized. Held separately so the per-pivot `falloffs`
    /// field the format is due to gain can drive them independently without a rewrite.
    public let shadowHalfWidth: Double
    public let highlightHalfWidth: Double

    public let whiteAnchorEV: Double
    public let blackAnchorEV: Double
    /// Guaranteed > 0 — every division by the axis span goes through this.
    public let spanEV: Double

    /// Pre-built two-pivot crossfades handed straight to the shared kernel.
    private let shadowCrossfade: [Double]
    private let highlightCrossfade: [Double]

    public init(pivots: [Double] = GradingWheels.defaultPivots,
                blending: Double = 50,
                balance: Double = 0,
                whiteAnchorEV: Double = 5.0,
                blackAnchorEV: Double = -9.0) {
        let hiEV: Double = whiteAnchorEV.isFinite ? whiteAnchorEV : 5.0
        let loEV: Double = blackAnchorEV.isFinite ? blackAnchorEV : -9.0
        let rawSpan: Double = hiEV - loEV
        let span: Double = rawSpan > 1e-3 ? rawSpan : 1.0
        self.whiteAnchorEV = hiEV
        self.blackAnchorEV = loEV
        self.spanEV = span

        var p0: Double = pivots.count >= 2 ? pivots[0] : GradingWheels.defaultPivots[0]
        var p1: Double = pivots.count >= 2 ? pivots[1] : GradingWheels.defaultPivots[1]
        if !p0.isFinite { p0 = GradingWheels.defaultPivots[0] }
        if !p1.isFinite { p1 = GradingWheels.defaultPivots[1] }
        if p1 < p0 {
            let swapped: Double = p0
            p0 = p1
            p1 = swapped
        }
        p0 = Num.saturate(p0)
        p1 = Num.saturate(p1)
        if p1 - p0 < ZoneWindows.minimumPivotGap {
            let centre: Double = (p0 + p1) / 2
            p0 = centre - ZoneWindows.minimumPivotGap / 2
            p1 = centre + ZoneWindows.minimumPivotGap / 2
        }

        let balanceShift: Double =
            (Num.clamp(balance, -100, 100) / 100) * ZoneWindows.balanceRangeEV / span
        let ps: Double = p0 + balanceShift
        let ph: Double = p1 + balanceShift
        self.shadowPivot = ps
        self.highlightPivot = ph

        // Half the separation is the hard ceiling: at it, the two crossfades meet at a
        // point and the mid zone is a single tonal position — never a negative weight.
        let maxHalf: Double = (ph - ps) / 2
        let requested: Double =
            ZoneWindows.nominalHalfWidthEV * (Num.clamp(blending, 0, 100) / 50) / span
        let floorHalf: Double = Swift.min(ZoneWindows.minimumHalfWidthEV / span, maxHalf)
        // Eased onto the ceiling, not clipped at it.
        //
        // `Swift.min(requested, maxHalf)` was a dead control. At the default pivots and
        // anchors the ceiling binds at Blending 79.3, so measured on a colour chart
        // every setting from 80 to 100 rendered BYTE-IDENTICAL — the top fifth of the
        // slider did nothing whatever. The same shape as the Highlights slider's old
        // hard cap, and the parametric curve's, found the same way.
        //
        // The ceiling itself is real and not a taste question: at it the two crossfades
        // meet at a point, and past it the mid zone's weight goes negative. So this
        // approaches it and never reaches it — `softKnee` is exact below
        // `blendingKnee × maxHalf` and asymptotic after, which leaves the mid zone a
        // vanishing but positive sliver at Blending 100 instead of a hard stop at 79.
        let eased: Double = maxHalf > 0
            ? maxHalf * Num.softKnee(requested / maxHalf, knee: ZoneWindows.blendingKnee)
            : 0
        let half: Double = Swift.min(Swift.max(eased, floorHalf), maxHalf)
        self.shadowHalfWidth = half
        self.highlightHalfWidth = half
        self.shadowCrossfade = [ps - half, ps + half]
        self.highlightCrossfade = [ph - half, ph + half]
    }

    /// The windows a `GradingWheels` describes. Per-mask grading passes the GLOBAL
    /// wheels' windows (docs/08 §8.4): a mask gets no tonal-zone definition of its own.
    public init(wheels: GradingWheels,
                whiteAnchorEV: Double = 5.0,
                blackAnchorEV: Double = -9.0) {
        self.init(pivots: wheels.pivots,
                  blending: wheels.blending,
                  balance: wheels.balance,
                  whiteAnchorEV: whiteAnchorEV,
                  blackAnchorEV: blackAnchorEV)
    }

    /// `t = log2(lum/0.18)` → the normalized axis the pivots live on.
    public func normalizedAxis(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return Num.saturate((t - blackAnchorEV) / spanEV)
    }

    /// Where the histogram strip above the wheels draws its draggable handles.
    public var shadowPivotEV: Double { blackAnchorEV + shadowPivot * spanEV }
    public var highlightPivotEV: Double { blackAnchorEV + highlightPivot * spanEV }

    /// Zone weights at a normalized position. Both crossfades are evaluated by
    /// `ZoneWeights` itself — one kernel, so tone zones and grade zones can never drift.
    public func weights(atNormalized x: Double) -> (shadows: Double, mid: Double, high: Double) {
        // Clamp before the kernel: ZoneWeights' pivot search assumes an ordered
        // comparison, which a NaN would defeat.
        let xs: Double = x.isFinite ? Num.saturate(x) : 0
        let s: Double = ZoneWeights.weights(x: xs, pivots: shadowCrossfade)[0]
        let h: Double = ZoneWeights.weights(x: xs, pivots: highlightCrossfade)[1]
        // The half-width clamp makes the two windows disjoint, so this is already ≥ 0;
        // the max() only absorbs float noise at the meeting point.
        let m: Double = Swift.max(0, 1 - s - h)
        return (s, m, h)
    }

    /// Zone weights at tonal position `t = log2(lum/0.18)`.
    public func weights(at t: Double) -> (shadows: Double, mid: Double, high: Double) {
        weights(atNormalized: normalizedAxis(t))
    }
}

// MARK: - Wheel tint

/// One wheel compiled to what the pixel loop actually needs: an OKLab (a, b) translation
/// and a lightness gain in stops. Computed once per engine, never per pixel.
private struct WheelTint: Sendable {
    let a: Double
    let b: Double
    let stops: Double

    var isNeutral: Bool { a == 0 && b == 0 && stops == 0 }

    init(_ wheel: Wheel) {
        let sat: Double = Num.clamp(wheel.sat, 0, 1)
        let lum: Double = Num.clamp(wheel.lum, -1, 1)
        if sat > 0 {
            let radians: Double = Num.wrapHue(wheel.hue) * .pi / 180
            let amplitude: Double = GradeEngine.maxABOffset * sat
            self.a = amplitude * cos(radians)
            self.b = amplitude * sin(radians)
        } else {
            // Exactly zero, not "a very small number": sat = 0 must be a bit-exact no-op.
            self.a = 0
            self.b = 0
        }
        self.stops = GradeEngine.lumRangeStops * lum
    }
}

// MARK: - GradeEngine

public struct GradeEngine: Sendable {

    /// Largest OKLab ab offset a wheel can produce, at sat = 1 (docs/05 §D15).
    /// 0.15 is roughly the chroma of a saturated surface colour — a full-deflection
    /// wheel is a strong grade, not a broken image.
    public static let maxABOffset: Double = 0.15
    /// ±1 on a wheel's Luminance = ±this many stops of PERCEPTUAL BRIGHTNESS — the
    /// H-K brightness J that `LumenUCS.scaleBrightness` scales — NOT stops of light.
    ///
    /// The distinction is load-bearing (docs/31 round two §1). J tracks OKLab L, and on
    /// the neutral axis L is the CUBE ROOT of linear luminance, so a gain of `2^stops`
    /// on J realises `2^(3·stops)` on the light: a full wheel is ±1.5 stops of
    /// luminance. The realised tone response is therefore `1 + 3·scale·slope`, and
    /// `solveLumScale` solves against that 3× slope — solving against the requested
    /// stops alone made the limiter 2.85× too permissive, and Midtones +1 against
    /// Highlights −1 folded the curve while it reported nothing to limit.
    public static let lumRangeStops: Double = 0.5
    /// Stops of scene luminance realised per stop of requested perceptual brightness —
    /// the exponent between J and light on the neutral axis. One name, read by the
    /// wheels' solve and the Colour Balance grid's, so the two limiters cannot disagree
    /// about what a stop is.
    public static let realisedStopsPerJStop: Double = 3.0
    /// One printer-light point = one twelfth-stop, exactly. No hidden negative gamma:
    /// 12 points is 2.0×, bit-comparably (docs/05 §D16).
    public static let pointsPerStop: Double = 12
    /// Wire ranges for printer lights: master ±4 stops, per-channel trims ±2 stops.
    public static let masterPointLimit: Double = 48
    public static let trimPointLimit: Double = 24

    /// The working space is linear Rec.2020 (docs/14 §1.3); the zone axis is driven by
    /// its luminance. Derived from the chromaticities, never a transcribed Rec.709 row —
    /// that substitution is the classic desaturate-on-luminance bug.
    public static let workingLuminanceWeights: RGB = RGBColorSpace.rec2020.luminanceWeights

    public let wheels: GradingWheels
    public let printerLights: PrinterLights
    /// The visible pivots. Exposed so the UI, the per-mask grade and the color-balance
    /// disclosure all read the same zone definition.
    public let windows: ZoneWindows
    public let context: OKLabTransform.Context

    /// The advanced disclosure, built from `wheels.colorBalance` against the SAME
    /// windows the four wheels grade through.
    ///
    /// Held here — rather than left for a caller to construct — because that is what
    /// puts it on the shipping path with no other change: `RenderPlan` bakes
    /// `grade.apply(color.apply(scene))` into the S9+S10 table, `RenderGraph`'s
    /// `LocalPlan` bakes the same call per mask, and both inherited the grid the moment
    /// `apply` started running it. A version that made the grid a separate object for
    /// the renderer to remember to call is how it stayed uncalled for a year.
    public let colorBalance: ColorBalanceGrid

    private let globalTint: WheelTint
    private let shadowTint: WheelTint
    private let midTint: WheelTint
    private let highTint: WheelTint

    /// See `solveLumScale`. The WHEELS' OWN solve, against a full monotonicity budget —
    /// what the Luminance rings would be scaled by if they were the only thing grading
    /// this pixel. What `apply` multiplies by is `lumScale · jointScale`.
    public let lumScale: Double

    /// See `solveJointScale`. 1 — exactly, bit for bit — unless BOTH the wheels'
    /// Luminance and the grid's Brilliance are live, which is what keeps every
    /// single-tool recipe byte-identical.
    public let jointScale: Double

    /// - Parameter forcingJointScale: substitutes a joint factor instead of solving for
    ///   one. **Testing only, and it exists so a claim can be measured rather than
    ///   recorded.**
    ///
    ///   `testEitherSideUntouchedRendersBitIdentically` asserts that a recipe using one of
    ///   the two tools renders exactly as it did before the joint correction existed. That
    ///   was checked against a hash of 71,136 renders written down as a constant — and a
    ///   hash of raw `Double` bit patterns is not portable. The constant was recorded on
    ///   Linux; on Apple Silicon the same code hashes differently, because FMA contraction
    ///   and libm differ, so the test passed `engine-linux` and failed `test-fast` on the
    ///   same commit. The engine was never wrong; the yardstick was.
    ///
    ///   Passing `1` here reconstructs the pre-fix engine exactly — `solveJointScale`'s
    ///   result is the only thing this parameter displaces — so the test can render both
    ///   engines in one process on one machine and compare them to each other. That is
    ///   both portable and a stronger claim than the constant was: it measures the property
    ///   instead of a number somebody transcribed.
    public init(wheels: GradingWheels,
                printerLights: PrinterLights,
                whiteAnchorEV: Double = 5.0,
                blackAnchorEV: Double = -9.0,
                context: OKLabTransform.Context = OKLabTransform.working,
                forcingJointScale: Double? = nil) {
        self.wheels = wheels
        self.printerLights = printerLights
        self.context = context
        self.windows = ZoneWindows(wheels: wheels,
                                   whiteAnchorEV: whiteAnchorEV,
                                   blackAnchorEV: blackAnchorEV)
        let g = WheelTint(wheels.global)
        let sh = WheelTint(wheels.shadows)
        let mid = WheelTint(wheels.mid)
        let hi = WheelTint(wheels.high)
        self.globalTint = g
        self.shadowTint = sh
        self.midTint = mid
        self.highTint = hi
        // The two independent solves first — each against a full budget, exactly as
        // before — then the one correction that knows about both. Solved here, and
        // handed to the grid, rather than left for `ColorBalanceGrid` to work out:
        // the grid can see its own axis and not the wheels above it, and this engine
        // is the only object that holds both.
        let lum = GradeEngine.solveLumScale(
            windows: self.windows, shadows: sh.stops, mid: mid.stops, high: hi.stops)
        let brilliance = ColorBalanceGrid.solveBrillianceScale(
            axis: wheels.colorBalance.brilliance, windows: self.windows)
        let joint = forcingJointScale ?? GradeEngine.solveJointScale(
            windows: self.windows, shadows: sh.stops, mid: mid.stops, high: hi.stops,
            lumScale: lum, brilliance: wheels.colorBalance.brilliance,
            brillianceScale: brilliance)
        self.lumScale = lum
        self.jointScale = joint
        self.colorBalance = ColorBalanceGrid(params: wheels.colorBalance,
                                             windows: self.windows,
                                             context: context,
                                             brillianceScale: brilliance,
                                             jointScale: joint)
    }

    /// What the ZONE-weighted lightness contribution is multiplied by so the grade
    /// cannot invert the tone response. 1 at every default, and at most real settings.
    ///
    /// Each wheel's Luminance is ±0.5 stops, so a shadow wheel at +1 against a
    /// highlight wheel at −1 asks brightness to fall by a full stop across the
    /// crossfade. How steep that fall is depends on the crossfade's WIDTH, and
    /// Blending drives the width: at Blending 0 the half-width collapses to the
    /// 0.05 EV floor, a fall of one stop in a tenth of a stop of input. The composed
    /// slope reached −6.9. A brighter pixel rendered darker than a dimmer one, in
    /// bands, across the whole zone boundary.
    ///
    /// The same failure as the Highlights slider's, and the same solve: everything
    /// else in the response is fixed and the zone term is linear in the scale, so one
    /// pass over the axis gives the largest safe multiplier in closed form. Blending 0
    /// keeps meaning "as hard a crossover as the tone response allows" rather than
    /// "hard enough to fold".
    ///
    /// SOLVED AGAINST THE REALISED SLOPE, `3·slope`, not the requested one — see
    /// `lumRangeStops`. The stops here are gains on UCS brightness J, J tracks OKLab
    /// L, and L cubes back to light, so the tone response the photograph shows is
    /// `1 + 3·scale·slope`. This solve measured `1 + scale·slope` for the wheels'
    /// whole life — 2.85× too permissive — and 345 of 810 sampled wheel combinations
    /// inverted behind its "nothing to limit" (docs/31 round two §1; measured here:
    /// Midtones +1 / Highlights −1 handed back 0.63 EV — about 27 sRGB code values —
    /// across 1.7 stops of midtone).
    static func solveLumScale(windows: ZoneWindows, shadows: Double, mid: Double,
                              high: Double) -> Double {
        guard shadows != 0 || mid != 0 || high != 0 else { return 1 }
        let span = windows.spanEV
        // Step from the narrowest feature, not from a round number. The crossfade
        // half-width shrinks with Blending, and a fixed step walks straight over a
        // narrow one and reports a slope far gentler than the real peak — which is
        // exactly the failure being solved for, so sampling it coarsely produces a
        // scale that still inverts.
        let narrowest = Swift.min(windows.shadowHalfWidth, windows.highlightHalfWidth)
        let step = Num.clamp(narrowest / 8, 1e-4, 0.01)
        let margin = 0.05
        // Unbounded, so a gentle setting reports the cap it is genuinely far below
        // rather than a flat 1. The knee below needs that headroom: clamping here
        // first put every unlimited setting at exactly the knee's engagement point,
        // which made the multiplier step from 1 to 0.918 the instant limiting began.
        var scale = Double.infinity
        var x = 0.0
        while x < 1 {
            let a = Swift.min(x + step, 1)
            func stops(_ position: Double) -> Double {
                let w = windows.weights(atNormalized: position)
                return w.shadows * shadows + w.mid * mid + w.high * high
            }
            // Per EV: the axis is normalized, so one unit of x is `span` stops.
            // REALISED, not requested: the J-stops the wheels ask for come out of the
            // picture three times over (L³ — see `lumRangeStops`), so the slope the
            // monotonicity bound applies to is three times this measurement.
            let slope = (stops(a) - stops(x)) / ((a - x) * span)
                * GradeEngine.realisedStopsPerJStop
            if slope < 0 {
                scale = Swift.min(scale, Swift.max((1 - margin) / -slope, 0))
            }
            x = a
        }
        guard scale.isFinite, scale > 0 else { return 1 }

        // Ease onto the cap rather than clipping at it, for the same reason
        // `ToneEngine` does. The cap is inversely proportional to the wheel deflection,
        // so `deflection × cap` is constant once it binds — and clipping there left the
        // Luminance ring applying ONE identical value over most of its travel. Measured
        // at Blending 0: ±0.20, ±0.50 and ±1.00 all produced 0.060681385, equal to
        // 1e-12. Eighty percent of the control, dead.
        //
        // `1/scale` is the deflection in units of the largest safe one, so easing that
        // and dividing back out gives a multiplier whose PRODUCT with the deflection is
        // strictly increasing. Below the knee it is exactly 1, so ordinary settings are
        // untouched — a fix that quietly weakened every wheel to protect one setting
        // would be its own bug.
        let normalized = 1 / scale
        return Swift.min(Num.softKnee(normalized) / normalized, 1)
    }

    /// What BOTH limiters' zone components are multiplied by ON TOP of their own
    /// solves, so the two tools cannot each spend the whole monotonicity budget on the
    /// same pixel.
    ///
    /// THE DEFECT. `solveLumScale` above and `ColorBalanceGrid.solveBrillianceScale`
    /// below solve the same constraint — `1 + 3·slope ≥ margin`, margin 0.05 — and each
    /// solves it as if it were the only thing grading the frame. So each is permitted
    /// to hand away 0.95 of a base slope of 1. They run on the SAME pixel, over the SAME
    /// crossfades, inside one `apply`, and nothing accounted for both: the composed
    /// realised slope at the mid/highlight crossfade reached −0.883 — exactly
    /// `1 − 0.95 − 0.95` — where each limiter alone left +0.057 and +0.049.
    ///
    /// Measured through `RenderPlan` on a −9…+5 EV grey ramp, wheels mid/high ±1 with
    /// Brilliance mid/high ±100: 53.5 sRGB code values of fold, from two controls that
    /// each fold by 0.0 alone. THE SHARP CASE IS THE GENTLE ONE — wheels ±0.3 with
    /// Brilliance ±15, where BOTH limiters report exactly 1.0 ("nothing to limit"),
    /// folds by 4.4 code values. That is a lone Midtones +0.3, which
    /// `GradeLuminanceInversionTests` calls "nowhere near the monotonicity limit", set
    /// beside a Brilliance inside the panel's own ±20 warning line
    /// (LookPanel.swift:865). Neither existing test could see it: the wheels' sweep
    /// holds colourBalance at zero throughout, and the Brilliance sweep holds every
    /// wheel's `lum` at zero.
    ///
    /// THE COMPOSED RESPONSE, which is what this solves against. On the neutral axis
    /// both moves are multiplicative and both cube back to light (see `lumRangeStops`):
    /// ```
    /// log2 Y_out(t) = t + 3·S(t) + 3·log2 G(t)
    ///   S = zone-weighted wheel J-stops × lumScale × k
    ///   G = max(0, (1 + global/100) + k · brillianceScale · Σ w_z·v_z/100)
    /// ```
    /// so the realised tone slope is `1 + 3·dS/dEV + 3·dlog2G/dEV`, and the bound is
    /// that sum — one constraint over two tools, not one constraint each.
    ///
    /// THE DESIGN CALL — HOW THE BUDGET IS SPLIT. `1 − margin` is the whole fall the
    /// response may absorb per EV. On each sampled interval it is divided between the
    /// two sides IN PROPORTION TO WHAT EACH IS ASKING FOR: with `d_w` and `d_b` the
    /// realised downward slopes the wheels and the grid contribute at their own solved
    /// scales, each side is allowed `(1 − margin)·d/(d_w + d_b)`. Both sides therefore
    /// keep the same FRACTION of the move they asked for, which means the ratio between
    /// the two controls' realised strengths survives the correction — a colorist who
    /// balanced a Luminance ring against a Brilliance row keeps the balance and loses a
    /// little of both, rather than watching one tool get annihilated to protect the
    /// other. The two alternatives were measured and rejected:
    ///
    ///   · "the second solve pays" (fold the wheels' slope into the grid's ratio bound
    ///     and leave `lumScale` alone) is exact and one line shorter, and it is
    ///     arbitrary: it punishes whichever tool this file happens to solve second. A
    ///     Brilliance of +5 beside a full wheel opposition would be scaled to nothing
    ///     for a fold the wheels caused.
    ///   · an equal split (0.475 each) punishes the gentle side hardest — the ±15
    ///     Brilliance in the case above would give up as much as the wheels do.
    ///
    /// Proportional is also the split under which a SINGLE shared factor is the honest
    /// implementation, which is why this returns one number: scaling both sides by the
    /// same `k` shrinks each side's contribution by that factor, so each gives up an
    /// amount proportional to its own demand. Exactly so for the wheels, whose slope is
    /// linear in the scale; for the grid the factor is solved from the ratio bound
    /// rather than assumed, because `log2 G` is not linear in it.
    ///
    /// SOLVED, NOT SEARCHED, for the reason `solveBrillianceScale` is: the constraint
    /// is affine in the scale even where the response is not. Per interval:
    ///
    ///   · the wheels reach their share at exactly `k = (1 − margin)/(d_w + d_b)`;
    ///   · the grid reaches its share when `G_i ≥ ρ·G_(i−1)` with
    ///     `ρ = 2^(−share·d_b·ΔEV/3)`, one division away in closed form.
    ///
    /// The per-interval factor is the smaller of the two, and — like both siblings —
    /// it is left UNBOUNDED above so a combined setting that is genuinely far from the
    /// limit reports how far, and the knee below returns exactly 1 for it instead of
    /// stepping to 0.918 the instant a second control is touched.
    ///
    /// NEITHER SIDE CAN ALREADY BE OVER ITS OWN BUDGET, which is what makes the split
    /// safe to compute from the demands rather than iterated: `solveLumScale` has
    /// already guaranteed `d_w ≤ 1 − margin` on every one of these intervals (they are
    /// its own samples), and `solveBrillianceScale` the same for `d_b`. So the factor
    /// only falls below 1 when BOTH sides are falling on the same interval, and no
    /// interval where one side is rising is ever limited by counting headroom that
    /// would shrink with `k`.
    static func solveJointScale(windows: ZoneWindows,
                                shadows: Double, mid: Double, high: Double,
                                lumScale: Double,
                                brilliance: ColorBalanceAxis,
                                brillianceScale: Double) -> Double {
        // THE PROPERTY THAT BOUNDS THIS CHANGE: either side untouched ⇒ exactly 1, so
        // every recipe that uses one of the two tools renders bit-identically to what
        // it rendered before this solve existed (`x * 1.0 == x` in IEEE 754, for every
        // finite x). Only recipes that use BOTH can move.
        guard shadows != 0 || mid != 0 || high != 0 else { return 1 }
        let bShadows: Double = Num.clamp(brilliance.shadows, -100, 100)
        let bMid: Double = Num.clamp(brilliance.mid, -100, 100)
        let bHigh: Double = Num.clamp(brilliance.high, -100, 100)
        guard bShadows != 0 || bMid != 0 || bHigh != 0 else { return 1 }
        guard lumScale > 0, brillianceScale > 0 else { return 1 }
        // Where the grid's gain sits with no zone term. At Global −100 it is zero, the
        // gain becomes a pure multiple of the zone term and the RATIO between two
        // samples stops depending on any scale at all — there is no multiplier that
        // changes the grid's shape, so there is nothing joint to solve.
        // `solveBrillianceScale` bails on the same condition for the same reason.
        //
        // MEASURED, because bailing here could have been hiding this defect rather
        // than declining a fix that does not exist: Brilliance Global −100 with
        // Midtones +100 / Highlights −100 folds by 84.18 sRGB code values WITH NO
        // WHEELS AT ALL, and by 112.69 with a full wheel opposition beside it. The
        // first number is `solveBrillianceScale`'s own hole and predates this solve —
        // at Global −100 the gain is a multiple of a zone term that crosses zero, so
        // the picture goes out and no multiplier moves the crossing. Limiting the
        // WHEELS there would buy nothing: the fold the grid causes survives the wheels
        // going to zero, so the only thing a joint correction could do on this setting
        // is weaken a control for a fold it did not cause.
        let rest: Double = 1 + Num.clamp(brilliance.global, -100, 100) / 100
        guard rest > 0 else { return 1 }

        let span: Double = windows.spanEV
        // The same step both siblings take, from the narrowest feature rather than a
        // round number — and the same one, so this reads the wheels' own intervals
        // rather than a third grid that could walk over the crossfade they measured.
        let narrowest: Double = Swift.min(windows.shadowHalfWidth,
                                          windows.highlightHalfWidth)
        let step: Double = Num.clamp(narrowest / 8, 1e-4, 0.01)
        let margin: Double = 0.05
        let blackGain: Double = pow(2.0, ColorBalanceGrid.blackFloorEV)

        // BOTH profiles on ONE sampling of the axis. The whole defect is that the two
        // solves each measured this crossfade on a grid of their own and neither added
        // the two answers up.
        var positions: [Double] = [0]
        var x: Double = 0
        while x < 1 {
            x = Swift.min(x + step, 1)
            positions.append(x)
        }
        var wheelStops: [Double] = []
        var gridZone: [Double] = []
        wheelStops.reserveCapacity(positions.count)
        gridZone.reserveCapacity(positions.count)
        for p in positions {
            let w = windows.weights(atNormalized: p)
            // The wheels' zone-weighted J-stops, at the scale their own solve chose.
            wheelStops.append((w.shadows * shadows + w.mid * mid + w.high * high)
                * lumScale)
            // The grid's zone term, at the scale its own solve chose — so the gain at
            // joint factor k is `rest + k · gridZone`.
            gridZone.append((w.shadows * bShadows + w.mid * bMid + w.high * bHigh)
                / 100 * brillianceScale)
        }

        var cap: Double = .infinity
        for i in 1..<positions.count {
            let deltaEV: Double = (positions[i] - positions[i - 1]) * span
            guard deltaEV > 0 else { continue }
            // Realised slopes per EV at the two solved scales — the 3× of
            // `realisedStopsPerJStop` on both sides, because both scale a perceptual
            // brightness that cubes back to light.
            let wheelSlope: Double = GradeEngine.realisedStopsPerJStop
                * (wheelStops[i] - wheelStops[i - 1]) / deltaEV
            let from: Double = rest + gridZone[i - 1]
            let to: Double = rest + gridZone[i]
            // A sample already at black carries no slope information — the crush rule
            // of `solveBrillianceScale`, read here off the gain rather than the log.
            let gridSlope: Double = from <= blackGain ? 0
                : GradeEngine.realisedStopsPerJStop
                    * (Num.safeLog2(Swift.max(to, 0)) - Num.safeLog2(from)) / deltaEV
            let demandWheels: Double = Swift.max(0, -wheelSlope)
            let demandGrid: Double = Swift.max(0, -gridSlope)
            let demand: Double = demandWheels + demandGrid
            guard demand > 0 else { continue }
            // The proportional split, as one number: the factor at which the wheels
            // reach their share is `budget/demand` whatever the shares are, because
            // the share is `demand_w/demand` of a budget the slope is linear in.
            let share: Double = (1 - margin) / demand

            var folds: Double = demandWheels > 0 ? share : .infinity
            if demandGrid > 0 {
                // The grid's own share, as the steepest gain ratio one interval may
                // carry: `3·log2(G_i/G_(i−1))/ΔEV ≥ −share·d_b`.
                let ratio: Double = pow(2.0, -share * demandGrid * deltaEV
                    / GradeEngine.realisedStopsPerJStop)
                // `G_i ≥ ρ·G_(i−1)` with both gains affine in k:
                // `rest·(1 − ρ) + k·(z_i − ρ·z_(i−1)) ≥ 0`.
                let fall: Double = ratio * gridZone[i - 1] - gridZone[i]
                if fall > 0 {
                    folds = Swift.min(folds, rest * (1 - ratio) / fall)
                }
            }
            guard folds.isFinite else { continue }
            // …unless the grid has taken the sample this interval falls FROM to black
            // by the factor in question, in which case nothing renders there and the
            // fall takes nothing with it. `solveBrillianceScale`'s guard, evaluated at
            // the same place: the candidate factor.
            guard rest + folds * gridZone[i - 1] > blackGain else { continue }
            cap = Swift.min(cap, folds)
        }
        guard cap.isFinite, cap > 0 else { return 1 }
        // Eased onto, not clipped at — the third use of the one knee, so a pair of
        // controls approaching the joint limit keeps doing more over its travel
        // instead of hitting a dead band, and a pair well below it is exactly 1.
        let normalized: Double = 1 / cap
        return Swift.min(Num.softKnee(normalized) / normalized, 1)
    }

    // MARK: Zones

    /// Zone weights at tonal position `t = log2(lum/0.18)`. Public because the pivots
    /// are a VISIBLE control: the histogram strip draws these curves and the handles the
    /// user drags, and the per-zone mask preview shades by them.
    public func zoneWeights(at t: Double) -> (shadows: Double, mid: Double, high: Double) {
        windows.weights(at: t)
    }

    /// The tonal position of a scene-linear colour: `t = log2(luminance / 0.18)`.
    /// Guarded at the bottom by `Num.safeLog2`, so black and the small negatives
    /// scene-referred data legitimately carries land at the floor instead of −∞.
    public func tonalAxis(of c: RGB) -> Double {
        let w: RGB = GradeEngine.workingLuminanceWeights
        let y: Double = w.r * c.r + w.g * c.g + w.b * c.b
        return Num.safeLog2(y / LumenLog.midGrey)
    }

    // MARK: Printer lights (S6, exposed not applied)

    /// Per-channel scene-linear gains, `2^(points/12)` with the master added to all
    /// three. Stage S6 multiplies by this immediately after WB + exposure; it is NOT
    /// part of `apply`, because applying it here would put it downstream of tone and
    /// colour and it would stop being a printer light.
    public var printerLightGains: RGB {
        let master: Double = Num.clamp(Double(printerLights.master),
                                       -GradeEngine.masterPointLimit,
                                       GradeEngine.masterPointLimit)
        let r: Double = Num.clamp(Double(printerLights.r),
                                  -GradeEngine.trimPointLimit, GradeEngine.trimPointLimit)
        let g: Double = Num.clamp(Double(printerLights.g),
                                  -GradeEngine.trimPointLimit, GradeEngine.trimPointLimit)
        let b: Double = Num.clamp(Double(printerLights.b),
                                  -GradeEngine.trimPointLimit, GradeEngine.trimPointLimit)
        let s: Double = GradeEngine.pointsPerStop
        return RGB(pow(2.0, (master + r) / s),
                   pow(2.0, (master + g) / s),
                   pow(2.0, (master + b) / s))
    }

    // MARK: Identity

    /// True when the four wheels AND the advanced grid are all at rest, which lets the
    /// renderer skip the stage entirely rather than round-tripping 45 megapixels through
    /// OKLab for nothing. Printer lights are not consulted: they are a different stage.
    ///
    /// The grid belongs in this test for the same reason `pointColors` belongs in
    /// `LocalPlan`'s: `RenderPlan` swaps a two-point identity cube in when this is true,
    /// so a grade whose only move is +40 Brilliance would have declared itself a no-op
    /// and rendered its input.
    public var isIdentity: Bool {
        globalTint.isNeutral && shadowTint.isNeutral && midTint.isNeutral
            && highTint.isNeutral && colorBalance.isIdentity
    }

    // MARK: Apply

    /// The wheels and the advanced grid, at one pixel. Zone weights come from the INPUT
    /// pixel's tonal position (invariant 4), the tint is a constant-luminance
    /// translation in OKLab, the lightness move is a perceptual gain in UCS, and the
    /// stage closes on the no gamut clip — see below.
    ///
    /// Order: wheels first, grid second, exactly as the panel stacks them — the grid is
    /// the disclosure that opens BELOW the wheels, and reading the panel top to bottom
    /// has to be reading the pixel's history. Both read `t` from the same stage-input
    /// measurement, so opening the disclosure never moves the zones the wheels are
    /// already grading against.
    public func apply(_ c: RGB) -> RGB {
        guard !isIdentity else { return c }
        guard c.isFinite else { return c }

        let t: Double = tonalAxis(of: c)
        let w: (shadows: Double, mid: Double, high: Double) = zoneWeights(at: t)

        let da: Double = globalTint.a
            + w.shadows * shadowTint.a + w.mid * midTint.a + w.high * highTint.a
        let db: Double = globalTint.b
            + w.shadows * shadowTint.b + w.mid * midTint.b + w.high * highTint.b
        // Global rides on top of the partition and contributes no slope, so it is
        // outside the monotonicity scale; the zone-weighted part is inside it.
        //
        // TWO scales, not one: the wheels' own solve, and the joint correction that is
        // the only thing in this file that knows the Brilliance row below is grading
        // the same crossfade (`solveJointScale`). `jointScale` is exactly 1 unless
        // both are live, so this is the same product it always was for a recipe that
        // uses one of them.
        let zoned: Double = (w.shadows * shadowTint.stops + w.mid * midTint.stops
            + w.high * highTint.stops) * lumScale * jointScale
        let stops: Double = Num.clamp(globalTint.stops + zoned, -2, 2)

        var out: RGB = c

        // Tint: (a, b) translation at constant L. No chroma-to-luminance leakage, and
        // an all-zero offset never enters the round trip at all.
        if da != 0 || db != 0 {
            var lab: OKLab = context.toLab(c)
            lab.a += da
            lab.b += db
            out = context.toRGB(lab)
        }

        // Luminance: a perceptual lightness gain through Lumen UCS, which holds the
        // colour's chroma RATIO (invariant 1) instead of washing it out the way a
        // linear multiply through a display-referred curve does.
        if stops != 0 {
            out = LumenUCS.scaleBrightness(out, by: pow(2.0, stops), context: context)
        }

        // The advanced disclosure: master hue rotation and vibrance, then
        // chroma / saturation / brilliance spread over the same three zones. `t` is the
        // STAGE-INPUT tonal position, which is why the grid takes it as an argument
        // rather than measuring it off `out` — a Brilliance push that re-measured its
        // own zone would walk the pixel up the tonal axis and out of the window that
        // selected it.
        if !colorBalance.isIdentity {
            out = colorBalance.apply(out, at: t)
        }

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
}

// MARK: - Color balance parameters

/// One control of the advanced disclosure, spread over the grade's zones.
/// Every field −100…+100, default 0; `global` rides on top of the partition rather
/// than being part of it, exactly like the Global wheel.
public struct ColorBalanceAxis: Codable, Equatable, Sendable {
    public var global: Double
    public var shadows: Double
    public var mid: Double
    public var high: Double

    public init(global: Double = 0, shadows: Double = 0, mid: Double = 0, high: Double = 0) {
        self.global = global
        self.shadows = shadows
        self.mid = mid
        self.high = high
    }

    public var isZero: Bool { global == 0 && shadows == 0 && mid == 0 && high == 0 }

    /// This axis at a fraction of its strength — what a mask's Amount does to it.
    /// Every field is a MAGNITUDE in percent, so all four scale.
    public func scaled(by scale: Double) -> ColorBalanceAxis {
        ColorBalanceAxis(global: global * scale, shadows: shadows * scale,
                         mid: mid * scale, high: high * scale)
    }

    private enum CodingKeys: String, CodingKey {
        case global, shadows, mid, high
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.global = try c.decodeIfPresent(Double.self, forKey: .global) ?? 0
        self.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        self.mid = try c.decodeIfPresent(Double.self, forKey: .mid) ?? 0
        self.high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 0
    }
}

/// The chroma / saturation / brilliance × (global, shadows, mid, high) grid that opens
/// below the four wheels — one disclosure of the grade panel, never a second tool (D3).
///
/// It lives on the wire as `look.wheels.colorBalance` (and inside a mask's own grade,
/// via `LocalAdjust.wheels`), which is the reason it is on `GradingWheels` rather than
/// beside it: the grid grades against the SAME visible pivots as the wheels, so a format
/// that could carry one without the other would be a format that can describe a grid
/// with no zones. Every field defaults to zero, so the sparse serializer prunes the
/// whole subtree out of an untouched recipe and adding it changed no fingerprint.
///
/// This struct and `ColorBalanceGrid` below were written, tested and referenced by
/// NOTHING for the whole of the project's life — roughly 180 lines of correct H-K
/// quadratic solves with no wire format, no panel and no stage. The cost was not the
/// dead code; it was that docs/05's headline claim over Lightroom ("the advanced grid
/// simply has no LR equivalent") was false in the shipping build.
public struct ColorBalanceParams: Codable, Equatable, Sendable {

    /// Master hue rotation, −180…+180 degrees, at constant lightness and chroma.
    public var hueShift: Double
    /// Master vibrance, −100…+100: a chroma move weighted toward LOW-chroma colours,
    /// so already-saturated colour resists further push.
    public var vibrance: Double

    /// Colourfulness at constant lightness and hue. −100 ⇒ neutral, +100 ⇒ 2×.
    public var chroma: ColorBalanceAxis
    /// The colourfulness/lightness RATIO, at constant H-K corrected brightness — the
    /// move that does not make saturated blues look like they dimmed.
    public var saturation: ColorBalanceAxis
    /// H-K corrected brightness at constant ratio: exposure-like, perceptually scaled.
    /// The UI shows a soft warning past ±20 — beyond that is artifact territory.
    public var brilliance: ColorBalanceAxis

    public init(hueShift: Double = 0,
                vibrance: Double = 0,
                chroma: ColorBalanceAxis = ColorBalanceAxis(),
                saturation: ColorBalanceAxis = ColorBalanceAxis(),
                brilliance: ColorBalanceAxis = ColorBalanceAxis()) {
        self.hueShift = hueShift
        self.vibrance = vibrance
        self.chroma = chroma
        self.saturation = saturation
        self.brilliance = brilliance
    }

    /// True when every control in the disclosure is at rest. Read by
    /// `GradingWheels.isNeutral` — which is what `LocalPlan` and the panel's "modified"
    /// dot consult — so a recipe whose only grade is a grid move is NOT identity and
    /// still gets a table baked for it.
    public var isZero: Bool {
        hueShift == 0 && vibrance == 0
            && chroma.isZero && saturation.isZero && brilliance.isZero
    }

    /// The grid at a fraction of its strength — a mask's Amount, applied.
    ///
    /// `hueShift` scales here even though `Wheel.hue` deliberately does not, and the
    /// difference is not an inconsistency: a wheel's hue is the DIRECTION of a tint
    /// whose magnitude is `sat`, so scaling it rotates the grade instead of weakening
    /// it. This hue shift is itself the magnitude — rotating by 0° is the identity — so
    /// half a mask must be half the rotation.
    public func scaled(by scale: Double) -> ColorBalanceParams {
        ColorBalanceParams(hueShift: hueShift * scale,
                           vibrance: vibrance * scale,
                           chroma: chroma.scaled(by: scale),
                           saturation: saturation.scaled(by: scale),
                           brilliance: brilliance.scaled(by: scale))
    }

    private enum CodingKeys: String, CodingKey {
        case hueShift, vibrance, chroma, saturation, brilliance
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        self.vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        self.chroma = try c.decodeIfPresent(ColorBalanceAxis.self, forKey: .chroma)
            ?? ColorBalanceAxis()
        self.saturation = try c.decodeIfPresent(ColorBalanceAxis.self, forKey: .saturation)
            ?? ColorBalanceAxis()
        self.brilliance = try c.decodeIfPresent(ColorBalanceAxis.self, forKey: .brilliance)
            ?? ColorBalanceAxis()
    }
}

// MARK: - ColorBalanceGrid

/// The advanced disclosure's engine, in the H-K aware UCS.
///
/// Three orthogonal handles on one point, separated exactly as docs/05 §D15 separates
/// them. Writing `L` for UCS lightness, `C` for chroma and `B` for the Helmholtz–
/// Kohlrausch corrected brightness that `LumenUCS` computes as `B = L · f(C, h)`:
/// ```
/// chroma      C' = C · g          L, h held        (colourfulness at fixed lightness)
/// saturation  s  = C / L          s' = s · g       solve L' from B(L', s'·L') = B
/// brilliance  B' = B · g          s held           L and C scale together along the ray
/// ```
/// `f` is affine in chroma — `HelmholtzKohlrausch.brightnessFactor` is `1 + m(h)·C` —
/// so both solves are one quadratic, not an iteration. `m(h)` is read out of that same
/// function's coefficients, so the two can never disagree about what brightness means.
///
/// This is why the three read as three different intents rather than three volumes of
/// the same one: a naive HSL model would collapse them into a single chroma multiply.
public struct ColorBalanceGrid: Sendable {

    /// Low-chroma prioritization for Vibrance: full effect below this chroma…
    public static let vibranceLowChroma: Double = 0.05
    /// …and none above this one.
    public static let vibranceHighChroma: Double = 0.25

    public let params: ColorBalanceParams
    /// The grid grades against the SAME visible pivots as the wheels above it.
    public let windows: ZoneWindows
    public let context: OKLabTransform.Context


    /// See `solveBrillianceScale`. The GRID'S OWN solve, against a full monotonicity
    /// budget — what Brilliance would be scaled by if it were the only thing grading
    /// this pixel. What `apply` multiplies the zone components by is
    /// `brillianceScale · jointScale`.
    public let brillianceScale: Double

    /// See `GradeEngine.solveJointScale`. 1 — exactly — unless the wheels' Luminance
    /// is live too; the grid cannot see the wheels above it, so the engine that holds
    /// both solves this and hands it down.
    public let jointScale: Double

    /// What the Brilliance zone components are actually multiplied by.
    public var appliedBrillianceScale: Double { brillianceScale * jointScale }

    public init(params: ColorBalanceParams = ColorBalanceParams(),
                windows: ZoneWindows = ZoneWindows(),
                context: OKLabTransform.Context = OKLabTransform.working) {
        self.init(params: params, windows: windows, context: context,
                  brillianceScale: ColorBalanceGrid.solveBrillianceScale(
                    axis: params.brilliance, windows: windows),
                  jointScale: 1)
    }

    /// The grid with both solves handed in. `GradeEngine` uses this because it has
    /// already run `solveBrillianceScale` — the joint solve needs its answer as an
    /// input — and running it a second time here would be the same loop over the same
    /// crossfade for the same number.
    init(params: ColorBalanceParams,
         windows: ZoneWindows,
         context: OKLabTransform.Context,
         brillianceScale: Double,
         jointScale: Double) {
        self.params = params
        self.windows = windows
        self.context = context
        self.brillianceScale = brillianceScale
        self.jointScale = jointScale
    }

    /// True when every control in the disclosure is at rest.
    public var isIdentity: Bool { params.isZero }

    /// Slope of the H-K brightness factor in chroma: `brightnessFactor(C, h) = 1 + m·C`
    /// for `C ≥ 0`. Kept as a derivation of Perceptual.swift's own coefficients rather
    /// than a second copy of them.
    private static func hkSlope(hue: Double) -> Double {
        0.4 * (-0.1340 * HelmholtzKohlrausch.q(hueDegrees: hue)
               + 0.0872 * HelmholtzKohlrausch.kBr)
    }

    /// Per-zone gain: `1 + (global + zoneScale · Σ w_z · v_z)/100`, floored at 0 so
    /// −100 lands on a true neutral and cannot go through it into negative chroma.
    ///
    /// `zoneScale` is the Brilliance monotonicity limit — the grid's own solve times
    /// the joint correction, 1 for every other axis — and applied to the ZONE
    /// components only: global rides on top of the partition and contributes no slope,
    /// exactly as the Global wheel sits outside `lumScale`.
    private static func gain(_ axis: ColorBalanceAxis,
                             _ w: (shadows: Double, mid: Double, high: Double),
                             zoneScale: Double = 1) -> Double {
        let zoned: Double = w.shadows * Num.clamp(axis.shadows, -100, 100)
            + w.mid * Num.clamp(axis.mid, -100, 100)
            + w.high * Num.clamp(axis.high, -100, 100)
        let sum: Double = Num.clamp(axis.global, -100, 100) + zoneScale * zoned
        return Swift.max(0, 1 + sum / 100)
    }

    /// `Num.safeLog2`'s own floor, in stops. A gain at or below `2^this` is BLACK
    /// rather than small: three stops of light below it is 2^−60, and every log in this
    /// file already reads it as the floor value rather than as a number. Named here
    /// because `solveBrillianceScale` has to decide what "already black" means, and it
    /// must mean the same thing there as it does in the logs it replaced.
    static let blackFloorEV: Double = -20

    /// What Brilliance's ZONE components are multiplied by so the grid cannot invert
    /// the tone response — the grid's own copy of `GradeEngine.solveLumScale`'s rule,
    /// which the wheels have had since the Blending-0 fold and this disclosure never
    /// did (docs/31 round two §1: "`ColorBalanceGrid` has no limiter at all").
    ///
    /// Brilliance scales the H-K brightness `B`, and B — like the wheels' J — cubes
    /// back to light, so the realised tone response of a per-zone gain `G(x)` is
    /// `1 + 3·d(log2 G)/dEV`.
    ///
    /// SOLVED, NOT SEARCHED — which is the fix for B2-01. The response is not linear in
    /// the scale (`G` sits inside a log), and this function used to conclude from that
    /// that the largest safe multiplier had to be found by bisection. The RESPONSE is
    /// not linear in the scale; the CONSTRAINT is. Writing `c = 1 + global` and `z_i`
    /// for the zone-weighted term at sample `i`, the gain is `G_i = max(0, c + s·z_i)`,
    /// and the monotonicity bound
    ///
    ///     1 + 3·(log2 G_i − log2 G_(i−1))/ΔEV ≥ margin
    ///
    /// is a RATIO bound between two quantities each affine in `s`:
    ///
    ///     G_i ≥ ρ·G_(i−1),  ρ = 2^((margin − 1)·ΔEV/3)
    ///     ⟺ c·(1 − ρ) + s·(z_i − ρ·z_(i−1)) ≥ 0
    ///
    /// — one division per sampled interval for the exact scale at which that interval
    /// first folds, and no search over `s` at all.
    ///
    /// THE SEARCH IS WHAT WAS BROKEN, and a wider one would not have fixed it: the
    /// predicate it searched is not monotone in `s`. Push the scale far enough and
    /// every sample hits the gain floor at zero, the sampled profile goes flat, and a
    /// flat profile reads as monotone — so the old test at the 64× ceiling reported
    /// "nothing to limit" on exactly the settings that fold hardest, and the bisection
    /// under it was left with no bracket to close on. Measured over shadows/mid/high ∈
    /// {−100, −50, 0, +50, +100}: 12 of 125 combinations ran the tone scale backwards
    /// at EVERY Blending, the shipped 50 included, while this function handed back 1.
    /// Brilliance −50 / −50 / −100 was brightest at −0.71 EV and pure black by
    /// +1.88 EV: 28.5 sRGB code values of reversal, with the highlights rendering BELOW
    /// the midtones.
    ///
    /// WHAT MONOTONE HAS TO MEAN ONCE A GAIN HAS FLOORED, which is the question the old
    /// predicate answered wrongly. A flat run of zero gain is not evidence about the
    /// composed curve; it is the picture already at black. Read off
    /// `Y = 0.18·2^t·G³` rather than off the profile:
    ///
    ///   · black → black and black → lit are both legitimate. A crush at the bottom of
    ///     the scale is what Brilliance −100 on the shadows IS, and nothing there
    ///     renders darker than anything below it.
    ///   · lit → black is the steepest fall there is, never a plateau. That is the
    ///     highlights going out while the midtones still render.
    ///
    /// So an interval is bound only while the sample it falls FROM is still lit. The
    /// ratio bound already forbids reaching zero from a lit sample (`ρ > 0`), so the
    /// two collapse into one test: take the interval's own fold scale, and ignore it if
    /// the gain it falls from has itself reached black by then. That is the whole of
    /// the special case, and it leaves the one genuinely flat setting — every zone at
    /// −100, the whole frame crushed together — exactly unlimited, as it already was.
    ///
    /// Measured before the limiter existed, at the shipped defaults: Brilliance
    /// Highlights −100 walks its gain to zero across the crossfade — 87 sRGB code
    /// values of reversal over 2.6 EV — and Midtones +100 / Highlights −100 reverses
    /// by 227 code values. Chroma and Saturation are untouched: both hold perceived
    /// brightness by construction, so neither can fold the curve.
    ///
    /// Same knee as the wheels': the cap is eased onto, not clipped at, so the axis
    /// keeps doing more over its whole travel; below the knee ordinary settings (the
    /// panel's documented ±20 working range included) are exactly unlimited.
    static func solveBrillianceScale(axis: ColorBalanceAxis,
                                     windows: ZoneWindows) -> Double {
        guard axis.shadows != 0 || axis.mid != 0 || axis.high != 0 else { return 1 }
        let span: Double = windows.spanEV
        let global: Double = Num.clamp(axis.global, -100, 100) / 100
        // What the gain is where the zone term contributes nothing. At Global −100 it
        // is zero, the gain becomes a pure multiple of the zone term, and the ratio
        // between any two samples stops depending on the scale at all — there is no
        // multiplier that changes the shape, so there is nothing to solve.
        let rest: Double = 1 + global
        guard rest > 0 else { return 1 }
        // Step from the narrowest feature, for `solveLumScale`'s reason: a fixed step
        // walks straight over a hard crossfade and reports a slope far gentler than
        // the real peak.
        let narrowest: Double = Swift.min(windows.shadowHalfWidth,
                                          windows.highlightHalfWidth)
        let step: Double = Num.clamp(narrowest / 8, 1e-4, 0.01)
        // The zone-weighted term, sampled once; the solve below reads the samples in
        // adjacent pairs.
        var zoned: [Double] = []
        var x: Double = 0
        while x < 1 {
            let w = windows.weights(atNormalized: x)
            zoned.append((w.shadows * Num.clamp(axis.shadows, -100, 100)
                + w.mid * Num.clamp(axis.mid, -100, 100)
                + w.high * Num.clamp(axis.high, -100, 100)) / 100)
            x += step
        }
        let wEnd = windows.weights(atNormalized: 1)
        zoned.append((wEnd.shadows * Num.clamp(axis.shadows, -100, 100)
            + wEnd.mid * Num.clamp(axis.mid, -100, 100)
            + wEnd.high * Num.clamp(axis.high, -100, 100)) / 100)

        let margin: Double = 0.05
        // The steepest fall one sampled interval may carry, as a ratio of gains: the
        // composed bound `1 + 3·Δlog2(G)/ΔEV ≥ margin`, rearranged.
        let ratio: Double = pow(2.0, (margin - 1) * (step * span)
            / GradeEngine.realisedStopsPerJStop)
        let blackGain: Double = pow(2.0, ColorBalanceGrid.blackFloorEV)

        // The smallest scale at which any interval folds. Unbounded above, for
        // `solveLumScale`'s reason: the knee needs to know how far below the cap a
        // gentle setting sits, or every unlimited setting lands exactly at the knee's
        // engagement point.
        var cap: Double = .infinity
        for i in 1..<zoned.count {
            let previous: Double = zoned[i - 1]
            let fall: Double = ratio * previous - zoned[i]
            // Nothing to bound: this interval holds the ratio at every scale, however
            // far the axis is pushed. Flat and rising intervals land here.
            guard fall > 0 else { continue }
            // The scale at which this interval first breaks it…
            let folds: Double = rest * (1 - ratio) / fall
            // …unless the gain it falls FROM has itself reached black by then, in
            // which case the fall takes nothing with it. A crush, not an inversion.
            guard rest + folds * previous > blackGain else { continue }
            cap = Swift.min(cap, folds)
        }
        guard cap.isFinite, cap > 0 else { return 1 }
        // Ease onto the cap exactly as `solveLumScale` does, so the axis's realised
        // strength keeps growing over its travel instead of clipping into a dead band.
        let normalized: Double = 1 / cap
        return Swift.min(Num.softKnee(normalized) / normalized, 1)
    }

    /// The disclosure, at one pixel, at tonal position `t = log2(lum/0.18)`.
    /// `t` is passed in rather than measured here so the caller can hand over the
    /// STAGE-INPUT position — the same rule the wheels follow (invariant 4).
    public func apply(_ c: RGB, at t: Double) -> RGB {
        guard !isIdentity else { return c }
        guard c.isFinite else { return c }

        let w: (shadows: Double, mid: Double, high: Double) = windows.weights(at: t)
        let lch: OKLCh = context.toLCh(c)

        var L: Double = lch.L
        var C: Double = Swift.max(0, lch.C)
        var h: Double = lch.h

        // Master hue rotation, at constant lightness and chroma.
        if params.hueShift != 0 {
            h = Num.wrapHue(h + Num.clamp(params.hueShift, -180, 180))
        }

        // The H-K slope is a function of hue only, so it is fixed for the rest of this
        // pixel once the rotation has happened.
        let m: Double = ColorBalanceGrid.hkSlope(hue: h)

        // Chroma: colourfulness at constant lightness and hue.
        if !params.chroma.isZero {
            C = Swift.max(0, C * ColorBalanceGrid.gain(params.chroma, w))
        }

        // Vibrance: the same kind of move, weighted toward low-chroma colour so skies
        // and skin gain before an already-red dress does.
        if params.vibrance != 0 {
            let low: Double = 1 - Num.smoothstep(ColorBalanceGrid.vibranceLowChroma,
                                                 ColorBalanceGrid.vibranceHighChroma, C)
            let v: Double = Num.clamp(params.vibrance, -100, 100) / 100
            C = Swift.max(0, C * Swift.max(0, 1 + v * low))
        }

        // Saturation: scale the C/L ratio, then restore the H-K brightness the colour
        // had before the move. B = L·(1 + m·C) ⇒ m·s'·L'² + L' − B = 0.
        if !params.saturation.isZero, L > 1e-6 {
            let brightness: Double = L * (1 + m * C)
            let s: Double = (C / L) * ColorBalanceGrid.gain(params.saturation, w)
            let k: Double = m * s
            var newL: Double = brightness
            if abs(k) > 1e-12 {
                let disc: Double = 1 + 4 * k * brightness
                if disc >= 0 {
                    newL = (-1 + disc.squareRoot()) / (2 * k)
                }
            }
            if newL.isFinite, newL > 0 {
                L = newL
                C = Swift.max(0, s * newL)
            }
        }

        // Brilliance: scale the H-K brightness at constant ratio — L and C ride the same
        // ray. (m·L·C)·k² + L·k − B·g = 0 in the common scale factor k.
        // The zone components ride `appliedBrillianceScale` — the grid's own solve
        // times the joint correction — so a per-zone brightness gain cannot fold the
        // tone response across a crossfade, alone (`solveBrillianceScale`) or against
        // the Luminance rings grading the same crossfade above it
        // (`GradeEngine.solveJointScale`). Chroma and Saturation above hold perceived
        // brightness by construction and need no limiter.
        if !params.brilliance.isZero, L > 1e-6 {
            let brightness: Double = L * (1 + m * C)
            let target: Double = brightness * ColorBalanceGrid.gain(
                params.brilliance, w, zoneScale: appliedBrillianceScale)
            let quad: Double = m * L * C
            var k: Double = target / L
            if abs(quad) > 1e-12 {
                let disc: Double = L * L + 4 * quad * target
                if disc >= 0 {
                    k = (-L + disc.squareRoot()) / (2 * quad)
                }
            }
            if k.isFinite, k >= 0 {
                L = Swift.max(0, L * k)
                C = Swift.max(0, C * k)
            }
        }

        let out: RGB = context.toRGB(OKLCh(L: L, C: C, h: h))
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
}
