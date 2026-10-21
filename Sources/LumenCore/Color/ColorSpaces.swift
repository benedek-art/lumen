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
    /// including a von Kries adaptation in `cone` space when the white points differ.
    ///
    /// CAT16 by default, because inside the engine adaptation is a model of the eye
    /// (docs/04, D9). A caller standing in for an ICC conversion — the soft proof, which
    /// promises what ColorSync will write into the file — passes
    /// `ChromaticAdaptation.bradford`, because that is what the D50 profile connection
    /// space uses, and the two disagree by up to 0.022 in a coefficient between
    /// Rec.2020 and ProPhoto. Between two D65 spaces the cone never enters.
    public func matrix(to other: RGBColorSpace,
                       cone: Mat3 = ChromaticAdaptation.cat16) -> Mat3 {
        var m = toXYZ
        if white != other.white {
            m = ChromaticAdaptation.adapt(from: white.xyz(), to: other.white.xyz(),
                                          cone: cone) * m
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
    /// matching the ICC convention matters more than matching our own. The soft proof
    /// uses it (`SoftProofTransform`, `SoftProof.isOutOfGamut`), because the file it
    /// previews is converted by ColorSync through the D50 PCS with exactly this.
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

/// Kelvin/tint ↔ chromaticity, in the Adobe / DNG SDK convention (WS-03).
///
/// **One convention, both ends.** The as-shot pair a camera file reports
/// (`CIRAWFilter.neutralTemperature`/`neutralTint`, a sidecar's `asShotKelvin`) is in
/// the DNG SDK's convention: Robertson isotemperature lines in CIE 1960 uv, tint as the
/// signed distance ALONG the isotherm, `kTintScale` −3000 (`DNGTemperature`). Lumen used
/// to read that pair, and the photographer's target pair, with a locus of its own (Kim's
/// Planckian fit crossfaded into the CIE daylight locus, tint as a pure +v offset), so
/// "5500 / +10" meant Adobe's 5309 / +17, the as-shot point was misread by up to 7 mired,
/// and the tint axis ran 48° off the isotherm at daylight — −tint rendered yellow-green
/// and +tint blue-violet (docs/quality/lanes/WS-03/AUDIT.md, findings 1–3).
///
/// Now `chromaticity(kelvin:tint:)` IS `DNGTemperature.chromaticity` below the magenta
/// guard, for the target and for the as-shot pair alike. Typing Lightroom's numbers for
/// a light neutralises a grey lit by it, a preset means the Adobe light of the same
/// name, and the tint slider moves along the isotherm — green one way, magenta the other.
public enum ColorTemperature {

    /// Slider range from docs/04 (D9).
    public static let minKelvin: Double = 2000
    public static let maxKelvin: Double = 50000
    public static let minTint: Double = -150
    public static let maxTint: Double = 150

    /// The tint-0 point at `kelvin`: the Robertson blackbody point of the DNG SDK table
    /// (`DNGTemperature.chromaticity(kelvin:tint: 0)`). Daylight illuminants sit about
    /// +10 tint off it, which is why the Daylight preset is 5500 / +10.
    public static func locus(kelvin: Double) -> Chromaticity {
        DNGTemperature.chromaticity(kelvin: Num.clamp(kelvin, 1000, 100000), tint: 0)
    }

    /// Kim et al. cubic fit to the Planckian locus. No longer what white balance is
    /// built on (that is `DNGTemperature`'s table); kept as an independent reference
    /// curve for colour-science checks.
    public static func planckianLocus(_ kelvin: Double) -> Chromaticity {
        let t = Swift.max(kelvin, 1667)
        let x = planckX(t)
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return Chromaticity(x, y)
    }

    /// CIE daylight locus, 4000–25000 K (extrapolated smoothly above). Like
    /// `planckianLocus`, a reference curve only.
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
    /// `ChromaticAdaptation.adapt` divides by the cone response of the illuminant it is
    /// adapting *from*. Push tint far enough toward magenta and that chromaticity leaves
    /// the region any light source occupies; the S (blue) cone response falls through
    /// zero and the adaptation passes through a pole and comes out with a NEGATIVE blue
    /// gain — the picture inverts to full blue (the owner's "slightly blue to an
    /// entirely full blue visual").
    ///
    /// This is the illuminant half of the guard: it bounds the target's own cone
    /// response, so it is a function of the target Kelvin alone, and it is what
    /// `chromaticity(kelvin:tint:)`, `clampedTint(kelvin:tint:)` and
    /// `temperatureAndTint(for:)` apply. On the DNG axis 0.15 gives +36 at 2000 K, +59 at
    /// 2500 K, +78 at 2850 K, +153 at 4000 K, +190 at 4500 K and +271 at 5500 K; above
    /// about 6000 K the whole ±300 hard range is admissible.
    ///
    /// The picture half — the rendered neutral must keep moving toward magenta, and
    /// keep three non-negative channels — depends on the as-shot neutral as well, and is
    /// `tintLimit(kelvin:asShot:)`. That one is never looser than this.
    public static let tintConeFloor: Double = 0.15

    /// The largest magenta tint at `kelvin` whose illuminant is still a colour a light
    /// source could be (`tintConeFloor`). As-shot independent; see
    /// `tintLimit(kelvin:asShot:)` for the bound the render applies.
    ///
    /// Only the magenta direction is bounded here. Green tint moves the chromaticity
    /// toward the interior of the plane, where every cone response grows.
    ///
    /// MEMOIZED by exact Kelvin: `neutralizing` probes a few thousand (Kelvin, tint)
    /// candidates over a few hundred distinct Kelvins.
    public static func tintLimit(kelvin: Double) -> Double {
        tintLimitLock.lock()
        if let held = tintLimitCache[kelvin] {
            tintLimitLock.unlock()
            return held
        }
        tintLimitLock.unlock()

        let limit = coneFloorLimit(kelvin: kelvin)

        tintLimitLock.lock()
        if tintLimitCache.count >= 4096 { tintLimitCache.removeAll() }
        tintLimitCache[kelvin] = limit
        tintLimitComputations += 1
        tintLimitLock.unlock()
        return limit
    }

    private static let tintLimitLock = NSLock()
    private static var tintLimitCache: [Double: Double] = [:]
    /// How many times the cone-floor bisection has actually run. Test-only reader;
    /// guarded by the lock.
    static var tintLimitComputationCount: Int {
        tintLimitLock.lock()
        defer { tintLimitLock.unlock() }
        return tintLimitComputations
    }
    private static var tintLimitComputations = 0

    private static func coneFloorLimit(kelvin: Double) -> Double {
        let base = unguardedConeResponse(kelvin: kelvin, tint: 0)
        guard base.r > 0, base.g > 0, base.b > 0 else { return maxTint }

        func admissible(_ t: Double) -> Bool {
            let c = unguardedConeResponse(kelvin: kelvin, tint: t)
            return c.r >= tintConeFloor * base.r
                && c.g >= tintConeFloor * base.g
                && c.b >= tintConeFloor * base.b
        }

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

    /// The CAT16 cone response of the chromaticity a (Kelvin, tint) pair asks for,
    /// WITHOUT the guard.
    private static func unguardedConeResponse(kelvin: Double, tint: Double) -> RGB {
        let k = Num.clamp(kelvin, 1000, 100000)
        return ChromaticAdaptation.cat16.apply(
            DNGTemperature.chromaticity(kelvin: k, tint: tint).xyz())
    }

    /// What `tint` is worth at `kelvin` by the illuminant bound alone.
    public static func clampedTint(kelvin: Double, tint: Double) -> Double {
        guard tint > 0 else { return tint }
        return Swift.min(tint, tintLimit(kelvin: kelvin))
    }

    // MARK: - The magenta bound, measured on the picture the as-shot neutral makes

    /// How far the rendered neutral's OKLab `a` may fall below the most magenta it has
    /// reached, as tint rises, before the guard stops the slider there.
    ///
    /// The bound used to be "the largest tint at which `a` is still rising", measured
    /// against a FIXED 5500 K neutral, because `chromaticity(kelvin:tint:)` is handed
    /// nothing else. Both halves were wrong on the DNG axis. The picture a tint move
    /// makes is the adaptation from the target TO THE AS-SHOT neutral, and with a cool
    /// as-shot and a warm target it turns round much earlier than against 5500 K
    /// (as-shot 12000 / +10 → 2000 K: `a` peaks at tint −15 and falls 0.0095 by tint
    /// 0); a naive port of the old guard fails the no-inversion grid at 0.0145. And a
    /// strict "still rising" test clamps ordinary work for nothing: at as-shot 7500 / +10
    /// and 2500 K, `a` flattens at +22 and has fallen 0.001 by +30, invisible, but a
    /// strict bound would make +22…+150 inert on a tungsten edit of a shade frame.
    ///
    /// 0.002 is two-thirds of the 0.003 the spec allows (SPEC line 8) and a tenth of
    /// the OKLab chroma a +10 tint move makes at daylight, so the turn it permits is
    /// below what anyone can see while the slider stays live where the picture is
    /// still changing the way it says.
    static let magentaSlack: Double = 0.002

    /// The largest tint at `kelvin` the render honours, given the neutral it adapts TO.
    ///
    /// The smaller of the illuminant bound (`tintLimit(kelvin:)`) and the picture
    /// bound: scanning tint upward from −300, the first tint at which a 0.18 neutral
    /// adapted from (kelvin, tint) to `asShot` either has a negative or non-finite
    /// channel, or has fallen more than `magentaSlack` in OKLab `a` below the most
    /// magenta it reached. CAN BE NEGATIVE: with a cool as-shot and a very warm target
    /// the green↔magenta axis turns before tint 0, and everything above the turn renders
    /// as the turn does.
    ///
    /// It does not clamp ordinary work: for every as-shot from 2850 K to 9365 K there
    /// is no clamp at tint ≤ +25 for Temp ≥ 2500 K, and from a 5500 / +10 as-shot none at
    /// +150 for Temp ≥ 4500 K (`TintGuardTests`).
    ///
    /// Memoized by (Kelvin, as-shot); the as-shot argument is read the way
    /// `WhiteBalanceEngine.adaptation` reads it (its own illuminant bound applied).
    public static func tintLimit(kelvin: Double, asShot: (kelvin: Double, tint: Double)) -> Double {
        let key = PictureBoundKey(kelvin: kelvin, asShotKelvin: asShot.kelvin,
                                  asShotTint: asShot.tint)
        pictureLock.lock()
        if let held = pictureCache[key] {
            pictureLock.unlock()
            return held
        }
        pictureLock.unlock()

        let limit = pictureBound(kelvin: kelvin, asShot: asShot)

        pictureLock.lock()
        if pictureCache.count >= 8192 { pictureCache.removeAll() }
        pictureCache[key] = limit
        pictureLock.unlock()
        return limit
    }

    /// What `tint` is actually worth at `kelvin` when the render adapts to `asShot`:
    /// the tint `WhiteBalanceEngine.adaptation` uses. Unlike `clampedTint(kelvin:tint:)`
    /// it can bound a green tint, when the picture's axis turns before zero.
    public static func clampedTint(kelvin: Double, tint: Double,
                                   asShot: (kelvin: Double, tint: Double)) -> Double {
        Swift.min(tint, tintLimit(kelvin: kelvin, asShot: asShot))
    }

    private struct PictureBoundKey: Hashable {
        let kelvin: Double
        let asShotKelvin: Double
        let asShotTint: Double
    }
    private static let pictureLock = NSLock()
    private static var pictureCache: [PictureBoundKey: Double] = [:]

    /// `RGBColorSpace.toXYZ` re-derives a 3×3 inverse on every read; the bound reads it
    /// hundreds of times per uncached Kelvin. Derived once, from the same constants.
    private static let workingToXYZ: Mat3 = RGBColorSpace.rec2020.toXYZ
    private static let workingFromCone: Mat3 =
        RGBColorSpace.rec2020.fromXYZ * ChromaticAdaptation.cat16Inverse
    private static let greyCone: RGB =
        ChromaticAdaptation.cat16.apply(workingToXYZ.apply(RGB(gray: 0.18)))

    private static func pictureBound(kelvin: Double,
                                     asShot: (kelvin: Double, tint: Double)) -> Double {
        let ceiling = tintLimit(kelvin: kelvin)
        let k = Num.clamp(kelvin, 1000, 100000)
        let destination = ChromaticAdaptation.cat16.apply(
            chromaticity(kelvin: asShot.kelvin, tint: asShot.tint).xyz())
        // Tint is linear along the (blended) isotherm at a fixed Kelvin, so two points
        // fix the whole line in uv.
        let origin = DNGTemperature.chromaticity(kelvin: k, tint: 0).uv
        let unit = DNGTemperature.chromaticity(kelvin: k, tint: 1).uv
        let du = unit.u - origin.u
        let dv = unit.v - origin.v
        let grey = greyCone
        let out = workingFromCone

        /// OKLab `a` of the rendered neutral at `t`, or nil when it is not a colour.
        func magenta(_ t: Double) -> Double? {
            let source = Chromaticity.fromUV(u: origin.u + du * t, v: origin.v + dv * t)
            let s = ChromaticAdaptation.cat16.apply(source.xyz())
            guard s.r > 0, s.g > 0, s.b > 0 else { return nil }
            let rgb = out.apply(RGB(grey.r * destination.r / s.r,
                                    grey.g * destination.g / s.g,
                                    grey.b * destination.b / s.b))
            guard rgb.isFinite, rgb.minComponent >= 0 else { return nil }
            return OKLabTransform.working.toLab(rgb).a
        }

        var peak: Double?
        var lastGood: Double?
        var t = -300.0
        var failedAt: Double?
        while t <= ceiling {
            if let a = magenta(t) {
                if let p = peak, a < p - magentaSlack { failedAt = t; break }
                peak = Swift.max(peak ?? a, a)
                lastGood = t
            } else if peak != nil {
                failedAt = t
                break
            }
            t += 1
        }
        guard let start = lastGood, var top = peak else { return -300 }
        let end: Double
        if let failedAt {
            end = failedAt
        } else {
            // The scan ran out below the illuminant bound; the bound itself decides.
            if let a = magenta(ceiling), a >= top - magentaSlack { return ceiling }
            end = ceiling
        }
        // Refine the last unit step finely, carrying the running maximum.
        var good = start
        var probe = start + 0.05
        while probe < end {
            guard let a = magenta(probe), a >= top - magentaSlack else { break }
            top = Swift.max(top, a)
            good = probe
            probe += 0.05
        }
        return Swift.min(good, ceiling)
    }

    // MARK: - The conversion

    /// Chromaticity for a (Kelvin, tint) pair: `DNGTemperature.chromaticity` with the
    /// magenta half bounded by the illuminant guard `tintLimit(kelvin:)`. Positive tint
    /// is magenta correction (a greener light), negative green, as in Lightroom.
    ///
    /// This is the single entry point white balance converts through, for the target
    /// pair and the as-shot pair alike, so a pair that was never moved maps to the same
    /// point it came from and Temp/Tint numbers mean what they mean in Adobe's tools.
    public static func chromaticity(kelvin: Double, tint: Double) -> Chromaticity {
        let k = Num.clamp(kelvin, 1000, 100000)
        return DNGTemperature.chromaticity(kelvin: k, tint: clampedTint(kelvin: k, tint: tint))
    }

    /// Inverse of `chromaticity(kelvin:tint:)`, exact to ~1e-9 over the range it can
    /// represent.
    ///
    /// Seeded with the SDK's own inverse (`DNGTemperature.temperatureAndTint`), which is
    /// NOT an exact inverse of the forward direction off the table rows — up to 0.033
    /// mired and 0.0016 tint, by design of the SDK (it interpolates by distance to two
    /// non-parallel isotherms) — and polished by Newton steps on the forward map so that
    /// a round trip returns the pair it started from. A colour from beyond the magenta
    /// guard reports the tint the guard would use.
    public static func temperatureAndTint(for chroma: Chromaticity) -> (kelvin: Double, tint: Double) {
        let seed = DNGTemperature.temperatureAndTint(for: chroma)
        guard seed.kelvin.isFinite, seed.tint.isFinite, seed.kelvin > 0 else {
            return (WhiteBalanceEngine.Neutral.reference.kelvin, 0)
        }
        let target = chroma.uv
        var mired = Num.clamp(1e6 / seed.kelvin, 10, 1000)
        var tint = seed.tint
        func uv(_ m: Double, _ t: Double) -> (u: Double, v: Double) {
            DNGTemperature.chromaticity(kelvin: 1e6 / m, tint: t).uv
        }
        for _ in 0..<8 {
            let here = uv(mired, tint)
            let ru = target.u - here.u
            let rv = target.v - here.v
            if abs(ru) < 1e-15 && abs(rv) < 1e-15 { break }
            let h = 1e-4
            let am = uv(mired + h, tint)
            let at = uv(mired, tint + h)
            let a = (am.u - here.u) / h, b = (at.u - here.u) / h
            let c = (am.v - here.v) / h, d = (at.v - here.v) / h
            let det = a * d - b * c
            guard det != 0, det.isFinite else { break }
            mired = Num.clamp(mired + (d * ru - b * rv) / det, 10, 1000)
            tint += (a * rv - c * ru) / det
        }
        let kelvin = Num.clamp(1e6 / mired, minKelvin, maxKelvin)
        return (kelvin, clampedTint(kelvin: kelvin, tint: Num.clamp(tint, -300, 300)))
    }
}
