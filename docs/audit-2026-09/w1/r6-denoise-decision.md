# R6 — The denoise decision

Dossier for the 30-agent audit. Area **E (denoise & sharpening)** is the body; every other area
is "Not applicable" or a one-line pointer. It ends in a recommendation, as the brief asks.

Tags: `[fetch: <url>]` = read directly from the repository file named; `[search: <url>]` = a
search result states it; `[knowledge]` = training memory, unverified this pass; `[docs/nn §x]` =
already in the repo; `[repo: path:line]` = read from Lumen's own tree; `[derived]` = arithmetic
from tagged inputs.

---

## 0. Lumen today (what the auditors hold the survey against)

| Piece | What is actually there | Source |
|---|---|---|
| Classical engine (S3) | `NoiseProfile` (Poisson–Gaussian `a·x + b`, per-ISO curve, block-variance estimator with 10th-percentile χ² debias) → generalized Anscombe `VST` with Makitalo–Foi exact-unbiased inverse → à-trous B3-spline wavelet, `defaultLevels = 5` (31 px support, 24 px declared halo) → luma/chroma soft shrinkage in a Y0U0V0-style space (`lumaK`/`chromaK` bounded ≤ 2.5σ, anchored) → luminance-guided "blotch" pass (`blotchMaxMix ≤ 0.10`) → hot-pixel replace. Wire format `ClassicNR(luma, chroma, hotPixels)`; the four LR-parity sub-sliders are engine constants. f64 reference, Metal measured against it. | `[repo: Sources/LumenCore/Image/DenoiseEngine.swift:1–1330]` |
| AI splice (S2) | `AIDenoiseSplice` exists and is complete for what surrounds a model: `blend(original:denoised:amount:)` = `(1−t)·input + t·artifact`, `amount(for:)` (nil unless `.ai`), `ArtifactKey` = (photo_id, kind, component_id, model_id+model_version, prefix_hash, pipeline_version) → `artifacts/xx/….atlas`; `TilePlan` with fixed tile extents (S2 default **768 px / 32 px apron**, S3 2048 px / 24 px) and `stitch`. **Nothing calls it.** | `[repo: DenoiseEngine.swift:1337–1650]` |
| `.ai` mode today | `Denoise.Mode { off, classic, ai }`, `amount` 0…100 default 50. In `.ai`, `appleStandIn` maps Amount to `CIRAWFilter.luminanceNoiseReductionAmount / colorNoiseReductionAmount`; it is part of the decode key so every Amount step re-demosaics; on rendered (non-RAW) files it drives nothing. Panel segment reads "AI (stand-in)". | `[repo: Sources/LumenCore/Recipe/Recipe.swift:1050–1095; Sources/LumenPipeline/AppleRawSource.swift:318–334; Sources/LumenApp/DetailPanel.swift:388, 509–530]` |
| CoreML plumbing | None. No `import CoreML` anywhere in `Sources/`; `VisionMattes.swift` uses Vision only. Catalog already has `model_id`/`model_version` columns on the artifact table. Platform floor macOS 15 (mlprogram, `MLTensor`, async prediction all available). | `[repo: grep; Sources/LumenCore/Catalog/Schema.swift:214; CatalogStore.swift:258; Package.swift:20]` |
| Download-on-first-use precedent | `AppUpdater` reads a GitHub release (`dev-latest`) via api.github.com, downloads `Lumen.app.zip` with no auth, verifies **size + codesign**, swaps. No content hash yet — a model asset needs SHA-256 (CryptoKit). | `[repo: Sources/LumenApp/AppUpdater.swift:8–12, 109–224]` |
| Ground-truth pair | `ProofFrames.noisyISO6400()`: **128×128** synthetic; clean = grey ramp `midGrey·2^(−3+5v)` × 6-px sinusoid (±15 %); noise = per-channel Gaussian with σ from a shot+read model (1500 e⁻ well, 3 e⁻ read). `noisyLumaFrame(iso:)`/`noisyChromaEdge(iso:)` use `NoiseProfile.forISO(iso).sigma(at:)` — the engine's own model. Metrics: `rmsAgainst` (RMS in code values), `edgeRetention` (step across ±4 px), fine-band correlation (level-0 à-trous detail). | `[repo: Tests/LumenCoreTests/Proof/ProofFrames.swift:285–470; ProofMetrics.swift:268–300]` |
| What "good" is measured as | Both masters at 100: residual < 0.90× undenoised; top of travel < 1.5× best point; every Colour setting < 0.95× undenoised on `noisyChromaEdge`; saturated colour edge retention > 0.90 (and < 1.0); ISO-adaptive defaults within 1.05× their travel's optimum; Luminance 100 keeps fine-band correlation > 0.78 (untouched frame > 0.80). | `[repo: Tests/LumenCoreTests/Proof/DenoiseQualityTests.swift]` |

Two facts the recommendation turns on:

