# F7-library — library spec vs. what the library does

Branch: `worktree-agent-a235d0964ad4c5ba3` (merged with trunk `claude/jolly-sagan-k7ch7z` at
c73ea9e). Specs: docs/10-spec-library.md, docs/15-catalog.md, docs/19-daily-use.md. Note that
doc 19 explicitly DROPS ingest-engine parity and virtual copies from scope; the table records
them anyway and marks them out of scope instead of implementing them.

## 1. Gap table (verified against code before any change)

| Capability (spec) | Before | After this stream | Evidence |
|---|---|---|---|
| Manual albums: create, target `B`, add/remove (§10.9) | BUILT | BUILT | `CatalogStore.createCollection/addToCollection`, sidebar Albums |
| Album rename / delete | MISSING (no API, no UI; delete would hit FK) | **BUILT** | 4466c70 |
| Album sets (nest one level) | PARTIAL (schema `parent_id`, no UI) | PARTIAL (delete reparents children; still no UI to nest) | 4466c70 |
| Album drag reorder / user order | MISSING (`AppState.SortOrder.userOrder` says so) | MISSING | — |
| Smart albums / saved filters (§10.8, D39) | MISSING (`album.kind/query` never written) | **BUILT** (save bar → sidebar row, click loads bar, update, rename, delete). Default set (Picks, ★≥4, …) not seeded | 49888cb |
| Smart album scope (folder subtree / album) | MISSING | MISSING (count is over the open folder) | — |
| Keyword add/remove, batch, chip, text search | BUILT | BUILT | — |
| Keyword hierarchy | MISSING (`parent_id` never set) | **BUILT** (`Parent > Child` entry, paths shown, chip/search include descendants) | ef1a782 |
| Keyword synonyms | MISSING | **BUILT** (store, chip, search, typing a synonym tags its keyword; sidebar "Add Synonym…") | ef1a782 |
| Keyword identity (one row per parent+name) | MISSING (LIMIT 1 over a full scan) | **BUILT** (migration 4, UNIQUE + fold) | ef1a782 |
| Keywords ↔ XMP `dc:subject` | MISSING both ways | **BUILT** both ways (delta write, additive import) | 3ab2585 |
| Hierarchical keywords ↔ `lr:hierarchicalSubject` | MISSING | MISSING (sidecar stays flat; leaf names round-trip onto the existing hierarchy) | — |
| Rating/flag/label/recipe XMP sync both ways | BUILT | BUILT | `SidecarMerge`, `XMPMerge` |
| Stacks: manual stack/unstack/collapse/promote | BUILT | BUILT | — |
| Auto-stack bursts (§10.2) | MISSING | **PARTIAL** — capture-gap half as an explicit command | 5246cb7 |
| Metadata editing: rating/flag/label batch | BUILT | BUILT | `setRating(_:photoIDs:)` etc. |
| Metadata editing: title/caption/copyright/job | MISSING (no columns except `job`, no UI for `job`) | MISSING | — |
| Search grammar: chips, OR within / All-Any across, FTS text | BUILT | BUILT (+ keyword closure) | `LibraryFilter`, `buildPhotoQuery` |
| Date-range / aperture chips | PARTIAL (`PhotoQuery` supports, `LibraryFilter` has no field) | PARTIAL | — |
| Evidence chips (junk, closed eyes…) | PARTIAL (`PhotoQuery` only) | PARTIAL — F5's territory | — |
| Sort orders (12 keys) | BUILT except user-order drag; sharpness/aesthetic have no writer | same | `PhotoQuery.SortKey` |
| Virtual copies (§10.9) | MISSING (doc 19: dropped) | MISSING, out of scope | — |
| Find missing / relink (§15.9) | PARTIAL (quick_sig move detection, `missing` flag; no relink UI) | PARTIAL | `CatalogStore.scan`, `adoptRowsFromRelatedFolders` |
| Catalog backup / restore | BUILT automatic (rotation, quick_check, restore-on-corrupt) | BUILT; Settings>Storage report + "Reveal backups" MISSING | `CatalogService.backUp`, `recoverIfNeeded` |
| Ingest presets (§10.7 templates as named presets, metadata preset) | MISSING (templates are sheet `@State`, not saved; no copyright preset) | MISSING (doc 19 drops ingest parity) | `IngestSheet.swift` |
| Rename on import | BUILT (`RenameTemplate`, `{seq:N}`) | BUILT | — |

## 2. Items

