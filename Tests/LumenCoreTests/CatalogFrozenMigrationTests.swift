// CatalogFrozenMigrationTests.swift
// A schema-1 catalog with edit rows, migrated by today's build.
//
// The other migration tests (KeywordHierarchyTests.writeOldCatalog) build their "old"
// catalog from TODAY's `CatalogSchema.lumenDDL`, so an edit to the base DDL lands in
// the fixture too and nothing notices. The DDL below is a frozen copy of the base
// schema as of this commit (still declared `schemaVersion = 1`; the shallow clone has
// no older text to copy). Do not regenerate it from the current source: drift between
// the two is what this test exists to catch.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class CatalogFrozenMigrationTests: XCTestCase {

    /// Frozen schema-1 DDL. Never edit to match Schema.swift.
    private static let frozenV1DDL = """
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

    // Recipe text as a v1 build could have written it: sparse JSON, which the decoder
    // fills with defaults. Hand-written, not produced by today's encoder.
    private static let recipeA = #"{"pipelineVersion":1,"develop":{"tone":{"exposure":0.5}}}"#
    private static let recipeB = #"{"pipelineVersion":1,"develop":{"tone":{"exposure":1.25}},"#
        + #""look":{"lut":{"ref":"blob:xxh64:00000000000000aa","name":"Kodachrome","tap":"log","amount":70}},"#
        + #""masks":[{"id":"m-sky","name":"Sky","amount":80,"group":"g-1","#
        + #""components":[{"op":"add","kind":"linear","amount":100}]}],"#
        + #""maskGroups":[{"id":"g-1","name":"Retouch","collapsed":true}]}"#
    private static let recipeSnap = #"{"pipelineVersion":1,"develop":{"tone":{"exposure":-0.3}}}"#
    private static let recipeC = #"{"pipelineVersion":1,"develop":{"color":{"saturation":18}}}"#

    private var directory: URL!
    private var path: String { directory.appendingPathComponent("lumen.db").path }
    private var cachePath: String { directory.appendingPathComponent("cache.db").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-frozen-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func writeV1Catalog() throws {
        let raw = try SQLiteDatabase(path: path)
        defer { raw.close() }
        try raw.execute(Self.frozenV1DDL)
        try raw.execute("""
        PRAGMA user_version = 1;
        INSERT INTO folder (id, path) VALUES (1, '/Volumes/Old');
        INSERT INTO photo (id, folder_id, filename, file_size, file_mtime, rating, flag, label)
          VALUES (1, 1, 'a.NEF', 1, 1700000000, 4, 1, 'green'),
                 (2, 1, 'b.NEF', 2, 1700000000, 0, 0, NULL);
        -- Schema 1 had no unique index, so photo 1 can carry two current rows (G5).
        INSERT INTO edit (id, photo_id, kind, name, is_current, pipeline_version,
                          recipe, recipe_fp, updated_at) VALUES
          (5,  1, 'working',  NULL,     1, 1, '\(Self.recipeA)',    'fpA', 10),
          (7,  1, 'snapshot', 'Before', 0, 1, '\(Self.recipeSnap)', 'fpS', 11),
          (9,  1, 'working',  NULL,     1, 1, '\(Self.recipeB)',    'fpB', 12),
          (11, 2, 'working',  NULL,     1, 1, '\(Self.recipeC)',    'fpC', 13);
        """)
        XCTAssertEqual(try raw.userVersion(), 1)
    }

    func testASchemaOneCatalogWithEditsMigratesToLatest() throws {
        try writeV1Catalog()

        var b = Recipe()
        b.pipelineVersion = 1
        b.develop.tone.exposure = 1.25
        b.look.lut = LUTReference(ref: "blob:xxh64:00000000000000aa", name: "Kodachrome",
                                  tap: .log, amount: 70)
        b.masks = [Mask(id: "m-sky", name: "Sky", amount: 80,
                        components: [MaskComponent(op: .add, kind: .linear)],
                        group: "g-1")]
        b.maskGroups = [MaskGroup(id: "g-1", name: "Retouch", collapsed: true)]
        var c = Recipe()
        c.pipelineVersion = 1
        c.develop.color.saturation = 18

        let store = try CatalogStore(path: path, cachePath: cachePath)
        // G5: of two current rows, the newest stays current.
        XCTAssertEqual(try store.currentRecipe(photoID: 1), b,
                       "migration kept the wrong current edit, or lost its masks/LUT")
        XCTAssertEqual(try store.currentRecipeFingerprint(photoID: 1), "fpB")
        XCTAssertEqual(try store.currentRecipe(photoID: 2), c)

        let edits = try store.edits(photoID: 1)
        XCTAssertEqual(edits.map(\.id), [5, 7, 9], "an edit row was lost")
        XCTAssertEqual(edits.map(\.kind), [.working, .snapshot, .working])
        XCTAssertEqual(edits.map(\.isCurrent), [false, false, true])
        let snap = try store.namedSnapshot(id: 7, photoID: 1)
        XCTAssertEqual(snap.name, "Before")
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(snap.recipeJSON.utf8))
                           .develop.tone.exposure, -0.3)

        let row = try XCTUnwrap(try store.photo(id: 1))
        XCTAssertEqual(row.rating, 4)
        XCTAssertEqual(row.flag, .pick)
        XCTAssertEqual(row.label, "green")
        store.close()

        let raw = try SQLiteDatabase(path: path)
        defer { raw.close() }
        XCTAssertEqual(try raw.userVersion(), CatalogStore.latestSchemaVersion)
        XCTAssertEqual(try raw.scalarInt("""
            SELECT COUNT(*) FROM (SELECT photo_id FROM edit WHERE is_current = 1
                                  GROUP BY photo_id HAVING COUNT(*) > 1);
            """), 0)
        XCTAssertEqual(try raw.scalarInt(
            "SELECT \"unique\" FROM pragma_index_list('edit') WHERE name = 'edit_current';"),
            1, "the edit_current unique index is missing")
    }
}

#endif
