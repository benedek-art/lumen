# M9 · Mask performance · acceptance spec

Owner's complaint: masks are "slow, glitchy". Target: Lightroom-class responsiveness.
Slider drags with any mask active stay at display rate, gradient handle drags stay at
display rate, a brush dab is visible within one frame.

macOS-only lines run in `gpu-parity.yml` (`swift test --filter LumenPipelineTests`);
Linux lines run with `swift test --filter LumenCoreTests` (bench: `LUMEN_BENCH=1 swift
test -c release -Xswiftc -enable-testing --filter MaskRasterCostBenchTests`).

## Measurable

1. **Adjustment-only edits never rasterize.** Changing `mask.adjust.*` on a mask whose
   alpha comes from the CPU raster path adds 0 to `MaskRasterCache.currentStats.bakes`,
   on a draft frame AND on a settle frame at 1100 px (above the 1024 proxy).
   `MaskSpeedTests.testAdjustmentOnlyEditsNeverRebakeAtSettle` (macOS CI).
2. **A settle raster is retained.** A second settle with an identical key is a hit
   (bakes delta 0) for a raster up to the 4096 interactive ceiling; the retained bytes
   never exceed `MaskRasterCache.settleResidencyBudget`; a raster above the interactive
   ceiling (an export) is not retained.
   `MaskSpeedTests.testSettleRastersAreHeldWithinTheirByteBudget` (macOS CI).
3. **Range masks never touch the CPU.** A mask made of any of linear, radial, luminance
   range, luminosity and colour range, with whole-mask invert and Levels, renders with 0
   bakes and 0 stage readbacks (`LazyStageBuffer.renderCount` unchanged) on draft and
   settle. `MaskSpeedTests.testRangeMasksTakeTheGPUPath` (macOS CI).
4. **GPU kernels match the CPU definition.** For luminance range (every channel, three
   smoothness values), luminosity (three series, levels 1 and 3.5) and colour range (1,
   3 and 8 samples, three Refine values), plus Levels, the GPU alpha against
   `MaskRaster.rasterize`/`refined` on the same stage buffer at 256², 331×197 and
   128×320: worst pixel < 2e-3, and < 0.1 % of pixels differ by more than 1e-3.
   `MaskGPUParityTests.testRangeKernelsMatchTheReference` (macOS CI).
5. **Fast-path eligibility is exact.** Any refine step that is not pointwise (Refine
   feather with radius ≥ 1, Edge ≠ 0, Blur σ > 0.05), any brush, polygon, similarity,
   AI, depth or reference component sends the mask to the CPU path; the existing
   `testAnythingNeedingThePictureOrTheChainIsRefused` stays green.
6. **A brush dab is visible in the first draft frame after commit.** After one stroke
   is appended to a plain (no refine) brush mask, the next draft frame is an exact key
   bake, not a stale serve: `staleServes` delta 0, and the frame's alpha equals a cold
   render's. `MaskSpeedTests.testACheapBrushBakeIsNeverServedStale` (macOS CI).
7. **No regression.** Every pre-existing LumenPipelineTests and LumenCoreTests test
   passes, except tests that encoded the old refusal to hold settle rasters, which are
   updated in the same commit with the reason in REPORT.md.

## Timing (report, not gate)

8. Per-operation CPU cost before and after at 1024×683, 4096×2731, 6000×4000 (Linux
   container, release), and the expected per-frame mask cost on an M-series Mac for: a
   global slider drag with a luminance-range mask; a radial handle drag; a colour-range
   Refine drag; a brush stroke commit.

## Visual (human)

9. Dragging Exposure with a sky luminance-range mask active: the band's edge moves with
   the tones on every frame, no lag-then-snap at the pause.
10. Dragging a gradient intersected with a luminance range: the selection follows the
    handle at display rate with no trailing raster.
