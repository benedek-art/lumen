# WS-28 Lens corrections: auditor report (removeCA, Defringe)

Auditor: independent of the builder. The measurement tool shares no code with LumenCore or
with the builder's lens stage. It uses numpy, plus Pillow for reading PNGs.
Branch `quality/c3-lens`, Linux, CPU only. Date 2026-10-21.

## 0. What was audited

`develop.geometry.lens.removeCA` (Bool, default true) and `develop.geometry.lens.defringe`
(purple/green amount 0-20, hue lo/hi 30/70 and 40/60) are saved in the recipe, but on the base
commit (`9068ded`) nothing renders them. Lateral CA and fringes therefore pass through to the
output untouched. LibRaw applies no lens corrections, so the native decodes below show the
uncorrected lens.

## 1. Inputs

Native-resolution decodes (`--long-edge 0`, no downsample), in `corpus/lfi-native/`:

| id | camera | size | half-diagonal px | note |
|---|---|---|---|---|
| 1840 | Nikon D850 | 8256x5504 | 4961 | treeline vs clear sky, ISO 64, render is dark (mean Y code ~0.14) |
| 4213 | Nikon Z 7II | 8256x5504 | 4961 | castle (near centre, r < 0.3), treeline vs flat overcast sky |
| 6929 | Sony A7 IV | 7008x4672 | 4211 | foliage against bright, partly clipped sky (0.40 % clipped) |
| 2545 | Panasonic GX85 | 4592x3448 | 2871 | lawn, trees, blue sky |
| 3437 | Canon T7i | 6024x4020 | 3621 | meadow, oaks, sky |
| 6001 | Fujifilm X-H2 (X-Trans) | 5149x7728 | 4643 | flower bed, sky. X-Trans demosaic false colour, so read with care |

Command: `python3 scripts/proof/decode_raw.py corpus/raw/<f> corpus/lfi-native/<name>.lfi --long-edge 0`

Baseline renders: `lumen-render render --input corpus/lfi-native/<n>.lfi --long-edge 0 --no-dither
--as-shot-kelvin K --as-shot-tint T --iso I --out /tmp/claude-0/audit/render_<n>.png`, with K/T/I
taken from the sidecar `recipe_hint`. These used the binary built at 01:39 UTC, which had no
lens stage: `LensStage.swift` was first written at 01:50 and its object file at 01:54, and all
renders finished between 01:45 and 01:51. Identity check against the new binary: the 2545
render with `--set develop.geometry.lens.removeCA=false --set develop.geometry.lens.profile=false`
on the rebuilt binary (01:54) is **byte-identical** (`cmp`) to the baseline PNG. So the new
stage is an exact no-op when switched off, for 2545 at least. All new comparisons must pass
those two flags for "before".

## 2. The tool: `tools/fringe_metrics.py`

```
python3 docs/quality/lanes/WS-28/tools/fringe_metrics.py IMAGE(.lfi|.png) --out m.json
python3 docs/quality/lanes/WS-28/tools/fringe_metrics.py --compare BEFORE AFTER [--out c.json]
python3 docs/quality/lanes/WS-28/tools/fringe_metrics.py --selftest --out selftest.json
#   options: --fringe-threshold 0.03 (OKLab ab), --max-edges 25000 (per zone), --seed 1234
#   BEFORE/AFTER may be PNGs, LFIs, or JSONs written by this tool. PNG ~20-30 s at 45 MP.
```

The full method is in the docstring. In short:

**(a) Lateral misregistration.** Edges come from non-maximum-suppressed Sobel on smoothed
log2 G, kept when the gradient is >= 0.25 stop/px and the gradient direction is within 25° of
radial. Each channel is sampled along the radial direction (bilinear, t in ±10 px, step 0.1)
and normalised to a 0..1 step using its own ends. The shift d in ±4 px minimises the SSD
between C(t) and G(t-d) over |t| <= 5, refined with a parabola. Rejected: clipped profiles,
channel steps under 0.5 stop or under 1 stop for G, a minimum at the search boundary, a
residual over 0.01, and multi-edge profiles. Output per zone (r normalised to the half-diagonal:
0-0.3, 0.3-0.6, 0.6-0.8, 0.8-1.0): median shift and MAD. Also a robust fit
shift(r) = k1·r + k3·r³, evaluated at r = 0.5/0.75/1.0. Sign: **+ = channel displaced outward
(magnified) relative to G.**

