// CatalogService.swift
// The app's door onto the catalog. `CatalogStore` in LumenCore owns the schema,
// migrations and queries; this type owns the threading and the sidecar discipline,
// and it is the only place in the app that knows a database exists.
//
// The trust posture docs/15 asks for, in three rules:
//   · originals are read-only, forever — nothing here writes next to a photo except
//     its own `.xmp` sidecar;
//   · every recipe lands in BOTH the catalog and a human-readable sidecar, so losing
//     the catalog costs speed rather than work;
//   · all database work happens on a serial queue off the main actor, and sidecar
//     writes are debounced and atomic, because a folder of 800 frames being rated
//     quickly must not become 800 file writes a second.

#if os(macOS)

import Foundation
import LumenCore
// `CaptureMetadataReader` reads EXIF through ImageIO, so it lives in LumenPipeline
// with the rest of the platform-image code rather than in LumenCore.
import LumenPipeline

final class CatalogService: @unchecked Sendable {

    struct StoredState {
        var catalogID: Int64
        var flag: PhotoFlag
        var rating: Int
        var label: ColorLabel?
        var recipe: Recipe?
        /// The capture ISO the backfill read, carried through so an unedited photo can
        /// start on the noise-reduction defaults its own gain calls for.
        var iso: Int?
    }

    private let store: CatalogStore
    private let queue = DispatchQueue(label: "dev.lumenapp.catalog", qos: .utility)
    private let directory: URL

    /// Called when a write fails. Every failure in here used to go to `NSLog` and
    /// nowhere else, so a full disk, a read-only volume or a locked database all
    /// presented as "the edit was applied" until the next launch reverted it.
    var onFailure: ((String) -> Void)?

    /// The payloads a recipe references rather than contains — brush stroke sets. A
    /// recipe stays small and diffable; the forty kilobytes of stylus samples behind
    /// `blob:xxh64:<hash>` live here.
    let blobs: BlobStore

