// CatalogStore.swift
// The catalog's typed API: one logical catalog over two physical databases
// (docs/15 §15.2) — `lumen.db` (authoritative) with `cache.db` ATTACHed as `cache`
// (disposable, recreated empty when missing or corrupt, never backed up).
//
// The shipped DDL in Schema.swift is a faithful transcription of docs/15 §15.3 and is
// treated as immutable here. Everything §15.3's prose requires but its DDL never wrote
// — the added_at / ext / job / aspect / edited columns, the LRU and metadata indices,
// the "exactly one current edit" constraint, the full six-tuple artifact key, the
// (photo_id, level, recipe_fp) preview key — arrives as an ordered, versioned,
// transactional migration below. `PRAGMA user_version` is the authority (§15.8); the
// migration list is append-only and forward-only, and an older build refuses a newer
// catalog rather than half-reading it.
//
// Hash discipline: `recipe_fp` values carry their algorithm prefix ("xxh64:<16hex>",
// Fingerprint.swift), so an algorithm change is a data migration and never a silent
// collision. `recipe_fp = ""` means as-shot.
//
// Platform: the value types below are pure Swift and compile everywhere; the store
// itself needs the sqlite3 module and is fenced, with a Linux stub that throws
// CatalogError.unavailable rather than pretending to persist anything.

import Foundation

// MARK: - Errors

public enum CatalogError: Error, CustomStringConvertible {
    case unavailable
    case notFound(String)
    case invalid(String)
    case corrupt(String)
    case schemaTooNew(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unavailable:
            return "catalog: SQLite is unavailable on this platform (the catalog is macOS-only)"
        case .notFound(let what):
            return "catalog: not found — \(what)"
        case .invalid(let why):
            return "catalog: invalid — \(why)"
        case .corrupt(let why):
            return "catalog: integrity check failed — \(why)"
        case .schemaTooNew(let found, let supported):
            return "catalog: schema version \(found) is newer than this build supports "
                + "(\(supported)); update Lumen rather than opening it read-half-way"
        }
    }
}

// MARK: - Small vocabulary types

/// Pick / reject / unflagged (docs/10 §10.4). Stored as the raw Int in `photo.flag`.
public enum PhotoFlag: Int, Sendable, CaseIterable {
    case reject = -1
    case unflagged = 0
    case pick = 1
}

/// Canonical colour-label keys. `photo.label` stores the key; the *display* name lives
/// in `meta` under `label_name_1…5` and is user-editable (gap G25).
public enum ColorLabel: String, Sendable, CaseIterable {
    case red, yellow, green, blue, purple

    /// 1-based meta slot, matching the `6`–`9` (+ purple) key bindings.
    public var metaSlot: Int {
        switch self {
        case .red: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        }
    }
}

/// Preview ladder levels (docs/15 §15.6). Level 0 is never evicted.
public enum PreviewLevel: Int, Sendable, CaseIterable {
    case thumb = 0
    case grid = 1
    case fit = 2
    case oneToOne = 3
}

/// Drives the camera-render honesty badge.
public enum PreviewSource: String, Sendable {
    case embedded
    case lumen
}

/// `edit.kind` — working state, virtual copy, or named snapshot (docs/15 §15.4).
public enum EditKind: String, Sendable {
    case working
    case version
    case snapshot
}

// MARK: - Row structs

public struct FolderRow: Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var bookmark: Data?
    public var volumeUUID: String?
    public var online: Bool
    public var lastEventID: Int64?
    public var lastScannedAt: Int64?

    public init(id: Int64 = 0, path: String, bookmark: Data? = nil,
                volumeUUID: String? = nil, online: Bool = true,
                lastEventID: Int64? = nil, lastScannedAt: Int64? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.volumeUUID = volumeUUID
        self.online = online
        self.lastEventID = lastEventID
        self.lastScannedAt = lastScannedAt
    }
}

/// Mirrors `photo` as it exists after migration 2 (the base DDL columns plus
/// added_at / ext / job / aspect / edited).
public struct PhotoRow: Equatable, Sendable {
    public var id: Int64
    public var folderID: Int64
    public var filename: String
    public var fileSize: Int64
    public var fileMTime: Int64
    public var quickSig: String?
    public var fullHash: String?
    public var captureAt: Int64?
    public var captureSubsec: Int?
    public var camera: String?
    public var cameraSerial: String?
    public var lens: String?
    public var iso: Int?
    public var shutterSeconds: Double?
    public var aperture: Double?
    public var focalMM: Double?
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var rating: Int
    public var flag: PhotoFlag
    public var label: String?
    public var missing: Bool
    public var sidecarMTime: Int64?
    public var addedAt: Int64
    public var ext: String?
    public var job: String?
    public var aspect: Double?
    public var edited: Bool

    public init(id: Int64 = 0, folderID: Int64, filename: String,
                fileSize: Int64 = 0, fileMTime: Int64 = 0,
                quickSig: String? = nil, fullHash: String? = nil,
                captureAt: Int64? = nil, captureSubsec: Int? = nil,
                camera: String? = nil, cameraSerial: String? = nil, lens: String? = nil,
                iso: Int? = nil, shutterSeconds: Double? = nil,
                aperture: Double? = nil, focalMM: Double? = nil,
                width: Int? = nil, height: Int? = nil, orientation: Int? = nil,
                gpsLatitude: Double? = nil, gpsLongitude: Double? = nil,
                rating: Int = 0, flag: PhotoFlag = .unflagged, label: String? = nil,
                missing: Bool = false, sidecarMTime: Int64? = nil,
                addedAt: Int64 = 0, ext: String? = nil, job: String? = nil,
                aspect: Double? = nil, edited: Bool = false) {
        self.id = id
        self.folderID = folderID
        self.filename = filename
        self.fileSize = fileSize
        self.fileMTime = fileMTime
        self.quickSig = quickSig
        self.fullHash = fullHash
        self.captureAt = captureAt
        self.captureSubsec = captureSubsec
        self.camera = camera
        self.cameraSerial = cameraSerial
        self.lens = lens
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.aperture = aperture
        self.focalMM = focalMM
        self.width = width
        self.height = height
        self.orientation = orientation
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.rating = rating
        self.flag = flag
        self.label = label
        self.missing = missing
        self.sidecarMTime = sidecarMTime
        self.addedAt = addedAt
        self.ext = ext
        self.job = job
        self.aspect = aspect
        self.edited = edited
    }
}

public struct EditRow: Equatable, Sendable {
    public var id: Int64
    public var photoID: Int64
    public var kind: EditKind
    public var name: String?
    public var isCurrent: Bool
    public var pipelineVersion: Int
    public var recipeJSON: String
    public var recipeFP: String
    public var updatedAt: Int64

    public init(id: Int64 = 0, photoID: Int64, kind: EditKind = .working,
                name: String? = nil, isCurrent: Bool = false,
                pipelineVersion: Int = currentPipelineVersion,
                recipeJSON: String, recipeFP: String, updatedAt: Int64 = 0) {
        self.id = id
        self.photoID = photoID
        self.kind = kind
        self.name = name
        self.isCurrent = isCurrent
        self.pipelineVersion = pipelineVersion
        self.recipeJSON = recipeJSON
        self.recipeFP = recipeFP
        self.updatedAt = updatedAt
    }
}

/// Bookkeeping only — the payload is a file under `~/Library/Caches/Lumen/previews/xx/`.
/// Key is (photoID, level, recipeFP); `recipeFP == ""` means as-shot (gap G1).
public struct PreviewRow: Equatable, Sendable {
    public var photoID: Int64
    public var level: PreviewLevel
    public var recipeFP: String
    public var source: PreviewSource
    public var path: String
    public var bytes: Int64
    public var createdAt: Int64
    public var lastUsedAt: Int64

