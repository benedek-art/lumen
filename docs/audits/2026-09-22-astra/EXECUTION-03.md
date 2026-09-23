# Verified repairs — execution record 03

## Parallel implementation scope

The owner explicitly approved three Astra implementation agents. Each works from the same committed safety checkpoint (`40e1048`) in an independent checkout and branch. No agent may merge, publish a release, install the app, or upload photographs. Root reviews and integrates tested commits into draft PR #5, then repeats combined regression checks.

The independent lanes are:

- AI-01 / AI-15: RAW decoder selection, colour boundary and immutable native dimensions.
- M01 / M02: referenced-mask source preparation and dependency-aware alpha invalidation.
- REL-06 / REL-07: source replacement, cache invalidation and exact preview provenance.

Red results before product changes: RAW **3 tests / 48 failed assertions** on all three private Sony RAW fixtures; referenced masks **5 tests / 10 failed assertions** through the actual GPU pipeline; source/preview caches **4 tests / 7 failed assertions** using real temporary-image replacements and a controlled publication interleaving. These are regression reproductions, not completed repairs; final verification follows integration.

## UI contract corrections (AI-09, AI-13, M13, M14)

New contract tests first ran **4 tests / 12 failed assertions** against the original controls. An initial missing test-initializer argument was corrected before this red run and is not counted as a product failure.

The implementation aligns Black target's typed range and binding with the existing engine ceiling of 9. Legacy values above 9 display their effective value without rewriting recipes on load; reset still clears the override. Grading Luminance help describes its actual 1.5-stop neutral-axis reach and notes zone limiting. Ramp shape help follows the actual inverse-gamma direction. All three halation controls are disabled for a stock with no halation response, with a visible explanation; stored creative parameters are retained.

Verification is a combination of numerical engine controls and source-level UI wiring assertions plus adjacent layout/mask/grading tests: **60 tests, zero failures**. Three existing layout precision expectations remain explicitly marked as expected failures by the inherited suite; they were not changed. A transient native build reported a metadata change on an unchanged source file; the successful build was rerun before counting tests. These checks do **not** replace hosted native interaction/accessibility verification. No image mathematics, tolerances, goldens, or intended stock look changed in this UI batch.

## AI-06 — full-range white-balance picker

The regression builds grey-card samples by inverting legal manual corrections, applies a different current WB, then asks the picker to recover a neutral. It covers negative and positive hard-range tints across 3,200–12,000 K plus ordinary sRGB-space controls. Before repair: **3 tests / 15 failed assertions**.

The coarse search and returned value now use the engine's full ±300 tint range. Forward evaluation retains the existing temperature-dependent physical tint guard. Simply expanding that range left one positive-tint case outside the unchanged 0.003 relative-channel residual limit. A bounded, strictly improving pattern-search refinement now follows the narrow Kelvin/tint minimum instead of being trapped inside the coarse seed's rectangular refinement window.

Final adjacent verification: **120 tests, zero failures**, including the new cases, existing WB/colour-preservation tests, tint guard tests and the existing picker bisection-cost bound. No tolerance changed. This improves sampled neutralization; it is not a universal claim about illuminant calibration or non-neutral objects selected with the picker.

## M01 / M02 — integrated referenced-mask changes

Agent commit `9b5d738` was reviewed and integrated as `9b14267`. Image preparation now follows reference dependencies, including disabled and inverted/transitive donors and explicitly requested disabled thumbnails. Alpha identity includes the selection-only dependency closure, referenced brush availability and matte generation. Local adjustments and cosmetic fields do not cause an alpha rebake.

The original **5 tests / 10 failed assertions** pass after repair. Expanded qualification passed **60 tests, zero failures**, including current-root/duplicate-target semantics, finite cycles, group-disabled donors, ordinary selection reuse, and regenerated same-kind mattes. An inherited adversarial test that intentionally documented the stale-root answer now rejects it. Cache memory/retention budgets are unchanged; larger retained raster caches remain a separate performance task.

Cross-review with the preview lane reproduced a further same-path Automask invalidation issue (**one test / one failure**, max linear channel difference 0.175399 versus a fresh renderer). Cache-clear races are being tested with semaphore-controlled work before repair. These follow-on changes and combined full-suite verification are not yet included in the counts above.

The follow-on repair was integrated as `51c1ca1` from agent commit `b70c699`. Deterministic clear regressions produced four failed assertions in two of three race tests; the same-key new-request negative control passed before and after. The repair clears Automask prefixes, gives old picture-dependent work a distinct source-generation key, and guards both alpha publication and queue bookkeeping against obsolete work. Broad agent qualification: **541 tests, 11 existing RAW-corpus skips, zero failures**. No original tolerance or golden changed. The preview lane supplies detection of actual source replacement.

## UX-02 — panel resize gesture

The production arithmetic was extracted without changing its behaviour, then exercised with repeated cumulative translations, overshoot/reversal, return to origin and a new gesture. Before repair: **2 tests / 5 failed assertions**. The calculation now holds one starting width through a gesture instead of repeatedly subtracting the full translation from the current width. Gesture completion and cancellation clear the starting value; persistence remains on completion.

Focused arithmetic and adjacent layout/state checks: **23 tests, zero failures** (the inherited layout expected failures remain unchanged). Native pointer-event and cancellation delivery are not established by these pure calculation checks.

## AI-01 / AI-15 — integrated RAW qualification

Agent commit `2efd71e` was reviewed and integrated as `1965507`. New sources use Apple's per-file selected decoder rather than forcing the last advertised version; supported explicit recipe pins remain honored. Native dimensions are captured before any scaled decode. Every RAW9 path, including its first native/export/picker request, now establishes a real extended-linear-sRGB evaluation boundary before conversion to the pipeline's extended-linear Rec2020 half-float buffer.

Beyond the original **3 tests / 48 failed assertions**, a fresh native first-read/cache test failed all **18 tile comparisons** across three private RAW fixtures before repair (worst absolute linear-channel error 0.547688). Qualification passed **129 tests, zero failures or skips**: 14 pipeline tests, 108 adjacent residency/draft/capture tests and 7 app budget tests. RAW9 native first/cache error is at most 0.000488; preview first/cache at most 0.001953, consistent with the final half-float buffer. Explicit decoder switches, unsupported-pin fallback and original dimensions also pass.

A synthetic nonzero-origin fixture exposed a separate materializer defect: correct extent metadata but zero pixels. Source-to-destination coordinate mapping is now explicit, with throwing render-task completion. Signed negative values, highlight headroom, alpha, tag, extent and byte accounting pass both evaluation paths. The independent RAW8 oracle matches its pre-existing half-intermediate evaluation contract; the RAW9 oracle uses float intermediates. Tolerances were not increased.

Limits: three Sony RAWs on one macOS/Apple Silicon host are not universal camera qualification. RAW9 now pays a full native demosaic and approximately 250 MiB at 33 MP even for a subsequent small picker read. The existing 512 MiB and 16,384-pixel allocation bounds remain; a required boundary that cannot allocate or render fails rather than returning wrongly coloured lazy pixels. Native RAW9 above roughly 67 MP needs a future tiled solution. Other decoders retain their previous lazy-first-native policy. Persistent cache revision invalidation belongs to the preview lane and must be integrated before acceptance. No photographs or original XMP data are committed.
