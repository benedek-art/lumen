// PreviewStore.swift
// The disk side of the browse cache: the file writes and the ImageIO calls that
// `PreviewCache` in LumenCore decides for.
//
// What was wrong. `ThumbnailLoader` was a pure in-memory LRU keyed `(url, pixels)` with
// no catalog reference, no `photo_id` and no disk write, while `recordPreview`,
// `preview`, `touchPreview`, `invalidatePreviews` and `pruneCache` sat in `CatalogStore`
// with zero callers. Every launch therefore re-decoded every embedded JPEG in the
// folder, and README goal #1 — "next photo in under 50 ms from a pre-decoded cache",
// which is Photo Mechanic's bar — could not be met by construction, because the cache
// it names did not survive the process.
//
// The division of labour here is deliberate and is the reason this stayed broken for so
// long. Every RULE — which stored rung answers a request, when a stored preview stopped
// describing the photograph, what a camera render may be filed under, where a payload
// lives, how big the cache may get — is in `LumenCore.PreviewCache`, under test. What is
// left in this file is the part that genuinely cannot leave: `CGImageDestination`,
// `CGImageSource`, `FileManager`, and the two dispatch queues. This file cannot be
// compiled on the machine it was written on and has no test target; anything decidable
// that lives here is a decision nobody can check.

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO
import LumenCore

/// The app's door onto the preview cache: URL in, pixels out or pixels filed away.
///
/// `@unchecked Sendable` for the same reason `CatalogService` is: it is reached from
/// eight decode workers at once and guards its own mutable state with a lock.
final class PreviewStore: @unchecked Sendable {

    /// One photo's answer to "is this already on disk?", together with everything a
    /// decode needs to file its own result afterwards.
    ///
    /// Fetched in ONE hop onto the catalog's serial queue. Two hops per thumbnail — one
    /// to ask for the fingerprint, one for the rows — would put eight decode workers
    /// behind each other on the path the 50 ms goal is measured on.
    struct Plan: Sendable {
        let photoID: Int64
        let level: PreviewLevel
        let pixels: Int
        /// The photo's current `recipe_fp`, empty for as-shot.
        let fingerprint: String
        /// The payload to read instead of decoding the original, if there is one.
        let payload: Payload?
    }

    struct Payload: Sendable {
        let file: URL
        /// The size to read the payload at, which is the size that was REQUESTED and
        /// not necessarily the payload's own — a `fit` file answering a `grid` request
        /// is read down to 1024 so the memory LRU gets the entry it budgeted for.
        let pixels: Int
        let level: PreviewLevel
        let recipeFP: String
    }

    private let catalog: CatalogService
    private let directory: URL

    /// Encoding and writing happen here, not on the decode worker: the photograph is
    /// already in the caller's hands by then, and making a scrolling grid wait on a HEIC
    /// encode would be spending the time this cache exists to save.
    private let writes = DispatchQueue(label: "dev.lumenapp.previews", qos: .utility)

    private let lock = NSLock()
    private var photoIDs: [URL: Int64] = [:]

    init(catalog: CatalogService, directory: URL) {
        self.catalog = catalog
        self.directory = directory
    }

