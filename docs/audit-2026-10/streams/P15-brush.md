# P15-brush: brush masks select the same region at every resolution

Stream agent P15-brush. Base: `origin/claude/jolly-sagan-k7ch7z` @ 0896556. Build dir `/tmp/lumen-build-p15`.
Inputs: Astra `findings.json` M04, `SUPPLEMENTAL-BACKLOG.md` S-10, `streams/P3-masks.md`.

## Summary

| # | Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|---|
| 1 | M04: brush alpha depends on raster resolution (stamp spacing) | FIXED | a9f75d5 | With `weight` forced to 1: 1 failure listing 5 rows (for example "M04 … at 340 px: worst cell 0.193, area ×0.658"). With the fix: 1/1. | none (no proof record covers masks) |
| 2 | M04 subpixel half + S-10: coarse fold of separately projected thin components | FIXED, with a disclosed band (see Limits) | 9c01936 | With `brushSupersample` forced to 1: 7 failures across 3 tests. With the fix: 4/4. | none (no proof record covers masks) |

**No proof record covers masks.** I checked `Tests/LumenCoreTests/Proof/records` (144 files). The only hit for "mask" is `sharpen.masking.json`, and that is the Sharpening Masking slider, not a mask component.
**No mask golden moves.** `Fixtures/maskalgebra.json` tests the algebra on scalar alphas and rasterizes no brush. No other fixture contains a stroke.
`PreviewCache.renderingRevision` goes **6 → 7**, because thin-brush masks render differently in both renderers.

## Where the renderers stand

The GPU path has no brush kernel. `MaskGPU` handles closed-form gradients only. Every brush mask goes through `MaskRaster.combine` in both renderers:
- the CPU reference, via `ReferenceRenderer`;
- the GPU pipeline, via `PipelineRenderer.makeGraph → bake`, with brush planes held in `BrushPlaneCache`.

So the pixel fix is in `LumenCore` and applies to both renderers. The pipeline still needed its own change. It paints the planes it holds at the size it asks for, and `rasterize` only uses a held plane of exactly the fold's size. Without the change, every thin-brush mask on the GPU path would have had its held plane refused, and the whole stroke set repainted inside the fold on every frame. The pixels would have been right and the ~140 ms settle would have gone back to seconds.

That pipeline hunk is in 9c01936. Its test, `MaskReferencePipelineTests.testAThinBrushIsHeldAtTheFoldSizeAndResumesThere`, is **source-verified**: I traced it against the old bake, where the held plane long edge is 128 and the test requires at least 400. It runs only on macOS.

## Measurement (Linux, reference rasterizer)

**Metric.** I box-reduce each render to a common grid and compare it with a "truth" rendered where the thinnest stroke is a 12 px radius. I report two numbers:
- **worst cell** |Δα|;
- **area**: total selected alpha divided by the truth's.

