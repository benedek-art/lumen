# WS-05 audit: Highlights, Shadows, Whites, Blacks (before)

Auditor pass on branch `quality/ws-05-zonal-tone`, no code changed. All renders use the
release `lumen-render` through `ReferenceRenderer` (the CPU definition), with `--no-dither`
and the sidecar as-shot Kelvin/tint. There are no Lightroom reference exports
(`corpus/lightroom/` is missing). Lightroom comparisons below come from documented
Camera Raw behaviour, so they are expectations and not measured references.

Scratchpad root (call it `$A` below):
`/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/audit`

## Owner complaint: "the highlights, the blue highlights are funky"

**Confirmed and located.** The tone gain itself does not cause it. S7 multiplies RGB by a
scalar in scene-linear, so it preserves hue. The cause is downstream: the display transform
bends the hue of bright saturated blues toward violet, magenta and finally pink as their
luminance rises. Highlights and Whites move pixels along that bent path, so moving them
changes the hue. Whites also moves the shoulder itself (through the white anchor), so it
changes the hue of blues that the tone gain does not touch at all.

Evidence: `evidence/before_sky_probe_blue_to_purple.png`. Each row is one constant scene
chromaticity at -1…+5 EV of luminance. The panels are Highlights -100 / default /
Highlights +100 / Whites -100 / Whites +100. The sRGB-blue row turns pink.

---

## Findings (ranked)

### F1. Bright saturated blues drift toward violet/magenta in the display transform. Highlights and Whites slide pixels along that drift. Owner: WS-13 (mechanism). WS-05 adds to it through the Whites anchor (F2).

Harness `H trajectory` (`$A/trajectory.txt`) renders a uniform patch through
`RenderPlan.exactColor` (analytic, no LUT) and `referenceColor` (33³ LUT) at each
scene-luminance EV. The table gives OKLab hue of the sRGB output at the default recipe:

| colour (sRGB in, scene hue) | -2 EV | 0 EV | +1 EV | +2 EV | +3 EV | drift over range |
|---|---|---|---|---|---|---|
| sRGB blue (20,30,255), 265.6° | 276.9 | 292.8 | 309.3 | 323.2 | 326.3 | **+49°**, ending pink (`[245,161,255]` at +2 EV) |
| deep sky (40,90,190), 262.2° | 270.6 | 270.8 | 273.5 | 277.3 | 281.1 | +10.5° |
| azure (30,120,220), 255.0° | 263.4 | 262.9 | 263.8 | 265.7 | 263.3 | ~3° (then collapses to white) |
| mid sky (90,140,200), 253.8° | 260.5 | 260.3 | 260.0 | 260.5 | 260.6 | flat, but a constant **+6.7°** offset |

Decomposition (`H decompose`, `$A/decompose.txt`). This reimplements the steps of
`DisplayTransform.apply` with each part switched on or off:

- **Constant offset of +6…+8° on every blue.** It comes from the inset primary rotation
  (`rotation = RGB(0.02, -0.03, 0.06)`). With rotation off, hue is within 1° of the scene;
  with rotation on, it is +6.7°. This is a static look choice, but it already pushes skies
  toward violet before any slider moves.
- **Luminance-dependent drift.** It comes from the per-channel / max-norm blend. The
  hue-preserving weight is `t·(1−shoulderU²)`, and `shoulderU` is measured on the **max
  channel**. A saturated blue at mid-grey *luminance* has its blue channel 3.4 EV higher
  (sRGB blue at Y = 0.18 has B at +3.4 EV), so it is already deep in the shoulder and
  rendered mostly per-channel. Per-channel compression of B, with R kept by the rotated
  inset, pushes R/B up, which reads as violet and then magenta. Measured on sRGB blue:
  pure max-norm path 277.7→279.2° (stable); blend without rotation 270→310°; shipped path
  279→326°. The gamut soft-clip holds hue constant, so it plays no part.
- For pale and cyan skies the per-channel part pulls the other way, toward cyan
  (perChannel 253→230°). That is the -20…-38° swing seen as those skies approach white
  (F3).

How much the sliders move hue (uniform patch, exact path, `$A/slider_hue.txt`; only
patches with C > 0.03):

