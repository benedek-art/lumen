# Raw-domain denoiser research (2026-10-18)

Target: Bayer-domain denoise of Sony A7 IV (33MP) and Panasonic GX85 (16MP) on an Apple M4 / 16 GB, under 10 s per 33MP image, fine-tuned on synthetic noise calibrated to those sensors, with clean low-ISO shots as ground truth.

Legend: VERIFIED = checked this session (HTTP status, file downloaded, or run). EST = estimate, not measured.

## Measured on this machine (Apple M4, 16 GB)

`UNetSeeInDark` (7.76 M params, nf=32), full frame, no tiling, packed 4ch 2336x3504 (a 33MP A7 IV), PyTorch MPS, inference only:

| dtype | time |
|---|---|
| fp16 | **3.0 s** (second run, after warm-up) |
| fp32 | 119 s (memory pressure/swap; unusable) |

So the SID/ELD UNet fits the 10 s budget in fp16 with about 3x headroom. Heavier nets (NAFNet 7.6 M, Restormer 4.6 M as configured in LED, SCUNet, sRGB Restormer) need tiling and an fp16 check on MPS; not measured here.

## Ranked table

Rank is for "best start point for a Bayer-domain fine-tune that can beat Lightroom AI Denoise", not out-of-the-box quality. None of the released raw checkpoints targets normal-exposure or high-ISO daylight work. They are low-light (digital gain 100-300) models, so fine-tuning is mandatory.

| # | Candidate | Domain | Params | Speed on M4 (33MP) | License | Pretrained weights | Train code | Noise-synth / calib code |
|---|---|---|---|---|---|---|---|---|
| 1 | **LED** (Jin et al., ICCV23) incl. UNet / NAFNet / Restormer backbones | packed 4ch RGGB, (x-bl)/(wl-bl), times ratio | UNet 7.76 M, NAFNet-w32 7.60 M, Restormer-dim32 4.56 M | UNet 3 s fp16 (VERIFIED); NAFNet/Restormer EST 10-40 s, tiled | CC BY-NC 4.0 (non-commercial) | yes, GitHub releases (VERIFIED) | yes (BasicSR) | yes, incl. dark-frame and colour-card calibration |
| 2 | **Sony AIM25 baseline** (Sony Research, ICCV25 workshop) | packed 4ch RGGB, normalized, dgain applied | 7.76 M | 3 s fp16 (VERIFIED) | MIT | yes, in the repo (31 MB, strict load VERIFIED) | yes (`train_denoise.py`) | yes: dark-frame sampling + Poisson, flat-field and dark-shading calibration, **includes A7R4 data** |
| 3 | **Sony CVPR25 "Noise modeling in one hour"** | same | 7.76 M | 3 s fp16 | MIT | yes, Google Drive via gdown (VERIFIED, 2 files, 31 MB each) | no training script (test only) | partial (`datasets/unprocess.py`); the method is what the AIM25 repo implements |
| 4 | PMN (Feng et al., ACM MM22 / TPAMI) | packed 4ch, SID/ELD style | 7.76 M UNet | 3 s | Apache-2.0 | Baidu only (not usable); PMN-trained UNet mirrored in LED releases (VERIFIED) | yes | yes (PMN noise sampling, `megvii-research/PMN`, branch TPAMI) |
| 5 | ELD (Wei et al., CVPR20) | packed 4ch RGGB | 7.76 M UNet | 3 s | MIT | Google Drive folder (not tested); mirrored as `ELD_Deploy_*` in LED releases (VERIFIED) | yes | baseline G / G+P / G+P* models and calibrated params for the ELD cameras. Their own TL+row model and calibration were withheld; LED re-implements it |
| 6 | SID UNet (Chen et al., CVPR18) | packed 4ch, ratio-scaled | 7.76 M | 3 s | MIT | in LED releases (`SID_Deploy_*`, VERIFIED) | yes | none (real pairs) |
| 7 | DNF (`kepengxu/DNF`) | packed 4ch Sony | not checked | not evaluated | NOASSERTION (no license) | Google Drive / Baidu (not tested) | yes | no |
| 8 | CPADNet (ICIP25, `OBAKSA/CPADNet`) | SID Sony, NAFNet/Restormer conditioned on ISO/shutter/F-number | not checked | EST like NAFNet/Restormer | no license file | in repo `/pretrained_models` (not downloaded) | eval only | none |
| 9 | "Rethinking Noise Synthesis" (Zhang et al., ICCV21), `zhangyi-3/noise-synthesis` | raw (SIDD-Medium) | not checked | not evaluated | MIT | Baidu only (not usable) | yes | yes: pattern-aligned patch sampling, high-bit reconstruction |
| 10 | NAFNet (megvii) | sRGB, [0,1] | 17-115 M | tiled, 30 s+ EST | MIT | SIDD-width32/64 on Google Drive / ModelScope (README links, not tested) | yes (BasicSR) | no |
| 11 | Restormer real denoising | sRGB | 26 M | tiled, 60 s+ EST | MIT | `real_denoising.pth` 104.6 MB, GitHub release (HTTP 200, VERIFIED) | yes | no |
| 12 | SCUNet real | sRGB | ~15 M | tiled, 30 s+ EST | Apache-2.0 | `scunet_color_real_psnr.pth` / `_gan.pth` 72 MB (HTTP 200, VERIFIED) | yes (KAIR) | sRGB degradation pipeline only |
| 13 | Uformer | sRGB | 20-50 M | tiled, slow EST | MIT | SharePoint link (not testable) | yes | no |

