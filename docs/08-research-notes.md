# 08 — Research Notes & Reference Shelf

Condensed output of the pre-project research sweep (Aug 2026): prior art, reusable libraries, model zoo, and the sources behind decisions in docs 02–07.

## Prior art — study list, ranked by relevance

| Project | Stack / license | Why it matters to Lumen |
|---|---|---|
| **RapidRAW** — github.com/CyberTimon/RapidRAW | Tauri + React, Rust core, whole pipeline in one wgpu/WGSL f32 shader, rawler decode, JSON sidecars, ONNX AI masks (SAM2, u2net, Depth Anything) + nind-denoise. AGPL-3.0 | The existence proof: solo dev, usable Lightroom alternative in ~6 months (2025). Closest architecture to ours; study its mask layering and AI backend split. AGPL → study, don't copy |
| **darktable** + **darktable-ai** — github.com/darktable-org | C/GTK/OpenCL, GPL-3.0; 5.6 (2026) added ONNX AI subsystem + open model zoo | Best-documented full implementation of everything: scene-referred pixelpipe, profiled denoise, parametric+drawn masks, tiling, noise profiles DB, AI model packaging (static tile shapes, EP fallback). GPL → reference, don't copy |
| **vkdt** — github.com/hanatos/vkdt | C + Vulkan GLSL compute DAG, by darktable's original author. Core BSD-2/GPL dual | The performance North Star (full-res interactive). Has `jddcnn`: joint demosaic+denoise CNN entirely in compute shaders. Permissive core = code is actually reusable |
| **Ansel** + **ansel-denoise** — github.com/aurelienpierreeng | darktable 4.0 fork, GPL-3.0, alpha | Two lessons: (a) tiny profiled raw-CFA U-Net with σ-map conditioning + synthetic Poisson-Gaussian training = no per-camera retraining; (b) cautionary tale — solo-forking a 1M-LoC GPL app means permanent alpha. Ansel's docs are the best free writing on scene-referred math |
| **RawTherapee / ART** | C++/GTK, CPU-only, GPL-3.0 | Best demosaic implementations (AMaZE/RCD/LMMSE, X-Trans); capture sharpening; `.pp3` text sidecars. ART = "RT with sane UI + masks" |
| **rembg** — github.com/danielgatis/rembg | Python, MIT | Cleanest minimal subject-mask ONNX pipeline (u2net/isnet/BiRefNet); logic directly portable |
| **AnyLabeling** (vietanhdev) | GPL-3.0 | Working interactive SAM click-prompt loop with encoder caching — the UX to replicate for object masks |
| Filmulator, PhotoFlow | GPL, dormant | Cautionary tales (author bandwidth); PhotoFlow's libvips-based demand-driven engine is an interesting idea |
| Immich / LibrePhotos / digiKam | AGPL / MIT / GPL | Library-side references only (thumbnail pipelines, ML tagging, catalog schemas) |

## Libraries & licenses (the reusable shelf)

