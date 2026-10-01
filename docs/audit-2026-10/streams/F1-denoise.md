# F1-denoise — GPU path for Tier-1 classical NR

Branch: `worktree-agent-a11f3214f88a3b179`, based on `claude/jolly-sagan-k7ch7z` @ 0896556.

## The finding that shapes everything else

The task said the GPU path "still rides Apple's decode-stage NR". **That was already untrue.**
The sentence came from the README's phase table (README.md:39). The code says:

- `RenderGraph.colorStageInput` calls `applyDenoise` (Sources/LumenPipeline/RenderGraph.swift:136)
  on every interactive and export render, except the mask-source proxy. The stage is the full
  Tier 1: hot pixels, the pedestal-centred VST, the Y0U0V0 rotation, a five-band à-trous stack
  with edge-aware soft shrinkage, the luminance-guided blotch pass, and the inverse. That is nine
  kernels, all parameterized from `ClassicalDenoise.gpuPlan` (RenderGraph.swift:350–464).
- Apple's decode NR is zero under Off and Classic: `filter.luminanceNoiseReductionAmount` and
  `colorNoiseReductionAmount` are set from `Denoise.appleStandIn` (AppleRawSource.swift:344–346),
  which returns `(0, 0)` for `.off` and `.classic` (Recipe.swift:1182–1193). The decode cache key
  carries the same values (AppleRawSource.swift:234–241), and the mapping is tested on Linux
  (EngineTests.swift:1092–1112). Only `.ai` drives the decoder, as Tier 2's stand-in until a model
  ships. Per docs/07, Tier 1 runs after Tier 2 as a finishing pass, so `.ai` with a hand-set master
  running both is the specified behaviour.
- The goldens exist and pass on the macOS lane. GPU parity run 36807716802 (head 0896556) passed
  testAtrousStep…, testEdgeMap…, testEdgeBlur…, testTheVSTAndRotationRoundTrip,
  testDenoiseMatchesTheReferenceEngine (bar 2e-4), testDenoiseBlotchPassTracksTheReference,
  testHotPixelKernelMatchesTheReference and testDenoiseReachesTheShippingGraph.
- Enabled by default already. `Recipe()` is `.classic` with ISO-adaptive Colour, and the seven
  `denoise.*` proof records pin it. No default-off switch is needed, and adding one would move
  every existing RAW edit.

So there was nothing to build. The work was to close the parity and tiling questions the existing
goldens could not answer, and to correct the stale claim.

## Items

| # | Item | Status | Commit | Red/green | Proof records |
|---|---|---|---|---|---|
| 1 | S3 export halo was 24 px. The stage reaches 79. | FIXED | daec51e | Linux: with `classicOverlap = 24` substituted, DenoiseTests has 2 failures (24 < 79; seam error 1.58e-5 > 1e-6). Restored: DenoiseTests 22/22, EngineIntegrationTests 62/62. | none (constant has no caller in Sources) |
| 2 | GPU goldens never exercised region/ROI rendering, an interior, preview noise scale, or RGBAh | FIXED (tests only) | 675a1b7 | Source-verified (macOS-only target), traced by hand. Breaking `bSplinePass`'s `reach` to `s` would under-fetch and fail the region test. | none |
| 3 | README said the GPU path rides Apple's NR | FIXED (doc) | 99d2b68 | n/a | none |

### 1 — `ClassicalDenoise.receptiveField(levels:)` and `TilePlan.classicOverlap`

