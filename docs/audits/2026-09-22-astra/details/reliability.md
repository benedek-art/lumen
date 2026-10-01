# Lumen independent reliability, speed, persistence and delivery audit

Auditor: Astra reliability sub-audit. Date: 2026-09-22. Baseline: `99c37272b42c211a04262ceb98cfb39355d1ab99` (main). Latest source cross-check: `origin/claude/photo-editor-design-plan-8ahzmm` at `a6e6941`. The product source files implicated below are unchanged on that branch; its CI test timeout increased, but its release gating did not change. No product files, actual user catalog, original photos, or remote resources were modified.

## Bottom line

The warm image pipeline is already usefully fast on this Mac: direct release rendering at 1536 px has roughly 7–11 ms median exposure/color updates. That is not yet an end-to-end UI responsiveness guarantee. In particular, folder registration does quadratic sibling-name work before applying the scan: even 500 tiny JPEG placeholders took about 19–23 seconds in the optimized app service harness. Reliability has more consequential gaps than shader speed: a healthy locked catalog can be rolled back to a backup, a newly added RAW sibling can inherit another photo's edits, and the ingest already-present shortcut can certify a truncated file. These warrant fixes and regression tests before entrusting sole copies or a sole catalog to the app.

This report separates reproduced defects from source-only risks and already acknowledged product gaps. No security exploit, live update install, power-failure durability, printer proof fidelity, or complete library recovery was tested.

## Evidence and method

Harnesses in this directory compile unchanged product modules or unchanged app service files with narrow model stubs. `core_probe.swift` uses real CatalogStore, VerifiedCopyDriver, XMP and preview APIs. `catalog_probe.swift` includes unchanged CatalogService; its PhotoFormats stub copies the product RAW/rendered extension sets. `preview_probe.swift` includes unchanged CatalogService, PreviewStore and ThumbnailLoader. `pipeline_probe.swift` includes unchanged RenderCoordinator and the real pipeline; only unrelated app type dependencies are stubbed. `metadata_probe.swift` uses real encoders and reopens the delivered files. `performance_probe.swift` links the parent's fully optimized release package objects, not a mocked render path.

All destructive/error injection operated only on newly created audit files. SQLite checks were moved to fresh `/private/tmp/lumen-reliability-*` directories after Documents/FileProvider produced intermittent `SQLITE_IOERR` in both audit hosts. Those I/O errors are an environmental limitation, not a product finding. CoreImage GPU runs required the execution sandbox exception; sandbox-denied encoder failures were excluded. Test stdout was observed directly; `observations.json` preserves measured values and conclusions without claiming a full raw trace. Harness source is the repeatable evidence.

The main agent owns baseline tests, UI exercise, the active-gesture undo persistence defect, latest-branch source-open regressions and integrated conclusions. This report supplements rather than duplicates those findings.

## Reproduced findings

### REL-01 — P1: an exclusive lock is mistaken for corruption and restores stale data

**Source:** `Sources/LumenCore/Catalog/CatalogStore.swift:1553–1577,1598–1602`.

`probeQuickCheck` collapses every open/check error to `false`. `recoverIfNeeded` responds by setting aside the current DB/WAL and copying the newest readable backup over the live path. In a fresh catalog, create a rating-1 backup, save rating 5, close the store, hold a separate SQLite connection with `PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;`, then call recovery. A direct check reports SQLite error 5 (`database is locked`); recovery nevertheless reports damage/restoration and the reopened rating is 1. The healthy original is retained under `.damaged-*`, so this is a rollback with a recoverable original, not demonstrated irreversible erasure. Album/keyword/stack changes cannot all be restored from sidecars automatically.

This is not a claim that an ordinary WAL writer blocks readers. The demonstrated trigger is an exclusive lock; transient I/O and permission errors enter the same code branch but were not separately injected as clean product tests. Distinguish unavailable/busy/I/O from a completed integrity check that actually finds corruption; never replace a catalog merely because it cannot presently be checked. Confidence high. New. Tests cover missing/corrupt databases, not healthy-but-unavailable ones. Repro: `core_probe.swift`, `healthy-but-locked-recovery`; raw `core-confirmed.log`.

