# P1-ingest: ingest identity and honesty

Agent: P1-ingest. Base: `cc4cdd7` (`origin/claude/jolly-sagan-k7ch7z`). Branch: `worktree-agent-a093dc4d7c173432e`.
Build dir: `/tmp/lumen-build-p1`. Inputs: `docs/audit-2026-10/verify/V1-ingest-catalog.md` and `docs/audits/2026-09-22-astra/SUPPLEMENTAL-BACKLOG.md` (S-01 to S-04).

Final state:
- `IngestAdversarialTests` 25/25 on Linux. All 12 cases that used to `return` early on Linux now run there, and **no `XCTExpectFailure` remains** in the file.
- `IngestCopyTests` 13/13 and `AuditSafetyTests` 9/9.
- `swift build --build-tests` is clean.
- `python3 scripts/check-swift-surface.py` exits 0.

Each red count below comes from substituting the fix out in the worktree, rebuilding, running the suite, and restoring.

## Items

| Item | Status | Commit | Red with the fix substituted out | Proof records that move |
|---|---|---|---|---|
| S-02 aliased backup root (P1) | FIXED | `bd06854` | Alias refusal off: 4 failures. Identity replaced by a path-string compare: 6 failures across 2 tests. | none |
| S-01 identical twins under one name (P1) | FIXED | `f1877b2` | Engine claim check off: 6 failures across 2 tests. Report gate off: 2 failures. | none |
| S-03 byte/progress/summary accounting (P2) | FIXED (progress contract decided by default, see D2) | `68375e3` | Old accounting substituted back: 11 failures across 8 tests. | none |
| S-04 renamed re-ingest idempotence (P2) | FIXED | `7ebe635` | Walk limited to the planned name: 10 failures across 3 tests. Claims ignored in the walk: 11 failures across 3 tests. | none |
| REL-05 weak test | FIXED (source-verified, macOS lane) | `80ad84b` | Traced by hand: old code gives 0 classifications instead of 400. V1's per-query substitution gives about 160 000. | none |
| Linux early-returns and XCTExpectFailure | FIXED | spread over the four ingest commits | Not applicable | none |

### S-02 — `bd06854`
- **New identity helper.** `IngestLocation.directoryIdentity` (in `IngestPlan.swift`) identifies a folder by the device and inode of its nearest existing ancestor after resolving symlinks, plus any trailing components that do not exist yet.
- **Engine check.** For each frame, `VerifiedCopyDriver.perform` refuses a destination whose folder has the same identity as one already written for that frame. That destination fails with `.failed(.aliasedDestination(of:))`, nothing is written there, and `allVerified` is false.
- **Sheet check.** The sheet's start-time refusal (`IngestSheet.swift`) now uses the same identity instead of comparing `standardizedFileURL`. This hunk is source-verified only.
- **What it does not prove.** The doc comment says so explicitly: two distinct directories may still be on one disk or one share. Nothing in this change certifies that copies are physically independent.

### S-01 — `f1877b2`
Two guards, each tested on its own:
1. **Run-wide claim map in the engine.** It maps each destination file's identity to the source that landed or proved it. A file this run already used for another frame is never treated as "already present" for a different frame. That frame lands at the next free disambiguated name, and nothing is overwritten.
2. **Report-level gate.** `IngestReport.allVerified` now also requires `!twoFramesShareOneFile`, compared by directory identity. When the gate trips, the summary says so.

### S-03 — `68375e3`
- **Byte counting.** `bytesCopied` only counts frames that landed on at least one destination.
- **New progress fields.** Progress gains `bytesProcessed` (what the bar fills by) and `filesFailed`.
- **New report fields.** The report gains `framesVerified` and `framesLanded`.
  - "Ingested N of M" counts `framesVerified`.
  - `allVerified` requires `framesVerified == filesPlanned`. This also closes a gap V1 did not list: a frame with no destination next to a good frame used to allow eject.
- **Summary wording.**
  - A cancelled run names the failures that happened before the stop.
  - A frame with no destination is reported as "had nowhere to go".
  - When verification is off, the summary says "k copied without verification".
- **Shrink-test oracle.** The `-1` sentinel is gone. The test now asserts: no file landed, `bytesCopied == 0`, and the failure is `shortRead(5000, 100)`.
- **Sheet caption.** The caption shows `bytesProcessed` plus "· N failed". Source-verified only.

