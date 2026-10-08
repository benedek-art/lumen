# LIB-02 smart album scope implementation

Commit: eef5561b362e730f9057cddefc95e7755455ba8b (`codex/lumen-smart-album-scope`, based on relink 25b9fdb; relink already integrated independently as d9527ce).

## Delivered

- Existing `album.scope`/`scope_id` storage now resolves to typed current-folder, entire-catalog, folder-subtree or manual-album sources. NULL retains legacy current-folder semantics. Unsupported wire values, malformed IDs, deleted references and smart albums used recursively as album sources refuse rather than widen.
- One source predicate resolver feeds photo rows, lightweight ordering, counts, metadata facet domains and keyword domains. Source conditions always AND with filter chips, including Match Any. Subtree matching handles both independently registered descendants and nested relative filenames registered under ancestor folders, with literal component boundaries (including `%`/`_`). User Order within an album scope uses that manual album's member positions.
- Album rows count the saved query against the actual saved scope. Unavailable scopes show a dash and refusal reason. Save Smart Album and Change Scope invoke an explicit source picker; active smart album and source type appear in the source header/sidebar. Choosing a manual album or Return to Folder reacquires the original folder universe instead of retaining a narrowed smart source.
- Source acquisition reads catalog rows/recipes on the existing serial queue; it never scans originals or imports their XMP. It works before any folder is open, and offline folder rows remain catalog candidates. Existing filters still exclude catalog-marked missing originals.
- Acquisitions flush a deferred slider gesture before the queued read and before replacing the visible roll. A mutation revision preserves latest overlapping live recipes and culling state by catalog ID when edits occur during an asynchronous read. Queued writes and durable sidecar debt are not reset. Newer folder/scope requests supersede earlier reads using the existing scan generation.
- Related-folder registration already adopts ownership to avoid duplicate rows. Defensive source acquisition additionally refuses legacy/corrupt overlapping URL identities rather than collapsing different catalog IDs in the URL-keyed UI. URLs use existing standardized/symlink-resolved identity rules; joins and recipe preservation use catalog IDs.
- Deleting a manual album formerly NULLed referring smart scopes. It now retains the explicit unavailable reference until deliberate scope change. Active unavailable sources clear visible results, selection and primary photo after gesture flush; facets and active-source warning update. Loaded recipes remain backing state until an explicit source replacement.

## Validation

Final native SwiftPM targeted run: **35 tests passed, 0 failures**, log `/private/tmp/lumen-smart-scope-final.log`. Command used native build system, jobs 2, isolated `/private/tmp/lumen-oct07-persistence-*` scratch/cache/module dirs and `--disable-sandbox`. `git diff --check` passed.

New core tests cover three-plus folders, descendant/ancestor relative names, wildcard-looking/sibling boundaries, rows/order/count/facet agreement, manual member User Order, Match Any, persistence/reopen, offline/missing distinction, NULL compatibility, unknown/deleted/recursive scope refusal and scope update validation. Existing album lifecycle test now asserts explicit deleted references remain unavailable.

Eight synthetic AppState/service regressions exercise:
1. Entire-catalog, subtree and manual-album source acquisition with count/facet agreement.
2. Newer asynchronous scope wins, preserving edits/culling made after an older catalog snapshot; open slider gesture flushed.
3. Newer folder wins; failed acquisition preserves previous visible roll.
4. Production deletion of active manual scope invalidates visible rows/selection and retains scope identity until explicit return.
5. Normal related-folder ownership adoption and deliberately corrupt duplicate URL refusal without silent collapse.
6. Relaunch/explicit catalog scope without any current folder.
7. Unwritable sidecar debt survives source switch and catalog recipe remains durable.
8. Conflicting external XMP is not imported or modified by source read.

Expanded existing coverage includes SavedLibraryFilterTests, SmartAlbumCatalogTests, FacetCountTests, AlbumLifecycleTests, LibraryQueryPacingTests and AuditPersistenceSafetyTests. Generated tiny JPEG fixtures and temporary catalogs only; no private RAWs, GPU qualification or release build. Existing test teardown/backfill may log closed-database notices when asynchronous background work settles after fixture close; all assertions passed.

## Bounded limitations

- Native modal picker/sidebar visual review remains for the later hands-on app session; no visual correctness is claimed from code tests.
- Broad scopes materialize their unfiltered catalog candidate rows and current recipes, matching the existing app roll model; this is not a new virtualized/paged catalog browser. Large-catalog memory/performance qualification remains separate.
- Source acquisition does not certify bytes against signatures or import external metadata; explicit rescan/relink retains that responsibility.
- Missing originals remain subject to existing filter policy; offline folder status alone does not discard catalog rows.
- Manual albums clicked directly retain their existing current-folder behavior; this change connects smart query scopes to manual-album candidates rather than rewriting the direct manual-album browser contract.
- Catalog-wide keyword vocabulary remains a library vocabulary by design; per-chip counts/domains use the scoped query.
- No schema migration, RAW rendering changes, updater/release changes, pushes or merges in this worktree.

## Independent review repair — c178da302c31a4086c21c36f75fd69e5bee0d002

Two review regressions were reproduced red in `/private/tmp/lumen-smart-scope-review-red.log` (2 tests, 3 failing assertions), then repaired:

- A smart album created first and scoped to the highest manual-album ROWID could silently acquire an unrelated album after deletion/recreation reused that ROWID. Deletion now writes `scope='deleted-album'` in the same SQLite transaction, preserving source ID and query while permanently refusing live-ID resolution. The typed codec recognizes the tombstone; the shared resolver supplies a meaningful deleted-source error. Explicit Change Scope is required to recover it. This supersedes the dangling-live-reference wording above.
- Paused source acquisition could resume its old URL after an actual relink updated the visible photo. Acquisition now rereads catalog source truth whenever the existing source-mapping revision changes while awaiting. Every reread retains folder/scan-generation guards; overlapping live edits are merged only after mappings settle. This also reevaluates subtree membership when a relink moves the original outside that subtree. `applyOriginalRelink` and `AppStateOriginalRelink.swift` were left untouched, allowing the independently queued early-flush repair to merge cleanly.

Final expanded native run: **52 tests passed, 0 failures**, `/private/tmp/lumen-smart-scope-review-final.log`, including existing original-relink core/app tests. New review tests exercise actual highest-ID deletion/recreation, actual relink while a scope read is paused, and moved-outside-subtree membership/count consistency. No production folder deletion API or `DELETE FROM folder` SQL exists in Sources; external/manual SQLite folder deletion and reuse remains an unsupported database modification, rather than an app deletion path.

Next bounded containment item (QA-04): `CatalogService.querySource` decodes `store.currentRecipe(photoID:)` while mapping every candidate. One malformed recipe currently aborts acquisition safely and retains the prior roll, but prevents unrelated healthy candidates from opening. Do not replace bad recipes with nil/default silently. A future containment path should carry per-photo read failures, keep that photo unavailable for editing/export, preserve malformed payload and offer recovery while allowing healthy photos to load. This review wave documents the limitation without introducing an unsafe fallback.