### REL-02 — P1: adding a RAW sibling silently changes sidecar ownership

**Source:** `Sources/LumenCore/XMP/SidecarNaming.swift:49–58`; `Sources/LumenApp/CatalogService.swift:1291–1318`.

A lone `DSC_0001.DNG` writes `DSC_0001.xmp`. Add `DSC_0001.NEF` later: the naming rule now assigns that bare file to the NEF and moves the DNG's expected path to `DSC_0001.DNG.xmp`, without migrating or checking provenance. In the actual CatalogService reopen sequence, a DNG edited to exposure +2 yielded both DNG and previously unedited NEF at +2. Only the bare XMP existed. The DNG's future sidecar/recovery path no longer contains its previously written state; an edit to the NEF can subsequently replace the original bare document.

Persist sidecar ownership, safely migrate when topology changes, or refuse ambiguous reassignment. Existing static RAW-collision tests do not cover folder membership changing after edits exist. Confidence high. New transition failure beyond the existing RAW+JPEG/collision fix. Repros: `catalog_probe.swift`, `service-sidecar-transition`; `core_probe.swift`, `dng-alone-then-nef` (also demonstrates rating adoption).

### REL-03 — P1: already-present ingest bypasses planned-length verification

**Source:** `Sources/LumenCore/Ingest/VerifiedCopy.swift:397–402,427–430,503–512`.

The normal copy path rejects a source shorter than the scan's planned `byteCount`, but the already-present shortcut returns before that guard. With a plan of 5000 bytes and source/destination both containing the same 100 bytes, the real driver reports `allVerified=true`, one already-present result, `bytesCopied=5000`, and “every copy verified.” Matching hashes prove these two short files agree, not that the originally scanned frame was transferred completely. This is exactly the distinction needed before allowing a card to be treated as ingested/ejectable.

Validate source digest length against the plan before accepting any destination as already present. Confidence high. New bypass of an already known/fixed fresh-copy short-read issue. Tests need the existing-destination branch plus source mutation between planning and execution. Repro: `core_probe.swift`, `ingest-short-already-present`.

### REL-04 — P1: export can overwrite a file created after name selection

**Source:** `Sources/LumenApp/AppStateActions.swift:337–341`; `Sources/LumenPipeline/PipelineRenderer.swift:1203–1211`.

The batch selects a free output name before rendering, but the final writer replaces any file now present at that name. An actual renderer harness chose an absent destination and created an unrelated sentinel there inside source decoding, after name choice. Export succeeded and replaced the sentinel with an 859-byte JPEG (`FF D8 FF`). Existing-file disambiguation before rendering works; this is specifically the race window with another writer or concurrent export, not an allegation that every ordinary re-export overwrites.

Make overwrite intent explicit, and use no-replace final publication/re-disambiguation for the normal export workflow. Ingest already has the appropriate no-overwrite final-move approach. Confidence high. New; prior OUT-04 inspection of the preflight guard did not exercise publication. Repro: `pipeline_probe.swift`, output-name race case.

### REL-05 — P1: folder registration does quadratic sidecar sibling work

**Source:** `Sources/LumenApp/CatalogService.swift:1291–1293,1304–1318`; `Sources/LumenCore/XMP/SidecarNaming.swift:66–77`; sidecar calls in CatalogService at `500–501,516,583`; main `Sources/LumenApp/AppState.swift:2652–2668`.

Only the directory listing is cached. Every sidecar lookup scans every directory entry again and creates a URL in the `isRawName` closure before rejecting unrelated stems. Swift eagerly evaluates this even for JPEGs whose naming needs no RAW sibling lookup. Registration invokes the lookup about four times per photo: O(N²) work before `applyScan`. The serial registration operation also cannot promptly yield to a newer folder request/catalog write.

