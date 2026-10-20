# Training recipe v2: options, evidence, A/B plan

Goal: the next run on the M4 beats B4, mostly at ISO 12800-51200, where B4 trails the older Sony-pretrained model by about 1.2 dB.
B4 = residual UNet nf48, B4 recipe (see `train.py` docstring); held-out tone-PSNR at ISO 400/1600/6400/25600: 49.7/46.1/42.4/38.3.

Every option is behind a flag in `lumen_denoise/train.py`. With no new flags a run is the B4 recipe: same model, noise, sampling, loss and RNG draws. Nothing here was trained. Every dB number marked "estimate" is a guess from literature or arithmetic, not a measurement on this data.

Timing anchors (M4, measured or extrapolated): UNet nf48 about 0.6 s/step at full duty (bs 8, ps 256), so about 1.0 s/step at `--duty 0.6`. Wall time = steps x s/step x ratio / duty. Inference budget <10 s per 33 MP (UNet nf32: 3.0 s net, 6.2 s CLI).

## 1. Options

### 1.1 Richer synthetic noise: `--noise-ext SPEC` (noise_ext.py)

What: extra terms on top of the calibrated Poisson-Gaussian noise. SPEC is a comma list or `all`:

| term | model |
|---|---|
| `row` | one Gaussian offset per RAW row (packed channels {0,1} share raw row 2i, {2,3} raw row 2i+1) |
| `col` | one offset per RAW column ({0,2} and {1,3}) |
| `gain` | per-channel shot-noise gain jitter (mean 1, signal untouched) |
| `fpn` | per-channel black bias + smooth 4x4 bilinear dark shading + per-raw-column offset |
| `hot` | isolated hot raw pixels, log-uniform amplitude 8 read-sd to 0.1 |
| `quant` | round to the camera's DN grid (14 bit Sony, 12 bit GX85) |
| `heavy` | Tukey-lambda read noise (heavier tails) at the same variance |
| `dualgain` | Sony read variance raised below the ISO 320 HCG switch (only matters with `--iso-min` < 400) |

Related flags: `--noise-ext-params data/noise_ext.json` (measured magnitudes from `calibrate_rows.py`; without it, literature-scale placeholders as fractions of read sd: row 0.08 Sony / 0.15 GX85, col 0.03 / 0.05), `--noise-ext-jitter 1.5` (log-uniform per-sample factor on row/col/fpn), `--val-noise-ext SPEC` (default `""` = plain Poisson-Gaussian validation, comparable to B4).

Why at high ISO: read noise is a large share of shadow noise there. A net trained on white noise leaves banding and blotchy colour as structured residue, or smooths real texture to fight it.

