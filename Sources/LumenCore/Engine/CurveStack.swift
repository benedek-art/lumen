// CurveStack.swift
// The tone curve (D10, docs/14 §S15) — the one deliberate post-transform stage.
// A curve is a picture-domain instinct: fifty years of muscle memory expect
// "midtones" to mean picture midtones, so the curve operates on display-linear values
// through the familiar encoded axis, composed as encode → curve → decode into one
// 1-D LUT per channel.
//
// Everything here is monotone by construction or by an explicit limiter: a
// non-monotone tone curve is an inversion artefact, never a creative choice, and the
// parametric sliders must not be able to produce one.

import Foundation

public struct CurveStack: Sendable {

    public let set: CurveSet
    /// The axis the user sees. sRGB encoding is what makes "the middle of the curve"
    /// land where a photographer's hand expects it.
    public let encoding: TransferFunction

    private let parametric: LUT1D
    private let point: MonotoneCubic?
    private let luma: MonotoneCubic?
    private let rCurve: MonotoneCubic?
    private let gCurve: MonotoneCubic?
    private let bCurve: MonotoneCubic?

    /// Whether the baked parametric curve is the identity, decided ONCE.
    ///
    /// `LUT1D.isIdentity()` walks all 1024 samples. It was being called from `apply`,
    /// per pixel, twice — once through `isIdentity` and once directly — so deciding to
    /// do nothing to an untouched photograph cost 2048 float comparisons per pixel.
    ///
    /// Measured on a release build: baking `RenderPlan.finishLUT` at its interactive
    /// size of 33 took 72.6 ms for a DEFAULT recipe, of which 53.0 ms was this. Since
    /// `finishLUT` is baked unconditionally on every plan and a plan is built for every
    /// frame, that was 53 ms of the per-frame budget spent proving a curve nobody had
    /// touched was still untouched. The whole identity plan drops from 70.3 ms to
    /// 17.7 ms; the draft plan, which is what a slider drag actually renders, drops
    /// from 10.1 ms to 2.6 ms.
    private let parametricIsIdentity: Bool

    public init(_ set: CurveSet, encoding: TransferFunction = .srgb) {
        self.set = set
        self.encoding = encoding
        let baked = CurveStack.bakeParametric(set.parametric)
        self.parametric = baked
        self.parametricIsIdentity = baked.isIdentity()
        self.point = set.point.map { MonotoneCubic(points: $0) }
        self.luma = set.luma.map { MonotoneCubic(points: $0) }
        self.rCurve = set.r.map { MonotoneCubic(points: $0) }
        self.gCurve = set.g.map { MonotoneCubic(points: $0) }
        self.bCurve = set.b.map { MonotoneCubic(points: $0) }
    }

    // MARK: - Parametric

    /// Region centres from the three movable splits.
    public static func regionCentres(_ splits: [Double]) -> [Double] {
        let s = splits.count == 3 ? splits.sorted() : [0.25, 0.5, 0.75]
        let a = Num.clamp(s[0], 0.02, 0.96)
        let b = Num.clamp(s[1], a + 0.01, 0.97)
        let c = Num.clamp(s[2], b + 0.01, 0.98)
        return [a / 2, (a + b) / 2, (b + c) / 2, (c + 1) / 2]
    }

    /// Slope the curve must still have at full deflection of ONE region.
    ///
    /// This replaced `parametricRange`, a fixed peak shift of 0.35 encoded units that
    /// every region shared. The regions are not the same width — the middle two are
    /// half the outer two at the default splits, and the splits are user-movable down
    /// to 0.02 apart — so one number could not be right for all of them, and it was
    /// right for none: measured, the monotonicity limiter bound at 47 on Darks and
    /// Lights and at 70 on Shadows and Highlights, so between 30% and 53% of every
    /// parametric slider applied the identical curve. The end of the control did
    /// nothing, silently, which is the failure `Num.softKnee` exists to prevent and
    /// which the limiter's own comment says it fixed. It fixed the SAWTOOTH. The dead
    /// top was still there underneath.
    ///
    /// And where it bound, it bound at slope zero exactly — the limiter's definition of
    /// safe — so full deflection put a dead-flat segment in the curve. Flat is not an
    /// inversion, but on a photograph it is a posterized band, and it was reachable on
    /// every one of the four sliders on its own.
    ///
    /// Sizing each region's amplitude from its OWN shape, to a slope floor instead of a
    /// zero floor, makes the whole travel live and the flat spot unreachable. It costs
    /// peak authority: Darks ±100 moves 30.6 code values where it used to move 38.3.
    /// The 38.3 was only ever reachable at setting 47 and above, all of which rendered
    /// the same picture.
    public static let parametricMinSlope: Double = 0.2

