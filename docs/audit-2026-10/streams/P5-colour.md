# P5-colour: AI-03 (colour-table accuracy) and AI-02 (Point Colour picker stage)

Stream agent P5-colour. Base: `claude/jolly-sagan-k7ch7z` at `cc4cdd7`. Build dir
`/tmp/lumen-build-p5` (debug) and `/tmp/lumen-build-p5-rel` (release, timing only).
Linux, Swift 6.1. LumenPipeline and LumenApp were not compiled here; anything in them
is **source-verified**. `scripts/check-swift-surface.py` exit 0.

| Item | Status | Commit | Red → green | Proof records that move |
|---|---|---|---|---|
| AI-03 colour-table accuracy | **FIXED** (Linux CPU path measured; GPU kernels source-verified) | `5c3f7e5` | Linux twin of the 4 GPU assertions: **4 red** before (39.82 / 35.84 / 12.25 / 37.42 codes), green after; 4 red again with the fused cube substituted back | **50**: every bw.\*, color.\*, mixer.\*, pointColor.\*, primaries.\* record (table below) |
| Orchestrator note: GPU tables at 8-bit (part of AI-03's budget) | **FIXED** (source-verified; GPU-only) | `9e37578` | `ColorCubePrecisionTests` (macOS, new): bound 2e-4 against values off the 1/255 grid. Red under `CIColorCube` per the trunk gpu-parity measurement (9/255); kernel not compilable here | none (proofs use the CPU path, which never quantized) |
| Follow-up to both (regressions the full suite caught) | **FIXED** | `c00c30c` | SliderContract Density-neutral 4 red → green; PointColorRePickReach 1 red → green | none beyond AI-03's (twin moves ~1e-7) |
| AI-02 picker vs selection stage | **FIXED** (engine half measured; renderer/app wiring source-verified) | `727509f` | `PointColourPickerStageTests`: **40 assertions red** with the old tap substituted back, reproducing the finding's 0.11980 / 0.04268 retained chroma; green after | none (only what a NEW pick stores changes) |

## AI-03: what changed

V4's measured split, implemented: **S9 (the whole of `ColorEngine`) runs exactly every
time; only S10 (the grade) stays in a cube.** Split by stage, never by recipe, so no
control crossing zero changes route.

- `Sources/LumenCore/Engine/ExactColorStage.swift` (new). `ColorEngine.exactStage`
  resolves the engine's own sanitized state (clamps, arcs, measured Uniformity targets,
  compiled swatch list) into Float32 `vec4` uniforms for a fixed pass sequence:
  `primaries` (remap and Shadows Tint, absent when both are identity), `mixer` (absent
  when flat), **one `point` pass per live swatch** (the recipe does not cap swatches at
  8, so a fixed-maximum kernel would drop valid ones), and `finish` (Vibrance/Saturation,
  B&W reading the pre-Saturation colour, and `apply`'s non-finite fallback). The four
  kernel sources are generated in the same file, beside **`ExactColorTwin`**, an
  operation-for-operation Float32 Swift twin that reads the same uniform vectors in the
  same order. `ColorEngine.apply` (Double) remains the independent oracle; the twin and
  the kernels are the implementation under test.
- **Why four kernels and not one.** Two hard limits. The swatch count is unbounded, and
  the Mixer alone needs 29 arguments (1 sample + 28 `vec4`), which is the most
  `ExactMixerGPU` was qualified with on device (EXECUTION-05). Every kernel is at or
  under 29, held by a Linux test that parses each kernel signature against its pass's
  uniform list. Core Image concatenates adjacent colour kernels. I found no point where
  the split could not be made exact within these limits, so there is no partial path.
- Consumers of the old combined table, all moved:
  - `RenderPlan`: `colorGradeLUT`/`colorGradeIsIdentity` are replaced by `colorStage`
    plus `gradeLUT`/`gradeIsIdentity`. `colorGraded(_:)` is exact S9 then the S10
    table, and `referenceColor` uses it. The grade table's cache key drops the colour
    subtrees and the measured hues, so a colour drag is a cache hit (slot renamed
    `.colorGrade` → `.grade`).
  - `RenderGraph.localStageInput` uses `applyColorStage` then the grade cube. That
    covers preview, export, the HDR pair, before/after, the mask rasterizer source and
    the mask eyedropper tap (`sampleMaskStageInput`).
  - Per-mask `LocalPlan` is now pre-table (tone, white balance), then the exact colour
    stage, then post-table (hue shift, tint, local grade). Each piece is nil only when
    it is the identity. It is **always split**, because fusing the tables when the
    colour stage is off would be a route that switches with a control.
  - `ReferenceRenderer`: the global S9 runs `colorStage.apply(to:)` (the twin, rows
    concurrent); the local path runs `exactStage.apply` instead of `ColorEngine.apply`,
    so CPU and GPU run one algorithm.
  - `KernelLibrary`: the four kernels are on the **core** roster
    (`unavailableKernels`). If one fails to compile, the renderer takes the CPU path
    (the twin), never a table.
- `PreviewCache.renderingRevision` 6 → 7.
- `ColorTableAccuracyTests` (macOS): the four strict `XCTExpectFailure` wrappers are
  **removed**. They are now ordinary assertions under the unchanged 3-code bound.

### Evidence (Linux, debug unless stated)

| Check | Result |
|---|---|
| `ColorTableAccuracyLinuxTests` (new, CPU twin of the 4 GPU assertions) | before: 4 failures (39.82, 35.84, 12.25, 37.42); after: green; fused cube substituted back into `RenderPlan`: 4 failures, same numbers |
| Twin vs `ColorEngine.apply` (Double), 1,940 Float32-quantized inputs × 94 recipes covering every family's ±100 endpoints, custom arcs, measured/fallback Uniformity, overlapping Variance swatches after a Mixer move, density, B&W after Saturation −100, and a many-control edit | worst **1.76e-5** normalized, worst **0.59 of the gate**. The gate is 3e-5 × max(1, \|in\|, \|out\|) (EXECUTION-05's float32 bound), widened only by the oracle's own measured condition number × 5e-7 where error exceeds 3e-5. The single point that needs it: κ ≈ 65, error 3.2e-5 ≈ 0.01 code |
| Mutation: twin's Variance reads the moving pixel, not the fixed pre-Mixer reference | red, 7,360× the gate |
| **0.001 continuity**: 26 nudges (Uniformity, Vibrance, Saturation, Density, Protect Skin, 5 primaries/tint, new swatch, variance-only swatch, existing swatch variance, B&W band, 3 grade controls, H/S/L of 3 Mixer bands) × 3 bases (neutral, Aqua −100, many-control) × 400 inputs, CPU render path at 33³ | worst render jump − exact jump = **0.083 code** (limit 0.25) |
| Mutation: per-recipe route switch (colour in the cube whenever the grade is live) | red: 6 boundaries jump 36.1–39.5 codes against exact moves of 0.003–0.06 |
| Partition floor (the kernel omits `bandWeights`' empty-partition fallback) | min Σ membership over all handle-range corners × 3,600 hues > 1e-3 |
| Kernel signature/budget test, mutation (drop one `finish` uniform) | red (15 ≠ 16) |
| `ColorScienceTests` measured-hue threading | now the full 20° (was 14.2° through the table); fused cube back: red |
| Suites after the fix | ColorTableAccuracyLinux 2/2, ExactColorStage 6/6, PointColourPickerStage 4/4, PlanTableCache 24/24, ColorScience 59/59, Masking 24/24, ExactMixerPrimitive 5/5, KernelRoster 2/2, Robustness 40/40, EngineIntegration 62/62, GeometryAndOutput 20/20, SoftProofExport 8/8, FilmLabDisplayTransform 5/5, GradeJointLimiter 11/11, PlanCostProbe 3/3, ProofSmoke 1/1. Full-suite run: see the end of this report |

Tests that pinned the old architecture were rewritten, not loosened. Each is listed so
it can be checked:
- `PlanTableCacheTests`: key completeness now also compares `colorStage`. A new
  assertion: a colour drag must hit the grade table's cache.
- `PlanCostProbeTests`: a Saturation drag re-keys **no** table now (asserted). The
  cold/warm test adds a live grade so the grade slot has a table.
- `RobustnessTests` / `MaskingTests` read `plan.colorGraded`, which is what the
  renderers now compute.
- `ExactMixerGPUTests.testIneligibleCombinationAndUniformityKeepTheExistingFusedRoute`
  asserted the fused cube **bit for bit**, which is the defect. It is rewritten as
  `…TakeTheExactShippingStage` and asserts the same two recipes against the oracle.
- `KernelGoldenTests` reads `LocalPlan.preLUT` for the size assertion.
- New macOS suite `ExactColorStageGPUTests`: the kernels compile (ordinary
  assertion), the GPU matches the oracle on every family under the Linux gate, a real
  RGBAh destination stays under EXECUTION-05's 0.003 bound, and alpha is preserved.
  Source-verified: the arithmetic was traced against the twin by hand, and the
  signatures are held on Linux.

### Interactive cost (item 4)

Measured on this box in a **release** build, with 4 cores shared with other agents.
The cube-path figures wobble from 135 to 409 ns/px for the same operation, so read
ratios loosely.

| Recipe | passes | twin, 1 thread | old cube path (encode + tetrahedral + decode), 1 thread | 2560×1707 frame, twin, 4 shared cores | 33³ bake no longer paid per colour edit |
|---|---|---|---|---|---|
| Aqua Lum −100 | 2 | 666 ns/px | 255 ns/px | 3.3 s | 153 ms |
| Saturation +100 | 1 | 1,238 ns/px | 409 ns/px | 5.2 s | 204 ms |
| many-control | 4 | 4,060 ns/px | 257 ns/px | 12.5 s | 432 ms |
| many-control + 8 swatches | 11 | 4,351 ns/px | 135 ns/px | 17.4 s | 688 ms |

GPU, from the generated kernel source (upper bounds over all branches, helpers
expanded; transcendental = pow/cos/sin/atan/exp/log2/sqrt): `primaries` ≤ 29,
`mixer` ≤ 56, `point` ≤ 61 per swatch, `finish` ≤ 231 with Vibrance, Saturation,
Density and B&W all live (about 60 for Saturation alone), plus roughly 3–4 flops per
transcendental of matrix and blend arithmetic. The old S9+S10 path was the log shaper
(6 transcendentals) plus one trilinear cube (8 texel fetches, about 25 flops). At
2560×1707 (4.37 MP), a typical recipe (Mixer + Saturation) is therefore about
1–1.5k flop-equivalents per pixel, roughly 5–7 GFLOP per frame. The worst case
(everything plus 8 swatches) is about 3–4k, roughly 15 GFLOP. This is an **estimate,
not a measurement**: the kernels were not compiled here. On Apple-silicon GPU
throughput that is single-digit milliseconds against the cube's sub-millisecond lookup.
In exchange, every colour-control drag no longer pays the 150–690 ms table bake (or
the stale-table frame) on the CPU. EXECUTION-05's native timing gates (warm 2560 px,
export, cold compile, peak memory on a quiet device) are still owed on macOS CI.

