// ColorEngine.swift
// The colour-correction stage (docs/14 S9) as one engine: primaries remap, the 8-band
// Colour Mixer, Point Colour swatches, Vibrance/Saturation, and the B&W mix — in the
// pipeline's order, as a single pure RGB→RGB function.
//
// Why one engine rather than five: every tool here shares the same three pieces of
// machinery, and splitting them is how colour stacks drift. They share
//   · the band partition of unity (Mixer and B&W are literally the same 8 weights),
//   · the chroma gate, so near-neutral pixels — whose hue is numerically noise — are
//     never rotated by a hue-selective tool,
//   · the variance-compression kernel, which is Mixer Uniformity and Point Colour
//     Variance seen from two sides (docs/06 brief §2.4).
//
// Which perceptual model each tool uses is a decision, not a detail (docs/14 §5.4):
//   · Hue-selective tools (Mixer, Point Colour) work in OKLCh. Their luminance moves
//     hold C *literally* constant — darkening a blue sky must not desaturate it, which
//     is invariant #1 and the single most visible differentiator vs LrC.
//   · Saturation-class tools (Vibrance, Saturation) work in Lumen UCS, where chroma
//     moves hold H-K-corrected perceived brightness constant — invariant #2, and the
//     reason saturated blues here do not read as if they dimmed.
// The one deliberate exception is the subtractive branch of Saturation, which darkens
// as it saturates *on purpose*: that is the whole point of the density model, and it is
// reached only through the user's `density` dial. The additive path it blends against
// still holds J exactly, so `density = 0` is a strictly luminance-preserving chroma move.
//
// The stage always finishes with a soft gamut clip against the working-gamut boundary
// (docs/14 §5.4 invariant #3): no colour tool may hand S14 a pixel the display
// transform would have to mangle. The boundary is built once, lazily, and shared.

import Foundation

/// Lazily-built, thread-safe holder for the working-gamut boundary. The boundary costs
/// ~600 bisections to build and is pure, so it is computed on first use and cached for
/// every subsequent pixel and every copy of the engine that shares this box.
private final class GamutBoundaryCache: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let context: OKLabTransform.Context
    private var stored: Gamut.Boundary?

    init(context: OKLabTransform.Context) {
        self.context = context
        self.stored = nil
    }

    func value() -> Gamut.Boundary {
        lock.lock()
        defer { lock.unlock() }
        if let b = stored { return b }
        let b = Gamut.Boundary(context: context)
        stored = b
        return b
    }
}

public struct ColorEngine: Sendable {

    // MARK: - Inputs

    public let mixer: Mixer
    public let pointColors: [PointColor]
    public let color: ColorAdjust
    public let primaries: Primaries
    public let bw: BlackAndWhite?
    public let context: OKLabTransform.Context

    /// The B&W band mix, always 8 sanitized values, present whether or not the
    /// treatment is on. The engine-side half of the state-preservation fix (docs/06
    /// brief §7.3): nothing in the colour path reads or writes Mixer state on behalf of
    /// B&W — the Mixer runs identically in both treatments — so toggling the treatment
    /// is lossless as far as rendering is concerned, and the UI can round-trip these.
    public let blackAndWhiteBands: [Double]

    /// Measured chroma-weighted mean hue per band, if the renderer has image statistics
    /// (docs/06 brief §1.6). `nil` — the default — falls back to the band centres, which
    /// is the best a per-pixel closed form can do; see `bandTargetHue(_:)`.
    public var bandMeanHues: [Double]?

    // MARK: - Derived state

    private let bands: [MixerBand]
    private let uniformity: Double
    private let mixerIsIdentity: Bool
    private let swatches: [Swatch]
    private let remap: Mat3
    private let remapIsIdentity: Bool
    private let tintA: Double
    private let tintB: Double
    private let tintIsIdentity: Bool
    private let bwEnabled: Bool
    private let bwHasBands: Bool
    private let lumaWeights: RGB
    private let gamut: GamutBoundaryCache

    // MARK: - Band model (docs/06 brief §1.1–1.2)

    public static let bandCount: Int = 8

    /// LrC-compatible names, in the wire format's fixed structural order.
    public static let bandNames: [String] = [
        "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"
    ]

    /// Anchor: the OKLCh hue of sRGB pure red. Golden-locked — changing this or the 45°
    /// step is a pipelineVersion bump, because it moves what every saved recipe means.
    public static let bandAnchorDegrees: Double = 29.23
    public static let bandSpacingDegrees: Double = 45.0