    /// Grid the limiter certifies, and the grid the checks probe.
    ///
    /// Fixed at 1024 rather than tied to `size` on purpose: a size-dependent solve
    /// would hand a 512-sample preview and a 1024-sample export different curves.
    ///
    /// This used to claim the bake grids were subsets of this one and inherited the
    /// guarantee. They are not, at ANY size. `LUT1D(size:)` samples `i / (size − 1)` —
    /// 1/511 apart for a 512-point table, 1/1023 for a 1024-point one — while this
    /// probes `i / 1024`. 511 and 1023 share no factor with 1024, so the two grids meet
    /// only at the endpoints, and the common refinement is 522,753 points. The
    /// certificate was real and it was about a curve nobody bakes. Hence the forward
    /// clamp in `bakeParametric`: the solve chooses the SHAPE, and the clamp makes the
    /// invariant exact on whatever grid is actually stored.
    static let parametricProbes: Int = 1024

    /// Fraction of the combination limit below which the sliders are applied exactly.
    /// Same knee as the tone engine and the grading wheels; same reason.
    ///
    /// `parametricMinSlope == 1 − parametricKnee` is not a coincidence and the two
    /// cannot be set independently. A lone slider at ±100 leaves the curve with slope
    /// `parametricMinSlope`, and the combination limiter — which allows slope down to 0
    /// — would let it go `1 / (1 − parametricMinSlope)` times further. That ratio is
    /// 1.25, exactly `1 / parametricKnee`, so a lone slider sits precisely at the knee
    /// and is applied EXACTLY at every setting. Raise the slope floor and lone sliders
    /// start getting eased for no reason; lower it and full deflection approaches a
    /// flat segment again.
    static let parametricKnee: Double = 0.8

    /// The four region bumps — weight × endpoint envelope — sampled on the probe grid.
    ///
    /// Sampled once and handed to both solves. `ZoneWeights.weights` allocates, and the
    /// bisection this replaced called it 41,000 times per bake: measured, 7.9 ms for a
    /// binding setting, on the path a slider drag runs every frame.
    static func parametricBumps(_ centres: [Double]) -> [[Double]] {
        let probes = parametricProbes
        var bumps = [[Double]](repeating: [Double](repeating: 0, count: probes + 1),
                               count: 4)
        for i in 0...probes {
            let x = Double(i) / Double(probes)
            let (lower, weight) = ZoneWeights.crossfade(x: x, pivots: centres)
            // The envelope pins both endpoints, so the curve can never move black or
            // white.
            let envelope = 4 * x * (1 - x)
            bumps[lower][i] = weight * envelope
            if lower + 1 < 4 { bumps[lower + 1][i] = (1 - weight) * envelope }
        }
        return bumps
    }

    /// Largest multiplier on a shift sampled over the probe grid that leaves the curve
    /// `x + m·delta(x)` with slope at or above `floor` everywhere.
    ///
    /// Closed form: the slope is `1 + m·Δdelta/Δx`, linear in `m`, so every interval
    /// where the shift falls gives one bound and the smallest of them is the answer.
    /// `.infinity` means nothing constrains it. Both solves below are this function —
    /// the per-region amplitude against `parametricMinSlope`, and the combination scale
    /// against zero.
    static func slopeLimit(_ delta: [Double], floor: Double) -> Double {
        let dx = 1.0 / Double(parametricProbes)
        var limit = Double.infinity
        for i in 1..<delta.count {
            let step = delta[i] - delta[i - 1]
            if step < 0 { limit = Swift.min(limit, (1 - floor) * dx / -step) }
        }
        return limit
    }

    /// The peak shift ±100 on one region is worth, given where the splits put it.
    /// Solved from the region's own shape rather than shared, because the regions are
    /// not the same width and the splits move.
    static func regionAmplitude(_ bump: [Double], sign: Double) -> Double {
        let signed = sign < 0 ? bump.map { -$0 } : bump
        let limit = slopeLimit(signed, floor: parametricMinSlope)
        return limit.isFinite ? limit : 0
    }

