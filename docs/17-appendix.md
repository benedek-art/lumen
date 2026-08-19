# 17 — Appendix: Ledgers, Model Zoo, Versions, Sources

The plan's bookkeeping lives here: every library and model named anywhere in docs 00–16 with its license and
a ship verdict; the model zoo; the competitor version snapshot the comparisons were written against; the
verification queue for future sessions; and the bibliography. If a dependency is not in this ledger, it does
not enter the build until it is.

Verification labels: **verified** = license/fact confirmed by direct fetch of the primary source (LICENSE
file, official docs, tagged release) during the Aug 2026 research sweep; **(unverified)** = carried from
prior knowledge or a blocked source — usable for planning, must be re-checked before the dependency ships.

## A. License ledger

### A.1 Ship list — libraries and frameworks

| Component | License | Verified | Verdict | Notes |
|---|---|---|---|---|
| Apple frameworks (Core Image, Metal, Vision, Core ML, ImageIO, ColorSync, AppKit/SwiftUI) | OS-provided | verified (platform) | **Ship** | The default answer for decode, encode (JPEG/HEIF/TIFF), segmentation, color management |
| GRDB.swift | MIT (unverified this sweep) | — | **Ship** | Catalog layer (docs/15-catalog.md); confirm LICENSE at integration |
| LibRaw | LGPL-2.1 **or CDDL-1.0**, user's choice | verified | **Ship (choose CDDL)** | File-level copyleft is the friendlier option for a closed app; `RawSource` escape hatch (D50) |
| libultrahdr | permissive; fetch reported dual MIT/Apache, exact wording (unverified) | partial | **Ship** | Ultra HDR JPEG authoring (D42); v2.0.0 (Aug 2026) adds HEIF/AVIF ISO 21496-1; pin exact license text before ship |
| coremltools | BSD-3 (unverified) | — | **Ship (dev tooling)** | Conversion toolchain only; nothing of it ships in the app |
| lcms2 | MIT — **but bundled fast_float plugin is GPL-3.0** | carried from v1 sweep | **Ship core only** | Likely unneeded (ColorSync covers us); if used, build without the GPL plugin |
| ACES 2.0 (ampas/aces: core/output/input/look/amf) | Apache-2.0 | verified | **Ship (math + reference)** | JMh tonescale/gamut-compression architecture informs the "Accurate" intent (D8, docs/14-pipeline.md) |
| Khronos ToneMapping (PBR Neutral) | Apache-2.0 | verified | **Ship-eligible** | Candidate "True Color" rendering intent; cheap to add |
| OpenColorIO | BSD-3 (unverified; ASWF standard) | — | Reference | Not a runtime dependency; its ACES-2 configs are a validation oracle for our transforms |
| libjxl | BSD | carried from v1 sweep | Reference | JXL export is not planned; revisit if the format lands in Apple ImageIO |
| mozjpeg / jpegli, libavif, libvips, fast_image_resize | various permissive/LGPL | carried from v1 sweep | Reference | Superseded by Apple ImageIO for our formats; keep on the shelf for quality-per-byte experiments |
| exiftool (subprocess) | Perl Artistic/GPL dual (unverified) | — | **Verify before bundling** | Subprocess use avoids linking questions; *distributing* it with the app needs a license read |
| exiv2 | GPL-2 (unverified) | — | **Do not link** | Read metadata via ImageIO; write via own XMP code (docs/15-catalog.md) |
| rawspeed | LGPL (unverified) | — | Avoid | LibRaw/CDDL covers the escape hatch |
| rawler (Rust) | LGPL, alpha API | carried from v1 sweep | Reference | Powers RapidRAW; wrong stack for us |
| ONNX Runtime | MIT (unverified) | — | Reference | Core ML is our runtime; ORT only relevant off-Apple, which is out of scope |
| spandrel / chaiNNer | MIT / GPL | carried from v1 sweep | Dev tools only | Model evaluation during bake-offs; using a GPL *app* is fine, copying its code is not |

### A.2 Reference-only — the GPL/AGPL shelf and the clean-room policy

