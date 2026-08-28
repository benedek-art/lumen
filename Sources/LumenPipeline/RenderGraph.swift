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
        /// This render IS the image a mask samples: skip S3 denoise and S8 presence,
        /// because a luma or colour band is denominated in the corrected scene's
        /// levels and neither stage moves those meaningfully at raster resolution —
        /// and the raster caller pays for this render on top of every frame.
        ///
        /// This used to be `draft`, which ALSO gated S11 local, S12 sharpening,
        /// halation, S15b local curves and grain out of every interactive frame — so
        /// the picture during a drag omitted seven stages and every mask, and jumped
        /// on release. That was the owner's first complaint in both Mac sessions
        /// (docs/19, DETAIL-20). A draft now runs the whole graph at draft RESOLUTION;
        /// the only render that skips stages is the mask source, under its real name.
        public var maskSource: Bool
        /// Table size — interactive during a drag, export size when it settles.
        public var lutSize: Int
        /// `(rendered long edge ÷ the file's own long edge)²` — the factor by which the
        /// decode's own downsampling has already reduced the noise VARIANCE, and
        /// therefore the factor the noise profile must be scaled by for the denoise
        /// stage to remove the noise that is actually there. 1 for an export.
        ///
        /// Without it a 2560 px preview of an 8000 px frame would be denoised as though
        /// it still carried the sensor's full noise — a heavily smoothed preview and a
        /// much lighter export of the same photograph.
        public var noiseScale: Double

        public init(longEdge: Int, maskSource: Bool = false,
                    lutSize: Int = LUT3D.interactiveSize,
                    noiseScale: Double = 1) {
            self.longEdge = longEdge
            self.maskSource = maskSource
            self.lutSize = lutSize
            self.noiseScale = noiseScale
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
    /// handles EV-denominated and stable (docs/08 §8.2).
    ///
    /// The CPU reference does NOT pass precisely this — this comment used to claim it
    /// did, and the audit measured the gap. `ReferenceRenderer.applyMasks` rasterizes
    /// from an image that has been through S3 (applied upstream of its render) and S8
    /// (`DetailEngine.apply` runs before the masks), while this path skips both under
    /// `options.maskSource`. For local contrast the difference is placement-invisible
    /// by design, but Dehaze moves LEVELS, so on a hazy frame a band sits at
    /// different values on the two paths and a golden comparing masked renders
    /// measures that gap. The eyedropper tap (`sampleMaskStageInput`) sides with this
    /// GPU convention. Reconciling the reference is queued in docs/23; until then the
    /// divergence is stated rather than papered over.
    public func localStageInput(_ input: CIImage, plan: RenderPlan,
                                options: Options) -> CIImage {
        var image = colorStageInput(input, plan: plan, options: options)

        // S9 + S10 — colour and grade, as one table on the log axis.
        if !plan.colorGradeIsIdentity {
            image = Self.throughShaper(image) { encoded in
                ColorCube.filter(plan.colorGradeLUT, image: encoded)
            } ?? image
        }
        return image
    }

    /// S3 through S8 — the image the COLOUR stage receives, which is therefore the
    /// value `ColorEngine.apply` compares a global Point Colour swatch against.
    /// Factored out of `localStageInput` (never copied from it) so the Point Colour
    /// eyedropper's tap and the render cannot drift: the eyedropper used to store the
    /// post-S6 value while the engine compared here, so a swatch picked with any tone
    /// move on the photograph selected the wrong colour, and the failure grew with
    /// the edit (docs/23 dossier queue item 5).
    public func colorStageInput(_ input: CIImage, plan: RenderPlan,
                                options: Options) -> CIImage {
        var image = input

        // S3 — profiled classical noise reduction, upstream of everything, because a
        // noise model is a statement about the sensor's own linear signal and stops
        // being true the moment a curve or a matrix has touched it.
        //
        // The mask source skips it: at a 1024 px proxy the noise it would remove is
        // already averaged away by the downsample, and a band's placement does not
        // move with it. Interactive drafts run it — at draft resolution, where
        // `noiseScale` has already shrunk the work to match.
        if !options.maskSource {
            image = applyDenoise(image, plan: plan, options: options)
        }

        // S6 — one fused matrix: white balance, exposure, printer lights.
        image = Self.applyMatrix(image, plan.linear.matrix)

        // S7 — tone, driven by the edge-aware guided mask.
        if !plan.toneIsIdentity {
            image = applyTone(image, plan: plan, options: options)
        }

        // S8 — presence, off one base–detail decomposition. The mask source skips it
        // for the same reason as S3: local contrast does not move a band's levels.
        if !options.maskSource {
            image = applyPresence(image, plan: plan, options: options)
        }
        return image
    }

    public func build(_ input: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        var image = localStageInput(input, plan: plan, options: options)

        // S11 — local adjustments, blended through each mask's alpha.
        if !plan.masks.isEmpty {
            image = applyLocal(image, plan: plan, options: options)
        }

        // S12 — creative sharpening, after local so masked clarity is not
        // double-sharpened.
        if plan.detail.sharpen.amount > 0 {
            image = Self.applySharpen(image, plan.detail.sharpen, longEdge: options.longEdge)
        }

        // S13 — vignette, then halation: the lens vignettes the light before it
        // strikes the film, and the film base reflects what arrives.
        if plan.vignetteEV != 0 {
            image = applyVignette(image, ev: plan.vignetteEV,
                                  crop: plan.recipe.develop.geometry.crop)
        }
        if let film = plan.filmChain, film.halationAmount > 0 {
            image = applyHalation(image, film: film, longEdge: options.longEdge)
        }

        // S14 + S15 — picture formation and the curve, as one table. The table is
        // normalized, so display white comes back through a matrix; that keeps an HDR
        // rendition's highlights out of the cube's unit domain entirely.
        //
        // First, the same input through the finish table WITHOUT the soft proof, kept
        // only when a gamut flag has to be drawn. Core Image is lazy and this branches
        // off the same upstream node, so it costs one extra table fetch per pixel and no
        // second evaluation of anything above it.
        var beforeProof: CIImage?
        if let proofTable = plan.finishLUTBeforeProof {
            beforeProof = Self.throughShaperToDisplay(image, { encoded in
                ColorCube.filter(proofTable, image: encoded)
            })
        }

        if let formed = Self.throughShaperToDisplay(image, { encoded in
            ColorCube.filter(plan.finishLUT, image: encoded)
        }) {
            image = Self.applyMatrix(formed, Mat3.diagonal(RGB(gray: plan.finishScale)))
        } else {
            // Picture formation failing is not a stage to skip: handing back
            // scene-referred data as if it were a picture is worse than any fallback.
            // Apply the transform's own curve through a 1-D cube instead.
            image = Self.applyFallbackTone(image, plan: plan) ?? image
            beforeProof = nil
        }

        // S15b — the local point curve, the second tap (docs/08 §8.4, docs/14). The
        // rest of a mask's sub-recipe is a scene-referred delta at S11; a curve is a
        // picture-domain instinct and has to see the formed picture, so it composites
        // here, through the same alpha S11 used.
        if !plan.masks.isEmpty {
            image = applyLocalCurves(image, plan: plan, options: options)
        }

        // Grain lives inside picture formation, in the density domain.
        if let film = plan.filmChain, film.grainAmount > 0, let plate = grainPlate {
            image = applyGrain(image, plate: plate, film: film)
        }

        // The gamut flag, last, so nothing paints over it — a warning that grain or a
        // later stage could modulate would read as a colour rather than as a flag.
        if let proof = plan.softProof, proof.settings.showGamutWarning,
           let beforeProof {
            image = Self.applyGamutWarning(image, beforeProof: beforeProof, proof: proof,
                                           finishScale: plan.finishScale)
        }

        return image
    }

    // MARK: - Soft proof's gamut flag

    /// Paint `SoftProof.warningColor` over every pixel the destination cannot hold.
    ///
    /// The proof's PICTURE half rides in the finish table, where it costs nothing and
    /// measures as accurate. The flag cannot: it is a step function, and a trilinear
    /// table turns a step into a ramp — measured, a baked flag's edge sat a mean of
    /// 0.017 OKLCh chroma off the true boundary and mislabelled 6% of a realistic sweep.
    /// So it is computed here, per pixel, from the value before the proof clipped it.
    ///
    /// No new kernel: the whole test is `Σ max(v−1, 0) + max(−v, 0)` in the destination's
    /// primaries, which is two `highlightEnergy` clamps, an `addGlow` sum, a `luminance`
    /// with unit weights, and a scale that saturates `blendMask`'s own clamp into a step.
    /// Branchless, like every kernel here, because there are no branches available.
    static func applyGamutWarning(_ image: CIImage, beforeProof: CIImage,
                                  proof: SoftProofTransform,
                                  finishScale: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // Into the destination's primaries. `beforeProof` is the NORMALIZED display
        // value — the table's own output, before `finishScale` — which is the domain the
        // gamut test is defined in.
        let inProof = Self.applyMatrix(beforeProof, proof.workingToProof)
        let negated = Self.applyMatrix(inProof, Mat3.diagonal(RGB(gray: -1)))

        guard let over = KernelLibrary.apply(KernelLibrary.highlightEnergy,
                                             extent: extent, [inProof, Float(1.0), Float(1.0)]),
              let under = KernelLibrary.apply(KernelLibrary.highlightEnergy,
                                              extent: extent, [negated, Float(0.0), Float(1.0)]),
              let excess = KernelLibrary.apply(KernelLibrary.addGlow, extent: extent,
                                               [over, under, CIVector(x: 1, y: 1, z: 1)]),
              let summed = KernelLibrary.apply(KernelLibrary.luminance, extent: extent,
                                               [excess, CIVector(x: 1, y: 1, z: 1)])
        else { return image }

        // `blendMask` clamps its mask to [0,1], so scaling the excess by 1/epsilon turns
        // that clamp into the step: anything past a quarter of a 12-bit code is fully
        // flagged, anything under it is invisible.
        let gate = Self.applyMatrix(
            summed, Mat3.diagonal(RGB(gray: 1 / SoftProof.gamutEpsilon)))
        let flag = SoftProof.warningColor * finishScale
        guard let warning = Self.constant(flag, extent: extent) else { return image }
        return KernelLibrary.apply(KernelLibrary.blendMask, extent: extent,
                                   [image, warning, gate]) ?? image
    }

    /// A flat colour over `extent`, in the working space, with no colour management in
    /// the way. A 1×1 float bitmap tagged with no colour space says exactly these
    /// numbers; `CIConstantColorGenerator` would take a `CIColor` and match it into the
    /// working space, which is a conversion nobody asked for on a value that is already
    /// expressed there.
    static func constant(_ color: RGB, extent: CGRect) -> CIImage? {
        let pixel: [Float] = [Float(color.r), Float(color.g), Float(color.b), 1]
        let data = pixel.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 16,
                            size: CGSize(width: 1, height: 1),
                            format: .RGBAf, colorSpace: nil)
        return image.clampedToExtent().cropped(to: extent)
    }
    // MARK: - S3 profiled classical noise reduction

    /// Tier 1 (docs/07 §2), in the graph: hot pixels, then a variance-stabilizing
    /// transform, an à-trous decomposition in a decorrelating luma/chroma basis,
    /// per-scale edge-aware soft shrinkage, and the inverse transform.
    ///
    /// The reference is `ClassicalDenoise.apply`, and every number this stage uses comes
    /// from `ClassicalDenoise.gpuPlan` rather than being re-derived here — the two paths
    /// read one definition of what each slider means. `KernelGoldenTests` renders this
    /// against that reference on real frames.
    ///
    /// **Radii here do not scale with resolution, deliberately.** Every other spatial
    /// stage in this file sizes itself off `longEdge`, because clarity and sharpening
    /// are statements about the picture. Noise is a statement about the sensor: it lives
    /// at the pixel, so the à-trous levels and the blotch radius are fixed pixel counts,
    /// and it is the noise PROFILE that follows the render scale, through
    /// `options.noiseScale`.
    func applyDenoise(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        guard !plan.denoiseIsIdentity, KernelLibrary.denoiseAvailable else { return image }
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2 else { return image }

        let gpu = plan.classicalDenoise.gpuPlan(width: Int(extent.width),
                                                height: Int(extent.height),
                                                noiseScale: options.noiseScale)
        var work = image
        if gpu.hotPixelK.isFinite, KernelLibrary.hotPixel != nil {
            work = Self.applyHotPixels(work, gpu: gpu) ?? work
        }

        let bands = Swift.min(gpu.lumaThresholds.count, gpu.chromaThresholds.count)
        let shrinks = gpu.lumaThresholds.contains { $0 > 0 }
            || gpu.chromaThresholds.contains { $0 > 0 }
        guard bands > 0, shrinks else { return work }

        let shot = gpu.profile.a
        // `0.375·a² + b` is the transform's own offset term, formed once here rather
        // than in the shader so the kernel takes one uniform instead of squaring a
        // number that spans seven decades.
        let offset = 0.375 * shot * shot + gpu.profile.b
        guard let forward = KernelLibrary.apply(
            KernelLibrary.denoiseForward, extent: extent,
            [work, Float(shot), Float(offset), Float(gpu.pedestalSignal),
             Float(gpu.sqrtPedestal), Float(Swift.max(gpu.signalFloor, -1e30)),
             Float(gpu.encodedScale)])
        else { return work }
        let rotated = Self.applyMatrix(forward, ClassicalDenoise.toY0U0V0)

        // Edge maps, each built only if the slider that reads it is live. Luma edges
        // come off the luma plane; chroma edges off the chroma magnitude, so a
        // saturated edge on flat luminance still protects itself.
        let flat = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: extent)
        var lumaEdge = flat
        if gpu.lumaProtection > 0 {
            let plane = Self.applyMatrix(rotated, Self.broadcastRed)
            lumaEdge = Self.edgePlane(plane, gpu: gpu) ?? flat
        }
        var chromaEdge = flat
        if gpu.chromaProtection > 0,
           let magnitude = KernelLibrary.apply(KernelLibrary.chromaMagnitude,
                                               extent: extent, [rotated]) {
            chromaEdge = Self.edgePlane(magnitude, gpu: gpu) ?? flat
        }

        let protection = CIVector(x: CGFloat(gpu.lumaProtection),
                                  y: CGFloat(gpu.chromaProtection),
                                  z: CGFloat(gpu.chromaProtection))

        // The à-trous stack. `current` walks down the smoothing chain and `out` carries
        // the running result: each band's REMOVED part is subtracted from it, which is
        // the same reconstruction as summing the shrunk bands and the residual without
        // ever adding five full-range planes back together.
        var current = rotated
        var out = rotated
        for j in 0..<bands {
            guard let smooth = Self.bSplinePass(current, step: 1 << j),
                  let detail = KernelLibrary.apply(KernelLibrary.subtract,
                                                   extent: extent, [current, smooth])
            else { break }
            let threshold = CIVector(x: CGFloat(gpu.lumaThresholds[j]),
                                     y: CGFloat(gpu.chromaThresholds[j]),
                                     z: CGFloat(gpu.chromaThresholds[j]))
            guard let removed = KernelLibrary.apply(
                    KernelLibrary.denoiseRemoved, extent: extent,
                    [detail, lumaEdge, chromaEdge, threshold, protection]),
                  let next = KernelLibrary.apply(KernelLibrary.subtract,
                                                 extent: extent, [out, removed])
            else { break }
            out = next
            current = smooth
        }

        // Large-scale chroma blotches survive band shrinkage because they ARE the coarse
        // band. A luminance-guided edge-preserving smooth is what removes them without
        // bleeding colour across an edge — and the guide is the linear luminance of the
        // stage's own input, so the filter follows the picture rather than the
        // variance-stabilized plane it is filtering.
        if gpu.blotchMix > 0, KernelLibrary.mixChroma != nil {
            let w = RGBColorSpace.rec2020.luminanceWeights
            if let guide = KernelLibrary.apply(KernelLibrary.luminance, extent: extent,
                                               [work, CIVector(x: w.r, y: w.g, z: w.b)]),
               let filteredU = Self.crossGuidedFilter(
                    input: Self.applyMatrix(out, Self.broadcastGreen), guide: guide,
                    radius: ClassicalDenoise.blotchRadius,
                    epsilon: ClassicalDenoise.blotchEpsilon),
               let filteredV = Self.crossGuidedFilter(
                    input: Self.applyMatrix(out, Self.broadcastBlue), guide: guide,
                    radius: ClassicalDenoise.blotchRadius,
                    epsilon: ClassicalDenoise.blotchEpsilon),
               let mixed = KernelLibrary.apply(
                    KernelLibrary.mixChroma, extent: extent,
                    [out, filteredU, filteredV, Float(gpu.blotchMix)]) {
                out = mixed
            }
        }

        let unrotated = Self.applyMatrix(out, ClassicalDenoise.fromY0U0V0)
        guard let restored = KernelLibrary.apply(
            KernelLibrary.denoiseInverse, extent: extent,
            [unrotated, Float(shot), Float(gpu.pedestalSignal), Float(gpu.sqrtPedestal),
             Float(1.0 / gpu.encodedScale),
             Float(Swift.max(gpu.minimumForwardRelative, -1e30)),
             Float(gpu.referenceLevel), Float(gpu.unbiasedGain), Float(gpu.shrinkage)])
        else { return work }
        return restored
    }

    /// Broadcast one channel of a three-plane image to all three, so a single-channel
    /// kernel — the guided filter, the edge map — can read it off `.r`.
    static let broadcastRed = Mat3(1, 0, 0, 1, 0, 0, 1, 0, 0)
    static let broadcastGreen = Mat3(0, 1, 0, 0, 1, 0, 0, 1, 0)
    static let broadcastBlue = Mat3(0, 0, 1, 0, 0, 1, 0, 0, 1)

    /// The hot-pixel pass: one general kernel reading its own 3×3 neighbourhood.
    static func applyHotPixels(_ image: CIImage,
                               gpu: ClassicalDenoise.GPUPlan) -> CIImage? {
        KernelLibrary.applyNeighbourhood(
            KernelLibrary.hotPixel, extent: image.extent, reach: 1,
            [clamped(image), Float(Swift.min(gpu.hotPixelK, 1e30)),
             Float(gpu.profile.a), Float(gpu.profile.b)])
    }

    /// One à-trous smoothing step: the B3-spline row `[1,4,6,4,1]/16` applied
    /// separably with its taps `step` pixels apart — the holes the transform is named
    /// for. Level `j` uses `step = 2^j`, so the support doubles per level while the
    /// resolution never drops, which is what makes the reconstruction an exact sum.
    ///
    /// The deepest level of a five-level stack reaches 32 px, so `reach` is not a
    /// formality: it is what Core Image is told to fetch, and a tile rendered without
    /// it would be built from a frame that stops at the tile edge.
    static func bSplinePass(_ image: CIImage, step: Int) -> CIImage? {
        let extent = image.extent
        let s = CGFloat(Swift.max(step, 1))
        guard let horizontal = KernelLibrary.applyNeighbourhood(
            KernelLibrary.bSpline5, extent: extent, reach: 2 * s,
            [clamped(image), CIVector(x: s, y: 0)])
        else { return nil }
        return KernelLibrary.applyNeighbourhood(
            KernelLibrary.bSpline5, extent: extent, reach: 2 * s,
            [clamped(horizontal), CIVector(x: 0, y: s)])
    }

    /// The blur-stabilized gradient edge map: three radius-1 box passes on each axis —
    /// which is exactly `SpatialOps.gaussianBlur(_:sigma: 1.5)` — then a central
    /// difference through the smoothstep knees the plan carries.
    static func edgePlane(_ plane: CIImage,
                          gpu: ClassicalDenoise.GPUPlan) -> CIImage? {
        let extent = plane.extent
        var blurred = plane
        for _ in 0..<3 {
            guard let horizontal = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [clamped(blurred), CIVector(x: 1, y: 0)]),
                  let vertical = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [clamped(horizontal), CIVector(x: 0, y: 1)])
            else { return nil }
            blurred = vertical
        }
        return KernelLibrary.applyNeighbourhood(
            KernelLibrary.edgeMap, extent: extent, reach: 1,
            [clamped(blurred), Float(gpu.edgeKneeLow), Float(gpu.edgeKneeHigh)])
    }

    /// The image with its border repeated outwards — the edge convention
    /// `Plane.clampedSample` gives the CPU reference, and the reason a five-tap kernel
    /// needs no special case per border.
    ///
    /// The y sign is not a hazard even though Core Image's origin is bottom-left and
    /// the reference's is top-left: every filter built on this — the B3-spline row, the
    /// box blur, the gradient magnitude, the 3×3 neighbourhood — is symmetric under a
    /// y flip.
    static func clamped(_ image: CIImage) -> CIImage { image.clampedToExtent() }

    // MARK: - S6

    static func applyMatrix(_ image: CIImage, _ m: Mat3) -> CIImage {
        if m.maxAbsDifference(.identity) < 1e-12 { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        // `rVector` is the ROW of the matrix that produces the output's red — that is,
        // `out.r = dot(inputColor, rVector)` — not the column that the input's red
        // feeds. The comment here used to assert the opposite, and the code followed
        // it, so `applyMatrix` applied the TRANSPOSE of every matrix handed to it.
        //
        // Measured on the runner rather than argued. A Rec.2020 green at
        // `(0.0646, 0.7053, 0.0542)` through `workingToProof`:
        //
        //   M   . v = (-0.31114404,  0.79053580, -0.01147569)   what the CPU computes
        //   M^T . v = ( 0.01843850,  0.75562130,  0.05004020)   what the GPU produced
        //
        // agreeing with the transpose to eight figures.
        //
        // Nothing caught it because nothing could. `Mat3.diagonal` is its own
        // transpose, so every scale and every `finishScale` was unaffected and any test
        // built on one passes either way. And the denoise stage rotates into Y0U0V0 and
        // back out, where `(M^-1)^T M^T = (M M^-1)^T = I` — a transposed pair round
        // trips perfectly, which is exactly what `testTheVSTAndRotationRoundTrip`
        // measured at 6e-8 while the basis in between was wrong.
        //
        // What it cost: the soft proof's gamut test read a green as in-gamut because
        // the transpose put it back inside the cube, and the denoise stage's luma and
        // chroma planes were not luma and chroma — which is why that golden fails on
        // "luma only" AND "colour only" with every primitive underneath it correct.
        filter.rVector = CIVector(x: m.m[0][0], y: m.m[0][1], z: m.m[0][2], w: 0)
        filter.gVector = CIVector(x: m.m[1][0], y: m.m[1][1], z: m.m[1][2], w: 0)
        filter.bVector = CIVector(x: m.m[2][0], y: m.m[2][1], z: m.m[2][2], w: 0)
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
        // ε from the reference, in lockstep — the fifth units bug lived HERE as a bare
        // 0.004 on the encoded plane (a 1.52 EV threshold; Shadows +100 haloed a 4 EV
        // edge by half a stop). The number and its measurement live on
        // `ReferenceRenderer.toneMaskContrastThresholdEV`.
        let mask = Self.guidedSelfFilter(
            lum, radius: radius,
            epsilon: ReferenceRenderer.toneMaskEpsilon) ?? lum
        // The plan's stored cube, baked once per plan. Calling `toneGainCube()`
        // rebuilt 32 768 samples on every frame of every slider drag.
        let cube = plan.toneGainCubeBaked ?? plan.toneGainCube()
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

    /// Texture and Clarity, each the picture minus its own guided base. Neither
    /// base is built unless its slider is off zero, so this is one guided filter
    /// for a one-slider recipe rather than two for every recipe.
    private static func applyDetailBands(_ image: CIImage, detail d: Detail,
                                         lum: CIImage, longEdge: Int) -> CIImage {
        var out = image

        // Two bands, each the picture minus its own guided base. Rounded, not
        // truncated, and floored at 2 like every other radius in this file.
        // `Int(longEdge * 0.003)` is 0 for any long edge below 334 px — every thumbnail
        // and grid preview in the app — and the old floor of 1 is the radius CIBoxBlur
        // ignores, so Texture was inert across that whole range rather than merely
        // coarse. The tone mask and dehaze already floor at 2 and 3; 1 was the outlier.
        let fine = Swift.max(Int((Double(longEdge) * 0.003).rounded()), 2)
        let mid = Swift.max(Int((Double(longEdge) * 0.02).rounded()), 3)

        // A guided filter's ε is a CONTRAST THRESHOLD SQUARED: `a = var / (var + ε)`, so
        // √ε is the excursion across the window below which the window is treated as one
        // surface. The reference names its own — `baseEpsilon = 0.01`, "√0.01 = 0.1 EV:
        // anything flatter than a tenth of a stop across the window is one surface" —
        // and it applies it to a plane in EV.
        //
        // This plane is `LumenLog`-encoded, where a stop is 1/24 of a unit, so an ε that
        // means 0.1 EV here is smaller by `range²`. The values were 0.0008 and 0.004,
        // which on this plane mean thresholds of 0.68 EV and 1.52 EV. A one-and-a-half
        // stop edge was inside the threshold, so the mid base SMOOTHED ACROSS IT —
        // measured, it preserved 49.4% of a 3 EV step and blurred the other 50.6%. The
        // band then contained the edge, and a gain on the band put a rim either side of
        // it: on a clean 3 EV step, Clarity at +100 left a trench of 0.72 EV on the dark
        // side and 0.70 EV on the bright side, against the reference local Laplacian's
        // 0.066 and 0.050. Eleven times the artefact, for slightly LESS local contrast
        // than the reference produces. That is the crunchy, over-processed look, and the
        // comment above used to say these filters could not halo.
        //
        // With the reference's ε the same step is preserved 99.8%, and the rim falls to
        // 0.108 / 0.092 — within four hundredths of a stop of the local Laplacian —
        // while the texture gain on the flat sides is unchanged at 1.63 against 1.63.
        let epsilon = DetailEngine.baseEpsilon / (LumenLog.range * LumenLog.range)

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

        if d.texture != 0, let baseFine = Self.guidedSelfFilter(lum, radius: fine,
                                                                epsilon: epsilon) {
            let k = d.texture / 100.0 * 0.9 * perStop
            // BOTH signs are gated by local structure, for opposite reasons, and the
            // two gate shapes differ. Negative Texture closes on any structure at all:
            // ungated it attacks an eyelash as readily as a pore, so the face goes waxy
            // while the edges go soft, and docs/06 names the gate as the point of the
            // control. Positive Texture closes only on genuine coherent edges, because
            // the band it gains still contains the edge — ungated here, as this was,
            // it rimmed a clean 3 EV step by 1.39 EV against a 0.30 EV bar. It cannot
            // simply borrow the negative shape: hair and fabric weave measure 0.19
            // coherence against a hard step's 1.00, and they are what the positive
            // control is for.
            //
            // The radius is the reference's `workingRadius / 4`, not `mid`. It was
            // `mid` here — four times too wide — which, together with the two errors in
            // the coherence kernel itself, had the gate closing on the flat skin it is
            // meant to smooth and opening on the edges it is meant to protect.
            let gate = Self.localStructure(
                lum, radius: Self.structureRadius(longEdge: longEdge))?.coherence
            let gained: CIImage?
            if let gate {
                gained = KernelLibrary.apply(
                    KernelLibrary.detailGainGated, extent: out.extent,
                    [lum, baseFine, gate, Float(k),
                     Float(d.texture < 0 ? 1.0 : 0.0),
                     Float(DetailEngine.texturePositiveGateLo),
                     Float(DetailEngine.texturePositiveGateHi)])
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
        if d.clarity != 0, let baseMid = Self.guidedSelfFilter(lum, radius: mid,
                                                               epsilon: epsilon) {
            // The picture minus its MID base, not the fine base minus the mid one.
            //
            // `Decomposition.base` is exactly this — `guidedFilter(logLum, logLum,
            // workingRadius, baseEpsilon)` — and Clarity is what is left over after it.
            // Differencing two bases instead put the band between two radii, which
            // needed the outer one to blur across edges to have any content at all;
            // that is what the oversized ε above was quietly paying for. Measured on
            // the same clean step, this construction gives a texture gain of 1.627
            // against the two-base form's 1.625 — the same strength — with a peak
            // excursion of 0.089 EV against 0.620, because the 0.53 EV difference was
            // all rim.
            //
            // It also costs one guided filter rather than two, and each is now built
            // only if its own slider is off zero, so a Clarity-only recipe no longer
            // runs the fine decomposition it never reads.
            // The reference's own remap, and the reference's own parameterization: the
            // slider sets the remap exponent, not a gain. `detailRemap` carries the
            // midtone Gaussian and the σ cut-off, so Clarity is no longer
            // exposure-invariant — a shadow six stops down used to get exactly the
            // local-contrast boost a face got, which is how the control ends up
            // amplifying shadow noise and fighting the highlight rolloff at once.
            let gain = KernelLibrary.apply(
                KernelLibrary.detailRemap, extent: out.extent,
                [lum, baseMid, Float(d.clarity / 100),
                 Float(DetailEngine.clarityDetailEV), Float(LumenLog.encode(0.18)),
                 Float(LumenLog.range), Float(DetailEngine.clarityMidtoneEV)])
            if let gain,
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
        // The reference sizes the dark-channel window off `min(width, height) / 100`.
        // This used the LONG edge, which on a 3:2 frame is a window half again as wide
        // as the one the transmission is defined against.
        let shortEdge = Swift.min(image.extent.width, image.extent.height)
        let radius = Swift.max(Int(shortEdge / 100), 3)

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
        // t = 1 − ω·darkChannel(I / A), refined. Three things here were not the
        // reference's, and together they were putting scene-linear pixels below zero.
        //
        // 1. The dark channel has to come off the image NORMALISED BY THE AIRLIGHT, per
        //    channel — `Decomposition.transmission()` divides `c` by `a` componentwise
        //    before taking the minimum. This divided by the airlight's scalar MEAN
        //    instead, which is a different number in every channel whenever the veil
        //    has a colour, and a veil that has no colour needs no dehaze worth the name.
        //    Measured on a synthetic scene under a blue-cyan airlight (0.55, 0.68,
        //    0.85), the transmission came out 0.060 too high on average and 0.149 at
        //    worst — and since the recombination divides by it, that pushed 9.2% of
        //    recovered pixels NEGATIVE where the reference produces none at all.
        //    Normalising per channel reproduces the reference exactly: 0.000000 mean
        //    absolute difference across the frame.
        //
        // 2. The dark channel is `saturate`d before use, so `t` cannot leave [0.05, 1].
        //    Without it a negative dark channel — legal, scene-referred data arrives
        //    here after stages that can undershoot — gives t > 1, and `(I − A)/t + A`
        //    with t above one ADDS haze.
        //
        // 3. The refinement guides with log luminance at the reference's radius and ε,
        //    not with the dark channel at a quarter the ε. Guiding by the dark channel
        //    means the transmission inherits the edges of a minimum-filtered plane,
        //    which is exactly the blocky structure the guided filter is there to remove.
        let normalized = Self.applyMatrix(
            image, Mat3.diagonal(RGB(1 / Swift.max(airlight.r, 1e-5),
                                     1 / Swift.max(airlight.g, 1e-5),
                                     1 / Swift.max(airlight.b, 1e-5))))
        let normalMinimum = CIFilter.morphologyRectangleMinimum()
        normalMinimum.inputImage = normalized.clampedToExtent()
        normalMinimum.width = Float(radius * 2 + 1)
        normalMinimum.height = Float(radius * 2 + 1)
        guard let normalDarkRGB = normalMinimum.outputImage?.cropped(to: image.extent),
              let normalDark = Self.channelMinimum(normalDarkRGB),
              let clampedDark = Self.clamped(normalDark, low: 0, high: 1)
        else { return image }

        let scaled = Self.applyMatrix(clampedDark,
                                      Mat3.diagonal(RGB(gray: -DetailEngine.dehazeOmega)))
        let biased = Self.addConstant(scaled, 1.0)

        // The reference guides with `logLuminance`, in EV, and regularises at ε = 0.02.
        // This plane is `LumenLog`-encoded, so its variance is smaller by `range²` and
        // the ε that means the same thing is smaller by the same factor. Written as the
        // division rather than as 3.47e-5, because the number is a consequence.
        let guideRadius = Swift.max(Swift.max(Int(Double(longEdge) * 0.02), 3), 8)
        let refined: CIImage
        if let guide = Self.logLuminance(image),
           let filtered = Self.crossGuidedFilter(
            input: biased, guide: guide, radius: guideRadius,
            epsilon: 0.02 / (LumenLog.range * LumenLog.range)),
           let bounded = Self.clamped(filtered, low: 0.02, high: 1.0) {
            refined = bounded
        } else {
            refined = Self.clamped(biased, low: 0.02, high: 1.0) ?? biased
        }

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
                                                 longEdge: options.longEdge,
                                                 lutSize: options.lutSize)
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
                                 longEdge: Int, lutSize: Int) -> CIImage {
        let scale = Num.clamp(mask.amount, 0, 200) / 100.0
        let a = mask.adjust
        var out = image

        let exposure = a.exposure * scale
        if exposure != 0 {
            out = applyMatrix(out, Mat3.diagonal(RGB(gray: pow(2, exposure))))
        }

        // The rest of the local set is per-pixel colour work, so it bakes into a table
        // exactly like the global path does — AT THE SIZE THIS RENDER ASKED FOR.
        //
        // `LocalPlan` used to hardcode `LUT3D.interactiveSize`, so a delivered file's
        // masked contrast, temp, tint, hue, saturation, vibrance, point colours and
        // grading wheels came out of a 33-cube while everything beside them — the
        // global colour/grade table, the finish table, and the local point curve two
        // stages down, which has taken `options.lutSize` since it was written — came
        // out of a 65. Measured over 30 000 in-gamut colours (docs/18), size 33 has a
        // worst-channel error of 0.197 stops with 10.6% of samples past 0.02 EV
        // against 0.074 and 4.1% at 65, so every masked colour edit in an export
        // carried preview-grade error that the preview it was judged on also carried
        // and the file did not have to.
        let localPlan = LocalPlan(adjust: a, scale: scale,
                                  whiteAnchorEV: plan.tone.whiteAnchorEV,
                                  blackAnchorEV: plan.tone.blackAnchorEV,
                                  size: lutSize,
                                  globalColor: plan.recipe.develop.color,
                                  globalWheels: plan.recipe.look.wheels)
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

    // MARK: - S15b local point curve

    /// Each mask's point curve, composited through that mask's alpha on the formed
    /// picture (docs/08 §8.4).
    ///
    /// Baked as a table over the shaper's axis, exactly like the finish stage above it
    /// — the values arriving here are display-linear with white at `plan.finishScale`,
    /// and `LumenLog` is used as an invertible axis for the cube rather than as a
    /// scene-referred encoding. The table's INPUT is therefore encoded picture, not
    /// encoded scene, which is why this cannot be folded into `plan.finishLUT`: that
    /// one is keyed by the scene value and is shared by every pixel, masked or not.
    func applyLocalCurves(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        var out = image
        for mask in plan.masks {
            // `finishScale`, not `displayWhite`: the white of the PIXELS ARRIVING, which
            // is what the comment above already says and what the two names meant
            // interchangeably until a draft frame could be served a stale finish table
            // (`PlanTableCache.pairedTableAllowingStale`). `displayWhite` is this
            // recipe's white; `finishScale` is the white of the picture in hand. Taking
            // the former here would denominate a local curve in a white the pixels do
            // not have — the same defect that pairing exists to end, one stage over.
            let curve = LocalCurve(curve: mask.adjust.curve, amount: mask.amount,
                                   white: plan.finishScale)
            guard !curve.isIdentity, let alpha = maskImages[mask.id] else { continue }
            let table = LocalCurvePlan(curve: curve, size: options.lutSize).lut
            guard let curved = Self.throughShaper(out, { encoded in
                ColorCube.filter(table, image: encoded)
            }) else { continue }
            guard let blended = KernelLibrary.apply(KernelLibrary.blendMask,
                                                    extent: out.extent,
                                                    [out, curved, alpha])
            else { continue }
            out = blended
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

        // The fine band is the reference's, exactly: the two finest a-trous bands,
        // `details[0] + 0.5 * details[1]`.
        //
        // It used to be `lum - gaussianBlur(lum, sigma: radius * 0.4)`, and that made
        // the Detail slider run BACKWARDS. A narrower blur is closer to the identity, so
        // `lum - G(0.4r)` is smaller in amplitude than `usm = lum - G(r)` at every
        // spatial frequency — which makes `mix(usm, fine, detail)` a monotone
        // ATTENUATOR in `detail`. Measured at Amount 100, gain against the unsharpened
        // frame by period:
        //
        //     period    2px    3     4     6     8    16
        //     Detail 0  1.99  1.89  1.71  1.42  1.27  1.07
        //     Detail 100 1.16  1.12  1.08  1.04  1.02  1.01   <- turning it UP
        //     reference  2.00  1.97  1.88  1.70  1.54  1.20
        //
        // At 100 the control was effectively off. The one golden covering it asserted
        // that Detail 0 and Detail 100 differ by more than 1e-4, which a sign inversion
        // satisfies perfectly.
        //
        // Algebra, with s1 and s2 the a-trous smooths at steps 1 and 2:
        //     d0 = lum - s1,  d1 = s1 - s2
        //     d0 + 0.5*d1 = lum - 0.5*(s1 + s2)
        // `bSplinePass` is the same operator as `SpatialOps.atrousSmooth` — pinned by
        // `testAtrousStepMatchesTheReference` — and `blendMask(a, b, 0.5)` is the mean,
        // so the reference's band is reproducible here without a new kernel.
        guard let lum = Self.logLuminance(image),
              let blurred = Self.gaussianBlur(lum, sigma: radius),
              let smooth1 = Self.bSplinePass(lum, step: 1),
              let smooth2 = Self.bSplinePass(smooth1, step: 2),
              let half = Self.constant(RGB(gray: 0.5), extent: image.extent),
              let meanSmooth = KernelLibrary.apply(KernelLibrary.blendMask,
                                                   extent: image.extent,
                                                   [smooth1, smooth2, half]),
              let fine = Self.subtract(lum, meanSmooth),
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

    /// Gaussian blur that keeps the extent it was given — THE one Gaussian in this
    /// file. Every stage that needs one calls this rather than building its own
    /// `CIFilter`, and that rule is not stylistic: the correction below landed here and
    /// missed `applyHalation`, which had kept a private copy of the filter, so for a
    /// whole round the sharpen stage blurred at sigma and the halation stage at three
    /// times it out of one profile in one file.
    ///
    /// `CIGaussianBlur.radius` was believed to be a SUPPORT radius rather than a
    /// standard deviation — the halation stage in this same file said exactly that and
    /// multiplied by three. Under that belief passing sigma straight through made every
    /// blur here about a third of the width it was asked for, and across the sharpen
    /// radius range (0.5…3.0) that put the support at 0.17…1.0 px, at or below where
    /// the filter stops doing anything. The stage rendered no change, and the
    /// `guard let … else { unsharp mask }` fallback could not catch it because every
    /// kernel compiled fine.
    static func gaussianBlur(_ image: CIImage, sigma: Double) -> CIImage? {
        guard sigma > 0 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        // `CIGaussianBlur.radius` IS the standard deviation. Measured on the runner by
        // blurring an impulse and taking the second moment of the response, which is
        // sigma by definition:
        //
        //     radius passed    2.0   6.0   9.0
        //     measured sigma   2.0   6.01  8.95
        //
        // It was `sigma * 3`, on the stated grounds that the parameter is a support
        // radius. It is not, and that made every Gaussian in the shipping graph three
        // times wider than it asked for — the sharpen stage's unsharp term, mask
        // feather, halation.
        //
        // How it surfaced: the Sharpen Detail slider ran backwards even after its fine
        // band was rebuilt from the reference's a-trous stack. `usm = lum − G(3·sigma)`
        // is a far wider high-pass than a band whose smooths measure sigma 1.0 and 2.0,
        // so mixing toward the finer band could only ever attenuate. The direction
        // assertion in `testDetailSliderMovesThePicture` is what refused to let that
        // pass twice.
        //
        // Same class as `CIBoxBlur.radius` being the window width rather than the
        // half-width, found the same way on the same day. Two Core Image blur
        // parameters, both documented in comments as fact, both wrong, both measurable
        // in one impulse response.
        filter.radius = Float(Swift.max(sigma, 0.5))
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
        for sigma in profile.sigmasInPixels where sigma > 0 {
            // Through the shared helper, which is the whole point of the fix recorded
            // in `gaussianBlur`'s own header: `CIGaussianBlur.radius` IS the standard
            // deviation, measured on the runner. This stage kept its own copy of the
            // filter with the old `sigma * 3` in it, so the correction landed
            // everywhere the helper is called and nowhere here — the glow rendered
            // three times wider than the 65 µm the profile derives, on every preview
            // and every export, while `ReferenceRenderer.applyHalation` rendered it at
            // one. The comment claiming halation had been fixed named this stage.
            //
            // The `where sigma > 0` matches the reference's loop: a profile with a
            // degenerate radius contributes nothing rather than a delta.
            guard let blurred = Self.gaussianBlur(energy, sigma: sigma) else { continue }
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

    /// `CIBoxBlur` with the parameter passed straight through, for the one test whose
    /// job is to measure what that parameter means. Nothing in the render calls this —
    /// the render calls `boxBlur`, which converts. Kept beside it so the two cannot
    /// drift apart while the conversion is being characterised.
    static func boxBlurRaw(_ image: CIImage, radius: Int) -> CIImage? {
        let filter = CIFilter.boxBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        return filter.outputImage?.cropped(to: image.extent)
    }

    static func boxBlur(_ image: CIImage, radius: Int) -> CIImage? {
        guard radius > 0 else { return image }
        // `CIBoxBlur.radius` is the WINDOW WIDTH, not the half-width. Measured on the
        // macOS runner by blurring an impulse and reading the peak, which is 1/(N²) for
        // an N-wide box:
        //
        //   CIBoxBlur(2)->1   (3)->3   (4)->3   (6)->5   (8)->7
        //             (12)->11  (16)->15  (24)->23  (32)->31
        //
        // An even argument gives width−1, an odd one gives width, so passing an odd
        // `2r+1` lands exactly on the reference's `(2r+1)`-wide window.
        //
        // What passing `r` cost: every guided filter in the render — Clarity, Texture,
        // the dehaze transmission, the denoise blotch pass — averaged over less than
        // half the neighbourhood it asked for. `CIBoxBlur(8)` is a 7-wide box where
        // `SpatialOps.boxBlur(radius: 8)` is 17 wide. It is the same class of mistake as
        // `CIGaussianBlur.radius` being a SUPPORT radius rather than sigma, which this
        // file already fixed once by multiplying by three, and it went unseen for the
        // same reason: a blur that is merely too narrow still looks like a blur.
        //
        // The old floor at 2 is gone with it. It existed because `CIBoxBlur(1)` returns
        // its input unchanged and a guided filter on an identity blur IS the identity —
        // which is how Texture died below 334 px. Under this conversion the smallest
        // real radius asks for 3 and gets a genuine 3-wide box, so nothing needs a floor
        // to avoid a primitive's dead zone.
        let filter = CIFilter.boxBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(2 * radius + 1)
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

    /// Component-wise clamp on RGB, with alpha held to its own legal [0, 1].
    /// `CIColorClamp` rather than a kernel: it is one of the few stock filters that
    /// does exactly one thing, and a clamp is not worth a shader.
    static func clamped(_ image: CIImage, low: Double, high: Double) -> CIImage? {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: low, y: low, z: low, w: 0)
        filter.maxComponents = CIVector(x: high, y: high, z: high, w: 1)
        return filter.outputImage?.cropped(to: image.extent)
    }

    static func addConstant(_ image: CIImage, _ value: Double) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.biasVector = CIVector(x: value, y: value, z: value, w: 0)
        return filter.outputImage ?? image
    }

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

    /// One average colour for the whole frame. Used for statistics that must be
    /// frozen across tiles (docs/14 §6.3's proxy-field rule).
    static func averageColor(_ image: CIImage) -> RGB? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        return readOnePixel(output)
    }

    /// The mean of a masked image's alpha — the fraction of pixels the mask kept.
    ///
    /// Its own read rather than `readOnePixel`, which returns an `RGB` and therefore
    /// throws away the only channel this cares about.
    static func averageAlpha(_ image: CIImage) -> Double? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        statisticsContext.render(output, toBitmap: &pixel, rowBytes: 16,
                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: nil)
        let value = Double(pixel[3])
        return value.isFinite ? value : nil
    }

    /// The brightest value in `image`. Used on an already-downsampled proxy, which is
    /// what makes it a robust high percentile rather than a single hot pixel: each
    /// proxy pixel is the mean of a block of the original.
    static func maximumColor(_ image: CIImage) -> RGB? {
        let filter = CIFilter.areaMaximum()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        return readOnePixel(output)
    }
}

// MARK: - Local point curve table

/// A mask's point curve as a cube over the shaper's axis.
///
/// The axis carries DISPLAY-linear values here, not scene-linear ones: this table is
/// applied after picture formation, and `LumenLog` is doing nothing but supplying an
/// invertible, shadow-dense coordinate for the cube — the same job it does for
/// `finishLUT`'s input. `throughShaper` encodes going in and decodes coming out, so
/// the picture leaves in the domain it arrived in.
///
/// One table per curved mask, and only for masks that have a curve: `LocalCurve`
/// reports identity for a mask with none, and `applyLocalCurves` never gets here.
struct LocalCurvePlan {
    let lut: LUT3D

    init(curve: LocalCurve, size: Int = LUT3D.interactiveSize) {
        self.lut = LUT3D(size: size) { encoded in
            LumenLog.encode(curve.apply(LumenLog.decode(encoded)))
        }
    }
}

// MARK: - Local adjustment table

/// A mask's per-pixel colour work, baked the same way the global path is.
struct LocalPlan {
    let lut: LUT3D
    let isIdentity: Bool

    /// `size` is the render's table size, not a default: an export bakes at
    /// `LUT3D.exportSize` and a preview at `LUT3D.interactiveSize`, and there is
    /// deliberately no default value here so that a new call site has to say which
    /// render it is baking for. Nothing caches this table — `PlanTableCache` refuses
    /// anything above the interactive size on purpose — so the size is not part of any
    /// cache key; it is baked once per mask per render, which at export is 274 625
    /// samples per mask instead of 35 937.
    /// `globalColor` and `globalWheels` are the GLOBAL panels' values, and they have
    /// no defaults for the same reason `size` has none: a call site that forgets them
    /// silently reverts COLOR-16/COLOR-27 — the masked grade re-zoned by factory
    /// pivots, the masked Sat re-protected by an invisible 70.
    init(adjust: LocalAdjust, scale: Double, whiteAnchorEV: Double,
         blackAnchorEV: Double, size: Int,
         globalColor: ColorAdjust, globalWheels: GradingWheels) {
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
        // Density and protectSkin inherited from the global colour panel — see
        // `ColorAdjust.local` (COLOR-27). Kept in lockstep with
        // `ReferenceRenderer.applyLocalAdjust`.
        let color = ColorAdjust.local(vibrance: adjust.vibrance * scale,
                                      saturation: adjust.sat * scale,
                                      inheriting: globalColor)
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
            // `adoptingWindows`: the mask's colour moves inside the GLOBAL wheels'
            // tonal windows — the docs/08 §8.4 contract (COLOR-16).
            : GradeEngine(wheels: adjust.wheels!.scalingShift(by: scale)
                              .adoptingWindows(from: globalWheels),
                          printerLights: PrinterLights(),
                          whiteAnchorEV: whiteAnchorEV, blackAnchorEV: blackAnchorEV)

        self.lut = LUT3D(size: size) { encoded in
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