**(b) Fringe width.** Edges come from NMS on log2 Y. The profile runs along the gradient,
±10 px in steps of 0.5. An edge is kept only when its contrast is >= 1.5 stops and both sides
are flat (std of log2 Y <= 0.25). The fringe-free prediction is the linear-light mix of the two
sides at the measured luminance, which is exact for any PSF that is identical in all channels.
Excess is the OKLab ab distance between the measured pixel and that prediction. Width is the
number of px within |t| <= 6 where the excess is over the threshold (default 0.03). The hue of
the excess vector gives the class: purple 270-350°, green 100-170°, plus red, orange, cyan
and blue. An edge counts as a purple (green) edge when it has >= 1 px of purple (green) excess.

### Validation (numbers in `baseline/selftest.json`, `baseline/inject_6929.json`)

Lateral: synthetic random disks, rendered analytically. Each channel is magnified about the
centre, then blurred with σ = 0.7 and given noise σ = 0.002.

| case | channel | truth r=0.5/0.75/1.0 px | measured | max abs err |
|---|---|---|---|---|
| 3000x2000 R x1.0005 B x0.9995 | R-G | 0.451 / 0.676 / 0.901 | 0.451 / 0.680 / 0.915 | 0.013 |
| | B-G | -0.451 / -0.676 / -0.901 | -0.449 / -0.679 / -0.916 | 0.014 |
| 6000x4000 R x1.0005 B x0.9995 | R-G | 0.901 / 1.352 / 1.803 | 0.906 / 1.352 / 1.788 | 0.015 |
| | B-G | -0.901 / -1.352 / -1.803 | -0.904 / -1.353 / -1.800 | 0.003 |
| 6000x4000 R x0.9997 B x1.0008 | R-G | -0.541 / -0.811 / -1.082 | -0.540 / -0.817 / -1.102 | 0.020 |
| | B-G | 1.442 / 2.163 / 2.884 | 1.446 / 2.162 / 2.870 | 0.015 |
| 6000x4000 zero CA | R-G | 0 | 0.002 / -0.001 / -0.009 | 0.009 |
| | B-G | 0 | 0.001 / 0.000 / -0.003 | 0.003 |

All errors are <= 0.021 px, inside the 0.1 px requirement. Zero CA reads <= 0.009 px.

Injection on a real photo (6929 LFI, R resampled x1.0002 and B x0.9998 = ±0.842 px at r = 1):

| | injected | measured change |
|---|---|---|
| R-G r=0.5/0.75/1.0 | 0.421 / 0.632 / 0.842 | 0.397 / 0.606 / 0.828 |
| B-G r=0.5/0.75/1.0 | -0.421 / -0.632 / -0.842 | -0.391 / -0.579 / -0.759 |

On real texture the tool recovers 90-98 % of an injected shift (worst error 0.08 px, B at
r = 1). It slightly under-reads. Seed-to-seed variation is about 0.002 px.

Fringe width: zero CA gives median 0, p90 0 and fringed fraction <= 0.0001 in every zone.
Exact purple bands of 2, 3 and 5 px read back as 2.0, 3.0 and 5.0 px (median = p90 = mean),
all classed purple. Lateral CA of R x1.0005 / B x0.9995 on a 6000x4000 frame gives p90 width
2.5 / 4.0 / 5.0 / 5.5 px from the centre zone out, which rises with r as it should. An
axial-like blur (R σ 1.6, G 0.7, B 2.4) gives median width about 5 px in every zone, with both
purple and green edges.

**Limits.**
1. Compare PNG with PNG and LFI with LFI. In the sRGB render, the Rec.2020→sRGB matrix and
   the look mix channels. The same frame reads smaller B-G there (1840 corner B-G: LFI -0.24,
   PNG -0.10).
2. Fringe width depends on exposure. Dark renders (1840) read near 0 at the 0.03 threshold, so
   `*.render.t015.json` repeats 1840/2545/4213/6929 at 0.015.
3. In colourful foliage (3437, 6001, 2545), part of the "fringe" excess is real colour
   texture, not CA. Use those frames for before/after deltas only.
4. Per-edge MAD is 0.1-0.5 px (demosaic, texture). The zone medians use thousands of edges and
   are stable to about 0.01 px.

## 3. Baseline numbers

Zone medians of the radial shift in px (n edges in parentheses), with the fit at r = 1. The
fringe columns use the 0.03 threshold unless marked otherwise. Full JSON is in `baseline/`.

