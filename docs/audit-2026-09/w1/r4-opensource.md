# R4 — darktable / RawTherapee / ART / vkdt / RapidRAW: algorithms with parameters

Scope: the four open-source engines whose maths can be read. Written for auditors who own ONE area;
each section stands alone. Source tags: `[src: <repo>/<file>]` = fetched from GitHub raw this session
(darktable `master`, RawTherapee `dev`, ART `master`); `[knowledge]` = training, unverified today;
`[docs/03 §6.x]` / `[docs/26 §n]` = already in the repo. Lumen references are from `grep` over
`Sources/` this session (file paths given). Licence reminder for every "adopt outright" line below:
**darktable GPL-3.0, RawTherapee GPL-3.0, ART GPL-3.0, RapidRAW AGPL-3.0, vkdt BSD-2 core with GPL
parts** — behaviour/parameterisation may be studied, code may not be ported (docs/17 §A.2 clean-room
policy). vkdt is the only one whose permissive-core files could be reused per-file after a licence read.

Versions in the field (from docs/03 §6, repo-verified Aug 2026): darktable 5.6.0, RawTherapee 5.13,
ART 1.26.7, vkdt 1.0.0, RapidRAW 1.6.x (changelog entry dated 2026-09-01 seen today
`[src: CyberTimon/RapidRAW/README.md]`). Lumen's baselines were measured against **RT 5.10 and dt 4.6**
(`scripts/baselines/crosscheck.py`, docs/26) — the param structs below are `master`/`dev` and
`crosscheck.py` carries a tripwire for dt's sigmoid struct drifting; the sigmoid struct fetched today
still has the fields the script packs (contrast, skew, white/black target, method, hue, insets/rotations,
purity, base primaries).

---

## A · Tone & sliders

### A.1 darktable `sigmoid` — `src/iop/sigmoid.c` `[src: darktable/src/iop/sigmoid.c]`

| Parameter (struct field) | Range | Default | What it does |
|---|---|---|---|
| contrast (`middle_grey_contrast`) | 0.1 – 10.0 | **1.5** | Steepness of the log-logistic at grey; NOT a calibrated log-log slope — measured realised slope 1.23 at dial 1.5 `[docs/26 §3]` |
| skew (`contrast_skewness`) | −1 – +1 | 0 | Redistributes curvature toe↔shoulder (film_power vs paper_power split) |
| display white target (`display_white_target`) | 20 – 1600 % | 100 | `f(scene_inf) = white_target` (normalised ×0.01); >100 for HDR |
| display black target (`display_black_target`) | 0 – 15 % | **0.0152** | `f(scene_zero) = black_target` |
| color processing (`color_processing`) | enum | **per channel** | `PER_CHANNEL` (each RGB through curve) vs `RGB_RATIO` (curve the norm, keep ratios) |
| preserve hue (`hue_preservation`) | 0 – 100 % | 100 | Per-channel path only: blends the mid channel toward `min + (max−min)·midscale` ("linear interpolation of hue that also preserves sum of channels") — corrects hue angle, leaves bleaching alone (dt hue 100 vs 66 give identical chroma `[docs/26 §2]`) |
| red/green/blue inset (`*_inset`) | 0 – 0.99 | 0 | Primaries "attenuation": pull each working primary toward white before the curve (the AgX inset idea) |
| red/green/blue rotation (`*_rotation`) | −0.4 – +0.4 rad | 0 | Rotate each primary's hue before the curve |
| recover purity (`purity`) | 0 – 1 | 0 | Partially undo the inset after the curve |
| base primaries (`base_primaries`) | enum | working profile | working / Rec2020 / Display P3 / Adobe RGB / sRGB — the space the inset/rotation is defined in |

Core: `_generalized_loglogistic_sigmoid(value, magnitude, paper_exp, film_fog, film_power, paper_power)`
= `magnitude · ( (fog+x)^film_power / (paper_exp + (fog+x)^film_power) )^paper_power`; `commit_params` solves
the coefficients so that `f(0)=black`, `f(0.1845)=0.1845` (`MIDDLE_GREY 0.1845f`), `f(∞)=white`. Pivot
grey is fixed at 18.45 %, there is no white/black *relative exposure* — the curve reaches white only
asymptotically. dt 5.2 made this the default transform `[docs/03 §6.2]`.

**Mapping to Lumen `DisplayTransformParams`** (`Sources/LumenCore/Engine/DisplayTransform.swift:22-59`):
`contrast`(0.1–10, 1.5) ↔ dt contrast (same range/default, different realised slope — Lumen's is a log-log
slope contract, docs/26 §3); `skew` ↔ `contrast_skewness`; `huePreservation`(100) ↔ `hue_preservation`, but
Lumen now ramps it quadratically to per-channel across the shoulder (docs/26 §2 fix) where dt keeps it
constant; `whiteTarget`(100) / `blackTarget`(0.0152) ↔ `display_white/black_target` (identical defaults);
`attenuation: RGB(0.14,0.18,0.12)` ↔ `red/green/blue_inset` (dt default 0, Lumen ships non-zero);
`rotation: RGB(0.02,−0.03,0.06)` ↔ `*_rotation`; `purityRestore 0.4` ↔ `purity` (dt default 0);
`whiteAnchorEV 5 / blackAnchorEV −9` have **no sigmoid equivalent** — they are filmic's
`white_point_source`/`black_point_source` (defaults +4 / −8 EV), so Lumen is a sigmoid with filmic's
anchored dynamic range; no `base_primaries` selector; per-channel vs ratio is not a switch in Lumen but the
ramp. `midGrey = 0.18` vs dt 0.1845.
→ Lumen would need: nothing structural for parity; an auditor should check the anchored-range claim
(`DisplayTransform.swift:170-171`) is exercised, since dt reaches white only asymptotically and Lumen pins it.

### A.2 darktable `filmic rgb` — `src/iop/filmicrgb.c` `[src: darktable/src/iop/filmicrgb.c]`

| Field | Range | Default | Meaning |
|---|---|---|---|
| `grey_point_source` | 0–100 % | 18.45 | scene grey |
| `black_point_source` | −16 … −0.1 EV | **−8.0** | black relative exposure |
| `white_point_source` | 0.1 … 16 EV | **+4.0** | white relative exposure |
| `grey_point_target` / `black_point_target` / `white_point_target` | 1–50 / 0–20 / 0–1600 % | 18.45 / 0.01517634 / 100 | display anchors |
| `contrast` | 0–5 | 1.0 | slope of the linear "latitude" segment at grey (log-log) |
| `latitude` | 0.01–99 % | 0.01 | width of the linear segment |
| `balance` | −50…+50 | 0 | shifts the latitude toward shadows (−) or highlights (+), slope kept |
| `output_power` ("hardness") | 1–10 | 4.0 | power applied after the spline; `auto_hardness` derives it from targets |
| `saturation` | −200…200 | 0 | extreme luminance desaturation |
| `preserve_color` | enum | power norm | `NONE`, `MAX_RGB`, `LUMINANCE` (Y), `POWER_NORM` (default), `EUCLIDEAN_NORM_V1/V2` (V2 scaled by 1/√3 so norm(1,1,1)=1) |
| `spline_version` / curve `type[2]` | V1 2019 / V2 2020 / V3 2021; POLY_4 "hard", POLY_3 "soft", RATIONAL "safe" | V3 | toe and shoulder types separately |
| reconstruction | `reconstruct_threshold`, `feather`, `bloom_vs_details`, `grey_vs_color`, `structure_vs_texture`, `high_quality_reconstruction` 0–10 | — | its own highlight-reconstruction engine |

Spline: 5 nodes `x[5]` (log input), `y[5]`; three segments — toe polynomial `y = M1 + x(M2 + x(M3 + x(M4 + xM5)))`
or rational `y = M4 − M1·rat/(rat+M3)`, linear latitude `y = M1[2] + x·M2[2]` (slope = contrast), shoulder same
family. Ratio path: `norm = get_pixel_norm(RGB, variant)`, `ratios = RGB/norm`,
`norm_log = (log2(norm/grey) − black)/dynamic_range`, `out = ratios · pow(spline(norm_log), output_power)`.
Five tabs, versioned colour science v3–v7 — the learning cliff `[docs/03 §6.2]`.
→ Lumen would need: nothing (one transform by law); the auditor's use is the **white/black relative
exposure + latitude + balance** vocabulary, which Lumen's `whiteAnchorEV/blackAnchorEV` half-implements.

