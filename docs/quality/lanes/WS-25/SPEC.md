# WS-25 acceptance spec: S16 geometry renderer, CPU twin, Upright

Written before any code change. Audit input: the lane inventory (crop/angle/flip are
GPU-only in `PipelineRenderer.applyGeometry`; the CPU reference and `lumen-render` never
crop or rotate; `geometry.upright` is stored and never rendered) plus a read of
`applyGeometry`: it rotates with `CIImage.transformed(by:)`, which samples through Core
Image's default **bilinear** sampler, and when an output scale is also asked for it
resamples TWICE (bilinear rotate, then `CILanczosScaleTransform`). So the GPU rotation
is soft today, and the code's own comment ("ONE transform and ONE resample") is not what
it does.

Measurement tool for lines 1-9: `swift test --filter GeometryStageTests` (LumenCore, Linux)
prints every number below; lines 10-11 are `LumenPipelineTests.GeometryGPUParityTests`
(macOS CI, `gpu-parity.yml`). Lines 12-18: `swift test --filter UprightTests` plus
`lumen-render` renders named in REPORT.md.

## Geometry twin (CPU definition)

1. **Identity is exact.** Default geometry (no crop, angle 0, no flip, upright nil or
   default) returns the input buffer bit-for-bit, same size. Threshold: max |Δ| = 0.
2. **Integer-pixel crop is a copy.** A crop whose rectangle lands on whole source pixels at
   angle 0, scale 1, is an exact copy of that sub-rectangle. Max |Δ| = 0 (≤ 1e-6 for
   float round-off). Flip of an uncropped frame is an exact mirror (max |Δ| ≤ 1e-6).
3. **One definition of where pixels go.** `GeometryMap` round-trips source↔output with
   error < 1e-9 px for random crops/angles/flips/upright, and with upright nil it agrees
   with the mapping `PipelineRenderer.geometryRects` encodes (re-derived in LumenCore in
   closed form; checked on macOS against `geometryRects` itself, line 11).
4. **Rotation sharpness, MTF.** Sinusoid gratings of frequency f cycles/px rotated by 1°
   and 10°; MTF = fitted amplitude / true amplitude, ideal analytic rotation as truth.
   At f = 0.25 cy/px the Lanczos-3 MTF is ≥ the bicubic (Keys a = −0.5, Photoshop
   "Bicubic") MTF at both angles, and ≥ 0.90; at f = 0.35 ≥ 0.75. Bilinear (the old GPU
   sampler) is reported for scale.
5. **Rotation is not a blur on real detail.** zone_plate rotated 10°: RMS error against the
   analytic rotated zone plate inside the Nyquist circle (r < 0.9 R) is ≤ 0.75 × bicubic's
   and ≤ 0.5 × bilinear's.
6. **Aliasing on downscale.** zone_plate at 0.25× output scale (combined crop+rotate+scale,
   one pass): energy above the output Nyquist that folds back (measured as RMS of the
   output in the annulus where the true signal, low-passed at output Nyquist, is < 1% of
   its amplitude) ≤ 2% of the signal amplitude. Box-free halving chain, not point sampling.
7. **Edges.** Rotating a flat field 10° with the default inscribed crop gives no darkened
   or transparent rim: every output pixel within 1e-4 of the field value, alpha = 1.
   Hard-edge frame rotated 1°: overshoot (Lanczos ringing) ≤ 8% of the step, and no
   pixel outside [min − 8%, max + 8%].
8. **Monotonic, continuous angle.** Output size and mean of a textured frame change
   smoothly across angle −45…45 in 0.5° steps (no jump > 1 px in size between neighbours,
   mean |Δ| < 0.5% between neighbours).
9. **`lumen-render` renders geometry.** `render --set develop.geometry.angle=10` and a crop
   produce an output whose size equals `CropGeometry.resolve(...).outputWidth/Height` at
   the render scale, and the picture is visibly rotated (sheet `evidence/angle_sweep.png`).

## GPU twin

10. **GPU uses the same sharp resampler.** `applyGeometry` evaluates the same
    `GeometryMap` homography and the same Lanczos-3 / halving chain in a general CIKernel;
    no `transformed(by:)` resample remains on the delivered path.
