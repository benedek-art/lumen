// RenderGraph.swift
// The Core Image graph, assembled in the stage order docs/14 §2 fixes. Core Image is
// used as a graph compiler — lazy fusion, ROI-driven tiled evaluation, extended-range
// working formats — not as a filter library: the colour-bearing work is Lumen's own
// baked tables and kernels, and stock filters appear only for blurs, resampling and
// encoding, where bit-exactness against our reference is not the point.
//
// Every stage is individually skippable and individually degradable. A missing kernel
// or a nil filter output drops that stage and leaves the rest of the chain intact,
// because a render that is missing its vignette is recoverable and a render that
// crashes the app in the middle of a shoot is not.

#if os(macOS)

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import LumenCore

public struct RenderGraph {

    /// Working resolution for the interactive path (docs/14 §6.2). Scale-dependent
    /// radii are scaled against this so the fit view is not a lie.
    public static let workingLongEdge: Int = 2560

    public struct Options: Sendable {
        /// Long edge of the image being rendered, used to scale spatial radii.
        public var longEdge: Int
        /// Skip the expensive spatial stages for the first interactive frame.
        public var draft: Bool
        /// Table size — interactive during a drag, export size when it settles.
        public var lutSize: Int

        public init(longEdge: Int, draft: Bool = false,
                    lutSize: Int = LUT3D.interactiveSize) {
            self.longEdge = longEdge
            self.draft = draft
            self.lutSize = lutSize
        }
    }

    /// Rasterized mask alphas keyed by mask id, supplied by the mask cache. Missing
    /// entries simply mean that mask does not contribute this frame.
    public var maskImages: [String: CIImage] = [:]
    /// The film grain plate, tiled, supplied by the film stage's cache.
    public var grainPlate: CIImage?

    public init() {}

    // MARK: - The chain

    /// S6 through S10 — everything upstream of the local stage.
    ///
    /// Factored out because the mask rasterizer needs exactly this image: a luma-range
    /// or colour-range component samples the LOCAL STAGE INPUT, which is what makes its
    /// handles EV-denominated and stable (docs/08 §8.2), and the CPU reference passes
    /// precisely this (`ReferenceRenderer.applyMasks(source: image)`). Calling it rather
    /// than repeating the sequence keeps the two from drifting apart.
    public func localStageInput(_ input: CIImage, plan: RenderPlan,
                                options: Options) -> CIImage {
        var image = input

        // S6 — one fused matrix: white balance, exposure, printer lights.
        image = Self.applyMatrix(image, plan.linear.matrix)

        // S7 — tone, driven by the edge-aware guided mask.
        if !plan.toneIsIdentity {
            image = applyTone(image, plan: plan, options: options)
        }

        // S8 — presence, off one base–detail decomposition.
        if !options.draft {
            image = applyPresence(image, plan: plan, options: options)
        }

        // S9 + S10 — colour and grade, as one table on the log axis.
        if !plan.colorGradeIsIdentity {
            image = Self.throughShaper(image) { encoded in
                ColorCube.filter(plan.colorGradeLUT, image: encoded)
            } ?? image
        }
        return image
    }

    public func build(_ input: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        var image = localStageInput(input, plan: plan, options: options)

        // S11 — local adjustments, blended through each mask's alpha.
        if !plan.masks.isEmpty && !options.draft {
            image = applyLocal(image, plan: plan, options: options)
        }

        // S12 — creative sharpening, after local so masked clarity is not
        // double-sharpened.
        if !options.draft, plan.detail.sharpen.amount > 0 {
            image = Self.applySharpen(image, plan.detail.sharpen, longEdge: options.longEdge)
        }

        // S13 — vignette, then halation: the lens vignettes the light before it
        // strikes the film, and the film base reflects what arrives.
        if plan.vignetteEV != 0 {
            image = applyVignette(image, ev: plan.vignetteEV,
                                  crop: plan.recipe.develop.geometry.crop)
        }
        if let film = plan.filmChain, film.halationAmount > 0, !options.draft {
            image = applyHalation(image, film: film, longEdge: options.longEdge)
        }

        // S14 + S15 — picture formation and the curve, as one table. The table is
        // normalized, so display white comes back through a matrix; that keeps an HDR
        // rendition's highlights out of the cube's unit domain entirely.
        if let formed = Self.throughShaperToDisplay(image, { encoded in
            ColorCube.filter(plan.finishLUT, image: encoded)
        }) {
            image = Self.applyMatrix(formed, Mat3.diagonal(RGB(gray: plan.finishScale)))
        } else {
            // Picture formation failing is not a stage to skip: handing back
            // scene-referred data as if it were a picture is worse than any fallback.
            // Apply the transform's own curve through a 1-D cube instead.
            image = Self.applyFallbackTone(image, plan: plan) ?? image
        }

        // Grain lives inside picture formation, in the density domain.
        if let film = plan.filmChain, film.grainAmount > 0, let plate = grainPlate,
           !options.draft {
            image = applyGrain(image, plate: plate, film: film)
        }

        return image
    }

    // MARK: - S6

