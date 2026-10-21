# WS-14 Texture & Clarity: acceptance spec

Controls: `develop.detail.texture`, `develop.detail.clarity` (global, and the same functions behind the
local mask sliders). Source of the defects: the auditor's report (D1 to D14). This spec describes
behaviour only. The algorithm is the builder's choice (edge-aware multi-scale, guided filter,
local Laplacian with a correct remap, and so on), but the CPU reference and the GPU kernel must
implement the same one.

Every line has an ID, a threshold, the command that measures it and the **baseline** on the unfixed
code (branch `quality/ws-14-texture-clarity` at `84bcd7c`). A line passes only if every case it
names passes.

## 0. Definitions and setup

- **L** is the long edge of the rendered image in px. Frequencies are in **cpi**, cycles per image long
  edge, so the period in px is L / cpi. "px@6000" means the period at a 24 MP (6000 px) long edge.
- **Texture band**: features of 2 to 8 px at 6000 px, i.e. periods of **4 to 16 px@6000 = 375 to
  1500 cpi** (0.067 % to 0.27 % of L). Band centre **750 cpi** (8 px@6000).
- **Clarity band**: local contrast with a Lightroom-like radius of tens to about 150 px@6000, i.e.
  periods of about **37 to 300 px@6000 = 20 to 160 cpi** (0.6 % to 5 % of L). Band centre **60 cpi**
  (100 px@6000).
- **Gain** is a cross-spectral or regression gain of log2 luminance (render vs value 0): 1.00 means
  untouched, 2.00 means the log-contrast is doubled, 0 means removed. A gain below 0 is a sign flip.
- **Codes** are 8-bit sRGB-encoded luma (0 to 255), measured on `--no-dither` renders.
- Probe frames that test 24 MP behaviour are **6000 px wide strips** (`tools/gen_frames.py`). Every
  renderer radius depends on the long edge, so a 6000 x 1000 strip runs the exact 24 MP radii at
  about 1/4 of the cost. The native photos are also cut into full-width strips (`tools/lfi_strip.py`),
  so the long edge stays 7008 / 4592 / 6744. An implementation may not use the short edge, the
  aspect ratio or any image-global statistic to pick a radius or a band. (The verifier checks this
  in the code, see G1.)

```
export PATH=/opt/swift612/usr/bin:$PATH            # from the repo root
swift build -c release --product lumen-render
export BIN=$(swift build -c release --show-bin-path)/lumen-render
T=docs/quality/lanes/WS-14/tools
O=/tmp/ws14                                          # any scratch folder
bash $T/render_all.sh $O        # frames + every render the spec reads, about 30 min on 4 cores
                                # (groups: frames pink steps hardedge ramps blobs noise skin synth photos native)
```

All tools are Python 3 + numpy + Pillow and take paths as arguments. `render_set.sh` names its outputs
`PREFIX_id.png`, `PREFIX_t<value>.png` and `PREFIX_c<value>.png`. Each tool's docstring defines its
metric exactly.

## 1. Frequency response: where each control acts (isotropic 1/f probe `pink_6000`, std 0.25 EV)

Command: `python3 $T/spectrum.py $O/pink p6000` (and `p3200`, `p1600`, `p1024`).

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S1 | Texture's band is at 2 to 8 px features at 24 MP | `peak_cpi` of t+100 and t-100 at L=6000 lies in **[375, 1500] cpi** | 288 / 288 cpi (20.9 px), **FAIL** |
| S2 | Texture leaves large-scale structure alone | `coarse_ratio` (max \|g-1\| at ≤ 120 cpi, period ≥ 50 px@6000, divided by the peak) **≤ 0.20** for t±50 and t±100 at 6000 | 0.33 to 0.34, **FAIL** |
| S3 | Texture rolls off at the pixel level, so it does not chase noise | `fine_ratio` (≥ 2000 cpi, period ≤ 3 px@6000) **≤ 0.60** for t±100 at 6000 | 0.00 to 0.02, PASS |
| S4 | Texture has authority in its band | at 6000: `g750`(t+100) **≥ 1.50**; `g750`(t-100) **≤ 0.50** and ≥ 0 | 1.252 / 0.747, **FAIL** |
| S5 | Clarity is a mid-frequency control | `peak_cpi` of c+100 and c-100 at 6000 lies in **[20, 160] cpi** | 2614 / 2614 cpi (high-pass shelf), **FAIL** |
| S6 | Clarity has little effect at the finest scales | `fine1500` (max \|g-1\| at ≥ 1500 cpi, period ≤ 4 px@6000, divided by the peak) **≤ 0.25** for c±100 and c±50 at 6000 | 1.00, **FAIL** |
| S7 | Clarity has authority and -Clarity smooths convincingly | at 6000: `g60`(c+100) in **[1.40, 2.50]**; `g60`(c-100) **≤ 0.70** | 1.439 / 0.773, **FAIL** (the -100 half) |
| S8 | The two bands are clearly separated | `centroid_cpi`(t+100) / `centroid_cpi`(c+100) **≥ 4** at 6000 (two octaves apart) | 265 / 254 = 1.04, **FAIL** |