    /// Band centres, 45° apart so the Mixer and the Hue Equalizer are one parameter set
    /// viewed two ways (D3: the Equalizer's "8 fixed, equally spaced hues").
    public static let bandHueCentres: [Double] = {
        var v: [Double] = []
        v.reserveCapacity(ColorEngine.bandCount)
        for i in 0..<ColorEngine.bandCount {
            v.append(Num.wrapHue(ColorEngine.bandAnchorDegrees
                                 + ColorEngine.bandSpacingDegrees * Double(i)))
        }
        return v
    }()

    /// Core half-arc and feather extent. Cores tile the circle exactly (±22.5° at 45°
    /// spacing) and the feathers overlap the neighbours, which is what makes the
    /// normalized weights C¹ everywhere: no wedge edges exist, so the LrC PV6 banding
    /// class of artifact is structurally impossible rather than merely mitigated.
    public static let bandCoreDegrees: Double = 22.5
    public static let bandFeatherDegrees: Double = 15.0

    /// ±100 on a Hue slider lands exactly on the adjacent band centre.
    public static let hueRangeDegrees: Double = 45.0
    /// Luminance shaping constant: ±100 moves L by at most ±0.25 at L = 0.5, with
    /// fixed points at black and white.
    public static let lumKappa: Double = 1.0
    /// B&W band gain constant: −100 on a band takes that colour's grey to zero.
    public static let bwKappa: Double = 1.0

    /// Chroma gate thresholds. Below `gateLo` a pixel's hue is noise; the gate scales
    /// the *magnitude* of every hue-selective adjustment and is deliberately never
    /// folded into band membership — doing that would break the partition of unity for
    /// neutrals and let hue rotation leak into greys.
    public static let gateLoChroma: Double = 0.02
    public static let gateHiChroma: Double = 0.06

    // MARK: - Point Colour (docs/06 brief §2.2)

    public static let pointSigmaL: Double = 0.60
    public static let pointSigmaC: Double = 0.25
    public static let pointSigmaH: Double = 0.30
    /// Range = 0 collapses a tolerance to a hard match; this floors the divisor.
    public static let pointSigmaFloor: Double = 1e-4
    public static let pointHueShiftLimit: Double = 60.0

    // MARK: - Skin (docs/06 brief §5.3)

    /// The NTSC vectorscope I-bar — the axis all human skin hues cluster on regardless
    /// of ethnicity (blood and melanin fix the hue; luminance is what varies) —
    /// transported into the OKLab a/b plane. Golden-locked constant, never re-derived at
    /// runtime, because the vectorscope graticule and the Skin tools must agree exactly.
    public static let skinLineDegrees: Double = 33.0
    /// Half-width, matching the UI's literal "±10°" label.
    public static let skinBandDegrees: Double = 10.0

    // MARK: - Vibrance / Saturation (docs/06 brief §5.5)

    public static let lowChromaLo: Double = 0.05
    public static let lowChromaHi: Double = 0.25
    /// Sat-vs-Sat compression: the knee above which further push resists, and the
    /// chroma the curve is asymptotic to. Internal machinery — never a user curve.
    public static let satKneeChroma: Double = 0.18
    public static let satCeilingChroma: Double = 0.34
    /// Lum-vs-Sat rolloff: the tonal window inside which a *push* has full effect.
    public static let satRolloffLo0: Double = 0.02
    public static let satRolloffLo1: Double = 0.20
    public static let satRolloffHi0: Double = 0.86
    public static let satRolloffHi1: Double = 1.00
    /// Full positive Saturation raises the dye-density gamma to this above 1.
    public static let densityGammaRange: Double = 1.0

    // MARK: - Primaries (docs/06 brief §6.2)

    public static let primaryRotationDegrees: Double = 20.0
    public static let primaryPurityScale: Double = 0.5
    /// Shadows Tint: a pinned shadow window (NOT the user's grading pivot) and the
    /// maximum a/b offset at ±100.
    public static let tintPivotEV: Double = -3.0
    public static let tintHalfWidthEV: Double = 1.5
    public static let tintAmplitude: Double = 0.05
    /// OKLab hue of the green↔magenta opponent axis; +tint is toward magenta.
    public static let tintAxisDegrees: Double = 328.36

    /// Fraction of the per-hue boundary chroma above which the always-on clip engages.
    public static let gamutThreshold: Double = 0.80

    /// The working space the stage operates in (docs/14 §1.3). The primaries remap needs
    /// chromaticities, which `OKLabTransform.Context` does not carry; this is the space
    /// `OKLabTransform.working` is built from.
    public static let workingSpace: RGBColorSpace = .rec2020

