# WS-40 Grain: report

Controls: `look.grain.amount/size/roughness` (creative), `look.filmLab.grain.*` (stock).
Branch `quality/ws-40-grain`. Verifier: **PASS** (fresh agent, spec + diff only).
GPU parity (spec line 12): see "CI" at the end.

## For the owner

- The old grain was one small noise tile repeated across the photo every ~72 px. That was the "print" you saw. It is gone.
- Grain is now computed per pixel with no repeat, at a real grain scale: Size 25 is ~1.2 px on a 6000 px file, not 20 px blotches.
- Amount 100 is about twice as strong as before (12 codes on mid grey), like Lightroom's heavy end. Amount 50 looks like ISO 400-800 film.
- Size and Roughness both do something visible across their whole range. Roughness 100 gives clumpy, mixed-size grain.
- Look at the three images below. Your call: Tri-X at grain 100 is very strong (16 codes; 31 at push +2).

Best evidence:
1. `evidence/02_p6929_wall_a50_s25.png`: the A7 IV wall, before (tiled blotches) and after (fine grain).
2. `evidence/06_size_sweep_6000eq.png`: Size 0 to 100, before and after, with the grain amplified 4x.
3. `evidence/07_roughness_sweep_6000eq.png`: Roughness 0 to 100.

## What was wrong (audit, measured)

- **Tiling.** One 128x128 value-noise plate was scaled and tiled. On `flat_grey` at amount 100, long edge 1024, the pattern repeated every 72 px.
  - Autocorrelation 0.95 at lag 71, and 0.22 / 0.21 / 0.19 / 0.27 at lags 64 / 128 / 256 / 512.
  - The tiling peak in the 2D spectrum was 1.2e7 times its local median.
- **Soft blobs, not grain.** The coarsest octave was 16 texels and carried ~75% of the variance.
  - Correlation length was 6 px at 1024 and ~36 px at 6000.
  - On 6929 at amount 60, the wall showed 10-30 px stains and the foliage showed no grain at all.
- **Size had a dead range.** Size 0 and Size 25 rendered identically at 1024, because of a half-pixel floor. Preview and export disagreed by 1.9x at Size 0.
- **Roughness did almost nothing.** std went 4.43 → 4.40 over the whole range, with the same tile every time.
- **Weak, smeared colour on stocks.** Grain was 5.9 codes at amount 100. On Portra 400, chroma noise was 0.85 of the luma noise, which showed as magenta/green blotches.

## What changed

**New `Sources/LumenCore/Engine/GrainField.swift`.** Stateless, per-pixel sparse-convolution grain, in the spirit of the boolean model in Newson et al. 2017.
- **Lattice.** Each cell of a lattice holds a few grains. Each grain has a hashed position, a ±height and a radius. A pixel sums the grains of its 3x3 neighbour cells. The cell edge is at least the largest grain's support, so that sum is exact.
- **Hash.** Two lanes, cubed modulo the primes 4091 and 4079 and crossed every round. Every intermediate is an integer below 2^24, so it is exact in float32 on the GPU and in Double on the CPU. CPU and GPU draw identical grains.
  - The verifier checked this exhaustively.
  - There is no period inside 4091 x 4079 cells.
- **Grain profile.** `(1 - d²/R²)²` with `R² = r² + Rp²`.
  - `Rp` = 0.825 px is a pixel aperture, matched to a 1 px box.
  - The amplitude is `r²/R²`, which conserves ink, and the field is normalised to the resolved variance. Sub-pixel grain therefore averages down exactly as downsampling would. That is what makes a preview look like the export at the same viewing size.
- **Zero-mean heights.** This makes the field exactly stationary in mean and variance with a fixed grain count per cell, so there is no cell grid.
- **Size.** Creative grain radius is 7.2·10^(size/100) µm at a 35 mm gate, which is 0.6 to 6 px on a 6000 px frame. It is relative to the frame's long edge.
  - Stocks use half their pitch at the gate, times each layer's size scale, with push scaling.
  - The half-pixel floor is gone.
- **Roughness.** It moves three things together:
  - grains per cell, 6 → 1.5 (sparser and more distinct);
  - radius spread, 0 → ±0.8 stops;
  - a clump layer at 2x radius, weight 0.7·r².
  The cells are the same at every Roughness, so dragging the slider morphs one pattern rather than reshuffling it.
