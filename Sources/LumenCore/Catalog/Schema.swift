// Schema.swift
// Catalog DDL, transcribed from docs/15-catalog.md §15.3 (the spec is the authority;
// this file is its executable form). Two databases:
//   lumen.db — authoritative: files, edits, history, blobs, organization, ingest, output.
//   cache.db — disposable, ATTACHed at open, recreated empty if missing/corrupt:
//              previews, AI artifacts, culling evidence, raw stats.
//
// GRDB wiring happens on macOS in Phase 2; the DDL lives in LumenCore so it can be
// validated headlessly (Tests + scripts/gen-fixtures.py execute it in real SQLite).
// Pragmas per §15.2: WAL, synchronous=NORMAL, foreign_keys=ON, busy_timeout=5000,
// page_size=8192, temp_store=MEMORY. One writer, ever.

import Foundation

public enum CatalogSchema {

    public static let schemaVersion = 1

    /// lumen.db — the authoritative database.
    public static let lumenDDL = """
    CREATE TABLE folder (
      id              INTEGER PRIMARY KEY,
      path            TEXT NOT NULL UNIQUE,
      bookmark        BLOB,
      volume_uuid     TEXT,
      online          INTEGER NOT NULL DEFAULT 1,
      last_event_id   INTEGER,
      last_scanned_at INTEGER
    );

    CREATE TABLE photo (
      id            INTEGER PRIMARY KEY,
      folder_id     INTEGER NOT NULL REFERENCES folder(id),
      filename      TEXT NOT NULL,
      file_size     INTEGER NOT NULL,
      file_mtime    INTEGER NOT NULL,
      quick_sig     TEXT,
      full_hash     TEXT,
      capture_at    INTEGER, capture_subsec INTEGER,
      camera TEXT, camera_serial TEXT, lens TEXT,
      iso INTEGER, shutter_s REAL, aperture REAL, focal_mm REAL,
      width INTEGER, height INTEGER, orientation INTEGER,
      gps_lat REAL, gps_lon REAL,
      rating  INTEGER NOT NULL DEFAULT 0,
      flag    INTEGER NOT NULL DEFAULT 0,
      label   TEXT,
      missing INTEGER NOT NULL DEFAULT 0,
      sidecar_mtime INTEGER,
      UNIQUE(folder_id, filename)
    );
    CREATE INDEX photo_capture ON photo(capture_at);
    CREATE INDEX photo_cull    ON photo(flag, rating, label);
    CREATE INDEX photo_sig     ON photo(quick_sig);

    CREATE TABLE edit (
      id               INTEGER PRIMARY KEY,
      photo_id         INTEGER NOT NULL REFERENCES photo(id),
      kind             TEXT NOT NULL DEFAULT 'working',
      name             TEXT,
      is_current       INTEGER NOT NULL DEFAULT 0,
      pipeline_version INTEGER NOT NULL,
      recipe           TEXT NOT NULL,
      recipe_fp        TEXT NOT NULL,
      updated_at       INTEGER NOT NULL
    );
    CREATE INDEX edit_photo ON edit(photo_id, is_current);

    CREATE TABLE history (
      photo_id INTEGER NOT NULL REFERENCES photo(id),
      seq      INTEGER NOT NULL,
      at       INTEGER NOT NULL,
      label    TEXT NOT NULL,
      delta    BLOB NOT NULL,
      PRIMARY KEY (photo_id, seq)
    );

    CREATE TABLE blob (
      hash       TEXT PRIMARY KEY,
      bytes      INTEGER NOT NULL,
      data       BLOB NOT NULL,
      created_at INTEGER NOT NULL
    );

    CREATE TABLE album (
      id        INTEGER PRIMARY KEY,
      parent_id INTEGER REFERENCES album(id),
      name      TEXT NOT NULL,
      kind      TEXT NOT NULL DEFAULT 'manual',
      query     TEXT,
      position  INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE album_photo (
      album_id INTEGER NOT NULL REFERENCES album(id),
      photo_id INTEGER NOT NULL REFERENCES photo(id),
      position INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (album_id, photo_id)
    );

    CREATE TABLE stack (
      id            INTEGER PRIMARY KEY,
      origin        TEXT NOT NULL,
      pick_photo_id INTEGER REFERENCES photo(id)
    );
    CREATE TABLE stack_member (
      stack_id INTEGER NOT NULL REFERENCES stack(id),
      photo_id INTEGER NOT NULL UNIQUE REFERENCES photo(id),
      position INTEGER NOT NULL,
      PRIMARY KEY (stack_id, photo_id)
    );

    CREATE TABLE keyword (
      id        INTEGER PRIMARY KEY,
      parent_id INTEGER REFERENCES keyword(id),
      name      TEXT NOT NULL
    );
    CREATE TABLE photo_keyword (
      photo_id   INTEGER NOT NULL REFERENCES photo(id),
      keyword_id INTEGER NOT NULL REFERENCES keyword(id),
      PRIMARY KEY (photo_id, keyword_id)
    );

    CREATE TABLE ingest_card (
      id            INTEGER PRIMARY KEY,
      volume_uuid   TEXT NOT NULL,
      camera_serial TEXT,
      label         TEXT,
      last_seen_at  INTEGER,
      UNIQUE(volume_uuid, camera_serial)
    );
    CREATE TABLE ingest_file (
      card_id          INTEGER NOT NULL REFERENCES ingest_card(id),
      filename         TEXT NOT NULL,
      file_size        INTEGER NOT NULL,
      xxh64            TEXT NOT NULL,
      ingested_at      INTEGER NOT NULL,
      verified_primary INTEGER NOT NULL DEFAULT 0,
      verified_backup  INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (card_id, filename, file_size)
    );

    CREATE TABLE export_recipe (
      id       INTEGER PRIMARY KEY,
      name     TEXT NOT NULL,
      checked  INTEGER NOT NULL DEFAULT 0,
      position INTEGER NOT NULL DEFAULT 0,
      settings TEXT NOT NULL
    );
    CREATE TABLE export_log (
      id          INTEGER PRIMARY KEY,
      photo_id    INTEGER NOT NULL REFERENCES photo(id),
      recipe_id   INTEGER REFERENCES export_recipe(id),
      recipe_fp   TEXT NOT NULL,
      destination TEXT NOT NULL,
      exported_at INTEGER NOT NULL
    );

    CREATE TABLE look (
      id         INTEGER PRIMARY KEY,
      name       TEXT NOT NULL,
      grp        TEXT,
      kind       TEXT NOT NULL,
      subset     TEXT NOT NULL,
      thumb      BLOB,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE meta ( key TEXT PRIMARY KEY, value TEXT );
    """