docs/14 §6.3 and `TilePlan.classicOverlap` declared a 24 px halo for S3. That number covers only
the deepest band's own support. The real chain is 1 (hot pixels) + 62 (five chained B3 bands,
2+4+8+16+32) + 16 (the blotch guided filter's two radius-8 boxes) = **79 px**. The GPU stage's
`roiCallback` reaches add up to the same sum. The new helper counts it, and `classicOverlap` is now
derived from it.

Measured on the reference: a structured ISO 6400 frame, 240 px tiles, every pass on. The worst seam
error was **1.58e-5 at 24 px** and **0.0 at 79 px**. The probe also gave 0.0 at 40, 8.9e-8 at 60,
3.0e-8 at 70 and 0.0 at 78. The error is small because the à-trous reconstruction is exact whatever
a band's border sees, and only the shrunk part of a coarse band depends on the border. But docs/14
promises tiled and untiled renders bit-identical, and nothing checked it for S3. The docs/14 table
row is updated to match.

Nothing in Sources tiles S3 with this constant. On the GPU, Core Image tiles the stage itself
through the ROIs, so no rendered pixel moves.

### 2 — four GPU-parity goldens (KernelGoldenTests, `// MARK: S3 at the sizes and precisions…`)

- `testDenoiseRegionRendersMatchTheWholeFrame`: a 256 × 224 frame with every pass on (hot pixels,
  both masters, the blotch filter). Three small regions (centre, left border, the colour line) are
  each rendered in an uncached context and must equal the whole-frame read to 1e-5. This is the
  only test that exercises the `roiCallback` reaches. The regions are vertically centred, so the
  bitmap's row convention cannot matter.
- `testDenoiseMatchesTheReferenceAwayFromTheBorder`: the existing 2e-4 whole-stage bar on a
  192 × 176 frame that has an interior.
- `testDenoiseAtPreviewScaleMatchesTheScaledReference`: at noise scale 0.6 the GPU must match
  `scaled(noiseScale: 0.6).apply` to 2e-4, and 0.6 must differ from scale 1 by more than 1e-3. At
  0.4, below `contributingNoiseScale`, both paths must be identity.
- `testDenoiseAtTheShippingHalfFloatPrecisionTracksTheReference`: renders in an RGBAh context, the
  working format `PipelineRenderer` actually uses. It bounds the worst pixel below 25% and the RMS
  below 2% of the stage's own effect, the relative form the blotch golden already uses. The model
  in `GPUPlan` predicts about 6% and 0.8%. The test prints the measured numbers, so the first CI run
  records them.

API names were checked against existing uses in the same file:
`CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)`, the `.cacheIntermediates` /
`.workingFormat` / `.workingColorSpace` options, `RenderGraph.Options(longEdge:noiseScale:)` and
`ImageBuffer(width:height:pixels:)`. `scripts/check-swift-surface.py` exits 0.

**Risk to watch on the first macOS run.** The half-float test's bars come from the documented
model, and no driver has measured them. If it fails, the printed `S3 HALF-FLOAT` line is the
measurement. Treat a failure as a finding about the RGBAh path, not as a reason to loosen the bar.

## DECISIONS

1. **docs/14 §6.3 S3 halo: 24 px → 79 px** (implemented). This is a documented number, but it was a
   wrong count rather than a taste choice, and no pixel moves. The cost of the larger apron, if an
   export tiler ever uses it: on 2048 px tiles the overlap work rises from about 2.4% to 8%. To keep
   24 px instead, revert daec51e. The measured price is up to 1.6e-5 at seams.
2. **No default-off switch.** Lumen's GPU NR is already the default and Apple's NR is already off
   under it. A switch would only add a way to change the look of existing edits. Nothing to measure
   before and after, because nothing changed.

## FOUND-WHILE-FIXING

- **GPU parity is red on trunk for an unrelated reason.** Run 36807716802 fails only
  `CurveBlackLiftGPUTests.testANeutralNearBlackStaysNeutralOnTheGPUUnderALiftedBlack` (16 failures).
  That belongs to the curves stream. The denoise goldens in the same run all pass.
- **docs/07 §Tier 1 still carries the "Milestone-1 stopgap" sentence** (CIRAWFilter NR "until this
  stage ships"). The stage has shipped. Left as is because it is a spec doc.
- **Non-RAW sources under `.ai`.** BUILDING.md already records that a JPEG/HEIC/TIFF under `.ai`
  gets no denoise at all, because Tier 1 is coupled to zero and there is no decoder stage. This is
  unchanged and belongs to LumenPipeline's `RenderedImageSource`.
- **Unused variable warning.** `Tests/LumenCoreTests/DenoiseTests.swift:141` (`base` never used)
  warns on every build.
- **The new Linux tiling golden takes about 100 s** in a debug build (16 reference tiles of
  240 px plus two whole-frame passes). It is acceptable, but it is the slowest case in DenoiseTests.
