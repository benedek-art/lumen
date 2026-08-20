// RenderPlan.swift
// The bake: a recipe compiled into the small set of objects a render actually needs.
//
// Nearly every colour-bearing stage in Lumen is a pure RGB→RGB function — printer
// lights, the colour tools, the grade, the film chain, the display transform, the tone
// curve. Rather than reimplement each one in a shader and hope the two stay in step,
// the engine evaluates the composed function here, in the reference implementation,
// and bakes it into lookup tables the GPU fetches. One implementation, one set of
// goldens, and the shader surface shrinks to a handful of trivial kernels.
//
// The plan is split exactly where the pipeline's spatial stages sit (docs/14 §2), so
// the documented stage order survives the optimization:
//
//   S6 linear matrix  →  S7 tone gain (needs the guided mask: spatial)
//                     →  colourGrade LUT   (S9 + S10, log → log)
//                     →  S8/S11/S12/S13    (presence, local, sharpen, vignette: spatial)
//                     →  finish LUT        (S14 + S15, log → display-linear)
//
// Building a plan is a few milliseconds; it happens once per parameter change, never
// per pixel and never per tile.

import Foundation

public struct RenderPlan: Sendable {

    public let recipe: Recipe

    // MARK: Stage S6 — the fused linear matrix
    public let linear: LinearStage

    // MARK: Stage S7 — tone
    public let tone: ToneEngine
    /// Gain (a linear multiplier) as a function of the log-encoded guided mask value.
    public let toneGainLUT: LUT1D
    public let toneIsIdentity: Bool

    // MARK: Stages S9–S10 — colour and grade, log → log
    public let colorGradeLUT: LUT3D
    public let colorGradeIsIdentity: Bool

    // MARK: Stages S14–S15 — picture formation and the curve, log → display-linear
    public let finishLUT: LUT3D

    // MARK: Display
    public let displayWhite: Double
    public let displayTransform: DisplayTransform
    public let filmChain: FilmChain?

    // MARK: Spatial parameters carried through for the image stages
    public let detail: Detail
    public let denoise: Denoise
    public let vignetteEV: Double
    public let masks: [Mask]

    public init(recipe: Recipe,
                asShotKelvin: Double = 5500,
                asShotTint: Double = 0,
                displayWhiteTarget: Double? = nil,
                lutSize: Int = LUT3D.interactiveSize,
                space: RGBColorSpace = .rec2020) {
        self.recipe = recipe
        let develop = recipe.develop
        let look = recipe.look

        // ---- S6 -------------------------------------------------------------
        let wb = WhiteBalanceEngine(asShotKelvin: asShotKelvin, asShotTint: asShotTint,
                                    targetKelvin: develop.raw.temp,
                                    targetTint: develop.raw.tint, space: space)
        let toneEngine = ToneEngine(tone: develop.tone, zones: develop.zones)
        let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                whiteAnchorEV: toneEngine.whiteAnchorEV,
                                blackAnchorEV: toneEngine.blackAnchorEV)
        self.linear = LinearStage(whiteBalance: wb,
                                  exposureGain: toneEngine.exposureGain,
                                  printerLightGains: grade.printerLightGains)

        // ---- S7 -------------------------------------------------------------
        self.tone = toneEngine
        self.toneIsIdentity = toneEngine.isIdentity
        self.toneGainLUT = toneEngine.isIdentity
            ? LUT1D(size: 2) { _ in 1 }
            : toneEngine.bakeGainLUT()

        // ---- S9 + S10 --------------------------------------------------------
        let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                color: develop.color, primaries: look.primaries,
                                bw: look.bw)
        let colorIdentity = color.isIdentity && grade.isIdentity
        self.colorGradeIsIdentity = colorIdentity
        if colorIdentity {
            self.colorGradeLUT = LUT3D.identity(size: 2)
        } else {
            self.colorGradeLUT = LUT3D(size: lutSize) { encoded in
                let scene = LumenLog.decode(encoded)
                let out = grade.apply(color.apply(scene))
                return LumenLog.encode(out)
            }
        }

        // ---- S14 + S15 -------------------------------------------------------
        var renderParams = look.render.resolved(displayWhiteTarget: displayWhiteTarget)
        toneEngine.applyAnchors(to: &renderParams)
        let transform = DisplayTransform(renderParams, space: space)
        self.displayTransform = transform
        self.displayWhite = transform.white

        let chain: FilmChain?
        if let film = look.filmLab, film.amount > 0, FilmStock.named(film.stock) != nil {
            chain = FilmChain(film, displayWhite: transform.white)
        } else {
            chain = nil
        }
        self.filmChain = chain

        let curve = CurveStack(develop.curve)
        let boundary = RenderPlan.sharedGamutBoundary
        let white = transform.white
        self.finishLUT = LUT3D(size: lutSize) { encoded in
            let scene = LumenLog.decode(encoded)
            let formed: RGB
            if let chain {
                formed = chain.apply(scene)
            } else {
                formed = transform.apply(scene, gamut: boundary)
            }
            return curve.apply(formed, white: white, space: space)
        }

        // ---- carried through --------------------------------------------------
        self.detail = develop.detail
        self.denoise = develop.denoise
        self.vignetteEV = look.vignette
        self.masks = recipe.masks.filter { $0.enabled }
    }

    /// One gamut boundary for the whole process: building it costs ~600 bisections
    /// and it depends only on the working space, so it is computed once.
    public static let sharedGamutBoundary = Gamut.Boundary()

    // MARK: - Per-pixel reference

    /// The composed per-pixel colour function, for stages that have no spatial
    /// component. This is what the LUTs approximate — goldens compare the two.
    public func referenceColor(_ sceneLinear: RGB) -> RGB {
        var c = linear.apply(sceneLinear)
        if !toneIsIdentity {
            let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
        }
        if !colorGradeIsIdentity {
            c = LumenLog.decode(colorGradeLUT.sample(LumenLog.encode(c)))
        }
        return LumenLog.decode(finishLUT.sample(LumenLog.encode(c)))
    }

    /// The same function with the LUT stages evaluated exactly rather than sampled —
    /// the f32 reference the LUT's interpolation error is measured against.
    public func exactColor(_ sceneLinear: RGB, space: RGBColorSpace = .rec2020) -> RGB {
        let develop = recipe.develop
        let look = recipe.look
        var c = linear.apply(sceneLinear)
        if !toneIsIdentity {
            let lum = Swift.max(space.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
        }
        let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                color: develop.color, primaries: look.primaries, bw: look.bw)
        let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                whiteAnchorEV: tone.whiteAnchorEV,
                                blackAnchorEV: tone.blackAnchorEV)
        c = grade.apply(color.apply(c))
        let formed: RGB
        if let filmChain {
            formed = filmChain.apply(c)
        } else {
            formed = displayTransform.apply(c, gamut: RenderPlan.sharedGamutBoundary)
        }
        return CurveStack(develop.curve).apply(formed, white: displayWhite, space: space)
    }

    /// Encode the tone gain as a cube so the GPU can apply it with the stock colour-cube
    /// filter against the log-encoded mask, with no custom kernel at all.
    public func toneGainCube(size: Int = 64) -> LUT3D {
        LUT3D(size: size) { encoded in RGB(gray: toneGainLUT.evaluate(encoded.r)) }
    }

    /// True when the whole colour path is a no-op and the renderer can hand the
    /// decoded image straight to the display transform.
    public var isColorIdentity: Bool {
        toneIsIdentity && colorGradeIsIdentity && linear.isIdentity
    }
}
