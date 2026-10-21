# M9 · Mask performance · report

Branch `quality/m9-mask-perf` from `claude/inspiring-dirac-ulgpch`.

## For the owner

1. Drag Exposure with a sky Luminance Range (or Colour Range) mask on: the band edge should move with the tones every frame, with no snap when you stop.
2. Drag a Linear gradient that intersects a Luminance Range: the selection should stick to the handle.
3. Paint one plain brush stroke (no Refine) at fit view: is the effect there the moment you release, or a frame later? The 8 ms rule depends on your Mac.
4. With a Refine/AI mask, move a mask Adjust slider and release: the settle should be instant now. Then move a global slider and release: that still re-rasterizes (expected, see "not fixed").
5. Open Activity Monitor during a session with 6+ masks: memory should rise by at most ~200 MB over the base build.

## What was slow, and why

Per frame, before this lane:

- **Every non-gradient mask was a CPU raster.** A luminance band, luminosity or colour range is a pointwise function of the stage input, but it took the hair-matte path: on every global tone edit the key changed. A draft frame then wore the previous raster (the "glitchy" lag-then-snap), and every settle rasterized again at up to 4096 px.
- **Settle rasters were never retained.** `MaskRasterCache.store` refused anything above the 1024 proxy, so every settle re-rasterized every CPU mask at the render size, including after adjustment-only edits that change no alpha. The complete reference-closure key (already in the base) made holding them legal. The refusal had simply outlived its reason.
- **A cheap bake was still served stale.** A brush stroke committed on mouse-up showed the old mask for a frame and popped in later.
- **The overlay** (`renderMaskAlpha`) rasterized on the CPU on every refresh.

## What changed

- `Kernels.swift`: four new kernels (`maskLumaRange`, `maskLuminosity`, `maskColorRef`, `maskLevels`), rostered in `unavailableMaskKernels`. `parametricMasksAvailable` is now independent of them, and `rangeMasksAvailable` is new.
- `MaskGPU.swift`:
  - `isGPUEvaluable` accepts any stack of linear, radial, lumaRange, luminosity and colorRange whose refine chain is pointwise at that resolution (refine radius < 1, Edge 0, Blur σ ≤ 0.05).
  - `alpha(for:extent:source:)` folds them on the GPU with whole-mask invert and Levels.
  - Every number comes from `MaskRaster`'s definition, which stays the CPU twin.
