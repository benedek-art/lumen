// ColorSpaces.swift
// Primaries, white points, RGB↔XYZ derivation, chromatic adaptation, and the encoding
// transfer functions. Everything is derived from chromaticities at runtime rather than
// carrying hard-coded 3×3 tables: one derivation, checked against the published sRGB
// matrix in the test suite, beats nine transcription opportunities per space.
//
// Working space: linear Rec.2020 (docs/14 §1.3). Every other space here exists to get
// data in (camera/source profiles) or out (export/display profiles).

import Foundation

// MARK: - Chromaticity

public struct Chromaticity: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// XYZ of this chromaticity at the given luminance.
    public func xyz(Y: Double = 1) -> RGB {
        guard y != 0 else { return RGB(0, 0, 0) }
        return RGB(Y * x / y, Y, Y * (1 - x - y) / y)
    }

    /// CIE 1960 UCS coordinates — the plane white balance's tint offset lives in.
    public var uv: (u: Double, v: Double) {
        let d = -2 * x + 12 * y + 3
        guard d != 0 else { return (0, 0) }
        return (4 * x / d, 6 * y / d)
    }

    public static func fromUV(u: Double, v: Double) -> Chromaticity {
        let d = 2 * u - 8 * v + 4
        guard d != 0 else { return Chromaticity(0, 0) }
        return Chromaticity(3 * u / d, 2 * v / d)
    }
}

public enum WhitePoint {
    public static let d65 = Chromaticity(0.3127, 0.3290)
    public static let d50 = Chromaticity(0.34567, 0.35850)
    public static let dci = Chromaticity(0.314, 0.351)
}

// MARK: - RGB colour space

public struct RGBColorSpace: Equatable, Sendable {
    public let name: String
    public let red: Chromaticity
    public let green: Chromaticity
    public let blue: Chromaticity
    public let white: Chromaticity

    public init(name: String, red: Chromaticity, green: Chromaticity,
                blue: Chromaticity, white: Chromaticity) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    /// Linear RGB → XYZ (matching this space's own white point), derived from the
    /// chromaticities by the standard SMPTE RP 177 construction.
    public var toXYZ: Mat3 {
        let r = red.xyz(), g = green.xyz(), b = blue.xyz()
        let m = Mat3(r.r, g.r, b.r,
                     r.g, g.g, b.g,
                     r.b, g.b, b.b)
        let s = m.inverse.apply(white.xyz())
        return m * Mat3.diagonal(s)
    }

    public var fromXYZ: Mat3 { toXYZ.inverse }

    /// Luminance weights for this space (row 1 of `toXYZ`) — the correct per-space
    /// "how bright is this colour" vector. Never hard-code Rec.709 weights on
    /// Rec.2020 data; that is the classic desaturation-on-luminance bug.
    public var luminanceWeights: RGB {
        let m = toXYZ.m
        return RGB(m[1][0], m[1][1], m[1][2])
    }

    public func luminance(_ c: RGB) -> Double {
        let w = luminanceWeights
        return w.r * c.r + w.g * c.g + w.b * c.b
    }

    // The spaces Lumen actually uses.

    public static let rec2020 = RGBColorSpace(
        name: "Rec.2020",
        red: Chromaticity(0.708, 0.292),
        green: Chromaticity(0.170, 0.797),
        blue: Chromaticity(0.131, 0.046),
        white: WhitePoint.d65)

    public static let srgb = RGBColorSpace(
        name: "sRGB",
        red: Chromaticity(0.640, 0.330),
        green: Chromaticity(0.300, 0.600),
        blue: Chromaticity(0.150, 0.060),
        white: WhitePoint.d65)

    public static let displayP3 = RGBColorSpace(
        name: "Display P3",
        red: Chromaticity(0.680, 0.320),
        green: Chromaticity(0.265, 0.690),
        blue: Chromaticity(0.150, 0.060),
        white: WhitePoint.d65)

