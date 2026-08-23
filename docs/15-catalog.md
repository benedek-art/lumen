# 15 — Catalog, Storage & Edit Persistence

This document owns the storage layer: the authority model, the SQLite schema, the edit-recipe
format, XMP sidecar policy, the preview and AI-artifact caches, versioning/migration, filesystem
watching, and crash safety. Consumers of this layer own their semantics elsewhere: mask lifecycle
(docs/08-spec-masking.md §8.7–8.9), denoise artifacts (docs/07-spec-denoise.md), culling evidence
and ingest UX (docs/10-spec-library.md), export recipes (docs/11-spec-output.md), history UX
(docs/12-spec-ux.md §12.10), concurrency and queues (docs/13-architecture.md), pipeline stage
order and prefix hashing (docs/14-pipeline.md).

The design brief in one line: **the catalog is a convenience, never a hostage.** Everything below
follows from that.

---

## 15.1 The three-layer authority model

Three layers, strictly ordered by authority:

```
Layer 1  ORIGINALS   RAW/JPEG files on disk. Read-only, forever. The folder
 (truth)             tree IS the library structure. Lumen opens them with
                     read-only intents; no code path writes into a source file.

Layer 2  SIDECARS    IMG_1234.xmp next to each original. Standard fields
 (portable truth     (rating/label/keywords) + the full Lumen recipe in our
  of *edits*)        namespace. Plain text, greppable, diffable, copyable.
                     A folder of originals + sidecars is a complete project.

Layer 3  CATALOG     One SQLite database. Index, evidence, caches, albums,
 (index +            history, queues. Fast to query, expensive to lose —
  convenience)       but losable: rebuildable from Layers 1–2 plus recompute.
```

On conflict, lower layers win: the catalog defers to a newer sidecar; nothing ever overrides the
original file. Derived artifacts (previews, mask rasters, denoise atlases, embeddings) sit below
all three — versioned, checksummed, and regenerable from `(original, recipe)` at any time.

Two named failures motivate this ordering; both are recent history, not hypotheticals.

**The Aperture betrayal.** Aperture stored library structure *and* adjustments inside an opaque
`.aplibrary` bundle. When Apple killed the app (discontinued 2014, unrunnable after the 64-bit
transition), every non-destructive edit died with it — migration paths could export flattened
JPEGs, nothing else. A decade of parametric editing became bake-or-lose. The same pattern is
re-arming right now: the Pixelmator/Photomator apps entered caretaker mode after Apple's
acquisition (D2). The lesson is structural, not sentimental: **whatever lives only inside a
proprietary database dies with the app.** Lumen is a solo-developer product; it must assume its
own mortality. Hence Layer 2 — every edit, every mask (as parametric prompts, docs/08 §8.9), every
rating exists as text beside the file it describes, readable without Lumen running.

**The `.lrcat-data` lesson.** Lightroom Classic's develop settings are XMP (`crs:*`), but the
AI era outgrew text: AI mask rasters and non-destructive Denoise results (14.4+) landed in an
opaque binary sidecar database, `<catalog>.lrcat-data`. It corrupts. The documented symptom is
masks rendering black or blank; the documented fix — in Adobe Community threads and Lightroom
Queen alike — is *quit, delete the file by hand, let LR regenerate*. Community folklore standing
in for product engineering. The lesson: **nothing may be both opaque and load-bearing.** In Lumen,
heavy binary data is either regenerable cache (self-healing, §15.7) or content-addressed blobs
whose parametric source also lives in the recipe and sidecar. There is no file whose corruption
costs the user anything but warm-up time, and no cache filename a user ever needs to learn (D52).

What lives where — the honest table:

| Data | Original | Sidecar | Catalog | Cache | On catalog loss |
|---|---|---|---|---|---|
| Pixels, capture EXIF | ● | | indexed | | nothing lost (rescan) |
| Ratings / flags / labels / keywords | | ● | ● | | recovered from sidecars |
| Edit recipes, mask definitions, versions | | ● | ● | | recovered from sidecars |
| Named snapshots | | ● | ● | | recovered from sidecars |
| Albums, smart-album queries, stacks picks | | | ● | | restored from catalog backup (§15.8) |
| Edit-history ring, export log, ingest ledger | | | ● | | restored from backup; history gap acceptable |
| Culling evidence, raw stats, embeddings | | | | ● | recomputed in background |
| Previews, mask rasters, AI artifacts | | | | ● | regenerated on demand |

---

## 15.2 Physical layout and SQLite discipline

One logical catalog, two physical databases, one cache directory:

```
~/Pictures/Lumen/
  lumen.db            authoritative store (Layer 3 truth-adjacent data) — backed up
  lumen.db-wal/-shm   WAL companions
  Backups/            VACUUM INTO rotation (§15.8)
~/Library/Caches/Lumen/
  cache.db            derived store: evidence + cache bookkeeping — never backed up,
                      deletable at any time (rebuilds silently)
  previews/xx/…       preview payloads, sharded by hash prefix (HEIC)
  artifacts/xx/…      AI artifact payloads (mask rasters, denoise atlases, embeddings)
```

Splitting authoritative from derived is what keeps backups small and honest: raw-clipping stats
alone run ~4 KB/photo (docs/10 §raw truth) — 800 MB at 200k photos — and belong nowhere near a
backup rotation. `cache.db` is `ATTACH`ed at open; if missing or corrupt it is recreated empty and
the analysis workers refill it (§15.7).

