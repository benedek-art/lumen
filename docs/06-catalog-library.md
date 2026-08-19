# 06 — Catalog, Library & Edit Storage

## Source-of-truth model

Three layers, strictly ordered by authority:

1. **Original files on disk** — never modified, never moved by Lumen (until an explicit "copy on import" feature exists). The folder tree *is* the library structure.
2. **Catalog** — one SQLite database (`~/Pictures/Lumen/lumen.db` by default). Holds file index, metadata cache, ratings/flags/labels, edit recipes, mask geometry, preview-cache bookkeeping.
3. **XMP sidecars** (`IMG_1234.CR3` → `IMG_1234.xmp`) — a mirror of ratings + the edit recipe, written next to the original (debounced, e.g. 2s after last edit). Purpose: catalog-loss insurance and greppable/inspectable edits. The catalog wins on conflict unless the sidecar is newer (mtime check on scan), which also gives us cross-machine portability for free.

## SQLite schema (v1 sketch)

```sql
CREATE TABLE folder (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,          -- absolute, plus security-scoped bookmark blob
  bookmark BLOB,                      -- macOS sandbox bookmark if we sandbox
  last_scanned_at INTEGER
);

CREATE TABLE photo (
  id INTEGER PRIMARY KEY,
  folder_id INTEGER NOT NULL REFERENCES folder(id),
  filename TEXT NOT NULL,
  file_size INTEGER, file_mtime INTEGER,
  content_hash TEXT,                  -- xxhash of first 1MB + size; detects moves/dupes
  capture_at INTEGER, camera TEXT, lens TEXT,
  iso INTEGER, shutter TEXT, aperture REAL, focal_mm REAL,
  width INTEGER, height INTEGER, orientation INTEGER,
  rating INTEGER DEFAULT 0,           -- 0..5
  flag INTEGER DEFAULT 0,             -- -1 reject / 0 none / 1 pick
  label TEXT,                         -- color label
  UNIQUE(folder_id, filename)
);

CREATE TABLE edit (
  id INTEGER PRIMARY KEY,
  photo_id INTEGER NOT NULL REFERENCES photo(id),
  version_name TEXT,                  -- NULL = the working version; named = snapshot/virtual copy
  is_current INTEGER DEFAULT 1,
  pipeline_version INTEGER NOT NULL,  -- process version for future-proofing
  recipe JSON NOT NULL,               -- the full parameter document (see below)
  updated_at INTEGER
);

CREATE TABLE preview (
  photo_id INTEGER NOT NULL,
  kind INTEGER NOT NULL,              -- 0 thumb(256) / 1 grid(1024) / 2 fit(2560) / 3 full
  edit_fingerprint TEXT NOT NULL,     -- hash of recipe; "" = as-shot
  file TEXT NOT NULL,                 -- path in cache dir
  PRIMARY KEY (photo_id, kind)
);
```

Notes:
- **GRDB.swift** is the SQLite layer (mature, value-type records, migrations, WAL mode, observation API that plugs straight into SwiftUI).
- All queries the UI runs (grid filter/sort) must be index-backed; smart collections are stored SQL predicates over `photo`.
- Catalog backup: on quit, if dirty, copy the db (`VACUUM INTO`) to `Backups/lumen-YYYYMMDD.db`, keep last 10.

## The edit recipe (the heart of non-destructive editing)

One JSON document per photo version. Ordered, typed, versioned. Sketch:

```jsonc
{
  "pipelineVersion": 1,
  "raw":     { "temp": 5200, "tint": 8, "boostShadowAmount": 0.0 },   // params consumed by the RAW stage
  "tone":    { "exposure": 0.35, "contrast": 12, "highlights": -40,
               "shadows": 25, "whites": 0, "blacks": -10 },
  "presence":{ "clarity": 10, "dehaze": 0, "texture": 0, "vibrance": 15, "saturation": 0 },
  "curve":   { "points": [[0,0],[0.25,0.22],[1,1]], "r": null, "g": null, "b": null },
  "hsl":     { "hue": [0,0,0,0,0,0,0,0], "sat": [...], "lum": [...] },
  "detail":  { "sharpenAmount": 40, "sharpenRadius": 1.0, "sharpenMasking": 20,
               "nrMode": "ai" | "classic" | "off", "nrLuma": 0, "nrChroma": 25 },
  "geometry":{ "crop": {"x":0,"y":0,"w":1,"h":1}, "angle": -0.4, "flipH": false },
  "effects": { "vignette": 0, "grain": 0 },
  "masks": [
    {
      "id": "uuid", "name": "Sky", "enabled": true,
      "components": [                            // mask algebra: OR of components, each maybe subtracted/intersected
        { "op": "add", "kind": "aiSky" },
        { "op": "subtract", "kind": "brush", "strokesRef": "blob:..." },
        { "op": "intersect", "kind": "lumaRange", "lo": 0.5, "hi": 1.0, "feather": 0.2 }
      ],
      "adjust": { "exposure": -0.6, "temp": -300, "sat": 10, "clarity": 0, ... }  // subset of global params
    }
  ]
}
```

Rules:
- **Params are declarative, order is fixed by the pipeline**, not by edit history — same as LR, unlike an undo-stack-as-format. History/undo is a separate ring of prior recipe states (persisted, capped).
- Brush strokes and AI-mask rasters are big → stored as blobs/files referenced from the recipe (`strokesRef`), with strokes kept vector-form (replayable at any resolution) and AI rasters cached at generation resolution + regenerable. (Adobe validated this split the hard way: Lightroom Classic 15 added a second *binary* "ACR sidecar" because AI masks and Denoise data broke pure-XMP storage.)
- `pipelineVersion` gates rendering: if a future Lumen changes an algorithm, old photos keep rendering identically until explicitly migrated (this is Lightroom's "process version," and retrofitting it is painful — so it exists from day 1).
- Copy/paste settings, presets, sync, auto-settings are all trivially recipe-subset operations. Virtual copies/snapshots are extra `edit` rows.

## XMP sidecar format

- Standard XMP fields for interoperable bits: `xmp:Rating`, `xmp:Label`, capture metadata.
- Our recipe under a custom namespace (`lumen:recipe` as embedded JSON), like darktable does with `darktable:history`. We do **not** attempt to write Adobe `crs:*` develop params — no fidelity is possible.

## Preview & thumbnail cache

The thing that makes culling feel instant. Cache directory of pre-rendered JPEGs/HEICs:

| Level | Size | When built | Used by |
|---|---|---|---|
| thumb | 256px | on folder scan (background, parallel) | grid |
| grid | 1024px | on scan (from embedded RAW preview when available — nearly free) | grid zoom, filmstrip |
| fit | ~2560px | lazily, on first loupe view; re-rendered after edits (debounced) | loupe |
| 1:1 | full res | on demand (zoom), LRU-capped disk budget | zoom |

Key trick (same as LR "embedded previews" import): **RAW files contain a full-size embedded JPEG** — extract it for instant grid/loupe on fresh imports, and only replace it with a Lumen-rendered preview once the user edits. Culling therefore never waits on RAW decode.

Scanning: `FSEventStream` watcher per registered folder; scan diff = insert/update/remove by `(filename, mtime, size)`; EXIF via `CGImageSource` (ImageIO) which reads RAW metadata without decoding pixels.
