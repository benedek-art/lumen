# Lumen Denoise

Raw-domain AI denoiser (RAW -> denoised DNG) for Sony A7 IV and Panasonic GX85, destined for Lumen.
Source of truth during development: ~/Projects/lumen-denoise (training data, photos and weights stay local, never in git).
See docs/PLAN.md and docs/STATUS.md.

## Evaluation / release gate

`python -m lumen_denoise.eval.gate --model net:runs/A/best.pt --baseline net:runs/prev/best.pt` runs every
eval module (synthetic PSNR/SSIM per camera x ISO x region, texture retention, no-reference real-noise checks,
low-ISO regression, stars, blind A/B vs Lightroom) and prints a PASS/FAIL release table plus
`RELEASE:` and `LIGHTROOM CLAIM:` verdicts (exit 0 pass / 1 fail / 2 not enough data). CPU smoke run without
photos: add `--synthetic --quick`. Thresholds, rationale and the Lightroom A/B procedure: docs/RELEASE_GATE.md.
Tests: `python -m pytest tests/test_eval_*.py -q`.
