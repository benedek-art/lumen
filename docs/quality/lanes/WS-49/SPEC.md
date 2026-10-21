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
| S4 | No shift: centroid of refined vs GT disc | < 0.5 px each axis; flipping the input flips the output to 1e-5 | `testNoShiftAndOrientationEquivariant` |
| S5 | Identity: constant 0 or 1 matte unchanged exactly; refined values in [0,1], finite | exact | `testConstantMatteIsIdentity` |
| S6 | Sky on synthetic blue-gradient sky + textured ground + tree with gaps | IoU >= 0.90, and >= 70% of gap pixels selected | `SkyDetectorTests.testFindsSkyThroughBranches` |
| S7 | Overcast (bright, low-chroma, smooth) sky | IoU >= 0.90 | `testOvercastSky` |
| S8 | No sky (indoor texture, dark frame, bright white wall at bottom) | nil, or coverage < 1% | `testNoSkyMeansNothing` |
| S9 | Blue object low in frame (blue car / water not connected to top) not selected | < 5% of it | `testBlueObjectBelowHorizonIsNotSky` |
| S10 | Detector + refinement on a 2048 px guide | < 1.5 s release on the Linux box | `testSkyCost` |
| S11 | Picker offers Sky; Object, Landscape, Depth stay unoffered; Sky's provider is on-device | exact | `testSkyIsOfferedTheRestAreNot` (LumenCoreTests over `MaskKind.matteProvider`) |

## Visual claims (human judges)

- V1. `evidence/sky-corpus.png`: on 983, 1840, 3437, 4213, 2545, the sky alpha follows
  the real skyline, includes sky seen through foliage where it is visible at 1024 px,
  and does not take buildings, water or white walls.
- V2. `evidence/refine-crop.png`: 100% crop of the synthetic hair fan. Old matte is a
  blur; refined matte resolves individual strands with no light ring outside.
- V3. On macOS (owner): Subject on a portrait against a busy background, exported at
  full size, shows hair-level edges and no grey ring.
