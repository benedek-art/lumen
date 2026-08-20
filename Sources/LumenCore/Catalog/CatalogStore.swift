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

// MARK: - Scan reconciliation

/// One file as the directory listing found it (docs/15 §15.9: the diff key is
/// (filename, file_size, file_mtime); `quickSig` is the move/dupe detector).
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
    public var isoRange: ClosedRange<Int>? = nil
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
    private let ftsEnabled: Bool

    public let path: String
    public let cachePath: String

    /// True when SQLite was built with FTS5 and the text index exists (gap G16).
    /// When false the text chip degrades to parameterized LIKE — correct, just slower.
    public var isTextIndexAvailable: Bool { ftsEnabled }

    // MARK: Migration list

    /// Schema version this build understands. Base DDL (`CatalogSchema.lumenDDL`) is
    /// version 1; everything after it is a migration below.
    public static let latestSchemaVersion: Int = 2

    /// Gap-closing migration for `lumen.db` (brief 02 §2.3, G5–G15, G17–G26, G31).
    public static let migrations: [CatalogMigration] = [
        CatalogMigration(version: 2, sql: CatalogStore.lumenMigration2)
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
        } catch {
            // Missing or corrupt cache -> recreate empty; the workers refill it
            // (docs/15 §15.2). Losing it costs warm-up time and nothing else.
            try? FileManager.default.removeItem(atPath: resolvedCachePath)
            try? FileManager.default.removeItem(atPath: resolvedCachePath + "-wal")
            try? FileManager.default.removeItem(atPath: resolvedCachePath + "-shm")
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

    /// `PRAGMA quick_check` — run on every open per §15.8 (the caller decides whether a
    /// failure triggers an auto-restore from the newest passing backup).
    public func quickCheck() throws -> Bool {
        (try db.scalarText("PRAGMA quick_check;")) == "ok"
    }

    /// Full `PRAGMA integrity_check` — the pre-weekly-backup gate.
    public func integrityCheck() throws -> Bool {
        (try db.scalarText("PRAGMA integrity_check;")) == "ok"
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

    /// `VACUUM INTO` — a compacted, checkpointed, single-file snapshot (§15.8).
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
            try self.reindexText(photoID: id)
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
            for id in photoIDs { try self.reindexText(photoID: id) }
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
                    try self.reindexText(photoID: id)
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
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, isCurrent: Bool) throws {
        try saveRecipe(recipe, photoID: photoID, kind: .working,
                       name: nil, isCurrent: isCurrent)
    }

    @discardableResult
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, kind: EditKind,
                           name: String?, isCurrent: Bool,
                           at now: Int64 = CatalogStore.now()) throws -> Int64 {
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let fingerprint = try RecipeFingerprint.fingerprint(recipe)
        // "Edited" means the recipe differs from the default at its own pipeline
        // version — comparing against a *different* version's default would light the
        // pencil badge on every photo after a pipeline bump.
        let isEdited = recipe != Recipe(pipelineVersion: recipe.pipelineVersion)

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

            if let id = editID {
                try self.db.run("""
                UPDATE edit SET name = ?, is_current = ?, pipeline_version = ?,
                  recipe = ?, recipe_fp = ?, updated_at = ? WHERE id = ?;
                """, [.optionalText(name), .bool(isCurrent),
                      .int(recipe.pipelineVersion), .text(json), .text(fingerprint),
                      .integer(now), .integer(id)])
                try self.db.run("UPDATE photo SET edited = ? WHERE id = ?;",
                                [.bool(isEdited), .integer(photoID)])
                return id
            }

            try self.db.run("""
            INSERT INTO edit (photo_id, kind, name, is_current, pipeline_version,
                              recipe, recipe_fp, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [.integer(photoID), .text(kind.rawValue), .optionalText(name),
                  .bool(isCurrent), .int(recipe.pipelineVersion), .text(json),
                  .text(fingerprint), .integer(now)])
            let inserted = self.db.lastInsertRowID
            try self.db.run("UPDATE photo SET edited = ? WHERE id = ?;",
                            [.bool(isEdited), .integer(photoID)])
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

    // MARK: - Culling state

    /// The decision write path: one transaction per action, never on the input path.
    public func setFlag(_ flag: PhotoFlag, photoID: Int64) throws {
        try setFlag(flag, photoIDs: [photoID])
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

    @discardableResult
    public func createStack(origin: String, photoIDs: [Int64],
                            pickPhotoID: Int64? = nil) throws -> Int64 {
        try db.transaction {
            try self.db.run(
                "INSERT INTO stack (origin, pick_photo_id, collapsed) VALUES (?, ?, 1);",
                [.text(origin), .optionalInteger(pickPhotoID ?? photoIDs.first)])
            let stackID = self.db.lastInsertRowID
            let statement = try self.db.prepare(
                "INSERT OR REPLACE INTO stack_member (stack_id, photo_id, position) "
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
            for photoID in photoIDs { try self.reindexText(photoID: photoID) }
            return id
        }
    }

    public func keywords(photoID: Int64) throws -> [String] {
        try allRows("SELECT k.name FROM photo_keyword pk "
                    + "JOIN keyword k ON k.id = pk.keyword_id "
                    + "WHERE pk.photo_id = ? ORDER BY k.name;",
                    [.integer(photoID)], { $0.string(0) ?? "" })
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
        if let range = query.isoRange {
            criteria.append("photo.iso BETWEEN ? AND ?")
            parameters.append(.int(range.lowerBound))
            parameters.append(.int(range.upperBound))
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
        let expression: String
        switch query.sortKey {
        case .captureTime: expression = "photo.capture_at"
        case .addedOrder:  expression = "photo.added_at"
        case .editTime:
            expression = "(SELECT MAX(e.updated_at) FROM edit e WHERE e.photo_id = photo.id)"
        case .rating:      expression = "photo.rating"
        case .flag:        expression = "photo.flag"
        case .label:       expression = "photo.label"
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
    private func reindexText(photoID: Int64) throws {
        if !ftsEnabled { return }
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

    public static let latestSchemaVersion: Int = 2
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
    public func checkpoint(truncate: Bool = false) throws { throw CatalogError.unavailable }
    public func optimize() throws { throw CatalogError.unavailable }
    public func backup(to path: String) throws { throw CatalogError.unavailable }

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

    public func saveRecipe(_ recipe: Recipe, photoID: Int64, isCurrent: Bool) throws {
        throw CatalogError.unavailable
    }
    @discardableResult
    public func saveRecipe(_ recipe: Recipe, photoID: Int64, kind: EditKind,
                           name: String?, isCurrent: Bool, at now: Int64 = 0) throws -> Int64 {
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

    public func setFlag(_ flag: PhotoFlag, photoID: Int64) throws {
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
