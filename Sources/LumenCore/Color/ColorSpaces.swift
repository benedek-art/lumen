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

    /// von Kries-style adaptation in the given cone space: XYZ(source white) → XYZ(dest white).
    public static func adapt(from source: RGB, to destination: RGB, cone: Mat3) -> Mat3 {
        let s = cone.apply(source)
        let d = cone.apply(destination)
        let gains = RGB(d.r / s.r, d.g / s.g, d.b / s.b)
        return cone.inverse * Mat3.diagonal(gains) * cone
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

    /// Chromaticity for a (Kelvin, tint) pair. Tint offsets perpendicular to the
    /// locus in CIE 1960 uv — positive tint toward magenta, negative toward green,
    /// matching every photographic UI ever shipped.
    public static func chromaticity(kelvin: Double, tint: Double) -> Chromaticity {
        let base = locus(kelvin: kelvin)
        guard tint != 0 else { return base }
        let (u, v) = base.uv
        return Chromaticity.fromUV(u: u, v: v + tint * tintUnitInV)
    }

    /// Inverse: nearest locus temperature and the perpendicular tint offset.
    /// Uses a coarse-to-fine search in mired space (perceptually even in Kelvin,
    /// which is why every camera UI steps in mireds under the hood).
    public static func temperatureAndTint(for chroma: Chromaticity) -> (kelvin: Double, tint: Double) {
        let (u, v) = chroma.uv
        var bestT = 5500.0
        var bestD = Double.infinity
        // Mired sweep: 1e6/50000 = 20 to 1e6/2000 = 500.
        var mired = 20.0
        while mired <= 500 {
            let t = 1e6 / mired
            let (lu, lv) = locus(kelvin: t).uv
            let d = (lu - u) * (lu - u) + (lv - v) * (lv - v)
            if d < bestD {
                bestD = d
                bestT = t
            }
            mired += 0.5
        }
        // Refine around the best mired with a finer step.
        let coarse = 1e6 / bestT
        var m = Swift.max(20.0, coarse - 1.0)
        let end = Swift.min(500.0, coarse + 1.0)
        while m <= end {
            let t = 1e6 / m
            let (lu, lv) = locus(kelvin: t).uv
            let d = (lu - u) * (lu - u) + (lv - v) * (lv - v)
            if d < bestD {
                bestD = d
                bestT = t
            }
            m += 0.02
        }
        let (bu, bv) = locus(kelvin: bestT).uv
        _ = bu
        let tint = (v - bv) / tintUnitInV
        return (Num.clamp(bestT, minKelvin, maxKelvin), Num.clamp(tint, -300, 300))
    }
}