1. The ground-truth pair is **synthetic, luma-textured, 128 px, and noised with the engine's own
   profile**. It is a fair bar for the classical engine and an *unfair-in-both-directions* bar
   for a learned model: 128 px is smaller than one tile's receptive field, the scene has no
   chroma content, and the noise is not any camera's. §5 adds the fixture the gate needs.
2. Every RGB-domain candidate below was trained on **sRGB-encoded** pairs (SIDD) or synthetic
   sRGB degradations. Lumen's S2 input is **linear Rec.2020 scene-referred** `[docs/14 §2]`. A
   splice needs an encoding shim either way; it is part of the integration, not an afterthought.

---

## A. Tone & sliders
Not applicable.

## B. Colour & grading
Not applicable.

## C. Film & grain
Not applicable (docs/07 sends "grain back on top of a clean result" to the grain engine — a
learned denoiser's Amount is a plain blend, not a texture-restore).

## D. Looks/presets & effects
Not applicable.

---

## E. Denoise & sharpening — the survey

### E.1 Algorithmic (no model)

| Candidate | How it works (control names, ranges, defaults) | Licence | Source | Lumen would need |
|---|---|---|---|---|
| **darktable `denoise (profiled)`** | Modes `MODE_NLMEANS`, `MODE_NLMEANS_AUTO`, `MODE_WAVELETS` (default), `MODE_WAVELETS_AUTO`, `MODE_VARIANCE` (profiling). VST: classic `2·sqrt(d/a + 3/8)`, or **v2 extended** `V(X)=a·(E[X]+b)^p` with `p[c] = max(shadows + 0.1·log(scale/wb[c]), 0)`, `P_FULCRUM = 0.05`; backtransform solves a quadratic with `bias`. Wavelets: à-trous B3 `[1,4,6,4,1]/16`, `DT_IOP_DENOISE_PROFILE_BANDS = 7`, `max_scale` where support ≤ 20 % of the buffer; Bayesian soft shrinkage `thrs = adjt·σ²_band/σ_x`, `adjt = 8·force²`, `σ_band ≈ 0.5^scale`; per-channel curves `x[6][7], y[6][7]` default 0.5. Colour: `wavelet_color_mode` RGB or **Y0U0V0** with a **white-balance-adaptive** matrix (`wb_adaptive_anscombe = TRUE`). NLM: `radius` (patch) 0–12 def 1, `nbhood` (search) 1–30 def 7, `scattering` 0–20 def 0 (`maxk = (K³+7K√K)·scattering/6 + K`), `central_pixel_weight` 0–10 def 0.1, norm `0.045/(2P+1)²`. Shared: `strength` 0.001–1000 def 1, `shadows` 0–1.8 def 1, `bias` −1000–100 def 0, `overshooting` (auto tune) def 1; `a[3], b[3] = −1` → auto from `noiseprofiles.json`. | GPL-3.0+ (code); `noiseprofiles.json` GPL data | `[fetch: raw.githubusercontent.com/darktable-org/darktable/master/src/iop/denoiseprofile.c]` | Lumen has the classic VST + 5-band Y0U0V0 shrinkage. Missing vs darktable: the **v2 exponent-p VST** with `shadows`/`bias` (fixes the deep-shadow under-denoise the Anscombe 3/8 pedestal leaves — Lumen's own comment at `DenoiseEngine.swift:328` notes an ISO 102400 black pedestal), **wb-adaptive Y0U0V0**, 7 bands, per-band curves, and an NLM option. `[repo: DenoiseEngine.swift]` |
| RawTherapee Noise Reduction | Wavelet luminance (`Luminance`, `Detail recovery`, per-level "curve") + chrominance in Lab with `Automatic global` / `Manual` chroma, `Median` pass (3×3…9×9), `Impulse NR` for hot pixels, **applied at output resolution only** (preview is not truthful at < 100 %). | GPL-3.0 | `[knowledge]` `[docs/03 §7]` | Nothing new beyond darktable's set; the "Impulse NR" is Lumen's hot-pixel pass. |
| BM3D / BM3D-CFA | Block matching + collaborative 3-D transform shrinkage; CFA variant denoises four Bayer mosaics. | Tampere reference: research/non-profit; PyPI `bm3d`: **non-commercial only** | `[search: pypi.org/project/bm3d]` `[docs/07 landmines]` | Do not take code. Re-implement from the IPOL paper only if ever wanted; not recommended — 10–50× the wavelet cost for ~1 dB. `[knowledge]` |
| Neat-style profiled | Closed (Neat Image/Video): per-camera profiles + frequency-band/channel strengths. | Proprietary | `[knowledge]` | Note only; Lumen's profiled à-trous is the same family. |
| **GALOSH (Jul 2026)** | Blind per-image Poisson–Gaussian fit → generalized Anscombe → **two-pass local Walsh–Hadamard shrinkage** of luma → luma-guided local regression of chroma; raw Bayer and sRGB; "strongest among tested blind training-free methods on SIDD Medium and RawNIND, approaching trained networks on raw"; 16 MP raw 0.76 s CPU. **US provisional patent 64/058,343 filed 6 May 2026.** | Code licence not surfaced; **patent pending** | `[search: arxiv.org/abs/2607.03768]` | Do not adopt (patent). Its two ideas Lumen already has in spirit (VST, luma-guided chroma). NEW. |
| Anscombe VST + shrinkage | What Lumen ships (above). | — | `[repo]` | — |

### E.2 Learned, RGB domain

Published numbers are sRGB SIDD/DND PSNR (dB). "Conv." = CoreML conversion outlook for a fixed
768² fp16 mlprogram. Sizes are fp16 weight bytes `[derived]` from param counts.

| Model | Licence (verified from LICENSE) | Params / cost | Input & noise model | Weights | SIDD / DND | Conv. / ANE | Lumen would need |
|---|---|---|---|---|---|---|---|
| **NAFNet-SIDD-width32** | **MIT** (megvii-model 2022) + Apache-2.0 for BasicSR parts `[fetch: …/NAFNet/main/LICENSE]` | ≈17.1 M / 16 GMACs @256² `[knowledge]`; ≈34 MB fp16 | RGB `[0,1]` sRGB; trained on real SIDD (phone, ISO ≤ 3200) | Google Drive / Baidu only — **must be mirrored** into a Lumen release `[fetch: github.com/megvii-research/NAFNet]` | **39.97 / 0.9599** `[fetch: NAFNet README]`; DND ≈ 40.3 `[knowledge]` | Ops: Conv2d (1×1, 3×3 depthwise), custom `LayerNorm2d`, `SimpleGate` (chunk·mul), `AdaptiveAvgPool2d(1)` (SCA), `PixelShuffle`, `F.pad` to multiple of 16 `[fetch: …/basicsr/models/archs/NAFNet_arch.py]`. All trace-convertible; no attention. Risks: LayerNorm fp16 overflow on ANE; SCA's **global** pool makes output tile-dependent → use `NAFNetLocal` (TLC) at conversion. darktable-ai packages exactly this model: MIT, "RGB in [0,1]", **static 768×768**, FP32 default with `--fp16` option `[fetch: raw.githubusercontent.com/darktable-org/darktable-ai/main/models/denoise-nafnet/README.md]` | Conversion + encoding shim + worker (§5). **Recommended.** |
| NAFNet-SIDD-width64 | same | ≈67.9 M / 63 GMACs `[knowledge]`; ≈136 MB fp16; config `width 64, enc [2,2,4,8], mid 12, dec [2,2,2,2]` `[fetch: options/test/SIDD/NAFNet-width64.yml]` | same | same | **40.30 / 0.9614** `[fetch]` | same ops; 4× the cost | Bake-off "quality" rung; likely over the 10 s budget on M1/M2 (§E.6). |
| Restormer | **MIT** (Syed Waqas Zamir 2022) `[fetch: …/Restormer/main/LICENSE.md]` — confirms docs/07 | 26.1 M / 141–155 GFLOPs @256² `[search: arxiv 2304.06346 table]`; ≈52 MB fp16 | RGB sRGB; real model trained on **SIDD train** `[fetch: github.com/swz30/Restormer]`; also Gaussian blind/σ15/25/50 | Google Drive | **40.02 / 40.03** `[search]` | MDTA transposed channel attention (L2-normalise + matmul), GDFN gating, bias-free LayerNorm, PixelUnshuffle `[knowledge]`. Traces; attention likely schedules to GPU. ~5× NAFNet-w32 per pixel. | Bench-only; +0.05 dB over w32 is not worth 5× time. |
| SCUNet | **Apache-2.0** (Kai Zhang) `[fetch: …/SCUNet/main/LICENSE]` | ≈17.9 M `[knowledge]` | RGB sRGB; **synthetic** practical degradation (Gaussian, Poisson, speckle, JPEG, camera-sensor ISP, shuffled); SIDD/DND pairs *not* used `[fetch: SCUNet README]` `[search]` | `main_download_pretrained_models.py` (`scunet_color_real_psnr`, `_gan`, gray/color 15/25/50) | No SIDD number published (blind) | Swin-Conv blocks = window attention (roll/shift, relative-position bias) → ANE falls back to GPU `[docs/17 B.2]` `[knowledge]` | Bench-only: the best "blind on a phone JPEG/scan" generalist, but the worst scheduler. |
| **DRUNet (DPIR)** | **MIT** (Kai Zhang 2020) `[fetch: …/DPIR/master/LICENSE]` | ≈32.6 M `[knowledge]`; ≈65 MB fp16 | RGB + **noise-level map channel** (non-blind); trained Gaussian σ ∈ [0,50] `[fetch: DPIR README]` | repo `model_zoo` | CBSD68 σ30 **32.44** `[fetch]`; no real-noise weights | Pure conv/strided-conv/transposed-conv; cleanest conversion of the set `[knowledge]` | Fallback design: run it **inside Lumen's VST domain** where noise *is* ≈ unit Gaussian and the map is known (§6.2). NEW. |
| SwinIR (color DN) | Apache-2.0 `[fetch: SwinIR README]` | 11.9 M `[fetch]` | sRGB, Gaussian 15/25/50 only | Google Drive | no SIDD model `[fetch]` | window attention → GPU | Bench-only `[docs/17]`. |
| Uformer-B | **MIT** (Zhendong Wang 2022) — file is `LICENSE`, not `LICENSE.md` `[fetch: …/Uformer/main/LICENSE]` | 50.9 M / 86 GFLOPs `[search]` | sRGB SIDD | SharePoint | **39.89 / 40.04** `[search]` | LeWin window attention → GPU `[knowledge]` | Skip: below w64 at 3× params. |
| KBNet | **MIT** (LICENSE visible) `[fetch: github.com/zhangyi-3/KBNet]` | ? ; optional CUDA ext (`--no_cuda_ext`) `[fetch]` | sRGB SIDD | Baidu/OneDrive | ≈39.9 (KBNet-s) `[knowledge]`; "SOTA over NAFNet" `[search: arxiv 2303.02881]` | kernel-basis attention custom op; conversion unverified | Skip for v1; revisit if a pure-PyTorch path is confirmed. |
| MIRNet-v2 | **Academic Public License — non-commercial** ("free for use in noncommercial settings…") `[fetch: …/MIRNetv2/main/LICENSE.md]` | — | — | — | — | — | **Not free. Do not ship.** (v1 likewise `[docs/17 B.3]`.) |
| NBNet | Apache-2.0; **MegEngine** `[fetch: github.com/megvii-research/NBNet]` | ? | sRGB SIDD | Drive / GitHub release | **39.765** `[fetch]` | MegEngine → ONNX → CoreML, untested | Skip. |
| X-Restormer | MIT `[docs/17]` | — | — | — | — | — | Backbone option only `[docs/07]`. |

### E.3 Learned, raw/CFA domain

| Model | Licence | Input / noise model | Weights | Conv. | Lumen would need |
|---|---|---|---|---|---|
| PMRID | **Apache-2.0** `[fetch: github.com/MegEngine/PMRID]`; PyTorch + MegEngine weights | uint16 raw, packed Bayer, **k-Sigma** transform; trained on an **OPPO Reno 10x** phone `[fetch]`; ≈1 M params `[knowledge]` | in repo `models/` | tiny UNet, converts | Phone weights will not transfer to FF sensors; **the k-Sigma recipe is the v2 conditioning** `[docs/07 v2]`. |
| LLPackNet | **MIT** `[fetch: github.com/MohitLamba94/LLPackNet]` | raw Bayer, pack α = 8; SID Sony; "2848×4256 in 3 s on CPU" `[fetch]` | in repo (`weights`) | small | Extreme-low-light *enhancement* (amplification), Sony-only. Not a denoiser for Lumen. |
| ELD (physics noise model) | code **MIT**; but "Due to the business license, we are unable to provide the noise model as well as the calibration method" `[fetch: github.com/Vandermode/ELD]` | packed Bayer, SID-UNet `[knowledge]`; per-camera models (A7S2 and three others) | Google Drive | UNet, converts | Per-camera weights; the calibrated noise model is withheld → not reusable as a generic engine. |
| Unprocessing (Brooks/Google) | not shown on page; google-research is Apache-2.0 `[knowledge]` | packed 4-ch Bayer + variance map `shot·x + read` `[fetch: github.com/timothybrooks/unprocessing]`; TF1 | Google Drive | TF1 → ONNX → CoreML, painful | The **σ-map-conditioned Bayer UNet** pattern is exactly docs/07's v2 design; retrain rather than convert. |
| SID (Learning to See in the Dark) | **MIT** `[search: github.com/cchen156/Learning-to-See-in-the-Dark]` | Sony/Fuji raw; "pretrained model probably not work for another camera sensor" `[search]`; TF1 / Python 2.7 | Drive | painful | Not reusable. |
| darktable-ai RawNIND UtNet2 | **GPL-3.0** weights `[fetch: …/darktable-ai/main/models/rawdenoise-nind/README.md]` | 4-ch packed Bayer `[R,G1,G2,B]`, black→white normalised to [0,1]; UtNet2 4-pool UNet (H,W % 16); static **512×512** FP32 | darktable-ai releases | **"its intermediate activations overflow FP16 on Apple's ANE / GPU and produce NaN/Inf output"** — pinned to CoreML CPU `[fetch]` | Never ship (GPL). The fp16 finding is the single most important risk datum in this file. |
| Raspberry Pi `AI_denoise` | **BSD-2-Clause** `[fetch: github.com/raspberrypi/AI_denoise]` | 3 RGB + 3 Bayer models, NAFNet and UNet families, **0.2–17.7 M params**, TFLite; trained on Pi camera images; 1.3–4.7 s/MP (Bayer) on a Pi 5 | in repo | TFLite → CoreML ok | Proof that a tiny Bayer NAFNet trains and runs; weights sensor-specific. NEW. |
| DeepPRIME XD2s/XD3, Adobe AI Denoise | closed | raw-domain joint demosaic+denoise | — | — | Note only `[docs/03 §2.1]`. |

### E.4 Self-supervised (train-free-ish)

| Method | Licence | What it needs | Lumen would need |
|---|---|---|---|
| Noise2Noise (NVlabs) | **CC BY-NC 4.0 — non-commercial** `[fetch: github.com/NVlabs/noise2noise]` | pairs of independently-noisy shots | Not free; the *idea* (train on two frames of a burst) is unencumbered `[knowledge]`. |
| Noise2Void (juglab/n2v) | BSD-3-Clause `[fetch: …/juglab/n2v/main/LICENSE.txt]` | single noisy images, blind-spot training | Per-image training on a Mac is minutes, not milliseconds; not a slider. |
| Neighbor2Neighbor | BSD-3-Clause; UNet; `gauss25/gauss5_50/poisson30/poisson5_50`; `pretrained_model/` folder `[fetch: github.com/TaoHuang2018/Neighbor2Neighbor]` | single noisy images | Only worth it as a **training recipe for v2** on the owner's own raw captures (no clean stacks needed). |

### E.5 Encoding: where each candidate would splice

Stage order `[docs/14 §2]`: S1 decode → **S2 AI splice** (disk artifact, 32 px halo, fixed 512–1024
tiles fp16) → **S3 classical** (24 px halo) → S4 capture sharpen → …

| Domain | Splice | Resolution | Classical engine still does |
|---|---|---|---|
| RGB sRGB-trained (NAFNet/Restormer/SCUNet) | S2, on the S1 checkpoint (linear Rec.2020, WB applied — WB is in the fingerprint `[docs/07 §3]`), through an **encoding shim** per tile: exposure-anchor so scene mid-grey → 0.18, sRGB OETF, clip to [0,1]; run; inverse OETF; pixels that were > 1.0 pre-clip take the input back (highlights are not noisy). | Full res, 768² tiles, 32 px apron (`TilePlan` S2 default) | **Hot pixels move ahead of S2** (SIDD nets were not trained on stuck pixels and will smear them); S3 Colour + Colour Smoothness as a finishing pass at reduced ISO default; Luminance default drops (the σ Tier 1 sees is post-net, so `NoiseProfile` must be re-estimated on the artifact, not read from ISO). |
| RGB Gaussian non-blind (DRUNet) | S2, **inside the VST**: `VST.forward` → σ ≈ 1 everywhere → map channel = 1 → net → `VST.inverse`. No sRGB shim; the profile Lumen already measures is the conditioning. | same | same as above; S3 becomes optional. |
| Raw/CFA (v2) | pre-demosaic via `RawSource` `[docs/07 v2]` — `CIRAWFilter` never exposes the mosaic, so this needs the LibRaw side-decode. | half-res 4-plane, tiles aligned to the 2×2 period | hot pixels in CFA domain; chroma pass in S3. |

### E.6 Cost on Apple silicon — 12–45 MP `[derived]`

Inputs: 45 MP (8192×5464) with 768 px tiles / 32 px apron → 704 px valid → **12 × 8 = 96 tiles**;
12 MP → ≈ 28 tiles. ANE nominal fp16: M1 ≈ 11, M2 ≈ 15.8, M3 ≈ 18, M4 ≈ 38 TOPS `[knowledge]`.
Measured anchors: LR 15.4 ANE ≈ 5 s / 45 MP on M4 Max `[docs/02 §2.15]`; DeepPRIME ≈ 5–10 s, XD
≈ 10–25 s / 45 MP `[docs/03 §2.1]`; a UNet-class astro denoiser via `coremltools` mlprogram on
an **M4 Air: 3600×2700 (9.7 MP) 314 s CPU-ORT → 46 s CoreML `.all`** ≈ 4.7 s/MP `[fetch:
github.com/Steffenhir/GraXpert/issues/252]` — the cautionary data point: "CoreML" does not mean
ANE-fast; darktable 5.6 says "GPU a few seconds, CPU tens of seconds" `[search: darktable 5.6]`.

| Model | MACs per 768² tile | 45 MP total | Ideal ANE (M2) | Realistic (3–5× overhead) | ms/MP (realistic) | Verdict vs ≤ 10 s |
|---|---|---|---|---|---|---|
| NAFNet-w32 | 16 G × 9 = 144 G | 13.8 TMAC | ≈ 1.7 s | **3–10 s** | 70–220 | Meets on M2+ ANE; marginal on M1; GPU fallback 5–15 s |
| NAFNet-w64 | 567 G | 54 TMAC | ≈ 7 s | 12–40 s | 270–900 | Fails except M3 Max/M4 |
| Restormer | ≈ 650 G (141 G × ~4.6, attention scales with HW·C²) | ≈ 62 TMAC | ≈ 8 s, but GPU-bound | 30–90 s | 700–2000 | Fails |
| SCUNet | ≈ 4× w32 `[knowledge, low confidence]`; window attention → GPU | — | — | 15–40 s | 350–900 | Fails |
| DRUNet | ≈ 2.5× w32 `[knowledge]` | ≈ 35 TMAC | ≈ 4 s | 8–25 s | 180–550 | Marginal |
| Classical S3 (Metal) | — | — | — | ≤ 200 ms full-res refine `[docs/07 budgets]` | ≈ 4 | — |

Memory: 768² × 4 ch × fp16 = 4.7 MB per tile; NAFNet-w32 ≈ 100 MB resident; atlas ≈ 360 MB /
45 MP `[docs/07 §3]`. Download: **≈ 35 MB** (w32 fp16 mlmodelc, zipped) — ≈ 70 MB if the fp32
GPU fallback must ship as a second package.

### E.7 Sharpening
Not in scope for this dossier beyond placement: S4 capture sharpen must see the artifact
(deconvolution amplifies whatever noise survives S2/S3) `[docs/14 §2.1.2]`. Lumen today: `.ai`
still rides `CIRAWFilter.sharpnessAmount` `[repo: AppleRawSource.swift:318]`.

---

## F. Masks
Only the local-NR touchpoint: docs/07 gives masks a single `Noise` 0–100 (local Tier-1 strength)
and makes the AI Amount "spatially maskable". `AIDenoiseSplice.blend` is a per-pixel scalar mix,
so a per-mask Amount is `blend` with a mask-weighted `t` — no engine work beyond passing the α
plane. `[repo: DenoiseEngine.swift:1358–1380]` `[docs/07 local NR]`

## G. UI/UX
Not applicable beyond: the "AI (stand-in)" segment label and the `aiAmountHelp` text must be
replaced the moment a model ships; a progress row + cancel + "artifact stale" badge exist in
spec, not in code `[repo: DetailPanel.swift:388, 509–530]` `[docs/07 §3 "How it feels"]`.

## H. Viewer & scopes
Not applicable (progressive tile composite is a viewer contract owned by docs/14 §6.2).

## I. Pipeline & performance
See E.5–E.6. Existing: `TilePlan` (fixed extents, valid-region tiling, 768/32 S2 default),
`stitch`, artifact key/path, export halo table (S2 = 32 px). Missing: the worker actor, the
CoreML session, the encoding shim, viewport-first tile ordering, cancel.
`[repo: DenoiseEngine.swift:1497–1650]` `[docs/14 §6.1, §6.3]`

## J. Library / culling / export / ingest
Export must reuse the artifact and, if it was evicted, **recompute it synchronously with the
same 768/32 plan** before the classical tiler runs; ISO-adaptive auto-queue rule is in spec only.
`[docs/14 §6.3]` `[docs/07 ISO-adaptive defaults, batch queue]`

## K. Crop / lens / geometry
Not applicable.

## L. State / undo
Artifact invalidation on upstream-fingerprint change with toggle-stays-on + badge + recompute
offer is spec `[docs/07 §3 caching]`; `ArtifactKey.prefixHash` is the hook `[repo: DenoiseEngine.swift:1414–1475]`.

## M. Recipe / serialization / sidecars
`Denoise { mode, amount, classic: ClassicNR(luma, chroma, hotPixels) }` is the whole wire format;
no `modelID` on the recipe (it lives on the artifact row, which is right: swapping the active
model invalidates the artifact, not the recipe) `[repo: Recipe.swift:1050–1095; Schema.swift:214]`.
The four LR-parity sub-sliders are still not on the wire `[repo: DenoiseEngine.swift header §12.7]`.

---

## 5. The decision

### Recommendation: **hybrid — adopt NAFNet-SIDD-width32 (MIT) as the S2 artifact for luminance *and* chroma at full resolution, with the classical engine kept for hot pixels (moved ahead of S2) and as the chroma/finishing pass (S3).**

Why this and not the others:

- It is the only candidate that is **free for commercial use, pure-conv (no attention), already
  packaged at a static 768² by another raw editor, and inside the ≤ 10 s / 45 MP budget on the
  ANE by arithmetic** (E.6). Restormer/Uformer buy ≤ 0.05 dB for 3–5× the time; SCUNet and
  SwinIR schedule to the GPU; MIRNet-v2 and Noise2Noise are non-commercial; every raw-domain
  option is sensor-specific or GPL.
- It is *not* clearly better than the classical engine **on the measured pair as it exists**
  (128 px synthetic Gaussian noise, no chroma). It will be clearly better on real ISO 6400+
  frames — that is what SIDD-class nets do (≈ 40 dB vs ≈ 35–37 dB for wavelet/NLM on SIDD
  `[knowledge]`) — so the gate has to grow a fixture that can show it (step 4). If it does not
  clear that fixture, the fallback is §6.2, then the classical improvements in §6.3.
- "Hybrid" is forced by the domain mismatch: SIDD is phone noise at ISO ≤ 3200 in sRGB; a
  full-frame ISO 12800 file has coarser, more chroma-heavy noise than the net ever saw. The
  classical chroma pass catches what the net under-treats, and hot pixels are not in SIDD at all.

### Integration steps, in order

1. **Conversion (offline, Python, one-off).** Load `NAFNet-SIDD-width32.pth` into `NAFNetLocal`
   (TLC — replaces SCA's global pool with a local one so a 768 tile behaves like the 256 training
   crop; `base_size` = training crop) → `torch.jit.trace` on `(1,3,768,768)` fp32 in [0,1] →
   `ct.convert(convert_to="mlprogram", compute_precision=FLOAT16, minimum_deployment_target=macOS15)`
   → **validate**: 20 SIDD-val crops, CoreML-vs-PyTorch PSNR ≥ 50 dB, zero NaN/Inf on
   `.all` *and* `.cpuAndGPU`; if the ANE run NaNs (the RawNIND precedent), re-convert with
   per-op fp32 on `LayerNorm2d` via `ct.transform.FP16ComputePrecision(op_selector=…)`
   `[knowledge]` and re-measure. Record ms/tile on the owner's Mac. Compile to `.mlmodelc`, zip,
   SHA-256. `[fetch: NAFNet_arch.py; darktable-ai denoise-nafnet README]` `[search: coremltools compute_precision]`
2. **Bundle / download.** New `ModelStore` (LumenPipeline) mirroring `AppUpdater`: a
   `models.json` manifest on a GitHub release (`id: nafnet-sidd-w32`, `version`, `url`, `sha256`,
   `bytes`, `tile: 768`, `apron: 32`, `encoding: srgb-anchored`) → download to Application
   Support/Lumen/models/<id>-<version>/ → **SHA-256 verify (CryptoKit)** — AppUpdater's size +
   codesign check is not enough for a model — → `MLModel(contentsOf:configuration:)`,
   `computeUnits = .all`, fallback `.cpuAndGPU` on NaN. Mirror the weights from Google Drive into
   the release; that is the delivery risk on the model side. `[repo: AppUpdater.swift:109–224]`
3. **`AIDenoiseSplice` wiring.** `AIDenoiseWorker` actor (pattern: `VisionMatteWorker`) : S1
   checkpoint → classical hot-pixel pass → `TilePlan(width:height:tile:768, overlap:32)` →
   per tile: encoding shim (E.5) → `MLTensor`/`MLMultiArray` → predict → inverse shim →
   `TilePlan.stitch` → fp16 atlas at `ArtifactKey.payloadPath` with `modelID`/`modelVersion` →
   catalog artifact row. `RenderGraph` S2: `AIDenoiseSplice.blend(original:denoised:amount:)`.
   `AppleRawSource` hands CIRAWFilter **zero** NR in `.ai` once an artifact exists; `appleStandIn`
   survives only as the pre-artifact fallback and loses the "(stand-in)" label. Tiles ordered
   viewport-first; cancel token per photo. `[repo: DenoiseEngine.swift:1350–1650; VisionMattes.swift:35]`
4. **Quality gate (`DenoiseQualityTests` grows; macOS-only lane for the CoreML half).**
   (a) Fixture: `ProofFrames.noisyISO6400(width: 768, height: 768)` + a `noisyChromaEdge` at 768 —
   the generator is parametric, so this is one call. (b) Bars: AI residual < **0.85×** the best
   point on the classical travel; fine-band correlation ≥ the classical value at Luminance 50;
   chroma edge retention > 0.90; Amount 0 bit-identical to input; no NaN on either compute
   path; a `PERFPROBE`-style line with ms/tile. (c) **One real pair**: a 768² crop from an
   ISO 6400 tripod frame vs the mean of its 16-frame stack, stored as fp16 test assets — the bar
   that actually decides "better than classical" (the synthetic frame cannot, §0). Mark the
   feature PARTIAL until (c) is captured.
5. **Export path.** `docs/14 §6.3`: export reuses the artifact; if evicted, recompute with the
   identical 768/32 plan before the 2048 px classical tiler; declared S2 halo stays 32 px; never
   upsample a working-res artifact. Add an export golden: export-vs-viewer artifact bytes equal.

### What it costs

| Item | Number | Basis |
|---|---|---|
| Download | ≈ 35 MB fp16 (≈ 70 MB with an fp32 GPU package) | 17.1 M params × 2 B `[derived]` |
| Time, 45 MP | 3–10 s ANE (M2+), 5–15 s GPU; 12 MP ≈ 1–3 s | E.6 `[derived]` |
| ms/MP | 70–220 | E.6 |
| Resident | ≈ 100 MB model + 4.7 MB/tile; atlas ≈ 360 MB/45 MP | `[docs/07]` `[derived]` |
| Licence obligations | MIT notice (megvii-model 2022) + Apache-2.0 notice (BasicSR) in the app's acknowledgements; no copyleft; weights' training set (SIDD) is research-terms — same "open weights on research data" posture already accepted for SAM/SA-1B `[docs/17 B.1]` | `[fetch: NAFNet LICENSE]` |

### Risk — what makes it fail on a Mac we cannot test on

1. **fp16 overflow on the ANE → NaN tiles.** Documented for a sibling UNet on exactly this stack
   (`[fetch: darktable-ai rawdenoise-nind README]`). Mitigation: NaN sentinel per tile → retry
   that tile on `.cpuAndGPU` → if repeated, pin the session to GPU and log the chip; the
   per-op fp32 LayerNorm re-conversion in step 1.
2. **Silent scheduling to GPU/CPU** (the GraXpert 46 s/9.7 MP case). Mitigation: the ms/tile
   probe runs on first use and the queue reports "ANE / GPU / CPU" in the popover; budget
   failure downgrades to "background only, never auto-queued".
3. **Tile seams** from SCA's global statistic — TLC in step 1; the 32 px apron with exact
   halo-crop is bit-stable only if the receptive field ≤ 32 px, which for a 4-level UNet it is
   *not* (the coarsest level sees ~256 px). Accept a small non-bit-stable seam or raise the
   apron to 64 px (cost +18 % tiles) — measure on the 768 fixture.
4. **Domain shift** (sRGB phone noise → linear full-frame ISO 12800). The encoding shim's
   exposure anchor is a free parameter; the bake-off must sweep it. This is the hybrid's whole
   reason to exist — S3 chroma catches the residue.
5. **Weights hosting** — Drive links rot; mirror on day one.
6. **Memory on 8 GB machines** — trivial at 768 tiles; the atlas is purgeable `[docs/07]`.

## 6. If NAFNet does not clear the gate

### 6.1 Order of fallbacks
NAFNet-w64 on GPU (quality rung, over budget) → **6.2** → **6.3**.

### 6.2 DRUNet inside the VST (MIT, non-blind) — the design that fits Lumen's engine best
Lumen already computes `VST.forward`, after which noise is ≈ N(0,1) — DRUNet's training regime
with σ-map = 1. Splice: `VST` → tile → DRUNet(fp16, map = 1) → `VST.inverse` (exact unbiased).
No sRGB shim, no phone-noise mismatch, ≈ 65 MB, pure conv. Unverified anywhere; it is a
bake-off contender, not a bet. NEW.

### 6.3 Classical improvements (what specifically), from darktable's verified parameter set
1. Extended VST `V = a·(x+b)^p` with `shadows` (0–1.8, def 1) and `bias` — the deep-shadow fix.
2. WB-adaptive Y0U0V0 matrix (`wb_adaptive_anscombe`).
3. 7 bands (Lumen: 5) with per-band luma/chroma curves; expose Luminance Detail/Contrast on the
   wire (§12.7).
4. An NLM luma option (`radius 1, nbhood 7, central_pixel_weight 0.1, scattering 0`) for the
   "fine texture" case where wavelets worm.
5. Hot-pixel pass ahead of everything; re-estimate `NoiseProfile` from the actual S2 output when
   Tier 2 is on.

---

## New relative to docs/02–03 (and 07/17)
- Every licence in E.2–E.4 re-verified from the LICENSE file this pass, including the ones the
  repo carried by name only: **Uformer MIT, KBNet MIT, DPIR/DRUNet MIT, PMRID Apache-2.0,
  LLPackNet MIT, ELD MIT, NBNet Apache-2.0, Neighbor2Neighbor BSD-3, Noise2Void BSD-3**;
  and the two that are **not free**: MIRNet-v2 (Academic Public License), Noise2Noise (CC BY-NC).
- NAFNet's exact op list and the multiple-of-16 padding rule; the width-64 topology; that
  darktable-ai ships NAFNet-w32 **MIT at a static 768²** (matches `TilePlan`'s S2 default).
- The RawNIND UtNet2 **fp16 NaN on ANE/GPU** finding — concrete evidence for docs/07's warning.
- A measured CoreML data point for a UNet denoiser on an M4 Air (46 s / 9.7 MP).
- darktable `denoiseprofile.c` parameter struct with defaults/ranges and the v2 exponent-p VST.
- GALOSH (Jul 2026): training-free, strong on RawNIND — **patent pending**, so a landmine.
- Raspberry Pi `AI_denoise`: BSD-2 tiny Bayer NAFNets exist and run.
- The ground-truth pair cannot adjudicate a learned model as it stands (128 px, no chroma,
  engine-shaped noise); the fixture change is one parametric call.
- DRUNet-in-VST as the engine-native fallback.

## Could not verify
- NAFNet parameter counts / MACs (17.1 M/16 G, 67.9 M/63 G) — paper PDF hosts (arxiv, ecva)
  blocked; `[knowledge]`.
- SCUNet (≈17.9 M) and DRUNet (≈32.6 M) parameter counts; KBNet SIDD number; NAFNet DND number.
- Any Apple-silicon timing for NAFNet specifically — E.6 is arithmetic plus two anchors.
- Whether coremltools per-op precision on `LayerNorm2d` is enough to keep the ANE path NaN-free.
- Unprocessing's licence (page did not surface a LICENSE); ELD's camera list beyond A7S2.
- darktable 5.6 per-model timings on Apple silicon (darktable.org and docs.darktable.org blocked).
- GALOSH code licence (arxiv blocked; no repository surfaced in search).
