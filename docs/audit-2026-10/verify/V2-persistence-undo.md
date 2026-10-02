# V2: sidecars, persistence, undo and preview provenance (verification of PR #5)

Verifier: V2. Worktree branch: `worktree-agent-ac402f4ec8869b4b0`, reset onto `claude/jolly-sagan-k7ch7z`
(a9a1d47). The worktree started on `origin/main` (99c3727), which does **not** contain PR #5, so I
reset it to the audit trunk before doing anything else. Build dir: `/tmp/lumen-build-v2`.

Note: worktree isolation refused writes to the main-tree path
`/home/user/lumen/docs/audit-2026-10/verify/V2-persistence-undo.md`. This report is committed at
the same relative path in the worktree branch instead.

Most of this area lives in `LumenApp` (`CatalogService`, `AppState`, `PreviewStore`,
`ThumbnailLoader`, `RenderCoordinator`), and those files cannot compile here. Their tests
(`AuditStateSafetyTests`, `AuditPersistenceSafetyTests`, `AuditSidecarOwnershipTests`,
`AuditPreviewReliabilityTests`) are `#if os(macOS)`. They do run in CI: the `test-fast` job runs
`swift test` on macos-15 with no LumenApp skip. I checked those by reading the source and say so
in each row. I ran the substitutions for the LumenCore halves.

`python3 scripts/check-swift-surface.py` exit code 0.

## Verdicts