### A.3 RawTherapee tone curve modes — `rtengine/curves.h` `[src: RawTherapee/rtengine/curves.h]`

`ToneCurveMode` enum `STD, WEIGHTEDSTD, FILMLIKE, SATANDVALBLENDING, LUMINANCE, PERCEPTUAL`
(`[src: RawTherapee/rtengine/procparams.h]`, two curves `curve`/`curve2` each with its own mode):

| Mode | Apply |
|---|---|
| Standard | LUT per channel: `curves::setLutVal(lutToneCurve, r, g, b)` — bleaches, hue skews |
| Weighted standard | each channel = 50 % own curve + 25 % each of the other two channels' curve response (`r = r1*0.50 + r2*0.25 + r3*0.25`, Triangle interpolation) |
| Film-like (`AdobeToneCurve`) | sort RGB, curve max and min, place median proportionally: `med = min + (max−min)·(medOld−minOld)/(maxOld−minOld)` — Adobe DNG SDK "RGBTone"; **this is the mode RT's "Standard Film Curve" profiles use** and it bleaches to zero chroma by +2 EV `[docs/26 §2]` |
| Saturation & value blending | HSV: curve V, blend S |
| Luminance | curve luminance only, `coef = newL/currL; r = LIM(r*coef, 0, 65535)` — ratio-preserving like dt RGB-ratio |
| Perceptual | CIECAM02 (`f,c,nc,yb,la,xw,yw,zw` fixed) — `calculateToneCurveContrastValue()` estimates the curve's contrast gain and reduces chroma to hold perceived saturation |

Also in `ToneCurveParams`: `expcomp`, `brightness`, `contrast`, `saturation`, `black`, `shcompr`,
`hlcompr`, `hlcomprthresh`, `hlbl`, `hlth`, `histmatching` (auto-matched tone curve from embedded JPEG),
`clampOOG`, highlight-reconstruction `method` (Luminance / CIELab blending / Color propagation / Inpaint
Opposed `[knowledge]`). RT's Shadows/Highlights at 100 moves mid-grey ±0.25 EV — it re-exposes;
Lumen's partition holds mid-grey at 1e-9 `[docs/26 §4]`.
→ Lumen would need: Lumen has the Luminance and Film-like behaviours as the two ends of its hue ramp
(`DisplayTransform.apply`); no per-channel curve-mode selector (correct per Law 21 / docs/03 §6.9 rule 7).

### A.4 RawTherapee Dynamic Range Compression — `rtengine/tmo_fattal02.cc` `[src: RawTherapee/rtengine/tmo_fattal02.cc]`

Fattal 2002 gradient-domain compression. Controls: **amount** → `beta = 1 − amount·0.3/100`;
**detail/threshold** → `alpha = 1 + threshold·0.9/100` (noise term `alpha·0.01`); **anchor** 1–100 %
(percentile of luminance held fixed: `scale = oldMedian/newMedian` at that percentile); `satcontrol`.
Log luminance `H = log(temp·Y + 1e-4)`, 7-level Gaussian pyramid of gradient magnitudes, attenuation
`Φ = ((|∇|+noise)/(alpha·avgGrad_k))^(beta−1)`, DCT Poisson solve with Neumann boundaries, `L = exp(U)`,
**processing capped at 1920 px** (`RT_dimension_cap`) so preview and export agree. RGB remap per channel by
`l = L/Y·scale`, with `s = l^±0.3` chroma compensation when `satcontrol`. Operates on tone-curve output.
→ Lumen would need: nothing to ship — but the **1920-px cap as a scale-invariance device** is a pattern
Lumen's `DetailEngine.pyramidReferenceLongEdge = 2560` (`DetailEngine.swift:55`) already mirrors.

---

## B · Colour & grading

### B.1 darktable `color balance rgb` — `src/iop/colorbalancergb.c` `[src: darktable/src/iop/colorbalancergb.c]`

Working spaces: pipeline RGB → CIE 2006 LMS D65 → Filmlight **Yrg → Ych** for the linear 4-ways;
**JzAzBz** (2021) or **darktable UCS 22** (v5 `saturation_formula` enum) for perceptual saturation/brilliance.

| Group | Fields | Range | Application (quoted) |
|---|---|---|---|
| 4-way luminance | `global_Y`, `shadows_Y`, `midtones_Y`, `highlights_Y` | −1…+1 | global: `RGB[c] += global[c]` (offset); shadows/highlights: `RGB[c] *= opacities_comp[2]·(opacities_comp[0] + opacities[0]·shadows[c]) + opacities[2]·highlights[c]` (masked **gain**); midtones: `Yrg[0] = pow(max(Yrg[0]/white_fulcrum,0), midtones_Y)·white_fulcrum` (**power about the white fulcrum**) |
| 4-way chroma+hue | `*_C` 0…1, `*_H` 0…360° | | vector offset in the rg chromaticity plane, masked by the same opacities; one-click opponent-colour picker neutralises a cast `[docs/03 §6.1]` |
| chroma | `chroma_global/shadows/midtones/highlights` | −1…+1 | `chroma_factor = max(1 + chroma_global + <opacities,chroma> + vibrance, 0); Ych[1] *= chroma_factor` — **linear, at constant Y** |
| vibrance | `vibrance` | −1…+1 | adds to the chroma factor, weighted toward low chroma `[knowledge]` |
| hue shift | `hue_angle` | −180…180 | rotation matrix on (cos h, sin h) |
| contrast | `contrast` | −1…+1 | `Yrg[0] = grey_fulcrum · pow(Yrg[0]/grey_fulcrum, 1 + contrast)` about `grey_fulcrum` (0…1, default 0.1845) |
| white fulcrum | `white_fulcrum` | −16…16 EV | anchor of the midtone power |
| saturation | `saturation_global/shadows/midtones/highlights` | −1…+1 | perceptual: saturation = `JC[1]/JC[0]` (chroma/brightness); adjustments projected on the saturation eigenvector `T = atan2(JC[1], JC[0])` |
| brilliance | `brilliance_*` | −1…+1 | the orthogonal axis of the same projection: `boosts = {1 + brilliance_global + <op,brilliance>, saturation_global + <op,saturation>}` |
| masks | `shadows_weight`, `highlights_weight` 0…3 (default 1), `mask_grey_fulcrum` 0…1 (0.1845) | | `x_offset = x − fulcrum; alpha = 1/(1+exp(x_offset_norm·shadows_weight)); beta = 1/(1+exp(−x_offset_norm·highlights_weight)); gamma = exp(−x_offset²·midtones_weight/4)·alpha_comp²·beta_comp²·8`; fulcrum pre-warped `pow(p->mask_grey_fulcrum, 0.4101…)`; weights scaled `2 + p·2`; checkerboard-through-output mask preview `[docs/03 §6.1]` |
| gamut | always on | | `Ych[0] = max(Ych[0], 0)`; `gamut_check_Yrg(Ych)` clips chroma at constant hue and Y; JzAzBz path: `max_C` from hue-dependent LUT `lookup_gamut`, `soft_clip(sat, 0.8·max, max)`, and LMS ≥ 0 constraints |

**Definitions the auditor needs:** *chroma* = colourfulness relative to the white (linear, scales with Y);
*saturation* = chroma ÷ brightness (perceptual, constant along a hue leaf); *brilliance* = the axis
orthogonal to saturation in (J, C) — brightens at constant saturation.

