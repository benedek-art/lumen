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

    public init(_ set: CurveSet, encoding: TransferFunction = .srgb) {
        self.set = set
        self.encoding = encoding
        self.parametric = CurveStack.bakeParametric(set.parametric)
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

        // Monotonicity limiter: shrink the whole shift until the sampled derivative
        // is non-negative everywhere. Two dozen halvings is far more than any real
        // slider combination needs, and it terminates.
        var scale = 1.0
        for _ in 0..<24 {
            var monotone = true
            var previous = 0.0
            let probes = 256
            for i in 0...probes {
                let x = Double(i) / Double(probes)
                let y = x + delta(x) * scale
                if i > 0 && y < previous - 1e-9 { monotone = false; break }
                previous = y
            }
            if monotone { break }
            scale *= 0.8
        }
        let finalScale = scale
        return LUT1D(size: size) { x in Num.saturate(x + delta(x) * finalScale) }
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
            && parametric.isIdentity()
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
        if !(point == nil && parametric.isIdentity()) {
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