Optimized CatalogService and `-O -whole-module-optimization` LumenCore, fresh tiny 3-byte JPEG placeholders and no sidecars: 100 files cold 1.946 s / repeat 1.325 s; 500 cold 22.926 s / repeat 18.734 s. An isolated optimized benchmark using the exact SidecarNaming function showed the same curve (100: 0.459 s; 500: 22.311 s; 1000: 114.783 s). A later repeat with `/private/tmp` as working directory took 0.447 s at 100 and 10.829 s at 500: about 24× the time for 5× the count, without depending on a Documents/FileProvider working directory. Audit/test jobs were active for some scan timings; treat these as observed loaded-session values, not controlled product SLA numbers. The O(N²) cause is independent of machine load, and no image decode is involved. A prior debug run of the full service reached 84–94 seconds at 1000 files; that is diagnostic only, not a release benchmark.

Build a per-directory stem→extension index once, short-circuit non-RAW names, and avoid re-resolving the same sidecar path within one photo registration. Add a large-folder registration test and a cancellable/supersedable scan boundary. Confidence high. New measured cause for the prior LIB-25 first-grid concern. Repros: `catalog_probe.swift`, `sibling_benchmark.swift`.

### REL-06 — P2: replacing an original at the same URL preserves stale pixels and identity

**Source:** `Sources/LumenCore/Catalog/CatalogStore.swift:1972–1978,2484`; `Sources/LumenApp/CatalogService.swift:214`; `Sources/LumenApp/RenderCoordinator.swift:604–610,728–751`; ThumbnailLoader URL/size cache keys.

The scan notices a changed file but retains its old quick signature via `COALESCE`, retains preview rows, and excludes it from missing-signature backfill. CatalogService discards the ScanResult. RenderCoordinator caches source objects by URL and has an invalidation method with no production caller. A real render harness read a 32×24 red PNG, replaced that audit file at the same URL with a 64×48 green PNG, and still returned 32×24 and identical sampled RGB until calling invalidate explicitly. Independently, the core scan persisted a prior quick signature and continued serving an old preview after size/mtime changed.

This matters for externally edited rendered photos, replaced files, RAW conversion/metadata workflows and folder rescans; ordinary immutable camera originals do not trigger it. Invalidate source, thumbnails, developed previews and identity/metadata together when the original changes. Confidence high. New. Existing cache tests focus recipe changes and eviction, not source generations. Repros: `pipeline_probe.swift` and `core_probe.swift`, changed-original case.

### REL-07 — P2: an old preview can be stored under the next recipe's fingerprint

**Source:** `Sources/LumenApp/ThumbnailLoader.swift:221–231`; `Sources/LumenApp/PreviewStore.swift:141–160,220–223`; `Sources/LumenApp/LoupeView.swift:1240–1265`.

`recordDeveloped` accepts only URL and pixels; its unstructured task later fetches the *then-current* recipe fingerprint. In an uninterrupted MainActor turn, queue an exposure-0 image with recordDeveloped, immediately save exposure +2, then yield. The actual PreviewStore wrote the old image under new fingerprint `xxh64:e4ce9920b7023b16` (old was `xxh64:fd50cceee634dfb4`), and subsequently served it as current. Cancellation/provenance is not carried into this API.

Capture photo/source generation and recipe fingerprint with the rendered result and reject publication if either is superseded. Confidence high. New. Rung-size/cache-match tests do not prove the pixels actually came from the fingerprint recorded on the row. Repro: `preview_probe.swift`; synthetic 2560×8 image, real persisted HEIC cache payload.

### REL-08 — P2: failed blob backup leaves a restore-eligible database snapshot

**Source:** `Sources/LumenApp/CatalogService.swift:1531–1547`; restore selection in `Sources/LumenCore/Catalog/CatalogStore.swift:1555–1561`.

The `.partial` catalog is renamed to final `.db` before brush blobs are copied. If blob copying fails, the catch removes only the now-absent partial. A real service harness stored a brush payload, made that audit blob unreadable, and closed the service. Backup reported an error, but a final `lumen-*.db` remained without that blob in its paired `.blobs` directory. Recovery admits this DB based on SQLite quick_check alone. Thus incomplete snapshot sets are published as potential restore candidates.

