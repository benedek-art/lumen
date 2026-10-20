# Release gate

The gate decides whether a denoise model may touch the user's photos, and whether we may say it is
"better than Lightroom". One command runs everything that the available data allows:

```
python -m lumen_denoise.eval.gate --model net:runs/A/best.pt --baseline net:runs/prev/best.pt
```

It prints one table (`section | check | value | threshold | status | note`), writes
`reports/gate/<model>_vs_<baseline>.json` and `.md`, then prints two verdict lines:

- `RELEASE: PASS | FAIL | NOT ENOUGH DATA` (or `NOT A RELEASE - synthetic smoke run` on procedural scenes)
- `LIGHTROOM CLAIM: PROVEN | NOT PROVEN`, with a list of what is missing

| exit code | meaning |
|---|---|
| 0 | RELEASE PASS. With `--synthetic`, the smoke run had no FAIL rows, but it is still not a release |
| 1 | at least one FAIL row (a crashed module counts as a FAIL row, `module crashed`) |
| 2 | nothing failed, but a release condition below is not met (real data, both cameras, no `--quick`/`--only`); also an unreadable `--calib` or a method that cannot load or run (probed on a 32 px crop before the run, e.g. `bm3d` without the package) |

Statuses: **PASS** and **FAIL** gate the release. **SKIP** means data or tools are missing (the note says which).
**INFO** is reported only.

## When is it a release?

`RELEASE: PASS` needs all of the following:

1. Zero FAIL rows outside the `a/b` section.
2. Clean frames are the real held-out set (`data/gt_val/*.npy` + `data/gt_meta.json`), not procedural scenes.
3. Each mandatory section (`synthetic`, `detail`, `real-noise`, `low-iso`, `stars`) has at least one PASS/FAIL row.
   `real-noise` means real high-ISO RAWs; its synthetic proxy section does not stand in for photos.
4. `low-iso` ran on real base-ISO RAWs (`*_real` rows exist).
5. No `--only`, because a partial run is never a release.
6. No `--quick` (2 frames, fewer crops: for iterating, never a release).
7. Held-out frames from every calibrated body (`ILCE-7M4` and `DMC-GX85`), so one camera cannot pass for both.

`a/b` rows are human judgements of a rendered "ours" (which may be an older model). They decide the Lightroom
claim only, never the release: not yet proven better than Lightroom must not block a model that is safe.

**Baseline.** Use the previous released model (or, before the first release, the best available net or
`bm3d`). The relative checks ("no worse than baseline") are what stop regressions. `wiener` is only a weak CPU
stand-in for tests. `identity`/`noisy` as baseline turns the relative detail checks into INFO, because a method
that removes nothing has no residual to compare with.

## "Better than Lightroom" (LIGHTROOM CLAIM: PROVEN)

All of these must hold:

- `RELEASE: PASS` on real data (a synthetic run never proves it).
- Blind A/B (`eval.abtest`) of ours vs Lightroom Denoise:
  - at least **20 decisive** judgements (`abtest.MIN_N`), ties dropped;
  - from at least **8 different photos** (`gate.AB_MIN_PHOTOS`), so one scene cannot carry the result;
  - ours preferred in **more than 50 %** (`WIN_MIN`);
  - exact two-sided sign test **p < 0.05** (`P_MAX`). At n = 20 that means at least 15-5.
- The results must have been judged on crops of *this* model. The gate cannot check this. The note shows the
  date of the newest results file; regenerate the crops with `--ours` for every candidate.

Each judgement is treated as independent. Several judgements of the same photo or by the same judge are
correlated, so p is somewhat optimistic. That is why the photo minimum exists, and why more photos beat more
repeats.

## Checks and thresholds

Every threshold is a module-level constant in the file named, with its rationale in a comment next to it.
The numbers below are the values at the time of writing. Values measured on synthetic scenes (quick mode,
2 frames) are given as orientation; they are not real-photo numbers.

### `synthetic`: PSNR/SSIM on held-out clean frames + calibrated noise (`eval/synth_bench.py`)

Crops: dark, flat, detail, mid (256 px) and a 512 centre crop (same as `train.validate`) per frame. Noise is
Poisson-Gaussian from `weights/calib.json`, fixed numpy seeds per (frame, region, ISO): every method sees the
same noise. Tone (gamma 1/2.2) space, per camera and ISO; ISO clamped to each camera's calibrated range.

