// ThumbnailLoader.swift
// The embedded-preview fast path (D34, Law 14): grid thumbnails come from the
// camera's embedded JPEG via ImageIO — never a RAW decode. Orientation is taken
// from the container's properties (the classic gotcha, docs/03 culling section);
// kCGImageSourceCreateThumbnailWithTransform handles it inside ImageIO.

#if os(macOS)

import AppKit
import Foundation
import ImageIO

final class ThumbnailLoader {

    private let cache = NSCache<NSString, NSImage>()

    /// Extensions where a full-image decode as thumbnail fallback is acceptable —
    /// already-rendered formats only. For RAW, the browse path must NEVER fall back
    /// to a full decode (D34/Law 14): no embedded preview means a placeholder.
    private static let decodableFallback: Set<String> = ["jpg", "jpeg", "heic", "png"]

    init() {
        cache.countLimit = 2000
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.absoluteString)#\(maxPixel)" as NSString
    }

    func cached(for url: URL, maxPixel: Int = 512) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// Decode the embedded preview off the calling thread; returns nil when the file
    /// has no usable preview (caller shows a placeholder, never blocks on RAW decode).
    func load(url: URL, maxPixel: Int = 512) async -> NSImage? {
        if let hit = cached(for: url, maxPixel: maxPixel) { return hit }
        let allowFullDecode =
            Self.decodableFallback.contains(url.pathExtension.lowercased())
        let image: NSImage? = await Task.detached(priority: .utility) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: allowFullDecode,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            cache.setObject(image, forKey: key(url, maxPixel))
        }
        return image
    }
}

#endif
