// InspectionGain.swift
// What `[` and `]` actually do to the picture (docs/10 §10.5).
//
// The holds are a DISPLAY transform, not an edit. `InspectionHolds.gain` says how much
// light to multiply by; this applies it to the proxy already on screen and hands back
// another image to draw. Nothing here touches a `Recipe`, nothing is persisted, and
// releasing the key draws the untouched image again — which is the whole difference
// between an inspection and the "drag Shadows, look, drag it back" ritual it replaces.
//
// Linear light, and it matters. The displayed proxy is sRGB-encoded; multiplying its
// code values would lift the shadows by the wrong amount and shift hue while doing it.
// `CIExposureAdjust` is a linear-light multiply, and Core Image converts into and out
// of its linear working space around it, so the gain lands where an exposure move
// belongs. On a Lumen-rendered proxy that makes the boost exact; on a frame that fell
// back to the camera's embedded preview it is approximate for the same reason
// everything else about that frame is, and the viewer already carries the EMBEDDED
// PREVIEW badge that says so.
//
// One entry of memo, because the gain is applied inside a view body and the body runs
// far more often than the key changes. Key-down transforms once; every redraw after it
// hits the cache; key-up drops it.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import LumenCore

@MainActor
enum InspectionGain {

    private static let context: CIContext = CIContext()
    private static var cachedSource: CGImage?
    private static var cachedHold: InspectionHold?
    private static var cachedResult: CGImage?

    /// The image to draw for a given hold. Nil hold, or a transform that fails, draws
    /// the original — an inspection that cannot be computed shows the picture as it is
    /// rather than nothing at all.
    static func displayed(_ image: CGImage, hold: InspectionHold?) -> CGImage {
        guard let hold else { return image }
        if let cachedResult, cachedHold == hold, let cachedSource, cachedSource === image {
            return cachedResult
        }
        guard let adjusted = apply(hold, to: image) else { return image }
        cachedSource = image
        cachedHold = hold
        cachedResult = adjusted
        return adjusted
    }

    private static func apply(_ hold: InspectionHold, to image: CGImage) -> CGImage? {
        // The EV comes from the rule, sign included, so this file cannot lift the
        // shadows when the user asked to inspect the highlights.
        let ev: Double = InspectionHolds.ev(hold)
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: ev), forKey: kCIInputEVKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: input.extent)
    }
}

#endif
