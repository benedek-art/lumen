// CatalogService.swift
// Persistence, with the trust posture docs/15 asks for: originals are read-only
// forever, the catalog is one SQLite file, and every recipe also lands in a
// human-readable XMP sidecar beside the photo. If the catalog is ever lost or
// corrupted, the sidecars still carry the work — that is the second copy's whole job,
// and it is why deleting the catalog is a recoverable event rather than a disaster.
//
// All database work happens on a serial queue off the main actor (docs/13 §3 rule 4).
// Sidecar writes are debounced and atomic: a folder of 800 frames being rated quickly
// must not turn into 800 file writes a second.

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

    private let database: SQLiteDatabase
    private let queue = DispatchQueue(label: "dev.lumenapp.catalog", qos: .utility)
    private let directory: URL

    /// Sidecar writes coalesce over this window, so a fast rating pass writes once per
    /// photo rather than once per keystroke.
    private static let sidecarDebounce: TimeInterval = 2.0
    private var pendingSidecars: [URL: SidecarContent] = [:]
    private var sidecarFlushScheduled = false
    private let sidecarLock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        let path = directory.appendingPathComponent("lumen.db").path
        let existed = FileManager.default.fileExists(atPath: path)
        self.database = try SQLiteDatabase(path: path)

        // Pragmas before any DDL: auto_vacuum in particular can only be set on an
        // empty database, and WAL is what keeps a background write from blocking a read.
        try database.execute("PRAGMA journal_mode=WAL;")
        try database.execute("PRAGMA foreign_keys=ON;")
        try database.execute("PRAGMA synchronous=NORMAL;")
        if !existed {
            try database.execute("PRAGMA auto_vacuum=INCREMENTAL;")
        }

        let version = try database.userVersion()
        if version == 0 {
            try database.execute(CatalogSchema.lumenDDL)
            try database.setUserVersion(CatalogSchema.schemaVersion)
        }
    }

    // MARK: - Folders and photos

    /// Register a folder, reconcile its files, and return everything already known
    /// about them. Called from a background task — it is one transaction, so a
    /// 5,000-frame folder is a single fsync rather than five thousand.
    func registerAndLoad(folder: URL, files: [URL]) -> [URL: StoredState] {
        var result: [URL: StoredState] = [:]
        queue.sync {
            do {
                try database.transaction {
                    let folderID = try self.upsertFolder(folder)
                    for file in files {
                        let attributes = try? FileManager.default.attributesOfItem(
                            atPath: file.path)
                        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                        let mtime = ((attributes?[.modificationDate] as? Date)?
                            .timeIntervalSince1970).map { Int64($0) } ?? 0
                        let id = try self.upsertPhoto(folderID: folderID, file: file,
                                                      size: size, mtime: mtime)
                        result[file] = try self.loadState(photoID: id, file: file)
                    }
                }
            } catch {
                NSLog("Lumen catalog: folder registration failed — %@",
                      String(describing: error))
            }
        }
        return result
    }

    private func upsertFolder(_ url: URL) throws -> Int64 {
        let path = url.path
        if let existing = try database.scalarInt(
            "SELECT id FROM folder WHERE path = ?1", [.text(path)]) {
            _ = try database.run(
                "UPDATE folder SET online = 1, last_scanned_at = ?2 WHERE id = ?1",
                [.integer(existing), .integer(Int64(Date().timeIntervalSince1970))])
            return existing
        }
        _ = try database.run(
            "INSERT INTO folder (path, online, last_scanned_at) VALUES (?1, 1, ?2)",
            [.text(path), .integer(Int64(Date().timeIntervalSince1970))])
        return database.lastInsertRowID
    }

    private func upsertPhoto(folderID: Int64, file: URL, size: Int64,
                             mtime: Int64) throws -> Int64 {
        let name = file.lastPathComponent
        if let existing = try database.scalarInt(
            "SELECT id FROM photo WHERE folder_id = ?1 AND filename = ?2",
            [.integer(folderID), .text(name)]) {
            _ = try database.run(
                "UPDATE photo SET file_size = ?2, file_mtime = ?3, missing = 0 WHERE id = ?1",
                [.integer(existing), .integer(size), .integer(mtime)])
            return existing
        }
        _ = try database.run(
            """
            INSERT INTO photo (folder_id, filename, file_size, file_mtime)
            VALUES (?1, ?2, ?3, ?4)
            """,
            [.integer(folderID), .text(name), .integer(size), .integer(mtime)])
        return database.lastInsertRowID
    }

    private func loadState(photoID: Int64, file: URL) throws -> StoredState {
        var flag = PhotoFlag.none
        var rating = 0
        var label = ColorLabel.none

        let statement = try database.prepare(
            "SELECT flag, rating, label FROM photo WHERE id = ?1")
        defer { statement.finalizeStatement() }
        try statement.bind(1, photoID)
        if try statement.step() {
            flag = PhotoFlag(rawValue: Int(statement.int(0))) ?? .none
            rating = Int(statement.int(1))
            label = Self.label(named: statement.string(2))
        }

        var recipe = try currentRecipe(photoID: photoID)

        // The sidecar is authoritative when it is newer than what we stored: the user
        // may have edited elsewhere, restored from backup, or moved the file in with
        // its sidecar attached.
        if let sidecar = Self.readSidecar(for: file) {
            if let json = sidecar.recipeJSON,
               let parsed = try? CanonicalJSON.decodeRecipe(from: Data(json.utf8)) {
                if recipe == nil { recipe = parsed }
            }
            if rating == 0, sidecar.rating > 0 { rating = sidecar.rating }
            if label == .none, let name = sidecar.label {
                label = Self.label(named: name)
            }
        }

        return StoredState(catalogID: photoID, flag: flag, rating: rating,
                           label: label, recipe: recipe)
    }

    // MARK: - Culling state

    func saveCullingState(_ photo: PhotoItem) {
        guard let id = photo.catalogID else { return }
        let flag = photo.flag.rawValue
        let rating = photo.rating
        let labelName = photo.label == .none ? nil : photo.label.displayName.lowercased()
        let url = photo.id
        queue.async {
            do {
                _ = try self.database.run(
                    "UPDATE photo SET flag = ?2, rating = ?3, label = ?4 WHERE id = ?1",
                    [.integer(id), .integer(Int64(flag)), .integer(Int64(rating)),
                     labelName.map { SQLiteValue.text($0) } ?? .null])
            } catch {
                NSLog("Lumen catalog: culling write failed — %@", String(describing: error))
            }
            self.enqueueSidecar(for: url, rating: rating, label: labelName, recipe: nil)
        }
    }

    // MARK: - Recipes

    func saveRecipe(_ recipe: Recipe, url: URL, catalogID: Int64?) {
        let json = (try? CanonicalJSON.canonicalRecipeJSON(recipe)) ?? "{}"
        let fingerprint = (try? RecipeFingerprint.fingerprint(recipe)) ?? "xxh64:0"
        queue.async {
            if let id = catalogID {
                do {
                    try self.database.transaction {
                        _ = try self.database.run(
                            "UPDATE edit SET is_current = 0 WHERE photo_id = ?1",
                            [.integer(id)])
                        _ = try self.database.run(
                            """
                            INSERT INTO edit (photo_id, kind, is_current, pipeline_version,
                                              recipe, recipe_fp, updated_at)
                            VALUES (?1, 'working', 1, ?2, ?3, ?4, ?5)
                            """,
                            [.integer(id), .integer(Int64(recipe.pipelineVersion)),
                             .text(json), .text(fingerprint),
                             .integer(Int64(Date().timeIntervalSince1970))])
                    }
                } catch {
                    NSLog("Lumen catalog: recipe write failed — %@", String(describing: error))
                }
            }
            self.enqueueSidecar(for: url, rating: nil, label: nil,
                                recipe: (json, fingerprint, recipe.pipelineVersion))
        }
    }

    private func currentRecipe(photoID: Int64) throws -> Recipe? {
        let statement = try database.prepare(
            "SELECT recipe FROM edit WHERE photo_id = ?1 AND is_current = 1 "
            + "ORDER BY updated_at DESC LIMIT 1")
        defer { statement.finalizeStatement() }
        try statement.bind(1, photoID)
        guard try statement.step(), let json = statement.string(0) else { return nil }
        return try? CanonicalJSON.decodeRecipe(from: Data(json.utf8))
    }

    // MARK: - Sidecars

    private func enqueueSidecar(for url: URL, rating: Int?, label: String?,
                                recipe: (json: String, fingerprint: String, version: Int)?) {
        sidecarLock.lock()
        var content = pendingSidecars[url] ?? Self.readSidecar(for: url) ?? SidecarContent()
        if let rating { content.rating = rating }
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
                try text.data(using: .utf8)?.write(to: path, options: .atomic)
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

    private static func label(named name: String?) -> ColorLabel {
        guard let name = name?.lowercased() else { return .none }
        for candidate in ColorLabel.allCases
        where candidate.displayName.lowercased() == name {
            return candidate
        }
        return .none
    }

    // MARK: - Maintenance

    /// `VACUUM INTO` gives a consistent snapshot without stopping the world — the
    /// backup discipline docs/15 asks for.
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
                _ = try self.database.run("VACUUM INTO ?1", [.text(target.path)])
            } catch {
                NSLog("Lumen catalog: backup failed — %@", String(describing: error))
            }
        }
    }

    func close() {
        flushSidecars()
        queue.sync { database.close() }
    }
}

#endif
