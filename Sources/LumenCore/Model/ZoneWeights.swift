// ZoneWeights.swift
// The zone weighting kernel behind the six-slider tone panel and the Zones panel
// (docs/04, docs/14 §S7): N zones over the normalized tonal axis x ∈ [0,1], each
// centered on a pivot, weights forming a partition of unity with raised-cosine
// crossfades between adjacent pivots.
//
// The mapping from scene luminance to the normalized axis is the pipeline's business
// (docs/14 defines it on log2 luminance with a guided-filter mask); this file is pure
// weighting math so it can be golden-tested on any platform.
//
// Contract (mirrored by scripts/gen-fixtures.py — change both together):
//  - pivots strictly ascending inside [0,1]
//  - x <= first pivot → weight 1 on zone 0; x >= last pivot → weight 1 on last zone
//  - between pivots i and i+1: w[i] = 0.5(1+cos(pi*u)), w[i+1] = 1-w[i],
//    u = (x - p[i]) / (p[i+1] - p[i])  — weights always sum to exactly 1.

import Foundation

public enum ZoneWeights {

    /// The crossfade at `x`, without materialising a weight vector: the index of the
    /// lower zone and its weight. The zone one above carries the remainder, and every
    /// other zone is zero — a raised-cosine crossfade only ever touches two.
    ///
    /// Every caller here is a per-sample loop over a 1024-point grid, and `weights`
    /// allocates an array on each call. `CurveStack.bakeParametric` did it 41,000 times
    /// per bake and `ToneEngine.zonePanelStops` once per LUT sample, both on the path a
    /// slider drag runs every frame.
    @inlinable public static func crossfade(x: Double, pivots: [Double])
        -> (index: Int, weight: Double) {
        let n = pivots.count
        precondition(n >= 1)
        if n == 1 || x <= pivots[0] { return (0, 1) }
        if x >= pivots[n - 1] { return (n - 1, 1) }
        var i = 0
        while i < n - 1 && !(x >= pivots[i] && x < pivots[i + 1]) { i += 1 }
        let u = (x - pivots[i]) / (pivots[i + 1] - pivots[i])
        return (i, 0.5 * (1 + cos(.pi * u)))
    }

    /// `Σ wᵢ · valuesᵢ` at `x`. The blend the zone system is for, allocation-free.
    @inlinable public static func blend(x: Double, pivots: [Double],
                                        values: [Double]) -> Double {
        precondition(values.count == pivots.count)
        let (i, w) = crossfade(x: x, pivots: pivots)
        guard i + 1 < values.count else { return values[i] * w }
        return values[i] * w + values[i + 1] * (1 - w)
    }

    /// Weights of each zone at position x. `pivots.count` = zone count.
    public static func weights(x: Double, pivots: [Double]) -> [Double] {
        let n = pivots.count
        var w = [Double](repeating: 0, count: n)
        let (i, wi) = crossfade(x: x, pivots: pivots)
        w[i] = wi
        if i + 1 < n { w[i + 1] = 1 - wi }
        return w
    }

    /// Per-zone exposure applied at x: gain in stops = Σ w_z · ev_z (+ global ev).
    /// This is the Resolve-HDR-palette model in one line (docs/04 §Zones).
    public static func exposureStops(
        x: Double, pivots: [Double], zoneEV: [Double], globalEV: Double
    ) -> Double {
        globalEV + blend(x: x, pivots: pivots, values: zoneEV)
    }
}