    /// `~/Library/Caches/Lumen` — docs/15 §15.2 puts payloads here on purpose: the OS's
    /// own storage tooling can reclaim them, Time Machine skips the location, and the
    /// whole directory is deletable with zero data loss. A row whose payload was
    /// reclaimed is a miss, which is handled below rather than being an error.
    static func defaultDirectory() -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true) else { return nil }
        let directory = caches.appendingPathComponent("Lumen", isDirectory: true)
        // Created here rather than lazily on the first write, because `prune` measures
        // free space through this URL and a directory that does not exist measures as
        // zero — which reads as "no budget" and would skip eviction forever.
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    /// Join a cache-relative path onto the cache directory, one component at a time.
    ///
    /// `appendingPathComponent` is documented to append ONE component; handing it
    /// `previews/ab/x.heic` relies on it splitting the string, which is behaviour this
    /// code should not be betting a photographer's cache on. Three appends, no bet.
    private func resolve(_ relative: String) -> URL {
        var url = directory
        for component in relative.split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }

    // MARK: - URL to photo id

    /// The map the loader needs and did not have. `registerAndLoad` already returns it;
    /// nothing was keeping it.
    func register(_ ids: [URL: Int64]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        for (url, id) in ids { photoIDs[url] = id }
        lock.unlock()
    }

    func photoID(for url: URL) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return photoIDs[url]
    }

    // MARK: - Lookup

    /// What to do about one request. Runs on a decode worker, never on the main actor.
    ///
    /// Nil means the cache has nothing to say about this file at all — it is not in the
    /// catalog, or the size asked for is not a rung — and the caller decodes without
    /// recording. A non-nil plan with a nil payload is a miss the caller should record
    /// the result of.
    func plan(for url: URL, pixels: Int) -> Plan? {
        guard let level = ThumbnailLadder.level(for: pixels),
              let photoID = photoID(for: url),
              let state = catalog.previewState(photoID: photoID) else { return nil }
        var payload: Payload?
        if case .serve(let row) = PreviewCache.decide(request: level,
                                                      fingerprint: state.fingerprint,
                                                      stored: state.rows),
           let readPixels = PreviewCache.readPixels(request: level, served: row) {
            let file = resolve(row.path)
            // The row can outlive its payload: `~/Library/Caches` is reclaimable by the
            // OS and a user may empty it from Storage settings at any time. That is a
            // miss, not a failure — the decode below rewrites both halves.
            if FileManager.default.fileExists(atPath: file.path) {
                payload = Payload(file: file, pixels: readPixels, level: row.level,
                                  recipeFP: row.recipeFP)
            }
        }
        return Plan(photoID: photoID, level: level, pixels: pixels,
                    fingerprint: state.fingerprint, payload: payload)
    }

    /// Stamp the LRU. Fire-and-forget: a lost stamp costs eviction accuracy and nothing
    /// else, and a thumbnail must never wait on a write.
    func served(_ payload: Payload, photoID: Int64) {
        catalog.touchPreview(photoID: photoID, level: payload.level,
                             recipeFP: payload.recipeFP)
    }

    /// Read a payload back. Not the same options as an original: there is nothing to
    /// demosaic here and nothing to protect, so synthesizing from the full image is
    /// exactly what is wanted — and the transform is deliberately NOT re-applied,
    /// because the payload was written from an already-oriented decode and rotating it
    /// twice is the sideways-portrait bug from the other direction.
    static func decodePayload(file: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(file as CFURL,
                                                      sourceOptions as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Recording

    /// File a finished decode. Returns immediately; the encode happens on `writes`.
    func record(_ plan: Plan, image: CGImage, source: PreviewSource = .embedded) {
        writes.async { [weak self] in
            self?.persist(plan, image: image, source: source)
        }
    }

    private func persist(_ plan: Plan, image: CGImage, source: PreviewSource) {
        // The row is built FIRST and the path is derived from the row's own key, so
        // there is no way for the file name and the row to disagree about which recipe
        // these pixels depict. `rowForDecode` is what decides that a camera render is
        // filed as as-shot whatever the photo's current fingerprint says.
        guard var row = PreviewCache.rowForDecode(photoID: plan.photoID,
                                                  pixels: plan.pixels,
                                                  currentFingerprint: plan.fingerprint,
                                                  source: source, path: "", bytes: 0)
        else { return }

        for format in PreviewStore.formats {
            let relative = PreviewCache.payloadPath(photoID: row.photoID,
                                                    level: row.level,
                                                    recipeFP: row.recipeFP,
                                                    ext: format.ext)
            guard let shard = PreviewCache.shardDirectory(for: relative) else { continue }
            try? FileManager.default.createDirectory(at: resolve(shard),
                                                     withIntermediateDirectories: true)
            let file = resolve(relative)
            guard PreviewStore.encode(image, to: file, type: format.uti) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            row.path = relative
            row.bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            catalog.recordPreview(row)
            return
        }
    }

    private struct Format {
        let uti: CFString
        let ext: String
    }

    /// HEIC is what docs/15 §15.6 specifies. JPEG is the fallback rather than the
    /// absence of a cache, because a machine whose encoder will not produce HEIC should
    /// browse slightly larger previews rather than re-decode every original on every
    /// launch. The row names whichever file was actually written, so a directory holding
    /// both reads back correctly.
    private static let formats: [Format] = [
        Format(uti: "public.heic" as CFString, ext: "heic"),
        Format(uti: "public.jpeg" as CFString, ext: "jpg"),
    ]

    /// 0.85 rather than a higher number: these are browse pixels, they are judged at
    /// grid and fit sizes, and the budget they consume is the thing that decides how
    /// much of a shoot stays instant.
    private static let quality: Double = 0.85

    private static func encode(_ image: CGImage, to file: URL, type: CFString) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type,
                                                                1, nil) else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - Eviction

    /// LRU eviction to the disk budget, payloads unlinked behind it.
    ///
    /// docs/10 §10.10: no menu item, no ritual, no confirmation — the photographer never
    /// hears about this. Run from the quit path, which is the one moment nothing is
    /// scrolling.
    func prune() {
        let free = PreviewStore.freeBytes(at: directory)
        // A volume we could not measure is not a licence to empty the cache: zero free
        // space would compute a zero budget, and a zero budget evicts everything except
        // the permanent thumbnails. Not knowing means leaving it alone.
        guard free > 0 else { return }
        let victims = catalog.prunePreviews(
            maxBytes: PreviewCache.budgetBytes(freeBytes: free))
        for row in victims {
            try? FileManager.default.removeItem(at: resolve(row.path))
        }
    }

    private static func freeBytes(at directory: URL) -> Int64 {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

#endif