Engine discipline (GRDB.swift over SQLite, D-carryover from v1):

- `journal_mode=WAL`, `synchronous=NORMAL` — durable across app crashes; an OS-level crash can
  lose the last few transactions, which sidecars and re-scan recover (§15.10).
- `foreign_keys=ON`, `busy_timeout=5000`, `page_size=8192` (recipe rows are multi-KB; 8 KB pages
  halve overflow chaining vs the 4 KB default), `temp_store=MEMORY`.
- **One writer.** GRDB `DatabasePool`: all writes serialize through a single queue
  (docs/13-architecture.md owns the actor layout); the UI reads through pool readers and observes
  via GRDB's observation API into SwiftUI. No render or ML thread ever holds a write transaction.
- Every UI-visible query is index-backed and proven so in CI (`EXPLAIN QUERY PLAN` assertions on
  the grid-filter, sort, and smart-album queries — grid scroll is a release-gated loop, D47).

---

## 15.3 Schema v2

v1's four-table sketch survives as the core; v2 adds what the feature set now implies. Grouped,
with the reasoning attached. `INTEGER` timestamps are Unix epoch seconds; hashes are lowercase hex
text (xxh3-128 unless noted).

### Files and folders

```sql
CREATE TABLE folder (
  id              INTEGER PRIMARY KEY,
  path            TEXT NOT NULL UNIQUE,     -- absolute
  bookmark        BLOB,                     -- security-scoped bookmark (sandbox)
  volume_uuid     TEXT,
  online          INTEGER NOT NULL DEFAULT 1,
  last_event_id   INTEGER,                  -- FSEvents resume point (§15.9)
  last_scanned_at INTEGER
);

CREATE TABLE photo (
  id            INTEGER PRIMARY KEY,
  folder_id     INTEGER NOT NULL REFERENCES folder(id),
  filename      TEXT NOT NULL,
  file_size     INTEGER NOT NULL,
  file_mtime    INTEGER NOT NULL,
  quick_sig     TEXT,                       -- xxh3(first 1 MB) + size: move/dupe detection
  full_hash     TEXT,                       -- xxh64 whole-file, set by verified ingest (D38)
  capture_at    INTEGER, capture_subsec INTEGER,
  camera TEXT, camera_serial TEXT, lens TEXT,
  iso INTEGER, shutter_s REAL, aperture REAL, focal_mm REAL,
  width INTEGER, height INTEGER, orientation INTEGER,
  gps_lat REAL, gps_lon REAL,               -- owner shoots travel; schema room per D38
  rating  INTEGER NOT NULL DEFAULT 0,       -- 0..5
  flag    INTEGER NOT NULL DEFAULT 0,       -- -1 reject / 0 none / 1 pick
  label   TEXT,
  missing INTEGER NOT NULL DEFAULT 0,       -- file gone; row and edits kept (§15.9)
  sidecar_mtime INTEGER,                    -- sidecar state at our last write/read (§15.5)
  UNIQUE(folder_id, filename)
);
CREATE INDEX photo_capture ON photo(capture_at);
CREATE INDEX photo_cull    ON photo(flag, rating, label);
CREATE INDEX photo_sig     ON photo(quick_sig);
```

### Edits, history, blobs

```sql
CREATE TABLE edit (
  id               INTEGER PRIMARY KEY,
  photo_id         INTEGER NOT NULL REFERENCES photo(id),
  kind             TEXT NOT NULL DEFAULT 'working',  -- working | version | snapshot
  name             TEXT,                             -- "B&W crop", "Client v2"
  is_current       INTEGER NOT NULL DEFAULT 0,       -- exactly one per photo
  pipeline_version INTEGER NOT NULL,                 -- render gating (§15.8, D52)
  recipe           TEXT NOT NULL,                    -- canonical JSON (§15.4)
  recipe_fp        TEXT NOT NULL,                    -- xxh3 of canonical form; keys every cache
  updated_at       INTEGER NOT NULL
);
CREATE INDEX edit_photo ON edit(photo_id, is_current);

-- The edit-history ring (UX in docs/12 §12.10). Ring-capped at 200 entries per
-- photo; every 20th entry stores full state, others store zstd JSON diffs, so
-- time-travel replays at most 19 diffs. Snapshots are edit rows and exempt.
CREATE TABLE history (
  photo_id INTEGER NOT NULL REFERENCES photo(id),
  seq      INTEGER NOT NULL,
  at       INTEGER NOT NULL,
  label    TEXT NOT NULL,                  -- "Exposure", "Apply Look 'Portra'"
  delta    BLOB NOT NULL,
  PRIMARY KEY (photo_id, seq)
);

-- Durable content-addressed blobs: brush/heal stroke vectors, sampled-point
-- sets — parametric truth too bulky for inline JSON (typically 1–30 KB zstd).
-- Referenced from recipes as "blob:xxh3:<hash>"; mirrored into sidecars;
-- garbage-collected by mark-and-sweep during maintenance (§15.8).
CREATE TABLE blob (
  hash       TEXT PRIMARY KEY,
  bytes      INTEGER NOT NULL,
  data       BLOB NOT NULL,
  created_at INTEGER NOT NULL
);
```

### Organization (albums, stacks, keywords)