- **Amplitude.** It stays in the density domain with the same √(p(1-p)) envelope: strongest in the midtones, falling to zero at both ends.
  - Creative grain is luminance-only. One density offset is applied to all three channels, so hue and chroma are untouched.
  - Stocks keep one field per dye layer, with the luma/own mix. Monochrome stocks get one field.
  - `densityScale` went 0.12 → 0.30.
  - Dye-layer chroma went 0.30 / 0.15 → 0.15 / 0.075 (negative / reversal).
- **What was removed.** The plate generator, `GrainPlateMemo`, `plateEncodeScale`, `sample`, octave band-limiting and the affine tiling are all deleted.

**GPU (`Kernels.swift`, `RenderGraph`).**
- The new generator kernel `lumenGrainField` evaluates the same field at `destCoord`, with the frame origin and height passed in so its y runs top-down like the reference.
- Every constant is interpolated from `GrainField`.
- `RenderGraph.grainPlate(_:extent:longEdge:)` keeps its signature, but now returns this full-frame field instead of a tiled plate. `PipelineRenderer` (owned by WS-01) therefore needs no edit.
- `lumenGrain` reads the raw field and gained the luminance-only mode.

**CPU (`ReferenceRenderer.applyGrain`).** The same field and the same modes. A 1024 px render takes 1.3 s.

## Spec verdicts

Measured by the verifier with `tools/run_spec.sh`: 35 of 35 rows pass. Line 12 is checked on macOS CI.

| # | line | before | after | verdict |
|---|---|---|---|---|
| 1a | ring-mean \|acf\| beyond 3x correlation length | 0.10 | 0.018 | PASS (< 0.05) |
| 1b | acf at lags 64/128/256/512 | 1.00 | 0.021 | PASS (< 0.05) |
| 1c | any single 2D lag | 1.04 | 0.048 | PASS (< 0.15) |
| 2a | 2D spectrum spike (white noise ≈ 12) | 1.4e3 | 15 | PASS (< 60) |
| 2b | radial spectrum spike | 2.1e3 | 1.55 | PASS (< 2.0) |
| 3a/b | std vs Amount 0/25/50/75/100 | 0/1.49/2.95/4.41/5.87 | 0/2.99/5.97/8.97/12.00, R² 1.0000 | PASS |
| 3c/d/e | Amount 0 is an exact identity (8-bit, creative and Portra; float unit test) | 0 | 0, test passes | PASS |
| 4a | std at Amount 100, Size 25, mid grey, 6000 px equivalent | 5.87 | 12.0 | PASS (10-14) |
| 4b | 6929 at Amount 50, Size 25: std / correlation length | 2.21 / 7.8 px | 2.72 / 0.74 px | PASS |
| 4c | 6929 at Amount 50, Size 50: std / correlation length | 2.22 / 13.2 px | 3.86 / 0.90 px | PASS |
| 5a | std vs luminance against the √(p(1-p)) prediction | 3% | 4.1% | PASS (≤ 20%) |
| 5b | peak bin / black-end ratio / white-end ratio | – | 143 / 0.10 / 0.39 | PASS |
| 6a/b | correlation length at Size 0/25/50/75/100, 6000 px eq | 11.9/19.9/35.2/–/98.3 | 0.82/1.18/1.74/2.85/4.95, min step 1.44x | PASS |
| 7a | std change over Roughness | – | 2.9% | PASS (< 15%) |
| 7b | kurtosis rise over Roughness | – | 3.68 → 4.12 | PASS |
| 7c | local-energy CV over Roughness | 1.09x | 0.368 → 0.587 (1.59x) | PASS (≥ 1.2x) |
| 8 | preview vs export: 1024 against 2048/2 and 4096/4 | bins 0-18.4 (fail) | std 1.013-1.042, per-bin 0.89-1.09, band 0.978-1.006 | PASS |
| 9 | isotropy, x/y correlation length | 1.11-1.32 | 0.991-1.015 | PASS |
| 10a/b | creative chroma / luma (grey / colorchecker) | – / 0.37 | 0.0003 / 0.063 | PASS (< 0.10) |
| 10c | Portra chroma / luma (6000 eq, 1024) | 0.85 / 0.59 | 0.37 / 0.29, 0.32 / 0.34 | PASS (0.10-0.50) |
| 10d | Tri-X chroma / luma | – | 0.0002 | PASS |
| 11 | determinism: same render byte-identical; another seed uncorrelated | – | 0; test passes | PASS |
| 12 | CPU/GPU parity < 1e-3 (KernelGoldenTests) | – | constants shared by construction; CI | see CI |
| 13 | no plate or tiling code left (grep) | 183 hits | 0 | PASS |
| V1-V3 | visual: reads as film grain, sweeps monotone, stocks right | fail (tiling) | verifier and lead: pass | PASS |