    public static let adobeRGB = RGBColorSpace(
        name: "Adobe RGB (1998)",
        red: Chromaticity(0.640, 0.330),
        green: Chromaticity(0.210, 0.710),
        blue: Chromaticity(0.150, 0.060),
        white: WhitePoint.d65)

    public static let proPhoto = RGBColorSpace(
        name: "ProPhoto RGB",
        red: Chromaticity(0.734699, 0.265301),
        green: Chromaticity(0.159597, 0.840403),
        blue: Chromaticity(0.036598, 0.000105),
        white: WhitePoint.d50)

    /// Matrix converting linear values in `self` to linear values in `other`,
    /// including a CAT16 adaptation when the white points differ.
    public func matrix(to other: RGBColorSpace) -> Mat3 {
        var m = toXYZ
        if white != other.white {
            m = ChromaticAdaptation.cat16(from: white, to: other.white) * m
        }
        return other.fromXYZ * m
    }
}

// MARK: - Chromatic adaptation

public enum ChromaticAdaptation {

    /// CAT16 cone response matrix (CAM16, Li et al. 2017) — the adaptation transform
    /// docs/04 specifies for white balance (D9).
    public static let cat16 = Mat3(
        0.401288, 0.650173, -0.051461,
        -0.250268, 1.204414, 0.045854,
        -0.002079, 0.048952, 0.953127)

    /// Bradford — kept for ICC-compatible profile conversions on export, where
    /// matching the ICC convention matters more than matching our own.
    public static let bradford = Mat3(
        0.8951, 0.2664, -0.1614,
        -0.7502, 1.7135, 0.0367,
        0.0389, -0.0685, 1.0296)

    /// THE TWO INVERSES, ONCE, beside the matrices they invert — the same treatment
    /// `OKLabTransform.labToLMS` already gets, and for the same measured reason.
    ///
    /// `Mat3.inverse` is a COMPUTED property: it allocates four `[[Double]]`s and
    /// re-derives the matrix on every read, at about 2 µs a time. `adapt` read it once
    /// per call, and `adapt` is on the path of every render plan build, every
    /// eyedropper candidate, and — since the magenta bound below — every step of two
    /// bisections per distinct Kelvin. Deriving it once instead of per call is the same
    /// matrix by construction: `Mat3.inverse` is a pure deterministic function of the
    /// same constants, so this is bit-identical, not merely close.
    public static let cat16Inverse: Mat3 = cat16.inverse
    public static let bradfordInverse: Mat3 = bradford.inverse

    /// von Kries-style adaptation in the given cone space: XYZ(source white) → XYZ(dest white).
    public static func adapt(from source: RGB, to destination: RGB, cone: Mat3) -> Mat3 {
        let s = cone.apply(source)
        let d = cone.apply(destination)
        let gains = RGB(d.r / s.r, d.g / s.g, d.b / s.b)
        return inverse(of: cone) * Mat3.diagonal(gains) * cone
    }

    /// The cached inverse when the caller passes one of the two matrices this type
    /// declares, and the derivation otherwise — `adapt` takes an arbitrary cone space
    /// and must keep working for one this file has never seen.
    private static func inverse(of cone: Mat3) -> Mat3 {
        if cone == cat16 { return cat16Inverse }
        if cone == bradford { return bradfordInverse }
        return cone.inverse
    }

    public static func cat16(from source: Chromaticity, to destination: Chromaticity) -> Mat3 {
        adapt(from: source.xyz(), to: destination.xyz(), cone: cat16)
    }

    public static func bradford(from source: Chromaticity, to destination: Chromaticity) -> Mat3 {
        adapt(from: source.xyz(), to: destination.xyz(), cone: bradford)
    }
}

// MARK: - Transfer functions