### 3a. Uncorrected native LFI (scene-linear Rec.2020)

| photo | zone | R-G med (n) | B-G med (n) | fringe edges | width med / p90 / mean px | fringed | purple /1k | green /1k |
|---|---|---|---|---|---|---|---|---|
| 1840 | 0-0.3 | +0.123 (2801) | -0.118 (976) | 1221 | 0 / 0.5 / 0.13 | 0.10 | 9.8 | 15.6 |
| | 0.3-0.6 | +0.338 (3203) | -0.310 (1866) | 1487 | 0 / 0.5 / 0.25 | 0.14 | 28.9 | 10.8 |
| | 0.6-0.8 | +0.557 (3887) | -0.374 (2283) | 1943 | 0 / 0 / 0.11 | 0.06 | 4.6 | 1.0 |
| | 0.8-1.0 | **+0.600** (4842) | -0.241 (3257) | 2183 | 0 / 0 / 0.09 | 0.04 | 6.9 | 2.3 |
| | fit r=1 | +0.664 | -0.048 | | | | | |
| 4213 | 0-0.3 | -0.100 (4844) | -0.046 (4374) | 3676 | 0 / 0 / 0.00 | 0.00 | 0.3 | 0.3 |
| | 0.3-0.6 | -0.224 (2065) | -0.309 (1675) | 1048 | 0 / 0 / 0.07 | 0.03 | 10.5 | 2.9 |
| | 0.6-0.8 | -0.392 (1372) | -0.463 (1035) | 396 | 0 / 0 / 0.15 | 0.08 | 70.7 | 0 |
| | 0.8-1.0 | **-0.437** (351) | **-0.469** (212) | 199 | 0 / 0 / 0.02 | 0.04 | 5.0 | 0 |
| | fit r=1 | -0.553 | -0.760 | | | | | |
| 6929 | 0-0.3 | +0.008 (7977) | -0.003 (5866) | 3624 | 0 / 0.5 / 0.33 | 0.12 | 51.0 | 39.7 |
| | 0.3-0.6 | +0.007 (8599) | +0.038 (6540) | 4267 | 0 / 2.0 / 0.45 | 0.16 | 96.3 | 30.5 |
| | 0.6-0.8 | +0.038 (11576) | +0.053 (9859) | 4277 | 0 / 2.5 / 0.56 | 0.19 | 119.7 | 40.0 |
| | 0.8-1.0 | +0.086 (12908) | -0.036 (11185) | 4710 | 0 / 3.0 / 0.72 | 0.26 | **170.1** | 38.9 |
| | fit r=1 | +0.137 | -0.102 | | | | | |
| 2545 | 0-0.3 | +0.054 (1767) | +0.043 (916) | 704 | 0.5 / 4.0 / 1.38 | 0.57 | 159.1 | 194.6 |
| | 0.3-0.6 | +0.149 (2423) | -0.054 (1641) | 1031 | 0 / 4.0 / 1.16 | 0.41 | 101.8 | 104.8 |
| | 0.6-0.8 | +0.261 (2912) | -0.075 (2440) | 1084 | 0 / 3.5 / 1.00 | 0.38 | 94.1 | 87.6 |
| | 0.8-1.0 | +0.266 (2713) | -0.032 (2208) | 1197 | 0 / 3.5 / 1.05 | 0.37 | 86.9 | 69.3 |
| | fit r=1 | +0.322 | -0.033 | | | | | |
| 3437 | 0-0.3 | -0.007 (6394) | -0.297 (6305) | 5680 | 0 / 4.0 / 0.98 | 0.31 | 51.4 | 155.5 |
| | 0.3-0.6 | -0.129 (9863) | -0.596 (9459) | 7774 | 0.5 / 7.5 / 2.48 | 0.51 | 129.9 | 324.0 |
| | 0.6-0.8 | -0.111 (9718) | -0.841 (8909) | 8128 | 5.5 / 9.5 / 4.77 | 0.74 | 260.0 | 510.3 |
| | 0.8-1.0 | -0.056 (7111) | **-0.961** (5970) | 6175 | 2.5 / 8.5 / 3.42 | 0.57 | 206.0 | 361.8 |
| | fit r=1 | -0.040 | -1.032 | | | | | |
| 6001 | 0-0.3 | +0.090 (4666) | +0.539 (3593) | 7931 | 0 / 5.0 / 1.49 | 0.42 | 202.2 | 164.8 |
| | 0.3-0.6 | +0.112 (12434) | +0.381 (10319) | 10523 | 0 / 1.5 / 0.42 | 0.15 | 30.3 | 62.4 |
| | 0.6-0.8 | +0.127 (12392) | +0.479 (8362) | 13577 | 0 / 0 / 0.13 | 0.05 | 17.5 | 13.6 |
| | 0.8-1.0 | +0.471 (4198) | +0.114 (2607) | 12110 | 0 / 0 / 0.01 | 0.01 | 1.8 | 0.1 |