```sql
CREATE TABLE album (
  id       INTEGER PRIMARY KEY,
  parent_id INTEGER REFERENCES album(id),
  name     TEXT NOT NULL,
  kind     TEXT NOT NULL DEFAULT 'manual',   -- manual | smart
  query    TEXT,                             -- smart: stored predicate JSON → SQL (D39)
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE album_photo (
  album_id INTEGER NOT NULL REFERENCES album(id),
  photo_id INTEGER NOT NULL REFERENCES photo(id),
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (album_id, photo_id)
);

-- Stacks: one table serves auto burst groups, manual stacks, and compare
-- seeds — one grouping concept (docs/10 §Stacks). origin records provenance
-- so re-running burst analysis never clobbers a manual stack.
CREATE TABLE stack (
  id            INTEGER PRIMARY KEY,
  origin        TEXT NOT NULL,               -- burst-auto | manual
  pick_photo_id INTEGER REFERENCES photo(id) -- stack thumbnail = pick
);
CREATE TABLE stack_member (
  stack_id INTEGER NOT NULL REFERENCES stack(id),
  photo_id INTEGER NOT NULL UNIQUE REFERENCES photo(id),
  position INTEGER NOT NULL,
  PRIMARY KEY (stack_id, photo_id)
);

CREATE TABLE keyword (
  id INTEGER PRIMARY KEY,
  parent_id INTEGER REFERENCES keyword(id),
  name TEXT NOT NULL
);
CREATE TABLE photo_keyword (
  photo_id   INTEGER NOT NULL REFERENCES photo(id),
  keyword_id INTEGER NOT NULL REFERENCES keyword(id),
  PRIMARY KEY (photo_id, keyword_id)
);
```

### Ingest ledger and output (in `lumen.db` — these are not recomputable)

```sql
-- Card identity for incremental re-ingest (D38): a half-shot card re-inserted
-- mid-event copies only new frames. Identity = volume UUID + camera serial.
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
  xxh64            TEXT NOT NULL,            -- streamed during copy (docs/10 §ingest)
  ingested_at      INTEGER NOT NULL,
  verified_primary INTEGER NOT NULL DEFAULT 0,  -- destination re-read matched
  verified_backup  INTEGER NOT NULL DEFAULT 0,  -- backup destination, independently
  PRIMARY KEY (card_id, filename, file_size)
);

-- Export recipes (UI and semantics: docs/11-spec-output.md). Rows, not files.
CREATE TABLE export_recipe (
  id       INTEGER PRIMARY KEY,
  name     TEXT NOT NULL,
  checked  INTEGER NOT NULL DEFAULT 0,       -- checked set persists per catalog (D40)
  position INTEGER NOT NULL DEFAULT 0,
  settings TEXT NOT NULL                     -- format/size/space/sharpen/naming/dest JSON
);
-- Export log: powers the "modified since export" badge — the useful core of
-- LR's Publish Services state machine without the plugin platform (r04 §19).
CREATE TABLE export_log (
  id          INTEGER PRIMARY KEY,
  photo_id    INTEGER NOT NULL REFERENCES photo(id),
  recipe_id   INTEGER REFERENCES export_recipe(id),
  recipe_fp   TEXT NOT NULL,                 -- edit state that was exported
  destination TEXT NOT NULL,
  exported_at INTEGER NOT NULL
);

-- Looks and develop presets (Develop/Look doctrine D4; adaptive presets embed
-- mask *prompts* and recompute per photo, docs/08 §8.10).
CREATE TABLE look (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  grp        TEXT,                           -- user folder/grouping
  kind       TEXT NOT NULL,                  -- look | develop-preset | import-default
  subset     TEXT NOT NULL,                  -- recipe subset JSON with stage tags
  thumb      BLOB,                           -- preview swatch
  updated_at INTEGER NOT NULL
);

CREATE TABLE meta ( key TEXT PRIMARY KEY, value TEXT );
-- catalog_uuid, created_at, last_app_version, current pipeline_version default
```

### Derived stores (in `cache.db` — recomputable, never backed up)