/// Encoding curves. The pipeline is linear-light everywhere (docs/14 §1.1); these
/// exist only at the encode boundary (S17) and for interpreting display-referred data.
public enum TransferFunction: String, Codable, Sendable, CaseIterable {
    case linear
    case srgb
    case gamma22
    case gamma18
    case rec709
    case pq          // SMPTE ST 2084, absolute, 10000 cd/m² peak
    case hlg

    /// Linear (0…1 nominal, display-referred) → encoded value.
    public func encode(_ x: Double) -> Double {
        switch self {
        case .linear:
            return x
        case .srgb:
            if x <= 0.0031308 { return 12.92 * x }
            return 1.055 * Num.spow(x, 1.0 / 2.4) - 0.055
        case .gamma22:
            return Num.spow(x, 1.0 / 2.2)
        case .gamma18:
            return Num.spow(x, 1.0 / 1.8)
        case .rec709:
            if x < 0.018 { return 4.5 * x }
            return 1.099 * Num.spow(x, 0.45) - 0.099
        case .pq:
            let m1 = 2610.0 / 16384.0
            let m2 = 2523.0 / 4096.0 * 128.0
            let c1 = 3424.0 / 4096.0
            let c2 = 2413.0 / 4096.0 * 32.0
            let c3 = 2392.0 / 4096.0 * 32.0
            let y = Num.saturate(x)
            let yp = pow(y, m1)
            return pow((c1 + c2 * yp) / (1 + c3 * yp), m2)
        case .hlg:
            let a = 0.17883277, b = 1 - 4 * 0.17883277, c = 0.5 - a * log(4 * a)
            let y = Num.saturate(x)
            return y <= 1.0 / 12.0 ? sqrt(3 * y) : a * log(12 * y - b) + c
        }
    }

    /// Encoded value → linear.
    public func decode(_ x: Double) -> Double {
        switch self {
        case .linear:
            return x
        case .srgb:
            if x <= 0.04045 { return x / 12.92 }
            return Num.spow((x + 0.055) / 1.055, 2.4)
        case .gamma22:
            return Num.spow(x, 2.2)
        case .gamma18:
            return Num.spow(x, 1.8)
        case .rec709:
            if x < 0.081 { return x / 4.5 }
            return Num.spow((x + 0.099) / 1.099, 1 / 0.45)
        case .pq:
            let m1 = 2610.0 / 16384.0
            let m2 = 2523.0 / 4096.0 * 128.0
            let c1 = 3424.0 / 4096.0
            let c2 = 2413.0 / 4096.0 * 32.0
            let c3 = 2392.0 / 4096.0 * 32.0
            let e = pow(Num.saturate(x), 1 / m2)
            let num = Swift.max(e - c1, 0)
            let den = c2 - c3 * e
            return den == 0 ? 0 : pow(num / den, 1 / m1)
        case .hlg:
            let a = 0.17883277, b = 1 - 4 * 0.17883277, c = 0.5 - a * log(4 * a)
            let y = Num.saturate(x)
            return y <= 0.5 ? y * y / 3 : (exp((y - c) / a) + b) / 12
        }
    }

    public func encode(_ c: RGB) -> RGB { c.map(encode) }
    public func decode(_ c: RGB) -> RGB { c.map(decode) }
}

// MARK: - Correlated colour temperature

/// Kelvin/tint ↔ chromaticity. Photographic convention: the Planckian locus below
/// 4000 K (tungsten and candlelight really are blackbody radiators) and the CIE
/// daylight locus at and above 4000 K (daylight and flash are not) — which is what
/// makes 5500 K on a camera mean what photographers expect.
public enum ColorTemperature {

    /// Slider range from docs/04 (D9).
    public static let minKelvin: Double = 2000
    public static let maxKelvin: Double = 50000
    public static let minTint: Double = -150
    public static let maxTint: Double = 150

    /// One tint unit as a CIE-1960 v offset. 150 units ≈ 0.05 v — the full slider
    /// covers the green/magenta excursion real light sources produce.
    public static let tintUnitInV: Double = 0.05 / 150.0