    /// Bake the four-region parametric curve. The region weights are the same
    /// partition-of-unity crossfade the tone zones use — one falloff grammar across
    /// the whole app — and an envelope pins both endpoints so the curve can never
    /// move black or white.
    static func bakeParametric(_ p: ParametricCurve, size: Int = 1024) -> LUT1D {
        let amounts = [p.shadows, p.darks, p.lights, p.highlights].map {
            Num.clamp($0, -100, 100) / 100
        }
        guard amounts.contains(where: { $0 != 0 }) else {
            return LUT1D(size: size) { $0 }
        }
        let centres = regionCentres(p.splits)
        let bumps = parametricBumps(centres)

        // Each region carries as much as its own shape allows, so a slider on its own
        // is monotone by construction and never meets the limiter below.
        var amplitude = [Double](repeating: 0, count: 4)
        for r in 0..<4 where amounts[r] != 0 {
            amplitude[r] = regionAmplitude(bumps[r], sign: amounts[r] < 0 ? -1 : 1)
        }

        let probes = parametricProbes

        // What the sliders ask for, before any limit, on the probe grid.
        var requested = [Double](repeating: 0, count: probes + 1)
        for i in 0...probes {
            var d = 0.0
            for r in 0..<4 where amounts[r] != 0 { d += bumps[r][i] * amounts[r] * amplitude[r] }
            requested[i] = d
        }

        // ONE scale over the sum, for the combinations that still conflict — Shadows up
        // against Darks down meet on the same stretch of the axis and cannot both be
        // honoured. `y(x) = x + scale·requested(x)` is linear in the scale, so the
        // largest safe value is closed form: one sweep, the smallest ratio over the
        // intervals where the sum falls. The bisection this replaced agreed with it and
        // cost forty sweeps.
        //
        // Then eased onto, not clipped at. The limit is inversely proportional to what
        // is asked for, so `scale × request` is constant the moment a hard cap binds —
        // which is exactly how the top of every slider went dead before.
        // Floor of zero, not `parametricMinSlope`: two adjacent regions pulled hard
        // against each other IS a request for a plateau, and honouring it is the
        // difference between a limiter and a house style. Measured, Shadows +100 with
        // Darks −100 bottoms out at slope 0.0126 — an 80:1 compression band at the
        // boundary, monotone, with no flat sample anywhere on the curve. The point
        // curve stays the unlimited tool; these four sliders are the safe one.
        let limit = slopeLimit(requested, floor: 0)
        let scale = limit.isFinite
            ? Swift.min(1, limit * Num.softKnee(1 / limit, knee: parametricKnee))
            : 1

        // Non-decreasing by construction, on the grid that will be read.
        //
        // The solve above certifies `parametricProbes`, and the stored grid is a
        // different one at every size — see the note there. A forward max is enough
        // because `LUT1D` interpolates linearly: linear interpolation between
        // non-decreasing samples is non-decreasing, so pinning the stored samples pins
        // the whole curve. It repairs only what the different grid leaves behind, which
        // is why it cannot flatten anything visible — a clamp on its own, without the
        // solve above, would.
        var samples = [Double](repeating: 0, count: size)
        var running = -Double.infinity
        let signed = (0..<4).map { amounts[$0] * amplitude[$0] }
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            let d = ZoneWeights.blend(x: x, pivots: centres, values: signed)
            let envelope = 4 * x * (1 - x)
            running = Swift.max(running, Num.saturate(x + d * envelope * scale))
            samples[i] = running
        }
        return LUT1D(samples: samples)
    }

    // MARK: - Evaluation on the encoded axis

    /// The master curve: parametric composed with the point curve.
    public func master(_ x: Double) -> Double {
        var y = parametric.evaluate(Num.saturate(x))
        if let point { y = point.evaluate(y) }
        return y
    }

    public func lumaCurve(_ x: Double) -> Double {
        luma?.evaluate(Num.saturate(x)) ?? x
    }

    public func channelCurve(_ x: Double, channel: Int) -> Double {
        let c = channel == 0 ? rCurve : (channel == 1 ? gCurve : bCurve)
        return c?.evaluate(Num.saturate(x)) ?? x
    }

    public var isIdentity: Bool {
        point == nil && luma == nil && rCurve == nil && gCurve == nil && bCurve == nil
            && parametricIsIdentity
    }

    /// Apply the whole stack to a display-linear colour, normalized so that
    /// `white` maps to 1.0 on the encoded axis.
    public func apply(_ c: RGB, white: Double = 1, space: RGBColorSpace = .rec2020) -> RGB {
        guard !isIdentity else { return c }
        let w = Swift.max(white, 1e-6)
        let normalized = c / w
        var e = encoding.encode(normalized.clamped(0, 1))

        // Master curve, luminance-preserving by default: curve the luminance and
        // carry the chroma ratios, which is what stops a contrast curve from also
        // being a saturation boost.
        if !(point == nil && parametricIsIdentity) {
            if set.preserveLuminance {
                let lum = Num.saturate(space.luminance(e))
                if lum > 1e-6 {
                    let scaled = master(lum) / lum
                    e = e * scaled
                } else {
                    e = e.map(master)
                }
            } else {
                e = e.map(master)
            }
        }

        if luma != nil {
            let lum = Num.saturate(space.luminance(e))
            if lum > 1e-6 {
                e = e * (lumaCurve(lum) / lum)
            }
        }

        if rCurve != nil || gCurve != nil || bCurve != nil {
            e = RGB(channelCurve(e.r, channel: 0),
                    channelCurve(e.g, channel: 1),
                    channelCurve(e.b, channel: 2))
        }

        return encoding.decode(e.clamped(0, 1)) * w
    }

    /// Per-channel 1-D LUTs on the encoded axis — the upload the GPU stage wants when
    /// there is no luminance coupling to honour.
    public func bakeChannelLUTs(size: Int = 1024) -> (r: LUT1D, g: LUT1D, b: LUT1D) {
        (LUT1D(size: size) { channelCurve(master($0), channel: 0) },
         LUT1D(size: size) { channelCurve(master($0), channel: 1) },
         LUT1D(size: size) { channelCurve(master($0), channel: 2) })
    }

    // MARK: - Editing helpers (TAT and the curve editor)

    /// Insert or move a control point so the curve passes through (x, y).
    /// Used by both the curve editor and the target adjustment tool, which is the
    /// same gesture pointed at the image instead of the graph.
    public static func settingPoint(_ points: [[Double]]?, x: Double, y: Double,
                                    snap: Double = 0.02) -> [[Double]] {
        var pts = points ?? [[0, 0], [1, 1]]
        let cx = Num.saturate(x)
        let cy = Num.saturate(y)
        if let i = pts.firstIndex(where: { abs($0[0] - cx) <= snap }) {
            pts[i] = [pts[i][0], cy]
        } else {
            pts.append([cx, cy])
        }
        pts.sort { $0[0] < $1[0] }
        return pts
    }

    /// Nudge the curve at `x` by `delta` on the y axis — the TAT drag.
    public func nudged(at x: Double, by delta: Double) -> [[Double]] {
        let y = Num.saturate(master(x) + delta)
        return CurveStack.settingPoint(set.point, x: x, y: y)
    }
}

