# Autonomous third wave — work in progress

Base: `c4923aa4b9b1948457d69ddd4d5d1d90bc7e34f7`. Integration branch: `codex/lumen-third-wave`.

## Per-photo snapshots

Integrated app-agent source commit `32935a5a6269ec9498ef4ee83cdfad43f0b7ccf3` as `34311af`. Named snapshots are immutable non-current catalog edit rows; saving does not replace the working edit. Restore validates recipe version and referenced painting/LUT dependencies, checks selection and intervening edits, and enters ordinary undo and sidecar persistence. Delete affects the scoped snapshot only. Existing backup includes snapshot-only painting dependencies. Agent expanded verification: 106 tests, plus 20 final focused tests. Combined qualification pending.

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

Each changed selection previously scanned all `allPhotos` using URL membership, including the selection-frame refresh. A source-order position index is being verified for sparse selections; dense selections and duplicate IDs retain the original lossless scan. Only replacement/mutation of `allPhotos` invalidates the index, while selected-value caches retain existing invalidation. Core index tests and the opt-in probe passed (4 tests). Three actual AppState regressions independently passed for sort/filter source order, sparse/dense unknown IDs, rating plus undo/redo freshness, and same-size folder replacement. Their test-only commit is integrated as `9a4d58d`.

Indexed source `34311af` plus the pending index changes (subsequently committed `5a57ca9`) measured 20k navigation p50/p95/p99 **0.079 / 0.152 / 0.770 ms**, and 5k **0.077 / 0.121 / 0.195 ms**. The earlier baseline predates snapshots, so this is not a strictly identical-source comparison apart from the index. The measured improvement is consistent with removing the per-selection linear membership scan; it does not measure actual displayed-frame latency. The remaining cold sort, scan, release and RSS costs are not claimed fixed. The indexed 20k run had 9,151 ms opening, 41.63 ms median cold order, 22.55 ms single-photo release, and 541.1 MB ending RSS.

## Missing-original relinking and proof portability

Relink agent commit `25b9fdb` integrated as `d9527ce`; 38 isolated tests passed including 8 core and 6 production AppState tests plus adjacent persistence/history coverage. Snapshot and relink service extensions were both retained when resolving their insertion conflict. Combined optimized workflow tests on `d9527ce` passed:25 tests,0 failures (snapshot, relink, core index and actual selection workflows). Proof numerical correction remains under investigation. No release or installation has occurred.
