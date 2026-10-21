# WS-04 Exposure — Audit

Auditor pass, branch `quality/ws-04-exposure`. No source changed.

Scope (owned): `ToneEngine.exposureGain` (ToneEngine.swift:481), `LinearStage`
(WhiteBalanceEngine.swift:333), `RG.applyMatrix` (RenderGraph.swift:845), RenderPlan `---- S6`
block (RenderPlan.swift:192-208), and the BasicPanel Exposure slider literal (BasicPanel.swift:466).

Evidence lives in `docs/quality/lanes/WS-04/audit/`:

| file | what |
|---|---|
| `harness_main.swift.txt` | the scratch harness, a SwiftPM executable that depends on LumenCore by path. Modes: `s6`, `equiv`, `grey`, `mono`, `hue`, `roll` |
| `harness_s6_grey_roll.txt`, `harness_equiv.txt`, `harness_mono.txt`, `harness_hue.txt` | harness output |
| `sweep.sh.txt` | the sweep commands (lumen-render release build, LUT 33, sRGB, dither on) |
| `sweep_<frame>.png/.json`, `log_<frame>.txt`, `tiles_<frame>/` | `lumen-render sweep --key develop.tone.exposure`, real frames at −2…+3, synthetic frames at −3…+4 |
| `crop100_<frame>.png` | 100 % crops at EV 0 / +2 / +3 from `render --long-edge 0` renders |

How the harness is run: put `harness_main.swift.txt` at `Sources/H/main.swift` in a package
that has `.package(path: "/home/user/lumen")` and depends on product `LumenCore`. Then run
`swift build -c release` followed by `.build/release/H <mode>`. Every harness render uses
`ReferenceRenderer.render` with a `RenderPlan` at as-shot D65 (6503.7 K / +9.77). It reports
encoded sRGB codes before rounding, with no dither. OKLab is computed from linear sRGB using
Ottosson's matrices. The "exact" columns use `RenderPlan.exactColor`, which bypasses the finish
LUT.

**Lightroom references:** `corpus/lightroom` does not exist, so there are no LR exports to
compare against. Finding 9 compares against published PV2012 behaviour instead.

---

## Summary

The owned code is correct. Exposure is an exact scene-linear gain of 2^EV. It is applied once,
in S6, before every other stage. It renders bit-for-bit identically to pre-scaling the input,
whatever else the recipe sets. Nothing downstream reads `tone.exposure`. EV 0 is bit-exact
identity. The response is monotone at every scene level from −5 to +5 EV.

Every visual defect found under an Exposure sweep comes from the display transform or its
finish table (WS-13), not from S6. The defects are:

- hue twist of orange, skin and deep blue toward white;
- a fixed +8…+11° purple bias on blues;
- a per-channel encode clamp;
- the 33-point finish table's piecewise-linear kink at mid-grey.

There are two small WS-04 items: the fp16 headroom of the GPU twin and the out-of-range recipe
value. There is one small UI item.

---

## Findings

### 1. CORRECT: S6 is exactly 2^EV, for all values and signs (owner WS-04)

- `LinearStage.matrix` = `diag(2^EV · printerLights) · WB`. Compared `M(EV)` with
  `2^EV·M(0)` for:
  - EV ∈ {±10, ±5, ±3, ±1, 2};
  - WB as-shot, 3200 K and 9000 K (as-shot 5000 K);
  - Printer Lights r = 0 and r = +3 / b = −3.

  Max relative error was **0.0**. Probes (v, 0.5v, −0.3v) with v ∈ {−1, −0.01, −1e-6, 0, 1e-6,
  0.001, 0.18, 1, 5.76, 64, 1000, 65504} gave **0.0** relative error. Output: `harness_s6_grey_roll.txt` §A.
- Through the Float32 `ImageBuffer`, EV +1 gives out/in = 2.000000 and EV −1 gives 0.500000,
  for every value from −1 to 1000. This includes negatives, which are kept rather than clamped.
