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
    /// Multiplier actually used by the combined parametric monotonicity solve.
    /// Read-only UI provenance; reporting it never changes the baked curve.
    public let parametricAppliedScale: Double
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
    let parametricIsIdentity: Bool

    /// Where the luma curve puts black: `f(0)` on the encoded axis, zero for a curve
    /// that does not lift it. Decided once, because it picks the branch in `apply`.
    let lumaBlack: Double

    /// The same for the master curve (parametric, then points). The parametric curve
    /// pins 0, so this is the point curve's lift.
    let masterBlack: Double

    public init(_ set: CurveSet, encoding: TransferFunction = .srgb) {
        self.set = set
        self.encoding = encoding
        let solved = CurveStack.bakeParametricWithScale(set.parametric)
        let baked = solved.lut
        self.parametricAppliedScale = solved.scale
        self.parametric = baked
        self.parametricIsIdentity = baked.isIdentity()
        let point = set.point.map { MonotoneCubic(points: $0) }
        self.point = point
        let parametricBlack = Num.saturate(baked.evaluate(0))
        self.masterBlack = Num.saturate(point?.evaluate(parametricBlack) ?? parametricBlack)
        let luma = set.luma.map { MonotoneCubic(points: $0) }
        self.luma = luma
        self.lumaBlack = luma.map { Num.saturate($0.evaluate(0)) } ?? 0
        self.rCurve = set.r.map { MonotoneCubic(points: $0) }
        self.gCurve = set.g.map { MonotoneCubic(points: $0) }
        self.bCurve = set.b.map { MonotoneCubic(points: $0) }
    }

    // MARK: - Parametric

    /// Region centres from the three movable splits.
    ///
    /// The splits go through `CurveEditing.sanitizedSplits` — the editor's own bounds,
    /// 10–90 % with a 2 % gap — before anything is computed from them. The engine used
    /// to clamp to 2–98 % with a 1 % gap on its own, so a sidecar holding splits the
    /// editor cannot reach rendered one curve while the graph drew the splits repaired
    /// to its bounds and the regions over them: two pictures of one recipe.
    public static func regionCentres(_ splits: [Double]) -> [Double] {
        let s = CurveEditing.sanitizedSplits(splits)
        let a = s[0], b = s[1], c = s[2]
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
        bakeParametricWithScale(p, size: size).lut
    }

    private static func bakeParametricWithScale(_ p: ParametricCurve, size: Int = 1024)
        -> (lut: LUT1D, scale: Double) {
        let amounts = [p.shadows, p.darks, p.lights, p.highlights].map {
            Num.clamp($0, -100, 100) / 100
        }
        guard amounts.contains(where: { $0 != 0 }) else {
            return (LUT1D(size: size) { $0 }, 1)
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
        return (LUT1D(samples: samples), scale)
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

    // MARK: - The point curve's handles on the composite graph (AI-05)

    /// Where a picture input lands on the POINT curve's own axis: the parametric curve,
    /// which runs first. This is the coordinate a point is stored in.
    ///
    /// The Point graph draws the master curve — parametric then points — because that
    /// is what the pipeline applies. Its handles were drawn, hit-tested and dragged in
    /// the point curve's raw coordinates, which are a DIFFERENT axis the moment a
    /// parametric slider is off zero: Lights 50 with a point at (.6, .7) drew the handle
    /// at .7 while the trace under it at x = .6 was .7565 — 17 px apart on a 300 px
    /// plot, 32 px at Lights 100. The handle the hand grabbed was not on the curve the
    /// eye was reading.
    public func pointInput(atCompositeX x: Double) -> Double {
        let u = Num.saturate(x)
        return parametricIsIdentity ? u : parametric.evaluate(u)
    }

    /// The inverse: the picture input whose parametric output is `u`, so that a stored
    /// point `(u, y)` lies on the drawn trace at `(compositeX(u), y)` — the master there
    /// is `point(parametric(compositeX(u))) = point(u) = y`.
    ///
    /// The parametric curve is non-decreasing and pins both ends, so the preimage
    /// exists; on a plateau (two regions pulled against each other can make one) this
    /// takes its left end. Bisection to below 1e-15: it runs once per handle per draw.
    public func compositeX(atPointInput u: Double) -> Double {
        let target = Num.saturate(u)
        guard !parametricIsIdentity else { return target }
        var lo = 0.0, hi = 1.0
        for _ in 0..<56 {
            let mid = (lo + hi) / 2
            if parametric.evaluate(mid) < target { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// Stored point-curve points as the Point graph must draw and hit-test them.
    /// Malformed rows pass through untouched, so indices still line up with the store.
    public func compositeHandles(_ points: [[Double]]) -> [[Double]] {
        guard !parametricIsIdentity else { return points }
        return points.map { p in
            guard p.count >= 2 else { return p }
            return [compositeX(atPointInput: p[0]), p[1]]
        }
    }

    public func channelCurve(_ x: Double, channel: Int) -> Double {
        let c = channel == 0 ? rCurve : (channel == 1 ? gCurve : bCurve)
        return c?.evaluate(Num.saturate(x)) ?? x
    }

    /// Which of the five curves are not the identity, in the order `run` takes them:
    /// master (parametric then point), luma, R, G, B. `CurveStage` bakes only these.
    var activeCurves: (master: Bool, luma: Bool, channels: [Bool]) {
        (!(point == nil && parametricIsIdentity), luma != nil,
         [rCurve != nil, gCurve != nil, bCurve != nil])
    }

    public var isIdentity: Bool {
        point == nil && luma == nil && rCurve == nil && gCurve == nil && bCurve == nil
            && parametricIsIdentity
    }

    /// Apply the whole stack to a display-linear colour. SDR white is encoded 1 at
    /// EVERY display peak; `white` is the peak, and only sets how far above SDR white
    /// the picture may reach.
    ///
    /// This used to divide by `white` before encoding, so the curve's 0…1 axis spanned
    /// black to the display PEAK. That is "the same curve on an HDR rendition" only if
    /// HDR were SDR × peak, and the display transform deliberately is not: it keeps
    /// mid-grey at 0.18 absolute at every peak and spends the headroom on highlights
    /// (`DisplayTransform.tone`, docs/14 §7). At a 400 % peak mid-grey therefore met the
    /// curve at encoded 0.235 instead of 0.461 — Shadows +60 lifted it half a stop in
    /// HDR and not at all in SDR, an S-curve darkened it 0.65 EV instead of 0.08 — and
    /// the two renditions of a gain-map export carried two different grades, which is
    /// the lie docs/14 §2.2 item 3 forbids. Every tone at or below SDR white now meets
    /// the curve where it does in SDR, and the headroom above it rides a unit-slope
    /// extension from the curve's value at 1 (`extended`), so a curve that pins white
    /// lets HDR highlights through untouched and one that lowers white lowers them by
    /// the same encoded amount, with no step at 1. At `white` 1 the extension is
    /// unreachable and this is, bit for bit, the curve it always was
    /// (`CurveHDRAxisTests`).
    public func apply(_ c: RGB, white: Double = 1, space: RGBColorSpace = .rec2020) -> RGB {
        guard !isIdentity else { return c }
        let masterActive = !(point == nil && parametricIsIdentity)
        return CurveStack.run(
            c, white: white, space: space, encoding: encoding,
            preserveLuminance: set.preserveLuminance,
            master: masterActive ? { self.master($0) } : nil, masterBlack: masterBlack,
            luma: luma == nil ? nil : { self.lumaCurve($0) }, lumaBlack: lumaBlack,
            channels: [rCurve == nil ? nil : { self.channelCurve($0, channel: 0) },
                       gCurve == nil ? nil : { self.channelCurve($0, channel: 1) },
                       bCurve == nil ? nil : { self.channelCurve($0, channel: 2) }])
    }

    /// The stage itself, over curves handed in as functions on the encoded axis — the
    /// exact ones (`apply`) or their tables (`CurveStage.apply`). ONE body for both, so
    /// the stage a renderer runs from tables cannot drift from the definition.
    /// A nil curve is the identity and is skipped outright.
    static func run(_ c: RGB, white: Double, space: RGBColorSpace,
                    encoding: TransferFunction, preserveLuminance: Bool,
                    master: ((Double) -> Double)?, masterBlack: Double,
                    luma: ((Double) -> Double)?, lumaBlack: Double,
                    channels: [((Double) -> Double)?]) -> RGB {
        let w = Swift.max(white, 1e-6)
        // The top of the encoded axis: SDR white (1) or the display peak, whichever is
        // higher. Spelled as a branch so that SDR never depends on whether `encode(1)`
        // rounds to exactly 1.
        let top = w <= 1 ? 1 : Swift.max(1, encoding.encode(w))
        var e = encoding.encode(c.clamped(0, w))

        // Master curve, luminance-preserving by default: curve the luminance and
        // carry the chroma ratios, which is what stops a contrast curve from also
        // being a saturation boost.
        if let master {
            if preserveLuminance {
                let lum = Num.clamp(space.luminance(e), 0, top)
                if masterBlack > 0 {
                    // The same zero-luminance limit as the luma stage below: a master
                    // curve that lifts black lifts it with grey (AI-04).
                    e = CurveStack.liftedLuma(e, luminance: lum, black: masterBlack) {
                        CurveStack.extended($0, top: top, master)
                    }
                } else if lum > 1e-6 {
                    let scaled = CurveStack.extended(lum, top: top, master) / lum
                    e = e * scaled
                } else {
                    e = e.map { CurveStack.extended($0, top: top, master) }
                }
            } else {
                e = e.map { CurveStack.extended($0, top: top, master) }
            }
        }

        if let luma {
            let lum = Num.clamp(space.luminance(e), 0, top)
            if lumaBlack > 0 {
                e = CurveStack.liftedLuma(e, luminance: lum, black: lumaBlack) {
                    CurveStack.extended($0, top: top, luma)
                }
            } else if lum > 1e-6 {
                e = e * (CurveStack.extended(lum, top: top, luma) / lum)
            }
        }

        if channels.contains(where: { $0 != nil }) {
            func channel(_ v: Double, _ i: Int) -> Double {
                guard i < channels.count, let f = channels[i] else { return v }
                return CurveStack.extended(v, top: top, f)
            }
            e = RGB(channel(e.r, 0), channel(e.g, 1), channel(e.b, 2))
        }

        return encoding.decode(e.clamped(0, top))
    }

    /// A curve on the encoded axis, continued above SDR white (1) at unit slope from its
    /// value there, up to `top`. Below 1 it is `f` exactly — `f` clamps its own input
    /// to [0, 1] — and with `top` 1 (every SDR render) the continuation collapses to
    /// `f(1)`, which is what the clamp always gave. Unit slope, not `f′(1)`: HDR
    /// headroom is the display transform's to shape, and a curve's job above white is
    /// only not to step or invert there.
    static func extended(_ x: Double, top: Double, _ f: (Double) -> Double) -> Double {
        guard x > 1 else { return f(x) }
        return f(1) + (Swift.min(x, top) - 1)
    }

    /// A luminance curve that LIFTS BLACK (AI-04), on the encoded axis: the luma curve,
    /// and the master curve under Preserve Luminance, which has the same form and had
    /// the same defect (a point curve `[[0, .2], [1, 1]]` rendered neutral 1e−8 as
    /// `[.053, .032, .093]` through the trilinear cube).
    ///
    /// The luma stage is `e · f(L) / L`: curve the luminance, carry the chroma ratios.
    /// With `f(0) = b > 0` that ratio has no value at L = 0 and grows without bound
    /// beside it. The stage used to skip `L ≤ 1e-6`, so black stayed black while a
    /// pixel 1e−7 above it jumped to the plotted lift — the graph's endpoint honoured
    /// everywhere except AT the endpoint. And next to black `b / L` is enormous, so a
    /// dark blue corner of the finish cube came out a saturated blue; Core Image's
    /// trilinear `CIColorCube` mixes that corner with its red and green neighbours on
    /// the diagonal, and a NEUTRAL near-black rendered `[.027, .006, .067]` — purple.
    ///
    /// The limit: below the lift, black is lifted with GREY. The neutral form
    /// `e · (f(L) − b) / L + b` adds `b` to every channel and applies only the curve's
    /// remaining rise as a ratio; that ratio tends to the curve's slope at 0, so the
    /// form is continuous into black, where it is exactly `(b, b, b)`. Its luminance is
    /// `f(L)` — the weights sum to one — so it is still a luma curve, and on a neutral
    /// it equals the ratio form exactly.
    ///
    /// It takes over only BELOW the lift. From `L = b` up, the ratio's gain is bounded
    /// (about `1 + f′`), and there the old ratio form runs unchanged; between 0 and `b`
    /// the two are blended with a smoothstep in `L / b`, so the hand-over is C¹ and a
    /// curve that does not lift black never reaches this function at all.
    static func liftedLuma(_ e: RGB, luminance lum: Double, black b: Double,
                           curve f: (Double) -> Double) -> RGB {
        let floor = 1e-6
        let l = Swift.max(lum, floor)
        let fl = f(l)
        let neutral = e * ((fl - b) / l) + RGB(b, b, b)
        guard lum > floor else { return neutral }
        let ratio = e * (fl / l)
        let t = Num.saturate(lum / b)
        let w = t * t * (3 - 2 * t)
        guard w < 1 else { return ratio }
        return neutral.mix(ratio, w)
    }

    // There was a `bakeChannelLUTs` here: per-channel 1-D tables composing
    // `channelCurve(master(x))` — "the upload the GPU stage wants when there is no
    // luminance coupling to honour". It had no caller in the repository, and it was not
    // a safe one to acquire: it composed neither `preserveLuminance` (`apply`'s master
    // branch) nor the luma curve, so the day something wired it, every curve using
    // either would have rendered differently on that path and nothing would have said
    // so (K-061). The curve stage is baked into the finish cube through `apply`, which
    // honours both. Removed rather than fixed, because a correct per-channel upload of a
    // luminance-coupled curve does not exist — that is what the coupling means.

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
    ///
    /// `x` is a picture input; the point is stored at the point curve's own input for
    /// it, `pointInput(atCompositeX:)`. Stored at `x` itself it would move the curve at
    /// some other tone whenever a parametric slider is off zero (AI-05's axis mix-up).
    public func nudged(at x: Double, by delta: Double) -> [[Double]] {
        let y = Num.saturate(master(x) + delta)
        return CurveStack.settingPoint(set.point, x: pointInput(atCompositeX: x), y: y)
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
    /// Display white: the peak `CurveStack.apply` lets the picture reach above SDR
    /// white. Not a normalizer — the axis is absolute, as it is globally.
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

