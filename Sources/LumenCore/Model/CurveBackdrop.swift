// CurveBackdrop.swift
// The histogram drawn behind the tone curve, put on the curve's INPUT axis.
//
// The editor was handed the frame's histogram — the delivered picture, which is the
// curve's OUTPUT — and drew it under an x axis that is the curve's input. With no curve
// the two are the same thing. With one they are not, and the error is exactly the
// curve: a strong S-curve spreads the midtones, so the output histogram shows the
// midtone hump wider than the tones the hand is choosing between, and every point
// placed "on the hump" lands on the wrong tones. Worse, the backdrop moved while the
// point was dragged, because dragging the point re-rendered the picture it was drawn
// from — the instrument the hand was aiming by was moving with the hand.
//
// The fix is a change of variables, not a second render. The curve `f` is monotone
// non-decreasing (every curve in `CurveStack` is, by construction or by limiter), so
// the share of pixels whose input lies in `[a, b]` is the share whose output lies in
// `[f(a), f(b)]`: input mass in a bin is the output CDF's rise across the bin's image.
// The output CDF is piecewise linear within each output bin, which is the honest
// reading of a binned histogram, and the result sums to the same total the output did.
//
// What it cannot know: a flat stretch of `f` sends a whole range of inputs to ONE
// output value, and the binned output cannot say where in that range they came from.
// The mass lands on the inputs where `f` crosses that output bin. That is the curve's
// black and white clip and nothing else in practice — the point curve keeps both
// anchors, and the parametric limiter keeps the slope above zero.

import Foundation

public enum CurveBackdrop {

    /// Redistribute an output histogram onto the input axis of the monotone curve `f`
    /// that produced it. `outputCounts` are bin counts over `[0, 1]`; the result has
    /// the same bin count and the same total.
    public static func inputCounts(_ outputCounts: [Double],
                                   through f: (Double) -> Double) -> [Double] {
        let n = outputCounts.count
        guard n > 0 else { return [] }
        // Output CDF at bin edges: cdf[j] is the mass below j / n.
        var cdf = [Double](repeating: 0, count: n + 1)
        for j in 0..<n {
            let c = outputCounts[j]
            cdf[j + 1] = cdf[j] + (c.isFinite && c > 0 ? c : 0)
        }
        func cumulative(_ y: Double) -> Double {
            guard y.isFinite else { return 0 }
            let t = Swift.min(Swift.max(y, 0), 1) * Double(n)
            let j = Swift.min(Int(t), n - 1)
            return cdf[j] + (cdf[j + 1] - cdf[j]) * (t - Double(j))
        }
        var out = [Double](repeating: 0, count: n)
        // The ends: whatever sits in the output's first bin below f(0) and last bin
        // above f(1) has nowhere else to come from than the ends of the input.
        var running = -Double.infinity
        var previous = 0.0
        for i in 0...n {
            let x = Double(i) / Double(n)
            // Running max: a curve that is non-decreasing by contract but rounds a hair
            // backwards between two samples must not hand a bin negative mass.
            running = Swift.max(running, f(x))
            let c = i == 0 ? 0 : (i == n ? cdf[n] : cumulative(running))
            if i > 0 { out[i - 1] = Swift.max(0, c - previous) }
            previous = c
        }
        return out
    }

    /// Bin heights scaled to `[0, 1]` for drawing, against the 99th-percentile occupied
    /// bin — the same spike-resistant reference `Histogram.normalized` uses, so the
    /// curve's backdrop and the histogram panel read as one instrument.
    public static func normalized(_ counts: [Double]) -> [Double] {
        let occupied = counts.filter { $0.isFinite && $0 > 1e-12 }.sorted()
        guard !occupied.isEmpty else { return [Double](repeating: 0, count: counts.count) }
        let reference = occupied[Int((Double(occupied.count - 1) * 0.99).rounded(.up))]
        guard reference > 0 else { return [Double](repeating: 0, count: counts.count) }
        return counts.map { $0.isFinite ? Swift.min(Swift.max($0, 0) / reference, 1) : 0 }
    }
}

extension CurveStack {

    /// Which curve a backdrop is for. Each one's input is a different point in the
    /// stack, so each one's backdrop inverts a different tail of it.
    public enum BackdropStage: Sendable {
        /// The master curve (Parametric and Point tabs): the whole stack follows it.
        case master
        /// The luma curve: its input is the master's output.
        case luma
        /// One RGB channel curve, 0 = R: its input is that channel after master and luma.
        case channel(Int)
    }

    /// What happens to a NEUTRAL tone on the encoded axis from `stage`'s input to the
    /// picture: the curve the backdrop's output histogram has to be pulled back through.
    ///
    /// Neutral, because the backdrop is one number per pixel (luma, or one channel) and
    /// a neutral is the one colour whose luma every stage maps by the plotted curve
    /// exactly. RGB curves on a neutral split it into three channels; the luma of that is
    /// what a luma histogram measures, with the same weights `apply` uses.
    public func neutralTail(_ x: Double, from stage: BackdropStage,
                            space: RGBColorSpace = .rec2020) -> Double {
        var v = Num.saturate(x)
        switch stage {
        case .channel(let c):
            return channelCurve(v, channel: c)
        case .master:
            v = master(v)
            fallthrough
        case .luma:
            v = lumaCurve(v)
        }
        let w = space.luminanceWeights
        return w.r * channelCurve(v, channel: 0) + w.g * channelCurve(v, channel: 1)
            + w.b * channelCurve(v, channel: 2)
    }
}