A follow-up harness saved an actual recipe referencing that brush, copied only the failed snapshot set into a fresh audit directory with a synthetically corrupt database, and opened the real CatalogService. It selected the incomplete snapshot and restored the recipe reference but zero brush payloads: a 128×128 mask's sum changed from 18.56348 before backup to 0 after restore. This demonstrates backup-alone incomplete restoration, without deleting the live audit catalog or originals. It intentionally does not import sidecars first; a small available sidecar can independently rescue a brush, but unavailable originals or payloads above the sidecar cap cannot rely on that. Publish a complete snapshot bundle/manifest only after both DB and blobs succeed; recovery must reject incomplete bundles. Confidence high. New beyond K-018 brush-backup addition. Repro: `catalog_probe.swift`, `failed-blob-backup-still-published` and `restore-incomplete-backup`; raw output saved in `catalog-recovery-confirmed.log`.

### REL-09 — P2: sidecar write failures remain invisible to the user

**Source:** `Sources/LumenApp/CatalogService.swift:1226–1260,1634–1646`.

Write failures log and requeue after 15 seconds but do not invoke the service's user-visible failure callback. The quit drain can fail, schedule a retry that cannot run after exit, and close normally. The real service harness placed a directory at the expected `.xmp` path, saved exposure +2 and closed: an NSError appeared in the log, the sidecar was still a directory, and `onFailure` recorded no errors. The DB edit survives, so this is not loss of the active catalog edit; it is an unreported failure of portable sidecar persistence/recovery promised to the photographer.

Surface a persistent failed-save indicator and make quit's final failed flush visible. Permission denial/full disk are ordinary analogous write errors; only the audit-owned blocked-path case was injected. Confidence high. New failure-reporting gap. Repro: `catalog_probe.swift`, `sidecar-write-failure-not-surfaced`.

### REL-10 — P2: JPEG export ignores requested print density

**Source:** `Sources/LumenPipeline/PipelineRenderer.swift:1075–1080,1159`.

Actual exports requesting 240 PPI reopened as JPEG 72 PPI, while HEIC/TIFF/PNG reopened as 240. This occurred with source EXIF both retained and stripped. JPEG's full property dump included TIFF X/YResolution 72. The implementation changes only the top-level DPI pair; source/nested density and the actual encoder output need reconciliation. This does not change pixel dimensions, but it changes placed/printed physical size in software honoring density tags.

Confidence high for delivery mismatch, medium for the exact metadata precedence inside CoreImage/ImageIO. Previously acknowledged OUT-05 verification gap, now experimentally confirmed. Repro: `metadata_probe.swift`, eight real exports; `inspect_metadata.swift` for full properties/tags.

### REL-11 — P2: the supplied Contact metadata field is absent from delivered files

**Source:** `Sources/LumenPipeline/PipelineRenderer.swift:1061–1073`; `Sources/LumenApp/ExportSheet.swift:807,828`.

With a synthetic contact string and copyright supplied, real JPEG/HEIC/TIFF/PNG outputs retained copyright but none retained contact. Full CGImageMetadata tag enumeration on JPEG/TIFF also found no contact, not merely a missing top-level property. The code writes IPTCContact as a plain string through the generic `put` helper; successful metadata dictionary construction does not prove encoder serialization. The sheet warns this metadata path is unverified, so report this as a broken/unfinished field, not a hidden claim that every metadata toggle works.

Either implement format-supported contact/XMP metadata and readback tests or disable the field with a clear limitation. Confidence high. Existing OUT-05 acknowledged-unverified area, now demonstrated. Repro: `metadata_probe.swift`, `inspect_metadata.swift`.

### REL-12 — P1 release-policy risk: test failures do not block automatic update publication

**Source:** `.github/workflows/ci.yml:121–170`; `Sources/LumenApp/AppUpdater.swift:161–162,166–241`; UpdateDecision date/commit selection.