- Clamp: `exposureGain` clamps to ±10. EV 11 gives a gain of 1024, the same as EV 10. See finding 8.

### 2. CORRECT: Exposure is a pure gain end to end; nothing downstream depends on it (owner WS-04)

- Code path. `tone.exposure` is read in exactly one renderer place, `ToneEngine.exposureGain`,
  which feeds `LinearStage` in the S6 block.
  - `ToneEngine.isIdentity`, the white and black anchors, the contrast pivot, the grade-LUT
    key and `DisplayTransform.forRecipe` do not read it.
  - `AutoTone` resets `develop.tone` to `Tone()` before it measures (AppStateActions.swift:41).
  - The `S7` tone mask, S8 presence, masks (S11), vignette (S13), film chain, grain and the
    finish table all run on the already-scaled image.
  - The other `exposure` reads are separate controls: local mask exposure in
    ReferenceRenderer.swift:340-377 and RenderGraph.swift:1268, and Film Lab exposure.
- Measured as **render(R with EV k, x) ≡ render(R, 2^k·x)**. Tested on a 403-pixel ramp over
  ±10 EV with neutral, blue, warm and red pixels, plus negatives and 100+ highlights, at k ∈ {−2, +1, +3}.
  - Recipes: default, tone stack (Contrast 40 / Highlights −60 / Shadows 50 / Whites 30 /
    Blacks −20), zones, saturation and vibrance, grade wheels, Punchy, Linear, vignette −50,
    clarity + dehaze, Film Lab portra400, and WB 4200 K.
  - Max |code difference| = **0.000000 for every recipe** (`harness_equiv.txt`).
- Consequences, all as intended:
  - Highlights, Shadows, Whites, Blacks and the zones work on post-exposure scene EV. Exposure
    moves pixels into different tone windows, which is the Lightroom order.
  - Luminance-range masks select on post-exposure luminance, on both CPU and GPU, because both
    build the mask source after S6.
  - S3 classical NR runs before S6, so NR strength does not depend on Exposure. The noise
    profile is ISO-based, so that is correct.

### 3. CORRECT: mid-grey placement and EV 0 identity (owner WS-04 for the gain, WS-13 for the curve)

`harness_s6_grey_roll.txt` §C. Scene 0.18 (neutral) maps as follows. "LUT33" is the shipped
interactive table and "exact" bypasses it. Each value is a pre-rounding sRGB code.

| EV | −3 | −2 | −1 | 0 | +1 | +2 | +3 |
|---|---|---|---|---|---|---|---|
| code, LUT33 | 20.32 | 41.29 | 72.72 | **117.65** | 168.74 | 207.17 | 234.51 |
| code, exact | 20.32 | 39.44 | 70.41 | 117.65 | 168.58 | 207.45 | 234.51 |
| code(0.18·2^k at EV 0) | 20.32 | 41.29 | 72.72 | 117.65 | 168.74 | 207.17 | 234.51 |
| display-linear Y | 0.0072 | 0.0225 | 0.0661 | **0.1800** | 0.3954 | 0.6251 | 0.8269 |

- 0.18 lands on exactly 0.18 display-linear (sRGB 118) at EV 0, which matches the
  DisplayTransform's construction. Row 1 equals row 3 at every k, so the gain is exact.
- EV 0 is bit-exact. `render` with no key, with `--set develop.tone.exposure=0` and with `=-0.0`
  produce byte-identical PNGs (`cmp`). EV 0.001 changes 10.5 % of pixels by at most 1 code,
  so 0.001 is not a dead zone.
- The display stops per scene stop are asymmetric: +1 EV is +1.14 display stops and −1 EV is
  −1.45. The cause is the transform's contrast 1.5 log-log slope and its toe. On real photos the
  mean display-linear luminance moves −2.2…−3.0 stops at EV −2 and +1.7…+2.35 stops at EV +2
  (`log_*.txt`, column `dMeanEV`). This is the display transform's character (WS-13), not a
  gain error.