### 3b. lumen-render output, current code (native size, `--no-dither`, sRGB PNG)

| photo | zone | R-G med | B-G med | width med/p90/mean @0.03 | purple/green /1k @0.03 | width mean @0.015 | fringed @0.015 | purple/green /1k @0.015 |
|---|---|---|---|---|---|---|---|---|
| 1840 | 0-0.3 | +0.100 | -0.055 | 0/0/0.03 | 3.8/2.3 | 0.32 | 0.14 | 47.4/21.4 |
| | 0.3-0.6 | +0.266 | -0.147 | 0/0/0.05 | 7.7/1.8 | 0.50 | 0.16 | 44.2/34.2 |
| | 0.6-0.8 | +0.491 | -0.177 | 0/0/0.01 | 1.3/0.8 | 0.22 | 0.09 | 13.1/14.8 |
| | 0.8-1.0 | **+0.520** | -0.103 | 0/0/0.04 | 6.0/0.8 | 0.32 | 0.12 | 27.5/22.6 |
| 4213 | 0-0.3 | -0.065 | -0.032 | 0/0/0.00 | 0.4/0 | 0.04 | 0.03 | 8.0/4.0 |
| | 0.3-0.6 | -0.125 | -0.091 | 0/0/0.02 | 1.3/0 | 0.14 | 0.06 | 26.0/14.3 |
| | 0.6-0.8 | -0.228 | -0.156 | 0/0/0.00 | 0/0 | 0.03 | 0.03 | 8.6/3.4 |
| | 0.8-1.0 | **-0.275** | -0.187 | 0/0/0.00 | 0/0 | 0.02 | 0.02 | 2.1/4.3 |
| 6929 | 0-0.3 | +0.004 | -0.004 | 0/0/0.13 | 27.2/12.6 | 1.01 | 0.29 | 129.6/98.3 |
| | 0.3-0.6 | +0.004 | +0.015 | 0/0/0.23 | 46.3/16.2 | 1.30 | 0.34 | 168.2/103.4 |
| | 0.6-0.8 | +0.030 | +0.041 | 0/0/0.25 | 49.0/25.2 | 1.24 | 0.31 | 148.9/110.9 |
| | 0.8-1.0 | +0.080 | +0.012 | 0/1.0/0.35 | 78.2/25.6 | 1.69 | 0.41 | **214.7**/153.3 |
| 2545 | 0-0.3 | +0.042 | +0.023 | 0/2.5/0.67 | 104.4/85.9 | 4.15 | 0.86 | 393.9/355.2 |
| | 0.3-0.6 | +0.126 | -0.025 | 0/2.0/0.50 | 71.3/43.9 | 2.64 | 0.64 | 242.3/194.8 |
| | 0.6-0.8 | +0.217 | -0.039 | 0/1.5/0.44 | 46.9/36.8 | 2.21 | 0.55 | 171.0/182.0 |
| | 0.8-1.0 | +0.224 | -0.015 | 0/1.0/0.29 | 31.5/22.2 | 2.11 | 0.55 | 160.3/144.6 |
| 3437 | 0-0.3 | +0.018 | -0.146 | 0/0/0.24 | 20.6/47.9 | | | |
| | 0.3-0.6 | -0.033 | -0.341 | 0/3.5/0.73 | 49.0/105.2 | | | |
| | 0.6-0.8 | -0.066 | -0.511 | 0/6.5/1.60 | 93.7/200.4 | | | |
| | 0.8-1.0 | -0.039 | **-0.576** | 0/5.5/1.09 | 75.7/134.2 | | | |
| 6001 | 0-0.3 | +0.059 | +0.307 | 0/2.5/0.59 | 89.1/69.5 | | | |
| | 0.3-0.6 | +0.118 | +0.197 | 0/0/0.12 | 12.3/17.4 | | | |
| | 0.6-0.8 | +0.134 | +0.247 | 0/0/0.03 | 5.3/5.0 | | | |
| | 0.8-1.0 | +0.326 | +0.071 | 0/0/0.00 | 0/0 | | | |

