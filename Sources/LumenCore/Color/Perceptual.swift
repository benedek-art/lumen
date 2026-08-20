// Perceptual.swift
// The two perceptual models the engine is allowed to use, and the gamut machinery
// that keeps colour tools from writing values the display transform will later mangle.
//
//  · OKLab / OKLCh — hue-selective tools (mixer bands, point colour, hue equalizer).
//    Cheap, hue-linear enough for band selection, and stable under the extreme
//    chroma scene-referred data reaches.
//  · Lumen UCS — OKLab plus a Helmholtz–Kohlrausch brightness term, used for
//    saturation / vibrance / brilliance so that chroma moves hold *perceived*
//    brightness constant (docs/14 §5.4, D21). Naive HSL cannot do this; it is why
//    LR's saturation slider makes blues look like they dimmed.
//
// Clean-room note: the H-K predictor is Nayatani's published VAC/VCC form, used as a
// measured psychophysical fact, not transcribed from any implementation.
//
// No stage ever persists a buffer in a perceptual space (docs/14 §1.3) — these are
// convert, operate, convert back.

import Foundation

// MARK: - OKLab

public struct OKLab: Equatable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Hue in degrees, [0, 360).
    public var hue: Double { Num.wrapHue(atan2(b, a) * 180 / .pi) }

    public var lch: OKLCh { OKLCh(L: L, C: chroma, h: hue) }
}

public struct OKLCh: Equatable, Sendable {
    public var L: Double
    public var C: Double
    public var h: Double     // degrees

    public init(L: Double, C: Double, h: Double) {
        self.L = L
        self.C = C
        self.h = h
    }

    public var lab: OKLab {
        let r = h * .pi / 180
        return OKLab(L: L, a: C * cos(r), b: C * sin(r))
    }
}

public enum OKLabTransform {

    /// XYZ (D65) → OKLab LMS cone space (Björn Ottosson's published matrix).
    public static let xyzToLMS = Mat3(
        0.8189330101, 0.3618667424, -0.1288597137,
        0.0329845436, 0.9293118715, 0.0361456387,
        0.0482003018, 0.2643662691, 0.6338517070)

    /// Nonlinear LMS → Lab.
    public static let lmsToLab = Mat3(
        0.2104542553, 0.7936177850, -0.0040720468,
        1.9779984951, -2.4285922050, 0.4505937099,
        0.0259040371, 0.7827717662, -0.8086757660)

    /// Cached matrix pair for one working space, so per-pixel work is two matrix
    /// multiplies and a cube root rather than a chain of derivations.
    public struct Context: Sendable {
        public let rgbToLMS: Mat3
        public let lmsToRGB: Mat3

        public init(space: RGBColorSpace) {
            // OKLab is defined at D65; adapt if a caller ever hands us a D50 space.
            var toXYZ = space.toXYZ
            if space.white != WhitePoint.d65 {
                toXYZ = ChromaticAdaptation.cat16(from: space.white, to: WhitePoint.d65) * toXYZ
            }
            var toLMS = xyzToLMS * toXYZ

            // Normalize so that RGB(1,1,1) produces equal cone responses. Rec.2020's
            // white point and the matrix's own D65 differ in the fourth decimal, which
            // is enough to leave a grey with ~1e-4 of chroma — invisible on its own,
            // but it means "neutral stays neutral" would be approximately rather than
            // exactly true, and every colour stage downstream would inherit the error.
            let white = toLMS.apply(RGB.one)
            if white.minComponent > 1e-9 {
                toLMS = Mat3.diagonal(RGB(1 / white.r, 1 / white.g, 1 / white.b)) * toLMS
            }
            self.rgbToLMS = toLMS
            self.lmsToRGB = toLMS.inverse
        }

        public func toLab(_ c: RGB) -> OKLab {
            let lms = rgbToLMS.apply(c)
            let n = RGB(Num.spow(lms.r, 1.0 / 3.0),
                        Num.spow(lms.g, 1.0 / 3.0),
                        Num.spow(lms.b, 1.0 / 3.0))
            let lab = lmsToLab.apply(n)
            return OKLab(L: lab.r, a: lab.g, b: lab.b)
        }

        public func toRGB(_ lab: OKLab) -> RGB {
            let n = lmsToLab.inverse.apply(RGB(lab.L, lab.a, lab.b))
            let lms = RGB(n.r * n.r * n.r, n.g * n.g * n.g, n.b * n.b * n.b)
            return lmsToRGB.apply(lms)
        }

