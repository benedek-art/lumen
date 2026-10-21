# WS-19 / WS-20 / WS-21 acceptance spec (lane T4: classic NR, hot pixels, NR defaults)

One spec for the three workstreams because they share one engine (`DenoiseEngine.swift`) and
one measurement harness. Written from the audit below, before the code change.

## Measurement setup

All commands run from the repo root after `bash scripts/proof/cloud-setup.sh`,
`swift build -c release --product lumen-render` and `bash scripts/proof/fetch_corpus.sh`.
Tools live in `docs/quality/lanes/WS-19/tools/`:

- `nrtool/` – a 40-line Swift package over LumenCore: applies `ClassicalDenoise` (the shipped
  engine, `NoiseProfile.forISO`, scale 1) to an `.lfi`. Build: `swift build -c release --package-path docs/quality/lanes/WS-19/tools/nrtool`.
- `prepare.sh` – native-resolution decodes of the five high-ISO frames (2348 G9 ISO 3200,
  2062 Kiss X9 ISO 6400, 1192 X-T10 ISO 4000, 2242 GX850 ISO 2000, 4144 A7C ISO 2000) plus
  640 px crops, and three ground-truth sims: a clean low-ISO RAW (6929 A7 IV, 4694 R5,
  2545 GX85) decoded twice through the same LibRaw path, once with Poisson-Gaussian noise
  (a = 7e-4, b = 4e-6, measured to match the G9/77D at ISO 3200) injected on the mosaic.
  Plus a hot-pixel sim (4694): separate decodes with 3000 single-site hot pixels, 3000
  Gaussian stars, 3000 specular discs, all on the same noisy base.
- `measure.py` – every number below. Display transform for metrics: Rec.2020→sRGB, ×2^EV
  (per crop), clip, sRGB OETF, CIELAB D65. "Flat" = lowest-quartile 16 px blocks of the
  clean twin's fine-band energy; "texture" = top quartile. `flatL`/`flatC` = σ of the error
  after removing scales above σ 16 px (L*, and per-channel RMS of a*/b*). `texRet` = projection
  of the output's σ2 high-pass onto the clean twin's in texture blocks (1 = all real fine
  texture kept). `midRet` = same for the σ2–σ6 band. `edgeC` = a*b* error at the top 3 % of
  clean chroma-gradient pixels. Real frames (no ground truth): flat = lowest 15 % of 16 px
  blocks by smoothed-L variance; `noiseL`/`noiseC` measured there.

Sim numbers use the ISO-3200 profile; "shipped" means the engine at commit 9068ded with its
ISO default for that frame.

## What the audit found (numbers that motivate each line)

1. `NoiseProfile.forISO` is a generic seed that under-reads real noise: measured σ(0.18)
   (LibRaw, mean of channels) over seed = 1.72 G9, 1.89 X9, 2.00 GX850, 1.77 X-T10, 1.13 A7C,
   1.98 77D, 1.36 D7200, 1.81 A7 IV. Every threshold is in units of a σ that is ~1.75× too small.
2. Demosaiced noise is not white. Band σ (in units of the white-noise table the thresholds
   use) on real frames, bands 0–4: chroma U ≈ 1.2, 3.7, 5.2, 5.4, 4.5; luma ≈ 2.3, 3.6, 5+.
   The thresholds assumed 1, 1, 1, 1, 1. Chroma noise lives in bands 1–3 (2–8 px blotches),
   exactly where the shipped Colour thresholds were 3–5× too low. Shipped default on the G9:
   flat chroma noise 9.0 → 4.5 ΔE*ab, the dark jacket stays purple/green.
3. Shipped Luminance at its ISO-3200 default (18.75) cut flat L noise 20 % while texture
   retention fell 0.976 → 0.928 (R5 background 0.79 → 0.58): fine grain removed, 2–8 px mottle
   left. That is the watercolour look.
4. The equal-weight Y0U0V0 basis makes Colour NR move luminance: Colour 25 alone drops
   texture retention 0.976 → 0.936 (A7 IV sim) and raises flat L error 7 % (R5).
5. The luma edge map fires on 54 % of pixels from noise alone; the chroma edge map almost
   never fires, so Colour Detail 0 → 100 moved edgeC by 0.02 (a dead control).
6. The guided-filter blotch pass bleeds at equal-luminance colour edges (its own measurement in
   `GPUPlan.blotchMix`) and buys nothing once bands are calibrated (flat chroma 2.22 vs 2.22).
7. Hot pixels: after demosaic a hot pixel is a single-channel 3×3 blob (red site: centre 1,
   edges 0.5, corners 0.25) or, on a green site, a near-white 1–3 px streak. The shipped pass
   replaces only the centre with its 8-neighbour median: median residual peak 51 % at every
   setting. It removes 18–33 % of the peak of ordinary stars, and at Hot Pixels 100 alters
   9.8 % of plain noise pixels.

## Acceptance lines

### WS-19 classic NR