The frame is a 6:1 band, so the long edge (which a stroke's size is a fraction of) can be large while the plane stays small.

**Tolerance (stated):** every cell within 0.10, and area within 2%.

### Committed fixture (`BrushResolutionTests`)

- Grid cell: 1/170 of the long edge.
- Resolutions: 340 / 850 / 2040 px.
- Stroke sizes are scaled ×3, so the thinnest stroke has the radius that Size 0.002 has at about 1020 (draft proxy), 2550 (fit) and 6120 (export).
- **Before** is HEAD-equivalent: both fixes substituted out.
- **After** is this branch.

| case | 340 before | 340 after | 850 before | 850 after | 2040 before | 2040 after |
|---|---|---|---|---|---|---|
| M04 line (Flow 10, Density 80) | 0.193 / ×0.658 | 0.051 / ×1.001 | ok | 0.001 / ×1.000 | ok | 0.000 / ×1.000 |
| minimum-size line, Flow 100 | 0.448 / ×0.492 | 0.061 / ×0.999 | 0.082 / ×0.900 | 0.026 / ×1.000 | 0.027 / ×0.970 | 0.014 / ×1.000 |
| minimum-size line, Flow 20, Feather 80 | 0.513 / ×0.162 | 0.010 / ×1.000 | 0.338 / ×0.444 | 0.032 / ×1.000 | 0.123 / ×0.797 | 0.018 / ×1.000 |
| thin dab | ok | 0.011 / ×1.000 | ok | 0.007 / ×1.000 | ok | 0.001 / ×1.000 |
| ordinary Size 0.05, Flow 30 line | ok | 0.002 / ×1.000 | ok | 0.000 / ×1.000 | ok | 0.000 / ×1.000 |
| thin **erase** across a wide stroke | 0.381 / ×1.024 | 0.059 / ×1.000 | 0.128 / ×1.008 | 0.040 / ×1.000 | ok | 0.001 / ×1.000 |
| **Add** of two thin components | 0.275 / ×0.735 | 0.045 / ×1.001 | 0.160 / ×0.933 | 0.029 / ×1.000 | ok | 0.001 / ×1.000 |
| thin **Subtract**ed from wide | 0.186 / ×1.007 | 0.061 / ×1.000 | ok | 0.043 / ×1.000 | ok | 0.002 / ×1.000 |
| wide **Intersect** thin | 0.186 / ×0.879 | 0.038 / ×1.001 | 0.043 / ×0.957 | 0.023 / ×1.000 | ok | 0.002 / ×1.000 |
| two thin crossing, **Intersect** | 0.183 / ×0.735 | 0.030 / ×0.992 | 0.053 / ×0.914 | 0.015 / ×0.995 | ok | 0.000 / ×1.000 |

"ok" means within tolerance before the fix; the test lists only failing rows.

### Probe at the app's real sizes

These came from a throwaway probe (not committed):
- Grid cell: 1/510 of the long edge.
- Resolutions: 1020 / 2550 / 6120 px.
- Truth: 12240 px.

**Before:**

| case | 1020 | 2550 | 6120 |
|---|---|---|---|
| M04 line | 0.193 / ×0.658 | 0.001 | 0.000 |
| Size 0.002 line, Flow 100 | 0.490 / ×0.437 | 0.081 / ×0.900 | 0.028 / ×0.970 |
| Size 0.002 line, Flow 20, Feather 80 | 0.517 / ×0.155 | 0.338 / ×0.446 | 0.123 / ×0.797 |
| Add of two Size 0.004 components | 0.345 / ×0.717 | 0.137 / ×0.926 | 0.003 |
| crossing Intersect | 0.347 / ×0.733 | 0.085 / ×0.919 | 0.003 |

**After:**

| case | 1020 | 2550 | 6120 |
|---|---|---|---|
| M04 line | 0.028 / ×0.999 | 0.001 | 0.000 |
| Size 0.002 line, Flow 100 | 0.060 / ×1.000 | 0.084 / ×0.999 | 0.029 / ×1.000 |
| Size 0.002 line, Flow 20, Feather 80 | 0.041 / ×1.000 | 0.044 / ×1.000 | 0.020 / ×1.000 |
| erase | 0.057 / ×1.000 | 0.037 / ×1.000 | — |
| Add | 0.050 / ×1.000 | 0.047 / ×0.999 | — |
| Subtract | 0.057 / ×1.000 | 0.037 / ×1.000 | — |
| Intersect wide∩thin | 0.038 / ×1.000 | 0.023 / ×1.000 | — |
| crossing Intersect | 0.053 / ×0.992 | 0.029 / ×1.005 | — |

The probe's first baseline also showed 0.376 at 2550 for the erase, Subtract and Intersect cases. That was **not** a resolution effect; see FOUND-WHILE-FIXING #1. The fixture geometry was moved off that coincidence for every number above.

## The fix

1. **Density-correct spacing (a9f75d5).** In `MaskRaster.paint`, stamp spacing stays `max(1 px, 0.1·r)`. Every stamp after the first now deposits what `spacing / (0.1·r)` nominal stamps would: `1 − (1 − f·s)^weight`. At a radius of 10 px or more, `weight == 1` and the old arithmetic runs verbatim, so those strokes paint bit-identically.
2. **One shared fine grid (9c01936).**
   - `MaskRaster.brushSupersample` picks an integer factor so the mask's thinnest stroke has a radius of at least `brushFineRadiusPx` = 3 px.
   - The factor is capped at `brushSupersampleLimit` = 4. The fine long edge is also capped at `max(DraftLadder.interactiveLongEdgeCeiling, requested)`, which is the same line `BrushPlaneCache` holds to.
   - `alpha` rasterizes **and folds** every component (Add/Subtract/Intersect, maskRef included) at that size. It then box-reduces once, before the refine chain. So the algebra runs on fine state, which is S-10's requirement.
   - The factor is 1 (no change at all) for any mask without a stroke under 3 px. An export at sensor size gets factor 1 too: Size 0.002 is a 6 px radius at 6000 px.
   - `PipelineRenderer` paints its held planes at `MaskRaster.brushFoldSize`.

Why 3 px: with the threshold at 2 px, the thin-component cases at a 2.04 px radius measured 0.134–0.167 (failing). At 3 px they pass.

## Memory and worst-case latency (disclosed)

Release build on this Linux container, under load average about 30. Read the numbers as ratios. Each row is a 60-stroke set, last stroke resumed, then the fold. This is the settle path.

| set | raster | fold grid (plane) | settle before¹ | settle after |
|---|---|---|---|---|
| 60 × Size 0.05 | 1024 | 1024 (2.7 MB) | 45 ms | 45 ms (same path) |
| 60 × Size 0.05 | 2048 | 2048 (10.7 MB) | 185 ms | 185 ms |
| 60 × Size 0.05 | 2560 | 2560 (16.7 MB) | 363 ms | 363 ms |
| 60 × Size 0.004 | 1024 | 2048×1366 (10.7 MB) | — | 91 ms |
| 60 × Size 0.002 | 1024 | 3072×2049 (24.0 MB) | — | 186 ms |
| 60 × Size 0.002 | 2048 | 4096×2730 (42.7 MB) | — | 346 ms |
| **59 × Size 0.05 + 1 × Size 0.002** | 1024 (draft) | 3072×2049 (24.0 MB) | ≈45 ms | **296 ms** |
| **59 × Size 0.05 + 1 × Size 0.002** | 2048 (fit) | 4096×2730 (42.7 MB) | ≈185 ms | **738 ms** |
| 59 × Size 0.05 + 1 × Size 0.002 | 2560 (fit, capped) | 2560 (16.7 MB) | ≈363 ms | 280 ms |

¹ Timings on this box vary by about ±25% run to run (the capped 2560 mixed row reads lower than its Size-0.05 sibling for that reason). The "before" for the Size-0.05 rows is the same code path: factor 1 and weight 1. For the mixed rows it is the Size-0.05 row, because one thin stroke adds negligible paint. I did not measure a separate before for the all-thin sets. They are cheaper than the Size-0.05 rows on the old code because their stamps are smaller.

- **Worst case: about 4× the settle**, when a mask mixes ordinary strokes with one stroke under a 3 px radius at a fit raster of 2048 or less. The fine grid then costs the factor squared in pixels for every stroke in that mask: painting the resumed stroke plus the fold. The cold repaint, which happens on a cache miss, is also about 4×: 17.2 s against about 4.4 s at 2048 on this box.
- On the ~140 ms settle scale, the worst case reads as about 0.5 s. Ordinary brushes (every stroke ≥ 3 px radius) pay nothing.
- **Memory.** Each held brush plane and the transient fold buffer are factor² the raster size: up to 42.7 MB per plane at a 2048 fit, and 24 MB at the 1024 proxy. These fine planes all land in `BrushPlaneCache`'s byte-bounded settle rung (96 MB). So at a 2048 fit only **two** thin-stroke brush components are held at once. A third evicts one, and the evicted one pays a cold repaint at the next settle. The transient peak per mask fold is about (components + 2) × the fine plane.

## Limits (what is not fixed)

- **Fit rasters from 2049 to about 2730 px with a stroke under a 3 px radius get no fine grid**, because the interactive ceiling caps it. In practice this means Size 0.002 at that fit (radius 2.05–2.73 px).
  - Measured at 2550 (probe): worst cell 0.084 and area ×0.999 for a Flow 100 Size 0.002 line, which is within tolerance.
  - Extrapolated from the 2.04 px fixture run: about 0.13–0.17 for thin multi-component masks at the bottom of the band (around 2050 px), which is outside the 0.10 tolerance.
  - Area is conserved everywhere (spacing fix). What remains is pixel-centre aliasing.
  - Closing the band means holding fold planes above 4096 px: about 70–80 MB each, and about 4× the settle. I did not make that trade. See DECISIONS.
- **Hardness guard.** `hardnessUsed ≤ 1 − 1/r` still softens a hard brush where its radius is small. On the fine grid, r is at least 3, so a Feather-0 stroke is at least 33% feathered at the proxy and not at export. This is inside the tolerance for the tested feathers (50, 80). I did not measure Feather 0 separately.
- **Automask strokes** sample the stage input bilinearly at the fine grid. This is consistent across resolutions but not separately measured.

## DECISIONS

1. **Tolerance = 0.10 per grid cell (cell = 1/170 to 1/510 of the long edge), 2% of area.** This is my choice. Tightening it needs a finer grid, and a finer grid costs latency.
2. **`brushFineRadiusPx = 3`, `brushSupersampleLimit = 4`, fine grid capped at the interactive ceiling (4096).** Together these cap the worst settle at about 4× and keep every fine plane resumable. The cost is the 2049–2730 px band above.
3. **renderingRevision 6 → 7.** This invalidates every cached preview once. Only thin-stroke brush masks actually change. Another stream may also bump it, so the merge must take the maximum plus one, not either side.

## FOUND-WHILE-FIXING

1. **A stroke's last stamp is at the mercy of floating point.** `stampCenters` lays stamps every spacing from the first point and never stamps the end point. If a stroke's length is an exact multiple of the spacing (0.8 / 0.0025 = 320 here), whether the 320th stamp lands depends on rounding. So the tip moved by up to one spacing (0.1 r) between 2550 and 12240 px: a 0.376 cell difference at a 64 px radius. This is not resolution-dependent in general. A fix (always stamp the end point, with a fractional weight) would move every existing stroke's tip, so I have not implemented it. It is a DECISION for the owner.
2. **`BrushPlaneCache.heldPlaneSizes()` and `PipelineRenderer.brushPlanes`** are now internal rather than private, for the pipeline test above.
3. `BrushAccumulationTests.testCombineUsesASuppliedBrushPlaneInsteadOfRepainting` supplied its plane at the raster size. Its strokes have a 2.4 px radius, so the fold now runs on the fine grid. The test now supplies the plane at `brushFoldSize`, which is the contract the pipeline relies on. Its sibling test, which checks that a mis-sized plane is ignored, is unchanged and green.

## Checks

- `swift build --build-tests` is clean.
- `check-swift-surface.py` exits 0.
- Green suites: BrushResolution (4), BrushAccumulation (9), MaskCost (7), MissingMaskInput (6), BrushSidecar (12), MaskDependencyAdversarial (14), MaskDependency, Masking (24), EngineIntegration (62), AuditSafety (9), BlobBackup (5), MaskBlend (14), MaskGroup (12), MaskChannelAndReference, MaskReferenceIdentity, PolygonMask.
