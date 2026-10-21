# WS-45 lane M3 audit: linear and radial gradient masks

Auditor run on 2026-10-21. I audited the prebuilt binary `.build/x86_64-unknown-linux-gnu/release/lumen-render` (mtime Oct 21 01:38) and did not rebuild it. HEAD was `9068ded`. Code read for the spec: `Sources/LumenCore/Image/MaskRaster.swift` `linearPlane`/`radialPlane`, and `ReferenceRenderer.applyMasks`, which does `out = base.mix(adjusted, alpha)` in scene-linear.
Work dir: `/tmp/claude-0/m3/audit/` (scripts `p1.py`, `p2.py`, `p2_ideal.py`, `p3.py`; recipes `p*.json`; raw renders).
Recipes come from `/tmp/claude-0/m3/mk.py recipe(comp, exposure, out)`, which is the default recipe plus one mask with one component.

## Verdict
| # | Finding | Severity |
|---|---|---|
| D1 | Radial **Feather 0 is aliased**. The edge has 0 intermediate codes: one pixel steps 118→41 (−2 EV) or 118→207 (+2 EV), a 77 to 89 code jump. The same holds on the 1536×1024 rot-30° ellipse (118→20, 0 intermediate codes). Stair-stepped rim: `radial_flat_feather.png` panel 4 and `alignment_3x2_rot30.png` right. Any slider value below ~1 px of ramp behaves the same, because `rin = max(1−f, 1/minRadiusPx)` and nothing anti-aliases the r=1 step. | defect (visible on any hard-edged radial, e.g. a vignette or spot darken) |
| O1 | Perceived midpoint is not the geometric midpoint, because the blend is in scene-linear. Linear [0.5,.2,.5,.8]: L* 50% lands at y=0.536 for −2 EV and y=0.402 for +2 EV, against a nominal 0.5. That is −2 EV skewed +0.036 (6% of span) and +2 EV skewed −0.098 (16% of span). Radial F100: L*50% at r=0.445 (−2 EV) and r=0.665 (+2 EV). It matches the stated model to ≤0.6 code, so the implementation is correct. This is a design observation, not a bug. | observation |
| – | Alignment (linear, radial, 3:2, rotation 30°) | **none**: render = model to ≤1 code (rounding ties) on every pixel |
| – | Banding caused by the mask | **none**: max runs ≤ unmasked in the sky-darkening direction, and dither removes the 1-code contours |
| – | Kinks in falloff | **none** beyond 8-bit quantisation |

## 1. Falloff profile (flat_grey, `--long-edge 512 --no-dither`)
Commands:
`lumen-render render --input corpus/synthetic/flat_grey.lfi --recipe p1_<case>.json --long-edge 512 --no-dither --out p1_<case>.png`
The linear profile is column x=256 against y_norm=(y+.5)/512. The radial profile is row 255 against r, taken from the rim inward. L* comes from the 8-bit code (sRGB decode, then CIE L*). The 10/50/90% figures are fractions of the L* change from the off code to the on code. "Model" is the spec alpha pushed through the measured tone curve: `cal/cal.npy`, 281 flat renders from −3.3 to +2.3 EV in 0.02 EV steps, read from metrics `meanEncoded`.

