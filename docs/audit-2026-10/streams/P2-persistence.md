# P2-persistence: sidecar ownership, source identity, quit-time persistence

Branch: `worktree-agent-ade4271a74f1c6d19`, reset onto `origin/claude/jolly-sagan-k7ch7z` (cc4cdd7).
Build dir `/tmp/lumen-build-p2`. Input: `docs/audit-2026-10/verify/V2-persistence-undo.md`.
`swift build --build-tests` is clean, and `python3 scripts/check-swift-surface.py` exits 0.
Green suites: SidecarNamingTests 11/11, AuditSourceIdentityTests 8/8, UnsavedSidecarRecordTests 4/4,
CatalogTests 63/63, AuditSafetyTests 9/9, SidecarAndIngestTests 24/24, SidecarReseedTests 7/7,
SidecarLabelPolicyTests 4/4.

## Items

| Item | Status | Commit | Red/green evidence | Proof records |
|---|---|---|---|---|
| REL-02 regression (darktable `NAME.EXT.xmp` displaces an owned `NAME.xmp`) | FIXED | f8e8f29 | The decision moved to the pure `SidecarNaming.resolve` in LumenCore. When the old "qualified exists → qualified" rule is put back at the top, SidecarNamingTests fails 3 tests / 6 assertions. Restored: 11/11. The macOS service test `testDarktableQualifiedSidecarDoesNotDisplaceOwnedBareSidecar` is source-verified. The four existing ownership transitions were traced by hand and still hold. | none |
| REL-06 regression (a) upgrade wipe, (b) `st_dev` remount wipe | FIXED | 2976a7a | With the old `stored != current` comparison put back: 4 tests / 16 assertions fail. With `st_dev` put back into the token and exact comparison: 2 tests / 5 assertions fail. Restored: 8/8. The existing same-size-rewrite tests are unchanged and green. | none |
| REL-09 quit half (failure at quit dropped) | FIXED | 61f06cd | With the empty-list clear and the stated-field merge taken out, UnsavedSidecarRecordTests fails 3 tests; restored, 4/4. The macOS test `testQuitFlushFailureIsSurfacedAtNextLaunchAndRewrittenFromCatalog` (V2's acceptance spec) is source-verified. | none |
| Auto Tone landing mid-drag overwritten by the release | FIXED | 63ceb77 | macOS test `testAutoToneLandingMidGestureSurvivesReleaseAndQuit`, source-verified: without the fix the catalog and XMP asserts fail (2). | none |
| "Ambiguous sidecar ownership" repeats every scan | FIXED (the repeat). The per-scan read is still open, see below | 3c2b2fa | macOS test `testAmbiguousOwnershipIsReportedOncePerSessionNotEveryScan`, source-verified: the old code gives 3 notices where 1 is expected. | none |
| Settle rendered before a Subject/People matte filed as developed preview | FIXED | bbf00e9 | macOS test `testSettleBeforeItsMatteIsReadyIsNotADevelopedPreview`, source-verified: the old predicate labels the early settle with the fingerprint. | none (on-screen pixels unchanged; it only limits which frames get cached) |

### How each fix works

- **REL-02.** Rules apply in this order:
  1. A bare file whose `lumen:sourceExtension` matches this extension is used, and nothing displaces it.
  2. Otherwise, a qualified file Lumen owns for this photo is honoured: either its owner tag matches, or it has no tag but contains Lumen content. Once a frame has moved to its qualified file, it stays there after its neighbour is removed.
  3. Otherwise, a bare file owned by another extension sends this photo to the qualified name.
  4. Otherwise, the unchanged K-015 rules apply.

  A foreign qualified file (darktable's) never takes part. `CatalogService.sidecarURL` now only reads the two files.
- **REL-06.**
  - A missing stored token is adopted, with no read.
  - A different token at the same size and second is treated as a suspicion. `CatalogStore.scan(…, signature:)` calls the closure only for those rows. It invalidates only when the quick signature differs from the stored one, or when there is no stored signature to compare against.
  - When a token is confirmed unchanged, it is stored, so the file is read once, not on every scan.
  - When a change is confirmed, the new signature is recorded instead of leaving NULL.
  - `st_dev` is dropped from `SourceFileIdentity`. `sameGeneration` ignores a leading device field, so tokens written by trunk builds compare equal and cost nothing.
  - Because the token no longer carries `st_dev`, `PreviewStore.scope` no longer re-namespaces the disk cache on a remount.
- **REL-09.**
  - `close()` returns the sidecar names its final flush could not write and logs them synchronously.
  - Before the store closes, it records `{photoPath, photoID, stated fields}` in the meta key `sidecar_unsaved`.
  - At the next open, `unsavedSidecarNotice` is set synchronously, and `AppState.openCatalog` shows it next to the recovery notice. The owed fields are re-queued, **rebuilt from the catalog**, so an outlived record can only cause a redundant, correct rewrite.
  - A successful write settles the record. A photo that is no longer in the catalog is reported once and dropped.

## DECISIONS (implemented conservatively; the owner can overrule)

1. **REL-06 cost.** When a stat token changes at the same size and mtime, Lumen now reads 1 MB of the file (the quick signature) before invalidating anything. V2 flagged this as an owner decision. I implemented it because the alternative wipes EXIF and previews.
   - If there is no stored signature to compare against (only right after a change, before the backfill runs), the suspicion is treated as a change. That is the safe direction for pixels.
2. **`st_dev` is out of the token entirely**, not just out of the scan comparison. It also feeds `PreviewStore.scope` and `PlanTableCache.renderIdentity`, and keeping it there would still re-namespace the disk preview cache on a remount. A replacement file is always on the same volume as the path it replaces, so the device number never told two generations apart.
3. **REL-09 at quit: no modal.** At quit the failure goes to NSLog and to the durable record. The notice appears at the next launch.
   - Showing it at quit itself would need either an alert inside `applicationWillTerminate`, or an `applicationShouldTerminate` flush that offers "Quit Anyway / Cancel". Both are new UI and change how quitting behaves. **DECISION NEEDED** if the owner wants either one.

## FOUND-WHILE-FIXING (specced, not fixed)

- **`ctime` still feeds `PreviewStore.scope`.** A Finder tag or an xattr write moves ctime. After this change the scan no longer wipes anything for it, but the disk cache key for that one photo changes, and its previews are re-rendered once.
  - Fix spec: key the scope on a generation that the catalog advances only when it confirms a change. For example, store a `source_generation_<id>` counter that the scan bumps on a confirmed change, and use `(id, generation)` in the scope instead of the stat hash.
  - Cost today: one re-render per tagged photo. No data is lost.
- **The pre-PR#5 → PR#5 upgrade still discards every disk preview row once.** This happens through `PreviewStore.plan`'s scope filter: legacy rows have no `render-vN/<key>/` prefix. It is by design, because `renderingRevision` exists to invalidate renders from the older decoder. I mention it only so it is not confused with the REL-06 scan wipe fixed here.
- **`establishLegacySidecarOwners` still reads one bare XMP per RAW stem on every scan, on the catalog queue.**
  - Fix spec: skip stems whose bare file's mtime equals a stamp recorded the last time the file was found unresolvable or already owned. A meta key per bare path, or an in-memory memo per session, would do it.
- **`close()` called twice** (some tests do this) now also tries `setMetaValue` on a closed store. That fails and is logged. It is harmless, but `close()` could become idempotent.

## Files touched

- LumenCore:
  - `Sources/LumenCore/XMP/SidecarNaming.swift`
  - `Sources/LumenCore/Catalog/SourceFileIdentity.swift`
  - `Sources/LumenCore/Catalog/CatalogStore.swift` (only the scan)
  - `Sources/LumenCore/XMP/UnsavedSidecarRecord.swift` (new)
- LumenApp:
  - `CatalogService.swift`
  - `AppState.swift` (`openCatalog`, `prepareToQuit`)
  - `AppStateActions.swift` (the Auto Tone landing)
  - `RenderCoordinator.swift` (one predicate)
- Tests:
  - `SidecarNamingTests`, `AuditSourceIdentityTests`, `UnsavedSidecarRecordTests` (new)
  - macOS: `AuditSidecarOwnershipTests`, `AuditPersistenceSafetyTests`, `AuditStateSafetyTests`, `AuditPreviewReliabilityTests`

No XCTExpectFailure was present for these defects, and no test was skipped or loosened.