### 4. CORRECT (S6) / WS-13 defect: monotone, but the 33-point finish table puts kinks in the EV response

`harness_mono.txt`. Ten scene levels from 0.001 to 64 were swept over EV −5…+5 in 0.01 steps
(1001 values), through LUT33, LUT65 and the exact transform.

- **Non-monotonic steps: 0** at every level and in all three modes.
- Step per 0.01 EV at grey: at most 0.636 codes (LUT33) against 0.570 (exact). Grey at EV
  −0.03…+0.03 reads 116.43, 116.84, 117.24, 117.65, 118.28, 118.91, 119.54, with no step and no
  dead zone.
- Dead ranges occur only below the black anchor (scene 0.18·2^−9). For example, scene 0.001 is
  flat at black for EV −5…−1.51. That is the intended black-point clamp, and it lies inside
  `blackAnchorEV` (WS-13 or Blacks).
- **WS-13 defect.** The interactive finish table (`LUT3D.interactiveSize` = 33 over the 24-EV
  `LumenLog` domain, so 0.75 EV per cell) makes the response piecewise linear in EV:
  - The second difference of code against EV is **0.34** for LUT33, 0.16 for LUT65 and 0.002
    for exact, so LUT33 is about 160× rougher.
  - At grey the slope is 0.40 codes per 0.01 EV just below EV 0 and 0.64 just above, while the
    exact slope is 0.57 on both sides. That is a 1.6× slope break exactly at mid-grey, because
    0.18 sits on a grid node.
  - The table also misplaces grey by up to **2.3 codes** (EV −1: 72.72 against 70.41 exact)
    and skin hue by up to **5.5°** (finding 5).
  - On a smooth gradient this is a Mach-band risk, and it is what the user sees while dragging.
  - Export uses 65, which halves the error.

### 5. WS-13 defect: highlight hue twist and bleaching path; S6 contributes 0° (attribution proven)

`harness_hue.txt`. The table reports the OKLab hue of the shipped (clamped) sRGB output and,
in brackets in the file, the exact and unclamped values. **dh** is relative to the scene
colour's own OKLab hue. OKLab hue is invariant under scaling, and finding 2 proves the render
is a pure pre-scale, so every degree below comes from the display transform, its table or the
final encode clamp. S6 contributes none.

| patch (linear Rec.2020) | scene h | EV −3 | −1 | 0 | +1 | +2 | +3 | +4 | chroma at EV 0 → +3 |
|---|---|---|---|---|---|---|---|---|---|
| sky blue (0.05, 0.12, 0.35) | 244.1 | +8.6 | +8.4 | +8.4 | +6.8 | +7.1 | +6.9 | −3.4 | 0.124 → 0.087 |
| deep blue (0.02, 0.03, 0.30) | 259.8 | +11.0 | +11.3 | +10.9 | +11.0 | **+15.4** | **+23.2** | **+33.6** | 0.174 → 0.181 |
| skin (0.45, 0.30, 0.22) | 41.0 | −3.1 | +3.9 | −0.1 | +4.0 | +4.3 | **+19.9** | (C 0.002) | 0.062 → 0.023 |
| dark skin (0.20, 0.12, 0.08) | 41.0 | +2.2 | +2.3 | +2.1 | +3.0 | +2.7 | +3.5 | +10.2 | 0.058 → 0.069 |
| saturated red (0.45, 0.04, 0.03) | 22.7 | −0.3 | −0.2 | −0.2 | −0.1 | −0.6 | +0.7 | +9.9 | 0.222 → 0.121 |
| orange (0.55, 0.22, 0.03) | 54.4 | +2.0 | +0.7 | +3.5 | **+8.6** | **+21.7** | **+32.9** | +46.9 | 0.151 → 0.082 |
| saturated green (0.06, 0.30, 0.05) | 152.3 | −5.7 | −6.0 | −5.8 | −5.9 | −4.0 | −1.3 | −2.9 | 0.186 → 0.201 |
| foliage (0.08, 0.14, 0.04) | 138.8 | 0.0 | +0.6 | −0.1 | +0.3 | −0.1 | −1.2 | −2.4 | 0.096 → 0.147 |