| case | off→on code | L*10/50/90 % position | model | max step (codes/px) | max abs d2(L*) (at) | next-largest d2 / p99 | render−model max (codes) | intermediate codes / px in transition |
|---|---|---|---|---|---|---|---|---|
| linear −2 EV (y) | 118→41 | 0.355 / 0.536 / 0.702 | 0.357 / 0.535 / 0.702 | 1 | 0.473 (0.784) | 0.473 / 0.468 | 0.60 | 76 / 289 |
| linear +2 EV (y) | 118→207 | 0.268 / 0.402 / 0.612 | 0.266 / 0.402 / 0.614 | 1 | 0.397 (0.218) | 0.397 / 0.396 | 0.50 | 88 / 273 |
| radial F0 −2 (r) | 118→41 | 1.005 / 1.003 / 1.000 | same | **77** | 33.0 (r=1.006) | – / 0.0 | 0.35 | **0 / 0** |
| radial F25 −2 | 118→41 | 0.937 / 0.860 / 0.791 | 0.935 / 0.860 / 0.791 | 4 | 0.941 (0.765) | 0.841 / 0.473 | 0.49 | 33 / 36 |
| radial F50 −2 | 118→41 | 0.874 / 0.719 / 0.583 | 0.870 / 0.721 / 0.581 | 3 | 0.845 (0.739) | 0.473 / 0.471 | 0.49 | 58 / 72 |
| radial F100 −2 | 118→41 | 0.744 / 0.445 / 0.166 | 0.741 / 0.445 / 0.168 | 1 | 0.473 | 0.473 / 0.470 | 0.50 | 76 / 143 |
| radial F0 +2 | 118→207 | 1.005 / 1.003 / 1.000 | same | **89** | 33.5 (r=1.006) | – / 0.0 | 0.35 | **0 / 0** |
| radial F25 +2 | 118→207 | 0.972 / 0.916 / 0.828 | 0.972 / 0.916 / 0.828 | 5 | 0.794 (0.993) | 0.785 / 0.391 | 0.50 | 32 / 34 |
| radial F50 +2 | 118→207 | 0.944 / 0.832 / 0.656 | 0.945 / 0.832 / 0.655 | 3 | 0.397 | 0.394 / 0.389 | 0.49 | 58 / 68 |
| radial F100 +2 | 118→207 | 0.886 / 0.665 / 0.318 | 0.890 / 0.666 / 0.315 | 2 | 0.397 | 0.397 / 0.397 | 0.50 | 87 / 136 |

Kink: the largest second difference everywhere equals one code step (0.47 / 0.40 L*). F25 and F50 reach two code steps where the ramp is steepest (4 to 5 codes/px). No isolated slope break shows at the ramp ends (smoothstep is C1) or at r_in. The plot is in `falloff_profiles_Lstar.png`.

Dither on the same linear −2 ramp: max run along y drops from 19 to 14 and the mean run from 3.85 to 1.85. The 8-row moving-mean max step is 0.625 without dither and 0.562 with it, max |2nd diff| 0.125 and 0.062. The 1-code alternation between rows 0 and 1 of the row means comes from the 8×8 Bayer row structure, which is outside M3.

## 2. Alignment (1536×1024 flat 0.18 written by hand, −3 EV, `--no-dither`)
`lumen-render render --input flat32.lfi --recipe p2_<case>.json --no-dither --out p2_<case>.png`
Alpha is (lin(code) − lin(118)) / (lin(20) − lin(118)), with lin() taken from the calibration curve. Full-off is code 118 and full-on is code 20. The fits invert the smoothstep (alpha 0.03 to 0.97) and least-squares the line or ellipse. Every fit was repeated on an **ideal synthesized render** (spec alpha → calibration → rounded code) to separate method bias from renderer error (`p2_ideal.py`).

| case | measured | ideal-render fit | expected | render vs ideal codes |
|---|---|---|---|---|
| linear [.25,.25,.75,.75] (diagonal, 923.02 px in pixel space) | α(start px 384,256)=0.000 (code 118); α(mid 768,512)=0.502; α(end 1152,768)=1.000; fit s0/s1 −6.35/928.14 px, mid 460.89 px, isoline tilt −0.002°, max abs α err vs model 0.014 | −6.37/928.16, mid 460.89 | 0/923.02, mid 461.51, tilt 0 | max 1 code, 2367 of 1.57 M px (rounding ties) |
| linear [.5,.2,.5,.8] | start (768,204) α=0.000; mid α=0.502; end (768,819) α=1.000; fit mid 306.81 px | 306.81 | 307.2 | max 1, 1536 px |
| radial rot30 r[.3,.15] F0 | ellipse fit major 460.78 px, minor 153.60 px, angle 29.997°; 30° ray α=0.5 at 460.80 px; 120° ray 153.60 px; wrong-sign (−30°) ray 174.0 px | identical | 460.80 / 153.60 / 30° | **0 px differ** |
| F50 | fit 461.49 / 153.83 / 29.999°; 30° ray: α≤0.995 from 234.8 px, α=0.5 at 346.05 px, α≤0.005 at 453.85 px | 461.49 / 153.83 / 29.999° | r_in 230.4, α=.5 345.6, rim 460.8 | max 1, 366 px |
| F100 | fit 463.38 / 154.46 / 30.001°; α=0.5 at 233.5 px | 463.38 / 154.46 / 30.000° | α=.5 at 231.9 px | max 1, 402 px |