- **Highlights ±100**: sRGB blue -9.1° / +5.1°; deep sky -4.9° / +3.5°; azure at +3 EV
  +2.7° / -31° (chroma collapsing); cyan sky at +3.5 EV -25° at +50.
- **Whites ±100**: sRGB blue **-15.1° / +9.7°**; mid sky at +2 EV -23.9° (+100); azure at
  +2 EV -25.5° (+100); cyan sky at +2 EV -21.9° (+100).
- hue_wheel at exposure +2 (`$A/swx/hue_wheel`): Highlights -100 |Δh| p95 7.7°, max 12.6°;
  +100 p95 8.6°, max 13.6°. **Whites +100 p95 29.2°, max 41.2°** (worst sectors 240° at
  30.4°, 210° at 24.0°, 30° at 22.9°). See `evidence/before_hue_wheel_whites_plus2ev.png`.
  That sheet also shows radial creases (hue folds) in the *default* wheel near blue/cyan.
  They come from the same max-channel switch in the blend (WS-13).
- On real skies at normal exposure, sky boxes drift < 2° with Highlights (983, 1840, 2545,
  4213; `$A/photo_sky.txt`), because those skies sit below +1 EV of luminance. The big
  drifts appear once a sky is bright: **2545 sky, Whites +100: -19.5°, chroma 0.076→0.016,
  B clipped on 100 % of the box** (`[159,194,241]` → `[235,247,255]`).

LR expectation: Camera Raw's Highlights and Whites keep hue. A blue sky darkened with
Highlights -100 stays the same blue and gains saturation. It does not turn violet or cyan.

### F2. Whites changes the hue of mid-luminance blues it should not touch. Owner: WS-05 (`applyAnchors` coupling), with WS-13.

`whiteWeight(t)` is 0 below +1 EV, so Whites applies no gain to a mid-luminance pixel.
Even so, sRGB blue at 0 EV luminance moves -4.8° / +7.9° at Whites ∓100. On the hue wheel
(L = 0.56, entirely midtones), Whites ±100 moves the 270-300° sector by a mean of
1.9° / 2.9° and up to 9.0° (`$A/sw/hue_wheel/whites`). Highlights on the same frame moves it
0.24°. **Mechanism:** Whites shifts `whiteAnchorEV` by ±1.5 EV, so the display
transform's `range`, `pivotX` and shoulder all move. A blue whose max channel is +3.4 EV
then changes its per-channel/ratio blend. Lightroom's Whites leaves mid-luminance
saturated colours alone.

### F3. Near-white skies lose chroma and swing hue as they clip. Owner: WS-13 (blend). WS-05 sets the slider strength.

Highlights +100 and Whites +100 drive sky patches into the per-channel region and into
white. Mid sky at +3 EV: Highlights +100 -28°, chroma 0.049→0.005. Whites +100 makes
mid/pale/azure skies at +2 EV fully white (B = 255, chroma -0.064…-0.083). This is a
correct "brighten", but the colour path to white goes through cyan instead of desaturating
at constant hue.

### F4. The zonal coordinate t ignores the max channel, so Highlights cannot reach a saturated blue sky. Owner: WS-07 (mask input `luminancePlane`/logLuminance). WS-05 (weights) is affected.

`applyTone` drives t from Rec.2020 Y. A saturated sky has low Y compared with its blue
channel, so Highlights treats it as midtone while its blue channel is the one nearest
clipping.

- Sky probe, sRGB blue at 0 EV luminance (B at code 247, +3.4 EV): Highlights -100 changes
  it by **0** (weight = smoothstep(0, 5, 0) = 0).
- Azure at 0 EV: B 207 → 207. At +1 EV: B 237 → 232, so Highlights -100 removes only 5
  codes.
- 983 at exposure +2 (sky Y +0.67 EV, blue channel +1.8 EV): Highlights -100 lowers sky
  OKLab L by 0.011 (blue code 203 → 200).

In Lightroom, Highlights -100 on a bright blue sky is the standard move for deepening it.
Here it barely moves skies, and pushing harder means the user reaches for Whites, which has
the hue problem in F2/F3.

### F5. Shadows +100 lifts the black floor and flattens shadow texture. Owner: WS-05 (`shadowWeight` shelf shape, `shadowShelfEnd`).

