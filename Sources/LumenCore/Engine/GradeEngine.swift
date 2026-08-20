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
        let half: Double = Swift.min(Swift.max(requested, floorHalf), maxHalf)
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
    /// ±1 on a wheel's Luminance = ±this many stops of perceptual lightness.
    public static let lumRangeStops: Double = 0.5
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

    /// See `solveLumScale`.
    public let lumScale: Double

    public init(wheels: GradingWheels,
                printerLights: PrinterLights,
                whiteAnchorEV: Double = 5.0,
                blackAnchorEV: Double = -9.0,
                context: OKLabTransform.Context = OKLabTransform.working) {
        self.wheels = wheels
        self.printerLights = printerLights
        self.context = context
        self.windows = ZoneWindows(wheels: wheels,
                                   whiteAnchorEV: whiteAnchorEV,
                                   blackAnchorEV: blackAnchorEV)
        self.colorBalance = ColorBalanceGrid(params: wheels.colorBalance,
                                             windows: self.windows,
                                             context: context)
        let g = WheelTint(wheels.global)
        let sh = WheelTint(wheels.shadows)
        let mid = WheelTint(wheels.mid)
        let hi = WheelTint(wheels.high)
        self.globalTint = g
        self.shadowTint = sh
        self.midTint = mid
        self.highTint = hi
        self.lumScale = GradeEngine.solveLumScale(
            windows: self.windows, shadows: sh.stops, mid: mid.stops, high: hi.stops)
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
            let slope = (stops(a) - stops(x)) / ((a - x) * span)
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
        let zoned: Double = (w.shadows * shadowTint.stops + w.mid * midTint.stops
            + w.high * highTint.stops) * lumScale
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


    public init(params: ColorBalanceParams = ColorBalanceParams(),
                windows: ZoneWindows = ZoneWindows(),
                context: OKLabTransform.Context = OKLabTransform.working) {
        self.params = params
        self.windows = windows
        self.context = context
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

    /// Per-zone gain: `1 + (global + Σ w_z · v_z)/100`, floored at 0 so −100 lands on a
    /// true neutral and cannot go through it into negative chroma.
    private static func gain(_ axis: ColorBalanceAxis,
                             _ w: (shadows: Double, mid: Double, high: Double)) -> Double {
        let sum: Double = Num.clamp(axis.global, -100, 100)
            + w.shadows * Num.clamp(axis.shadows, -100, 100)
            + w.mid * Num.clamp(axis.mid, -100, 100)
            + w.high * Num.clamp(axis.high, -100, 100)
        return Swift.max(0, 1 + sum / 100)
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
        if !params.brilliance.isZero, L > 1e-6 {
            let brightness: Double = L * (1 + m * C)
            let target: Double = brightness * ColorBalanceGrid.gain(params.brilliance, w)
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
