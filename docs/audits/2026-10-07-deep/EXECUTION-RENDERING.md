# Rendering execution report — October 7, 2026

Branch: codex/lumen-oct07-rendering. Worktree: work/lumen-rendering. Baseline: 5643497.

## RENDER-01 implementation

Owned changes: StrokeHeal.swift, StrokeSourceSearch.swift, and StrokeHealRobustnessTests.swift.

* Bounds intersect in Double before converting to Int; finite off-canvas coordinates beyond Int range cannot trap.
* Resample segment count caps in Double before conversion; empty/invalid inputs are refused.
* Frame-scaled coordinates and source offsets must fit an arithmetic-safe magnitude (sqrt(greatestFiniteMagnitude)/1024) so squared-distance and rim calculations have headroom. This does not clip ordinary normalized overdraw.
* Source search produces a harmless one-pixel sentinel for invalid windows and refuses invalid search inputs.
* Sampling clamps continuous coordinates before ImageBuffer.bilinear's integer conversion. Extremely far but arithmetically valid source offsets preserve the same edge-extension result as a normal off-frame offset.
* No normal look, recipe schema, shader arithmetic, cache revision or proof record changed.

Red evidence: isolated Swift interpreter executed the prior exact cap-after-Int expression with finite ±1e300 coordinates; exit 133 with Double-to-Int overflow. This is an arithmetic crash proof, not claimed as a full imported sidecar end-to-end reproduction. Decoders preserve finite x/y and offsets, so entrypoints need independent validation.

Regression cases include nonfinite coordinates, product-overflow-scale finite coordinates/offsets, empty input, invalid spacing/dimensions, >Int-range valid resampling with 256-vertex cap, fully off-frame strokes and intersecting overdraw, clamped source-offset equivalence, and bounded source search.

## Validation

Targeted native test invocation uses --build-system native, --disable-sandbox, isolated /private/tmp caches and maximum 2 jobs. The default build-system attempt was interrupted on parent advice because its dsymutil phase is incompatible with current sandbox. Native build completed in 230.36s. The initial selected run completed 23 tests in 85.36s: six new robustness tests, eleven existing core healing tests, and two characterization probes passed. Of four GPU tests, kernel compilation passed but three image tests failed at XCTUnwrap because GPU readback returned nil. This does not certify GPU parity; parent must compare baseline/environment. Output was heavily buffered; an initially suspected runner hang was disproven by final log. Direct xcrun xctest reconfirmed six robustness tests and eleven core healing tests green. A redundant second characterization run was interrupted once initial results were available.

## Brush characterization

Temporary synthetic characterization covers Feather 0/50/100 at fit widths 2048, 2049, 2050, 2550 and 2730 against a 6120 reference; also forward/reversed endpoint deposition at 2048/2049/2550. The reference is a finite higher resolution, not analytic truth. Common-grid grouping is approximate at nonintegral scale ratios and can conflate alignment differences with raster differences. Metrics are evidence for next work, not visual sign-off or a new tolerance contract.

No brush stamp, supersample ceiling, feather guard or saved-look behavior altered. Raw photographs and target-device interaction tests remain necessary for final quality acceptance.

### New measured synthetic evidence

Single minimum-size (0.002) Flow100/Density100 line, 0.1007/0.45 → 0.9007/0.55, frame aspect approximately6:1, compared with6120-long-edge reference:

| Width | Feather0 selected-area ratio | Feather50 ratio | Feather100 ratio |
|---|---:|---:|---:|
| 2048 | 0.981750 | 1.000907 | 1.000833 |
| 2049 | 0.928564 | 1.000227 | 1.001599 |
| 2050 | 0.929771 | 1.001380 | 1.001524 |
| 2550 | 0.948446 | 0.999989 | 1.000101 |
| 2730 | 0.953369 | 0.999343 | 0.999604 |

Hard-brush area drops by~5.3 percentage points crossing2048→2049 and is~7.1% below the6120 reference at2049. Feather50/100 stay within~0.2% in this fixture. Area normalization is independent of common-grid alignment; worst common-grid cell differences are approximate due nonintegral grouping. This confirms the previously unmeasured hard-brush gap in this one synthetic fixture, not all shapes or components.

Forward/reversed strokes at2048/2049/2550 produce maximum pixel-alpha differences0.213663/0.240866/0.350980 while area ratio is1.000038/1.000853/1.000880. This measures raster direction/phase sensitivity across the entire line; it does not isolate last-stamp omission. No endpoint or hard-brush look was changed.

Reproducible characterization class saved outside repository in work/BrushBoundaryCharacterizationTests.swift. It is deliberately not committed as a permanently passing test with a weak tolerance for a known unresolved discrepancy. Place temporarily in Tests/LumenCoreTests and select BrushBoundaryCharacterizationTests to reproduce. Main regression commit includes only behaviorally meaningful healing robustness tests.
