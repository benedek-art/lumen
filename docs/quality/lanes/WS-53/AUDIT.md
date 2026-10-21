# M8 audit (before any code change, base 9068ded)

Setup: synthetic zone_plate, hard_edge, colorchecker, skin_tones, grey_ramp; real 6929 + 6933
(A7 IV), 2545 (GX85), 1569 (GX80), 2348 (G9, ISO 3200), 4694 (R5), 983 (5D4), sidecar WB/ISO
on every render. Full-frame mask = radial radii 5 feather 0 (`tools/full.json`); partial =
radial 0.25/0.30 feather 50 (`tools/radial.json`). 8-bit PNG, `--no-dither`.

## Defects

- **D1 Local Sharpness ignores global Radius/Detail/Masking/Halo.** Both paths build
  `ManualSharpen(amount:)` with defaults. Global radius 2 + masking 60, local 100 vs global
  100: 2545 max 50 / mean 4.0 codes / 60 % > 2; 6929 max 47 / 3.0 / 48 %; zone_plate 22 /
  6.0 / 58 %. Lightroom: local positive sharpness adds to global Amount with the Detail
  panel's Radius/Detail/Masking (fairly sure).
- **D2 Negative Sharpness dead zone.** GX85 at 2400 px, mean change vs none: −10 0.003,
  −25 3.8, −50 8.3, −75 10.8, −100 12.4 codes. At 1024 px preview an effective −25 moves
  0.011 codes. Global sharpening at S12 re-sharpens the blurred area afterwards. Lightroom:
  0…−50 fades global sharpening, −50 cancels, −50…−100 blurs (fairly sure).
- **D3 Full-frame local Dehaze/Clarity ≠ global once global colour/grade is edited.** Local
  presence runs after S9/S10. With vibrance 30, sat 10, a shadow grade: dehaze ±100 mean
  3–4 codes, max 60; clarity +100 max ≈ 30. Tone-only edits: 0. Both renderers.
- **D4 Mask Amount > 100 plateaus differently per control.** Dehaze flat 100→200 (±100
  clamp), Sharpness +100 flat above 150, −100 flat above 100, Clarity nearly flat 150→200
  (α floor in `localLaplacian`), Texture keeps scaling to 2×. Monotonic everywhere.
- **D5 Clarity +100 speckles grass** (global engine; shows through local = global).
- **D6 Stale dead-field comment** in `RecipeMasks.swift` (names `DenoiseEngine` and S5;
  global NR is `ClassicalDenoise` at S3).

## Behaves correctly

- **B1** Full-frame local = global, exactly, at default global settings: 12 images ×
  texture/clarity/dehaze ±50/±100 and sharpness 50/100 vs global Sharpen Amount: max 0 codes.
- **B2** CPU and GPU code agree for the local controls (raw `a.texture` + `strength:` on CPU
  ≡ `scaledPresenceAmount` on GPU; clamps, sigma, radius and order match).
- **B3** No halo or seam at a feathered edge (6 real + 2 synthetic, every control ±100 and the
  curve, native 2400 px): 0 codes outside, 0 vs full-frame in the core, 0.00 % of feather
  pixels outside [none, full] ± 1 code.
- **B4** Local curve = global curve: max 3 codes (one case 6) at lut 33, ≤ 2 at 65.
- **B5** All-zero mask, identity curve and Amount 0 are byte-identical to no mask.

## Part 2

All five carried fields at ±100: 0 codes, byte-identical PNGs (G9 ISO 3200, A7 IV,
zone_plate); local grain 100 over global grain 30 also 0. No global defringe/CA engine and no
moiré engine in the tree. Lightroom masks: Noise −100…+100 (negative cancels global NR,
fairly sure), Defringe signed (fairly sure), Moiré exists (meaning of negative unknown),
Grain: none in masks (guess). Adobe's help pages returned 403, so not checked against
current docs.