    public init(photoID: Int64, level: PreviewLevel, recipeFP: String = "",
                source: PreviewSource = .embedded, path: String, bytes: Int64 = 0,
                createdAt: Int64 = 0, lastUsedAt: Int64 = 0) {
        self.photoID = photoID
        self.level = level
        self.recipeFP = recipeFP
        self.source = source
        self.path = path
        self.bytes = bytes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Bookkeeping only. The contractual key is the six-tuple
/// (photoID, kind, componentID, modelID+modelVersion, prefixHash, pipelineVersion)
/// — enforced by a UNIQUE index from migration 2 (gap G4).
public struct ArtifactRow: Equatable, Sendable {
    public var id: Int64
    public var photoID: Int64
    public var kind: String
    public var componentID: String?
    public var modelID: String?
    public var modelVersion: String?
    public var prefixHash: String
    public var pipelineVersion: Int
    public var checksum: String
    public var path: String
    public var bytes: Int64
    public var createdAt: Int64
    public var lastUsedAt: Int64

    public init(id: Int64 = 0, photoID: Int64, kind: String,
                componentID: String? = nil, modelID: String? = nil,
                modelVersion: String? = nil, prefixHash: String,
                pipelineVersion: Int = currentPipelineVersion,
                checksum: String, path: String, bytes: Int64 = 0,
                createdAt: Int64 = 0, lastUsedAt: Int64 = 0) {
        self.id = id
        self.photoID = photoID
        self.kind = kind
        self.componentID = componentID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.prefixHash = prefixHash
        self.pipelineVersion = pipelineVersion
        self.checksum = checksum
        self.path = path
        self.bytes = bytes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// The `album` table: manual albums, smart albums and saved filters are one engine
/// with two entry points (D39). `kind='smart'` + `query` = serialized filter tree;
/// `pinned` distinguishes a sidebar smart album from a bar preset (gap G23);
/// `scope`/`scopeID` carry everywhere / folder-subtree / album (gap G22).
public struct CollectionRow: Equatable, Sendable {
    public var id: Int64
    public var parentID: Int64?
    public var name: String
    public var kind: String
    public var query: String?
    public var position: Int
    public var scope: String?
    public var scopeID: Int64?
    public var isTarget: Bool
    public var pinned: Bool

    public init(id: Int64 = 0, parentID: Int64? = nil, name: String,
                kind: String = "manual", query: String? = nil, position: Int = 0,
                scope: String? = nil, scopeID: Int64? = nil,
                isTarget: Bool = false, pinned: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.query = query
        self.position = position
        self.scope = scope
        self.scopeID = scopeID
        self.isTarget = isTarget
        self.pinned = pinned
    }
}

/// The `stack` table: burst / bracket grouping with a pick on top (docs/10 §10.2).
/// `collapsed` arrives in migration 2 — collapse state is per stack and persisted,
/// because a card that re-expands 400 stacks on every launch is a card nobody stacks.
public struct StackRow: Equatable, Sendable {
    public var id: Int64
    public var origin: String
    public var pickPhotoID: Int64?
    public var collapsed: Bool

    public init(id: Int64 = 0, origin: String = "manual",
                pickPhotoID: Int64? = nil, collapsed: Bool = true) {
        self.id = id
        self.origin = origin
        self.pickPhotoID = pickPhotoID
        self.collapsed = collapsed
    }
}

/// One row of the `look` table: a named look the photographer saved, as stored.
///
/// The payload stays as text here rather than being decoded on the way out, because the
/// browser lists dozens of looks to show four words each, and parsing every stored
/// slice to draw a name is work nobody asked for. `subset()` decodes the one the
/// photographer actually reaches for.
///
/// `look.thumb` has no accessor because nothing writes it: a swatch would have to be
/// rendered through the pipeline against some photograph, and choosing which photograph
/// is a design question this pass did not answer. The column stays NULL and the browser
/// lists names — said here rather than left for the next reader to discover, since a
/// stored field with no writer is exactly what audit LIB-22 was about.
public struct LookRow: Equatable, Sendable {
    public var id: Int64
    public var name: String
    /// User grouping ("folder" in the docs). NULL = ungrouped.
    public var group: String?
    public var kind: LookKind
    /// Canonical sparse JSON, as written by `CanonicalJSON.canonicalLookJSON`.
    public var subsetJSON: String
    public var updatedAt: Int64

    public init(id: Int64 = 0, name: String, group: String? = nil,
                kind: LookKind = .look, subsetJSON: String = "{}",
                updatedAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
        self.subsetJSON = subsetJSON
        self.updatedAt = updatedAt
    }

    /// The stored slice, decoded.
    public func subset() throws -> LookSubset {
        try CanonicalJSON.decodeLookSubset(from: Data(subsetJSON.utf8))
    }
}

/// The columns the metadata chips enumerate. An enum rather than a string, because the
/// value is interpolated into SQL: a chip that took a column name from anywhere else
/// would be an injection point, and there is no such thing as a trusted string here.
///
/// Two cases, not four. `ext` is already the RAW-only chip's job, and `job` has no
/// writer anywhere in the app — a chip enumerating it would be permanently empty, which
/// is the inert control this whole pass exists to remove.
public enum PhotoFacet: String, Sendable, CaseIterable {
    case camera, lens

    var column: String {
        switch self {
        case .camera: return "camera"
        case .lens: return "lens"
        }
    }
}

/// One value of a metadata chip and how many photos carry it — the live counts docs/10
/// §10.8 asks for ("Sony A7 IV (1,203)").
public struct FacetValue: Equatable, Sendable {
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// Every number the filter bar puts beside a facet, counted once, together.
///
/// One value rather than six calls because the numbers are only meaningful as a set:
/// they all describe the SAME grid, and a bar that assembled them from six independently
/// scoped reads is a bar whose numbers can be individually stale. `ratingAtLeast` is
/// indexed by the threshold — index 3 is "★3 or better" — with index 0 unused, so a
/// chip can look its own number up by the value it sets.
public struct FacetCounts: Equatable, Sendable {
    public var flags: [PhotoFlag: Int] = [:]
    public var ratingAtLeast: [Int] = [Int](repeating: 0, count: 6)
    public var labels: [ColorLabel: Int] = [:]
    /// Photographs carrying no colour label — its own field because it is its own
    /// predicate: `label IN (…)` can never match the NULL an unlabelled photo stores.
    public var unlabeled: Int = 0
    public var cameras: [FacetValue] = []
    public var lenses: [FacetValue] = []
    public var keywords: [FacetValue] = []

    public init() {}
}

// MARK: - Scan reconciliation

/// One file as the directory listing found it (docs/15 §15.9: the diff key is
/// (filename, file_size, file_mtime); `quickSig` is the move/dupe detector).
///
/// `filename` is the file's path RELATIVE TO ITS REGISTERED FOLDER, not its basename.
/// The distinction is the whole identity of a photo, because the folder scan is
/// recursive and `photo` is `UNIQUE(folder_id, filename)`: keyed on the basename,
/// `day1/DSC_0001.NEF` and `day2/DSC_0001.NEF` are one row. Camera counters wrap and
/// DCIM folders reuse names, so a single card routinely contains both. Editing one and
/// then the other saved both recipes onto the same row, and the first frame's work was
/// gone — with the sidecar unable to rescue it, since the merge rule is catalog-wins.
///
/// For a file sitting directly in the registered folder the two are the same string,
/// which is why the collision only ever showed up on multi-folder imports.
public struct ScannedFile: Equatable, Sendable {
    public var filename: String
    public var fileSize: Int64
    public var fileMTime: Int64
    public var quickSig: String?
    public var ext: String?

    public init(filename: String, fileSize: Int64, fileMTime: Int64,
                quickSig: String? = nil, ext: String? = nil) {
        self.filename = filename
        self.fileSize = fileSize
        self.fileMTime = fileMTime
        self.quickSig = quickSig
        self.ext = ext
    }

    /// A photo's identity within its registered folder: the path from that folder down
    /// to the file, `/`-joined. See `filename` above for why this is not the basename.
    ///
    /// Here rather than in `CatalogService` because it decides which photo row a recipe
    /// is saved onto, and `LumenApp` has no test target. On `ScannedFile` rather than
    /// on `CatalogStore` because `CatalogStore` has a separate stub for platforms
    /// without SQLite, and a rule that exists on only one of them is a rule that is
    /// about to drift.
    ///
    /// Falls back to the basename when `file` is not inside `folder` at all — wrong in
    /// the same way the old behaviour was, rather than an empty string that would
    /// collide with every other stray.
    public static func catalogName(for file: URL, in folder: URL) -> String {
        let root = folder.standardizedFileURL.pathComponents
        let full = file.standardizedFileURL.pathComponents
        guard full.count > root.count,
              Array(full.prefix(root.count)) == root else {
            return file.lastPathComponent
        }
        return full.dropFirst(root.count).joined(separator: "/")
    }
}

/// What one reconciliation pass concluded. `relocated` rows kept their edits, history
/// and album membership; `missing` rows are a *state*, never a deletion.
public struct ScanResult: Equatable, Sendable {
    public var added: [Int64]
    public var changed: [Int64]
    public var relocated: [Int64]
    public var missing: [Int64]
    public var restored: [Int64]
    public var unchanged: Int

    public init(added: [Int64] = [], changed: [Int64] = [], relocated: [Int64] = [],
                missing: [Int64] = [], restored: [Int64] = [], unchanged: Int = 0) {
        self.added = added
        self.changed = changed
        self.relocated = relocated
        self.missing = missing
        self.restored = restored
        self.unchanged = unchanged
    }
}

/// What the caller needs to know BEFORE it decides which files are worth hashing.
///
/// `quick_sig` only earns its cost when there is something for it to match. Hashing a
/// megabyte of every file in a listing is 5 GB of I/O for a 5,000-frame card — seconds,
/// on the one path docs/10 §10.1 gates under a second, and LIB-25 already flags that
/// path as blocking the first grid. So the scan asks first:
///
/// - `known` — filenames this folder already has rows for. Those are not new, so no
///   relocation can be about them.
/// - `candidateSizes` — the `file_size` of every row a newly listed file could be a
///   relocation OF: rows in this folder that have vanished from the listing, and rows
///   anywhere marked `missing = 1`. Both halves are restricted to rows that actually
///   carry a signature, because a candidate without one cannot be matched anyway.
///
/// Size is an exact prefilter, not a heuristic: renaming or moving a file does not
/// change its length, so a new file whose size matches nothing cannot be a relocation
/// of anything and never needs hashing. Where sizes DO collide — two frames of the same
/// length — the signature is what tells them apart, which is the job it exists for.
///
/// The first open of a fresh folder therefore hashes nothing at all: no rows, no
/// candidates, empty set.
public struct RelocationProbe: Equatable, Sendable {
    public var known: Set<String>
    public var candidateSizes: Set<Int64>

    public init(known: Set<String> = [], candidateSizes: Set<Int64> = []) {
        self.known = known
        self.candidateSizes = candidateSizes
    }

    /// What a caller gets when the catalog could not answer: hash nothing rather than
    /// hash everything. A missed relocation costs a re-link; a stalled folder open on
    /// every launch costs the app's one measurable promise.
    public static let none = RelocationProbe()
}

/// What the open-time integrity check found, and what was done about it.
///
/// docs/15 §15.8: "`PRAGMA quick_check` on every open (fails → restore newest backup
/// that passes, automatically, with a notice *after* the fact)". The notice is the
/// reason this is a value and not a Bool: the user is told what happened to their
/// catalog once it has already been handled, never asked to decide.
public struct CatalogRecovery: Equatable, Sendable {

    public enum Outcome: Equatable, Sendable {
        /// No catalog file yet. A first run has nothing to check and nothing to lose.
        case firstRun
        /// `PRAGMA quick_check` returned "ok". Nothing was touched.
        case healthy
        /// The catalog failed its check and was replaced by a backup that passed. The
        /// corrupt file is MOVED ASIDE, never deleted: a file SQLite cannot read may
        /// still be readable by a recovery tool, and the last hour of somebody's
        /// culling can be worth more than the tidiness.
        case restored(fromBackup: String, corruptSetAsideAt: String)
        /// The catalog failed and no backup passed either. Nothing was moved and
        /// nothing was replaced — the caller opens the corrupt file, which is what it
        /// would have done anyway, and now it knows.
        case unrecoverable(backupsTried: Int)
    }

    public var outcome: Outcome

    /// The after-the-fact notice, or nil when there is nothing to say. Phrased for a
    /// status line: the user is being told, not consulted.
    public var notice: String? {
        switch outcome {
        case .firstRun, .healthy:
            return nil
        case .restored(let backup, _):
            let name = URL(fileURLWithPath: backup).lastPathComponent
            // Careful about the tense. Sidecar recovery happens per folder, at scan
            // time, so at the moment this notice is written nothing has been recovered
            // yet — promising otherwise would be the same class of caption this project
            // keeps finding and removing.
            return "The catalog was damaged and has been restored from \(name). "
                + "Edits made since that backup come back from the sidecars as each "
                + "folder is rescanned."
        case .unrecoverable(let tried):
            return tried == 0
                ? "The catalog is damaged and there is no backup to restore from. "
                    + "Your edits are still in the sidecars beside your photos."
                : "The catalog is damaged and none of the \(tried) backups could be "
                    + "read either. Your edits are still in the sidecars beside your photos."
        }
    }

    /// True when the catalog the caller is about to open is known to be unreadable.
    public var isDamaged: Bool {
        if case .unrecoverable = outcome { return true }
        return false
    }

    public init(outcome: Outcome) { self.outcome = outcome }
}

// MARK: - Backup retention

/// Which snapshots in `backups/` survive, as arithmetic over filenames.
///
/// A pure function with no `FileManager` in it. `CatalogService` lists the directory
/// and does the deleting; this decides, and it decides from a list of strings so the
/// decision can be exercised exhaustively — including the degenerate shapes a real
/// `backups/` directory reaches about once in its life and never while anyone is
/// watching. A retention rule that can only be run against a real directory is a
/// retention rule that is run rarely, and this one deletes the file the restore path
/// depends on.
///
/// The policy is three sentences:
///
///  1. **The newest is never a victim.** Not "K ≥ 1, so it happens to fall out of rule
///     2" — a separate, unconditional rule, applied under BOTH orderings that matter:
///     newest by the timestamp in the name, and first under the *name* ordering
///     `CatalogStore.recoverIfNeeded` actually walks (`sorted(by: >)` over the
///     directory). Deleting the file the restore reaches first is the only mistake this
///     type could make that costs somebody a catalog, so it is stated rather than
///     implied by an arithmetic accident somewhere else.
///  2. Keep the newest `keepNewest`, for the ordinary "it was fine yesterday" restore.
///  3. Keep the newest snapshot of each of the most recent `keepWeeks` distinct weeks,
///     so damage that went unnoticed for a fortnight still has something behind it.
///
/// A name this cannot date is retained, always. A file this code did not write is not
/// this code's to delete, and "I do not understand it" is not a reason to remove
/// something from the one directory a damaged catalog is restored from.
public enum BackupRetention {

    /// How many of the newest snapshots survive regardless of age — K.
    ///
    /// Three, because a snapshot is a `VACUUM INTO` copy of the whole catalog and the
    /// ceiling on this policy is `keepNewest + keepWeeks` files on the photographer's
    /// disk: at three plus four that is seven copies, and a gigabyte catalog is then
    /// seven gigabytes of backups, which is already the largest number defensible on a
    /// laptop that is also holding the photographs. Three covers the case the newest
    /// snapshot is itself damaged (a bad sector rarely respects file boundaries) and
    /// the case where the damage was noticed one session late.
    public static let keepNewest = 3

    /// How many distinct weeks keep a representative — W.
    ///
    /// Four. The audit's rule is "newest K plus one per week", unbounded; unbounded is
    /// one full copy of a multi-gigabyte catalog per week forever, which on a three-year
    /// library is 150 of them. The cap is the part of the rule the audit did not have to
    /// write because it was not the one shipping it. Four weeks is where the value runs
    /// out: restoring a catalog more than a month stale is worse than the rescan it
    /// competes with, because every folder's sidecars have to be merged back in anyway
    /// and a month of album, stack and keyword work does not live in a sidecar.
    public static let keepWeeks = 4

    /// The name shape `CatalogService` writes: `lumen-<ISO 8601, colons swapped>.db`.
    public static let namePrefix = "lumen-"
    public static let nameSuffix = ".db"

    /// One dated snapshot, as the policy sees it.
    public struct DatedBackup: Equatable, Sendable {
        /// The filename, exactly as it appears in the directory.
        public var name: String
        /// Unix epoch seconds parsed out of the name — never off the filesystem, which
        /// a copy, a restore or a sync client rewrites at will.
        public var timestamp: Int64
        /// Monday-based week number since the epoch. Integer arithmetic rather than
        /// `Calendar`, so the bucket a name lands in does not depend on the locale,
        /// the time zone or the machine.
        public var weekIndex: Int64

        public init(name: String, timestamp: Int64, weekIndex: Int64) {
            self.name = name
            self.timestamp = timestamp
            self.weekIndex = weekIndex
        }
    }

    /// What to keep and what to delete. Both lists are newest-first, and every input
    /// name appears in exactly one of them.
    public struct RetentionPlan: Equatable, Sendable {
        public var retained: [String]
        public var victims: [String]

        public init(retained: [String] = [], victims: [String] = []) {
            self.retained = retained
            self.victims = victims
        }
    }

    /// Epoch seconds for a backup filename, or nil when the name is not one of ours.
    ///
    /// Accepts the ISO form `CatalogService` writes (`lumen-2026-09-02T14-33-21Z.db`)
    /// and the compact `lumen-20260902.db` form `CatalogStore.backup(to:)`'s own
    /// comment names, because a directory can contain both and a name that dates
    /// perfectly well should not be immortal just because an older build wrote it.
    public static func timestamp(inBackupName name: String) -> Int64? {
        guard name.hasPrefix(namePrefix), name.hasSuffix(nameSuffix) else { return nil }
        let body = String(name.dropFirst(namePrefix.count).dropLast(nameSuffix.count))
        guard !body.isEmpty else { return nil }

        // Digit runs, in order: 2026-09-02T14-33-21Z -> [2026, 09, 02, 14, 33, 21].
        var groups: [String] = []
        var current = ""
        for character in body {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }

        var fields: [Int64] = []
        if groups.count == 1, groups[0].count == 8 {
            let digits = groups[0]
            let year = digits.prefix(4)
            let month = digits.dropFirst(4).prefix(2)
            let day = digits.dropFirst(6)
            fields = [Int64(year) ?? -1, Int64(month) ?? -1, Int64(day) ?? -1, 0, 0, 0]
        } else if groups.count >= 6 {
            fields = groups.prefix(6).map { Int64($0) ?? -1 }
        } else {
            return nil
        }

        let (year, month, day) = (fields[0], fields[1], fields[2])
        let (hour, minute, second) = (fields[3], fields[4], fields[5])
        guard (1970...9999).contains(year), (1...12).contains(month),
              (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }

        return daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
    }

    /// Every name this understands, newest first. Ties break on the name, descending,
    /// so two snapshots written inside one second still order deterministically.
    public static func snapshots(in names: [String]) -> [DatedBackup] {
        names.compactMap { name -> DatedBackup? in
            guard let stamp = timestamp(inBackupName: name) else { return nil }
            return DatedBackup(name: name, timestamp: stamp,
                               weekIndex: weekIndex(forEpochSeconds: stamp))
        }
        .sorted { left, right in
            left.timestamp == right.timestamp ? left.name > right.name
                                              : left.timestamp > right.timestamp
        }
    }

    /// The policy. `names` is a directory listing filtered to `.db`; order is ignored.
    public static func plan(names: [String],
                            keepNewest: Int = BackupRetention.keepNewest,
                            keepWeeks: Int = BackupRetention.keepWeeks) -> RetentionPlan {
        // At least one, always. A configuration that keeps nothing is not a retention
        // policy, it is a delete, and no caller gets to ask for it by passing 0.
        let newestKept = max(keepNewest, 1)
        let weeksKept = max(keepWeeks, 0)

        let dated = snapshots(in: names)
        var keep = Set<String>()

        // Rule 1, first and on its own line: the newest survives. Twice over — the
        // newest by date, and the first name the restore walk reaches, which is a
        // different file only when somebody has put a name in here that we did not
        // write, and is exactly the case where being wrong is unrecoverable.
        if let newest = dated.first { keep.insert(newest.name) }
        if let firstReached = names.max() { keep.insert(firstReached) }

        // Rule 2: the newest K.
        for snapshot in dated.prefix(newestKept) { keep.insert(snapshot.name) }

        // Rule 3: the newest of each of the most recent W weeks that has anything in
        // it. Weeks are counted from the snapshots present, not backwards from a clock,
        // so this function needs no clock and a gap in the history does not silently
        // consume a week's allowance.
        var weeksSeen: [Int64] = []
        for snapshot in dated where !weeksSeen.contains(snapshot.weekIndex) {
            if weeksSeen.count < weeksKept { keep.insert(snapshot.name) }
            weeksSeen.append(snapshot.weekIndex)
        }

        // A name we cannot date is not ours to remove.
        let undated = names.filter { timestamp(inBackupName: $0) == nil }
        keep.formUnion(undated)

        let ordered = names.sorted(by: >)
        return RetentionPlan(retained: ordered.filter { keep.contains($0) },
                             victims: ordered.filter { !keep.contains($0) })
    }

    /// Convenience for the caller that only wants the deletions.
    public static func victims(among names: [String],
                               keepNewest: Int = BackupRetention.keepNewest,
                               keepWeeks: Int = BackupRetention.keepWeeks) -> [String] {
        plan(names: names, keepNewest: keepNewest, keepWeeks: keepWeeks).victims
    }

    /// Monday-based weeks since the epoch. Day 0 (1970-01-01) was a Thursday, so the
    /// Monday that opens its week is day -3; shifting by three and flooring puts every
    /// Monday-to-Sunday run in one bucket.
    static func weekIndex(forEpochSeconds seconds: Int64) -> Int64 {
        floorDivide(floorDivide(seconds, 86_400) + 3, 7)
    }

    /// Days from 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Here rather than in `Calendar` because the answer must not
    /// change with the machine's locale or time zone: the names carry UTC.
    static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = floorDivide(shifted, 400)
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Truncating division rounds toward zero, which puts pre-epoch dates in the wrong
    /// bucket and off by one. Nothing here should ever see one; being right anyway is
    /// two lines.
    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1
                                                                     : quotient
    }
}

// MARK: - Query

/// The filter bar compiled to SQL (docs/10 §10.8, D39).
///
/// Boolean rule, day one: **multi-value within one criterion is OR, and criteria AND
/// with each other**. `matchAny` flips the cross-criterion join to OR (the bar's
/// All/Any toggle). Scope predicates (folder, album, missing) always AND — they are
/// the source, not a chip.
public struct PhotoQuery: Sendable {

    public enum RatingComparison: String, Sendable {
        case atLeast, exactly, atMost
    }

    public enum SortKey: String, Sendable, CaseIterable {
        case captureTime, addedOrder, editTime, rating, flag, label
        case filename, fileType, aspectRatio, userOrder, sharpness, aesthetic
    }

    /// `collapsedTopsOnly` shows unstacked photos, every member of an expanded stack,
    /// and only the pick of a collapsed one — a pure index operation (§6.4).
    public enum StackState: String, Sendable {
        case any, collapsedTopsOnly, unstacked
    }

    /// Virtual copies are `edit` rows, so "masters" means "no version edit exists".
    public enum VersionKind: String, Sendable {
        case all, mastersOnly, versionsOnly
    }

    // Attribute chips
    public var flags: [PhotoFlag] = []
    public var rating: Int? = nil
    public var ratingComparison: RatingComparison = .atLeast
    public var labels: [ColorLabel] = []
    public var includeUnlabeled: Bool = false
    public var edited: Bool? = nil
    public var stackState: StackState = .any
    public var fileTypes: [String] = []
    public var versionKind: VersionKind = .all

    // Metadata chips
    public var cameras: [String] = []
    public var lenses: [String] = []
    /// ISO bands, as a UNION rather than a span.
    ///
    /// This was one `ClosedRange`, built by taking the minimum lower bound and the
    /// maximum upper bound of every lit chip — which is only the union when the chips
    /// are adjacent. Lighting "≤ 400" and "≥ 6401" produced `0...4_000_000` and returned
    /// every ISO 800 photo in the library, against a filter bar that states OR-within-a-
    /// criterion. The union of two disjoint sets is not the interval that spans them.
    public var isoRanges: [ClosedRange<Int>] = []
    public var apertureRange: ClosedRange<Double>? = nil
    public var captureRange: ClosedRange<Int64>? = nil
    public var keywords: [String] = []
    public var jobs: [String] = []

    // Evidence chips — these live in cache.db, which is why the ATTACH is mandatory
    public var junkCandidates: Bool = false
    public var closedEyes: Bool = false
    public var softFocus: Bool = false
    public var cameraPreviewOnly: Bool = false
    public var closedEyesThreshold: Double = 0.35
    public var softFocusThreshold: Double = 0.35

    // Text chip — tokenized contains/prefix
    public var text: String? = nil

    // Scope and shape
    public var albumID: Int64? = nil
    public var includeMissing: Bool = true
    public var matchAny: Bool = false
    public var sortKey: SortKey = .captureTime
    public var ascending: Bool = true
    public var limit: Int? = nil
    public var offset: Int? = nil

    public init() {}
}

// MARK: - Migrations

/// One append-only, forward-only schema step. Applied inside a transaction with the
/// `user_version` bump, so a crash mid-migration leaves the old version intact.
public struct CatalogMigration: Sendable {
    public let version: Int
    public let sql: String

    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

#if canImport(SQLite3)

// MARK: - Store

public final class CatalogStore {

    // MARK: Stored state

    private let db: SQLiteDatabase
    /// A VAR, because the text index can stop being available while the app is running
    /// and there was no way to say so (J1-02).
    ///
    /// It was a `let` fixed at open: FTS5 present, index created, true for the session.
    /// A `cache.db` that goes read-only afterwards — a full disk, an external volume
    /// unmounted — then failed every `photo_fts` write, and those failures propagated
    /// out of `setRating` and `setLabel` into the culling write's `catch`, which
    /// reported "Could not save the flag or rating" for a rating that HAD been saved.
    /// Every keystroke an error banner about a cache.
    ///
    /// Guarded by whatever serialises the rest of this class — `CatalogService` owns the
    /// queue — which is the same guarantee every other mutable field here has, and the
    /// honest claim rather than a stronger one.
    private var ftsEnabled: Bool

    public let path: String
    public let cachePath: String

    /// True when SQLite was built with FTS5 and the text index exists (gap G16).
    /// When false the text chip degrades to parameterized LIKE — correct, just slower.
    public var isTextIndexAvailable: Bool { ftsEnabled }

    // MARK: Migration list

    /// Schema version this build understands. Base DDL (`CatalogSchema.lumenDDL`) is
    /// version 1; everything after it is a migration below.
    public static let latestSchemaVersion: Int = 3

    /// Gap-closing migration for `lumen.db` (brief 02 §2.3, G5–G15, G17–G26, G31).
    public static let migrations: [CatalogMigration] = [
        CatalogMigration(version: 2, sql: CatalogStore.lumenMigration2),
        CatalogMigration(version: 3, sql: CatalogStore.lumenMigration3),
    ]

    /// Gap-closing migration for `cache.db` (G1–G4, G19, G28, G29).
    public static let cacheMigrations: [CatalogMigration] = [
        CatalogMigration(version: 2, sql: CatalogStore.cacheMigration2)
    ]

    private static let lumenMigration2: String = """
    -- G9/G10/G11/G12/G13: sort keys and filter chips docs/15 §15.3's prose requires
    -- but its DDL never wrote. All five must exist as columns: "added order",
    -- "file type" and "aspect ratio" are sort keys, and the "edited" chip plus the
    -- pencil cell badge cannot afford to join and parse every recipe.
    ALTER TABLE photo ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE photo ADD COLUMN ext      TEXT;
    ALTER TABLE photo ADD COLUMN job      TEXT;
    ALTER TABLE photo ADD COLUMN aspect   REAL;
    ALTER TABLE photo ADD COLUMN edited   INTEGER NOT NULL DEFAULT 0;

    UPDATE photo SET added_at = file_mtime WHERE added_at = 0;
    UPDATE photo SET aspect = CAST(width AS REAL) / height
      WHERE aspect IS NULL AND width IS NOT NULL AND height IS NOT NULL AND height > 0;

    CREATE INDEX IF NOT EXISTS photo_added    ON photo(added_at);
    CREATE INDEX IF NOT EXISTS photo_ext      ON photo(ext);
    CREATE INDEX IF NOT EXISTS photo_job      ON photo(job);
    CREATE INDEX IF NOT EXISTS photo_aspect   ON photo(aspect);
    CREATE INDEX IF NOT EXISTS photo_edited   ON photo(edited);
    CREATE INDEX IF NOT EXISTS photo_folder   ON photo(folder_id, missing);

    -- G15: photo_cull leads with flag, so a bare "rating >= 3" chip or a rating sort
    -- cannot use it.
    CREATE INDEX IF NOT EXISTS photo_rating   ON photo(rating);

    -- G14: metadata chips carry live counts ("Sony A7 IV (1,203)") and must stay
    -- index-backed under 50 ms at 100k photos.
    CREATE INDEX IF NOT EXISTS photo_iso      ON photo(iso);
    CREATE INDEX IF NOT EXISTS photo_camera   ON photo(camera);
    CREATE INDEX IF NOT EXISTS photo_lens     ON photo(lens);
    CREATE INDEX IF NOT EXISTS photo_aperture ON photo(aperture);

    -- G5: "exactly one is_current per photo" was a comment. Two current edits render
    -- nondeterministically; make it a constraint. Fold any pre-existing duplicates
    -- onto the newest row first so the index can be created.
    UPDATE edit SET is_current = 0
      WHERE is_current = 1
        AND id NOT IN (SELECT MAX(id) FROM edit WHERE is_current = 1 GROUP BY photo_id);
    CREATE UNIQUE INDEX IF NOT EXISTS edit_current ON edit(photo_id) WHERE is_current = 1;

    -- G6/G7/G8: reverse lookups that back the album chip, the keyword chip and the
    -- "modified since export" badge drawn on every cell.
    CREATE INDEX IF NOT EXISTS album_photo_rev   ON album_photo(photo_id);
    CREATE INDEX IF NOT EXISTS photo_keyword_rev ON photo_keyword(keyword_id);
    CREATE INDEX IF NOT EXISTS export_log_photo  ON export_log(photo_id, exported_at);

    -- G20: collapse/expand is per stack, default collapsed, persisted.
    ALTER TABLE stack ADD COLUMN collapsed INTEGER NOT NULL DEFAULT 1;

    -- G21/G22/G23: the target album for `B`, smart-album scope, and the pinned flag
    -- that separates a sidebar smart album from a saved filter-bar preset.
    ALTER TABLE album ADD COLUMN is_target INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE album ADD COLUMN scope     TEXT;
    ALTER TABLE album ADD COLUMN scope_id  INTEGER;
    ALTER TABLE album ADD COLUMN pinned    INTEGER NOT NULL DEFAULT 0;
    CREATE UNIQUE INDEX IF NOT EXISTS album_target ON album(is_target) WHERE is_target = 1;

    -- G24: sort key + direction, thumbnail size and filter state are persisted per
    -- source (docs/10 §10.2, §10.4).
    CREATE TABLE IF NOT EXISTS source_state (
      source_key  TEXT PRIMARY KEY,
      sort_key    TEXT NOT NULL DEFAULT 'captureTime',
      sort_dir    INTEGER NOT NULL DEFAULT 1,
      thumb_px    INTEGER NOT NULL DEFAULT 192,
      filter_json TEXT
    );

    -- G26: the history ring stores every 20th entry as full state and the rest as
    -- zstd JSON diffs; the payload needs a discriminator, not a convention.
    ALTER TABLE history ADD COLUMN is_full INTEGER NOT NULL DEFAULT 0;

    -- G31: content-level dedupe on re-ingest, and "which photo did this ledger row
    -- become".
    ALTER TABLE ingest_file ADD COLUMN photo_id INTEGER;
    CREATE INDEX IF NOT EXISTS ingest_file_hash  ON ingest_file(xxh64);
    CREATE INDEX IF NOT EXISTS ingest_file_photo ON ingest_file(photo_id);

    -- G25: labels are canonical keys in `photo.label`; the display names are editable
    -- and live here. 6-9 map to slots 1-4; purple is assignable in prefs.
    INSERT OR IGNORE INTO meta(key, value) VALUES
      ('label_name_1', 'Red'),
      ('label_name_2', 'Yellow'),
      ('label_name_3', 'Green'),
      ('label_name_4', 'Blue'),
      ('label_name_5', 'Purple');
    """

    /// The `look` table gains the constraint that makes a saved look identifiable.
    ///
    /// A look is reached for by NAME — that is the whole of its identity in the browser
    /// — so two rows with one name inside one group are two things the photographer
    /// cannot tell apart, and "apply Portra Warm" stops having an answer. Saving over a
    /// name is how a look is updated (`saveLook`), which only works if the name is a
    /// key.
    ///
    /// `COALESCE(grp, '')` rather than the bare column, for the reason cacheMigration2's
    /// artifact index records: SQLite treats NULLs as distinct in a UNIQUE index, and
    /// ungrouped is the common case, so the bare form would constrain everything except
    /// the rows that need it most.
    ///
    /// No de-duplication pass precedes it, unlike every other unique index in this file.
    /// The `look` table has existed since the base DDL with no writer anywhere in the
    /// tree (audit FILM-15/LIB-22: "zero insert/select"), so every catalog reaching this
    /// migration has an empty one and there is nothing to collapse. If that is ever
    /// wrong the migration fails loudly inside its transaction and leaves the catalog at
    /// version 2, which is the correct outcome for a claim that turned out to be false.
    private static let lumenMigration3: String = """
    CREATE UNIQUE INDEX IF NOT EXISTS look_identity
      ON look(kind, COALESCE(grp, ''), name);
    CREATE INDEX IF NOT EXISTS look_kind ON look(kind, name);
    """

    private static let cacheMigration2: String = """
    -- G1: the invalidation key in §15.6 is (photo_id, level, recipe_fp). One row per
    -- level cannot hold an embedded and a Lumen render at once, cannot hold per-version
    -- previews for virtual copies, and breaks the camera-render handoff, which needs
    -- both rows to coexist during the swap.
    CREATE TABLE preview_v2 (
      photo_id     INTEGER NOT NULL,
      level        INTEGER NOT NULL,
      recipe_fp    TEXT NOT NULL,
      source       TEXT NOT NULL,
      path         TEXT NOT NULL,
      bytes        INTEGER NOT NULL,
      created_at   INTEGER NOT NULL,
      last_used_at INTEGER NOT NULL,
      PRIMARY KEY (photo_id, level, recipe_fp)
    );
    INSERT OR IGNORE INTO preview_v2
      SELECT photo_id, level, recipe_fp, source, path, bytes, created_at, last_used_at
        FROM preview;
    DROP TABLE preview;
    ALTER TABLE preview_v2 RENAME TO preview;

    -- G2: eviction order is 1:1 -> fit -> grid, least-recently-viewed first. Without
    -- this it is a full scan every time the budget is re-evaluated.
    CREATE INDEX IF NOT EXISTS preview_lru ON preview(level, last_used_at);

    -- G3: §15.7 mandates per-kind LRU budgets (embeddings evict first, denoise atlases
    -- last).
    CREATE INDEX IF NOT EXISTS artifact_lru ON artifact(kind, last_used_at);

    -- G4: artifact_key covers 3 of the 6 contractual key fields, so nothing prevented
    -- duplicate rows per key. Collapse any duplicates onto the newest, then constrain.
    -- COALESCE, not the bare columns: SQLite treats NULLs as distinct in a UNIQUE
    -- index, and component_id / model_id / model_version are legitimately NULL for
    -- whole-image, model-free artifacts — which is exactly where duplicates bred.
    DELETE FROM artifact WHERE id NOT IN (
      SELECT MAX(id) FROM artifact
       GROUP BY photo_id, kind, component_id, model_id, model_version,
                prefix_hash, pipeline_version
    );
    CREATE UNIQUE INDEX IF NOT EXISTS artifact_key_full ON artifact(
      photo_id, kind, COALESCE(component_id, ''), COALESCE(model_id, ''),
      COALESCE(model_version, ''), prefix_hash, pipeline_version);

    -- G19: cache schema version, disk budget, last budget re-evaluation and the current
    -- analyzer_rev had nowhere to live; self-healing needs a version stamp.
    CREATE TABLE IF NOT EXISTS meta ( key TEXT PRIMARY KEY, value TEXT );

    -- G28: face.crop_artifact_id had no FK, so orphaned crops were silent. Same
    -- database, so the reference is expressible.
    CREATE TABLE face_v2 (
      id INTEGER PRIMARY KEY,
      photo_id INTEGER NOT NULL,
      rect_x REAL, rect_y REAL, rect_w REAL, rect_h REAL,
      eyes_open REAL,
      capture_quality REAL,
      focus REAL,
      crop_artifact_id INTEGER REFERENCES artifact(id),
      analyzer_rev INTEGER NOT NULL
    );
    INSERT INTO face_v2
      SELECT id, photo_id, rect_x, rect_y, rect_w, rect_h, eyes_open,
             capture_quality, focus, crop_artifact_id, analyzer_rev
        FROM face;
    DROP TABLE face;
    ALTER TABLE face_v2 RENAME TO face;
    CREATE INDEX IF NOT EXISTS face_photo ON face(photo_id);

    -- G29: one concept, one name.
    ALTER TABLE feature_print RENAME COLUMN revision TO analyzer_rev;
    """

    /// G16: the text chip needs tokenized contains/prefix; `LIKE '%x%'` cannot meet
    /// 50 ms at 100k. FTS5 belongs on the disposable side because it is rebuildable.
    /// Created best-effort: a SQLite without FTS5 falls back to LIKE rather than
    /// refusing to open the catalog. rowid == photo.id, so sync is a rowid delete.
    private static let ftsDDL: String = """
    CREATE VIRTUAL TABLE IF NOT EXISTS photo_fts USING fts5(
      filename, ext, camera, lens, job, keywords,
      tokenize = 'unicode61 remove_diacritics 2'
    );
    """

    // MARK: Column lists

    /// Select list for `PhotoRow`. Column order here IS the decode order below.
    private static let photoColumns: String = """
    photo.id, photo.folder_id, photo.filename, photo.file_size, photo.file_mtime, \
    photo.quick_sig, photo.full_hash, photo.capture_at, photo.capture_subsec, \
    photo.camera, photo.camera_serial, photo.lens, photo.iso, photo.shutter_s, \
    photo.aperture, photo.focal_mm, photo.width, photo.height, photo.orientation, \
    photo.gps_lat, photo.gps_lon, photo.rating, photo.flag, photo.label, \
    photo.missing, photo.sidecar_mtime, photo.added_at, photo.ext, photo.job, \
    photo.aspect, photo.edited
    """

    private static let editColumns: String = """
    id, photo_id, kind, name, is_current, pipeline_version, recipe, recipe_fp, updated_at
    """

    private static let previewColumns: String = """
    photo_id, level, recipe_fp, source, path, bytes, created_at, last_used_at
    """

    private static let artifactColumns: String = """
    id, photo_id, kind, component_id, model_id, model_version, prefix_hash, \
    pipeline_version, checksum, path, bytes, created_at, last_used_at
    """

    private static let albumColumns: String = """
    id, parent_id, name, kind, query, position, scope, scope_id, is_target, pinned
    """

    private static let stackColumns: String = """
    stack.id, stack.origin, stack.pick_photo_id, stack.collapsed
    """

    /// `thumb` is deliberately absent: nothing writes it (see `LookRow`), and selecting
    /// a BLOB column to ignore it would read every swatch off disk to draw a list of
    /// names.
    private static let lookColumns: String = """
    id, name, grp, kind, subset, updated_at
    """

    // MARK: - Open

    /// Opens (creating if needed) `lumen.db` at `path`, prepares and ATTACHes the
    /// disposable `cache.db`, applies the base DDL when `user_version == 0`, then runs
    /// the ordered migration list. Idempotent: reopening an up-to-date catalog does no
    /// schema work at all.
    ///
    /// `cachePath` defaults to a sibling `<name>-cache.db`; production passes
    /// `~/Library/Caches/Lumen/cache.db` so macOS storage tooling can reclaim it.
    public convenience init(path: String) throws {
        try self.init(path: path, cachePath: nil)
    }

    public init(path: String, cachePath: String?) throws {
        self.path = path
        let resolvedCachePath = cachePath ?? CatalogStore.defaultCachePath(for: path)
        self.cachePath = resolvedCachePath

        try CatalogStore.ensureParentDirectory(of: path)
        try CatalogStore.ensureParentDirectory(of: resolvedCachePath)

        // cache.db is prepared on its own connection: `PRAGMA user_version` is then
        // unambiguous, and the table rewrites in cacheMigration2 run without
        // foreign_keys enforcement biting on pre-existing orphans.
        var textIndexAvailable = false
        do {
            textIndexAvailable = try CatalogStore.prepareCacheDatabase(at: resolvedCachePath)
        } catch let error as CatalogError {
            // A cache.db FROM A NEWER BUILD IS DISPOSABLE, and treating it as fatal was
            // the most expensive line in this file.
            //
            // `prepareCacheDatabase` throws `schemaTooNew` for a cache whose
            // `user_version` is ahead of this build's migrations. The catch below is
            // `SQLiteError`-typed, and `CatalogError` is not one — so the throw escaped
            // `init` entirely, `AppState.openCatalog` caught it, set `catalog = nil`, and
            // the whole session ran in memory: no catalog rows AND no sidecars, because
            // the sidecar writer lives inside `CatalogService`. Every edit, rating and
            // flag made that day was discarded at quit, announced only by ten-point text
            // at the bottom of a sidebar that can be hidden.
            //
            // docs/15 §15.2 is explicit that this database is derived and is recreated
            // empty when it cannot be used. "Written by a newer build" is exactly that
            // case: nothing in it is user work. Run a dev build, go back to the release,
            // and this fired.
            guard case .schemaTooNew = error else { throw error }
            try? FileManager.default.removeItem(atPath: resolvedCachePath)
            textIndexAvailable = try CatalogStore.prepareCacheDatabase(at: resolvedCachePath)
        } catch let error as SQLiteError where error.indicatesCorruptDatabase {
            // Corrupt cache -> recreate empty; the workers refill it (docs/15 §15.2).
            // Losing it costs warm-up time and nothing else.
            //
            // ONLY on corruption. This catch used to be unqualified, so a transient
            // failure — SQLITE_BUSY against another instance's migration, a WAL
            // contention error — deleted the cache and its `-wal`/`-shm` out from
            // under a process that had them open, whose mapped shared memory then
            // pointed at an unlinked inode. Its writes vanished and it began
            // reporting a malformed image. Launching Lumen twice against one catalog
            // was enough. The `-wal` and `-shm` are not deleted at all now: SQLite
            // recovers them itself, and unlinking them is what did the damage.
            try? FileManager.default.removeItem(atPath: resolvedCachePath)
            textIndexAvailable = try CatalogStore.prepareCacheDatabase(at: resolvedCachePath)
        }
        self.ftsEnabled = textIndexAvailable

        let database = try SQLiteDatabase(path: path)
        self.db = database

        // page_size and auto_vacuum only take effect before the first table exists,
        // so they lead — auto_vacuum=INCREMENTAL is gap G17, and retrofitting it later
        // would cost a full VACUUM.
        try database.execute("PRAGMA page_size=8192;\nPRAGMA auto_vacuum=INCREMENTAL;")
        try database.execute(CatalogSchema.pragmas)

        try database.execute(
            "ATTACH DATABASE \(SQLiteDatabase.quoteLiteral(resolvedCachePath)) AS cache;")

        try migrate()
        try seedMetaIfNeeded()
        try rebuildTextIndexIfNeeded()
    }

    deinit {
        // PRAGMA optimize on close is the invisible maintenance slot (§15.8); it is
        // advisory, so a failure here must not surface from a deinit.
        try? db.execute("PRAGMA optimize;")
        db.close()
    }

    /// Close early — quit path: TRUNCATE checkpoint, optimize, then release the handle.
    public func close() {
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try? db.execute("PRAGMA optimize;")
        db.close()
    }

    private static func defaultCachePath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(base + "-cache.db").path
    }

    private static func ensureParentDirectory(of path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        }
    }

    /// Returns true when the FTS5 text index exists (or was just created).
    private static func prepareCacheDatabase(at cachePath: String) throws -> Bool {
        let cache = try SQLiteDatabase(path: cachePath)
        defer { cache.close() }

        try cache.execute("PRAGMA page_size=8192;\nPRAGMA auto_vacuum=INCREMENTAL;")
        try cache.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA busy_timeout=5000;
        PRAGMA temp_store=MEMORY;
        """)

        var version = try cache.userVersion()
        if version == 0 {
            try cache.transaction {
                try cache.execute(CatalogSchema.cacheDDL)
                try cache.setUserVersion(1)
            }
            version = 1
        }
        let latest = CatalogStore.cacheMigrations.map({ $0.version }).max() ?? 1
        if version > max(latest, 1) {
            throw CatalogError.schemaTooNew(found: version, supported: max(latest, 1))
        }
        for migration in CatalogStore.cacheMigrations where migration.version > version {
            try cache.transaction {
                try cache.execute(migration.sql)
                try cache.setUserVersion(migration.version)
            }
            version = migration.version
        }

        // Best-effort: a SQLite without FTS5 compiled in must not stop the app opening.
        do {
            try cache.execute(CatalogStore.ftsDDL)
            return true
        } catch {
            return false
        }
    }

    private func migrate() throws {
        var version = try db.userVersion()
        if version == 0 {
            try db.transaction {
                try db.execute(CatalogSchema.lumenDDL)
                try db.setUserVersion(CatalogSchema.schemaVersion)
            }
            version = CatalogSchema.schemaVersion
        }
        if version > CatalogStore.latestSchemaVersion {
            throw CatalogError.schemaTooNew(
                found: version, supported: CatalogStore.latestSchemaVersion)
        }
        for migration in CatalogStore.migrations where migration.version > version {
            try db.transaction {
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
            version = migration.version
        }
    }

    private func seedMetaIfNeeded() throws {
        let now = CatalogStore.now()
        try db.transaction {
            if (try self.metaValue("catalog_uuid")) == nil {
                try self.setMetaValue("catalog_uuid", UUID().uuidString)
                try self.setMetaValue("created_at", String(now))
            }
            try self.setMetaValue("pipeline_version", String(currentPipelineVersion))
        }
    }

    // MARK: - Integrity and maintenance

    /// `PRAGMA quick_check` against the open catalog.
    ///
    /// The open-time check §15.8 asks for is `recoverIfNeeded`, below, which runs
    /// BEFORE the store exists — a restore has to replace the file, and it cannot do
    /// that through a handle that is holding it open. This one is the same pragma
    /// against a live store, for a caller that already has one.
    public func quickCheck() throws -> Bool {
        (try db.scalarText("PRAGMA quick_check;")) == "ok"
    }

    /// Full `PRAGMA integrity_check` — the pre-backup gate, against the live handle.
    ///
    /// The gate itself now lives inside `snapshot(from:to:)`, which runs it on the
    /// connection it is about to vacuum, because a gate the caller has to remember is
    /// one the caller eventually forgets. What it is for is unchanged: a corrupt catalog
    /// that backs itself up rotates the last readable snapshot out of existence, and
    /// then `recoverIfNeeded` has nothing to restore from. §15.8 specifies it "before
    /// each weekly backup"; the automatic snapshot is once per
    /// `automaticBackupInterval`, so it runs before every one of those instead — a
    /// stricter reading, and cheap enough beside the vacuum it precedes.
    ///
    /// This overload stays for a caller that already holds a store and only wants the
    /// answer. In `Sources` there is now no such caller — the app's every backup goes
    /// through `snapshot(from:to:)` — so its live users are `CatalogTests`, which uses
    /// it to prove the full check notices damage a `quick_check` alone would pass.
    public func integrityCheck() throws -> Bool {
        (try db.scalarText("PRAGMA integrity_check;")) == "ok"
    }

    // MARK: Automatic backup — when, and on whose connection

    /// Where the "when did we last take one" stamp lives. `meta` because it belongs to
    /// the catalog rather than to the machine: copy the catalog to another Mac and the
    /// backup rhythm travels with it, which is what `seedMetaIfNeeded` establishes for
    /// `catalog_uuid` and `created_at` for the same reason.
    public static let lastBackupMetaKey = "last_backup_at"

    /// N — the shortest gap between two automatic snapshots, in seconds.
    ///
    /// Twenty hours, not twenty-four. A photographer's quits cluster in the evening, and
    /// a strict 24-hour gate phase-drifts against that: yesterday's quit at 21:00 makes
    /// tonight's at 20:45 only 23.75 hours old, so it is skipped, and the "daily" backup
    /// silently becomes every second day. Twenty hours absorbs four hours of evening
    /// jitter while still collapsing a working day of launch-cull-quit cycles — the
    /// shape of an import session — into one snapshot rather than nine.
    ///
    /// The upper bound on N is what a restore costs: everything since the last snapshot
    /// comes back from sidecars folder by folder as each is rescanned, and the album,
    /// stack and keyword work that has no sidecar does not come back at all. A day of
    /// that is a bad evening; a week of it is the thing this project promised would
    /// never happen.
    public static let automaticBackupInterval: Int64 = 20 * 3_600

    /// The stamp, or nil on a catalog that has never been backed up.
    public func lastBackupAt() throws -> Int64? {
        guard let raw = try metaValue(CatalogStore.lastBackupMetaKey) else { return nil }
        return Int64(raw)
    }

    /// Is a snapshot owed? Never-backed-up counts as owed, which is what gives a fresh
    /// install its first backup at its first quit rather than at its second.
    ///
    /// A stamp in the future — a clock that was wrong and has been corrected, a catalog
    /// carried back across a time zone — also counts as owed, and the write that follows
    /// repairs the stamp. The alternative is a catalog that quietly stops backing itself
    /// up until the calendar catches up with the bad stamp, which is a failure mode with
    /// no symptom until the day it matters.
    public func isBackupDue(now: Int64 = CatalogStore.now(),
                            interval: Int64 = CatalogStore.automaticBackupInterval)
        throws -> Bool {
        guard let last = try lastBackupAt() else { return true }
        if last > now { return true }
        return now - last >= interval
    }

    /// Record a snapshot. Called only after one has actually landed on disk: a backup
    /// that failed must leave the stamp alone so the next quit tries again, rather than
    /// buying a full-disk error twenty hours of silence.
    public func noteBackupTaken(at when: Int64 = CatalogStore.now()) throws {
        try setMetaValue(CatalogStore.lastBackupMetaKey, String(when))
    }

    /// A checked snapshot taken on a connection of this store's own, not on the app's.
    ///
    /// `backup(to:)` below runs `VACUUM INTO` on the live handle, which means it runs on
    /// whatever queue serialises that handle — in the app, the one serial lane that also
    /// carries every grid query, every preview lookup and the recipe write behind every
    /// slider event. A full `integrity_check` plus a `VACUUM INTO` of a multi-gigabyte
    /// catalog holds that lane for tens of seconds, so the automatic backup would have
    /// been a scheduled stall of the whole browser. SQLite in WAL mode lets a second
    /// connection read while the first writes, and `VACUUM INTO` needs only a read
    /// transaction, so the snapshot can be taken beside the running app instead of
    /// through it.
    ///
    /// The integrity gate is inside this function rather than at the call site, where it
    /// used to live, because it is not optional and a gate a caller can forget is not a
    /// gate. §15.8's rule: a corrupt catalog that backs itself up rotates the last
    /// readable snapshot out of existence, turning recoverable damage into permanent
    /// loss. `integrity_check` is the only thing standing between those two outcomes.
    ///
    /// Throws rather than returning false, so "the catalog is damaged" cannot be
    /// mistaken for "the snapshot is done" by a caller that ignored a Bool.
    public static func snapshot(from path: String, to destination: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CatalogError.notFound("catalog at \(path)")
        }
        let source = try SQLiteDatabase(path: path)
        defer { source.close() }
        // Long enough to sit out a slider gesture's write on the app's own connection,
        // short enough that a wedged writer fails the backup instead of the quit.
        try source.execute("PRAGMA busy_timeout=5000;")

        guard (try source.scalarText("PRAGMA integrity_check;")) == "ok" else {
            throw CatalogError.corrupt(
                "the catalog failed its integrity check, so it was not backed up — "
                + "the existing backups are the good copies and were left alone")
        }

        try CatalogStore.ensureParentDirectory(of: destination)
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        try source.execute(
            "VACUUM main INTO \(SQLiteDatabase.quoteLiteral(destination));")
    }

    /// The open-time integrity check, and the restore §15.8 promises when it fails.
    ///
    /// Call this BEFORE constructing a store on `path`. It opens the catalog on its own
    /// connection, runs `PRAGMA quick_check`, and on failure walks the backups newest
    /// first until one passes, sets the damaged catalog aside and puts that backup in
    /// its place. Whatever it returns, the caller then opens `path` normally — the
    /// point is that the file it opens is the best readable one available, and that the
    /// user is told afterwards rather than asked beforehand.
    ///
    /// Nothing is ever deleted. The damaged catalog is RENAMED — the corrupt file may
    /// still yield to a recovery tool, and the check that condemned it can be wrong
    /// about a file a human would rather still have. The `-wal` and `-shm` move with
    /// it, because leaving a stale WAL beside a restored catalog would let SQLite
    /// replay the damaged journal straight back over the snapshot; renaming rather than
    /// unlinking them is also what keeps a second process's mapped shared memory
    /// pointing at a file that still exists, which is the failure the cache-recreation
    /// path above documents at length.
    ///
    /// Backups are ordered by filename, descending. `CatalogService` names them
    /// `lumen-<ISO 8601 stamp>.db`, and that format sorts lexically and
    /// chronologically at once, so the ordering does not depend on a modification date
    /// that a copy or a restore can rewrite.
    public static func recoverIfNeeded(path: String,
                                       backupDirectory: String) -> CatalogRecovery {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return CatalogRecovery(outcome: .firstRun)
        }
        if probeQuickCheck(path: path) { return CatalogRecovery(outcome: .healthy) }

        let backups = (try? manager.contentsOfDirectory(atPath: backupDirectory))?
            .filter { $0.hasSuffix(".db") }
            .sorted(by: >) ?? []
        for name in backups {
            let candidate = URL(fileURLWithPath: backupDirectory, isDirectory: true)
                .appendingPathComponent(name).path
            guard probeQuickCheck(path: candidate) else { continue }
            let stamp = String(CatalogStore.now())
            let setAside = path + ".damaged-" + stamp
            do {
                try setAsideCatalog(at: path, to: setAside)
                try manager.copyItem(atPath: candidate, toPath: path)
            } catch {
                // A restore that cannot complete must not leave the catalog half
                // replaced. Put the original back if it is still where we moved it,
                // and report the damage rather than a restore that did not happen.
                if manager.fileExists(atPath: setAside), !manager.fileExists(atPath: path) {
                    try? manager.moveItem(atPath: setAside, toPath: path)
                }
                return CatalogRecovery(outcome: .unrecoverable(backupsTried: backups.count))
            }
            return CatalogRecovery(outcome: .restored(fromBackup: candidate,
                                                      corruptSetAsideAt: setAside))
        }
        return CatalogRecovery(outcome: .unrecoverable(backupsTried: backups.count))
    }

    /// One `PRAGMA quick_check` on a file this process does not otherwise hold open.
    ///
    /// False for anything that is not a readable SQLite catalog, including a file that
    /// cannot be opened at all: the caller's question is "can this be used", and every
    /// no is the same no.
    ///
    /// Internal rather than private so the recovery tests can assert that the damage
    /// they inflicted actually took. A restore test that ran against a file SQLite still
    /// finds perfectly readable would pass while proving nothing.
    ///
    /// The existence guard is load-bearing, not defensive tidying. `SQLiteDatabase`
    /// opens with `SQLITE_OPEN_CREATE`, so a path that is not there becomes an empty
    /// database — which passes `quick_check` perfectly. Without this, a backup that
    /// vanished between the directory listing and this call would be created empty,
    /// pass, and be restored OVER a catalog that was merely damaged. Answering "no" for
    /// a file that does not exist is also just correct: nothing there cannot be used.
    static func probeQuickCheck(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let database = try? SQLiteDatabase(path: path) else { return false }
        defer { database.close() }
        return (try? database.scalarText("PRAGMA quick_check;")) == "ok"
    }

    /// Move a catalog and its WAL companions aside, together.
    private static func setAsideCatalog(at path: String, to destination: String) throws {
        let manager = FileManager.default
        try manager.moveItem(atPath: path, toPath: destination)
        for suffix in ["-wal", "-shm"] where manager.fileExists(atPath: path + suffix) {
            try? manager.moveItem(atPath: path + suffix, toPath: destination + suffix)
        }
    }

    /// Passive WAL checkpoint for the idle maintenance slot.
    public func checkpoint(truncate: Bool = false) throws {
        try db.execute(truncate ? "PRAGMA wal_checkpoint(TRUNCATE);"
                                : "PRAGMA wal_checkpoint(PASSIVE);")
    }

    public func optimize() throws {
        try db.execute("PRAGMA optimize;")
        try db.execute("PRAGMA incremental_vacuum;")
    }

    /// `VACUUM INTO` — a compacted, checkpointed, single-file snapshot (§15.8), on
    /// **this** connection and therefore on whatever queue serialises it.
    ///
    /// The automatic backup uses `snapshot(from:to:)` instead, which opens its own
    /// connection and checks integrity first. Prefer that one anywhere the app is
    /// running; this is the unguarded primitive, for a caller that has already decided.
    ///
    /// The destination is embedded as an escaped SQL string literal because SQLite's
    /// VACUUM grammar does not reliably accept a bound parameter there; the value is
    /// a path this process chose, never user-typed SQL.
    public func backup(to path: String) throws {
        try CatalogStore.ensureParentDirectory(of: path)
        if FileManager.default.fileExists(atPath: path) {
            // Same-day backups overwrite by design (lumen-YYYYMMDD.db).
            try FileManager.default.removeItem(atPath: path)
        }
        try db.execute("VACUUM main INTO \(SQLiteDatabase.quoteLiteral(path));")
    }

    /// Cross-database orphan sweep (gap G30). Cache tables carry `photo_id` with no FK
    /// — SQLite cannot express a cross-database reference — so deleted photos would
    /// otherwise leak rows and payload files forever. Returns the rows removed.
    @discardableResult
    public func sweepCacheOrphans() throws -> Int {
        try db.transaction {
            var removed = 0
            let tables = ["raw_stats", "frame_score", "face", "feature_print",
                          "preview", "artifact"]
            for table in tables {
                let deleted = try self.db.run(
                    "DELETE FROM cache.\(table) "
                    + "WHERE photo_id NOT IN (SELECT id FROM main.photo);")
                removed += deleted
            }
            if self.ftsEnabled {
                let deleted = try self.db.run(
                    "DELETE FROM cache.photo_fts "
                    + "WHERE rowid NOT IN (SELECT id FROM main.photo);")
                removed += deleted
            }
            return removed
        }
    }

    // MARK: - Test hooks

    /// Raw SQL against the open connection, for tests that need to put the database
    /// into a state the store would never create itself — an index emptied behind the
    /// store's back, a row a broken build left. Internal, `@testable` only; the app has
    /// no business here.
    func debugExecute(_ sql: String) throws {
        try db.execute(sql)
    }

    // MARK: - meta

    public func metaValue(_ key: String) throws -> String? {
        try db.scalarText("SELECT value FROM meta WHERE key = ?;", [.text(key)])
    }

    public func setMetaValue(_ key: String, _ value: String?) throws {
        if let value = value {
            try db.run("INSERT INTO meta(key, value) VALUES (?, ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?;", [.text(key)])
        }
    }

    public func catalogUUID() throws -> String {
        if let existing = try metaValue("catalog_uuid") { return existing }
        let generated = UUID().uuidString
        try setMetaValue("catalog_uuid", generated)
        return generated
    }

    /// Display name for a colour label (gap G25). `photo.label` stores the key.
    public func labelName(_ label: ColorLabel) throws -> String {
        if let stored = try metaValue("label_name_\(label.metaSlot)"), !stored.isEmpty {
            return stored
        }
        return label.rawValue.capitalized
    }

    public func setLabelName(_ name: String, for label: ColorLabel) throws {
        try setMetaValue("label_name_\(label.metaSlot)", name)
    }

    // MARK: - Folders

    /// Registers a root (or returns the existing row's id) and refreshes its bookmark.
    @discardableResult
    public func registerFolder(path: String, bookmark: Data? = nil,
                               volumeUUID: String? = nil) throws -> Int64 {
        try db.transaction {
            try self.db.run("""
            INSERT INTO folder (path, bookmark, volume_uuid, online)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(path) DO UPDATE SET
              bookmark    = COALESCE(excluded.bookmark, folder.bookmark),
              volume_uuid = COALESCE(excluded.volume_uuid, folder.volume_uuid);
            """, [.text(path), .optionalBlob(bookmark), .optionalText(volumeUUID)])
            guard let id = try self.db.scalarInt(
                "SELECT id FROM folder WHERE path = ?;", [.text(path)]) else {
                throw CatalogError.notFound("folder \(path) after insert")
            }
            return id
        }
    }

    public func folder(id: Int64) throws -> FolderRow? {
        try firstRow("SELECT id, path, bookmark, volume_uuid, online, last_event_id, "
                     + "last_scanned_at FROM folder WHERE id = ?;",
                     [.integer(id)], CatalogStore.decodeFolder)
    }

    public func folder(path: String) throws -> FolderRow? {
        try firstRow("SELECT id, path, bookmark, volume_uuid, online, last_event_id, "
                     + "last_scanned_at FROM folder WHERE path = ?;",
                     [.text(path)], CatalogStore.decodeFolder)
    }

    public func folders() throws -> [FolderRow] {
        try allRows("SELECT id, path, bookmark, volume_uuid, online, last_event_id, "
                    + "last_scanned_at FROM folder ORDER BY path;",
                    [], CatalogStore.decodeFolder)
    }

    /// Unmount flips this: browsable, searchable, cullable from cache; nothing errors.
    public func setFolderOnline(_ online: Bool, folderID: Int64) throws {
        try db.run("UPDATE folder SET online = ? WHERE id = ?;",
                   [.bool(online), .integer(folderID)])
    }

    /// Persists the FSEvents resume point and the last successful scan time (§15.9).
    public func setFolderScanState(folderID: Int64, lastEventID: Int64?,
                                   lastScannedAt: Int64) throws {
        try db.run("UPDATE folder SET last_event_id = COALESCE(?, last_event_id), "
                   + "last_scanned_at = ? WHERE id = ?;",
                   [.optionalInteger(lastEventID), .integer(lastScannedAt),
                    .integer(folderID)])
    }

    // MARK: - Photos

    /// Upsert keyed on (folder_id, filename) — the path half of docs/10 §10.1's key —
    /// with `quick_sig` as the content id used for move and dupe detection.
    ///
    /// A rescan refreshes file facts and metadata but **never** overwrites culling
    /// decisions (rating / flag / label), `added_at`, or `edited`: the filesystem is
    /// not an authority on what the photographer decided.
    @discardableResult
    public func upsertPhoto(_ photo: PhotoRow) throws -> Int64 {
        var row = photo
        if row.addedAt == 0 { row.addedAt = CatalogStore.now() }
        if row.aspect == nil, let w = row.width, let h = row.height, h > 0 {
            row.aspect = Double(w) / Double(h)
        }
        if row.ext == nil {
            row.ext = CatalogStore.fileExtension(of: row.filename)
        }
        return try db.transaction {
            try self.db.run("""
            INSERT INTO photo
              (folder_id, filename, file_size, file_mtime, quick_sig, full_hash,
               capture_at, capture_subsec, camera, camera_serial, lens, iso, shutter_s,
               aperture, focal_mm, width, height, orientation, gps_lat, gps_lon,
               rating, flag, label, missing, sidecar_mtime, added_at, ext, job,
               aspect, edited)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(folder_id, filename) DO UPDATE SET
              file_size      = excluded.file_size,
              file_mtime     = excluded.file_mtime,
              quick_sig      = COALESCE(excluded.quick_sig, photo.quick_sig),
              full_hash      = COALESCE(excluded.full_hash, photo.full_hash),
              capture_at     = COALESCE(excluded.capture_at, photo.capture_at),
              capture_subsec = COALESCE(excluded.capture_subsec, photo.capture_subsec),
              camera         = COALESCE(excluded.camera, photo.camera),
              camera_serial  = COALESCE(excluded.camera_serial, photo.camera_serial),
              lens           = COALESCE(excluded.lens, photo.lens),
              iso            = COALESCE(excluded.iso, photo.iso),
              shutter_s      = COALESCE(excluded.shutter_s, photo.shutter_s),
              aperture       = COALESCE(excluded.aperture, photo.aperture),
              focal_mm       = COALESCE(excluded.focal_mm, photo.focal_mm),
              width          = COALESCE(excluded.width, photo.width),
              height         = COALESCE(excluded.height, photo.height),
              orientation    = COALESCE(excluded.orientation, photo.orientation),
              gps_lat        = COALESCE(excluded.gps_lat, photo.gps_lat),
              gps_lon        = COALESCE(excluded.gps_lon, photo.gps_lon),
              missing        = excluded.missing,
              sidecar_mtime  = COALESCE(excluded.sidecar_mtime, photo.sidecar_mtime),
              ext            = COALESCE(excluded.ext, photo.ext),
              job            = COALESCE(excluded.job, photo.job),
              aspect         = COALESCE(excluded.aspect, photo.aspect);
            """, CatalogStore.photoInsertParameters(row))

            guard let id = try self.db.scalarInt(
                "SELECT id FROM photo WHERE folder_id = ? AND filename = ?;",
                [.integer(row.folderID), .text(row.filename)]) else {
                throw CatalogError.notFound("photo \(row.filename) after upsert")
            }
            self.reindexText(photoID: id)
            return id
        }
    }

    public func photo(id: Int64) throws -> PhotoRow? {
        try firstRow("SELECT \(CatalogStore.photoColumns) FROM photo WHERE photo.id = ?;",
                     [.integer(id)], CatalogStore.decodePhoto)
    }

    public func photo(folderID: Int64, filename: String) throws -> PhotoRow? {
        try firstRow("SELECT \(CatalogStore.photoColumns) FROM photo "
                     + "WHERE photo.folder_id = ? AND photo.filename = ?;",
                     [.integer(folderID), .text(filename)], CatalogStore.decodePhoto)
    }

    public func photos(folderID: Int64, includeMissing: Bool = true) throws -> [PhotoRow] {
        let filter = includeMissing ? "" : " AND photo.missing = 0"
        return try allRows("SELECT \(CatalogStore.photoColumns) FROM photo "
                           + "WHERE photo.folder_id = ?\(filter) ORDER BY photo.filename;",
                           [.integer(folderID)], CatalogStore.decodePhoto)
    }

    /// Missing is a state, not a deletion — rows, recipes and previews are kept.
    public func setMissing(_ missing: Bool, photoID: Int64) throws {
        try db.run("UPDATE photo SET missing = ? WHERE id = ?;",
                   [.bool(missing), .integer(photoID)])
    }

    public func setJob(_ job: String?, photoIDs: [Int64]) throws {
        if photoIDs.isEmpty { return }
        try db.transaction {
            let statement = try self.db.prepare("UPDATE photo SET job = ? WHERE id = ?;")
            for id in photoIDs {
                statement.reset()
                try statement.bind(1, job)
                try statement.bind(2, id)
                try statement.run()
            }
            statement.reset()
            for id in photoIDs { self.reindexText(photoID: id) }
        }
    }

    /// Removes a photo and everything keyed to it in both databases. Returns the cache
    /// payload rows so the caller can unlink the files.
    @discardableResult
    public func deletePhoto(id: Int64) throws -> [PreviewRow] {
        try db.transaction {
            let previews = try self.previews(photoID: id)
            try self.db.run("DELETE FROM album_photo   WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM photo_keyword WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM stack_member  WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM history       WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM export_log    WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM edit          WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("UPDATE stack SET pick_photo_id = NULL WHERE pick_photo_id = ?;",
                            [.integer(id)])
            try self.db.run("DELETE FROM cache.preview      WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM cache.artifact     WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM cache.raw_stats    WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM cache.frame_score  WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM cache.face         WHERE photo_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM cache.feature_print WHERE photo_id = ?;", [.integer(id)])
            if self.ftsEnabled {
                try self.db.run("DELETE FROM cache.photo_fts WHERE rowid = ?;", [.integer(id)])
            }
            try self.db.run("DELETE FROM photo WHERE id = ?;", [.integer(id)])
            return previews
        }
    }

    // MARK: - Scan reconciliation

    /// Which of the listed files could possibly be a relocation, so the scanner can
    /// hash those and only those. See `RelocationProbe` for why this is asked at all.
    public func relocationProbe(folderID: Int64, listed: Set<String>) throws
        -> RelocationProbe {
        var probe = RelocationProbe()

        let statement = try db.prepare(
            "SELECT filename, file_size, quick_sig FROM photo WHERE folder_id = ?;")
        try statement.bind(1, SQLiteValue.integer(folderID))
        while try statement.step() {
            let name = statement.string(0) ?? ""
            probe.known.insert(name)
            // A row still present in the listing is not going anywhere; only the ones
            // that have vanished from it are candidates for an in-folder rename.
            if !listed.contains(name), statement.string(2)?.isEmpty == false {
                probe.candidateSizes.insert(statement.int(1))
            }
        }

        // Cross-folder moves: the row was marked missing on an earlier scan of the
        // folder it left, and this scan is the folder it arrived in.
        let missing = try db.prepare(
            "SELECT DISTINCT file_size FROM photo "
            + "WHERE missing = 1 AND quick_sig IS NOT NULL AND quick_sig <> '';")
        while try missing.step() {
            probe.candidateSizes.insert(missing.int(0))
        }
        return probe
    }

    /// Reconciles one folder against a directory listing (docs/15 §15.9, the cold-start
    /// path and the FSEvents fallback). Runs as a single transaction.
    ///
    /// New file          -> insert.
    /// (size, mtime) differ -> update, reported as changed.
    /// Gone              -> move detection first: a `quick_sig` match against a newly
    ///                      appeared file (this folder, or a `missing` row anywhere)
    ///                      relocates the row with edits, history and album membership
    ///                      intact. Only an unmatched disappearance sets `missing = 1`.
    @discardableResult
    public func scan(folderID: Int64, files: [ScannedFile],
                     at now: Int64 = CatalogStore.now()) throws -> ScanResult {
        try db.transaction {
            var result = ScanResult()

            // Existing rows for this folder, keyed by filename.
            var existing: [String: (id: Int64, size: Int64, mtime: Int64,
                                    sig: String?, missing: Bool)] = [:]
            let statement = try self.db.prepare(
                "SELECT id, filename, file_size, file_mtime, quick_sig, missing "
                + "FROM photo WHERE folder_id = ?;")
            try statement.bind(1, folderID)
            while try statement.step() {
                existing[statement.string(1) ?? ""] = (
                    id: statement.int(0),
                    size: statement.int(2),
                    mtime: statement.int(3),
                    sig: statement.string(4),
                    missing: statement.bool(5))
            }
            statement.reset()

            var seen: Set<String> = []
            var newFiles: [ScannedFile] = []

            for file in files {
                seen.insert(file.filename)
                guard let row = existing[file.filename] else {
                    newFiles.append(file)
                    continue
                }
                if row.size != file.fileSize || row.mtime != file.fileMTime {
                    try self.db.run("""
                    UPDATE photo SET file_size = ?, file_mtime = ?,
                      quick_sig = COALESCE(?, quick_sig), missing = 0 WHERE id = ?;
                    """, [.integer(file.fileSize), .integer(file.fileMTime),
                          .optionalText(file.quickSig), .integer(row.id)])
                    result.changed.append(row.id)
                } else if row.missing {
                    try self.db.run("UPDATE photo SET missing = 0 WHERE id = ?;",
                                    [.integer(row.id)])
                    result.restored.append(row.id)
                } else {
                    result.unchanged += 1
                }
            }

            // Rows whose filename vanished from the listing, indexed by signature so a
            // rename inside the folder is a relocation, not a disappearance.
            var goneBySignature: [String: Int64] = [:]
            var gone: [(name: String, id: Int64)] = []
            for (name, row) in existing where !seen.contains(name) {
                gone.append((name: name, id: row.id))
                if let sig = row.sig, !sig.isEmpty { goneBySignature[sig] = row.id }
            }
            var consumed: Set<Int64> = []

            for file in newFiles {
                var relocatedID: Int64? = nil
                if let sig = file.quickSig, !sig.isEmpty {
                    if let candidate = goneBySignature[sig], !consumed.contains(candidate) {
                        relocatedID = candidate
                    } else if let candidate = try self.db.scalarInt(
                        "SELECT id FROM photo WHERE quick_sig = ? AND missing = 1 "
                        + "ORDER BY id LIMIT 1;", [.text(sig)]),
                        !consumed.contains(candidate) {
                        relocatedID = candidate
                    }
                }
                if let id = relocatedID {
                    consumed.insert(id)
                    try self.db.run("""
                    UPDATE photo SET folder_id = ?, filename = ?, file_size = ?,
                      file_mtime = ?, missing = 0,
                      ext = COALESCE(?, ext) WHERE id = ?;
                    """, [.integer(folderID), .text(file.filename),
                          .integer(file.fileSize), .integer(file.fileMTime),
                          .optionalText(file.ext
                                        ?? CatalogStore.fileExtension(of: file.filename)),
                          .integer(id)])
                    self.reindexText(photoID: id)
                    result.relocated.append(id)
                    continue
                }
                let inserted = try self.upsertPhoto(PhotoRow(
                    folderID: folderID, filename: file.filename,
                    fileSize: file.fileSize, fileMTime: file.fileMTime,
                    quickSig: file.quickSig, addedAt: now,
                    ext: file.ext ?? CatalogStore.fileExtension(of: file.filename)))
                result.added.append(inserted)
            }

            for entry in gone where !consumed.contains(entry.id) {
                try self.db.run("UPDATE photo SET missing = 1 WHERE id = ?;",
                                [.integer(entry.id)])
                result.missing.append(entry.id)
            }

            try self.db.run("UPDATE folder SET last_scanned_at = ? WHERE id = ?;",
                            [.integer(now), .integer(folderID)])
            return result
        }
    }

    // MARK: - Recipes

    /// Persists a recipe as canonical sparse JSON plus its `recipe_fp`, keeping exactly
    /// one `is_current = 1` edit per photo (the unique partial index from migration 2
    /// makes that a constraint, not a hope). `photo.edited` is maintained in the same
    /// transaction so the "edited" chip and the pencil badge never join and parse.
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, isCurrent: Bool,
                           isRenderedFile: Bool = false) throws {
        try saveRecipe(recipe, photoID: photoID, kind: .working,
                       name: nil, isCurrent: isCurrent, isRenderedFile: isRenderedFile)
    }

    /// - Parameter isRenderedFile: whether this photograph is a file somebody has
    ///   already tone-mapped — a JPEG, HEIC, PNG or TIFF — rather than a camera raw.
    ///   It decides the baseline `edited` is measured against, and it is a PARAMETER
    ///   because LumenCore does not own the list of rendered extensions:
    ///   `PhotoFormats` in the app target does, and a second copy of that list here
    ///   could disagree with the one the folder scan used about the same file. Its
    ///   default is `false` — the raw case — so a caller that does not know says
    ///   nothing rather than guessing "JPEG".
    @discardableResult
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, kind: EditKind,
                           name: String?, isCurrent: Bool,
                           isRenderedFile: Bool = false,
                           at now: Int64 = CatalogStore.now()) throws -> Int64 {
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let fingerprint = try RecipeFingerprint.fingerprint(recipe)
        // "Edited" means the recipe differs from what a fresh import of THIS
        // PHOTOGRAPH would have left behind — not from the type's default.
        //
        // It compared against `Recipe(pipelineVersion:)`, and the two are not the same
        // baseline for two large classes of file: a rendered file is imported carrying
        // `look.render.preset = "Linear"`, and a raw with a recorded ISO is imported
        // carrying `ISODefaults.startingDenoise(forISO:)`. So every JPEG in the library
        // was marked edited by its own import and stayed marked forever — the pencil
        // badge lit on a photograph nobody had touched, Reset unable to put it out, and
        // the "Edited: no" chip (`photo.edited = ?`, in `buildPhotoQuery`) refusing to
        // show it at all. That last one is a filter whose number and whose rows
        // disagree, which is the same defect as the facet counts wearing a different
        // hat.
        //
        // `Recipe.asImported(from:)` is the ONE statement of what as-imported means —
        // `RecipeReset.swift`, unit-tested on Linux — and this reads it rather than
        // restating it. The ISO comes off the photo row because the row is where the
        // scanner put it; only `isRendered` has to be told, because the extension list
        // that answers it lives in the app target on purpose.
        //
        // The pipeline version is normalized onto the baseline for the reason the old
        // comment gave and which still holds: comparing against a *different* version's
        // default would light the pencil badge on every photo after a pipeline bump.
        //
        // `rendersSameAs`, not `!=`: a recipe differing only by a mask name is not an
        // edit, and lighting the pencil badge for one is a lie about the photograph.
        // That is also why this cannot simply call `Recipe.isAsImported(from:)`, which
        // compares whole documents with `==`; the baseline is the shared half, and the
        // comparison is this call's own.
        let capturedISO = try db.scalarInt("SELECT iso FROM photo WHERE id = ?;",
                                           [.integer(photoID)])
        var baseline = Recipe.asImported(from: Recipe.SourceFile(
            isRendered: isRenderedFile, iso: capturedISO.map { Int($0) }))
        baseline.pipelineVersion = recipe.pipelineVersion
        let isEdited = !recipe.rendersSameAs(baseline)
        // A ROW CANNOT CLAIM A VERSION ITS WRITER DOES NOT IMPLEMENT.
        //
        // `Recipe`'s decoder carries a version it reads rather than restamping it, so a
        // recipe decoded from a newer build's row arrives here still saying it is that
        // newer thing. Writing that number back would leave a row this build produced
        // claiming semantics this build does not have — and the next older build to
        // open the catalog would then demote a row that is, in fact, its own.
        //
        // `min`, not `currentPipelineVersion` outright: an OLDER recipe must keep
        // reporting its own age, which is what migrations read and what
        // `testARecipeWrittenAtAnOlderVersionStillReportsThatVersion` pins.
        let storedPipelineVersion = Swift.min(recipe.pipelineVersion,
                                              currentPipelineVersion)

        return try db.transaction {
            if isCurrent {
                try self.db.run(
                    "UPDATE edit SET is_current = 0 WHERE photo_id = ? AND is_current = 1;",
                    [.integer(photoID)])
            }

            var editID: Int64? = nil
            if kind == .working {
                editID = try self.db.scalarInt(
                    "SELECT id FROM edit WHERE photo_id = ? AND kind = 'working' "
                    + "ORDER BY id LIMIT 1;", [.integer(photoID)])
            }

            // A working row from a FUTURE pipeline version is not this build's row to
            // overwrite. The scenario is real and destructive: a newer build wrote an
            // edit this build's decoder cannot (fully) read, the viewer fell back to a
            // default recipe, and the photographer touched one slider — the in-place
            // UPDATE below would then replace the newer recipe with the fallback, in
            // the catalog now and in the sidecar at the next flush. The newer edit is
            // the photographer's most recent work on the photo; it must survive the
            // older build. So it is demoted to a named `version` row — visible in the
            // edits list, restorable by the build that wrote it — and this save
            // INSERTs a fresh working row of its own.
            // AGAINST THIS BUILD'S VERSION, not the recipe's own (K-020).
            //
            // It compared `rowVersion > recipe.pipelineVersion`, and `Recipe`'s decoder
            // CARRIES a version it reads rather than restamping it — deliberately, so an
            // old recipe keeps reporting its own age. So the newer row was decoded, the
            // in-memory recipe took the newer number with it, the photographer touched a
            // slider, and the guard compared 7 against 7 and did not fire. The UPDATE
            // below then overwrote the newer edit with this build's rendering of it, in
            // the catalog and at the next sidecar flush — which is precisely the loss
            // the guard was written to prevent, arriving through the guard.
            //
            // The question is whether THIS BUILD can safely rewrite the row, and only
            // this build's own version answers it.
            if let id = editID,
               let rowVersion = try self.db.scalarInt(
                   "SELECT pipeline_version FROM edit WHERE id = ?;", [.integer(id)]),
               rowVersion > Int64(currentPipelineVersion) {
                try self.db.run("""
                UPDATE edit SET kind = 'version', is_current = 0,
                  name = COALESCE(name, ?) WHERE id = ?;
                """, [.text("Preserved from a newer build (pipeline v\(rowVersion))"),
                      .integer(id)])
                editID = nil
            }

            if let id = editID {
                try self.db.run("""
                UPDATE edit SET name = ?, is_current = ?, pipeline_version = ?,
                  recipe = ?, recipe_fp = ?, updated_at = ? WHERE id = ?;
                """, [.optionalText(name), .bool(isCurrent),
                      .int(storedPipelineVersion), .text(json), .text(fingerprint),
                      .integer(now), .integer(id)])
                // Only the CURRENT edit decides the badge. Saving a snapshot of a
                // default recipe used to clear `edited` on a photo whose working edit
                // was heavily worked.
                if isCurrent {
                    try self.db.run("UPDATE photo SET edited = ? WHERE id = ?;",
                                    [.bool(isEdited), .integer(photoID)])
                }
                return id
            }

            try self.db.run("""
            INSERT INTO edit (photo_id, kind, name, is_current, pipeline_version,
                              recipe, recipe_fp, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [.integer(photoID), .text(kind.rawValue), .optionalText(name),
                  .bool(isCurrent), .int(storedPipelineVersion), .text(json),
                  .text(fingerprint), .integer(now)])
            let inserted = self.db.lastInsertRowID
            if isCurrent {
                try self.db.run("UPDATE photo SET edited = ? WHERE id = ?;",
                                [.bool(isEdited), .integer(photoID)])
            }
            return inserted
        }
    }

    public func currentRecipe(photoID: Int64) throws -> Recipe? {
        guard let json = try db.scalarText(
            "SELECT recipe FROM edit WHERE photo_id = ? AND is_current = 1 LIMIT 1;",
            [.integer(photoID)]) else { return nil }
        return try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
    }

    public func currentEdit(photoID: Int64) throws -> EditRow? {
        try firstRow("SELECT \(CatalogStore.editColumns) FROM edit "
                     + "WHERE photo_id = ? AND is_current = 1 LIMIT 1;",
                     [.integer(photoID)], CatalogStore.decodeEdit)
    }

    public func edits(photoID: Int64) throws -> [EditRow] {
        try allRows("SELECT \(CatalogStore.editColumns) FROM edit "
                    + "WHERE photo_id = ? ORDER BY id;",
                    [.integer(photoID)], CatalogStore.decodeEdit)
    }

    /// The `recipe_fp` every cache is keyed on. Empty string = as-shot.
    public func currentRecipeFingerprint(photoID: Int64) throws -> String {
        (try db.scalarText(
            "SELECT recipe_fp FROM edit WHERE photo_id = ? AND is_current = 1 LIMIT 1;",
            [.integer(photoID)])) ?? ""
    }

    /// Makes an existing edit row the current one, preserving the one-per-photo rule.
    public func makeCurrent(editID: Int64) throws {
        try db.transaction {
            guard let photoID = try self.db.scalarInt(
                "SELECT photo_id FROM edit WHERE id = ?;", [.integer(editID)]) else {
                throw CatalogError.notFound("edit \(editID)")
            }
            try self.db.run(
                "UPDATE edit SET is_current = 0 WHERE photo_id = ? AND is_current = 1;",
                [.integer(photoID)])
            try self.db.run("UPDATE edit SET is_current = 1 WHERE id = ?;",
                            [.integer(editID)])
        }
    }

    // MARK: - Looks

    /// Store a named look, or update the one already stored under that name.
    ///
    /// Save-over rather than save-another, because a look is reached for by name and
    /// two rows called "Portra Warm" are two rows the browser draws identically. The
    /// alternative — appending "Portra Warm 2" — turns a browser into a graveyard
    /// within one shoot, and there is no gesture in a photographer's day that means
    /// "keep the old version of this look but never show me which is which". Renaming
    /// is how a second variant is kept.
    ///
    /// Look-then-write rather than `ON CONFLICT`, for the reason `recordArtifact` gives
    /// above it: the conflict target is an expression index over a nullable column, and
    /// a plain `SELECT … grp IS ?` says what it means without asking SQLite's upsert
    /// parser to agree about which index it is aiming at.
    @discardableResult
    public func saveLook(name: String, subset: LookSubset,
                         kind: LookKind = .look, group: String? = nil,
                         at now: Int64 = CatalogStore.now()) throws -> Int64 {
        guard let clean = LookSubset.normalizedName(name) else {
            throw CatalogError.invalid("a look needs a name")
        }
        let json = try CanonicalJSON.canonicalLookJSON(subset)
        return try db.transaction {
            let existing = try self.db.scalarInt("""
            SELECT id FROM look WHERE kind = ? AND grp IS ? AND name = ? LIMIT 1;
            """, [.text(kind.rawValue), .optionalText(group), .text(clean)])
            if let id = existing {
                try self.db.run(
                    "UPDATE look SET subset = ?, updated_at = ? WHERE id = ?;",
                    [.text(json), .integer(now), .integer(id)])
                return id
            }
            try self.db.run("""
            INSERT INTO look (name, grp, kind, subset, updated_at) VALUES (?, ?, ?, ?, ?);
            """, [.text(clean), .optionalText(group), .text(kind.rawValue),
                  .text(json), .integer(now)])
            return self.db.lastInsertRowID
        }
    }

    /// Every stored look of one register, newest name-sorted rather than
    /// recency-sorted: a browser whose rows move when you use them is a browser you
    /// have to re-read every time.
    public func looks(kind: LookKind = .look) throws -> [LookRow] {
        try allRows("SELECT \(CatalogStore.lookColumns) FROM look WHERE kind = ? "
                    + "ORDER BY COALESCE(grp, ''), name COLLATE NOCASE;",
                    [.text(kind.rawValue)], CatalogStore.decodeLook)
    }

    public func look(id: Int64) throws -> LookRow? {
        try firstRow("SELECT \(CatalogStore.lookColumns) FROM look WHERE id = ?;",
                     [.integer(id)], CatalogStore.decodeLook)
    }

    /// The look stored under a name, if there is one. What "apply the look called X"
    /// resolves through, and what a save dialog asks before it overwrites.
    public func look(named name: String, kind: LookKind = .look,
                     group: String? = nil) throws -> LookRow? {
        guard let clean = LookSubset.normalizedName(name) else { return nil }
        return try firstRow("SELECT \(CatalogStore.lookColumns) FROM look "
                            + "WHERE kind = ? AND grp IS ? AND name = ? LIMIT 1;",
                            [.text(kind.rawValue), .optionalText(group), .text(clean)],
                            CatalogStore.decodeLook)
    }

    /// Rename a look. Throws rather than silently merging when the new name is taken:
    /// a rename that quietly destroyed the look already sitting on that name would be
    /// the same loss `saveLook`'s save-over is at least explicit about.
    ///
    /// The check below is not what makes that safe — `look_identity` is. Deleting the
    /// check and running the suite leaves it green, because the UPDATE then violates
    /// the unique index and SQLite refuses it anyway; deleting both is what turns the
    /// rename into a clobber and the test red. The check earns its place by naming the
    /// look in the error, which is the difference between a sentence the panel can show
    /// and a raw constraint failure.
    public func renameLook(id: Int64, to name: String,
                           at now: Int64 = CatalogStore.now()) throws {
        guard let clean = LookSubset.normalizedName(name) else {
            throw CatalogError.invalid("a look needs a name")
        }
        try db.transaction {
            guard let row = try self.look(id: id) else {
                throw CatalogError.notFound("look \(id)")
            }
            let taken = try self.db.scalarInt("""
            SELECT id FROM look WHERE kind = ? AND grp IS ? AND name = ? AND id <> ?
             LIMIT 1;
            """, [.text(row.kind.rawValue), .optionalText(row.group), .text(clean),
                  .integer(id)])
            if taken != nil {
                throw CatalogError.invalid("a look called \(clean) already exists")
            }
            try self.db.run("UPDATE look SET name = ?, updated_at = ? WHERE id = ?;",
                            [.text(clean), .integer(now), .integer(id)])
        }
    }

    /// Delete a look. Nothing references `look.id` — a look is copied into a recipe at
    /// apply time, never linked — so this cannot orphan an edit, and a photograph
    /// graded with a look the photographer later threw away keeps its grade.
    public func deleteLook(id: Int64) throws {
        try db.run("DELETE FROM look WHERE id = ?;", [.integer(id)])
    }

    // MARK: - Culling state

    /// The decision write path: one transaction per action, never on the input path.
    public func setFlag(_ flag: PhotoFlag, photoID: Int64) throws {
        try setFlag(flag, photoIDs: [photoID])
    }

    /// Capture metadata, filled in by a background pass after the grid is already up.
    ///
    /// Not part of `scan`, deliberately. Reading EXIF costs a file open per photo, and
    /// the scan is what stands between the user and their first grid — docs/16 gates
    /// that at under a second for five thousand photos. Everything here is nullable and
    /// stays null until something fills it, which is what makes the pass interruptible.
    public func setMetadata(_ metadata: PhotoMetadata, photoID: Int64) throws {
        try db.transaction {
            try self.writeMetadata(metadata, photoID: photoID)
            // LIB-10. `camera` and `lens` reach the catalog nowhere else, and the FTS
            // row was built at scan time — minutes earlier, when both were still NULL.
            // Without this line the index holds empty strings for the two fields the
            // text chip's own placeholder advertises, so searching "Sony" matched
            // nothing on the branch that is PREFERRED whenever FTS5 is compiled in,
            // while the slower LIKE fallback found it. Re-indexing belongs next to the
            // write and inside the same transaction, so the index cannot end up
            // describing a photo the catalog no longer holds.
            self.reindexText(photoID: photoID)
        }
    }

    /// The bare UPDATE, without the re-index. Split out so the batch below can write
    /// every row first and re-index once per row afterwards, rather than nesting a
    /// savepoint per photo inside a five-thousand-row transaction.
    private func writeMetadata(_ metadata: PhotoMetadata, photoID: Int64) throws {
        // `aspect` is a derived column, and it was derived in exactly one place: the
        // scan-time upsert, which has never seen a width or a height — those arrive
        // here, minutes later, from EXIF. So every photo the backfill filled in kept
        // `aspect = NULL`, and the aspect-ratio sort ordered the whole roll by NULL,
        // i.e. by row id, i.e. it silently did nothing. Maintained here, next to the
        // two columns it is computed from, so the two cannot disagree.
        let aspect: Double? = {
            guard let width = metadata.width, let height = metadata.height,
                  height > 0 else { return nil }
            return Double(width) / Double(height)
        }()
        let statement = try db.prepare("""
            UPDATE photo SET capture_at = ?, capture_subsec = ?, camera = ?,
                             camera_serial = ?, lens = ?, iso = ?, shutter_s = ?,
                             aperture = ?, focal_mm = ?, width = ?, height = ?,
                             orientation = ?, gps_lat = ?, gps_lon = ?,
                             aspect = COALESCE(?, aspect)
            WHERE id = ?;
            """)
        let values: [SQLiteValue] = [
            .optionalInteger(metadata.captureAt),
            .optionalInt(metadata.captureSubsec),
            .optionalText(metadata.camera),
            .optionalText(metadata.cameraSerial),
            .optionalText(metadata.lens),
            .optionalInt(metadata.iso),
            .optionalReal(metadata.shutterSeconds),
            .optionalReal(metadata.aperture),
            .optionalReal(metadata.focalMM),
            .optionalInt(metadata.width),
            .optionalInt(metadata.height),
            .optionalInt(metadata.orientation),
            .optionalReal(metadata.gpsLatitude),
            .optionalReal(metadata.gpsLongitude),
            .optionalReal(aspect),
            .integer(photoID),
        ]
        for (offset, value) in values.enumerated() {
            try statement.bind(offset + 1, value)
        }
        try statement.run()
    }

    /// A batch of metadata in one transaction.
    ///
    /// Five thousand individual commits is a minute of fsync; one transaction per few
    /// hundred rows is milliseconds. Batched here rather than at the call site so the
    /// database handle stays private and there is one place that knows how wide a
    /// transaction should be.
    public func setMetadata(_ batch: [(photoID: Int64, metadata: PhotoMetadata)]) throws {
        guard !batch.isEmpty else { return }
        try db.transaction {
            for entry in batch {
                try self.writeMetadata(entry.metadata, photoID: entry.photoID)
            }
            // LIB-10, the batch half. This is the writer the backfill pass actually
            // calls, so an index kept in step only by the single-photo entry point
            // would still have been empty on every real launch.
            for entry in batch { self.reindexText(photoID: entry.photoID) }
        }
    }

    /// Photos no capture time has been read for yet.
    ///
    /// `capture_at IS NULL` is the resume marker rather than a separate "done" column:
    /// a photo genuinely without a capture time is re-read next launch, which costs one
    /// file open and is cheaper than a column that can disagree with the file.
    ///
    /// `afterID` is what makes the caller's loop TERMINATE. The obvious loop — "fetch,
    /// write, fetch again until empty" — never ends on a folder holding one file whose
    /// EXIF cannot be parsed: that row keeps `capture_at IS NULL` forever and comes back
    /// in every page. Paging by strictly increasing id ends after one pass over the
    /// folder whatever the files contain (LIB-26a: the caller used to fetch one page of
    /// 5,000 and stop, so a 20k folder needed four launches to sort correctly).
    public func photosMissingMetadata(folderID: Int64, afterID: Int64 = 0,
                                      limit: Int = 5000) throws
        -> [(id: Int64, filename: String)] {
        let statement = try db.prepare("""
            SELECT id, filename FROM photo
            WHERE folder_id = ? AND id > ? AND capture_at IS NULL AND missing = 0
            ORDER BY id LIMIT ?;
            """)
        try statement.bind(1, SQLiteValue.integer(folderID))
        try statement.bind(2, SQLiteValue.integer(afterID))
        try statement.bind(3, SQLiteValue.int(limit))
        var out: [(id: Int64, filename: String)] = []
        while try statement.step() {
            out.append((id: statement.int(0), filename: statement.string(1) ?? ""))
        }
        return out
    }

    /// Photos whose `quick_sig` has never been computed.
    ///
    /// Same resume-marker discipline as the metadata backfill, and paged by id for the
    /// same reason: a file that cannot be opened stays NULL and must not be able to
    /// spin the caller's loop.
    public func photosMissingQuickSig(folderID: Int64, afterID: Int64 = 0,
                                      limit: Int = 5000) throws
        -> [(id: Int64, filename: String)] {
        let statement = try db.prepare("""
            SELECT id, filename FROM photo
            WHERE folder_id = ? AND id > ?
              AND (quick_sig IS NULL OR quick_sig = '') AND missing = 0
            ORDER BY id LIMIT ?;
            """)
        try statement.bind(1, SQLiteValue.integer(folderID))
        try statement.bind(2, SQLiteValue.integer(afterID))
        try statement.bind(3, SQLiteValue.int(limit))
        var out: [(id: Int64, filename: String)] = []
        while try statement.step() {
            out.append((id: statement.int(0), filename: statement.string(1) ?? ""))
        }
        return out
    }

    /// Record a computed `quick_sig`. This is the writer the column never had.
    public func setQuickSig(_ signature: String, photoID: Int64) throws {
        try setQuickSigs([(photoID: photoID, signature: signature)])
    }

    /// A batch in one transaction, for the same reason `setMetadata` batches: five
    /// thousand individual commits is a minute of fsync.
    public func setQuickSigs(_ batch: [(photoID: Int64, signature: String)]) throws {
        guard !batch.isEmpty else { return }
        try db.transaction {
            for entry in batch {
                try self.db.run("UPDATE photo SET quick_sig = ? WHERE id = ?;",
                                [.text(entry.signature), .integer(entry.photoID)])
            }
        }
    }

    /// The sidecar's mtime as of our last write of it, or our last read of it — the
    /// clock docs/15 §15.5's three conflict rules are evaluated against. Written on
    /// both sides of the exchange, because "unchanged since we last touched it" is the
    /// only question rule 1 asks and a stamp taken on writes alone cannot answer it for
    /// a sidecar that arrived from another machine.
    public func setSidecarMTime(_ mtime: Int64?, photoID: Int64) throws {
        try db.run("UPDATE photo SET sidecar_mtime = ? WHERE id = ?;",
                   [.optionalInteger(mtime), .integer(photoID)])
    }

    public func setRating(_ rating: Int, photoID: Int64) throws {
        try setRating(rating, photoIDs: [photoID])
    }

    public func setLabel(_ label: ColorLabel?, photoID: Int64) throws {
        try setLabel(label, photoIDs: [photoID])
    }

    /// Painter mode sweeps 800 cells into one transaction batch, never a UI stall.
    public func setFlag(_ flag: PhotoFlag, photoIDs: [Int64]) throws {
        try batchUpdate("UPDATE photo SET flag = ? WHERE id = ?;",
                        value: .integer(Int64(flag.rawValue)), photoIDs: photoIDs)
    }

    public func setRating(_ rating: Int, photoIDs: [Int64]) throws {
        let clamped = min(5, max(0, rating))
        try batchUpdate("UPDATE photo SET rating = ? WHERE id = ?;",
                        value: .int(clamped), photoIDs: photoIDs)
    }

    public func setLabel(_ label: ColorLabel?, photoIDs: [Int64]) throws {
        try batchUpdate("UPDATE photo SET label = ? WHERE id = ?;",
                        value: .optionalText(label?.rawValue), photoIDs: photoIDs)
    }

    private func batchUpdate(_ sql: String, value: SQLiteValue,
                             photoIDs: [Int64]) throws {
        if photoIDs.isEmpty { return }
        try db.transaction {
            let statement = try self.db.prepare(sql)
            for id in photoIDs {
                statement.reset()
                try statement.bind(1, value)
                try statement.bind(2, id)
                try statement.run()
            }
            statement.reset()
        }
    }

    /// Cull HUD counters: total / picks / rejects / unrated, in one pass.
    public func cullCounts(folderID: Int64?) throws -> (total: Int, picks: Int,
                                                        rejects: Int, unrated: Int) {
        let scope = folderID == nil ? "" : " WHERE folder_id = ?"
        var parameters: [SQLiteValue] = []
        if let id = folderID { parameters.append(.integer(id)) }
        let sql = """
        SELECT COUNT(*),
               SUM(CASE WHEN flag = 1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN flag = -1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN rating = 0 THEN 1 ELSE 0 END)
          FROM photo\(scope);
        """
        let statement = try db.prepare(sql)
        try statement.bindAll(parameters)
        defer { statement.reset() }
        if try statement.step() {
            return (total: Int(statement.int(0)),
                    picks: Int(statement.int(1)),
                    rejects: Int(statement.int(2)),
                    unrated: Int(statement.int(3)))
        }
        return (0, 0, 0, 0)
    }

    // MARK: - Collections, stacks, keywords

    @discardableResult
    public func createCollection(name: String, kind: String = "manual",
                                 parentID: Int64? = nil, query: String? = nil,
                                 scope: String? = nil, scopeID: Int64? = nil,
                                 pinned: Bool = false, position: Int = 0) throws -> Int64 {
        try db.run("""
        INSERT INTO album (parent_id, name, kind, query, position, scope, scope_id, pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [.optionalInteger(parentID), .text(name), .text(kind),
              .optionalText(query), .int(position), .optionalText(scope),
              .optionalInteger(scopeID), .bool(pinned)])
        return db.lastInsertRowID
    }

    public func collections() throws -> [CollectionRow] {
        try allRows("SELECT \(CatalogStore.albumColumns) FROM album "
                    + "ORDER BY position, name;", [], CatalogStore.decodeCollection)
    }

    public func collection(id: Int64) throws -> CollectionRow? {
        try firstRow("SELECT \(CatalogStore.albumColumns) FROM album WHERE id = ?;",
                     [.integer(id)], CatalogStore.decodeCollection)
    }

    /// `B` adds to the target album (default "Tray"); any album is designatable.
    public func setTargetCollection(_ albumID: Int64) throws {
        try db.transaction {
            try self.db.run("UPDATE album SET is_target = 0 WHERE is_target = 1;")
            try self.db.run("UPDATE album SET is_target = 1 WHERE id = ?;",
                            [.integer(albumID)])
        }
    }

    public func targetCollectionID() throws -> Int64? {
        try db.scalarInt("SELECT id FROM album WHERE is_target = 1 LIMIT 1;")
    }

    public func addToCollection(_ albumID: Int64, photoIDs: [Int64]) throws {
        if photoIDs.isEmpty { return }
        try db.transaction {
            let next = (try self.db.scalarInt(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM album_photo WHERE album_id = ?;",
                [.integer(albumID)])) ?? 0
            let statement = try self.db.prepare(
                "INSERT OR IGNORE INTO album_photo (album_id, photo_id, position) "
                + "VALUES (?, ?, ?);")
            var position = next
            for id in photoIDs {
                statement.reset()
                try statement.bind(1, albumID)
                try statement.bind(2, id)
                try statement.bind(3, position)
                try statement.run()
                position += 1
            }
            statement.reset()
        }
    }

    public func removeFromCollection(_ albumID: Int64, photoIDs: [Int64]) throws {
        if photoIDs.isEmpty { return }
        try db.transaction {
            let statement = try self.db.prepare(
                "DELETE FROM album_photo WHERE album_id = ? AND photo_id = ?;")
            for id in photoIDs {
                statement.reset()
                try statement.bind(1, albumID)
                try statement.bind(2, id)
                try statement.run()
            }
            statement.reset()
        }
    }

    /// Collapsing 3,000 frames into 400 stacks is a pure index operation.
    public func setStackCollapsed(_ collapsed: Bool, stackID: Int64) throws {
        try db.run("UPDATE stack SET collapsed = ? WHERE id = ?;",
                   [.bool(collapsed), .integer(stackID)])
    }

    /// RE-STACKING A PHOTOGRAPH USED TO MAKE ITS OLD STACK DISAPPEAR FROM THE GRID.
    ///
    /// `stack_member.photo_id` is UNIQUE and this inserted with `OR REPLACE`, so taking a
    /// frame into a new stack silently deleted its old membership row — while the old
    /// `stack.pick_photo_id` went on pointing at it. `collapsedTopsOnly` is
    /// `s.collapsed = 0 OR s.pick_photo_id = photo.id`, and with the pick no longer a
    /// member that is false for every remaining member; the `NOT EXISTS stack_member`
    /// branch is false too. The whole stack drops out of the contact sheet.
    ///
    /// Reproduced: a burst A/B/C collapsed with A as the pick, then ⌘G on {A, D}. B and C
    /// are on disk, in the catalog, and in no view — and nothing in the interface can
    /// bring them back, because the stack they belong to is the thing that vanished.
    ///
    /// Three things had to change together, and none of them is the SQL predicate:
    /// membership is moved rather than replaced, a stack that loses its pick re-picks
    /// from the survivors (or is deleted when there are none), and a pick that is not one
    /// of the members is refused — which `setStackPick` already did and this did not.
    @discardableResult
    public func createStack(origin: String, photoIDs: [Int64],
                            pickPhotoID: Int64? = nil) throws -> Int64 {
        try db.transaction {
            // A pick that is not a member is not a pick. `setStackPick` refuses one;
            // accepting it here was how a stack could be born already broken.
            let pick = pickPhotoID.flatMap { photoIDs.contains($0) ? $0 : nil }
                ?? photoIDs.first

            // WHICH STACKS ARE LOSING MEMBERS, read before the delete so the repair below
            // knows where to look.
            var touched: Set<Int64> = []
            for id in photoIDs {
                if let old = try self.db.scalarInt(
                    "SELECT stack_id FROM stack_member WHERE photo_id = ?;",
                    [.integer(id)]) {
                    touched.insert(old)
                }
            }
            for id in photoIDs {
                try self.db.run("DELETE FROM stack_member WHERE photo_id = ?;",
                                [.integer(id)])
            }

            try self.db.run(
                "INSERT INTO stack (origin, pick_photo_id, collapsed) VALUES (?, ?, 1);",
                [.text(origin), .optionalInteger(pick)])
            let stackID = self.db.lastInsertRowID
            let statement = try self.db.prepare(
                "INSERT INTO stack_member (stack_id, photo_id, position) "
                + "VALUES (?, ?, ?);")
            var position = 0
            for id in photoIDs {
                statement.reset()
                try statement.bind(1, stackID)
                try statement.bind(2, id)
                try statement.bind(3, position)
                try statement.run()
                position += 1
            }
            statement.reset()

            // REPAIR WHAT WAS LEFT BEHIND. A stack with no members at all is an orphan
            // row nothing would ever delete; one whose pick has moved away needs a new
            // pick, or every one of its frames is invisible while collapsed.
            for old in touched where old != stackID {
                guard let survivor = try self.db.scalarInt(
                    "SELECT photo_id FROM stack_member WHERE stack_id = ? "
                    + "ORDER BY position ASC LIMIT 1;", [.integer(old)]) else {
                    try self.db.run("DELETE FROM stack WHERE id = ?;", [.integer(old)])
                    continue
                }
                let stillAMember = try self.db.scalarInt(
                    "SELECT 1 FROM stack_member m JOIN stack s ON s.id = m.stack_id "
                    + "WHERE s.id = ? AND m.photo_id = s.pick_photo_id;",
                    [.integer(old)]) != nil
                if !stillAMember {
                    try self.db.run("UPDATE stack SET pick_photo_id = ? WHERE id = ?;",
                                    [.integer(survivor), .integer(old)])
                }
            }
            return stackID
        }
    }

    @discardableResult
    public func addKeyword(_ name: String, photoIDs: [Int64]) throws -> Int64 {
        try db.transaction {
            var keywordID = try self.db.scalarInt(
                "SELECT id FROM keyword WHERE name = ? LIMIT 1;", [.text(name)])
            if keywordID == nil {
                try self.db.run("INSERT INTO keyword (name) VALUES (?);", [.text(name)])
                keywordID = self.db.lastInsertRowID
            }
            guard let id = keywordID else {
                throw CatalogError.notFound("keyword \(name) after insert")
            }
            let statement = try self.db.prepare(
                "INSERT OR IGNORE INTO photo_keyword (photo_id, keyword_id) VALUES (?, ?);")
            for photoID in photoIDs {
                statement.reset()
                try statement.bind(1, photoID)
                try statement.bind(2, id)
                try statement.run()
            }
            statement.reset()
            for photoID in photoIDs { self.reindexText(photoID: photoID) }
            return id
        }
    }

    public func keywords(photoID: Int64) throws -> [String] {
        try allRows("SELECT k.name FROM photo_keyword pk "
                    + "JOIN keyword k ON k.id = pk.keyword_id "
                    + "WHERE pk.photo_id = ? ORDER BY k.name;",
                    [.integer(photoID)], { $0.string(0) ?? "" })
    }

    /// Every keyword in the catalog with how many photos carry it.
    ///
    /// THE CATALOG's, and that word is load-bearing: this counts `photo_keyword` across
    /// every folder ever opened and every offline frame, which is the right answer for
    /// a vocabulary list and the wrong one for anything beside a chip. The filter bar
    /// used to show these numbers next to a chip that queries one folder, and they were
    /// out by two orders of magnitude on any catalog with more than one shoot in it.
    /// The bar's keyword counts come from `facetCounts(for:)` now; this is the
    /// vocabulary only.
    public func allKeywords() throws -> [FacetValue] {
        try allRows("""
        SELECT k.name, COUNT(pk.photo_id) FROM keyword k
          LEFT JOIN photo_keyword pk ON pk.keyword_id = k.id
         GROUP BY k.id ORDER BY k.name;
        """, []) { FacetValue(value: $0.string(0) ?? "", count: Int($0.int(1))) }
    }

    /// Detaches a keyword from photos without deleting the keyword itself: a shoot
    /// vocabulary is worth keeping even when the last photo using a term is untagged.
    public func removeKeyword(_ name: String, photoIDs: [Int64]) throws {
        if photoIDs.isEmpty { return }
        try db.transaction {
            guard let keywordID = try self.db.scalarInt(
                "SELECT id FROM keyword WHERE name = ? LIMIT 1;", [.text(name)])
            else { return }
            let statement = try self.db.prepare(
                "DELETE FROM photo_keyword WHERE photo_id = ? AND keyword_id = ?;")
            for photoID in photoIDs {
                statement.reset()
                try statement.bind(1, photoID)
                try statement.bind(2, keywordID)
                try statement.run()
            }
            statement.reset()
            for photoID in photoIDs { self.reindexText(photoID: photoID) }
        }
    }

    // MARK: - Stacks

    /// The stack one photo belongs to, if any. `stack_member.photo_id` is UNIQUE, so
    /// this is a single index lookup and a photo is in at most one stack.
    public func stack(containing photoID: Int64) throws -> StackRow? {
        try firstRow("SELECT \(CatalogStore.stackColumns) FROM stack "
                     + "JOIN stack_member sm ON sm.stack_id = stack.id "
                     + "WHERE sm.photo_id = ? LIMIT 1;",
                     [.integer(photoID)], CatalogStore.decodeStack)
    }

    public func stackMembers(stackID: Int64) throws -> [Int64] {
        try allRows("SELECT photo_id FROM stack_member WHERE stack_id = ? "
                    + "ORDER BY position, photo_id;",
                    [.integer(stackID)], { $0.int(0) })
    }

    /// Promote a member to the pick — the frame the collapsed stack shows (`⇧S`).
    /// Refuses a photo that is not in the stack rather than pointing the stack at a
    /// thumbnail from somewhere else in the library.
    public func setStackPick(_ photoID: Int64, stackID: Int64) throws {
        guard (try db.scalarInt(
            "SELECT 1 FROM stack_member WHERE stack_id = ? AND photo_id = ? LIMIT 1;",
            [.integer(stackID), .integer(photoID)])) != nil else {
            throw CatalogError.invalid("photo \(photoID) is not in stack \(stackID)")
        }
        try db.run("UPDATE stack SET pick_photo_id = ? WHERE id = ?;",
                   [.integer(photoID), .integer(stackID)])
    }

    /// Unstack (`⇧⌘G`): the grouping goes, the photographs stay. Nothing here touches
    /// `photo`, which is the whole reason stacking is safe to try on a real card.
    public func dissolveStack(id: Int64) throws {
        try db.transaction {
            try self.db.run("DELETE FROM stack_member WHERE stack_id = ?;", [.integer(id)])
            try self.db.run("DELETE FROM stack WHERE id = ?;", [.integer(id)])
        }
    }

    // MARK: - Metadata chip values

    /// Every number the filter bar shows, counted through the query the grid runs.
    ///
    /// THE INVARIANT THIS EXISTS FOR: the number beside a facet is the number of rows
    /// you get when you click it. Nothing in here counts with SQL of its own. Every
    /// field is a `countPhotos` over the SAME `PhotoQuery` the grid is about to run,
    /// with exactly one criterion swapped for the value being offered — so the count
    /// and the result are not two queries that agree, they are one query.
    ///
    /// They used to be two, and they disagreed by two orders of magnitude, in three
    /// separate ways:
    ///
    ///   · keyword counts came from `allKeywords()`, which groups `photo_keyword` over
    ///     the WHOLE CATALOG — every folder ever opened, offline frames included —
    ///     while the grid shows one folder. A term used all season read in the
    ///     thousands beside a chip that returned eleven frames.
    ///   · camera and lens counts were folder-scoped but chip-blind. They counted the
    ///     folder, never the folder as the lit chips had already narrowed it.
    ///   · flag, rating and label counts were a pass over the roll in memory with no
    ///     filter applied at all. That is the "★4 · 37" that clicks through to six.
    ///
    /// WHAT "CLICK IT" MEANS, stated once so the tests and the bar cannot read it two
    /// ways: the number beside a value is the size of the grid with that value as the
    /// SOLE selection of its own criterion, every other criterion left exactly as it
    /// is. For a criterion nothing has narrowed yet — the ordinary case, and the one
    /// the ★ report was about — that is literally the row count of the next click. For
    /// a criterion that already has something lit it is that value's own contribution,
    /// which is the only reading that stays still while its siblings are toggled:
    /// counting "what you would get AFTER the toggle" would have a lit chip advertise
    /// the larger number it produces by being switched off.
    public func facetCounts(for query: PhotoQuery, folderID: Int64? = nil,
                            limit: Int = 200) throws -> FacetCounts {
        var counts = FacetCounts()

        for flag in PhotoFlag.allCases {
            var probe = query
            probe.flags = [flag]
            counts.flags[flag] = try countPhotos(matching: probe, folderID: folderID)
        }

        // `.atLeast` rather than whatever the caller was carrying: the bar offers
        // "★ r or better" and offers nothing else, so a probe that inherited
        // `.exactly` would be pricing a chip that does not exist.
        for stars in 1...5 {
            var probe = query
            probe.rating = stars
            probe.ratingComparison = .atLeast
            counts.ratingAtLeast[stars] = try countPhotos(matching: probe,
                                                          folderID: folderID)
        }

        for label in ColorLabel.allCases {
            var probe = query
            probe.labels = [label]
            probe.includeUnlabeled = false
            counts.labels[label] = try countPhotos(matching: probe, folderID: folderID)
        }
        var unlabeled = query
        unlabeled.labels = []
        unlabeled.includeUnlabeled = true
        counts.unlabeled = try countPhotos(matching: unlabeled, folderID: folderID)

        counts.cameras = try metadataFacetCounts(.camera, matching: query,
                                                 folderID: folderID, limit: limit)
        counts.lenses = try metadataFacetCounts(.lens, matching: query,
                                                folderID: folderID, limit: limit)
        counts.keywords = try keywordFacetCounts(matching: query, folderID: folderID,
                                                 limit: limit)
        return counts
    }

    /// Distinct values of one metadata column with live counts, most-used first.
    ///
    /// The unfiltered case of `facetCounts(for:)` and nothing else, so the two cannot
    /// drift apart — this used to be a second, independently written GROUP BY, which is
    /// how the drift started. `includeMissing = false` because that is what this call
    /// has always meant: a frame that is not on the disk is not something a chip can
    /// show you.
    public func facetCounts(_ facet: PhotoFacet, folderID: Int64? = nil,
                            limit: Int = 200) throws -> [FacetValue] {
        var query = PhotoQuery()
        query.includeMissing = false
        return try metadataFacetCounts(facet, matching: query, folderID: folderID,
                                       limit: limit)
    }

    /// One metadata axis: the values the scope actually contains, each priced by the
    /// grid's own query with that value swapped in.
    ///
    /// One statement per value rather than one GROUP BY over the axis, and deliberately.
    /// A GROUP BY that respected the other lit chips would need a SECOND copy of the
    /// predicate set, and a second copy of the predicate set is precisely how the number
    /// and the result came to disagree. `countPhotos` shares `buildPhotoQuery` with
    /// `photos(matching:)`, so the tree holds exactly one set of predicates and the
    /// count is the grid. What that costs is in the class comment on `facetDomain`.
    private func metadataFacetCounts(_ facet: PhotoFacet, matching query: PhotoQuery,
                                     folderID: Int64?,
                                     limit: Int) throws -> [FacetValue] {
        let selected: Set<String>
        switch facet {
        case .camera: selected = Set(query.cameras)
        case .lens: selected = Set(query.lenses)
        }
        var out: [FacetValue] = []
        for value in try facetDomain(facet, query: query, folderID: folderID,
                                     limit: limit) {
            var probe = query
            switch facet {
            case .camera: probe.cameras = [value]
            case .lens: probe.lenses = [value]
            }
            let count = try countPhotos(matching: probe, folderID: folderID)
            // A value that would return nothing is not offered. A row reading "0" is a
            // control that does nothing, which is the one thing this bar has always
            // refused to draw. A value already lit stays whatever its count, or there
            // would be no way left to switch it off.
            if count > 0 || selected.contains(value) {
                out.append(FacetValue(value: value, count: count))
            }
        }
        return CatalogStore.rankedFacets(out)
    }

    /// The vocabulary a menu offers: the values present in the SCOPE — this folder,
    /// these on-disk frames — not in the catalog.
    ///
    /// Ordered by how common they are in the scope because `LIMIT` has to cut somewhere
    /// and scope frequency is the one ordering available before the honest counts
    /// exist; with the criteria ANDing, a value's honest count can only be smaller than
    /// its scope count, so the cut never hides a big number behind a small one. The
    /// honest counts then re-rank whatever survived.
    ///
    /// THE COST, stated plainly: this is one index-backed statement for the domain plus
    /// one `COUNT(*)` per value offered, where the old wrong answer was a single GROUP
    /// BY. For camera and lens that is a handful of statements; for keywords it is
    /// bounded by `limit`. Correct first, fast second — and the whole set is computed
    /// only when the filter popover is open, never per keystroke.
    private func facetDomain(_ facet: PhotoFacet, query: PhotoQuery, folderID: Int64?,
                             limit: Int) throws -> [String] {
        var conditions = ["photo.\(facet.column) IS NOT NULL"]
        var parameters: [SQLiteValue] = []
        if !query.includeMissing { conditions.append("photo.missing = 0") }
        if let folderID = folderID {
            conditions.append("photo.folder_id = ?")
            parameters.append(.integer(folderID))
        }
        parameters.append(.int(limit))
        return try allRows("""
        SELECT photo.\(facet.column) FROM photo
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY photo.\(facet.column)
        ORDER BY COUNT(*) DESC, photo.\(facet.column)
        LIMIT ?;
        """, parameters) { $0.string(0) ?? "" }
    }

    /// The keyword axis.
    ///
    /// The domain is joined THROUGH `photo` so it is the FOLDER's vocabulary rather
    /// than the library's. `allKeywords()` is the library's, by design and by name, and
    /// putting its numbers beside a chip that queries one folder is the two-orders-of-
    /// magnitude half of this finding.
    private func keywordFacetCounts(matching query: PhotoQuery, folderID: Int64?,
                                    limit: Int) throws -> [FacetValue] {
        var conditions: [String] = []
        var parameters: [SQLiteValue] = []
        if !query.includeMissing { conditions.append("photo.missing = 0") }
        if let folderID = folderID {
            conditions.append("photo.folder_id = ?")
            parameters.append(.integer(folderID))
        }
        let scope = conditions.isEmpty
            ? "" : "WHERE " + conditions.joined(separator: " AND ")
        parameters.append(.int(limit))
        let domain = try allRows("""
        SELECT k.name FROM keyword k
        JOIN photo_keyword pk ON pk.keyword_id = k.id
        JOIN photo ON photo.id = pk.photo_id
        \(scope)
        GROUP BY k.id
        ORDER BY COUNT(DISTINCT photo.id) DESC, k.name
        LIMIT ?;
        """, parameters) { $0.string(0) ?? "" }

        let selected = Set(query.keywords)
        var out: [FacetValue] = []
        for name in domain {
            var probe = query
            probe.keywords = [name]
            let count = try countPhotos(matching: probe, folderID: folderID)
            if count > 0 || selected.contains(name) {
                out.append(FacetValue(value: name, count: count))
            }
        }
        return CatalogStore.rankedFacets(out)
    }

    /// Most-used first, ties broken by name so a menu does not reshuffle two equal
    /// values against each other on every refresh.
    private static func rankedFacets(_ values: [FacetValue]) -> [FacetValue] {
        values.sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
    }

    // MARK: - Per-source view state (G24)

    public func sourceState(_ key: String) throws
        -> (sortKey: String, ascending: Bool, thumbPx: Int, filterJSON: String?)? {
        try firstRow("SELECT sort_key, sort_dir, thumb_px, filter_json "
                     + "FROM source_state WHERE source_key = ?;", [.text(key)]) { s in
            (sortKey: s.string(0) ?? "captureTime",
             ascending: s.int(1) >= 0,
             thumbPx: Int(s.int(2)),
             filterJSON: s.string(3))
        }
    }

    public func setSourceState(_ key: String, sortKey: String, ascending: Bool,
                               thumbPx: Int, filterJSON: String?) throws {
        try db.run("""
        INSERT INTO source_state (source_key, sort_key, sort_dir, thumb_px, filter_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(source_key) DO UPDATE SET
          sort_key    = excluded.sort_key,
          sort_dir    = excluded.sort_dir,
          thumb_px    = excluded.thumb_px,
          filter_json = excluded.filter_json;
        """, [.text(key), .text(sortKey), .int(ascending ? 1 : -1),
              .int(thumbPx), .optionalText(filterJSON)])
    }

    // MARK: - Preview cache bookkeeping

    /// Records (or replaces) one preview row. Payload lives on disk; this is pure
    /// bookkeeping keyed (photo_id, level, recipe_fp).
    public func recordPreview(_ preview: PreviewRow,
                              at now: Int64 = CatalogStore.now()) throws {
        try db.run("""
        INSERT INTO cache.preview
          (photo_id, level, recipe_fp, source, path, bytes, created_at, last_used_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(photo_id, level, recipe_fp) DO UPDATE SET
          source       = excluded.source,
          path         = excluded.path,
          bytes        = excluded.bytes,
          last_used_at = excluded.last_used_at;
        """, [.integer(preview.photoID), .int(preview.level.rawValue),
              .text(preview.recipeFP), .text(preview.source.rawValue),
              .text(preview.path), .integer(preview.bytes),
              .integer(preview.createdAt == 0 ? now : preview.createdAt),
              .integer(preview.lastUsedAt == 0 ? now : preview.lastUsedAt)])
    }

    public func preview(photoID: Int64, level: PreviewLevel,
                        recipeFP: String = "") throws -> PreviewRow? {
        try firstRow("SELECT \(CatalogStore.previewColumns) FROM cache.preview "
                     + "WHERE photo_id = ? AND level = ? AND recipe_fp = ?;",
                     [.integer(photoID), .int(level.rawValue), .text(recipeFP)],
                     CatalogStore.decodePreview)
    }

    public func previews(photoID: Int64) throws -> [PreviewRow] {
        try allRows("SELECT \(CatalogStore.previewColumns) FROM cache.preview "
                    + "WHERE photo_id = ? ORDER BY level;",
                    [.integer(photoID)], CatalogStore.decodePreview)
    }

    /// LRU stamp. Called on every serve; index `preview_lru` makes eviction ordered.
    public func touchPreview(photoID: Int64, level: PreviewLevel, recipeFP: String = "",
                             at now: Int64 = CatalogStore.now()) throws {
        try db.run("UPDATE cache.preview SET last_used_at = ? "
                   + "WHERE photo_id = ? AND level = ? AND recipe_fp = ?;",
                   [.integer(now), .integer(photoID), .int(level.rawValue),
                    .text(recipeFP)])
    }

    /// Marks fit and 1:1 rows for a photo stale after an edit (thumb/grid survive:
    /// browsing never blocks on the develop loop). Returns the rows to unlink.
    @discardableResult
    public func invalidatePreviews(photoID: Int64,
                                   keeping recipeFP: String) throws -> [PreviewRow] {
        try db.transaction {
            let stale = try self.allRows(
                "SELECT \(CatalogStore.previewColumns) FROM cache.preview "
                + "WHERE photo_id = ? AND level >= 2 AND recipe_fp <> ?;",
                [.integer(photoID), .text(recipeFP)], CatalogStore.decodePreview)
            try self.db.run("DELETE FROM cache.preview "
                            + "WHERE photo_id = ? AND level >= 2 AND recipe_fp <> ?;",
                            [.integer(photoID), .text(recipeFP)])
            return stale
        }
    }

    public func previewCacheBytes() throws -> Int64 {
        (try db.scalarInt("SELECT COALESCE(SUM(bytes), 0) FROM cache.preview;")) ?? 0
    }

    /// LRU eviction to a byte budget. Order is 1:1 -> fit -> grid, least-recently-viewed
    /// first; level 0 thumbnails are permanent (docs/15 §15.6). Returns the evicted rows
    /// so the caller can unlink the payload files — this layer only does bookkeeping.
    @discardableResult
    public func pruneCache(maxBytes: Int64) throws -> [PreviewRow] {
        let total = try previewCacheBytes()
        if total <= maxBytes { return [] }
        var toReclaim = total - maxBytes
        var victims: [PreviewRow] = []

        // Streamed rather than materialized: at 200k photos the level-3 set is large,
        // and eviction usually stops after a handful of rows.
        for level in [PreviewLevel.oneToOne, PreviewLevel.fit, PreviewLevel.grid] {
            if toReclaim <= 0 { break }
            let statement = try db.prepare(
                "SELECT \(CatalogStore.previewColumns) FROM cache.preview "
                + "WHERE level = ? ORDER BY last_used_at ASC;")
            try statement.bind(1, Int64(level.rawValue))
            while toReclaim > 0 {
                guard try statement.step() else { break }
                let row = CatalogStore.decodePreview(statement)
                victims.append(row)
                toReclaim -= row.bytes
            }
            statement.reset()
        }
        if victims.isEmpty { return [] }

        try db.transaction {
            let statement = try self.db.prepare(
                "DELETE FROM cache.preview "
                + "WHERE photo_id = ? AND level = ? AND recipe_fp = ?;")
            for row in victims {
                statement.reset()
                try statement.bind(1, row.photoID)
                try statement.bind(2, Int64(row.level.rawValue))
                try statement.bind(3, row.recipeFP)
                try statement.run()
            }
            statement.reset()
        }
        return victims
    }

    // MARK: - Artifact bookkeeping

    /// Upsert on the full six-tuple key (docs/15 §15.7): photo, kind, component,
    /// model id + version, prefix hash, pipeline version.
    ///
    /// Written as look-then-write rather than ON CONFLICT because three of the six key
    /// fields are nullable, and `NULL = NULL` is never true in a conflict target. The
    /// lookup uses `IS`, which does match NULL to NULL.
    @discardableResult
    public func recordArtifact(_ artifact: ArtifactRow,
                               at now: Int64 = CatalogStore.now()) throws -> Int64 {
        let key: [SQLiteValue] = [
            .integer(artifact.photoID), .text(artifact.kind),
            .optionalText(artifact.componentID), .optionalText(artifact.modelID),
            .optionalText(artifact.modelVersion), .text(artifact.prefixHash),
            .int(artifact.pipelineVersion)]
        let lookupSQL = """
        SELECT id FROM cache.artifact
         WHERE photo_id = ? AND kind = ?
           AND component_id IS ? AND model_id IS ? AND model_version IS ?
           AND prefix_hash = ? AND pipeline_version = ?;
        """
        return try db.transaction {
            if let existing = try self.db.scalarInt(lookupSQL, key) {
                try self.db.run("""
                UPDATE cache.artifact SET checksum = ?, path = ?, bytes = ?,
                  last_used_at = ? WHERE id = ?;
                """, [.text(artifact.checksum), .text(artifact.path),
                      .integer(artifact.bytes),
                      .integer(artifact.lastUsedAt == 0 ? now : artifact.lastUsedAt),
                      .integer(existing)])
                return existing
            }
            try self.db.run("""
            INSERT INTO cache.artifact
              (photo_id, kind, component_id, model_id, model_version, prefix_hash,
               pipeline_version, checksum, path, bytes, created_at, last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.integer(artifact.photoID), .text(artifact.kind),
                  .optionalText(artifact.componentID), .optionalText(artifact.modelID),
                  .optionalText(artifact.modelVersion), .text(artifact.prefixHash),
                  .int(artifact.pipelineVersion), .text(artifact.checksum),
                  .text(artifact.path), .integer(artifact.bytes),
                  .integer(artifact.createdAt == 0 ? now : artifact.createdAt),
                  .integer(artifact.lastUsedAt == 0 ? now : artifact.lastUsedAt)])
            return self.db.lastInsertRowID
        }
    }

    /// Exact-key lookup. `IS` rather than `=` so a NULL component / model matches.
    public func artifact(photoID: Int64, kind: String, componentID: String? = nil,
                         modelID: String? = nil, modelVersion: String? = nil,
                         prefixHash: String,
                         pipelineVersion: Int = currentPipelineVersion) throws
        -> ArtifactRow? {
        try firstRow("""
        SELECT \(CatalogStore.artifactColumns) FROM cache.artifact
         WHERE photo_id = ? AND kind = ?
           AND component_id IS ? AND model_id IS ? AND model_version IS ?
           AND prefix_hash = ? AND pipeline_version = ?;
        """, [.integer(photoID), .text(kind), .optionalText(componentID),
              .optionalText(modelID), .optionalText(modelVersion),
              .text(prefixHash), .int(pipelineVersion)],
             CatalogStore.decodeArtifact)
    }

    public func touchArtifact(id: Int64, at now: Int64 = CatalogStore.now()) throws {
        try db.run("UPDATE cache.artifact SET last_used_at = ? WHERE id = ?;",
                   [.integer(now), .integer(id)])
    }

    public func artifactBytes(kind: String? = nil) throws -> Int64 {
        if let kind = kind {
            return (try db.scalarInt(
                "SELECT COALESCE(SUM(bytes), 0) FROM cache.artifact WHERE kind = ?;",
                [.text(kind)])) ?? 0
        }
        return (try db.scalarInt(
            "SELECT COALESCE(SUM(bytes), 0) FROM cache.artifact;")) ?? 0
    }

    /// Per-kind LRU budget (§15.7: embeddings evict first, denoise atlases last — the
    /// ordering lives in the caller's budget table, this is the mechanism).
    @discardableResult
    public func pruneArtifacts(kind: String, maxBytes: Int64) throws -> [ArtifactRow] {
        let total = try artifactBytes(kind: kind)
        if total <= maxBytes { return [] }
        var toReclaim = total - maxBytes
        var victims: [ArtifactRow] = []
        let candidates = try allRows(
            "SELECT \(CatalogStore.artifactColumns) FROM cache.artifact "
            + "WHERE kind = ? ORDER BY last_used_at ASC;",
            [.text(kind)], CatalogStore.decodeArtifact)
        for row in candidates {
            if toReclaim <= 0 { break }
            victims.append(row)
            toReclaim -= row.bytes
        }
        if victims.isEmpty { return [] }
        try db.transaction {
            let statement = try self.db.prepare("DELETE FROM cache.artifact WHERE id = ?;")
            for row in victims {
                statement.reset()
                try statement.bind(1, row.id)
                try statement.run()
            }
            statement.reset()
        }
        return victims
    }

    /// Self-healing read path (D52): a checksum/version mismatch, a missing file or a
    /// truncated payload discards the row so the worker regenerates from parametric
    /// truth. Never an error to the user.
    public func discardArtifact(id: Int64) throws {
        try db.run("DELETE FROM cache.artifact WHERE id = ?;", [.integer(id)])
    }

    // MARK: - Raw-truth statistics (`cache.raw_stats`)

    /// The cull-time scene-linear statistics, cached so a second look at a photograph
    /// does not pay for a second decode.
    ///
    /// The table has existed since the first schema and nothing wrote to it, which is
    /// why `RawStatistics` had two round-trip tests and no product behind them. These
    /// four calls are the writer, the reader, the staleness rule and the backlog query.
    ///
    /// The row is disposable by construction (`cache.db`, D52), so every failure mode
    /// here resolves to "recompute": a blob that does not decode, an analyzer revision
    /// this build does not recognise, or a provenance that is not the one being asked
    /// for all read as absent rather than as an error.
    @discardableResult
    public func recordRawStatistics(_ stats: RawStatistics, photoID: Int64,
                                    at now: Int64 = CatalogStore.now()) throws -> Bool {
        // A measurement that cannot say what it measured is not cached. Storing it
        // would put a row in front of the panel that has to be captioned "this is not
        // evidence of anything", and a cache whose job is to avoid recomputation must
        // not be the reason a wrong caption survives.
        guard stats.provenance != .unspecified else { return false }
        try db.run("""
        INSERT INTO cache.raw_stats (photo_id, bins, clipped_pct, analyzer_rev, computed_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(photo_id) DO UPDATE SET
          bins         = excluded.bins,
          clipped_pct  = excluded.clipped_pct,
          analyzer_rev = excluded.analyzer_rev,
          computed_at  = excluded.computed_at;
        """, [.integer(photoID), .blob(stats.encoded()),
              .text(stats.clippedPercentJSON),
              .int(Int(stats.analyzerRevision)), .integer(now)])
        return true
    }

    /// The cached measurement, or nil when there is none this build can use.
    ///
    /// `revision` and `provenance` are both required rather than optional filters,
    /// because both are ways the same photograph's row can be stale in a way no
    /// exception would announce: a binning change makes the bins mean something else,
    /// and a row measured on the decoded frame is not an answer to a caller asking for
    /// the sensor's mosaic. Reading either as a hit is how a cache starts lying.
    public func rawStatistics(photoID: Int64,
                              revision: UInt16 = RawStatistics.currentAnalyzerRevision,
                              provenance: RawStatistics.Provenance) throws -> RawStatistics? {
        let blob: Data? = try firstRow(
            "SELECT bins FROM cache.raw_stats WHERE photo_id = ? AND analyzer_rev = ?;",
            [.integer(photoID), .int(Int(revision))]) { $0.data(0) ?? Data() }
        guard let blob, let decoded = RawStatistics.decode(blob) else { return nil }
        guard decoded.analyzerRevision == revision else { return nil }
        guard decoded.provenance == provenance else { return nil }
        return decoded
    }

    /// The `clipped_pct` JSON as stored, for a caller that wants the numbers without
    /// paying to decode 2 KB of bins — the grid badge, not the panel.
    public func rawStatisticsClippedJSON(photoID: Int64) throws -> String? {
        let text: String? = try firstRow(
            "SELECT clipped_pct FROM cache.raw_stats WHERE photo_id = ?;",
            [.integer(photoID)]) { $0.string(0) ?? "" }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Photographs in a folder with no usable row, oldest id first — the background
    /// worker's queue. A row at the wrong revision counts as missing, which is what
    /// makes a revision bump a recompute rather than a permanent wrong answer.
    public func photosMissingRawStatistics(
        folderID: Int64,
        revision: UInt16 = RawStatistics.currentAnalyzerRevision,
        afterID: Int64 = 0,
        limit: Int = 500) throws -> [Int64] {
        try allRows("""
        SELECT photo.id FROM photo
        LEFT JOIN cache.raw_stats AS rs
               ON rs.photo_id = photo.id AND rs.analyzer_rev = ?
        WHERE photo.folder_id = ? AND photo.id > ? AND photo.missing = 0
          AND rs.photo_id IS NULL
        ORDER BY photo.id
        LIMIT ?;
        """, [.int(Int(revision)), .integer(folderID), .integer(afterID),
              .int(Swift.max(0, limit))]) { $0.int(0) }
    }

    // MARK: - Filter / sort query builder

    /// Builds and runs the grid query. Every value is a bound parameter; the only
    /// interpolated fragments are compile-time constants chosen by an enum.
    public func photos(matching query: PhotoQuery,
                       folderID: Int64? = nil) throws -> [PhotoRow] {
        let built = buildPhotoQuery(query, folderID: folderID, countOnly: false)
        return try allRows(built.sql, built.parameters, CatalogStore.decodePhoto)
    }

    /// Live chip counts ride the same predicates and the same indexes.
    public func countPhotos(matching query: PhotoQuery,
                            folderID: Int64? = nil) throws -> Int {
        let built = buildPhotoQuery(query, folderID: folderID, countOnly: true)
        return Int((try db.scalarInt(built.sql, built.parameters)) ?? 0)
    }

    /// The `EXPLAIN QUERY PLAN` rows for a query — the CI assertion surface that keeps
    /// every UI-visible query index-backed (§15.2).
    public func queryPlan(for query: PhotoQuery, folderID: Int64? = nil) throws -> [String] {
        let built = buildPhotoQuery(query, folderID: folderID, countOnly: false)
        return try allRows("EXPLAIN QUERY PLAN " + built.sql, built.parameters) {
            $0.string(3) ?? ""
        }
    }

    private func buildPhotoQuery(_ query: PhotoQuery, folderID: Int64?,
                                 countOnly: Bool)
        -> (sql: String, parameters: [SQLiteValue]) {

        var parameters: [SQLiteValue] = []
        var joins: [String] = []

        let needsScoreJoin = (query.sortKey == .sharpness || query.sortKey == .aesthetic)
        let hasAlbum = query.albumID != nil

        // JOIN parameters bind before WHERE parameters — keep this block first.
        if let albumID = query.albumID {
            joins.append("JOIN album_photo AS ap ON ap.photo_id = photo.id "
                         + "AND ap.album_id = ?")
            parameters.append(.integer(albumID))
        }
        if needsScoreJoin {
            joins.append("LEFT JOIN cache.frame_score AS fs ON fs.photo_id = photo.id")
        }

        // Scope predicates always AND: they are the source, not a chip.
        var scope: [String] = []
        if let folderID = folderID {
            scope.append("photo.folder_id = ?")
            parameters.append(.integer(folderID))
        }
        if !query.includeMissing {
            scope.append("photo.missing = 0")
        }

        // Chip predicates: OR within a criterion, AND (or OR, with the Any toggle)
        // across criteria.
        var criteria: [String] = []

        if !query.flags.isEmpty {
            criteria.append("photo.flag IN (\(CatalogStore.placeholders(query.flags.count)))")
            for flag in query.flags { parameters.append(.integer(Int64(flag.rawValue))) }
        }
        if let rating = query.rating {
            switch query.ratingComparison {
            case .atLeast: criteria.append("photo.rating >= ?")
            case .exactly: criteria.append("photo.rating = ?")
            case .atMost:  criteria.append("photo.rating <= ?")
            }
            parameters.append(.int(rating))
        }
        if !query.labels.isEmpty || query.includeUnlabeled {
            var parts: [String] = []
            if !query.labels.isEmpty {
                parts.append("photo.label IN (\(CatalogStore.placeholders(query.labels.count)))")
                for label in query.labels { parameters.append(.text(label.rawValue)) }
            }
            if query.includeUnlabeled { parts.append("photo.label IS NULL") }
            criteria.append("(" + parts.joined(separator: " OR ") + ")")
        }
        if let edited = query.edited {
            criteria.append("photo.edited = ?")
            parameters.append(.bool(edited))
        }
        if !query.fileTypes.isEmpty {
            criteria.append("photo.ext IN (\(CatalogStore.placeholders(query.fileTypes.count)))")
            for ext in query.fileTypes { parameters.append(.text(ext.lowercased())) }
        }
        if !query.cameras.isEmpty {
            criteria.append("photo.camera IN (\(CatalogStore.placeholders(query.cameras.count)))")
            for camera in query.cameras { parameters.append(.text(camera)) }
        }
        if !query.lenses.isEmpty {
            criteria.append("photo.lens IN (\(CatalogStore.placeholders(query.lenses.count)))")
            for lens in query.lenses { parameters.append(.text(lens)) }
        }
        if !query.jobs.isEmpty {
            criteria.append("photo.job IN (\(CatalogStore.placeholders(query.jobs.count)))")
            for job in query.jobs { parameters.append(.text(job)) }
        }
        if !query.isoRanges.isEmpty {
            // One OR group, so a disjoint pair of bands stays disjoint. Parenthesised
            // because the surrounding criteria are joined with AND (or OR under
            // `matchAny`), and an unbracketed OR would silently rewrite the whole
            // predicate.
            let clause = query.isoRanges
                .map { _ in "photo.iso BETWEEN ? AND ?" }
                .joined(separator: " OR ")
            criteria.append("(\(clause))")
            for range in query.isoRanges {
                parameters.append(.int(range.lowerBound))
                parameters.append(.int(range.upperBound))
            }
        }
        if let range = query.apertureRange {
            criteria.append("photo.aperture BETWEEN ? AND ?")
            parameters.append(.real(range.lowerBound))
            parameters.append(.real(range.upperBound))
        }
        if let range = query.captureRange {
            criteria.append("photo.capture_at BETWEEN ? AND ?")
            parameters.append(.integer(range.lowerBound))
            parameters.append(.integer(range.upperBound))
        }
        if !query.keywords.isEmpty {
            criteria.append("""
            EXISTS (SELECT 1 FROM photo_keyword pk JOIN keyword k ON k.id = pk.keyword_id
                     WHERE pk.photo_id = photo.id
                       AND k.name IN (\(CatalogStore.placeholders(query.keywords.count))))
            """)
            for keyword in query.keywords { parameters.append(.text(keyword)) }
        }

        switch query.stackState {
        case .any:
            break
        case .unstacked:
            criteria.append("NOT EXISTS (SELECT 1 FROM stack_member sm "
                            + "WHERE sm.photo_id = photo.id)")
        case .collapsedTopsOnly:
            criteria.append("""
            (NOT EXISTS (SELECT 1 FROM stack_member sm WHERE sm.photo_id = photo.id)
             OR EXISTS (SELECT 1 FROM stack_member sm JOIN stack s ON s.id = sm.stack_id
                         WHERE sm.photo_id = photo.id
                           AND (s.collapsed = 0 OR s.pick_photo_id = photo.id)))
            """)
        }

        switch query.versionKind {
        case .all:
            break
        case .mastersOnly:
            criteria.append("NOT EXISTS (SELECT 1 FROM edit e "
                            + "WHERE e.photo_id = photo.id AND e.kind = 'version')")
        case .versionsOnly:
            criteria.append("EXISTS (SELECT 1 FROM edit e "
                            + "WHERE e.photo_id = photo.id AND e.kind = 'version')")
        }

        if query.junkCandidates {
            criteria.append("EXISTS (SELECT 1 FROM cache.frame_score f "
                            + "WHERE f.photo_id = photo.id AND f.junk = 1)")
        }
        if query.softFocus {
            criteria.append("EXISTS (SELECT 1 FROM cache.frame_score f "
                            + "WHERE f.photo_id = photo.id AND f.sharpness IS NOT NULL "
                            + "AND f.sharpness < ?)")
            parameters.append(.real(query.softFocusThreshold))
        }
        if query.closedEyes {
            criteria.append("EXISTS (SELECT 1 FROM cache.face fa "
                            + "WHERE fa.photo_id = photo.id AND fa.eyes_open IS NOT NULL "
                            + "AND fa.eyes_open < ?)")
            parameters.append(.real(query.closedEyesThreshold))
        }
        if query.cameraPreviewOnly {
            criteria.append("""
            (EXISTS (SELECT 1 FROM cache.preview p
                      WHERE p.photo_id = photo.id AND p.source = 'embedded')
             AND NOT EXISTS (SELECT 1 FROM cache.preview p
                              WHERE p.photo_id = photo.id AND p.source = 'lumen'))
            """)
        }

        if let text = query.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            if ftsEnabled, let match = CatalogStore.ftsMatchExpression(text) {
                criteria.append("photo.id IN (SELECT rowid FROM cache.photo_fts "
                                + "WHERE photo_fts MATCH ?)")
                parameters.append(.text(match))
            } else {
                // Fallback when FTS5 is not compiled in. Still fully parameterized:
                // any % or _ the user typed simply widens their own match.
                criteria.append("""
                (photo.filename LIKE ? OR photo.ext LIKE ? OR photo.camera LIKE ?
                 OR photo.lens LIKE ? OR photo.job LIKE ?
                 OR EXISTS (SELECT 1 FROM photo_keyword pk
                              JOIN keyword k ON k.id = pk.keyword_id
                             WHERE pk.photo_id = photo.id AND k.name LIKE ?))
                """)
                let pattern = "%" + text + "%"
                for _ in 0..<6 { parameters.append(.text(pattern)) }
            }
        }

        var clauses: [String] = scope
        if !criteria.isEmpty {
            if criteria.count == 1 {
                clauses.append(criteria[0])
            } else {
                let glue = query.matchAny ? " OR " : " AND "
                clauses.append("(" + criteria.joined(separator: glue) + ")")
            }
        }

        var sql = countOnly
            ? "SELECT COUNT(*) FROM photo"
            : "SELECT \(CatalogStore.photoColumns) FROM photo"
        for join in joins { sql += "\n" + join }
        if !clauses.isEmpty { sql += "\nWHERE " + clauses.joined(separator: " AND ") }

        if !countOnly {
            sql += "\n" + CatalogStore.orderClause(query, hasAlbum: hasAlbum)
            if let limit = query.limit {
                sql += "\nLIMIT ?"
                parameters.append(.int(limit))
                if let offset = query.offset {
                    sql += " OFFSET ?"
                    parameters.append(.int(offset))
                }
            } else if let offset = query.offset {
                // SQLite's grammar requires a LIMIT before OFFSET; -1 means "no limit".
                sql += "\nLIMIT -1 OFFSET ?"
                parameters.append(.int(offset))
            }
        }
        sql += ";"
        return (sql: sql, parameters: parameters)
    }

    /// Sort keys are enum-selected constants, never interpolated user text. NULLs sort
    /// last in both directions: unscored items land at the end, unlabeled (§6.2).
    private static func orderClause(_ query: PhotoQuery, hasAlbum: Bool) -> String {
        let direction = query.ascending ? "ASC" : "DESC"

        // Nine frames a second all carry the same whole second, so ordering a burst by
        // `capture_at` alone hands them back in whatever order the index walked — which
        // is `photo.id`, i.e. scan order, i.e. filename order, i.e. right by luck on one
        // card and wrong on the next. EXIF SubsecTimeOriginal is what separates them,
        // and `PhotoMetadata` has been reading it all along with nothing sorting by it.
        if query.sortKey == .captureTime {
            return "ORDER BY (photo.capture_at IS NULL), photo.capture_at \(direction), "
                + "COALESCE(photo.capture_subsec, 0) \(direction), photo.id \(direction)"
        }

        let expression: String
        switch query.sortKey {
        case .captureTime: expression = "photo.capture_at"
        case .addedOrder:  expression = "photo.added_at"
        case .editTime:
            expression = "(SELECT MAX(e.updated_at) FROM edit e WHERE e.photo_id = photo.id)"
        case .rating:      expression = "photo.rating"
        case .flag:        expression = "photo.flag"
        // THE SLOT, NOT THE KEY. `photo.label` stores the canonical name, so ordering on
        // it was alphabetical — blue, green, purple, red, yellow — which is neither the
        // swatch row's order nor the 6/7/8/9 keys', and is the REVERSE of what the
        // catalog-less fallback does (`AppState` sorts by `ColorLabel.rawValue`, which
        // puts unlabelled first). One menu item, two different orders depending on
        // whether the catalog is live, and neither the one the interface teaches.
        case .label:
            expression = "CASE photo.label WHEN 'red' THEN 1 WHEN 'yellow' THEN 2 "
                + "WHEN 'green' THEN 3 WHEN 'blue' THEN 4 WHEN 'purple' THEN 5 END"
        case .filename:    expression = "photo.filename"
        case .fileType:    expression = "photo.ext"
        case .aspectRatio: expression = "photo.aspect"
        case .userOrder:   expression = hasAlbum ? "ap.position" : "photo.added_at"
        case .sharpness:   expression = "fs.sharpness"
        case .aesthetic:   expression = "fs.aesthetic"
        }
        return "ORDER BY (\(expression) IS NULL), \(expression) \(direction), "
            + "photo.id \(direction)"
    }

    private static func placeholders(_ count: Int) -> String {
        if count <= 0 { return "NULL" }
        return Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Tokenized contains/prefix, expressed in FTS5's own query language. Tokens are
    /// split on non-alphanumerics and quoted, so nothing the user types can become
    /// FTS syntax; the whole expression is still bound as one parameter.
    private static func ftsMatchExpression(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        if tokens.isEmpty { return nil }
        var terms: [String] = []
        for token in tokens {
            let escaped = String(token).replacingOccurrences(of: "\"", with: "\"\"")
            terms.append("\"" + escaped + "\"*")
        }
        return terms.joined(separator: " ")
    }

    /// Keeps the FTS row for one photo in step with the catalog. rowid == photo.id, so
    /// the delete is a rowid lookup rather than a scan.
    /// THE TEXT INDEX LIVES IN THE DISPOSABLE DATABASE; THE ROWS IT INDEXES DO NOT.
    ///
    /// `cache.db` is recreated empty in three places in `init` — a cache from a newer
    /// build, a corrupt cache, and a cache that is simply absent, which is the first run
    /// and also what a photographer gets by emptying `~/Library/Caches`, exactly as
    /// `defaultCachePath`'s own comment invites. All three land on `CREATE VIRTUAL
    /// TABLE IF NOT EXISTS`, which succeeds, so `ftsEnabled` is true for an index that
    /// holds nothing. Every text query then prefers it over the LIKE fallback, and
    /// the search chip matches nothing, permanently: the only writer is the per-photo
    /// `reindexText`, and it is reached from edit paths, never from a scan of what is
    /// already there.
    ///
    /// So: if the catalog has photographs and the index has none of them, refill it.
    /// One statement, one transaction, in SQL rather than a Swift loop, because a
    /// hundred-thousand-frame catalog must not pay a round trip per row at launch. The
    /// condition also repairs a catalog that is ALREADY in the broken state — shipped
    /// builds have been creating them — which is why it is a check on emptiness rather
    /// than a flag from the recreate paths.
    ///
    /// `EXISTS … LIMIT 1` on both sides: FTS5 keeps no row count, so `COUNT(*)` on the
    /// index is a scan, and this runs on every open.
    private func rebuildTextIndexIfNeeded() throws {
        guard ftsEnabled else { return }
        let indexHasRows = try db.scalarInt(
            "SELECT EXISTS(SELECT 1 FROM cache.photo_fts LIMIT 1);") == 1
        let catalogHasRows = try db.scalarInt(
            "SELECT EXISTS(SELECT 1 FROM main.photo LIMIT 1);") == 1
        if catalogHasRows && !indexHasRows { try rebuildTextIndex() }
    }

    /// Repopulate `cache.photo_fts` from `main`, wholesale. Internal so a test can
    /// drive it directly; the app reaches it through `init`.
    ///
    /// The SELECT is `reindexText`'s row, written once for every photograph: the same
    /// five columns, the same keyword join (`keywords(photoID:)`), COALESCEd because a
    /// NULL camera must index as an empty string and not as no row.
    func rebuildTextIndex() throws {
        guard ftsEnabled else { return }
        try db.transaction {
            _ = try self.db.run("DELETE FROM cache.photo_fts;")
            _ = try self.db.run("""
            INSERT INTO cache.photo_fts (rowid, filename, ext, camera, lens, job, keywords)
            SELECT p.id, p.filename, COALESCE(p.ext, ''),
                   COALESCE(p.camera, ''), COALESCE(p.lens, ''), COALESCE(p.job, ''),
                   COALESCE((SELECT group_concat(k.name, ' ')
                               FROM photo_keyword pk JOIN keyword k ON k.id = pk.keyword_id
                              WHERE pk.photo_id = p.id), '')
              FROM main.photo p;
            """)
        }
    }

    /// NEVER THROWS. The text index is DERIVED DATA — every row in it is recomputable
    /// from `photo` and `photo_keyword` — and derived data must not be able to fail a
    /// photographer's write (J1-02).
    ///
    /// This used to throw, and its callers are `setRating`, `setLabel`, `setFlag` and
    /// the scan's upsert. So an unwritable `cache.db` turned a rating that had already
    /// been committed to `main` into "Could not save the flag or rating", once per
    /// keystroke, with no recovery short of a relaunch.
    ///
    /// A failure here turns the index OFF for the rest of the session instead. Every
    /// text query then takes the parameterized-LIKE fallback, which
    /// `isTextIndexAvailable` already exists to describe and which is correct, just
    /// slower — the degradation this store was designed for, finally reachable.
    private func reindexText(photoID: Int64) {
        guard ftsEnabled else { return }
        do {
            guard let fields = try firstRow(
                "SELECT filename, ext, camera, lens, job FROM photo WHERE id = ?;",
                [.integer(photoID)], { statement in
                    (statement.string(0) ?? "", statement.string(1) ?? "",
                     statement.string(2) ?? "", statement.string(3) ?? "",
                     statement.string(4) ?? "")
                }) else { return }
            let keywordList = try keywords(photoID: photoID).joined(separator: " ")
            try db.run("DELETE FROM cache.photo_fts WHERE rowid = ?;", [.integer(photoID)])
            try db.run("""
            INSERT INTO cache.photo_fts (rowid, filename, ext, camera, lens, job, keywords)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [.integer(photoID), .text(fields.0), .text(fields.1), .text(fields.2),
                  .text(fields.3), .text(fields.4), .text(keywordList)])
        } catch {
            // Once, and then quiet: the same unwritable cache is about to be hit by
            // every following keystroke, and a log line per photograph is how a disk
            // problem becomes a second disk problem.
            NSLog("Lumen catalog: text index unavailable (%@) — searches fall back to "
                  + "LIKE for the rest of this session", String(describing: error))
            ftsEnabled = false
        }
    }

    // MARK: - Row helpers

    private func allRows<T>(_ sql: String, _ parameters: [SQLiteValue],
                            _ decode: (SQLiteStatement) -> T) throws -> [T] {
        let statement = try db.prepare(sql)
        try statement.bindAll(parameters)
        var out: [T] = []
        while try statement.step() { out.append(decode(statement)) }
        statement.reset()
        return out
    }

    private func firstRow<T>(_ sql: String, _ parameters: [SQLiteValue],
                             _ decode: (SQLiteStatement) -> T) throws -> T? {
        let statement = try db.prepare(sql)
        try statement.bindAll(parameters)
        defer { statement.reset() }
        if try statement.step() { return decode(statement) }
        return nil
    }

    // MARK: - Decoders (column order must match the *Columns constants above)

    private static func decodeFolder(_ s: SQLiteStatement) -> FolderRow {
        FolderRow(id: s.int(0),
                  path: s.string(1) ?? "",
                  bookmark: s.data(2),
                  volumeUUID: s.string(3),
                  online: s.bool(4),
                  lastEventID: s.optionalInt(5),
                  lastScannedAt: s.optionalInt(6))
    }

    private static func decodePhoto(_ s: SQLiteStatement) -> PhotoRow {
        PhotoRow(id: s.int(0),
                 folderID: s.int(1),
                 filename: s.string(2) ?? "",
                 fileSize: s.int(3),
                 fileMTime: s.int(4),
                 quickSig: s.string(5),
                 fullHash: s.string(6),
                 captureAt: s.optionalInt(7),
                 captureSubsec: s.optionalIntValue(8),
                 camera: s.string(9),
                 cameraSerial: s.string(10),
                 lens: s.string(11),
                 iso: s.optionalIntValue(12),
                 shutterSeconds: s.optionalDouble(13),
                 aperture: s.optionalDouble(14),
                 focalMM: s.optionalDouble(15),
                 width: s.optionalIntValue(16),
                 height: s.optionalIntValue(17),
                 orientation: s.optionalIntValue(18),
                 gpsLatitude: s.optionalDouble(19),
                 gpsLongitude: s.optionalDouble(20),
                 rating: Int(s.int(21)),
                 flag: PhotoFlag(rawValue: Int(s.int(22))) ?? .unflagged,
                 label: s.string(23),
                 missing: s.bool(24),
                 sidecarMTime: s.optionalInt(25),
                 addedAt: s.int(26),
                 ext: s.string(27),
                 job: s.string(28),
                 aspect: s.optionalDouble(29),
                 edited: s.bool(30))
    }

    private static func decodeEdit(_ s: SQLiteStatement) -> EditRow {
        EditRow(id: s.int(0),
                photoID: s.int(1),
                kind: EditKind(rawValue: s.string(2) ?? "working") ?? .working,
                name: s.string(3),
                isCurrent: s.bool(4),
                pipelineVersion: Int(s.int(5)),
                recipeJSON: s.string(6) ?? "{}",
                recipeFP: s.string(7) ?? "",
                updatedAt: s.int(8))
    }

    private static func decodePreview(_ s: SQLiteStatement) -> PreviewRow {
        PreviewRow(photoID: s.int(0),
                   level: PreviewLevel(rawValue: Int(s.int(1))) ?? .thumb,
                   recipeFP: s.string(2) ?? "",
                   source: PreviewSource(rawValue: s.string(3) ?? "embedded") ?? .embedded,
                   path: s.string(4) ?? "",
                   bytes: s.int(5),
                   createdAt: s.int(6),
                   lastUsedAt: s.int(7))
    }

    private static func decodeArtifact(_ s: SQLiteStatement) -> ArtifactRow {
        ArtifactRow(id: s.int(0),
                    photoID: s.int(1),
                    kind: s.string(2) ?? "",
                    componentID: s.string(3),
                    modelID: s.string(4),
                    modelVersion: s.string(5),
                    prefixHash: s.string(6) ?? "",
                    pipelineVersion: Int(s.int(7)),
                    checksum: s.string(8) ?? "",
                    path: s.string(9) ?? "",
                    bytes: s.int(10),
                    createdAt: s.int(11),
                    lastUsedAt: s.int(12))
    }

    private static func decodeCollection(_ s: SQLiteStatement) -> CollectionRow {
        CollectionRow(id: s.int(0),
                      parentID: s.optionalInt(1),
                      name: s.string(2) ?? "",
                      kind: s.string(3) ?? "manual",
                      query: s.string(4),
                      position: Int(s.int(5)),
                      scope: s.string(6),
                      scopeID: s.optionalInt(7),
                      isTarget: s.bool(8),
                      pinned: s.bool(9))
    }

    /// An unknown `kind` decodes as `.look` rather than throwing: the column is
    /// constrained by this build's writers and by nothing else, and a look written by a
    /// later build under a register this one has not heard of is still a look worth
    /// listing. It is the same posture `decodeEdit` takes on `edit.kind`.
    private static func decodeLook(_ s: SQLiteStatement) -> LookRow {
        LookRow(id: s.int(0),
                name: s.string(1) ?? "",
                group: s.string(2),
                kind: LookKind(rawValue: s.string(3) ?? "look") ?? .look,
                subsetJSON: s.string(4) ?? "{}",
                updatedAt: s.int(5))
    }

    private static func decodeStack(_ s: SQLiteStatement) -> StackRow {
        StackRow(id: s.int(0),
                 origin: s.string(1) ?? "manual",
                 pickPhotoID: s.optionalInt(2),
                 collapsed: s.bool(3))
    }

    // MARK: - Small utilities

    /// Unix epoch seconds — the catalog's only timestamp form (docs/15 §15.3).
    public static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    /// Lowercased, no dot; nil when the name has no usable extension (gap G10).
    public static func fileExtension(of filename: String) -> String? {
        // URL rather than NSString: `String as NSString` does not bridge on Linux.
        let ext = URL(fileURLWithPath: filename).pathExtension
        if ext.isEmpty { return nil }
        return ext.lowercased()
    }

    private static func photoInsertParameters(_ row: PhotoRow) -> [SQLiteValue] {
        [.integer(row.folderID),
         .text(row.filename),
         .integer(row.fileSize),
         .integer(row.fileMTime),
         .optionalText(row.quickSig),
         .optionalText(row.fullHash),
         .optionalInteger(row.captureAt),
         .optionalInt(row.captureSubsec),
         .optionalText(row.camera),
         .optionalText(row.cameraSerial),
         .optionalText(row.lens),
         .optionalInt(row.iso),
         .optionalReal(row.shutterSeconds),
         .optionalReal(row.aperture),
         .optionalReal(row.focalMM),
         .optionalInt(row.width),
         .optionalInt(row.height),
         .optionalInt(row.orientation),
         .optionalReal(row.gpsLatitude),
         .optionalReal(row.gpsLongitude),
         .int(row.rating),
         .integer(Int64(row.flag.rawValue)),
         .optionalText(row.label),
         .bool(row.missing),
         .optionalInteger(row.sidecarMTime),
         .integer(row.addedAt),
         .optionalText(row.ext),
         .optionalText(row.job),
         .optionalReal(row.aspect),
         .bool(row.edited)]
    }
}

#else

// Linux: no sqlite3 module, so no catalog. The type stays declared — callers and the
// pure-core tests compile — and every entry point refuses honestly.

public final class CatalogStore {

    public static let latestSchemaVersion: Int = 3
    public static let migrations: [CatalogMigration] = []
    public static let cacheMigrations: [CatalogMigration] = []

    public let path: String
    public let cachePath: String

    public var isTextIndexAvailable: Bool { false }

    public convenience init(path: String) throws {
        try self.init(path: path, cachePath: nil)
    }

    public init(path: String, cachePath: String?) throws {
        self.path = path
        self.cachePath = cachePath ?? path
        throw CatalogError.unavailable
    }

    public func close() {}

    public func quickCheck() throws -> Bool { throw CatalogError.unavailable }
    public func integrityCheck() throws -> Bool { throw CatalogError.unavailable }

    /// Without SQLite there is no catalog to check and none to restore. `.firstRun` is
    /// the honest answer: nothing was found, nothing was touched, and the open that
    /// follows fails on its own terms rather than being pre-empted by a damage report
    /// this build cannot have made.
    public static func recoverIfNeeded(path: String,
                                       backupDirectory: String) -> CatalogRecovery {
        CatalogRecovery(outcome: .firstRun)
    }
    public func checkpoint(truncate: Bool = false) throws { throw CatalogError.unavailable }
    public func optimize() throws { throw CatalogError.unavailable }
    public func backup(to path: String) throws { throw CatalogError.unavailable }

    // The automatic-backup surface, kept in step with the SQLite build so a caller
    // written against one compiles against the other. `BackupRetention` itself is
    // outside the fence — it is arithmetic over filenames and needs no database.
    public static let lastBackupMetaKey = "last_backup_at"
    public static let automaticBackupInterval: Int64 = 20 * 3_600
    public func lastBackupAt() throws -> Int64? { throw CatalogError.unavailable }
    public func isBackupDue(now: Int64 = CatalogStore.now(),
                            interval: Int64 = CatalogStore.automaticBackupInterval)
        throws -> Bool {
        throw CatalogError.unavailable
    }
    public func noteBackupTaken(at when: Int64 = CatalogStore.now()) throws {
        throw CatalogError.unavailable
    }
    public static func snapshot(from path: String, to destination: String) throws {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func sweepCacheOrphans() throws -> Int { throw CatalogError.unavailable }

    public func metaValue(_ key: String) throws -> String? { throw CatalogError.unavailable }
    public func setMetaValue(_ key: String, _ value: String?) throws {
        throw CatalogError.unavailable
    }
    public func catalogUUID() throws -> String { throw CatalogError.unavailable }
    public func labelName(_ label: ColorLabel) throws -> String {
        throw CatalogError.unavailable
    }
    public func setLabelName(_ name: String, for label: ColorLabel) throws {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func registerFolder(path: String, bookmark: Data? = nil,
                               volumeUUID: String? = nil) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func folder(id: Int64) throws -> FolderRow? { throw CatalogError.unavailable }
    public func folder(path: String) throws -> FolderRow? { throw CatalogError.unavailable }
    public func folders() throws -> [FolderRow] { throw CatalogError.unavailable }
    public func setFolderOnline(_ online: Bool, folderID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func setFolderScanState(folderID: Int64, lastEventID: Int64?,
                                   lastScannedAt: Int64) throws {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func upsertPhoto(_ photo: PhotoRow) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func photo(id: Int64) throws -> PhotoRow? { throw CatalogError.unavailable }
    public func photo(folderID: Int64, filename: String) throws -> PhotoRow? {
        throw CatalogError.unavailable
    }
    public func photos(folderID: Int64, includeMissing: Bool = true) throws -> [PhotoRow] {
        throw CatalogError.unavailable
    }
    public func setMissing(_ missing: Bool, photoID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func setJob(_ job: String?, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func deletePhoto(id: Int64) throws -> [PreviewRow] {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func scan(folderID: Int64, files: [ScannedFile],
                     at now: Int64 = 0) throws -> ScanResult {
        throw CatalogError.unavailable
    }

    public func relocationProbe(folderID: Int64, listed: Set<String>) throws
        -> RelocationProbe {
        throw CatalogError.unavailable
    }

    public func saveRecipe(_ recipe: Recipe, photoID: Int64, isCurrent: Bool,
                           isRenderedFile: Bool = false) throws {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, kind: EditKind,
                           name: String?, isCurrent: Bool,
                           isRenderedFile: Bool = false,
                           at now: Int64 = 0) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func currentRecipe(photoID: Int64) throws -> Recipe? {
        throw CatalogError.unavailable
    }
    public func currentEdit(photoID: Int64) throws -> EditRow? {
        throw CatalogError.unavailable
    }
    public func edits(photoID: Int64) throws -> [EditRow] { throw CatalogError.unavailable }
    public func currentRecipeFingerprint(photoID: Int64) throws -> String {
        throw CatalogError.unavailable
    }
    public func makeCurrent(editID: Int64) throws { throw CatalogError.unavailable }

    @discardableResult
    public func saveLook(name: String, subset: LookSubset,
                         kind: LookKind = .look, group: String? = nil,
                         at now: Int64 = 0) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func looks(kind: LookKind = .look) throws -> [LookRow] {
        throw CatalogError.unavailable
    }
    public func look(id: Int64) throws -> LookRow? { throw CatalogError.unavailable }
    public func look(named name: String, kind: LookKind = .look,
                     group: String? = nil) throws -> LookRow? {
        throw CatalogError.unavailable
    }
    public func renameLook(id: Int64, to name: String, at now: Int64 = 0) throws {
        throw CatalogError.unavailable
    }
    public func deleteLook(id: Int64) throws { throw CatalogError.unavailable }

    public func setFlag(_ flag: PhotoFlag, photoID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func setMetadata(_ metadata: PhotoMetadata, photoID: Int64) throws {
        throw CatalogError.unavailable
    }

    public func setMetadata(_ batch: [(photoID: Int64, metadata: PhotoMetadata)]) throws {
        throw CatalogError.unavailable
    }

    public func photosMissingMetadata(folderID: Int64, afterID: Int64 = 0,
                                      limit: Int = 5000) throws
        -> [(id: Int64, filename: String)] {
        throw CatalogError.unavailable
    }

    public func photosMissingQuickSig(folderID: Int64, afterID: Int64 = 0,
                                      limit: Int = 5000) throws
        -> [(id: Int64, filename: String)] {
        throw CatalogError.unavailable
    }

    public func setQuickSig(_ signature: String, photoID: Int64) throws {
        throw CatalogError.unavailable
    }

    public func setQuickSigs(_ batch: [(photoID: Int64, signature: String)]) throws {
        throw CatalogError.unavailable
    }

    public func setSidecarMTime(_ mtime: Int64?, photoID: Int64) throws {
        throw CatalogError.unavailable
    }

    public func setRating(_ rating: Int, photoID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func setLabel(_ label: ColorLabel?, photoID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func setFlag(_ flag: PhotoFlag, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func setRating(_ rating: Int, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func setLabel(_ label: ColorLabel?, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func cullCounts(folderID: Int64?) throws
        -> (total: Int, picks: Int, rejects: Int, unrated: Int) {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func createCollection(name: String, kind: String = "manual",
                                 parentID: Int64? = nil, query: String? = nil,
                                 scope: String? = nil, scopeID: Int64? = nil,
                                 pinned: Bool = false, position: Int = 0) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func collections() throws -> [CollectionRow] { throw CatalogError.unavailable }
    public func collection(id: Int64) throws -> CollectionRow? {
        throw CatalogError.unavailable
    }
    public func setTargetCollection(_ albumID: Int64) throws { throw CatalogError.unavailable }
    public func targetCollectionID() throws -> Int64? { throw CatalogError.unavailable }
    public func addToCollection(_ albumID: Int64, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func removeFromCollection(_ albumID: Int64, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func setStackCollapsed(_ collapsed: Bool, stackID: Int64) throws {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func createStack(origin: String, photoIDs: [Int64],
                            pickPhotoID: Int64? = nil) throws -> Int64 {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func addKeyword(_ name: String, photoIDs: [Int64]) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func keywords(photoID: Int64) throws -> [String] { throw CatalogError.unavailable }
    public func allKeywords() throws -> [FacetValue] { throw CatalogError.unavailable }
    public func removeKeyword(_ name: String, photoIDs: [Int64]) throws {
        throw CatalogError.unavailable
    }
    public func stack(containing photoID: Int64) throws -> StackRow? {
        throw CatalogError.unavailable
    }
    public func stackMembers(stackID: Int64) throws -> [Int64] {
        throw CatalogError.unavailable
    }
    public func setStackPick(_ photoID: Int64, stackID: Int64) throws {
        throw CatalogError.unavailable
    }
    public func dissolveStack(id: Int64) throws { throw CatalogError.unavailable }
    public func facetCounts(_ facet: PhotoFacet, folderID: Int64? = nil,
                            limit: Int = 200) throws -> [FacetValue] {
        throw CatalogError.unavailable
    }
    public func facetCounts(for query: PhotoQuery, folderID: Int64? = nil,
                            limit: Int = 200) throws -> FacetCounts {
        throw CatalogError.unavailable
    }

    public func sourceState(_ key: String) throws
        -> (sortKey: String, ascending: Bool, thumbPx: Int, filterJSON: String?)? {
        throw CatalogError.unavailable
    }
    public func setSourceState(_ key: String, sortKey: String, ascending: Bool,
                               thumbPx: Int, filterJSON: String?) throws {
        throw CatalogError.unavailable
    }

    public func recordPreview(_ preview: PreviewRow, at now: Int64 = 0) throws {
        throw CatalogError.unavailable
    }
    public func preview(photoID: Int64, level: PreviewLevel,
                        recipeFP: String = "") throws -> PreviewRow? {
        throw CatalogError.unavailable
    }
    public func previews(photoID: Int64) throws -> [PreviewRow] {
        throw CatalogError.unavailable
    }
    public func touchPreview(photoID: Int64, level: PreviewLevel, recipeFP: String = "",
                             at now: Int64 = 0) throws {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func invalidatePreviews(photoID: Int64,
                                   keeping recipeFP: String) throws -> [PreviewRow] {
        throw CatalogError.unavailable
    }
    public func previewCacheBytes() throws -> Int64 { throw CatalogError.unavailable }
    @discardableResult
    public func pruneCache(maxBytes: Int64) throws -> [PreviewRow] {
        throw CatalogError.unavailable
    }

    @discardableResult
    public func recordArtifact(_ artifact: ArtifactRow, at now: Int64 = 0) throws -> Int64 {
        throw CatalogError.unavailable
    }
    public func artifact(photoID: Int64, kind: String, componentID: String? = nil,
                         modelID: String? = nil, modelVersion: String? = nil,
                         prefixHash: String,
                         pipelineVersion: Int = currentPipelineVersion) throws
        -> ArtifactRow? {
        throw CatalogError.unavailable
    }
    public func touchArtifact(id: Int64, at now: Int64 = 0) throws {
        throw CatalogError.unavailable
    }
    public func artifactBytes(kind: String? = nil) throws -> Int64 {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func pruneArtifacts(kind: String, maxBytes: Int64) throws -> [ArtifactRow] {
        throw CatalogError.unavailable
    }
    public func discardArtifact(id: Int64) throws { throw CatalogError.unavailable }

    public func photos(matching query: PhotoQuery,
                       folderID: Int64? = nil) throws -> [PhotoRow] {
        throw CatalogError.unavailable
    }
    public func countPhotos(matching query: PhotoQuery,
                            folderID: Int64? = nil) throws -> Int {
        throw CatalogError.unavailable
    }
    public func queryPlan(for query: PhotoQuery, folderID: Int64? = nil) throws -> [String] {
        throw CatalogError.unavailable
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    public static func fileExtension(of filename: String) -> String? {
        // URL rather than NSString: `String as NSString` does not bridge on Linux.
        let ext = URL(fileURLWithPath: filename).pathExtension
        if ext.isEmpty { return nil }
        return ext.lowercased()
    }
}

#endif