**Policy.** GPL/AGPL sources are read for *behavior*: parameter ranges, defaults, pipeline placement,
documented math. Lumen re-implements from published papers and re-derived math. No code is copied, ported,
or translated. Digest-verified constants (a slider's range and default, a curve's published equation, a
measured physical fact) are facts, not copyrightable expression, and are used freely with attribution in
the specs. Where a GPL implementation is the *only* documentation of an algorithm (e.g. darktable UCS 22),
the reimplementation works from the described model and the underlying color-science literature, and the
implementing session records what it read.

| Source | License | Status | What we take (behavior only) |
|---|---|---|---|
| darktable (sigmoid.c, colorbalancergb.c, UCS 22 helpers, locallaplacian.c, hazeremoval.c, tone equalizer, diffuse.c, AI subsystem docs) | GPL-3.0 | verified repo | Parameterizations and defaults across docs 04–08; the task/model registry pattern; the four-tone-mapper cautionary tale |
| RawTherapee (capturesharpening.cc, demosaic lineage) | GPL-3.0 | verified repo | RL-deconvolution capture sharpening with auto-σ from Bayer greens (D24); RL deconvolution itself is textbook (1972/1974) |
| ART | GPL-3.0 | verified repo | Mask-layer algebra, ΔE value+weight slider pairing, 5-band tone EQ simplification |
| Ansel | GPL-3.0 | verified repo | Cache discipline: prefix caching, downstream-only recompute, export cache reuse (D49); its docs are the best free writing on scene-referred math |
| vkdt | core BSD-2/GPL dual (per-file; carried from v1 sweep) | — | Permissive-core files *may* be reusable — verify per file before any copy; jddcnn architecture as design reference |
| RapidRAW | AGPL-3.0 | verified repo | Architecture decisions and scope lessons only; AGPL means never copy, and its "Spektrafilm" film code is inside the AGPL boundary |
| spektrafilm (film emulation) | GPLv3 | per D18 | **Reference-only.** Film Lab is clean-roomed from Giorgianni & Madden / Hunt; verified physical constants from digest r10 are usable as facts |
| AnyLabeling | GPL-3.0 | carried from v1 sweep | The SAM click-prompt loop UX (encode once, decode per click) — pattern, not code |
| darktable noiseprofiles.json | GPL (data) | carried from v1 sweep | Do not bundle. Use its *documented self-measurement procedure* to build Lumen's own per-camera Poisson-Gaussian profiles (docs/07-spec-denoise.md) |
| AgX configs (sobotka/AgX, EaryChow/AgX) | **license not surfaced — (unverified)** | fetch attempted | Re-derive the math (log2 encoding, inset/rotation idea are published concepts); do **not** copy matrices verbatim until LICENSE files are checked |

### A.3 Never list

| Item | Why never |
|---|---|
| lcms2 fast_float plugin | GPL-3.0 inside an otherwise-MIT library |
| Any darktable/RT/ART/Ansel code, ported or translated | GPL-3.0; clean-room only |
| Any RapidRAW code | AGPL-3.0 |
| Tampere BM3D reference code | Research license |
| PPR10K, FiveK as training data for shipped models | PPR10K explicitly non-commercial (verified); FiveK terms (unverified) — both are benchmark/prototyping only (D11) |

## B. Model zoo

