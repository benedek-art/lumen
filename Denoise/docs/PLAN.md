# Lumen Denoise — plan

Goal: RAW in → denoised DNG out, for Sony A7 IV (ILCE-7M4) and Panasonic GX85, beating Lightroom Denoise, < 10 s per 33 MP photo on M4 / 16 GB. Standalone now, drops into Lumen (Swift) later.

## Hard rules
- `/Volumes/Offload Drive` is READ-ONLY. Copy off, never write. Enforced by `.claude/hooks/protect_drive.py`.
- All work lives in `~/Projects/lumen-denoise`. Lumen repo is not touched.
- Every claim of "better" is backed by a number or a crop in `reports/`.

## Pipeline
1. Read RAW with rawpy (LibRaw) → Bayer CFA, black/white level, WB, ISO.
2. Normalize: `(cfa - black) / (white - black)`, pack RGGB → 4×H/2×W/2.
3. Noise level for this shot (per camera×ISO calibration, refined per image) → noise-map channels.
4. Network (UNet-class, raw domain, noise-conditioned) → clean packed Bayer. Tiled with overlap.
5. Unpack, de-normalize, write CFA DNG with original metadata (`lumen_denoise/dng.py`).
6. Strength slider = blend with the input (0–100%), default tuned on the benchmark.

## Data (from the drive, copied to `data/`)
- `drive_index.csv`: every RAW's camera/ISO/exposure.
- Clean set (ground truth): base-ISO, well-exposed, sharp → training + held-out eval. Split by shoot date so eval scenes are never seen in training.
- Real noisy set: high-ISO across bands (soccer, astro, indoor, night) → visual eval, no ground truth.

## Noise model (per camera)
Poisson-Gaussian per ISO (shot gain K, read σ) + row/banding noise + quantization; fitted from flat patches of real high-ISO frames, as functions of ISO. Validated by comparing the statistics of synthetic noise on clean frames vs real noise at the same ISO.

## Evaluation
- Synthetic: held-out clean frames + calibrated noise at ISO 800…25600 → PSNR/SSIM in linear raw and in rendered sRGB.
- Real: crop grids (original / classic / pretrained / ours) on real noisy shots, with the noise residual (input − output) shown to prove no detail was removed.
- Regression: low-ISO shots must come out ~unchanged.
- Speed: wall time per image, end to end.

## Stages
1. Setup + guard ✔  2. Index + copy set  3. DNG round-trip  4. Noise calibration
5. Baselines (classic + pretrained)  6. Fine-tune on own sensors  7. Speed + CLI + drag-drop app  8. Report
