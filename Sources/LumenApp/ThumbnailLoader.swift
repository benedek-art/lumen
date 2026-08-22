// ThumbnailLoader.swift
// The embedded-preview fast path (D34, Law 14) and the memory side of the browse
// cache. Grid and filmstrip pixels come from the camera's embedded JPEG via ImageIO —
// the browse path NEVER decodes RAW, because a contact sheet that demosaics is a
// contact sheet the photographer waits for.
//
// What this file owns:
//   · extraction: CGImageSourceCreateThumbnailAtIndex with FromImageAlways = false,
//     so a RAW without a usable preview yields nil (a placeholder) rather than a
//     45 MP decode. Orientation comes from the container's properties, applied inside
//     ImageIO by kCGImageSourceCreateThumbnailWithTransform — the classic
//     sideways-portrait gotcha (docs/03).
//   · an LRU cache with a byte budget (512 MB default, shared-texture-budget figure
//     from docs/10 §10.3), evicted least-recently-shown first.
//   · a bounded decode pool (8 workers, docs/15 §15.6) that runs off the main actor,
//     drains highest-priority-newest-first, and drops work for cells that scrolled
//     away before their slot came up.
//   · direction-aware prefetch, 8 ahead / 2 behind the cursor (D34). Fixed policy,
//     not a preference; a direction flip re-aims the window so a reversal costs at
//     most one page.
//
// Scheduling bookkeeping lives on the main actor deliberately: it is a few dictionary
// operations per cell, and keeping it here is what lets the scroll path ask
// `thumbnail(for:size:)` a synchronous question and get a synchronous answer.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Decode (off-actor, no shared state)

/// Sizes the cache is allowed to hold. Requests snap up to one of these so a
/// thumbnail-size slider drag reuses decodes instead of spawning one per pixel step.
private let thumbnailLevels: [Int] = [256, 512, 1024, 2048]

private func thumbnailBucket(for size: Int) -> Int {
    for level in thumbnailLevels where size <= level { return level }
    return thumbnailLevels[thumbnailLevels.count - 1]
}

/// Formats where "decode the whole image as a thumbnail" is acceptable because there
/// is nothing to demosaic. For RAW the answer is always no: no embedded preview means
/// a placeholder, never a full decode on the browse path (D34 / Law 14).
private let alreadyRenderedExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
]

private func allowsFullDecode(_ url: URL) -> Bool {
    alreadyRenderedExtensions.contains(url.pathExtension.lowercased())
}

/// Queue priorities. Visible cells beat the prefetch ring, which beats anything
/// speculative (docs/10 §10.3: visible > lookahead > rest).
enum ThumbnailPriority {
    static let visible = 300
    static let lookahead = 200
    static let prefetch = 100
    static let background = 10
}

private func decodeEmbeddedThumbnail(url: URL, maxPixel: Int, allowFullDecode: Bool) -> CGImage? {
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
        return nil
    }
    let thumbOptions: [CFString: Any] = [
        // The two that matter: never synthesize from the full image for RAW, and do
        // synthesize for formats that are already pixels.
        kCGImageSourceCreateThumbnailFromImageAlways: false,
        kCGImageSourceCreateThumbnailFromImageIfAbsent: allowFullDecode,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        // Pay the pixel cost here, on the worker, not on the first frame that draws it.
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
}

// MARK: - Loader

@MainActor
final class ThumbnailLoader: ObservableObject {

    typealias Priority = ThumbnailPriority

    /// D34's ring, exactly: 8 ahead in the direction of travel, 2 behind.
    private static let aheadCount = 8
    private static let behindCount = 2