Highlights roll off rather than clipping hard, which is good. Chroma falls smoothly toward
white, as the path-to-white ramp intends. Neutrals compress: at +1 EV a scene value of 1.5
renders 250.0 and 3.0 renders 254.7 (§F). Blue sky never goes cyan, and red, green and
foliage are stable within 6°. The defects, all owned by WS-13, are:

- **a) Orange goes yellow, +22° at +2 and +33° at +3.**
  - Unclamped, the drift is +10° at +2 and +23° at +3. Roughly half the drift is the transform's
    per-channel shoulder. The other half is the **final per-channel clamp to [0, 1] in the sRGB
    encode**: R exceeds 1.0 after the outset matrix and the Rec.2020 → sRGB conversion, because
    `apply(_:gamut:)` is not given a gamut boundary on the finish path.
- **b) Skin goes yellow at +3: +20° (61° against 41°).**
  - Exact unclamped is +4.6°. Most of it is the encode clamp at R = 255, from EV +2 onward.
  - Visible in `sweep_skin_tones.png` at +3 and +4, where the light patches turn cream or
    yellow. The rule that "skin must not go yellow" fails from +2.5 EV.
- **c) Deep blue turns purple as it brightens: +11° baseline, then +15° at +2, +23° at +3 and
  +34° at +4.**
  - This is the known `rotation.b = +0.06` defect documented in
    DisplayTransformParams. Sky blue keeps a constant +7…+8° purple bias.
  - The rule that "blue must not go purple" fails for saturated blue from +2 EV.
- **d) The LUT33 table adds ±3…5° hue noise on low-chroma skin.** At EV 0 skin reads h 40.9
  through LUT33 against 43.7 exact. At EV −3 it reads 37.9 against 43.4.
- **e) `sweep_hue_wheel.png` shows two seams at every EV.** One is a radial seam in the blue
  sector, near the 7 o'clock position. The other is a lobe boundary in the cyan half-radius.
  Brightening makes both more visible: at +3 and +4 blue bleaches to lavender and cyan stays
  saturated longer. These seams exist at EV 0, so they belong to the transform and gamut handling.

### 6. Real photographs: correct gain, smooth roll-off, no artefacts from S6 (owner: notes only)

Eight corpus frames were swept at −2…+3 with as-shot K, tint and ISO from the sidecars
(`sweep.sh.txt`). Frames: Sony A7 IV 6929 and 6933, Panasonic GX85 2545, GX80 1569, G9 2348,
Fujifilm X-H2 6001, Nikon D850 1840 and Canon R5 4694. Five synthetic frames were swept at
−3…+4: skin_tones, flat_grey, grey_ramp, colorchecker and hue_wheel. I looked at every sheet,
and at 100 % crops for GX85 sky, A7 IV white wall and bricks, GX80 sky through trees, and X-H2
overcast sky.

- **Zone tables, consistent across all eight photos.**
  - At +1 EV: zones 2–4 move +42…+50 codes, zone 0 +13…+18, zone 8 +22…+28.
  - At −1 EV: zones 4–6 move −44…−50, zone 0 −7…−11.
  - This is the expected shape of one stop through an S-curve with a soft shoulder.
- **ΔE00 against EV 0:** at +1 the mean is 7.8–13.9 and the p95 16–20. At +2 the mean is
  18–29. Clipping (any channel at 255) is 0 % at +1 for every photo, 0–0.6 % at +2, and
  0.05–5.5 % at +3: GX85 5.0 %, X-H2 5.5 %, G9 3.5 %, GX80 3.3 %.