        public func toLCh(_ c: RGB) -> OKLCh { toLab(c).lch }
        public func toRGB(_ lch: OKLCh) -> RGB { toRGB(lch.lab) }
    }

    /// The working-space context — every colour stage uses this one.
    public static let working = Context(space: .rec2020)
}

// MARK: - Helmholtz–Kohlrausch

public enum HelmholtzKohlrausch {

    /// Nayatani's hue-dependent q(θ), θ in degrees. Saturated yellows read brighter
    /// than equally-luminant blues; this term is the size of that effect by hue.
    public static func q(hueDegrees: Double) -> Double {
        let t = Num.wrapHue(hueDegrees) * .pi / 180
        return -0.01585
            - 0.03017 * cos(t) - 0.04556 * cos(2 * t)
            - 0.04256 * cos(3 * t) - 0.00295 * cos(4 * t)
            + 0.14592 * sin(t) + 0.05084 * sin(2 * t)
            - 0.01900 * sin(3 * t) - 0.00764 * sin(4 * t)
    }

    /// Adaptation-luminance term. Fixed at the ISO 12646 viewing condition Lumen's
    /// assessment mode targets (160 cd/m²) — a constant here, a preference later.
    public static let kBr: Double = 0.2717 * (6.469 + 6.362 * pow(160.0, 0.4495))
        / (6.469 + pow(160.0, 0.4495))

    /// Perceived-brightness multiplier for a colour at (chroma, hue) in OKLab units.
    /// Returns 1 for neutrals — a grey never gets an H-K boost, which is the property
    /// that keeps the whole model well-behaved on the neutral axis.
    public static func brightnessFactor(chroma: Double, hue: Double) -> Double {
        // OKLab chroma ~0.4 is about as saturated as real surface colour gets;
        // scale it into the "saturation" argument Nayatani's model expects.
        let s = Swift.max(0, chroma) * 4.0
        return 1 + (-0.1340 * q(hueDegrees: hue) + 0.0872 * kBr) * s * 0.1
    }
}

// MARK: - Lumen UCS

/// OKLCh with the H-K correction folded in: `J` is perceived brightness, `C` chroma,
/// `h` hue. The invariant the engine relies on: changing `C` and converting back
/// leaves `J` unchanged, so saturation never silently changes apparent lightness.
public struct UCS: Equatable, Sendable {
    public var J: Double
    public var C: Double
    public var h: Double

    public init(J: Double, C: Double, h: Double) {
        self.J = J
        self.C = C
        self.h = h
    }
}

public enum LumenUCS {

    public static func fromRGB(_ c: RGB, context: OKLabTransform.Context = OKLabTransform.working) -> UCS {
        let lch = context.toLCh(c)
        let f = HelmholtzKohlrausch.brightnessFactor(chroma: lch.C, hue: lch.h)
        return UCS(J: lch.L * f, C: lch.C, h: lch.h)
    }

    public static func toRGB(_ u: UCS, context: OKLabTransform.Context = OKLabTransform.working) -> RGB {
        let f = HelmholtzKohlrausch.brightnessFactor(chroma: u.C, hue: u.h)
        let L = f == 0 ? u.J : u.J / f
        return context.toRGB(OKLCh(L: L, C: u.C, h: u.h))
    }

    /// Scale chroma while holding perceived brightness and hue — the operation every
    /// saturation-like control in Lumen is built from.
    public static func scaleChroma(_ c: RGB, by factor: Double,
                                   context: OKLabTransform.Context = OKLabTransform.working) -> RGB {
        var u = fromRGB(c, context: context)
        u.C = Swift.max(0, u.C * factor)
        return toRGB(u, context: context)
    }

    /// Scale perceived brightness while holding chroma ratio and hue — the inverse
    /// invariant (docs/14 §5.4: "luminance moves preserve chroma ratios").
    public static func scaleBrightness(_ c: RGB, by factor: Double,
                                       context: OKLabTransform.Context = OKLabTransform.working) -> RGB {
        var u = fromRGB(c, context: context)
        guard u.J != 0 else { return c }
        let newJ = u.J * factor
        // Chroma scales with brightness so the colour keeps its ratio rather than
        // washing out (the LR luminance-slider-desaturates artifact, engineered away).
        u.C *= factor > 0 ? factor : 0
        u.J = newJ
        return toRGB(u, context: context)
    }
}

