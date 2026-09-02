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
import os.signpost
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

    /// os_signpost intervals around the four phases of an interactive frame
    /// (docs/23 M1b), so an Instruments trace of a laggy drag says WHICH phase ate
    /// the budget instead of leaving it to be guessed from wall time. Free when no
    /// instrument is attached; the categories mirror the HUD's vocabulary.
    private static let signposter = OSSignposter(subsystem: "dev.lumenapp",
                                                 category: "render")

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
    /// must not pin a hundred mattes in memory. What the bound implies for anyone
    /// keeping a copy of this is in `storeMattes`.
    private var mattes: [URL: MatteEntry] = [:]
    private var matteOrder: [URL] = []
    private static let matteCacheLimit = 12

    /// Measured mixer-band mean hues per file — Uniformity's convergence target
    /// (docs/05; `ColorEngine.measureBandMeanHues`). Cached like the mattes and for
    /// the same reason: the measurement is a statement about the PHOTOGRAPH, made
    /// once, off the drag path.
    ///
    /// The basis is a small NEUTRAL decode — camera white balance, no edit — so the
    /// target holds still while the photographer works instead of chasing every
    /// slider through a feedback loop (Uniformity moves hues; hues re-measured
    /// per-edit would move the target Uniformity converges on). The known cost,
    /// recorded in docs/27 §2: a strong user WB change shifts the picture's hues off
    /// the measured basis, and the target lags by that shift — still the image's own
    /// blues, no longer exactly its current ones. `nil` is stored too ("this file
    /// measured as grey"), so a monochrome frame is not re-measured every frame.
    private var bandHues: [URL: [Double]?] = [:]
    private var bandHueOrder: [URL] = []
    private static let bandHueCacheLimit = 64
    /// Long edge of the measurement decode. Hue statistics are means over ~40k
    /// samples; 512 px is thousands of times that.
    private static let bandHueMeasureLongEdge = 512.0

    /// Rasters kept across frames so a draft can run S11 without paying
    /// `MaskRaster.combine` per mouse event. See the type's header for the contract.
    private let maskRasters = MaskRasterCache()

    /// Painted brush planes, so appending a stroke costs one stroke rather than the
    /// whole set. Separate from `maskRasters` because it caches a different thing at a
    /// different granularity: one component's painting, before the fold and before the
    /// refinement chain, which is the only part of a mask that grows without bound as
    /// the photographer works. See the type's header (docs/36 §1.2).
    private let brushPlanes = BrushPlaneCache()

    /// One file's mattes, and which kinds have been LOOKED for.
    ///
    /// The two are one value because they are evicted together, and they used to be
    /// neither. "Has this file been attempted" was `mattes[url] != nil` — per FILE, not
    /// per KIND — so adding a Subject mask ran the pass for `{aiSubject}`, and adding a
    /// People mask afterwards short-circuited on the first one's entry and never
    /// generated the People matte, on the preview path and on the export path both.
    /// The panel then reported "Vision found no person in this frame" about a request
    /// nobody had made.
    private struct MatteEntry {
        var planes: [String: Plane] = [:]
        /// Kinds a generation pass has been RUN for, whatever it found. Vision looking
        /// for a person and finding none is an answer, and this is what keeps it from
        /// being re-asked on every edit — the job the old per-file flag was doing, at
        /// the granularity the question actually has.
        var attempted: Set<String> = []
    }

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
        Set((mattes[url]?.planes ?? [:]).keys)
    }

    /// Which kinds a generation pass has already been run for on this file, whatever
    /// it found. The caller subtracts this from what the recipe wants and generates
    /// the difference; an empty difference is the fast exit.
    public func attemptedMatteKinds(for url: URL) -> Set<String> {
        mattes[url]?.attempted ?? []
    }

    /// Store what a generation pass produced, and record what it was ASKED for.
    ///
    /// `requested` is not derivable from `produced`: a kind Vision looked for and found
    /// nothing for produces no plane, and the whole point of the ledger is that such a
    /// kind is not re-segmented on every edit. Storing an empty result under the file
    /// was how that used to be expressed, and it could only say "this file", never
    /// "this kind of this file".
    ///
    /// Returns the files the bound evicted. THIS RENDERER IS THE LEDGER — anything the
    /// app keeps is a copy, and a copy that is not told about an eviction becomes a
    /// lie: browse thirteen photographs carrying Vision masks and come back to the
    /// first, and the app's own "attempted" set would short-circuit the regeneration
    /// while the render read an empty matte and the panel still said READY. The mask
    /// rendered as nothing, in the loupe, with no error anywhere. Handing the evictions
    /// back at the one call site that changes them is what keeps the copy honest.
    @discardableResult
    public func storeMattes(_ produced: [String: Plane], requested: Set<String>,
                            for url: URL) -> [URL] {
        var entry = mattes[url] ?? MatteEntry()
        entry.planes.merge(produced) { _, new in new }
        entry.attempted.formUnion(requested)
        mattes[url] = entry
        matteOrder.removeAll { $0 == url }
        matteOrder.append(url)
        var evicted: [URL] = []
        while matteOrder.count > Self.matteCacheLimit, let oldest = matteOrder.first {
            matteOrder.removeFirst()
            mattes.removeValue(forKey: oldest)
            evicted.append(oldest)
        }
        return evicted
    }

    public func forgetMattes(for url: URL) {
        mattes.removeValue(forKey: url)
        matteOrder.removeAll { $0 == url }
        // The mask rasters were computed from this file's pixels and mattes, so
        // they go with them. The raster key now carries the url, so a re-imported
        // file at the same path with NEW pixels is the case this clears — the key
        // alone cannot see a content change under an unchanged path. Coarse
        // (clears every photo's rasters), and correct: an invalidate is rare and
        // a raster rebake is a background stale-while-bake, not a stall.
        maskRasters.clear()
        // The band-hue measurement is a statement about the same pixels.
        bandHues.removeValue(forKey: url)
        bandHueOrder.removeAll { $0 == url }
    }

    // MARK: - Band hue statistics

    /// The measured mean hue per mixer band for this file, measured once and cached —
    /// Uniformity's convergence target (docs/05; docs/23 audit queue item 12). See
    /// `bandHues` for the basis and its recorded limitation.
    func measuredBandMeanHues(source: any ImageSource) -> [Double]? {
        let url = source.url
        if let held = bandHues[url] { return held }

        var means: [Double]? = nil
        let native = source.nativeLongEdge
        let scale = native > 0
            ? Swift.min(1.0, Self.bandHueMeasureLongEdge / native) : 1.0
        // Neutral recipe, draft decode: the camera's own rendition of the photograph,
        // cheap, and independent of everything the photographer will do to it.
        if let decoded = source.decode(recipe: Recipe(), draft: true,
                                       scaleFactor: scale),
           let buffer = Self.buffer(from: decoded, context: context) {
            means = ColorEngine.measureBandMeanHues(buffer)
        }

        bandHues[url] = means
        bandHueOrder.removeAll { $0 == url }
        bandHueOrder.append(url)
        while bandHueOrder.count > Self.bandHueCacheLimit,
              let oldest = bandHueOrder.first {
            bandHueOrder.removeFirst()
            bandHues.removeValue(forKey: oldest)
        }
        return means
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
                           maxLongEdge: maxLongEdge, draft: false,
                           coarseDecode: false)
    }

    public var unavailableKernels: [String] { availability.unavailable }

    /// Stamp `PlanTableCache`'s photograph identity before building a plan.
    ///
    /// Every entry point that owns an `ImageSource` calls this ahead of
    /// `RenderPlan(...)`, so the tables the plan bakes are recorded as THIS
    /// photograph's — the identity the cache's stale door refuses to cross. Only
    /// the draft path (`renderPreview` with `draft: true`) ever reaches that door,
    /// but stamping on every path keeps the ledger truthful for whichever render
    /// runs next. The identity is the file URL: it names the photograph, and it is
    /// already the identity the mask-raster keys use.
    private static func stampRenderIdentity(_ source: any ImageSource) {
        PlanTableCache.setRenderIdentity(PlanTableCache.renderIdentity(for: source.url))
    }

    // MARK: - Preview

    /// What a preview render hands back when the caller may have asked for a REGION:
    /// the pixels, the unit rectangle they actually cover (integralized — it can grow
    /// a hair beyond the ask), and the full delivered frame's pixel size, which is
    /// what the viewer draws its geometry against. Whole-frame renders carry a nil
    /// region and the image's own size.
    public struct PreviewDelivery {
        public let image: CGImage
        public let regionUnit: CGRect?
        public let fullPixelSize: CGSize
        /// Wall time inside `source.decode` — the RAW read and demosaic, separated from
        /// the graph for the first time. A cache hit reports near zero, so a number
        /// here means the file was actually gone back to; on an external drive that is
        /// a read of tens of megabytes before a pixel is computed. The owner's "six to
        /// seven seconds" on a photo change is unattributed until this is on the HUD.
        public let decodeMilliseconds: Double
    }

    /// `showingUncropped` is set while the crop tool is open, so the tool draws its
    /// rectangle against the frame that rectangle is expressed in.
    ///
    /// `softProof` is a VIEWING mode, not an edit (docs/11), which is why it arrives
    /// here as an argument rather than through the recipe: two viewers of the same photo
    /// may proof to different destinations, and neither is changing the picture.
    /// `coarseDecode` asks the RAW stage for Apple's draft decode
    /// (`isDraftModeEnabled`): a faster, LOWER-QUALITY demosaic, which Core Image
    /// honours only when `scaleFactor` is 0.5 or less. It is SEPARATE from `draft`,
    /// which governs whether the colour tables and mask rasters may be served stale,
    /// and separating them is the whole point of this parameter.
    ///
    /// An interactive frame used to carry both on one flag, so it had TWO quality
    /// knobs: its resolution, which `DraftLadder` measures and controls, and this one,
    /// which was hard-coded, invisible and unmeasured. The second is the one the eye
    /// notices. It is a softer picture at the same size — the demosaic is the stage
    /// that decides what fine detail exists at all — and it applied to every frame
    /// under a moving hand and to none at rest, which is exactly the shape the owner
    /// reported three rounds running: blurry while dragging, sharp on release.
    ///
    /// Worse than its cost is that nothing chose it. Because the flag is honoured only
    /// below half scale, the sharpness of a drag frame depended on where the ladder
    /// happened to sit relative to that threshold — a quality cliff at an unrelated
    /// constant, moving under a control whose job is to trade quality for speed
    /// deliberately.
    ///
    /// So the viewer's frames decode at full detail and the ladder holds the only
    /// quality knob there is — one lever, owned by the thing that measures. The coarse
    /// decode remains available to the one-shot instrument path (`renderOneShot`, where
    /// a 512 px scope proxy could not show a demosaic if it tried), but note that both
    /// of its callers pass `draft: false` today for reasons of their own, so nothing in
    /// the app currently asks for it at all.
    ///
    /// AND IT SHOULD NOT BE PAID PER FRAME, which is what makes the trade easy.
    /// `AppleRawSource` caches the decode under a key of everything the decoder reads —
    /// draft, scale, capture sharpening, the two NR amounts, lens profile, decoder
    /// version — and not one of those fields moves while a tone or colour slider is
    /// dragged, so every frame of the gesture is handed the same lazy `CIImage`. This
    /// context runs with `cacheIntermediates: true`, which is what lets Core Image reuse
    /// the demosaic behind it rather than re-running it per frame. Stated as the
    /// intent it is: that cache is bounded and heuristic, and a ladder step DOES change
    /// the scale factor and so the key. The `draft` line on the HUD is what says whether
    /// it is actually holding.
    public func renderPreview(source: any ImageSource, recipe: Recipe,
                              maxLongEdge: Int, draft: Bool,
                              coarseDecode: Bool,
                              showingUncropped: Bool = false,
                              strokeSets: [String: BrushStrokeSet] = [:],
                              softProof: SoftProof? = nil) throws -> CGImage {
        try renderPreviewDelivery(source: source, recipe: recipe,
                                  maxLongEdge: maxLongEdge, draft: draft,
                                  coarseDecode: coarseDecode,
                                  showingUncropped: showingUncropped,
                                  strokeSets: strokeSets,
                                  softProof: softProof,
                                  region: nil).image
    }

    /// The region-capable preview. `region` is a unit rectangle of the DELIVERED
    /// frame, origin top-left (`ZoomRegion`'s convention); the graph is lazy, so
    /// rasterizing the sub-rect is what makes a zoomed render cost the viewport
    /// rather than the sensor — the whole of docs/32's fifth-round fix.
    public func renderPreviewDelivery(source: any ImageSource, recipe: Recipe,
                                      maxLongEdge: Int, draft: Bool,
                                      coarseDecode: Bool,
                                      showingUncropped: Bool = false,
                                      strokeSets: [String: BrushStrokeSet] = [:],
                                      softProof: SoftProof? = nil,
                                      region: CGRect? = nil) throws -> PreviewDelivery {
        // Decode at the target resolution, not the sensor's: a 2560 px preview of a
        // 7000 px raw decodes roughly seven times less data.
        let native = source.nativeLongEdge
        let scale = native > 0 ? Swift.min(1.0, Double(maxLongEdge) / native) : 1.0
        let decodeInterval = Self.signposter.beginInterval("decode")
        let decodeStarted = DispatchTime.now().uptimeNanoseconds
        guard let decoded = source.decode(recipe: recipe, draft: coarseDecode,
                                          scaleFactor: scale) else {
            Self.signposter.endInterval("decode", decodeInterval)
            throw RenderError.decodeFailed
        }
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStarted) / 1e6
        Self.signposter.endInterval("decode", decodeInterval)

        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let planInterval = Self.signposter.beginInterval("plan")
        // The photograph's identity, stamped BEFORE the plan is built: the plan's
        // stale-table door (`PlanTableCache.pairedTableAllowingStale`) may only
        // borrow a table this photograph rendered with — the newest entry in the
        // slot, unqualified, is whatever photograph was edited last, which is how
        // stepping from a B&W edit flashed the next colour frame monochrome
        // (docs/31 round two §4).
        Self.stampRenderIdentity(source)
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
                              softProof: softProof,
                              // A draft frame may ride the previous event's finish and
                              // colour-grade tables while the exact bake lands off the
                              // render path — this is what takes the 23.7 ms
                              // finish bake (and the colour-grade bake on top of it,
                              // for Whites and Blacks) out of every frame of a drag.
                              // The settle render comes through here with draft: false
                              // and blocks on the exact tables, so the picture at rest
                              // never shows a stale one.
                              allowStaleTables: draft,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)
        Self.signposter.endInterval("plan", planInterval)
        let rasterInterval = Self.signposter.beginInterval("rasterize")
        let graph = makeGraph(plan: plan, decoded: decoded,
                              sourceURL: source.url,
                              allowStaleRasters: draft,
                              strokeSets: strokeSets,
                              aiMattes: mattes[source.url]?.planes ?? [:],
                              // The preview is an inspection, never a delivery — see
                              // the parameter's note at `makeGraph`.
                              maskRasterCeiling:
                                  CGFloat(DraftLadder.interactiveLongEdgeCeiling))
        Self.signposter.endInterval("rasterize", rasterInterval)
        // Preview decodes are downsampled, and downsampling averages the noise down
        // with them, so the profile the denoise stage works against follows the same
        // factor — squared, because it is a variance.
        var image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: longEdge,
                                                             noiseScale: scale * scale))
        image = Self.applyGeometry(image, recipe: recipe, scaleTo: maxLongEdge,
                                   skipCrop: showingUncropped)

        // The preview quantizes to 8-bit sRGB on the next line, and it did so
        // UNDITHERED while the export dithered — so the loupe showed banding in
        // exactly the skies the exported file would render clean, and a photographer
        // judging the sky was judging an artifact the file does not have. Same plate,
        // same amplitude table, same everything as the export's.
        image = Self.applyDither(image, colorSpace: .srgb, bitDepth: 8)

        // The graph is lazy, so THIS is where the GPU actually evaluates it — and
        // where a region ask changes what a zoomed render costs: only the sub-rect's
        // pixels (plus each kernel's own neighbourhood) are ever computed. The unit
        // rect arrives top-left-origin; Core Image extents are bottom-up, so the flip
        // happens here, once, at the same line the row-order comments in
        // KernelGoldenTests warn about.
        let fullExtent: CGRect = image.extent
        var rasterRect: CGRect = fullExtent
        var deliveredUnit: CGRect?
        // `!isInfinite` — `DecodeMaterializer.materialize`'s idiom, three files away,
        // guarding the same thing on the same kind of value. A Core Image extent can
        // legitimately be infinite (a generator nothing has cropped), and the
        // arithmetic below would turn that into a nonsense rect rather than into the
        // whole-frame render it should fall back to. The component checks beside it
        // cover a NaN edge, which `isInfinite` alone does not.
        //
        // Written as `CGRect.isFinite` first, which does not exist on Apple's
        // CoreGraphics and cost a CI round: `swiftc -parse` on the Linux box does not
        // type-check, and LumenPipeline is not built there at all, so a member that is
        // not there parses cleanly and fails on the first Mac that compiles it. The
        // checker's `values` pass learned the CG geometry types in the same commit;
        // the cheaper lesson is that the idiom was already in the package.
        let extentUsable: Bool = !fullExtent.isInfinite
            && fullExtent.minX.isFinite && fullExtent.minY.isFinite
            && fullExtent.width.isFinite && fullExtent.height.isFinite
            && fullExtent.width >= 1 && fullExtent.height >= 1
        if let region, extentUsable, region.width > 0, region.height > 0 {
            let asked = CGRect(
                x: fullExtent.minX + region.minX * fullExtent.width,
                y: fullExtent.minY + (1 - region.maxY) * fullExtent.height,
                width: region.width * fullExtent.width,
                height: region.height * fullExtent.height)
            let integral = asked.integral.intersection(fullExtent)
            if integral.width >= 1, integral.height >= 1,
               integral != fullExtent.integral {
                rasterRect = integral
                // Back to the top-left unit convention, from the rect that will
                // actually be delivered — integralization can move edges a pixel.
                deliveredUnit = CGRect(
                    x: (integral.minX - fullExtent.minX) / fullExtent.width,
                    y: 1 - (integral.maxY - fullExtent.minY) / fullExtent.height,
                    width: integral.width / fullExtent.width,
                    height: integral.height / fullExtent.height)
            }
        }
        let renderInterval = Self.signposter.beginInterval("render")
        let cgImage = context.createCGImage(
            image, from: rasterRect, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        Self.signposter.endInterval("render", renderInterval)
        guard let cgImage else {
            throw RenderError.renderFailed
        }
        // The full frame's extent when it is a usable one, else the pixels actually
        // delivered — which for any nil-region render IS the full frame. The viewer
        // denominates its whole geometry against this, so it must never be an
        // infinity that came from an uncropped generator.
        let fullPixelSize: CGSize = extentUsable
            ? CGSize(width: fullExtent.width, height: fullExtent.height)
            : CGSize(width: cgImage.width, height: cgImage.height)
        return PreviewDelivery(image: cgImage, regionUnit: deliveredUnit,
                               fullPixelSize: fullPixelSize,
                               decodeMilliseconds: decodeMs)
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
        try write(image, to: destination, using: exportRecipe,
                  sourceProperties: Self.sourceImageProperties(source.url))
        return availability.unavailable
    }

    /// The ORIGINAL file's property dictionary, through ImageIO — the base the
    /// metadata policy edits (docs/31 round one §13). Nil for a file no
    /// CGImageSource can open (a stub, a moved original); the policy then falls
    /// back to the rendered image's own dictionary.
    static func sourceImageProperties(_ url: URL) -> [String: Any]? {
        guard let container = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil)
                as? [String: Any]
        else { return nil }
        return properties
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
        Self.stampRenderIdentity(source)
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              // Not `hdr?.whiteTargetPercent`: raising the ceiling to
                              // 400% and then encoding 8 bits clipped everything above
                              // diffuse white. See `ExportRecipe.hdrIsWritable`.
                              displayWhiteTarget: exportRecipe.renderWhiteTargetPercent,
                              lutSize: LUT3D.exportSize,
                              captureISO: source.captureMetadata.iso,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)

        let graph = makeGraph(plan: plan, decoded: decoded,
                              sourceURL: source.url,
                              allowStaleRasters: false,
                              strokeSets: strokeSets,
                              aiMattes: mattes[source.url]?.planes ?? [:],
                              deferGrain: true)
        var image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: longEdge,
                                                             lutSize: LUT3D.exportSize))
        // The resize is where a shared render WOULD fork, and today nothing forks here.
        //
        // This function is called once per (photo × checked recipe) by
        // `AppStateActions.export`, and every call arrives at this line having just
        // built its own `RenderGraph` and rendered the whole develop chain from the
        // decode. Three checked recipes cost three full develop renders, not one render
        // and three tails. The only thing genuinely reused across them is the decoded
        // `CIImage`, which `ImageSource` caches — real, and a small fraction of the
        // work at export scale.
        //
        // The comment that used to sit here claimed the sharing as fact, and so did
        // `ExportRecipe`, `ExportSheet` and docs/11. It is a good design and it is not
        // built: the natural shape is for `exportedImage` to take an already-rendered
        // master and apply only geometry, resize, grain, sharpen, watermark and dither
        // — everything from here down. What makes it more than a refactor is that
        // `RenderPlan` is built from `exportRecipe.renderWhiteTargetPercent`, so two
        // recipes with different HDR white targets do NOT share a master and the
        // sharing has to be keyed on that. It also needs measuring on a Mac before
        // anyone claims a number for it.
        let cropped = Self.applyGeometry(image, recipe: recipe)
        let extent = cropped.extent
        if exportRecipe.resizeMode == .none {
            // "Don't resize" means the resampler DOES NOT RUN — scale is exactly 1
            // by construction, not by arithmetic (docs/31 round one §11). The old
            // path fed `targetSize` the crop extent TRUNCATED to Int, then asked
            // `applyGeometry` to scale to it: any cropped or straightened
            // photograph has a fractional crop extent, so `.none` resampled the
            // whole frame through Lanczos at ~0.9999× and delivered it one pixel
            // short per axis. `cropped` above is already the un-resized geometry —
            // orientation and crop, no scale — so it IS the `.none` delivery.
            image = cropped
        } else {
            // The UN-TRUNCATED crop extent (docs/32 Stream G item 3, the `.none`
            // fix's sibling): `Int(extent.width)` truncated a fractional crop
            // extent before the scale was derived from it, which near a rounding
            // boundary promised a short edge one pixel off the size the resample
            // below actually delivers. `targetSize(Double, Double)` rounds from
            // the extent exactly as this function holds it.
            let target = exportRecipe.targetSize(sourceWidth: Double(extent.width),
                                                 sourceHeight: Double(extent.height))
            image = Self.applyGeometry(image, recipe: recipe,
                                       scaleTo: Swift.max(target.width, target.height),
                                       allowUpscale: exportRecipe.allowUpscale)
        }
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
        // WHICHEVER GRAIN THE PLAN RESOLVED, not just a stock's. This read
        // `plan.filmChain`, so a creative grain fell through to the graph and was laid
        // before the resize — see `RenderGraph.defersGrain` for what that costs. The
        // two cases were never different: one `GrainPlan`, one plate builder, one
        // kernel, and `plateLongEdge` is the uncropped equivalent of this delivery for
        // both of them.
        if let grain = plan.grain, grain.amount > 0,
           let plate = RenderGraph.grainPlate(grain, extent: image.extent,
                                              longEdge: plateLongEdge) {
            image = graph.applyGrain(image, plate: plate, grain: grain)
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
        let levels = Dither.levels(bitDepth: bitDepth)
        guard let plate = Self.ditherPlate(extent: extent),
              let steps = ColorCube.filter(DitherStepCube.forTransfer(transfer,
                                                                      levels: levels),
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
        let options = RenderGraph.Options(longEdge: longEdge,
                                          lutSize: LUT3D.exportSize)

        let hues = measuredBandMeanHues(source: source)
        Self.stampRenderIdentity(source)
        let sdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: 100, lutSize: LUT3D.exportSize,
                                 captureISO: source.captureMetadata.iso,
                                 bandMeanHues: hues)
        let hdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: settings.whiteTargetPercent,
                                 lutSize: LUT3D.exportSize,
                                 captureISO: source.captureMetadata.iso,
                                 bandMeanHues: hues)

        let cached = mattes[source.url]?.planes ?? [:]
        let sdrGraph = makeGraph(plan: sdrPlan, decoded: decoded,
                                 sourceURL: source.url,
                                 allowStaleRasters: false,
                                 strokeSets: strokeSets, aiMattes: cached)
        let hdrGraph = makeGraph(plan: hdrPlan, decoded: decoded,
                                 sourceURL: source.url,
                                 allowStaleRasters: false,
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
    /// **The two halves of this function rest on different amounts of evidence, and the
    /// difference is the most important thing on this page.**
    ///
    /// The SUBTRACTIVE half — the `drop` calls below — is sound under either reading of
    /// what `CIContext.write*Representation` does with the dictionary
    /// `settingProperties` attaches. If it honours it, the removed keys are gone. If it
    /// ignores it, nothing was going to be written anyway. Either way the coordinates do
    /// not reach the file, and Strip GPS means what it says.
    ///
    /// The ADDITIVE half — Copyright, Contact and the DPI pair below — is sound under
    /// only ONE of those readings. It is written here, correctly ordered after the
    /// drops, and whether the encoder serialises properties that were ADDED rather than
    /// merely preserved **has not been verified on a Mac by anyone**. The older comment
    /// in this spot asserted that `CIContext.write*Representation` "takes no metadata
    /// argument" and concluded the additive half was impossible; that is the pessimistic
    /// reading, and it is not obviously right — `settingProperties` exists precisely to
    /// carry a dictionary forward to an encoder. It is also not obviously wrong. Nobody
    /// has opened a written file and looked.
    ///
    /// So: this code writes a copyright line, and the export sheet says it writes one
    /// and says it is unconfirmed. That is the honest position while the fact is
    /// unknown. It is one afternoon at a Mac to settle — export a JPEG and a TIFF with a
    /// copyright set, read them back with `CGImageSourceCopyPropertiesAtIndex`, and
    /// check `kCGImagePropertyTIFFCopyright` and `kCGImagePropertyIPTCCopyrightNotice`
    /// — after which either this comment loses its hedge or the file has to be authored
    /// through `CGImageDestination`, which takes an explicit properties dictionary and
    /// removes the question. Zero tests touch this function on either platform.
    ///
    /// One thing the additive half is NOT: a way to guarantee EXIF is present when the
    /// switch is on. Nothing here fabricates camera fields the decode did not carry, and
    /// the sheet's EXIF row says so in those words.
    /// `sourceProperties` is the ORIGINAL FILE's property dictionary, read through
    /// ImageIO — not the rendered image's (docs/31 round one §13). `image` here has
    /// been through ~40 custom kernels, and `CIImage.properties` across a filter
    /// chain is one of two wrong things: empty, in which case the whole policy was
    /// a no-op and "EXIF: on" delivered files with no camera data at all; or the
    /// decode's dictionary carried forward verbatim, in which case the SOURCE's
    /// orientation and pixel dimensions survived onto a rotated, cropped, resized
    /// delivery — a file that lies about its own geometry. Reading the source
    /// dictionary makes the policy's subject real, and `reconcile` below overwrites
    /// the geometry fields with what was actually written. Nil (a source with no
    /// readable container, or a test stub) falls back to the rendered image's own
    /// dictionary, which preserves the old behaviour for callers with nothing
    /// better.
    static func applyMetadataPolicy(_ image: CIImage,
                                    _ policy: MetadataPolicy,
                                    resolutionPPI: Double,
                                    sourceProperties: [String: Any]? = nil) -> CIImage {
        var properties = sourceProperties ?? image.properties

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
        //
        // This is the additive half the header hedges. It is written; whether the
        // encoder serialises it is unconfirmed, and the sheet says as much.
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

        // RECONCILE the geometry fields with the pixels being written. The source
        // dictionary describes the source: a RAW's EXIF orientation says "rotate me
        // on display" about pixels this pipeline has already rendered upright, and
        // its pixel dimensions are the sensor's, not this delivery's. Carrying
        // either forward makes a resized file that claims the original's size and a
        // straightened file that viewers rotate a second time. The render is the
        // authority here, so these fields are overwritten last, after every policy
        // decision above.
        let deliveredWidth = Int(image.extent.width.rounded())
        let deliveredHeight = Int(image.extent.height.rounded())
        if deliveredWidth > 0, deliveredHeight > 0 {
            properties[kCGImagePropertyPixelWidth as String] = deliveredWidth
            properties[kCGImagePropertyPixelHeight as String] = deliveredHeight
            let exifKey = kCGImagePropertyExifDictionary as String
            if var exif = properties[exifKey] as? [String: Any] {
                exif[kCGImagePropertyExifPixelXDimension as String] = deliveredWidth
                exif[kCGImagePropertyExifPixelYDimension as String] = deliveredHeight
                properties[exifKey] = exif
            }
        }
        // Orientation 1: "the pixels are already the right way up", which is what
        // this renderer delivers by construction.
        properties[kCGImagePropertyOrientation as String] = 1
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        if var tiff = properties[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[tiffKey] = tiff
        }

        // Explicit upcast: `properties` is [String: Any] and the API takes
        // [AnyHashable: Any].
        return image.settingProperties(properties as [AnyHashable: Any])
    }

    private func write(_ image: CIImage, to destination: URL,
                       using recipe: ExportRecipe,
                       sourceProperties: [String: Any]? = nil) throws {
        guard let colorSpace = Self.cgColorSpace(recipe.colorSpace) else {
            throw RenderError.unsupportedFormat(recipe.colorSpace.rawValue)
        }
        let prepared = Self.applyMetadataPolicy(image, recipe.metadata,
                                                resolutionPPI: recipe.resolutionPPI,
                                                sourceProperties: sourceProperties)
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
                // 10-bit through `writeHEIF10Representation` (HEVC Main 10, the
                // format's answer to an 8-bit sky banding; docs/32 Stream G item 2).
                // No format parameter — the 10-bit call takes none; depth is the call.
                //
                // NO SILENT FALLBACK, deliberately. On a machine whose encoder cannot
                // do Main 10, this throws and the export FAILS with the destination
                // named, because a file quietly written at 8 bits when the recipe says
                // 10 is the exact class of lie this codebase keeps having to dig out.
                // The sheet only offers the 10-bit option when `canWriteTenBitHEIC`
                // probed true, so the failing path is a recipe carried over from
                // another machine — rare, and worth a loud error over a wrong file.
                if recipe.effectiveBitDepth >= 10 {
                    try context.writeHEIF10Representation(of: prepared, to: destination,
                                                          colorSpace: colorSpace,
                                                          options: options)
                } else {
                    try context.writeHEIFRepresentation(of: prepared, to: destination,
                                                        format: .RGBA8,
                                                        colorSpace: colorSpace,
                                                        options: options)
                }
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

    /// Whether THIS machine can author a 10-bit HEIC — settled by asking it to, once.
    ///
    /// The API (`writeHEIF10Representation`/`heif10Representation`, macOS 12+) exists
    /// at compile time on every OS this app runs on; whether the encoder behind it
    /// accepts Main 10 is a runtime property of the machine, and the only honest
    /// answer is a probe, not an assumption — the sheet must not offer a depth the
    /// export would then throw on. An 8×8 grey patch through the in-memory variant is
    /// the whole cost, a few milliseconds paid at most once per launch, and only if
    /// something asks (the bit-depth row of the export sheet is the one reader today).
    ///
    /// What the probe proves is "the encoder accepted the request"; that the bytes it
    /// returns really carry 10 bits per channel is asserted where it can be measured —
    /// `testTenBitHEICWritesTenDeepOrRefusesLoudly` writes a file through the real
    /// export path and reads its depth back through ImageIO on the macOS lane.
    public static let canWriteTenBitHEIC: Bool = {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return false }
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let patch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let encoded = try? context.heif10Representation(of: patch, colorSpace: space,
                                                        options: [:])
        return encoded != nil
    }()

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
    private func makeGraph(plan: RenderPlan, decoded: CIImage,
                           sourceURL: URL,
                           allowStaleRasters: Bool,
                           strokeSets: [String: BrushStrokeSet],
                           aiMattes: [String: Plane],
                           deferGrain: Bool = false,
                           maskRasterCeiling: CGFloat? = nil) -> RenderGraph {
        var graph = RenderGraph()
        let extent = decoded.extent

        // This used to `guard !draft else { return graph }` — so during every drag,
        // every mask rendered as absent and popped in on release, along with the
        // grain plate. Drafts now build the full graph; what makes that affordable is
        // `MaskRasterCache` below, which lets a draft frame reuse a raster instead of
        // paying probe (b)'s 12–190 ms per mask per event.
        if !plan.masks.isEmpty {
            // The raster resolution SCALES WITH THE RENDER (docs/31 round two §3).
            // Only a draft frame rasterizes at the 1024 proxy — that is the price a
            // moving hand pays, bounded by MaskRasterCache so it is paid once per
            // gesture, not per event. A settle or export frame rasterizes at the
            // render target's own resolution: every path used to cap at 1024 and
            // bilinearly upsample, which delivered every masked EXPORT a mask edge
            // resolved to 1/1024 of the frame — an 8 px ramp on a 45 MP file with
            // the boundary quantised to 8 px — while the CPU reference rasterizes
            // at full resolution, so the two renderers could not agree either.
            let long = Swift.max(extent.width, extent.height)
            // `maskRasterCeiling` bounds the SETTLE raster where the caller says the
            // render is an interactive inspection rather than a delivery: the zoomed
            // settle now renders at the sensor's own size (docs/32 owner round), and
            // a guided-refined raster at 7000+ px is seconds of CPU per settle — paid
            // at rest, per edit, while the photographer waits. An export passes nil
            // and rasterizes at the render target, which is the docs/31 §3 contract;
            // a capped inspection raster is at worst 1.7× softer at the edge than the
            // ideal, on the surface whose job is judging tone, not mask feather.
            let deliveryCap = allowStaleRasters ? CGFloat(Self.maskRasterLongEdge) : long
            let cap = Swift.min(deliveryCap, maskRasterCeiling ?? deliveryCap)
            let scale = long > 0 ? Swift.min(1.0, cap / long) : 1
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

            // Everything the raster reads goes into the key, or the cache lies —
            // PlanTableCache's rule, applied to planes. The source image is keyed by
            // the recipe subtrees `localStageInput` reads (S6–S10; S3/S8 are skipped
            // for a mask source), OVER-keyed on whole subtrees deliberately: an extra
            // rebake costs a background raster, an under-key shows last week's mask.
            // FILE identity is in the key UNCONDITIONALLY, and `maskRasterKey` is the
            // only place a key is spelled: it takes the photograph as a REQUIRED
            // parameter, so a raster key with no photograph in it is not something
            // this file can express any more.
            //
            // The url used to be spliced in here instead, inside `if source != nil`,
            // on the reasoning that a nil picture source "means the raster is pure
            // geometry, which is legitimately identical across photos". That is
            // false, and false in a way that no second conditional fixes. `source`
            // is nil exactly when `maskSource`'s `needsPicture` is false, and
            // `needsPicture` asks `MaskKind.readsSourceImage` — which returns false
            // for every AI kind and for `depthRange`, CORRECTLY, because those read a
            // cached Vision matte rather than the decode. A matte is the most
            // photograph-specific thing in this engine, so the one question the
            // condition asked was the one question that does not decide this.
            //
            // Concretely, before this: a Subject mask with Follow at 0 — the value
            // that row resets to (`MaskPanel:1645`), and `refineRadius` is 0 for any
            // feather ≤ 2 at the 1024 proxy, so the seeded 10 only has to be nudged
            // down — keyed as `maskJSON|1024x682||aiSubject|-`. Nothing in that names
            // the file. `mattesKey` is the matte KIND NAMES, identical across
            // photographs; `WxH` is 1024x682 for every 3:2 frame at draft, whatever
            // the sensor; Paste Settings copies mask ids verbatim; and
            // `MaskRasterCache.plane` serves an exact key hit to any identity. So the
            // next frame's subject brightened where the PREVIOUS frame's subject was,
            // in the loupe and in the delivered JPEG, with nothing badged.
            //
            // What the unconditional url costs, stated rather than waved past: a
            // geometry-only raster (a polygon, or a gradient stack `MaskGPU`
            // declined) genuinely IS identical across photographs at the same size,
            // and that reuse is given up. It is worth one bake — 12.8 ms for a
            // geometry-only stack at the proxy, docs/23 probe (b) — per mask, on the
            // first frame after a photograph switch, and never again, because this
            // cache holds ONE entry per mask id: a cross-photograph hit could only
            // ever have been the frame immediately after the switch. Within a
            // photograph the hit rate is unchanged. The alternative — keying the url
            // only for kinds that "can depend on the picture" — is the code that was
            // here, one level down: the same list, the same omission, and the next
            // matte kind added silently outside it.
            //
            // The picture-source fingerprint stays its own term and keeps its own
            // copy of the url, because `BrushPlaneCache` keys on this string too
            // (`sourceKey:` in `bake` below) and that cache has the same door.
            let photograph = PlanTableCache.renderIdentity(for: sourceURL)
            let sourceKey: String?
            if source != nil {
                // `sourceURL` is threaded in from the caller — the local `source` is
                // the staged ImageBuffer, which has no url (the first draft of this
                // asked it for one and the macOS compiler said no).
                sourceKey = Self.maskSourceFingerprint(recipe: plan.recipe)
                    .map { photograph + "|" + $0 }
            } else {
                // No stage input was built, so there is no fingerprint to state. This
                // term says that and nothing else; WHICH photograph is the key
                // builder's business now, not this branch's.
                sourceKey = "-"
            }

            for mask in plan.masks {
                // THE CLOSED-FORM PATH FIRST. A mask made only of gradients, with no
                // refinement, is evaluated in a shader at the render's own resolution —
                // so it never enters the raster cache, never misses it, and can never
                // be served one gesture stale. That staleness IS the tail the owner
                // reported dragging a radial (docs/35 §5.1).
                if let gpu = MaskGPU.alpha(for: mask, extent: extent) {
                    graph.maskImages[mask.id] = gpu
                    continue
                }
                let bake = { [brushPlanes] in
                    // The brush half is accumulated rather than replayed. Built inside
                    // `bake` and not before it, so a frame served a stale raster does
                    // not pay for painting it will not use.
                    var painted: [String: Plane] = [:]
                    for (index, component) in mask.components.enumerated()
                    where component.kind == .brush {
                        guard let ref = component.strokesRef,
                              let set = strokeSets[ref], !set.strokes.isEmpty else { continue }
                        // A brush WITHOUT automask does not read the picture, so its
                        // plane must not be thrown away when the exposure moves — that
                        // invalidation is the cost this cache exists to remove.
                        let readsPicture = set.strokes.contains { $0.automask }
                        painted[ref] = brushPlanes.plane(
                            componentKey: "\(mask.id)#\(index)",
                            set: set,
                            size: (width: width, height: height),
                            sourceKey: readsPicture ? (sourceKey ?? "-") : "-",
                            source: readsPicture ? source : nil)
                    }
                    return MaskRaster.combine(mask: mask,
                                              size: (width: width, height: height),
                                              source: source,
                                              strokeSets: strokeSets,
                                              aiMattes: aiMattes,
                                              brushPlanes: painted,
                                              // A `maskRef` component resolves against
                                              // this list; without it, one selects
                                              // nothing and says nothing.
                                              masks: plan.allMasks)
                }
                let alpha: Plane
                if let sourceKey,
                   let maskJSON = (try? CanonicalJSON.tree(of: mask))
                       .map(CanonicalJSON.serialize) {
                    let strokesKey = mask.components.compactMap(\.strokesRef)
                        .map { "\($0):\(strokeSets[$0]?.strokes.count ?? 0)" }
                        .joined(separator: ",")
                    // The matte KIND NAMES, not the matte pixels — which is why this
                    // term cannot stand in for the photograph, and why it was so easy
                    // to mistake for a term that could.
                    let mattesKey = aiMattes.keys.sorted().joined(separator: ",")
                    let key = Self.maskRasterKey(sourceURL: sourceURL,
                                                 maskJSON: maskJSON,
                                                 width: width, height: height,
                                                 strokesKey: strokesKey,
                                                 mattesKey: mattesKey,
                                                 sourceKey: sourceKey)
                    alpha = maskRasters.plane(maskID: mask.id, key: key,
                                              identity: photograph,
                                              allowStale: allowStaleRasters,
                                              bakeExact: bake)
                } else {
                    // An unencodable mask must not collide with anything: no cache.
                    alpha = bake()
                }
                guard let image = Self.image(from: alpha, targetExtent: extent) else {
                    continue
                }
                graph.maskImages[mask.id] = image
            }
        }

        // ONE PLATE BUILDER, in `RenderGraph`, band-limited to the resolution it is
        // about to be sampled at. This file had its own copy for the film path; see
        // that function's header for what the duplicate cost when the plate learned
        // to band-limit itself.
        if let grain = plan.grain, grain.amount > 0, !deferGrain, !grain.isCreative {
            graph.grainPlate = RenderGraph.grainPlate(
                grain, extent: extent,
                longEdge: Int(Swift.max(extent.width, extent.height)))
        }
        // And the graph is told, rather than left to infer it from a missing plate: a
        // creative grain builds its own when none is supplied, so withholding the plate
        // withheld nothing (C2-03).
        graph.defersGrain = deferGrain
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
    /// - Parameter longEdge: how big to rasterize. The overlay wants the proxy; a mask
    ///   row's thumbnail wants ~96 px, which is a hundredth of the pixels and therefore
    ///   about a hundredth of the cost — cheap enough to recompute whenever the recipe
    ///   moves, which is what makes a live thumbnail per row affordable at all.
    public func renderMaskAlpha(source: any ImageSource, recipe: Recipe, maskID: String,
                                strokeSets: [String: BrushStrokeSet] = [:],
                                longEdge: Int? = nil) -> Plane? {
        Self.stampRenderIdentity(source)
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              // The overlay's stage input must be the render's: a
                              // Uniformity-moved hue is part of what a colour-range
                              // mask samples.
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)
        guard let mask = plan.allMasks.first(where: { $0.id == maskID }) else { return nil }

        let target = Swift.max(longEdge ?? Self.maskRasterLongEdge, 16)
        let native = source.nativeLongEdge
        // The DECODE stays at the proxy even for a thumbnail. A 96 px decode would be a
        // second scale factor in `AppleRawSource`'s cache — a whole extra demosaic of a
        // 45 MP file — to save a rasterization that is already sub-millisecond at that
        // size. The scale that matters here is the raster's, not the decode's.
        let scale = native > 0
            ? Swift.min(1.0, Double(Self.maskRasterLongEdge) / native) : 1.0
        guard let decoded = source.decode(recipe: recipe, draft: true,
                                          scaleFactor: scale) else { return nil }

        let extent = decoded.extent
        let long = Swift.max(extent.width, extent.height)
        let fit = long > 0 ? Swift.min(1.0, CGFloat(target) / long) : 1
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
                                  aiMattes: mattes[source.url]?.planes ?? [:],
                                  masks: plan.allMasks)
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
        // The mask is sampling the picture's LUMINANCE and COLOUR, and the spatial
        // stages move neither meaningfully at this size. Skipping them keeps this to
        // one cheap pass — under its own name now that `draft` no longer gates stages.
        let staged = RenderGraph().localStageInput(
            small, plan: plan,
            options: RenderGraph.Options(longEdge: Swift.max(width, height),
                                         maskSource: true))
        return Self.buffer(from: staged, context: context)
    }

    /// The recipe subtrees the mask-source image is a function of — S6 white balance
    /// and exposure, S7 tone and zones, S9/S10 colour and grade — serialized
    /// canonically for the raster cache's key. Nil when any subtree fails to encode,
    /// which the caller treats as "do not cache".
    ///
    /// Public because the mask thumbnails key off it too: a thumbnail is a picture of
    /// what a mask SELECTS, and every selection that reads the picture — a luminance
    /// band, a colour range, a similarity point — moves when these subtrees move. Two
    /// callers stating the same dependency two ways is how they drift apart.
    public static func maskSourceFingerprint(recipe: Recipe) -> String? {
        var parts: [String] = []
        let inputs: [any Encodable] = [
            recipe.develop.raw, recipe.develop.tone, recipe.develop.zones,
            recipe.develop.color, recipe.develop.mixer, recipe.develop.pointColors,
            recipe.look.wheels, recipe.look.printerLights, recipe.look.primaries,
            recipe.look.bw,
        ]
        for value in inputs {
            guard let tree = try? CanonicalJSON.tree(of: value) else { return nil }
            parts.append(CanonicalJSON.serialize(tree))
        }
        return parts.joined(separator: "|")
    }

    /// One mask raster's `MaskRasterCache` key — the ONLY place a raster key is
    /// spelled, and the reason the photograph can no longer fall out of one.
    ///
    /// `sourceURL` is a required, non-optional parameter, deliberately, and it is the
    /// first term. The defect this replaced was not a missing `if`; it was a key
    /// assembled inline from whatever terms happened to be in scope, where the
    /// photograph was one OPTIONAL contributor among five and the branch that dropped
    /// it looked locally reasonable (see `makeGraph`, at the `sourceKey` block, for
    /// the full account). A key that omits the photograph is now unwriteable: there is
    /// no call to this function without a URL in hand.
    ///
    /// The consequence of getting it wrong is not a stale mask, it is the WRONG
    /// PHOTOGRAPH's mask. `MaskRasterCache.plane` serves an exact key hit to any
    /// identity, mask ids travel between photographs verbatim through Paste Settings,
    /// and at draft every 3:2 frame rasterizes at 1024x682 — so two frames that share
    /// a pasted mask definition share a key, and one frame wears the other's
    /// rasterized selection in the loupe and in the delivered file.
    ///
    /// None of the other terms can stand in for it. `maskJSON` is the mask DEFINITION,
    /// which Paste Settings makes identical on purpose. `WxH` is the raster size, which
    /// collides across every frame of the same aspect. `strokesKey` is stroke refs and
    /// counts. `mattesKey` is the matte KIND names — `aiSubject`, not the subject.
    /// `sourceKey` is the picture-source fingerprint, which is absent ("-") for
    /// precisely the matte-backed kinds where being wrong is most visible.
    static func maskRasterKey(sourceURL: URL,
                              maskJSON: String,
                              width: Int, height: Int,
                              strokesKey: String,
                              mattesKey: String,
                              sourceKey: String) -> String {
        // The same spelling of "which photograph" the cache's own identity check uses
        // (`PlanTableCache.renderIdentity`, which the renderer already stamps at
        // `:284`), so the key term and the identity term cannot drift apart.
        [PlanTableCache.renderIdentity(for: sourceURL),
         maskJSON, "\(width)x\(height)", strokesKey, mattesKey,
         sourceKey].joined(separator: "|")
    }

    /// Long edge a DRAFT frame's mask raster is computed at — and only a draft's.
    /// Settle and export rasterize at the render target's own resolution
    /// (`makeGraph`, docs/31 round two §3).
    ///
    /// The previous comment here claimed a full-resolution guided-filter
    /// refinement stage "in the graph" made the proxy harmless everywhere. No such
    /// stage exists, and it never did: the raster — refinement included — was
    /// computed at this size on every path and bilinearly upsampled, which is an
    /// 8 px ramp with an 8 px-quantised boundary on a 45 MP export.
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
        return sampleMean(decoded, sourceX: sourceX, sourceY: sourceY, radius: radius)
    }

    /// The cull-time clipping measurement (docs/10 §10.5, README goal 3).
    ///
    /// WHAT IT MEASURES, precisely, because the instrument's whole value is that claim.
    /// `source.decode` is `CIRAWFilter` at the flat settings `AppleRawSource` pins:
    /// Apple's tone curve, shadow boost, local tone mapping, gamut mapping and contrast
    /// all off, extended range kept, white balance at the camera's own neutral. Nothing
    /// downstream of it has run — no white balance adaptation, no exposure, no tone
    /// stage, no display transform. So the numbers are scene-referred and carry the
    /// headroom above display white, which is the entire difference from the develop
    /// histogram, and they are POST-DEMOSAIC, which is the entire difference from what
    /// docs/10 §10.5 specifies. `.sceneLinearDecode` is that statement, and it travels
    /// with the numbers into the cache and onto the panel.
    ///
    /// The proxy is the second honest limit. A 45 MP decode is 716 MB as f32 RGBA, so
    /// `RawTruth.plan` scales the decode first and records the site stride that
    /// corresponds to; the caption says a large blown region reads true and an isolated
    /// clipped pixel is averaged down.
    ///
    /// Not draft. Draft mode changes what the demosaic does, and a measurement taken
    /// through a cheaper decode than the one the user's render will use would be
    /// answering about a different picture.
    ///
    /// The name is `clippingStatistics`, not `sceneLinearStatistics`, because this runs
    /// for rendered files too and a JPEG's decode is not scene-linear — the camera's
    /// tone curve is baked into it and converting to linear Rec.2020 does not take it
    /// back out. The source says which reading its decode produces
    /// (`statisticsProvenance`) and that word travels into the row and onto the panel,
    /// so the honest label never lands on the untruthful measurement.
    public func clippingStatistics(source: any ImageSource,
                                   recipe: Recipe) -> (RawStatistics, RawTruth.Plan)? {
        let size = source.nativePixelSize
        let plan = RawTruth.plan(nativeWidth: size.width, nativeHeight: size.height)
        guard let decoded = source.decode(recipe: recipe, draft: false,
                                          scaleFactor: plan.decodeScaleFactor),
              let buffer = PipelineRenderer.buffer(from: decoded, context: context)
        else { return nil }
        let stats = RawStatistics.compute(buffer,
                                          provenance: source.statisticsProvenance,
                                          space: .rec2020,
                                          subsample: plan.bufferStride,
                                          recordedSiteStride: plan.siteStride)
        return (stats, plan)
    }

    /// One sample of the image a MASK compares against: `RenderGraph.localStageInput`,
    /// S6 through S10, which is the same image `maskSource` hands the rasterizer.
    ///
    /// A different tap from `sampleSceneLinear`'s, and the difference is the defect.
    /// A Colour Range or Similarity component compares its stored samples against the
    /// local stage input — which carries the tone stage and the colour+grade table as
    /// well as the linear matrix — while the eyedropper stored a value that had been
    /// through the linear matrix ALONE. With any real global tone or colour edit the
    /// clicked colour and the compared colour are different numbers, so the mask can
    /// fail to select the very pixel that was clicked, and the failure grows with the
    /// edit rather than announcing itself.
    ///
    /// Of the two taps this is the one that has to move: the mask must compare against
    /// what it will be applied to, and it is applied to the output of this function's
    /// own stage list.
    ///
    /// `maskSource: true` matches the raster's own source exactly, and for the same
    /// reason — a mask samples luminance and colour, and denoise and presence move
    /// neither.
    ///
    /// One approximation, stated: `maskSource` stages a 1024 px proxy while this stages
    /// the decode, and the tone stage's guided mask has a scale-dependent radius. The
    /// two therefore differ by the difference between two local averages of the same
    /// picture, which is nothing on a flat patch and small on a busy one — against a
    /// pre-existing error that was the whole of S7 plus the whole of S9/S10.
    public func sampleMaskStageInput(source: any ImageSource, recipe: Recipe,
                                     sourceX: Double, sourceY: Double,
                                     radius: Int = 2) -> RGB? {
        guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1.0)
        else { return nil }
        Self.stampRenderIdentity(source)
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)
        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let staged = RenderGraph().localStageInput(
            decoded, plan: plan,
            options: RenderGraph.Options(longEdge: longEdge, maskSource: true))
        // Cropped back to the decode's own extent so the normalized coordinate means
        // the same thing it did going in. Every stage in that list preserves the
        // extent today; a stage that stopped doing so would otherwise move the
        // eyedropper rather than fail.
        return sampleMean(staged.cropped(to: decoded.extent),
                          sourceX: sourceX, sourceY: sourceY, radius: radius)
    }

    /// One sample of the image the COLOUR stage receives — S3 through S8, the value
    /// `ColorEngine.apply` compares a global Point Colour swatch against (docs/23
    /// dossier queue item 5).
    ///
    /// The fourth tap, and like the third it is not a luxury. The global Point Colour
    /// eyedropper stored `sampleSceneLinear` through the linear matrix — post-S6 —
    /// while the engine compares after tone and presence, so a swatch picked on a
    /// photograph carrying any real tone move selected the wrong colour, and the
    /// error grew with the edit. Through `RenderGraph.colorStageInput`, the same
    /// expression the render uses, never a re-derivation.
    public func sampleColorStageInput(source: any ImageSource, recipe: Recipe,
                                      sourceX: Double, sourceY: Double,
                                      radius: Int = 2) -> RGB? {
        guard let decoded = source.decode(recipe: recipe, draft: false, scaleFactor: 1.0)
        else { return nil }
        Self.stampRenderIdentity(source)
        let plan = RenderPlan(recipe: recipe,
                              asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)
        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let staged = RenderGraph().colorStageInput(
            decoded, plan: plan,
            options: RenderGraph.Options(longEdge: longEdge, maskSource: true))
        return sampleMean(staged.cropped(to: decoded.extent),
                          sourceX: sourceX, sourceY: sourceY, radius: radius)
    }

    /// The mean of a small window about a normalized source coordinate, read back in
    /// the working space.
    private func sampleMean(_ image: CIImage, sourceX: Double, sourceY: Double,
                            radius: Int) -> RGB? {
        let extent = image.extent
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
            context.render(image, toBitmap: base, rowBytes: width * 16,
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
    ///
    /// CLAMPED at the edges, then cropped back (docs/31 round one §12). A Lanczos
    /// tap reaches three source pixels past the pixel it produces, and beyond the
    /// extent an unclamped image is transparent black — so the outermost rows of
    /// every resized export averaged real pixels with nothing and delivered a
    /// darkened, semi-transparent rim. `clampedToExtent` extends the edge pixels
    /// outward (the same fix `applyOutputSharpen` and every blur in `RenderGraph`
    /// already carry), and the crop pins the result to the geometry the unclamped
    /// filter would have produced, so callers see the same extent as before —
    /// with pixels in it.
    static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale > 0, abs(scale - 1) > 0.0001 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let out = filter.outputImage else { return image }
        let target = image.extent.applying(CGAffineTransform(scaleX: scale, y: scale))
        return out.cropped(to: target)
    }

    // MARK: - Output sharpening

    /// A stock `CIUnsharpMask` at the radius and energy `OutputSharpen` derives — and
    /// nothing more than that.
    ///
    /// Worth naming precisely, because `OutputSharpen.energy()` used to describe this
    /// function as applying an asymmetric dark:light halo weighting, and it does not. An
    /// unsharp mask halos symmetrically by construction: the same high-pass is added on
    /// both sides of an edge, so a light rim and a dark rim come out at equal amplitude.
    /// docs/11 asks for the asymmetry and it is not built; the claim has been removed
    /// from the place that made it rather than approximated here.
    ///
    /// What IS right and easy to break: this runs AFTER the resize, so the radius is in
    /// delivered pixels the way `baseRadius(printPPI:)` derives it, and the Lanczos
    /// resample before it runs in linear light. Both orderings are load-bearing and
    /// neither has a test that would notice if they moved — deleting this call entirely
    /// leaves every suite green (OUT-08).
    static func applyOutputSharpen(_ image: CIImage, _ sharpen: OutputSharpen,
                                   resolutionPPI: Double) -> CIImage {
        guard !sharpen.isIdentity else { return image }
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image.clampedToExtent()
        // `appliedRadius` IS the clamp — it lives on `OutputSharpen` so the export
        // sheet's readout prints this exact number instead of the unclamped formula.
        // A literal here and a different literal there is how the two would drift.
        filter.radius = Float(sharpen.appliedRadius(printPPI: resolutionPPI))
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

        // IT HAS TO FIT, and until now nothing checked. `sizePercent` is a fraction of the
        // LONG edge, so on a portrait frame it is a fraction of the height — a 27-character
        // notice at Size 5% on a 1365 × 2048 delivery rasterizes about 1600 points wide
        // against 1365 points of picture. The placement arithmetic below then produced a
        // negative x, and `composited(over:)` takes the UNION of the two extents, so the
        // file written was 1645 × 2048 with 280 points of transparent black down the left
        // edge — wrong dimensions on disk, and a black band in any format without alpha.
        // Every neighbouring stage bounds itself (`applyOutputSharpen` clamps and crops,
        // the grain and the dither are handed an explicit extent); this one did not.
        //
        // Scaled to fit rather than clipped, because a mark cropped in half is worse than
        // a mark a little smaller than asked for, and the slider's own top setting (20%)
        // overflows a landscape frame with a short name.
        //
        // A NEW NAME, not `var rendered = rendered`. Shadowing an immutable with a
        // mutable of the same name works for a parameter, which comes from an enclosing
        // scope; it is a redeclaration for a `let` in the SAME scope, and Swift refuses
        // it. Caught only on the macOS lane, because `LumenPipeline` needs CoreImage and
        // so type-checks nowhere else — the same blind spot `LumenApp` has.
        let available = Swift.max(extent.width - inset * 2, 1)
        let fitted: CIImage = rendered.extent.width > available
            ? rendered.transformed(by: CGAffineTransform(
                scaleX: available / rendered.extent.width,
                y: available / rendered.extent.width))
            : rendered

        let size = fitted.extent
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
        // PINNED INSIDE, then cropped back. The clamp covers the cases the shrink above
        // cannot — a mark taller than the frame, or a `.centre` placement on a frame
        // narrower than the inset allows — and the crop is the guarantee: whatever the
        // placement arithmetic produces, the file is the size the Size section promised.
        x = Swift.min(Swift.max(x, extent.minX), Swift.max(extent.maxX - size.width,
                                                           extent.minX))
        y = Swift.min(Swift.max(y, extent.minY), Swift.max(extent.maxY - size.height,
                                                           extent.minY))
        let placed = fitted.transformed(by: CGAffineTransform(translationX: x, y: y))
        return placed.composited(over: image).cropped(to: extent)
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
        Self.stampRenderIdentity(source)
        let plan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                              asShotTint: source.asShotTint,
                              captureISO: source.captureMetadata.iso,
                              softProof: softProof,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer)
                                  ? measuredBandMeanHues(source: source) : nil)
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
                                             aiMattes: mattes[source.url]?.planes ?? [:]))
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
/// `RenderPlan.toneGainCubeBaked` carries the tone gain — the stock colour-cube filter is
/// the only table the GPU can fetch, so a 1-D function borrows it. Size 64 rather than
/// the usual 33 because the function's whole point is the shadows, where sRGB's toe puts
/// an 8× change of code width inside what would otherwise be a single cell.
///
/// Static `let`s rather than a cache with a lock: there are four curves in play across
/// every destination Lumen writes, Swift builds each of these once and only when it is
/// first read, and an export that never leaves sRGB never bakes the other three.
///
/// Held as `ColorCube.Baked` — the table already in Core Image's bytes — and not as the
/// `LUT3D` it is baked from, which is what makes the `static let` mean anything. Baking
/// once and then handing the array to `ColorCube.filter` still copied 4 MB into a fresh
/// `Data` on the way to the GPU on every frame that dithered, and `renderPreview`
/// dithers every frame it shows. Same footprint as before, not double: the `[Float]` is
/// released as soon as the copy is taken.
enum DitherStepCube {

