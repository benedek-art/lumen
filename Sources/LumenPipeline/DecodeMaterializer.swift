// DecodeMaterializer.swift
// Turning a decode's PROMISE into a decode's PIXELS.
//
// `AppleRawSource` caches what `CIRAWFilter.outputImage` returns, and that is a lazy
// `CIImage`: a description of a decode rather than the result of one. Caching it caches
// the intention, so every render that consumed a cache "hit" re-ran the whole demosaic.
// Measured in the app on a 33 MP file, that was 457 ms per drag frame against a settle
// at a LARGER size costing 14.5 ms — thirty times slower for fewer pixels, which is the
// signature of a demosaic running where none should.
//
// This file exists SEPARATELY from that one so the part that can go silently wrong can
// be tested without a camera RAW.
//
// Every eligible decode crosses this same precision boundary on its FIRST use.
// A lazy first native image and a half-float cached image are not interchangeable:
// hosted public RAWs reproduced history-dependent pixels even with denoise Off.
// Deterministically oversized legacy decodes remain lazy for their entire cache
// lifetime. An eligible allocation/render failure instead returns nil for retry.
// RAW9 always requires its existing explicit colour-evaluation boundary.
//
// WHAT CAN GO SILENTLY WRONG. The whole contract of the RAW stage is that what leaves it
// is scene-referred and keeps the headroom above display white — Apple's picture-forming
// stages are switched off precisely so that a 4.0 in a specular highlight survives to
// the display transform. Materializing through any 8-bit surface, or through a
// non-extended colour space, clamps that to 1.0. Nothing downstream would fail; the
// goldens use a stub source and never touch this path; the picture would simply lose its
// highlights on every photograph, and the loss would look like the photograph.
//
// So: half-float RGBA, in the extended linear working space, named explicitly on the way
// out AND on the way back in. `MaterializedDecodeTests` writes values above 1.0 and
// below 0.0 through this and reads them back.

#if os(macOS)

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import LumenCore

enum DecodeMaterializer {

    enum EvaluationSpace {
        case pipeline
        /// RAW9 must be evaluated here, then converted into the pipeline space.
        /// This is a colour-correctness boundary, not merely a cache optimization.
        case raw9LinearSRGB
    }

    /// Existing long-edge cap, unchanged. Byte admission is bounded separately by
    /// DraftLadder.materializedDecodeByteCeiling (512 MiB). Oversized legacy
    /// graphs remain lazy; RAW9 cannot bypass its required colour boundary.
    static let longEdgeLimit = DraftLadder.inspectionLongEdgeCeiling

    /// Half-float RGBA — four channels at two bytes. Named rather than spelled `8` at
    /// the two places that need it, since the byte ceiling below is only meaningful if
    /// it is denominated in the format actually allocated.
    static let bytesPerPixel = 8

    /// The working space every stage of this pipeline agrees on. Extended and linear:
    /// extended so values above display white survive, linear so no transfer function
    /// is applied on the way through.
    static var workingSpace: CGColorSpace? {
        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
    }

    /// One context, because materializing is the only thing it does.
    ///
    /// `cacheIntermediates` is off deliberately: each render here materializes a
    /// different key exactly once, so an intermediate cache would hold megabytes that
    /// are never read again. That is also the setting whose ABSENCE on the main render
    /// context was masking this bug — a 33 MP RGBAh intermediate is about 260 MB, far
    /// past what any cache holds, so it was evicted and recomputed every frame.
    static let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let working = workingSpace {
            options[.workingColorSpace] = working
            options[.outputColorSpace] = working
        }
        return CIContext(options: options)
    }()

    /// RAW9/custom-wide-working-space decoding is not colour-correct on the
    /// qualification OS/corpus. Evaluate its graph in extended-linear sRGB; render
    /// to the same extended-linear Rec2020 buffer/tag used by every other decoder.
    /// Float intermediates match the independent platform oracle. Only the final
    /// cache plane is half-float, preserving signed values and highlight headroom.
    private static let raw9Context: CIContext? = {
        guard let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else { return nil }
        return CIContext(options: [
            .workingColorSpace: linearSRGB,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
        ])
    }()

    typealias Plane = (image: CIImage, bytes: Int)
    typealias Materializer = (CIImage, EvaluationSpace) -> Plane?

    /// Shared deterministic admission check. Refusal here must not be confused
    /// with a transient allocation/GPU failure after an image was admitted.
    static func isEligible(_ image: CIImage) -> Bool {
        let extent = image.extent
        guard !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1,
              Swift.max(extent.width, extent.height) <= CGFloat(longEdgeLimit)
        else { return false }
        return DraftLadder.mayHoldAsPixels(width: Int(extent.width.rounded()),
            height: Int(extent.height.rounded()), bytesPerPixel: bytesPerPixel)
    }

    /// A required RAW9 boundary can never fall back to a lazy image. Legacy images
    /// too large for the existing caps keep their old lazy availability; all others
    /// either return canonical pixels or fail without publishing alternate pixels.
    static func prepareForCache(_ image: CIImage, evaluatingIn evaluation: EvaluationSpace,
                                materializer: Materializer) -> Plane? {
        let extent = image.extent
        guard !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { return nil }
        guard isEligible(image) else {
            switch evaluation {
            case .pipeline: return (image, 0)
            case .raw9LinearSRGB: return nil
            }
        }
        return materializer(image, evaluation)
    }

    /// `image`'s pixels and what they weigh, or nil when the boundary cannot be made.
    ///
    /// Nil alone does not classify a refusal: prepareForCache separates deterministic
    /// oversize from eligible allocation/render failure before calling this method.
    /// A RAW9 caller must always fail closed when its boundary cannot be established.
    static func materialize(_ image: CIImage, evaluatingIn evaluation: EvaluationSpace = .pipeline)
        -> (image: CIImage, bytes: Int)? {
        let renderContext: CIContext
        switch evaluation {
        case .pipeline: renderContext = context
        case .raw9LinearSRGB:
            guard let raw9Context else { return nil }
            renderContext = raw9Context
        }
        guard isEligible(image), let working = workingSpace else { return nil }
        let extent = image.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            // IOSurface-backed, so the buffer stays on the GPU and the graph that reads
            // it does not pay a CPU round trip for the privilege of not re-decoding.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_64RGBAHalf,
                                  attributes as CFDictionary,
                                  &created) == kCVReturnSuccess,
              let buffer = created
        else { return nil }

        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = working
        destination.isClamped = false
        do {
            // `from` is in source coordinates; `at` is in the zero-origin buffer.
            // Passing a nonzero source extent as the buffer's render bounds kept
            // the metadata but wrote no pixels when that rectangle missed it.
            let task = try renderContext.startTask(toRender: image, from: extent,
                                                   to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch {
            // A required colour boundary is not established by a failed GPU task.
            return nil
        }
        // Named explicitly on the way back in too, or Core Image assumes sRGB for a
        // pixel buffer and every value is re-interpreted through the wrong transfer
        // function — a silent colour shift on every photograph in the app.
        let out = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: working])
        // Four half-float channels — the same figure the byte ceiling above is
        // denominated in, so the guard and the accounting cannot drift apart.
        let bytes = width * height * bytesPerPixel
        // The buffer starts at the origin; the decode's extent may not. Put the pixels
        // back where the caller's geometry expects to find them.
        guard extent.origin != .zero else { return (out, bytes) }
        return (out.transformed(by: CGAffineTransform(translationX: extent.origin.x,
                                                     y: extent.origin.y)),
                bytes)
    }
}

#endif