Fit at r = 1 (PNG): 1840 R +0.598 / B +0.005; 4213 R -0.320 / B -0.215; 6929 R +0.131 /
B -0.004; 2545 R +0.265 / B -0.019; 3437 R -0.090 / B -0.672; 6001 R +0.422 / B -0.124.

**Reading.**
- Lateral CA is real and measurable. In the corners it reaches 0.6 px R-G on the D850
  (red magnified), about 0.45 px R and B on the Z 7II (G magnified relative to both, so
  green/magenta fringes), and 1 px B-G on the T7i kit lens.
- The A7 IV frame (6929) has almost no lateral CA (<= 0.09 px). Its problem is purple fringes
  around bright, partly clipped sky gaps: purple edges are 4.4x more common than green in the
  corner zone of the LFI (170 vs 39 per 1000). That makes it a **Defringe** test frame, not a
  removeCA one.
- 6001 (X-Trans) gives an inconsistent radial profile (B-G +0.54 in the centre, +0.11 in the
  corner). That points to demosaic or texture bias, not lens CA. Do not use it as a removeCA
  pass/fail frame.

## 4. Visual check (100 % crops of the current render)

All crops are in `/tmp/claude-0/audit/`. Each comes as `crop_*.png` (400x300 at 100 %),
`*_gainN.png` (linear gain so p99.5 → 0.85, because 1840 and 4213 render dark),
`*_zoom4_*.png` (a 200x150 window at 4x nearest-neighbour) and `*_chroma4.png` (the same with
OKLab a,b x4, to make colour and side legible). Corner tiles were picked automatically by
`tools/find_fringe_crops.py`, which ranks chroma high-pass on strong edges in tiles at
r >= 0.72 that hold both sky and dark subject. 4213 was picked by hand with
`tools/manual_crops.py`.

- **1840 TR** (`crop_1840_TR_x7800_y1350*`, r = 0.82, branches against blue sky). At plain 100 %
  the render is very dark and the fringes are hard to see. Boosted at 4x, branch and leaf edges
  carry a thin (about 1 px) red-magenta rim on the side that faces the image centre (lower
  left). With chroma x4 it is clearly a magenta-red outline on the centre-facing sides of dark
  twigs and a faint cyan on the outer sides. That fits R magnified by about 0.5-0.6 px.
  **1840 TL** (`crop_1840_TL_x400_y750*`, r = 0.80): the same red-brown edging, plus blue
  speckle from sky gaps inside the foliage.
- **4213 left treeline** (`crop_4213_m_x0_y2100*`, r = 0.82, bare birch twigs against overcast
  sky). The plain 4x view shows faint magenta tinting on twig edges. With chroma x4 there are
  paired fringes on nearly every twig, 1-1.5 px each: magenta on one side and green on the
  other. That is the pattern for G magnified relative to both R and B, matching the -0.44/-0.47
  px readings. The right-edge crop `crop_4213_m_x7856_y2150*` landed on sky only and is useless.
  The castle crops (`crop_4213_m_x4100_y2600*`, `x3650_y3150`) are at r < 0.15, where lateral
  CA is under 0.1 px.
- **6929 TR** (`crop_6929_TR_x6200_y600*`, r = 0.83, leaves against bright sky). A blue-violet
  to purple fringe surrounds the bright sky gaps on the dark side, on all sides of each gap and
  not only one radial side. It is about 1-2 px wide and is visible in the plain 4x view as a
  violet edge, most strongly along the lower and right edges of the gaps. This is the classic
  axial / bloom purple fringe that Defringe purple targets. Also cropped: TL (r = 0.78) and BR
  (r = 0.78).

None of these fringes is visible at fit-to-screen. They show at 100-200 % on the treeline
edges, which is where a Lightroom user would turn on Remove CA.

## 5. Lightroom / Camera Raw behaviour

Sources: Adobe Camera Raw help "Correct lens distortions in Camera Raw" and the Lightroom
Classic lens-corrections help. helpx.adobe.com returned 403 to this machine, so the Adobe
wording was taken from search-indexed text and quoted where marked. Third-party sources are
labelled.