    // MARK: - Init

    public init(mixer: Mixer,
                pointColors: [PointColor],
                color: ColorAdjust,
                primaries: Primaries,
                bw: BlackAndWhite?,
                context: OKLabTransform.Context = OKLabTransform.working) {
        self.mixer = mixer
        self.pointColors = pointColors
        self.color = color
        self.primaries = primaries
        self.bw = bw
        self.context = context
        self.bandMeanHues = nil

        let sanitized: [MixerBand] = Self.sanitizedBands(mixer.bands)
        self.bands = sanitized
        self.uniformity = Num.clamp(mixer.uniformity, 0, 100)
        var mixerFlat = true
        for b in sanitized where b.hue != 0 || b.sat != 0 || b.lum != 0 { mixerFlat = false }
        self.mixerIsIdentity = mixerFlat && Num.clamp(mixer.uniformity, 0, 100) == 0

        self.swatches = Self.compiledSwatches(pointColors, context: context)

        let m: Mat3 = Self.primariesMatrix(primaries, space: Self.workingSpace)
        self.remap = m
        self.remapIsIdentity = m.maxAbsDifference(.identity) < 1e-12

        let tintAngle: Double = Self.tintAxisDegrees * .pi / 180
        let hueAmount: Double = Num.clamp(primaries.tintHue, -100, 100) / 100
        let purityAmount: Double = Num.clamp(primaries.tintPurity, -100, 100) / 100
        // tintHue rides the green↔magenta axis (the spec's one Shadows Tint slider);
        // tintPurity rides its perpendicular, because a shadow cast is not always on
        // the green–magenta axis (docs/06 brief §6.1, the seven-vs-eight-field conflict).
        self.tintA = Self.tintAmplitude
            * (hueAmount * cos(tintAngle) - purityAmount * sin(tintAngle))
        self.tintB = Self.tintAmplitude
            * (hueAmount * sin(tintAngle) + purityAmount * cos(tintAngle))
        self.tintIsIdentity = hueAmount == 0 && purityAmount == 0

        var bandsOut: [Double] = [Double](repeating: 0, count: Self.bandCount)
        if let b = bw {
            for i in 0..<Self.bandCount where i < b.bands.count {
                bandsOut[i] = Num.clamp(b.bands[i], -100, 100)
            }
        }
        self.blackAndWhiteBands = bandsOut
        self.bwEnabled = bw != nil
        var anyBand = false
        for v in bandsOut where v != 0 { anyBand = true }
        self.bwHasBands = anyBand

        self.lumaWeights = Self.workingSpace.luminanceWeights
        self.gamut = GamutBoundaryCache(context: context)
    }

    // MARK: - The stage

    /// The whole of S9, in pipeline order. Pure, closed-form, one pass: primaries remap
    /// → Mixer → Point Colour → Vibrance/Saturation → B&W → always-on soft gamut clip.
    public func apply(_ c: RGB) -> RGB {
        guard c.isFinite else { return c }
        var out: RGB = c
        out = applyPrimaries(out)
        out = applyMixer(out)
        out = applyPointColors(out)
        out = applyVibranceSaturation(out)
        out = applyBlackAndWhite(out)
        guard out.isFinite else { return c }
        return Gamut.softClip(out, boundary: gamut.value(),
                              threshold: Self.gamutThreshold, context: context)
    }

    /// True when nothing in the stage would change a pixel, so the renderer can skip S9
    /// entirely rather than round-tripping 45 megapixels through OKLab for no reason.
    public var isIdentity: Bool {
        remapIsIdentity && tintIsIdentity && mixerIsIdentity && swatches.isEmpty
            && Num.clamp(color.vibrance, -100, 100) == 0
            && Num.clamp(color.saturation, -100, 100) == 0
            && !bwEnabled
    }

    // MARK: - Band weights

