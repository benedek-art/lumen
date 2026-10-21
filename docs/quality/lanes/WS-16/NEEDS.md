# WS-16 needs from other lanes

These are changes WS-16 cannot make inside its owned functions. Each item names the owner, the
evidence and the target.

## N1. Hue-preserving gamut mapping to the output space (owner: WS-13 DisplayTransform, with WS-12 for the encode)

**Problem.** S9 holds OKLab hue to 0.002 deg, measured as HUE-1 in `SPEC.md`. In the PNG, though,
Saturation and Vibrance pushes turn hue. The cause is downstream of S9:

1. `DisplayTransform` soft-clips to the Rec.2020 boundary (`Gamut.sharedBoundary`).
2. The sRGB (or P3) encode then hard-clamps each channel.

Hard-clamping a colour that is out of gamut on one channel rotates its hue.

**Evidence** (WS-16 audit F5, current code):

- ColorChecker, Sat +100: output max |dh| 15.6 deg and mean 3.3 deg. The worst patches are cyan
  (+15.6), orange (-13.2) and orange-yellow (-10.7).
- ColorChecker, Sat +50: max |dh| 8.8 deg.
- ColorChecker, Sat -50: dark skin drifts -8 deg, even though the stage drift is 0.001 deg.
- Real photos at Sat +100: p95 |dh| is 3-10 deg. On 2242 the orange pieces turn red and pink.
- At the stage output, 10 of 18 chromatic ColorChecker patches have a negative sRGB channel at Sat +100.
- hue_wheel pixels with a channel at 0 go from 22.6% to 48.0%.

**What WS-16 does about it.** SAT-4 keeps every push inside Rec.2020, and SAT-5 approaches that
boundary softly. That removes any need for the display transform's Rec.2020 clip on pushed colours,
but it cannot fix the sRGB clamp.

**Ask.** Map from the working space to the output gamut (sRGB, P3) in a hue-preserving way:
constant OKLab hue, with chroma compressed toward the output boundary at constant lightness (or
along a lightness/chroma cusp path), before the encode clamps.

**Targets** to verify, once N1 and WS-16 have both landed, with `m_saturation.py`-style output
measurement (OKLab of the PNG, colorchecker patches with C > 0.02, render at V vs 0):

- Sat +50: max |dh| <= 2 deg. Sat +100: max |dh| <= 3 deg.
- Sat -50: max |dh| <= 1 deg.
- hue_wheel at Sat +100: no hue band where |dh| > 3 deg.

## N2. B&W band centres and names (owner: whoever owns `ColorEngine.bandHueCentres`; it is shared with the Colour Mixer, WS-31)

**Problem.** The centres are 29.2 deg + 45 deg x i in Lumen OKLab, so "Orange" sits at 74 deg
(yellow-orange) and "Yellow" at 119 deg (yellow-green). Measured at band -100 (audit F10):

- Orange moves orange-yellow by -178 codes, but orange by only -51.
- Yellow moves yellow-green by -180, but yellow by only -39.
- Red is the band that moves the skin patches. In Lightroom, Orange is the skin slider.

**Ask.** Decide whether the B&W mixer should use Lightroom-like centres. In this OKLab that means
roughly red 25, orange 55, yellow 95, green 140, aqua 195, blue 255, purple 300, magenta 340. A B&W
array of its own would make that possible without moving the Mixer's handles.

WS-16's BW lines are measured at whatever centres the code has, so they do not depend on this.

## N3. Skin band used by `skinWeight` and the vectorscope skin line (owner: Scopes / Skin tools)

**Problem.** `skinLineDegrees` = 56.4 and `skinBandDegrees` = 10 make `skinWeight` miss most real
skin while scoring ColorChecker orange as skin. Measured with `ws16probe skinweight`:

| patch | hue / chroma | skinWeight |
|---|---|---|
| CC light skin | h 40.7 | 0 |
| CC dark skin | h 42.3 | 0.08 |
| MST 1 | h 67.6, C 0.015 | 0 |
| MST 3 | h 84.6 | 0 |
| MST 4 | h 84.6 | 0 |
| MST 5 | h 77.8 | 0 |
| MST 6 | h 70.5 | 0.09 |
| MST 7 | h 54.2 | 1 |
| MST 8 | h 43.6 | 0.33 |
| CC orange | h 53.6, C 0.152 | **1** |

Measured skin spans h 40-85 deg at C <= 0.07. ColorChecker orange and orange-yellow sit inside that
hue range but at C >= 0.149.