**Why dt's luminance stays monotone (the docs/31 r2 #1 question):** every luminance operation is either an
**offset** (global), a **masked multiplicative gain ≥ 0** (shadows/highlights, each mask ∈ [0,1] and the
masks are complementary — `opacities_comp` products keep the gain a convex-ish blend around 1), or a
**power law about a fulcrum** (midtones about `white_fulcrum`, contrast about `grey_fulcrum`), all in
*linear* Yrg — a power is monotone for any exponent > 0 and a gain never crosses. Nothing is applied in a
cube-root/J domain, so no 3× stops leverage appears. Lumen's `GradeEngine` applies the wheels' Luminance as
stops of **perceptual J** (`lumRangeStops 0.5`, `realisedStopsPerJStop 3.0`, `GradeEngine.swift:230-245`)
with per-zone crossfades from `ZoneWindows` — the 3× leverage plus additive zone weights is exactly the
mechanism that folds; dt sidesteps it by staying in linear light for the 4-ways and reserving the perceptual
space for chroma-only moves. `[analysis of fetched code]`
→ Lumen would need: either apply wheel luminance as a masked *gain in linear light* (dt's shape) or keep the
J domain and make `solveLumScale` a hard limiter (docs/31 says `ColorBalanceGrid` has none).

### B.2 darktable `color calibration` — `src/iop/channelmixerrgb.c` `[src: darktable/src/iop/channelmixerrgb.c]`

Params: `illuminant` enum (default `DT_ILLUMINANT_D`; also A, E, F1–F12 via `illum_fluo` (default F3),
LED B1–B5 via `illum_led` (default B5), custom, camera-detected `[knowledge for list]`), `x, y` chromaticity,
`temperature` (TEMP_MIN…TEMP_MAX), `adaptation` enum default **CAT16** (also Bradford full "non-linear" with
luminance-dependent scaling, Bradford linear, XYZ, none), `gamut` compression 0…12, `clip` (default TRUE),
per-channel mixer `red[4] green[4] blue[4]` plus `saturation[4]`, `lightness[4]`, `grey[4]` (−2…2) and
`normalize_*` flags. Adapted white is always **D50** ("we are mandatorily in XYZ"). Illuminant detection:
(a) **surfaces** — B-spline local average, patch-wise variance and chroma covariance, keep stable chromatic
patches; (b) **edges** — `image − blur = laplacian`, Minkowski p-norm; both average in CIE 1960 uv with the
D50 point as origin. Gamut compression: in xyY→uvY, `delta = D50 − uv`, `correction = pow(Delta,
compression)`, move toward white then clip. Requires legacy `white balance` set to "camera reference" —
policed with warning badges `[docs/03 §6.4]`.
Lumen `WhiteBalanceEngine` (`Sources/LumenCore/Engine/WhiteBalanceEngine.swift`): CAT via
`ChromaticAdaptation.adapt(from:to:)` between kelvin/tint chromaticities (clamped, tint ±300), neutral
picker `neutralizing(sample:)` is a mired/tint grid search minimising residual chroma (coarse then ±10 mired
fine).
→ Lumen would need: an image-content illuminant estimator (dt's edge/surface methods) behind "Auto"; an
explicit gamut-compression step for blue-LED failures; a Bradford option is not needed (Law 21).

### B.3 darktable `color zones` — `src/iop/colorzones.c` `[src: darktable/src/iop/colorzones.c]`

LCh. `channel` picks the x-axis (lightness / chroma / hue); three curves (L, C, h) of up to 20 nodes each,
`curve_type` per curve (cubic, Catmull-Rom, monotone Hermite), `strength`, `mode` smooth (v3) / strong (v1).
Application: `L *= 2^(4·(lut_L(sel) − 0.5))`, `C *= 2·lut_C(sel)`, `h += lut_h(sel) − 0.5`; strength:
`value + (value − 0.5)·strength/100`. Presets: "B&W: with red", "B&W: with skin tones", "polarizing filter",
"natural skin tones", "B&W: film", "HSL base setting". Superseded by `color equalizer` (8 fixed nodes +
guided-filter smoothing, docs/03 §6.1).
Lumen `ColorEngine` (`Sources/LumenCore/Engine/ColorEngine.swift:92-147`): 8 bands, anchor 29.23°,
spacing 45°, core 22.5° + feather 15°, OKLab. → Lumen would need: nothing from color zones; the
`color equalizer` influence/change visualisations are the open item (docs/05).

### B.4 RawTherapee colour tools `[src: RawTherapee/rtengine/procparams.h]` (+ `[knowledge]` where marked)

| Tool | Fields | How it works |
|---|---|---|
| Vibrance (`ipvibrance.cc` `[src]`) | `pastels`, `saturated` (%), `psthreshold` (4-point), `protectskins`, `avoidcolorshift`, `pastsattog`, `skintonescurve` | LCh; pastel/saturated split at `limitpastelsatur = (topLeft/100)(1−0.07)+0.07` with `transitionweighting`; chroma `Chprov *= 1 + (pa·sat + pb)·satredu`, limits [−0.93, 2.0] pastels / [−0.93, 1.8] saturated; skin hue window `skbeg −0.05 … skend 1.60` rad with `Color::SkinSat` reducing `satredu`, hue softening `Hc = Hn·0.5 + HH·0.5`, `dhue 0.15`; "avoid colour shift" = `Color::AllMunsellLch` Munsell correction |
| Colour toning | `method` ∈ {Splitlr, Splitco, Splitbal, Lab, Lch, RGBSliders, RGBCurves, LabGrid}; `labgridALow/BLow/AHigh/BHigh`, `labregions` (list of `LabCorrectionRegion` with mask), `strength`, `balance`, `hlColSat`/`shadowsColSat`, `redlow…bluehigh`, `satProtectionThreshold`, `saturatedOpacity`, `lumamode`, `autosat` | LabGrid = two a*b* pickers (shadows/highlights) — the simplest 2-way split-tone in the field; LabRegions = per-region hue/sat/lightness with H/C/L range masks (ART's precursor) `[knowledge]` |
| HSV equalizer | `hcurve`, `scurve`, `vcurve` | three flat curves over hue; classic HSL-by-hue `[knowledge]` |
| L*a*b* adjustments | `brightness`, `contrast`, `chromaticity`, `lcurve/acurve/bcurve/cccurve/chcurve/lhcurve/hhcurve/lccurve/clcurve`, `lcredsk` (restrict red/skin), `rstprotection`, `gamutmunselmethod` | the curve zoo: L, a, b, C(C), C(h), L(h), h(h), L(C), C(L) `[knowledge]` |
| Wavelet levels (`ipwavelet.cc`) | `WaveletParams` in `params/advanced.h` (not fetched) | per-level contrast (up to 9 Daubechies levels D2–D14), chroma per level, edge sharpness, residual tone/contrast, final local contrast, tiling method `[knowledge]` |

→ Lumen would need: `ColorAdjust` (`Recipe.swift:295-299`) has `vibrance`, `saturation`, `density`,
`protectSkin` and `ColorEngine` has a skin line (56.4° ± 10°, `ColorEngine.swift:217-219`) — RT's
skin-hue window and Munsell correction are the two behaviours an auditor can compare; RT's LabGrid is the
minimal split-tone Lumen's wheels already exceed.

---

## C · Film & grain

| Capability | How it works | Source | Lumen |
|---|---|---|---|
| dt `grain` | Lab **L only** (`IOP_CS_LAB`). `scale` (coarseness, shown as ISO 20–6400 via `GRAIN_SCALE_FACTOR 213.2`, default 1600), `strength` 0–100 (25), `midtones_bias` 0–100 (100). Noise = 3 octaves of **simplex noise**, `f = {0.4910, 0.9441, 1.7280}`, `a = {0.2340, 0.7850, 1.2150}`; `zoom = (1 + 8·scale/100)/800` relative to image width (so grain size is image-relative, not print-relative); L gain via a 2-D LUT `grain_lut(noise·strength·GRAIN_LIGHTNESS_STRENGTH_SCALE, L/100)` shaped by a `paper_resp()` exponential from `midtones_bias` that suppresses grain in blacks and whites | `[src: darktable/src/iop/grain.c]` | `FilmGrain` (`RecipeLook.swift:457`: `size` relative pitch, `amount`), `FilmGrainProfile`, `GrainPlan` with `grainPitchMicrons`, `gateLongEdgeMM`, `printSize` anchor (`FilmLab.swift:591,1048,173-177`) — Lumen's grain is print/gate-anchored; dt's is width-relative. Lumen would need: nothing; note dt has no chroma grain either |
| dt `lut 3D` | `filepath`, `colorspace` ∈ {sRGB, Adobe RGB, gamma Rec709, linear Rec709, linear Rec2020, linear ProPhoto}, `interpolation` ∈ {tetrahedral, trilinear, pyramid}; formats **PNG HaldCLUT, .cube, .3dl, .gmz** (G'MIC compressed, `HAVE_GMIC`); `DT_IOP_LUT3D_CLUT_LEVEL 48`, max cube 256; pipeline: work profile → LUT profile → lookup → work profile | `[src: darktable/src/iop/lut3d.c]` | `LUT3D` (`Color/LUT.swift:159`): tetrahedral sampling, `.cube` read/write only, no HaldCLUT/.3dl, no LUT-colourspace tag. Lumen would need: HaldCLUT PNG import + a declared LUT input space if user LUTs ship |
| RT `film simulation` | `clutFilename`, `strength` 0–100; HaldCLUT PNG/TIFF directory, applied in working RGB after tone curve, strength = linear blend `[knowledge]`; RT ships no CLUTs — users download Pat David's "Film Emulation" pack (Creative Commons `[knowledge]`) | `[src: RawTherapee/rtengine/procparams.h]` | as above |
| G'MIC film emulation | ~300 CLUTs (Pat David's set + others) compressed to `.gmz` keypoint form; `fx_emulate_film_*` filters; G'MIC is **CeCILL** (GPL-compatible) — do not bundle `[knowledge]` | | — |
| ART `film negative` | per-channel power inversion `out = refOut · (in/refIn)^(−exp)`, implemented `rmult · pow(in, rexp)` with `rmult = refOut/pow(max(refIn,1), rexp)`; params `redRatio`, `greenExp`, `blueRatio`, `refInput`, `refOutput`, `colorSpace` (INPUT / working), `backCompat` V1/V2; runs on demosaiced `Imagefloat` before colour conversion; two-spot neutral pick derives the exponents (not in fetched excerpt) | `[src: ART/rtengine/filmnegativeproc.cc]` | Lumen has no negative inversion. Would need: an "invert scan" stage before `FilmLab` if scanning is in scope |
| ART `grain` | `ipgrain.cc` fetched: iso→coarseness `LIM01((iso−19)/(6380))·100+0.5`, ISO 20–6400, `strength` split over `nlevels = ceil(3/scale)` pyramid levels as `strength/(nlevels−i)`, optional `color` chrominance grain at half strength; the fetched file delegates to `guidedSmoothing()` after a `ProcParamsOverride` — the noise source itself was not in the excerpt | `[src: ART/rtengine/ipgrain.cc]` (summary suspect — see Could not verify) | Lumen's grain is level-agnostic; ART's per-pyramid-level split is the one idea worth a look |

---

## D · Looks/presets & effects

- **dt styles** = ordered lists of module instances + params + blend params, applied append/overwrite;
  **module presets** per iop (`init_presets`), many auto-applied by camera/ISO match (denoise profiled,
  lens, camera styles since 5.0) `[knowledge]`, `[docs/03 §6.6]`. Diffuse-or-sharpen's 21 presets are the
  proof that a shared engine can ship as named tools (§E.3 below).
- **RT processing profiles** (`.pp3`, INI): bundled "Standard Film Curve — ISO Low/Medium/High", "Neutral",
  "Auto-Matched Curve — ISO Low…"; **partial profiles** (tick which sections to paste); profile copy/paste with
  section filter `[knowledge]`. `crosscheck.py` drives RT with `Standard Film Curve - ISO Low.pp3` `[docs/26]`.
- Effects: dt `vignette`, `framing`, `watermark`, `bloom`, `soften`, `lowlight`, `velvia`, `split-toning`,
  `graduated density`, `retouch` (heal/clone/fill/blur with wavelet scales) `[knowledge]`; RT `vignetting`,
  `graduated filter`, `soft light`, `retinex`, `haze removal`, `film negative` `[src: procparams.h list]`.
→ Lumen would need: `Look` (`RecipeLook.swift:8-19`) has wheels, printer lights, film lab, primaries, B&W,
vignette; no watermark/framing (out of scope by vision); a preset "intensity" slider (RapidRAW, LR) is the
missing generic — grep found none in `LookSubset.swift`.

---

## E · Denoise & sharpening

### E.1 RawTherapee capture sharpening — `rtengine/capturesharpening.cc` `[src]`

Runs **immediately after demosaic on linear camera RGB**, sharpens **luminance** (`RGB2Y`) and rescales RGB
by `YNew/YOld` (hue-neutral by construction). Controls (`CaptureSharpeningParams` `[knowledge for names]`):
`autoContrast` + `contrast` threshold (flat-area mask via `buildBlendMask`), `autoRadius` + `deconvradius`,
`deconvradiusOffset` (corner boost: `sigmaTile = sigma + distanceFactor·distance`), `deconviter`,
`deconvitercheck` (early stop when `tmpIThr < iterCheck` — convergence test per pixel), `noisecap`/`noisecaptype`
(pre-denoise), `showcap` mask view. **Auto radius** (`calcRadiusBayer`/`calcRadiusXtrans`): over the *green*
CFA sites compare adjacent green values at fixed offsets, `maxRatio = maxVal/minVal` on unclipped pairs
(`upperLimit` guard), `sigma = sqrt(1/log(maxRatio))`, capped at `maxSigma`; 3×3 kernel when `sigma < 0.6`
and no corner offset. Deconvolution = Richardson–Lucy with a Gaussian PSF: `gauss*x*div2` then `gauss*x*mult2`
per iteration. dt 5.4 adopted the same thing inside `demosaic` as `cs_enabled`, `cs_radius` 0–1.5 px (0 =
auto "recalculated next run"), `cs_thrs` 0–1 (0.40), `cs_boost` 0–1.5 px corner boost, `cs_center` 0–1,
`cs_iter` 1–25 (8) `[src: darktable/src/iop/demosaic.c]`.
Lumen: `CaptureSharpen` (`Recipe.swift:817-837`: `auto`, `radius?` nil=auto, `amount?`) and
`DetailEngine.captureSharpen` (`DetailEngine.swift:495`) exist and out-recover the manual stage on a known
PSF, but **no shipping build calls it** — dead Radius control `[docs/26 §6]`. → Lumen would need: wire it;
add the flat-area contrast threshold and the corner-boost term; auto-σ must come from CFA greens, which
Apple's `CIRAWFilter` does not expose (see §K) — Lumen's `RawTruth`/LibRaw escape hatch is the route.

### E.2 RawTherapee `sharpening` — `rtengine/ipsharpen.cc` `[src]` (Lab L)

USM: `gaussianBlur(L, radius/scale)`, `delta = threshold.multiply(min(|diff|, upperBound), amount·diff·0.01)`
with a **4-point threshold** (lower start/end, upper start/end on local contrast); `edgesonly` swaps the blur
for a bilateral (`edges_radius`, `edges_tolerance`); **halo control**: local min/max in a 5-px window,
`newL = max + (newL − max)·(100 − halocontrol_amount)/100` (and mirror for min) — i.e. damps the *overshoot
past the local plateau*, which is exactly the fix docs/26 §6 prescribes for Lumen's `haloSuppression`
(currently gated on USM magnitude, delivers zero rim reduction). RL path: `deconvradius/scale` σ,
`deconviter`, `deconvamount` blend, `deconvdamping` with `dampingFac = −2/damping²`,
`U = (O·log(I/O) − I + O)·dampingFac; U = U⁴(5 − 4U); aI = (O − I)/I·U + 1`. Measured: RL 10.9 % overshoot vs
USM 17.1 % at equal recovery `[docs/26 §6]`. `contrast` threshold via `buildBlendMask` on both paths.
Lumen `ManualSharpen` (`Recipe.swift:871-876`: amount 0–150, radius 0.5–3, detail, masking,
haloSuppression). → Lumen would need: re-gate `haloSuppression` on the local min/max plateau (RT's formula).

### E.3 darktable sharpeners

- `sharpen` — `src/iop/sharpen.c` `[src]`: Lab L USM, `radius` 0–99 (2.0, kernel capped `MAXR 12`),
  `amount` 0–2 (0.5), `threshold` 0–100 (0.5): `detail = |diff| > thr ? sign(diff)·(|diff| − thr) : 0;
  out = in + detail·amount` (soft-threshold, not hard gate).
- `diffuse or sharpen` — `src/iop/diffuse.c` `[src]`: anisotropic heat equation across à-trous B-spline
  wavelet scales. Params: `iterations` 0–500 (1), `radius` 0–2048 px (8), `radius_center` 0–1024 (0),
  `sharpness` −1…1, `regularization` 0–4, `variance_threshold` −2…2, `threshold` 0–8 (luminance mask),
  `first..fourth` speed −1…1 (negative = sharpen/inverse heat, positive = blur; 1st/2nd act on low-frequency
  layers, 3rd/4th on high-frequency), `anisotropy_first..fourth` −10…10 (negative = along gradient,
  positive = along isophotes). **Presets and what they set:** lens deblur soft/medium/hard (8/16/24 it,
  radius 8/10/12); dehaze default (10 it, radius 512) / extra contrast (+sharpness 0.007, reg 1.0);
  denoise fine/medium/coarse (32 it, radius_center 2/4/8, radius 1/3/6); surface blur (2 it, r 32, all
  speeds +1, high anisotropy); bloom (1 it, r 32, +0.5 isotropic); simulate watercolor (4 it, r 64);
  simulate line drawing (50 it, r 64, all −1, aniso −5); sharpen demosaicing no-AA (r 4) / AA (r 8);
  local contrast normal (10 it, centre 512, r 384) / fine (5 it, r 170) / fast (1 it, 512/512); inpaint
  highlights (32 it, r 4, 4th +0.5, threshold 1.41); sharpness fast (1 it, r 128, 3rd −0.5) / normal
  (3 it, r 3) / strong (6 it, r 3, reg 2.15). The docs admit users "are likely to be overwhelmed"
  `[docs/03 §6.3]`.
→ Lumen would need: nothing from the maths; the preset table above is the calibration reference for
  Lumen's texture/clarity/dehaze/sharpen radii (`DetailEngine` uses 5 à-trous levels, `waveletLevels = 5`,
  `clarityDetailEV 0.7`, `clarityMidtoneEV 3.0`, `DetailEngine.swift:47-103`).

### E.4 Local contrast

- dt `local contrast` — `src/iop/bilat.c` `[src]`: Lab; `mode` bilateral grid / **local laplacian**
  (default); bilateral: `sigma_s` (feature size), `sigma_r` (L edge difference); local laplacian: `detail`
  −1…4 (0.25), `midtone` 0.001–1 (0.5, "lower for more dynamic-range compression, raise for stronger local
  contrast"), highlights/shadows compression reuse `sigma_r`/`sigma_s`; `local_laplacian(in, out, w, h,
  midtone, sigma_s, sigma_r, detail, 0)` (Paris–Hasinoff–Kautz fast local Laplacian in `locallaplacian.c`
  `[knowledge]`).
- RT `local contrast` — `rtengine/iplocalcontrast.cc` `[src]`: Lab L, `gaussianBlur(L, radius/scale)`,
  `v = (L − blur)·amount; v *= v > 0 ? lightness : darkness; L = LIM(L + v, 1e-4, 32767)` — a
  single-scale USM with separate up/down gains. `LocalContrastParams: radius (int), amount, darkness, lightness`.
→ Lumen: `applyClarity` is a wavelet/guided decomposition (`DetailEngine.swift:341`); the RT "darkness /
lightness" asymmetry is the one control Lumen lacks and C1 also exposes (docs/03 §1.6).

### E.5 Denoise

| Tool | Parameters | Algorithm | Adopt? |
|---|---|---|---|
| dt `denoise (profiled)` `[src: denoiseprofile.c]` | `mode` ∈ {nlmeans, nlmeans auto, wavelets, **wavelets auto**, variance(debug)}; `wavelet_color_mode` RGB / **Y0U0V0**; `radius` 0–12 (1) patch, `nbhood` 1–30 (7) search, `strength` 0.001–1000 (1), `shadows` 0–1.8 (1), `bias` −1000…100 (0), `scattering` 0–20 (0), `central_pixel_weight` 0–10 (0.1), `overshooting` (1), per-channel wavelet curves `x/y[4][7]`, `a[3] b[3]` profile (a[0] = −1 → auto from EXIF), flags `wb_adaptive_anscombe`, `fix_anscombe_and_nlmeans_norm`, `use_new_vst`, `compensate_hilite_pres` | Noise model `V(X) = a·(E[X]+b)^p`; VST: legacy GAT `2·sqrt(x/a + (b/a)² + 3/8)` (inverse uses 1/8), v2 `f(x) = 2(x+b)^(1−p/2)/(√a(2−p))` with a bias-corrected quadratic inverse `z = (x + sqrt(x² + bias))/denom`. NLM: patch (2P+1)², search K (K ≤ 3 on preview/fast pipes), norm `0.045/(2P+1)²`, scattering `maxk = (K³ + 7K√K)·scattering/6 + K`. Wavelets: à trous `{1,4,6,4,1}/16`, ≤ 7 bands, `σ_band = (√2.5)^scale`, BayesShrink `thr = adj·σ²/std_x` with `adj *= (4·force²)` from the curves. **Y0U0V0**: `Y0 = WB-weighted mean/√3`, `U0 = 0.5(R−B)/σ_U0`, `V0 = (0.25R − 0.5G + 0.25B)/σ_V0`, ×2.5 strength compensation. Profiles from `noiseprofiles.json` (GPL data — do not bundle, docs/17) | **Design yes, code no (GPL).** Lumen already has the same skeleton: `NoiseProfile(a,b)` + `forISO` + block estimator, `VST.forward/inverse`, `ClassicalDenoise` with `toY0U0V0`, 5–6 à-trous levels, `atrousDetailSigma`, BayesShrink-style `lumaThresholds` (`DenoiseEngine.swift:39-892`). Missing vs dt: NLM branch, `scattering`, `shadows`/`bias` compensation, per-camera profile DB |
| dt `raw denoise` `[src: rawdenoise.c]` | `threshold` 0–1 (0.01), curves `x/y[4][5]` for all/R/G/B | DWT (5 scales) on each CFA colour (R, G1, B, G2) separately, `sqrt` VST, `noise[i] = noise_all[i]·all⁴·chan⁴·16·16·threshold` | Behaviour only; Lumen's `hotPixels` + `ClassicNR` run post-demosaic — a CFA-domain pass needs the LibRaw path |
| dt `astrophoto denoise` `[src: nlmeans.c]` | `radius` 0–10 (2), `strength` 0–100000 (50), `luma` 0–1 (0.5), `chroma` 0–1 (1.0) | Lab NLM, `P = ceil(radius·scale)`, `K = ceil(7·scale)`, norm `{1/120², 1/512², 1/512²}`, output blend `{luma, chroma, chroma}` | No — superseded by profiled |
| dt 5.6 AI (`darktable-ai`) | tasks mask/denoise/rawdenoise/upscale, one model per task, ONNX + Core ML on macOS | `[docs/03 §6.5]` | Pattern adopted already (docs/07) |
| RT `noise reduction` `[src: FTblockDN.cc]` | `DirPyrDenoiseParams`: `luma`, `Ldetail`, `chroma`, `redchro`, `bluechro`, `gamma`, `Lmethod` SLI/CUR (+`lcurve`), `Cmethod` MAN/AUT/PRE/PON, `C2method`, `smethod` (shrink all / "shal"), `medmethod` 3×3 soft/3×3 strong/5×5 soft/5×5 strong/7×7/9×9, `methodmed` Lonly/Lab/ab/Lpab/RGB, `passes`, `enhance`, `rgbmethod`, `dmethod` | Lab (or RGB) with gamma pre-transform (`gamthresh 0.001`, non-raw gamma pulled toward 0.7); luminance wavelets 5–8 levels (+`nrwavlevel` in enhanced), `noisevarL = ((luma/125)(1 + luma/25))²`; **Ldetail** = DCT block detail recovery, `TS 64`, offset 25, `noisevar_Ldetail = (((100−Ld)² + 50(100−Ld))·TS·0.5)²`; chroma auto = MAD of wavelet coefficients `/0.6745`, `PON` tiles, `PRE` preview with `ponderCC 0.5`; enhanced = BiShrink then standard shrink; median passes as separate impulse stage | Behaviour only. RT's **Ldetail** (DCT texture restore) and **auto multi-zone chroma** are the two ideas absent from Lumen's `ClassicNR` (`lumaDetail`, `lumaContrast`, `colorDetail`, `colorSmoothness`, `hotPixels`, `DenoiseEngine.swift:410-424`) |

Licence flag: every row above is GPL-3.0. The only adoptable *code* would be the maths that is textbook
(Anscombe/GAT, à trous, BayesShrink, RL) — Lumen has already re-derived these.

---

## F · Masks

### F.1 darktable drawn masks — `src/develop/masks/*.c` `[src: circle.c, gradient.c]`, `[knowledge]` for path/brush/ellipse

| Shape | Create/edit grammar | Scroll (creation and edit) | Notes |
|---|---|---|---|
| circle | click = place at conf size; drag centre = move; drag rim = (clone source) | **scroll = size** (`dt_masks_change_size`, toast "size: %3.2f%%"), **⇧scroll = feather** ("feather size"), **⌃scroll = opacity ±0.05** (edit only) | `MIN_CIRCLE_RADIUS 0.0005`, `MIN_CIRCLE_BORDER 0.0005`, max 1.0 (0.5 for clone); conf keys `plugins/darkroom/spots/circle_size` / `circle_border`; right-click = delete shape (edit) or leave continuous-creation (create); ⇧/⇧⌃-click sets clone source |
| ellipse | as circle + rotate handles; ⇧scroll feather, ⌃scroll opacity; ⇧⌃scroll rotation `[knowledge]` | | proportional vs equidistant feather toggle `[knowledge]` |
| gradient | click-drag sets line + direction; drag anchor = move; ⌃-drag anywhere or pivot handle = rotate; double-click resets curvature | **scroll = curvature ±0.01 (−2…2, shown ×50 as %)**, **⇧scroll = compression ×1/0.8 (0.001–1)**, **⌃scroll = opacity ±0.05** | curvature bends the line parabolically |
| path (Bézier) | click nodes, ⌃-click for sharp node, ⇧-drag feather handles; scroll = size, ⇧scroll = feather, ⌃scroll = opacity `[knowledge]` | | nodes have independent feather handles |
| brush | paint; scroll = size, ⇧scroll = hardness, ⌃scroll = opacity; pressure → size/hardness/opacity by conf `[knowledge]` | | stored as stroke polylines with per-node size/hardness |

Mask **groups**: per shape `union / intersection / difference / exclusion` state and invert; masks are
first-class in the history stack (`dt_dev_add_masks_history_item`); **mask manager** lists all shapes for
reuse across modules. All coordinates are normalised to image width/height (`center = pts/iwidth`), so masks
survive scale but are defined **before** geometry modules in raw coordinates — dt handles this with
`distort_transform` hooks per module `[knowledge]` (ART merely documents the trap, docs/03 §6.7).
Lumen (`Sources/LumenApp/MaskCanvas.swift:74-92, 358-362`): `[`/`]` size ×1.15 geometric, `⇧[`/`⇧]` feather
±10 linear, radial rim drag = resize, inner ring = feather, "just outside" = rotate; no scroll-on-canvas
grammar for size/feather/opacity. → Lumen would need: scroll / ⇧scroll / ⌃scroll on a hovered mask (dt's
exact triple) and a curvature control on the linear gradient.

### F.2 darktable parametric + raster — `src/develop/blend.h` `[src]`

`dt_develop_blend_params_t`: `mask_mode` (off / uniform / drawn / parametric / raster, combinable),
`blend_cst` (RAW / Lab / RGB display / **RGB scene**), `blend_mode` (normal, lighten, darken, multiply,
average, add, subtract, difference, screen, overlay, softlight, hardlight, vividlight, linearlight, pinlight,
lightness, chroma, hue, colour, HSV lightness/colour, RGB R/G/B, divide, geometric mean, harmonic mean +
reverse flag), `blend_parameter` (fulcrum), `opacity`, `mask_combine` ∈ {NORM, INV, EXCL, INCL, MASKS_POS},
`mask_id`, **`feathering_radius` (guided-filter feathering) with `feathering_guide` ∈ {output before blur,
input before blur, output after blur, input after blur}**, `blur_radius`, `contrast`, `brightness`,
`details` (detail-threshold mask from the demosaic high-pass), `blendif` flags, `blendif_parameters[4·N]`
= **four-point ramps (lower start/end, upper start/end)** per channel, `blendif_boost_factors`,
`raster_mask_source/instance/id`, `raster_mask_invert`. Channels: Lab `L a b C h`; scene RGB
`gray R G B Jz Cz hz` — each on **input and output** of the module. Any module's final mask can be reused
as a raster mask by any later module.
Lumen `MaskComponent` (`RecipeMasks.swift:392-…`): kinds linear/radial/brush/lumaRange/luminosity/polygon/
colorRange/similarity/depthRange/ai*/maskRef; `lo/hi/smooth` for ranges, `feather`, `invert`, `amount`,
`op` add/subtract/intersect (`MaskRaster.swift:214-216`), `MaskRefine`, `maskRef` (raster reuse, depth
limit 8). → Lumen would need: dt's four-point ramp is richer than `lo/hi/smooth` (asymmetric feather);
input-vs-output channel choice; `details` mask; blend modes beyond normal (grep found none in `MaskBlend`).

### F.3 RawTherapee local adjustments — `rtengine/params/locallab.h` `[src]`

`LocallabSpot`: `shape` ELI/RECT, `spotMethod` **norm / exc (excluding spot) / full**, `shapeMethod`
IND/SYM/INDSL/SYMSL (independent vs symmetric handles, ±sliders), geometry `locX/locXL/locY/locYT`
(four half-axes), `centerX/Y`, `circrad` (reference circle radius for the ΔE sample), `transit` (transition
%), `feather`, `transitweak`, `transitgrad`, `thresh`, `iter`, `balan`/`balanh` (ΔE weight of L vs ab, and
hue), `colorde`, `colorscope`, `sensiexclu`/`structexclu` (excluding-spot scope and structure), `struc`,
`qualityMethod`, `complexMethod` (basic/standard/advanced UI tiers), `wavMethod` D2…D14, `avoidgamutMethod`
NONE/LAB/XYZ, `deltae`, `laplac`, `recurs`, `scopemask`, `lumask`, `denoichmask`. Per sub-tool a **`sensi*`
scope** (ΔE range around the reference sample): `sensi` colour, `sensiex` exposure, `sensihs` S/H, `sensiv`
vibrance, `sensisf` soft light, `sensibn` blur/noise, `sensilc` local contrast, `sensicb` CBDL, `sensilog`
log, `sensimask`, `sensicie`. Tool flags: `expcolor, expexpose, expshadhigh, expvibrance, expsoft, expblur,
exptonemap, expreti, expsharp, expcontrast, expcbdl, expdenoi, explog, expmask, expcie`. The RT disease in
one struct (docs/03 §6.7). ART's 4-tools × 4-mask-types algebra is the cure (docs/03 §6.7).
→ Lumen would need: nothing from RT; Lumen's `similarity` component with `chromaSel`/`lumaSel`
(`RecipeMasks.swift`) is ART's ΔE weight-pair — auditors should confirm both weights are exposed in `MaskPanel`.

---

## G · UI/UX lessons

- **dt module groups**: darkroom right panel = tabs (active / favourites / technical / grading / effects,
  user-editable via "manage module layouts" presets), a search box, and the **quick access panel** (5.x): a
  user-curated flat list of individual widgets from any module ("basic adjustments" style) `[knowledge]`,
  `[docs/03 §6.6]`. Module header: on/off, presets, reset, multi-instance menu, mask indicator icon.
- **Keys**: dt 4.x "shortcuts" system binds *any* widget to key/mouse/MIDI with modifiers and speed
  scales; default darkroom keys are sparse (Tab hides panels, `L` lighttable, `1–5` rating, `F1–5` colour
  labels, `ctrl+z/y`, `alt+1` 100 %, `alt+2` fill, `alt+3` fit, `ctrl+b` borders) `[knowledge]`. Scroll on
  a hovered slider adjusts it; scroll on a mask on canvas resizes; scroll on thumbnails rates in some
  configs — the "interaction inconsistency compounding" anti-pattern `[docs/03 §6.9 #6]`.
- **RT tool panels**: fixed tabs Exposure / Detail / Color / Advanced / Locallab / Transform / Raw /
  Metadata, each a vertical stack of collapsible tools with a power button; every disagreement became a
  method dropdown `[docs/03 §6.7]`. Keys: `w` (before/after), `z` zoom, `f` fit, `1` 100 %, `i` info,
  `shift+f/e` favourites `[knowledge]`.
- **Do not copy**: four tone mappers; ~95 module pages; math-named sliders; per-module scroll dialects;
  warnings as correctness policing; complexity tiers via config keys (AgX 3-tab mode) — catalog in
  `[docs/03 §6.9]`. **Do copy**: dt's *mask indicator on the module header*, its checkerboard-through-output
  mask preview, colour-balance-rgb's opponent-colour picker, tone equalizer's hover-zone + scroll-to-dodge,
  RT's before/after `w` toggle and its per-tool "show mask" buttons.
→ Lumen: `KeyGrammar.swift` / `Keymap.swift` already encode one grammar; auditors should check the
 scroll-on-slider and scroll-on-mask behaviours are consistent per Law 19/20.

## H · Viewer & scopes

dt: histogram / waveform (horizontal, vertical) / RGB parade / **vectorscope in Luv, JzAzBz or RYB**, with
linear/log scale toggles and raw over/under-exposure indicators; navigator thumbnail; colour assessment
(ISO 12646 grey surround, `ctrl+b`); "second window" `[knowledge]`. RT: histogram (RGB/L/chroma/**raw**),
navigator with pixel readout in RGB/HSV/Lab, clipping indicators; preview "only exact at 100 %"
`[docs/03 §6.9 #8]`. → Lumen `ScopesView`/`Scopes.swift` are achromatic by Law 7; nothing to add from here
except the vectorscope space choice (dt's JzAzBz option) as a comparison point.

## I · Pipeline & performance

dt: fixed module order (v3.0 scene-referred order), CPU (OpenMP + SSE) and OpenCL paths per module,
region-of-interest pipeline with per-module input/output caches, preview pipe at reduced size + full pipe
for the visible ROI, "high quality processing" toggle for export `[knowledge]`; Ansel's benchmarks show the
GUI-side leakage: mid-pipeline change 5.4–40× faster with downstream-only recompute `[docs/03 §6.8]`.
RT: CPU only (OpenMP, SSE), tiled processing for FFT tools (Fattal cap 1920 px), no GPU; "fast export"
uses a downscaled pipeline `[knowledge]`. vkdt: everything on GPU, DAG with feedback connectors,
textures never leave VRAM `[src: hanatos/vkdt/readme.md]`. → Lumen already adopts Ansel's three rules
(`RenderCoordinator`, `PlanTableCache`); the dt lesson to *test* is scale-invariant preview (§H).

## J · Library/culling/export/ingest

dt lighttable: collections by any metadata, filmstrip, culling mode with fixed/dynamic layout, ratings
`0–5` + reject, colour labels, tags with hierarchy, styles-on-export, export presets with per-format
options and "high quality resampling" `[knowledge]`. RT: file browser with filters, no catalog, batch
queue, sidecar-only `[knowledge]`. Not the strength of either; docs/03 §5 (Photo Mechanic, FRV) governs.

## K · Crop/lens/geometry — and raw decode

| Stage | darktable | RawTherapee | Lumen (Apple `CIRAWFilter`) |
|---|---|---|---|
| Demosaic (Bayer) | `demosaic.c` `[src]`: PPG, **AMaZE**, VNG4, **RCD** (default), LMMSE (+`lmmse_refine` basic/median/3×median/refine&medians/2×refine+medians), **RCD (dual)**, **AMaZE (dual)**, passthrough mono/colour, Monochrome; `dual_thrs` 0–1 (0.2); `green_eq` off/local/full/both; `median_thrs`; `color_smoothing` 1–5 passes | `params/raw.h` `[src]`: AMAZE, AMAZEBILINEAR, AMAZEVNG4, RCD, RCDBILINEAR, RCDVNG4, DCB, DCBBILINEAR, DCBVNG4, LMMSE, IGV, AHD, EAHD, HPHD, VNG4, FAST, MONO, PIXELSHIFT, NONE; `dcb_iterations`, `dcb_enhance`, `lmmse_iterations`, `dualDemosaicAutoContrast`/`dualDemosaicContrast`; `ccSteps` (false-colour suppression), `twogreen`, `linenoise` H/V/both/PDAF, `greenthresh`, `pdafLinesFilter`, `border` | Apple's own (undocumented) demosaic; `draft` decode is a lower-quality demosaic (`RenderCoordinator.swift:197`). **Cannot match:** algorithm choice, dual blending, green equilibration, false-colour steps |
| Dual demosaic | blend mask from luminance contrast `buildBlendMask(L, contrast/100, autoContrast)`, `out = intp(blend, detail, flat)` — detail = AMaZE/RCD/DCB, flat = VNG4/bilinear `[src: dual_demosaic_RT.cc]` (dt copied) | same | — |
| X-Trans | VNG, Markesteijn 1-pass / 3-pass, FDC, Markesteijn 3-pass (dual), passthroughs | FOUR_PASS, THREE_PASS, TWO_PASS, ONE_PASS, FAST, MONO, NONE | Apple's |
| Hot/dead pixels | `hotpixels.c`: threshold + strength, "detect by 3 neighbours" `[knowledge]` | `hotPixelFilter`, `deadPixelFilter`, `hotdeadpix_thresh` | `ClassicNR.hotPixels` post-demosaic (`DetailPanel.swift:500`) — could match |
| CA (raw) | `cacorrect.c`: RT's algorithm ported, `iterations`, avoid colour shift `[knowledge]` | `CA_correct_RT.cc` `[src]`: tiles `ts 128`, `border 8`; per-block R/B shift vs G minimising colour-difference variance; **2-D polynomial fit `polyord 4, numpar 16`** (falls to linear `polyord 2` if `numblox < 32`); `caautoiterations`; `ca_avoidcolourshift` (blurred per-pixel correction factors reapplied); manual `cared/cablue` = `2·vfrac·cared`; bilinear R/B resampling at shifted positions | `LensCorrections.removeCA` (`Recipe.swift:1325`) → Apple's lens-profile CA only; **cannot** do auto CA on the CFA; `Defringe` (purple/green amount + hue windows) is the Lab-domain fallback (= RT `Defringe`/dt `defringe`) |
| Flat field / dark frame | `flatfield` not in dt core (only via LUT/"lens" vignetting) `[knowledge]` | `ff_file`, `ff_AutoSelect`, `ff_FromMetaData`, `ff_BlurRadius`, `ff_BlurType` AREA/V/H/VH, `ff_AutoClipControl`, `ff_clipControl`; `dark_frame`, `df_autoselect` | absent; only reachable via the LibRaw escape hatch (docs/17 `RawSource`) |
| Highlight reconstruction | `highlights.c`: clip / **inpaint opposed** (default) / segmentation / guided laplacians / LCh `[knowledge]` | `method` Luminance / CIELab / Colour propagation / Inpaint Opposed; `hlbl`, `hlth` | Apple's; RT's Inpaint-Opposed is docs/03's chosen invisible default |
| Lens / geometry | `lens` (lensfun), `rotate and perspective` (auto line detection, keystone), `crop`, `flip`, `liquify`, `retouch` `[knowledge]` | lensfun / LCP, `distortion`, `perspective` (auto from Hough lines, camera-based), `rotate`, `crop` with guides, `resize` | `CropPanel`, `LensCorrections.profile` (Apple) — no auto-keystone from lines |
| Capture sharpen at demosaic | dt 5.4 `cs_*` in demosaic (see §E.1) | RT capture sharpening | dead control (§E.1) |

**What Lumen could match without LibRaw:** hot-pixel, defringe, dual-decode "draft/full" ladder (already),
capture sharpening on Apple's demosaiced output with σ estimated from the demosaiced greens (looser than CFA
greens). **What needs the LibRaw/`RawTruth` path:** demosaic choice, CFA-domain auto-σ, auto CA, flat/dark
frames, raw denoise, green equilibration.

## L · State/undo

dt: history stack is the document — every module change appends an item (params + blend params + mask
state), "compress history", snapshots with split overlay, `ctrl+z/y` `[knowledge]`. RT: per-image history
list with bookmarks ("snapshots"), undo by clicking any row `[knowledge]`. Both persist history in the
sidecar (§M). → Lumen `HistoryStack.swift` exists; the dt property to check is that **masks are history
items** (`dt_dev_add_masks_history_item` `[src: circle.c]`).

## M · Recipe/serialization/sidecars

- dt XMP: `darktable:history` = `rdf:Seq` of items with `operation`, `enabled`, `modversion`, **`params` as
  hex-encoded packed C struct** (the fragility `crosscheck.py` tripwires), `blendop_params` likewise,
  `multi_name`, `multi_priority`; `darktable:masks_history`; `darktable:iop_order_version`/`iop_order_list`;
  `xmp_version` (5 in `crosscheck.py`) `[src: scripts/baselines/crosscheck.py]`, `[knowledge]`. Versioned
  by `modversion` with per-module `legacy_params` migration.
- RT `.pp3`: INI sections `[Exposure] Compensation=1.0`, `[Dehaze] Enabled/Strength`, `[Sharpening]`… with
  `Version=` and per-key defaults; partial profiles; ART `.arp` same family `[src: crosscheck.py]`, `[knowledge]`.
- RapidRAW `.rrdata` JSON sidecar `[src: RapidRAW/README.md]`.
→ Lumen `Recipe` (`CanonicalJSON`, `Fingerprint`, `RecipeDecoding`) — text JSON with explicit field
names is already the better design; the dt lesson is **migration by version per sub-struct**, which
`RecipeDecoding.swift` should be checked for.

---

## vkdt / ART / RapidRAW — one paragraph each

**vkdt** `[src: hanatos/vkdt/readme.md]`: darktable's original author's rewrite as a **Vulkan processing
node graph** — every module is GLSL, the whole pipeline lives in VRAM and the GUI draws textures without
readback; the DAG has feedback connectors for animation/iteration, native GPU decoders for Magic Lantern
MLV and MotionCam raw video, and U-Net denoising "using fast schedules" (jddcnn: joint demosaic+denoise,
ONNX→SPIR-V, docs/03 §6.8). BSD-2 core with GPLv3 parts (rawspeed, ffmpeg); macOS Apple Silicon is a
supported target; 4–8 GB VRAM recommended for 50 MP+. Novel for Lumen: proof that full-res interactive is a
data-residency problem, and the only permissive-core engine on the shelf.

**ART** `[docs/03 §6.7]`, `[src: ART/rtengine/filmnegativeproc.cc, ipgrain.cc]`: RT's engine with the tool
count halved, local editing rebuilt as layers with exactly four mask types (parametric HCL curves, ΔE with
value+weight pairs, area shapes with add/subtract/intersect, brush) and deterministic combination; film
negative as a per-channel power inversion calibrated from picked spots; grain split across pyramid levels;
Tone EQ 5 bands + pivot, Log Tone Mapping. Novel: the controlled experiment showing ~45 tools lose nothing.

**RapidRAW** `[src: CyberTimon/RapidRAW/README.md]`: Tauri + React + Rust + WGPU/WGSL, <20 MB installer,
Windows/macOS/Linux/Android; AgX tone mapping, luma/RGB/parametric curves, AI masks (SAM 2, U-2-Net,
Depth Anything V2) with stacking and blend modes, denoise (BM3D, NIND, luma/colour NR), LaMa inpainting,
HDR merge with deghosting, GPU panorama, focus stacking, Spektrafilm LUT film emulation, gphoto2 tethering
(2,500+ cameras), presets with intensity, `.rrdata` sidecars, CLI batch/headless; changelog 2026-09-01
"guided perspective correction". AGPL-3.0 — architecture lessons only. Novel: the cadence, and *preset
intensity* + *mask blend modes* as cheap wins Lumen lacks.

---

## New relative to docs/02–03

- Full **sigmoid param struct with ranges/defaults** and the exact meaning of `hue_preservation` (mid-channel
  interpolation preserving channel sum), plus the field-by-field map onto Lumen's `DisplayTransformParams`
  — including that `whiteAnchorEV/blackAnchorEV` are filmic's, not sigmoid's.
- **filmic rgb** internals: 5-node spline, three curve types, six norm modes, `auto_hardness`.
- **color balance rgb**: verbatim application lines (global = offset; shadows/highlights = masked gain;
  midtones = power about white fulcrum; contrast = power about grey fulcrum; chroma linear at constant Y;
  saturation/brilliance = eigenvector projection) and the sigmoid mask formulas with weights `2 + 2p` and
  fulcrum warp `^0.4101` — and the resulting answer to the docs/31 luminance-inversion question.
- **color calibration**: the two illuminant detectors (surfaces / edges) and the uv-space gamut compression.
- **RT tone-curve mode maths** (weighted-std 50/25/25, film-like median interpolation, luminance ratio,
  perceptual CIECAM02 compensation) and **Fattal DRC** constants (`beta = 1 − 0.3·amount`, `alpha = 1 +
  0.9·thr`, 7 levels, 1920-px cap, percentile anchor).
- **Capture sharpening auto-σ formula** `sqrt(1/log(maxRatio))` on unclipped green pairs; luminance-only with
  RGB rescale; iteration early-stop; dt 5.4's `cs_*` field set.
- **RT halo control = plateau-relative damping** (`newL = max + (newL − max)·(1 − hc)`), the mechanism
  docs/26 §6 says Lumen's `haloSuppression` needs; RL damping formula.
- **diffuse.c preset table with numeric values** (iterations/radius per preset).
- **denoise profiled**: both VSTs with constants, NLM norm and scattering formula, à-trous taps, 7 bands,
  BayesShrink threshold, Y0U0V0 definition — and the finding that Lumen's `DenoiseEngine` already mirrors the
  skeleton; RT's `Ldetail` DCT recovery (`TS 64`, offset 25) and MAD auto-chroma.
- **Haze**: dt 95th/95th percentile airlight, `t = 1 − strength·min(I/A0)`, guided filter `eps = sqrt(0.025)`,
  `t_min = exp(−distance·distance_max)`, no sky protection; RT `t0`, `tl` clamps, luminance mode, saturation
  blend for blue cast.
- **Masks**: dt scroll triple (size / ⇧feather / ⌃opacity ±0.05) and gradient curvature/compression
  increments; `blend.h` field inventory (feathering guide modes, four-point ramps, `details` mask, raster
  source); RT `LocallabSpot` full field list and per-tool `sensi*` scopes.
- **Raw**: complete dt/RT demosaic method enums; RT auto-CA tile/polynomial constants (128/8, order 4/16
  params); flat-field/dark-frame field set; RT X-Trans pass list.
- grain (dt): simplex octave constants and width-relative sizing; lut3d formats and spaces; ART film-negative
  inversion formula.

## Could not verify

- RT `CaptureSharpeningParams` field names (struct lives in `params/*.h` not fetched; names inferred from
  usage in `capturesharpening.cc`).
- RT `WaveletParams` (`params/advanced.h`) and the colour-toning method internals — listed from
  `procparams.h` names and `[knowledge]`.
- ART `ipgrain.cc`: the summariser reported no noise generator in the file (delegation to `guidedSmoothing`);
  the actual grain synthesis may live elsewhere — treat the ART grain row as partial.
- ART film negative two-spot calibration (function present, maths not in the excerpt); its pipeline stage.
- dt ellipse/path/brush scroll modifiers and the shortcuts list — `[knowledge]` only (circle and gradient
  were fetched).
- dt `hotpixels.c`, `cacorrect.c`, `highlights.c`, `locallaplacian.c` internals — `[knowledge]`.
- G'MIC film emulation CLUT count/licence — `[knowledge]`.
- The exact `opacities_comp` algebra in `colorbalancergb.c` that keeps the masked gain ≥ 0 — quoted line is
  verbatim, the monotonicity argument is my analysis.
- `docs.darktable.org` and `rawpedia` were not attempted (blocked per common brief); GitHub raw was the sole
  primary source. RT param headers moved to `rtengine/params/*.h` on `dev` — `raw.h` and `locallab.h`
  fetched, others not.