The shadow window is a **shelf**: full +2 EV from -4.5 EV all the way down to the black
anchor. So near-black pixels get the whole lift, nothing anchors the blacks, and the
picture goes grey.

- Grey ramp: -6 EV 1 → 10 codes, -4 EV 10 → 39, -2 EV 41 → 67, 0 EV unchanged
  (`$A/ramp.txt`).
- Real photos (`$A/shadows.txt`, base exposure): p1 / minimum code at 0 → +100:
  6929 (A7 IV) 10.5 / 3 → **39.9 / 16**; 2545 (GX85) 7.4 / 1 → 32.3 / 8; 4213
  10.9 / 3 → 40.1 / 18; 1332 5.7 / 2 → 27.8 / 11. With exposure +1.5/+2: 6929 p1
  31.7 → 57.5, min 10 → 34; 4213 min 12 → 39.
- Local contrast in shadows (std of luma minus its 7×7 mean, on pixels below code 50 in
  the reference) drops on textured scenes: 6929 10.99 → 8.43 (-23 %), 2545 13.50 → 10.70
  (-21 %), 1332 8.62 → 6.59 (-24 %), 983 6.56 → 5.52 (-16 %), 1569 (GX80) 11.40 → 8.98
  (-21 %). It rises only where the texture is finer than the mask threshold (1840
  4.36 → 6.56, 4213 3.80 → 4.11). Std of the shadow pixels falls for 6929 (11.6 → 8.7) and
  4213 (10.5 → 8.6) while their mean doubles. That is "lifted and flat".
- **Cause.** The shelf slope is at most 1.5·2/4.5 = 0.67 stops per stop. Across
  -4.5…0 EV, the output log-contrast is compressed down to 0.33 of input wherever the guided
  mask follows the texture. Its ε is 0.375 EV (`toneMaskContrastThresholdEV`, WS-07), so
  foliage and grass texture above about 0.4 EV gets the per-pixel curve. Below -4.5 EV the
  shelf is flat at +2 EV, so it lifts the black floor 1:1 in stops.
- LR expectation: Shadows +100 opens the quarter-tones strongly, keeps the darkest values
  near where Blacks puts them, and keeps local contrast (it is local-adaptive). The lift
  has to taper toward the black anchor (a bump-like tail below about -5 EV, or a
  black-anchored taper), and shadow detail should not lose more than about 10 % of its
  local contrast.

### F6. Halos at moderate-contrast edges (1-2 EV). Owner: WS-07 (guided mask). Amplitude scales with the WS-05 shelf slopes.

At extreme contrast (`hard_edge`, 9.7 EV step) there is **no halo** at any setting: width
0 px, deviation ≤ 1 code (`$A/halo_syn.txt`). Edges of 1-2 EV, which is what a skyline is,
do halo. Probe `$A/probe/edges.lfi` (vertical edges, 1300 px long edge, so the mask radius
is 26 px). Width is in px where |code - plateau| > 1; values are in `$A/halo_edges.txt`:

| setting | edge (L\|R EV) | halo width L / R | peak |
|---|---|---|---|
| Highlights -100 | +2.5\|+1.5 | 17 / 25 px | +4.0 / -5.0 codes |
| Highlights -100 | +3.5\|+1.5 | 11 / 19 px | -4.0 |
| Highlights -100 | +1.5\|-2.5 | 16 / 0 px | +2.1 |
| Shadows +100 | -1\|-3 | **29** / 10 px | **+5.3** / -2.9 |
| Shadows +100 | 0\|-2 | 0 / 21 px | -4.6 |
| Shadows +100 | -2\|-4, -3\|-5 | 20, 15 px | +4.0 |
| Shadows -100 | 0\|-1 | 25 px | +3.2 |
| Whites +100 | +2.5\|+1.5 | **34** px | **+7.6** |
| Whites +100 | +3.5\|+1.5 | 30 px | +6.6 |
| Whites +100 | +1.5\|-2.5 | 22 px | -3.6 |
| Blacks ±100 | various | ≤ 9 px | ≤ 2 codes |

Evidence: `evidence/before_edges_halo.png`. In the Whites +100 row a brightness gradient is
visible on the +1.5 EV side next to the edge, without amplification.