```sql
-- Culling evidence (workers and thresholds: docs/10 §AI assists, D37).
CREATE TABLE raw_stats (        -- true raw histogram: 128 EV-spaced bins × 4 ch, ~4 KB
  photo_id INTEGER PRIMARY KEY,
  bins BLOB NOT NULL, clipped_pct TEXT NOT NULL,   -- per-channel percentages JSON
  analyzer_rev INTEGER NOT NULL, computed_at INTEGER NOT NULL
);
CREATE TABLE frame_score (
  photo_id INTEGER PRIMARY KEY,
  sharpness REAL, junk INTEGER NOT NULL DEFAULT 0, -- black-frame/gross-exposure bits
  aesthetic REAL, is_utility INTEGER,              -- macOS 15 aesthetics API; sort-only
  analyzer_rev INTEGER NOT NULL, computed_at INTEGER NOT NULL
);
CREATE TABLE face (                                -- per-face evidence for the crop strip
  id INTEGER PRIMARY KEY,
  photo_id INTEGER NOT NULL,
  rect_x REAL, rect_y REAL, rect_w REAL, rect_h REAL,   -- normalized
  eyes_open REAL,                                  -- EAR-derived, 0–1
  capture_quality REAL,                            -- VNDetectFaceCaptureQuality, 0–1
  focus REAL,                                      -- variance-of-Laplacian on face region
  crop_artifact_id INTEGER,                        -- small JPEG crop in artifact store
  analyzer_rev INTEGER NOT NULL
);
CREATE INDEX face_photo ON face(photo_id);
CREATE TABLE feature_print (                       -- Vision FeaturePrint → burst grouping
  photo_id INTEGER PRIMARY KEY,
  data BLOB NOT NULL, revision INTEGER NOT NULL
);

-- Preview index (§15.6). Payloads are files; rows are bookkeeping.
CREATE TABLE preview (
  photo_id  INTEGER NOT NULL,
  level     INTEGER NOT NULL,          -- 0 thumb256 / 1 grid1024 / 2 fit2560 / 3 one-to-one
  recipe_fp TEXT NOT NULL,             -- "" = as-shot
  source    TEXT NOT NULL,             -- embedded | lumen  (camera-render badge, docs/10)
  path TEXT NOT NULL, bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL,
  PRIMARY KEY (photo_id, level)
);

-- AI artifact index (§15.7). Key discipline is contractual (docs/08 §8.7, docs/07):
CREATE TABLE artifact (
  id INTEGER PRIMARY KEY,
  photo_id INTEGER NOT NULL,
  kind TEXT NOT NULL,                  -- mask-raster | sam-embedding | denoise-atlas |
                                       -- depth-map | heal-patch | face-crop | matte
  component_id TEXT,                   -- mask component UUID where applicable
  model_id TEXT, model_version TEXT,
  prefix_hash TEXT NOT NULL,           -- hash of upstream pipeline params feeding its input
  pipeline_version INTEGER NOT NULL,
  checksum TEXT NOT NULL,              -- xxh3 of payload; self-healing gate
  path TEXT NOT NULL, bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL
);
CREATE INDEX artifact_key ON artifact(photo_id, kind, component_id);
```

Scale check at 200k photos: `lumen.db` ≈ 400–900 MB (recipes dominate; sparse serialization keeps
the median recipe under 4 KB), which `VACUUM INTO` compacts into a backup in seconds on Apple
Silicon SSDs. `cache.db` ≈ 1–2 GB and is disposable. Preview payloads are the real disk story
(§15.6) and live under Caches where macOS tooling expects reclaimable data.

---

## 15.4 The edit recipe

One JSON document per `edit` row. Declarative, typed, sparse. The v1 sketch extended with
everything the v2 specs added — zones (D7), Film Lab (D18), grading wheels with pivots (D15),
printer lights (D16), per-component mask amounts and local curve/wheels (D29), heal strokes,
and the Develop/Look stage split (D4):

```jsonc
{
  "pipelineVersion": 1,
  "develop": {                                    // per-image normalization (D4)
    "raw":     { "decoder": "apple", "decoderVersion": 11,      // D50: pinned
                 "temp": 5200, "tint": 8 },
    "tone":    { "exposure": 0.35, "contrast": 12, "highlights": -40,
                 "shadows": 25, "whites": 0, "blacks": -10 },
    "zones":   { "pivots": [0.08, 0.25, 0.5, 0.75, 0.92],       // D7, draggable
                 "dark":  { "ev": 0.3, "wheel": [0.02, -0.01], "sat": 0 },
                 "shadow": {}, "mid": {}, "light": {}, "bright": {},
                 "global": { "ev": 0.0 } },
    "curve":   { "parametric": {…}, "point": [[0,0],[0.25,0.22],[1,1]],
                 "r": null, "g": null, "b": null, "luma": null,
                 "preserveLuminance": true },                   // D10 default
    "mixer":   { "bands": [{ "hue": 0, "sat": 0, "lum": 0 }, …], "uniformity": 0 },
    "pointColors": [ { "sample": [0.62, 0.31, 0.22], "range": 50, "variance": 30,
                       "shift": { "h": -6, "s": 4, "l": 0 } } ],
    "detail":  { "capture": { "auto": true }, "texture": 0, "clarity": 10, "dehaze": 0 },
    "denoise": { "mode": "ai", "amount": 70, "model": "nafnet/2.1",  // splice: docs/07
                 "classic": { "luma": 0, "chroma": 25 } },
    "geometry":{ "crop": { "x": 0, "y": 0, "w": 1, "h": 1 }, "angle": -0.4,
                 "flipH": false, "upright": {…}, "lens": {…} },
    "heal":    { "strokesRef": "blob:xxh3:9f2a…", "count": 14 }  // vectors, docs/09
  },
  "look": {                                       // portable creative layer (D4)
    "wheels":  { "global": {…},
                 "shadows": { "hue": 18, "sat": 0.06, "lum": -0.04 },
                 "mid": {}, "high": {},
                 "blending": 50, "balance": 0, "pivots": [0.33, 0.67] },  // D15: visible pivots
    "printerLights": { "master": 3, "r": -1, "g": 0, "b": 2 },   // 1/12-stop points, D16
    "filmLab": { "stock": "lumen/portra400", "amount": 100, "pushPull": 0,
                 "halation": 35, "grain": { "size": 1.0, "amount": 40 },
                 "printSize": "8x10" },                          // D18
    "primaries": {…}, "bw": null, "vignette": 0
  },
  "masks": [
    { "id": "8c1f…", "name": "Sky", "enabled": true, "amount": 100,   // 0–200, D29
      "components": [
        { "op": "add",       "kind": "aiSky", "model": "skyseg/1.3", "amount": 100 },
        { "op": "subtract",  "kind": "brush", "amount": 80,           // per-component: D29
          "strokesRef": "blob:xxh3:c41b…" },
        { "op": "intersect", "kind": "lumaRange", "lo": 0.55, "hi": 1.0,
          "smooth": 0.5, "amount": 100 }
      ],
      "refine": { "feather": 12, "edge": -5 },
      "adjust": { "exposure": -0.6, "temp": -300,
                  "curve": {…}, "wheels": {…} }   // local curve + wheels: the D29 win
    }
  ]
}
```

