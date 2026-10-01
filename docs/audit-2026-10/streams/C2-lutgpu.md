# C2-lutgpu: the CreativeLUTParityTests failures on the first macOS run

| Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|
| Display tap 159.7 / 255 codes off on the affine cube, 7.8 / 12.75 off on the curved cube | NOT-A-DEFECT in the stage. The harness read back an all-zero frame. FIXED in the harness, but CI still has to confirm green. | `eb8af31` | Source-verified (macOS only). With the old harness and the CI log's zero readback, 4 of 4 tests are red; before, 2 passed on `0 == 0`. With the shared ref restored, the affine case reads the curved cube and fails. | none |
| Two cubes registered under one ref, with a process-wide upload cache | FIXED (test) | `eb8af31` | as above | none |

## What the log actually says

In the GPU-parity and CI lanes of run 5c29602, every `LUT_PARITY` line prints
`base=(0,0,0) gpu=(0,0,0)` for all six inputs. That holds with the LUT and without it, at
both taps. Here is where each reported number comes from:

- 255 codes: the red-inverting cube maps black to sRGB red, which is 0.627 in Rec.2020.
- 159.7 codes: the same at Amount 35.
- 12.75 and 7.8 codes: the curved cube's black lift (it maps black to blue 0.05) at Amount 100 and 60.

So the reference was being applied to a black that the GPU never rendered. The log-tap
and inert tests passed only because `0 == 0`. The four inert renders took 7 ms in total,
which is far too little for four real graph renders.

## The stage, traced against the four suspects

- **(a) Transfer.** The GPU path is: matrix to sRGB, `CIColorClamp`,
  `CILinearToSRGBToneCurve`, lookup, `CISRGBToneCurveToLinear`, matrix back. These are the
  same steps as `CreativeLUTStage.map`, so encode comes before the lookup and decode after.
- **(b) Axis order.** `LUT3D.data` and the `cubeLookup` atlas are both laid out with red
  fastest, then green, then blue. `ColorCubePrecisionTests` checks the atlas addressing
  knot by knot. The log tap uses the same upload.
- **(c) CIColorCubeWithColorSpace.** Not used anywhere in this path.
- **(d) 8-bit storage.** `ColorCube.filter` has used P5's float `KernelLibrary.cubeLookup`
  since P5 landed. No CIColorCube remains on this path. Only a comment still said
  otherwise, and it is now corrected.

I restated the GPU stage on Linux, with a trilinear twin of the lookup applied to the
reference's own default-graph output for these six inputs:

- On the affine cube it is exact.
- On the curved cube it is at most 0.18 code from the tetrahedral reference (darkest
  input) and under 0.012 code elsewhere.
- Both bounds (0.05 and 1.0) hold with margin.

## Harness changes (`Tests/LumenPipelineTests/CreativeLUTParityTests.swift`)

- **Frame layout.** The frame is now untagged RGBAf, 6×4 with identical rows, read back
  untagged in the linear Rec.2020 working space. That matches `KernelGoldenTests` and
  `ToneShippingGoldenTests`, which pass. In the suite, the only whole-graph render that
  was N×1 and colour-tagged was this one; the 1×1 tagged renders pass.
- **Dead renders throw.** Any pixel that is not finite, or has every channel ≤ 1e-5,
  throws `DeadRender`, so a recurrence is named for what it is. The extent is asserted,
  and so is row invariance.
- **The GPU stage must move the picture.** The display cases also require the GPU
  with-LUT render to move more than 5 codes from the GPU base.
- **Distinct refs.** `affineRef` and `curvedRef` are now separate.

## DECISIONS

- None of these change behaviour or the look of anything.

## FOUND-WHILE-FIXING

1. **I could not establish why the old N×1 tagged frame read back all zeros.**
   - The same lookup on an N×1 tagged frame (`ColorCubePrecisionTests`) passes.
   - The whole graph on a 1×1 tagged frame (`CurveBlackLiftGPUTests`) passes.
   - The whole graph on a 64×8 untagged frame (`ToneShippingGoldenTests`) passes.
   - For the default recipe the graph is only `logEncode` → `cubeLookup`.

   If CI still shows a dead render with the new harness, the next probe is
   `graph.build` on N×1 against N×4, tagged against untagged. Production frames are never
   one row tall.
2. **`CreativeLUTCubes` keys on ref alone, for the whole process.** That is correct for
   content-addressed refs. But any code path that registers a different cube under an
   existing ref (tests, or a future non-hash ref) gets stale bytes silently.
3. **`CullingAnalyzerTests` and `SpotRetouchGPUParityTests` failed in the same run.**
   They are not related to this stream.
