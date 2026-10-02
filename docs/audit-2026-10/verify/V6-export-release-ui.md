# V6: export, release pipeline and panel UI (Phase 1 verification)

Verifier: V6. Worktree branch: `worktree-agent-a0184b08471adb304`, based on `a9a1d47` (the session
trunk). The worktree had been created from `main`, which does not contain PR #5, so I reset it to
`a9a1d47` before starting. Build dir: `/tmp/lumen-build-v6`. The full build with tests completed
(`swift build --build-tests`, EXIT 0).

LumenApp and LumenPipeline do not compile on Linux. Every verdict that depends on them is marked
**source-verified only**. For those I read the mechanism and the macOS test, and reasoned about whether
the test would go red with the fix removed. I could not watch those tests go red here.

## Verdicts

| Finding | Commit | Verdict | Evidence |
|---|---|---|---|
| REL-04: final publication overwrites a file created during render | cc30178 | **CONFIRMED (source-verified only)**, with one portability risk (below) | `PipelineRenderer.write` now publishes with `renamex_np(partial, destination, RENAME_EXCL)`. The existence check and the publication happen in one syscall, and the temp file is removed on failure. Replacement needs `allowOverwrite: true`, and no app caller passes it (`RenderCoordinator.export` uses the default `false`). The dynamic test `ExportSoftProofTests.testDestinationCreatedDuringRenderIsNeverOverwritten` writes a sentinel from inside `decode()`, which runs mid-render, and asserts that the export throws, the sentinel is intact and no `.part` file is left. Under the old `replaceItemAt` that test would fail on the sentinel assertion. It is skipped when `KernelLibrary` is unavailable. `AuditExportMetadataTests.testMetadataExportCannotOverwriteExistingDestinationAndLeavesNoPartial` covers a destination that already exists, with no skip. The Linux pins (`SoftProofExportTests`, 8/8 green) strip comments but only match text: `flags = 0` with the token left in place would pass them. The macOS dynamic test is the real guard. |
| REL-10: JPEG written at 72 PPI instead of the requested 240 | d9713fb | **CONFIRMED (source-verified only)** | The requested PPI now overrides the nested TIFF X/YResolution (unit = inches) and the JFIF density (rounded, clamped 1…65535). A source PNG's pHYs is removed. `AuditExportMetadataTests` reopens real JPEG/HEIC/TIFF/PNG files through ImageIO and asserts 240 with EXIF on and off, 300.5 from every source container, unchanged pixel dimensions and identical decoded pixels across PPI values. Without the nested override, the 72 PPI the finding reproduced would show up in those readbacks. |
| REL-11: Contact absent in JPEG/HEIC/TIFF/PNG | d9713fb | **CONFIRMED (source-verified only for the encoder; Linux-verified for the validator)**. DECISION NEEDED on one contract change (below). | Contact is now written as IPTC Core `CreatorContactInfo` `CiEmailWork`/`CiUrlWork` and replaces the inherited contact block. The legacy `IPTCContact` key, which ImageIO drops, is removed. Real readback is asserted for all four formats, for 10-bit HEIC, for "explicit contact replaces the inherited email", and for "nil/blank contact reintroduces nothing". A non-empty contact that is not an email or URL now makes `export()` throw before any render (`validateContact()`). Linux: `ExportContactTests` passed, 5/5. |
| 3d8e25b: contact validation in the export sheet | 3d8e25b | **CONFIRMED** | Red/green on Linux: I reverted the `ExportRecipe.swift` hunk of 3d8e25b (`git apply -R`) and `ExportContactTests` went to **14 failures in `testMalformedAddressCannotBecomeAnEmailOrFallThroughAsAWebsite`** (`name@.`, `name%40…`, `https://.invalid`, …). After restoring the hunk: 5/5 green. Sheet gating: `ExportContactEligibility` looks only at enabled recipes, which is the same `exportRecipes.filter(\.enabled)` that `export(to:)` uses. The only route into `export(to:)` is `chooseExportDestination`, called only from the sheet button, and that button is both disabled and guarded. `ExportMetadataUITests` (macOS) unit-tests the eligibility logic. The wiring assertions are comment-stripped source pins, which is acceptable for SwiftUI. |
| REL-12: test failures do not gate the auto-update release | 6566cdf | **CONFIRMED** for the workflow as it stands. The policy checker was **WEAK-TEST**; I fixed it in `06f1493`. | `publish-release` needs `[app-bundle, build-macos, test-fast, fixtures-linux, engine-linux, release-validation]` with `if: success() && github.ref == 'refs/heads/main'`. Workflow-level permissions are `contents: read`; only the publisher has `write`. No other workflow (`proof`, `gpu-parity`, `raw-corpus`, `ui-layout`) publishes. A red lane blocks publication: `test-fast` and `engine-linux` run `\| tee` under an explicit `shell: bash` (GitHub runs it as `bash -eo pipefail`), and their `exit $status` gives swift test's status. `release-validation` runs a bare `swift test -c release`. The timing assertion in the release gate that EXECUTION-01 called failing (`PlanCostProbeTests`) is now an operation-count test, so the gate is not permanently red. **The September SHA-256 verification is intact.** `AppUpdater.swift` has not been touched since `9f29253`. The digest is parsed as exactly 64 hex characters and fails closed when the line is missing. It is checked against the downloaded bytes before `ditto` unpacks anything. CI still writes `sha256: ${DIGEST}`, and `UpdateDecisionTests.testTheReleaseWorkflowPublishesADigest` pins that. Checker gap: `ruby scripts/check-release-policy.rb` passed with 8 mutations rejected, but **8 further unsafe edits also passed it**: a step-level `if: false` on the test step, a job-level condition on a required lane, dropping `shell: bash` (which turns pipefail off, so `status=$?` becomes tee's 0), `set +o pipefail`, `exit 0`, a run that does not end in `exit $status`, and `\|\| true`. Fixed: against the old rules all 8 new mutations pass; against the new rules all 16 are rejected and the real `ci.yml` passes. |
| UX-02: panel resize accumulates the gesture translation | ad1e7c4 | **WRONG (source-verified only)**. Fixed in `306dfa0`. | The fix anchors the width to the gesture's starting width but leaves `DragGesture(minimumDistance: 0)` in its default **local** coordinate space. The handle (`columnResizer`) sits on the column's left edge, in an HStack before `DevelopPanel().frame(width:)`, and moves left as the column widens. So the local translation equals the pointer's travel minus the handle's own displacement. Anchored, a pointer held 10 pt left produces 410, 400, 410, 400 on successive events. The finding's own recommendation was "capture the starting width **and use a stable coordinate space**", and only the first half landed. `MaskFloatingPanel.swift` already documents this exact feedback loop and fixes it with `.global`. Fix: `coordinateSpace: .global`. Tests added: a replay that shows the oscillation, and a comment-stripped pin on the resizer's gesture. LumenAppTests cannot run here. I checked the pin logic with an equivalent script against the old source (false) and the new source (true). `check-swift-surface.py` exits 0, and `swiftc -parse` on both files exits 0. |
| cc30178: other parts | cc30178 | No regression found in what I reviewed; notes below | Linux: `AuditSafetyTests` passed 6/6. I did not do red/green on the catalog and ingest parts and am leaving those to the catalog/persistence verifier. |

