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

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 2000
    }

    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Decode the embedded preview off the calling thread; returns nil when the file
    /// has no usable preview (caller shows a placeholder, never blocks on RAW decode).
    func load(url: URL, maxPixel: Int = 512) async -> NSImage? {
        if let hit = cached(for: url) { return hit }
        let image: NSImage? = await Task.detached(priority: .utility) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }
}

#endif