    /// The 8-band partition of unity at `hue`, in wire order. Σw = 1 exactly, on every
    /// path including the degenerate one. Exposed so the UI's ring and the "show reach"
    /// overlay draw the weights the engine actually uses, not a redrawn approximation.
    public static func bandWeights(hue: Double) -> [Double] {
        var w: [Double] = [Double](repeating: 0, count: bandCount)
        var sum: Double = 0
        for i in 0..<bandCount {
            let d = Num.hueDelta(bandHueCentres[i], hue)   // signed wrap180(hue − centre)
            let below = Swift.max(0, -d - bandCoreDegrees)
            let above = Swift.max(0, d - bandCoreDegrees)
            var v: Double = 1
            if below > 0 {
                v = featherFalloff(below)
            } else if above > 0 {
                v = featherFalloff(above)
            }
            w[i] = v
            sum += v
        }
        if sum < 1e-6 {
            // Every band has been shrunk away from this hue. Never emit an all-zero
            // membership vector: hand the whole weight to the nearest band, measured in
            // units of its own reach.
            var best: Int = 0
            var bestScore: Double = .infinity
            let reach = Swift.max(bandCoreDegrees + bandFeatherDegrees, 1e-6)
            for i in 0..<bandCount {
                let score = abs(Num.hueDelta(bandHueCentres[i], hue)) / reach
                if score < bestScore {
                    bestScore = score
                    best = i
                }
            }
            var fallback: [Double] = [Double](repeating: 0, count: bandCount)
            fallback[best] = 1
            return fallback
        }
        for i in 0..<bandCount { w[i] /= sum }
        return w
    }

    /// Raised-cosine feather: 1 at the core edge, 0 at the feather extent, derivative 0
    /// at both ends. `Num.raisedCosine` runs the other way, hence the complement — one
    /// shape family for tone zones and colour bands alike.
    private static func featherFalloff(_ distance: Double) -> Double {
        guard bandFeatherDegrees > 0 else { return 0 }
        return 1 - Num.raisedCosine(Num.saturate(distance / bandFeatherDegrees))
    }

    /// Chroma gate. Multiplies adjustment magnitude, never membership.
    public static func chromaGate(_ chroma: Double) -> Double {
        Num.smoothstep(gateLoChroma, gateHiChroma, chroma)
    }

    // MARK: - The shared variance-compression kernel

    public enum VarianceAxis: Sendable {
        case hue
        case chroma
        case lightness
    }

    /// `v' = v + q · β · W · (μ − τ)` — one kernel, three faces (D13 Mixer Uniformity,
    /// D14 Point Colour Variance, D17 Skin Uniformity).
    ///
    /// The quantity scaled is the deviation of the *local mean* from the target, never
    /// the deviation of the raw pixel. That is the entire trick: `q < 0` compresses the
    /// low-frequency blotch toward `τ` while `(v − μ)` — pores, grain, sky texture —
    /// survives untouched, and `q > 0` amplifies real colour structure instead of chroma
    /// noise. Callers fold the chroma gate into `weight` for the hue axis.
    ///
    /// `μ` is the guided-filter local mean of the axis (brief §2.4). A per-pixel closed
    /// form has no neighbourhood, so callers here pass `μ = v`: the flat-neighbourhood
    /// case, which keeps the algebra and the direction of the move exactly right and
    /// gives up only the texture-preservation half. Passing a real filtered mean makes
    /// this the full kernel with no other change.
    public static func varianceCompress(value v: Double,
                                        localMean mu: Double,
                                        target: Double,
                                        q: Double,
                                        beta: Double,
                                        weight: Double,
                                        axis: VarianceAxis) -> Double {
        guard q != 0, weight != 0, beta != 0 else { return v }
        switch axis {
        case .hue:
            let deviation = Num.hueDelta(target, mu)      // wrap180(μ − τ)
            return Num.wrapHue(v + q * beta * weight * deviation)
        case .chroma, .lightness:
            return v + q * beta * weight * (mu - target)
        }
    }

    /// Uniformity's convergence target for band `i`: the measured chroma-weighted mean
    /// hue when the renderer supplied one, otherwise the band's canonical centre.
    private func bandTargetHue(_ i: Int) -> Double {
        if let means = bandMeanHues, i < means.count, means[i].isFinite {
            return means[i]
        }
        return Self.bandHueCentres[i]
    }

    // MARK: - Skin membership

    /// Vectorscope skin-band membership in 0…1: how much this colour reads as skin.
    /// One constant, two consumers — the Skin tools' selection and Vibrance/Saturation's
    /// `protectSkin` attenuation both read this, so "protected" means the same thing in
    /// the guardrail and on the scope.
    public static func skinWeight(_ c: RGB,
                                  context: OKLabTransform.Context = OKLabTransform.working) -> Double {
        guard c.isFinite else { return 0 }
        let lch = context.toLCh(c)
        guard lch.C.isFinite, lch.L.isFinite else { return 0 }
        let offAxis = abs(Num.hueDelta(skinLineDegrees, lch.h))
        let inBand = 1 - Num.smoothstep(skinBandDegrees, skinBandDegrees * 1.5, offAxis)
        guard inBand > 0 else { return 0 }
        return Num.saturate(inBand * chromaGate(lch.C) * plausibility(L: lch.L, C: lch.C))
    }

