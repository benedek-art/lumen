// ColorMath.swift
// The arithmetic substrate for every color stage: an RGB triple, a 3×3 matrix, and
// the small set of operations the engine repeats a million times per frame.
//
// Reference-implementation policy (docs/14 §1.4): the pipeline's math is DEFINED here,
// in f64, and golden-tested here. GPU kernels and baked LUTs are optimizations that
// must match this file within a stage-declared tolerance. Nothing in this file may
// import a platform framework — it is the part of Lumen that runs anywhere.

import Foundation

// MARK: - RGB

/// A linear, unbounded RGB triple in whatever space the caller is working in
/// (the pipeline's working space is linear Rec.2020 — docs/14 §1.3).
/// Values may exceed 1.0 and go below 0.0; no operation here clamps unless it says so.
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    @inlinable public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    @inlinable public init(gray v: Double) {
        self.init(v, v, v)
    }

    public static let zero = RGB(0, 0, 0)
    public static let one = RGB(1, 1, 1)

    @inlinable public subscript(i: Int) -> Double {
        get { i == 0 ? r : (i == 1 ? g : b) }
        set { if i == 0 { r = newValue } else if i == 1 { g = newValue } else { b = newValue } }
    }

    @inlinable public var maxComponent: Double { Swift.max(r, Swift.max(g, b)) }
    @inlinable public var minComponent: Double { Swift.min(r, Swift.min(g, b)) }
    @inlinable public var sum: Double { r + g + b }

    @inlinable public var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite }

    @inlinable public func clamped(_ lo: Double = 0, _ hi: Double = 1) -> RGB {
        RGB(Swift.min(Swift.max(r, lo), hi),
            Swift.min(Swift.max(g, lo), hi),
            Swift.min(Swift.max(b, lo), hi))
    }

    /// Component-wise map — the workhorse for per-channel curves.
    @inlinable public func map(_ f: (Double) -> Double) -> RGB {
        RGB(f(r), f(g), f(b))
    }

    @inlinable public static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    @inlinable public static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    @inlinable public static func * (a: RGB, b: RGB) -> RGB { RGB(a.r * b.r, a.g * b.g, a.b * b.b) }
    @inlinable public static func / (a: RGB, b: RGB) -> RGB { RGB(a.r / b.r, a.g / b.g, a.b / b.b) }
    @inlinable public static func * (a: RGB, s: Double) -> RGB { RGB(a.r * s, a.g * s, a.b * s) }
    @inlinable public static func * (s: Double, a: RGB) -> RGB { a * s }
    @inlinable public static func / (a: RGB, s: Double) -> RGB { RGB(a.r / s, a.g / s, a.b / s) }
    @inlinable public static func + (a: RGB, s: Double) -> RGB { RGB(a.r + s, a.g + s, a.b + s) }
    @inlinable public static func - (a: RGB, s: Double) -> RGB { RGB(a.r - s, a.g - s, a.b - s) }
    @inlinable public static prefix func - (a: RGB) -> RGB { RGB(-a.r, -a.g, -a.b) }

    /// Linear interpolation, `t = 0` → self, `t = 1` → other.
    @inlinable public func mix(_ other: RGB, _ t: Double) -> RGB {
        self + (other - self) * t
    }

    /// Largest absolute component-wise difference — the tolerance metric goldens use.
    @inlinable public func maxAbsDifference(_ other: RGB) -> Double {
        Swift.max(abs(r - other.r), Swift.max(abs(g - other.g), abs(b - other.b)))
    }
}

// MARK: - Mat3

/// Row-major 3×3 matrix. `m[row][col]`, applied as `out = M · in`.
public struct Mat3: Equatable, Sendable {
    public var m: [[Double]]