| check | threshold | rationale |
|---|---|---|
| `psnr_gain_vs_baseline@iso` | >= 0.0 dB, worst camera (`MIN_MEAN_GAIN_DB`) | a release must not regress; per camera, so an A7 IV gain can't hide a GX85 loss |
| `psnr_gain_vs_noisy@iso` | >= +1.0 / +3.0 / +5.0 dB at ISO 1600 / 6400 / 25600, worst camera (`MIN_GAIN_OVER_NOISY_DB`) | must clearly beat doing nothing; a 5x5 Wiener already gains 5.5 / 6.2 / 6.8 dB |
| `worst_region_vs_baseline@iso` | >= -0.15 dB dark/detail (`MAX_CRITICAL_LOSS_DB`), -0.3 dB other (`MAX_REGION_LOSS_DB`) | shadow blotches and smeared texture are what users notice first |
| `ssim_vs_baseline@iso` | >= -0.002 (`MAX_SSIM_DROP`) | SSIM differences below this are invisible |

### `detail`: texture retention and perceptual distance (`eval/detail.py`, `eval/perceptual.py`)

On detail crops (texture metrics) and flat crops (method noise). Luminance = tone(mean of the 4 planes).

| check | threshold | rationale |
|---|---|---|
| `hf_ratio@iso` | in [0.85, 1.15] at ISO <= 6400, [0.70, 1.30] above (`HF_BAND`, `HF_BAND_HIGH`) | high-pass energy out/clean on textured pixels; +-15 % is about the smallest visible change at 100 %; at high ISO texture is under the noise |
| `hf_ratio_vs_baseline@iso` | abs(log ratio) at most 0.05 worse than baseline (`HF_MARGIN`) | ~5 % more texture change than the baseline is a real loss |
| `resid_corr@iso` | <= baseline + 0.10 (`RC_MARGIN`) | local correlation of the removed residual with image structure ("method noise", Buades 2005); relative only |
| `struct_removed@iso` | <= 0.10 (<= 0.20 above ISO 6400) and <= baseline + 0.03 (`SR_MAX`, `SR_MAX_HIGH`, `SR_MARGIN`) | share of clean texture that ended up in the residual; blur:0.7 removes 0.28 |
| `gmsd@iso` | <= 1.2 x baseline + 0.002 (`GMSD_REL`, `GMSD_ABS`) | Gradient Magnitude Similarity Deviation (Xue 2014); wiener 0.001-0.016, blur:1 0.024, blur:2 0.074 |
| `method_noise@iso` | in [0.5, 1.5] (`MN_BAND`) | removed energy / predicted noise variance on flat pixels; < 0.5 leaves most noise (identity = 0), > 1.5 eats signal |
| `lpips@iso` | INFO | only with `LUMEN_LPIPS=1` and lpips + cached AlexNet weights (lpips is BSD-2; AlexNet weights are ImageNet research terms: evaluation only, never bundle) |

### `real-noise`: no-reference checks on real high-ISO RAWs (`eval/noref.py`, `eval/realdata.py`)

No ground truth exists, so these judge the residual (input - output), normalized by the predicted noise std:
if the model removed only noise, the residual is white, independent per Bayer plane and has the predicted
variance. Crops: flat, dark, detail, mid per file (12 files x 4 crops, quick 2 x 4). The same checks run on
synthetic noise as `real-noise (synthetic proxy)` (at the highest gate ISO), so the code path is exercised on a
CPU box; that section gates too.

| check | threshold | rationale |
|---|---|---|
| `residual_lag1_autocorr` | worst crop kind <= 0.10 (`AUTOCORR_MAX`), or <= baseline x 1.15 (`WHITE_REL`); never > 0.30 | white noise ~0 +- 0.01; removed texture 0.13-0.6 |
| `residual_spectral_flatness` | worst kind >= 0.70 (`FLATNESS_MIN`), or >= baseline x 0.85 (`WHITE_REL`); never < 0.30 | radial spectral flatness; white 0.99, removed texture or low-frequency noise left in 0.03-0.55 |
| `residual_xchan_corr` | worst kind <= 0.15 (`XCHAN_MAX`), or <= baseline x 1.15; never > 0.50 | sensor noise is independent per photosite; removed luminance detail is shared across planes (blur:2 0.8-0.99) |
| `residual_var_ratio` | median in [0.6, 1.4] (`VAR_BAND`) | residual / predicted variance; wide because real calibration can be ~20 % off and real noise has fixed-pattern noise |
| `residual_var_ratio_worst_kind` | <= 2.0 (`VAR_KIND_MAX`) | removed signal on one crop kind (blur:1 2.7, blur:2 5.7 on detail) |
| `leftover_noise_flat` | <= 0.5 (`LEFTOVER_MAX`) | noise std left / input std on flat + dark crops (Donoho MAD of the finest Haar band); identity = 1 |
| `chroma_blotch_vs_baseline` | <= baseline x 1.15 + 0.02 (`BLOTCH_MARGIN`, `BLOTCH_ABS`) | low-frequency log-chroma blotches; relative because content sets the absolute level |
| `banding_not_amplified` | output / input <= 1.2 per axis (`BAND_AMPLIFY`) | a denoiser must not create or strengthen row/column stripes |
| `banding_ceiling` | <= 3.0 white-noise row means on axes stronger than input (`BAND_CEIL`) | barely visible stripes |

