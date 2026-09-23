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
