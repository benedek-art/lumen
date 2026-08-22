// PipelineRenderer.swift
// One pure render function of (file, recipe, target) → pixels, used by the loupe, the
// grid and the export alike (docs/13 §2). There is no separate preview pipeline to
// drift out of sync with the export path; there is one graph evaluated at different
// resolutions.
//
// The working colour space is extended-range linear Rec.2020, set on the CIContext, so
// every kernel and table in the graph operates on scene-referred linear data and Core
// Image handles the conversion in and out. Encoding happens exactly once, at write.

#if os(macOS)

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

public enum RenderError: Error {
    case decodeFailed
    case renderFailed
    case unsupportedFormat(String)
    case writeFailed(URL)
    /// An export refused because the GPU path cannot form a picture. Carries the names
    /// of the kernels that failed to compile, so the caller can say which.
    case kernelsUnavailable([String])
}

/// What a renderer believes about its kernels.
///
/// A value with a `live` default rather than a direct read of `KernelLibrary` at each
/// call site, and it exists for exactly one reason: `KernelLibrary`'s kernels are
/// `static let`, compiled once at first touch, so on a healthy runner they CANNOT be
/// made to fail — and the export path's behaviour when they do is therefore untestable
/// without a seam. This is the seam, and it is the whole of it. Nothing in the app
/// writes it; the app gets `.live`.
public struct KernelAvailability: Sendable {
    /// The kernels the core colour path cannot run without. False means the graph
    /// cannot form a picture at all.
    public let coreAvailable: Bool
    /// Names of every kernel that failed, core or not — the stages that would silently
    /// no-op through `KernelLibrary.apply(...) ?? image`.
    public let unavailable: [String]

    public init(coreAvailable: Bool, unavailable: [String]) {
        self.coreAvailable = coreAvailable
        self.unavailable = unavailable
    }

    /// What this build actually compiled.
    public static var live: KernelAvailability {
        KernelAvailability(coreAvailable: KernelLibrary.coreAvailable,
                           unavailable: KernelLibrary.unavailableKernels)
    }
}

public final class PipelineRenderer {

    private let context: CIContext