### `low-iso`: clean shots must stay unchanged (`eval/lowiso.py`)

Base ISO 100 and 200 (clamped per camera). Two cases on synthetic or held-out frames: base-ISO noise added
(`@iso`), and the exact clean crop fed in (`_clean_in@iso`). With real base-ISO RAWs: `*_real` rows.

| check | threshold | rationale |
|---|---|---|
| `psnr_vs_input` | >= 45 dB (`PSNR_MIN`); clean input >= 50 dB (`PSNR_MIN_CLEAN`) | rms change 0.56 % of tone range (~1.4 8-bit levels): invisible at 100 % |
| `mean_shift` | worst crop and channel <= 1 DN of 14 bit (`SHIFT_MAX`) | no black-level or colour shift; an exact denoiser's worst crop/channel mean change is 0.15-0.35 DN (noise mean of a 256 px crop). 1 DN = 1/16383 normalized: one A7 IV level, ~1/4 of a GX85 (12-bit) level |
| `hf_kept` | >= 0.97 (`HF_MIN`), noise-corrected | at most 3 % texture loss on clean shots |
| `hf_kept_shadow` | >= 0.85 on dark crops (`HF_MIN_SHADOW`) | waxy shadows: the energy-weighted ratio hides them; perfect denoiser ~0.98 |
| `p999_change` | <= 0.03 tone (`P999_MAX`) | no local damage beyond ~8 8-bit levels |
| `not_worse_vs_clean` | >= -0.1 dB (`CLEAN_TOL`) | output may not end further from clean than the input was |

### `stars`: astro (`eval/stars.py`)

Synthetic stars (48 per crop, 12 px apart) on a darkened, smoothed sky at ISO 6400 and 12800, measured
differentially: (f(starry + n) - f(clean + n)) / true flux with the same noise n. Real: stars detected on the
noisy sky box of RAWs in `--astro-list` (or `$LUMEN_ASTRO_LIST`, or real files named astro/star/night/milky).

| check | threshold | rationale |
|---|---|---|
| `star_faint_kept` (5-10x SNR) | median >= 0.70 (`FAINT_MIN`) | 30 % dimming (~0.4 mag) is visible on a star field |
| `star_10-25x_kept`, `star_25-60x_kept` | median >= 0.90 (`BRIGHT_MIN`) | bright stars have no excuse to dim > 0.1 mag |
| `stars_lost` | <= 5 % of >= 5x stars below 30 % flux (`LOST_MAX`, `LOST_FRAC`) | identity ~0 % |
| `star_faint_vs_baseline` | >= -0.05 (`BASE_MARGIN`) | paired on the same seeds |
| `real_star_flux_kept` | >= 0.75 (`REAL_FLUX_MIN`) | an exact denoiser keeps 0.99-1.0 (faint half ~0.97, detection on the noisy frame); slack for real PSFs and hot pixels |
| `real_stars_lost` | <= 0.10 (`REAL_LOST_MAX`) | detection is ~9 sigma of the smoothed noise (no false hits on a synthetic sky); hot pixels count as stars and a denoiser should remove them |
| `real_star_flux_vs_baseline` | >= -0.05 (`BASE_MARGIN`) | real median flux kept may trail the baseline's by at most 0.05 |

### `a/b`: blind A/B (`eval/abtest.py`), claim only

| check | threshold | rationale |
|---|---|---|
| `ab_ours_vs_lightroom` | rate > 0.5, p < 0.05, n >= 20 decisive | see above |
| `ab_photos` | >= 8 distinct photos (`gate.AB_MIN_PHOTOS`) | one scene cannot carry the claim |
| `ab_ours_vs_original` | INFO | sanity: ours should beat the untouched RAW |

## Running on the Mac (real data)

