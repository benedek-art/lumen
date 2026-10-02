# Verified repairs — execution record 01

22 September 2026. Baseline: `a6e694103a3676e059847ac48b82c0031281ea53`; isolated branch `codex/lumen-verified-repairs`. This is an implementation record, not a revision of the historical audit.

## Changes under verification

| IDs | Change | Executed evidence |
|---|---|---|
| UX-01 | End pending gesture persistence before undo/redo restoration | Actual AppState, temporary photo/catalog, release, quit, reopened catalog and XMP agree; open/closed gesture and redo controls |
| BR-01 | Stop common-parent comparison at first mismatch | Repeated sibling folder names and identical basenames now retain two catalog IDs |
| BR-02 | Partial registration does not reconcile unseen files as missing | Actual subset open retains both present catalog rows; subsequent full scan still detects physical deletion |
| REL-01 | Tri-state read-only integrity probe distinguishes corruption from unavailability | Real exclusive SQLite lock with stale backup retains current rating; nonexistent probe cannot manufacture a backup; extended result-code classification |
| REL-03 | Already-present ingest checks planned byte count as well as matching digests | Identical truncated files fail verification without removing the existing destination; adjacent ingest tests |
| REL-04 | Atomic exclusive export publication; replacement explicitly opt-in | Real GPU export creates a competing delivery during decode; it remains byte-identical and export fails; explicit replacement succeeds and leaves no partial |
| REL-08 | Copy blobs before publishing database; unique snapshot names | Injected unreadable blob prevents any eligible database publication; successful snapshot restores actual brush payload and reference; pixel restoration check added |
| REL-09 | Report once per sidecar outage, retaining retries and newest edits | Write-blocking directory, repeated failures, unblock/retry with newer exposure, second outage; full suite then revealed post-close retry lifecycle defect, now under test |
| REL-12 | Separate app artifact from updater publication; main plus successful prerequisites only | YAML-parsed offline policy check fails on old workflow; passing policy rejects seven unsafe mutations. Complete optimized suite is a release prerequisite |

## Runs

All Swift commands use `swift test --package-path work/lumen --scratch-path /private/tmp/lumen-verified-repairs-build-20260922 --build-system native -c release` from the task directory. Scratch builds are outside the real library. macOS 27 / Apple M4 / Swift 6.4, same environment as audit.

1. First batch, filter `AuditSafetyTests|AuditStateSafetyTests`: corrected red run **8 tests, 10 assertion failures**. An initial test mistakenly queried missing rows as well as present ones; it was corrected and the failure rerun before changing production code.
2. First green plus adjacent tests, filter `AuditSafetyTests|AuditStateSafetyTests|CatalogTests|IngestCopyTests|BackupPolicyTests|DragBroadcastTests|HistoryPanelTests`: **118 tests, 0 failures**.
3. Delivery red, filter `AuditPersistenceSafetyTests|ExportSoftProofTests/testDestinationCreatedDuringRender`: **3 tests, 6 assertion failures**. A test closure compile error was corrected before this executed red run; compile failure is not counted as a reproduced bug.
4. Delivery green plus adjacent tests, filter `AuditPersistenceSafetyTests|ExportSoftProofTests|ExportCancelAdversarialTests|BackupPolicyTests|BlobStoreTests`: **41 tests, 0 failures**.
5. Expanded combined run: **165 tests, 1 failure**, an older source-structure test still requiring `FileManager.moveItem`. Updated to require the actual atomic `renamex_np` publication; behavioral competing-file test remains mandatory.
6. `ruby work/lumen/scripts/check-release-policy.rb`: old workflow rejected; updated workflow passes; **7 unsafe mutations rejected**. This is offline configuration verification, not hosted CI execution.
7. Complete optimized suite: **2,413 tests, 14 skipped, 2 failures**, 157.2 seconds wall time. One failure was the previously known draft/settle timing ratio. The other was a test intentionally exporting twice to one path; its second call now explicitly opts into replacement. No pixel assertion was removed. The run also exposed failed sidecar callbacks surviving `close()`.
8. Post-close writer regression: **1 test, 1 failure** before the lifecycle fix. Sidecar flushing now closes on the catalog queue, deferred callbacks do not revive closed writers, and callbacks capture the service weakly.
9. Expanded safety batch after these fixes: **167 tests, 0 failures**, including 64×64 brush-raster restoration, explicit overwrite, release-body digest contract and the close/retry negative control.
10. Complete optimized rerun: **2,414 tests, 14 skipped, 1 failing test (2 assertion failures)**, 143.4 seconds wall time. Both assertions are in the pre-existing `PlanCostProbeTests.testATableRekeyingDragDoesNotPayTheBakePerFrame`: whites draft 2.842 ms versus a 2.113 ms bound; saturation draft 1.455 ms versus a 1.215 ms bound. No other test failed. The performance issue remains tracked, not hidden behind a skip or a relaxed threshold. Skips remain visible; this is not a real-photo corpus or native UI certification.

Full logs remain local under `work/repairs/`, not published with machine-specific paths. No tolerances or image goldens were relaxed. No original photos, sidecars or live catalog were used. No installed app, main branch or release changed.

## Outstanding verification

The safety phase is **not complete**. Sidecar ownership transitions (REL-02), expanded multi-photo/album checks, backup interruption/legacy validation, native error display/quit and hosted CI still need completion. Subsequent RAW, colour, mask, creative, performance and accessibility phases remain in the plan; passing these tests is not a percentage-complete claim.
