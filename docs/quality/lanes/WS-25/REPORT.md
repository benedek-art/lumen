# WS-25 report: S16 geometry renderer, CPU twin, Upright

Branch `quality/c2-geometry`. Verifier: one round, fresh agent. It confirmed every
measurable line except 15 (corpus) and 7b, the two FAILs below. It also found a latent
sign bug in `Homography.normalized`, fixed in the second commit.

## For the owner

- Rotation was soft: the GPU sampled with bilinear (MTF 0.81 at 0.25 cy/px). It is now Lanczos-3 on both paths (1.01), sharper than bicubic (0.95).
- The CPU reference and `lumen-render` now crop, straighten, flip and Upright. The mapping is defined once, in LumenCore `GeometryMap`.
- Upright Level, Vertical, Full, Auto and Guided all solve exactly on a synthetic facade. On the church (7301), Vertical works. On the castle (4213), it correctly refuses to pitch from 2 lines, but Level rotates 1.4° off a field path: judge `evidence/upright_4213.png`.
- Try by hand on a Mac: the Transform fold (Crop panel), "Draw" guides on the crop canvas, and drag feel with Upright on (kernel cost).
- GPU parity, UI snapshot and kernel compile are proven only by macOS CI on this branch.

## Verdict per spec line

| # | Claim | Measured | Verdict |
|---|---|---|---|
| 1 | default geometry is a bit-exact identity | equal pixels, same size | PASS |
| 2 | integer crop copies, flip mirrors | max abs diff 0.0 / 0.0 | PASS |
| 3 | one map, round trip, agrees with `geometryRects` | 7.4e-13 px / 9.4e-13 px | PASS |
| 4 | MTF ≥ bicubic and ≥ 0.90 at 0.25 cy/px; ≥ 0.75 at 0.35 | 1.013 vs bicubic 0.948 (bilinear 0.812); 0.954 at 0.35; same at 1° and 10° | PASS |
| 5 | zone plate at 10° (RMS error over amplitude, inside 0.9R): Lanczos ≤ 0.75× bicubic, ≤ 0.5× bilinear | 0.079 vs 0.152 vs 0.242 (ratios 0.52, 0.33) | PASS |
| 6 | folded-back energy at a 0.25× downscale ≤ 2% | 0.49% (2 halvings, σ 1.01) | PASS |
| 7a | no rim on a rotated flat field | worst 6e-9, min alpha 1.0 | PASS |
| 7b (rev.) | σ 0.5 px edge overshoot ≤ 1% | **3.15%** (bicubic 1.93%; ideal pixel step 11.8% vs 7.4%) | **FAIL** |
| 8 (rev.) | angle response continuous | largest jump 10 px at 0.5° steps, 6 px at 0.25°; mean change 0.38% / 0.33% | PASS |
| 9 (rev.) | output size = integral crop in the straightened frame | 300 random geometries match the legacy closed form | PASS |
| 10 | GPU uses the same resampler | `GeometryKernels` evaluates the same map, taps and chain; no `transformed(by:)` resample left on the delivered path except the kernel-missing fallback | PASS (code, verifier review) |
| 11 | GPU and CPU agree to 2e-3 | `GeometryGPUParityTests` (5 geometries × 3 sizes) | macOS CI |
| 12 | default Upright is an identity | exact | PASS |
| 13 | ≥ 8 vertical and ≥ 4 horizontal lines; vertical vanishing point within 0.5° | 41–42 / 41; 0.03°–0.08° | PASS |
| 14 | Level is roll only, median deviation < 0.2° | pitch = yaw = 0; 0.07°–0.09° | PASS |
| 15 synthetic | verticals < 0.3° after Vertical | 3.71° → 0.07° (re-detected on the pixels 0.075°) | PASS |
| 15 corpus (rev.) | median vertical deviation drops ≥ 60% | 7301: 3.49° → 1.18° (−66%; RMS only 11.4° → 10.7°). 4213: no correction (2 vertical lines, below the 4-line gate); median 1.04° → 2.45° from Level's roll | 7301 PASS, **4213 FAIL** |
| 16 | Full: horizontals < 0.5° | 1.53° → 0.07–0.10° | PASS |
| 17 | guides become exact; result always fills the frame | 0.00000°; worst corner 5.7e-13 px over 120 random corrections | PASS |
| 18 | Transform section in the Crop panel | `CropTransformSection` built from `LumenSegmented`/`LumenSlider`; snapshot `panel-crop-transform-open` | macOS CI (ui-snapshots) |

## What changed and why