| Finding | Commit | Verdict | Evidence |
|---|---|---|---|
| **UX-01**: undo during a slider gesture saves the undone value | cc30178 (+ test in 40e1048) | **CONFIRMED** (source-verified only) | `undo()`/`redo()` now call `sliderGesture(active:false)` first. That flushes `pendingGesturePersist` (+1) *before* `apply` persists the history value, so on the serial catalog queue and in the sidecar pending map the undo result is the last write. With the hunk removed, `testUndoDuringGesturePersistsUndoThroughReleaseAndQuit` would see the release flush write +1 after undo's 0 and fail on both the catalog and XMP asserts. It has a negative control (`closeBeforeUndo`), a redo case, and a cross-photo case. The HistoryPanel jump and the menu/keyboard items all go through `state.undo()`/`redo()`. Not run (macOS). See the sibling note on Auto Tone below. |
| **REL-09**: sidecar write failure is never shown | cc30178 | **INCOMPLETE** (source-verified only) | While the app is running it is fixed: the first failure per URL calls `report()` → `onFailure` → status bar, the notice resets after a success, and retry continues. The test would go red without the `report` call (`notices.count == 0`). **It is not fixed for the quit flush**, which the finding names explicitly. `close()` → `flushSidecars()` → `report()` → `onFailure`, and `onFailure` is `Task { @MainActor … }` (AppState.swift:2559). That task cannot run once `applicationWillTerminate` returns. `sidecarsClosed = true` then drops the re-queued failure, and nothing records it durably. The ledger lists this as a limitation. |
| **REL-02**: new same-basename RAW sibling inherits sidecar edits | 40e1048, cf508cf | **WRONG**: the trigger is fixed, but the fix adds a regression (source-verified only) | The trigger itself is fixed: Lumen writes an owner tag (`lumen:sourceExtension`), `sidecarURL` routes a foreign-owned bare file to `NAME.EXT.xmp`, `readSidecar` and the flush refuse a mismatched owner, and legacy files are migrated only with an mtime and fingerprint match. Traced: DNG→NEF, NEF→DNG, NEF→CR3, legacy-DNG, unknown-legacy and Adobe-bare all behave. **Regression:** the new early return `if qualified exists → return qualified` (CatalogService.swift:1344) runs *before* the ownership check. darktable writes `NAME.NEF.xmp` beside every RAW it opens. A lone NEF whose Lumen edits are in `DSC_0001.xmp` (owner `nef`) is switched to darktable's file once darktable has opened the folder. From then on Lumen reads and splices into darktable's document, and the portable copy of the Lumen edits is orphaned. Before 40e1048 a lone RAW always used the bare name. LumenCore half: I added a test, red when the mechanism is substituted out (below). |
| **REL-06**: replaced original keeps stale pixels, preview and quick signature | fb2a990 | **WRONG**: the trigger is fixed, but the fix adds a regression | The trigger is fixed. The scan treats a changed `SourceFileIdentity` as a changed file, which nulls quick_sig, full_hash and EXIF, deletes preview and artifact rows, and unlinks payloads. `RenderCoordinator.source(for:)` re-decodes on an identity change. `PlanTableCache.renderIdentity` includes the token. **Substitution:** with the scan hunk reverted, `AuditSourceIdentityTests` failed 2 tests / 7 assertions. With the `renderIdentity` token removed, `testRapidSameSizeWriteRestoringMTimeStillChangesIdentity` failed (1). Both restored to green. **Collateral regression, measured by a temporary LumenCore probe:** (a) the first scan after upgrading treats *every* row as changed, because `metaValue("source_identity_<id>")` is nil and nil ≠ token. The probe on an unchanged file showed `changed=[1] quickSig=nil width=nil previews=0`, so every capture date, EXIF field, quick signature and preview in the library is wiped once. (b) The token includes `st_dev` (and `st_ino`/`ctime`). A token that differs only in the device field produced the same full wipe. On macOS `st_dev` of an external volume depends on mount order, so re-plugging a photo drive in a different order invalidates that whole folder's previews and metadata on every such reopen. Quick sigs are NULL until the backfill runs, which also blinds rename detection (LIB-01) in that window. |
| **REL-07**: old developed preview gets a newer recipe fingerprint | fb2a990 | **CONFIRMED** (source-verified only) | The render result carries `DevelopedPreviewIdentity(source, fingerprint(rendered recipe))` and only for exact, whole-frame, unproofed, note-free settles. `developedPlan` rejects the plan when the current fingerprint or source differs. `recordPreview` re-checks both on the catalog queue at publication time. A rejected writer unlinks its own UUID-named payload. `testDevelopedPixelsCannotAcquireLaterRecipeFingerprint` covers the finding's exact interleaving and would go red without the `developedPlan` check (the plan would read the newer fingerprint). `testRecipeChangesAfterWritePlanCannotPublishObsoletePixels` would go red without the publication re-check. |
| **Brush snapshot recovery** (`prepareBackupPayloads`) | 40e1048 (+ backup ordering in cc30178) | **CONFIRMED**. The test was weak and I fixed it | The mechanism is right: refs are collected from every `edit.recipe`, each one must exist live or in the snapshot with bytes that hash to the ref, repairs are written before the DB is swapped, and damaged live bytes are kept as `.damaged-<uuid>`. Substitution with the guard removed: `testRecoverySkipsLegacySnapshotWithMissingBrushPayload` red (1). **Weak:** that test uses a ref with no file at all, so on the Linux lane nothing exercised the hash check or the live repair write. Removing either one left everything green. Added `testRecoveryRejectsSnapshotWhoseOnlyBrushCopyIsCorrupt` (hash check substituted out → 2 failures: the newer snapshot is chosen and the damaged bytes are published as the live brush) and `testRecoveryRestoresTheLiveBrushFromTheChosenSnapshot` (repair write substituted out → 1 failure). |
| September **K-015** (shared `NAME.xmp`) | (d. Sept) | **No regression** (source) | With no Lumen document present, `sidecarURL` still falls through to `SidecarNaming.url`. With a Lumen document present, the owner tag gives the bare file to exactly one extension and sends everyone else to qualified, so no two photos can address one file. The only exception, two names differing only in case on a case-sensitive volume, predates this change. `SidecarNaming` tests are untouched and green. |
| September **J1-03** (flush re-seeds from the file as it is now) | | **No regression** (source) | The re-seed path is intact. The new ownership guard sits in front of it and refuses with a report on a mismatch. `reseed` now also carries `sourceExtension` (stated ?? fresh), and my new test pins that. |
| September **M-01** (newer-build recipe not downgraded) | | **No regression** (source) | `writableFields(documentVersion:)` is still applied in the flush. The new legacy-owner migration only rewrites when `pipelineVersion <= currentPipelineVersion` and `parsedCleanly`, and it splices with the verbatim `recipeJSON` string, so nothing gets downgraded. |