Not found: a 2024-2026 open raw denoiser with downloadable weights that is clearly stronger than the UNet class. MIPI 2024 few-shot raw denoising entries mostly reuse LED with bigger backbones (NAFNet/Restormer). AIM 2025 winners (e.g. CPADNet's idea, 1st in the video track) have no raw-image checkpoint I could verify. Searches for "ultra-high-definition raw" and RawDenoise returned nothing downloadable.

## Where the quality will come from

The pretrained weights are only a starting point: the 7.8 M UNet is the architecture the whole field uses (SID, ELD, PMN, LED, Sony), and its ceiling is modest. To beat Lightroom AI Denoise: (a) UNet for pipeline plumbing, (b) your own noise model per sensor, (c) a bigger backbone (LED's 4ch NAFNet or Restormer; 7.6 M and 4.6 M here are small, widen them) trained with the same synthetic pipeline once the pipeline works.

## Downloaded (top 3 picks)

All under `/Users/benedekpurnhauser/Projects/lumen-denoise/models/`. Repos are shallow clones; no install scripts were run.

| Dir | Content |
|---|---|
| `led/repo` | https://github.com/Srameo/LED |
| `led/weights/` | 3 UNet LED pretrains, `ELD_Deploy_SID_SonyA7S2_MM22_*` (PMN-trained plain UNet), LED+NAFNet and LED+Restormer pretrains, two noise-generator state dicts (SonyA7S2 calibrated, 5 virtual cameras); ~340 MB |
| `sony-aim25/repo` | https://github.com/SonyResearch/AIM2025_Denoise_Challenge (contains `checkpoints/epoch_500.bin`) |
| `sony-cvpr25/repo` | https://github.com/SonyResearch/raw_image_denoising |
| `sony-cvpr25/weights/` | `sonya7s2.pth`, `imx686.pth` (Drive folder 1KyR9f6SIciXWv29owm0xYPCOnaMd9YWh, via gdown) |

Release URLs (HTTP 200 / downloaded):
- `https://github.com/Srameo/LED/releases/download/0.1.0/<name>.pth` (UNet LED / ELD / PG / SID, noise generators)
- `https://github.com/Srameo/LED/releases/download/0.1.1/LED%2BNAFNet_Pretrain_None_None_CVPR20_Setting_Ratio100-300.pth`, `.../LED%2BRestormer_Pretrain_None_None_CVPR20_Setting_Ratio100-300.pth`
- Not downloaded (sRGB fallbacks): `https://github.com/swz30/Restormer/releases/download/v1.0/real_denoising.pth`, `https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth`

## Per-model notes

### 1. LED (`models/led/repo`, CC BY-NC 4.0)

- Network classes: `led/archs/unet_arch.py` (`UNetArch`, same as SID), `nafnet_arch.py`, `restormer_arch.py`, `repnr_utils.py` (re-parameterization). Configs: `options/base/network_g/{unet,nafnet,restormer}.yaml` and `repnr_*.yaml` (4 in / 4 out, width/dim 32).
- Input: packed RGGB 4ch, `x = (raw - black) / (white - black)`, then `x * ratio`, clipped at 1.0 on top; output has the same (amplified) scale. Packing is `raw[0::2,0::2], raw[0::2,1::2], raw[1::2,0::2], raw[1::2,1::2]` = R, G1, G2, B for RGGB. Helpers: `led/data/raw_utils.py` (`pack_raw_bayer`, `depack_raw_bayer`, `read_img`).
- Calibration/noise code: `led/data/noise_utils/noise_generator.py` (`CalibratedNoisyPairGenerator`, `VirtualNoisyPairGenerator`: shot, Tukey-lambda read, row, quantization), `noise_utils/common.py`; `docs/calib_en.md` (24-patch colour chart fits K, dark frames fit read and row noise, then log-log regression of K vs sigma across ISO). Needs chart shots and about 15 dark frames per ISO.
- Few-shot fine-tune: `scripts/cutomized_denoiser.py` (BasicSR-based; not installed).
- License is non-commercial. Fine for personal use; blocks shipping derived weights commercially.

### 2. Sony AIM25 baseline (`models/sony-aim25/repo`, MIT)

- Network: `models/ELD_models.py::UNetSeeInDark` (in 4, out 4, nf 32, 7,760,484 params, LeakyReLU 0.2). Its `forward` pads H and W up by `16 - n % 16`, i.e. **an extra 16 px even when n is already a multiple of 16**, then crops.
- Input: packed RGGB, `(raw - mean(black_level_per_channel)) / (white_level - mean_bl)`, times dgain, clipped to (0, 1).
- Camera-agnostic training on SID long-exposure clean images with noise synthesized for Canon 70D, Sony A6700, ZV-E10M2, **A7R4**. Dark-frame sampling gives the signal-independent part (row noise included, no parametric model); calibrated-gain Poisson gives shot noise.
- Reusable: `datasets/synth_train_dataset.py::noise_synthesis` (`poisson(img/gain)*gain - img + dark_frame`), `noise_calib/calib_dark_shading.py`, `noise_calib/calib_flat_field.py`, `datasets/camera_config.yaml`. The A7 IV and GX85 need your own dark frames and flat fields (the challenge calibration data was not downloaded).
- Training: `train_denoise.py`, `train_parallel.sh`.

### 3. Sony CVPR25 (`models/sony-cvpr25/repo`, MIT)

- Same `UNetSeeInDark`; weights are bare state dicts. Paper: https://arxiv.org/abs/2505.00045 (up to 0.54 dB over PMN's noise synthesis on SID/ELD/LRID). Eval needs the 36 GB ELD/SID datasets (not downloaded). Pre-computed dark shadings are in a separate Drive folder (18YUiNsSH-YR9L5KJZGP23-DsOvJC0JWz), not downloaded. No training script; the AIM25 repo has the loop for the same pipeline.

### sRGB fallbacks (not downloaded)

- Restormer real denoising: `basicsr/models/archs/restormer_arch.py`, RGB [0,1], pad to multiple of 8, `torch.load(p)['params']`. About 26 M params, tiling mandatory on 16 GB.
- SCUNet: `models/network_scunet.py`, `SCUNet(in_nc=3, config=[4,4,4,4,4,4,4], dim=64)`, plain state dict.
- NAFNet-SIDD: width 32 or 64, RGB [0,1], weights on Drive/ModelScope.
- These work on demosaiced sRGB, losing the point of raw-domain denoising. Comparison baselines only.

## Loading the published weights in plain PyTorch (all checks below were run)

Our code: `lumen_denoise/model.py::UNetSeeInDark` (SID names, wrapped as `Denoiser.net`, input 4 + 1 noise-map channel), loader `lumen_denoise/train.py::load_init`.

### A. Sony AIM25 checkpoint, Sony CVPR25 weights, LED `*_Deploy_*` files: load directly

| File | Container | Key prefix | `load_init` result |
|---|---|---|---|
| `sony-aim25/repo/checkpoints/epoch_500.bin` | dict, `['model']` is the state dict | none (`conv1_1.weight`, ..., `conv10_1.bias`; 46 tensors) | 46/46 |
| `sony-cvpr25/weights/sonya7s2.pth`, `imx686.pth` | bare state dict | none | 46/46 |
| `led/weights/ELD_Deploy_SID_SonyA7S2_MM22_*.pth` (and other `*_Deploy_*`) | dict, `['params']` | none | 46/46 |

`load_init` already handles these (it unwraps `model`/`params`, then maps `k` to `net.k`, and zero-pads `conv1_1.weight` from 4 to 5 input channels for the noise map).

Verified: with `Denoiser.net` loaded from `epoch_500.bin`, and input = 64x64 random 4ch plus a zero noise channel, zero-padded by 16 px on the right/bottom (to mimic the reference class' pad), the output matches the reference `UNetSeeInDark` with max abs diff **0.0**. Without that pad the results differ near the edges only (0.54 max diff on a 64x64 tile) because the reference class always adds 16 px of zero padding.

Pitfalls for our model:
1. `Denoiser.forward` returns `noisy + net(x)` (residual). The published nets output the clean image directly, so with these weights the output is clean_est + noisy, not clean_est. The `load_init` docstring ("pretrained behaviour is preserved") holds only for the zero-padded noise channel, not for the residual wrapper. Options: init with a non-residual path, or fine-tune until the net learns the residual. This is not fixed in this commit; it is your call.
2. The published nets were trained on inputs multiplied by dgain 100-300, so input statistics are very different from normal-exposure data. Expect to need real fine-tuning, not just a warm start.
3. `UNetSeeInDark` in `model.py` has no padding; H and W must be multiples of 16 (the reference pads).

### B. LED pretrains (`LED_Pretrain_*`, `LED+NAFNet_Pretrain_*`, `LED+Restormer_Pretrain_*`): must be merged first

These store the re-parameterized form: each dense `Conv2d` is replaced by `RepNRConv2d` with keys
`<name>.main_weight`, `<name>.main_bias`, `<name>.align_weights.{0..5}` (shape `(1, C_in, 1, 1)`), `<name>.align_biases.{0..5}`. Only 10 or fewer tensors keep their plain names. Under key `['params']`.

- UNet (`LED_Pretrain_None_None_CVPR20_Setting_Ratio100-300.pth`): 262 tensors. Plain keys kept: `conv10_1.{weight,bias}` and the four `upv6..9.{weight,bias}` (ConvTranspose2d), 10 in total. The other 18 convs have the repnr keys above.
- NAFNet (`LED+NAFNet_*`): 1432 tensors. Converted: every dense conv (e.g. `intro`, `blocks`' 1x1 convs); kept plain: `ending`, `dwconv2`, `downconv`, `upconv`, LayerNorm `weight/bias`, `beta`, `gamma`.
- Restormer (`LED+Restormer_*`): 1003 tensors. Kept plain: `output`, `dwconv`, `qkv_dwconv`, norm weights, `temperature`.
- Branches 0-4 are the 5 virtual cameras; branch 5 (the default, `idx=-1`) is the "generalized" slot, which I verified equals the mean of branches 0-4 for the UNet pretrain (not all ones). LED's `deploy()` uses branch -1.

**Warning:** `load_init` on a `LED_Pretrain_*` file does not fail. It loads **10/46 tensors** and silently leaves all main convs at random init. Merge first.

**Yes, the re-parameterized UNet merges exactly into a plain `UNetSeeInDark`.** Per conv, with branch `i` (default last = 5): the align layer is a per-input-channel affine `a*x + ab` placed before the conv, so

- `weight' = main_weight * a.reshape(1, C_in, 1, 1)`
- `bias'  = main_bias + conv2d(replicate_pad(ab), main_weight)` (LED's own formula; the bias contribution is padded with replicate, so borders match LED's reparameterized forward)

Verified code (copy into the loader; no LED import needed):

```python
import torch, torch.nn.functional as F

def merge_led(sd, branch=-1):
    """LED re-parameterized state dict ['params'] -> plain-network state dict."""
    out = {}
    for k in sd:
        if k.endswith('.main_weight'):
            p = k[:-len('.main_weight')]
            n = len([q for q in sd if q.startswith(p + '.align_weights.')])
            i = branch if branch >= 0 else n - 1
            a, ab, W = sd[f'{p}.align_weights.{i}'], sd[f'{p}.align_biases.{i}'], sd[k]
            pad = (W.shape[-1] - 1) // 2
            out[p + '.weight'] = W * a.reshape(1, -1, 1, 1)
            out[p + '.bias'] = F.conv2d(F.pad(ab, (pad,) * 4, mode='replicate'), W,
                                        bias=sd.get(p + '.main_bias')).reshape(-1)
    for k, v in sd.items():
        if '.align_' not in k and not k.endswith(('.main_weight', '.main_bias')):
            out[k] = v
    return out

sd = torch.load('LED_Pretrain_None_None_CVPR20_Setting_Ratio100-300.pth',
                map_location='cpu', weights_only=False)['params']
merged = merge_led(sd)            # 46 keys, same names as UNetSeeInDark
torch.save({'params': merged}, 'led_unet_merged.pth')   # load_init then gives 46/46
```

Test results (all run on this machine):
- UNet: merged weights load `strict=True` into the Sony `UNetSeeInDark`; output vs LED's own `RepNRConv2d` reparameterize forward (branch -1): max abs diff **7e-7**. `load_init` on the merged file: **46/46**.
- NAFNet-w32 (4ch, `img_channel=4, width=32, blocks [2,2,2,2], middle 2`): merged loads strict into the plain LED `NAFNet`; 7.60 M params; max abs diff vs LED reparam forward **1e-6**.
- Restormer (`dim=32, num_blocks=[2,2,2,2], num_refinement_blocks=1`): 4.56 M params; max abs diff **7e-7**, but requires `bias=True` on the merged convs, and the class hard-codes `bias=False` for `patch_embed.proj`, `down*.body.0`, `up*.body.0`, `reduce_chan_level*` (those get a bias from the align biases). In the test I attached a bias parameter to each such conv, and set the biases that the pretrain lacks (every `dwconv`/`qkv_dwconv` bias, `output.bias`) to zero. **LED's own `deploy()` drops these biases for `bias=False` convs, so LED's deployed Restormer differs from its reparameterized forward.** Prefer the UNet or NAFNet.
- Classes are imported from LED's files with a stub for `led.utils.registry`; NAFNet/Restormer need no other LED code (Restormer needs `einops`).

The merged UNet has no relationship to our extra noise-map channel: apply `load_init` after merging (it zero-pads `conv1_1.weight` to 5 channels).

Which LED file to use as a warm start: pick by additional-gain range. `Ratio100-300` = CVPR20 (ELD) noise at ratios 100-300; `MM22` = PMN-style noise; `Ratio1-200` = low ratios. None is trained for normal exposures.

## Recommendation

1. Use the SID/ELD `UNetSeeInDark` architecture with the Sony AIM25 `epoch_500.bin` checkpoint (MIT) as the day-one inference target: it already runs 33MP in 3 s fp16 on this M4, leaving about 7 s of budget for IO, DNG writing, and optionally a second pass.
2. Reuse Sony's dark-frame-sampling + flat-field-gain pipeline (`synth_train_dataset.py`, `noise_calib/`) as the primary noise synthesis (MIT, no parametric noise model to mis-fit), and add LED's `noise_generator.py` (row noise, Tukey-lambda read, quantization) as an ablation. Keep LED code out of any redistributed product (CC BY-NC).
3. To beat Lightroom, plan a second stage with a bigger backbone (LED's 4ch NAFNet or Restormer config, widened) trained on the same synthetic pipeline, tiled with overlap in fp16, compared against the UNet on your clean low-ISO ground truth. The small UNet alone is not expected to beat Adobe on detail retention.
4. Train on normal-exposure ranges (ISO 100-12800, unit gain): every released checkpoint assumes extreme digital gain.

## Riskiest unknown

Domain gap from "extreme low-light, dgain 100-300" to "normal-exposure high-ISO photography". All released weights are for brightening dark frames, where noise after huge amplification is dominated by read/row noise. Your use is ISO 800-12800 at nominal exposure, where shot noise and fine-detail preservation dominate. Whether a small UNet fine-tuned from those weights can match Adobe's AI Denoise on detail in that regime is unproven. First experiment: fine-tune on a handful of A7 IV ISO pairs and blind-compare against Lightroom on held-out frames before building a bigger backbone.

Second-order risks: (a) the A7 IV's on-sensor processing/compression at high ISO may break the Poisson-Gaussian assumption; (b) DNG writing for A7 IV/GX85 (colour profile, linearization table, active area) is untested and absent from every repo here; (c) all the 4-channel nets assume RGGB, so the GX85 CFA pattern should be confirmed with rawpy; (d) license: LED code and weights are CC BY-NC.