    static func applyMatrix(_ image: CIImage, _ m: Mat3) -> CIImage {
        if m.maxAbsDifference(.identity) < 1e-12 { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        // CIColorMatrix multiplies each INPUT channel by its vector and sums, so the
        // vectors are the matrix's columns, not its rows. Getting this backwards
        // transposes every colour transform in the app and looks almost right.
        filter.rVector = CIVector(x: m.m[0][0], y: m.m[1][0], z: m.m[2][0], w: 0)
        filter.gVector = CIVector(x: m.m[0][1], y: m.m[1][1], z: m.m[2][1], w: 0)
        filter.bVector = CIVector(x: m.m[0][2], y: m.m[1][2], z: m.m[2][2], w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage ?? image
    }

    // MARK: - S7 tone

    func applyTone(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        guard let lum = Self.logLuminance(image) else { return image }
        // The mask is edge-aware and computed in log space, so it stays valid when
        // Exposure moves — the exposure-independent property the tone equalizer needs.
        let radius = Swift.max(Int(Double(options.longEdge) * 0.02), 2)
        let mask = Self.guidedSelfFilter(lum, radius: radius, epsilon: 0.004) ?? lum
        // The plan's stored cube, baked once per plan. Calling `toneGainCube()`
        // rebuilt 32 768 samples on every frame of every slider drag.
        let cube = plan.toneGainCube32 ?? plan.toneGainCube()
        guard let normalized = ColorCube.filter(cube, image: mask) else {
            return image
        }
        // The cube stores gains normalized into the unit domain; the scale comes back
        // as a matrix multiply, so a +2 EV shadow lift cannot be clipped by the table.
        let gain = Self.applyMatrix(normalized,
                                    Mat3.diagonal(RGB(gray: plan.toneGainScale)))
        return KernelLibrary.apply(KernelLibrary.multiply, extent: image.extent,
                                   [image, gain]) ?? image
    }

    // MARK: - S8 presence

    func applyPresence(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        Self.applyPresence(image, detail: plan.detail, longEdge: options.longEdge)
    }

    /// Presence over an explicit `Detail`, so the local stage can run the same code on
    /// a mask's own texture/clarity/dehaze values instead of having none.
    static func applyPresence(_ image: CIImage, detail d: Detail,
                              longEdge: Int) -> CIImage {
        var out = image

        // Texture → Clarity → Dehaze, matching `DetailEngine.apply`. Dehaze used to run
        // FIRST here, so with any two of the three set the two paths rendered different
        // pixels by construction: dehaze is a contrast expansion, and expanding before
        // versus after the two detail gains is not the same operation. The reference is
        // the contract, so the graph follows it rather than the other way round.
        guard d.texture != 0 || d.clarity != 0 || d.dehaze != 0 else { return out }

        if d.texture != 0 || d.clarity != 0, let lum = Self.logLuminance(out) {
            out = Self.applyDetailBands(out, detail: d, lum: lum, longEdge: longEdge)
        }
        if d.dehaze != 0 {
            out = Self.applyDehaze(out, amount: d.dehaze, longEdge: longEdge)
        }
        return out
    }

    /// The two detail-band gains, off one decomposition of `lum`.
    private static func applyDetailBands(_ image: CIImage, detail d: Detail,
                                         lum: CIImage, longEdge: Int) -> CIImage {
        var out = image

        // One decomposition, two bands: texture is the fine scale, clarity the mid
        // scale. Both come off guided filters, so neither can halo.
        // Rounded, not truncated, and floored at 2 like every other radius in this
        // file. `Int(longEdge * 0.003)` is 0 for any long edge below 334 px — every
        // thumbnail and grid preview in the app — and the old floor of 1 is the radius
        // CIBoxBlur ignores, so Texture was inert across that whole range rather than
        // merely coarse. The tone mask and dehaze already floor at 2 and 3; 1 was the
        // outlier.
        let fine = Swift.max(Int((Double(longEdge) * 0.003).rounded()), 2)
        let mid = Swift.max(Int((Double(longEdge) * 0.02).rounded()), 3)
        guard let baseFine = Self.guidedSelfFilter(lum, radius: fine, epsilon: 0.0008),
              let baseMid = Self.guidedSelfFilter(lum, radius: mid, epsilon: 0.004)
        else { return out }

        // `k` is a gain exponent PER STOP, and the plane these bands come off is
        // `logLuminance` — which is `LumenLog.encode`d, not EV. The encoding squeezes a
        // 24-stop domain into [0,1], so one stop of local detail arrives as 1/24 of a
        // unit and `exp2(k · Δ)` was computing a gain of `2^(k·ΔEV/24)`.
        //
        // What that cost: Texture at +100 moved local contrast by 2.6% where the
        // reference implementation, whose delta is explicitly `deltaEV`, moves it by
        // 100%. The two most-used presence sliders in the app were, on every preview
        // and every export, doing about one twenty-fifth of what they said — and the
        // one test that turns these stages on also sets a −1 EV vignette and asserts
        // only that *something* moved, so it passed either way.
        //
        // Converting the coefficient is exact rather than approximate: the encoding is
        // affine in EV above its toe, so `k · range` reproduces `2^(k·ΔEV)` to 1.6e-14
        // across the whole 0.05–4 EV band.
        let perStop = LumenLog.range

        if d.texture != 0 {
            let k = d.texture / 100.0 * 0.9 * perStop
            // NEGATIVE Texture is gated by local structure and positive Texture is not.
            // That asymmetry is the whole difference between a skin smoother and a
            // negative-Clarity glow: ungated, it attacks an eyelash as readily as a
            // pore, so the face goes waxy while the edges go soft. docs/06 names the
            // gate as the point of the control.
            //
            // The radius is the reference's `workingRadius / 4`, not `mid`. It was
            // `mid` here — four times too wide — which, together with the two errors in
            // the coherence kernel itself, had the gate closing on the flat skin it is
            // meant to smooth and opening on the edges it is meant to protect.
            let gate = d.texture < 0
                ? Self.localStructure(lum, radius: Self.structureRadius(longEdge: longEdge))?
                    .coherence
                : nil
            let gained: CIImage?
            if let gate {
                gained = KernelLibrary.apply(
                    KernelLibrary.detailGainGated, extent: out.extent,
                    [lum, baseFine, gate, Float(k), Float(1.0)])
            } else {
                gained = KernelLibrary.apply(KernelLibrary.detailGain,
                                             extent: out.extent,
                                             [lum, baseFine, Float(k)])
            }
            if let gained,
               let combined = KernelLibrary.apply(KernelLibrary.multiply,
                                                  extent: out.extent, [out, gained]) {
                out = combined
            }
        }
        if d.clarity != 0 {
            let k = d.clarity / 100.0 * 1.1 * perStop
            if let gain = KernelLibrary.apply(KernelLibrary.detailGain,
                                              extent: out.extent,
                                              [baseFine, baseMid, Float(k)]),
               let combined = KernelLibrary.apply(KernelLibrary.multiply,
                                                  extent: out.extent, [out, gain]) {
                out = combined
            }
        }
        return out
    }

    static func applyDehaze(_ image: CIImage, amount: Double, longEdge: Int) -> CIImage {
        let strength = Num.clamp(amount / 100.0, -1, 1)
        guard strength != 0 else { return image }
        let radius = Swift.max(Int(Double(longEdge) * 0.01), 3)

        // Dark channel via the stock minimum morphology, then the guided filter
        // refines the transmission so edges survive.
        let minimum = CIFilter.morphologyRectangleMinimum()
        minimum.inputImage = image.clampedToExtent()
        minimum.width = Float(radius * 2 + 1)
        minimum.height = Float(radius * 2 + 1)
        guard let darkRGB = minimum.outputImage?.cropped(to: image.extent) else {
            return image
        }
        guard let dark = Self.channelMinimum(darkRGB) else { return image }

        // Airlight: the BRIGHTEST region of the dark channel, which is He et al.'s
        // definition and what `SpatialOps.estimateAirlight(topFraction: 0.001)` does on
        // the reference path.
        //
        // This used to be the dark channel's MEAN. The comment was right that a frame
        // average is wrong and switching to the dark channel helped, but a mean of the
        // dark channel is still roughly half the true airlight — and it divides the
        // transmission, so `t = 1 − w·dark/A` collapsed. With the floor at 0.1 the
        // recombination was then free to amplify by 10×: Dehaze +20 pushed part of the
        // frame above scene white, and +50 put a fifth of it on the clamp. The
        // reference renders the same recipe with no clipping at all.
        //
        // Taking the maximum of the PROXY rather than of the full-resolution plane is
        // what keeps this robust: each proxy pixel is already the mean of a block, so a
        // single hot pixel cannot define the airlight. Measured on a proxy and frozen
        // for the render, which is also what the proxy-field rule requires for tiled
        // export (docs/14 §6.3).
        // He et al.'s definition, which the reference implements: the airlight is the
        // colour of the SOURCE IMAGE where the dark channel is brightest — not the dark
        // channel's own maximum.
        //
        // Taking the dark channel's maximum returns a GREY, because the dark channel is
        // a per-pixel channel minimum and `CIMinimumComponent` emits greyscale. So the
        // neutralisation gains below came out (1,1,1) on every frame, and the step the
        // dehaze kernel calls load-bearing — "the veil is white-balanced away, which is
        // what stops magenta skies at the algorithm level" — was an identity multiply.
        // Negative Dehaze was worse: it blends toward the airlight, so it painted GREY
        // fog. Measured against the reference on a hazy scene, a sky pixel lost 0.16
        // scene-linear in blue, about a fifth of it, and desaturated instead of hazing.
        //
        // The masked mean comes out of two area averages: the kernel zeroes everything
        // below the threshold and carries the selection in alpha, so sum(rgb)/N divided
        // by sum(alpha)/N is the mean over the selected pixels alone.
        let proxy = Self.scaledToProxy(dark)
        let imageProxy = Self.scaledToProxy(image)
        let brightest = Self.maximumColor(proxy)?.maxComponent ?? 0.8
        var airlight = RGB(gray: 0.8)
        if let masked = KernelLibrary.apply(
            KernelLibrary.thresholdMask, extent: imageProxy.extent,
            [imageProxy, proxy, Float(brightest * 0.99)]),
           let sums = Self.averageColor(masked),
           let weight = Self.averageAlpha(masked), weight > 1e-6 {
            airlight = RGB(sums.r / weight, sums.g / weight, sums.b / weight)
        }
        let mean = Swift.max((airlight.r + airlight.g + airlight.b) / 3, 1e-4)

        // t = 1 − w·dark/A, refined. The amount is NOT folded in here any more.
        //
        // It used to be — `scale` carried `-strength` — which conflated the estimate
        // with the strength: the transmission map itself changed shape as the slider
        // moved, so the recombination could not be the reference's, which takes an
        // amount-independent transmission and applies the amount at the end. Folding it
        // in also made the negative branch's transmission the wrong sign entirely.
        let scale = -0.95 / mean
        let scaled = Self.applyMatrix(dark, Mat3.diagonal(RGB(gray: scale)))
        let biased = Self.addConstant(scaled, 1.0)
        let refined = Self.crossGuidedFilter(input: biased, guide: dark, radius: radius,
                                             epsilon: 0.0025) ?? biased

        // The same base transmission floor the reference uses. The reference ALSO lifts
        // it per pixel toward 0.9 where the frame is bright and flat — its sky guard —
        // which needs the gradient and log-luminance planes the kernel is not given, so
        // that part stays reference-only and is listed in BUILDING.md.
        let distance = Num.clamp(DetailEngine.dehazeDistance, 0, 100) / 100
        let floorT = Num.mix(0.55, 0.05, distance)

        // Neutralization gains: after multiplying by these the veil is grey at
        // `airLuma`, which is what lets a single luminance ratio carry the whole
        // recombination without touching the colour.
        let weights = RGBColorSpace.rec2020.luminanceWeights
        let airLuma = Swift.max(RGBColorSpace.rec2020.luminance(airlight), 1e-5)
        let gain = RGB(airLuma / Swift.max(airlight.r, 1e-5),
                       airLuma / Swift.max(airlight.g, 1e-5),
                       airLuma / Swift.max(airlight.b, 1e-5))

        return KernelLibrary.apply(
            KernelLibrary.dehaze, extent: image.extent,
            [image, refined,
             CIVector(x: gain.r, y: gain.g, z: gain.b),
             CIVector(x: weights.r, y: weights.g, z: weights.b),
             CIVector(x: airlight.r, y: airlight.g, z: airlight.b),
             Float(airLuma), Float(floorT), Float(strength)]) ?? image
    }

    // MARK: - S11 local

    func applyLocal(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        var out = image
        for mask in plan.masks {
            guard let alpha = maskImages[mask.id] else { continue }
            let adjusted = Self.applyLocalAdjust(out, mask: mask, plan: plan,
                                                 longEdge: options.longEdge)
            guard let blended = KernelLibrary.apply(KernelLibrary.blendMask,
                                                    extent: out.extent,
                                                    [out, adjusted, alpha])
            else { continue }
            out = blended
        }
        return out
    }

    /// A mask's sub-recipe evaluated on the stage input. Local parameters are deltas
    /// over the global ones, so this is the same maths as the global path with a
    /// different parameter set — never a parallel implementation.
    static func applyLocalAdjust(_ image: CIImage, mask: Mask, plan: RenderPlan,
                                 longEdge: Int) -> CIImage {
        let scale = Num.clamp(mask.amount, 0, 200) / 100.0
        let a = mask.adjust
        var out = image

        let exposure = a.exposure * scale
        if exposure != 0 {
            out = applyMatrix(out, Mat3.diagonal(RGB(gray: pow(2, exposure))))
        }

        // The rest of the local set is per-pixel colour work, so it bakes into a table
        // exactly like the global path does.
        let localPlan = LocalPlan(adjust: a, scale: scale,
                                  whiteAnchorEV: plan.tone.whiteAnchorEV,
                                  blackAnchorEV: plan.tone.blackAnchorEV)
        if !localPlan.isIdentity {
            out = throughShaper(out) { encoded in
                ColorCube.filter(localPlan.lut, image: encoded)
            } ?? out
        }

        // The spatial half. It runs over the whole frame and `applyLocal` composites
        // the result through the mask's alpha, which is why a masked Clarity needs no
        // cropped decomposition of its own. Without this the mask panel's Texture,
        // Clarity, Dehaze and Sharpness sliders moved and nothing happened.
        var localDetail = Detail()
        localDetail.texture = a.texture * scale
        localDetail.clarity = a.clarity * scale
        localDetail.dehaze = a.dehaze * scale
        if localDetail.texture != 0 || localDetail.clarity != 0 || localDetail.dehaze != 0 {
            out = Self.applyPresence(out, detail: localDetail, longEdge: longEdge)
        }

        let sharpness = a.sharpness * scale
        if sharpness > 0 {
            out = Self.applySharpen(out,
                                    ManualSharpen(amount: Num.clamp(sharpness, 0, 150)),
                                    longEdge: longEdge)
        } else if sharpness < 0 {
            // Negative Sharpness is a softening; `applySharpen` clamps at zero.
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = out.clampedToExtent()
            filter.radius = Float(Num.clamp(-sharpness / 100, 0, 1) * 2.5)
            out = filter.outputImage?.cropped(to: out.extent) ?? out
        }
        return out
    }

    // MARK: - S12 sharpen

    /// Sharpening as a log-luminance delta, which is what the reference does and what
    /// `CIUnsharpMask` could not express.
    ///
    /// The stock filter was the whole path, so Masking and Halo Suppression — one of
    /// which docs/06 calls "the fifth slider Adobe never shipped" — were live controls
    /// no preview and no export ever read, and Detail had to be folded into a radius
    /// because a USM has nowhere else to put it. A per-channel USM also shifts hue on
    /// any saturated edge; a luminance ratio cannot.
    ///
    /// Falls back to the stock filter if any kernel is unavailable, rather than
    /// dropping the stage: a soft picture is a better failure than a stage that
    /// silently does nothing.
    static func applySharpen(_ image: CIImage, _ sharpen: ManualSharpen,
                             longEdge: Int) -> CIImage {
        let amount = Num.clamp(sharpen.amount, 0, 150) / 100
        guard amount > 0 else { return image }
        let radius = Num.clamp(sharpen.radius, 0.5, 3.0)
        let detail = Num.clamp(sharpen.detail, 0, 100) / 100
        let masking = Num.clamp(sharpen.masking, 0, 100) / 100
        let halo = Num.clamp(sharpen.haloSuppression, 0, 100) / 100

        // The fine band must sit BELOW the working radius, not at a fixed 1.0.
        // `ManualSharpen.radius` defaults to 1.0, so a fixed 1.0 made these two the
        // same filter on the same input: `fine` and `usm` came out bit-identical and
        // `mix(usm, fineEV, detail)` was constant in `detail`. Measured against the
        // reference, the Detail slider moved a frame by exactly 0.000000 EV across its
        // entire range at the default radius — the failure this rewrite existed to
        // remove, reintroduced one line lower.
        let fineSigma = radius * 0.4
        guard let lum = Self.logLuminance(image),
              let blurred = Self.gaussianBlur(lum, sigma: radius),
              let finestBlur = Self.gaussianBlur(lum, sigma: fineSigma),
              let fine = Self.subtract(lum, finestBlur),
              let structure = Self.localStructure(
                lum, radius: Self.structureRadius(longEdge: longEdge)),
              let delta = KernelLibrary.apply(
                KernelLibrary.sharpenDelta, extent: image.extent,
                [lum, blurred, fine, structure.magnitude, Float(amount), Float(detail),
                 Float(masking), Float(halo), Float(LumenLog.range)]),
              let out = KernelLibrary.apply(KernelLibrary.lumaRatio,
                                            extent: image.extent,
                                            [image, delta, Float(2.0)])
        else {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(sharpen.unsharpRadius)
            filter.intensity = Float(Num.clamp(sharpen.amount / 100.0, 0, 1.5))
            return filter.outputImage?.cropped(to: image.extent) ?? image
        }
        return out
    }

    /// Gaussian blur that keeps the extent it was given.
    ///
    /// `CIGaussianBlur.radius` is a SUPPORT radius, not a standard deviation — the
    /// halation stage in this same file says exactly that and multiplies by three. This
    /// passed sigma straight through, so every blur here was about a third of the width
    /// it was asked for, and across the sharpen radius range (0.5…3.0) that put the
    /// support at 0.17…1.0 px, at or below where the filter stops doing anything. The
    /// stage rendered no change, and the `guard let … else { unsharp mask }` fallback
    /// could not catch it because every kernel compiled fine.
    static func gaussianBlur(_ image: CIImage, sigma: Double) -> CIImage? {
        guard sigma > 0 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(Swift.max(sigma * 3, 0.5))
        return filter.outputImage?.cropped(to: image.extent)
    }

    /// a − b, signed. Not `CISubtractBlendMode`: the blend modes are defined over
    /// display-referred colour and clamp at zero, and a detail band is signed by nature
    /// — half of it is the dark side of every edge.
    static func subtract(_ a: CIImage, _ b: CIImage) -> CIImage? {
        KernelLibrary.apply(KernelLibrary.subtract, extent: a.extent, [a, b])
    }

    /// Local structure of a log-luminance plane: gradient strength along the dominant
    /// direction, and how directed that neighbourhood is. The GPU counterpart of
    /// `DetailEngine.structureTensor`, and the same two outputs off one smoothed tensor
    /// because that is what they cost — sharpening's edge mask and negative Texture's
    /// skin gate are two reads of one quantity, not two filters.
    ///
    /// `magnitude` is √λ₁ in EV per pixel, so a threshold on it is a statement about
    /// contrast rather than about exposure. `coherence` is (λ₁−λ₂)/(λ₁+λ₂) gated by
    /// strength: 1 on a directed, high-contrast edge and 0 on isotropic texture.
    ///
    /// The smoothing radius is the reference's, `workingRadius / 4`, floored at 2
    /// rather than at 1 because `CIBoxBlur` returns its input unchanged at radius 1 —
    /// an unsmoothed tensor is rank-1, which collapses coherence to a constant 1 and
    /// the magnitude to a bare per-pixel gradient. That floor is the one deliberate
    /// departure: on a frame small enough for `workingRadius / 4` to reach 1 the GPU
    /// averages a 5x5 window where the reference averages 3x3.
    static func localStructure(_ plane: CIImage, radius: Int)
        -> (magnitude: CIImage, coherence: CIImage)? {
        let horizontal = CIFilter.convolution3X3()
        horizontal.inputImage = plane.clampedToExtent()
        horizontal.weights = CIVector(values: [-1, 0, 1, -2, 0, 2, -1, 0, 1], count: 9)
        horizontal.bias = 0
        let vertical = CIFilter.convolution3X3()
        vertical.inputImage = plane.clampedToExtent()
        vertical.weights = CIVector(values: [-1, -2, -1, 0, 0, 0, 1, 2, 1], count: 9)
        vertical.bias = 0
        guard let gx = horizontal.outputImage?.cropped(to: plane.extent),
              let gy = vertical.outputImage?.cropped(to: plane.extent),
              let tensor = KernelLibrary.apply(
                KernelLibrary.structureTensor, extent: plane.extent,
                [gx, gy, Float(LumenLog.range)]),
              let smoothed = Self.boxBlur(tensor, radius: Swift.max(radius, 2)),
              let magnitude = KernelLibrary.apply(KernelLibrary.tensorMagnitude,
                                                  extent: plane.extent, [smoothed]),
              let coherence = KernelLibrary.apply(
                KernelLibrary.coherence, extent: plane.extent,
                [smoothed, Float(Self.coherenceStrengthLow),
                 Float(Self.coherenceStrengthHigh)])
        else { return nil }
        return (magnitude, coherence)
    }

    /// The neighbourhood the structure tensor is averaged over, from the same working
    /// radius the reference derives it from: `max(longEdge * 0.02, 3) / 4`.
    ///
    /// It has to scale with the frame or the two halves of the app disagree with each
    /// other. A per-pixel gradient measured on a 1600 px fit preview is four times the
    /// same edge measured on a 6000 px export, so a fixed threshold against it means
    /// something different in the loupe than in the file that comes out.
    static func structureRadius(longEdge: Int) -> Int {
        let working = Swift.max(Int((Double(longEdge) * 0.02).rounded()), 3)
        return Swift.max(working / 4, 2)
    }

    /// Contrast, in EV per pixel, below which a direction is not evidence of an edge.
    /// `DetailEngine.structureTensor`'s numbers.
    static let coherenceStrengthLow: Double = 0.05
    static let coherenceStrengthHigh: Double = 0.35

    // MARK: - S13 vignette and halation

    /// `crop` is the recipe's crop, so the burn is centred on the rectangle the user
    /// will actually see.
    ///
    /// This stage runs on the full decoded frame and `applyGeometry` crops afterwards,
    /// so computing the ellipse from `image.extent` centred it on the SENSOR. On a
    /// cropped photo the burn was off-centre with the wrong radius, and on an
    /// off-centre crop it could sit almost entirely outside the visible frame — while
    /// the panel note asserts the vignette "is masked to the crop rectangle, so it
    /// stays post-crop by construction".
    ///
    /// Straighten is not accounted for: the crop rectangle is expressed on the
    /// straightened frame while this stage still sees the source orientation, and the
    /// two coincide only at angle 0. A rotated frame therefore still places the ellipse
    /// slightly off. That is a much smaller error than the one being fixed, and it is
    /// listed in BUILDING.md rather than approximated with maths I cannot check here.
    func applyVignette(_ image: CIImage, ev: Double, crop: Crop) -> CIImage {
        let full = image.extent
        guard full.width > 0, full.height > 0 else { return image }

        var e = full
        if crop.x != 0 || crop.y != 0 || crop.w != 1 || crop.h != 1,
           crop.w > 0, crop.h > 0 {
            // Recipe crop is top-left-origin; Core Image extents are bottom-up.
            e = CGRect(x: full.minX + CGFloat(crop.x) * full.width,
                       y: full.minY + CGFloat(1 - crop.y - crop.h) * full.height,
                       width: CGFloat(crop.w) * full.width,
                       height: CGFloat(crop.h) * full.height)
        }
        guard e.width > 0, e.height > 0 else { return image }
        let centre = CIVector(x: e.midX, y: e.midY)
        // PER AXIS, then scaled so the corner lands at r = 1 — the ellipse inscribed in
        // the crop rectangle, which is what docs/06's Roundness 0 means and what
        // `DetailEngine.vignette` draws.
        //
        // Normalizing both axes by the half-DIAGONAL, as this did, draws a CIRCLE. On a
        // 3:2 frame that put the long-edge midpoint at r = 0.832 where the reference
        // has 0.707, and the short-edge midpoint at 0.555 — a visibly different
        // vignette from the same slider, and a 24% gain difference at the edge.
        let norm = 1.0 / (2.0 as CGFloat).squareRoot()
        let inv = CIVector(x: norm / (e.width / 2), y: norm / (e.height / 2))
        // The kernel's `feather` is `1 − inner`, so it starts where the reference does.
        let feather = 1 - DetailEngine.vignetteInnerRadius
        // Rendered over the FULL extent — the crop only defines the ellipse. Cropping
        // the output here would throw away the pixels applyGeometry is about to select.
        // Highlight protection, at the same disclosure default the reference uses.
        // Default scene white is mid-grey plus five stops; the taper starts at half of
        // it, which is what keeps a burn off a bright sky while it still shapes the
        // corners. The constants live on `DetailEngine` so the two paths cannot pick
        // different numbers.
        let weights = RGBColorSpace.rec2020.luminanceWeights
        let threshold = 0.18 * pow(2.0, 5.0) / 2.0
        return KernelLibrary.apply(KernelLibrary.vignette, extent: full,
                                   [image, centre, inv, Float(ev), Float(feather),
                                    CIVector(x: weights.r, y: weights.g, z: weights.b),
                                    Float(threshold),
                                    Float(DetailEngine.vignetteHighlightProtection)])
            ?? image
    }

    func applyHalation(_ image: CIImage, film: FilmChain, longEdge: Int) -> CIImage {
        let profile = film.halation(longEdgePixels: longEdge)
        guard profile.strengths.maxComponent > 0 else { return image }
        guard let energy = KernelLibrary.apply(
            KernelLibrary.highlightEnergy, extent: image.extent,
            [image, Float(profile.threshold), Float(profile.boost)])
        else { return image }

        // Three bounces at geometrically spaced radii, decaying by half each time —
        // the film base is not a single-scale scatterer.
        var glow: CIImage?
        var weight = 1.0
        for sigma in profile.sigmasInPixels {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = energy.clampedToExtent()
            // The profile carries standard deviations; CIGaussianBlur wants a support
            // radius. Three sigmas covers ~99.7% of the kernel.
            blur.radius = Float(Swift.max(sigma * 3, 0.5))
            guard let blurred = blur.outputImage?.cropped(to: image.extent) else { continue }
            let scaled = Self.applyMatrix(blurred, Mat3.diagonal(RGB(gray: weight)))
            if let existing = glow {
                glow = KernelLibrary.apply(KernelLibrary.addGlow, extent: image.extent,
                                           [existing, scaled, CIVector(x: 1, y: 1, z: 1)])
                    ?? existing
            } else {
                glow = scaled
            }
            weight *= profile.decay
        }
        guard let field = glow else { return image }
        let s = profile.strengths
        return KernelLibrary.apply(KernelLibrary.addGlow, extent: image.extent,
                                   [image, field, CIVector(x: s.r, y: s.g, z: s.b)])
            ?? image
    }

    func applyGrain(_ image: CIImage, plate: CIImage, film: FilmChain) -> CIImage {
        KernelLibrary.apply(KernelLibrary.grain, extent: image.extent,
                            [image, plate, Float(film.grainAmount), Float(film.grainDMax)])
            ?? image
    }

    // MARK: - Shaper helpers

    /// Run a table over the log domain and come back to scene-linear.
    static func throughShaper(_ image: CIImage,
                              _ body: (CIImage) -> CIImage?) -> CIImage? {
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: image.extent, [image]),
              let mapped = body(encoded),
              let decoded = KernelLibrary.apply(KernelLibrary.logDecode,
                                                extent: image.extent, [mapped])
        else { return nil }
        return decoded
    }

    /// Run a table that ENDS in display-linear: encode in, no decode out.
    static func throughShaperToDisplay(_ image: CIImage,
                                       _ body: (CIImage) -> CIImage?) -> CIImage? {
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: image.extent, [image])
        else { return nil }
        return body(encoded)
    }