Additional test, also red when its mechanism is substituted out: `testSidecarOwnershipSurvivesSerializeSpliceAndReseed`
(LumenCore, REL-02's owner tag). With the reseed carry and the parse case-folding removed it gave 2 failures; restored, it is green.
Final green run: `AuditSafetyTests` 9/9, `AuditSourceIdentityTests` 3/3, `SidecarAndIngestTests` 24/24.

## Phase 2 specs

**REL-02 regression (darktable / foreign qualified sidecar).** `Sources/LumenApp/CatalogService.swift`
`sidecarURL(for:)`. Trigger: lone `DSC_0001.NEF`, Lumen edits in `DSC_0001.xmp` (owner `nef`), then a
`DSC_0001.NEF.xmp` appears that Lumen did not write (darktable). Today Lumen switches to it. Fix: check
the bare file's owner first (owner == own extension → bare). Honour an existing qualified file only
when it is Lumen-owned for this extension (`sourceExtension == ext`) or the bare file belongs to
someone else. Better still, move the whole decision into a pure `SidecarNaming` function that takes
the (bare content, qualified content, siblings) facts, so the Linux lane can test it. Acceptance test
(LumenCore, pure): bare owned by `nef` plus a qualified file with no Lumen content → bare. Qualified
owned by `nef` with the bare owned by `dng` → qualified. Keep the existing four
`AuditSidecarOwnershipTests` green.

**REL-06 regression (identity instability).** `Sources/LumenCore/Catalog/CatalogStore.swift` scan
(`identityChanged`) and `SourceFileIdentity`. Triggers: (a) the first scan after upgrade, when no
`source_identity_<id>` is stored. (b) The same file with only `st_dev` changed (a remount), or only
`ctime` changed (a Finder tag or xattr). Fix: a missing stored identity means "adopt", not "changed".
When size and second-mtime are equal but the token differs, confirm with `QuickSignature` against
the stored `quick_sig` before invalidating, and only invalidate on a mismatch. Consider dropping
`st_dev` from the token, and from the cache-namespace key `PreviewStore.scope`, or the disk cache
re-namespaces on remount anyway. Acceptance tests (LumenCore): a row scanned without identity, then
with identity at the same size and mtime → `unchanged == 1`, previews, EXIF and quick_sig kept. Two
tokens differing only in the dev field with the signature unchanged → unchanged. The existing
`AuditSourceIdentityTests` stay green: a real same-size rewrite still invalidates because its
signature differs. This needs the owner's agreement on the cost: one 1 MB read per
identity-changed file.

**REL-09 quit-flush half.** `CatalogService.close()` / `AppState.prepareToQuit()`. Trigger: an edit
followed by ⌘Q inside the 2 s debounce, with the sidecar path unwritable. Fix: have `close()` return
or record the URLs whose final flush failed (for example a `meta` key `sidecar_unsaved` in the
catalog, written before `store.close()`), and show them at the next launch, re-queueing their
sidecars from the catalog recipe. Acceptance test (macOS): sidecar path is a directory, save, `close()`,
reopen the service → a notice is delivered synchronously on open naming the file, and after the
directory is removed the sidecar is written with the catalog's recipe.

## Further observations (not regressions from these commits)

- **UX-01 sibling, Auto Tone.** `applyAutoTone` (AppStateActions.swift:48-80) writes `recipes`
  and calls `persist` directly. If its async measurement lands while a slider gesture is open and no
  further drag event follows, the release flushes the older `pendingGesturePersist` over Auto's
  write, so memory has Auto's tone and the catalog and XMP do not. Same remedy as undo: call
  `sliderGesture(active:false)` before applying. macOS-only; not fixed here.
- `establishLegacySidecarOwners` re-reports "Ambiguous sidecar ownership" on every scan of a folder
  with an unresolved legacy file, and it reads one bare XMP per RAW stem per scan on the catalog
  queue.
- A loupe settle rendered before a Subject or People matte is ready carries the final recipe's
  fingerprint, and could be filed as the developed preview. This predates PR #5 and is outside
  REL-07's trigger. I did not chase it.

## Pixel or contract impact

No production code changed. No proof records move. No decisions for the owner were made in code.
The REL-06 fix proposal includes an owner decision (the cost of a signature check on an identity
change).

## Local commits

- `14fbd4f`: The brush recovery's hash check and the sidecar owner tag had no test on the lane that
  runs every push (tests only, `Tests/LumenCoreTests/AuditSafetyTests.swift`).
- The commit that adds this report (see the branch head).

Branch: `worktree-agent-ac402f4ec8869b4b0`. Not pushed.
