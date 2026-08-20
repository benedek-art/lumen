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

final class CatalogService: @unchecked Sendable {

    struct StoredState {
        var catalogID: Int64
        var flag: PhotoFlag
        var rating: Int
        var label: ColorLabel
        var recipe: Recipe?
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
                    return ScannedFile(filename: file.lastPathComponent,
                                       fileSize: size, fileMTime: mtime,
                                       ext: file.pathExtension.lowercased())
                }
                _ = try store.scan(folderID: folderID, files: scanned,
                                   at: CatalogStore.now())

                for file in files {
                    guard let row = try store.photo(folderID: folderID,
                                                    filename: file.lastPathComponent)
                    else { continue }
                    let recipe = try store.currentRecipe(photoID: row.id)
                    result[file] = Self.merge(row: row, recipe: recipe, file: file)
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

    /// Reconcile what the catalog knows with what the sidecar says. The sidecar wins
    /// where the catalog is silent: a photo moved in from another machine, or restored
    /// from a backup, should arrive with its work attached.
    private static func merge(row: PhotoRow, recipe: Recipe?, file: URL) -> StoredState {
        // The rule — "the sidecar fills in where the catalog is silent, and never
        // overwrites it" — lives in `SidecarMerge`, in LumenCore, where it can be
        // tested. This function owns only the file read and the enum mapping.
        let merged = SidecarMerge.resolve(
            catalog: SidecarMerge.State(rating: row.rating,
                                        flag: sidecarFlag(appFlag(row.flag)),
                                        label: row.label,
                                        recipe: recipe),
            sidecar: readSidecar(for: file))

        return StoredState(catalogID: row.id,
                           flag: appFlag(merged.flag),
                           rating: merged.rating,
                           label: appLabel(merged.label),
                           recipe: merged.recipe)
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
                try self.store.setFlag(Self.coreFlag(flag), photoID: id)
                try self.store.setRating(rating, photoID: id)
                try self.store.setLabel(Self.coreLabel(label), photoID: id)
            } catch {
                NSLog("Lumen catalog: culling write failed — %@", String(describing: error))
                self.onFailure?("Could not save the flag or rating — \(error)")
            }
            self.enqueueSidecar(
                for: url, rating: rating, flag: Self.sidecarFlag(flag),
                label: .some(label == .none ? nil : label.displayName.lowercased()),
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
        guard let json = try? CanonicalJSON.canonicalRecipeJSON(recipe),
              let fingerprint = try? RecipeFingerprint.fingerprint(recipe) else {
            NSLog("Lumen catalog: refusing to write an uncanonicalizable recipe for %@",
                  url.lastPathComponent)
            onFailure?("Could not save the edit for \(url.lastPathComponent) — "
                       + "it contains a value the recipe format cannot represent")
            return
        }
        queue.async {
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

    /// Filter and sort in SQL rather than in Swift, which is what keeps a
    /// 100,000-frame archive responsive.
    func photos(matching query: PhotoQuery, folderPath: String?) -> [PhotoRow] {
        var rows: [PhotoRow] = []
        queue.sync {
            do {
                let folderID = try folderPath.flatMap { try store.folder(path: $0)?.id }
                rows = try store.photos(matching: query, folderID: folderID)
            } catch {
                NSLog("Lumen catalog: query failed — %@", String(describing: error))
            }
        }
        return rows
    }

    // MARK: - Enum bridging

    static func sidecarFlag(_ flag: PhotoFlag) -> SidecarFlag {
        switch flag {
        case .picked: return .pick
        case .rejected: return .reject
        case .none: return .none
        }
    }

    static func appFlag(_ flag: SidecarFlag) -> PhotoFlag {
        switch flag {
        case .pick: return .picked
        case .reject: return .rejected
        case .none: return .none
        }
    }

    // The app and the catalog each name these for their own audience. One conversion
    // in one place beats qualifying every call site.

    static func appFlag(_ flag: LumenCore.PhotoFlag) -> PhotoFlag {
        switch flag {
        case .pick: return .picked
        case .reject: return .rejected
        case .unflagged: return .none
        }
    }

    static func coreFlag(_ flag: PhotoFlag) -> LumenCore.PhotoFlag {
        switch flag {
        case .picked: return .pick
        case .rejected: return .reject
        case .none: return .unflagged
        }
    }

    static func appLabel(_ name: String?) -> ColorLabel {
        guard let name = name?.lowercased() else { return .none }
        for candidate in ColorLabel.allCases
        where candidate.displayName.lowercased() == name {
            return candidate
        }
        return .none
    }

    static func coreLabel(_ label: ColorLabel) -> LumenCore.ColorLabel? {
        switch label {
        case .none: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
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
            let text = XMPSidecar.serialize(content)
            do {
                // Atomic: a sidecar half-written by a crash is worse than no sidecar.
                try Data(text.utf8).write(to: path, options: .atomic)
            } catch {
                NSLog("Lumen: sidecar write failed for %@ — %@", path.lastPathComponent,
                      String(describing: error))
            }
        }
    }

    static func sidecarURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
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
        flushSidecars()
        queue.sync { store.close() }
    }
}

#endif
