// MonotoneCubic.swift
// Monotone cubic interpolation (Fritsch–Carlson) for point curves (docs/04: the point
// curve engine; GPU stages bake this to a 1-D LUT, the CPU reference lives here).
//
// Behavior contract (mirrored by scripts/gen-fixtures.py — change both together):
//  - control points sorted by x, strictly ascending; y arbitrary
//  - 0 points → identity; 1 point → constant; 2 points → linear
//  - outside [x_first, x_last] → clamps to the endpoint y (flat extension)
//  - monotone segments never overshoot (the Fritsch–Carlson tangent limiter)

import Foundation

public struct MonotoneCubic: Sendable {
    public let xs: [Double]
    public let ys: [Double]
    private let tangents: [Double]

    public init(points: [[Double]]) {
        let sorted = points
            .filter { $0.count >= 2 }
            .sorted { $0[0] < $1[0] }
        var xs: [Double] = []
        var ys: [Double] = []
        for p in sorted {
            if let last = xs.last, p[0] <= last { continue } // drop duplicate x
            xs.append(p[0])
            ys.append(p[1])
        }
        self.xs = xs
        self.ys = ys

        let n = xs.count
        guard n >= 2 else {
            self.tangents = Array(repeating: 0, count: n)
            return
        }

        var d = [Double](repeating: 0, count: n - 1)   // secant slopes
        for i in 0..<(n - 1) {
            d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
        }

        var m = [Double](repeating: 0, count: n)       // tangents
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2
        }

        // Fritsch–Carlson monotonicity limiter
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let a = m[i] / d[i]
                let b = m[i + 1] / d[i]
                let s = a * a + b * b
                if s > 9 {
                    let t = 3 / s.squareRoot()
                    m[i] = t * a * d[i]
                    m[i + 1] = t * b * d[i]
                }
            }
        }
        self.tangents = m
    }

    public func evaluate(_ x: Double) -> Double {
        let n = xs.count
        if n == 0 { return x }              // identity
        if n == 1 { return ys[0] }          // constant
        if x <= xs[0] { return ys[0] }      // flat extension
        if x >= xs[n - 1] { return ys[n - 1] }

        // binary search for the interval with xs[i] <= x < xs[i+1]
        var lo = 0
        var hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }

        let h = xs[lo + 1] - xs[lo]
        let t = (x - xs[lo]) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[lo] + h10 * h * tangents[lo]
             + h01 * ys[lo + 1] + h11 * h * tangents[lo + 1]
    }

    /// Bake to a LUT of `size` samples over [0,1] — what the GPU stage uploads.
    public func bakeLUT(size: Int) -> [Double] {
        precondition(size >= 2)
        return (0..<size).map { evaluate(Double($0) / Double(size - 1)) }
    }
}
