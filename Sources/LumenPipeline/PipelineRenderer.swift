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

    /// True when the GPU path is intact. False means kernels failed to compile and the
    /// renderer is producing a reduced result the UI must label.
    public var isGPUPathAvailable: Bool { KernelLibrary.coreAvailable }

    public var unavailableKernels: [String] { KernelLibrary.unavailableKernels }

    // MARK: - Preview

    public func renderPreview(source: AppleRawSource, recipe: Recipe,
                              maxLongEdge: Int, draft: Bool,
                              strokeSets: [String: BrushStrokeSet] = [:]) throws -> CGImage {
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
                              lutSize: draft ? 17 : LUT3D.interactiveSize)
        let graph = makeGraph(plan: plan, decoded: decoded, draft: draft,
                              strokeSets: strokeSets)
        var image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: longEdge,
                                                             draft: draft))
        image = Self.applyGeometry(image, recipe: recipe, scaleTo: maxLongEdge)

        guard let cgImage = context.createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw RenderError.renderFailed
        }
        return cgImage
    }

    // MARK: - Export

    public func export(source: AppleRawSource, recipe: Recipe, to destination: URL,
                       using exportRecipe: ExportRecipe,
                       strokeSets: [String: BrushStrokeSet] = [:]) throws {
        guard let decoded = source.decode(recipe: recipe, draft: false) else {
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
                              lutSize: LUT3D.exportSize)

        let graph = makeGraph(plan: plan, decoded: decoded, draft: false,
                              strokeSets: strokeSets)
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
        image = Self.applyOutputSharpen(image, exportRecipe.sharpen,
                                        resolutionPPI: exportRecipe.resolutionPPI)
        if let watermark = exportRecipe.watermark, !watermark.text.isEmpty {
            image = Self.applyWatermark(image, watermark)
        }

        try write(image, to: destination, using: exportRecipe)
    }

    /// Render the SDR base and the HDR rendition off one shared graph, then derive the
    /// gain map from the pair (docs/14 §7: render twice at two peaks, cheaply).
    public func renderHDRPair(source: AppleRawSource, recipe: Recipe,
                              settings: HDRSettings,
                              strokeSets: [String: BrushStrokeSet] = [:])
        throws -> (sdr: CIImage, hdr: CIImage) {
        guard let decoded = source.decode(recipe: recipe, draft: false) else {
            throw RenderError.decodeFailed
        }
        let longEdge = Int(Swift.max(decoded.extent.width, decoded.extent.height))
        let options = RenderGraph.Options(longEdge: longEdge, draft: false,
                                          lutSize: LUT3D.exportSize)

        let sdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: 100, lutSize: LUT3D.exportSize)
        let hdrPlan = RenderPlan(recipe: recipe, asShotKelvin: source.asShotTemperature,
                                 asShotTint: source.asShotTint,
                                 displayWhiteTarget: settings.whiteTargetPercent,
                                 lutSize: LUT3D.exportSize)

        let sdrGraph = makeGraph(plan: sdrPlan, decoded: decoded, draft: false,
                                 strokeSets: strokeSets)
        let hdrGraph = makeGraph(plan: hdrPlan, decoded: decoded, draft: false,
                                 strokeSets: strokeSets)
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
    private func makeGraph(plan: RenderPlan, decoded: CIImage, draft: Bool,
                           strokeSets: [String: BrushStrokeSet]) -> RenderGraph {
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
                                    width: width, height: height, extent: extent)

            for mask in plan.masks {
                let alpha = MaskRaster.combine(mask: mask,
                                               size: (width: width, height: height),
                                               source: source,
                                               strokeSets: strokeSets,
                                               aiMattes: [:])
                guard let image = Self.image(from: alpha, targetExtent: extent) else {
                    continue
                }
                graph.maskImages[mask.id] = image
            }
        }

        if let film = plan.filmChain, film.grainAmount > 0 {
            graph.grainPlate = Self.grainPlate(film: film, extent: extent)
        }
        return graph
    }

    /// The local-stage input, at mask-raster resolution, as an `ImageBuffer`.
    ///
    /// Returns nil when no mask component actually reads the picture, because then this
    /// is a whole extra render pass bought for nothing: a Linear or Radial gradient is
    /// pure geometry and a brush is pure geometry plus its stroke set.
    private func maskSource(decoded: CIImage, plan: RenderPlan,
                            width: Int, height: Int, extent: CGRect) -> ImageBuffer? {
        let needsPicture = plan.masks.contains { mask in
            mask.components.contains { $0.kind.readsSourceImage }
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
    static let maskRasterLongEdge: Int = 1024

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
    static func grainPlate(film: FilmChain, extent: CGRect) -> CIImage? {
        let size = 128
        let plate = FilmGrainProfile.plate(size: size, seed: 0x5DEECE66D, sigma: 1)
        var pixels = [Float](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) {
            // No `saturate`: the texture is RGBAf and the clamp was flattening the
            // 3.4% of the plate beyond ±2σ — precisely the strongest grains.
            let v = Float(Double(plate[i]) / FilmGrainProfile.plateEncodeScale + 0.5)
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let tile = CIImage(bitmapData: data, bytesPerRow: size * 16,
                           size: CGSize(width: size, height: size),
                           format: .RGBAf, colorSpace: nil)
        let long = Int(Swift.max(extent.width, extent.height))
        let scale = film.grain.plateScale(longEdgePixels: long,
                                          printSizeInches: film.printLongEdgeInches)
        let scaled = tile.transformed(by: CGAffineTransform(scaleX: CGFloat(Swift.max(scale, 0.5)),
                                                            y: CGFloat(Swift.max(scale, 0.5))))
        let tiler = CIFilter.affineTile()
        tiler.inputImage = scaled
        tiler.transform = .identity
        return (tiler.outputImage ?? scaled).cropped(to: extent)
    }

    // MARK: - Geometry (S16)

    /// Crop, straighten, flip AND the output scale compose into ONE transform and ONE
    /// resample. Two resamples are two low-pass filters, which is a blur nobody asked
    /// for (docs/14 §5.8).
    ///
    /// The crop is expressed on the STRAIGHTENED frame, not on the rotated bounding
    /// box: dragging a crop rectangle and then straightening must not slide the
    /// rectangle across the picture.
    /// `allowUpscale` exists because `scale` was `min(1, …)` unconditionally, which
    /// made `ExportRecipe.allowUpscale` dead: `targetSize` correctly returned an
    /// enlarged size and this then refused to reach it. Unticking "Don't enlarge" and
    /// asking for an 8000 px long edge from a 24 MP file wrote 4000 px, with nothing
    /// said. A preview never wants enlargement, so the clamp stays the default.
    static func applyGeometry(_ image: CIImage, recipe: Recipe,
                              scaleTo maxLongEdge: Int? = nil,
                              allowUpscale: Bool = false) -> CIImage {
        let geo = recipe.develop.geometry
        var out = image

        var orientation = CGAffineTransform.identity
        if geo.flipH { orientation = orientation.scaledBy(x: -1, y: 1) }
        if geo.angle != 0 { orientation = orientation.rotated(by: -geo.angle * .pi / 180) }

        // Work out the crop rectangle on the straightened frame first.
        let straightened = orientation.isIdentity
            ? out.extent
            : out.extent.applying(orientation)
        var target = straightened
        let crop = geo.crop
        if crop.x != 0 || crop.y != 0 || crop.w != 1 || crop.h != 1,
           straightened.width > 0, straightened.height > 0 {
            // Recipe crop is top-left-origin (image convention); Core Image extents are
            // bottom-up, so the y term flips.
            target = CGRect(x: straightened.origin.x + crop.x * straightened.width,
                            y: straightened.origin.y
                                + (1 - crop.y - crop.h) * straightened.height,
                            width: crop.w * straightened.width,
                            height: crop.h * straightened.height)
        }

        // Fold the output scale into the same transform, so there is one resample.
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
    public func renderReference(source: AppleRawSource, recipe: Recipe,
                                maxLongEdge: Int) throws -> CGImage {
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
                              asShotTint: source.asShotTint)
        let rendered = ReferenceRenderer.render(buffer, plan: plan)
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

#endif