| # | Claim | Threshold | Command |
|---|---|---|---|
| 19.1 | Noise model matches real sensors | `NoiseProfile.forISO` σ(0.18) / measured σ within [0.7, 1.4] on ≥ 7 of 8 corpus frames | `measure.py profile` |
| 19.2 | Colour noise vanishes at default (Colour 25, Detail 50, Smoothness 50, Luminance 0) | real frames: flat `noiseC` ≤ 2.2 ΔE*ab AND ≥ 70 % below input on all 5; sims a7iv, r5, r5bg: `flatC` ≥ 70 % below input | `measure.py colour` |
| 19.3 | No colour bleeding at default | (a) equal-luminance red/blue step with demosaiced noise: 10–90 % chroma width grows ≤ 1.0 px vs noise-free twin; (b) 2 px colour line keeps ≥ 70 % of its chroma contrast; (c) sims a7iv, r5, r5bg: `edgeC` ≤ 0.75 × input | unit test `testColourDefaultDoesNotBleed…`; `measure.py colour` |
| 19.4 | Colour NR leaves luminance alone | Luminance 0, Colour 25: `texRet` within 0.01 of input and `flatL` within 3 % of input on a7iv, r5 | `measure.py colour` + unit test |
| 19.5 | Luminance beats shipped at matched noise | at the setting that removes 35 % of flat L noise: `texRet` and `midRet` ≥ shipped engine's at the same reduction (a7iv, r5); max reachable reduction ≥ 55 % (shipped tops out at 50 % on a7iv) | `measure.py luma` |
| 19.6 | Luminance is smooth and has no dead range | 0…100 in steps of 10: `texRet` strictly decreasing on a7iv with every step ≥ 0.01; `flatL` non-increasing 0→60 on r5bg | `measure.py luma` |
| 19.7 | Luminance Detail works | Luminance 50: Detail 0→50→100 raises `texRet` monotonically, total ≥ 0.10 (a7iv) | `measure.py luma` |
| 19.8 | Luminance Contrast works | Luminance 50: Contrast 0→50→100 raises `midRet` monotonically, total ≥ 0.04 (r5) | `measure.py luma` |
| 19.9 | Colour Detail works | Colour 25: Detail 0→50→100 lowers gx85 `edgeC` monotonically by ≥ 0.8; a7iv `flatC` rises ≤ 0.5 | `measure.py colour` |
| 19.10 | Colour Smoothness works | Colour 25: Smoothness 0→50→100 lowers r5bg `flatC` monotonically by ≥ 0.15 | `measure.py colour` |
| 19.11 | Off is identity | every slider 0 → output bit-identical to input | existing `DenoiseTests` |
| 19.12 | One definition for both paths | `gpuPlan` luma / chroma-U / chroma-V thresholds equal the engine's × `encodedScale`; basis matrices are exact inverses | unit test; macOS `gpu-parity` CI |
| 19.13 | No black lift | Luminance 100 + Colour 100 on r5bg: mean ΔL* in L* < 30 ≤ 1.0 | `measure.py luma` |

### WS-20 hot pixels

| # | Claim | Threshold | Command |
|---|---|---|---|
| 20.1 | Hot pixels go | Hot Pixels 50: ≥ 90 % of injected hot pixels left at ≤ 30 % of their peak | `measure.py hot` + unit test |
| 20.2 | Stars stay | stars with PSF σ ≥ 0.7 px: ≥ 95 % keep ≥ 90 % of peak at 25, 50 and 100 | `measure.py hot` + unit test |
| 20.3 | Speculars stay | discs r 1–2.5 px: 100 % keep ≥ 90 % of peak at every setting | `measure.py hot` |
| 20.4 | Noise is not touched | pixels changed on the noise-only base ≤ 0.1 % at 50, ≤ 1 % at 100 | `measure.py hot` |
| 20.5 | Slider | 0 is identity; changed-pixel count non-decreasing with the slider | unit test |

### WS-21 mode and ISO defaults

| # | Claim | Threshold | Command |
|---|---|---|---|
| 21.1 | Colour default | 25 at every ISO (Lightroom's), because thresholds are now in units of measured noise | unit test |
| 21.2 | Luminance default | rises log-linearly with ISO from 0 at ≤ 400 to 25 at ≥ 25600 (anchors in `ISODefaults.luminanceAnchors`); on the 5 real frames the default cuts flat L noise by 10–45 % (visible help, not plastic) | `measure.py defaults` |
| 21.3 | Sub-slider defaults | Detail 50, Contrast 0, Colour Detail 50, Smoothness 50 at every ISO | unit test |
| 21.4 | Per camera | on each of the 5 real frames (4 makes, 3 sensor sizes) the ISO default meets 19.2 | `measure.py defaults` |
| 21.5 | Mode semantics unchanged | Off is off, Classic reads the block, AI zeroes un-hand-set masters | existing `DenoiseTests` |

### Visual claims (human-judged, sheets in `evidence/`)

- V1 `2348-jacket.png`: at the new ISO default the jacket's purple/green colour noise is gone
  and the red stripe's edge carries no halo; shipped default keeps visible colour blotches.
- V2 `2062-poppy.png`: red / white / green boundaries keep their colour, no bleed.
- V3 `hot-pixels.png`: hot pixels gone, stars and speculars intact.