The bundle job explicitly runs independently of test verdicts (no `needs` gate) and publishes the single `dev-latest` feed from both main and the Claude branch. The updater's quiet startup check installs an eligible differing/newer-published build automatically. CI concurrency is keyed per branch, so distinct branch jobs can race to replace the same release; a later-published older/divergent commit is not excluded by ancestry. This is source-confirmed workflow behavior, not an injected remote update test. A failing test suite can still produce the installed release by design.

Separate experimental artifacts from the auto-update channel; require selected tests/proof, restrict the publishing branch, serialize the shared feed and adopt a monotonic release version. Confidence high for missing gate; branch-release race is a reasoned consequence, not dynamically exercised. Known intentional policy, not a novel coding defect. Latest branch keeps this policy despite increasing a test timeout. No remote write or live installation was performed.

## Additional boundary evidence owned by the main audit

The latest branch's `commonParent` loop retains equal path components after the first mismatch. For `/a/day1/photos/DSC_0001.NEF` and `/a/day2/photos/DSC_0001.NEF`, the computed false root is `/a/photos`. Passing that root and both files through actual unchanged CatalogService/core registration collapses both relative names to `DSC_0001.NEF`: returned IDs `[3,3]`, one DB row, and saving exposure -2 for the second changes the first row from +1 to -2. The core probe separately scans a previously registered two-file folder with only one selected file: the other is marked missing and disappears from an album queried with `includeMissing=false` (2→1). These substantiate the parent's latest-only `openSources` regressions; do not duplicate issue IDs.

The core probe also shows an external sidecar recipe change within the same integer mtime second is ignored (`catalog exposure 1`, `sidecar exposure 2`, selected 1). CatalogService truncates Date to seconds at 1266–1270, and SidecarMerge considers the stamp changed only when integer values differ. A richer change token is advisable. Lower-priority boundary evidence; not promoted over the persistence issues above.

## Release performance measurements

Hardware/runtime: this user's Apple M4 Mac, macOS 27, arm64, Swift 6.4. Build: unchanged optimized release LumenCore/LumenPipeline objects. Three safe audit copies of Sony ARW files, original ImageIO dimensions 7008×4672; portrait output 4672×7008. No user originals modified. Source recipe: asImported with source ISO, then the specified single global adjustment; no AI/local masks or complex personal sidecar recipe. Preview: 1536 px long edge, exact/non-coarse unless called draft. 20 sequential samples per warm adjustment. Times include synchronous pipeline delivery to CGImage, not SwiftUI events, view compositing, scopes, async queue contention or input-to-photon latency. OS/disk/shader caches were not reset; “cold” means new source/first preview in that process. Other audit activity may have existed, so these are observations, not formal performance certification.

| Safe RAW copy | Source init ms | First 1536 preview ms (decode ms) | Exact exposure p50 / p95 ms | Exact mixer hue p50 / p95 ms | Draft hue p50 / p95 ms | Final exact settle ms | Native JPEG90 export ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| A7401502 | 2549.74 | 1570.33 (1541.67) | 8.62 / 18.96 | 10.44 / 16.15 | 8.12 / 9.39 | 6.95 | 3389.93 |
| A7401654 | 313.93 | 1022.50 (1008.71) | 7.64 / 10.83 | 10.63 / 13.26 | 7.74 / 10.50 | 8.31 | 3628.78 |
| A7401693 | 291.60 | 874.09 (859.56) | 6.60 / 9.27 | 9.90 / 13.17 | 9.54 / 11.57 | 9.02 | 3077.77 |

All kernels were available. Exact exposure maxima were 88.30/47.84/35.83 ms, concentrated in each sequence's first changed frame; medians alone conceal that outlier. Warm exposure decode medians were about 0.01 ms, demonstrating useful prefix reuse. Each draft-hue loop recorded 20 stale-table serves and 20 deferred bakes; final exact settles returned without missing kernels. Delivered native JPEGs read back as 4672×7008 for all three files, sizes 8,091,637 / 3,528,461 / 7,026,847 bytes. Full export decodes at scale 1 before obtaining its render plan/extent (`PipelineRenderer:706–710`), so the separately investigated mutable decoder native-size issue did **not** downsize these outputs.