    // MARK: - Guided filter

    /// Log luminance broadcast to all channels, in the shaper's bounded domain — the
    /// coordinate every edge-aware stage works in.
    static func logLuminance(_ image: CIImage) -> CIImage? {
        let w = RGBColorSpace.rec2020.luminanceWeights
        guard let lum = KernelLibrary.apply(KernelLibrary.luminance, extent: image.extent,
                                            [image, CIVector(x: w.r, y: w.g, z: w.b)])
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.logEncode, extent: image.extent, [lum])
    }

    static func boxBlur(_ image: CIImage, radius: Int) -> CIImage? {
        guard radius > 0 else { return image }
        // CIBoxBlur returns its input unchanged at radius 1, and a guided filter built
        // on an identity blur is itself exactly the identity: mean(I) = I makes the
        // variance zero, the covariance zero, a = 0 and b = I, so a·I + b = I. The
        // caller then gets its own image back with no error and no diagnostic.
        //
        // That is how Texture died. `applyDetailBands` floored its fine radius at 1,
        // which every render below 334 px landed on, so the fine band was identically
        // zero and exp2(k·0) = 1 — Texture moved a 64 px frame by exactly 0.0 while
        // the CPU reference moved it by a measured 5.6e-3 in the encoded plane. The
        // floor lives here as well as at that call site because no caller can ever
        // mean "blur by an amount this primitive ignores".
        let filter = CIFilter.boxBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(Swift.max(radius, 2))
        return filter.outputImage?.cropped(to: image.extent)
    }

    /// He/Sun/Tang guided filter, self-guided: the edge-aware smoother behind the tone
    /// mask, the presence decomposition and mask feathering.
    static func guidedSelfFilter(_ image: CIImage, radius: Int,
                                 epsilon: Double) -> CIImage? {
        guidedFilter(input: image, guide: image, radius: radius, epsilon: epsilon)
    }

    /// The cross-guided filter: `input` and `guide` are different images, so the
    /// numerator is the covariance of the two, not the variance of the guide. Using the
    /// self-guided coefficients here drives `a` toward zero in flat regions and returns
    /// the GUIDE instead of the filtered signal.
    static func crossGuidedFilter(input: CIImage, guide: CIImage, radius: Int,
                                  epsilon: Double) -> CIImage? {
        guard let squared = KernelLibrary.apply(KernelLibrary.square,
                                                extent: guide.extent, [guide]),
              let product = KernelLibrary.apply(KernelLibrary.multiply,
                                                extent: guide.extent, [guide, input]),
              let meanI = boxBlur(guide, radius: radius),
              let meanII = boxBlur(squared, radius: radius),
              let meanP = boxBlur(input, radius: radius),
              let meanIP = boxBlur(product, radius: radius),
              let coefficients = KernelLibrary.apply(
                KernelLibrary.guidedCrossCoefficients, extent: guide.extent,
                [meanI, meanII, meanP, meanIP, Float(epsilon)]),
              let meanCoefficients = boxBlur(coefficients, radius: radius)
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.guidedApply, extent: guide.extent,
                                   [meanCoefficients, guide])
    }

    /// Reduce an image to a small proxy before measuring a global statistic, so the
    /// measurement costs a thumbnail rather than a frame.
    static func scaledToProxy(_ image: CIImage, longEdge: Int = 256) -> CIImage {
        let extent = image.extent
        let current = Swift.max(extent.width, extent.height)
        guard current > CGFloat(longEdge), current > 0 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(CGFloat(longEdge) / current)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    /// What picture formation degrades to when the table stage cannot run: the
    /// transform's own scalar curve, applied per channel through a small cube on the
    /// log axis. Less accurate than the real stage, still a picture.
    static func applyFallbackTone(_ image: CIImage, plan: RenderPlan) -> CIImage? {
        let transform = plan.displayTransform
        let scale = Swift.max(transform.white, 1e-6)
        let cube = LUT3D(size: 17) { encoded in
            RGB(transform.tone(LumenLog.decode(encoded.r)) / scale,
                transform.tone(LumenLog.decode(encoded.g)) / scale,
                transform.tone(LumenLog.decode(encoded.b)) / scale)
        }
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: image.extent, [image]),
              let mapped = ColorCube.filter(cube, image: encoded) else { return nil }
        return applyMatrix(mapped, Mat3.diagonal(RGB(gray: scale)))
    }

    static func guidedFilter(input: CIImage, guide: CIImage, radius: Int,
                             epsilon: Double) -> CIImage? {
        guard let squared = KernelLibrary.apply(KernelLibrary.square,
                                                extent: guide.extent, [guide]),
              let meanI = boxBlur(guide, radius: radius),
              let meanII = boxBlur(squared, radius: radius),
              let coefficients = KernelLibrary.apply(
                KernelLibrary.guidedCoefficients, extent: guide.extent,
                [meanI, meanII, Float(epsilon)]),
              let meanCoefficients = boxBlur(coefficients, radius: radius)
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.guidedApply, extent: input.extent,
                                   [meanCoefficients, input])
    }

    static func channelMinimum(_ image: CIImage) -> CIImage? {
        // The minimum of the three channels, expressed with the tools we have: a
        // matrix cannot do min, so the morphology filter already gave us a per-channel
        // minimum and we take the darkest channel via two blends.
        let filter = CIFilter.minimumComponent()
        filter.inputImage = image
        return filter.outputImage
    }

    static func addConstant(_ image: CIImage, _ value: Double) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.biasVector = CIVector(x: value, y: value, z: value, w: 0)
        return filter.outputImage ?? image
    }

    /// One average colour for the whole frame. Used for statistics that must be
    /// frozen across tiles (docs/14 §6.3's proxy-field rule).
    /// One context for the one-pixel statistics readbacks, not one per call.
    ///
    /// `averageColor` built a fresh `CIContext` every time, and it is called once per
    /// frame from `applyDehaze` — so dragging any slider on a photo with Dehaze set
    /// spun up a new Metal context per frame. Creating a context is expensive by
    /// design; it is the object you are supposed to keep.
    private static let statisticsContext = CIContext(options: [.workingColorSpace: NSNull()])

    private static func readOnePixel(_ image: CIImage) -> RGB? {
        var pixel = [Float](repeating: 0, count: 4)
        statisticsContext.render(image, toBitmap: &pixel, rowBytes: 16,
                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: nil)
        return RGB(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    static func averageColor(_ image: CIImage) -> RGB? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        return readOnePixel(output)
    }

    /// The brightest value in `image`. Used on an already-downsampled proxy, which is
    /// what makes it a robust high percentile rather than a single hot pixel: each
    /// proxy pixel is the mean of a block of the original.
    /// The mean of a masked image's alpha — the fraction of pixels the mask kept.
    static func averageAlpha(_ image: CIImage) -> Double? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        let value = Double(pixel[3])
        return value.isFinite ? value : nil
    }

    static func maximumColor(_ image: CIImage) -> RGB? {
        let filter = CIFilter.areaMaximum()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        return readOnePixel(output)
    }
}