- **RAW decode**: LibRaw (C++, **LGPL-2.1/CDDL dual** — embeddable anywhere; 1284 cameras in 0.22, ships the Adobe-derived color-matrix table) · rawspeed (darktable's, LGPL) · rawler (Rust, LGPL, alpha API; powers RapidRAW/vkdt-optional) · zenraw (imazen, new safe-Rust decoder, watch) · rawpy (MIT wrapper, for prototyping in Python).
- **Color**: lcms2 (MIT; note the bundled fast_float plugin is GPL-3.0) · Adobe DNG SDK + free DNG spec (dual-illuminant ColorMatrix1/2 + ForwardMatrix model) · dcpTool / DCamProf for DCP profile work · Apple ColorSync (our default path).
- **Encoders/resize**: mozjpeg or jpegli (best JPEG quality/byte) · libavif · libjxl (BSD) · fast_image_resize (Rust, MIT, SIMD Lanczos — must linearize before downscale) · libvips (LGPL, streaming engine behind sharp) · Apple ImageIO covers JPEG/HEIF/TIFF natively for us.
- **Metadata**: exiv2 (C++) · exiftool (subprocess, full fidelity) · Apple ImageIO/CGImageSource for read.
- **Data**: GRDB.swift (SQLite) · darktable `noiseprofiles.json` (GPL, per-camera Poisson-Gaussian noise params + documented self-measurement procedure).
- **ML tooling**: coremltools (PyTorch/ONNX → Core ML) · ONNX Runtime (`ort` Rust crate / onnxruntime-node) if ever off-Apple · spandrel (MIT, auto-loads restoration-model checkpoints) + chaiNNer (GPL GUI) for model evaluation.

## Model zoo (license-vetted)

**Safe to ship**: SAM 2.1 tiny/small (Apache, 39/46M — click-to-mask) · MobileSAM (Apache, ~10M) · EfficientSAM (Apache) · BiRefNet (MIT, 221M — best subject matte) · u2net/u2netp (Apache, 176MB/4.7MB) · MODNet (Apache, ~25MB — portrait matting) · InSPyReNet (MIT) · skyseg (MIT) / fast-skyseg · Depth Anything V2 **Small** (Apache, ~25M) · NAFNet (MIT) · SCUNet (Apache) · Restormer (MIT) · DnCNN (tiny, first-experiment grade) · SID "Learning to See in the Dark" (MIT) · darktable-ai conversions (GPL-compatible; incl. RawNIND UtNet2 raw-domain denoiser, static 512px Bayer tiles).

**Restricted — never ship**: MIRNet (academic) · EdgeSAM (S-Lab non-commercial) · RMBG-1.4/2.0 (BRIA) · Depth Anything V2 Base/Large (CC-BY-NC) · Tampere BM3D reference code. (SAM-family weights are Apache but trained on research-only SA-1B — "open weights," fine for us.)

## Facts that shaped decisions (with the decision they shaped)

- darktable's decade-long display→scene-referred migration, and why (linear-light math correctness, HDR headroom) → Lumen is scene-referred from day 1 (03).
- Sigmoid/AgX (2-slider) displaced filmic (many-slider) as darktable's recommended transform; dt 5.4 default workflow builds on AgX → our tone map is sigmoid-family (03).
- Linear Rec.2020 working space over ProPhoto (imaginary primaries → negative-energy math) → adopted (03).
- RCD demosaic: near-AMaZE quality, ~600-line reference, darktable default since 3.4 → our escape-hatch demosaic choice; Markesteijn ported for X-Trans (03).
- Highlight reconstruction "inpaint opposed" is darktable's cheap robust default → escape-hatch choice (03).
- f16's 10-bit mantissa bands in deep shadows of scene-linear data → f32 intermediates, f16 only for masks/display (03).
- Adobe's AI Denoise runs joint denoise+demosaic on the raw mosaic (Eric Chan, "Denoise Demystified"); LrC 14.4 moved results into the catalog (no more DNG copies); LrC 15 added a binary "ACR sidecar" because AI data broke pure-XMP → our v2 raw-domain ambition, our cached-artifact design, and our recipe/blob storage split (04, 06).
- darktable profiled denoise = Poisson-Gaussian VST + wavelet Y0U0V0 / NLM → our Tier-1 design (04).
- darktable 5.6 ONNX subsystem: static tile shapes (512–768px) baked into models to avoid per-shape JIT; fp16 overflow on ANE for the Bayer model → our tiling + precision validation plan (04).
- Guided filter: O(N) edge-aware, darktable uses it for mask feathering → our mask refinement core (05).
- SAM desktop pattern: encode once (~1s, cache embeddings), decode per click (<10ms) → our object-mask architecture (05).
- LR masking semantics (component stacks with add/subtract/intersect, range ∩ AI combinators) → adopted wholesale (05).
- Embedded RAW JPEG previews make culling instant before any decode (LR "embedded previews" import) → our preview cache fast path (06).
- Human-readable sidecar params (LR `crs:`) beat opaque binary blobs (darktable) for debuggability → JSON recipe, custom XMP namespace (06).
- RapidRAW timeline (usable solo v1 in ~6 months with maximal library reuse) and Ansel's permanent-alpha fork → build narrow on platform machinery, don't fork (02, 07).

## Primary sources

darktable manual (pixelpipe, denoise-profiled, masks, sigmoid/AgX) · ansel.photos resources (guided-laplacian highlights, scene-referred math) · RawPedia (demosaicing) · Adobe: "Denoise Demystified", LrC masking help, DNG spec 1.6/1.7 · darktable-ai model READMEs · libraw.org (cameras, licensing) · github: dnglab/rawler, hanatos/vkdt, CyberTimon/RapidRAW, pykeio/ort, chaiNNer-org/spandrel · Apple docs: CIRAWFilter, Vision (foreground instance masks, person segmentation), coremltools · HF: vietanhdev SAM/SAM2 ONNX exports, Xenova/modnet, JianyuanWang/skyseg, onnx-community depth-anything-v2-small · NIST exact tiled inference (PMC10914126) · PMRID (ECCV 2020, k-Sigma transform) · NIND/RawNIND datasets.
