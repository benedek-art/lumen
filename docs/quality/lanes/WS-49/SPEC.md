# WS-49 acceptance spec: AI mattes and depth

Scope: `VisionMattes.swift`, `MaskRaster.mattePlane/depthRangePlane`, the PR AI-matte
functions (`matteSourceImage` and the matte ledger), `MaskKind.matteProvider`, the MP kind
lists. New LumenCore code: `Image/MatteRefine.swift` (edge-aware upsampling) and
`Image/SkyDetector.swift` (classical sky). Everything measurable runs on Linux:

    swift test --filter 'MatteRefineTests|SkyDetectorTests'

## Audit findings this spec answers

- A1. Vision mattes were generated against a 1024 px neutral image and stored as-is.
  `VNGenerateForegroundInstanceMaskRequest` runs at its own internal resolution and
  `generateScaledMaskForImage` bilinearly scales that up, so the stored edge is a soft,
  model-resolution ramp. `MaskRaster.mattePlane` then bilinearly stretched it to the
  render target: on a 7000 px export that is a further 7x stretch. No step looked at the
  photograph's own edges. That is the blurry/haloed edge.
- A2. Person segmentation at `.accurate` returns a buffer whose size is fixed by the
  model, not the input; the stretch was correct (full-frame) but again photo-blind.
- A3. Sky, Object, Landscape and Depth are `.model` and render empty.
- A4. Alignment: matte and mask share the source frame (upright, uncropped, pre-geometry),
  so crop and orientation are correct by construction. One real hole: the matte image is
  rendered with `Recipe()`, whose `lens.profile` is true; a photo edited with the lens
  profile OFF gets a matte computed on the distortion-corrected frame (up to ~2% of the
  frame off at the corners on m4/3 zooms). Recorded in NEEDS.md (coordinator cache key).

## Measurable lines

Synthetic frame for S1-S5: 512x384 guide, a disc plus a 1-px-wide "hair" fan and a
jagged skyline over a textured colour background; the "model matte" is the ground truth
box-downsampled 8x and bilinearly upsampled (what the old path delivered).

| # | claim | threshold | measured by |
|---|---|---|---|
| S1 | Refined matte error in the edge band (pixels within 6 px of a GT edge) | MAE <= 0.5x the bilinear matte's | `MatteRefineTests.testRefinementHalvesEdgeError` |
| S2 | 10-90% edge transition width on a straight GT edge | <= 3 px (bilinear: >= 6 px) | `testRefinedEdgeIsNarrow` |
| S3 | Halo: alpha > 0.05 more than 4 px outside the GT shape | < 0.2% of outside pixels | `testNoHalo` |
| S4 | No shift: centroid of refined vs GT disc | < 0.5 px each axis; flipping the input flips the output to 1e-4 (for sizes divisible by the subsample factor, 4; other sizes differ up to ~0.06 because the coefficient grid is not symmetric) | `testNoShiftAndOrientationEquivariant` |
| S5 | Identity: constant 0 or 1 matte unchanged exactly; refined values in [0,1], finite | exact | `testConstantMatteIsIdentity` |
| S6 | Sky on synthetic blue-gradient sky + textured ground + tree with gaps | IoU >= 0.90, and >= 70% of gap pixels selected | `SkyDetectorTests.testFindsSkyThroughBranches` |
| S7 | Overcast (bright, low-chroma, smooth) sky | IoU >= 0.90 | `testOvercastSky` |
| S8 | No sky (indoor texture, dark frame, bright white wall at bottom) | nil, or coverage < 1% | `testNoSkyMeansNothing` |
| S9 | Blue object low in frame (blue car / water not connected to top) not selected | < 5% of it | `testBlueObjectBelowHorizonIsNotSky` |
| S10 | Detector + refinement on a 2048 px guide | < 1.5 s release on the lane's Linux box (1 core); the test enforces a 5 s regression ceiling because wall-clock differs between machines | `testSkyCost` |
| S11 | Picker offers Sky; Object, Landscape, Depth stay unoffered; Sky's provider is on-device | exact | `testSkyIsOfferedTheRestAreNot` (provider, Linux) + `MaskPanelTests.testTheThreeKindsWithNoModelAreNotOnThePickerBoard` (picker, macOS) |
| S12 | 2048 matte into a 1024 draft raster keeps a 1 px strand's coverage | within 2%, strand > 0.4 on every row | `MattePlaneFitTests.testShrinkingKeepsThinStrandCoverage` |

### Added after verifier round 1 (FAIL)

| # | claim | threshold | measured by |
|---|---|---|---|
| S2b | Realistic edge: low contrast (0.08), wavy, 3 px anti-aliased in the guide | 10-90 width <= 4.5 px and <= 0.5x bilinear | `testRefinedEdgeIsNarrowOnARealisticEdge` |
| S13 | A uniformly soft matte (0.3, 0.6) is not crushed | mean within 0.02 (values under 0.12 are deliberately attenuated by a toe: 0.10 → 0.07, 0.05 → 0.01) | `testSoftMatteIsNotCrushed` |
| S14 | Hair strands 15-70 px from the disc keep alpha | >= 1.5x the model's own (bilinear) strand alpha, for a 1/8 and a 1/4 resolution model | `testHairTipsSurvive` |
| S15 | A NaN in the matte or guide stays local | output finite; pixels > 40 px away change < 1e-5 | `testNaNIsContained` |
| S16 | Sky over a bright foreground (snow, sand, 50% of frame) | IoU >= 0.90 | `SkyDetectorTests.testSkyOverBrightForeground` |
| S17 | Sky reaching lower in a narrow strip is not cut by a frame-wide horizon | IoU >= 0.90, lower strip >= 0.90 | `testNarrowSkyStripIsNotCut` |
| S18 | Clouds inside a blue sky are sky; a snow slope rising into it is not | clouds >= 0.9, snow < 0.1 | `testCloudsAreSkySnowSlopeIsNot` |

### Added after verifier round 2 (FAIL)

| # | claim | threshold | measured by |
|---|---|---|---|
| S19 | Objects enclosed by sky (red balloon 0.7%, dark kite) are not filled as sky | each < 0.1 | `testObjectsInTheSkyAreNotSky` |
| V4 | 1346 (defocused dark background, chart): no near-black pixel selected | judged on the corpus harness | REPORT |

Round-1 notes kept honest: S2's perfect step flatters the filter, so S2b is the line that
matters. S8 puts the wall at the bottom; a bright smooth ceiling or wall touching the TOP
is a known false positive (3582), recorded in REPORT, not claimed.

## Visual claims (human judges)

- V1. `evidence/sky-corpus.png`: on 983, 1840, 3437, 4213, 2545 (plus 7301, 6001, 3582
  added in round 2), the sky alpha follows the real skyline, includes clouds, and does not
  take buildings, water or snow. Sky behind dense fine branches (2545, 3437) is partial;
  a smooth interior wall touching the top (3582) is taken. Both are stated limits.
- V2. `evidence/refine-crop.png`: 100% crop of the synthetic hair fan. Old matte is a
  blur; refined matte resolves individual strands with no light ring outside.
- V3. On macOS (owner): Subject on a portrait against a busy background, exported at
  full size, shows hair-level edges and no grey ring.