// MARK: - The local point curve

/// A mask's point curve (docs/08 §8.4) — the one local control that does NOT run at
/// the local stage.
///
/// Every other local adjustment is a scene-referred delta composited at S11. A curve
/// is not: "midtones" means picture midtones to every photographer alive, so a curve
/// operates on display-linear values through the familiar encoded axis, and that axis
/// only exists after S14. docs/14 calls this the two-tap design, and it is why this
/// type is separate from `LocalPlan` / `applyLocalAdjust`: both render paths run it as
/// a second pass over the FORMED picture, through the same pre-geometry mask alpha.
///
/// Baking it into the local stage instead would be the units mistake BUILDING.md
/// catalogues, in a new costume: a control denominated on the display's encoded axis
/// evaluated against a scene-referred plane, where 0.5 is not middle grey and the four
/// parametric regions do not land on the tones they are named after.
public struct LocalCurve: Sendable {

    private let stack: CurveStack
    /// The mask's Amount as a multiplier. It scales the curve's DISPLACEMENT, which is
    /// what "Amount scales the adjustment deltas" means for a curve (docs/08 §8.1);
    /// above 1 it extrapolates, exactly as Amount > 100 does for every other local
    /// control.
    private let scale: Double
    /// Display white, so the curve's axis means the same thing on an HDR rendition as
    /// it does globally — `CurveStack.apply` normalizes by it.
    private let white: Double
    private let space: RGBColorSpace

    /// True when this curve cannot move a pixel: no curve stored, an untouched one, or
    /// an Amount of zero. Callers skip the whole tap rather than bake a table for it.
    public let isIdentity: Bool

    public init(curve: CurveSet?, amount: Double = 100, white: Double = 1,
                space: RGBColorSpace = .rec2020) {
        let built = CurveStack(curve ?? CurveSet())
        let factor = Num.clamp(amount.isFinite ? amount : 100, 0, 200) / 100
        self.stack = built
        self.scale = factor
        self.white = (white.isFinite && white > 1e-6) ? white : 1
        self.space = space
        self.isIdentity = curve == nil || built.isIdentity || factor == 0
    }

    /// Apply to a display-linear colour — the same domain `CurveStack.apply` takes.
    public func apply(_ c: RGB) -> RGB {
        guard !isIdentity, c.isFinite else { return c }
        let curved = stack.apply(c, white: white, space: space)
        guard curved.isFinite else { return c }
        return scale == 1 ? curved : c.mix(curved, scale)
    }
}