Real skylines (delta method, `$A/halo_real.py`; note that the sky's own gradient inflates
these numbers):

- 4213 at exposure +1.5: Highlights -100 median 35 px, p90 excess 15.9 codes. Whites +100
  median 42 px, p90 excess 27 codes.
- 1840 at exposure +2: Whites +100 median 38 px, excess 36.9 codes.

Visual check (`$A/crops/4213_hl-100_delta.png`, `1840_hl-100_delta.png`) shows a thin band
of reduced effect right above the treeline, plus **sky holes inside the canopy getting the
foliage's gain**. On 1840, open sky vs sky holes: Highlights -100 −13.6 vs −10.2 codes
(25 % less), Whites +100 +26.8 vs +16.7 (38 % less). After the edit the holes therefore
read 3-10 codes off from the open sky.

### F7. Whites +100 is too strong at the top and accelerates; part of its range is dead. Owner: WS-05 (`whiteBlackRangeEV`, `whiteToneEV`, `endShelf*`).

- Neutral steps (`$A/probe/top_steps.lfi`): at default the 255 clip starts at +5 EV.
  Whites +50 clips from about +4 EV; **Whites +100 clips from +2.5 EV** (grey ramp: from
  +2.48 EV). That is 2.5 stops of highlight range thrown away. Code at +2 EV: 207 → 219
  (+50) → 244 (+100). The second half is worth 2× the first. Grey ramp zone 8: +13.4 at +50
  vs +34.9 at +100.
- Dead travel: at +3 EV the fine sweep reads 253, 254, 255, 255, 255 for +60…+100.
- Clipping on real frames: 983 at exposure +3, any-channel 255 2.17 % → 32.3 % (all three
  channels 21.5 %). 2545 at +2.5: 0.35 % → 40.7 %. 1332 at +2: 0 → 16.5 %.
- Asymmetric: Whites -100 takes +3 EV from 235 to 217 (-18), Whites +100 to 255 (+20,
  clipped).
- LR expectation: Whites sets the white clip point smoothly. +100 does clip a well-exposed
  frame, but with progressive travel (Alt-drag shows clipping grow) and no dead band.

### F8. Highlights: recovery works on neutrals but costs highlight texture. Owner: WS-05 (shelf slope), WS-07 (mask ε).

- Recovery (neutral steps): Highlights -100 moves the 255 clip point from +5 EV to
  **+7 EV (2 stops)**. Codes at +4/+4.5/+5 EV go from 249/254/255 to 214/223/235. That is
  within LR's expected 1-2 stops. 983 at exposure +3: any-channel clip 2.17 % → 0.19 %.
  Sensor-clipped snow becomes flat grey 223 because the LibRaw decode has no data there.
  That belongs to the decode, not this lane.
- Separation in near-clipped areas: 983 at exposure +2, mountain snow p5-p95 spread
  75.1 → 49.8 codes; lantern glass 7.3 → 4.9. Local contrast (high-pass std) drops:
  lantern 2.91 → 1.96 (-33 %), snow 0.99 → 0.87 (-12 %), 2545 roof 14.6 → 11.3 (-23 %),
  4213 castle 21.7 → 19.3 (-11 %) (`$A/recover.txt`). LR's Highlights -100 keeps or raises
  perceived highlight texture. Here the shelf slope (min 1 - 2·1.5/5 = 0.4 at +2.5 EV) is
  applied per pixel wherever the texture exceeds the mask ε.
- Highlights +100 adds clipping: grey ramp clips from +3.4 EV. 983 at exposure +3
  any-channel 2.17 → 13.4 %, 2545 at +2.5 0.35 → 21.4 %. That is acceptable for "+", but
  LR's Highlights +100 rarely clips a frame that was not clipping before.

### F9. The 33³ finish LUT adds ±3-4° of hue jitter on blues. Owner: WS-13 / RenderPlan (finish LUT size and interpolation).

Exact path against `referenceColor` at lutSize 33: mid sky at -1.5 EV 260.5 vs 264.6°; at
+3 EV 260.6 vs 256.3°. Slider-induced drift reads differently through the LUT, for example
mid sky at +3 EV with Highlights -100: -0.3° exact vs +3.3° LUT. At lutSize 65 the
difference is ≤ 1°. The LUT lattice is 0.75 EV per node across 24 EV of log space, so a
pixel moved by the tone gain crosses cells and the hue wobbles. Preview uses 33 and export
uses 65, so preview and export disagree on blue hue by up to 4°.

