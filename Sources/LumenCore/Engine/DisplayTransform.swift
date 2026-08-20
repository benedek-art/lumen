// DisplayTransform.swift
// THE display transform (D8, docs/14 §S14). Exactly one, forever: an AgX-class
// sigmoid with primaries inset before the curve, purity restore after it, hue
// preservation as a parameter, and a display-peak parameter that makes SDR and HDR the
// same curve family (docs/14 §7 — which is what makes Phase 7 gain maps cheap).
//
// Clean-room: the equations are the published two-power sigmoid construction and the
// AgX primaries-inset mechanism, implemented from the mathematics, not from any GPL
// source (docs/17 ledger).
//
// Construction (all four constraints hold by construction, not by clamping):
//   · scene mid-grey (0.18) lands exactly on the display's mid-grey target
//   · the scene black anchor lands exactly on the display black target
//   · the scene white anchor lands exactly on the display white target
//   · the log-log slope at mid-grey equals `contrast`, independent of `skew`
//
// The scene anchors come from the Whites/Blacks sliders (ToneEngine), which is how
// "Whites owns the white point" is implemented as geometry rather than as a rule.

import Foundation

public struct DisplayTransformParams: Equatable, Sendable {

    /// Slope at mid-grey, log-log. darktable-sigmoid-compatible range/default.
    public var contrast: Double = 1.5
    /// Toe ↔ shoulder emphasis. Slope at the pivot is unchanged by construction.
    public var skew: Double = 0
    /// 0 = per-channel character (hotter sunsets), 100 = hue-stable.
    public var huePreservation: Double = 100
    /// Display white in % of SDR white. 100 = SDR; up to 1600 on an EDR display.
    public var whiteTarget: Double = 100
    /// Display black floor, in % of SDR white.
    public var blackTarget: Double = 0.0152

    /// Primaries inset: purity reduction before the curve (0…0.99 per channel).
    public var attenuation: RGB = RGB(0.14, 0.18, 0.12)
    /// Primaries rotation before the curve, radians (±0.4).
    public var rotation: RGB = RGB(0.02, -0.03, 0.06)
    /// Post-curve purity recovery, 0…1.
    public var purityRestore: Double = 0.4

    /// Scene EV of the white anchor relative to mid-grey (set by Whites).
    public var whiteAnchorEV: Double = 5.0
    /// Scene EV of the black anchor relative to mid-grey (set by Blacks).
    public var blackAnchorEV: Double = -9.0

    /// The escape hatch (docs/04 §6.1 "Linear" preset): straight scene→display
    /// scaling, clipped at display white. Always available, for inspection and
    /// round-tripping — the "show me the data" honesty control.
    public var linear: Bool = false

    public init() {}

    // MARK: Presets

    public static let neutral = DisplayTransformParams()

    public static var soft: DisplayTransformParams {
        var p = DisplayTransformParams()
        p.contrast = 1.2
        p.skew = 0.25
        p.purityRestore = 0.3
        return p
    }

    public static var punchy: DisplayTransformParams {
        var p = DisplayTransformParams()
        p.contrast = 2.1
        p.skew = -0.15
        p.attenuation = RGB(0.18, 0.22, 0.16)
        p.purityRestore = 0.55
        return p
    }

    public static var filmBase: DisplayTransformParams {
        var p = DisplayTransformParams()
        p.contrast = 1.7
        p.skew = 0.4
        p.huePreservation = 70
        p.attenuation = RGB(0.22, 0.24, 0.20)
        p.rotation = RGB(0.04, -0.05, 0.09)
        p.purityRestore = 0.25
        return p
    }

    public static var linearPreset: DisplayTransformParams {
        var p = DisplayTransformParams()
        p.linear = true
        return p
    }

    public static let presetNames = ["Neutral", "Soft", "Punchy", "Film Base", "Linear"]

    public static func preset(named name: String) -> DisplayTransformParams {
        switch name {
        case "Soft": return .soft
        case "Punchy": return .punchy
        case "Film Base": return .filmBase
        case "Linear": return .linearPreset
        default: return .neutral
        }
    }
}

/// A solved transform: the curve's shape constants plus the two primaries matrices.
/// Building one costs a handful of microseconds; per-pixel work is then a curve
/// evaluation and two matrix multiplies (docs/04 §6.5's "rebake, then apply").
public struct DisplayTransform: Sendable {

    public let params: DisplayTransformParams

    /// Display white/black in display-linear units (1.0 = SDR white).
    public let white: Double
    public let black: Double

    // Normalized log-domain curve constants.
    private let minEV: Double
    private let range: Double
    private let pivotX: Double
    private let pivotY: Double
    private let toePower: Double
    private let toeLambda: Double
    private let shoulderPower: Double
    private let shoulderLambda: Double

