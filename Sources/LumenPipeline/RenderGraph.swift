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
            image = applyVignette(image, ev: plan.vignetteEV)
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
        guard let normalized = ColorCube.filter(plan.toneGainCube(), image: mask) else {
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

        if d.dehaze != 0 {
            out = Self.applyDehaze(out, amount: d.dehaze, longEdge: longEdge)
        }

        guard d.texture != 0 || d.clarity != 0 else { return out }
        guard let lum = Self.logLuminance(out) else { return out }

        // One decomposition, two bands: texture is the fine scale, clarity the mid
        // scale. Both come off guided filters, so neither can halo.
        let fine = Swift.max(Int(Double(longEdge) * 0.003), 1)
        let mid = Swift.max(Int(Double(longEdge) * 0.02), 3)
        guard let baseFine = Self.guidedSelfFilter(lum, radius: fine, epsilon: 0.0008),
              let baseMid = Self.guidedSelfFilter(lum, radius: mid, epsilon: 0.004)
        else { return out }

        if d.texture != 0 {
            let k = d.texture / 100.0 * 0.9
            if let gain = KernelLibrary.apply(KernelLibrary.detailGain,
                                              extent: out.extent, [lum, baseFine, Float(k)]),
               let combined = KernelLibrary.apply(KernelLibrary.multiply,
                                                  extent: out.extent, [out, gain]) {
                out = combined
            }
        }
        if d.clarity != 0 {
            let k = d.clarity / 100.0 * 1.1
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

        // Airlight: averaged over the DARK CHANNEL, not the image — a frame average is
        // dominated by midtones and lands far below the true airlight, which sends the
        // transmission negative. Measured on a proxy and frozen for the render, which
        // is also what the proxy-field rule requires for tiled export (docs/14 §6.3).
        let proxy = Self.scaledToProxy(dark)
        let airlight = Self.averageColor(proxy) ?? RGB(gray: 0.8)
        let neutral = Swift.max((airlight.r + airlight.g + airlight.b) / 3, 1e-4)

        // t = 1 − w·dark/A, refined.
        let scale = -strength * 0.95 / neutral
        let scaled = Self.applyMatrix(dark, Mat3.diagonal(RGB(gray: scale)))
        let biased = Self.addConstant(scaled, 1.0)
        let refined = Self.crossGuidedFilter(input: biased, guide: dark, radius: radius,
                                             epsilon: 0.0025) ?? biased

        let a = CIVector(x: neutral, y: neutral, z: neutral)
        return KernelLibrary.apply(KernelLibrary.dehaze, extent: image.extent,
                                   [image, refined, a, Float(0.1)]) ?? image
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

    static func applySharpen(_ image: CIImage, _ sharpen: ManualSharpen,
                             longEdge: Int) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image.clampedToExtent()
        // `unsharpRadius`, not `radius`: Detail was read by nothing here while the
        // panel shipped it as a live slider, and a radius is the one thing a stock
        // unsharp mask can honestly carry it in. Masking and halo suppression have no
        // expression in this filter and are still unimplemented on this path — see the
        // note on `ManualSharpen.unsharpRadius`.
        filter.radius = Float(sharpen.unsharpRadius)
        filter.intensity = Float(Num.clamp(sharpen.amount / 100.0, 0, 1.5))
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    // MARK: - S13 vignette and halation

    func applyVignette(_ image: CIImage, ev: Double) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let centre = CIVector(x: e.midX, y: e.midY)
        // Normalize against the half-diagonal so the effect follows the frame's shape.
        let half = (e.width * e.width + e.height * e.height).squareRoot() / 2
        let inv = CIVector(x: 1.0 / half, y: 1.0 / half)
        return KernelLibrary.apply(KernelLibrary.vignette, extent: e,
                                   [image, centre, inv, Float(ev), Float(0.7)]) ?? image
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
        let filter = CIFilter.boxBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
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
    static func averageColor(_ image: CIImage) -> RGB? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return RGB(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
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
        let colorEngine = ColorEngine(mixer: Mixer(), pointColors: adjust.pointColors,
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
            return LumenLog.encode(c)
        }
    }
}

#endif