- `PipelineRenderer.makeGraph` (mask block):
  - Eligible masks are evaluated first, over `gpuMaskStage` (the same `localStageInput(maskSource:)` graph at the decode's extent, never read back).
  - Only the masks the GPU path declined build the CPU stage and keys.
  - `renderMaskAlpha` takes the GPU route too.
- `MaskRasterCache.swift`:
  - New settle rung: one raster per mask up to the 4096 ceiling, under a 192 MB byte budget. Exports are still not held.
  - Injected synchronous-bake budget (8 ms in the renderer): a draft miss on a mask whose last draft bake fit the budget bakes in line instead of serving stale.

## Spec verdicts

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | Adjustment-only edits rasterize nothing, draft and settle | CI_PENDING | `MaskSpeedTests.testAdjustmentOnlyEditsNeverRebakeAtSettle` |
| 2 | Settle rasters held within budget, exports not | CI_PENDING | `MaskPerfTests.testTheRasterCacheHoldsSettleRastersWithinItsByteBudget` |
| 3 | Range masks: 0 bakes, 0 readbacks, draft and settle | CI_PENDING | `MaskSpeedTests.testRangeMasksTakeTheGPUPath`, `…OverTheRealStageIsTheCPUDefinition` |
| 4 | Kernel parity at 3 sizes, RGBAf and RGBAh | CI_PENDING | `MaskRangeGPUParityTests` |
| 5 | Eligibility exact | CI_PENDING | `MaskRangeGPUParityTests.testOnlyPointwiseChainsAndRangeKindsTakeTheGPUPath` |
| 6 | Cheap bake never stale; expensive still is | CI_PENDING | `MaskSpeedTests.testACheapBrushBakeIsNeverServedStale`, `testAnExpensiveBakeStillServesStaleOnADraft` |
| 7 | No regression | Linux PASS (3045 LumenCoreTests); macOS CI_PENDING | see below |
| 8 | Timings | reported below | `evidence/bench-cpu-raster.txt` |
| 9, 10 | Visual | human | "For the owner" 1 and 2 |

**Tests changed, and why:**

- `MaskPerfTests.testTheRasterCacheStillRefusesToHoldASettleSizedRaster` is now `testTheRasterCacheHoldsSettleRastersWithinItsByteBudget`. The refusal guarded an incomplete key, and the base key now closes over the whole reference closure (`maskSelectionFingerprint(MaskDependency.closure)`).
- `MaskReferencePipelineTests`: two band fixtures (`testAPictureMaskReadsThePictureBackOnlyWhenItsRasterBakes`, the gain-map test) get `refine.edge = 10`. A plain band no longer reaches the CPU path those tests are about. The gain-map test also gains a hits-delta assertion, since a held settle raster could otherwise satisfy "1 bake" with the box broken.

## Timings

CPU raster cost per operation on this Linux container (release build, p50; full table in `evidence/bench-cpu-raster.txt`, `MaskRasterCostBenchTests`, `LUMEN_BENCH=1`):

| op | 1024×683 | 4096×2731 | 6000×4000 |
|---|---|---|---|
| luminance range | 13.8 ms | 243 ms | 608 ms |
| luminosity | 45.7 | 756 | 1684 |
| colour range, 1 sample | 74.2 | 1208 | 2634 |
| colour range, 4 samples | 124 | 1642 | 3610 |
| refine identity chain | 4.1 | 93 | 203 |
| refine Levels | 11.6 | 194 | 437 |
| refine guided (feather 30) | 95.5 | 2478 | 5795 |
| polygon | 22.3 | 378 | 830 |
| brush 10 strokes, cold | 69.7 | 1074 | 2319 |

After this lane, the CPU functions themselves are unchanged (they are other lanes'). What changed is which of them run per frame:

| scenario | before, per event | after, per event |
|---|---|---|
| global slider drag, luminance-range mask | stale raster + background 1024 bake (~14 + 4 ms CPU), stage readback; settle 4096 bake ~340 ms | 0 CPU work; GPU stage graph + 1 kernel pass |
| colour-range Refine drag | stale + background 74 ms bake; settle ~1.3 s | 0 CPU; GPU stage + 1 pass per sample |
| gradient ∩ luminance range handle drag | CPU, stale every event | GPU, exact every event |
| mask Adjust slider release, refined mask at 4096 | full re-raster, ~2.5 s here | cache hit, 0 |
| plain brush stroke commit, draft | previous raster for ≥ 1 frame | exact on the first frame when the bake ≤ 8 ms |

**Expected on an M-series Mac (a guess; nothing here ran on Apple hardware).** I assume a P-core runs 2.5–4× this container's core.

- A pointwise kernel over a 2048-px draft (2.8 MP, half float) moves ~45 MB, under 1 ms on an M1 GPU. The stage graph it samples (WB, tone, colour, grade, no spatial stages) is a second CI graph, likely 1–3 ms at 2048 and 3–8 ms at a 4096 settle.
- So a drag with one or two range masks should add roughly 2–5 ms of GPU per frame, which fits 60 Hz if the base frame already does. It also never waits on the CPU.
- A settle after an adjustment-only edit with a refined mask goes from ~0.6–1 s to ~0.
- A first-frame brush dab at 1024 (one stroke resume plus fold) is probably 5–15 ms on the Mac, so the 8 ms rule will catch some strokes and not others. Owner item 3 checks this.

## Not fixed (see NEEDS.md)

- Edge shift, Blur and guided Refine keep a mask on the CPU. So do brush, polygon, similarity, AI and depth.
- A global tone edit with such a mask still re-rasterizes at settle, synchronously, at up to 4096.
- Not measured: whether Core Image shares the colour-range stage input across the per-sample passes or evaluates it up to eight times. Instruments on the owner's Mac would show it.
- Kernel edge cases where GPU and CPU differ, none reachable from real stage values: a NaN stage pixel can be selected on the GPU but not on the CPU, and finite values above 3e38 floor to −16 EV.
- The Linux toolchain cannot compile the base (`CompareView.swift` trailing commas, NEEDS.md 1).

## Verification

- Verifier round 1: FAIL. Fixed in `b74f81e`:
  - The cheap-bake rule deadlocked `testASettleCancelsTheDragsQueuedDraftRaster` and broke three `MaskRasterCacheTests`. Now injected, default 0.
  - A declined GPU mask could fall back with no picture. GPU alphas are now computed first.
  - The settle memo exceeded the memory budget. Removed.
  - Several tests were weaker than the spec. Strengthened.
  - The macOS compile failed on a test typo.
- macOS CI: CI_PENDING.
