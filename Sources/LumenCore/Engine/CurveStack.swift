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

    /// Peak shift, in encoded units, that ±100 on a parametric slider produces at the
    /// centre of its region. Chosen so a full-slider move is decisive without being
    /// able to flatten the curve on its own.
    public static let parametricRange: Double = 0.35

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

        func delta(_ x: Double) -> Double {
            let w = ZoneWeights.weights(x: x, pivots: centres)
            var s = 0.0
            for i in 0..<4 { s += w[i] * amounts[i] }
            let envelope = 4 * x * (1 - x)     // 0 at both ends, 1 at the middle
            return s * envelope * parametricRange
        }

        // Monotonicity limiter: the largest scale that keeps the sampled derivative
        // non-negative everywhere.
        //
        // Found by bisection, NOT by a `scale *= 0.8` ladder. The ladder was a real
        // artefact, not a nicety: the scale a given slider setting needs falls smoothly
        // as you drag, but a geometric ladder can only answer 1, 0.8, 0.64, 0.512, …
        // so the applied shift SAWTOOTHED. Every time the ladder stepped, the curve
        // jumped backwards by 16% in one slider notch — measured, Darks reversed at 46,
        // 57, 71 and 89, Lights at 49, 61, 76 and 94. A drop of 0.028 on the encoded
        // axis is about 7 of 255 levels, arriving mid-drag, so the image visibly
        // bounced as the photographer pushed the slider up.
        //
        // It also meant the end of the slider was not its strongest setting: Lights at
        // 100 landed 15% weaker than Lights at 60. Bisection makes the response
        // non-decreasing across all four sliders, both directions, and puts the maximum
        // at 100 where the label promises it.
        func isMonotone(_ scale: Double) -> Bool {
            var previous = 0.0
            // Probe the grid the curve is actually baked on. This was 256 while
            // production bakes 1024, so the limiter certified monotonicity on a grid
            // four times coarser than the one it was asked to guarantee, and the
            // samples in between dipped: at Highlights −100 / Lights +100 a baked
            // 512-sample curve stepped backwards by 6.8e-7, and six of the nine
            // extreme slider combinations did it at all. Raising this to 1024 takes
            // every one of them to exactly zero while moving the solved scale by
            // 0.014% — the limiter was already in the right place, it was just
            // looking at every fourth sample.
            //
            // Certifying the grid is sufficient as well as necessary: LUT1D
            // interpolates linearly between stored samples, and linear interpolation
            // between non-decreasing samples is non-decreasing. So a curve monotone at
            // every stored sample is monotone everywhere it will ever be read.
            //
            // Fixed at 1024 rather than tied to `size` on purpose: a size-dependent
            // scale would hand a 512-sample preview and a 1024-sample export different
            // curves.
            //
            // This used to claim the bake grids were subsets of this one and inherited
            // the guarantee. They are not, at ANY size. `LUT1D(size:)` samples
            // `i / (size − 1)` — 1/511 apart for a 512-point table, 1/1023 for a
            // 1024-point one — while this probes `i / 1024`. 511 and 1023 share no
            // factor with 1024, so the two grids meet only at the endpoints, and the
            // common refinement is 522,753 points: far too many to bisect over forty
            // times. The certificate was real and it was about a curve nobody bakes.
            //
            // Hence the clamp below. This bisection still chooses the SHAPE — a single
            // global scale, so the curve keeps its form instead of being flattened in
            // patches — and the clamp makes the invariant exact on whatever grid is
            // actually stored. Proof by sampling where the samples are the output.
            let probes = 1024
            for i in 0...probes {
                let x = Double(i) / Double(probes)
                let y = x + delta(x) * scale
                if i > 0 && y < previous - 1e-9 { return false }
                previous = y
            }
            return true
        }

        var finalScale = 1.0
        if !isMonotone(1) {
            var lo = 0.0        // always monotone: the curve is the identity
            var hi = 1.0        // known not to be
            for _ in 0..<40 {
                let mid = 0.5 * (lo + hi)
                if isMonotone(mid) { lo = mid } else { hi = mid }
            }
            finalScale = lo
        }
        // Non-decreasing by construction, on the grid that will be read.
        //
        // The limiter lands within about 2e-9 of monotone and no closer, because it
        // certifies a different grid and tolerates 1e-9 on that one. Measured, a
        // 512-point bake at Highlights −100 / Lights +100 stepped backwards by 1.8e-9
        // — invisible on any axis (a 16-bit level is 1.5e-5, four orders of magnitude
        // larger) but a broken invariant, and the kind that gets designed around later.
        //
        // A forward max is enough because `LUT1D` interpolates linearly: linear
        // interpolation between non-decreasing samples is non-decreasing, so pinning
        // the stored samples pins the whole curve. It repairs only what the limiter
        // left behind, which is why it cannot flatten anything visible — a clamp on
        // its own, without the global scale above, would.
        var samples = [Double](repeating: 0, count: size)
        var running = -Double.infinity
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            running = Swift.max(running, Num.saturate(x + delta(x) * finalScale))
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