    private let insetMatrix: Mat3
    private let outsetMatrix: Mat3

    /// Encoded output anchors: black, white and mid-grey on the shaping axis.
    private let encodedBlack: Double
    private let encodedWhite: Double

    /// The curve is SHAPED on a perceptually encoded output axis, not on
    /// display-linear values. This is not cosmetic. A two-power sigmoid built on
    /// linear output needs an exponent near 9 to hit a log-log slope of 1.5 at
    /// mid-grey, and its slope then collapses away from the pivot: four stops down it
    /// renders four times darker than the contrast it promises. On the encoded axis
    /// the same construction needs an exponent near 4.4 and tracks the promised slope
    /// through the midtones, rolling off only where a shoulder and a toe belong.
    /// Encoding still happens exactly once, at S17 — this is the curve's shaping
    /// domain, not the output's.
    public static let shapingCurve: TransferFunction = .srgb

    public static let midGrey: Double = 0.18
    /// Shape parameter of the skew term. 2 keeps the extra curvature gentle and
    /// keeps the monotonicity bound (`lambda < power/skewShape`) generous.
    private static let skewShape: Double = 2.0

    public init(_ p: DisplayTransformParams,
                space: RGBColorSpace = .rec2020) {
        self.params = p
        let w = Swift.max(p.whiteTarget, 1) / 100.0
        // Black is a fraction of SDR white, not of the display peak: raising the peak
        // must not raise the floor. Same reasoning pins mid-grey below.
        let b = Num.clamp(p.blackTarget, 0, 15) / 100.0
        self.white = w
        self.black = Swift.min(b, DisplayTransform.midGrey * 0.5)

        // Scene anchors, in stops around mid-grey. Guard the degenerate ordering a
        // slider combination could produce.
        let hi = Swift.max(p.whiteAnchorEV, 0.5)
        let lo = Swift.min(p.blackAnchorEV, -0.5)
        self.minEV = lo
        self.range = hi - lo
        self.pivotX = (0 - lo) / (hi - lo)

        // Mid-grey lands on 0.18 display-linear in ABSOLUTE terms, at every display
        // peak. In HDR the extra headroom goes to speculars; diffuse white and
        // mid-grey stay where they are, which is why an HDR rendition looks like the
        // SDR one with the highlights let out rather than like a brighter picture.
        let curve = DisplayTransform.shapingCurve
        let eb = curve.encode(self.black)
        let ew = curve.encode(w)
        let ep = curve.encode(DisplayTransform.midGrey)
        self.encodedBlack = eb
        self.encodedWhite = ew
        let span = Swift.max(ew - eb, 1e-6)
        let py = Num.clamp((ep - eb) / span, 0.01, 0.99)
        self.pivotY = py

        // Slope at the pivot, converted from the log-log `contrast` the UI shows.
        // out = decode(Yn·span + eb), so d log2(out)/d log2(x) at the pivot is
        // decode'(ep)·span·m / (0.18 · ln2 · range). Inverting that gives m.
        let contrast = Num.clamp(p.contrast, 0.1, 10)
        let h = 1e-6
        let slopeOfDecode = Swift.max((curve.decode(ep + h) - curve.decode(ep - h)) / (2 * h),
                                      1e-9)
        let m = contrast * DisplayTransform.midGrey * log(2.0) * (hi - lo)
            / (slopeOfDecode * span)

        let aToe = m * pivotX / py
        let aShoulder = m * (1 - pivotX) / (1 - py)

        // Skew adds curvature to one side and removes it from the other while
        // leaving the pivot slope untouched: y = u^a·(1−λ+λu^d) with a = a₀ − λd.
        let skew = Num.clamp(p.skew, -1, 1)
        let shape = DisplayTransform.skewShape
        let toeLambda = Num.clamp(skew * 0.5, -1, aToe / shape * 0.9)
        let shoulderLambda = Num.clamp(-skew * 0.5, -1, aShoulder / shape * 0.9)
        self.toeLambda = toeLambda
        self.shoulderLambda = shoulderLambda
        self.toePower = Swift.max(aToe - toeLambda * shape, 0.05)
        self.shoulderPower = Swift.max(aShoulder - shoulderLambda * shape, 0.05)

        // Primaries inset/outset (the AgX mechanism).
        let inset = DisplayTransform.insetSpace(space, attenuation: p.attenuation,
                                                rotation: p.rotation)
        let toInset = space.matrix(to: inset)
        self.insetMatrix = toInset
        let back = inset.matrix(to: space)
        let restore = Num.clamp(p.purityRestore, 0, 1)
        // Purity restore blends between "stay inset" (identity) and "fully undo".
        self.outsetMatrix = DisplayTransform.blend(Mat3.identity, back, restore)
    }