- **`LumenCore/Image/GeometryStage.swift` (new).** `Homography` and `GeometryMap` hold one projective map from an output pixel to a source pixel: crop, inscribed frame, flip, straighten, Upright and scale. It is re-derived from `geometryRects` and keeps that function's delivered pixel grid: crop bounds rounded outward in the straightened frame. Holding that grid fixed is what keeps the vignette ellipse (WS-41) and every export size unchanged. `GeometryResample` is the stage: Lanczos-3, separable in source axes, normalized, with clamp-to-edge taps.
  - The kernel widens by √|det J|. Beyond σ 2 the source is halved first, so a downscale is filtered, not point-sampled.
  - The edge fade lets output pixels reach 1 output pixel past the source edge, which the outward-rounded grid needs. Below that, transparency appears only where Upright's Scale or Offset really exposes a border.
- **GPU (`LumenPipeline/GeometryResampler.swift`, new; `applyGeometry` rewritten).** Three CIKL kernels: 6- or 12-tap resample and a 1-D halve. They evaluate the same map with the same windows and weights, so parity is to float round-off.
  - `sourceNormalized`/`displayedNormalized` now go through `GeometryMap`, so mask tools follow Upright too.
  - The old path was a bilinear `transformed(by:)` followed by a second Lanczos resize.
- **Upright.** `Upright` gains `mode`, `segments` (detected lines) and `guides`, all tolerant-decoded; a default Upright is still identity.
  - `UprightDetector`: an LSD-style segment detector on log luminance, proxy ≤ 1600 px.
  - `UprightSolver`: RANSAC plus least-squares vanishing points, and a camera-rotation homography K·R·K⁻¹ (roll, pitch, yaw), plus a shear for Full and Guided. It is constrained:
    - a vanishing point needs ≥ 4 lines and 0.35 long edges of support;
    - pitch and yaw at most 35°, auto roll at most 15°, every angle at most 45°;
    - re-centred and zoomed so the frame is always filled.
  - Lines are detected once, when a mode is picked, and stored, so every render solves the same homography.
- **Wiring.** These touch code other lanes own, so each is listed:
  - `renderReference` (WS-01): one 3-line hunk after `ReferenceRenderer.render` calls `GeometryStage.apply(rendered, geometry:, targetLongEdge: maxLongEdge)`.
  - `lumen-render`: S16 after the render, plus a `--resampler` option, an `upright` diagnostic command, and sweep metrics that tolerate tiles of different sizes.
  - `CropPanel.cropRows`: one line mounting `CropTransformSection`.
  - `LoupeView.cropCanvas`: a 6-line hunk mounting the guide overlay.
  - `RenderCoordinator`: one passthrough method.
  - `LayoutMetricSupport`: inventory rows plus the call-site count, 106 → 107.
- **Test fixtures changed.** `RecipeCodecToleranceTests`' all-fields-off-default fixture now sets the new Upright keys. That is a fixture extension, not a loosened test.

## Could not fix / for a human

- **7b ringing.** Lanczos-3 overshoots 3.2% on the sharpest realistic edge, against bicubic's 1.9%. That is the price of the MTF gain (0.95 vs 0.83 at 0.35 cy/px). Anti-ringing clamps cost exactly that MTF back. Keep Lanczos-3 (my call, and what the brief asked for) or trade for bicubic-sharper. The regression guard pins 3.5%.
- **4213.** Level's 1.4° comes from a long field path among the near-level lines, and the tower's edges get worse. A spread test on the level candidates would make it decline; I did not tune it on a single frame.
- **7301 Full = Vertical.** No horizontal vanishing point passes the 35° yaw plausibility gate: the corner view's side wall wants 55°. Correct to refuse; Lightroom would likely do the same.
- **Lightroom parity.** No Lightroom references exist for geometry, so "as sharp as Lightroom" is argued from MTF against bicubic, not measured.
- `renderReference` crops a decode sized for the full frame, so a cropped CPU-fallback preview is smaller than a GPU one at the same `maxLongEdge`. That is WS-01's decode-scale call (NEEDS.md).
- NEEDS.md also lists the kernel roster (WS-58), the stale "geometry not applied" note in RenderCoordinator, vignette under Upright (WS-41), and editing individual guides (WS-23/24).

## Evidence

Best three: `evidence/rotation_crops.png`, `evidence/upright_7301.png`, `evidence/gx85_straighten_crops.png`.
The others: `upright_synthetic.png`, `upright_4213.png`, `angle_sweep.png`.
Reproduce with `swift test --filter "GeometryStageTests|UprightTests"` and `lumen-render upright --input corpus/lfi/7301_fujifilm-x100vi.lfi --long-edge 1600`.