The doctrine, each rule with its reason:

1. **Declarative, order fixed by the pipeline.** The recipe stores *state*, never an operation
   log; render order is the pipeline's business (docs/14-pipeline.md) and identical for every
   photo. This is LR's model and it is correct: it makes copy/paste, sync, presets, and auto all
   trivial recipe-subset operations, and it makes rendering a pure function of
   `(original, recipe, pipelineVersion)`. History and undo are the separate `history` ring —
   an undo-stack-as-format (serializing edit order) would make batch sync semantically undefined.
2. **Sparse and canonical.** Only non-default keys serialize (median recipe <4 KB; forward
   compatibility is free because unknown keys pass through untouched). Serialization is canonical —
   sorted keys, fixed float formatting — so `recipe_fp` is stable and every cache keyed on it
   (previews, prefix caches per D49, artifacts) invalidates exactly when content changes.
3. **Stage tags are structural.** `develop` vs `look` is the D4 split expressed in the format
   itself: "apply this Look to 800 frames" copies one subtree; per-frame normalization is never
   dragged along by accident.
4. **Bulky parametric data goes to content-addressed blobs.** Brush and heal stroke vectors
   (delta-encoded, zstd, typically 1–30 KB) live in the `blob` table, referenced as
   `blob:xxh3:<hash>`, deduplicated across versions and snapshots for free. They are *truth*, so
   they mirror into sidecars (§15.5) — unlike rasters, which are cache (§15.7). This is the split
   Adobe validated the hard way: AI-era data outgrew XMP, Adobe reached for an opaque binary
   sidecar (`.lrcat-data`), and LrC through 15.5 still can't put a mask in a text sidecar. Lumen's
   masks are prompts + vectors + parameters — text all the way down; only the disposable rasters
   are binary.
5. **`pipelineVersion` gates rendering from day 1** (§15.8, D52). Retrofitting a process-version
   system is famously painful; Adobe has carried six of them for twenty years because v1 didn't
   plan for v2.

Virtual copies are `edit` rows with `kind='version'` (docs/10 calls them Versions); snapshots are
`kind='snapshot'` rows. Both cost bytes, not files.

### What `look.subset` holds

