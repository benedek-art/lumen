// ReferenceRenderer.swift
// The whole pipeline, in f32, on the CPU, in the documented stage order.
//
// This is not the shipping render path — that is Core Image on the GPU. This is the
// definition docs/14 §1.4 requires: "every stage has an f32 reference implementation;
// the shipping fp16-buffered path must match it within stage-declared tolerance." It
// earns its place three times over:
//
//   · goldens render both paths and compare, so a shader can never drift silently;
//   · headless tooling renders a recipe to pixels with no display and no GPU;
//   · a machine whose kernels will not compile still produces correct images, slowly,
//     instead of producing wrong ones quickly.

import Foundation

public enum ReferenceRenderer {

    /// Rasterized mask alphas, and the AI mattes their components need, supplied by
    /// the caller's cache. Anything missing simply does not contribute.
    public struct Inputs: Sendable {
        public var strokeSets: [String: BrushStrokeSet]
        public var aiMattes: [String: Plane]
        public var grainSeed: UInt64

        public init(strokeSets: [String: BrushStrokeSet] = [:],
                    aiMattes: [String: Plane] = [:],
                    grainSeed: UInt64 = FilmGrainProfile.defaultPlateSeed) {
            self.strokeSets = strokeSets
            self.aiMattes = aiMattes
            self.grainSeed = grainSeed
        }
    }

    /// Render scene-linear input to display-linear output.
    public static func render(_ input: ImageBuffer, plan: RenderPlan,
                              inputs: Inputs = Inputs(),
                              space: RGBColorSpace = .rec2020) -> ImageBuffer {
        var image = input
        let longEdge = Swift.max(image.width, image.height)

        // S6 — the fused linear matrix.
        if !plan.linear.isIdentity {
            let matrix = plan.linear.matrix
            image = image.map { matrix.apply($0) }
        }

        // S7 — tone, weighted by the exposure-independent guided mask so a zone edit
        // follows edges instead of haloing across them.
        if !plan.toneIsIdentity {
            image = applyTone(image, plan: plan, longEdge: longEdge, space: space)
        }

        // S8 — presence, off one decomposition built once.
        let detail = plan.detail
        let needsDecomposition = detail.texture != 0 || detail.clarity != 0
            || detail.dehaze != 0 || detail.sharpen.amount > 0
        var decomposition: DetailEngine.Decomposition?
        if needsDecomposition {
            let radius = Swift.max(Int(Double(longEdge) * 0.02), 3)
            let node = DetailEngine.Decomposition(image: image, workingRadius: radius,
                                                  space: space)
            decomposition = node
            image = DetailEngine.apply(image, detail: detail, decomposition: node)
        }

        // S9 + S10 — colour and grade.
        if !plan.colorGradeIsIdentity {
            let lut = plan.colorGradeLUT
            image = image.map { LumenLog.decode(lut.sample(LumenLog.encode($0))) }
        }

        // S11 — local adjustments, blended through each mask's alpha in scene-linear.
        //
        // The alphas are rasterized ONCE here rather than inside the stage, because the
        // local point curve taps again after S14 and has to composite through the very
        // same alpha. Rasterizing twice would be a guided filter and a distance
        // transform run twice per mask for one curve.
        var alphas: [(mask: Mask, alpha: Plane)] = []
        if !plan.masks.isEmpty {
            alphas = plan.masks.map { mask in
                (mask, MaskRaster.combine(mask: mask,
                                          size: (width: image.width, height: image.height),
                                          source: image,
                                          strokeSets: inputs.strokeSets,
                                          aiMattes: inputs.aiMattes,
                                          // The whole list, so a `maskRef` component can
                                          // find what it points at. Without it a
                                          // reference selects nothing, silently.
                                          masks: plan.masks))
            }
            image = applyMasks(image, plan: plan, alphas: alphas, space: space)
        }

        // S12 — creative sharpening, after local so masked clarity is never
        // double-sharpened.
        if detail.sharpen.amount > 0, let node = decomposition {
            image = DetailEngine.applySharpen(image, params: detail.sharpen,
                                              decomposition: node)
        }

        // S13 — vignette in scene-linear, then halation: the lens vignettes the light
        // before it strikes the film, and the film base reflects what arrives.
        // Feather rides the plan with the EV (docs/32 Stream E item 4); at the
        // default it reproduces the fixed geometry bit-for-bit.
        if plan.vignetteEV != 0 {
            image = DetailEngine.vignette(image, ev: plan.vignetteEV,
                                          feather: plan.vignetteFeather)
        }
        // Halation was in the GPU graph and MISSING here, so the Halation slider did
        // nothing on the reference path — every headless render, every machine whose
        // kernels will not compile — and any golden comparing the two diverged wherever
        // it was set. `HalationProfile` already carried everything needed; only the
        // stage was absent.
        if let film = plan.filmChain, film.halationAmount > 0 {
            image = applyHalation(image, film: film, longEdge: longEdge)
        }

        // S14 + S15 — picture formation and the curve. The table ends in
        // display-linear, so this stage encodes going in and does not decode coming
        // out; the graph's `throughShaperToDisplay` is the same asymmetry.
        // `finishScale`, which the graph applies as a matrix after the same table
        // (`RenderGraph.build`). Dropping it here was harmless only while display white
        // is 1.0 — that is, only for SDR. Any plan with a whiteTarget above 100 rendered
        // the whole reference path, and the grain that runs after it, `1/white` too
        // dark, so the two paths disagreed by a factor rather than a tolerance exactly
        // when an HDR rendition was being checked against them.
        // Through `finishedColor` rather than the table directly, because the last stage
        // is the table PLUS the soft proof's gamut flag when one is on, and that flag is
        // computed per pixel rather than baked. One expression, so this path and the
        // graph cannot disagree about what the final stage is.
        image = image.map { plan.finishedColor(encoded: LumenLog.encode($0)) }

        // S15b — the local point curve, the second tap (docs/08 §8.4, docs/14). It runs
        // HERE, on the formed picture, because a curve is a picture-domain instinct:
        // the same curve applied at S11 would be shaping scene-referred code values,
        // where the parametric regions do not sit on the tones they are named after.
        // Same alpha as S11, so the two halves of a mask's sub-recipe select the same
        // pixels; the blend is in the picture domain because that is where the curve's
        // output lives.
        if !alphas.isEmpty {
            image = applyLocalCurves(image, alphas: alphas, plan: plan, space: space)
        }

        // Grain lives inside picture formation, in the density domain.
        //
        // Off `plan.grain` rather than off `plan.filmChain`: the plan answers "is there
        // grain here, and what is it" once, so this stage does not have to know that a
        // photograph can now be grained without an emulsion (`GrainPlan`). For a film
        // recipe the four numbers are the four this line used to read off the chain, so
        // the change is byte-identical there by construction.
        if let grain = plan.grain, grain.amount > 0 {
            image = applyGrain(image, grain: grain, seed: inputs.grainSeed,
                               longEdge: longEdge)
        }

        return image
    }

