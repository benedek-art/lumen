# WS-03 White balance: audit (before)

Auditor pass on branch `quality/ws-03-white-balance`. No source code changed. All scratch artefacts are under
`/tmp/claude-0/-home-user-lumen/5b5e92d4-cc72-5c7d-a3b9-2f1d9938cab6/scratchpad/audit/` (called `$A` below).

Tools:
- `$A/wbmodel.py` is a Python port of `ColorTemperature` (locus, crossfade, v-offset tint, both magenta bounds),
  `WhiteBalanceEngine.adaptation`, the `neutralizing` objective and `DNGTemperature` (both directions). Check
  (`$A/xcheck.py`): for 7 (K, tint) targets, including a clamped one (2500/+120), I made a colour the port says
  Lumen will neutralise and rendered it with `lumen-render`. Every output was R=G=B=118 with OKLab C ≤ 2e-5.
- The sweeps are `$A/sweep.sh`, and their sheets, tiles and metrics are in `$A/sweeps/`.
- The tables come from `$A/q1.py`, `q1b.py`, `q2.py`, `q3` (inline), `q5.py` and `q6.py`. Their outputs are in `$A/q*.txt`.

Labels: **[M]** = measured. **[R]** = from a web source (cited). **[G]** = my inference or guess, not measured.

---

## Findings

### 1. [M] Lumen's Kelvin/Tint numbers are not Adobe's numbers, but the as-shot pair arrives in Adobe's convention and is read with Lumen's locus

`WhiteBalanceEngine.adaptation` converts **both** the as-shot pair and the target pair with
`ColorTemperature.chromaticity`. That function uses Kim's Planckian fit up to 3500 K, a smoothstep blend to
the CIE daylight locus at 4500 K, and tint as a pure CIE-1960 **+v** offset of 1/3000 per unit. The sidecar /
`CIRAWFilter` as-shot pair, however, uses the DNG SDK convention (Robertson isotherms, tint along the isotherm,
kTintScale −3000). Examples:

| Lumen pair | xy | the same xy in Adobe K/tint |
|---|---|---|
| 2850 / 0 | 0.44752, 0.40764 | 2858 / +0.2 |
| 4000 / 0 | 0.38144, 0.38025 | 3999 / +4.0 |
| 5000 / 0 | 0.34574, 0.35867 | 5000 / +9.8 |
| 5500 / 0 | 0.33250, 0.34761 | 5498 / +10.2 |
| **5500 / +10 (Lumen "Daylight")** | 0.33738, 0.35637 | **5309 / +17.0** |
| 6500 / +10 (Lumen "Cloudy") | 0.31724, 0.33744 | 6216 / +16.1 |
| 7500 / +10 (Lumen "Shade") | 0.30326, 0.32290 | 7109 / +15.2 |
| 3800 / +21 (Lumen "Fluorescent") | | 3657 / +19.6 |
| 10000 / +10 | | 9266 / +13.9 |
| 50000 / +10 | | 31884 / +12.9 |

- Lumen tint 0 is Adobe tint ≈ 0 below 3500 K and Adobe tint ≈ +10 above 4500 K. The offset between the two
  conventions therefore changes with temperature.
- The synthetic as-shot pair D65 = 6503.7 / +9.77 (Adobe) is read by Lumen as xy (0.31707, 0.33719). In Adobe
  terms that is 6226 / +15.9, which is 6.8 mired and about 6 tint units greener than the file's real neutral.
- Going the other way, Adobe 5500 / 0 is Lumen 5218 / −14.9, and Adobe 6500 / 0 is Lumen 6039 / −16.6.
- Identity is still exact (see 4f), because `adaptation` short-circuits when target == as-shot. As soon as the
  target moves, though, the misread as-shot point and the convention mismatch both show up in the picture.

### 2. [M] Kelvin accuracy on a synthetic grey under known illuminants

Setup: a 0.18 grey lit by illuminant L, decoded at a given as-shot neutral. The decode is modelled as CAT16
from the as-shot white to D65; with as-shot = D65 this is the identity, so the CAT choice drops out. I then
render with the target set to L's Adobe K/tint, which is what a Lightroom user would type, and measure the
scene-linear residual. Full table in `$A/q1.txt`.

As-shot D65 (6503.7 / +9.77):