These results support a promising warm pipeline, not a complete Lightroom-speed claim: browse/import, first decode, mask generation, many-photo memory pressure, 1:1, multi-output export, and complete UI drag scheduling need their own budgets. The warm median fits 60 Hz and often approaches 120 Hz, but p95/outliers plus GUI/scopes can exceed either frame budget.

## Export correctness, color, HDR and privacy scope

Dynamic format matrix: JPEG 8-bit; HEIC 8/10-bit; TIFF 8/16-bit; PNG 8/16-bit all encoded and reopened with the requested 32×24 dimensions, expected component depth and Display P3 ICC identification in synthetic tests. Three native RAW JPEG deliveries retained full pixel count as above. This is encoder/profile/depth evidence, **not** a perceptual ΔE proof, printer proof or all-orientation/crop test.

Synthetic metadata source included GPS, body serial, auxiliary serial, lens serial, capture time and source keywords. With GPS and camera serial disabled, all tested output formats omitted the standard GPS dictionary and standard body/auxiliary serial fields. EXIF keep retained capture time and lens serial; EXIF strip removed them. Source-keyword keep/strip behaved accordingly. Copyright survived; contact and JPEG density failed as reported. We did not inspect every proprietary MakerNote/XMP namespace or arbitrary embedded metadata payload, so this does not certify exhaustive anonymization. The UI's camera-serial toggle promises the body, not all equipment identifiers; retained lens serial is a residual privacy consideration, not mislabeled as a proven violation of that narrower label.

HDR remains deliberately non-writable (`hdrIsWritable=false`): outputs are SDR, with no delivered gain map/true HDR path. The main audit owns the HDR-badged HEIC preset screenshot; this is a misleading/unfinished capability, not a demonstrated broken implemented HDR encoder. Soft proof/custom printer ICC workflows are not a full Lightroom print-proof replacement. Multi-output export independently renders the develop graph for each checked recipe (the product source explicitly acknowledges this); it is not the advertised single-master/multiple-tail optimization. Catalog keywords are not injected into export's source-property dictionary, and catalog keyword preservation in XMP remains an acknowledged library gap. These are important feature-coverage limitations distinct from new defects.

## Persistence and original-file safety: what is sound, and what remains

Source review found original photo handling read-oriented across scanner, decoder, metadata read and renderer; recipe/rating persistence writes the catalog and adjacent XMP, not RAW/JPEG pixel originals. Ingest reads source files and writes destination copies through hidden partials. Normal export disambiguates existing names. No test observed an original photo being changed. The export publication race above still means another file can be overwritten in a user-selected output folder; this is not a blanket no-overwrite guarantee. No adversarial symlink/hard-link path audit was completed.

Catalog writes use prepared statements/transactions, WAL and synchronous NORMAL; cache database recovery is separated from primary recipe storage. Future-schema and malformed/foreign-sidecar preservation are deliberate. Sidecar writes are atomic and normally debounced; quit drains catalog work before flushing. These are valuable protections, but disk/sidecar errors need UI visibility, same-second conflict detection is coarse, and automatic rollback must not conflate busy with corrupt.

Backups use a separately opened connection and integrity-check the catalog before `VACUUM INTO`; the open/background path avoids tying the large copy to the edit writer lane. Daily gating, a 32 MiB quit-time threshold, and a non-overlapping backup guard bound some UI impact. Retention keeps newest 3 plus one representative from each of 4 distinct recent weeks (at most 7 recognized DB snapshots), preserves unrecognized filenames, and prunes only after successful backup. Corresponding brush payload directories are included. This is good bounded retention, not independent disaster recovery: backups reside beside the catalog, and sidecars cannot restore all albums/stacks/keywords. Loss of that whole volume is outside their protection. REL-08 weakens the DB+blob atomicity promise; REL-01 weakens restore selection. Database integrity alone is not complete semantic library recoverability.