    static let srgb = ColorCube.Baked(cube(.srgb, levels: 256))
    static let gamma22 = ColorCube.Baked(cube(.gamma22, levels: 256))
    static let gamma18 = ColorCube.Baked(cube(.gamma18, levels: 256))
    static let rec709 = ColorCube.Baked(cube(.rec709, levels: 256))

    // The 10-bit set, for HEVC Main-10 HEIC deliveries. Its own `static let`s rather
    // than a keyed cache for the same reason as the row above: Swift bakes each lazily
    // on first read, so a session that never writes a 10-bit file never pays for these,
    // and the preview path (which dithers at 8) keeps the exact tables it had.
    static let srgb10 = ColorCube.Baked(cube(.srgb, levels: 1_024))
    static let gamma22At10 = ColorCube.Baked(cube(.gamma22, levels: 1_024))
    static let gamma18At10 = ColorCube.Baked(cube(.gamma18, levels: 1_024))
    static let rec709At10 = ColorCube.Baked(cube(.rec709, levels: 1_024))

    /// `levels` is `Dither.levels(bitDepth:)` for the depth being encoded — the table
    /// used to be baked for 256 codes regardless, which was the right amplitude for
    /// every file Lumen could write until the 10-bit HEIC path landed: on a 1024-code
    /// encode a 256-code offset is four codes of noise, not the half-code the ordered
    /// dither is specified to add.
    static func forTransfer(_ transfer: TransferFunction, levels: Int) -> ColorCube.Baked {
        if levels >= 1_024 {
            switch transfer {
            case .gamma22: return gamma22At10
            case .gamma18: return gamma18At10
            case .rec709: return rec709At10
            default: return srgb10
            }
        }
        switch transfer {
        case .gamma22: return gamma22
        case .gamma18: return gamma18
        case .rec709: return rec709
        default: return srgb
        }
    }

    private static func cube(_ transfer: TransferFunction, levels: Int) -> LUT3D {
        LUT3D(size: 64) { value in
            RGB(Dither.codeStep(value.r, transfer: transfer, levels: levels),
                Dither.codeStep(value.g, transfer: transfer, levels: levels),
                Dither.codeStep(value.b, transfer: transfer, levels: levels))
        }
    }
}

#endif
