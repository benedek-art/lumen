// PipelineRenderer.swift
// Phase-1 render path: one pure function of (file, recipe, target) → image, used by
// BOTH the loupe and the export (no separate preview pipeline to drift — docs/13).
// The Lumen stage chain (docs/14 S6+) grows downstream of the Apple stage from
// Phase 3; today the graph is: AppleRawSource → crop/straighten → output.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore

public struct ExportSettings: Sendable {
    public var jpegQuality: Double      // 0…1
    public var maxLongEdge: Int?        // nil = full size
    public init(jpegQuality: Double = 0.9, maxLongEdge: Int? = nil) {
        self.jpegQuality = jpegQuality
        self.maxLongEdge = maxLongEdge
    }
}

public enum RenderError: Error {
    case decodeFailed
    case renderFailed
    case writeFailed(URL)
}

public final class PipelineRenderer {

    private let context: CIContext

    public init() {
        // Working format per docs/14 precision policy: half-float linear working space,
        // sRGB only at the very end (output transform is Phase 3's job).
        self.context = CIContext(options: [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ])
    }

    /// Render for display at a bounded size. Draft decode keeps sliders interactive;
    /// the full-quality pass re-renders when interaction settles (docs/12 latency ladder).
    public func renderPreview(source: AppleRawSource, recipe: Recipe,
                              maxLongEdge: Int, draft: Bool) throws -> CGImage {
        guard var image = source.decode(recipe: recipe, draft: draft) else {
            throw RenderError.decodeFailed
        }
        image = Self.applyGeometry(image, recipe: recipe)
        image = Self.downscale(image, maxLongEdge: maxLongEdge)
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw RenderError.renderFailed
        }
        return cg
    }

    /// Export to JPEG. Same graph as the preview, full quality, color-managed to sRGB.
    public func exportJPEG(source: AppleRawSource, recipe: Recipe,
                           to destination: URL, settings: ExportSettings) throws {
        guard var image = source.decode(recipe: recipe, draft: false) else {
            throw RenderError.decodeFailed
        }
        image = Self.applyGeometry(image, recipe: recipe)
        if let maxEdge = settings.maxLongEdge {
            image = Self.downscale(image, maxLongEdge: maxEdge)
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RenderError.renderFailed
        }
        do {
            let qualityKey = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String)
            try context.writeJPEGRepresentation(
                of: image, to: destination, colorSpace: srgb,
                options: [qualityKey: settings.jpegQuality])
        } catch {
            throw RenderError.writeFailed(destination)
        }
    }

    // MARK: - Stages

    /// Crop + straighten (docs/14 S16: geometry last, sampled once).
    static func applyGeometry(_ image: CIImage, recipe: Recipe) -> CIImage {
        var out = image
        let geo = recipe.develop.geometry

        if geo.angle != 0 {
            let radians = -geo.angle * .pi / 180
            out = out.transformed(by: CGAffineTransform(rotationAngle: radians))
        }
        if geo.flipH {
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }

        let crop = geo.crop
        if crop.x != 0 || crop.y != 0 || crop.w != 1 || crop.h != 1 {
            // Recipe crop is top-left-origin (image convention); Core Image extents
            // are bottom-up — flip the y term. (Review finding; a unit test guards
            // this once the crop UI lands in Phase 3.)
            let e = out.extent
            let rect = CGRect(x: e.origin.x + crop.x * e.width,
                              y: e.origin.y + (1 - crop.y - crop.h) * e.height,
                              width: crop.w * e.width,
                              height: crop.h * e.height)
            out = out.cropped(to: rect.intersection(e))
        }
        return out.transformed(by: CGAffineTransform(
            translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    static func downscale(_ image: CIImage, maxLongEdge: Int) -> CIImage {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > CGFloat(maxLongEdge), longEdge > 0 else { return image }
        let scale = CGFloat(maxLongEdge) / longEdge
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return lanczos.outputImage ?? image
    }
}

#endif