    /// Sidecar writes coalesce over this window.
    private static let sidecarDebounce: TimeInterval = 2.0
    private var pendingSidecars: [URL: SidecarContent] = [:]
    private var sidecarFlushScheduled = false
    private let sidecarLock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        self.blobs = try BlobStore(
            directory: directory.appendingPathComponent("blobs", isDirectory: true))
        self.store = try CatalogStore(
            path: directory.appendingPathComponent("lumen.db").path,
            cachePath: directory.appendingPathComponent("cache.db").path)
    }

    // MARK: - Folders and photos

    /// Register a folder, reconcile its files, and return everything already known
    /// about them. Runs on the caller's thread by design: it is called from the
    /// background scan task, never from the main actor.
    func registerAndLoad(folder: URL, files: [URL]) -> [URL: StoredState] {
        var result: [URL: StoredState] = [:]
        queue.sync {
            do {
                let folderID = try store.registerFolder(path: folder.path)
                let scanned: [ScannedFile] = files.map { file in
                    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    let mtime = ((attributes?[.modificationDate] as? Date)?
                        .timeIntervalSince1970).map { Int64($0) } ?? 0
                    // The folder scan is recursive and `photo` is UNIQUE per
                    // (folder, filename), so the basename is not an identity: one card
                    // with day1/ and day2/ subfolders puts two different frames named
                    // DSC_0001.NEF on one row, and the second edit overwrites the
                    // first. The path relative to the registered folder is unique by
                    // construction, and equals the basename for files sitting directly
                    // in it — which is why this only ever bit multi-folder imports.
                    return ScannedFile(filename: ScannedFile.catalogName(for: file, in: folder),
                                       fileSize: size, fileMTime: mtime,
                                       ext: file.pathExtension.lowercased())
                }
                _ = try store.scan(folderID: folderID, files: scanned,
                                   at: CatalogStore.now())

                for file in files {
                    guard let row = try store.photo(
                        folderID: folderID,
                        filename: ScannedFile.catalogName(for: file, in: folder))
                    else { continue }
                    let recipe = try store.currentRecipe(photoID: row.id)
                    let state = Self.merge(row: row, recipe: recipe, file: file)
                    // A sidecar fills in where the catalog is silent — and until now it
                    // filled in ONLY the copy handed to the grid. Membership and
                    // ordering are SQL-backed (the whole filter bar compiles to
                    // `PhotoQuery`), so a five-star recovered from a sidecar showed five
                    // stars in its cell and vanished under the five-star filter, and a
                    // recovered recipe rendered while the Edited chip excluded it. The
                    // view and the query disagreed about the same photograph.
                    Self.persistRecovered(state, row: row, storedRecipe: recipe,
                                          store: store)
                    result[file] = state
                }
            } catch {
                NSLog("Lumen catalog: folder registration failed — %@",
                      String(describing: error))
                self.onFailure?("Could not register \(folder.lastPathComponent) "
                                + "with the catalog — \(error)")
            }
        }
        return result
    }

    /// Fill in capture metadata for photos that have none.
    ///
    /// Runs AFTER the grid is on screen and off the main actor, because reading EXIF
    /// costs a file open per photo and the scan is what stands between the user and
    /// their first grid — docs/16 gates that under a second for five thousand photos.
    /// Metadata is what ten of the twelve sort orders, the capture-time grouping, the
    /// filter chips and duplicate detection all read, and until now nothing wrote it,
    /// so every one of them was reading NULL.
    ///
    /// Interruptible by construction: `capture_at IS NULL` is the resume marker, so
    /// quitting halfway costs nothing and the next launch continues. Batched into
    /// transactions of 200 because 5,000 individual commits is a minute of fsync.
    func backfillMetadata(folder: URL, onProgress: ((Int, Int) -> Void)? = nil) {
        queue.async { [store, weak self] in
            do {
                let folderID = try store.registerFolder(path: folder.path)
                let pending = try store.photosMissingMetadata(folderID: folderID)
                guard !pending.isEmpty else { return }
                var done = 0
                for chunk in stride(from: 0, to: pending.count, by: 200).map({
                    Array(pending[$0..<Swift.min($0 + 200, pending.count)])
                }) {
                    let read: [(photoID: Int64, metadata: PhotoMetadata)] =
                        chunk.compactMap { row in
                            let url = folder.appendingPathComponent(row.filename)
                            guard let metadata = CaptureMetadataReader.read(url: url)
                            else { return nil }
                            return (photoID: row.id, metadata: metadata)
                        }
                    try store.setMetadata(read)
                    done += chunk.count
                    onProgress?(done, pending.count)
                }
            } catch {
                // Not surfaced to the user: metadata is an enrichment, and a folder
                // whose EXIF could not be read still browses, culls and edits. Saying
                // so would be noise on a path nobody asked for.
                NSLog("Lumen catalog: metadata backfill stopped — %@",
                      String(describing: error))
                _ = self
            }
        }
    }

    /// Reconcile what the catalog knows with what the sidecar says. The sidecar wins
    /// where the catalog is silent: a photo moved in from another machine, or restored
    /// from a backup, should arrive with its work attached.
    private static func merge(row: PhotoRow, recipe: Recipe?, file: URL) -> StoredState {
        // The rule — "the sidecar fills in where the catalog is silent, and never
        // overwrites it" — lives in `SidecarMerge`, in LumenCore, where it can be
        // tested. This function owns only the file read and the enum mapping.
        let merged = SidecarMerge.resolve(
            catalog: SidecarMerge.State(rating: row.rating,
                                        flag: sidecarFlag(row.flag),
                                        label: row.label,
                                        recipe: recipe),
            sidecar: readSidecar(for: file))

        return StoredState(catalogID: row.id,
                           flag: photoFlag(merged.flag),
                           rating: merged.rating,
                           label: Self.label(named: merged.label),
                           recipe: merged.recipe,
                           iso: row.iso)
    }

    /// Write back whatever the sidecar filled in, so the catalog agrees with the grid.
    ///
    /// Only fields the merge actually CHANGED are written: `SidecarMerge.resolve` never
    /// overwrites a value the catalog holds, so a difference here means the catalog was
    /// silent and the sidecar spoke. Writing unconditionally would be a no-op storm on
    /// every folder open, and writing a recipe that came from the catalog back into the
    /// catalog would make a new version row per launch.
    private static func persistRecovered(_ state: StoredState, row: PhotoRow,
                                         storedRecipe: Recipe?, store: CatalogStore) {
        do {
            if state.rating != row.rating {
                try store.setRating(state.rating, photoID: row.id)
            }
            if state.flag != row.flag {
                try store.setFlag(state.flag, photoID: row.id)
            }
            let mergedLabel = state.label?.rawValue
            if mergedLabel != row.label {
                try store.setLabel(state.label, photoID: row.id)
            }
            if storedRecipe == nil, let recovered = state.recipe {
                try store.saveRecipe(recovered, photoID: row.id, isCurrent: true)
            }
        } catch {
            // A recovery that cannot be persisted is not worth failing the folder open
            // over: the grid still shows the merged state for this session, and the next
            // launch will try again from the same sidecar.
            NSLog("Lumen catalog: could not persist sidecar recovery — %@",
                  String(describing: error))
        }
    }

    // MARK: - Culling state

    func saveCullingState(_ photo: PhotoItem) {
        guard let id = photo.catalogID else { return }
        let flag = photo.flag
        let rating = photo.rating
        let label = photo.label
        let url = photo.id
        queue.async {
            do {
                try self.store.setFlag(flag, photoID: id)
                try self.store.setRating(rating, photoID: id)
                try self.store.setLabel(label, photoID: id)
            } catch {
                NSLog("Lumen catalog: culling write failed — %@", String(describing: error))
                self.onFailure?("Could not save the flag or rating — \(error)")
            }
            self.enqueueSidecar(
                for: url, rating: rating, flag: Self.sidecarFlag(flag),
                label: .some(label?.rawValue),
                recipe: nil)
        }
    }

    // MARK: - Recipes

    func saveRecipe(_ recipe: Recipe, url: URL, catalogID: Int64?) {
        // If a recipe cannot be canonicalized, write NOTHING. The previous code fell
        // back to "{}" and "xxh64:0", which wrote an empty recipe over the sidecar —
        // turning a render failure into the loss of the user's edit, silently, in the
        // copy whose entire purpose is to survive losing the catalog. Every such
        // failure also shared one fingerprint, so they collided in the cache.
        // Canonicalizing happens on the QUEUE, not here.
        //
        // This used to run before the hop, so every frame of every slider drag paid for
        // it on the main actor: `canonicalRecipeJSON` is a full `JSONEncoder.encode`
        // plus a `JSONDecoder.decode` into an indirect enum tree, and it does that for
        // the recipe AND for a freshly built `Recipe()` baseline; `fingerprint` then
        // calls the same function again on `renderIdentity`. Four encodes and four
        // decodes of the whole recipe, per mouse event, to produce a string that was
        // immediately handed to a background queue anyway.
        //
        // `updateRecipe` loops over `editTargets`, so a forty-frame batch drag was
        // paying it forty times per event. That does not lag, it locks — and it is the
        // largest single cost on the path between the cursor and the picture.
        //
        // Nothing here needs the result synchronously. The guard that refuses to write
        // an uncanonicalizable recipe still runs, just one hop later, and still writes
        // NOTHING rather than falling back to "{}" — which is what once put an empty
        // recipe over a sidecar and lost the edit it existed to protect.
        queue.async {
            guard let json = try? CanonicalJSON.canonicalRecipeJSON(recipe),
                  let fingerprint = try? RecipeFingerprint.fingerprint(recipe) else {
                NSLog("Lumen catalog: refusing to write an uncanonicalizable recipe for %@",
                      url.lastPathComponent)
                self.onFailure?("Could not save the edit for \(url.lastPathComponent) — "
                                + "it contains a value the recipe format cannot represent")
                return
            }
            if let id = catalogID {
                do {
                    try self.store.saveRecipe(recipe, photoID: id, isCurrent: true)
                } catch {
                    NSLog("Lumen catalog: recipe write failed — %@", String(describing: error))
                    self.onFailure?("Could not save the edit for "
                                    + "\(url.lastPathComponent) — \(error)")
                }
            }
            self.enqueueSidecar(for: url, rating: nil, label: nil,
                                recipe: (json, fingerprint, recipe.pipelineVersion))
        }
    }

    // MARK: - Queries

    /// Every read below is the same three steps — hop to the serial queue, run one
    /// store call, hop back — and writing them out twenty times is twenty chances to
    /// forget the hop and stall the main actor mid-cull.
    ///
    /// Failures return the fallback and are logged rather than thrown. A filter that
    /// cannot reach the catalog degrades to showing everything, which is the same
    /// posture the rest of this file takes: losing the catalog costs speed, never work,
    /// and never a modal in the middle of a culling pass.
    private func onQueue<T: Sendable>(_ what: String, fallback: T,
                                      _ body: @escaping @Sendable (CatalogStore) throws -> T)
        async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { [store] in
                do {
                    continuation.resume(returning: try body(store))
                } catch {
                    NSLog("Lumen catalog: %@ failed — %@", what, String(describing: error))
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    /// Filter and sort in SQL rather than in Swift, which is what keeps a
    /// 100,000-frame archive responsive — and what makes the eight sort orders that
    /// need capture time, camera, ISO or aspect possible at all.
    func photos(matching query: PhotoQuery, folderPath: String?) async -> [PhotoRow] {
        await onQueue("grid query", fallback: []) { store in
            let folderID = try folderPath.flatMap { try store.folder(path: $0)?.id }
            return try store.photos(matching: query, folderID: folderID)
        }
    }

    /// The values a metadata chip offers, with live counts.
    func facets(_ facet: PhotoFacet, folderPath: String?) async -> [FacetValue] {
        await onQueue("metadata chip values", fallback: []) { store in
            let folderID = try folderPath.flatMap { try store.folder(path: $0)?.id }
            return try store.facetCounts(facet, folderID: folderID)
        }
    }

    // MARK: - Collections

    /// Albums with their membership counts, which is what the sidebar shows. Counted
    /// through the same query builder the grid uses, so an album row and the grid it
    /// opens can never report different numbers.
    func collections() async -> [CollectionItem] {
        await onQueue("album list", fallback: []) { store in
            var out: [CollectionItem] = []
            for album in try store.collections() {
                var query = PhotoQuery()
                query.albumID = album.id
                let count = try store.countPhotos(matching: query)
                out.append(CollectionItem(id: album.id, name: album.name,
                                          count: count, isTarget: album.isTarget))
            }
            return out
        }
    }

    func createCollection(name: String) async -> Int64? {
        await onQueue("album creation", fallback: nil) { (store: CatalogStore) -> Int64? in
            let id = try store.createCollection(name: name)
            // The first album a photographer makes becomes the target, so `⌘B` does
            // something the moment there is somewhere for it to put a photo.
            if (try store.targetCollectionID()) == nil {
                try store.setTargetCollection(id)
            }
            return id
        }
    }

    func setTargetCollection(_ albumID: Int64) async {
        await onQueue("target album", fallback: ()) { try $0.setTargetCollection(albumID) }
    }

    func addToCollection(_ albumID: Int64, photoIDs: [Int64]) async {
        await onQueue("album membership", fallback: ()) {
            try $0.addToCollection(albumID, photoIDs: photoIDs)
        }
    }

    func removeFromCollection(_ albumID: Int64, photoIDs: [Int64]) async {
        await onQueue("album membership", fallback: ()) {
            try $0.removeFromCollection(albumID, photoIDs: photoIDs)
        }
    }

    // MARK: - Keywords

    func keywords(photoID: Int64) async -> [String] {
        await onQueue("keyword read", fallback: []) { try $0.keywords(photoID: photoID) }
    }

    func allKeywords() async -> [FacetValue] {
        await onQueue("keyword list", fallback: []) { try $0.allKeywords() }
    }

    func addKeyword(_ name: String, photoIDs: [Int64]) async {
        await onQueue("keyword write", fallback: ()) {
            _ = try $0.addKeyword(name, photoIDs: photoIDs)
        }
    }

    func removeKeyword(_ name: String, photoIDs: [Int64]) async {
        await onQueue("keyword write", fallback: ()) {
            try $0.removeKeyword(name, photoIDs: photoIDs)
        }
    }

    // MARK: - Per-source view state

    /// What a source remembers about how it was being looked at (docs/10 §10.2: sort
    /// key and direction are per-source memory, not one global setting). A struct
    /// rather than the store's tuple so it can cross the queue as a `Sendable` value.
    struct SourceViewState: Sendable {
        var sortKey: String
        var ascending: Bool
        var thumbnailSize: Int
    }

    func sourceState(_ key: String) async -> SourceViewState? {
        await onQueue("view state", fallback: nil) { (store: CatalogStore) -> SourceViewState? in
            guard let stored = try store.sourceState(key) else { return nil }
            return SourceViewState(sortKey: stored.sortKey, ascending: stored.ascending,
                                   thumbnailSize: stored.thumbPx)
        }
    }

    func setSourceState(_ key: String, _ value: SourceViewState) async {
        await onQueue("view state", fallback: ()) {
            // `filterJSON` stays nil: the filter bar's state is deliberately NOT
            // restored. A grid that comes back empty because yesterday's chips are
            // still lit is the single most-complained-about behaviour in the app this
            // one is trying to be better than.
            try $0.setSourceState(key, sortKey: value.sortKey,
                                  ascending: value.ascending,
                                  thumbPx: value.thumbnailSize, filterJSON: nil)
        }
    }

    // MARK: - Stacks

    /// Group a selection, with the frame under the cursor as the pick. Returns the
    /// stack so the caller can say how many frames went into it.
    func createStack(photoIDs: [Int64], pickPhotoID: Int64?) async -> Int64? {
        await onQueue("stack creation", fallback: nil) { (store: CatalogStore) -> Int64? in
            try store.createStack(origin: "manual", photoIDs: photoIDs,
                                  pickPhotoID: pickPhotoID)
        }
    }

    func stack(containing photoID: Int64) async -> StackRow? {
        await onQueue("stack lookup", fallback: nil) { (store: CatalogStore) -> StackRow? in
            try store.stack(containing: photoID)
        }
    }

    func stackMembers(stackID: Int64) async -> [Int64] {
        await onQueue("stack members", fallback: []) { try $0.stackMembers(stackID: stackID) }
    }

    func setStackCollapsed(_ collapsed: Bool, stackID: Int64) async {
        await onQueue("stack collapse", fallback: ()) {
            try $0.setStackCollapsed(collapsed, stackID: stackID)
        }
    }

    func setStackPick(_ photoID: Int64, stackID: Int64) async {
        await onQueue("stack pick", fallback: ()) {
            try $0.setStackPick(photoID, stackID: stackID)
        }
    }

    func dissolveStack(id: Int64) async {
        await onQueue("unstack", fallback: ()) { try $0.dissolveStack(id: id) }
    }

    // MARK: - Enum bridging

    static func sidecarFlag(_ flag: PhotoFlag) -> SidecarFlag {
        switch flag {
        case .pick: return .pick
        case .reject: return .reject
        case .unflagged: return .none
        }
    }

    static func photoFlag(_ flag: SidecarFlag) -> PhotoFlag {
        switch flag {
        case .pick: return .pick
        case .reject: return .reject
        case .none: return .unflagged
        }
    }

    /// The catalog column and the XMP sidecar both store the lowercased key, which is
    /// exactly `ColorLabel.rawValue` — so this one function is the whole of what
    /// `appLabel` and `coreLabel` used to do between them, and the `PhotoFlag` pair
    /// they sat beside is gone entirely: with one flag enum instead of two spellings
    /// of one, `coreFlag` had nothing left to convert.
    ///
    /// Lowercasing survives because a sidecar written by another application may
    /// capitalize; an unrecognised name is unlabelled, exactly as it was before.
    static func label(named name: String?) -> ColorLabel? {
        name.flatMap { ColorLabel(rawValue: $0.lowercased()) }
    }

    // MARK: - Sidecars

    /// `label` is double-optional on purpose. `nil` means "this call has nothing to
    /// say about the label"; `.some(nil)` means "the label was cleared". Collapsing
    /// the two meant clearing a red label wrote the catalog but left the sidecar
    /// saying red — and the next scan's merge read the sidecar and put red back.
    private func enqueueSidecar(for url: URL, rating: Int?, flag: SidecarFlag? = nil,
                                label: String??,
                                recipe: (json: String, fingerprint: String, version: Int)?) {
        sidecarLock.lock()
        var content = pendingSidecars[url] ?? Self.readSidecar(for: url) ?? SidecarContent()
        if let rating { content.rating = rating }
        if let flag { content.flag = flag }
        if let label { content.label = label }
        if let recipe {
            content.recipeJSON = recipe.json
            content.recipeFingerprint = recipe.fingerprint
            content.pipelineVersion = recipe.version
        }
        content.writeStamp = ISO8601DateFormatter().string(from: Date())
        pendingSidecars[url] = content
        let shouldSchedule = !sidecarFlushScheduled
        sidecarFlushScheduled = true
        sidecarLock.unlock()

        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + Self.sidecarDebounce) {
            self.flushSidecars()
        }
    }

    func flushSidecars() {
        sidecarLock.lock()
        let batch = pendingSidecars
        pendingSidecars = [:]
        sidecarFlushScheduled = false
        sidecarLock.unlock()

        for (url, content) in batch {
            let path = Self.sidecarURL(for: url)

            // An existing sidecar is somebody else's document that Lumen is allowed to
            // add three fields to — NOT a file Lumen owns. `serialize` builds a whole
            // document from an eight-field struct, so writing it over a sidecar that
            // came from Lightroom, Bridge, Camera Raw or exiftool deleted every
            // develop setting, keyword, capture date and colour label in it. That
            // happened on the first rating keystroke, to photos Lumen had never
            // rendered, with no backup and no undo.
            //
            // So: splice into what is there. If the document cannot be edited safely,
            // leave it completely alone. The rating is still in the catalog; the
            // user's work in that file is not recoverable from anywhere.
            let text: String
            if let existing = try? String(contentsOf: path, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let merged = XMPSidecar.update(existing, with: content) else {
                    NSLog("Lumen: left %@ untouched — it is not a sidecar this "
                          + "version knows how to edit without losing its contents",
                          path.lastPathComponent)
                    continue
                }
                text = merged
            } else {
                text = XMPSidecar.serialize(content)
            }

            do {
                // Atomic: a sidecar half-written by a crash is worse than no sidecar.
                try Data(text.utf8).write(to: path, options: .atomic)
            } catch {
                NSLog("Lumen: sidecar write failed for %@ — %@", path.lastPathComponent,
                      String(describing: error))
            }
        }
    }

    /// Where a photo's sidecar lives.
    ///
    /// RAW files get `NAME.xmp` — the Adobe convention every other tool reads. Anything
    /// else gets `NAME.EXT.xmp`, which is also the Adobe convention, and which is the
    /// part that was missing: stripping the extension from both halves of a RAW+JPEG
    /// pair pointed `DSC_0001.NEF` and `DSC_0001.JPG` at one `DSC_0001.xmp`. Both are
    /// browsable, so on a card shot RAW+JPEG editing the JPEG overwrote the RAW's
    /// recipe and vice versa — half the frames on the card, with the promise that
    /// losing the catalog costs speed and never work quietly false for all of them.
    static func sidecarURL(for photo: URL) -> URL {
        guard PhotoFormats.isRaw(photo) else {
            return photo.appendingPathExtension("xmp")
        }
        return photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func readSidecar(for photo: URL) -> SidecarContent? {
        let url = sidecarURL(for: photo)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return XMPSidecar.parse(data)
    }

    // MARK: - Maintenance

    /// `VACUUM INTO` gives a consistent snapshot without stopping the world.
    func backup() {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let target = self.directory
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent("lumen-\(stamp).db")
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try self.store.backup(to: target.path)
            } catch {
                NSLog("Lumen catalog: backup failed — %@", String(describing: error))
            }
        }
    }

    func close() {
        // Drain first, THEN flush. `saveCullingState` and `saveRecipe` are `queue.async`
        // and call `enqueueSidecar` at the END of their work, so on a backlogged queue —
        // a metadata backfill is the usual cause — a rating pressed just before quitting
        // is still queued when `close()` runs. Flushing first wrote an empty batch; the
        // `queue.sync` below then let that save run, enqueue its sidecar, and close the
        // store, and the app terminated with the edit in the catalog and no sidecar. The
        // sidecar is the recovery copy, so the one edit most likely to be lost was the
        // last one made.
        queue.sync {}
        flushSidecars()
        queue.sync { store.close() }
    }
}

#endif
