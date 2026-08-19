# 04 — Denoise

Flagship feature #1. Goal: match or beat Lightroom AI Denoise *as experienced* — quality on our real high-ISO files, seconds not minutes, non-destructive, no duplicate-DNG litter.

## How the incumbents work (research summary)

- **Lightroom AI Denoise** (Adobe's own writeup, Eric Chan "Denoise Demystified"): a CNN that does **denoise + demosaic jointly on the raw mosaic**, before demosaic artifacts get baked in. Originally output a Linear DNG copy; since LrC 14.4 stored non-destructively in the catalog. DxO DeepPRIME is the same idea. Raw-domain input is the quality edge.
- **darktable "denoise (profiled)"**: the best classical design. Per-camera/ISO **noise profiles** (Poisson-Gaussian: variance = a·signal + b) → variance-stabilizing transform (generalized Anscombe) so noise becomes uniform → non-local means or **edge-aware wavelet shrinkage** (in Y0U0V0 space: aggressive on chroma, gentle on luma) → invert transform. Profiles for hundreds of cameras live in darktable's GPL `noiseprofiles.json`, with a documented self-measurement procedure.
- **darktable 5.6 (June 2026)** added an ONNX-runtime AI subsystem with an open model zoo (`darktable-ai`): RGB denoisers (U-Net trained on NIND, GPL; NAFNet-small on SIDD, MIT) and a **raw-domain UtNet2** taking 4-channel packed Bayer — with static 512–768px tile shapes baked into the models. Ansel takes a different path: a tiny CFA-agnostic U-Net conditioned on a per-pixel σ map from the camera noise profile, trained purely on synthetic Poisson-Gaussian noise (new camera ⇒ just needs a noise profile, no retraining).

## Lumen's two-tier strategy

### Tier 1 — Classical, always-live (pipeline stage, real-time)

Runs as a normal GPU stage; sliders respond instantly.

- **Chroma NR**: wavelet (à-trous) shrinkage on the chroma channels of a luma/chroma decomposition — heavy smoothing here is nearly free of perceived detail loss. Default on at a mild level for high ISO.
- **Luma NR**: edge-aware wavelet shrinkage with per-scale strength; optional NLM pass for the highest-quality setting (patch 5–7, search ~21, GPU).
- **Profiled**: adopt the Poisson-Gaussian VST approach. Bootstrap: since we run *after* Apple's RAW stage, estimate the noise model per (camera, ISO) from flat regions on first encounter and cache it; darktable's profile DB is GPL — we can read its *numbers* for our own cameras manually as calibration reference, or measure our own from defocused test shots per darktable's documented procedure.
- Milestone 1 stopgap: `CIRAWFilter`'s built-in luminance/color NR sliders until this stage exists.

### Tier 2 — AI denoise, explicit cached step (seconds, not per-slider)

- **v1 model: RGB-domain** on the linear scene-referred output of the RAW stage (stage-2 splice point in 03). Candidates, all license-safe and ONNX-available → converted to Core ML with coremltools: **NAFNet** (MIT, simple arch, fast, darktable uses NAFNet-small), **SCUNet** (Apache-2.0, best blind-real-noise generalist), and the **NIND-trained U-Net** (GPL — fine for a personal/GPL project; trained on real camera noise rather than smartphone data, which matters). Bake-off on our own ISO 3200–12800 files decides the default; strength slider = linear blend with the noisy input (darktable's approach).
- **Execution**: Core ML (ANE/GPU). **Tiled inference** is mandatory at 45MP: 512–768px tiles, 32–64px overlap, feathered (Hann) blending on accumulation — or exact halo-crop when tile halo ≥ the network's receptive field. Tile size scales with available memory; fp16 where the model tolerates it (darktable hit fp16 overflow on ANE with its Bayer model — validate per model).
- **Non-destructive caching**: the result is a **cached artifact**, not a file the user manages. Keyed by (photo, fingerprint of upstream RAW-stage params that affect input pixels — WB shifts materially change denoiser input). Stored as 16-bit half-float tile atlas in the preview cache; invalidated + offered for re-run when upstream params change. This is precisely the LrC-14.4 model, minus Adobe's earlier DNG-copy mess — our headline UX win.
- **v2 ambition: raw-domain**. `CIRAWFilter` never exposes the mosaic, so this requires the LibRaw side-decode (`LumenRawSource` escape hatch in 03) used *just for the denoise path*: pack Bayer to 4 half-res planes (tiles aligned to the 2×2 CFA period), run a UtNet2/Ansel/PMRID-style small U-Net — ideally σ-map-conditioned (PMRID's k-Sigma insight: normalize by sensor noise params so one small net handles all ISOs) — then hand the denoised mosaic to our own demosaic. This is real Lightroom-AI-Denoise architecture and only makes sense once the custom RAW source exists. Explicitly out of v1.

## Bake-off protocol (before choosing the default model)

Fixed set of 12 of our own frames (ISO 1600→25600, low light + night sky + indoor people). For each: Tier-1 best effort, each Tier-2 candidate, and our archived LR AI Denoise exports as reference. Blind A/B at 100% + full-frame. Score detail retention, chroma blotches, texture worms, and wall-clock time on our Mac. Winner ships as default; results recorded in this doc.

## License landmines (recorded so we never trip them)

Non-commercial / restricted — do not ship: MIRNet (academic-only), Tampere BM3D reference code, RMBG-1.4/2.0 (BRIA), EdgeSAM (S-Lab), Depth Anything V2 Base/Large (CC-BY-NC). Safe: NAFNet (MIT), SCUNet (Apache), Restormer (MIT), SAM 2.1 (Apache), BiRefNet (MIT), MODNet (Apache), u2net (Apache), Depth Anything V2 **Small** (Apache), darktable-ai conversions (GPL-compatible).