Paths are the repo defaults; every flag can override them.

| input | default | made by |
|---|---|---|
| held-out clean frames | `data/gt_val/*.npy`, `data/gt_meta.json` | `prepare.py` |
| noise calibration | `weights/calib.json` | `calibrate.py` |
| real high-ISO RAWs | `data/lists/local_real_noisy.txt` (`--real-list`) | `select_set.py` + `copy_set.py` |
| real base-ISO RAWs | `data/lists/local_clean_val.txt` (`--lowiso-list`) | same (held-out clean list) |
| night-sky RAWs | `data/lists/local_astro.txt` (`--astro-list`) | write by hand: one path per line |

rawpy and `exiftool` must be installed (`brew install exiftool`); otherwise the real rows SKIP.

```
python -m lumen_denoise.eval.gate --model net:runs/A/best.pt --baseline net:runs/prev/best.pt          # full
python -m lumen_denoise.eval.gate --model net:runs/A/best.pt --baseline net:runs/prev/best.pt --quick  # ~minutes, never a release
python -m lumen_denoise.eval.gate ... --only synthetic,detail                                          # iterate on one part
```

### Lightroom A/B

1. In Lightroom Classic, pick ~10 high-ISO photos from `local_real_noisy.txt` (both cameras, ISO 3200-25600,
   at least one night/shadow-heavy scene). Photo > Enhance > Denoise (default amount 50, or the amount you would
   really use). Lightroom writes `<name>-Enhanced-NR.dng`. Copy these DNGs to `reports/lightroom/`
   (file names must start with the original stem, e.g. `DSC01234-Enhanced-NR.dng`).
2. Make unlabelled crops with ours, Lightroom and the original:
   `python -m lumen_denoise.crops --files data/lists/local_real_noisy.txt --n 12 --methods net:runs/A/best.pt --ab reports/ab_crops --ours last`
3. Build the page: `python -m lumen_denoise.eval.abtest build --crops reports/ab_crops --out reports/ab.html --focus ours`
4. Open `reports/ab.html`, judge every pair (A / L / S keys, Z zooms), press "Download results" and copy
   `ab_results_*.json` into `reports/`. More judges or sessions: just add more files (duplicates are merged).
5. `python -m lumen_denoise.eval.abtest tally reports/ab_results*.json`, then rerun the gate.

## Synthetic smoke run (cloud / CPU, no photos)

```
python -m lumen_denoise.eval.gate --model wiener --baseline identity --synthetic --quick     # ~17 s (without --quick ~40 s)
python -m pytest tests/test_eval_*.py -q
```

Procedural scenes (`common.synthetic_scene`) replace the held-out frames, every real-photo row SKIPs, and the
verdict line says `NOT A RELEASE - synthetic smoke run`. It proves the pipeline and the direction of every
metric, not the quality of a model. Expected: `wiener` vs `identity` fails the whiteness rows of the synthetic
proxy and `hf_kept_shadow` (a 5x5 Wiener does remove shadow texture and leaves low-frequency noise);
`identity` vs `wiener` and `blur:2.0` vs `wiener` fail broadly.

## Known limitations

- **Synthetic noise is not real noise.** The PSNR, detail, low-ISO and star sections add Poisson-Gaussian noise
  from the calibration. Real raws also have row noise, fixed-pattern noise and slight spatial correlation, so
  the real-noise section is the only one that sees those, and its thresholds (flatness, variance band, banding)
  are not yet validated on A7 IV / GX85 files. Expect to loosen or tighten them after the first real run.
- **Calibration mismatch.** The no-reference checks normalize by the calibrated noise level. If `calib.json`
  is off for a body or ISO, the variance ratio moves with it (the band is +-40 % for that reason).
- **Lightroom comparison happens after rendering.** Lightroom's Denoise DNG is demosaiced linear RGB, not a
  Bayer raw, so it cannot be scored in packed-RGGB space with our metrics. It is rendered by rawpy (LibRaw
  default demosaic) next to our AHD-rendered columns; small rendering differences may let a judge recognise it.
  Only the blind A/B compares against Lightroom.
- **Thresholds tuned on synthetic scenes.** Several sit close to the Wiener reference (e.g. `struct_removed`
  0.19 vs 0.20 cap at ISO 25600); recheck all of them on real held-out frames.
- **A/B provenance.** The gate cannot prove the A/B files judged the model being gated, and judgements are
  treated as independent.
- **Real-file paths only exercised with fake loaders in the cloud** (rawpy files and exiftool absent).