    public init() {
        // Extended-range linear Rec.2020: unbounded, so values above display white and
        // below zero survive the graph (docs/14 §1.1), and wide enough that the HDR
        // path is the same pipeline pointed at a higher peak.
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ]
        if let working {
            options[.workingColorSpace] = working
        }
        self.context = CIContext(options: options)
    }

    /// AI mattes, keyed by file and then by `MaskKind.rawValue` (docs/08 §8.9: the
    /// raster is never the source of truth — it is disposable, and regenerating it
    /// costs a second).
    ///
    /// Held HERE rather than threaded through every render call because the
    /// alternative is a defaulted `aiMattes:` parameter on nine functions across three
    /// targets, and a caller that forgets one gets no error — it gets a mask that
    /// silently selects nothing, which is the exact failure this project has already
    /// shipped twice. The renderer looks the mattes up from the source it was handed.
    ///
    /// Bounded like the source cache, for the same reason: a scroll through a folder
    /// must not pin a hundred mattes in memory.
    private var mattes: [URL: [String: Plane]] = [:]
    private var matteOrder: [URL] = []
    private static let matteCacheLimit = 12

    /// What this renderer believes about its kernels. `.live` in the app; a test can
    /// substitute a degraded build, which is the only way the refusal below can be
    /// exercised on a machine whose kernels all compile.
    public var availability: KernelAvailability = .live

    /// True when the GPU path is intact. False means kernels failed to compile and the
    /// renderer is producing a reduced result the UI must label.
    public var isGPUPathAvailable: Bool { availability.coreAvailable }

    // MARK: - AI mattes

    /// Which kinds this file already has a matte for.
    public func matteKinds(for url: URL) -> Set<String> {
        Set((mattes[url] ?? [:]).keys)
    }

    /// Store what a generation pass produced. An empty result is stored as an empty
    /// dictionary rather than dropped, so "we looked and found nothing" is
    /// distinguishable from "we have not looked yet" and the pass is not repeated on
    /// every edit.
    public func storeMattes(_ produced: [String: Plane], for url: URL) {
        mattes[url, default: [:]].merge(produced) { _, new in new }
        matteOrder.removeAll { $0 == url }
        matteOrder.append(url)
        while matteOrder.count > Self.matteCacheLimit, let oldest = matteOrder.first {
            matteOrder.removeFirst()
            mattes.removeValue(forKey: oldest)
        }
    }

    /// True once a generation pass has run for this file, whatever it found.
    public func hasAttemptedMattes(for url: URL) -> Bool { mattes[url] != nil }

    public func forgetMattes(for url: URL) {
        mattes.removeValue(forKey: url)
        matteOrder.removeAll { $0 == url }
    }

    /// The picture the segmenter sees: a NEUTRAL rendition of the file, at matte
    /// resolution, with no crop and no rotation.
    ///
    /// Neutral because a matte computed from the user's edit would move every time the
    /// exposure did, and every slider drag would invalidate a cache that costs a second
    /// to refill. Uncropped and unrotated because a mask raster is expressed in source
    /// coordinates — that invariant is what lets a crop re-rasterize a mask instead of
    /// orphaning it, and a matte in any other frame would not line up with it.
    public func matteSourceImage(source: any ImageSource,
                                 maxLongEdge: Int = PipelineRenderer.maskRasterLongEdge)
    -> CGImage? {
        try? renderPreview(source: source, recipe: Recipe(),
                           maxLongEdge: maxLongEdge, draft: false)
    }

    public var unavailableKernels: [String] { availability.unavailable }

    // MARK: - Preview

    /// `showingUncropped` is set while the crop tool is open, so the tool draws its
    /// rectangle against the frame that rectangle is expressed in.
    ///
    /// `softProof` is a VIEWING mode, not an edit (docs/11), which is why it arrives
    /// here as an argument rather than through the recipe: two viewers of the same photo
    /// may proof to different destinations, and neither is changing the picture.
    public func renderPreview(source: any ImageSource, recipe: Recipe,
                              maxLongEdge: Int, draft: Bool,
                              showingUncropped: Bool = false,
                              strokeSets: [String: BrushStrokeSet] = [:],
                              softProof: SoftProof? = nil) throws -> CGImage {
        // Decode at the target resolution, not the sensor's: a 2560 px preview of a
        // 7000 px raw decodes roughly seven times less data.
        let native = source.nativeLongEdge
        let scale = native > 0 ? Swift.min(1.0, Double(maxLongEdge) / native) : 1.0
        guard let decoded = source.decode(recipe: recipe, draft: draft,
                                          scaleFactor: scale) else {
            throw RenderError.decodeFailed
        }

        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              // ONE table size for draft and settle.
                              //
                              // The draft used to bake at 17 and the settle at 33, and
                              // that is not a coarser version of the same picture — it
                              // is a different picture. Measured over 30 000 in-gamut
                              // colours across -6…+4 EV, worst-channel display-linear
                              // error: size 17 has a p99 of 0.1465 (37.4 of 255 levels)
                              // against size 33's 0.0767 (19.6). Concentrated in
                              // highlights and saturated tones, which is exactly where
                              // a photographer is looking while they drag.
                              //
                              // The owner's report, unprompted and before anyone showed
                              // him a measurement: "while I'm dragging a different
                              // colour comes up on the screen and then when I let go it
                              // applies something different." That is this line.
                              //
                              // The bake it saved is not the win it looks like either:
                              // `PlanTableCache` already serves the whole tone,
                              // presence, denoise, sharpening, mask and vignette
                              // register from cache during a drag, so for most controls
                              // this costs one bake at the start of a gesture rather
                              // than one per frame.
                              lutSize: LUT3D.interactiveSize,
                              captureISO: source.captureMetadata.iso,
                              softProof: softProof)
        let graph = makeGraph(plan: plan, decoded: decoded, draft: draft,
                              strokeSets: strokeSets,
                              aiMattes: mattes[source.url] ?? [:])
        // Preview decodes are downsampled, and downsampling averages the noise down
        // with them, so the profile the denoise stage works against follows the same
        // factor — squared, because it is a variance.
        var image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: longEdge,
                                                             draft: draft,
                                                             noiseScale: scale * scale))
        image = Self.applyGeometry(image, recipe: recipe, scaleTo: maxLongEdge,
                                   skipCrop: showingUncropped)

        guard let cgImage = context.createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw RenderError.renderFailed
        }
        return cgImage
    }

    // MARK: - Export

    /// Writes the file and returns the names of the kernels that were NOT available,
    /// so the caller can report a reduced delivery instead of counting it as clean.
    ///
    /// Empty means every stage in the graph ran. It is not an error — a missing
    /// non-core kernel leaves a real picture with one stage absent — but it is not a
    /// success either, and the status line said "Exported N files" for both.
    public func export(source: any ImageSource, recipe: Recipe, to destination: URL,
                       using exportRecipe: ExportRecipe,
                       strokeSets: [String: BrushStrokeSet] = [:]) throws -> [String] {
        let image = try exportedImage(source: source, recipe: recipe,
                                      using: exportRecipe, strokeSets: strokeSets)
        try write(image, to: destination, using: exportRecipe)
        return availability.unavailable
    }

    /// The delivered pixels, one step before the encoder.
    ///
    /// Split out from `export` so the file that gets written can be MEASURED without
    /// going through an encoder and back: every claim about what an export contains was
    /// otherwise a claim about a PNG's bytes, decoded through whatever colour space the
    /// reader chose, which is a poor instrument for asking whether a stage ran.
    func exportedImage(source: any ImageSource, recipe: Recipe,
                       using exportRecipe: ExportRecipe,
                       strokeSets: [String: BrushStrokeSet] = [:]) throws -> CIImage {
        // An export is a promise in a way a preview is not, so it refuses rather than
        // delivers.
        //
        // The preview path made this decision twice already: it checks
        // `coreAvailable`, renders through `renderReference` when it is false, and
        // labels a merely-reduced render with the names of whatever else failed
        // (RenderCoordinator.swift:100-125). Export had no equivalent — it built the
        // graph unconditionally, every `KernelLibrary.apply(...) ?? image` no-opped a
        // missing stage into the delivered file, and with the core four missing it
        // wrote the fallback-tone approximation with no error at all. A file on disk
        // outlives the session that noticed the GPU was broken; a frame on screen does
        // not. There is no reference fallback here on purpose: `renderReference` has no
        // geometry stage (GEO-17), so it cannot honour a crop, and delivering an
        // uncropped file would be a different silent wrong answer.
        guard availability.coreAvailable else {
            throw RenderError.kernelsUnavailable(availability.unavailable)
        }
        guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1.0) else {
            throw RenderError.decodeFailed
        }
        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              // Not `hdr?.whiteTargetPercent`: raising the ceiling to
                              // 400% and then encoding 8 bits clipped everything above
                              // diffuse white. See `ExportRecipe.hdrIsWritable`.
                              displayWhiteTarget: exportRecipe.renderWhiteTargetPercent,
                              lutSize: LUT3D.exportSize,
                              captureISO: source.captureMetadata.iso)

        let graph = makeGraph(plan: plan, decoded: decoded, draft: false,
                              strokeSets: strokeSets,
                              aiMattes: mattes[source.url] ?? [:],
                              deferGrain: true)
        var image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: longEdge,
                                                             draft: false,
                                                             lutSize: LUT3D.exportSize))
        // The render forks at the resize node: everything above is shared across every
        // checked recipe, which is why three recipes cost far less than three exports.
        let cropped = Self.applyGeometry(image, recipe: recipe)
        let extent = cropped.extent
        let target = exportRecipe.targetSize(sourceWidth: Int(extent.width),
                                             sourceHeight: Int(extent.height))
        image = Self.applyGeometry(image, recipe: recipe,
                                   scaleTo: Swift.max(target.width, target.height),
                                   allowUpscale: exportRecipe.allowUpscale)
        // Grain, on the grid that is DELIVERED — which is why `makeGraph` was asked to
        // withhold the plate above.
        //
        // The preview decodes at roughly its own display size, so it grains at the size
        // it shows. This grained at the DECODE's size and then resampled, and the two
        // are not the same file. Not by much of an amplitude — measured on the
        // reference path, a 3x average costs σ about 4%, and about 1% where the plate
        // scales freely, because `plateScale` already tracks the render's long edge and
        // the plate's energy sits in its coarsest octave. The audit's "cutting grain
        // sigma about 3x" is wrong by an order of magnitude and
        // `testFilmGrainHasTheSameAmplitudeAtEveryRenderSize` records the real numbers.
        //
        // What it does change is the half-pixel floor. `plateScale` refuses to draw a
        // grain cell finer than half a pixel because there is nothing there to draw —
        // and a resample AFTER the plate has been scaled divides straight past that
        // floor, so a heavily downsized delivery carried a pattern finer than the model
        // allows and finer than the preview showed. Graining here puts the floor where
        // the photographer will see it. C1 grains at output resolution for the same
        // family of reasons (docs/03:116-118), and this is also cheaper: the kernel
        // runs over the output's pixels rather than the decode's.
        //
        // Before the output sharpen, which is where it already sat relative to it: the
        // only thing this moved is the resize.
        //
        // And the plate is scaled for the delivery's PIXELS-PER-GATE, not for its
        // pixel count. A crop takes pixels away and takes the same fraction of the
        // negative away with them, so the grain's pixel footprint does not change;
        // handing `plateScale` the cropped long edge instead would make every cropped
        // export's grain finer than the negative's by exactly the crop factor. The
        // uncropped equivalent of this delivery is `decode × delivered ÷ cropped`,
        // which is also, for an uncropped frame, just the delivered long edge — and
        // which is the footprint the old decode-then-resize order happened to produce,
        // since a resample scales the grain with everything else. That part of it was
        // right and is kept.
        let plateLongEdge = FilmGrainProfile.plateLongEdge(
            decodeLongEdge: longEdge,
            croppedLongEdge: Int(Swift.max(extent.width, extent.height).rounded()),
            deliveredLongEdge: Int(Swift.max(image.extent.width,
                                             image.extent.height).rounded()))
        if let film = plan.filmChain, film.grainAmount > 0,
           let plate = Self.grainPlate(film: film, extent: image.extent,
                                       plateLongEdge: plateLongEdge) {
            image = graph.applyGrain(image, plate: plate, film: film)
        }
        image = Self.applyOutputSharpen(image, exportRecipe.sharpen,
                                        resolutionPPI: exportRecipe.resolutionPPI)
        if let watermark = exportRecipe.watermark, !watermark.text.isEmpty {
            image = Self.applyWatermark(image, watermark)
        }
        // Last, on the output pixel grid: the dither has to be one output CODE wide, and
        // a resample after it would average the pattern away.
        image = Self.applyDither(image, colorSpace: exportRecipe.colorSpace,
                                 bitDepth: exportRecipe.effectiveBitDepth)
        return image
    }

    // MARK: - Dither

    /// Ordered dither, immediately before the encoder quantizes (docs/11 §Format).
    ///
    /// There was no dithering anywhere in the repository, and the export sheet said so;
    /// an 8-bit sky off an f32 pipeline bands, and it bands worst in exactly the frames
    /// worth delivering. This adds at most half an output code of a tiled 8×8 Bayer
    /// pattern, which is enough to make the rounding land on the code below or the code
    /// above in the proportion the true value asks for, so the local mean survives
    /// quantization instead of stepping.
    ///
    /// The amplitude is the part that has to be right, and it is the units bug this
    /// codebase keeps making: one code is 0.0003 of display white at the bottom of the
    /// sRGB curve and 0.008 at the top, a factor of 27, so a constant offset would be
    /// noise in the shadows and nothing at all in the highlights. `Dither.codeStep`
    /// writes that conversion, and it is baked here as a per-channel table so the GPU
    /// can fetch it — the same trick every other colour-bearing function in this graph
    /// uses, and no new kernel.
    ///
    /// One approximation, stated: the offset is added in the WORKING primaries and the
    /// encoder then converts to the destination's, so a saturated colour's dither is
    /// rotated by that 3×3 and its amplitude scaled by the row norms — of order one, and
    /// a dither only needs to be about a code wide to break a band.
    static func applyDither(_ image: CIImage, colorSpace: ExportColorSpace,
                            bitDepth: Int) -> CIImage {
        guard Dither.isWorthwhile(bitDepth: bitDepth) else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1,
              extent.width.isFinite, extent.height.isFinite else { return image }

        let transfer = colorSpace.transfer
        guard let plate = Self.ditherPlate(extent: extent),
              let steps = ColorCube.filter(DitherStepCube.forTransfer(transfer),
                                           image: image),
              let offsets = KernelLibrary.apply(KernelLibrary.multiply, extent: extent,
                                                [plate, steps])
        else { return image }
        return KernelLibrary.apply(KernelLibrary.addGlow, extent: extent,
                                   [image, offsets, CIVector(x: 1, y: 1, z: 1)]) ?? image
    }

    /// The 8×8 Bayer cell, tiled over the frame, carrying values in (−0.5, +0.5).
    ///
    /// Stored biased into (0, 1) and re-centred by a colour matrix rather than written
    /// out negative, which is the same convention `grainPlate` uses and for the same
    /// reason: a bitmap-backed CIImage is a texture, and asking a texture to carry signed
    /// values is asking a question about formats that does not need asking.
    static func ditherPlate(extent: CGRect) -> CIImage? {
        let side = Dither.matrixSide
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let v = Float(Dither.offset(x: x, y: y) + 0.5)
                let i = (y * side + x) * 4
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let cell = CIImage(bitmapData: data, bytesPerRow: side * 16,
                           size: CGSize(width: side, height: side),
                           format: .RGBAf, colorSpace: nil)
        let tiler = CIFilter.affineTile()
        tiler.inputImage = cell
        tiler.transform = .identity
        guard let tiled = tiler.outputImage?.cropped(to: extent) else { return nil }

        // Back to (−0.5, +0.5). `CIColorMatrix`'s bias is unclamped, which is what lets
        // the result go negative at all.
        let centre = CIFilter.colorMatrix()
        centre.inputImage = tiled
        centre.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        centre.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        centre.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        centre.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        centre.biasVector = CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)
        return centre.outputImage
    }

    /// Render the SDR base and the HDR rendition off one shared graph, then derive the
    /// gain map from the pair (docs/14 §7: render twice at two peaks, cheaply).
    public func renderHDRPair(source: any ImageSource, recipe: Recipe,
                              settings: HDRSettings,
                              strokeSets: [String: BrushStrokeSet] = [:])
        throws -> (sdr: CIImage, hdr: CIImage) {
        guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1.0) else {
            throw RenderError.decodeFailed
        }
        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let options = RenderGraph.Options(longEdge: longEdge, draft: false,
                                          lutSize: LUT3D.exportSize)

        let sdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: 100, lutSize: LUT3D.exportSize,
                                 captureISO: source.captureMetadata.iso)
        let hdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: settings.whiteTargetPercent,
                                 lutSize: LUT3D.exportSize,
                                 captureISO: source.captureMetadata.iso)

        let cached = mattes[source.url] ?? [:]
        let sdrGraph = makeGraph(plan: sdrPlan, decoded: decoded, draft: false,
                                 strokeSets: strokeSets, aiMattes: cached)
        let hdrGraph = makeGraph(plan: hdrPlan, decoded: decoded, draft: false,
                                 strokeSets: strokeSets, aiMattes: cached)
        let sdr = Self.applyGeometry(sdrGraph.build(decoded, plan: sdrPlan, options: options),
                                     recipe: recipe)
        let hdr = Self.applyGeometry(hdrGraph.build(decoded, plan: hdrPlan, options: options),
                                     recipe: recipe)
        return (sdr, hdr)
    }

    /// Apply the recipe's metadata policy to the image's property dictionary.
    ///
    /// The whole Metadata section of the export sheet had no reader: `MetadataPolicy`
    /// appeared only in its own declaration and in the sheet's bindings. "Strip GPS" —
    /// which `ExportRecipe`'s own header calls the one privacy decision that should
    /// never need to be remembered — stripped nothing, because whatever the decode's
    /// property dictionary carried went to the encoder untouched.
    ///
    /// This is deliberately only the SUBTRACTIVE half, and that half is sound under
    /// either reading of what the encoder does with these properties: if it honours
    /// them, the removed keys are gone; if it ignores them, nothing was going to be
    /// written anyway. Either way the coordinates do not reach the file.
    ///
    /// The additive half — guaranteeing EXIF is present when it is switched ON, and
    /// writing Copyright and Contact into IPTC — needs the file to be authored through
    /// `CGImageDestination` rather than `CIContext.write*Representation`, which takes
    /// no metadata argument. That is not done, and the panel now says so rather than
    /// implying those fields land somewhere.
    static func applyMetadataPolicy(_ image: CIImage,
                                    _ policy: MetadataPolicy,
                                    resolutionPPI: Double) -> CIImage {
        var properties = image.properties

        func drop(_ key: CFString) {
            properties.removeValue(forKey: key as String)
        }

        if !policy.includeGPS {
            drop(kCGImagePropertyGPSDictionary)
        }
        if !policy.includeEXIF {
            drop(kCGImagePropertyExifDictionary)
            drop(kCGImagePropertyExifAuxDictionary)
            drop(kCGImagePropertyTIFFDictionary)
            drop(kCGImagePropertyMakerAppleDictionary)
        }
        if !policy.includeKeywords {
            drop(kCGImagePropertyIPTCDictionary)
        }
        if !policy.includeCameraSerial {
            // The body's serial identifies the camera across every frame it ever shot,
            // so it is removed from each dictionary that carries one rather than only
            // from the obvious one.
            for container in [kCGImagePropertyExifAuxDictionary,
                              kCGImagePropertyExifDictionary] {
                let key = container as String
                guard var nested = properties[key] as? [String: Any] else { continue }
                nested.removeValue(forKey: kCGImagePropertyExifBodySerialNumber as String)
                nested.removeValue(forKey: kCGImagePropertyExifAuxSerialNumber as String)
                properties[key] = nested
            }
        }

        // Copyright and contact never reached the written file either. Both have a text
        // field in the export sheet and a slot in `MetadataPolicy`, and nothing anywhere
        // read them — a photographer typing a copyright line got a file with no
        // copyright in it, which is the one metadata field whose absence is the point of
        // filling it in.
        //
        // Written AFTER the drops above, and creating the dictionaries if those drops
        // removed them. Writing before would reintroduce the same defect one layer down:
        // an export with EXIF off drops the whole TIFF dictionary, so a copyright placed
        // in it first would go out with the bathwater.
        func put(_ value: String?, _ key: CFString, in container: CFString) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            var nested = properties[container as String] as? [String: Any] ?? [:]
            nested[key as String] = value
            properties[container as String] = nested
        }
        put(policy.copyright, kCGImagePropertyTIFFCopyright,
            in: kCGImagePropertyTIFFDictionary)
        put(policy.copyright, kCGImagePropertyIPTCCopyrightNotice,
            in: kCGImagePropertyIPTCDictionary)
        put(policy.contact, kCGImagePropertyIPTCContact,
            in: kCGImagePropertyIPTCDictionary)

        // Resolution never reached the written file at all: `resolutionPPI` drove the
        // output-sharpening radius and nothing else, so the print TIFF a user asked for
        // at 300 ppi opened in Photoshop at 72 dpi.
        if resolutionPPI.isFinite, resolutionPPI > 0 {
            properties[kCGImagePropertyDPIWidth as String] = resolutionPPI
            properties[kCGImagePropertyDPIHeight as String] = resolutionPPI
        }

        // Explicit upcast: `properties` is [String: Any] and the API takes
        // [AnyHashable: Any].
        return image.settingProperties(properties as [AnyHashable: Any])
    }

    private func write(_ image: CIImage, to destination: URL,
                       using recipe: ExportRecipe) throws {
        guard let colorSpace = Self.cgColorSpace(recipe.colorSpace) else {
            throw RenderError.unsupportedFormat(recipe.colorSpace.rawValue)
        }
        let prepared = Self.applyMetadataPolicy(image, recipe.metadata,
                                                resolutionPPI: recipe.resolutionPPI)
        let quality = Num.clamp(recipe.quality / 100.0, 0, 1)
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [qualityKey: quality]

        // Every branch writes `prepared`, not `image` — the metadata policy is only
        // applied if the thing carrying it is the thing that gets encoded.
        do {
            switch recipe.format {
            case .jpeg:
                try context.writeJPEGRepresentation(of: prepared, to: destination,
                                                    colorSpace: colorSpace,
                                                    options: options)
            case .heif:
                try context.writeHEIFRepresentation(of: prepared, to: destination,
                                                    format: .RGBA8,
                                                    colorSpace: colorSpace,
                                                    options: options)
            case .png:
                try context.writePNGRepresentation(
                    of: prepared, to: destination,
                    format: recipe.bitDepth >= 16 ? .RGBA16 : .RGBA8,
                    colorSpace: colorSpace, options: [:])
            case .tiff:
                try context.writeTIFFRepresentation(
                    of: prepared, to: destination,
                    format: recipe.bitDepth >= 16 ? .RGBA16 : .RGBA8,
                    colorSpace: colorSpace, options: [:])
            }
        } catch {
            throw RenderError.writeFailed(destination)
        }
    }

    static func cgColorSpace(_ space: ExportColorSpace) -> CGColorSpace? {
        switch space {
        case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)
        case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)
        }
    }

    // MARK: - Graph assembly

    /// Build the graph WITH its per-frame inputs. Masks are rasterized on the CPU by
    /// the reference implementation and handed in as single-channel images; the grain
    /// plate is generated once per stock and tiled. Leaving either empty is how the
    /// local stage and film grain silently did nothing.
    ///
    /// `deferGrain` withholds the film grain plate so `RenderGraph.build` skips the
    /// grain stage — for the export path, which applies grain itself on the OUTPUT
    /// pixel grid after the resize. Withholding the plate rather than adding a flag to
    /// `Options` because that is already how the graph is told a stage has nothing to
    /// run on, and because building a full-resolution plate the export will not use is
    /// the waste this is here to avoid.
    private func makeGraph(plan: RenderPlan, decoded: CIImage, draft: Bool,
                           strokeSets: [String: BrushStrokeSet],
                           aiMattes: [String: Plane],
                           deferGrain: Bool = false) -> RenderGraph {
        var graph = RenderGraph()
        guard !draft else { return graph }
        let extent = decoded.extent

        if !plan.masks.isEmpty {
            // Mask rasters are smooth by construction, so they cost a fraction of the
            // frame at proxy resolution and upsample without visible error.
            let long = Swift.max(extent.width, extent.height)
            let scale = long > 0 ? Swift.min(1.0, CGFloat(Self.maskRasterLongEdge) / long) : 1
            let width = Swift.max(Int(extent.width * scale), 8)
            let height = Swift.max(Int(extent.height * scale), 8)

            // The stage input the mask components sample.
            //
            // This used to be `nil`, which meant every component that reads the picture
            // rasterized to an EMPTY plane on every shipping path — Luma Range, Colour
            // Range and both Similarity kinds returned nothing, the Refine slider's
            // guided-filter step was skipped entirely (`refined` guards on the same
            // argument), and Automask was forced off. Linear, Radial and a plain brush
            // were the only mask kinds that did anything, and the panel showed no
            // badge, because `validationError()` has nothing to complain about.
            //
            // Built at raster resolution, so this is a small fraction of a frame, and
            // through `localStageInput` so it is the same image the CPU reference hands
            // its rasterizer — a luma band is denominated in EV of the corrected scene,
            // not of the raw decode, or the handles move when Exposure does.
            let source = maskSource(decoded: decoded, plan: plan,
                                    width: width, height: height, extent: extent,
                                    strokeSets: strokeSets)

            for mask in plan.masks {
                let alpha = MaskRaster.combine(mask: mask,
                                               size: (width: width, height: height),
                                               source: source,
                                               strokeSets: strokeSets,
                                               aiMattes: aiMattes)
                guard let image = Self.image(from: alpha, targetExtent: extent) else {
                    continue
                }
                graph.maskImages[mask.id] = image
            }
        }

        if let film = plan.filmChain, film.grainAmount > 0, !deferGrain {
            graph.grainPlate = Self.grainPlate(film: film, extent: extent)
        }
        return graph
    }

    /// One mask's alpha, rasterized for display over the loupe.
    ///
    /// The app had no way to produce this. `MaskOverlayView` takes a raster and every
    /// caller passed nil, so its fallback — a flat tint over the entire frame — was the
    /// only thing the "show this mask's alpha as an overlay" button ever drew. A
    /// uniform wash reads as "this mask selects everything", which is worse than
    /// showing nothing, and it was the app's only way to SEE a mask.
    ///
    /// Built through the same `maskSource` and `MaskRaster.combine` the render uses, so
    /// what the overlay shows is what the pipeline will apply — an overlay derived from
    /// the displayed preview instead would put a luma-range mask's band in the wrong
    /// place, which is exactly the sort of "close enough" that makes an instrument
    /// worse than useless.
    ///
    /// A `Plane`, not a `CGImage`. It used to hand back an 8-bit grey CGImage with
    /// `CGImageAlphaInfo.none`, which the viewer then used as a SwiftUI `.mask` —
    /// and a SwiftUI mask reads the ALPHA channel, which on that image is 1
    /// everywhere. So the overlay was a flat tint over the whole frame a second time,
    /// by a different route than the first. The six overlay modes need the alpha as
    /// numbers anyway: `MaskOverlay.composite` mixes the picture with it per pixel.
    public func renderMaskAlpha(source: any ImageSource, recipe: Recipe, maskID: String,
                                strokeSets: [String: BrushStrokeSet] = [:]) -> Plane? {
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint)
        guard let mask = plan.masks.first(where: { $0.id == maskID }) else { return nil }

        let native = source.nativeLongEdge
        let scale = native > 0
            ? Swift.min(1.0, Double(Self.maskRasterLongEdge) / native) : 1.0
        guard let decoded = source.decode(recipe: recipe, draft: true,
                                          scaleFactor: scale) else { return nil }

        let extent = decoded.extent
        let long = Swift.max(extent.width, extent.height)
        let fit = long > 0 ? Swift.min(1.0, CGFloat(Self.maskRasterLongEdge) / long) : 1
        let width = Swift.max(Int(extent.width * fit), 8)
        let height = Swift.max(Int(extent.height * fit), 8)

        let stage = maskSource(decoded: decoded, plan: plan, width: width,
                               height: height, extent: extent, strokeSets: strokeSets)
        return MaskRaster.combine(mask: mask,
                                  size: (width: width, height: height),
                                  source: stage,
                                  strokeSets: strokeSets,
                                  // The same cache the render reads, so the overlay
                                  // shows the subject mask the picture is getting
                                  // rather than an empty one.
                                  aiMattes: mattes[source.url] ?? [:])
    }

    /// The local-stage input, at mask-raster resolution, as an `ImageBuffer`.
    ///
    /// Returns nil when no mask component actually reads the picture, because then this
    /// is a whole extra render pass bought for nothing: a Linear or Radial gradient is
    /// pure geometry and a brush is pure geometry plus its stroke set.
    private func maskSource(decoded: CIImage, plan: RenderPlan,
                            width: Int, height: Int, extent: CGRect,
                            strokeSets: [String: BrushStrokeSet]) -> ImageBuffer? {
        /// A brush is pure geometry UNLESS one of its strokes has Automask on, which
        /// gates each stamp on a colour difference against the picture.
        ///
        /// `MaskKind.brush.readsSourceImage` is false, correctly, for a plain brush —
        /// but that made this test skip the stage input whenever Refine was 0, and
        /// `MaskRaster.paint` then computes `stroke.automask && source != nil`, which is
        /// false, and drops the ΔE gate entirely. So the Automask toggle did nothing in
        /// preview or export while the CPU reference honoured it, and turning Refine up
        /// to 3 switched it back on by accident.
        func usesAutomask(_ component: MaskComponent) -> Bool {
            guard component.kind == .brush, let ref = component.strokesRef,
                  let set = strokeSets[ref] else { return false }
            return set.strokes.contains { $0.automask }
        }

        let needsPicture = plan.masks.contains { mask in
            mask.components.contains { $0.kind.readsSourceImage || usesAutomask($0) }
                || MaskRaster.refineRadius(feather: mask.refine.feather,
                                           longEdge: Swift.max(width, height)) >= 1
        }
        guard needsPicture else { return nil }

        let scaleX = CGFloat(width) / Swift.max(extent.width, 1)
        let scaleY = CGFloat(height) / Swift.max(extent.height, 1)
        let small = decoded
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // Draft: the mask is sampling the picture's LUMINANCE and COLOUR, and the
        // spatial stages move neither meaningfully at this size. Skipping them keeps
        // this to one cheap pass.
        let staged = RenderGraph().localStageInput(
            small, plan: plan, options: RenderGraph.Options(longEdge: Swift.max(width, height),
                                                            draft: true))
        return Self.buffer(from: staged, context: context)
    }

    /// Long edge a mask raster is computed at. Masks are low-frequency fields; the
    /// guided-filter refinement that makes their edges sharp runs at full resolution
    /// in the graph, not here.
    ///
    /// Public because it is also the resolution an AI matte is generated at, and
    /// `matteSourceImage` takes it as a default argument.
    public static let maskRasterLongEdge: Int = 1024

    /// A single-channel plane as a grey CIImage stretched over the frame.
    static func image(from plane: Plane, targetExtent: CGRect) -> CIImage? {
        var pixels = [Float](repeating: 1, count: plane.width * plane.height * 4)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let v = Float(Num.saturate(plane[x, y]))
                let i = (y * plane.width + x) * 4
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: plane.width * 16,
                            size: CGSize(width: plane.width, height: plane.height),
                            format: .RGBAf, colorSpace: nil)
        guard plane.width > 0, plane.height > 0,
              targetExtent.width > 0, targetExtent.height > 0 else { return image }
        let sx = targetExtent.width / CGFloat(plane.width)
        let sy = targetExtent.height / CGFloat(plane.height)
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: targetExtent.origin.x,
                                               y: targetExtent.origin.y))
    }

    /// A tileable unit-variance grain plate, mapped into [0,1] because the kernel
    /// re-centres it. Deterministic: the same frame grains the same way every render.
    ///
    /// THREE plates on a colour stock, one per emulsion layer, each at its own crystal
    /// size and from its own seed — `lumenGrain` already samples `noise.rgb` per
    /// channel, so the kernel needed no change; it was being handed a grey plate. See
    /// `ReferenceRenderer.applyGrain` for why decorrelated layers are what makes grain
    /// read as film. A monochrome stock takes the single-plate path, both because its
    /// layers must stay correlated and because building three identical ones would be
    /// waste.
    /// `plateLongEdge` is the long edge `plateScale` is asked about, which is NOT
    /// always the extent's. `plateScale` converts a gate pitch into pixels through
    /// pixels-per-gate-millimetre, so it assumes the long edge it is given covers the
    /// whole gate. A cropped delivery does not: it has fewer pixels AND covers less of
    /// the negative, and those cancel — the grain keeps its pixel footprint, exactly as
    /// it does in a darkroom. So a caller holding a crop has to hand over the long edge
    /// the delivery WOULD have if it were uncropped. Defaults to the extent's own long
    /// edge, which is right whenever the image being grained is the whole frame.
    static func grainPlate(film: FilmChain, extent: CGRect,
                           plateLongEdge: Int? = nil) -> CIImage? {
        let size = 128
        let long = plateLongEdge ?? Int(Swift.max(extent.width, extent.height))

        /// One channel's tile: its noise in `channel`, zero in the others, so the three
        /// sum to a packed RGB plate. Alpha is carried by the red tile alone — addition
        /// compositing adds alpha too, and three opaque tiles would sum to 3.
        func tile(channel: Int) -> CIImage? {
            let plate = FilmGrainProfile.plate(
                size: size, seed: film.grain.plateSeed(channel: channel), sigma: 1)
            var pixels = [Float](repeating: 0, count: size * size * 4)
            for i in 0..<(size * size) {
                // No `saturate`: the texture is RGBAf and the clamp was flattening the
                // 3.4% of the plate beyond ±2σ — precisely the strongest grains.
                pixels[i * 4 + channel] =
                    Float(Double(plate[i]) / FilmGrainProfile.plateEncodeScale + 0.5)
                pixels[i * 4 + 3] = channel == 0 ? 1 : 0
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let image = CIImage(bitmapData: data, bytesPerRow: size * 16,
                                size: CGSize(width: size, height: size),
                                format: .RGBAf, colorSpace: nil)
            let scale = Swift.max(film.grain.plateScale(
                longEdgePixels: long, printSizeInches: film.printLongEdgeInches,
                channel: channel), 0.5)
            let scaled = image.transformed(
                by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            let tiler = CIFilter.affineTile()
            tiler.inputImage = scaled
            tiler.transform = .identity
            return tiler.outputImage ?? scaled
        }

        if film.grain.monochrome {
            // One plate, written to all three channels: no dye layers, no colour.
            let plate = FilmGrainProfile.plate(
                size: size, seed: FilmGrainProfile.defaultPlateSeed, sigma: 1)
            var pixels = [Float](repeating: 1, count: size * size * 4)
            for i in 0..<(size * size) {
                let v = Float(Double(plate[i]) / FilmGrainProfile.plateEncodeScale + 0.5)
                pixels[i * 4] = v
                pixels[i * 4 + 1] = v
                pixels[i * 4 + 2] = v
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let image = CIImage(bitmapData: data, bytesPerRow: size * 16,
                                size: CGSize(width: size, height: size),
                                format: .RGBAf, colorSpace: nil)
            let scale = Swift.max(film.grain.plateScale(
                longEdgePixels: long, printSizeInches: film.printLongEdgeInches), 0.5)
            let scaled = image.transformed(
                by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            let tiler = CIFilter.affineTile()
            tiler.inputImage = scaled
            tiler.transform = .identity
            return (tiler.outputImage ?? scaled).cropped(to: extent)
        }

        guard let red = tile(channel: 0), let green = tile(channel: 1),
              let blue = tile(channel: 2) else { return nil }
        // Addition compositing is exact here rather than approximate: it works on
        // premultiplied colour, and premultiplying by an alpha of 1 or 0 leaves the
        // one contributing channel of each tile untouched.
        func add(_ a: CIImage, _ b: CIImage) -> CIImage? {
            let filter = CIFilter.additionCompositing()
            filter.inputImage = a
            filter.backgroundImage = b
            return filter.outputImage
        }
        guard let rg = add(red, green), let packed = add(rg, blue) else { return nil }
        return packed.cropped(to: extent)
    }

    // MARK: - Geometry (S16)

    /// Crop, straighten, flip AND the output scale compose into ONE transform and ONE
    /// resample. Two resamples are two low-pass filters, which is a blur nobody asked
    /// for (docs/14 §5.8).
    ///
    /// The crop is expressed on the STRAIGHTENED frame, not on the rotated bounding
    /// box: dragging a crop rectangle and then straightening must not slide the
    /// rectangle across the picture.
    /// The orientation transform `applyGeometry` uses, and the straightened/cropped
    /// rectangles it derives. Factored out so the INVERSE below is built from the same
    /// expression rather than a second copy of it that can drift.
    static func geometryRects(_ geo: Geometry, sourceSize: CGSize)
        -> (orientation: CGAffineTransform, usable: CGRect, target: CGRect) {
        var orientation = CGAffineTransform.identity
        if geo.flipH { orientation = orientation.scaledBy(x: -1, y: 1) }
        if geo.angle != 0 { orientation = orientation.rotated(by: -geo.angle * .pi / 180) }

        let extent = CGRect(origin: .zero, size: sourceSize)
        let rotated = orientation.isIdentity ? extent : extent.applying(orientation)
        let resolved = CropGeometry.resolve(sourceWidth: Double(sourceSize.width),
                                            sourceHeight: Double(sourceSize.height),
                                            geometry: geo)
        // The rotated picture keeps its centre, so the inscribed frame is centred on it.
        // `resolved` is top-left-origin; Core Image extents are y-up.
        let usable = CGRect(x: rotated.midX - CGFloat(resolved.usableWidth) / 2,
                            y: rotated.midY - CGFloat(resolved.usableHeight) / 2,
                            width: CGFloat(resolved.usableWidth),
                            height: CGFloat(resolved.usableHeight))
        let target = CGRect(x: usable.minX + CGFloat(resolved.x),
                            y: usable.maxY - CGFloat(resolved.y) - CGFloat(resolved.height),
                            width: CGFloat(resolved.width),
                            height: CGFloat(resolved.height))
        return (orientation, usable, target)
    }

    /// A point in the DISPLAYED frame — normalized 0…1, top-left origin, as a view
    /// hands it over — expressed as the source-normalized coordinate a recipe stores.
    ///
    /// The on-image mask tools need this and did not have it. `MaskCanvas` normalized
    /// every gesture against the drawn preview, which `renderPreview` has already
    /// cropped and straightened, and then stored the result as if it were
    /// source-relative. On any cropped photo a gradient or radial was therefore written
    /// somewhere other than where it was dragged, its handles drew somewhere else
    /// again, and a brush — whose size is a fraction of the SOURCE long edge — painted
    /// several times wider than the cursor ring promised. Uncropped photos were
    /// unaffected, which is why it survived casual use.
    ///
    /// Built by inverting the very transform `applyGeometry` applies, rather than by
    /// re-deriving the mapping: `CGAffineTransform.inverted()` cannot disagree with the
    /// forward direction about a convention, and getting flip-then-rotate ordering
    /// subtly wrong in a second implementation is exactly how this kind of bug starts.
    /// One scene-linear sample off the decoded frame, at a SOURCE-normalized point.
    ///
    /// This is the probe the white-balance solver has been waiting for. The only thing
    /// the app could sample was the displayed proxy — 8-bit sRGB, after tone mapping
    /// and the display transform — and `WhiteBalanceEngine.neutralizing` needs a value
    /// from before any of that. Everything colour-driven in the app has been stuck on
    /// the same hole: Point Colour, Colour Range masks, both Similarity kinds and the
    /// local colour tint all seed their samples with a hard-coded 18% grey.
    ///
    /// Deliberately taps the DECODED image, before Lumen's own stages. That is what the
    /// neutral solver wants, and it is the one tap whose meaning does not change when
    /// the user moves a slider — sampling after white balance would make the picked
    /// neutral depend on the white balance it is being used to compute.
    ///
    /// Cheap despite decoding at full resolution: Core Image is lazy, so rendering a
    /// five-pixel-square bounds computes that region and its filter support, not the
    /// frame. The square is an average because a single pixel of a real photograph is
    /// noise — the same reason every other editor's eyedropper samples an area.
    public func sampleSceneLinear(source: any ImageSource, recipe: Recipe,
                                  sourceX: Double, sourceY: Double,
                                  radius: Int = 2) -> RGB? {
        guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1.0)
        else { return nil }
        let extent = decoded.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        // Core Image extents are bottom-up; the caller's y is top-down.
        let px = extent.minX + Num.clamp(sourceX, 0, 1) * extent.width
        let py = extent.minY + (1 - Num.clamp(sourceY, 0, 1)) * extent.height

        let side = CGFloat(Swift.max(radius, 0) * 2 + 1)
        let wanted = CGRect(x: (px - CGFloat(radius)).rounded(.down),
                            y: (py - CGFloat(radius)).rounded(.down),
                            width: side, height: side)
        let clipped = wanted.intersection(extent)
        guard !clipped.isNull else { return nil }
        let width = Int(clipped.width.rounded(.down))
        let height = Int(clipped.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }
        let rect = CGRect(x: clipped.origin.x, y: clipped.origin.y,
                          width: CGFloat(width), height: CGFloat(height))

        // Read back in the working space, so what comes out is the same linear
        // Rec.2020 the graph operates in rather than anything display-referred.
        guard let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(decoded, toBitmap: base, rowBytes: width * 16,
                           bounds: rect, format: .RGBAf, colorSpace: working)
        }

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for i in 0..<(width * height) {
            sumR += Double(pixels[i * 4])
            sumG += Double(pixels[i * 4 + 1])
            sumB += Double(pixels[i * 4 + 2])
        }
        let count = Double(width * height)
        let mean = RGB(sumR / count, sumG / count, sumB / count)
        return mean.isFinite ? mean : nil
    }

    public static func sourceNormalized(displayedX u: Double, displayedY v: Double,
                                        geometry: Geometry,
                                        sourceSize: CGSize) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let (orientation, _, target) = geometryRects(geometry, sourceSize: sourceSize)
        guard target.width > 0, target.height > 0 else { return .zero }

        // Into the straightened frame's coordinates. Core Image extents are bottom-up
        // and `v` arrives top-down, so the y term flips.
        let point = CGPoint(x: target.minX + CGFloat(u) * target.width,
                            y: target.maxY - CGFloat(v) * target.height)

        let inSource = orientation.isIdentity
            ? point
            : point.applying(orientation.inverted())

        return CGPoint(x: inSource.x / sourceSize.width,
                       y: 1 - inSource.y / sourceSize.height)
    }

    /// The exact inverse of `sourceNormalized`: where a stored source-normalized point
    /// lands in the displayed frame. Handles and overlays need this so they draw on the
    /// thing the user dragged.
    public static func displayedNormalized(sourceX nx: Double, sourceY ny: Double,
                                           geometry: Geometry,
                                           sourceSize: CGSize) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let (orientation, _, target) = geometryRects(geometry, sourceSize: sourceSize)
        guard target.width > 0, target.height > 0 else { return .zero }

        let inSource = CGPoint(x: CGFloat(nx) * sourceSize.width,
                               y: (1 - CGFloat(ny)) * sourceSize.height)
        let point = orientation.isIdentity ? inSource : inSource.applying(orientation)

        return CGPoint(x: (point.x - target.minX) / target.width,
                       y: (target.maxY - point.y) / target.height)
    }

    /// How many displayed pixels one source pixel covers, along the long edge.
    ///
    /// The brush's size is stored as a fraction of the source long edge, and the hover
    /// ring was drawn as that fraction of the DISPLAYED long edge — so on a 0.35 crop
    /// the ring showed a third of the width the stroke actually painted.
    public static func displayedPixelsPerSourcePixel(_ geo: Geometry,
                                                     sourceSize: CGSize,
                                                     displayedLongEdge: CGFloat) -> CGFloat {
        let (_, _, target) = geometryRects(geo, sourceSize: sourceSize)
        let targetLong = Swift.max(target.width, target.height)
        guard targetLong > 0 else { return 1 }
        return displayedLongEdge / targetLong
    }

    /// `allowUpscale` exists because `scale` was `min(1, …)` unconditionally, which
    /// made `ExportRecipe.allowUpscale` dead: `targetSize` correctly returned an
    /// enlarged size and this then refused to reach it. Unticking "Don't enlarge" and
    /// asking for an 8000 px long edge from a 24 MP file wrote 4000 px, with nothing
    /// said. A preview never wants enlargement, so the clamp stays the default.
    /// `skipCrop` renders the straightened frame WITHOUT its crop, which is what a
    /// crop tool needs and the reason that tool could not be wired before.
    ///
    /// `renderPreview` applies geometry before returning, so the picture handed to the
    /// loupe is already cropped — while `CropOverlayView`'s rectangle is normalized to
    /// the straightened frame. Drawing one over the other put a second inset crop
    /// inside the first, compounding on every drag. Orientation and output scale still
    /// apply, because a crop tool showing an unstraightened frame would ask the user to
    /// place a rectangle against a picture they are not editing.
    static func applyGeometry(_ image: CIImage, recipe: Recipe,
                              scaleTo maxLongEdge: Int? = nil,
                              allowUpscale: Bool = false,
                              skipCrop: Bool = false) -> CIImage {
        let geo = recipe.develop.geometry
        var out = image

        // `geometryRects` works in a zero-origin frame, and both the rotation and the
        // scale below are about the ORIGIN rather than the image's centre — so an image
        // arriving at a non-zero origin would have its crop offset by exactly that
        // origin. Making the assumption true costs nothing when it already is, and the
        // function ends by re-normalizing anyway.
        if out.extent.origin != .zero {
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x,
                                                        y: -out.extent.origin.y))
        }

        // The frame the crop is a fraction of is `CropGeometry`'s INSCRIBED rectangle,
        // not the rotated frame's bounding box.
        //
        // It was `out.extent.applying(orientation)`, which returns the axis-aligned
        // bounding box of the transformed rectangle — strictly larger than the picture,
        // 12% larger in area for a 3:2 frame at 5°. The crop was a fraction of that, so
        // the default crop of the whole frame on a straightened photograph included the
        // four empty wedges rotation leaves behind, and nothing in the repository
        // computed an inscribed rectangle to save it.
        //
        // The arithmetic is in LumenCore so it can be tested from a machine with no
        // renderer, which is also why this file could carry the bug: it is `#if
        // os(macOS)` and had no test of any kind.
        var effective = geo
        if skipCrop { effective.crop = Crop() }
        // ONE definition, shared with the inverse the mask tools invert. `geometryRects`
        // was factored out for exactly that reason and `applyGeometry` still carried its
        // own copy of the arithmetic, so the two had already drifted — the comment on it
        // says "rather than a second copy of it that can drift" above a second copy.
        let rects = geometryRects(effective, sourceSize: out.extent.size)
        let orientation = rects.orientation
        let target = rects.target
        var scale: CGFloat = 1
        if let maxLongEdge {
            let long = Swift.max(target.width, target.height)
            if long > 0 {
                let wanted = CGFloat(maxLongEdge) / long
                scale = allowUpscale ? wanted : Swift.min(1, wanted)
            }
        }

        let combined = orientation.concatenating(
            CGAffineTransform(scaleX: scale, y: scale))
        if !combined.isIdentity {
            out = abs(scale - 1) > 0.0001
                ? scaled(out.transformed(by: orientation), by: scale)
                : out.transformed(by: combined)
        }

        let scaledTarget = target.applying(CGAffineTransform(scaleX: scale, y: scale))
        let clipped = scaledTarget.intersection(out.extent)
        if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 {
            out = out.cropped(to: clipped)
        }
        return out.transformed(by: CGAffineTransform(
            translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    // MARK: - Resampling

    static func downscale(_ image: CIImage, maxLongEdge: Int) -> CIImage {
        let extent = image.extent
        let longEdge = Swift.max(extent.width, extent.height)
        guard longEdge > CGFloat(maxLongEdge), longEdge > 0 else { return image }
        return scaled(image, by: CGFloat(maxLongEdge) / longEdge)
    }

    static func resize(_ image: CIImage, to target: (width: Int, height: Int)) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scaleX = CGFloat(target.width) / extent.width
        let scaleY = CGFloat(target.height) / extent.height
        guard abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 else { return image }
        return scaled(image, by: Swift.min(scaleX, scaleY))
    }

    /// Lanczos-3, in linear light. Resampling gamma-encoded data is the classic
    /// downscale-darkening bug; the working space here means we cannot make it.
    static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale > 0, abs(scale - 1) > 0.0001 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    // MARK: - Output sharpening

    static func applyOutputSharpen(_ image: CIImage, _ sharpen: OutputSharpen,
                                   resolutionPPI: Double) -> CIImage {
        guard !sharpen.isIdentity else { return image }
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(Num.clamp(sharpen.baseRadius(printPPI: resolutionPPI),
                                        0.3, 12))
        filter.intensity = Float(Num.clamp(sharpen.energy(), 0, 2))
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    // MARK: - Watermark

    /// Rasterization factor for the watermark's glyphs. Named because it has to be
    /// undone by exactly the same number a few lines later; a mismatch is a silently
    /// mis-sized mark on a client delivery.
    static let watermarkSupersample: CGFloat = 2

    static func applyWatermark(_ image: CIImage, _ watermark: Watermark) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let longEdge = Swift.max(extent.width, extent.height)
        let fontSize = Swift.max(longEdge * CGFloat(watermark.sizePercent / 100), 8)
        let inset = longEdge * CGFloat(watermark.insetPercent / 100)

        guard let generator = CIFilter(name: "CIAttributedTextImageGenerator") else {
            return image
        }
        // CoreText, not AppKit: nothing in LumenPipeline may import AppKit or SwiftUI
        // (docs/13 §2), which is also what keeps this target testable headless.
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let color = CGColor(colorSpace: gray,
                                  components: [1, Num.clamp(watermark.opacity / 100, 0, 1)])
        else { return image }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let text = NSAttributedString(string: watermark.text, attributes: attributes)
        generator.setValue(text, forKey: "inputText")

        // `inputScaleFactor` scales the rasterization, so it is a supersampling knob
        // and NOT free quality: setting it to 2 and using the result as-is drew the
        // mark at twice the requested percentage of the long edge — Size 3% put a 6%
        // mark on the picture. Rasterize at 2× for smoother glyph edges, then scale
        // back down by exactly the same factor, so the drawn height is the one the
        // slider asked for.
        generator.setValue(Self.watermarkSupersample, forKey: "inputScaleFactor")
        guard let raster = generator.outputImage else { return image }
        let inverse = 1 / Self.watermarkSupersample
        let rendered = raster.transformed(
            by: CGAffineTransform(scaleX: inverse, y: inverse))

        let size = rendered.extent
        var x = extent.maxX - size.width - inset
        var y = extent.minY + inset
        switch watermark.position {
        case .bottomLeft:
            x = extent.minX + inset
        case .bottomRight:
            break
        case .topLeft:
            x = extent.minX + inset
            y = extent.maxY - size.height - inset
        case .topRight:
            y = extent.maxY - size.height - inset
        case .centre:
            x = extent.midX - size.width / 2
            y = extent.midY - size.height / 2
        }
        let placed = rendered.transformed(by: CGAffineTransform(translationX: x, y: y))
        return placed.composited(over: image)
    }

    // MARK: - CPU reference

    /// Render through the pure-Swift reference implementation instead of the GPU
    /// graph. Slower by orders of magnitude and used deliberately: goldens compare the
    /// two, and a machine whose kernels will not compile still gets correct pixels.
    public func renderReference(source: any ImageSource, recipe: Recipe,
                                maxLongEdge: Int,
                                strokeSets: [String: BrushStrokeSet] = [:],
                                softProof: SoftProof? = nil) throws -> CGImage {
        let native = source.nativeLongEdge
        let scale = native > 0 ? Swift.min(1.0, Double(maxLongEdge) / native) : 1.0
        guard let decoded = source.decode(recipe: recipe, draft: true,
                                          scaleFactor: scale) else {
            throw RenderError.decodeFailed
        }
        guard let buffer = Self.buffer(from: decoded, context: context) else {
            throw RenderError.renderFailed
        }
        let plan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              captureISO: source.captureMetadata.iso,
                              softProof: softProof)
        // S3 runs here rather than inside `ReferenceRenderer.render`, which starts at
        // S6 and is what several dozen goldens compare against. The stage belongs on
        // this path — a fallback that skips the denoise the GPU path applies is a
        // different picture — and the same decode scale reaches the profile.
        var staged = buffer
        if !plan.denoiseIsIdentity {
            staged = plan.classicalDenoise.scaled(noiseScale: scale * scale).apply(buffer)
        }
        // Stroke sets go in, exactly as they do on the GPU path — a fallback that
        // silently drops every brush mask is not the same picture, and this is the
        // path that runs when the graph could not be built at all. The proof goes in for
        // the same reason: a fallback that quietly stops proofing would tell the user
        // their picture is deliverable when nothing had checked.
        let rendered = ReferenceRenderer.render(
            staged, plan: plan,
            // Mattes too, for the same reason: a fallback that drops the subject mask
            // renders a different picture from the one the user was looking at.
            inputs: ReferenceRenderer.Inputs(strokeSets: strokeSets,
                                             aiMattes: mattes[source.url] ?? [:]))
        guard let cgImage = Self.cgImage(from: rendered) else {
            throw RenderError.renderFailed
        }
        return cgImage
    }

    /// Pull a CIImage into the CPU reference's buffer type, in the working space.
    static func byte(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        return UInt8(Num.saturate(v) * 255)
    }

    public static func buffer(from image: CIImage, context: CIContext) -> ImageBuffer? {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1,
              extent.width.isFinite, extent.height.isFinite else { return nil }
        let width = Int(extent.width)
        let height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    public static func cgImage(from buffer: ImageBuffer,
                               space: RGBColorSpace = .rec2020) -> CGImage? {
        // The reference path produces display-linear values in the WORKING space.
        // Converting the primaries before encoding is what keeps it comparable with
        // the GPU path; tagging Rec.2020 data as sRGB would leave it oversaturated.
        let toOutput = space.matrix(to: .srgb)
        var bytes = [UInt8](repeating: 255, count: buffer.width * buffer.height * 4)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let converted = toOutput.apply(buffer[x, y])
                let encoded = TransferFunction.srgb.encode(converted.clamped(0, 1))
                let i = (y * buffer.width + x) * 4
                // `Num.saturate` propagates NaN, and UInt8(NaN) traps. One poisoned
                // pixel must not take down an export.
                bytes[i] = byte(encoded.r)
                bytes[i + 1] = byte(encoded.g)
                bytes[i + 2] = byte(encoded.b)
                bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: buffer.width, height: buffer.height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: buffer.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// One code-step table per transfer curve, built at most once each.
///
/// The table is a per-channel 1-D function carried in a 3-D cube, exactly as
/// `RenderPlan.toneGainCube32` carries the tone gain — the stock colour-cube filter is
/// the only table the GPU can fetch, so a 1-D function borrows it. Size 64 rather than
/// the usual 33 because the function's whole point is the shadows, where sRGB's toe puts
/// an 8× change of code width inside what would otherwise be a single cell.
///
/// Static `let`s rather than a cache with a lock: there are four curves in play across
/// every destination Lumen writes, Swift builds each of these once and only when it is
/// first read, and an export that never leaves sRGB never bakes the other three.
enum DitherStepCube {

    static let srgb = cube(.srgb)
    static let gamma22 = cube(.gamma22)
    static let gamma18 = cube(.gamma18)
    static let rec709 = cube(.rec709)

    static func forTransfer(_ transfer: TransferFunction) -> LUT3D {
        switch transfer {
        case .gamma22: return gamma22
        case .gamma18: return gamma18
        case .rec709: return rec709
        default: return srgb
        }
    }

    private static func cube(_ transfer: TransferFunction) -> LUT3D {
        LUT3D(size: 64) { value in
            RGB(Dither.codeStep(value.r, transfer: transfer, levels: 256),
                Dither.codeStep(value.g, transfer: transfer, levels: 256),
                Dither.codeStep(value.b, transfer: transfer, levels: 256))
        }
    }
}

#endif