    /// Render exactly, without the tables — the reference the tables' interpolation
    /// error is measured against.
    public static func renderExact(_ input: ImageBuffer, plan: RenderPlan,
                                   space: RGBColorSpace = .rec2020) -> ImageBuffer {
        input.map { plan.exactColor($0, space: space) }
    }

    // MARK: - Stages

    /// The tone mask's contrast threshold: local structure flatter than this many
    /// stops is one surface and gets one gain; anything steeper is an edge the mask
    /// must not cross. MEASURED, not chosen (ToneMaskEdgeTests): at the shipped
    /// ε=0.004 — √0.004 encoded × 24 EV/unit = 1.52 EV, the fifth instance of
    /// BUILDING.md's units bug — Shadows +100 lifted the bright side of a 4 EV
    /// shadow/midtone edge by 0.497 EV, a half-stop halo beside every backlit
    /// subject. The naive ÷24² correction (0.06 EV) fails the other way: at ±0.2 EV
    /// of high-ISO luminance noise the mask follows the grain at σ 0.090 EV and the
    /// tone gains re-print it. 0.375 EV is the measured knee — halo 0.052 EV, noise
    /// σ 0.010 EV — with about 2x margin to each bar.
    public static let toneMaskContrastThresholdEV: Double = 0.375
    /// The threshold CONVERTED to the encoded plane the mask runs on (rule 1 of the
    /// units section in BUILDING.md: write the conversion, not the result).
    public static var toneMaskEpsilon: Double {
        let encoded = toneMaskContrastThresholdEV * LumenLog.invRange
        return encoded * encoded
    }