### S-04 — `7ebe635`
- **Chain walk.** The collision branch walks the disambiguation chain (`name`, `name-1`, …) and stops at the first slot that is free or holds this frame.
- **What "holds this frame" means.** The slot is not claimed by another frame in this run, has the same size as the source, and has the same digest as the source.
- **Cost.** A stranger's file costs one stat. A full hash runs only for a candidate of the same size.
- **REL-03 still holds.** The REL-03 short-read guard is kept, and `AuditSafetyTests` stays green.
- **Rename count.** `renamed` no longer counts a frame found already present under an earlier run's disambiguated name.
- **Twin re-ingest test.** The new `testReIngestOfDisambiguatedTwinsFindsEachTwinsOwnFile` checks that twins split into `wedding` / `wedding-1` find their own files again.

### REL-05 — `80ad84b`
- **Counter on the production path.** The classifier used by `CatalogService.rawSiblings(of:)` now increments a counter under `siblingLock`. `forgetSiblings()` resets it, and tests read it via `siblingClassificationCount`.
- **New test.** `testProductionSiblingPathClassifiesEachListedNameOnce` uses N = 400: it calls `registerAndLoad`, then `sidecarURL(for:)` on every file, and asserts exactly 400 classifications.
- **Verification.** LumenApp tests do not compile on Linux, so this is source-verified and will run on the macOS lane.

## DECISIONS (conservative default implemented; the owner may overrule)

- **D1. S-01: disambiguate rather than refuse.** The second identical twin lands as `wedding-1.RAF`, using the same policy already used for a stranger's file, and is verified. Because both frames are then honestly on the volume, `testATwinFrameThatWasAbsorbedDoesNotUnlockEject` no longer asserts `allVerified == false`. It now asserts the pairing instead: two sources, two distinct proven files, and eject offered exactly when both exist. The "two frames on one file never unlocks eject" contract moved to the new report-level test `testAReportWhereTwoFramesStandOnOneFileDoesNotUnlockEject`. If you would rather refuse twins outright, change the claim branch to fail the frame.
- **D2. Progress bar on a failed run (V1 flagged this as DECISION NEEDED).** I used the default the task gave: the bar fills to 1.0 when the run has dealt with every frame, and success is not the bar's to claim. Failures are named in `progress.filesFailed`, the sheet caption ("· N failed") and the summary. Accordingly, the progress test's `fraction < 1.0` assertion was replaced by:
  - `fraction == 1.0`
  - `bytesProcessed == 10000`
  - `filesFailed == 1`
  - `bytesCopied == bytes on disk (400)`
  - the summary names `PRG00002.RAF → primary`
- **D3. Wording of the new summary text.** All of these are owner-editable strings:
  - "Before the stop, …"
  - "… had nowhere to go"
  - "· k copied without verification"
  - "· two different frames point at one file on the destination"
  - the alias sentence: "is the same folder as the primary destination, so it would not be a second copy — nothing was written there"
- **D4. S-04 identity across runs.** Within one run, the claim map stops two different frames from sharing a file. Across runs, a frame is recognised by its rendered-name chain plus identical size and digest. So if one run ingests only frame A, a later run ingesting a *different* frame B with byte-identical content that renders to the same name will treat B as already present. Telling these apart would need a persisted source identity (an xattr or a manifest at the destination), which is a format decision.
- **D5. Public API additions.** All new parameters have defaults, so existing callers compile unchanged:
  - `IngestCopyFailure.aliasedDestination(of:)`
  - `IngestProgress.bytesProcessed` and `filesFailed`
  - `IngestReport.framesVerified`, `framesLanded` and `twoFramesShareOneFile`
  - `IngestLocation`

## FOUND-WHILE-FIXING

- **Surface-checker false positive.** `check-swift-surface.py` ("values" pass) misreads an optional tuple named `found` when the same function also declares `let found: IngestDigest`. It reported `found.url` / `found.digest` as missing members. I renamed the tuple to `earlierCopy` / `earlierDigest`; the checker itself was not changed.
- **Weak cancel-test assertion.** `testACancelledRunStillNamesTheDestinationThatFailed` used to accept `contains("failed") || contains("backup")`. It now requires both "failed" and the `STOP0001.RAF → backup` label.
- **Possible empty-folder open (not changed).** `IngestSheet` still opens the primary folder whenever `filesAttempted > 0`. If every frame fails, it opens a folder with nothing new in it. The status line names the failure, so I left it alone.
- **Case-insensitive name collisions (not addressed).** `IngestLocation` does not normalise case, so on a case-insensitive volume `A.RAF` and `a.raf` are one file but different identities. This does not matter for roots (the rendered names are identical across roots). It is an edge case for claims.
- **No proof records move.** Nothing here touches rendering.