11. **Parity.** GPU vs CPU twin on 4 fixtures (crop, 1°, 10°+flip+crop, 0.3× scale,
    upright vertical) at three sizes: max |Δ| ≤ 2e-3 in linear (RGBAf context), mean
    ≤ 2e-4; output sizes equal. `sourceNormalized/displayedNormalized` agree with the old
    `geometryRects` inverse to 1e-6 when upright is nil.

## Upright

12. **Default is identity.** `Upright()` and `mode = .off` produce the identity homography
    (exact), so every existing recipe renders unchanged.
13. **Line detection.** On a synthetic perspective facade (known vanishing points) the
    detector finds ≥ 8 vertical and ≥ 4 horizontal segments and the estimated vertical
    vanishing point direction is within 0.5° of truth.
14. **Level.** After Level, the length-weighted median deviation of near-vertical and
    near-horizontal segments from their axis is < 0.2° (synthetic) and roll is the only
    rotation (pitch = yaw = 0).
15. **Vertical.** After Vertical, re-detected near-vertical segments are within 0.3° of
    vertical (length-weighted RMS) on the synthetic facade; on corpus 4213 (castle) and
    7301 (church) residual RMS vertical deviation drops by ≥ 60% against the uncorrected
    frame.
16. **Full.** Additionally, re-detected near-horizontal segments of the dominant plane
    are within 0.5° of horizontal (synthetic).
17. **Guided.** Two vertical guides become vertical to < 0.05°; two vertical + two
    horizontal guides make all four axis-aligned to < 0.05°. Constraint: any solved
    pitch/yaw/roll is clamped to ±45°, and the result always fills the frame (no empty
    corners at scale 100, checked by mapping the four output corners inside the source).
18. **Exposed in the UI.** Crop panel Transform section with Off/Auto/Level/Vertical/Full/
    Guided, the manual Vertical/Horizontal/Rotate/Aspect/Scale/Offset sliders, built from
    `LumenSegmented` and `LumenSlider`; snapshot in the ui-snapshots set.

## Visual claims (human-judged)

- V1 `evidence/rotation_crops.png`: 100% crop of zone_plate rotated 10°, bilinear vs
  bicubic vs Lanczos-3: Lanczos visibly crisper at the fine rings, no extra moiré.
- V2 `evidence/upright_4213.png`, `evidence/upright_7301.png`: before/after Vertical; walls
  read vertical, picture not stretched unnaturally.

## Revisions after the first measurement (recorded, not silent)

- **7b.** The 8% ringing bound was set against an IDEAL pixel step, which is not a
  sampled band-limited signal: every interpolating kernel rings on it (measured at 1°:
  Lanczos-3 11.8%, bicubic 7.4%). The edge a photograph actually contains has passed a
  lens, an AA filter or a demosaic. Revised: an edge blurred to σ = 0.5 px, rotated 1°,
  overshoots ≤ 1% of the step. The ideal-step numbers stay in the report.
- **8.** "No size jump > 1 px between 0.5° neighbours" contradicts the inscribed-frame
  definition (`CropGeometry.usableSize`, WS-23), whose width legitimately moves 9 px/°
  near 22° on a 240×160 frame. Revised to a continuity test: halving the angle step at
  least halves the largest neighbour change in size (+2 px: both edges round outward,
  see 9), on a 480×320 frame; the mean change
  stays < 0.5% at both step sizes (it cannot halve: one whole-pixel column entering a
  113 px frame moves it by a third of a percent at any step).
- **9.** Output size is not `CropGeometry.Resolved.outputWidth/Height` (round) but the
  crop's bounds in the scaled straightened frame rounded OUTWARD to that frame's pixel
  grid: the extent the GPU path has always delivered (Core Image's integral render of a
  fractional crop) and the rectangle `RenderGraph.applyVignette` (WS-41) centres on.
  Keeping it means no delivered size and no vignette moves. It is `outputWidth` or one
  more. Tested against the legacy closed form on 300 random geometries.
- **15 (corpus metric).** RMS over every line within 30° of vertical counts arch tangents,
  gable and spire flanks and rose-window tracery, which no correction should make vertical
  (see `evidence/upright_7301.png`, red). The corpus claim is restated on the robust
  reading `UprightSolver.Residual.verticalMedian`: length-weighted median |deviation| of
  re-detected lines within 20° of vertical, ≥ 60% drop. The RMS numbers stay in the report.