    public init(_ rows: [[Double]]) {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 },
                     "Mat3 needs 3×3 values")
        self.m = rows
    }

    public init(_ a: Double, _ b: Double, _ c: Double,
                _ d: Double, _ e: Double, _ f: Double,
                _ g: Double, _ h: Double, _ i: Double) {
        self.m = [[a, b, c], [d, e, f], [g, h, i]]
    }

    public static let identity = Mat3(1, 0, 0, 0, 1, 0, 0, 0, 1)

    public static func diagonal(_ v: RGB) -> Mat3 {
        Mat3(v.r, 0, 0, 0, v.g, 0, 0, 0, v.b)
    }

    @inlinable public func apply(_ v: RGB) -> RGB {
        RGB(m[0][0] * v.r + m[0][1] * v.g + m[0][2] * v.b,
            m[1][0] * v.r + m[1][1] * v.g + m[1][2] * v.b,
            m[2][0] * v.r + m[2][1] * v.g + m[2][2] * v.b)
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += a.m[i][k] * b.m[k][j] }
                out[i][j] = s
            }
        }
        return Mat3(out)
    }

    public var determinant: Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    /// Inverse; traps on a singular matrix (every matrix in the engine is a
    /// well-conditioned color transform — a singular one is a programming error).
    public var inverse: Mat3 {
        let det = determinant
        precondition(abs(det) > 1e-12, "Mat3.inverse on a singular matrix")
        let a = m
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        out[0][0] = (a[1][1] * a[2][2] - a[1][2] * a[2][1]) / det
        out[0][1] = (a[0][2] * a[2][1] - a[0][1] * a[2][2]) / det
        out[0][2] = (a[0][1] * a[1][2] - a[0][2] * a[1][1]) / det
        out[1][0] = (a[1][2] * a[2][0] - a[1][0] * a[2][2]) / det
        out[1][1] = (a[0][0] * a[2][2] - a[0][2] * a[2][0]) / det
        out[1][2] = (a[0][2] * a[1][0] - a[0][0] * a[1][2]) / det
        out[2][0] = (a[1][0] * a[2][1] - a[1][1] * a[2][0]) / det
        out[2][1] = (a[0][1] * a[2][0] - a[0][0] * a[2][1]) / det
        out[2][2] = (a[0][0] * a[1][1] - a[0][1] * a[1][0]) / det
        return Mat3(out)
    }

    public var transposed: Mat3 {
        Mat3(m[0][0], m[1][0], m[2][0],
             m[0][1], m[1][1], m[2][1],
             m[0][2], m[1][2], m[2][2])
    }

    /// Row-major flattening — the form Core Image's colour-matrix filters want.
    public var flattened: [Double] { m[0] + m[1] + m[2] }

    public func maxAbsDifference(_ other: Mat3) -> Double {
        var d = 0.0
        for i in 0..<3 {
            for j in 0..<3 { d = Swift.max(d, abs(m[i][j] - other.m[i][j])) }
        }
        return d
    }
}

// MARK: - Small numeric helpers

public enum Num {

