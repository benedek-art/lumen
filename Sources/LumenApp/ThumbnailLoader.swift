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
//   · the memory half of a two-level cache. Behind it is `PreviewStore`, which reads
//     and writes `previews/xx/` and files a row in `cache.preview`, so a decode paid
//     once is paid once — not once per launch, which is what this loader did for as
//     long as it existed. A miss consults the disk BEFORE scheduling an extraction,
//     and an extraction files its result. The rules live in `LumenCore.PreviewCache`;
//     the pixels live here.
//   · a bounded decode pool (8 workers, docs/15 §15.6) that runs off the main actor,
//     drains highest-priority-newest-first, and drops work for cells that scrolled
//     away before their slot came up.
//   · direction-aware prefetch, 8 ahead / 2 behind the cursor (D34). Fixed policy,
//     not a preference; a direction flip re-aims the window so a reversal costs at
//     most one page. The ring's index arithmetic and the size ladder both live in
//     `LumenCore.ThumbnailLadder` / `PrefetchRing`, where they have tests; what stays
//     here is the queue, the cache and the AppKit.
//
// Scheduling bookkeeping lives on the main actor deliberately: it is a few dictionary
// operations per cell, and keeping it here is what lets the scroll path ask
// `thumbnail(for:size:)` a synchronous question and get a synchronous answer.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LumenCore

// MARK: - Decode (off-actor, no shared state)