// MARK: - Local adjustment table

/// A mask's per-pixel colour work, baked the same way the global path is.
struct LocalPlan {
    let lut: LUT3D
    let isIdentity: Bool

    init(adjust: LocalAdjust, scale: Double, whiteAnchorEV: Double, blackAnchorEV: Double) {
        // `pointColors` belongs in this list. Leaving it out meant a mask whose ONLY
        // edit was a sampled swatch declared itself identity, got a 2-point identity
        // table, and returned its input — the Point Colour control did nothing at all
        // inside a mask on the GPU path, which is every preview and every export.
        let identity = adjust.contrast == 0 && adjust.highlights == 0
            && adjust.shadows == 0 && adjust.whites == 0 && adjust.blacks == 0
            && adjust.temp == 0 && adjust.tint == 0 && adjust.hue == 0
            && adjust.sat == 0 && adjust.vibrance == 0 && adjust.colorTint == nil
            && adjust.pointColors.isEmpty
            // `wheels` belongs here for the same reason `pointColors` does: a mask
            // whose only edit is a grade would otherwise declare itself identity and
            // return its input.
            && (adjust.wheels?.isNeutral ?? true)
        self.isIdentity = identity
        guard !identity else {
            self.lut = LUT3D.identity(size: 2)
            return
        }

        let tone = ToneEngine(tone: Tone(contrast: adjust.contrast * scale,
                                         highlights: adjust.highlights * scale,
                                         shadows: adjust.shadows * scale,
                                         whites: adjust.whites * scale,
                                         blacks: adjust.blacks * scale))
        let color = ColorAdjust(vibrance: adjust.vibrance * scale,
                                saturation: adjust.sat * scale)
        let colorEngine = ColorEngine(
            mixer: Mixer(),
            pointColors: adjust.pointColors.map { $0.scalingShift(by: scale) },
            color: color, primaries: Primaries(), bw: nil)
        let hueShift = adjust.hue * scale
        let tintColor = adjust.colorTint
        let tintStrength = Num.clamp(adjust.colorTintStrength, 0, 100) / 100 * scale
        // Temp and Tint were in the identity test above and then never applied, so a
        // local white-balance nudge marked the stage live, rebuilt the table, and
        // produced the same picture.
        let balance = ReferenceRenderer.LocalWhiteBalance(temp: adjust.temp * scale,
                                                          tint: adjust.tint * scale,
                                                          space: .rec2020)
        // Local grading wheels (D29). The panel has offered four draggable wheels
        // since it was written and no stage read them, so a masked grade moved
        // nothing. The anchors this needs were already parameters of this initializer
        // and were the only two it never used — they were plumbed here for exactly
        // this and left unconnected.
        //
        // Same engine as the global grade, never a parallel implementation: the zone
        // windows, the constant-luminance ab translation and the monotonicity solve
        // are the parts that make a grade look like a grade rather than a tint.
        let localGrade = (adjust.wheels?.isNeutral ?? true)
            ? nil
            : GradeEngine(wheels: adjust.wheels!.scalingShift(by: scale),
                          printerLights: PrinterLights(),
                          whiteAnchorEV: whiteAnchorEV, blackAnchorEV: blackAnchorEV)

        self.lut = LUT3D(size: LUT3D.interactiveSize) { encoded in
            var c = LumenLog.decode(encoded)
            let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
            c = balance.apply(c)
            c = colorEngine.apply(c)
            if hueShift != 0 {
                var lch = OKLabTransform.working.toLCh(c)
                lch.h = Num.wrapHue(lch.h + hueShift)
                c = OKLabTransform.working.toRGB(lch)
            }
            // One implementation, shared with the reference renderer — this used to be
            // a second copy here and nothing at all there.
            c = ReferenceRenderer.applyColorTint(c, tint: tintColor,
                                                 strength: tintStrength)
            // After the colour stage and the tint, matching where the global grade
            // sits relative to colour in the main plan (S9/S10).
            if let localGrade { c = localGrade.apply(c) }
            return LumenLog.encode(c)
        }
    }
}

#endif
