// BlobStore.swift
// Content-addressed storage for the payloads a recipe references rather than contains:
// brush stroke sets today, imported LUTs and AI mattes on the same shelf later.
//
// A recipe is meant to stay small and diffable — a mask component carries
// `blob:xxh64:<hash>`, not forty kilobytes of stylus samples. That reference is only
// worth anything if the bytes behind it are somewhere the next launch can find them,
// which is what this is.
//
// Content addressing does the housekeeping. The name of a blob is the hash of its
// contents, so writing the same strokes twice is one file, two photos sharing a
// brushed mask is one file, and a write is idempotent — which means it is also safe
// to repeat after a crash. Nothing here ever overwrites: if the file exists, its
// contents already hash to this name.

import Foundation

/// A directory of content-addressed payloads. Reads are cached in memory because a
/// render asks for the same stroke set on every frame of a slider drag.
public final class BlobStore: @unchecked Sendable {

    public let directory: URL

    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    /// Cheap insurance against a runaway cache on a long session: stroke sets are a
    /// few tens of kilobytes, so this is generous and still bounded.
    private static let cacheLimit = 256

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Backup

    /// Copy every payload into `directory`, beside a catalog snapshot (K-018).
    ///
    /// THE BACKUP WAS NOT A BACKUP OF THE MASKS. `CatalogStore.backup` is
    /// `VACUUM main INTO`, which snapshots the catalog database and nothing else, and
    /// the brush strokes do not live there — they live here, as content-addressed files
    /// beside it. So a restore gave back every recipe intact, each one referencing a
    /// `strokesRef` whose bytes were never copied, and every brush mask in the library
    /// rasterized to nothing. The sidecar is not the second copy either: it carries
    /// strokes only up to its size cap.
    ///
    /// Content addressing makes this cheap and safe to repeat. A payload's name IS its
    /// digest, so a file that is already there is already correct — nothing is
    /// overwritten, and a second backup into the same place copies only what is new.
    ///
    /// Returns the number of payloads copied, so the caller can say something true
    /// about what it just protected.
    @discardableResult
    public func backUp(to destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        var copied = 0
        for name in names where name.hasSuffix(".blob") {
            let target = destination.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: directory.appendingPathComponent(name), to: target)
            copied += 1
        }
        return copied
    }

    /// Put payloads back from a backup, next to a restored catalog.
    ///
    /// The other half, and it has to exist for the same reason: a catalog restored
    /// without its blobs is a library of empty masks. Never overwrites — a payload
    /// present in the live store is, by content addressing, the same bytes, and the
    /// live one may be NEWER work that the restore has no business replacing.
    @discardableResult
    public func restore(from source: URL) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return 0 }
        let names = try fm.contentsOfDirectory(atPath: source.path)
        var restored = 0
        for name in names where name.hasSuffix(".blob") {
            let target = directory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: source.appendingPathComponent(name), to: target)
            restored += 1
        }
        if restored > 0 {
            lock.lock()
            cache.removeAll()
            lock.unlock()
        }
        return restored
    }

    /// Where a reference lives on disk. A ref is `blob:xxh64:<16 hex>`; anything else
    /// is refused rather than turned into a path, because a reference arriving from a
    /// sidecar written elsewhere is untrusted input and `../../` is a valid string.
    public func url(for ref: String) -> URL? {
        guard let name = BlobStore.filename(for: ref) else { return nil }
        return directory.appendingPathComponent(name)
    }

    static func filename(for ref: String) -> String? {
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "blob" else { return nil }
        let algorithm = String(parts[1])
        let digest = String(parts[2])
        guard algorithm == "xxh64",
              digest.count == 16,
              // `isHexDigit` is Unicode Hex_Digit, which admits fullwidth ０-９ and
              // ａ-ｆ. Harmless here — neither contains a separator — but the whole
              // job of this function is refusing input it did not write.
              digest.allSatisfy({ $0.isASCII && $0.isHexDigit
                                  && ($0.isNumber || $0.isLowercase) })
        else { return nil }
        return algorithm + "-" + digest + ".blob"
    }

    // MARK: - Reading and writing

    public func data(for ref: String) -> Data? {
        lock.lock()
        if let hit = cache[ref] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let url = url(for: ref), let data = try? Data(contentsOf: url) else { return nil }
        remember(ref, data)
        return data
    }

    /// Store `data` and return the reference that addresses it. The caller does not
    /// choose the name — the bytes do.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let ref = BrushStrokeSet.blobRef(for: data)
        guard let url = url(for: ref) else { throw BlobStoreError.malformedReference(ref) }
        if !FileManager.default.fileExists(atPath: url.path) {
            // Write beside and rename: a torn blob would be a stroke set that hashes
            // to a name whose contents are not it.
            let temporary = directory.appendingPathComponent(
                "." + UUID().uuidString + ".partial")
            try data.write(to: temporary, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch {
                // Somebody else stored the same bytes first, which is the one outcome
                // content addressing lets us shrug at.
                try? FileManager.default.removeItem(at: temporary)
                guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            }
        }
        remember(ref, data)
        return ref
    }

    private func remember(_ ref: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= BlobStore.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[ref] = data
    }

    // MARK: - Stroke sets

    public func strokeSet(for ref: String) -> BrushStrokeSet? {
        guard let data = data(for: ref) else { return nil }
        return try? BrushStrokeSet.decode(data)
    }

    @discardableResult
    public func store(_ set: BrushStrokeSet) throws -> String {
        try store(set.encode())
    }

    /// Every stroke set a recipe's masks refer to, keyed by reference — exactly the
    /// shape the rasterizer wants. Missing blobs are skipped rather than faked: a
    /// brush component with no bytes behind it must rasterize to nothing, not to a
    /// mask somebody else painted.
    public func strokeSets(for recipe: Recipe) -> [String: BrushStrokeSet] {
        var out: [String: BrushStrokeSet] = [:]
        for mask in recipe.masks {
            for component in mask.components where component.kind == .brush {
                guard let ref = component.strokesRef, out[ref] == nil else { continue }
                if let set = strokeSet(for: ref) { out[ref] = set }
            }
        }
        return out
    }
}

public enum BlobStoreError: Error, Equatable {
    case malformedReference(String)
}