| illuminant (Adobe K/t) | OKLab C left | R/G | B/G | Lumen `neutralizing` result | ΔK | Δmired | Δtint |
|---|---|---|---|---|---|---|---|
| CIE A (2856 / 0) | 0.0064 | 0.996 | 0.933 | 2844 / +4.0 | −12 | +1.45 | +4.0 |
| Planck 4000 (3998 / −0.1) | 0.0032 | 1.005 | 0.966 | 3957 / +2.4 | −40 | +2.56 | +2.5 |
| F11 (4001 / +0.5) | 0.0031 | 1.004 | 0.967 | 3965 / +2.9 | −36 | +2.26 | +2.5 |
| D50 (5002 / +9.6) | 0.0013 | 1.002 | 1.013 | 4995 / +7.9 | −6 | +0.25 | −1.7 |
| D65 | 0.0001 | 1.000 | 1.000 | 6504 / +9.8 | +1 | −0.02 | 0 |
| D75 (7506 / +9.6) | 0.0005 | 0.999 | 0.994 | 7515 / +10.7 | +9 | −0.16 | +1.1 |
| D100 (9992 / +9.3) | 0.0014 | 0.997 | 0.985 | 10083 / +12.7 | +91 | −0.90 | +3.4 |

- With as-shot 5000 / +5, the K error grows with distance from the as-shot point: the D65 grey solves to
  6726 / +14.5 (+223 K, −5.1 mired, +4.8 tint) and the D100 grey to 10810 / +19.3 (+818 K, −7.6 mired, +10.1
  tint). Switching the decode-model CAT to Bradford changes this by less than 10 %.
- With a tungsten as-shot (3000 / 0), every daylight grey solves to Lumen tint ≈ −1, where Adobe says +10. That
  is an 11-unit tint disagreement on every daylight target.
- Typing Adobe's numbers for the true illuminant into Lumen, over a grid of as-shot {2500…10000 K} × {−10…+20}
  and target over the same grid, leaves a grey with **ΔE00 median 2.42, p90 3.84, max 5.40** (`$A/q5.txt`).
  Under a DNG-convention engine the same test would give 0 by construction.
- `neutralizing` itself is fine. It hits residual ≤ 3e-15 on every case. The answer is only "wrong" because
  the numbers are expressed in Lumen's convention.

### 3. [M] The tint axis points the wrong way: −tint renders yellow-green and +tint renders blue-violet, not green and magenta

Lumen's tint is a pure +v shift. Adobe's runs along the Robertson isotherm, which sits at 95° (2000 K),
108° (2850 K), 138° (5500 K) and 154° (10000 K) in the uv plane. The angle between the two tint axes is
5° at 2000 K, 18.5° at 2850 K, **48° at 5500 K**, 54° at 6500 K and 64° at 10000 K.

The code comment "Tint offsets perpendicular to the locus" is false: at 5500 K the Lumen tint axis is 138°
from the locus tangent. The step length is the same in both conventions (1 unit = 1/3000 Δuv), so only the
direction differs. Two consequences:

- **Hue.** Scene-linear 0.18 grey, as-shot D65, tint-only move (`$A/q2.txt`):

  | tint | Lumen OKLab hue | Lumen C | Adobe-convention hue | Adobe C |
  |---|---|---|---|---|
  | −75 | 112° (yellow-green) | 0.044 | 153° (green) | 0.051 |
  | +75 | 289° (blue-violet) | 0.055 | 326° (magenta) | 0.040 |
  | +150 | 285° | 0.187 | 322° | 0.090 |

  Rendered `flat_grey` tiles in display OKLab (`$A/sweeps/flat_grey_tint_tiles`):

  | tint | a | b |
  |---|---|---|
  | −150 | −0.030 | +0.060 |
  | −75 | −0.019 | +0.038 |
  | 0 | −0.002 | +0.005 |
  | +9.77 (as shot) | 0 | 0 |
  | +75 | +0.020 | −0.051 |
  | +150 | +0.062 | −0.160 |

  The sign of `a` is right (+ is magenta, − is green), but `|b|` is 2–2.6× `|a|`. Tint is mostly a blue/yellow
  control. See it in `evidence/before_tint_axis_skin_tones.png` (−150 is olive/yellow, +150 is violet) and in
  `evidence/before_tint_2545_gx85.png` (the GX85 sky goes teal at −150 and purple at +150, and the lawn turns
  yellow at −150).
- **Tint changes Kelvin.** +10 Lumen tint at 5500 K moves the Adobe CCT by −191 K (6.5 mired). At 50000 K it
  moves it by −18000 K.
- **Magnitude at the end of travel.** At as-shot 5500 / +10, Lumen +150 gives C 0.26 against Adobe's 0.11.
  The magenta end is about 2.4× stronger (and bluer).
