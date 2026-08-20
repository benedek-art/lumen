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
    private var sources: [URL: AppleRawSource] = [:]
    private var latestGeneration: UInt64 = 0

    /// Bounded so a fast scroll through a folder cannot pin a hundred decoded RAWs in
    /// memory at once; the eviction is safe because a source is recreatable.
    private static let sourceCacheLimit = 12
    private var sourceOrder: [URL] = []

    func render(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                generation: UInt64) async -> RenderResult? {
        latestGeneration = max(latestGeneration, generation)
        // Drop work that is already stale before paying for a decode.
        guard generation >= latestGeneration else { return nil }

        do {
            let source = try self.source(for: url)
            guard generation >= latestGeneration else { return nil }
            let image = try renderer.renderPreview(source: source, recipe: recipe,
                                                   maxLongEdge: maxLongEdge, draft: draft)
            guard generation >= latestGeneration else { return nil }
            return RenderResult(image: image, generation: generation, isDraft: draft,
                                usedEmbeddedPreview: false,
                                note: KernelLibrary.coreAvailable
                                    ? nil
                                    : "CPU fallback — GPU kernels unavailable")
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
    func renderFullSize(url: URL, recipe: Recipe) throws -> CGImage {
        let source = try self.source(for: url)
        return try renderer.renderPreview(source: source, recipe: recipe,
                                          maxLongEdge: Int(source.nativeLongEdge),
                                          draft: false)
    }

    func export(url: URL, recipe: Recipe, to destination: URL,
                exportRecipe: ExportRecipe) throws {
        let source = try self.source(for: url)
        try renderer.export(source: source, recipe: recipe, to: destination,
                            using: exportRecipe)
    }

    func nativeSize(for url: URL) -> (width: Int, height: Int)? {
        guard let source = try? self.source(for: url) else { return nil }
        return source.nativePixelSize
    }

    func invalidate(url: URL) {
        sources.removeValue(forKey: url)
        sourceOrder.removeAll { $0 == url }
    }

    // MARK: - Sources

    private func source(for url: URL) throws -> AppleRawSource {
        if let cached = sources[url] {
            sourceOrder.removeAll { $0 == url }
            sourceOrder.append(url)
            return cached
        }
        let created = try AppleRawSource(url: url)
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
            case .undecodable: return "no RAW decoder for this file"
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