    private static func blend(_ a: Mat3, _ b: Mat3, _ t: Double) -> Mat3 {
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 { out[i][j] = Num.mix(a.m[i][j], b.m[i][j], t) }
        }
        return Mat3(out)
    }

    /// Move each primary toward the white point by `attenuation` and rotate it by
    /// `rotation` radians about white in the chromaticity plane.
    static func insetSpace(_ space: RGBColorSpace, attenuation: RGB, rotation: RGB) -> RGBColorSpace {
        func move(_ c: Chromaticity, _ att: Double, _ rot: Double) -> Chromaticity {
            let w = space.white
            let dx = c.x - w.x
            let dy = c.y - w.y
            let a = Num.clamp(att, 0, 0.99)
            let r = Num.clamp(rot, -0.4, 0.4)
            let cs = cos(r), sn = sin(r)
            let rx = dx * cs - dy * sn
            let ry = dx * sn + dy * cs
            return Chromaticity(w.x + rx * (1 - a), w.y + ry * (1 - a))
        }
        return RGBColorSpace(
            name: space.name + " (inset)",
            red: move(space.red, attenuation.r, rotation.r),
            green: move(space.green, attenuation.g, rotation.g),
            blue: move(space.blue, attenuation.b, rotation.b),
            white: space.white)
    }

    // MARK: The curve

    /// Normalized curve on [0,1] → [0,1]. Monotone by construction for every
    /// parameter combination the initializer admits.
    public func normalizedCurve(_ x: Double) -> Double {
        let X = Num.saturate(x)
        if X < pivotX {
            guard pivotX > 0 else { return 0 }
            let u = X / pivotX
            return pivotY * pow(u, toePower) * (1 - toeLambda + toeLambda * pow(u, DisplayTransform.skewShape))
        } else {
            guard pivotX < 1 else { return 1 }
            let u = (1 - X) / (1 - pivotX)
            let s = pow(u, shoulderPower)
                * (1 - shoulderLambda + shoulderLambda * pow(u, DisplayTransform.skewShape))
            return 1 - (1 - pivotY) * s
        }
    }

    /// Scene-linear scalar → display-linear scalar.
    public func tone(_ x: Double) -> Double {
        if params.linear {
            return Num.clamp(x * white, 0, white)
        }
        guard x > 0 else { return black }
        let ev = log2(x / DisplayTransform.midGrey)
        let X = (ev - minEV) / range
        let Y = normalizedCurve(X)
        let encoded = encodedBlack + (encodedWhite - encodedBlack) * Y
        return DisplayTransform.shapingCurve.decode(encoded)
    }

    /// Bake the scalar curve over the shaper's log domain — the form the GPU applies.
    public func bakeCurveLUT(size: Int = 2048) -> LUT1D {
        LUT1D(size: size) { y in tone(LumenLog.decode(y)) }
    }

    /// The full per-pixel transform: inset → curve → outset → gamut map.
    public func apply(_ c: RGB, gamut: Gamut.Boundary? = nil) -> RGB {
        if params.linear {
            return RGB(tone(c.r), tone(c.g), tone(c.b))
        }
        let inset = insetMatrix.apply(c)

        // Per-channel character: the curve on each channel independently.
        let perChannel = RGB(tone(inset.r), tone(inset.g), tone(inset.b))

        // Hue-stable: curve the norm, keep the ratios.
        let norm = Swift.max(inset.maxComponent, 1e-9)
        let scaled = tone(norm)
        let ratio = norm > 0 ? inset * (scaled / norm) : RGB(black, black, black)

        let t = Num.clamp(params.huePreservation, 0, 100) / 100
        var out = perChannel.mix(ratio, t)

        out = outsetMatrix.apply(out)
        out = RGB(Swift.max(out.r, 0), Swift.max(out.g, 0), Swift.max(out.b, 0))

        // Display-gamut mapping is the last colour operation inside S14 —
        // hue-preserving compression, never per-channel clipping.
        if let gamut, white > 0 {
            let normalized = out / white
            let mapped = Gamut.softClip(normalized, boundary: gamut)
            out = mapped * white
        }
        return out
    }

    /// Monotonicity check on the baked curve — what the inverted-curve warning in the
    /// UI evaluates (docs/04 §6.5). Returns the normalized x where it first fails.
    public func firstNonMonotonicX(samples: Int = 512) -> Double? {
        var previous = -Double.infinity
        for i in 0..<samples {
            let x = Double(i) / Double(samples - 1)
            let y = normalizedCurve(x)
            if y < previous - 1e-9 { return x }
            previous = y
        }
        return nil
    }
}