    /// Skin is a *plausible* colour, not just an angle: crushed blacks, blown highlights
    /// and fire-engine chroma sit on the I-bar too, and unifying them is the failure the
    /// band alone cannot prevent.
    private static func plausibility(L: Double, C: Double) -> Double {
        let lo = Num.smoothstep(0.05, 0.20, L)
        let hi = 1 - Num.smoothstep(0.85, 0.98, L)
        let chroma = 1 - Num.smoothstep(0.16, 0.26, C)
        return Num.saturate(lo * hi * chroma)
    }

    // MARK: - Primaries (S9's first move: redefine what R, G and B mean)

    private func applyPrimaries(_ c: RGB) -> RGB {
        var out: RGB = c
        if !remapIsIdentity { out = remap.apply(c) }
        guard !tintIsIdentity else { return out }
        let y = lumaWeights.r * out.r + lumaWeights.g * out.g + lumaWeights.b * out.b
        let w = Self.shadowWindow(luminance: y)
        guard w > 0 else { return out }
        var lab = context.toLab(out)
        guard lab.L.isFinite else { return out }
        lab.a += w * tintA
        lab.b += w * tintB
        return context.toRGB(lab)
    }

    /// The pinned shadow window Shadows Tint rides — deliberately NOT the user's grading
    /// pivot, so retuning a grade never silently moves the primaries' shadow cast.
    private static func shadowWindow(luminance y: Double) -> Double {
        let x = Num.safeLog2(y / 0.18)
        let u = (x - tintPivotEV) / tintHalfWidthEV
        return 1 - stepC1(u)
    }

    /// Raised-cosine step on [−1, +1]: 0 below, 1 above, C¹ throughout. Same family as
    /// ZoneWeights, so zone edges look the same wherever they appear.
    private static func stepC1(_ u: Double) -> Double {
        if u <= -1 { return 0 }
        if u >= 1 { return 1 }
        return Num.raisedCosine((u + 1) / 2)
    }

    /// Rotate and rescale each primary's chromaticity about the white point, then rebuild
    /// the RGB→XYZ matrix. The rebuild renormalizes so `M · (1,1,1)` is the white point:
    /// **greys are preserved by construction**, at any setting. That is the property that
    /// beats LrC Calibration, where extreme primary moves drag neutrals off-axis.
    private static func primariesMatrix(_ p: Primaries, space: RGBColorSpace) -> Mat3 {
        let hues: [Double] = [p.rHue, p.gHue, p.bHue]
        let purities: [Double] = [p.rPurity, p.gPurity, p.bPurity]
        let base: [Chromaticity] = [space.red, space.green, space.blue]
        var flat = true
        for i in 0..<3 where hues[i] != 0 || purities[i] != 0 { flat = false }
        if flat { return .identity }

        let w = space.white
        var moved: [Chromaticity] = []
        moved.reserveCapacity(3)
        for i in 0..<3 {
            let theta = Num.clamp(hues[i], -100, 100) / 100 * primaryRotationDegrees * .pi / 180
            let rho = 1 + Num.clamp(purities[i], -100, 100) / 100 * primaryPurityScale
            let dx = base[i].x - w.x
            let dy = base[i].y - w.y
            let ct = cos(theta)
            let st = sin(theta)
            let ox = rho * (ct * dx - st * dy)
            let oy = rho * (st * dx + ct * dy)
            moved.append(safeChromaticity(white: w, offsetX: ox, offsetY: oy, fallback: base[i]))
        }

        let remapped = RGBColorSpace(name: "primaries", red: moved[0], green: moved[1],
                                     blue: moved[2], white: w)
        let toXYZ = remapped.toXYZ
        guard abs(toXYZ.determinant) > 1e-9 else { return .identity }
        let full = space.fromXYZ * toXYZ
        guard abs(full.determinant) > 1e-9 else { return .identity }
        for row in full.m {
            for value in row where !value.isFinite { return .identity }
        }
        return full
    }