**Remove Chromatic Aberration (checkbox, Profile tab).**
- Corrects "blue-yellow and red-green color fringes", which is lateral (transverse) CA:
  colour channels imaged at slightly different magnification (Adobe help).
- Automatic, with no sliders. It analyses the image itself and does not need a lens profile
  (it works with Enable Profile Corrections off). Since process 2012 / LR 4.1 the old manual
  lateral-CA sliders are gone, and the checkbox is the only lateral-CA control (repo
  `docs/02` and `docs/09`).
- Adobe recommends turning it on before using the Defringe eyedropper, because "just doing
  this alone might fix the entire issue".
- Practitioner note: it acts on the colour along high-contrast edges and does not geometrically
  warp the image (scottdavenportphoto.com).

**Defringe (Manual tab; also a local mask slider).**
- Targets axial (longitudinal) CA: purple/magenta fringes in front of the focus plane and
  green behind it, worst at wide apertures. It also catches purple bloom around clipped
  highlights. Lateral CA is left to the checkbox.
- **Purple Amount, Green Amount: 0-20, default 0.** "The higher the amount, the more color
  defringing is applied" (Adobe). It **desaturates** fringe-coloured pixels. It does not
  shift them.
- **Purple Hue and Green Hue are dual-thumb ranges on 0-100.** Defaults are 30/70 (purple)
  and 40/60 (green). "Drag either end-point control to expand or decrease the range of
  affected colors. Drag between the end point controls to move the hue range." The **minimum
  span between end points is 10 units** (Adobe Camera Raw help, via search snippet). "The
  default spacing for the green sliders is narrow to protect green/yellow image colors, like
  foliage." "Take care not to apply an adjustment that affects purple or green objects in your
  image."
- **What hues the 0-100 scale spans.** Adobe does not publish the mapping. The slider tracks
  show a gradient: purple runs from blue through violet to magenta, green from yellow-green
  through green to aqua (UI observation, not verified on this machine). The only quantitative
  source found is third-party reverse engineering. rawmakase PR #33 fits ACR 18.6 renders with
  OKLab hue centres of 0.875 turn (315°, purple) and 0.46 turn (166°, green) and a span of
  0.5 turn (180°) across 0-100, i.e. 1.8° per slider unit. Under that fit:
  - Purple 0-100 covers 225° (blue) to 405° = 45° (red-orange), centred on magenta.
    Default 30/70 = 279°-351°.
  - Green 0-100 covers 76° (yellow) to 256° (blue-cyan). Default 40/60 = 148°-184°.
  - Range ends are feathered by about ±9° (0.025 turn). Removed fraction:
    (1 - 0.45·e^(-C/0.09))·(1 - e^(-Amount/2.5)), so Amount 10 already removes about 98 % of
    the maximum.
  - That fit does **not** reproduce ACR's extra reduction next to strong edges. ACR only
    defringes near high-contrast edges, which the PR acknowledges and leaves out.

  Treat the degree values as unverified. The 30/70 and 40/60 defaults and the 10-unit minimum
  span are Adobe's.
- **Eyedropper:** a click on a fringe sets Amount and moves the hue range to the sampled
  colour. Alt/Option-drag on any Defringe slider shows a black-and-white mask of the pixels
  being affected.
- **Edge-only:** Defringe affects only pixels near high-contrast edges. Third-party
  descriptions of the same algorithm family (J. Sachs, "Defringe Transformation Notes", 2013)
  say a pixel is a fringe pixel when its hue is in range **and** it lies within a radius of a
  pixel brighter than a threshold. That is why a purple shirt away from edges survives.
- **Local Defringe** (brush / mask) exists in LR. It is WS-55's concern, not this lane's.

## 6. Proposed acceptance thresholds (for SPEC.md)

"Before" is always rendered with `--set develop.geometry.lens.removeCA=false --set
develop.geometry.lens.profile=false` (shown byte-identical to the base commit for 2545; the
verifier should repeat that for 1840/4213/6929). Renders use `--long-edge 0 --no-dither`.
Measure with `fringe_metrics.py --compare before.png after.png`.

**removeCA**
1. **Corner residual.** With `removeCA=true`, the R-G **and** B-G zone medians in zones 0.6-0.8
   and 0.8-1.0 have |shift| <= 0.15 px on 1840, 4213, 2545 and 3437. Baseline worst cases:
   1840 R +0.520, 4213 R -0.275, 3437 B -0.576, 2545 R +0.224.