## Notes and risks (not verdict changes)

1. **REL-04 portability (needs a Mac check).** `renamex_np` with `RENAME_EXCL` is only guaranteed on
   volumes that advertise `VOL_CAP_INT_RENAME_EXCL` (APFS, HFS+). On exFAT/FAT SD cards and external
   drives, SMB and NFS, the call may return `ENOTSUP`. The code turns any non-zero result into
   `writeFailed`, so on those volumes **every export could fail**. It used to work there. I could not test this on Linux.
2. **REL-04 failure message.** `errno` is discarded, and the batch status line names only
   `photo → recipe`. A lost race, an unsupported volume and a refused contact all read the same. For
   contact the sheet prevents it; for the other two the photographer gets no reason.
3. **REL-11 contract change: DECISION NEEDED.** A saved preset whose Contact is prose (for example
   "Jane Doe, +1 555…") used to export with the contact silently dropped. Now the sheet blocks the whole
   batch and the renderer refuses until the field is edited or the recipe is unchecked. That matches
   the ledger's stated limitation ("unsupported nonempty prose fails explicitly"). The owner should confirm
   this is the intended contract, as opposed to writing prose into another IPTC field.
4. **REL-12, residual.** Monotonicity of the feed still relies on `concurrency: cancel-in-progress` per
   ref plus a date comparison in the updater. A manual "re-run jobs" on an old main run would publish an
   older commit as `dev-latest`, and installed copies newer than it by publish date would not be
   protected. A cancel that lands between `gh release delete` and `gh release create` leaves no release.
   That is fail-safe, because the updater reports and installs nothing.