One active model per task, swappable (darktable 5.6's registry pattern, adopted in docs/13-architecture.md).
Three-layer rule before any model ships: code license, weights license, training-data provenance — all three
checked, or the model stays in the lab.

### B.1 Ship candidates

| Task | Model | Size | License | Verified | Role |
|---|---|---|---|---|---|
| Interactive masking | **SAM 2.1 Small** (fallback Tiny) | 46M / 38.9M params | Apache-2.0 | verified | Click/box-to-select with cached encoder embeddings (docs/08-spec-masking.md); weights Apache, trained on research-only SA-1B ("open weights" — accepted) |
| Hover/instant masking | MobileSAM | 9.66M params | Apache-2.0 | verified | Cheap always-on hover-highlight candidate |
| Subject matte (hair-grade) | **BiRefNet** (HR / dynamic-res variants) | ~221M class; ~3.5 GB fp16 inference | MIT | verified | Quality ceiling for Select Subject; ~17 FPS @1024 fp16 on desktop GPU |
| Subject/sky (light) | u2net / u2netp, skyseg, InSPyReNet | 176 MB / 4.7 MB; small | Apache / MIT / MIT | carried from v1 sweep | Lightweight fallbacks and sky model |
| Portrait matting | MODNet | ~25 MB | Apache-2.0 | carried from v1 sweep | Optional portrait-matte refinement |
| Depth masks | **Depth Anything V2 Small** | ~25M params | Apache-2.0 | verified | Depth-range masks for every photo (D28); Small ONLY — Base/Large are CC-BY-NC |
| Denoise (v1, RGB) | **NAFNet** / SCUNet / Restormer / X-Restormer | ~100–300 MB class resident | MIT / Apache-2.0 / MIT / MIT | verified (all four LICENSE files) | Phase 5 bake-off pool (docs/07-spec-denoise.md); Restormer is MIT — commonly misremembered as research-only |
| Denoise (v2, raw) | Own Bayer U-Net (NAFNet-width32-class), σ-map/ISO-conditioned | ~30M-params class | own weights | — | Trained on SIDD + own captures; the DxO/Adobe architecture via `RawSource` (D26); NIND/RawNIND dataset licenses (unverified) — check before training on them |
| Inpaint (heal fill) | **MI-GAN** | ~5–7M params | MIT | verified | Best license/size fit for on-device removal (D33) |
| Inpaint (large hole) | LaMa (retrained) | — | code Apache-2.0 (verified, Samsung); **Big-LaMa weights provenance (unverified)** | partial | Ship only with retrained or cleared weights |
| Upscale (2× fidelity) | PLKSR or DAT-light | DAT-light 573K params / 49.7 GFLOPs | MIT / Apache-2.0 | verified | Phase 8 "Enhance"; CNN converts cleanly to Core ML/ANE |
| Upscale (4×, flagged generative) | Real-ESRGAN x4plus | RRDBNet class | BSD-3-Clause | verified | Statement upscale, run after denoise, never default on portraits |
| OS-provided (no download) | Vision: foreground/person instance masks (macOS 14/15+), `CalculateImageAestheticsScoresRequest` (15+), face landmarks, saliency; `GenerateIterativeSegmentationRequest` (macOS 27 beta); ProRAW semantic mattes via CIRAWFilter | — | OS | verified (API docs) | Zero-download default paths for subject/person/culling/skin-sky mattes |

Bench-only (never ship, useful in bake-offs): SwinIR (Apache), HAT (Apache) — quality baselines that
schedule poorly on ANE; MambaIR/v2 (Apache-2.0, CVPR 2025) — claims +0.29 dB over HAT but Core ML
conversion feasibility (unverified); DnCNN (first-experiment grade); SID "Learning to See in the Dark" (MIT).

### B.2 Deployment constraints (Core ML / ANE)

The conversion and runtime facts every model above must live with (from the Aug 2026 platform sweep;
enforcement lives in docs/13-architecture.md):

| Constraint | Value | Consequence |
|---|---|---|
| ANE precision | fp16 only; fp32 requires CPU/GPU via mlprogram `compute_precision` | Every shipped model is validated for fp16 numerical stability in the bake-off (norm layers, large activations); final compositing math stays in our own Metal shaders |
| Tile shapes | Fixed 512–768 px tiles (denoise), 512–1024 px + overlap for >16MP ML ops | No dynamic-shape models; enumerated shapes only if a second size is unavoidable |
| Conversion path | torch.jit.trace (torch.export parity was ~68% of ops at coremltools 8.1) | Trace-based conversion is the default; exotic ops (window attention, Mamba scans) disqualify a model regardless of benchmark wins |
| Scheduling | Window-attention transformers (SwinIR/HAT) fall back from ANE to GPU | CNN-style models (PLKSR, NAFNet-class, MI-GAN) are preferred at equal quality |
| Memory | BiRefNet ~3.5 GB fp16 inference; NAFNet-class ~100–300 MB resident; 61MP RGBA fp16 buffer ≈ 482 MB | Heavy models load on demand and unload after the queue drains; min-spec 16 GB M-series with tiling, comfortable at 32 GB |
| Future path | Metal 4 `MTL4MachineLearningCommandEncoder` (macOS 26+): whole networks inside the command stream via `metal-package-builder` | Planned migration for in-graph inference (per-tile denoise inside the render graph), not a v1 dependency (D51) |

### B.3 Restricted — never ship

| Model | License problem |
|---|---|
| MIRNet | Academic/research license |
| EdgeSAM | S-Lab non-commercial |
| RMBG-1.4 / 2.0 | BRIA proprietary terms |
| Depth Anything V2 **Base / Large** | CC-BY-NC (Small is Apache — the only shippable size) |
| MAT (inpainting) | README: "research purposes only" |
| SUPIR / diffusion restorers | Too slow for RAW workflows; licenses (unverified); hallucination-prone |
| darktable-ai model packages (incl. RawNIND UtNet2 conversions) | GPL-adjacent packaging; retrain/convert from original sources instead |

## C. Version snapshot — the field as compared (Aug 2026)

Every "Vs. the field" verdict in docs 04–12 was written against these versions. Rows marked (unverified)
could not be re-fetched in the Aug 2026 sweep and are cited in the specs at their last-verified era.

| Product | Version | Date | Status |
|---|---|---|---|
| Lightroom Classic | **15.5** | 2026 | verified. Milestones cited in specs: 14.4 (denoise becomes non-destructive, no DNG), 15.0 (Dust Removal ships; blocking mask-recompute regression), 15.2 (Feb 2026, Generative Upscale = licensed Topaz Gigapixel, cloud + credits), 15.4 (ANE denoise ~5 s/45MP on M4 Max; the pulled release) |
| Capture One | **16.8.4** | 2026 | verified |
| darktable | **5.6.0** (5.8 in dev, ~Dec 2026) | 2026-06-21 | verified. There is no darktable 6.0 |
| RawTherapee | **5.13** | 2026-07-25 | verified |
| ART | **1.26.7** | 2026-07-13 | verified (now at github.com/artraweditor/ART) |
| vkdt | **1.0.0** + nightlies | 2025-12-13 | verified |
| RapidRAW | **1.6.1** (~9.4k stars) | 2026-08-07 | verified |
| Ansel | alpha "0.0.0" nightlies | active 2026-08-19 | verified |
| macOS | 15 Sequoia (2024) → **26 Tahoe** (2025) → 27 beta (2026) | — | verified; the version number jumps 15→26 — there is no macOS 16 |
| DxO PhotoLab | 9 expected/likely Oct 2025 (unverified); specs cite **PL8-era facts** (Oct 2024) | — | flagged per D53 |
| DxO PureRAW | 5 (Apr 2025); 5.x point-release features (unverified) | — | flagged |
| DxO Nik Collection | 8 (Jun 2025, existence high-confidence; features unverified); Silver Efex facts cited at v7-era | — | flagged |
| Topaz Photo AI | 3.x (2024–25); a v4 (unverified) | — | flagged; Gigapixel 8 (late 2024) verified-era |
| Photo Mechanic | version (unverified this sweep) | — | behaviors cited from its stable, decade-old design contract |
| FastRawViewer | version (unverified this sweep) | — | raw-truth instruments cited from its stable feature set |
| Pixelmator Pro / Photomator | caretaker mode since Apple acquired the team (2024/25) | — | per D2 |
| Affinity Photo | absorbed by Canva | — | per D2 |

Toolchain and standards snapshot (verified): coremltools **9.0** (2025-11-10; ANE is fp16-only);
Metal 4 ML encoders (macOS 26+); OpenColorIO **2.5.2** (2026-05-13); ACES **v2.0.0+2025.04.04**
(Apache-2.0); libultrahdr **v2.0.0–2.0.2** (Aug 2026); SAM 2.1 checkpoints (2024-09-29); Vision
`GenerateIterativeSegmentationRequest` (macOS 27 beta); LibRaw 0.22-era (1284 cameras, carried from v1 sweep).

### C.1 Apple API availability matrix

What each relied-on API requires, and the fallback when the baseline (macOS 15) predates it. All
availabilities verified against Apple docs in the Aug 2026 sweep.

| API | Available since | Used for | Fallback on macOS 15 |
|---|---|---|---|
| `CIRAWFilter` (full property surface, `linearSpaceFilter`, ProRAW mattes, `decoderVersion`) | macOS 12 | The RAW stage (docs/14-pipeline.md) | — (baseline) |
| `CAMetalLayer.wantsExtendedDynamicRangeContent` + `NSScreen` headroom queries | macOS 10.11 / 14-era additions | EDR viewport (docs/11-spec-output.md) | — |
| `writeHEIFRepresentation(... .HDRImage:)` auto gain-map embed; `.expandToHDR`; `CIToneMapHeadroom` | macOS 15 ("Adaptive HDR") | HDR read/author (D42) | — (baseline; this is why the floor is 15, not 14) |
| `CIContext.writeHEIF10RepresentationOfImage` (PQ/HLG) | macOS 12 | 10-bit HEIF export | — |
| `VNGenerateForegroundInstanceMaskRequest` | macOS 14 | One-click subject | — |
| Swift Vision `GeneratePersonInstanceMaskRequest` / `GeneratePersonSegmentationRequest` | macOS 15 | Person masks (D28) | — |
| `CalculateImageAestheticsScoresRequest` (`overallScore`, `isUtility`) | macOS 15 | Culling assists (D37) | — |
| Core ML stateful models; 4-bit quant | macOS 15 / coremltools 8.0 | Model optimization headroom | — |
| Metal 4 `MTLTensor` + `MTL4MachineLearningCommandEncoder` + Shader ML | macOS 26 | In-graph inference migration (D51) | Core ML out-of-graph path (the v1 design) |
| `GenerateIterativeSegmentationRequest` (tap/scribble/box + include/exclude points) | macOS 27 beta | Zero-download interactive masking (D30) | SAM 2.1-small with cached embeddings (ships regardless) |

Rule restated from docs/16-roadmap.md risk #5: anything newer than macOS 15 is adopted behind availability
checks with a shipped fallback, never as a hard dependency.

## D. Verification queue

Gaps flagged across the research digests. A future session with web access should clear these top-down;
items blocking a ship decision are marked **[blocking]** with the phase they block.

**Licensing and legal**
1. **[blocking P3]** AgX config licenses: check LICENSE files in sobotka/AgX and EaryChow/AgX before any
   matrix constants are used verbatim (re-derived math is safe regardless).
2. **[blocking P7]** libultrahdr exact license text (fetch suggested dual MIT/Apache; confirm wording).
3. **[blocking P8 heal]** PatchMatch patent posture: Adobe filings ~2009–2010 suggest expiry by 2029–30 at
   the latest, possibly already passed — needs counsel, or a non-infringing NNF variant.
4. **[blocking P8 heal]** Big-LaMa weights provenance (Places365 research terms); cost of retraining on
   cleared data.
5. **[blocking P5 v2]** NIND / RawNIND / SIDD dataset licenses for training the raw-domain denoiser.
6. Weights-terms spot-check at integration: Real-ESRGAN, SwinIR, HAT, DAT, PLKSR (in-repo distribution
   assumed same-license; confirm).
7. Confirm licenses carried unverified: GRDB.swift (MIT?), exiv2 (GPL-2?), rawspeed (LGPL?), exiftool
   distribution terms, coremltools (BSD-3?), ONNX Runtime (MIT?).
8. FiveK exact terms (site was blocked; assumed research-only).
9. ISO 21496-1 final publication status/date (widely reported published 2025; iso.org unreachable).

**Competitor facts (specs cite these at last-verified era)**
10. DxO PhotoLab 9: existence, feature list (XD3 in PL? AI masking? merge features? export formats?),
    pricing — the highest-priority competitor gap (r06).
11. PureRAW 5.x current feature list and price; Nik Collection 8 features; current Topaz versioning
    (Photo AI 4? rebrand?) and 2026 model lineup + Apple Silicon timings.
12. Exact DxO slider ranges: Lens Sharpness (Global/Details/Bokeh), CA/vignetting, ColorWheel Uniformity
    range; DxO Wide Gamut primaries if ever published; whether PL7 or PL8 introduced Luminosity masks.
13. Photo Mechanic and FastRawViewer current versions (cited version-less in docs/03 and 10).
14. Current optics-module count claim; whether PL9+ added HDR/pano merge or tethering.

**Platform and technical**
15. `CalculateImageAestheticsScoresRequest` score range (not stated in docs) — needed to calibrate the
    culling strictness slider (docs/10-spec-library.md).
16. `GenerateIterativeSegmentationRequest` final API shape at macOS 27 GA; quality vs SAM 2.1-small on the
    owner's corpus.
17. MPSGraph ANE dispatch: docs claim CPU/GPU/ANE; practical behavior (unverified) — matters only if a
    hand-built graph ever needs ANE.
18. MambaIR/v2 Core ML conversion feasibility (Mamba scan ops).
19. AVIF encode availability via ImageIO on macOS 15/26 (`CGImageDestinationCopyTypeIdentifiers`);
    libavif/libaom fallback decision.
20. Metal 4 `metal-package-builder` workflow exercised on a real denoise model (planned migration, D51).
21. 2025–26 denoise SOTA sweep (search was unavailable): is there a practical successor to
    NAFNet/Restormer-class for real-photo blind denoising? Re-run before the Phase 5 bake-off freezes.
22. Throughput claims to measure, not trust: "~1–4 s per 45MP" Bayer U-Net estimate; BiRefNet fp16 memory
    on M-series; all bake-off numbers land in docs/07-spec-denoise.md.
23. `VNDetectFaceLandmarksRequest` landmark count (76-point figure is prior knowledge) — the eye-aspect-ratio
    blink detector (D37) needs the exact eye-contour points confirmed.
24. ProRAW specifics (48MP/12-bit linear DNG ceiling, Apple gain-map behavior through LibRaw) — partially
    from prior knowledge; matters for the `RawSource` path.

**Ecosystem and sentiment**
25. Browser/platform HDR support matrix: Chrome 116+ Ultra HDR, Safari 26 HDR images, Instagram HDR
    uploads (all unverified — affects docs/11-spec-output.md delivery guidance).
26. Sentiment re-checks on live forums (blocked this sweep): sigmoid-vs-AgX community equilibrium, ART
    reception, vkdt daily-driver reports, RapidRAW user complaints, "Vision instance masks soft on hair vs
    BiRefNet" reputation.
27. OKLab primary source re-fetch (bottosson.github.io was blocked; math is re-derivable from published
    matrices regardless).

## E. Bibliography

Compact by design: names and roles here; the teachings and design implications live in
docs/01-research-literature.md.

### E.1 Books (the shelf behind the design laws)

- Ansel Adams — *The Negative* (zone system: docs/04-spec-tone.md zones, D7; B&W overlay, D20)
- Bruce Fraser & Jeff Schewe — *Real World Image Sharpening* (the three-pass sharpening doctrine, D24)
- Edward Giorgianni & Thomas Madden — *Digital Color Management: Encoding Solutions* (film characteristic
  curves and density math — the Film Lab's clean-room foundation, D18)
- R.W.G. Hunt — *The Reproduction of Colour* (memory colors, appearance modeling; D17, D18)
- Alexis Van Hurkman — *Color Correction Handbook* (grading doctrine, skin-tone line, memory-color
  idealization; D15–D17)
- Martin Evening — *The Adobe Photoshop Lightroom Classic Book* and Scott Kelby — *The Lightroom Book*
  (the two registers of the same tool — the disclosure split, D3)

### E.2 Papers and specifications

- Paris, Hasinoff, Kautz — *Local Laplacian Filters* (SIGGRAPH 2011); Aubry et al. fast variant (2014) —
  halo-free local contrast (D23)
- He, Sun, Tang — *Guided Image Filtering* (ECCV 2010) — base-detail, mask feathering (D23, D30)
- He, Sun, Tang — *Single Image Haze Removal Using Dark Channel Prior* (TPAMI 2011) — dehaze (D23)
- Mertens et al. — *Exposure Fusion* (2007)
- Hasinoff et al. — *Burst photography for HDR…* (HDR+, SIGGRAPH Asia 2016); Liba et al. — Night Sight
  (2019) — merge-in-raw, tone-map-locally lessons
- Richardson (1972) / Lucy (1974) — deconvolution; RawTherapee's auto-σ application (D24)
- Barnes et al. — *PatchMatch* (SIGGRAPH 2009) — heal/clone core (D33; patent check pending, queue #3)
- Zeng et al. — *Image-Adaptive 3D LUTs* (2020) — auto-edit architecture reference (D11)
- Björn Ottosson — OKLab (2020, public-domain-style) (D21)
- Hellwig & Fairchild (2022) — CAM16 modifications underlying ACES 2.0's JMh (D8)
- Eric Chan (Adobe) — *Denoise Demystified* — raw-domain joint demosaic+denoise architecture (D26 v2)
- PMRID (ECCV 2020) — k-Sigma transform for raw denoise conditioning
- vkdt/denox — *Optimizing Vulkan dispatch schedules for real-time U-Net denoising* (2026) — in-pipeline
  inference reference
- ISO/TS 22028-5 (ISO HDR); ISO 21496-1 (gain maps); Android Ultra HDR format spec (full gain-map math,
  verified) — docs/11-spec-output.md
- Adobe DNG specification 1.6/1.7 (dual-illuminant color model)
- ACES 2.0 CTL source (`Lib.Academy.OutputTransform.ctl`) — JMh tonescale, chroma compression, gamut
  compression (verified in source)

### E.3 Primary sources — verified by direct fetch, Aug 2026 sweep

- Apple: CIRAWFilter full property surface; Adaptive HDR (WWDC24 #10177) and ISO HDR (WWDC23 #10181);
  `CAMetalLayer` EDR + `NSScreen` headroom APIs; Vision request docs incl. macOS 27 beta iterative
  segmentation; Metal 4 ML (WWDC25 #262, `MTLTensor` / ML command encoder docs); coremltools release notes
  8.0–9.0
- darktable: tagged RELEASE_NOTES 4.6–5.6 + 5.8-dev; source for sigmoid, color balance rgb, UCS 22, local
  laplacian, hazeremoval, diffuse presets; dtdocs module reference incl. the AI subsystem
- RawTherapee: tagged release notes 5.10–5.13; `capturesharpening.cc`
- ART site repo (1.26.7 reference, mask algebra); vkdt repo (1.0.0, jddcnn); RapidRAW repo (v1.6.1
  changelogs); Ansel repo (benchmarks, critique)
- ACES umbrella repo + releases; OpenColorIO tags 2.4.0–2.5.2; EaryChow/AgX config (Blender's default);
  Khronos ToneMapping
- Android Ultra HDR developer docs; google/libultrahdr releases
- LICENSE files fetched verbatim: Real-ESRGAN (BSD-3), SwinIR (Apache-2.0), HAT (Apache-2.0), DAT
  (Apache-2.0), PLKSR (MIT), MambaIR (Apache-2.0), LaMa (Apache-2.0), MI-GAN (MIT), MAT (research-only),
  SAM 2 (Apache-2.0), MobileSAM (Apache-2.0), BiRefNet (MIT), NAFNet (MIT), SCUNet (Apache-2.0), Restormer
  (MIT), X-Restormer (MIT), LibRaw (LGPL-2.1/CDDL-1.0 dual)
- PPR10K repo (non-commercial terms, dataset contents)

### E.4 Referenced from prior knowledge — primary source unreachable in the sweep

darktable manual (rendered), RawPedia, pixls.us and Reddit sentiment threads, bottosson.github.io,
Aurélien Pierre's UCS 22 article, ACESCentral, Adobe helpx (LR gain maps, Generative Upscale FAQ), iso.org,
hdrplusdata.org, dxo.com, topazlabs.com, nikcollection.dxo.com, dpreview/petapixel/photographylife
reviews, Finding the Universe and Fstoppers denoise comparisons (standings carried via digest r03),
browser/Instagram HDR announcements. Everything load-bearing from these carries an (unverified) flag at its
point of use, and the re-checks live in the queue above.