2. **Reduction.** Wherever the baseline |zone median| >= 0.2 px, the after value is reduced by
   >= 60 % with no sign flip beyond -0.1 px (no overcorrection).
3. **Do no harm.** On 6929 and 6001, which have little or inconsistent CA, no zone median
   |shift| grows by more than 0.05 px, and fringed fraction (@0.015) does not increase by
   more than 0.01.
4. **CA-free identity.** A CA-free synthetic (e.g. `synth_disks(6000,4000,scales=(1,1,1))`
   saved as LFI, or `corpus/synthetic/*`) renders **byte-identical** with removeCA on and off.
   This needs a dead-band: estimated corner shift < 0.1 px → no-op.
5. **Known-CA recovery.** A synthetic with R x1.0005 and B x0.9995 (6000x4000, ±1.80 px at
   r = 1) has a residual <= 0.1 px at r = 0.5/0.75/1.0 after correction (tool fit).
6. **G untouched.** If the design keeps G as the reference, the output G channel with
   removeCA on equals removeCA off: max |Δ| <= 1 code, or exactly 0 if no other stage mixes
   channels.
7. **No blur.** The R and B edge 10-90 % rise width at strong edges does not grow by more than
   10 %. Proxy: the per-edge SSD residual distribution does not get worse.
8. **Fringe follows CA.** On 1840 and 4213 the corner-zone (0.8-1.0) fringed fraction @0.015
   falls by >= 50 % (1840: 0.117 → <= 0.058).

**Defringe**
9. **Amount 0 is identity.** `defringe` nil, and `defringe` with purpleAmount = greenAmount =
   0 at any hue values, are byte-identical outputs.
10. **Effect on a purple-fringe frame.** 6929 with purpleAmount 20 (default hue 30/70): purple
    edges per 1000 @0.015 drop by >= 50 % in every zone (corner 214.7 → <= 107) and mean
    fringe width @0.015 drops by >= 40 % (1.69 → <= 1.01). Green edges per 1000 change by no
    more than ±10 % (the purple slider must not touch green).
11. **Monotonic.** purpleAmount 0/5/10/15/20 gives non-increasing purple-edge counts and
    non-decreasing ΔE on fringe pixels. Same for green.
12. **Purple object away from edges survives.** A synthetic flat purple patch (OKLab h ≈ 300°,
    C ≈ 0.12, 200x200 px, low-contrast surround < 1 stop), with purpleAmount 20: ΔE2000 <= 1.0
    for pixels more than 8 px from any >= 1.5-stop edge.
13. **Foliage protected.** 2545 and 3437 with greenAmount 20 and default 40/60: the median
    ΔE2000 over pixels more than 8 px from any >= 1.5-stop edge is <= 1.0, and p99 is <= 3.
14. **Hue window respected.** A synthetic fringe of OKLab hue outside the selected window plus
    the feather (e.g. a yellow-orange 60° fringe with purple 30/70) changes by ΔE2000 <= 0.5.
    The minimum span of 10 units is enforced (lo/hi closer than 10 are clamped, not inverted).
15. **Desaturates, never shifts hue or lightness.** On defringed pixels, OKLab L changes by
    <= 0.01, and chroma is reduced along the pixel's own hue. It must not rotate the hue: an
    output with C > 0.02 stays within 5° of the input hue.

**Visual (human-judged, from named crops)**
- V1: `crop_1840_TR_x7800_y1350` and `crop_4213_m_x0_y2100` (and their `_chroma4`), before
  and after removeCA. The magenta/red and green twig rims are gone at 4x zoom.
- V2: `crop_6929_TR_x6200_y600`, before and after purpleAmount 10. The violet rim around the
  sky gaps is neutral at 4x, and the leaves keep their green.

## 7. Files

- Tool: `docs/quality/lanes/WS-28/tools/fringe_metrics.py`. Helpers: `tools/inject_check.py`
  (real-image injection check), `tools/find_fringe_crops.py`, `tools/manual_crops.py` (crop
  scripts; they read `/tmp/claude-0/audit/render_<n>.png`).
- Baseline JSON: `docs/quality/lanes/WS-28/baseline/<n>.lfi.json`, `<n>.render.json`,
  `<n>.render.t015.json`, `selftest.json`, `inject_6929.json`.
- Native decodes: `corpus/lfi-native/*.lfi` (git-ignored). Renders: `/tmp/claude-0/audit/render_<n>.png`.