/// The level a request snaps to, so a thumbnail-size slider drag reuses decodes
/// instead of spawning one per pixel step. The ladder itself is `ThumbnailLadder` in
/// LumenCore: it has to be the same ladder the prefetch plans against, and while it
/// was a private constant in this file nothing could check that it was.
private func thumbnailBucket(for size: Int) -> Int {
    ThumbnailLadder.bucket(for: size)
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

    /// Where each photograph sits in the roll, memoised and re-verified on every read.
    ///
    /// It lives on the loader rather than on either view because the grid, the strip
    /// and the loupe all aim rings at the SAME cursor in the SAME roll on one keystroke:
    /// a memo per view would be built three times and would go stale three times
    /// independently. The rule that keeps it honest is `RollCursor`'s, and it is stated
    /// there at length — the short version is that the index it returns has been checked
    /// against the roll it is about to be used on, so a roll that changed under it costs
    /// one rebuild rather than a window warmed around the wrong frame.
    private var roll = RollCursor()

    /// The disk half. Nil until the catalog has opened, and nil forever if it could not
    /// — a session with no catalog still browses, out of memory only, exactly as every
    /// session did before this existed.
    private var previews: PreviewStore?

    init(budgetBytes: Int = 512 * 1024 * 1024, maxConcurrent: Int = 8) {
        self.budgetBytes = max(budgetBytes, 16 * 1024 * 1024)
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Hand the loader its disk cache.
    ///
    /// Set after construction rather than injected into `init` for one prosaic reason:
    /// `AppState` holds this loader as a stored property and opens the catalog from its
    /// own initializer, so the catalog does not exist yet at the moment the loader is
    /// built. The seam is the same either way — the loader knows about `PreviewStore`
    /// and nothing else about the catalog.
    func attach(previews: PreviewStore) {
        self.previews = previews
    }

    /// File a SETTLED develop frame at the rung ITS OWN PIXELS FILL, so returning to
    /// this photograph does not read the RAW again.
    ///
    /// The rung, the freshness rule and the edit-invalidation were all built for this
    /// and never connected: `PreviewLevel.fit` is documented in `PreviewCache.Freshness`
    /// as "a rung that claims to show the current render", it is the one rung an edit
    /// makes STALE rather than merely browsable, and `invalidatePreviews` already
    /// deletes it. What was missing was a writer — every fit row in the cache was the
    /// camera's own embedded JPEG, so the loupe's instant path opened a photograph you
    /// had edited and showed you the camera's rendering of it.
    ///
    /// WHY THE RUNG IS NOT NAMED HERE, which is the whole of I3-01. This function used
    /// to file every settle under `ThumbnailLadder.pixels(for: .fit)` — the constant
    /// 2560 — without once reading `image.width`. The settle is not 2560. It is
    /// `requestedLongEdge`, which is the container's long edge in device pixels narrowed
    /// by `DraftResolution.visibleCeiling` to "not one pixel more than the panel draws",
    /// so a portrait frame in a landscape pane or a windowed loupe on a 1× display
    /// settles somewhere between 640 and 1600. Filed as a `fit` row under the current
    /// fingerprint it scored `.current` and won `PreviewCache.decide`'s tie against the
    /// camera's own full-size embedded row, and `decodePayload` never upscales — so the
    /// next launch answered a 2560 request with 900 pixels and reported a hit. The
    /// photograph the owner had EDITED came back softer than the one he had not, the
    /// smaller the window the softer it was, and nothing downstream could see it: a row
    /// carries a level and a path and no pixel count.
    ///
    /// So the size is derived from the image and cannot be omitted — there is no rung
    /// parameter to get wrong, and `PreviewCache.pixelsFilled(byPayloadLongEdge:)` is
    /// the rule, in LumenCore where it is tested. It answers the largest rung these
    /// pixels can FILL and nil below `thumb`, which is `decide`'s "never upward" rule
    /// enforced at the writing end. A frame too small to fill any rung is not filed at
    /// all; one that fills `grid` is a grid row, and the loupe's `fit` request then falls
    /// through to the camera's row exactly as it did before this writer existed —
    /// slower, and true.
    ///
    /// This is the one writer in the loader whose payload is not an extraction made at
    /// the size that was asked for; `start`'s `record` hands over exactly what
    /// `decodeEmbeddedThumbnail` produced for `key.pixels`, which is the case
    /// `PreviewCache.rowForDecode` argues is honest at the ask.
    ///
    /// `source: .lumen` is what files this under the CURRENT fingerprint —
    /// `PreviewCache.rowForDecode` files a camera render as as-shot whatever the photo's
    /// recipe says, which is right for an embedded JPEG and would be a lie about this.
    ///
    /// Fire-and-forget, and refusable: `record` drops the write under back pressure, so
    /// a settle never waits on an encoder and a cache miss costs a decode rather than a
    /// stall.
    func recordDeveloped(url: URL, image: CGImage) {
        guard let previews else { return }
        let longEdge = max(image.width, image.height)
        guard let pixels = PreviewCache.pixelsFilled(byPayloadLongEdge: longEdge) else {
            return
        }
        Task { [weak self] in
            guard self != nil,
                  let plan = await previews.plan(for: url, pixels: pixels) else { return }
            previews.record(plan, image: image, source: .lumen)
        }
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
    ///
    /// THE ROLL IS PASSED AS PHOTOGRAPHS, NOT AS URLS, and that is the whole of the
    /// change on the caller's side. Every cursor move used to reach this as
    /// `state.photos.map(\.id)` — a fresh array of every URL in the folder, built from
    /// the contact sheet, again from the filmstrip, and again from the loupe, on every
    /// one of the ~25–30 key repeats a second an arrow key held down produces. The
    /// window this function actually reads is at most eleven of them. Measured over
    /// 2,000 frames, the two projections and the two linear searches they fed cost
    /// ~95 µs per keystroke of pure bookkeeping against an 8.3 ms frame budget, and it
    /// is linear in the size of the shoot. Only the window's own indices are read now,
    /// so the cost is a fixed eleven reads whatever the folder holds.
    func prefetch(around anchor: URL?, in photos: [PhotoItem], size: Int,
                  surface: PagingSurface) {
        prefetch(around: anchor, count: photos.count, size: size, surface: surface) {
            photos[$0].id
        }
    }

    /// The same ring aimed from a list that is already URLs.
    ///
    /// Kept because the loupe holds one; it shares the memo and the direction memory
    /// with the call above, which is what lets two views aim the same ring at the same
    /// cursor on one keystroke and pay for it once.
    func prefetch(around anchor: URL?, in urls: [URL], size: Int,
                  surface: PagingSurface) {
        prefetch(around: anchor, count: urls.count, size: size, surface: surface) {
            urls[$0]
        }
    }

    /// `surface` is not decoration. The window is warmed at every level
    /// `ThumbnailLadder.warmSizes` names for that surface, because the strip under the
    /// loupe pages the LOUPE: warming only the strip's own 256 left the viewer's
    /// 1600-pixel request (the top level) cold on every advance, which is the
    /// pre-decoded cache the paging budget is built on, missing every time. The levels
    /// are requested in the order that function returns them, at descending priority,
    /// so the heavier level can never starve the cells that are visible now.
    ///
    /// Where the cursor sits comes from `RollCursor` rather than from a search, and the
    /// index it hands back is verified against `idAt` before it is used — see that type
    /// for why a memo nobody checks is a ring warmed around the wrong photograph.
    private func prefetch(around anchor: URL?, count: Int, size: Int,
                          surface: PagingSurface, idAt: (Int) -> URL) {
        guard let anchor,
              let index = roll.index(of: anchor, inRollOf: count, idAt: idAt) else {
            return
        }
        travelDirection = PrefetchRing.direction(from: lastAnchorIndex, to: index,
                                                 current: travelDirection)
        lastAnchorIndex = index

        let ring = PrefetchRing(ahead: Self.aheadCount, behind: Self.behindCount)
        let window = ring.window(anchor: index, count: count,
                                 direction: travelDirection)
        let ahead: [URL] = window.ahead.map { idAt($0) }
        let behind: [URL] = window.behind.map { idAt($0) }

        var keep: Set<Key> = []
        var managed: Set<Int> = []
        for (rank, level) in ThumbnailLadder.warmSizes(for: surface,
                                                       browsePixels: size).enumerated() {
            // Rank 0 is the level being drawn right now; anything behind it is a bet on
            // the next keystroke and queues below the visible work.
            let aheadPriority = rank == 0 ? Priority.lookahead : Priority.prefetch
            let behindPriority = rank == 0 ? Priority.prefetch : Priority.background
            request(ahead, size: level, priority: aheadPriority)
            request(behind, size: level, priority: behindPriority)
            let pixels = thumbnailBucket(for: level)
            managed.insert(pixels)
            for url in ahead { keep.insert(Key(url: url, pixels: pixels)) }
            for url in behind { keep.insert(Key(url: url, pixels: pixels)) }
        }
        pruneSpeculative(keeping: keep, levels: managed)
    }

    // MARK: Compatibility surface

    /// AppKit-shaped convenience for the loupe's instant-preview path.
    ///
    /// The default is the loupe's own ask rather than a bare number: 512 stopped being a
    /// rung when the ladder became docs/15 §15.6's, and a default that silently snapped
    /// up a rung is the kind of drift `ThumbnailLadder` exists to prevent.
    func load(url: URL, maxPixel: Int = ThumbnailLadder.loupeInstantPixels) async -> NSImage? {
        guard let cg = await image(for: url, size: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func cached(for url: URL, maxPixel: Int = ThumbnailLadder.loupeInstantPixels) -> NSImage? {
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
        let previews = self.previews
        // `async` in the signature is explicit, not inferred: the disk-cache lookup
        // below now SUSPENDS on the catalog rather than blocking this worker, and eight
        // workers blocking cooperative threads was starving every other continuation in
        // the process.
        let task = Task.detached(priority: taskPriority) { () async -> CGImage? in
            if Task.isCancelled { return nil }
            // The disk cache first. This is the line README goal #1 turns on: on the
            // second visit to a folder every cell answered from `previews/xx/` is an
            // embedded-JPEG extraction out of a 40 MB original that does not happen.
            // Off the main actor by construction — this is the detached worker.
            let plan = await previews?.plan(for: key.url, pixels: key.pixels)
            if let plan, let payload = plan.payload,
               let cached = PreviewStore.decodePayload(file: payload.file,
                                                       maxPixel: payload.pixels) {
                previews?.served(payload, photoID: plan.photoID)
                return cached
            }
            if Task.isCancelled { return nil }
            guard let image = decodeEmbeddedThumbnail(url: key.url, maxPixel: key.pixels,
                                                      allowFullDecode: allowFull)
            else { return nil }
            // Filed asynchronously: the caller already has the photograph, and a
            // scrolling grid must not wait behind an encode.
            if let plan { previews?.record(plan, image: image) }
            return image
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

    /// Drop the speculative jobs the newest window does not name, at the levels that
    /// window manages.
    ///
    /// Two changes from pruning by url at one level. The keep set is keyed by (url,
    /// level), because a window is now warmed at more than one level. And the sweep is
    /// bounded to `levels`: the loupe and the strip both aim rings at the same cursor,
    /// so a sweep across every level would have each caller throw away the other's
    /// pending work on every keystroke. The cost of the bound is that a level nobody
    /// aims at any more — the grid slider crossing a bucket edge — keeps at most one
    /// ring of pending decodes until they run.
    private func pruneSpeculative(keeping keep: Set<Key>, levels: Set<Int>) {
        for (key, job) in jobs {
            guard job.waiters.isEmpty, job.task == nil, job.priority < Priority.visible else { continue }
            guard levels.contains(key.pixels) else { continue }
            if keep.contains(key) { continue }
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