**What WS-16 does about it.** WS-16 gives `skinProtectionWeight` its own band constants (SPEC
decision 3). It leaves `skinWeight`, `skinLineDegrees` and `skinBandDegrees` unchanged, because the
vectorscope graticule (`Scopes.swift: skinToneLineDegrees`, `skinBandHalfWidthDegrees`) and the
Skin-tool tests read them.

**Ask.** Re-derive the skin selection band, using the same hue and chroma plausibility WS-16 lands
for protection. Decide whether the vectorscope's I-bar line should stay at 56.4 deg as a graticule
mark while the selection band widens.

## N4. Product decisions (owner: product / integrator)

- **Default B&W mix.** Today it is plain Rec.2020 luminance. Lightroom uses an image-adaptive default
  mix (Adobe Monochrome or Auto) that generally lifts reds and yellows and darkens blues. Saturation
  -100 gives a different grey: it holds H-K brightness, and differs from the B&W default by up to
  11 codes on the colorchecker and 24 on the hue_wheel. Should there be an "Auto" mix, and should
  the two greys converge? (audit F11)
- **Density default.** WS-16 recommends changing the `ColorAdjust.density` default from 50 to 0, so
  that Saturation alone is a plain, luminance-neutral chroma scale. Stored recipes keep their value.
  If the integrator would rather keep 50 as a bipolar neutral, the meaning of stored values changes,
  which is a recipe-format decision.

## N5. Preview-cache rendering revision (owner: integrator / Catalog, `PreviewCache.renderingRevision`)

**Problem.** WS-16 changes what S9 renders for every recipe with Saturation, Vibrance or a B&W mix,
and it changes the `ColorAdjust.density` default from 50 to 0. The canonical recipe form is sparse
against `Recipe()`, so a recipe whose Density was never touched keeps the same canonical JSON and the
same `recipe_fp`, while its Saturation pushes now render brightness-neutral instead of 0.19 EV darker.
A stored preview keyed on that fingerprint would be served stale.

**Ask.** Bump `PreviewCache.renderingRevision` (8 → 9, or once for every lane landing together)
when WS-16 merges. Comment text: "9: S9 Saturation/Vibrance/Density/Protect Skin and the B&W mix were
redefined (WS-16), and Density's default moved from 50 to 0."

## N6. Proof-registry rows WS-16 made stale (owner: WS-58, `Tests/LumenCoreTests/Proof/ProofRegistry.swift`)

The registry is append-only for other lanes, so WS-16 changed only what its tests require:

- **Edited (required): the `bw.*` authority floor, 107 → 44.** `testEveryRegisteredControlHasVisibleAuthority`
  fails without it. The old floor (0.7 of aqua's 153.13) measured a band at −100 sending its colours to
  black. The response is now ±2 EV at full chroma by design (SPEC BW-1..BW-3), and the weakest band on the
  colour chart measures 63.16 (blue; the chart's blue and purple patches are dark). 44 is 0.7 of that, the
  same rule as before. WS-58 must accept or re-derive it.
- **Not edited, now stale:**
  - The `color.protectSkin` row's comment (~line 282) says it "attenuates Vibrance (both signs)". Since
    WS-16 it attenuates pushes only. Its companion (Vibrance +80) is a push, so the measurement is still
    valid.
  - The `color.density` row declares `neutral: 50` and its comment calls the control "gated". The default
    is now 0; the companion (Saturation 60) still makes it live.
  - The `blackAndWhite` docstring still says a full-negative band takes its hue to BLACK
    (`1 + w·gate·band/100·bwKappa`). It is now `2^(w·gate·band/100·bwKappa)` with `bwKappa` = 2 EV.
- The proof records for `color.saturation`, `color.vibrance`, `color.density`, `color.protectSkin` and
  `bw.*` were re-recorded by WS-16 (`LUMEN_RECORD_PROOFS=1`). The moves are fixes. The main ones are
  hueRotation dropping on Saturation and Vibrance, and B&W authority following the new EV response.

## N7. Control inventory citations (owner: whoever maintains `docs/quality/controls.json` / `controls.md`)

WS-16 rewrote `BasicPanel.saturationRows`, so the slider call sites moved. The new lines are:
- Vibrance: 659
- Saturation: 667
- Density: 675
- Protect Skin: 682

`Tests/LumenAppTests/LayoutMetricSupport.swift` is updated (its self-test fails otherwise).
`docs/quality/controls.json` and `controls.md` still cite 674/681/694/705, along with the old engine line numbers and
the "additive vs subtractive (per-channel gamma)" Density description. Those docs are outside the lane
folder, so WS-16 does not edit them.
