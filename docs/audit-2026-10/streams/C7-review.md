# C7-review: three review-bot findings on PR #6 (reviewed at 17665d9)

Each finding was checked against the code before any fix. All three are real.

| # | Finding | Status | Commit | Red (fix removed) | Green | Proof records |
|---|---------|--------|--------|-------------------|-------|---------------|
| 1 | P1: backup recovery ignores creative-LUT blobs | FIXED | 629b962 | AuditSafetyTests: 3 tests, 4 failures | 14/14 | none |
| 2 | P2: O_EXCL fallback leaves a zero-byte claim after a crash | FIXED | 69c1327 | ExclusivePublishTests: 2 tests, 4 failures (+2 with the run-start clause disabled) | 12/12 (+ ExportCollisionTests 6/6) | none |
| 3 | P2: two pending `.expand` opens share one scan generation | FIXED | a350205 | SourceOpeningTests: 2 tests, 3 failures | 18/18 | none |

## 1. LUT blobs in the recovery integrity pass (verified real)
`CatalogStore.prepareBackupPayloads` collected only keys named `strokesRef`. `look.lut.ref`
blobs, which live in the same BlobStore, were never checked or repaired. The bulk
`BlobStore.restore` never overwrites, so a damaged live cube also survived it.
`CreativeLUTStage` then returned nil without an error. The pass now also collects
`lut.ref` when it is a blob address and treats it exactly like a stroke payload: it hashes
the live copy, repairs it from the backup, keeps the damaged bytes aside, and otherwise
skips that snapshot. Heal strokes (`develop.heal.strokesRef`) were already covered by the
recursive key match. A new test pins that, and it passes both with and without the fix,
as expected. The tests use a real catalog and BlobStore on Linux.

## 2. Abandoned O_EXCL claim (verified real)
On a volume with no RENAME_EXCL and no hard links, the final name has to be claimed empty
before the fill. No other operation there refuses an existing name, so the claim cannot
be avoided. `ExclusivePublish.reclaimAbandonedClaim(at:olderThan:)` removes a claim only
when all of these hold:
- it is a regular file of zero bytes;
- its `.<name>.….part` partial is still beside it;
- its mtime is before the run's start.

The batch (`AppStateActions`) calls it on each wanted name before `ExportRecipe.placement`.
That wiring is source-verified and pinned. The test reproduces the crash with injected
ENOTSUP/EPERM and a "dying" rename/unlink, then shows that Skip now places a write and the
next FAT-like publish delivers the photo.

## 3. Expansion generation (verified real)
`ExpansionRequests` (LumenCore, in SourceOpening.swift) issues a ticket when each request
starts. A walk opens only if it is the latest expansion and no folder open has advanced
`scanGeneration` since. An expansion does not advance `scanGeneration` itself, so a walk
that finds nothing cannot strand a folder scan that is already in flight. The AppState
wiring is source-verified and pinned.

## Checks
`swift build --build-tests` clean. `check-swift-surface.py` exits 0. One test-side
issue came up on the way: a `"Task {"` string literal unbalanced the scanner's brace
count. It was rewritten without a brace. `recite-slider-inventory.py HEAD~3 --write`:
0 citations moved.

## DECISIONS
- Finding 2: a zero-byte file is reclaimed only when its Lumen partial is still beside it.
  A zero-byte file with no partial, for example after someone cleaned out hidden files,
  is still treated as a file that exists, so nothing a user made is ever removed. The
  owner can loosen this to "any zero-byte file older than the run".

## FOUND-WHILE-FIXING
- After a crash in the claim window, the stale partial (`.<name>.lumen-XXXX.part`, which
  holds a complete render) is left in the export folder. Reclaiming the claim does not
  remove it. It is harmless but it is hidden clutter. A later cleanup could delete
  partials older than the run.
- BlobStore.restore's bulk copy still never verifies hashes. That is safe only because
  `prepareBackupPayloads` runs first for every referenced payload. Unreferenced blobs are
  copied unchecked, which is harmless.