| Item | Status | Commit | Red/green | Proof records |
|---|---|---|---|---|
| Album rename/delete | FIXED | 4466c70 | AlbumLifecycleTests 3; cleanup statements substituted out → 2/3 red (FOREIGN KEY constraint failed). UI source-verified | none |
| Keywords ↔ XMP dc:subject | FIXED | 3ab2585 | SidecarKeywordTests 11; parse + delta substituted out → 8/11 red; ownership substituted out → 5/11 red. SidecarKeywordRoundTripTests (macOS lane) source-verified. `xmp.json` fixture bytes unchanged | none |
| Smart albums | FIXED | 49888cb | SavedLibraryFilterTests 4 + SmartAlbumCatalogTests 1; codec line/version/unknown-label substituted → 3/4 red. Mirror guard fails if `LibraryFilter` gains an unsaved field | none |
| Keyword hierarchy + synonyms + migration 4 | FIXED | ef1a782 | KeywordHierarchyTests 6 (+KeywordPathTests 1) incl. v1 and v3 catalogs written with the old DDL/migrations; fold/closure/reindex substituted → 5/6 red | none |
| Stack bursts by capture time | PARTIAL (capture-gap half, as a command; FeaturePrint half not built) | 5246cb7 | BurstGroupingTests 4 + BurstStackingCatalogTests 1; chain/body/not-in-stack substituted → 2/4 and 1/1 (5 assertions) red. Menu item source-verified; surface check exit 0 | none |

No rendering code touched: no proof record moves.

## Migration order (for the merge with F5)

This stream adds **lumen.db migration 4** (`lumenMigration4`, keyword identity + synonyms) and sets
`latestSchemaVersion = 4` in both `CatalogStore` declarations. Trunk had 3 at merge time (c73ea9e).
If F5 lands a migration 4 first, renumber mine to the next free number: it is self-contained
(touches only `keyword`, `photo_keyword`, new `keyword_synonym`), idempotent (`IF NOT EXISTS`),
and order-independent of a frame-score / facet migration. `KeywordHierarchyTests.writeOldCatalog(version: 3)`
builds its fixture from `CatalogStore.migrations where version <= 3`, so it keeps working
after renumbering. `SavedLookCatalogTests` no longer pins `user_version == 3`; it asserts `>= 3`
and `== latestSchemaVersion`.

## Constraint: the culling keystroke path

Nothing added runs per keystroke. Smart-album rows are not highlighted from `state.filter`
(that would add an Equatable compare per row per publish); counts are computed on
`refreshLibrarySections`, which only folder changes and membership edits call. Sidecar keyword
writes ride the existing debounced queue.

## DECISIONS (conservative choice implemented; owner may overrule)

1. **Sidecar keyword import is additive only.** A keyword in the catalog but missing from the
   sidecar is kept: the scan cannot tell "another tool removed it" from "Lumen added it and has
   not flushed". A removal made in another tool therefore does not propagate into Lumen.
2. **A failed-at-quit keyword write is replayed as additions only** (UnsavedSidecarRecord stores
   fields, not deltas); a removal owed at quit is not replayed.
3. **Keyword identity is case-sensitive.** Migration 4 folds exact duplicates only; "Dawn" and
   "dawn" stay two keywords. Lightroom folds case; folding here would merge keywords a user may
   have meant apart.
4. **Keyword chip / search on a parent includes descendants and synonyms.** Spec is silent;
   chosen because filing under a parent is pointless otherwise.
5. **Hierarchy is not written to sidecars.** `dc:subject` gets the tagged keyword's own name;
   `lr:hierarchicalSubject` is not written or read.
6. **Smart album count = its filter over the open folder** (what clicking shows), and clicking
   loads the filter into the bar rather than making the album a "source". Scope
   (everywhere/subtree/album) is not exposed. Default smart-album set is not seeded.
7. **Smart albums cannot be the target album** (`setTargetCollection` throws).
8. **Deleting an album leaves no target** if it was the target, rather than promoting another.
9. **Burst stacking is a command, not a default, and capture-gap only** (≤2 s, per body, chain).
   The spec's FeaturePrint half is not built; turning it on by default would change what a
   freshly opened card looks like under the Collapsed-stacks chip.

## FOUND-WHILE-FIXING

- `addKeyword`'s `SELECT id FROM keyword WHERE name = ? LIMIT 1` was an unindexed scan per
  keystroke-entry; migration 4 adds `keyword_name`.
- Folder open read each sidecar twice (merge + stroke restore); now once (3ab2585).
- The non-SQLite `CatalogStore` stub was missing parity for new album methods; added.
- Remaining MISSING items worth a follow-up, by value: relink UI for missing folders; date-range
  chip in `LibraryFilter` (the SQL exists); IPTC title/caption/copyright fields; ingest template
  presets; album drag-reorder; Settings>Storage backup report.
