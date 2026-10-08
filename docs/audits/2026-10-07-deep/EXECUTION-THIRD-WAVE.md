# Autonomous third wave — implementation and qualification

Base: `c4923aa4b9b1948457d69ddd4d5d1d90bc7e34f7`. Integration branch: `codex/lumen-third-wave`.

## Per-photo snapshots

Integrated app-agent source commit `32935a5a6269ec9498ef4ee83cdfad43f0b7ccf3` as `34311af`. Named snapshots are immutable non-current catalog edit rows; saving does not replace the working edit. Restore validates recipe version and referenced painting/LUT dependencies, checks selection and intervening edits, and enters ordinary undo and sidecar persistence. Delete affects the scoped snapshot only. Existing backup includes snapshot-only painting dependencies. Agent expanded verification: 106 tests, plus 20 final focused tests. Complete combined qualification is recorded at the end of this report.

## Generated large-library performance

The opt-in `GeneratedWorkflowCostTests` creates independent 16×12 PNGs and isolated catalogs/previews. It measures app bookkeeping on the main actor, not display latency or RAW decoding. It checks the original first/last image bytes after work and restores remembered-folder defaults. Baseline source: `c4923aa`.

| Probe | 5,000 photographs | 20,000 photographs |
|---|---:|---:|
| Open/scan | 3,541 ms | 8,625 ms |
| Cold photo order, p50 / p95 | 12.57 / 14.21 ms | 32.40 / 36.54 ms |
| Selection/navigation bookkeeping, p50 / p95 / p99 | 4.53 / 8.90 / 14.52 ms | 23.57 / 44.84 / 51.27 ms |
| Single-photo exposure drag, p50 / p95 / p99 | 0.027 / 0.029 / 0.039 ms | 0.031 / 0.032 / 0.041 ms |
| Forty-photo exposure drag, p50 / p95 / p99 | 0.682 / 0.739 / 0.795 ms | 0.790 / 0.951 / 0.964 ms |

Single-photo release costs were 3.02 and 16.61 ms. These timings are one local run, not portable performance guarantees. Resident memory increased from 55.8 to 160.8 MB for 5k and 128.4 to 489.8 MB for 20k; two readings do not establish a leak or bounded residency. RSS includes process-wide framework caches and scan work.

Each changed selection previously scanned all `allPhotos` using URL membership, including the selection-frame refresh. A source-order position index handles sparse selections; dense selections and duplicate IDs retain the original lossless scan. Only replacement/mutation of `allPhotos` invalidates the index, while selected-value caches retain existing invalidation. Core index tests and the opt-in probe passed (4 tests). Three actual AppState regressions independently passed for sort/filter source order, sparse/dense unknown IDs, rating plus undo/redo freshness, and same-size folder replacement. Their test-only commit is integrated as `9a4d58d`.

Indexed source `34311af` plus the pending index changes (subsequently committed `5a57ca9`) measured 20k navigation p50/p95/p99 **0.079 / 0.152 / 0.770 ms**, and 5k **0.077 / 0.121 / 0.195 ms**. The earlier baseline predates snapshots, so this is not a strictly identical-source comparison apart from the index. The measured improvement is consistent with removing the per-selection linear membership scan; it does not measure actual displayed-frame latency. The remaining cold sort, scan, release and RSS costs are not claimed fixed. The indexed 20k run had 9,151 ms opening, 41.63 ms median cold order, 22.55 ms single-photo release, and 541.1 MB ending RSS.

## Missing-original relinking and proof portability

Relink agent commit `25b9fdb` integrated as `d9527ce`; 38 isolated tests passed including 8 core and 6 production AppState tests plus adjacent persistence/history coverage. Snapshot and relink service extensions were both retained when resolving their insertion conflict. Combined optimized workflow tests on `d9527ce` passed: 25 tests, 0 failures (snapshot, relink, core index and actual selection workflows). The subsequent proof correction is documented below. No release or installation has occurred.

## Connected generated-shoot lifecycle

Test-only agent commit `9e767c3` integrated as `c46d780`. Two generated 48×32 PNGs pass the actual verified primary/backup copy driver, open in AppState, acquire distinct culling values, gesture edits, brush/clone/painted-heal/LUT references, and a named snapshot. Actual export succeeds, quit backup carries all three dependency payloads, then a reconstructed AppState loads catalog/culling/recipe/sidecar/report/snapshot state and exports the same pixels. Original and four landed image bytes remain unchanged; decoded export pixels match exactly. Isolated native test passed in 1.876 s. This exercises same-process AppState reconstruction, not a new OS process or real card/RAW/display. Complete combined qualification is recorded at the end of this report.

## Parametric curve limiter caption