    @inlinable public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(x, lo), hi)
    }

    @inlinable public static func saturate(_ x: Double) -> Double { clamp(x, 0, 1) }

    /// Ease `amount` onto `cap` instead of clipping at it.
    ///
    /// Exact while `|amount|` is below `knee × cap`, then approaching `cap`
    /// asymptotically — so the result is STRICTLY increasing in `amount` everywhere,
    /// which is the property a hard `min(amount, cap)` loses.
    ///
    /// This exists because two engines solve a monotonicity cap that is inversely
    /// proportional to the slider, which makes `slider × cap` constant once it binds.
    /// Clipping there leaves the top of the control applying one identical value:
    /// Highlights was dead from 57 to 100, and the grading wheels' Luminance ring was
    /// dead over 80% of its range at low Blending. A dead control that still moves is
    /// worse than a shorter one, because nothing tells the photographer it stopped.
    @inlinable public static func softLimit(_ amount: Double, cap: Double,
                                            knee: Double = 0.8) -> Double {
        guard amount.isFinite else { return 0 }
        guard cap.isFinite, cap > 0 else { return 0 }
        // `|amount|` can never exceed the cap here, so there is nothing to ease.
        guard cap < 1 else { return amount }
        let eased = softKnee(abs(amount) / cap, knee: knee) * cap
        return amount < 0 ? -eased : eased
    }

    /// The knee itself, on a quantity normalized so that 1 is the limit: identity below
    /// `knee`, then approaching 1 without reaching it. Strictly increasing on [0, ∞).
    ///
    /// Exposed separately because the two callers normalize differently. `softLimit`
    /// divides an amount by its cap; the grading wheels already hold the reciprocal —
    /// their solved scale IS `1 / deflection` in units of the largest safe deflection —
    /// so they need the knee without the cap comparison wrapped around it.
    @inlinable public static func softKnee(_ u: Double, knee: Double = 0.8) -> Double {
        guard u.isFinite, u > 0 else { return 0 }
        let k = clamp(knee, 0.01, 0.99)
        guard u > k else { return u }
        // `1 − (1−k)·(k/u)^q` with `q = k/(1−k)`, which is the exponent that makes the
        // slope match 1 at the knee, so the join is C¹.
        //
        // A power tail rather than an exponential one, because the exponential
        // saturates in DOUBLE PRECISION long before the control runs out: at Blending 0
        // the grading wheels' deflection reaches 16× the cap, and `1 − e^(−76)` is
        // exactly 1. The power form still gains 1.9e-5 between 8× and 16×, which is the
        // difference between a control that keeps responding and one that is dead again
        // at the far end for a subtler reason than before.
        let q = k / (1 - k)
        return 1 - (1 - k) * pow(k / u, q)
    }

    @inlinable public static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// Hermite smoothstep. Returns 0 below `e0`, 1 above `e1`.
    @inlinable public static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        if e1 <= e0 { return x < e0 ? 0 : 1 }
        let t = saturate((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    /// Raised-cosine crossfade on [0,1] — the falloff shape the zone system uses
    /// (matches ZoneWeights' crossfade so tone and grade share one visual grammar).
    @inlinable public static func raisedCosine(_ t: Double) -> Double {
        let u = saturate(t)
        return 0.5 * (1 - cos(.pi * u))
    }

    /// Signed power that preserves sign: `spow(-x, y) == -spow(x, y)`.
    /// Used wherever a curve must survive the negative excursions scene-referred
    /// data legitimately carries (docs/14 §1.1).
    @inlinable public static func spow(_ x: Double, _ y: Double) -> Double {
        x < 0 ? -pow(-x, y) : pow(x, y)
    }

    /// log2 guarded against zero/negative input, floored at `floorEV` stops.
    @inlinable public static func safeLog2(_ x: Double, floorEV: Double = -20) -> Double {
        x <= 0 ? floorEV : Swift.max(log2(x), floorEV)
    }

    /// Wrap a hue in degrees into [0, 360) — with the top end ACTUALLY CLOSED.
    ///
    /// The half-open range is the contract twenty-one callers across the colour engine
    /// read this function for, and `remainder`-then-`+360` did not keep it. Any input
    /// in the last few ulps below zero comes back as exactly 360: `ulp(360)` is 5.7e-14,
    /// so `-5.7e-14 + 360` has no representable neighbour short of 360 and rounds to it.
    ///
    /// That input is not hypothetical, it is the commonest interesting case. Two grade
    /// pucks on opposite sides of red — 350° and 10° — interpolate to a point whose
    /// `atan2` is zero to within a rounding error, and the SIGN of that error is not
    /// the caller's to choose; half the time the walk between two neighbouring tints
    /// reports 360°. The same arithmetic reaches here from `OKLab.hue`, from
    /// `varianceCompress`, and from both grading engines' hue shifts.
    ///
    /// Nothing renders differently — 0° and 360° are the same colour, and the two
    /// consumers that could tell them apart cannot: `Gamut.Boundary.maxChroma` indexes
    /// `Int(360/360 × hueSteps) % hueSteps`, which is bin 0 either way, and `OKLCh.lab`
    /// differs by 2.4e-16 in `b`, on a colour whose chroma is 1e-16 to begin with. That
    /// is exactly why it is worth closing rather than leaving: an error that changes no
    /// pixel is one nothing will ever surface, while `hue: 360` and `hue: 0` serialize
    /// to different canonical text and therefore to different `recipe_fp` values — two
    /// cache entries and two proof records for one look, decided by a floating-point
    /// sign. `LookSubset.wrappedHue` folded it at its own call site and left the
    /// boundary here to be closed properly, which is this.
    @inlinable public static func wrapHue(_ h: Double) -> Double {
        var x = h.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        // Only reachable by the rounding above: `truncatingRemainder` itself never
        // returns 360, and a value that rounded up to it is a hue of zero.
        if x >= 360 { x = 0 }
        return x
    }

    /// Shortest signed angular distance from `a` to `b`, in degrees, in (−180, 180].
    @inlinable public static func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Linear interpolation over a table of (x, y) anchors, clamped at the ends.
    /// The interpolation rule for every "per-ISO anchor" table in the engine.
    public static func interpolateAnchors(_ anchors: [(x: Double, y: Double)], at x: Double) -> Double {
        guard let first = anchors.first else { return 0 }
        if anchors.count == 1 || x <= first.x { return first.y }
        guard let last = anchors.last else { return first.y }
        if x >= last.x { return last.y }
        var i = 0
        while i < anchors.count - 2 && x >= anchors[i + 1].x { i += 1 }
        let a = anchors[i], b = anchors[i + 1]
        let t = (x - a.x) / (b.x - a.x)
        return mix(a.y, b.y, t)
    }
}