- **Magenta guard values** (`tintLimit(K)`, port matches the comments to 0.01): 2000 K +3.6 · 2200 K +13.8 ·
  2500 K +29.7 · 2850 K +48.3 · 3200 K +66.3 · 3500 K +81.0 · 4000 K +100.8 · 4500 K +117.9 · 5000 K +136.0 ·
  5400 K +149.1 · 5500 K +152.2 · 6500 K +176.9 · 8000 K +200.1. The bound is measured against a fixed 5500 K
  reference, not against the file's as-shot neutral **[M from code]**. At 2000 K only +3.6 of magenta is
  usable; Lightroom gives the full +150 there **[G: Adobe does not use a CAT16 von-Kries on the illuminant, so
  it has no pole]**. If the axis were changed to the Adobe isotherm direction, the guard would need
  re-deriving: under CAT16 the Adobe-direction tint at 3200 K / +150 inverts the picture (C 1.17, hue 113°).

### 4. Sweeps: 2 synthetic frames and 6 real frames (temp 2500…20000 including as-shot; tint −150…+150)

The frames are `flat_grey`, `skin_tones`, 6929 (A7 IV), 2545 (GX85), 1346, 983, 3914 and 864, all at
`--long-edge 768`. Every sheet was opened, and 100 % sky crops of 2545 are in `$A/crop_2545_{temp,tint}_sky.png`.
Per-tile numbers are in `$A/sweeptable.txt`.

- a. [M] **Monotonicity.** Whole-frame OKLab `b` rises monotonically with temp on all 8 frames, and `a` rises
  monotonically with tint on all 8. No reversals inside ±150.
- b. [M] **No banding or posterisation** in the sky gradients at any setting (2545 crops). No inversion at the
  magenta end.
- c. [M] **Clipping is small.** The worst cases are blue-channel highlight clipping of 0.58 % on 864 at 2500 K,
  1.81 % on 1346 at tint +150 and 0.53 % on 6929 at +150. Shadow "crush any" reaches 10 % on 1346 at 2500 K and
  12.6 % on 3914 at tint −150. Both are dark charts and foliage driven to 0 in one channel.
  Scene-linear blue gain is 4.26× for a D65 frame at 2500 K and 3.81× at tint +150 (`$A/q1b`, inline).
- d. [M] **Lightness moves with WB in the display output, and not monotonically.** On `flat_grey` the mean
  display-linear luminance changes by −0.085 EV at 2500 K, +0.106 at 3200, +0.174 at 4000, +0.112 at 5000 and
  0 at as-shot; at tint +75 by +0.168 and at +150 by −0.048. The WB matrix alone keeps scene Y within 0.03 EV
  (−0.018 EV at 2500 K, −0.027 at +150), so the shift comes downstream of S6. **[G]** It is likely the display
  transform or gamut handling treating saturated colour as brighter or darker. That is not in WS-03's functions,
  so it is a NEEDS candidate. A Lightroom user would read it as "Temp changes exposure".
- e. [M] **Hue of non-neutrals.** Warm targets turn blue sky teal-grey (2545 at 12000–20000 K) and cool targets
  turn foliage cyan (6929 at 2500 K). Both are expected from a von-Kries move. The tint axis error in finding 3
  is the only hue defect I saw.
- f. [M] **Identity.** Rendering with temp/tint set to exactly the sidecar as-shot values gave a PNG
  **bit-identical** (`cmp`) to rendering with nothing set, on all 8 frames (`$A/sweeps/*_id0.png` vs `*_id1.png`).
- g. [M] The temp control is strong, as Lightroom's is. Mean ΔE00 against as-shot: about 21–27 at 2500 K and
  about 10–13 at 20000 K on the real frames.

### 5. [M+R] Slider scale: the mired axis puts 5500 K two-thirds of the way along and spends 31 % of the travel below 2850 K

Lumen `.reciprocal` maps 2000–50000 K linearly in mired, so K(p) = 1e6 / (500 − 480 p):

| travel | 0 % | 10 % | 25 % | 50 % | 75 % | 90 % | 100 % |
|---|---|---|---|---|---|---|---|
| Lumen K | 2000 | 2212 | 2632 | 3846 | 7143 | 14706 | 50000 |
| Lightroom K (community measurement, see below) | 2000 | 3000 | 4500 | 7000 | 12633 | 26642 | 50000 |

Where key values sit on the track:

| K | Lumen | Lightroom (measured model) |
|---|---|---|
| 2850 | 31 % | 8.5 % |
| 3200 | 39 % | 12 % |
| 5000 | 62.5 % | 30 % |
| 5500 | 66 % | 35 % |
| 6500 | 72 % | 45 % |
| 10000 | 83 % | 68 % |
| 20000 | 94 % | 85 % |