- **100 % crops** (`crop100_*.png`):
  - GX85 sky bleaches smoothly to white through +3. Measured over a 200×200 patch: scene hue
    251.1°; render 256.2° at 0, 256.6° at +2, 254.3° at +3. That is stable, with no cyan and
    no banding.
  - A7 IV white wall and brick go to white without posterisation at the clip boundary. There
    are no per-channel colour fringes.
  - GX80 backlit foliage edges against the sky show no halo. Exposure is not spatial, and the
    S7 tone mask is skipped when tone is at identity.
- **The X-H2 overcast sky is lilac at every EV.**
  - Its scene value is already purple: mean Rec.2020 (0.54, 0.54, 0.83), h 283°.
  - The render adds +4°. The cause is the LibRaw decode (corpus) plus finding 5c. It is not
    Exposure.
  - The sensor-clipped patch inside it renders neutral, as `CORPUS.md` predicts.
- Absolute levels are about 0.2–0.4 EV darker than Apple's decode would be (`CORPUS.md`), so I
  make no claim about the "right" default brightness.

### 7. GPU twin `RG.applyMatrix` (owner WS-04): matches the CPU; one fp16 headroom risk (not runnable here)

- `CIColorMatrix` is fed `rVector = row 0`, `gVector = row 1` and `bVector = row 2` of
  `Mat3.m`, so it computes `out.r = dot(in, row0)`. That equals `Mat3.apply` (ColorMath.swift:103),
  which means **M, not M^T**. The bias is 0 and alpha passes through.
- Neither path clamps, so negatives and >1 values survive on both. The identity skip uses the
  same 1e-12 test as `LinearStage.isIdentity`.
- **Risk (WS-04, low).** The main context works in **RGBAh, half-float with a maximum of 65504**
  (PipelineRenderer.swift:79), and the decode cache is RGBAh too.
  - The CPU reference is Float32. At hard-range EV +10, any scene value ≥ 64 (a specular
    highlight, or a +6 EV light source in a RAW) becomes ≥ 65536 and overflows to +inf in fp16.
  - Downstream, the inset/outset matrices have negative off-diagonals. inf − inf gives NaN, so
    such a pixel could render black or NaN on GPU while the CPU renders white.
  - At the slider's soft limit (+5, ×32) the threshold is 2047, which is unreachable in practice.
  - Suggested spec line: S6 output finite on the GPU for inputs up to 1e4 at EV +10, or clamp
    the S6 output to the fp16 maximum.
  - Not testable on Linux, so a macOS golden is needed.
- Under-range: 0.001 × 2^−10 ≈ 1e-6 is an fp16 subnormal, quantised to about 6 %. It sits
  below the black anchor (3.5e-4), so it is invisible.

### 8. Recipe clamp and UI (owner WS-04; UI notes)

**Correct:**
- BasicPanel Exposure: range −5…5, hard range −10…10 for typing, default 0, step 0.01, two
  decimals, and the label resets on double-click (`onTapGesture(count: 2) { reset() }`,
  LumenControls.swift:690).
- `Lumen.ToneRow.exposure` uses the same −5…5 / −10…10 / 0.01 (LumenControls.swift:2305-2313).
- SpeedEdit uses −5…5 / 0.01. `ToneEngine.exposureGain` clamps at ±10 to match the hard range.
- The help text ("+1 doubles the light, exactly like opening the aperture a stop") is
  **true**, by findings 1 and 2.

**Minor defects:**
- a) **Silent clamp mismatch.** A recipe holding `exposure: 12` (from a sidecar, the API or the
  CLI) renders byte-identically to +10. `cmp` confirms this, and so does −12 against −10.
  - The recipe keeps 12 and nothing normalizes or reports it, so the readout would show a
    number the render does not use.
  - `lumen-render` reports no `effectiveValue` change for it.
  - Fix: either normalize at decode, or clamp the binder display.