### F10. Blacks: clipping works; lift is moderate and the floor is code 1. Owner: WS-05. Low priority.

- Blacks -100 clips to 0 on real frames: 2348 0.52 → 9.18 %, 1840 0 → 13.8 %, 1569 6.6 %,
  983 4.4 %. This matches LR's black clip point. On the grey ramp the floor stays at code 1:
  the display `blackTarget` 0.0152 % renders as code 1, and nothing in the ramp goes below
  the anchor.
- Blacks +100: p1 rises by about 10 codes (6929 10.5 → 21.8; 2545 7.4 → 19.9), the
  minimum rises 3 → 12. Ramp: -8 EV 1 → 3, -6 EV 1 → 12, -4 EV 10 → 23. Zone 0 +7.1 codes.
  Reasonable; LR's Blacks +100 is somewhat stronger in the deepest tones.
- Blacks ±100 on halos: ≤ 9 px, ≤ 2 codes. Fine.

### F11. Zone isolation (grey ramp zone table, Δ codes ×255). Mostly good.

| control | z0 | z1 | z2 | z3 | z4 | z5 | z6 | z7 | z8 | z9 |
|---|---|---|---|---|---|---|---|---|---|---|
| Highlights -100 | 0 | 0 | 0 | 0 | -0.0 | -2.3 | -9.3 | -19.3 | -28.2 | -36.6 |
| Highlights +100 | 0 | 0 | 0 | 0 | 0.1 | 2.2 | 8.7 | 16.5 | 20.4 | 12.0 |
| Shadows -100 | -3.3 | -17.1 | -10.4 | -4.5 | -0.2 | 0 | 0 | 0 | 0 | 0 |
| Shadows +100 | 11.5 | 26.6 | 10.9 | 5.6 | 0.2 | 0 | 0 | 0 | 0 | 0 |
| Whites -100 | 0 | 0 | 0 | 0 | -0.0 | -0.4 | -1.2 | -3.4 | -8.8 | -19.0 |
| Whites +100 | 0 | 0 | 0 | 0 | 0 | 0.9 | 6.3 | 25.7 | 34.9 | 13.4 |
| Blacks -100 | -3.4 | -10.4 | -0.8 | -0.2 | -0.0 | 0 | 0 | 0 | 0 | 0 |
| Blacks +100 | 7.1 | 2.6 | 0.3 | 0.1 | 0 | 0 | 0 | 0 | 0 | 0 |

