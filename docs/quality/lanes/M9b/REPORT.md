# M9b · Range masks back on the GPU · report

**Status: PAUSED by the director before verification.** The code is done and macOS GPU parity
passed every range test on eb75b22. The fresh verifier was cut off by a usage limit before it
reported, so this lane has no verifier verdict yet. Not ready to merge until a verifier passes
it and gpu-parity is green on the final sha.

## For the owner

1. Drag Exposure with a sky Brightness Range on: the band edge should move with the tones every frame, with no snap at release.
2. On an ISO 3200+ frame, a band edge through a dark tone should look the same (soft, not salty) during a drag and after it.
3. Drag Refine on a Colour Range: the selection should update live and match the export.

## What changed

- `KernelLibrary.maskLumaRange`: M4's centred shoulders (`lumaRangeValue`), open ends, step at Smooth 0. Reads the raw EV plus a correction image.
- `KernelLibrary.maskColorRef`: M4's shading-invariant distance (chromaticity at the sample's lightness, along/across split, toward-grey cap, separate EV gate).
- `MaskRangeMeasure` (new): M4's measurement denoise on the GPU. The per-bin noise table is an exact radix-select median in Metal compute inside a `CIImageProcessorKernel` (no readback; CPU fallback only without a Metal device). The two guided passes are four CIKL kernels each, written in a relative, separable form so half-float intermediates never hold an EV level, only differences.
- `MaskGPU.rangeKindsOnGPU = true`; the six skipped tests are un-skipped, unchanged.
- `MaskRaster.rangeMeasured`: the noise table was extracted into `rangeNoiseTable` / `rangeNoiseVariance` (behaviour-neutral) and a few constants made public for the GPU side.
- New tests: denoise parity at r = 1 and 2 on a noisy frame (float and half), GPU noise table vs CPU per bin, Metal path pinned (no CPU fallback). Bench `MaskRangeCostBenchTests` behind `LUMEN_BENCH=1`.

## Spec lines (macOS gpu-parity run 39588525479 on eb75b22)

| # | Result |
|---|---|
| 1 | PASS `testRangeKernelsMatchTheReference` |
| 2 | PASS `testRangeKernelsHoldInHalfFloat` |
| 3 | PASS `testTheRangeAlphaOverTheRealStageIsTheCPUDefinition` |
| 4 | PASS `testRangeMasksTakeTheGPUPath` |
| 5 | PASS: all six executed, none skipped (plus `testTheColourFixtureSelectsSomething`, `testOnlyPointwiseChainsAndRangeKindsTakeTheGPUPath`) |
| 6 | PASS `testDenoisedRangesMatchTheReference` (on eb75b22 with 3 sizes; 112cff6 trimmed it to 2 sizes for CI time, not yet re-run) |
| 7 | PASS `testDenoisedRangesHoldInHalfFloat` |
| 8 | PASS `testTheNoiseTableIsTheReferences` (≤ 1e-3 relative per bin) |
| 9 | PASS (cpuFallbacks unchanged in 6 and 8) |
| 10 | PASS on Linux: 3379 LumenCoreTests, 0 failures |
| 11 | gpu-parity red only on `LocalSofteningScaleTests` and `ToneMaskGPUParityTests`, which 84698be lists as pre-existing reds owned by M8 and T1. Not re-proven on the base by this lane. test-fast (ci.yml) result not collected. |
| 12 | below |
| V1, V2 | human, owner items 1 and 2 |

## Per-drag cost

GPU alpha per frame on the macOS CI runner (paravirtual GPU, half float, includes the denoise; `M9b-bench`):

| | 1024×683 (r 1) | 2048×1365 (r 3) | 4096×2731 (r 5) |
|---|---|---|---|
| luminance range | 3.4 ms | 8.2 ms | 29 ms |
| colour range, 3 samples | 7.8 ms | 12.5 ms | 35 ms |

Before (range masks on the CPU since 84698be): every drag event re-keys the raster, the frame wears the previous raster, and a background bake runs. M4's own Linux release numbers are 0.48–0.63 s (luminance) and 1.3–1.5 s (colour) per bake at 2400 px. The same CI runner's debug-build CPU raster was 4.0 s / 11.3 s at 1024 px, but a debug build is not a fair baseline. A release CPU bench on Linux was started and did not finish before the pause.

## Not done

- Verifier: not run to completion (usage limit). Must be redone.
- gpu-parity and test-fast on the final sha 112cff6 not yet checked.
- READY not sent.