The F50/F100 fit offsets (+0.7 / +2.6 px) and the linear s0/s1 extrapolation (−6 / +5 px) are bias from quantising the tails. The ideal render reproduces them to ≤0.03 px. The rim is at the expected position within 1 px (F0: 0.0 px), and the rotation is pixel-space +x→+y as specified. Overlay: `alignment_3x2_rot30.png`, red = expected rim, yellow = expected r_in.

## 3. Banding (`--long-edge 1600`, default dither vs `--no-dither`, −1.5 EV)
Lines chosen after viewing each frame:
- 983: horizon ≈ 0.45 H.
- 1840: horizon ≈ 0.5 H.
- `mask` = line [.5,0,.5,h] as literally briefed. Alpha is 0 at the top, so the effect falls below the horizon and flattens the sky.
- `maskr` = [.5,h,.5,0]. Alpha is 0 at the horizon and 1 at the top: the real "darken the sky" use.

Sky crops are x300–840 y20–180 for 983 and x300–740 y0–170 for 1840. Run length = runs of a constant 8-bit code down each column.

| crop | G max / p99 / mean run | R max | B max | distinct G | dev from box31, std (G) |
|---|---|---|---|---|---|
| 983 none, no dither | 16 / 11 / 3.24 | 18 | 13 | 36 | 0.422 |
| 983 none, dither | 13 / 8 / 1.87 | 17 | 14 | 37 | 0.510 |
| 983 mask, no dither | 56 / 21 / 3.47 | 22 | 30 | 25 | 0.416 |
| 983 mask, dither | 46 / 11.4 / 1.88 | 17 | 28 | 26 | 0.506 |
| 983 maskr, no dither | 15 / 12 / 4.29 | 18 | 12 | 39 | 0.352 |
| 983 maskr, dither | 14 / 8 / 1.92 | 16 | 12 | 39 | 0.454 |
| 1840 none, no dither | 25 / 17 / 5.54 | 25 | 23 | 20 | 0.336 |
| 1840 none, dither | 22 / 12 / 1.96 | 22 | 20 | 21 | 0.445 |
| 1840 mask, no dither | 90 / 41 / 5.46 | 91 | 38 | 11 | 0.336 |
| 1840 mask, dither | 63 / 16 / 1.95 | 39 | 28 | 13 | 0.446 |
| 1840 maskr, no dither | 18 / 14 / 5.63 | 26 | 17 | 33 | 0.321 |
| 1840 maskr, dither | 16 / 8 / 1.96 | 24 | 16 | 33 | 0.432 |

What the runs show:
- The long `mask` runs (90 / 63) are content, not banding. That mask cancels the sky's natural gradient: the G row-mean range shrinks from 102.3–114.8 to 102.3–106.3, about 4 codes over 170 rows. The ordered dither cannot break plateaus where the value sits near a code centre.
- In the sky-darkening direction (`maskr`) the run lengths are at or below the unmasked crop.

Visual check (×20 deviation from a 31-px box blur, `sky_banding_stretch20.png`):
- Undithered renders show the usual 1-code contours: arcs for 1840 `mask`, horizontal lines for `maskr`.
- With dither they disappear on 1840.
- 983 `maskr` has a faint diagonal chroma streak in both the dithered and undithered crops. Its row-mean amplitude is ≤0.44 code. It is diagonal while the mask varies only along y, so it is not mask geometry.

## 4. Evidence sheet (6 PNGs, all < 400 KB, every one viewed)
- `sky_1840_before_after.png` (319 KB) and `sky_983_before_after.png` (259 KB): rendered at long edge 1024 with default dither, before | after (maskr, −1.5 EV), each panel BOX-downscaled to 512 to fit 400 KB.
- `radial_flat_feather.png` (53 KB): flat_grey 512, −2 EV, F0 / F50 / F100, plus an 8× nearest-neighbour zoom of the F0 rim (D1 stair).
- `alignment_3x2_rot30.png` (30 KB): §2 overlay.
- `falloff_profiles_Lstar.png` (13 KB): §1 L* profiles.
- `sky_banding_stretch20.png` (367 KB): §3 stretched 100% crops (230×150 each): none_nd / mask_nd / maskr_nd / maskr_d.
