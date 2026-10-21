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

    /// Slope at mid-grey, log-log — CALIBRATED: 1.5 here produces a measured
    /// log-log slope of 1.5 at the pivot, by construction. The range and default
    /// number match darktable's sigmoid, but not the semantic: dt's "contrast 1.5"
    /// is a steepness knob whose realized mid-grey slope measures ~1.23
    /// (docs/26 §3, measured via scripts/baselines). Same dial label, more actual
    /// contrast here.
    public var contrast: Double = 1.5
    /// Toe ↔ shoulder emphasis. Slope at the pivot is unchanged by construction.
    public var skew: Double = 0
    /// 0 = per-channel character (hotter sunsets), 100 = hue-stable through the
    /// midtones. Every setting ramps toward per-channel across the shoulder so
    /// highlights bleach to display white (the path-to-white ramp in `apply`):
    /// hue preservation is a promise about colour, not a licence to render a
    /// +5 EV overexposure as pastel.
    public var huePreservation: Double = 100
    /// Display white in % of SDR white. 100 = SDR; up to 1600 on an EDR display.
    public var whiteTarget: Double = 100
    /// Display black floor, in % of SDR white.
    public var blackTarget: Double = 0.0152

    /// Primaries inset: purity reduction before the curve (0…0.99 per channel).
    public var attenuation: RGB = RGB(0.14, 0.18, 0.12)
    /// Primaries rotation before the curve, radians (±0.4). Positive turns a primary
    /// counter-clockwise about white in xy (`insetSpace`).
    ///
    /// KNOWN DEFECT, KEPT ON PURPOSE FOR NOW. Rec.2020 blue sits at about 238° around
    /// D65, so +0.06 turns the inset blue toward the purple line and adds to the
    /// blue-to-magenta skew the inset exists to remove (LED blue about +41° by +2 EV,
    /// a sky blue about +6° at every exposure, in OKLCh). Turning it the other way
    /// (−0.04 was the measured minimax) was tried and reverted: every value at or
    /// below 0 sharpens the composed transform's curvature on a bright yellow near
    /// white, where blue is the small channel, and the 65-cube finish table then
    /// misses its exact evaluation by 0.022–0.033 against the 0.02 bar
    /// (RobustnessTests.testEachTableTracksItsOwnExactEvaluationSeparately), and the
    /// 33-cube preview disagrees with the export by 0.066–0.070 against 0.045
    /// (EngineIntegrationTests.testTheInteractiveTableAgreesWithTheExportOne). The
    /// sign fix needs a table that tracks that region first (a finer or reshaped
    /// finish domain), not a looser bar.
    public var rotation: RGB = RGB(0.02, -0.03, 0.06)
    /// Post-curve purity recovery, 0…1.
    public var purityRestore: Double = 0.4

    /// Scene EV of the white anchor relative to mid-grey (set by Whites).
    public var whiteAnchorEV: Double = 5.0
    /// Scene EV of the black anchor relative to mid-grey (set by Blacks).
    public var blackAnchorEV: Double = -9.0

    /// The escape hatch (docs/04 §6.1 "Linear" preset): display-linear equals
    /// scene-linear (1.0 = SDR white), clipped at the display peak. Always available,
    /// for inspection and round-tripping — the "show me the data" honesty control.
    public var linear: Bool = false
    /// The PROFILE's own exposure, in EV, added to the Exposure slider at S6 (like a DNG
    /// BaselineExposure). 0 for every preset except Camera, whose fitted value carries
    /// the ~1.2 EV the flat render sat below the camera's own JPEG. Not user-facing: an
    /// unedited photo on Camera still reads Exposure 0.00.
    public var baselineEV: Double = 0

    public init() {}

    // MARK: Presets

    public static let neutral = DisplayTransformParams()

    /// THE STARTING LOOK FOR A CAMERA RAW: roughly what the camera's own JPEG and
    /// Lightroom's "Adobe Color" hand you — more midtone lift, contrast and colour than
    /// Neutral, whose deliberately flat AgX base made every photo open dull (measured on
    /// an A7 IV night frame against Apple's render: ~0.7 stop darker, 21% vs 49% midtone
    /// saturation). Neutral stays as the "Flat" choice. Values fitted to embedded camera
    /// JPEGs; see the fit note beside them.
    public static var camera: DisplayTransformParams {
        if let cameraTuningOverride { return cameraTuningOverride }
        // Fitted 2026-10-20 to the embedded camera JPEGs of 18 RAWs (A7 IV + GX85,
        // ISO 100–10000, day/indoor/night soccer): luminance quantiles + per-band
        // saturation error 34.6 (Neutral) -> 13.5. Brightness was most of it: the flat
        // render sat ~1.2 EV under the camera on every frame.
        var p = DisplayTransformParams()
        p.contrast = 1.6
        p.skew = 0.7
        p.whiteAnchorEV = 4.5
        p.attenuation = RGB(0.07, 0.09, 0.06)
        p.purityRestore = 0.8
        p.baselineEV = 0.8
        return p
    }

    /// Tuning hook for the camera fit harness only; nil in the app.
    nonisolated(unsafe) public static var cameraTuningOverride: DisplayTransformParams?

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

    public static let presetNames = ["Camera", "Neutral", "Soft", "Punchy", "Film Base", "Linear"]

    public static func preset(named name: String) -> DisplayTransformParams {
        switch name {
        case "Camera": return .camera
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
    /// The smallest toe/shoulder exponent the initializer admits. Above 1 the slope
    /// reaches zero at the anchor; 1.5 makes the last stop visibly ease in.
    private static let minimumPower: Double = 1.5

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
        //
        // The same term also guarantees there IS a shoulder (and a toe). Near the
        // anchor the shoulder is u^power, whose normalized slope power·u^(power−1)
        // falls to zero only for power > 1; below 1 it grows without bound and the
        // picture accelerates into display white and then stops dead — a clip edge.
        // a₀ falls as the display peak rises (mid-grey stays at 0.18 absolute, so
        // pivotY drops on the encoded axis): 2.08 at 100 %, 0.82 at 400 %, 0.39 at
        // 1600 %, which broke docs/04's promise that the shoulder does at 400 %
        // white what it did at 100 %. Low Contrast or strong Skew did the same in
        // SDR, and the old 0.05 power floor that caught the worst of it moved the
        // pivot slope off `contrast`. So λ is capped where the power would fall
        // below `minimumPower`: the power is then exactly 1.5, the pivot slope
        // (power + λ·shape = a₀) is untouched, λ ≥ (0 − 1.5)/2 = −0.75 keeps it in
        // the clamp, and a negative λ is monotone for every a₀ > 0 (the derivative's
        // bracket is smallest at the pivot, where it equals a₀). Every shipped SDR
        // preset already sits above the bound and renders unchanged.
        let minimumPower = DisplayTransform.minimumPower
        let toeLambda = Num.clamp(skew * 0.5, -1,
                                  Swift.min(aToe / shape * 0.9, (aToe - minimumPower) / shape))
        let shoulderLambda = Num.clamp(-skew * 0.5, -1,
                                       Swift.min(aShoulder / shape * 0.9,
                                                 (aShoulder - minimumPower) / shape))
        self.toeLambda = toeLambda
        self.shoulderLambda = shoulderLambda
        self.toePower = aToe - toeLambda * shape
        self.shoulderPower = aShoulder - shoulderLambda * shape

        // Primaries inset/outset (the AgX mechanism) — orientation matters and it
        // shipped BACKWARDS for the project's whole life until the six-agent audit's
        // numeric recompute caught it. The two candidate matrices:
        //   · inset.matrix(to: space) reinterprets the image's numbers as amounts of
        //     the LESS saturated inset primaries — all-positive entries, rows summing
        //     to 1: it moves every colour TOWARD the neutral axis. This is the AgX
        //     pre-curve purity reduction, the direction whose per-channel curve can
        //     then bleach anything to white.
        //   · space.matrix(to: inset) converts coordinates INTO the inset basis —
        //     diagonal > 1, negative off-diagonals: it pushes saturated colours
        //     AWAY from neutral, and a rec2020 red's green/blue channels go negative,
        //     where tone()'s x > 0 guard pins them at the black floor forever. A
        //     colour in that state cannot bleach at ANY exposure or hue-preservation
        //     setting — measured 0.935 residual chroma at +7 EV, all settings — and
        //     purityRestore's meaning inverts with it.
        // The defect hid because every probe patch (sun-lit sand here, the same
        // orange in the darktable/RawTherapee baselines) stays inside the inset
        // gamut, where both orientations bleach; the saturated-red prong of
        // testOverexposureBleachesTowardWhite is the tripwire that keeps this
        // direction from ever flipping again.
        let inset = DisplayTransform.insetSpace(space, attenuation: p.attenuation,
                                                rotation: p.rotation)
        let compress = inset.matrix(to: space)
        self.insetMatrix = compress
        let expand = space.matrix(to: inset)
        let restore = Num.clamp(p.purityRestore, 0, 1)
        // Purity restore blends between "stay compressed" (identity) and "fully undo
        // the compression" (the expanding inverse) — so 1.0 RECOVERS purity, which
        // is what the parameter has always claimed to mean.
        self.outsetMatrix = DisplayTransform.blend(Mat3.identity, expand, restore)
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
            // Identity, clipped at the peak — never scaled by it. The same absolute
            // rule as the anchored presets (mid-grey on 0.18 at every peak): every
            // JPEG/HEIC imports on Linear, and multiplying by `white` showed the HDR
            // preview of one 2 stops brighter at 400 % and wrote a uniform 4× gain
            // map. In HDR the headroom goes to values above 1.0, nothing else.
            return Num.clamp(x, 0, white)
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
        //
        // Below the black anchor the curve is flat at `black`, so the ratio scale
        // tone(peak)/peak is black/peak and grows without bound as the peak falls
        // toward zero. A shadow-noise pixel with a peak near zero and partners near
        // −0.01 had those partners multiplied by ~1.5e5, and the outset's negative
        // off-diagonals turned them into R ≈ 126. Below the anchor the hue-stable
        // branch therefore fades into the per-channel one, in proportion to how far
        // the peak sits under it. The per-channel branch is already exactly `black`
        // there. The faded ratio term reduces to inset·black/anchor, which is bounded
        // and keeps neutrals at `black`. At and above the anchor the weight is exactly
        // 1, so nothing a visible pixel renders through changes.
        //
        // The black fallback keys on the UNfloored peak: `norm` is floored for the
        // log below, and testing it instead made the fallback unreachable, so scene
        // black rendered at 0 rather than the black target whenever hue preservation
        // was on (0.3·black at the Film Base preset's 70, black only at 0).
        let peak = inset.maxComponent
        let norm = Swift.max(peak, 1e-9)
        let ratio = peak > 1e-9 ? inset * (tone(norm) / norm) : RGB(black, black, black)
        let blackAnchorScene = DisplayTransform.midGrey * exp2(minEV)
        let aboveBlack = Num.saturate(peak / blackAnchorScene)

        // Path to white. Ratios may hold through the midtones, but a display cannot
        // show "brighter than white": above the pivot the only honest rendering of
        // more light is less chroma, which the per-channel branch does by
        // construction and the ratio branch never does — without this ramp a +5 EV
        // overexposure kept 96% of its chroma (the owner's "pastel wash" screenshot).
        // Quadratic in shoulder position: untouched at the pivot, fully per-channel
        // at the white anchor.
        let t = Num.clamp(params.huePreservation, 0, 100) / 100
        let evX = (log2(norm / DisplayTransform.midGrey) - minEV) / range
        let shoulderU = Num.saturate((evX - pivotX) / Swift.max(1 - pivotX, 1e-6))
        var out = perChannel.mix(ratio, t * (1 - shoulderU * shoulderU) * aboveBlack)

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

    /// The transform a recipe renders through, without building a whole `RenderPlan`.
    ///
    /// `RenderPlan` calls this too, so the two cannot drift. Anything that needs to
    /// reason about where a rendered pixel came from — Auto's scene statistics are the
    /// first — needs exactly the transform the render used, including the anchors
    /// Whites and Blacks moved, and reassembling those at the call site is how you get
    /// a measurement taken against a curve the picture was never put through.
    public static func forRecipe(_ recipe: Recipe,
                                 displayWhiteTarget: Double? = nil,
                                 space: RGBColorSpace = .rec2020) -> DisplayTransform {
        var params = recipe.look.render.resolved(displayWhiteTarget: displayWhiteTarget)
        ToneEngine(tone: recipe.develop.tone,
                   zones: recipe.develop.zones).applyAnchors(to: &params)
        return DisplayTransform(params, space: space)
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