Evidence:
- ELD (Wei et al., CVPR 2020, https://arxiv.org/abs/2003.12751), Table 1, SID Sony PSNR at x100/x250/x300: Poisson-Gaussian 38.31/34.39/33.37; + Tukey-lambda 39.10/36.46/35.69; + row 39.23/36.89/36.01; + quantization 39.27/37.13/36.30 (paired real data 38.60/37.08/36.29). Gains grow as gain rises. Heavy tails are the biggest single term; row adds +0.13 to +0.43 dB.
- PMN (Feng et al., ACM MM 2022, https://arxiv.org/abs/2207.06103): dark-shading correction alone 44.47 -> 46.20 dB (ELD x100), 42.06 -> 43.06 dB (SID x100). This is the case for `fpn`.
- Zhang et al., "Rethinking noise synthesis", ICCV 2021 (https://arxiv.org/abs/2110.04756): physics models only remove the noise they model; 14-bit quantization matters at x100-x200.
- Dual gain: Kasson / photonstophotos data (https://blog.kasson.com/?p=28263) show a Sony read-noise drop at ISO 250 -> 320 (A7R IV). The A7 IV switch point and the 2.5 ratio are unverified.

Expected gain (estimate): `row,col,fpn` +0.1 to +0.4 dB on REAL Sony 12800-51200 frames, mostly less banding; `heavy` 0 to +0.5 dB in deep shadows; `quant` about 0 on Sony, +0.05 to +0.2 dB on GX85 shadows; `gain`, `dualgain` about 0. On the synthetic val (plain Poisson-Gaussian) expect about 0 or -0.05 dB: judge on real frames.

Caveats: magnitudes are placeholders until `calibrate_rows.py` measures them. If the measured Sony `row_sd` is about 0 (calibration already found Sony noise spatially white), leave `row` off: training on noise that is not there costs PSNR. `hot` can erase very compact stars: keep it off for astro runs or check the star bench. `fpn` is drawn per sample, not a fixed per-camera frame.

### 1.2 Row/column calibration: `calibrate_rows.py` (offline, no flag)

Measures, per camera and ISO: row_sd, col_sd (absolute std, normalized units), black_offset_sd (dark frames only), hot_rate, chan_gain_sd. Writes `data/noise_ext.json` for `--noise-ext-params`. Dark (lens-cap) frames are auto-detected (mean < 0.003), give black_offset and are about 10x more accurate than photos. From photos the estimate has a texture floor of about 0.05-0.1 read sd, so photo-only values near that are upper bounds. Synthetic accuracy: row 0.91-1.05x, col 0.87-1.04x on textured frames, 0.94-1.04x on dark frames, 0 when there is no banding. Method: row-mean / column-mean variance on bias frames (ELD; Harvest Imaging noise series, https://harvestimaging.com/blog/?paged=17), plus a texture-robust photo path (vertical second difference, flat blocks, cross-covariance of column halves).

### 1.3 Self-supervised term on REAL noisy photos: `--selfsup r2r|n2n` (selfsup.py, prepare_real.py)

What: each step also draws `--selfsup-bs 4` real high-ISO Sony crops (no ground truth) and adds `--selfsup-weight 0.3` x a self-supervised loss:
- `r2r` (Recorrupted-to-Recorrupted): input y + a z, target y - z/a, z ~ N(0, K x + r) from the calibration; L2, full resolution. Removes white noise at the calibrated level; keeps row banding (shared by input and target).
- `n2n` (Neighbor2Neighbor): two half-res sub-images from each 2x2 packed cell + consistency regulariser (gamma ramped from 0). `--selfsup-pairs vert` takes the pair from different raw rows, so row noise is independent between input and target and gets removed. Trains at half resolution; `--selfsup-ps` must be a multiple of 32.

Other flags: `--real DIR`, `--real-val DIR` (logs `<it> realval excess x`, lower is better), `--selfsup-start`, `--selfsup-ramp`, `--selfsup-every`, `--selfsup-alpha 0.5`, `--selfsup-gamma 1.0`, `--selfsup-iso-min 6400`, `--selfsup-norm std`. Off = no real batch, no RNG consumed. ISOs above calib.json are extrapolated physically (K proportional to ISO, r = b ISO^2 + c).

Why at high ISO: there the synthetic-to-real gap dominates (tails, residual structure, real night/indoor content). The 5,000 real frames are all high ISO.

Evidence:
- Neighbor2Neighbor (Huang et al., CVPR 2021, https://arxiv.org/abs/2101.02824), SIDD raw-RGB packed 4-channel, U-Net: N2N 50.76/51.06 dB vs supervised Noise2Clean 50.60/51.19 vs Noise2Noise 50.62/51.21; N2V 48.01/48.55. gamma=1 for real data; gamma=0 clearly worse.
- R2R (Pang et al., CVPR 2021, https://openaccess.thecvf.com/content/CVPR2021/html/Pang_Recorrupted-to-Recorrupted_Unsupervised_Deep_Learning_for_Image_Denoising_CVPR_2021_paper.html): expected loss = supervised MSE + const, explicitly extended to signal-dependent diag(b1 x + b2) noise, which is our K x + r. SIDD sRGB: R2R 34.78/35.04 vs N2V 29.56/30.72; 10% noise-level error costs about 0.05 dB.
- Generalized R2R (Monroy et al., 2024, https://arxiv.org/abs/2412.04648): Poisson within about 0.05 dB of supervised.
- Blind-spot methods (N2V, N2S) are not used: correlated row/column noise breaks their independence assumption.

Expected gain (estimate): on real Sony 12800-51200 frames +0.2 to +0.5 dB equivalent for either mode; n2n additionally less banding if row noise is real. Synthetic val: about +/-0.1 dB; a drop > 0.1 dB means the weight is too high. Mixing self-supervision into good synthetic supervision has only indirect published evidence, so this needs the A/B.

Step cost: r2r 1.37x, n2n 1.26x (CPU-measured ratio).

### 1.4 Loss options and ISO-balanced sampling: `--loss SPEC`, `--iso-sampling MODE` (losses.py)

`--loss` is a comma list of `name:weight` on top of `base` (= L1 tone + 4x L1 linear, bit-identical to B4):
- `fft:w` L1 of |rfft2| of the tone image (most blur-selective term in our tests: 1.7-2.1x penalty on a blotchy low-passed residual vs equal-base-loss noise).
- `fftri:w` L1 on rfft real/imag parts (MIMO-UNet style). `grad:w` L1 of finite-difference gradient error in tone space.
- `nw:p` per-sample weight (s_i / mean s)^p, s = noise std: shifts gradient toward high ISO.
- `charb[:eps]` Charbonnier instead of L1. `perc:w` / `perc3:w` small VGG16 term (needs `pip install torchvision`, downloads about 530 MB once; judge by eye).

`--iso-sampling`: `loguniform` (B4), `high[:f]` (with prob f=0.5 draw from the top two octaves), `bands:w1,w2,..` (per-octave weights), `adaptive` (per-octave EMA of loss steers sampling; `--iso-adapt-floor 0.3`; state saved in the checkpoint; probabilities logged as `isoP=`).

Why at high ISO: B4 loses about 1.9 dB per octave. With log-uniform sampling over 400-51200 the top two octaves are 28.6% of samples and get about 55% of the gradient (per-sample gradients scale with noise std). `high` puts 64% of samples there; `nw:0.5` raises the gradient share to about 66%. At high ISO an L1-trained net over-smooths; `fft` and `grad` push back.

Evidence:
- MIMO-UNet (Cho et al., ICCV 2021, https://arxiv.org/abs/2108.05054): frequency reconstruction loss (L1 on FFT, lambda 0.1) about +0.27 dB on GoPro (ablation, not re-checked against Table 4).
- Focal Frequency Loss (Jiang et al., ICCV 2021, https://arxiv.org/abs/2012.12821): spatial losses under-weight hard high frequencies.
- Zhao et al., IEEE TCI 2017: L1 beats L2 (from memory). Perceptual losses trade about 1-2 dB PSNR at full weight for texture (Johnson 2016, SRGAN 2017; from memory), hence weight 0.01.

Expected gain (estimate) at ISO 12800-51200: `high` or `adaptive` +0.3 to +0.6 dB at 25600-51200, -0.1 to -0.2 dB at 400-1600 (largest single lever); `fft:0.05` 0 to +0.2 dB and less waxy texture; `fft:0.05,grad:0.1` similar PSNR, better edges, maybe -0.05 dB at low ISO; `nw:0.5` +0.2 to +0.4 dB (do not stack with `high` without checking low ISO); `charb` about 0; `perc:0.01` -0.1 to -0.3 dB, grain-like texture.

Step cost: about +1-2% for fft/grad, about +10% for perc. Inference cost zero.

### 1.5 Stronger backbone: `--arch nafnet` (nafnet.py, model.py)

What: original MIT implementation of NAFNet blocks written from the paper (LayerNorm in fp32, SimpleGate, simplified channel attention, depthwise 3x3), same noise-unit residual interface as the UNet, final conv zero-initialised so the model is identity at init. Eval-time local SCA (TLC) for 1024 tiles vs 256 training patches: `--nafnet-tlc` (default = `--ps`, 0 = global). Presets via `--nafnet-preset` (default `s`), overrides `--nafnet-width/-enc/-dec/-middle`. Checkpoints carry `arch_code`/`arch_cfg` buffers, so `infer.py` loads them unchanged. A UNet `--init` into NAFNet loads nothing and the run exits with an error: NAFNet trains from scratch.

| preset | params | blocks enc/mid/dec | 33 MP net / CLI (estimate) | train step vs nf48 (CPU) |
|---|---|---|---|---|
| unet nf48 (B4) | 17.5 M | | about 5.6 s net | 1.0 |
| s | 3.9 M | w24, (1,1,1,2)/2/(1,1,1,1) | about 5.6 s / 8.8 s | about 0.7-1.2 |
| m | 11.6 M | w32, (1,1,2,4)/4/(1,1,1,1) | about 8 s / 11 s, likely over budget | about 1.1-1.5 |
| l | 29.2 M | paper's 36 blocks | over budget | 3.7 |

Why at high ISO: input-adaptive gating and channel attention act like noise-level-dependent shrinkage, and depth sits at coarse levels where large-area pooling is needed, at low full-res cost.

Evidence: NAFNet (Chen et al., ECCV 2022, https://arxiv.org/abs/2204.04676): SIDD ablation PlainNet 39.29 -> +LN 39.73 -> Baseline 39.85 -> NAFNet 39.96 dB; block count 9/18/36/72 = 39.78/39.90/39.96/39.95 (flat past about 18); raw denoising (PMRID 4Scenes) 40.05 dB at 1.1 GMACs vs PMRID 39.76 dB at 1.2 GMACs. TLC: Chu et al., ECCV 2022. NAFNet-family entries are standard raw baselines in NTIRE 2025 RAW restoration (https://arxiv.org/abs/2506.02197). No paper compares SID-UNet vs NAFNet on the same raw low-light split.

Expected gain (estimate): +0.1 to +0.5 dB at ISO 6400-51200 for a backbone that fits the budget; 0 to +0.2 dB at 400-1600. Preset s probably roughly matches nf48. If NAFNet does not beat nf48 by >= 0.1 dB at 25600, keep the UNet. NAFNet is LR sensitive (paper: AdamW lr 1e-3, LN makes it stable), so run lr 6e-4 too. Depthwise conv in MPS fp16 can be slow: measure first with `speedcheck`.

### 1.6 EMA and crash-safe checkpoints: `--ema 0.999`, `--resume` (ckpt.py)

EMA: shadow weights s = d s + (1-d) p with warmup min(d, (1+n)/(10+n)); validation, `real_excess`, `best.pt` and `last.pt` use EMA weights (still plain state dicts for infer.py). Cost: a few ms/step, about +70 MB.

Checkpoints (always on): `<out>/ckpt.pt` holds net, optimizer, scheduler, EMA, step, best, RNGs and ISO sampler; written atomically every `--ckpt-every 250` steps, at each validation, and on SIGTERM / SIGINT / SIGUSR1. `--stop-after N` = checkpoint and exit after N steps of this session. If ckpt.pt exists and neither `--resume` nor `--fresh` is given, train.py refuses to start.

Evidence: Polyak and Juditsky 1992 (iterate averaging reduces variance); BasicSR / NAFNet configs use ema 0.999; community reports +0.05-0.2 dB (no dedicated paper; from memory). Why at high ISO: high-ISO patches have the largest gradient variance at bs 8.

Expected gain (estimate): +0.05 to +0.2 dB, smoother val curves, less noisy best.pt choice. Resume adds no dB but makes 24k+ step runs practical at duty 0.6.

## 2. One-time prep on the Mac (from `Denoise/`)

Check the calibration ISO range first. Validation clamps each scene to its camera's max table ISO, so if a camera's table stops at 25600 its "51200" val number is really 25600 (GX85 tops out at 25600):

```
python -c "from lumen_denoise.train import NoiseTable;t=NoiseTable('data/calib.json');print({m:t.iso_range(m) for m in t.t})"
```

### 2a. Speed check (5 min)

```
python -m lumen_denoise.speedcheck --arch unet --nf 48 --steps 50
python -m lumen_denoise.speedcheck --arch nafnet --preset s --steps 50
python -m lumen_denoise.speedcheck --arch nafnet --preset m --steps 50
```
Prints inference time per 33 MP (12 tiles of 1024^2, like infer.py), s/step, wall time at duty 0.6 and MPS memory. Use the measured s/step to rescale every time below. Drop any preset over 10 s CLI (roughly > 7 s net). If memory > about 10 GB, use `--bs 4` or preset s.

### 2b. Row/column calibration (2-10 min + 10 min shooting)

Shoot 10-20 lens-cap dark frames per ISO per camera (ISO 800-51200 full stops, usual high-ISO shutter speed, viewfinder covered); add their paths to the calibrate.py list.

```
python -m lumen_denoise.calibrate_rows data/calib_list.txt --calib data/calib.json --out data/noise_ext.json --workers 6
```
About 0.4 s wall per file with 6 workers: 200 files 1-2 min, 1000 files 5-8 min. For 5,000 high-ISO frames, sample about 30 per (camera, ISO). Check the printed table: `row/read` ratio per ISO, and `row_meas` vs `row_synth` in the validation table should agree. Decision: if Sony row/read < about 0.05 at all ISOs and there are dark frames, drop `row` from the Sony arms.

### 2c. Real-photo crops for self-supervision (20-25 min, 20-40 GiB)

```
exiftool -q -r -ext ARW -if '$Model eq "ILCE-7M4" and $ISO >= 6400' -p '$Directory/$FileName' ~/Pictures > data/real_all.txt
n=$(wc -l < data/real_all.txt); tail -n 200 data/real_all.txt > data/real_val.txt; head -n $((n-200)) data/real_all.txt > data/real_list.txt
python -m lumen_denoise.prepare_real data/real_list.txt data/real --crops 2 --ps 512 --workers 6
python -m lumen_denoise.prepare_real data/real_val.txt data/real_val --crops 2 --ps 512
```
(`head -n -200` is GNU only; the `$((n-200))` form works on macOS.) About 1-1.5 s per frame, 15-25 min for 5,000 frames with 6 workers. Disk: 2 MiB per 512 crop: `--crops 2` about 20 GiB, `--crops 4` about 40 GiB. Resumable: rerun skips finished frames.

## 3. A/B plan

Protocol: fine-tune from B4 with a short fixed schedule. It is about 4x cheaper than from-scratch runs, every arm starts from the same weights, and a fair control (same fine-tune, no new flags) removes the "more steps" effect. Only the backbone arm must train from scratch (with its own from-scratch UNet control). Same `--seed` for all arms. One run at a time on the Mac.

Common prefix (replace `runs/B4/best.pt` with the real B4 checkpoint; keep B4's other args if they differed):
```
P="python -m lumen_denoise.train --gt data/gt --val data/gt_val --calib data/calib.json --residual --nf 48 --stars 0.4 --duty 0.6 --seed 0 --val-isos 400,1600,6400,12800,25600,51200 --val-every 500 --resume"
FT="--init runs/B4/best.pt --iters 3000 --lr 5e-5"
```
`--resume` can always be appended: it starts fresh when no ckpt.pt exists.

### Phase 1: fine-tune arms (ordered by expected value per hour)

Base cost: 3000 steps x 1.0 s = 50 min plus validation (6 ISOs x 7 vals), call it about 55 min.

| # | arm | command | step ratio | wall @ duty 0.6 (estimate) |
|---|---|---|---|---|
| F0 | control | `$P $FT --out runs/F0_ctrl` | 1.00 | 55 min |
| F1 | ISO oversampling | `$P $FT --iso-sampling high --out runs/F1_high` | 1.00 | 55 min |
| F2 | EMA | `$P $FT --ema 0.999 --out runs/F2_ema` | 1.01 | 55 min |
| F3 | fft + grad loss | `$P $FT --loss base,fft:0.05,grad:0.1 --out runs/F3_fftgrad` | 1.02 | 57 min |
| F4 | banding noise | `$P $FT --noise-ext row,col,fpn --noise-ext-params data/noise_ext.json --out runs/F4_band` | 1.03 | 57 min |
| F5 | R2R real photos | `$P $FT --real data/real --real-val data/real_val --selfsup r2r --selfsup-weight 0.3 --out runs/F5_r2r` | 1.37 | 75 min |
| F6 | N2N real photos | `$P $FT --real data/real --real-val data/real_val --selfsup n2n --selfsup-gamma 1 --selfsup-weight 0.3 --out runs/F6_n2n` | 1.26 | 70 min |
| F7 | adaptive ISO | `$P $FT --iso-sampling adaptive --out runs/F7_adapt` | 1.00 | 55 min |
| F8 | noise-weighted loss | `$P $FT --loss base,nw:0.5 --out runs/F8_nw` | 1.02 | 57 min |
| F9 | ELD physics set | `$P $FT --noise-ext row,heavy,quant --noise-ext-params data/noise_ext.json --out runs/F9_eld` | 1.03 | 57 min |
| F10 | full noise | `$P $FT --noise-ext all --noise-ext-params data/noise_ext.json --out runs/F10_noiseall` | 1.03 | 57 min |
| F11 | fft only | `$P $FT --loss base,fft:0.05 --out runs/F11_fft` | 1.01 | 56 min |
| F12 | perceptual (optional) | `pip install torchvision`, then `$P $FT --loss base,fft:0.05,perc:0.01 --out runs/F12_perc` | 1.10 | 60 min |

Phase 1 total: F0-F8 about 9 h, all arms about 13 h. Overnight in chunks: add `--stop-after 1500` and rerun the same command next session.

`realval excess` is only logged when `--selfsup` is on, so score any run (F0 included) on the held-out real crops with the same seeded metric afterwards (mode r2r = same metric for every run):
```
python -c "import sys,torch;from lumen_denoise import selfsup as S;from lumen_denoise.train import NoiseTable,std_map,DEV;from lumen_denoise.model import Denoiser
t=NoiseTable('data/calib.json');d=S.RealData('data/real_val','data/real_val/real_meta.json',device=DEV,iso_min=6400)
for w in sys.argv[1:]: n=Denoiser.from_state_dict(torch.load(w,map_location='cpu')).to(DEV);print(w,S.real_excess(n,d,t,n=64,ps=256,mode='r2r',std_fn=std_map))" runs/F0_ctrl/best.pt runs/F5_r2r/best.pt runs/F6_n2n/best.pt
```
For the self-supervised winner, sweep `--selfsup-weight 0.1` and `1.0`.

F4/F9/F10 and F5/F6 cannot show their gain on the synthetic val (it has no banding, no real noise). Judge them by: synthetic val not worse by > 0.1 dB, `realval excess` lower than F0, and the evaluation suite / bench on real ISO 12800-51200 Sony frames (banding and blotches by eye).

### Phase 2: combined run

Take every Phase 1 winner (rule in section 4). Likely combination:

```
$P $FT --iters 6000 --ema 0.999 --iso-sampling high --loss base,fft:0.05,grad:0.1 \
  --noise-ext row,col,fpn --noise-ext-params data/noise_ext.json \
  --real data/real --real-val data/real_val --selfsup n2n --selfsup-weight 0.3 --out runs/C1_combined
```
Do not stack `nw:` with `high` unless both won separately and low ISO holds. Wall: 6000 x 1.0 s x about 1.3 = about 2.2 h. Control for it: `$P $FT --iters 6000 --out runs/C0_ctrl` (1.7 h).

Optional from scratch with the same flags, 12000 steps, no `--init`, `--lr 2e-4`: about 3.3 h x step ratio, about 4.3-4.6 h with a self-supervised term.

### Phase 3: backbone (from scratch, most expensive, run last)

Use the Phase 2 recipe flags minus `--init` (call them `$R`), 12000 steps:

```
$P $R --iters 12000 --lr 2e-4 --out runs/S_unet48                                   # control, about 3.3 h x recipe ratio
$P $R --iters 12000 --arch nafnet --nafnet-preset s --lr 6e-4 --out runs/S_naf_s_lr6  # about 2.4-4 h
$P $R --iters 12000 --arch nafnet --nafnet-preset s --lr 2e-4 --out runs/S_naf_s       # about 2.4-4 h
```
Preset m only if speedcheck shows < 10 s CLI per 33 MP: about 5-8 h at duty 0.6. Note `--nf` is ignored for nafnet. Before shipping a NAFNet checkpoint, run infer on a real 33 MP frame and check for tile seams (TLC local SCA).

### Pause, crash, resume

- Pause: `kill -USR1 <pid>` (or Ctrl-C once, or `kill -TERM <pid>`). It writes ckpt.pt and last.pt and exits cleanly. A second Ctrl-C force-quits without saving.
- Continue: rerun the identical command (it already has `--resume`). After a crash or reboot you lose at most `--ckpt-every` (250) steps.
- `--resume` refuses if `--iters`, `--lr`, `--arch`, `--nf`, `--residual` or the NAFNet config changed. Turning `--ema` on at resume is allowed.
- Start over: `--fresh` (old ckpt.pt kept as ckpt.prev.pt).
- MPS kernels are not deterministic, so a resumed run is close to, not bitwise equal to, an uninterrupted one.

## 4. Reading results

Log: `runs/<name>/log.txt` (args in `args.json`).
- `<it> loss x <sec>s tone=.. lin=.. fft=..` every 100 steps (parts only when `--loss` is not `base`; `isoP=` with adaptive).
- `<it> val {400: .., 1600: .., ..., 51200: ..} mean m` at every validation; `best.pt` = highest mean.
- `<it> realval excess x` when `--selfsup` and `--real-val` are set (lower is better; compare across runs with the post-hoc snippet in Phase 1, which uses one mode for all).

Tabulate the final validation of each run:
```
python - <<'EOF'
import ast,glob,re
for f in sorted(glob.glob("runs/*/log.txt")):
    v=[l for l in open(f) if " val {" in l]
    if v: d=ast.literal_eval(re.search(r"\{.*\}",v[-1]).group()); print(f.split("/")[1].ljust(16)," ".join(f"{k}:{x:.2f}" for k,x in d.items()))
EOF
```

What counts as real: an arm wins at an ISO if it beats F0 by >= 0.1 dB at that ISO on the final validation AND on the one before it (the val set is seeded and fixed, but training noise moves single checkpoints by a few hundredths). An arm is accepted if it wins at >= 1 ISO in 12800-51200 and loses no more than 0.1 dB at any ISO below 6400. For noise and self-supervised arms, the synthetic-val rule is only "not worse by > 0.1 dB"; acceptance comes from real frames. When `--val-isos` has 6 ISOs, best.pt can differ from a 4-ISO run's, so compare per-ISO values, not the mean, against B4's 49.7/46.1/42.4/38.3.

## 5. Expected outcome (ESTIMATES, nothing trained)

Synthetic held-out tone-PSNR delta vs B4, per arm (dB):

| ISO | 400 | 1600 | 6400 | 12800 | 25600 | 51200 |
|---|---|---|---|---|---|---|
| B4 measured | 49.7 | 46.1 | 42.4 | n/a | 38.3 | n/a |
| F1 high | -0.1 to -0.2 | -0.1 | 0 to +0.1 | +0.2 to +0.4 | +0.3 to +0.6 | +0.3 to +0.6 |
| F2 EMA | +0.05 | +0.05 | +0.1 | +0.1 | +0.1 to +0.2 | +0.1 to +0.2 |
| F3 fft+grad | -0.05 to 0 | 0 | 0 to +0.1 | 0 to +0.2 | 0 to +0.2 | 0 to +0.2 |
| F4/F9/F10 noise | 0 | 0 | 0 | 0 (real: +0.1 to +0.4) | -0.05 to 0 (real: +0.1 to +0.4) | (real: +0.1 to +0.5) |
| F5/F6 selfsup | 0 | 0 | +/-0.1 | +/-0.1 (real: +0.2 to +0.5) | (real: +0.2 to +0.5) | (real: +0.2 to +0.5) |
| C1 combined | -0.1 to +0.1 | 0 to +0.1 | +0.1 to +0.3 | +0.4 to +0.7 | +0.4 to +0.8 | +0.4 to +0.9 |
| NAFNet s vs UNet48 | 0 to +0.2 | 0 to +0.2 | +0.1 to +0.3 | +0.1 to +0.4 | +0.1 to +0.5 | +0.1 to +0.5 |

Combined expectation: synthetic val about 49.6-49.8 / 46.1-46.3 / 42.5-42.8 / 38.7-39.1 at ISO 400/1600/6400/25600, plus real-frame gains from the noise model and self-supervision that the synthetic val cannot show. Closing the full 1.2 dB gap at ISO 12800-51200 likely needs the sampling, noise-model and real-photo terms together; the backbone is a smaller lever.
