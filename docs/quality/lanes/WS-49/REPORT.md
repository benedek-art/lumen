# WS-49 report: AI mattes and depth

Branch `quality/m5-ai-masks` from `claude/inspiring-dirac-ulgpch`.

**Verdict: BLOCKED after three build/verify rounds.** Every measurable spec line passes
(S1-S20, S2b). The third verifier failed the lane on a regression the round-3 fix caused;
that fix was removed, and what it was meant to fix (V4: Sky on 1346's defocused
background) is open. Edge refinement is in good shape. Sky works well on open, overcast,
cloudy and bright-foreground skies, but has false positives on pale smooth regions at the
top of non-sky frames.

## For the owner

1. Subject on a portrait against a busy background, exported full size: hair edge clean, no grey ring? (V3; Vision can't run on Linux.)
2. Sky on 4-5 of your own landscapes, plus one shallow-depth portrait and one interior: decide whether Sky ships as is, given it can select a pale wall or bokeh at the top of a non-sky frame (1346, 3582, 1332).
3. A licensed sky model would fix the false positives: pick weights you can ship, run `convert_sky_model.py`, call `SkyModel.install` (no UI yet, NEEDS.md 3).
4. Moon in a night or dusk sky: it is filled as part of the sky. Acceptable?
5. People sub-parts (face, skin, hair, eyes) are not built: Vision on macOS 15 has none.

## Verdict per spec line

Measured on Linux, release build, `MatteRefineTests`, `MattePlaneFitTests`, `SkyDetectorTests`.

| # | claim | measured | verdict |
|---|---|---|---|
| S1 | edge-band MAE ≤ 0.5x bilinear | 0.0317 vs 0.168 (0.19x) | PASS |
| S2 | 10-90 width ≤ 3 px (perfect step) | 0.0 vs 13.0 | PASS (flattering; S2b is the real line) |
| S2b | realistic edge ≤ 4.5 px and ≤ 0.5x | 2.44 vs 10.0 | PASS |
| S3 | halo < 0.2% | 0.0% | PASS |
| S4 | no shift; flip-equivariant (sizes divisible by 4) | shift −0.0014/0.0029 px; flip 1.1e-6 | PASS |
| S5 | constant 0/1 identity | exact | PASS |
| S6 | synthetic sky through branches IoU ≥ 0.90, gaps ≥ 0.70 | 0.9955, 0.976 | PASS |
| S7 | overcast IoU ≥ 0.90 | 0.995 | PASS |
| S8 | no-sky synthetic < 1% | 0 / 0 | PASS |
| S9 | blue object below horizon < 5% | 0.0 | PASS |
| S10 | 2048 px detect + refine < 1.5 s | 1.13 s (lane box), 1.26-1.36 s (slower restarted box); test ceiling 5 s | PASS |
| S11 | Sky offered, Object/Landscape/Depth not | provider exact (Linux); picker in `MaskPanelTests` (macOS) | PASS (Linux part) |
| S12 | 2048 → 1024 keeps strand coverage | 0.02197 → 0.02197 | PASS |
| S13 | soft matte not crushed (≥ 0.12) | 0.3005 / 0.6011 | PASS |
| S14 | strand tips ≥ 1.5x the model's | 0.201 vs 0.103 (1/8), 0.322 vs 0.211 (1/4) | PASS (tips stay faint: 0.2-0.3 of truth) |
| S15 | NaN stays local | 0.0 change; output finite | PASS |
| S16 | sky over snow/sand IoU ≥ 0.90 | 0.9985 / 0.9985 / 0.9987 | PASS |
| S17 | narrow sky strip not cut | IoU 0.998, strip 1.0 | PASS |
| S18 | clouds in, snow slope out | 1.0 / 0.005 | PASS |
| S19 | balloon, kite out | 0.005 / 0.025 | PASS |
| S20 | studio backdrop < 1% | 0.0 | PASS |
| V1 | corpus sky judged by eye | good on 983, 1840, 4213, 6001, 7301 right side; see limits | PARTIAL |
| V2 | hair-fan crop | disc edge clean, strands full length, tips faint | PASS |
| V3 | macOS portrait export | not runnable here | OWNER |
| V4 | 1346 no near-black selected | 0.33 coverage, runs into the dark bokeh | **BLOCKED** |

Full LumenCoreTests (trimmed package, see Gates): 3073 tests, the same 24 failing test names
as the base commit, nothing new.

## Verifier rounds

1. **FAIL.** Sky missed over bright foregrounds; a frame-wide horizon cut real sky (7301);
   the edge-decision step crushed soft mattes and erased hair tips; canopy speckles; NaN
   spread; SkyModel crop, 2-channel and Float16-locking risks. All fixed in round 2.
2. **FAIL.** 1346's defocused background taken down to near-black; hole filling swallowed
   balloons, kites and the moon. Round 3 fixed both.
3. **FAIL.** Round 3's per-pixel growth floor left a clean pale patch at the top of dark
   indoor frames that then passed the brightness test: 2062, 4144 and 832 (no sky) came out
   26-57% sky, covering the subject in two. The floor is removed in the pushed code. The
   round-3 verifier measured exactly this configuration with the floor switched off: those
   three at 0, 1346 back at 0.33. S20 now guards the regression. Hole-filling and every
   other round-3 change stay.

## What changed and why

- **`MatteRefine` (new, LumenCore).** Colour guided filter, fast variant, in two stages.
  LOCATE: window sized from the model's native resolution (1.5x the upscale) moves the
  transition onto the photograph's edge. One pass only narrows a ramp (13 → 8 px), because
  inside the ramp the picture is flat. DECIDE + FEATHER: push toward a decision, weighted by
  the located matte's local spread so uniformly soft regions and faint strands keep their
  value; a toe under 0.12 removes the faint wash a coarse model leaves between strands
  (0.10 → 0.07); then a 2 px guided feather, the filter's original matting use.
  Epsilon 3e-4. Exact identity where the matte is solid. NaN/Inf zeroed on entry.
- **Every Vision matte is refined before it is cached** (`VisionMattes.generate`) against
  the neutral image the request saw. Background is the complement of the refined subject.
  Foreground reads its native resolution from `instanceMask`; person segmentation asks for
  32-bit float.
- **Matte resolution 1024 → 2048** (`PipelineRenderer.matteLongEdge`). 11-13 MB per kind per
  photo; ledger holds 12 photos (worst case ~600 MB with four AI kinds on every photo).
- **`MaskRaster.mattePlane` area-averages when shrinking ≥ 2x.**
- **Sky is offered** (`MaskKind.aiSky.matteProvider = .vision`, on-device). Installed Core
  ML model if present (`SkyModel`), otherwise `SkyDetector` (classical, LumenCore):
  smoothness at 384 px; growth from the top row; seeds big, sky-coloured, bright relative to
  the frame or plainly bright (> 0.72), lightness spread < 0.13, largest seed plus only
  same-coloured others; cloud growth from the seed (under a blue seed only clouds enclosed
  by blue); colour model per OKLab channel linear in height, per-column horizon; small
  enclosed holes filled only when cloud-like or speck-sized; one-pixel dilation so the ramp
  straddles the skyline; guided refinement; full-resolution canopy key gated by edge
  density, clustering and a 5x5 opening.
- **`SkyModel` (new, macOS).** Loads `~/Library/Application Support/Lumen/Models/LumenSky.mlmodelc`.
  ADE20K logits (sky = channel 2), 2-class, or single-channel output; scale-to-fill input;
  strides honoured; read through `withUnsafeBytes`. `install(from:sha256:)` downloads a
  single `.mlmodel`, verifies, compiles, swaps. No URL configured.
- **Panel copy** (`modelNote`) for Sky; kind-list comments updated.

## Model research

- Vision on macOS 15 has foreground instances, person segmentation, person instances and
  saliency. No sky or scene segmentation, no person parts.
- ADE20K segmenters set the bar. NVIDIA's SegFormer weights are non-commercial; other
  ADE20K checkpoints inherit the dataset's research-use terms. I found none clearly
  licensed for commercial redistribution, so none ships or downloads.
  `convert_sky_model.py` converts one once the owner clears weights.

## People sub-parts

Not built. No part segmentation in Vision on macOS 15. AVFoundation's hair/skin/teeth
mattes exist only as auxiliary images in iPhone HEIC captures. Face landmarks could seed
Eyes/Lips polygons, but the wire format has no per-part chips.

## What I could not fix

- **V4 / pale non-sky at the top** (1346 33%, 1332 16%, 3582 13%). Every per-pixel or
  per-region guard I tried either missed these or broke no-sky frames. A model is the
  real fix.
- **Dense fine branches**: 2545 flecks, 3437 nothing.
- **Large grey storm skies** (> ~50% of frame, L < 0.72) are not detected.
- **Moon and birds** are filled with the sky.
- **Lens-profile alignment** and the matte cache key: NEEDS.md 1.

## Gates

- `swift test` on the repo's Package.swift can't build on Linux: `Sources/LumenApp/CompareView.swift`
  doesn't parse under Swift 6.0.3 (84 errors on the base commit too). LumenCoreTests run
  through a trimmed package with the same sources: 3073 tests, the identical 24 failing
  names as base.
- Existing tests updated for Sky moving from `.model` to `.vision` (rosters moved, none
  loosened): `MaskingTests`, `MaskDependencyAdversarialTests`, `MaskDependencyTests` (model
  example now Landscape), `MaskPanelTests` (now also asserts Sky is offered).
- CI: see the final note at the bottom.

## Evidence

- `evidence/sky-corpus.png`: 983, 1840, 4213, 2545, 3437, 7301, 6001, 3582, 1346, photo and sky overlay. 1346 and 3582 show the open false positives.
- `evidence/sky-edge-100pct.png`: 100% crops, 384 px decision vs refined: 1840 treeline, 983 lantern, 7301 spire.
- `evidence/refine-crop.png`: synthetic hair fan: picture, truth, old bilinear matte, refined.
