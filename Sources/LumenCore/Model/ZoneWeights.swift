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

    /// Weights of each zone at position x. `pivots.count` = zone count.
    public static func weights(x: Double, pivots: [Double]) -> [Double] {
        let n = pivots.count
        precondition(n >= 1)
        var w = [Double](repeating: 0, count: n)
        if n == 1 || x <= pivots[0] {
            w[0] = 1
            return w
        }
        if x >= pivots[n - 1] {
            w[n - 1] = 1
            return w
        }
        var i = 0
        while i < n - 1 && !(x >= pivots[i] && x < pivots[i + 1]) { i += 1 }
        let u = (x - pivots[i]) / (pivots[i + 1] - pivots[i])
        let wi = 0.5 * (1 + cos(.pi * u))
        w[i] = wi
        w[i + 1] = 1 - wi
        return w
    }

    /// Per-zone exposure applied at x: gain in stops = Σ w_z · ev_z (+ global ev).
    /// This is the Resolve-HDR-palette model in one line (docs/04 §Zones).
    public static func exposureStops(
        x: Double, pivots: [Double], zoneEV: [Double], globalEV: Double
    ) -> Double {
        precondition(zoneEV.count == pivots.count)
        let w = weights(x: x, pivots: pivots)
        var stops = globalEV
        for (i, wi) in w.enumerated() { stops += wi * zoneEV[i] }
        return stops
    }
}
