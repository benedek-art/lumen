// RenderCoordinator.swift
// The one place pipeline work is allowed to happen (docs/13 §3). The main actor hands
// it a recipe version and gets a frame back; it decodes, renders, coalesces and
// cancels. Nothing here touches SwiftUI, and nothing in SwiftUI touches Core Image.
//
// Coalescing is the whole trick behind a slider that keeps up with a hand: while a
// drag is producing recipe versions faster than frames can be made, only the newest
// one is rendered and every superseded request is dropped on arrival rather than
// rendered and thrown away.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import LumenCore
import LumenPipeline

struct RenderResult: @unchecked Sendable {
    let image: CGImage
    let generation: UInt64
    let isDraft: Bool
    /// True when the RAW stage refused the file and this is the embedded preview.
    /// The UI must say so — a preview shown as if it were the edit is a lie.
    let usedEmbeddedPreview: Bool
    let note: String?
}

actor RenderCoordinator {

    private let renderer = PipelineRenderer()
    private var sources: [URL: any ImageSource] = [:]
    private var latestGeneration: UInt64 = 0

    /// Bounded so a fast scroll through a folder cannot pin a hundred decoded RAWs in
    /// memory at once; the eviction is safe because a source is recreatable.
    private static let sourceCacheLimit = 12
    private var sourceOrder: [URL] = []

    /// A render that takes part in coalescing: it claims the newest ticket, and any
    /// request holding an older one is dropped wherever it happens to be.
    ///
    /// `generation` must be a real ticket from `RenderGeneration.next()`. A sentinel
    /// like `.max` would latch `latestGeneration` at the ceiling and every subsequent
    /// request would compare as stale — one poisoned call and the viewer never updates
    /// again. Work that must not participate goes through `renderOneShot` instead.
    func render(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                generation: UInt64,
                strokeSets: [String: BrushStrokeSet] = [:]) async -> RenderResult? {
        latestGeneration = max(latestGeneration, generation)
        // Drop work that is already stale before paying for a decode.
        guard generation >= latestGeneration else { return nil }
        return await produce(url: url, recipe: recipe, maxLongEdge: maxLongEdge,
                             draft: draft, generation: generation, coalesced: true,
                             strokeSets: strokeSets)
    }

    /// A render nobody else is waiting on — the scope proxy, the Auto-tone probe. It
    /// neither claims a ticket nor yields to one: the caller has its own supersede
    /// check, and letting these touch `latestGeneration` would have them cancelling
    /// the viewer's frames (or, with a sentinel, all of them forever).
    func renderOneShot(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                       strokeSets: [String: BrushStrokeSet] = [:]) async -> RenderResult? {
        await produce(url: url, recipe: recipe, maxLongEdge: maxLongEdge,
                      draft: draft, generation: 0, coalesced: false,
                      strokeSets: strokeSets)
    }

    private func produce(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                         generation: UInt64, coalesced: Bool,
                         strokeSets: [String: BrushStrokeSet]) async -> RenderResult? {
        func stale() -> Bool { coalesced && generation < latestGeneration }

        do {
            let source = try self.source(for: url)
            guard !stale() else { return nil }

            // The fallback the kernel header promises, actually taken.
            //
            // This used to render through the graph unconditionally and then ATTACH a
            // "CPU fallback" note to the GPU's own output — so when the core kernels
            // were missing the user got a wrong picture with a label claiming it came
            // from the reference path. `renderReference` existed the whole time and had
            // no caller. Without `logEncode` in particular the graph cannot form a
            // picture at all: S9/S10 is skipped, picture formation is skipped, and even
            // the fallback tone curve needs it — the output is scene-referred data
            // presented as a photograph.
            let image: CGImage
            let note: String?
            if KernelLibrary.coreAvailable {
                image = try renderer.renderPreview(source: source, recipe: recipe,
                                                   maxLongEdge: maxLongEdge, draft: draft,
                                                   strokeSets: strokeSets)
                // Core kernels present but something else missing: the picture is real,
                // and some stage of it silently did nothing. Say which.
                let missing = KernelLibrary.unavailableKernels
                note = missing.isEmpty
                    ? nil
                    : "Reduced — \(missing.count) GPU "
                        + (missing.count == 1 ? "kernel" : "kernels")
                        + " unavailable: " + missing.joined(separator: ", ")
            } else {
                image = try renderer.renderReference(source: source, recipe: recipe,
                                                     maxLongEdge: maxLongEdge,
                                                     strokeSets: strokeSets)
                note = "CPU fallback — GPU kernels unavailable"
            }

            guard !stale() else { return nil }
            return RenderResult(image: image, generation: generation, isDraft: draft,
                                usedEmbeddedPreview: false,
                                note: note)
        } catch {
            // Never leave the viewer empty: fall back to the embedded preview and
            // label it honestly.
            if let preview = Self.embeddedPreview(url: url, maxLongEdge: maxLongEdge) {
                return RenderResult(image: preview, generation: generation, isDraft: true,
                                    usedEmbeddedPreview: true,
                                    note: "Embedded preview — \(Self.describe(error))")
            }
            return nil
        }
    }

    /// Render at full resolution for export. Never coalesced: an export is a promise.
    func renderFullSize(url: URL, recipe: Recipe,
                        strokeSets: [String: BrushStrokeSet] = [:]) throws -> CGImage {
        let source = try self.source(for: url)
        return try renderer.renderPreview(source: source, recipe: recipe,
                                          maxLongEdge: Int(source.nativeLongEdge),
                                          draft: false, strokeSets: strokeSets)
    }

    func export(url: URL, recipe: Recipe, to destination: URL,
                exportRecipe: ExportRecipe,
                strokeSets: [String: BrushStrokeSet] = [:]) throws {
        let source = try self.source(for: url)
        try renderer.export(source: source, recipe: recipe, to: destination,
                            using: exportRecipe, strokeSets: strokeSets)
    }

    /// One mask's alpha, for the loupe's overlay. Small by construction — the raster is
    /// capped at 1024 px — so it does not claim a render ticket.
    func maskAlpha(url: URL, recipe: Recipe, maskID: String,
                   strokeSets: [String: BrushStrokeSet]) -> CGImage? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.renderMaskAlpha(source: source, recipe: recipe,
                                        maskID: maskID, strokeSets: strokeSets)
    }

    func nativeSize(for url: URL) -> (width: Int, height: Int)? {
        guard let source = try? self.source(for: url) else { return nil }
        return source.nativePixelSize
    }

    func invalidate(url: URL) {
        sources.removeValue(forKey: url)
        sourceOrder.removeAll { $0 == url }
    }

    /// One scene-linear sample, for the eyedroppers.
    ///
    /// Lives on the actor because the decoded source does, and it reuses the same
    /// bounded cache the renders use — picking on a photo you are already looking at
    /// costs no decode at all.
    func sampleSceneLinear(url: URL, recipe: Recipe,
                           sourceX: Double, sourceY: Double) -> RGB? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.sampleSceneLinear(source: source, recipe: recipe,
                                          sourceX: sourceX, sourceY: sourceY)
    }

    /// Sample a point and solve the Temp/Tint that make it neutral.
    ///
    /// The whole solve happens here rather than in the app because everything it needs
    /// is on this side of the actor: the sample, and the as-shot neutral it has to be
    /// measured against. Handing the caller a bare RGB would have meant exporting the
    /// capture metadata too, and then two places would have to agree about what the
    /// sample means.
    ///
    /// `neutralizing` expects a value with the CURRENT white balance already applied —
    /// it inverts that matrix internally to recover the decoded value — so the sample
    /// goes through `wb.matrix` on the way in. The round trip is deliberate and exact:
    /// it keeps this call correct without depending on the solver's internals.
    func solveNeutral(url: URL, recipe: Recipe,
                      sourceX: Double, sourceY: Double) -> (kelvin: Double, tint: Double)? {
        guard let source = try? self.source(for: url),
              let sample = renderer.sampleSceneLinear(source: source, recipe: recipe,
                                                     sourceX: sourceX, sourceY: sourceY),
              sample.isFinite, sample.maxComponent > 1e-9
        else { return nil }
        let wb = WhiteBalanceEngine(asShotKelvin: source.asShotTemperature,
                                    asShotTint: source.asShotTint,
                                    targetKelvin: recipe.develop.raw.temp,
                                    targetTint: recipe.develop.raw.tint)
        return WhiteBalanceEngine.neutralizing(sample: wb.matrix.apply(sample),
                                               asShotKelvin: source.asShotTemperature,
                                               asShotTint: source.asShotTint,
                                               current: wb)
    }

    // MARK: - Sources

    /// Picks the decoder by extension rather than by trying one and catching, because
    /// `CIRAWFilter(imageURL:)` is not documented to refuse a JPEG — it may return a
    /// filter that produces something, and a rendered file quietly run through the RAW
    /// stage would be wrong in ways nobody could see from the picture.
    private func source(for url: URL) throws -> any ImageSource {
        if let cached = sources[url] {
            sourceOrder.removeAll { $0 == url }
            sourceOrder.append(url)
            return cached
        }
        let extensionName = url.pathExtension.lowercased()
        let created: any ImageSource = PhotoFormats.rendered.contains(extensionName)
            ? try RenderedImageSource(url: url)
            : try AppleRawSource(url: url)
        sources[url] = created
        sourceOrder.append(url)
        while sourceOrder.count > Self.sourceCacheLimit, let oldest = sourceOrder.first {
            sourceOrder.removeFirst()
            sources.removeValue(forKey: oldest)
        }
        return created
    }

    private static func describe(_ error: Error) -> String {
        if let raw = error as? RawSourceError {
            switch raw {
            case .unreadable: return "file unreadable"
            case .undecodable: return "this file could not be decoded"
            }
        }
        return "render failed"
    }

    nonisolated static func embeddedPreview(url: URL, maxLongEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A monotonically increasing ticket the main actor stamps on every render request.
@MainActor
final class RenderGeneration {
    private var value: UInt64 = 0

    func next() -> UInt64 {
        value &+= 1
        return value
    }

    var current: UInt64 { value }
}

#endif