- b) **The histogram exposure drag (HistogramView.setTone) resolves through `ToneRow.resolve`,
  which clamps to −5…5.**
  - A typed value of +7 snaps to +5 on the first histogram drag event.
  - Arguably correct, since drag pins to the range, but the slider and histogram should state
    the same rule.
  - This is UI (LumenApp), not a render issue.
- c) `Num.clamp` passes NaN through, so `pow(2, NaN)` makes the whole frame NaN. JSON cannot
  carry NaN, so I rate this informational.

### 9. Comparison with Lightroom PV2012 (no reference exports; documentation and known behaviour)

Sources:
- Adobe's help page for tone controls: helpx.adobe.com/lightroom-classic/help/tone-control-adjustment.html
- M. Evening's PV2012 Exposure description: peachpit.com/articles/article.aspx?p=1930485

What Adobe documents:
- PV2012 Exposure sets midtone brightness and highlight clipping together.
- It "soft clips" highlights as they approach the clip point, which gives about one stop more
  latitude than PV2010.
- It affects midtones more than the highlights and shadows.
- Adobe's workflow advice is to set Exposure first.

Where Lumen will **match**:
- Midtones move about one stop per EV. Lumen measures grey +1.14 / −1.45 display stops.
- Highlights roll off rather than clip. In Lumen, scene 0.9 at +2 EV renders 252.3, not 255.
- Exposure is the first tonal operation, and the other tone sliders work around it.

Where Lumen will **differ**:

- **Content-independent.** Lumen's Exposure is a strict scene gain followed by a fixed curve,
  with its white anchor at +5 EV over grey.
  - After +k EV, everything above 0.18·2^(5−k) is display white: 0.72 scene at +3, 1.44 at +2.
  - LR's PV2012 roll-off is widely described as image-adaptive: its highlight compression
    depends on the frame's own highlight distribution.
  - On a frame with large bright areas, LR at +2/+3 will hold more highlight separation than
    Lumen. Lumen is more predictable: +1 is always the aperture stop the help text promises.
- **Asymmetry.** Lumen darkens more per stop (−1.45) than it brightens (+1.14) through the toe.
  LR's −EV is generally gentler in the deep shadows because its default curve has a lifted toe.
  Expect Lumen at −2 to look darker and more crushed than LR at −2.
  - Measured: zone 0 at EV −2 moves −11…−16 codes, and EV −2 is −2.2…−3.0 display stops on photos.
- **Hue in highlights.** LR's RGB tone curve in ProPhoto also yellows bright oranges, so finding
  5a is partly LR-like. But Lumen's skin goes +20° yellow at +3 (finding 5b) and deep blue goes
  +23° purple (finding 5c). Those Lumen behaviours come from WS-13, not exposure.
- **Interactive-preview kink.** LR has no 33-point log-domain table in its preview path; this
  is finding 4.

---

## Owner roll-up

| # | verdict | owner |
|---|---|---|
| 1 | S6 gain exact (0.0 rel err), negatives preserved | WS-04 CORRECT |
| 2 | render(EV k, x) ≡ render(2^k x), 0.000 code diff on 11 recipes; no other exposure reads | WS-04 CORRECT |
| 3 | 0.18 → 117.65 (Y 0.180), EV 0 bit-exact | WS-04 CORRECT |
| 4 | monotone everywhere; LUT33 kink 1.6× at grey, grey error up to 2.3 codes | WS-13 (finish table) |
| 5 | orange +22°/+33°, skin +20° (clamp), deep blue +15…+34° purple at +2…+4 | WS-13 (transform, encode clamp, rotation.b) |
| 6 | real photos smooth, no S6 artefacts; X-H2 lilac sky is decode | notes / corpus |
| 7 | GPU applyMatrix = CPU (M, no clamp); fp16 overflow ≥ 64 at EV +10 | WS-04 (low) |
| 8 | ±10 silent clamp leaves an un-normalized recipe value; histogram ±5 snap | WS-04 (minor) / UI |
| 9 | LR: midtones match; Lumen is non-adaptive, darker at −EV, skin and blue twist via WS-13 | info |