A read-only caption now uses the actual shared bake multiplier, without a separate limiter estimate. Before refactoring, ten original Darwin release LUTs were fingerprinted across all 1024 samples each. Identity, ordinary amounts, conflicting extremes, compressed/end/reordered/missing splits, and out-of-range amounts are represented. The compatibility test checks those original bytes; portable tests check the quiet 100% threshold, invalid-value refusal, and real conflicting curve reporting. Verified on combined 20-test optimized run: 0 failures. All ten pre-refactor Darwin LUT fingerprints match exactly (10,240 sampled doubles). The shared calculation changes no math expressions; only its existing scale is returned with the LUT and displayed. Committed as `ec7c87b`.

## Proof numerical correction under qualification

The independent 90-digit atan2 oracle selects Float bits 1061935361 for the actual patch-2 chroma inputs. Darwin atan2f returns those bits; Linux atan2f returns 1061935362. All earlier chart/tone/LMS/pow/Newton/Lab inputs are bit-identical. An isolated one-input interposer reproduces all three Linux records exactly on Darwin, demonstrating the causal path. A one-call production change computes this LCh angle in Double and rounds once to Float before unchanged degree conversion; the mixer blend call remains untouched. Linux/macOS hosted run 37704880594 independently confirms common bits 1061935361.

Root integrated diagnostic commits `78f4c35`, `31dcf5f` and production correction `f225269`. Existing CPU/GPU parity gates passed in agent optimized/debug runs and independent narrow scratch rendering. Across all 144 Darwin controls, 143 records are bit-identical; color.density mean changes 4.196e-7, below the unchanged 1e-6 metric tolerance. Hosted patched full 144 run 37706173885 completed on both platforms. The three corrected control records match exactly; all other platform differences are below 1e-6. Only three records/four fields were updated in `3471047`. Original optimized ControlProofTests passed all six including the complete 144 sweep. No tolerance changed; 141 records remain untouched. Root combined 20-test run passes exact-color oracle/axes tests, curve byte compatibility, generated lifecycle and core relink tests.

## Filesystem failure reporting and delivery boundaries

Integrated `65ea10e` as `6c2a751`: failed readback cleanup no longer claims deletion when removing the unusable final copy fails. Seven causal assertions failed before the change; 38 core and 21 native app tests passed afterward. Source bytes remain unchanged, retained bad files do not count as verified and do not permit eject, and report details omit digest bytes. Successful cleanup retains existing mismatch/unreadable categories. Actual AppState export cancellation after first delivery yields delivered/notAttempted/notAttempted; blocked output subfolder yields failed/delivered, preserving the existing sentinel. Durable reports reload exactly and no staging files remain.

A further destination-replacement race was reproduced: an injected readback replaces the landed file with unrelated bytes; old cleanup deletes the replacement, and a matching digest from the old bytes can falsely certify it. Device/inode ownership and generation checks integrated as `b5586a2`; 45 focused tests pass, including matching-digest replacement, same-inode mutation and symlink controls. Root also preserves signed device-number identity without a trapping integer conversion. Filesystem path preflight cannot promise a conditional atomic unlink against arbitrary concurrent changes; that limitation stays explicit. These add PS-11/PS-12 to the original 84-item backlog rather than retroactively calling existing feature projects defects. Actual ENOSPC/disconnect/removable-volume and physical eject qualification remain external gates.

## Final integration review

Review caught a relink completion arriving after a new slider gesture started. URL replacement previously removed the old catalog-ID join before selection-change flush, losing the latest durable recipe. A real catalog commit/completion split reproduced the missing catalog/XMP edit. Integrated `0ef2dfc` flushes first, while the old join remains available; 15 adjacent tests and 7 final relink regressions pass, including latest recipe, undo/redo and no orphan old sidecar.

Smart scopes integrated `4d5b82e` and review repair `f7ec1d6`. An explicit deleted-album tombstone preserves the source reference/query without allowing reused SQLite ROWIDs to redirect it. Acquisition rereads catalog truth after a source revision changes, rejecting stale paths and respecting photos moved outside a subtree. Both cases were red before repair; 52 isolated native tests pass. Complete combined optimized suite and source checker passed at `351a6ac`, with final header compatibility follow-up recorded below. Forty-one checker fixtures pass, including raw XML and typed loop positive/negative controls.

## Final qualification follow-up

The first complete run exposed a stale comparator negative-control fixture: its fixed “drifted” value now equaled the deliberately corrected ruler. The comparator correctly reported zero differences, then the test indexed the empty array. The fixture now applies an explicit above-tolerance offset relative to the current record and safely unwraps the difference. All four comparator tests pass; the complete optimized suite subsequently passed. This was a test fixture failure, not a rendering regression.