    /// Purity at ±100 can push a primary off the chromaticity plane entirely (Rec.2020's
    /// blue leaves y > 0 well before the slider ends). Shrink the offset along its own
    /// direction until it lands somewhere a matrix can be built from, rather than letting
    /// the derivation trap or emit garbage.
    private static func safeChromaticity(white w: Chromaticity,
                                         offsetX: Double, offsetY: Double,
                                         fallback: Chromaticity) -> Chromaticity {
        func valid(_ s: Double) -> Bool {
            let x = w.x + s * offsetX
            let y = w.y + s * offsetY
            return x.isFinite && y.isFinite && y > 0.002 && x > 0.001 && (x + y) < 0.999
        }
        if valid(1) { return Chromaticity(w.x + offsetX, w.y + offsetY) }
        var lo: Double = 0
        var hi: Double = 1
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if valid(mid) { lo = mid } else { hi = mid }
        }
        // A primary collapsed onto the white point would make the matrix singular.
        guard lo > 0.05 else { return fallback }
        return Chromaticity(w.x + lo * offsetX, w.y + lo * offsetY)
    }

    // MARK: - Colour Mixer (D13)

    private static func sanitizedBands(_ input: [MixerBand]) -> [MixerBand] {
        var out: [MixerBand] = [MixerBand](repeating: MixerBand(), count: bandCount)
        for i in 0..<bandCount where i < input.count { out[i] = input[i] }
        return out
    }

    private func applyMixer(_ c: RGB) -> RGB {
        guard !mixerIsIdentity else { return c }
        let lch = context.toLCh(c)
        guard lch.L.isFinite, lch.C.isFinite else { return c }
        let w = Self.bandWeights(hue: lch.h)
        let gate = Self.chromaGate(lch.C)

        // Sum all three attributes across bands BEFORE applying any of them. Applying
        // band-serially would double-count in the overlap regions, which is exactly
        // where the smooth band model is supposed to be invisible.
        var hueSum: Double = 0
        var satSum: Double = 0
        var lumSum: Double = 0
        var converge: Double = 0
        let q = -uniformity / 100
        for i in 0..<Self.bandCount {
            let weight = w[i] * gate
            if weight == 0 { continue }
            let band = bands[i]
            hueSum += weight * (Num.clamp(band.hue, -100, 100) / 100) * Self.hueRangeDegrees
            satSum += weight * (Num.clamp(band.sat, -100, 100) / 100)
            lumSum += weight * (Num.clamp(band.lum, -100, 100) / 100)
            if q != 0 {
                // Uniformity is evaluated against the STAGE INPUT hue (invariant #4:
                // a selection never sees the move it is driving).
                let moved = Self.varianceCompress(value: lch.h, localMean: lch.h,
                                                  target: bandTargetHue(i),
                                                  q: q, beta: 1, weight: weight, axis: .hue)
                converge += Num.hueDelta(lch.h, moved)
            }
        }

        let gC = Swift.max(0, 1 + satSum)
        // Chroma is carried through the luminance move literally unchanged — invariant
        // #1. The shaping term uses the saturated L so the fixed points at black and
        // white hold even for the above-white values scene-referred data reaches.
        let shaped = Num.saturate(lch.L)
        let L = lch.L + lumSum * Self.lumKappa * shaped * (1 - shaped)
        let h = Num.wrapHue(lch.h + hueSum + converge)
        return context.toRGB(OKLCh(L: L, C: lch.C * gC, h: h))
    }

    // MARK: - Point Colour (D14)

    /// One compiled swatch. Ranges resolve to tolerances once, at init, because the
    /// per-pixel cost of eight swatches is the thing that keeps this inside one pass.
    private struct Swatch: Sendable {
        let target: OKLCh
        let sigmaL: Double
        let sigmaC: Double
        let sigmaH: Double
        let shiftH: Double
        let shiftS: Double
        let shiftL: Double
        let q: Double
    }

    private static func compiledSwatches(_ input: [PointColor],
                                         context: OKLabTransform.Context) -> [Swatch] {
        var out: [Swatch] = []
        out.reserveCapacity(input.count)
        for pc in input {
            guard pc.sample.count >= 3 else { continue }
            let sample = RGB(pc.sample[0], pc.sample[1], pc.sample[2])
            guard sample.isFinite else { continue }
            let shiftH = Num.clamp(pc.shift.h, -pointHueShiftLimit, pointHueShiftLimit)
            let shiftS = Num.clamp(pc.shift.s, -100, 100)
            let shiftL = Num.clamp(pc.shift.l, -100, 100)
            let q = Num.clamp(pc.variance, -100, 100) / 100
            if shiftH == 0 && shiftS == 0 && shiftL == 0 && q == 0 { continue }
            let target = context.toLCh(sample)
            guard target.L.isFinite, target.C.isFinite else { continue }
            // The wire format carries one master Range; the per-axis refine ranges are a
            // documented format gap (brief §2.1), so all three axes share it.
            let r = Num.clamp(pc.range, 0, 100) / 100
            out.append(Swatch(target: target,
                              sigmaL: Swift.max(pointSigmaL * r, pointSigmaFloor),
                              sigmaC: Swift.max(pointSigmaC * r, pointSigmaFloor),
                              sigmaH: Swift.max(pointSigmaH * r, pointSigmaFloor),
                              shiftH: shiftH, shiftS: shiftS, shiftL: shiftL, q: q))
        }
        return out
    }

    private func applyPointColors(_ c: RGB) -> RGB {
        guard !swatches.isEmpty else { return c }
        var out: RGB = c
        // Compose in creation order; each swatch is closed-form, so all eight evaluate
        // in one pass with no intermediate buffers.
        for s in swatches { out = applySwatch(s, to: out) }
        return out
    }

    private func applySwatch(_ s: Swatch, to c: RGB) -> RGB {
        let lch = context.toLCh(c)
        guard lch.L.isFinite, lch.C.isFinite else { return c }

        let dL = lch.L - s.target.L
        let dC = lch.C - s.target.C
        let dh = Num.hueDelta(s.target.h, lch.h)
        // Chordal ΔH, the CIEDE-style form: hue distance shrinks correctly as either
        // colour approaches the neutral axis, where hue stops meaning anything.
        let dH = 2 * Swift.max(0, lch.C * s.target.C).squareRoot() * sin(dh * .pi / 360)

        let tL = dL / s.sigmaL
        let tC = dC / s.sigmaC
        let tH = dH / s.sigmaH
        let d = (tL * tL + tC * tC + tH * tH).squareRoot()
        guard d.isFinite else { return c }
        // Flat plateau out to half the radius, C¹ rolloff to nothing at the edge.
        let weight = 1 - Num.smoothstep(0.5, 1.0, d)
        guard weight > 0 else { return c }

        var L = lch.L
        var C = lch.C
        var h = lch.h

        if s.q != 0 {
            let gate = Self.chromaGate(lch.C)
            h = Self.varianceCompress(value: h, localMean: h, target: s.target.h,
                                      q: s.q, beta: 1.0, weight: weight * gate, axis: .hue)
            C = Self.varianceCompress(value: C, localMean: C, target: s.target.C,
                                      q: s.q, beta: 1.0, weight: weight, axis: .chroma)
            // Lightness deviation participates at half weight — which is why evening out
            // a blotchy sky does not flatten its luminance texture.
            L = Self.varianceCompress(value: L, localMean: L, target: s.target.L,
                                      q: s.q, beta: 0.5, weight: weight, axis: .lightness)
        }

        h += weight * s.shiftH
        C = Swift.max(0, C * (1 + weight * s.shiftS / 100))
        // Same chroma-preserving lightness kernel as the Mixer: C is untouched here.
        let shaped = Num.saturate(L)
        L += weight * (s.shiftL / 100) * Self.lumKappa * shaped * (1 - shaped)
        return context.toRGB(OKLCh(L: L, C: C, h: Num.wrapHue(h)))
    }

    // MARK: - Vibrance and Saturation (D21)

    /// Low-chroma prioritization: Vibrance spends itself on the colours that have least.
    public static func lowChroma(_ chroma: Double) -> Double {
        1 - Num.smoothstep(lowChromaLo, lowChromaHi, chroma)
    }

    /// Sat-vs-Sat compression. Monotone, C¹ at the knee, asymptotic to the ceiling:
    /// already-saturated colours resist further push. Applied to the *increment* so an
    /// untouched colour is an exact fixed point.
    public static func satCompress(_ chroma: Double) -> Double {
        guard chroma > satKneeChroma else { return chroma }
        let room = satCeilingChroma - satKneeChroma
        guard room > 0 else { return chroma }
        return satCeilingChroma - room * exp(-(chroma - satKneeChroma) / room)
    }

    /// Lum-vs-Sat rolloff: no chroma-noise shadows, no neon highlights. Together with
    /// the compression above this is the actual mechanism of "expensive" colour — film's
    /// apparent richness is saturation rolloff at the extremes. Both are internal and
    /// always on; exposing them as user curves would violate the one-intent rule.
    public static func lumSatRolloff(_ brightness: Double) -> Double {
        Num.smoothstep(satRolloffLo0, satRolloffLo1, brightness)
            * (1 - Num.smoothstep(satRolloffHi0, satRolloffHi1, brightness))
    }

    /// The subtractive branch: per-channel gamma on the chromaticity ratios against the
    /// density-weighted norm. Colour intensifies by *densifying* — the absorbing layers
    /// deepen while the transmitting one holds, so the colour darkens as it saturates,
    /// the way stacked dye does, instead of pushing channels apart toward neon.
    /// Neutrals have unit ratios and are therefore exact fixed points.
    public static func subtractivePush(_ c: RGB, amount: Double) -> RGB {
        guard amount > 0 else { return c }
        let norm = c.maxComponent
        guard norm > 1e-9, norm.isFinite else { return c }
        let gamma = 1 + amount * densityGammaRange
        guard gamma > 0 else { return c }
        let r = Num.spow(c.r / norm, gamma)
        let g = Num.spow(c.g / norm, gamma)
        let b = Num.spow(c.b / norm, gamma)
        let out = RGB(r * norm, g * norm, b * norm)
        return out.isFinite ? out : c
    }

    private func applyVibranceSaturation(_ c: RGB) -> RGB {
        let vibrance = Num.clamp(color.vibrance, -100, 100) / 100
        let saturation = Num.clamp(color.saturation, -100, 100) / 100
        guard vibrance != 0 || saturation != 0 else { return c }

        let input = LumenUCS.fromRGB(c, context: context)
        guard input.J.isFinite, input.C.isFinite else { return c }

        // Selection and shaping weights are read off the stage input, never the output.
        let skin = Self.skinWeight(c, context: context)
        let protection = 1 - Num.clamp(color.protectSkin, 0, 100) / 100 * skin
        let rolloff = Self.lumSatRolloff(input.J)

        // The rolloff tapers *pushes* only. Negative Saturation still reaches true B&W
        // at −100 everywhere in the frame, including the extremes.
        let vibAmount = (vibrance >= 0 ? vibrance * rolloff : vibrance)
            * Self.lowChroma(input.C) * protection
        let satAmount = (saturation >= 0 ? saturation * rolloff : saturation) * protection

        var mid: RGB = c
        if vibAmount != 0 {
            mid = shapedChromaScale(c, gain: 1 + vibAmount)
        }
        guard satAmount != 0 else { return mid }

        let additive = shapedChromaScale(mid, gain: 1 + satAmount)
        // Only the positive side is subtractive; a negative move is a plain, exactly
        // luminance-preserving walk toward the neutral axis.
        guard satAmount > 0 else { return additive }
        let density = Num.clamp(color.density, 0, 100) / 100
        guard density > 0 else { return additive }
        let subtractive = Self.subtractivePush(mid, amount: satAmount)
        return additive.mix(subtractive, density)
    }

    /// Scale chroma in Lumen UCS — holding H-K-corrected perceived brightness and hue —
    /// with the sat-vs-sat curve applied to the increment rather than to the level.
    private func shapedChromaScale(_ c: RGB, gain: Double) -> RGB {
        var u = LumenUCS.fromRGB(c, context: context)
        guard u.C.isFinite, u.J.isFinite else { return c }
        let base = Swift.max(0, u.C)
        let target = base * Swift.max(0, gain)
        u.C = Swift.max(0, base + (Self.satCompress(target) - Self.satCompress(base)))
        let out = LumenUCS.toRGB(u, context: context)
        return out.isFinite ? out : c
    }

    // MARK: - Black & White (D20)

    private func applyBlackAndWhite(_ c: RGB) -> RGB {
        guard bwEnabled else { return c }
        let base = lumaWeights.r * c.r + lumaWeights.g * c.g + lumaWeights.b * c.b
        guard base.isFinite else { return c }
        var gain: Double = 1
        if bwHasBands {
            let lch = context.toLCh(c)
            if lch.C.isFinite, lch.L.isFinite {
                // The same smooth periodic band model as the Mixer, which is why an
                // aggressive mix (Blue −80 skies) darkens cleanly instead of banding.
                let w = Self.bandWeights(hue: lch.h)
                let gate = Self.chromaGate(lch.C)
                for i in 0..<Self.bandCount {
                    gain += w[i] * gate * (blackAndWhiteBands[i] / 100) * Self.bwKappa
                }
            }
        }
        // The working space's luminance weights sum to one, so an equal-energy triple of
        // this value is a true neutral at exactly the mixed luminance.
        return RGB(gray: Swift.max(0, base * Swift.max(0, gain)))
    }
}
