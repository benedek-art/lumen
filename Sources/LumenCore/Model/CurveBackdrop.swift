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
// The fix is a change of variables, not a second render: where the curve is monotone,
// the share of pixels whose input lies in `[a, b]` is the share whose output lies in
// `[f(a), f(b)]`. The output is read as uniform within each bin, which is the honest
// reading of a binned histogram, and the result sums to the same total the output did.
//
// What it cannot know: a flat stretch of `f` sends a whole range of inputs to ONE
// output value, and a dip sends two ranges to the same values; the binned output cannot
// say where in either they came from. A flat stretch gets nothing (its neighbours take
// the bin), two branches split a bin evenly. Both are rare and both are stated.

import Foundation

public enum CurveBackdrop {

    /// Redistribute an output histogram onto the input axis of the curve `f` that
    /// produced it. `outputCounts` are bin counts over `[0, 1]`; the result has the same
    /// bin count and the same total.
    ///
    /// Each output bin's count is shared among the stretches of input that land in it,
    /// in proportion to how much of the bin each stretch's image covers (the output is
    /// read as uniform within a bin). For a monotone curve that is exactly the change of
    /// variables — the input mass of `[a, b]` is the output mass of `[f(a), f(b)]`. For a
    /// curve that dips or inverts, which the point editor allows, a bin reached from two
    /// stretches of input is split between them: the binned output cannot say which
    /// branch a pixel came from, and an even split is the reading that does not invent
    /// one. A bin no stretch reaches (below the curve's minimum or above its maximum —
    /// a clip) goes to the stretch whose image is nearest.
    public static func inputCounts(_ outputCounts: [Double],
                                   through f: (Double) -> Double) -> [Double] {
        let n = outputCounts.count
        guard n > 0 else { return [] }
        let mass = outputCounts.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        // Sub-intervals: `per` to an input bin, so a steep stretch inside one bin is
        // still resolved.
        let per = 8
        let m = n * per
        var y = [Double](repeating: 0, count: m + 1)
        for j in 0...m {
            let v = f(Double(j) / Double(m))
            y[j] = v.isFinite ? Swift.min(Swift.max(v, 0), 1) * Double(n) : 0
        }
        // Coverage of each output bin by each sub-interval's image, in bin widths.
        func overlaps(_ j: Int, _ body: (Int, Double) -> Void) {
            let lo = Swift.min(y[j], y[j + 1]), hi = Swift.max(y[j], y[j + 1])
            guard hi > lo else { return }
            var k = Swift.min(Int(lo), n - 1)
            while k < n && Double(k) < hi {
                let o = Swift.min(hi, Double(k + 1)) - Swift.max(lo, Double(k))
                if o > 0 { body(k, o) }
                k += 1
            }
        }
        var cover = [Double](repeating: 0, count: n)
        for j in 0..<m { overlaps(j) { k, o in cover[k] += o } }
        var out = [Double](repeating: 0, count: n)
        for j in 0..<m {
            overlaps(j) { k, o in out[j / per] += mass[k] * o / cover[k] }
        }
        // Bins no stretch reaches: to the input whose output is nearest.
        for k in 0..<n where cover[k] == 0 && mass[k] > 0 {
            let centre = Double(k) + 0.5
            var best = 0, bestDistance = Double.infinity
            for j in 0...m {
                let d = abs(y[j] - centre)
                if d < bestDistance { bestDistance = d; best = j }
            }
            out[Swift.min(best / per, n - 1)] += mass[k]
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
    ///
    /// `weights` is the luminance weights of the working space, passed in rather than
    /// read here: `RGBColorSpace.luminanceWeights` derives them from the primaries (a
    /// matrix inverse) on every read, and the backdrop calls this two thousand times a
    /// frame — that alone was 2–3.5 ms of every hover frame.
    public func neutralTail(_ x: Double, from stage: BackdropStage, weights w: RGB) -> Double {
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
        return w.r * channelCurve(v, channel: 0) + w.g * channelCurve(v, channel: 1)
            + w.b * channelCurve(v, channel: 2)
    }
}