The source checker now distinguishes declared enum cases from initializer switch patterns and recognizes inline defaults. Added positive and negative fixtures retain missing-case detection; all 41 fixtures pass. The hosted Swift 6.1.2 compiler also found a type-check complexity limit in the library header; an equivalent expression decomposition is under qualification.

The combined optimized run at `351a6ac` passed **3,228 tests: 3,205 passes, 23 intentional skips, zero failures**, including the original full control proof. The additional skip is the opt-in generated-library benchmark; the three existing narrow layout expected-failure annotations are retained. All-source surface checks exited zero; all 41 checker fixtures pass. `a9029e3` integrates the equivalent header expression decomposition; all 53 native layout/library tests passed again on the root integrated source; hosted Swift 6.1.2 build/layout/GPU qualification passed. No tolerance or production look changed in this follow-up.

Final source `a9029e3` passed hosted Swift 6.1.2 whole-package build, app-bundle generation, Linux fixtures and portable-engine tests. GPU run [37709638957](https://github.com/benedek-art/lumen/actions/runs/37709638957) passed 216 tests with 17 declared skips and no failures; layout run [37709638958](https://github.com/benedek-art/lumen/actions/runs/37709638958) passed 19 tests with no failures. Root all-source checks also exited zero on this final source. The later optimized full proof sweep passed; the subsequent complete optimized Mac CI passed before merge, as recorded below.

## Proof-lane execution cost

`4a56a27` changes only proof workflow configuration and its numerical evidence README. Push/nightly full proof sweeps now use the release optimizer; a manual dispatch can explicitly choose debug. Every registered control, 21-setting sweep, comparison tolerance and opt-in record-writing guard remains unchanged. The prior workflow documents 66–80 minute debug runs; the measured local optimized full suite and hosted optimized registry artifacts justify exercising shipping arithmetic without shrinking coverage. Actual hosted runtime is recorded after completion, not promised from the local measurement.

Release safety policy passed with 31 unsafe mutations rejected. Four isolated shell probes verified release/debug invocation, Swift failure propagation and invalid-configuration refusal. Git tree identities in `qualification-source-identity.json` demonstrate all Sources, Tests, scripts and Package.swift are unchanged from qualified `a9029e3`; core/pipeline/tests/scripts/package are also unchanged from the full-suite `351a6ac`. The only app-source difference from that complete run is the independently qualified header decomposition.

`8ee85b8` upgrades the existing Mac `test-fast` job to the **complete** `swift test -c release` suite, removing all slow-test selection filters. The legacy job name, 35-minute timeout, bash pipefail/status propagation, release policy and every other job remain unchanged. Independent debug Linux and GPU checks remain. Release policy again rejected all 31 unsafe mutations; all 18 bash steps parsed, and success/failure probes preserved exit statuses and summary logging. Hosted qualification passed before consolidation. Application/engine/pipeline/tests/scripts/package tree identities are unchanged from `4a56a27` and `a9029e3`.

The complete optimized Linux proof run [37710960640](https://github.com/benedek-art/lumen/actions/runs/37710960640) passed all six original tests with zero failures. The actual hosted job ran **9m40s** including setup/build, versus the previous documented 66–80 minute debug lane; this is one measured run, not a runtime guarantee. Its log reports release configuration and the committed-record comparison passes. All 144 controls and the `1e-6` ruler remain in place. The complete Mac optimized suite at `8ee85b8` subsequently passed, as recorded below.

## Final hosted qualification and publication

CI [37711580182](https://github.com/benedek-art/lumen/actions/runs/37711580182) at `8ee85b8` passed **the complete 3,228-test optimized Mac suite: 3,205 passes, 23 declared skips, zero failures**. The actual Mac job took 15m58s including compilation, within the unchanged 35-minute limit. All slow-test filters were removed. Linux completed 2,600 selected core tests successfully; this selection count includes declared opt-in skips and is not presented as a pass count. Build, app bundle and fixtures passed. Latest layout passed 19 tests; the independent debug GPU lane passed 216 with 17 declared skips; the complete optimized proof passed all six original tests. These lanes overlap and are not summed. Three existing narrowly matched slider precision-floor expected failures remain explicit.

[PR #9](https://github.com/benedek-art/lumen/pull/9) merged onto `main` as `9c6d78f828fada3a1dd5977eff1041be7d34304f`. All source, test, script and package tree identities on the merge match the verified integration source. Final documentation is updated on main without changing those qualified trees. No private RAWs, user catalog, installed app or updater release was modified. The confirmed-defect repair wave is complete; future feature/product and native/camera/volume qualification remain in the master plan.