Ingest hashes streaming source bytes and verifies destination readback, isolates individual destination failures, cleans partials on cancellation, and disambiguates at final publication. The fresh-copy short-read check is good. No power-cut/unplug/card-reader fault testing was done; hash/readback through normal filesystem APIs does not prove physical stable-storage durability or camera-media health. `allVerified` should be interpreted only after fixing REL-03 and within that logical-copy scope.

## Concurrency and memory/cache census (source audit unless above)

The render coordinator actor serializes mutable decoder use and bounds source objects to 12, with a smaller live RAW working set. AppleRawSource uses an eight-entry cache, a 320 MiB interactive working set and one separately handled native inspection plane. DecodeResidency derives a process retained-plane budget (currently 1344 MiB from 1024 MiB worst-case one-source ceiling plus 320 MiB interactive space). ThumbnailLoader defaults to 512 MiB, eight workers, LRU trim to 90%, and a bounded failed-URL set. LUT tables are bounded per slot; in-flight bakes join under synchronization; matte caches and other bounded structures exist. Draft stale-table delivery followed by exact settle was observed in the benchmark.

These counts/budgets do not bound total process RSS: lazy CoreImage graphs, GPU/intermediate allocations, decoder internals, thumbnail storage and other structures are additional. `AppState.strokeCache` (`2412`, `2488`) accumulates content-addressed brush stroke sets without a visible eviction/reset path; long brushing sessions can retain many obsolete stroke histories. PreviewStore's URL→photoID map is also session-lived. BlobStore's cache is count-bounded (256), not byte-bounded. Those are source-level long-session growth risks, not a measured OOM claim. We did not run hours of editing, memory-pressure tests or a representative 50k-photo library. File-identity invalidation and preview provenance races were dynamically demonstrated (REL-06/07), unlike these RSS risks.

## Updater/security/release reliability census

The updater checks downloaded size and SHA-256 **before** archive extraction, rejects missing hashes, verifies the extracted code signature's internal consistency, stages the replacement beside the installed app and uses atomic replacement. These are meaningful integrity/failed-install protections. Builds are ad-hoc signed, not Developer-ID authenticated/notarized distribution. Hash and archive provenance come from the same GitHub release/account trust boundary; they detect corruption/mismatch but are not independent protection against a compromised release publisher. This is a private-development distribution model, not proof of a security vulnerability or public-release hardening.

Source-only residuals: updater hash/extraction/signature/copy subprocess work occurs in a MainActor class and can stall the UI; no adversarial archive/failure matrix was exercised. Temporary unpack directories are not obviously cleaned. Relaunch opens the new app before terminating the old one, so lifecycle/catalog handoff deserves a real installation test. Publication is independent of tests and branches race one feed (REL-12). No network behavior beyond reading source was required in this sub-audit; no telemetry/exfiltration claim is made. Standard export GPS/body-serial scrubbing passed the limited dynamic checks, with proprietary-metadata caveats above.

## Priority and acceptance tests

Before relying on a sole library: fix busy-as-corrupt recovery; preserve sidecar ownership through sibling additions/removals; validate already-present planned ingest lengths; make normal export final publication no-overwrite; index sibling names; gate the automatic-update feed. Then close preview/source identity and sidecar/backup failure-reporting gaps. Each should gain the concrete regression harness case above in the product test suite.

An adequate next release gate should include: healthy locked/unavailable catalog never renamed; complete DB+blob restore after live-store loss; DNG→DNG+NEF transition preserving independent edits; planned-length ingest for already-present/mixed-destination branches; final-output name race; original replacement invalidating every cache layer; old render unable to acquire a newer fingerprint; actual encode/readback for every metadata field and supported bit depth. Add realistic large-folder cancellation/first-grid and long-session memory budgets. Passing isolated formula/unit tests alone will not cover these boundaries.