// MARK: - Gamut

public enum Gamut {

    /// Largest chroma at (L, h) that stays inside `space`, found by bisection on the
    /// in-gamut predicate. 24 iterations resolves chroma to ~1e-7 — far below any
    /// visible step, and the result is cached into a per-hue LUT by callers.
    public static func maxChroma(L: Double, hue: Double,
                                 context: OKLabTransform.Context = OKLabTransform.working,
                                 limit: Double = 0.5) -> Double {
        guard L > 0, L < 1 else { return 0 }
        var lo = 0.0
        var hi = limit
        if inside(context.toRGB(OKLCh(L: L, C: hi, h: hue))) { return hi }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if inside(context.toRGB(OKLCh(L: L, C: mid, h: hue))) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    private static func inside(_ c: RGB, epsilon: Double = 1e-6) -> Bool {
        c.minComponent >= -epsilon && c.maxComponent <= 1 + epsilon
    }

    /// A per-hue table of max chroma at a set of lightness slices — the "precomputed
    /// per-hue max-chroma LUT" docs/14 §5.4 requires colour stages to soft-clip against.
    public struct Boundary: Sendable {
        public let hueSteps: Int
        public let lightnessSteps: Int
        public let table: [Double]     // hueSteps × lightnessSteps

        public init(hueSteps: Int = 36, lightnessSteps: Int = 17,
                    context: OKLabTransform.Context = OKLabTransform.working) {
            self.hueSteps = hueSteps
            self.lightnessSteps = lightnessSteps
            var t = [Double](repeating: 0, count: hueSteps * lightnessSteps)
            for hi in 0..<hueSteps {
                let h = Double(hi) * 360.0 / Double(hueSteps)
                for li in 0..<lightnessSteps {
                    let L = Double(li) / Double(lightnessSteps - 1)
                    // Qualified: `Boundary` has its own `maxChroma(L:hue:)`, which
                    // would otherwise shadow the bisection we actually want here.
                    t[hi * lightnessSteps + li] = Gamut.maxChroma(L: L, hue: h,
                                                                  context: context)
                }
            }
            self.table = t
        }

        public func maxChroma(L: Double, hue: Double) -> Double {
            // Guarded for the same reason the tables are: a non-finite coordinate
            // would reach `Int()` and trap rather than merely look wrong.
            guard L.isFinite, hue.isFinite else { return 0 }
            let h = Num.wrapHue(hue) / 360 * Double(hueSteps)
            let h0 = Int(h) % hueSteps
            let h1 = (h0 + 1) % hueSteps
            let ht = h - Double(Int(h))
            let l = Num.saturate(L) * Double(lightnessSteps - 1)
            let l0 = Swift.min(Int(l), lightnessSteps - 1)
            let l1 = Swift.min(l0 + 1, lightnessSteps - 1)
            let lt = l - Double(l0)
            let a = Num.mix(table[h0 * lightnessSteps + l0], table[h0 * lightnessSteps + l1], lt)
            let b = Num.mix(table[h1 * lightnessSteps + l0], table[h1 * lightnessSteps + l1], lt)
            return Num.mix(a, b, ht)
        }
    }

    /// Soft-clip chroma toward the boundary at constant hue and lightness. Below
    /// `threshold` of the boundary nothing moves; above it, chroma compresses
    /// asymptotically so no colour tool can produce a value the display transform
    /// would have to clip per-channel (which is what turns pushed reds into neon).
    public static func softClip(_ c: RGB, boundary: Boundary, threshold: Double = 0.8,
                                context: OKLabTransform.Context = OKLabTransform.working) -> RGB {
        let lch = context.toLCh(c)
        guard lch.C > 0, lch.L > 0, lch.L < 1 else { return c }
        let maxC = boundary.maxChroma(L: lch.L, hue: lch.h)
        guard maxC > 0 else { return c }
        let t = threshold * maxC
        guard lch.C > t else { return c }
        // Reinhard-style compression of the excess: the boundary is approached but
        // never crossed, and the mapping is C¹-continuous at the threshold.
        let excess = lch.C - t
        let room = maxC - t
        let compressed = t + room * (excess / (excess + room))
        return context.toRGB(OKLCh(L: lch.L, C: compressed, h: lch.h))
    }
}