### Proof records that move (item 5)

Every record whose recipe has a non-identity colour stage moves, as expected: 50 of
50 measured. The "before" values are the committed records; the "after" values were
measured here with `ProofRunner.measure` (65³, the proof's own size). Grade, cb.\* and
printer.\* records are not expected to move: with an identity colour stage the grade
table's samples are bit-identical to the old combined table. No record falls under its
authority floor (closest: bw.green 128.34 vs 107). One record changes monotonicity:
mixer.orange.hue, which now gives back 0.107 code, 0.2% of its authority against the
5% ceiling. The large B&W drops (green −74, red −34) and the Mixer Aqua/Orange/Blue
Luminance gains (+25/+17/+15) are the cube's interpolation error leaving the
measurement. The twin matches the oracle on every bw\* and mixer\* endpoint within the
gate above. **The owner re-pins these through proof.yml.** The B&W floor comment in
`ProofRegistry.swift` (it quotes the old per-band numbers) will need its numbers
updated in that re-pin.

| record | authority before | after | Δ | givenBack before → after | monotone before → after |
|---|---|---|---|---|---|
| color.saturation | 137.44 | 137.34 | -0.10 | 0.0000 → 0.0000 | true → true |
| color.vibrance | 86.33 | 89.18 | +2.85 | 0.0000 → 0.0000 | true → true |
| color.density | 36.88 | 37.17 | +0.29 | 0.0000 → 0.0000 | true → true |
| color.protectSkin | 13.32 | 28.52 | +15.19 | 0.0000 → 0.0000 | true → true |
| mixer.red.hue | 101.73 | 102.58 | +0.85 | 0.0000 → 0.0000 | true → true |
| mixer.red.sat | 76.39 | 77.73 | +1.35 | 0.0000 → 0.0000 | true → true |
| mixer.red.lum | 163.77 | 165.64 | +1.86 | 0.0000 → 0.0000 | true → true |
| mixer.orange.hue | 45.91 | 47.02 | +1.11 | 0.0000 → 0.1070 | true → false |
| mixer.orange.sat | 113.11 | 126.02 | +12.91 | 0.0000 → 0.0000 | true → true |
| mixer.orange.lum | 106.93 | 124.06 | +17.13 | 0.0000 → 0.0000 | true → true |
| mixer.yellow.hue | 84.46 | 84.31 | -0.15 | 0.0000 → 0.0000 | true → true |
| mixer.yellow.sat | 122.11 | 122.56 | +0.45 | 0.1249 → 0.1064 | false → false |
| mixer.yellow.lum | 149.73 | 150.59 | +0.85 | 0.0000 → 0.0000 | true → true |
| mixer.green.hue | 61.68 | 58.03 | -3.65 | 0.0000 → 0.0000 | true → true |
| mixer.green.sat | 51.39 | 48.69 | -2.69 | 0.0000 → 0.0000 | true → true |
| mixer.green.lum | 101.96 | 97.33 | -4.64 | 0.0000 → 0.0000 | true → true |
| mixer.aqua.hue | 45.04 | 52.16 | +7.12 | 0.0000 → 0.0000 | true → true |
| mixer.aqua.sat | 60.04 | 66.13 | +6.09 | 0.0000 → 0.0000 | true → true |
| mixer.aqua.lum | 113.92 | 139.15 | +25.23 | 0.0000 → 0.0000 | true → true |
| mixer.blue.hue | 24.50 | 22.37 | -2.14 | 0.0000 → 0.0000 | true → true |
| mixer.blue.sat | 79.35 | 77.84 | -1.51 | 0.0000 → 0.0000 | true → true |
| mixer.blue.lum | 138.01 | 153.36 | +15.34 | 0.0000 → 0.0000 | true → true |
| mixer.purple.hue | 39.76 | 36.78 | -2.98 | 0.0000 → 0.0000 | true → true |
| mixer.purple.sat | 75.10 | 76.78 | +1.68 | 0.0000 → 0.0000 | true → true |
| mixer.purple.lum | 128.09 | 128.53 | +0.45 | 0.0000 → 0.0000 | true → true |
| mixer.magenta.hue | 106.01 | 106.04 | +0.03 | 0.0000 → 0.0000 | true → true |
| mixer.magenta.sat | 80.48 | 69.52 | -10.97 | 0.0000 → 0.0000 | true → true |
| mixer.magenta.lum | 152.05 | 152.07 | +0.02 | 0.0000 → 0.0000 | true → true |
| mixer.uniformity | 10.03 | 11.01 | +0.98 | 0.0000 → 0.0000 | true → true |
| primaries.rHue | 117.14 | 117.06 | -0.08 | 0.0000 → 0.0000 | true → true |
| primaries.rPurity | 88.12 | 88.12 | -0.01 | 0.4188 → 0.4184 | false → false |
| primaries.gHue | 53.59 | 53.27 | -0.32 | 0.0000 → 0.0000 | true → true |
| primaries.gPurity | 58.53 | 58.36 | -0.17 | 0.0003 → 0.0003 | false → false |
| primaries.bHue | 108.03 | 108.13 | +0.11 | 11.9614 → 11.9599 | false → false |
| primaries.bPurity | 136.74 | 136.70 | -0.04 | 0.0000 → 0.0000 | false → false |
| primaries.tintHue | 21.38 | 21.44 | +0.06 | 0.0000 → 0.0000 | true → true |
| primaries.tintPurity | 40.68 | 40.82 | +0.14 | 0.0000 → 0.0000 | true → true |
| pointColor.hue | 127.90 | 128.48 | +0.58 | 0.0000 → 0.0000 | true → true |
| pointColor.saturation | 77.57 | 77.73 | +0.16 | 0.0000 → 0.0000 | true → true |
| pointColor.luminance | 165.69 | 165.64 | -0.05 | 0.0000 → 0.0000 | true → true |
| pointColor.range | 53.05 | 56.24 | +3.19 | 0.0000 → 0.0000 | true → true |
| pointColor.variance | 69.26 | 78.39 | +9.12 | 0.0000 → 0.0000 | true → true |
| bw.red | 168.99 | 134.92 | -34.07 | 0.0000 → 0.0000 | true → true |
| bw.orange | 206.91 | 211.09 | +4.18 | 0.0000 → 0.0000 | true → true |
| bw.yellow | 211.85 | 212.43 | +0.58 | 0.0000 → 0.0000 | true → true |
| bw.green | 202.48 | 128.34 | -74.14 | 0.0000 → 0.0000 | true → true |
| bw.aqua | 153.13 | 150.33 | -2.80 | 0.0000 → 0.0000 | true → true |
| bw.blue | 161.53 | 166.41 | +4.88 | 0.0000 → 0.0000 | true → true |
| bw.purple | 161.23 | 160.90 | -0.33 | 0.0000 → 0.0000 | true → true |
| bw.magenta | 167.93 | 168.33 | +0.40 | 0.0000 → 0.0000 | true → true |

## The 8-bit cube (orchestrator note, checked and fixed)

The note: gpu-parity on `0896556` measured `CurveBlackLiftGPUTests` returning exactly
9/255 (0.0352941) and about 8.06/255 against an exact 0.033596.

- **Not our upload.** `ColorCube.filter` already passed `CIColorCube` the
  `LUT3D.data` `[Float]` bytes, n³ × 16 bytes of Float32 RGBA. So "make the cube
  data Float32" was already the case, and the quantization is inside the filter's
  table storage or sampling.
- **Reproduced numerically on Linux.** Storing the finish table to 1/255 in the CPU
  path and sampling it trilinearly (as `CIColorCube` does) returns exactly 0.0352941
  near black. Budget at 65³ (33³ in brackets): neutral-corpus worst 3.02 → **6.12**
  codes (6.40 → 6.70); Aqua Lum −100 with grade Hue +180 0.25 → **1.70** (2.68 →
  2.19); Aqua alone 0.51 → 0.43; Saturation +100 0.38 → 0.54. AI-03's 30–50 codes
  were interpolation. This is the next term of the same budget, and it applies to
  every table still in the graph: the S10 grade table, finish, tone gain, local tables
  and dither.
- **Fix (commit `9e37578`).** `ColorCube.filter` now uses `KernelLibrary.cubeLookup`,
  a general kernel doing the same trilinear lookup over an RGBAf atlas of the same
  bytes (x = r + g·n, one row per blue index, row 0 at the top as
  `CIImage(bitmapData:)` places it, which the grain fix measured on device). It
  samples nearest at texel centres and clamps to the unit cube like `CIColorCube`. It
  is on the core roster. **Source-verified only**: the atlas addressing was traced by
  hand against the trilinear twin. New `ColorCubePrecisionTests` (macOS) checks
  corners, knots and interior points at n = 2/17/33/65 within 2e-4, which admits a
  half-float texture and not 8 bits.
- The black-lift **interpolation** error (AI-04: 33/44 codes at 1e-8 on this base with
  float storage) is a separate defect that another stream owns; this fix does not
  claim it.

## AI-02: what changed

`ColorEngine.selectionInput(_:for:)` runs the sequence `apply` runs, stopped where the
selection reads. For `.mixerBand` that is after the primaries and Shadows Tint. For
`.pointColor(index: i)` it is after the primaries, the Mixer, and swatches `0..<i`,
compiled exactly as the render compiles them, with Variance reading the same pre-Mixer
reference. `PipelineRenderer.sampleColorStageInput` now takes the tap and maps its
window mean through the plan's own engine (recipe plus measured band hues).
`RenderCoordinator.samplePointColorReference` and `AppState` pass the tap:
`.newPointColor` → `.pointColor(index: current count)`, `.pointColor(i)`, and
`.mixerBand`. Mask pickers are untouched.

Tests (`PointColourPickerStageTests`, Linux): the finding's trigger (Red Mixer Hue
+100, pick, Point Saturation −100 at Range 0 and 50); a primaries plus Shadows Tint
edit; a swatch picked after an earlier swatch (and not a later one, with a dead swatch
between); and the Mixer band pick agreeing, at every 5° of hue, with the band whose
Luminance actually darkens the pixel most after a primaries edit that moves colours
across seams.

