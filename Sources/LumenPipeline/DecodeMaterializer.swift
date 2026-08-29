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

    /// Above this, leave the decode lazy.
    ///
    /// An export decodes at full resolution, uses the result once, and would gain
    /// nothing from being held; at 60 MP the buffer would be half a gigabyte. Every
    /// INTERACTIVE size is at or below this — the viewer's settle, every rung of
    /// `DraftLadder`, the mask raster, the 512 px probes — which is the whole working
    /// set that repeats.
    ///
    /// IT SAID 3072 AND THE CLAIM ABOVE WAS FALSE. `DraftLadder.rungs[0]` and
    /// `LoupeView.maxRenderLongEdge` are both 4096, and at any zoom the viewer asks for
    /// exactly that — so the settle, the one render that repeats most and matters most,
    /// sat just above this line. `AppleRawSource` then cached the lazy
    /// `CIRAWFilter.outputImage` (`let stored = materialized(image) ?? (image, 0)`),
    /// which is the INTENTION to decode rather than its pixels, and every hit paid a
    /// full RAW demosaic again. That is verbatim the defect this type exists to fix,
    /// left live for the sizes it was written for. Measured on the owner's machine:
    /// `draft 8.5 ms @2048` against `settle 312.7 ms @4096`, and the same file's own
    /// history records an unmaterialized decode at 457 ms.
    ///
    /// Reading the ladder's own ceiling rather than restating it is the fix, not the
    /// number: two independent constants for one quantity is what produced a cliff
    /// nobody could see from either side of it.
    static let longEdgeLimit = DraftLadder.interactiveLongEdgeCeiling

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

    /// `image`'s pixels and what they weigh, or nil if it should stay lazy.
    ///
    /// Returning nil is never an error: a decode that cannot be materialized is still a
    /// correct decode, just an expensive one, and the caller keeps the lazy image.
    static func materialize(_ image: CIImage) -> (image: CIImage, bytes: Int)? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1,
              Swift.max(extent.width, extent.height) <= CGFloat(longEdgeLimit),
              let working = workingSpace
        else { return nil }

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

        context.render(image, to: buffer, bounds: extent, colorSpace: working)
        // Named explicitly on the way back in too, or Core Image assumes sRGB for a
        // pixel buffer and every value is re-interpreted through the wrong transfer
        // function — a silent colour shift on every photograph in the app.
        let out = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: working])
        // 8 bytes a pixel: four half-float channels.
        let bytes = width * height * 8
        // The buffer starts at the origin; the decode's extent may not. Put the pixels
        // back where the caller's geometry expects to find them.
        guard extent.origin != .zero else { return (out, bytes) }
        return (out.transformed(by: CGAffineTransform(translationX: extent.origin.x,
                                                     y: extent.origin.y)),
                bytes)
    }
}

#endif