A saved look is `{"pipelineVersion": n, "look": {…}}` — the recipe's `look` subtree, whole, plus
the vocabulary version it was written in (docs/14 §3: "a named look is the look-slice of a recipe
plus its `pipelineVersion`"). Same serialization discipline as a recipe: canonical, sparse,
sorted keys, fixed float formatting.

**Whole, with no exceptions inside the subtree.** `look.lut` travels with a look even though no
stage renders it, because the alternative is a second dead-field decision to unwind on the day a
LUT stage lands, and because a LUT is the most look-shaped thing in the format. `Recipe.render
Identity` strips it for an unrelated reason — that projection answers "do these two recipes
produce the same pixels", and what a photographer's saved look remembers is a different question.

**Nothing outside it travels.** Not `develop` (white balance is derived from one camera's as-shot
neutral, exposure and tone are one frame's light, geometry is one frame's crop), and not `masks`
— docs/14 §3 says masks declare their own register and that look-tagged ones travel, and `Mask`
carries no register field yet, so there is no look-tagged mask to carry. Carrying all of them
instead would move one photograph's brush blobs and radial centres onto another, which is the
same defect as moving a crop. `LookSubset` in LumenCore is the single place that decides this,
and `SavedLookTests` fails if a top-level recipe key is ever added without the decision being
made.

Applying a look raises the target recipe's `pipelineVersion` to the higher of the two and never
lowers it: a v2 look can express "black and white, off, mix kept", which a v1 reader would render
as black and white, while a v1 look must not restamp a v2 document whose develop half it never
touched.

`look` rows are unique on `(kind, COALESCE(grp, ''), name)` — schema version 3. A look is reached
for by name, so two rows the browser draws identically are two things the photographer cannot
choose between; saving over a name is how a look is updated, and renaming onto a taken name is
refused. Nothing references `look.id`: a look is *copied into* a recipe at apply time, so deleting
one never un-grades a photograph that used it.

`look.thumb` still has no writer. A swatch has to be rendered through the pipeline against some
photograph, and which photograph is a question this pass did not answer; the browser lists names.

---

## 15.5 XMP sidecar policy

**What we write.** For every photo with any Lumen state: `IMG_1234.xmp` beside the original.
Contents:

- **Standard, interoperable fields**: `xmp:Rating`, `xmp:Label`, `dc:subject` (keywords),
  creator/copyright as applied at ingest. Any XMP-aware tool — LrC, C1, exiftool, Spotlight —
  reads these. Cull in Lumen, and the picks survive into anyone else's software.
- **The Lumen namespace** (`lumen:` — `http://lumenapp.dev/xmp/1.0/`): `lumen:recipe` (the full
  canonical JSON, including mask prompts and blob payloads inlined as zstd+base64),
  `lumen:pipelineVersion`, `lumen:recipeFingerprint`, `lumen:snapshots` (named versions),
  `lumen:catalogUUID` + `lumen:writeStamp` for conflict attribution. Precedent: darktable's
  `darktable:history` has kept edits portable across two decades of catalog deaths.
- **What we refuse to write**: Adobe `crs:*` develop parameters. Two different pipelines cannot
  share slider semantics; a `crs:Exposure2012` written by Lumen would render *differently* in LR
  and that lie is worse than silence. (The one exception pattern worth noting from FastRawViewer —
  writing an LR-compatible exposure hint at cull time — is not worth the ambiguity for an app that
  IS the editor.)

**Naming and collisions.** Sidecars use the LR/C1 convention `basename.xmp` so other tools find
them. When two originals share a basename (`IMG_1234.CR3` + `IMG_1234.JPG`), the raw owns
`IMG_1234.xmp` and the sibling gets the unambiguous full-name form `IMG_1234.JPG.xmp` — originals
are read-only (D-constraint), so embedding XMP inside the JPEG is not an option.

**Write discipline.** Debounced ~2 s after the last mutation, batched per folder, written
atomically (temp file + rename), always off the input path (D43). Adobe's own 14.4 release notes
concede the failure mode: per-edit XMP writes were "a measurable performance drag," fixed by
batching flushes to every 10 s. Lumen starts where Adobe ended up. During bulk operations
(800-frame Look apply) sidecar writes coalesce behind the catalog transaction and drain in the
background queue.

**Conflict rules**, evaluated at scan time against `photo.sidecar_mtime`:

1. Sidecar unchanged since we last wrote it → catalog wins (normal case).
2. Sidecar newer than our last write and fingerprint differs → sidecar wins; the catalog updates
   silently. This is what makes restore-from-Time-Machine and edit-on-another-Mac just work.
3. Both changed (catalog has unflushed edits *and* the sidecar moved underneath) → catalog wins,
   but the sidecar's state is preserved as a snapshot named "Imported from sidecar &lt;date&gt;".
   Nothing is ever silently discarded.

**Implementation status.** Rules 1 and 2 are implemented in `SidecarMerge.resolve` and tested;
`photo.sidecar_mtime` is written on both sides of the exchange (after each sidecar flush, and
after each scan-time read), which is what makes "unchanged since we last touched it" answerable
at all. **Rule 3's snapshot is NOT implemented**, because snapshots do not exist anywhere yet —
`saveRecipe` only ever writes `kind = 'working'`. On a rule-3 conflict the catalog wins as
specified and the sidecar's divergent recipe is handed back to the caller in
`Resolution.unpreservedSidecar`, which the app logs by name. So the sentence above is currently
**"the discard is not silent"**, not "nothing is discarded", and it becomes true when versions
ship. Two narrower limits fall out of taking §15.5 literally, and both are deliberate: rule 2
fires on a differing recipe fingerprint, so a sidecar carrying only a changed rating does not take
one; and under rule 2 the sidecar wins for every field it *states*, because `xmp:Rating` absent
and `xmp:Rating = 0` are the same bytes and silence must not be able to delete a rating.

**Portability — the Capture One idea, absorbed.** C1 sessions prove that "the folder is the
project" is the right transport: copy the session folder anywhere and everything travels. C1 makes
you *choose* sessions or catalog up front, and its session state lives partly in a proprietary
database inside the folder. Lumen keeps one catalog (D39's "one library, done well") and gets the
portability anyway, because sidecars are always written: **any folder of originals + `.xmp` files
is a complete, portable, text-inspectable project.** Drop it on a second Mac running Lumen — scan
ingests ratings, edits, masks, snapshots; the catalog rebuilds itself around the folder. No mode,
no export step, no `.cosessiondb`.

---

## 15.6 Preview cache

The ladder that makes culling instant (budgets and UX: docs/10-spec-library.md):

| Level | Size | Format | Built | Evicted |
|---|---|---|---|---|
| 0 thumb | 256 px | HEIC | at scan, 8 parallel workers | never |
| 1 grid | 1024 px | HEIC | at scan — embedded-preview extraction, ~10–30 ms/file | not under budget pressure; LRU after fit/1:1 |
| 2 fit | 2560 px | HEIC | lazily on first loupe; re-rendered ~2 s after edits settle | LRU |
| 3 one-to-one | full res | HEIC | on demand (zoom) | LRU, tightest budget |

**Embedded fast path.** Levels 0–1 come from the camera's embedded JPEG wherever one exists
(Canon/Nikon/Fuji embed full-size; many Sony bodies only ~1616×1080 — the fallback ladder in
docs/10 §embedded previews handles paging on whatever exists and never blocks on raw decode).
Rows carry `source='embedded'`, which drives the camera-render badge; Lumen-rendered previews
replace embedded ones in the background — immediately for any photo the user edits, newest-first
otherwise — so the render "jump" happens before editing, not during (the "Lightroom changed my
photos" complaint, defused by scheduling).

**Regeneration policy.** Previews are keyed `(photo_id, level, recipe_fp)`; an edit makes the
stored fit/1:1 stale, and the re-render is debounced behind the live viewport (which renders from
the pipeline's own prefix cache, D49 — the preview cache serves *browsing*, not the develop loop).
`pipelineVersion` participates via the fingerprint, so a rendering migration lazily refreshes
previews without a rebuild-everything event. Orientation is taken from the RAW container's EXIF,
never the embedded JPEG's own tags (a documented camera-firmware inconsistency).

**Budgets, invisible.** Default disk budget: 20% of free space at cache creation, clamped to
10–100 GB, re-evaluated weekly; eviction order 1:1 → fit → grid (least-recently-viewed first);
thumbs are permanent (≈3–6 GB per 100k photos and worth every byte for instant grids). Payloads
live under `~/Library/Caches` — reclaimable by the OS's own storage tooling, excluded from Time
Machine by location, deletable wholesale with zero data loss.

**Vs. the field.** LrC 15.5's preview machinery is four import-time preview tiers (Minimal /
Embedded & Sidecar / Standard / 1:1) × Smart Previews × a Standard Preview Size setting (up to
2880px, with community guidance to match your monitor) × three quality levels × four auto-discard
windows — the community's #1 import-speed trick is knowing which combination to pick, which is the
definition of a confusing subsystem. **Better because Lumen has zero preview decisions**: one
automatic ladder, embedded-first, self-budgeting, self-discarding. **Consciously worse than LR in
one respect**: no Smart-Preview equivalent means no *editing* of offline originals in v1 — offline
volumes stay browsable/searchable/cullable from cached previews, but develop needs the file.
Scene-referred editing from a lossy 2560px proxy compromises exactly the image-quality priority we
rank first; if offline editing earns its way onto the roadmap it will be full-fidelity or absent.

---

## 15.7 AI artifact cache — content fingerprints and self-healing

Every derived AI artifact — mask rasters, SAM encoder embeddings, denoise fp16 tile atlases
(~360 MB worst case per 45 MP frame, docs/07), depth maps, heal patches, face crops — is indexed
in `artifact` with the key discipline that docs/08 §8.7 and docs/07 define contractually:

```
key   = (photo_id, kind, component_id, model_id + model_version,
         prefix_hash, pipeline_version)
value = payload file + xxh3 checksum + last_used_at
```

`prefix_hash` fingerprints the upstream pipeline parameters that feed the artifact's *input*
pixels (WB shifts change a denoiser's input; a crop does not) — the same hashing the D49 prefix
cache uses, so invalidation is exact, never conservative-rebuild-everything.

**Self-healing is a read-path property, not a repair tool.** On every load: checksum mismatch,
version mismatch, missing file, or truncated payload → the artifact is discarded and regeneration
is enqueued from the parametric truth (recipe + original), silently, at background QoS; the UI
shows the stale badge docs/08 specifies, never an error. Deleting `~/Library/Caches/Lumen`
wholesale — or macOS purging it under disk pressure — costs warm-up time only. This is D52
mechanized: LR's black-mask `.lrcat-data` folklore ("quit, delete the sidecar, let it regenerate")
is what self-healing looks like when the *user* has to be the read-path. Per-kind LRU budgets keep
the store bounded; embeddings evict first (a 1 s re-encode), denoise atlases last (a ≤10 s
recompute, D26).

---

## 15.8 Versioning, migration, backup — all invisible

Three version numbers, three different contracts:

1. **Schema version** (`PRAGMA user_version`, GRDB `DatabaseMigrator`). Append-only migration
   list, each migration transactional, forward-only. Before any migration that rewrites tables,
   the pre-migration catalog is preserved via `VACUUM INTO Backups/pre-migration-<v>.db`.
   Completely invisible: the app opens, migrates, runs. Downgrade protection: an older Lumen
   refuses a newer catalog with a message naming both versions, never a corrupt half-read.
2. **`pipelineVersion`** — the rendering contract (semantics owned by docs/14-pipeline.md).
   Recipes render under the version they were created with, *forever*, unless the user migrates —
   explicitly, per-photo or per-selection, with a before/after preview and a badge on migrated
   photos (D52). LR's historical silent process-version upgrades changed people's pictures behind
   their backs; the badge is the apology we never have to make. Old pipeline code paths are kept
   compilable and golden-tested (docs/14) for as long as any catalog row references them.
3. **Analyzer/model revisions** (`analyzer_rev`, `model_version`) — cache-level only; a bumped
   revision lazily re-runs evidence workers and regenerates artifacts. No user-facing surface at
   all.

**Backups.** On quit, if the catalog changed that day: `VACUUM INTO Backups/lumen-YYYYMMDD.db` —
a compacted, checkpointed, single-file snapshot (seconds for a sub-GB catalog on Apple Silicon).
Retention: 7 daily, 4 weekly, 6 monthly, pruned automatically. Integrity: `PRAGMA quick_check` on
every open (fails → restore newest backup that passes, automatically, with a notice *after* the
fact); full `PRAGMA integrity_check` before each weekly backup. Maintenance — `PRAGMA optimize`
on close, passive WAL checkpoints on idle, blob mark-and-sweep, preview budget re-evaluation —
runs in the same invisible slot.

Contrast, because it is the point (D39): LrC 15.5 ships a backup *prompt* on exit (Never / once a
month / weekly / daily / every time / next time), a checkbox pair for integrity-test and optimize,
zipped backups the user must prune by hand, and a `File > Optimize Catalog` menu ritual that
community lore prescribes whenever LR "gets slow." Every one of those decisions is one a database
should make for itself. **Lumen has no backup dialog, no optimize command, and no catalog
settings panel.** The catalog is plumbing; plumbing that asks questions is broken.

---

## 15.9 Filesystem watching and scan diffing

Folders are the library (D34), so the catalog must track a filesystem it does not control.

- **Watcher**: one `FSEventStream` per registered root (file-level events, 1 s latency
  coalescing). `folder.last_event_id` persists the resume point; on launch Lumen replays events
  since that ID (the FSEvents journal survives reboots), falling back to a full diff scan when the
  journal has rolled over or the ID is invalid.
- **Diff scan** (per folder, also the cold-start path): readdir → compare `(filename, file_size,
  file_mtime)` against catalog rows. New → insert + metadata extract (`CGImageSource`, ~1–3 ms,
  no pixel decode) + preview/evidence enqueue. Changed → re-extract, mark previews stale, re-read
  sidecar per §15.5 rules. Gone → *move detection first*: match `quick_sig` (xxh3 of first 1 MB +
  size) against files newly appeared elsewhere; a match relocates the row — edits, history,
  album membership intact. Only an unmatched disappearance marks `missing=1`.
- **Missing is a state, not a deletion.** Missing photos keep their rows, recipes, and previews;
  they gray out with a badge and a one-click relink that auto-matches by fingerprint when the
  volume returns. LR's "?" folders and the Find Missing Folder scavenger hunt are the anti-pattern:
  right diagnosis, manual cure.
- **Offline volumes**: unmount flips `folder.online=0` for its roots — browsable, searchable,
  cullable from cache; nothing renders, nothing errors.
- Scan work is elastic (docs/13-architecture.md owns QoS): a 3,000-file card scan must never
  contend with the cull loop's <50 ms paging budget (D43).

---

## 15.10 Crash safety and WAL discipline

The rules, and why each exists:

1. **One writer, short transactions.** Every user action is one transaction on the single write
   queue; render and ML work never touch it (docs/13). A crash can lose at most the last few
   seconds of bookkeeping, never leave a half-applied edit.
2. **WAL + `synchronous=NORMAL`** trades a sliver of OS-crash durability for never fsyncing on
   the input path. The trade is safe *because of the layers*: originals are untouched by
   definition, and sidecars re-supply any edit the WAL lost. Backups use full-durability writes.
3. **Checkpoint policy**: passive checkpoints on idle; `TRUNCATE` checkpoint on quit so the WAL
   never grows unbounded and backup snapshots are complete.
4. **Kill-tested in CI** (the D47 stability gate applied to storage): a harness drives a scripted
   edit/rate/scan burst and `kill -9`s the process at randomized points, thousands of iterations;
   the assertion is `quick_check` passes and the last *committed* decision is present. A catalog
   that can be corrupted by a crash is a catalog that will be.
5. **Worst case is bounded and stated**: catalog and backups all gone → re-scan folders, re-read
   sidecars; recover every edit, mask, rating, and snapshot; lose albums, stacks picks, history
   ring, export log, ingest ledger. Painful, not fatal — and strictly better than the failure
   geometry of any tool whose edits live only in its database.

---

## 15.11 Vs. the field

| Subsystem | Lightroom Classic 15.5 | Capture One 16.8.4 | Lumen | Verdict |
|---|---|---|---|---|
| Edit portability | XMP `crs:*` but AI-era data (masks, Denoise) locked in binary `.lrcat-data` | Sessions are portable; catalog edits live in a proprietary DB | Full recipe incl. mask prompts in text sidecars, always | **Better**: nothing load-bearing is opaque |
| Catalog hygiene | Backup prompt matrix, manual zip pruning, Optimize Catalog ritual | Periodic backup prompts | `VACUUM INTO` rotation, auto integrity, auto optimize — zero UI | **Better**: no rituals (D39) |
| Preview machinery | 4 import tiers × Smart Previews × size × quality × discard windows | Simpler, still settings-laden | One automatic embedded-first ladder, self-budgeting | **Better**: zero decisions |
| AI artifact integrity | `.lrcat-data` corruption → black masks → delete-the-sidecar folklore | n/a at LR's scale | Checksummed, versioned, self-healing on the read path | **Better** (D52) |
| Rendering versions | Six process versions; historical silent upgrades; 15.5 "Render to DNG" bakes to escape | Engine versions per catalog | `pipelineVersion` gated, badged, previewed migration | **Better**: nothing silent |
| Project portability | Catalog export/import ceremony | **Sessions — the good idea** | Folder + sidecars = portable project, no mode switch | **Equal to C1's idea, better integrated**: one catalog, portability always on |
| Offline editing | Smart Previews (2560 px lossy proxies) | Limited | Browse/cull offline; no proxy editing in v1 | **Consciously worse**: full-fidelity or absent (image quality > feature count) |
| Multi-catalog / multi-user | Multiple catalogs, import-from-catalog | Sessions + catalogs | One catalog, one user | **Consciously worse**: out of scope by design (D-constraints) |

The one-sentence summary for implementers: originals are sacred, sidecars are the will, the
catalog is a fast index that knows it is replaceable, and every byte of cache can prove its own
staleness and rebuild itself without being asked.
