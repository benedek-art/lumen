# Status — paused 2026-10-18 evening (user resumes 2026-10-19)

## Done (verified)
- Drive guard hook (`.claude/hooks/protect_drive.py`), tested: copy-off allowed, writes/deletes blocked.
- Drive index: 13,060 RAWs (Sony A7 IV 6,732 — 74% at ISO ≥ 3200; GX85 6,235). ~1,250 copied to `data/raw/` (read-only copy).
- Noise calibration (`data/calib.json`, copy in `weights/`): K = 1.654e-7·ISO (Sony), 3.789e-7·ISO (GX85); read noise fitted. No in-camera raw NR detected on Sony (noise is spatially white).
- DNG writer via Adobe DNG Converter (`~/Applications`), bit-exact round trip both cameras (`tests/test_dng.py`).
- End-to-end CLI `python -m lumen_denoise.infer` = 6.2 s per 33 MP Sony file.
- Mac app `app/` (`app/build.sh` → `app/dist/Lumen Denoise.app`), refuses output on the Offload Drive.
- Baselines (held-out, PSNR dB @ ISO 1600/6400/25600): noisy 39.5/33.1/26.5, BM3D 45.0/40.9/36.2, Sony pretrained zero-shot 37.8/37.3/36.0.

## Paused mid-flight (processes SIGSTOPped, not killed)
- Run A (UNet nf32, init Sony AIM25), step ~3400/6000. Val @2000: 43.2/41.6/39.1. Checkpoints: `runs/A_nf32_sony/{best,last}.pt`.
- Extra ground-truth prep (`data/lists/local_clean_extra.txt` → `data/gt`).

## Resume
- Same boot: `pgrep -f "lumen_denoise\.(train|prepare)" | xargs kill -CONT` (plus their child workers).
- After a reboot: rerun extra prep (skips finished files), then run A with `--init runs/A_nf32_sony/last.pt --iters 3000`.

## Next
1. Finish run A → `bench` vs BM3D on identical crops; `crops` on real high-ISO shots.
2. Run B: UNet nf64 from scratch on the full ground-truth set, ~12k steps (~3.5 h).
3. Pick winner → `weights/lumen_denoise.pt`; tune default strength; publish comparison report.
4. Ask the user to export ~10 Lightroom-denoised DNGs into `reports/lightroom/` for a head-to-head.
