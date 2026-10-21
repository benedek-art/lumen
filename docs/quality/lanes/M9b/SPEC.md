# M9b · Range masks back on the GPU · spec

Scope: `MaskGPU`'s range path (`KernelLibrary.maskLumaRange`, `maskColorRef`, the new
measurement-denoise kernels and `MaskRangeMeasure`) must compute lane M4's CPU definition
(`MaskRaster.lumaRangePlane`, `colorRangePlane`, `rangeMeasured`), and
`MaskGPU.rangeKindsOnGPU` goes back to true. The audit is NEEDS.md item 6 of lane M9 and
the macOS failures it cites; the acceptance tests existed before this lane and are not
changed. Measured on macOS CI (`gpu-parity.yml`, `ci.yml` test-fast) unless marked Linux.

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| 1 | Every range kernel case (bands on six channels at Smooth 0/25/100, luminosity, colour 1/3/8 samples at Refine 0/50/100, stacks, invert, Levels) matches `MaskRaster.combine` at 256², 331×197, 128×320 | share of pixels past 1e-3 < 1e-3; soft cases worst < 2e-3 (unchanged) | `MaskRangeGPUParityTests.testRangeKernelsMatchTheReference` |
| 2 | Same cases in half float | share past 4e-3 < 5e-3 (unchanged) | `testRangeKernelsHoldInHalfFloat` |
| 3 | GPU alpha over the real stage input (600 px, denoise on at r = 1) equals the CPU definition over that stage read back | share past 2e-3 < 1e-3 (unchanged) | `MaskSpeedTests.testTheRangeAlphaOverTheRealStageIsTheCPUDefinition` |
| 4 | Range masks never rasterize on the CPU and never read the stage back, at settle (1100 px, denoise on) and on drafts | 0 bakes, 0 stage reads (unchanged) | `MaskSpeedTests.testRangeMasksTakeTheGPUPath` |
| 5 | The six previously skipped tests run (none skipped) | 6 executed | test logs |
| 6 | The denoise itself, on a noisy frame with edges, at r = 1 and r = 2 (640×427, 1200×800): bands (luma, red, min) at Smooth 0/25/100, colour 1/3 samples at Refine 25/100, a 4-component stack, inverted through Levels | same thresholds as line 1 | new `testDenoisedRangesMatchTheReference` |
| 7 | Line 6 in half float, 640×427 | same thresholds as line 2 | new `testDenoisedRangesHoldInHalfFloat` |
| 8 | The GPU noise table equals `MaskRaster.rangeNoiseTable` per bin, for the EV plane and OKLab L, a, b | relative error ≤ 1e-3 per bin | new `testTheNoiseTableIsTheReferences` |
| 9 | The noise table is reduced on the GPU (Metal), with no CPU fallback, in lines 6 and 8 | `NoiseTableKernel.cpuFallbacks` unchanged | lines 6, 8 |
| 10 | CPU definition unchanged: the refactor of `rangeMeasured` (table extracted into `rangeNoiseTable` / `rangeNoiseVariance`) is behaviour-neutral | all M4 range tests pass on Linux | `swift test --filter LumenCoreTests` (Linux) |
| 11 | No regression | gpu-parity and test-fast green apart from failures proven pre-existing on the base | macOS CI |
| 12 | Per-drag cost before/after reported | reported | `MaskRangeCostBenchTests` (macOS, `LUMEN_BENCH=1`) and the CPU bench |

Visual claims (human):

- V1. Drag Exposure with a sky Brightness Range on: the band's edge moves with the tones on
  every frame, with no snap when the drag stops.
- V2. On an ISO 3200+ frame, the band edge through a dark tone reads the same in the loupe
  during a drag as after release (soft, not salty).
