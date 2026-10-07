# Integrated execution and qualification — 7 October 2026

## Result

Twenty confirmed defects were repaired across three parallel work streams and integration review. Catalog keyword additions now reach delivered files while preserving source IPTC. The current plan has 84 entries; remaining entries include product projects, investigations, performance work and photo/native-device acceptance, rather than 64 undiscovered bugs.

Useful September changes and evidence were consolidated onto October main `5643497`. Obsolete disabled colour/brush prototypes were preserved rather than re-enabled. Local branches, dirty patches and relevant untracked work were backed up before changes. No private photographs, user catalogs, preservation bundles or installed app changes are publication artifacts.

## Repairs and evidence

| Scope | Result and regressions |
|---|---|
| PS-01–05, PS-07, PS-10 | Distinguish absent XMP from I/O failure; retain refused edits durably; replay removals/current re-adds; project hierarchy leaves; preserve shared leaves; merge concurrent owed fields. Fault-injected refusal/race/restart regressions were red before repair. |
| PS-06, PS-08–09, OUT-01 | Existing files identified by device/inode; independent frame/role/source landings enforced; same-batch export aliases renamed. Actual hardlink/symlink/case tests pass; re-ingest reuses independent copies; existing aliases remain unchanged. |
| APP-01–04 | Actual oriented source metadata and all-or-none crop ratio/swap preflight; refuse ineligible/changed targets; preserve unrelated edits; stale ratio locks cannot distort drag. Generated TIFF/race/impossible reciprocal tests passed. |
| APP-05–08 | Failed updater relaunch leaves process alive; heavy file operations run away from UI actor; owned scratch cleaned; scan returns regular image files rather than image-extension directories/broken links. Disposable bundle replacement tested; no actual install/launch. |
| RENDER-01 | Malformed/huge finite healing coordinates and offsets bounded before integer conversion, source search and sampling. Six new and eleven existing core healing tests passed; four GPU tests passed with service access. |
| RENDER-13 | Four equivalent Boolean comparisons avoid macOS 27 CIKL-to-Metal argument propagation failure. All three colour kernels compile. Existing aqua accuracy improved from ~66.5 to 1.73/0.51 encoded codes under unchanged bound; independent half/Float32/signed-HDR parity passes. No colour math/goldens/tolerance changed. |
| OUT-02, partial feature | Catalog leaf additions merge with embedded source tags. Empty/nil catalog preserves original tags; keyword stripping remains authoritative; missing/closed catalog reads refuse keyword-enabled recipes, stripped siblings continue. Real AppState/coordinator/renderer/ImageIO paths tested. Embedded-source removals need an imported baseline or tombstones and remain planned. |
| Integration maintenance | Precise proof drift diagnostics; equivalent distinct updater helper name avoids checker collision; HDR source assertion allows added metadata argument; crop citation updated; SQLite plan recognizer accepts optional EXISTS annotation while requiring the integer-PK lookup and rejecting a degraded query. |

## Combined verification

Native Swift build system, Swift 6.4, macOS 27 arm64, release configuration with isolated caches and Metal/Core Image service access. The default Xcode build-system dSYM step was blocked in sandbox; native compilation succeeds. Sandbox-only image readbacks previously failed; the same binaries passed with service access.

- Initial integrated run: 3157 tests, 78 skips, 42 reported assertion failures across 11 failed cases. This revealed baseline missing colour kernels and compatibility-sensitive source/plan tests. It is not a passing result.
- Final full optimized run: **3158 tests; 3135 passed, 22 intentional skips, one failure**. Exit status 1 is retained and reported, not rewritten to green.
- The sole failed case is `ControlProofTests.testTheCommittedRecordsStillDescribeWhatTheEngineDoes`, on the same three records already failing hosted October main. Fieldwise diagnostics preserve the original 1e-6 gate. Local macOS debug and release reproduce the historical macOS values; same-SHA Linux passes. Exact primitive cause and cross-platform portability contract remain unresolved.
- Skips: five private RAW cases without `LUMEN_AUDIT_RAW_DIR`; twelve public corpus cases without `LUMEN_RAW_CORPUS`; three opt-in benchmarks; two opt-in probe utilities. There are no remaining missing-colour-kernel skips.
- Source checker: all passes verified; final follow-up removes an interpolation-parser false positive without expanding a keyword allowlist. Final clean run completed with every pass green and exit status 0.
- Release policy: passed, with 24 unsafe mutations rejected. Checker fixture suite: all 31 controls passed. Slider-atlas canonical-record tests passed.
- A final diagnostic-only test follow-up extracts SQLite version into a local variable to avoid nested-string parser confusion; no SQL or assertion changed. Focused optimized recompile/test completed: 19 tests passed, zero failures.

Full-run production/test revision: `885515f`. Subsequent `3939a29` changes only the diagnostic print. Later audit/report commits do not alter production code. Working logs live in the local task’s `work/baseline`; no private RAWs were loaded.

## Release and publication

Updater publication now requires explicit workflow-dispatch opt-in plus every previous success/main/current-tip gate. No release, tag, app installation or real relaunch was performed. Existing proof drift still blocks release validation. Real RAW decoding, look acceptance, native accessibility/interaction, volume disconnect and actual update installation remain unearned gates.

Published after explicit owner approval through [PR #7](https://github.com/benedek-art/lumen/pull/7), merged into GitHub main as `1a0c91a122bd684e9716f5e9b468b928cc908ea8`. Local main is synchronized; its prior pointer is preserved as `codex/lumen-main-before-oct07`. Hosted macOS compilation, app bundle and layout checks passed before merge. Longer GPU/Linux/fast checks remained running; the ordinary merge path did not bypass repository-required protections. This documentation update does not change tested production code. No updater release was published.

## Recommended next work

1. Settle proof portability with measured, protected per-field/platform contracts; verify this kernel syntax on older supported macOS CI.
2. Stage release candidates without deleting known-good delivery before replacement; keep explicit publication opt-in.
3. Build durable per-file result reporting, relink, per-photo snapshots and explicit smart-album scopes in separate ownership waves.
4. Measure large-catalog, mask and settle latency; retain the hard-brush boundary data and choose a saved-look compatibility policy before changing deposition.
5. Qualify RAW cameras, skin/sky/foliage/B&W/HDR and actual native UI/update workflows when originals and devices are available.