    /// Chromaticity of the locus at `kelvin`, before any tint offset.
    ///
    /// The two loci disagree by about 0.007 in y where they meet, so switching
    /// between them at a hard boundary would put a visible tint step in the middle of
    /// the temperature slider. They are crossfaded over 3500–4500 K instead: the
    /// result is C¹-smooth, stays monotone, and is within measurement error of either
    /// source across the blend region.
    public static func locus(kelvin: Double) -> Chromaticity {
        let t = Num.clamp(kelvin, 1000, 100000)
        if t <= 3500 { return planckianLocus(t) }
        if t >= 4500 { return daylightLocus(t) }
        let w = Num.smoothstep(3500, 4500, t)
        let p = planckianLocus(t)
        let d = daylightLocus(t)
        return Chromaticity(Num.mix(p.x, d.x, w), Num.mix(p.y, d.y, w))
    }

    /// Kim et al. cubic fit to the Planckian locus — tungsten and candlelight really
    /// are blackbody radiators.
    public static func planckianLocus(_ kelvin: Double) -> Chromaticity {
        let t = Swift.max(kelvin, 1667)
        let x = planckX(t)
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        }
        return Chromaticity(x, y)
    }

    /// CIE daylight locus — daylight and flash are not blackbody radiators, and
    /// photographers' 5500 K intuition is built on this curve, not on Planck's.
    /// Fitted for 4000–25000 K; the high branch extrapolates smoothly above that so
    /// the 50000 K end of the slider stays monotone.
    public static func daylightLocus(_ kelvin: Double) -> Chromaticity {
        let t = Swift.max(kelvin, 1000)
        let x: Double
        if t <= 7000 {
            x = 0.244063 + 0.09911e3 / t + 2.9678e6 / (t * t) - 4.6070e9 / (t * t * t)
        } else {
            x = 0.237040 + 0.24748e3 / t + 1.9018e6 / (t * t) - 2.0064e9 / (t * t * t)
        }
        let y = -3.000 * x * x + 2.870 * x - 0.275
        return Chromaticity(x, y)
    }

    private static func planckX(_ t: Double) -> Double {
        if t <= 4000 {
            return -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t)
                + 0.8776956e3 / t + 0.179910
        }
        return -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t)
            + 0.2226347e3 / t + 0.240390
    }

    // MARK: - The magenta guard

    /// How much of a physical illuminant's cone response the guard insists survives.
    ///
    /// **The defect this exists for.** `ChromaticAdaptation.adapt` divides by the cone
    /// response of the illuminant it is adapting *from*. Push tint far enough toward
    /// magenta and the chromaticity leaves the region any light source occupies; the
    /// S (blue) cone response falls through zero, and the adaptation matrix passes
    /// through a pole and comes out the other side with a NEGATIVE blue gain. The
    /// picture does not merely go magenta, it inverts to full blue.
    ///
    /// That pole sits INSIDE the range the slider could be dragged to, and how far in
    /// depends on the temperature: the S cone crosses zero at tint +45 at 2000 K, +80
    /// at 2750 K, +185 at 5500 K. So on any warm frame the magenta half of the tint
    /// slider inverted the photograph somewhere before a third of its travel. The
    /// owner's first session reported it as "it goes from slightly blue to an entirely
    /// full blue visual", which is exactly what a sign flip in the blue gain looks
    /// like.
    ///
    /// **What the number means, and what it does not.** The floor is a ceiling on the
    /// blue gain of THIS adaptation — the pure tint move, as-shot equal to target —
    /// holding it at or below 1/0.15 ≈ 6.7×. A floor rather than a fixed tint limit is
    /// the right shape for that: the bound means the same thing at every temperature,
    /// and the tint it corresponds to falls out.
    ///
    /// It is not a ceiling on the blue gain of the matrix a photograph actually renders
    /// through, which composes this with the temperature move. At as-shot 5500 K,
    /// target 2800 K, tint +80 — clamped by this floor to +69.80 — the working-space
    /// blue gain is 17.7× and green is NEGATIVE. That is what `magentaMonotoneLimit`
    /// below measures and bounds, and why `tintLimit` is now the smaller of the two.
    ///
    /// **Why 0.15.** It is the largest floor that leaves the shipped ±150 tint range
    /// unclamped at and above 5500 K (the limit it implies at 5500 K is +156), so
    /// daylight and cooler edits render exactly as they did. Below that it engages
    /// progressively — +143 at 5000 K, +128 at 4500 K, +87 at 3200 K, +36 at 2000 K —
    /// which is the warm end where the pole actually sat. A higher floor (0.25 ⇒ +135
    /// at 5500 K) would start clamping ordinary daylight work; a lower one (0.05 ⇒
    /// +177) admits a 20× blue gain, which blows the channel out without help from any
    /// sign flip.
    public static let tintConeFloor: Double = 0.15

    /// The largest magenta tint at `kelvin` the render will honour: the smaller of the
    /// two bounds below — the illuminant must still describe a colour a light source
    /// could be (`tintConeFloor`), and the picture must still be going the way the
    /// slider says (`magentaMonotoneLimit`).
    ///
    /// Only the magenta direction is bounded. Green tint moves the chromaticity toward
    /// the interior of the plane, where every cone response grows; it is admissible
    /// across the whole range and is left alone.
    ///
    /// Monotone by construction — the S response falls strictly as tint rises — so a
    /// bisection finds the boundary exactly rather than approximately.
    ///
    /// MEMOIZED, because "called twice when a render plan is built" stopped being the
    /// whole story the day the WB eyedropper landed: `neutralizing` sweeps a few
    /// thousand (kelvin, tint) candidates and each one comes through
    /// `chromaticity(kelvin:tint:)` → `clampedTint` → here — a 40-step bisection with
    /// two cone evaluations per step, per candidate. The kelvin values repeat heavily
    /// (each kelvin is probed at dozens of tints), so a cache by exact kelvin turns
    /// ~6 000 bisections per eyedropper click into ~140 — and it matters more now that
    /// each of those is two bisections rather than one. The function is pure, so the
    /// cache cannot change an answer, only how often it is derived —
    /// `testTheTintLimitCacheServesTheBisectionsAnswer` holds the pair together.
    public static func tintLimit(kelvin: Double) -> Double {
        tintLimitLock.lock()
        if let held = tintLimitCache[kelvin] {
            tintLimitLock.unlock()
            return held
        }
        tintLimitLock.unlock()

        let limit = computeTintLimit(kelvin: kelvin)

        tintLimitLock.lock()
        // Whole-cache reset rather than LRU: entries are 16 bytes, the working set is
        // one eyedropper sweep, and an occasional cold refill is 140 bisections.
        if tintLimitCache.count >= 4096 { tintLimitCache.removeAll() }
        tintLimitCache[kelvin] = limit
        tintLimitComputations += 1
        tintLimitLock.unlock()
        return limit
    }

    private static let tintLimitLock = NSLock()
    private static var tintLimitCache: [Double: Double] = [:]
    /// How many times the bisection has actually run — the observable the cache's
    /// whole reason to exist is measured by. Test-only reader; guarded by the lock.
    static var tintLimitComputationCount: Int {
        tintLimitLock.lock()
        defer { tintLimitLock.unlock() }
        return tintLimitComputations
    }
    private static var tintLimitComputations = 0

    private static func computeTintLimit(kelvin: Double) -> Double {
        let physical = coneFloorLimit(kelvin: kelvin)
        return Swift.min(physical, magentaMonotoneLimit(kelvin: kelvin, ceiling: physical))
    }

    /// The original bound: the illuminant must still be a colour a light source could
    /// have, by `tintConeFloor`. Correct as far as it goes, and it is exactly as far as
    /// it goes that `magentaMonotoneLimit` exists for.
    private static func coneFloorLimit(kelvin: Double) -> Double {
        let base = unguardedConeResponse(kelvin: kelvin, tint: 0)
        guard base.r > 0, base.g > 0, base.b > 0 else { return maxTint }

        func admissible(_ t: Double) -> Bool {
            let c = unguardedConeResponse(kelvin: kelvin, tint: t)
            return c.r >= tintConeFloor * base.r
                && c.g >= tintConeFloor * base.g
                && c.b >= tintConeFloor * base.b
        }

        // The hard end of the slider. Above about 20000 K nothing in range offends,
        // and the bisection is skipped entirely.
        let ceiling = 300.0
        if admissible(ceiling) { return ceiling }

        var lo = 0.0
        var hi = ceiling
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if admissible(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: - The magenta bound, measured on the picture instead of on the illuminant

    /// The neutral the magenta bound is measured against: the daylight reference this
    /// project already names as "what a file recording no camera neutral adapts from"
    /// (`WhiteBalanceEngine.Neutral.reference`). Stated as a number here rather than
    /// read from there because the bound has to be a function of the TARGET Kelvin
    /// alone — `chromaticity(kelvin:tint:)` is handed nothing else, and the memo is
    /// keyed on nothing else.
    public static let magentaReferenceKelvin: Double = 5500

    /// **The defect the cone floor does not close.** `tintConeFloor` bounds the
    /// illuminant's own cone response, and it is verified on the DIAGONAL — as-shot
    /// equal to target, a pure tint move — where it is very nearly exact: the rendered
    /// green↔magenta axis turns round at +35.25 at 2000 K against a bound of +35.57,
    /// at +68.75 at 2800 K against +69.80, at +152.50 at 5500 K against +155.58.
    ///
    /// Off the diagonal it is not. A daylight-balanced file taken to a warm target is
    /// the ordinary way anybody uses the Temperature slider, and there the adaptation
    /// carries the illuminant's runaway AND the temperature move together. Measured on
    /// a 0.18 neutral, as-shot 5500 K:
    ///
    ///   · target 2800 K, tint +80 (the cone floor admits +69.80) renders
    ///     **RGB(0.0967, −0.0872, 3.1857)** — a negative green channel, blue at 17.7×
    ///     the neutral it started from, and an OKLab `a` of −0.089 against −0.038 with
    ///     no tint at all. The magenta slider moved the picture toward GREEN.
    ///   · target 2000 K, tint +40 (admits +35.57) renders RGB(0.0175, −0.3832, 6.4618).
    ///   · the axis reverses at +4 at 2000 K, +30 at 2500 K, +46 at 2800 K, +67 at
    ///     3200 K, +101 at 4000 K, +136 at 5000 K — every one of them inside the bound
    ///     the guard was handing out, and every one of them inside the slider.
    ///
    /// `TintGuardTests` says "no (Kelvin, tint) pair the app can ask for" inverts the
    /// picture, and sweeps only as-shot == target: the claim was broader than its
    /// coverage, which is why this went four audits without being seen.
    ///
    /// So the bound is now measured on the thing the photographer is looking at. The
    /// largest magenta tint at which the RENDERED neutral is still moving toward
    /// magenta, and still has three non-negative channels, against the reference
    /// neutral above. A dead top to the slider is an ordinary thing for a control to
    /// do; a control that turns round in the middle of its travel is the "it fights me"
    /// complaint, and a negative channel is not a colour at all.
    ///
    /// Green is untouched, as before — it moves toward the interior of the plane where
    /// every response grows — and so is everything at and above 5500 K. Daylight work
    /// renders exactly as it did; only the warm half of the temperature slider tightens.
    ///
    /// **READ THE MARGIN, NOT THE SENTENCE.** "Untouched at and above 5500 K" is true
    /// and it is true by 2.2 units: the bound at 5500 K is +152.22 against a shipped
    /// slider that stops at +150, and it first enters the shipped range at about
    /// 5430 K (5400 K is already +149.13). This bound is a function of the `locus` fit,
    /// and `locus` crossfades from the Planckian branch to the daylight branch through
    /// a smoothstep between 3500 and 4500 K — so a change anywhere near that fit moves
    /// the 5500 K number, and an inequality test that only asks "is it at least 150"
    /// would not notice until the margin had already become a clamp on ordinary
    /// daylight work. `testTheMagentaBoundKeepsItsDaylightMarginOnBothSides` pins the
    /// crossover from both sides for that reason.
    private static func magentaMonotoneLimit(kelvin: Double, ceiling: Double) -> Double {
        guard ceiling > 0 else { return ceiling }
        // A quarter of a tint unit: the finite difference across it is ~1e-5 of `a`
        // near the turn, ten orders of magnitude above double noise, and a twentieth of
        // the smallest step the slider can be dragged.
        let probe = 0.25

        /// Still going the way it says at `t`, and still a colour.
        func admissible(_ t: Double) -> Bool {
            guard let here = renderedMagenta(kelvin: kelvin, tint: t) else { return false }
            guard let ahead = renderedMagenta(kelvin: kelvin, tint: t + probe) else { return false }
            return ahead >= here
        }

        // Both halves of the predicate are downward-closed on [0, ceiling] — the
        // deflection is unimodal below the pole and the channels fail once and stay
        // failed — so a bisection lands on the boundary rather than merely near it.
        if admissible(ceiling) { return ceiling }
        var lo = 0.0
        var hi = ceiling
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if admissible(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Where a neutral at (Kelvin, tint) actually lands on the green↔magenta axis, in
    /// the working space, adapted to the reference neutral — `nil` when it lands
    /// somewhere that is not a colour.
    ///
    /// OKLab `a` rather than a linear-RGB opponent, because the runaway is a
    /// CHROMATICITY move and a linear opponent cannot see it turn: at 2800 K the
    /// linear `(r+b)/2 − g` goes on rising through the reversal purely because blue is
    /// exploding, while `a` — which normalizes against lightness the way the eye does
    /// — turns at +46 where the picture does. It is also the axis the rest of the
    /// colour engine already measures green↔magenta on (`ColorEngine.tintAxisDegrees`).
    private static func renderedMagenta(kelvin: Double, tint: Double) -> Double? {
        let base = locus(kelvin: kelvin)
        let source: Chromaticity
        if tint == 0 {
            source = base
        } else {
            let (u, v) = base.uv
            source = Chromaticity.fromUV(u: u, v: v + tint * tintUnitInV)
        }
        let destination = locus(kelvin: magentaReferenceKelvin)
        let adaptation = ChromaticAdaptation.adapt(from: source.xyz(), to: destination.xyz(),
                                                  cone: ChromaticAdaptation.cat16)
        let out = (workingFromXYZ * adaptation * workingToXYZ).apply(RGB(gray: LumenLog.midGrey))
        guard out.isFinite, out.minComponent >= 0 else { return nil }
        return OKLabTransform.working.toLab(out).a
    }

    /// `RGBColorSpace.toXYZ` is a computed property that runs a 3×3 inversion on every
    /// read, and the bound above reads it eighty times per uncached Kelvin. Derived
    /// once, from the same constants, so it is the same matrix.
    private static let workingToXYZ: Mat3 = RGBColorSpace.rec2020.toXYZ
    private static let workingFromXYZ: Mat3 = RGBColorSpace.rec2020.fromXYZ

    /// What `tint` is actually worth at `kelvin`, once physics has had its say.
    public static func clampedTint(kelvin: Double, tint: Double) -> Double {
        guard tint > 0 else { return tint }
        return Swift.min(tint, tintLimit(kelvin: kelvin))
    }

    /// The CAT16 cone response of the chromaticity a (Kelvin, tint) pair asks for,
    /// WITHOUT the guard — which is the quantity the guard is defined in terms of, and
    /// so the one function here that must not call `chromaticity(kelvin:tint:)`.
    private static func unguardedConeResponse(kelvin: Double, tint: Double) -> RGB {
        let base = locus(kelvin: kelvin)
        guard tint != 0 else { return ChromaticAdaptation.cat16.apply(base.xyz()) }
        let (u, v) = base.uv
        let c = Chromaticity.fromUV(u: u, v: v + tint * tintUnitInV)
        return ChromaticAdaptation.cat16.apply(c.xyz())
    }

    /// Chromaticity for a (Kelvin, tint) pair. Tint offsets perpendicular to the
    /// locus in CIE 1960 uv — positive tint toward magenta, negative toward green,
    /// matching every photographic UI ever shipped.
    ///
    /// Magenta is bounded by `tintLimit(kelvin:)`. Past that bound the slider goes on
    /// moving and the picture stops changing, which is an ordinary thing for a control
    /// to do and the thing it did before was invert the photograph. The panel range is
    /// deliberately NOT narrowed to match: the bound moves with temperature, so a
    /// contracting slider would either strand the readout above what the render used
    /// or rewrite a tint the photographer had set, and losing his number while he
    /// scrubs the temperature past a warm value and back is worse than a slider whose
    /// last few points are inert on a 2000 K frame.
    public static func chromaticity(kelvin: Double, tint: Double) -> Chromaticity {
        let base = locus(kelvin: kelvin)
        let guarded = clampedTint(kelvin: kelvin, tint: tint)
        guard guarded != 0 else { return base }
        let (u, v) = base.uv
        return Chromaticity.fromUV(u: u, v: v + guarded * tintUnitInV)
    }

    /// Inverse of `chromaticity(kelvin:tint:)`, and exactly its inverse over the
    /// range that function can represent — its magenta half is bounded by
    /// `tintLimit(kelvin:)`, and a colour sampled from beyond that bound reports the
    /// tint the render would actually use rather than one it would silently pull in.
    ///
    /// Tint offsets the v coordinate and leaves u alone, so the temperature is
    /// recovered by matching **u** — not by finding the nearest point on the locus.
    /// Nearest-point looks equivalent and is not: the locus is curved, so a colour a
    /// long way off it in v is closest to a *different* temperature than the one it
    /// came from. At 5500 K with tint −80 that error was 2850 K.
    ///
    /// Searched coarse-to-fine in mired space, which is the axis that is perceptually
    /// even in Kelvin and the reason every camera UI steps in mireds underneath.
    public static func temperatureAndTint(for chroma: Chromaticity) -> (kelvin: Double, tint: Double) {
        let (u, v) = chroma.uv
        let minMired = 1e6 / maxKelvin
        let maxMired = 1e6 / minKelvin

        func uError(atMired m: Double) -> Double {
            abs(locus(kelvin: 1e6 / m).uv.u - u)
        }

        var bestMired = 1e6 / 5500
        var best = Double.infinity
        var m = minMired
        while m <= maxMired {
            let e = uError(atMired: m)
            if e < best {
                best = e
                bestMired = m
            }
            m += 0.5
        }

        var step = 0.25
        for _ in 0..<12 {
            let lower = Swift.max(minMired, bestMired - step)
            let upper = Swift.min(maxMired, bestMired + step)
            let a = uError(atMired: lower)
            let b = uError(atMired: upper)
            if a < best { best = a; bestMired = lower }
            if b < best { best = b; bestMired = upper }
            step /= 2
        }

        let kelvin = Num.clamp(1e6 / bestMired, minKelvin, maxKelvin)
        let tint = (v - locus(kelvin: kelvin).uv.v) / tintUnitInV
        return (kelvin, clampedTint(kelvin: kelvin, tint: Num.clamp(tint, -300, 300)))
    }
}
