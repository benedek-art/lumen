// VisionMattes.swift
// Subject, Background and People masks from Apple's Vision framework (docs/08 §8.3,
// §8.8): on-device, no model download, no bundled weights, no licence ledger to clear.
//
// Three decisions this file makes, all of them from the spec:
//
//   · BACKGROUND IS THE COMPLEMENT of the subject, not a second model. docs/08 §8.3
//     is explicit that a separate background model can disagree with the subject one,
//     which is where LR's "subtract Entire Person from Background when Background
//     fails" folklore comes from. One request serves both.
//   · THE SEGMENTER SEES A NEUTRAL RENDITION of the file, never the user's edit. If it
//     saw the edit, the mask would move every time the exposure did, and every slider
//     drag would invalidate a cache that costs a second to refill.
//   · IT NEVER RUNS ON THE RENDER PATH. `VisionMatteWorker` is its own actor, so the
//     render coordinator suspends rather than blocks while a matte is computed — the
//     §8.7 contract, and the one thing LrC's masking is most criticised for.
//
// Coordinates: the request is handed a CGImage, whose row 0 is the top of the picture,
// and Vision returns a mask buffer in the same orientation. `Plane` is row-major from
// the top too, and `MaskRaster` normalizes against the source frame — so a matte
// generated from the SOURCE frame (uncropped, unrotated) lines up with the mask
// rasterizer's coordinate space by construction. Nothing here flips anything, and
// nothing here should have to.

#if os(macOS)

import CoreGraphics
import CoreVideo
import Foundation
import LumenCore
import Vision

/// The mask work queue of docs/08 §8.7, in its smallest honest form: one actor that is
/// not the render actor, so a segmentation never occupies the thing drawing frames.
public actor VisionMatteWorker {

    public static let shared = VisionMatteWorker()

    public init() {}

    /// Every matte Vision can supply for `kinds`, keyed by `MaskKind.rawValue` — the
    /// keys `MaskRaster.combine(aiMattes:)` looks for.
    public func mattes(image: CGImage, kinds: Set<MaskKind>) -> [String: Plane] {
        VisionMattes.generate(image: image, kinds: kinds)
    }
}

public enum VisionMattes {

    /// Recorded into `MaskComponent.model` so a recipe says what produced its matte,
    /// and so a future model's mattes are distinguishable from these.
    public static let identifier = "apple.vision/1"

    /// The kinds in a recipe that Vision can serve. Empty is the common case and the
    /// caller's fast exit.
    ///
    /// The walk is `MaskDependency.contributing`, not `recipe.masks where enabled`, and
    /// that is finding F5-01. A mask can reference another through a `.maskRef`
    /// component, and switching the referenced mask off — which is what you do
    /// constantly, to see what a mask is doing — used to drop it from this roster. Its
    /// matte was then never generated, so the mask built ON it had nothing to intersect
    /// and rendered as nothing: no selection in the loupe, and the same absence written
    /// into the exported file, because both reach this through
    /// `RenderCoordinator.missingMatteKinds`.
    ///
    /// Disabling a mask removes its own contribution. It does not delete its geometry
    /// out from under something that points at it.
    ///
    /// NOT by dropping the filter, which is the cheap fix and the wrong one: that asks
    /// Vision for a matte belonging to a switched-off mask nobody references, which
    /// records an attempted pass for a request the recipe never needed — and
    /// `AppState.matteStatus` turns attempted-and-absent into `.notFound`, so the panel
    /// would report "Vision found no clear subject" about a mask that is simply off.
    /// Reachability, not removal.
    public static func kinds(in recipe: Recipe) -> Set<MaskKind> {
        MaskDependency.wantedMattes(in: recipe, from: .vision)
    }

    /// Generate the requested mattes. Returns only what was actually produced: a
    /// missing key is "nothing found", which `MaskRaster` already renders as an empty
    /// mask, and the panel reports as "no subject found" rather than as an error.
    ///
    /// Deliberately total — a Vision failure is a mask that selects nothing, never a
    /// thrown error that takes a render down with it.
    public static func generate(image: CGImage, kinds: Set<MaskKind>) -> [String: Plane] {
        guard !kinds.isEmpty else { return [:] }
        var out: [String: Plane] = [:]

        let wantsForeground = kinds.contains(.aiSubject) || kinds.contains(.aiBackground)
        if wantsForeground, let subject = foregroundPlane(image: image) {
            if kinds.contains(.aiSubject) {
                out[MaskKind.aiSubject.rawValue] = subject
            }
            if kinds.contains(.aiBackground) {
                // The complement, by construction.
                out[MaskKind.aiBackground.rawValue] = subject.map { 1 - Num.saturate($0) }
            }
        }

        if kinds.contains(.aiPerson), let people = personPlane(image: image) {
            out[MaskKind.aiPerson.rawValue] = people
        }
        return out
    }

    // MARK: - The two requests

    /// `VNGenerateForegroundInstanceMaskRequest` (macOS 14+): every foreground
    /// instance, unioned into one matte. Instance CHIPS — pick one subject of several —
    /// are a component field the wire format does not have, so all instances are taken
    /// rather than an arbitrary one being guessed at.
    static func foregroundPlane(image: CGImage) -> Plane? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // The conditional cast is deliberate even though the request types its own
        // results: it costs a "cast always succeeds" warning at worst, and this file
        // cannot be compiled on the machine it was written on.
        guard let observation = request.results?.first as? VNInstanceMaskObservation
        else { return nil }
        let instances = observation.allInstances
        guard !instances.isEmpty else { return nil }
        guard let buffer = try? observation.generateScaledMaskForImage(
            forInstances: instances, from: handler) else { return nil }
        return plane(from: buffer)
    }

    /// `VNGeneratePersonSegmentationRequest`: one matte covering every person in the
    /// frame. Per-person chips and the nine parts need a face-landmark pass and a
    /// per-person matte the format cannot yet express, so this is Entire Person for
    /// everyone in shot — which is what the component's default part is.
    static func personPlane(image: CGImage) -> Plane? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGeneratePersonSegmentationRequest()
        // The mask is cached and reused across every render of this photo, so the
        // accurate level's extra time is paid once and never on a frame.
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNPixelBufferObservation
        else { return nil }
        return plane(from: observation.pixelBuffer)
    }

    // MARK: - Pixel buffer to plane

    /// One-component 8-bit or 32-bit-float buffers, the two formats these requests
    /// produce. Row 0 is the top in both, which is `Plane`'s convention too.
    static func plane(from buffer: CVPixelBuffer) -> Plane? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isFloat = format == kCVPixelFormatType_OneComponent32Float
        guard isFloat || format == kCVPixelFormatType_OneComponent8 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * (isFloat ? 4 : 1) else { return nil }

        var out = Plane(width: width, height: height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            if isFloat {
                let pixels = row.assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    out[x, y] = Num.saturate(Double(pixels[x]))
                }
            } else {
                let pixels = row.assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    out[x, y] = Double(pixels[x]) / 255
                }
            }
        }
        return out
    }
}

#endif