The verifier also tried to break it, and nothing failed:
- 5 seeds × 3 sizes × 3 roughnesses at field level: spike 11.5-21.8, no cell grid (phase-folded energy CV ≤ 0.02), no seams.
- Every stock at push -1, 0 and +2.
- Odd frame sizes: 1x1, 2x2, 1x50, 6000x3.
- NaN, ±inf and negative pixels.
- 5 more corpus photos.
- With B&W on, Film Lab at strength 0, and a vignette.
- 4800 vs 1600 long edge: std within 3%.

## Tests changed

The old tests encoded the plate design, so replacing them was expected. Nothing was skipped or loosened to get green.

**Deleted: `GrainPlateTests`, all 10 tests.** They tested the plate's packing, memo, octaves, persistence and half-pixel floor, none of which exist any more.

**`GrainParityScanTests`.**
- The 4 plate scans became `testNoPlateCodeIsLeft`, `testTheGrainFieldKernelInterpolatesItsConstants` and `testBothRenderersGetTheFieldFromThePlan`.

**`CreativeGrainTests`.**
- Size, gate, roughness and stock tests rewritten for the new model.
- The 5 floor tests and 5 octave tests are replaced by preview = export-downsampled tests.

**`EngineIntegrationTests` and `ScaleHonestyTests`.**
- They moved to `grainRadiusPixels`.
- "Same grain size at every render size" became "the preview is the export downsampled". This deliberately inverts the old property, because the old one was the dead range.

**`KernelGoldenTests` (macOS only).**
- New: a generator-vs-reference field test.
- `testGrainMatchesTheReferenceRenderer` now covers 4 grains and 4 odd frame sizes, 3 of them with a non-zero origin.
- The colour-stock check used to be statistical. It is now pixel-exact at < 1e-3.

**New: `GrainSpecTests`, 12 tests.** Identity, determinism, seed, no period and no grid, float32-exact hash, monotone size, roughness character, preview = export, luminance-only, clamping.

**Proof records.** The 5 grain records were regenerated (`LUMEN_RECORD_PROOFS=1`). The declared reversals were restated at their measured values:
- `look.grain.size`: 61.6 of authority 110.
- `film.grain.size`: 25.5.
- `look.grain.roughness`: gives back 0.03 of 72.7.

**Gates.**
- `swift build --target LumenCore --target LumenRender`: clean.
- `swift test` cannot build on this Linux toolchain, at the base commit too. Swift 6.0.3 rejects trailing commas at `Sources/LumenApp/CompareView.swift:326,569` (NEEDS N3).
- With that comma fix applied locally and not committed, the release test bundle runs 3042 LumenCoreTests: 0 failures, 6 pre-existing env-gated skips.

## Not fixed / for a human

- **Per-photo seed (NEEDS N1).** Every photo still uses `defaultPlateSeed`, so a burst shares one grain pattern. The plumbing belongs to WS-01; the seed parameter is ready on every call site.
- **GPU cost is unmeasured.** The new kernel does about 1,500 integer-exact modulo operations per layer per pixel, against one texture fetch before. Colour stocks run 3-6 layers. Preview frame time during drags needs measuring on a Mac.
- **Strength is a taste call.** Tri-X at 100 is 16 codes (31 at push +2), and stocks are generally stronger than before because they share `densityScale` with the creative grain.
- **Deep shadows.** Grain in the deepest blacks (codes 0-16) is faint, 0.5-0.9 codes against 3.5 in the midtones. That is the density envelope working as film does, but some users may want more there.
- **No Lightroom exports.** The amplitude and size targets are sourced estimates. Exporting the two grain presets in `docs/quality/lightroom-reference` from Lightroom would settle them.

## CI

On `7e6c807` (the kernel commit), **GPU parity passed.** That run includes `testTheGrainFieldGeneratorIsTheReferenceField` and `testGrainMatchesTheReferenceRenderer` at < 1e-3, so spec line 12 is **PASS**. The proof sweep also passed.

On `ab4149a`, every CI job passed except `fixtures-linux`:
- Passed: build-macos, test-fast, engine-linux, app-bundle, UI layout and the proof sweep.
- `fixtures-linux` failed in its Swift-surface checker on two things in `GrainSpecTests`: a multi-line `var` list the checker cannot scope, and `M_E`, which it does not know. Both are fixed in the final commit.
- The checker's remaining findings were already on the base branch (in `RecipeKeys`, `Metrics`, `main.swift`, `AppState`, `PanelLayout` and `LumenType`), in files this lane does not touch.