## 2. Slider response: monotonic, no dead range, no sign flip, identity at 0

| ID | Claim | Threshold and command | Baseline |
|---|---|---|---|
| M1 | Band-centre gain rises strictly with the value | `spectrum.py $O/pink p6000` and `p3200`: the line `t gain@750cpi ... strictly_increasing=True` and `c gain@60cpi ... True` (values -100, -50, -25, 0, 25, 50, 100) | True on both, PASS |
| M2 | No dead range near 0 | at 6000: \|g750-1\| for t±25 **≥ 0.08**; \|g60-1\| for c±25 **≥ 0.08** | t +0.063 / -0.063; c +0.082 / -0.070, **FAIL** |
| M3 | Smooth progression (no jump, no stall) | at 6000, at the band centre: \|g(±50)-1\| / \|g(±100)-1\| in **[0.35, 0.65]**; \|g(±25)-1\| / \|g(±100)-1\| in **[0.15, 0.40]**, for both controls | t 0.50 / 0.25; c 0.41, 0.57 / 0.19, 0.31, PASS |
| M4 | No sign flip or overshoot of the band at any render size | at L = 1024, 1600, 3200 and 6000, every bin: negative values `gmin ≥ 0.00` and `gmax ≤ 1.05`; positive values `gmin ≥ 0.95` (both controls) | t-100 at 1024: gmin **-0.225** (sign reversed at the preview's Nyquist), **FAIL** |
| M5 | Value 0 is an exact identity | `bash $T/identity.sh corpus/lfi/6929_sony-ilce-7m4.lfi $O/ident 1600`: both `IDENTITY` lines say `byte-identical yes` (with Dehaze off and with Dehaze 10 building the decomposition) | yes / yes, PASS |
| M6 | ±1 is a small step | same command: every `CONTINUITY` line max **≤ 3 codes** | max 2, PASS |
| M7 | ±25 has a measurable effect on real photos | 8 photos at 1600 (`photo_metrics.py $O/photos <id>` for 6929 6933 2545 1569 983 2348 4694 3437): every photo \|gT-1\| ≥ **0.05** at t±25 and \|gC-1\| ≥ **0.03** at c±25 | texture 0.066 to 0.21 PASS; clarity 0.000 to 0.005, **FAIL** |
| M8 | Monotonic on real photos | same 8 photos: gT strictly increasing over t = -100, -50, -25, (0 = 1), 25, 50, 100; gC strictly increasing over c at the same values | texture PASS; clarity **FAIL** (983 gC flat at 1.000; 2348 gC 1.001 to 0.998, *decreasing*) |

## 3. Authority and band separation on real photos (8 photos at 1600, `photo_metrics.py`)

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| P1 | Texture works on photos | every photo gT(t+100) **≥ 1.20** and gT(t-100) **≤ 0.80**; median over the 8 **≥ 1.40** / **≤ 0.60** | min 1.248 (983), median 1.79 / max 0.722, median 0.32, PASS |
| P2 | Clarity works on photos (D1: the γ-node comb makes it net zero now) | every photo gC(c+100) **≥ 1.15** and gC(c-100) **≤ 0.88**; median **≥ 1.25** / **≤ 0.80** | gC +100 = 0.998 to 1.016, -100 = 0.985 to 1.001, **FAIL** |
| P3 | Each control stays in its band on photos | at ±100: Texture \|gC-1\| ≤ **0.30**·\|gT-1\|; Clarity \|gT-1\| ≤ **0.50**·\|gC-1\| (every photo) | Texture max 0.13 PASS; Clarity e.g. 3437 \|gT-1\| 0.093 vs \|gC-1\| 0.021, **FAIL** |

## 4. Brightness: neither control changes overall brightness

| ID | Claim | Threshold and command | Baseline |
|---|---|---|---|
| B1 | Flats, ramps and synthetic patches keep their brightness | `photo_metrics.py $O/synth <s> t-100 t100 c-100 c100` for s = flat_grey, grey_ramp, colorchecker, skin_tones; also `$O/ramp r` and `$O/skin k6000`: \|dLuma\| **≤ 0.25 codes** and zoneP **≤ 1.0 code** | skin_tones c+100 **-0.42**, skin_6000 c+100 **-0.35**, **FAIL** (all others ≤ 0.12 / ≤ 1.0) |
| B2 | Photos keep their mean brightness | 8 photos at 1600, ±100 of both: \|dLuma\| **≤ 0.50 codes** | Texture +100: +1.56 (6929), +1.73 (2545), **+1.92** (1569); -100 down to -1.09, **FAIL**. Clarity ≤ 0.27, pass |
| B3 | Photos keep their tones (block zones, L/10 blocks) | same renders: zoneB **≤ 1.0 code** | Texture +100 up to **3.80** (2545), **FAIL**; Clarity ≤ 0.55 |
| B4 | Same at full size | `photo_metrics.py $O/native <n>_full` for n = 6929, 2545, 983 at ±100: \|dLuma\| **≤ 0.75**, zoneB **≤ 1.5** | 2545 t+100 **+2.98** / 3.54, **FAIL** |

## 5. Colour: no hue shifts, limited chroma change

| ID | Claim | Threshold and command | Baseline |
|---|---|---|---|
| C1 | Chroma barely moves | 8 photos at 1600 and the 3 native strips at full size, ±100: Texture \|chroma\| **≤ 2.0 %**; Clarity chroma change in **[-2.0 %, +4.0 %]** (Lightroom's Clarity may add a little saturation, never take it) | Texture ≤ 1.29 % PASS; Clarity 3437 **-2.56 %**, **FAIL** |
| C2 | No systematic hue rotation | same renders: whole-frame chroma-weighted signed hue change **≤ 1.0°**, worst 30° sector **≤ 2.5°** (pixels with C > 0.03 and ≥ 30 codes) | worst: 2545 c+100 **-1.11°** whole frame (sector 1.93°), Texture worst sector 2.24°, **FAIL** (C2 whole-frame part) |
| C3 | colorchecker is untouched | `photo_metrics.py $O/synth colorchecker t-100 t100 c-100 c100`: mean \|hue\| (the `\|hue\|` field) **≤ 0.2°** and \|chroma\| **≤ 0.5 %** | \|hue\| ≤ 0.08°, chroma ≥ -0.25 %, PASS |

## 6. Halos and edges

Steps: `python3 $T/halo.py $O/steps s6000` and `... s1600` (0.5 / 1 / 2 / 3 / 6 EV steps).
High-contrast lines and junctions: `python3 $T/hard_edge.py $O/he he`.
Soft gradients (bokeh-like blobs, σ 0.25 to 2 % L): `python3 $T/blobs.py $O/blobs b6000` and `... b1600`.

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| H1 | +Texture does not rim edges | t+100, t+50, t-100 at 6000 and 1600: WORST over and under **≤ 6 %** of the step | t+100: 28 / 28 % (6000), **40 / 36 %** (1600), **FAIL** |
| H2 | Texture's residual edge effect is narrow | t±100 WORST width **≤ 0.15 % L** | 0.30 % (6000), 0.25 % (1600), **FAIL** |
| H3 | -Texture keeps edges sharp | t-100 rise growth **≤ 2 px** at 6000, **≤ 1 px** at 1600 | +9 px / +4 px, **FAIL** |
| H4 | Clarity does not halo | c+100, c+50, c-100 at both sizes: WORST over and under **≤ 8 %** | c-100: **28 %** over (6000), 20 % (1600); c+100 6.1 %, **FAIL** |
| H5 | Clarity does not blur edges into halos | c±100, c+50: rise growth **≤ 2 px** at both sizes; WORST width **≤ 3 % L** | c+100 rise **+40 px** (6000), +9 (1600), **FAIL** |
| H6 | No blobs at line ends, T-junctions or very high contrast edges | `hard_edge.py`, all four renders: max **≤ 30 codes** and > 8 codes on **≤ 0.02 %** of pixels | t+100 **117**, t-100 **102** codes, 0.069 %, **FAIL**; clarity 13 / 4, PASS |
| H7 | No rings around soft blobs | `blobs.py`, all five renders at 6000 and 1600: WORST ring **≤ 3 %** of the blob amplitude | c+100 **7.0 %** (6000), 6.5 % (1600), **FAIL** |

## 7. Posterisation and tone smoothness

| ID | Claim | Threshold and command | Baseline |
|---|---|---|---|
| Q1 | Soft gradients stay soft (no plateaus with hard outlines: the lantern-glass / bokeh defect D2) | `blobs.py` at 6000 and 1600: WORST slope ratio **≤ 2.2** at ±100 and **≤ 1.6** at +50, both controls | c+100 **x6.85** (6000), x6.36 (1600); c+50 **x2.24**, **FAIL** |
| Q2 | Local-contrast gain is smooth over tone (no γ-node comb, D1/D4) | `python3 $T/ramp_gain.py $O/ramp r --vs r0 c100 c-100 c50 c-50 t100 t-100 t50 t-50`: for +values `mid_min ≥ 1.05`, for -values `mid_max ≤ 0.95`; `mid_ratio ≤ 1.35` (Clarity ±100) / ≤ 1.25 (Texture ±100); `max_jump ≤ 0.15` (all) | c+100: mid_min **0.595**, ratio **3.02**, jump **1.20**; c-100: mid_max **1.165**, jump 0.60, **FAIL**. Texture: ratio 1.07, jump 0.13, PASS |
| Q3 | One black pixel does not change the control | same command: Clarity ±100 `vs_maxdiff` **≤ 0.05** | c+100 **0.954**, c-100 0.559, **FAIL** |
| Q4 | No new histogram gaps on a lightly textured ramp | `python3 $T/poster.py $O/ramp rl`: `new gaps` **≤ 0** for every render | +0, PASS |

## 8. Noise

Command: `python3 $T/noise.py $O/noise n6000` (flat 0.18 with 4 % per-pixel luminance noise, 6000 px).

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| N1 | +Texture does not exaggerate noise (ACR: "doesn't exaggerate the noise") | t+100 pixel-level std **≤ x1.35** of the identity. This holds together with S4: the 8 px band must be boosted, the 2 px noise must not | x1.01, PASS (but only because the band sits at 21 px: S1 and S4 fail) |
| N2 | +Clarity does not amplify pixel noise | c+100 pixel-level std **≤ x1.15** | **x3.71**, **FAIL** |

## 9. Skin: negative values smooth convincingly

Command: `python3 $T/skin.py $O/skin k6000` (skin_6000: pores = 2 to 8 px features, 40 to 200 px
mottling, 3 px lashes of -1.5 EV, 1 EV lip edge).

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| K1 | -Texture removes pore-scale detail | t-100 pores **≤ x0.55**; t-50 pores ≤ x0.80 | x0.67 / x0.83, **FAIL** |
| K2 | -Texture leaves mid-scale modelling | t-100 mottle **≥ x0.85** | x0.75, **FAIL** |
| K3 | Lashes stay | t-100, t-50 and c-100: lash depth **≥ x0.90**, width growth **≤ 1 px** | x0.93 / x0.97 / x0.96, +0 px, PASS |
| K4 | Edges stay sharp under negative values | t-100 and c-100: lip rise growth **≤ 2 px**, over and under ≤ 5 % | t-100: 3 to **19 px**, **FAIL**; c-100 PASS |
| K5 | -Clarity is a soft mid-scale smoothing, not a blur | c-100 mottle **≤ x0.70** and pores **≥ x0.85** | x0.76 / x0.73, **FAIL** |
| K6 | +Clarity leaves pores mostly alone | c+100 pores **≤ x1.25**, mottle **≥ x1.40** | **x2.12** / x1.63, **FAIL** |
| K7 | +Texture lifts pores, not mottling, without rimming the lip | t+100 pores **≥ x1.40**, mottle **≤ x1.15**, lip over and under ≤ 6 %; c+100 lip over and under ≤ 8 % | x1.38 / x1.27 / 24.9 %; c+100 under 14.6 %, **FAIL** |

## 10. Resolution consistency: the preview shows what the export will do

Command: `python3 $T/resconsist.py BIG_id BIG_v SMALL_id SMALL_v`. The full-size render is
area-downsampled to the preview size in linear light, and then the effect maps
(log2 Y(v) - log2 Y(0)) are compared. Texture's band lies above the 1600 px Nyquist (800 cpi), so at
1600 px it is held to the part that survives the downsample (looser ratio). It is held tight at
3200 px, where the whole band is representable.

| ID | Claim | Pairs | Threshold | Baseline |
|---|---|---|---|---|
| R1 | Clarity preview = export (pink) | `$O/pink/p6000_*` vs `p1600_*` and vs `p3200_*`, c±100 and c±25 | ratio **[0.85, 1.15]** and corr **≥ 0.85** at ±100; ratio [0.80, 1.25] and corr ≥ 0.80 at ±25 | 1600: c+100 **1.74 / 0.733**, c-100 1.26 / 0.944; 3200: c+100 **1.33** / 0.763, **FAIL** |
| R2 | Clarity preview = export (photos) | `$O/native/<n>_full_*` vs `<n>_1600_*`, n = 6929, 2545, 983, c±100 | ratio **[0.80, 1.25]**, corr **≥ 0.80** | 6929 1.49 / 0.68; 2545 **1.98 / 0.105**; 983 1.06 / 0.525, **FAIL** |
| R3 | Texture preview = export at 3200 (pink) | p6000 vs p3200, t±100 and t±25 | ratio **[0.85, 1.15]**, corr **≥ 0.90** at ±100 (≥ 0.80 at ±25) | 1.07 / 0.982; ±25 1.13 / 0.86, PASS |
| R4 | Texture preview agrees at 1600 (pink) | p6000 vs p1600, t±100 | ratio **[0.80, 1.20]**, corr **≥ 0.85** | **1.52** / 0.92, **FAIL** |
| R5 | Texture preview agrees at 1600 (photos) | native n = 6929, 2545, 983, t±100 | ratio **[0.70, 1.30]**, corr **≥ 0.70** | 6929 1.36; 2545 **1.60**; 983 **0.53 / 0.45**, **FAIL** |

## 11. GPU twin, scope and regressions

| ID | Claim | How it is checked | Baseline |
|---|---|---|---|
| G1 | The GPU kernel implements the CPU algorithm | **Code reading by the verifier.** `RenderGraph.applyPresence` / `applyDetailBands` (+ `localStructure` / `structureRadius`) and the `Kernels.swift` sources it uses must build the same decomposition as `DetailEngine.applyTexture` / `applyClarity`: the same log-luminance domain and floor, the same band definition as fractions of L (no rounding a CPU path does not do), the same gain law per value, the same gates and edge-stopping thresholds in the same units, the same clamps, the same Texture → Clarity order and luminance source, the same luma-ratio recombination. Neither path may use a global image statistic (min/max range and the like) that the other does not. The builder's REPORT.md has a table mapping each CPU step to its GPU line, and every difference is listed with a reason (e.g. a float16 or CIFilter rounding). Any algorithmic difference is a FAIL. | **FAIL**: audit §5 G1 to G7 (GPU Texture is one guided high-pass, GPU Clarity is a single-scale remap) |
| G2 | The macOS parity tests cover the new algorithm and pass | `swift test --filter LumenPipelineTests` on macOS CI (`gpu-parity.yml`; it cannot run on Linux): `TextureSpectrumProbeTests.testTextureFrequencyResponseOnBothPaths`, `KernelGoldenTests.testGraphMatchesTheReferenceRendererWithTheSpatialStagesOn` (SPATIALPARITY), `testPresenceDoesNotRimAHardEdge`, `testNegativeTextureSmoothsTextureMoreThanEdges`, `testTextureGainClampsAtFourEVLikeTheReference`, `testDetailSliderMovesThePicture`, `GlobalPresenceClampTests`, `LocalPresenceStrengthTests`. The builder **tightens** the probe: (a) TEXSPEC asserts gpu/ref gain within **[0.85, 1.15]** at every period; (b) the same probe is added for Clarity (periods 8 to 128 px at a long edge of 1024 or more); (c) the SPATIALPARITY per-stage texture and clarity gpu/reference ratios are asserted within **[0.80, 1.25]**. The verifier checks that these assertions exist and compile-read correctly. The lane is PASS only when macOS CI is green, or else G2 is "pending CI" in the report. | probe asserts only 0.2 to 5x sanity bounds, n/a |
| G3 | Local mask Texture / Clarity keep working | `swift test --filter LumenCoreTests` passes, including `LocalStageReferenceContractTests.testTextureAndClarityKeepRespondingAboveOneHundredStrength` and `GlobalPresenceClampReferenceTests` (global clamped at ±100, mask Strength up to 200 still scales) | PASS |
| G4 | Dehaze (WS-15) is unchanged | Render 6929 at 1600 with `--set develop.detail.dehaze=50` and `=-50` on the base commit and on the lane head: max difference **≤ 1 code**. If the shared `Decomposition` has to change Dehaze, it goes in `NEEDS.md`, not in this lane. | n/a (by construction) |
| G5 | Tests that encoded the old behaviour are changed honestly | e.g. `ScaleHonestyTests.testTheClarityPyramidTracksTheLongEdge` (rounded pyramid depth) and `EngineIntegrationTests.testTextureChangesLocalContrastWithoutMovingTheMean`: a test may be changed only to encode the new spec behaviour, with the reason in the commit and REPORT.md. Nothing is skipped or loosened. | n/a |

## 12. Unit tests the builder adds to `Tests/LumenCoreTests` (fast, synthetic, `DetailEngine` direct)

Run the presence stage the way `ReferenceRenderer` does: `Decomposition(image:workingRadius:)` with
radius `max(Int(0.02·L), 3)`, then `DetailEngine.apply`. Use strips (long edge as given, short edge
32 to 128 px) so each test takes under a second or two in debug. Log amplitudes are measured on
log2 Y.

| Test | Encodes | Content |
|---|---|---|
| U1 | M5 | texture = clarity = 0 returns pixels bit-identical to the input (also with dehaze ≠ 0 in the same `Detail`) |
| U2 | S1, S4, S5, S6 | a 6000 x 32 strip with log-sinusoids (0.05 EV) along x. At +100: Texture gain ≥ 1.5 at period 8 px and ≤ 1.15 at period 64 px; Clarity gain ≥ 1.3 at period 100 px and ≤ 1.15 at periods 3 to 4 px |
| U3 | M1, M4 | on the same probes at long edges 512, 1024 and 6000: band-centre gain strictly increasing over the seven values; at -100 the gain is ≥ 0 at every period down to 2 px (Nyquist) |
| U4 | B1/B2 | a 1024 x 256 1/f texture (0.25 EV): at ±100 the mean of the sRGB-encoded luminance moves by ≤ 0.002 (0.5 code) |
| U5 | H1, H3, H4 | a 2048 x 32 strip with a 0.5 EV and a 1 EV step: over and under ≤ 6 % (Texture) / ≤ 8 % (Clarity) of the step in encoded luma; t-100 10-90 % rise grows ≤ 1 px |
| U6 | Q1, H7 | a 2048 x 256 strip with a σ = 20 px, +1 EV Gaussian blob: Clarity +100 max radial slope ≤ 2.2x the input, ring ≤ 3 % |
| U7 | Q2, Q3 | a 1024 x 128 log ramp -5..+3 EV with 0.1 EV noise: Clarity +100 gain in every 1 EV window over [-3, +2] is ≥ 1.05, max/min ≤ 1.35; setting one pixel to 0 changes every window gain by ≤ 0.05 |
| U8 | R1, R4 | 1/f strips 4096 x 128 and their 2x area-downsample 2048 x 64: effect RMS ratio within [0.85, 1.15] and corr ≥ 0.85 (Clarity); within [0.8, 1.2] and corr ≥ 0.85 (Texture) |
| U9 | N1, N2 | a 6000 x 64 flat 0.18 with 4 % Gaussian noise: pixel-level std ratio ≤ 1.35 (Texture +100) and ≤ 1.15 (Clarity +100) |
| U10 | K1, K3 | a 6000 x 128 strip with σ 1.5 px, -0.25 EV dips and one 3 px, -1.5 EV line: Texture -100 fine-band energy ≤ 0.6x, line depth ≥ 0.9x |

## 13. Visual claims (a human judges them; build with `python3 $T/sheets.py $O`)

Each sheet goes into `evidence/` with its before (base commit) twin.

- **V1 `V1_skin.png`** (skin_6000, 2x crop beside the lashes). Texture -50 / -100 visibly smooths
  the pore speckle into even skin, and the lashes stay as crisp, dark and thin as at 0, with no grey
  fringe. Clarity -100 looks like a soft, low-contrast mottling reduction (gentle glow), not a blur.
  Clarity +100 shows **no blotchy flat patches with hard outlines**. Today's Clarity +100 does, and
  that is the defect.
- **V2 `V2_lantern.png`** (983 native strip, 1:1 crop of the lantern glass and the blurred background
  at x 4700, y 250, 700 x 700). At Clarity +50 and +100 the bokeh and the glass gradient stay smooth,
  with more local contrast but **no contour lines and no hard-edged plateaus** (today's +100 cuts the
  left bokeh shape into a flat cut-out). Texture +100 does not turn the dust specks into bright
  sparkles noticeably more than it enhances the surrounding texture.
- **V3 `V3_preview.png`** (2545 tree and sky). Each row pairs the 1600 preview with the full-size
  export reduced to 1600. The two halves of every row look like the same edit: today's Texture -100
  preview is a defocus blur while the export is not. That mismatch must be gone, and Texture +100 and
  Clarity +100 must look equally strong in both halves.

## 14. Baseline summary

Failing on the unfixed code: S1 S2 S4 S5 S6 S7 S8, M2 M4 M7 M8, P2 P3, B1 B2 B3 B4, C1 C2, H1 to
H7, Q1 Q2 Q3, N2, K1 K2 K4 to K7, R1 R2 R4 R5, G1.
Passing (regression guards): S3, M1, M3, M5, M6, P1, C3, Q4, N1, K3, R3, G3.

## 15. Amendments, round 2 (after verify round 1)

These lines **add to** sections 1 to 14. Every existing line ID keeps its meaning and threshold,
except R5, which is refined here (R5a). Each line below has two baselines:

- **head** is `e406d6e`, the round-1 build.
- **base** is `e75523c`, which carries the unfixed code.

Both were rendered with release `lumen-render` binaries built from those commits. The base was
built in a temporary worktree with `--scratch-path`.

New tools and frames (all in `tools/`):

- `gen_frames.py` makes `strands_6000`, `glyphs_6000` and `g2probe_*`.
- `strands.py`, `corners.py` and `probe_gain.py` are new measurement scripts.
- `resconsist.py` now also prints `Nq`, `corr_max` and a below-floor flag.
- `render_all.sh` has the new groups `strands`, `glyphs` and `g2probe`. These are also part of
  the default "all".

| ID | Claim | Threshold and command | Baseline head e406d6e | Baseline base e75523c |
|---|---|---|---|---|
| S9 | Texture has authority on **oriented** fine detail at normal contrast (hair, grass, weave), not only on isotropic texture | `python3 $T/strands.py $O/strands st6000 t100 t-100` and `... st2048 ...`. The frame has six bands: random-position hair/grass strokes (σ 1.5 px, ±20° of vertical) of depth 0.1 / 0.2 / 0.3 EV, and a grating of period 10 px@6000 (3.4 px at 2048) of amplitude 0.1 / 0.2 / 0.3 EV. Gain over the Texture band. **Every band** at both 6000 and 2048 must have t+100 gain **≥ 1.40** and t-100 gain **≤ 0.60**. S9 counts as PASS only if H1 and H2 also pass on the same build: oriented detail must not be bought back with rims on the 0.5 to 6 EV steps. | 6000 t+100: strokes 1.81 / 1.86 / 1.49, grating 1.42 / **1.000 / 1.000**; t-100: 0.26 / 0.34 / **0.62**, **0.61 / 1.000 / 1.000**. 2048 t+100: grating 0.3 EV **1.000**, 0.2 EV **1.125**; t-100: **0.89 / 1.000**. **FAIL** (the gate shuts at ≥ 0.2 EV oriented content). H1 and H2 PASS (0 %) | 6000 t+100 min **1.380** (strokes 0.1: 1.387, grating 0.3: 1.380), t-100 max **0.658**; 2048 PASS (t+100 ≥ 1.60, t-100 ≤ 0.574). **FAIL**, and H1 fails as well (28 %) |
| H8 | Clarity does not mark convex corners or junctions | `python3 $T/corners.py <dir> <prefix> c100 c-100` on `$O/synth colorchecker`, `$O/synth skin_tones` (1600), and `$O/glyphs g1600`, `g6000` (twelve 1-2 EV squares, L, T, + and E glyphs). The metric is geometry-free: corner and junction pixels have a 2-D structure tensor on the identity, and straight-edge pixels lie more than 3·rc from any of them, with rc = 0.5 % L. For c±100 on all four frames: **corner max ≤ max(1.5 × straight max, 6)** and **corner max ≤ 15 codes** | c+100: cc 29.5 vs straight 11.4; skin_tones 26.1 vs 9.7; glyphs 34 vs 13 (1600) and 34 vs 20 (6000). c-100: skin_tones 14.1 vs 6.2; glyphs 1600 15 vs 9. **FAIL** (c-100 colorchecker and glyphs 6000 pass) | c+100: cc 8.3 / 7.1, skin_tones **15.2** / 15.2, glyphs 6000 10 / 9, glyphs 1600 **24** / 22. c-100 all pass (≤ 11 codes). **FAIL** (cap: skin_tones by 0.2 code, glyphs 1600 24) |
| H8b | Texture does not mark corners or junctions either (regression guard) | same command, t±100 on the same four frames: corner max **≤ 20 codes** | cc 17.0 / 13.1, skin_tones 18.2 / 15.8, glyphs 6000 19 / 18, glyphs 1600 18 / 17. **PASS** (with 1 to 2 codes of margin) | cc **80 / 135**, skin_tones 62 / 48, glyphs 49 / 48 and 55 / 55. **FAIL** |
| R5a | *Refines R5.* Below a stated noise floor, a frame drops out of the correlation part of R5 but still has to meet the strength ratio | `resconsist.py` (unchanged pairs, t±100) now prints `Nq`. This is the RMS of the 8-bit quantisation noise in the preview effect map, assuming independent rounding of both renders: per pixel, 2·(1/12)·(∂log2Y/∂code)². The **floor is max(0.03 EV, 2·Nq)**, and the tool marks `BELOW-FLOOR (corr exempt)` when the preview effect RMS is under it. A below-floor frame needs only the R5 ratio **[0.70, 1.30]**. Every other frame needs ratio [0.70, 1.30] and corr ≥ 0.70 as before. **Why this floor:** at effect RMS = 2·Nq the signal is S² = 3·Nq², so the best correlation a perfect implementation can reach is S²/(S² + Nq²) = 0.75. That is just above R5's 0.70. Below it, the corr criterion measures 8-bit rounding, not the control. On these frames Nq = 0.021 EV (983), 0.023 EV (2545) and 0.024 EV (6929), so the floor is 0.041 to 0.048 EV. | 983: RMS 0.0145 / 0.0164 EV, below the floor (0.041). Ratio 1.25 / 1.18 within [0.70, 1.30], corr exempt (0.61 / 0.64). 6929: 1.04 / 1.05, corr 0.93 / 0.92. 2545: 1.18 / 1.18, corr 0.87 / 0.84. **PASS** | 983 t-100: RMS 0.039, below the floor, but ratio **0.53**. 983 t+100: 0.045 (above the floor), ratio 0.55, corr **0.45**. 2545 ratio **1.60**, 6929 ratio **1.36**. **FAIL** |
| U11 | The presence unit suite is fast | `swift build --build-tests && swift test --skip-build --filter PresenceBandTests` (debug, Linux, nothing else running). **Each test ≤ 5 s** and the suite ≤ 30 s, measured from XCTest's per-test times. The probes stay in the U1 to U10 contract: strips, and fewer or smaller probes, not looser thresholds. Long-edge-dependent probes must keep their long edge (e.g. a 6000 × 16 strip) and shrink the short edge or the number of periods instead. | U1 1.2 s; U2 47.0; U3 **216.5**; U4 25.2; U5 25.6; U6 17.5; U7 10.3; U8 **97.8**; U9 30.2; U10 40.2; total **511.5 s**. **FAIL** (9 of 10 tests over 5 s) | n/a (the suite does not exist at base) |
| G2b | *Refines G2.* The GPU parity probes use content the edge gates leave open, so a dead GPU path fails them | `TextureSpectrumProbeTests` (TEXSPEC / CLARSPEC) and any new presence probe must use **2-D** content: an isotropic or product-of-sinusoids pattern, or band noise, at **≤ 0.05 EV** log amplitude, on a frame whose long edge is ≥ 2048 px. For every amount it asserts at the band centre (750 cpi for Texture, 60 cpi for Clarity), the **CPU reference gain must satisfy \|g − 1\| ≥ 0.30**. That check sits in the test as an assertion before the gpu/ref ratio is checked. If the reference cannot move, the ratio check proves nothing. Verified on Linux with the same content through `lumen-render`: `python3 $T/probe_gain.py $O/g2 <x20_tex\|2d05_tex\|x20_clar\|2d05_clar>`. `x20_*` is the test's current content (x-only ±20 % sinusoid); `2d05_*` is the proposed content (2-D, 0.05 EV), both at 4096 px. | current content: t±100 **1.000 / 1.000**, c±100 **1.000 / 1.000**, so the probe is vacuous. **FAIL**. The proposed 2-D 0.05 EV content gives t 1.732 / 0.315 and c 1.457 / 0.372, so it is usable | current content: t 1.285 / 0.824 (\|g−1\| < 0.30), c 1.958 / 0.570. **FAIL** for Texture |

Notes for the builder and the verifier:

- **S9 and H1/H2 together:** an edge gate can no longer use "locally oriented" as its edge
  criterion. The 0.1 to 0.3 EV strokes and grating must count as texture, while the 0.5 EV and
  larger isolated steps (H1, H2, H3) and the -1.5 EV lashes (K3) must still count as edges.
  Amplitude, isolation or a scale-space contrast test can tell them apart. Orientation cannot.
- **G5 still applies:** restoring `RobustnessTests.testPositiveTextureKeepsItsAuthorityOnFineDetail`
  to its original amplitude (about 0.2 EV hair lines) is the unit-level twin of S9. Add it to §12
  as **U12**: ±15 % (about 0.2 EV) 3 px oriented lines on a strip whose long edge is at least 2048
  px. Required: t+100 gain ≥ 1.4 and t-100 gain ≤ 0.6, measured over the Texture band.
- **H8 visual check:** the verifier also opens a 2x crop of `$O/glyphs/g1600_c100.png` against
  `g1600_id.png` at a T-junction, and of `$O/synth/skin_tones_c100.png` at a patch corner. Look
  for bright or dark rims that grow toward the corners.

Amendment baseline summary:

- **Head e406d6e:** S9 FAIL, H8 FAIL, H8b PASS, R5a PASS, U11 FAIL, G2b FAIL.
- **Base e75523c:** S9 FAIL, H8 FAIL, H8b FAIL, R5a FAIL, U11 n/a, G2b FAIL.