    static func applyTone(_ image: ImageBuffer, plan: RenderPlan, longEdge: Int,
                          space: RGBColorSpace) -> ImageBuffer {
        let luminance = image.luminancePlane(space: space)
        let log = luminance.map { LumenLog.encode(Swift.max($0, 0)) }
        let radius = Swift.max(Int(Double(longEdge) * 0.02), 2)
        let mask = SpatialOps.exposureIndependentGuidedFilter(
            luminance: log, radius: radius, epsilon: Self.toneMaskEpsilon,
            iterations: 1)

        var out = image
        let lut = plan.toneGainLUT
        for y in 0..<image.height {
            for x in 0..<image.width {
                let gain = lut.evaluate(mask[x, y])
                out[x, y] = image[x, y] * gain
            }
        }
        return out
    }

    static func applyMasks(_ image: ImageBuffer, plan: RenderPlan,
                           alphas: [(mask: Mask, alpha: Plane)],
                           space: RGBColorSpace) -> ImageBuffer {
        var out = image
        for (mask, alpha) in alphas {
            let adjusted = applyLocalAdjust(out, mask: mask, plan: plan, space: space)
            let blend = mask.blend
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let a = Num.saturate(alpha[x, y])
                    if a > 0 {
                        // The blend runs BEFORE the alpha composite, so Amount and
                        // the mask's own softness still do exactly what they did.
                        // `MaskAlgebra.blended` returns `adjusted` untouched in Normal,
                        // which is what makes this bit-identical for every existing mask.
                        let base = out[x, y]
                        let result = blend == .normal
                            ? adjusted[x, y]
                            : MaskAlgebra.blended(base: base, adjusted: adjusted[x, y],
                                                  blend: blend, space: space)
                        out[x, y] = base.mix(result, a)
                    }
                }
            }
        }
        return out
    }

    /// The local point curves (docs/08 §8.4), on the formed picture.
    ///
    /// One `LocalCurve` per mask that has one, evaluated per pixel and composited
    /// through that mask's alpha. Masks without a curve cost nothing: `isIdentity`
    /// skips them before a single pixel is touched, so a photograph with ten masks and
    /// no curves does not pay for this stage at all.
    static func applyLocalCurves(_ image: ImageBuffer,
                                 alphas: [(mask: Mask, alpha: Plane)],
                                 plan: RenderPlan,
                                 space: RGBColorSpace) -> ImageBuffer {
        var out = image
        for (mask, alpha) in alphas {
            // `finishScale` — the white of the pixels in hand — matching `RenderGraph`,
            // where the distinction can actually bite (a reference plan is never built
            // with stale tables). The two renderers state the same rule or the parity
            // contract is only true by luck.
            let curve = LocalCurve(curve: mask.adjust.curve, amount: mask.amount,
                                   white: plan.finishScale, space: space)
            guard !curve.isIdentity else { continue }
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let a = Num.saturate(alpha[x, y])
                    if a > 0 {
                        out[x, y] = out[x, y].mix(curve.apply(out[x, y]), a)
                    }
                }
            }
        }
        return out
    }

    /// The local Colour tint: a mix toward a target hue that holds the pixel's own
    /// luminance, so tinting a mask does not also brighten it.
    ///
    /// Here, and shared, because the two render paths each dropped a different local
    /// control: the GPU path declared a mask identity when its only edit was a Point
    /// Colour swatch, and this path never read `colorTint` at all. Each was silently
    /// missing what the other applied, which is exactly the divergence a single
    /// implementation makes impossible.
    public static func applyColorTint(_ c: RGB, tint: [Double]?, strength: Double,
                                      space: RGBColorSpace = .rec2020) -> RGB {
        guard let tint, tint.count >= 3, strength > 0 else { return c }
        let target = RGB(tint[0], tint[1], tint[2])
        let targetLuminance = space.luminance(target)
        guard targetLuminance > 1e-6 else { return c }
        let luminance = Swift.max(space.luminance(c), 0)
        return c.mix(target * luminance / targetLuminance, Num.saturate(strength))
    }

    /// A mask's sub-recipe is a delta over the global parameters, evaluated with the
    /// same engines the global path uses — never a parallel implementation.
    static func applyLocalAdjust(_ image: ImageBuffer, mask: Mask, plan: RenderPlan,
                                 space: RGBColorSpace) -> ImageBuffer {
        let scale = Num.clamp(mask.amount, 0, 200) / 100.0
        let a = mask.adjust
        let tone = ToneEngine(tone: Tone(exposure: a.exposure * scale,
                                         contrast: a.contrast * scale,
                                         highlights: a.highlights * scale,
                                         shadows: a.shadows * scale,
                                         whites: a.whites * scale,
                                         blacks: a.blacks * scale))
        let color = ColorEngine(mixer: Mixer(),
                                pointColors: a.pointColors.map { $0.scalingShift(by: scale) },
                                // Density and protectSkin inherited from the global
                                // colour panel — see `ColorAdjust.local` for why an
                                // invisible default-70 protection was the wrong thing
                                // to hand a masked Sat −100 (COLOR-27).
                                color: .local(vibrance: a.vibrance * scale,
                                              saturation: a.sat * scale,
                                              inheriting: plan.recipe.develop.color),
                                primaries: Primaries(), bw: nil)
        let exposureGain = tone.exposureGain
        let hueShift = a.hue * scale
        let context = OKLabTransform.working
        let balance = LocalWhiteBalance.resolve(a, amount: scale,
                                                balanced: plan.balancedNeutral,
                                                space: space)
        let tintColor = a.colorTint
        let tintStrength = Num.clamp(a.colorTintStrength, 0, 100) / 100 * scale
        // Local grading wheels (D29), the same engine the global grade uses. Kept in
        // step with `LocalPlan` on the GPU side deliberately: a mask's sub-recipe is a
        // delta evaluated with the shared engines, and the moment the two paths grow
        // separate grade code a golden that compares them starts measuring the
        // difference between two implementations rather than one implementation's error.
        let localGrade = (a.wheels?.isNeutral ?? true)
            ? nil
            // `adoptingWindows`: the mask's colour moves inside the GLOBAL wheels'
            // tonal windows, which is the docs/08 §8.4 contract both paths violated
            // for the wheels' whole life (COLOR-16).
            : GradeEngine(wheels: a.wheels!.scalingShift(by: scale)
                              .adoptingWindows(from: plan.recipe.look.wheels),
                          printerLights: PrinterLights(),
                          whiteAnchorEV: plan.tone.whiteAnchorEV,
                          blackAnchorEV: plan.tone.blackAnchorEV)

        var out = image.map { pixel in
            var c = pixel * exposureGain
            if !tone.isIdentity {
                let lum = Swift.max(space.luminance(c), 0)
                c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
            }
            c = balance.apply(c)
            c = color.apply(c)
            if hueShift != 0 {
                var lch = context.toLCh(c)
                lch.h = Num.wrapHue(lch.h + hueShift)
                c = context.toRGB(lch)
            }
            // The GPU path applied this and the reference did not, so the two rendered
            // different pictures for any mask with a Colour tint — and a golden
            // comparing them would have diverged wherever one was set.
            c = applyColorTint(c, tint: tintColor, strength: tintStrength,
                               space: space)
            // After colour and tint, matching the GPU local plan and the global
            // stage order.
            if let localGrade { c = localGrade.apply(c) }
            return c
        }

        // The spatial half of the local set. These run over the WHOLE buffer and the
        // caller composites the result through the mask's alpha — the same shape the
        // colour half already had, and the reason a masked Clarity does not need its
        // own cropped decomposition.
        let texture = a.texture * scale
        let clarity = a.clarity * scale
        let dehaze = a.dehaze * scale
        let sharpness = a.sharpness * scale
        if texture != 0 || clarity != 0 || dehaze != 0 || sharpness != 0 {
            let radius = Swift.max(Int(Double(Swift.max(out.width, out.height)) * 0.02), 3)
            let node = DetailEngine.Decomposition(image: out, workingRadius: radius,
                                                  space: space)
            out = DetailEngine.applyTexture(out, amount: texture, decomposition: node)
            out = DetailEngine.applyClarity(out, amount: clarity, decomposition: node)
            out = DetailEngine.applyDehaze(out, amount: dehaze, decomposition: node)
            if sharpness > 0 {
                out = DetailEngine.applySharpen(
                    out, params: ManualSharpen(amount: Num.clamp(sharpness, 0, 150)),
                    decomposition: node)
            } else if sharpness < 0 {
                // Negative Sharpness is a blur, which `applySharpen` refuses by
                // contract (it clamps amount at 0). A small Gaussian is what the
                // control means.
                let sigma = Num.clamp(-sharpness / 100, 0, 1) * 2.5
                out = SpatialOps.gaussianBlur(out, sigma: sigma)
            }
        }
        return out
    }

    /// A local Temp/Tint nudge. The mask panel's two sliders are RELATIVE — −100…+100
    /// around whatever the global white balance settled on — so they cannot go through
    /// `WhiteBalanceEngine`, which speaks in absolute Kelvin. They are converted to a
    /// mired shift about a 5500 K anchor, which is what "warmer by a bit" means in a
    /// way that behaves the same at every global temperature.
    public struct LocalWhiteBalance: Sendable {
        public let matrix: Mat3
        public let isIdentity: Bool

        public init(temp: Double, tint: Double, space: RGBColorSpace = .rec2020) {
            let t = Num.clamp(temp, -100, 100)
            let g = Num.clamp(tint, -100, 100)
            guard t != 0 || g != 0 else {
                self.matrix = .identity
                self.isIdentity = true
                return
            }
            self.isIdentity = false
            // ±100 is ±50 mired, about 5500 K → 4400 K one way and 7300 K the other:
            // a decisive nudge, not a relabelling of the whole scene.
            let anchorMired = 1e6 / 5500.0
            let target = 1e6 / Num.clamp(anchorMired - t * 0.5, 20, 500)
            self.matrix = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                             targetKelvin: target,
                                             targetTint: g * 1.5,
                                             space: space).matrix
        }

        /// ABSOLUTE per-mask white balance: this region is lit at `kelvin`, whatever the
        /// global row says.
        ///
        /// By the time the local stage runs the pixel has already been carried to
        /// `balanced` by S6, so the incremental matrix is the one that re-balances FROM
        /// there TO the mask's target. That is what makes the number stable: drag the
        /// global temperature and `balanced` moves, this matrix moves the opposite way,
        /// and the masked region renders at the Kelvin it is labelled with. Neither
        /// Lightroom nor Capture One offers this; both give a relative shift only, and a
        /// relative shift silently re-lights every mask the moment the global row moves.
        ///
        /// AMOUNT interpolates in MIRED, not in Kelvin. Half of "3200 K" is not 1600 K —
        /// mired is the space colour temperature is perceptually even in, and it is the
        /// space the relative slider above already works in, so a mask fading from 0 to
        /// 100 passes through the same colours either spelling is written in. Tint,
        /// which is already a linear axis, interpolates directly.
        ///
        /// At `amount` 0 this is exactly the identity: the endpoint IS `balanced`, so
        /// the engine is asked to adapt a neutral to itself.
        public init(kelvin: Double, tint: Double?, amount: Double,
                    balanced: WhiteBalanceEngine.Neutral,
                    space: RGBColorSpace = .rec2020) {
            let scale = Num.saturate(amount)
            let target = Num.clamp(kelvin, ColorTemperature.minKelvin,
                                   ColorTemperature.maxKelvin)
            let fromMired = 1e6 / Swift.max(balanced.kelvin, 1)
            let toMired = 1e6 / Swift.max(target, 1)
            let mired = fromMired + (toMired - fromMired) * scale
            let toTint = Num.clamp(tint ?? balanced.tint, -300, 300)
            let effectiveTint = balanced.tint + (toTint - balanced.tint) * scale
            let engine = WhiteBalanceEngine(asShotKelvin: balanced.kelvin,
                                            asShotTint: balanced.tint,
                                            targetKelvin: 1e6 / Swift.max(mired, 1e-9),
                                            targetTint: effectiveTint, space: space)
            self.matrix = engine.matrix
            self.isIdentity = false
        }

        /// The one place that decides which spelling a mask is using, so the reference
        /// renderer and the GPU's `LocalPlan` cannot disagree about it.
        public static func resolve(_ a: LocalAdjust, amount: Double,
                                   balanced: WhiteBalanceEngine.Neutral,
                                   space: RGBColorSpace = .rec2020) -> LocalWhiteBalance {
            if let kelvin = a.kelvin {
                return LocalWhiteBalance(kelvin: kelvin, tint: a.kelvinTint,
                                         amount: amount, balanced: balanced, space: space)
            }
            return LocalWhiteBalance(temp: a.temp * amount, tint: a.tint * amount,
                                     space: space)
        }

        public func apply(_ c: RGB) -> RGB { isIdentity ? c : matrix.apply(c) }
    }

    /// Halation: the highlight energy that passes through the emulsion, scatters off
    /// the film base and comes back — three bounces at geometrically spaced radii,
    /// decaying each time, because the base is not a single-scale scatterer.
    ///
    /// The stage order matters and is the graph's: this runs on scene-linear data after
    /// the vignette and before picture formation. `HalationProfile` owns the physics;
    /// this owns the blurs and the accumulation, which is the same split the GPU path
    /// uses.
    static func applyHalation(_ image: ImageBuffer, film: FilmChain,
                              longEdge: Int) -> ImageBuffer {
        // The same accessor the graph uses, so the two stages cannot be handed
        // different profiles for the same recipe.
        let profile = film.halation(longEdgePixels: longEdge)
        guard profile.strengths.maxComponent > 0 else { return image }

        let energy = image.map { profile.highlightEnergy($0) }
        var glow = ImageBuffer(width: image.width, height: image.height)
        var weight = 1.0
        var contributed = false
        for sigma in profile.sigmasInPixels where sigma > 0 {
            let blurred = SpatialOps.gaussianBlur(energy, sigma: sigma)
            for y in 0..<glow.height {
                for x in 0..<glow.width {
                    glow[x, y] = glow[x, y] + blurred[x, y] * weight
                }
            }
            contributed = true
            weight *= profile.decay
        }
        guard contributed else { return image }

        var out = image
        for y in 0..<out.height {
            for x in 0..<out.width {
                out[x, y] = profile.combine(image[x, y], blurred: glow[x, y])
            }
        }
        return out
    }

    /// The film path's spelling, delegating. Kept because `FilmChain` is what the
    /// goldens hold and what `PipelineRenderer` passes: a test that had to assemble a
    /// `GrainPlan` in order to ask a question about an emulsion would be measuring the
    /// plan rather than the stock. One implementation, two front doors.
    static func applyGrain(_ image: ImageBuffer, film: FilmChain, seed: UInt64,
                           longEdge: Int) -> ImageBuffer {
        applyGrain(image, grain: GrainPlan.film(film), seed: seed, longEdge: longEdge)
    }

    /// The density-domain grain stage, for whichever grain the plan resolved.
    ///
    /// Unchanged in every arithmetic detail from the version that took a `FilmChain`;
    /// what moved is where the four scalars come from. A creative grain differs from a
    /// stock's only in the profile it was built from — a 35 mm gate, a pitch off the Size
    /// slider, a flat Dmax and a plate persistence off Roughness — so there is one grain
    /// implementation on this path and there always was.
    static func applyGrain(_ image: ImageBuffer, grain: GrainPlan, seed: UInt64,
                           longEdge: Int) -> ImageBuffer {
        let plateSize = GrainPlan.plateSize
        // One plate per emulsion layer, at that layer's own crystal size.
        //
        // The amplitude envelope √(p(1−p)) was already per-channel, but a single noise
        // value `n` went into all three — which is a luminance overlay wearing film's
        // envelope, not film. Colour film has three physically separate dye layers with
        // their own crystals, so their grain is uncorrelated and the blue layer's is
        // coarsest; `grainSizeScale` has said (0.8, 1.0, 2.0) since the stocks were
        // authored and `plateScale(…, channel:)` was written to use it and never called.
        //
        // `plateSeed(channel:)` collapses to one seed on a monochrome stock, so Tri-X
        // keeps a single field and cannot acquire coloured speckle.
        //
        // Through `GrainPlan.plate` rather than `FilmGrainProfile.plate`, because the
        // plate's PERSISTENCE now lives on the profile and a caller that assembled the
        // arguments itself would have had to remember to pass it — which is precisely
        // how the GPU plate ended up with a different seed from this one, back when both
        // spelled the seed themselves.
        let plates = (0..<3).map { grain.plate(channel: $0, size: plateSize, seed: seed) }
        let scales = (0..<3).map {
            grain.plateScale(longEdgePixels: longEdge, channel: $0)
        }
        var out = image
        let dmax = Swift.max(grain.dMax, 0.1)
        let amount = grain.amount
        for y in 0..<image.height {
            for x in 0..<image.width {
                let c = image[x, y]
                var result = RGB.zero
                for channel in 0..<3 {
                    let n = FilmGrainProfile.sample(plates[channel], size: plateSize,
                                                    x: Double(x) / scales[channel],
                                                    y: Double(y) / scales[channel])
                    let v = Swift.max(c[channel], 1e-5)
                    let density = -log10(v)
                    let p = Num.saturate(density / dmax)
                    let amplitude = (p * (1 - p)).squareRoot()
                    result[channel] = pow(10, -(density + amplitude * n * amount))
                }
                out[x, y] = result
            }
        }
        return out
    }
}
