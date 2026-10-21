# WS-04 Exposure: report

## For the owner

1. Exposure itself is correct: +1 EV is exactly ×2 in scene-linear (relative error 0.0 over ±10 EV, 1e-4 to 6e4, negatives), EV 0 is byte-identical, monotone, no dead range.
2. Real photos (A7 IV, GX85 and 6 more) bleach smoothly toward white with no fringes, halos or banding; every render is byte-identical to before this lane.
3. What looks wrong at +2/+3 EV is the display transform (WS-13): skin and orange go yellow (+20° / +33° OKLab hue at +3), deep blue goes purple (+15° at +2, +23° at +3). Filed in NEEDS.md, not fixed here.
4. Fixed: a NaN exposure no longer blanks the frame, and the GPU S6 can no longer overflow fp16 to inf/NaN at extreme +EV.
5. Not measured against Lightroom pixels: `corpus/lightroom/` does not exist yet. Run the CHECKLIST export to get that number.

Best evidence: `evidence/01_a7iv-6929_exposure_-2_to_+3.png`, `evidence/04_skin-tones_exposure_-3_to_+4_WS13-yellowing.png`, `evidence/06_hue-wheel_exposure_-3_to_+4_WS13-blue-purple.png`.

## Verdict per spec line (SPEC.md)

Verifier verdict: **PASS** (VERIFY.md, independent re-measurement).

| # | Claim | Result | Measured |
|---|---|---|---|
| 1 | S6 matrix = 2^EV · M(0) | PASS | max rel err 0.0 (also quarter-stops, extreme printer lights) |
| 2 | `LinearStage.apply` exact 2^EV, signs kept | PASS | rel err 0.0 over 4686 channels |
| 3 | render(EV k, x) == render(EV 0, 2^k·x) | PASS | 0.0 codes on 11 spec recipes + 9 verifier recipes (WB, printer lights, masks, Film Lab, vignette) |
| 4 | EV 0 identity | PASS | no-key / `0` / `-0.0` PNGs `cmp`-identical |
| 5 | Mid-grey at EV 0 = 117.65 ±0.5 | PASS | 117.646 |
| 6 | Grey ladder −3…+3 (LUT33) | PASS | 20.32 / 41.29 / 72.72 / 117.65 / 168.74 / 207.17 / 234.51 |
| 6a | Grey ladder (exact path) | PASS | 20.32 / 39.44 / 70.41 / 117.65 / 168.58 / 207.45 / 234.51 |
| 7 | Monotone at 0.01 EV over −5…+5 | PASS | 0 falls (also 0 at 1e-6 EV steps) |
| 8 | Max step per 0.01 EV | PASS | 0.636 (limit 0.70) LUT33, 0.570 (limit 0.62) exact |
| 9 | No dead zone at grey | PASS | +0.636 code per 0.01 EV |
| 10 | Hard clamp ±10 | PASS | 1024 / 1/1024; EV 12 render bit-equal to EV 10 |
| 11 | Slider literal matches engine | PASS (source read) | −5…5, hard ±10, step 0.01, default 0 |
| 12 | Non-finite exposure cannot poison frame | PASS | NaN → gain 1, render bit-equal to EV 0; ±inf → 1024 / 1/1024 |
| 13 | S6 output clamped to ±65504 on CPU and GPU | PASS (CPU), GPU by code read | 64·2^10 → 65504, finite to ±1e30 |
| 14 | CPU reference finite and white at EV +10 | PASS | no non-finite pixel; neutral min code 255 |
| 15 | CPU render call site uses the clamp | PASS as filed | NEEDS.md N-1 (WS-01 owns `ReferenceRenderer.swift:68`) |
| 16 | GPU parity at EV +10 on RGBAh | PENDING macOS CI | `ExposureGPUParityTests` written, not runnable on Linux |
| 17 | Existing tests pass | PASS | 3054 LumenCoreTests, 0 failures; `ControlProofTests` times out in debug on base and branch alike (not run to completion) |

Visual claims V1–V3: A7 IV and GX85 sweeps bleach smoothly with no fringes or halos (sheets 01, 02, 07, 08); grey ramp evenly spaced with no banding (03). The GX85 sky blotches at −2…0 are present and byte-identical on base, not caused by Exposure.

Lightroom (L1): human must judge, pending reference exports. From Adobe's documentation, PV2012 moves midtones about a stop per EV with an image-adaptive highlight roll-off. Lumen matches the midtone move; its roll-off is fixed (anything above 0.18·2^(5−k) goes white) and −EV darkens more than +EV brightens (−1.45 vs +1.14 display stops at grey). Both are display-transform properties (WS-13).

## What changed and why

- `ToneEngine.exposureGain`: `Num.clampFinite(…, -10, 10, fallback: 0)`. `Num.clamp` passed NaN through, and `pow(2, NaN)` turned the whole frame NaN. Finite values are bit-for-bit unchanged.
- `LinearStage.apply`: identity short-circuit, else matrix product clamped per channel to `LinearStage.outputLimit` = 65504 (fp16 max). The GPU works in RGBAh, so at +10 EV a scene value ≥ 64 became +inf and then NaN at the next matrix with a negative coefficient; the CPU (Float32) rendered white.
- `RG.applyMatrix` (GPU twin): `CIColorClamp` to ±65504 fused after the colour matrix. All 17 callers checked by builder and verifier: inside ±65504 values pass bit-for-bit; the two callers that can exceed it in RGBAf (gamut gate, dehaze 1/airlight) clamp to [0, 1] immediately after.
- Tests: `Tests/LumenCoreTests/ExposureQualityTests.swift` (14 tests, lines 1–14), `Tests/LumenPipelineTests/ExposureGPUParityTests.swift` (macOS only, line 16). No existing test changed.

## Not fixed (see NEEDS.md)

- N-1 (WS-01): `ReferenceRenderer.swift:68` calls `matrix.apply` directly, so the CPU clamp is enforced at stage level only. CPU and GPU agree exactly for S6 outputs inside ±65504; above that both render white.
- O1–O6 (WS-13): orange +21.7°/+32.9° hue at +2/+3 EV, skin +19.9° at +3 (mostly the sRGB encode's per-channel clamp, no gamut boundary on the finish path), deep blue +15…+34° toward purple (`rotation.b`), sky blue constant +7…+8.6° purple bias, LUT33 slope break and 2.3-code grey misplacement in the preview, hue-wheel seams.
- O7 (LumenApp): histogram drag snaps a typed +7 to +5; recipe value 12 is stored un-normalized.
- GPU-only nuance: a NaN input to the GPU clamp may become −65504 where the CPU keeps NaN. No reachable source of NaN found.

## Process and gates

- Roles run as separate agents: auditor (AUDIT.md), spec (SPEC.md), builder (BUILD-NOTES.md), verifier (VERIFY.md).
- `swift build --target LumenCore --target LumenRender` clean.
- Pre-existing: on Linux Swift 6.0.3, `swift test` cannot build because `Sources/LumenApp/CompareView.swift` uses trailing commas in call arguments (Swift 6.1 syntax). Tests were run by patching that file transiently and reverting; it is not part of this commit.
- Audit sweep sheets (67 MB) were pruned; `audit/sweep.sh.txt` regenerates them, and the harness source and its outputs are kept in `audit/`.