- Highlights does not touch z0-z4, and Shadows does not touch z5-z9 (≤ 0.2 codes). Pass.
- Whites +100 reaches z6 (+6.3) and z7 (+25.7, more than Highlights +100's 16.5 there).
  Whites acts as a second, stronger Highlights instead of a white-point control, because
  of the endShelf overlap the file comments already admit.
- Shadows +100 moves z0 by +11.5, which is the black floor (F5). Blacks +100 moves z0 by
  only +7.1, so **Shadows has more authority over the black point than Blacks does.**

### F12. Monotonicity, smoothness, identity. Pass.

- 23-value fine sweep on the grey ramp (-100…100 in steps of 10, plus ±1;
  `$A/fine/`): zero slider-monotonicity violations, zero spatial non-monotone columns for
  all four controls.
- ±1 moves at most 1 code. Value 0 is an exact identity (`ToneEngine.isIdentity` skips
  S7, and the finish table is unchanged at default anchors).
- The only dead range is Whites +60…+100 on already-bright tones (F7).

---

## Root-cause map and ownership

| # | finding | where | owner |
|---|---|---|---|
| F1 | blue → violet/magenta with brightness; cyan swing for pale skies | `DisplayTransform.apply`: primary rotation (+6.7° static), blend weight from the max channel's `shoulderU`, outset purity restore | **WS-13** |
| F2 | Whites shifts mid-luminance blue hue | `ToneEngine.applyAnchors` → anchor moves the DT shoulder; DT blend as F1 | WS-05 (decide whether the anchor move stays, or Whites becomes gain-only plus a hue-safe clip), WS-13 |
| F3 | near-white skies swing hue | DT blend; strength of Whites/Highlights `+` | WS-13; WS-05 strength |
| F4 | t from Y, so Highlights misses saturated blue skies | `RR.applyTone` `luminancePlane` → mask; `RG.logLuminance` | **WS-07** (NEEDS); WS-05 weights are affected |
| F5 | Shadows +100 lifts blacks, flattens texture | `shadowWeight` shelf with no taper toward the black anchor; `shadowShelfEnd` 0.5; slope 0.67 | **WS-05** (+ WS-07 ε for the texture part) |
| F6 | halos 15-34 px, 4-8 codes at 1-2 EV edges | guided mask radius 2 %, ε 0.375 EV; amplitude ∝ shelf slope | **WS-07**; WS-05 reduces shelf slope |
| F7 | Whites +100 clips from +2.5 EV, accelerates, dead top | `whiteBlackRangeEV` 1.5 + `whiteToneEV` 1.3 stacked, `endShelfStart/End` 0.2-0.8 | **WS-05** |
| F8 | Highlights -100 loses 11-33 % highlight texture | shelf slope 0.4 per pixel where texture > ε | WS-05 (slope) + WS-07 (ε) |
| F9 | ±3-4° LUT hue jitter at 33³ | finish LUT 33 vs 65 | WS-13 / RenderPlan |
| F10 | Blacks moderate, floor code 1 | `blackToneEV`, DT `blackTarget` | WS-05 (low) |
| F11 | Whites reaches z6-z7, Shadows owns z0 more than Blacks | shelf placement | WS-05 |

---

## Reproduction (for the spec writer)

```
export PATH=/opt/swift/usr/bin:$PATH
BIN=$(swift build -c release --show-bin-path)/lumen-render
A=/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/audit
# per-control sweeps (sidecar Kelvin/tint/ISO read automatically), -100,-50,0,50,100, 1024 px, no dither
$A/sweep.sh  corpus/lfi/6929_sony-ilce-7m4.lfi 6929            # -> $A/sw/6929/<key>/{sheet.png,sweep.json,tiles/}
$A/sweepx.sh corpus/lfi/983_canon-eos-5d-mark-iv.lfi 983 2.0 highlights whites   # base exposure +2 -> $A/swx/...
# synthetic probes (python3 $A/make_sky.py etc.)
#   $A/probe/sky.lfi        6 blues x 7 luminance EVs (-1..+5), 120 px patches
#   $A/probe/edges.lfi      13 vertical edges of 1-7 EV contrast (sweep at --long-edge 1300)
#   $A/probe/top_steps.lfi  neutral steps 0..+9 EV ; $A/probe/white_steps.lfi
# analysis scripts (python3, numpy+PIL; run from $A)
python3 sky_an.py highlights whites        # OKLab hue/chroma drift per patch from sweep tiles
python3 photo_sky.py                       # sky boxes in 983/1840/2545/4213
python3 ramp.py                            # clip points and codes vs EV on grey_ramp
python3 halo_edges.py ; python3 halo_syn.py ; python3 halo_real.py sw swx
python3 shadows_an.py ; python3 recover.py sw swx
# Swift harness linking LumenCore (exact vs LUT, decomposition of DisplayTransform.apply)
cd $A/harness && swift build -c release && ./.build/release/H trajectory | slider highlights | slider whites | decompose
```

## Evidence

- `evidence/before_sky_probe_blue_to_purple.png`: sky probe, Highlights -100 / 0 / +100 and
  Whites -100 / +100. The sRGB-blue row goes violet, then magenta, then pink. Whites +100
  turns skies white or cyan.
- `evidence/before_hue_wheel_whites_plus2ev.png`: hue wheel at exposure +2, Whites
  -100 / 0 / +100 and a |Δh| map (white = 40°). The default wheel also shows hue creases.
- `evidence/before_edges_halo.png`: edge probe, Highlights -100, Whites +100, Shadows +100,
  with the image on the left and (Δ - far-field Δ)×8 on the right.
- `evidence/before_983_sky_highlights.png`: 983 at exposure +2, 100 % crop of sky and snow
  at Highlights -100 / 0 / +100. The snow loses texture at -100 and the sky barely changes
  (F4, F8).