    private struct Key: Hashable, Sendable {
        let url: URL
        let pixels: Int
    }

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUsed: UInt64
    }

    private struct Waiter {
        let ticket: Int
        let continuation: CheckedContinuation<CGImage?, Never>
    }

    private struct Job {
        var priority: Int
        /// Monotonic request stamp: ties break newest-first, so a direction change
        /// jumps the queue instead of waiting behind the old window.
        var stamp: Int
        var waiters: [Waiter]
        var task: Task<CGImage?, Never>?
    }

    /// Purely informational; nothing on the scroll path observes this object.
    @Published private(set) var inFlightCount: Int = 0

    private let budgetBytes: Int
    private let maxConcurrent: Int

    private var cache: [Key: Entry] = [:]
    private var cacheBytes: Int = 0
    private var jobs: [Key: Job] = [:]
    private var failed: Set<Key> = []
    private var active: Int = 0
    private var clock: UInt64 = 0
    private var stampCounter: Int = 0
    private var ticketCounter: Int = 0
    private var lastAnchorIndex: Int?
    private var travelDirection: Int = 1

    init(budgetBytes: Int = 512 * 1024 * 1024, maxConcurrent: Int = 8) {
        self.budgetBytes = max(budgetBytes, 16 * 1024 * 1024)
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: Reads

    /// The scroll path's only question: is it here already? Never blocks, never
    /// decodes, never allocates a task.
    func thumbnail(for url: URL, size: Int) -> CGImage? {
        let key = Key(url: url, pixels: thumbnailBucket(for: size))
        guard var entry = cache[key] else { return nil }
        clock += 1
        entry.lastUsed = clock
        cache[key] = entry
        return entry.image
    }

    /// Awaits a thumbnail, joining any decode already in flight for the same file and
    /// size. If the caller's task is cancelled — the cell scrolled away — the wait
    /// ends immediately and the work is dropped if nobody else still wants it.
    func image(for url: URL, size: Int, priority: Int = Priority.visible) async -> CGImage? {
        if let hit = thumbnail(for: url, size: size) { return hit }
        let key = Key(url: url, pixels: thumbnailBucket(for: size))
        if failed.contains(key) { return nil }
        if Task.isCancelled { return nil }

        ticketCounter += 1
        let ticket = ticketCounter

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                var job = jobs[key] ?? makeJob(priority: priority)
                job.waiters.append(Waiter(ticket: ticket, continuation: continuation))
                if priority > job.priority {
                    stampCounter += 1
                    job.priority = priority
                    job.stamp = stampCounter
                }
                jobs[key] = job
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abandon(ticket: ticket, key: key)
            }
        }
    }

    // MARK: Requests

    /// Enqueue without waiting. Used for prefetch windows.
    func request(_ urls: [URL], size: Int, priority: Int = Priority.prefetch) {
        guard !urls.isEmpty else { return }
        let pixels = thumbnailBucket(for: size)
        for url in urls {
            enqueue(Key(url: url, pixels: pixels), priority: priority)
        }
        pump()
    }

    /// Drop speculative work for files nobody is looking at any more. A decode that
    /// has already started is cancelled but still allowed to land in the cache if it
    /// beats us to it — throwing away finished pixels helps nobody.
    func cancel(_ urls: [URL], size: Int) {
        let pixels = thumbnailBucket(for: size)
        for url in urls {
            let key = Key(url: url, pixels: pixels)
            guard let job = jobs[key], job.waiters.isEmpty else { continue }
            if let task = job.task {
                task.cancel()
            } else {
                jobs.removeValue(forKey: key)
            }
        }
    }

    /// Direction-aware prefetch around the cursor: `aheadCount` in the direction of
    /// travel, `behindCount` the other way (D34). Reversing direction re-aims the
    /// window on the next call, so a page-back costs one page, not eight.
    func prefetch(around anchor: URL?, in urls: [URL], size: Int) {
        guard let anchor, let index = urls.firstIndex(of: anchor) else { return }
        if let last = lastAnchorIndex, index != last {
            travelDirection = index >= last ? 1 : -1
        }
        lastAnchorIndex = index

        var ahead: [URL] = [urls[index]]
        var behind: [URL] = []
        if Self.aheadCount > 0 {
            for step in 1...Self.aheadCount {
                let i = index + step * travelDirection
                if i >= 0 && i < urls.count { ahead.append(urls[i]) }
            }
        }
        if Self.behindCount > 0 {
            for step in 1...Self.behindCount {
                let i = index - step * travelDirection
                if i >= 0 && i < urls.count { behind.append(urls[i]) }
            }
        }

        request(ahead, size: size, priority: Priority.lookahead)
        request(behind, size: size, priority: Priority.prefetch)

        var keep = Set(ahead)
        keep.formUnion(behind)
        pruneSpeculative(keeping: keep, pixels: thumbnailBucket(for: size))
    }

    // MARK: Compatibility surface

    /// AppKit-shaped convenience for the loupe's instant-preview path.
    func load(url: URL, maxPixel: Int = 512) async -> NSImage? {
        guard let cg = await image(for: url, size: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func cached(for url: URL, maxPixel: Int = 512) -> NSImage? {
        guard let cg = thumbnail(for: url, size: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Scheduling

    private func makeJob(priority: Int) -> Job {
        stampCounter += 1
        return Job(priority: priority, stamp: stampCounter, waiters: [], task: nil)
    }

    private func enqueue(_ key: Key, priority: Int) {
        if cache[key] != nil || failed.contains(key) { return }
        if var job = jobs[key] {
            guard priority > job.priority else { return }
            stampCounter += 1
            job.priority = priority
            job.stamp = stampCounter
            jobs[key] = job
            return
        }
        jobs[key] = makeJob(priority: priority)
    }

    private func pump() {
        while active < maxConcurrent, let key = nextPending() {
            start(key)
        }
        if inFlightCount != active { inFlightCount = active }
    }

    private func nextPending() -> Key? {
        var best: Key?
        var bestPriority = Int.min
        var bestStamp = Int.min
        for (key, job) in jobs where job.task == nil {
            if job.priority > bestPriority
                || (job.priority == bestPriority && job.stamp > bestStamp) {
                best = key
                bestPriority = job.priority
                bestStamp = job.stamp
            }
        }
        return best
    }

    private func start(_ key: Key) {
        guard var job = jobs[key] else { return }
        active += 1
        let allowFull = allowsFullDecode(key.url)
        let taskPriority: TaskPriority = job.priority >= Priority.visible ? .userInitiated : .utility
        let task = Task.detached(priority: taskPriority) { () -> CGImage? in
            if Task.isCancelled { return nil }
            return decodeEmbeddedThumbnail(url: key.url, maxPixel: key.pixels,
                                           allowFullDecode: allowFull)
        }
        job.task = task
        jobs[key] = job
        Task { @MainActor [weak self] in
            let image = await task.value
            self?.finish(key, image: image)
        }
    }

    private func finish(_ key: Key, image: CGImage?) {
        active = max(0, active - 1)
        let job = jobs.removeValue(forKey: key)
        let wasCancelled = job?.task?.isCancelled ?? false

        if let image {
            store(key, image: image)
        } else if !wasCancelled {
            // A file with no usable preview stays unusable for this session; retrying
            // it on every scroll pass would starve the files that do have one.
            failed.insert(key)
            if failed.count > 8192 { failed.removeAll() }
        }

        if let job {
            if wasCancelled, image == nil, !job.waiters.isEmpty {
                // Somebody asked again while the cancellation was in flight.
                var retry = makeJob(priority: Priority.visible)
                retry.waiters = job.waiters
                jobs[key] = retry
            } else {
                for waiter in job.waiters {
                    waiter.continuation.resume(returning: image)
                }
            }
        }
        pump()
    }

    private func abandon(ticket: Int, key: Key) {
        guard var job = jobs[key],
              let index = job.waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        let waiter = job.waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
        if job.waiters.isEmpty, job.task == nil {
            // Never started, nobody waiting: it scrolled away before its slot came up.
            jobs.removeValue(forKey: key)
            return
        }
        jobs[key] = job
    }

    private func pruneSpeculative(keeping keep: Set<URL>, pixels: Int) {
        for (key, job) in jobs {
            guard job.waiters.isEmpty, job.task == nil, job.priority < Priority.visible else { continue }
            if key.pixels == pixels && keep.contains(key.url) { continue }
            jobs.removeValue(forKey: key)
        }
    }

    // MARK: Cache

    private func store(_ key: Key, image: CGImage) {
        let bytes = max(image.bytesPerRow * image.height, 1)
        if let existing = cache[key] { cacheBytes -= existing.bytes }
        clock += 1
        cache[key] = Entry(image: image, bytes: bytes, lastUsed: clock)
        cacheBytes += bytes
        if cacheBytes > budgetBytes { evict() }
    }

    /// Evict to 90% of budget rather than to the line, so a full cache does not run
    /// an eviction pass on every single insert.
    private func evict() {
        let target = (budgetBytes / 10) * 9
        let ordered = cache.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in ordered {
            if cacheBytes <= target { break }
            cache.removeValue(forKey: key)
            cacheBytes -= entry.bytes
        }
        if cacheBytes < 0 { cacheBytes = 0 }
    }
}

#endif
