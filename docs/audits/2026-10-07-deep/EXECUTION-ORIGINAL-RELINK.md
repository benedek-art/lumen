# APP-14 explicit missing-original relinking — 2026-10-07

Implemented on `codex/lumen-original-relink` from `origin/main c4923aa`. No RAW fixtures, release build, installed app files or unrelated snapshot/selection helper changes.

## Behavior

The File menu exposes **Relink Missing Original…**. The user selects a known missing catalog original, explicitly chooses a file, sees both paths and the matching stored size/signature, and confirms the mapping. The review explicitly says that the existing one-megabyte prefix signature is an identity hint, not proof of full-file equality. Where a stored supported full-file checksum exists, it is also required to match. There is no new automatic search or guessed replacement.

Preflight requires a confirmed missing old path, a readable regular candidate with the same extension/size/signature, a stable stat generation before/after reads and immediately before commit, unique signature ownership, and a destination not registered to another photo (including filesystem aliases/hard links). Missing identity, stale mapping, ambiguous owners, unreadable/conflicting candidate XMP, unsupported edit versions, unresolved brush references and unsafe durable sidecar debt are refused without changing mappings. Unknown pending-record fields/bits and malformed records are preserved, rather than rewritten through an older schema.

A single catalog transaction changes the existing photo ID's folder/relative filename/stat token, migrates compatible sidecar debt, and invalidates source-derived cache rows. SQL exceptions roll those changes back, including a newly registered folder. Working/version edit rows, history, album/keyword associations and blob references remain on that same ID. No original or sidecar filesystem write occurs inside this transaction; rollback does not claim to cover external writes.

The service owes a portable copy beside the relinked original even if the former sidecar had already settled. That debt is stored before the mapping commits, then reconstructed/enqueued after commit through existing conservative sidecar writing. Existing source-side XMP is untouched. Write refusal remains durable and retries. Later queued edits carrying the former URL follow the stable photo ID to the new sidecar.

After success only, AppState migrates the live recipe/selection/undo URL joins, preserves the latest live culling values, updates the preview photo-ID join, and invalidates renderer/matte/mask source state. Database-derived URLs and scanned URLs can spell `/var` and `/private/var` differently: tests exposed this real join problem, and migration now uses stable photo IDs plus filesystem identity, refusing multiple competing alias entries.

## Validation

Final native debug SwiftPM targeted run: **38 tests passed, 0 failures**, including:

- 8 OriginalRelinkTests: two-photo working/version edits, history, album/keyword/blob continuity and reopen; wrong size/same-size wrong signature; duplicate signature ownership and registered destination; present original/missing or changed candidate; injected SQL rollback of path/folder/token/debt/cache; malformed and unknown-field debt preservation plus compatible keyword-delta migration; full checksum refusal for same prefix/size with different tail; absent identity and stale preflight mapping.
- 6 OriginalRelinkAppTests: production AppState undo/redo, selection, preview join, brush and other-photo continuity; unreadable/conflicting XMP unchanged; pending debt and delayed former-URL edits retry at new path; sidecar appearance after review refused; already settled old sidecar becomes durable owed copy at new path; future edit and missing brush payload refuse before mapping changes.
- Existing AuditPersistenceSafetyTests, HistoryPanelTests and CurveDeletionHistoryTests passed unchanged.

Fixtures were generated small JPEGs, temporary catalogs and synthetic byte files. No GPU readback or RAW qualification is claimed. Log: `/private/tmp/lumen-original-relink-final.log`. `git diff --check` passed. Parent owns integrated suite/build verification; shared snapshot work will require ordinary adjacent-hunk integration only.

## Remaining limits

The common historical catalog contains prefix signatures, not full-file digests; matching those is deliberately described as a hint. Relinking refuses rows that never gained a stored signature. The chooser uses catalog missing/offline rows plus the selected missing photo; other unscanned disappearances require rescanning their folder. This first implementation handles one explicitly selected original at a time. It preserves existing scan reconciliation behavior. Manual review of the native dialogs and real moved/offline media remains necessary later. Cache invalidations are reconstructible; the catalog mapping/debt share the durable main database, while attached cache files retain the application's existing crash-recovery assumptions. No claim of filesystem-wide transactional publication is made.