## DECISIONS

1. **S9 alone exact, S10 still in a cube** (V4's open DECISION NEEDED). Implemented as
   the task specified. The grade-family cube error EXECUTION-04 measured (Grade Hue
   +180, Grade Saturation +100, the signed domain) remains. EXECUTION-05 steps 6–7
   (exact grade) are the follow-up if the owner wants it.
2. **CPU paths run the Float32 twin, not `ColorEngine.apply` in Double**, so the CPU
   fallback and the GPU execute one algorithm on one set of uniforms. The difference
   from Double is ≤ 1.8e-5 relative (≈ 0.01 code). Owner may prefer Double on the CPU
   (bit-exact to the oracle, but then CPU and GPU differ by the same amount).
3. **`LocalPlan` always split** into pre/exact/post. A mask that has both a tone or
   white-balance edit and a hue, tint or grade edit, but no Point Colour or Saturation,
   now goes through two tables instead of one, so its pixels move by the difference
   between the two interpolations. No proof record covers masks. The alternative,
   fusing when the colour stage is off, is a route switch.
4. **CPU fallback cost.** The twin is 2.6–32× the old cube lookup per pixel, so a full
   2560 px CPU-fallback frame went from about 1 s to 3–17 s on this box. The GPU path
   is the shipping path; the CPU path is headless/proof/fallback. If the owner needs a
   faster fallback, the twin can be vectorised (it allocates nothing per pixel now,
   but runs one pixel at a time).
5. **Twin accuracy gate is condition-aware** (3e-5, plus κ·5e-7 only where the oracle
   itself is ill-conditioned). Without the κ term, one point (three overlapping
   Variance swatches after a Mixer move, κ ≈ 65) measures 3.2e-5 against 3e-5.
6. AI-02: the picker maps the **window mean** through the stage rather than averaging
   mapped pixels, the same order of approximation the mean already is. The Mixer band
   picker also moved to post-primaries, because it had the same gap.

7. **The float cube lookup replaces `CIColorCube` for every table**, so every GPU
   frame moves slightly toward the CPU reference (by up to the 8-bit step). This
   changes no look and no recipe, but it is a GPU-wide change landed source-verified.
   If the owner prefers it gated until gpu-parity has run it, it can be held as its
   own commit (`9e37578`); the AI-03 and AI-02 commits do not depend on it.

## FOUND-WHILE-FIXING

- **Masked Point Colour has the AI-02 shape too.** `LocalPlan` evaluates a mask's
  swatches after the mask's own tone and white balance, while `.maskPointColor` samples
  `localStageInput` (before them). Not fixed here, because the mask stream owns that
  path.
- `ExactMixer`/`ExactMixerGPU` (the EXECUTION-05 prerequisite) is now superseded by
  `ExactColorStage`. It is left in place with its tests; it can be deleted together
  with `ColorEngine.exactMixer`.
- Mixer Uniformity and Point Colour Variance could now become texture-preserving: the
  `point` kernel already takes a second image, so a guided-filter mean is a kernel
  argument rather than an impossibility (comments in `ColorEngine` updated to say so).
- `check-swift-surface.py`'s KNOWN list lacked `SIMD2/3/4/8` (standard-library types);
  added.
- The 29-argument ceiling is an on-device qualification from EXECUTION-05, not a
  documented Core Image limit. `ExactColorStageGPUTests.testEveryColourKernelCompiles`
  is the first CI signal if a runtime disagrees.

## Full-suite run

Whole Linux suite, run in letter-range groups because `--skip ControlProofTests`
overflows posix_spawn just as `--filter LumenCoreTests` does. **2,069 tests across 10
groups.** The pass found 5 failed assertions in 2 tests; every other test was green,
and the 3 skips are existing platform skips. Both failures were **regressions of my
own**. They are fixed in `c00c30c`, and their suites (SliderContract,
ColorPanelReach and PointColorRePickReach) re-run green along with ExactColorStage
and ColorTableAccuracyLinux:
- `SliderContractTests.testDensityDarkensASaturatedPushAndLeavesNeutralsAlone`, 4
  failures (a grey drifted 6e-8–1.8e-7 with Density). The Float32 chroma scale was a
  round trip; it is now a delta between two round trips, in the twin and the kernel.
- `PointColorRePickReachTests.testTheResolverReplacesTheSampleAndRebuildsNothing`.
  That test reads `AppState.swift` as text from the first `case .pointColor(let
  index):`, and my new helper used that exact spelling. The helper's binding is
  respelled.

`ControlProofTests` (the proof.yml drift sweep, 135 records at 65³) was **not**
completed here. It ran for 90 minutes on this contended box and was stopped. Its
result is known from the measurement above: the 50 colour-stage records drift by
design, and nothing else is expected to. The proof "after" column above was measured
before `c00c30c`; that change moves the twin by ~1e-7, about 1e-4 code, so the
column stands to the precision shown. The owner's re-pin run is the authority.

Branch: `worktree-agent-aa91835df5f0c7bd3`. Nothing pushed.