5. **cc30178, other parts I checked:**
   - `AppState` common-ancestor: the `for … where a == b` loop kept matching after the first difference, and the fix replaces it with a break. That is a real fix.
   - Undo and redo now end the slider gesture first.
   - The backup now copies blobs before it publishes the `.db`, and the name has a UUID suffix. `BackupRetention.timestamp` takes the first 6 digit runs, so UUID suffixes still date correctly.
   - The integrity probe opens read-only and separates corrupt from unavailable (`code & 0xff` handles the extended result codes).
   - `close()` now flushes inside `queue.sync`. `flushSidecars` only uses `queue.async` and `onFailure` hops to the main actor through a `Task`, so I found no re-entrancy deadlock. A sidecar write that fails during quit is re-queued after `sidecarsClosed` and never retried. The catalog keeps the edit, but the status message cannot be seen after quit. This is minor.
   - `VerifiedCopy` now refuses `alreadyPresent` when the source digest's byte count differs from the planned copy.

## Phase 2 specs

**REL-12 (policy checker).** Done in `06f1493`; nothing open. Optional extension: run
`check-release-policy.rb` over every file in `.github/workflows/`, not only `ci.yml`, so that a new
workflow with `contents: write` or a `gh release` step is rejected as well.

**UX-02.** Done in `306dfa0`, but native confirmation is outstanding. Acceptance: on macOS, run
`AuditPanelResizeTests` (4 tests green). Then, in the running app, drag the develop divider 100 pt left
slowly and quickly. The edge must stay under the pointer with no jitter, and releasing must persist the
width that was shown.

**REL-04 portability (new; only if the Mac check confirms `ENOTSUP`).** Files:
`Sources/LumenPipeline/PipelineRenderer.swift` `write(...)`. Trigger: export to an exFAT-formatted
volume, or check `getattrlist` `VOL_CAP_INT_RENAME_EXCL` on it. Fix shape: on `errno == ENOTSUP` or
`EINVAL`, fall back to an exclusive claim that preserves the no-overwrite guarantee, for example
`link(partial, destination)` (`EEXIST` is atomic) where hard links exist, otherwise
`open(destination, O_CREAT|O_EXCL)` followed by a non-exclusive rename over the claimed empty file. Also
surface `EEXIST` as a distinct error that the batch can name. Acceptance: a LumenPipelineTests case
against a disk image formatted ExFAT (`hdiutil create -fs ExFAT`) exports successfully, and repeats the
existing sentinel-race test on that volume.

## Local commits (not pushed)

- `06f1493` The release policy accepted a test lane that cannot fail
- `306dfa0` The develop column resize was anchored but still measured in the moving handle's space

No proof-registry pixels are affected; neither commit touches rendering.

Branch: `worktree-agent-a0184b08471adb304`