Lumen's step is a constant 4.8 mired per 1 % of travel. On the measured Lightroom model it is 10.8 mired per
1 % at 3000 K and 2.3 at 6500 K.

- **[R] Source.** A single community measurement of Lightroom Classic (Temp knob aligned against the linear
  Tint slider): 3650 K at 16.7 %, 5400 K at 33.3 %, 7000 K at 50 %, 15000 K at 79 %, 20000 K at 85.3 %,
  30000 K at 90 %. It was fitted as linear 100 K per 1 % up to 7000 K, then log
  (https://github.com/storytold/lightcraft/issues/1295).
- I found **no Adobe documentation** of the mapping. Treat it as unverified, roughly ±2 %.
- **[G]** On the Lumen axis the daylight working band (4000–8000 K) occupies 52–79 %, about 27 % of the track,
  against about 60 % on Lightroom's (if the measurement holds).

### 6. [M+R] Presets

The list is As Shot, then Daylight 5500/+10, Cloudy 6500/+10, Shade 7500/+10, Tungsten 2850/0,
Fluorescent 3800/+21 and Flash 5500/0 (`WhiteBalanceEngine.presets`). There is no Auto, no Custom entry
(Custom is a label only), and no eyedropper inside the menu.

- **Sources.** The Kelvin values match the commonly cited Camera Raw/Lightroom raw presets ("Daylight 5500,
  Cloudy 6500, Shade 7500, Tungsten 2850, Fluorescent 3800", https://blog.kepler1649c.keh.com/?p=63). I could
  **not verify the tints** (+10/+21/0) from any source.
- **[G]** In ACR these presets are computed per camera profile, so the displayed numbers may differ by camera.
- The numbers are the same as Lightroom's, but they mean different light (finding 1). I rendered a grey lit by
  each preset's Adobe illuminant with Lumen's same-numbered preset, as ΔE00 against neutral (`$A/q5.txt`):

| as-shot | Daylight | Cloudy | Shade | Tungsten | Fluorescent | Flash |
|---|---|---|---|---|---|---|
| 2850 / 0 | 2.97 | 2.61 | 2.39 | 0.00 | 2.39 | 2.97 |
| 5500 / +10 | 0.00 | 0.41 | 0.65 | 2.88 | 2.43 | 1.48 |
| D65 (synthetic) | 0.41 | 0.04 | 0.25 | 2.53 | 2.18 | 1.49 |
| 5500 / −15 | 3.51 | 3.54 | 3.58 | 4.12 | 5.17 | 2.18 |

- The presets are only right when the as-shot pair sits on the same side of the 3500–4500 K crossfade as the
  preset.
- `presetName` matches with ±1 tolerance in Lumen numbers, which is consistent with the presets as written.

### 7. [M] Auto WB ground truth: chart neutrals on 5 frames (`charts.json`)

The rectangles were checked visually: boxes are drawn on previews in `$A/charts/*_boxes*.png`. A
`lumen-render` render at the chart-neutral value leaves every mid-grey patch at |OKLab a|, |b| ≤ 0.0021 in the
8-bit output; the as-shot render leaves up to 0.037 (`$A/charts/*_chart-neutral.png`). No mid-grey patch is
clipped: the brightest patch used is 0.57, and the white patches are recorded with their max values. The
"Adobe est." column assumes the decode is a CAT16 adaptation (approximate).

| frame | chart | as-shot | chart-neutral (Lumen) | Adobe est. | as-shot residual C / ΔE00 | mid-grey R/G, B/G at as-shot |
|---|---|---|---|---|---|---|
| 1346 5D | CC Passport | 5426 / −3.9 | 5348 / −9.3 | 5454 / −7.6 | 0.0027 / 1.21 | 1.011, 1.025 |
| 967 A7 II | CC Passport | 4840 / +10.9 | 4826 / +16.8 | 4740 / +15.5 | 0.0052 / 2.10 | 0.996, 0.946 |
| 983 5D IV | **SpyderCheckr 24** (not a CC; uses greys E2–E5) | 5096 / +15.5 | 4896 / +12.2 | 4947 / +13.1 | 0.0032 / 1.26 | 1.021, 0.978 |
| 3914 X-T4 | CC Classic | 4708 / +48.2 | 5149 / +30.9 | 5456 / +32.2 | **0.0311 / 9.68** | 0.984, 1.377 |
| 864 X-T2 | Kosmos printed grey card (steps 4–8 + main field) | 9365 / +16.4 | 10021 / +5.6 | 11024 / +11.2 | 0.0098 / 3.57 | 0.995, 1.108 |

- **[G]** The 3914 as-shot is far off (greys B/G 1.38). The likely cause is the LibRaw decode's X-Trans as-shot
  multipliers or matrix rather than the camera itself; CORPUS.md says the as-shot K here is approximate. Apple's
  decode may differ, so a spec should treat 3914's as-shot residual as a property of this corpus.
- **[G]** 864 is a printed (inkjet/litho) card on a blue cloth, and its greys may not be spectrally neutral, so
  give it lower weight.

**Naive whole-frame estimators**, as a difficulty gauge. Each is solved with the same model; the residual is on
the chart's mid-greys.

| frame | grey-world K / tint | grey-world ΔE00 | white-patch (top 1 % luminance, unclipped) K / tint | white-patch ΔE00 |
|---|---|---|---|---|
| 1346 | 4900 / −7.2 (+17 mired) | 3.91 | 5102 / −5.5 | 2.77 |
| 967 | 4485 / 0.0 (+16 mired, −17 tint) | 3.92 | 4440 / +17.2 (+18 mired) | 4.18 |
| 983 | 5437 / +7.7 (−20 mired) | 5.29 | 4861 / +13.6 | 0.82 |
| 3914 | 5076 / +80.2 (+49 tint) | 15.65 | 4443 / +57.5 | 14.62 |
| 864 | 9855 / −9.6 | 2.88 | 9617 / +13.9 | 2.57 |

- Grey-world beats the as-shot only on 864 (2.88 against 3.57). White-patch beats it only on 983 (0.82
  against 1.26) and 864 (2.57 against 3.57).
- Foliage-dominated 3914 pulls grey-world toward magenta (+80 tint).
- The camera's as-shot is the best of the three on 1346, 967 and 3914. Any Auto must at least not do worse
  than as-shot on these frames.

### 8. Smaller items

- [M] **Comment mismatch.** The header comment on `ColorTemperature` says "Planckian below 4000 K, daylight at
  and above 4000 K". The code crossfades over 3500–4500 K.
- [M] **The as-shot pair is clamped by the magenta guard as well** (`lumen_xy` on the destination). On a warm
  as-shot with a large positive tint (for example 2200 K / +20, where the limit is +13.8), the render adapts from
  a point that is not the file's neutral. None of the corpus as-shot pairs hit this: the highest is
  3914 at +48 / 4708 K, against a limit of +125.
- [M] **Range.** The Temp slider runs 2000–50000 and Tint ±150 soft / ±300 hard. Lightroom raw is 2000–50000
  and ±150 [R: search results; no Adobe primary page found].

---

## What a spec writer should take from this

1. **The main defect is the convention** (findings 1–3, 6). The minimal fix is for `ColorTemperature.chromaticity`
   (or `WhiteBalanceEngine`) to speak the DNG convention: `DNGTemperature.chromaticity` already exists and is
   tested. Two things follow from that:
   - the magenta guard must be re-derived on the new axis;
   - existing tests that pin Lumen's locus will have to change: `ColorScienceTests.testTheLocusPassesThroughTheStandardIlluminants`,
     `testTemperatureRoundTrip`, `TintGuardTests` (pinned limits, e.g. +152.22 at 5500 K) and
     `EngineMathFixtureTests`/`MaskWhiteBalanceTests` if they use the locus. **[G: I did not read every one of them.]**
2. **Measurable targets:**
   - typing the Adobe pair of an illuminant neutralises its grey to ΔE00 < 0.5, against today's median 2.4 and max 5.4;
   - ±tint moves the grey along OKLab hue 145–160° / 320–330° at daylight, against today's 112° / 289°;
   - presets match their Adobe chromaticity.
3. **Slider travel (finding 5) is a judgement call.** The Lightroom mapping is not documented by Adobe.
4. **The lightness shift in 4d** belongs to another lane.
5. **For Auto:** use the `charts.json` targets. The bar to beat is the as-shot residual: ΔE00 1.2 / 2.1 / 1.3 /
   9.7 / 3.6.

Evidence (before):
- `evidence/before_tint_axis_skin_tones.png`
- `evidence/before_tint_2545_gx85.png`
- `evidence/before_temp_6929_a7iv.png`
- `evidence/before_3914_asshot_vs_chartneutral.png` (left: as-shot, blue greys; right: chart-neutral 5149/+30.9)
