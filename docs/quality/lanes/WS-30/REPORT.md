# WS-30 Creative LUT: report (lane K4)

## For the owner

1. A `.cube` now loads exactly: an identity LUT changes nothing, even P3 colours and HDR highlights (it used to clip them to sRGB and SDR white).
2. LUT Amount goes 0–200% like Lightroom's profile Amount, and 50% looks like half the look.
3. Camera log LUTs (S-Log3 → 709 and the like) still render wrong at both taps. They need a new tap and a version bump from WS-58/WS-01 (NEEDS.md).
4. Judge on a P3 screen: a B&W LUT leaves a hint of colour in reds beyond sRGB. That is the price of exact identity.
5. Recipes that already carry a LUT below 100%, or wide-gamut/HDR content, render slightly differently. There is no version bump, so this only matters if LUTs have shipped.

Best evidence: `evidence/lut-contrast709-amount-0-200.png`, `evidence/lut-log2709-both-taps-wrong.png`.

## Verdict per spec line

Final verifier (round 3 of 3, fresh agent, spec + diff only): **PASS**. Rounds 1 and 2 failed; their findings are fixed in 7d24962 and 7bce34f.

| # | Verdict | Measured |
|---|---|---|
| L1 identity exact | PASS | 33/65: 1.3e-15 display, 1.1e-13 log; 32 (inexact knots): 1.24e-7 |
| L2 Rec.709 contrast cube vs reference, 0–200% | PASS | max ΔE2000 0.144 (0 against independent tetrahedral) |
| L3 log-domain cube at the log tap | PASS | max ΔE2000 8e-6 |
| L4 Amount linear in the cube's encoding, 0–200, clamps | PASS | 8.9e-16 per 10% step; 250 → 2, −5 and NaN → 0 |
| L5 tetrahedral interpolation | PASS | 5.5e-9 from the barycentric mix; trilinear off by 0.12 (ΔE 1.1–6.0 on twist_9) |
| L6 residual for out-of-domain values | PASS | 1.6e-15 |
| L7 camera log-to-709 LUT | **BLOCKED** | mean ΔE2000 28.1 (log tap), 30.5 (display tap); NEEDS.md |
| L8 GPU parity incl. 200% and out-of-domain | macOS CI | `CreativeLUTParityTests` + new unclamped stage test; see CI below |
| L9 non-finite input, DOMAIN honoured | PASS (reference); GPU half BLOCKED on WS-58 | finite at all taps/Amounts; one NaN channel leaves the other two (1e-16); DOMAIN identity ≤ 1.95e-7 incl. per-channel domains. GPU NaN: NEEDS.md; GPU DOMAIN clamp read term-for-term, no parity case yet |

## What changed and why

- **Residual around the cube** (`CreativeLUTStage.apply`, `RenderGraph.applyCreativeLUT`). A cube only sees its unit domain. The part outside it (gamut beyond sRGB, EDR above white, scene past ±12 stops) is now carried around the lookup and added back. Before this, an identity cube moved values by up to 2.3 linear.
- **Amount** is 0…200 and scales `L(e) − e` in the cube's own encoding, floored at black. The old linear-light blend capped at 100 ran away when extrapolated: a 1.25× log cube at 150% put a highlight at 255×.
- **DOMAIN_MIN/MAX** is honoured at both taps, and non-finite channels are folded before the matrix.
- **GPU twin** uses only existing kernels (`subtract`, `addGlow`, `CIColorClamp`), so there is no registry change.
- **Existing tests changed, with reasons:** `testTheDisplayTapClampsAboveDisplayWhite` pinned the clip and is now `…HandsBackWhatIsAboveDisplayWhite`; `testAmountBlendsAgainstTheInput` pinned the linear, 100-capped blend.
- **Reference:** `tools/lutref.py`, independent numpy (own matrices, sRGB, LumenLog, tetrahedral + trilinear, CIEDE2000).

## Not fixed

- L7 (above).
- GPU NaN handling needs a finite-test kernel (NEEDS.md). Before this lane the GPU was already NaN-out below 100%.
- Amount above 100 is not version-gated: an older build clamps it to 100.
- Inputs ≥ 1e308 now overflow in the display matrix (non-finite folding runs before it, so one NaN channel no longer blacks out the pixel). No real pixel gets there.