    /// cache.db — disposable; recreated empty when missing or corrupt (self-healing, D52).
    public static let cacheDDL = """
    CREATE TABLE raw_stats (
      photo_id INTEGER PRIMARY KEY,
      bins BLOB NOT NULL, clipped_pct TEXT NOT NULL,
      analyzer_rev INTEGER NOT NULL, computed_at INTEGER NOT NULL
    );
    CREATE TABLE frame_score (
      photo_id INTEGER PRIMARY KEY,
      sharpness REAL, junk INTEGER NOT NULL DEFAULT 0,
      aesthetic REAL, is_utility INTEGER,
      analyzer_rev INTEGER NOT NULL, computed_at INTEGER NOT NULL
    );
    CREATE TABLE face (
      id INTEGER PRIMARY KEY,
      photo_id INTEGER NOT NULL,
      rect_x REAL, rect_y REAL, rect_w REAL, rect_h REAL,
      eyes_open REAL,
      capture_quality REAL,
      focus REAL,
      crop_artifact_id INTEGER,
      analyzer_rev INTEGER NOT NULL
    );
    CREATE INDEX face_photo ON face(photo_id);
    CREATE TABLE feature_print (
      photo_id INTEGER PRIMARY KEY,
      data BLOB NOT NULL, revision INTEGER NOT NULL
    );

    CREATE TABLE preview (
      photo_id  INTEGER NOT NULL,
      level     INTEGER NOT NULL,
      recipe_fp TEXT NOT NULL,
      source    TEXT NOT NULL,
      path TEXT NOT NULL, bytes INTEGER NOT NULL,
      created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL,
      PRIMARY KEY (photo_id, level)
    );

    CREATE TABLE artifact (
      id INTEGER PRIMARY KEY,
      photo_id INTEGER NOT NULL,
      kind TEXT NOT NULL,
      component_id TEXT,
      model_id TEXT, model_version TEXT,
      prefix_hash TEXT NOT NULL,
      pipeline_version INTEGER NOT NULL,
      checksum TEXT NOT NULL,
      path TEXT NOT NULL, bytes INTEGER NOT NULL,
      created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL
    );
    CREATE INDEX artifact_key ON artifact(photo_id, kind, component_id);
    """

    /// Connection pragmas (docs/15 §15.2), applied on every open.
    /// page_size must run first: it only takes effect on a fresh database before
    /// the first write / before WAL mode is entered.
    public static let pragmas = """
    PRAGMA page_size=8192;
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    PRAGMA busy_timeout=5000;
    PRAGMA temp_store=MEMORY;
    """
}
