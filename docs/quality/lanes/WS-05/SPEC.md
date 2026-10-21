# WS-05 spec: Highlights, Shadows, Whites, Blacks

Acceptance spec for lane WS-05 (`tone.highlights`, `tone.shadows`, `tone.whites`,
`tone.blacks`). It is written from `AUDIT.md` (F1 to F12) before any code change. The
standard is the owner's: correct, and measurably as good as Lightroom or better. There are
no Lightroom reference exports in `corpus/lightroom/`, so the Lightroom side of each line
comes from documented Camera Raw behaviour. Each line gives the reason for its number.

Every line has an **id**, a **claim**, a **threshold**, the **command** that measures it,
the **baseline** measured on the base commit `84bcd7c`, and an **owner**:

- **WS-05**: WS-05 can fix the line inside its own code. That code is
  `ToneEngine.anchors(for:)`, the `ToneEngine` init, the shelf constants
  (`highlightShadowRangeEV`, `whiteBlackRangeEV`, `*ShelfStart/End`, `whiteToneEV`,
  `blackToneEV`), `highlightWeight` / `whiteWeight` / `shadowWeight` / `blackWeight`,
  `solveZonalLimits` / `zonalLimit` / `zonalParts` / `zonalStops`, `easedScale`,
  `applyAnchors`, and `BasicPanel.toneRows` / `toneSection`. These lines must PASS.
- **NR (WS-07)** or **NR (WS-13)**: the cause is outside the lane. WS-05 must not make
  these lines worse, and the threshold is the baseline plus a stated tolerance. The fix
  request with evidence is in `NEEDS.md`.

## 0. How to measure

```
export PATH=/opt/swift/usr/bin:$PATH
cd /home/user/lumen && swift build -c release --product lumen-render     # the tree under test
S=/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/spec
A=/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/audit
(cd $S/anchorh && swift build -c release)   # exact-path harness `AH`, links the working tree's LumenCore
export ASHIFT=0                       # = new defaultWhiteAnchorEV - 5.0 if line A1 moved it (e.g. -2 for 3.0)
bash $S/render.sh $S/after            # ~2.5 min, every sweep below, into $S/after/{sw,swx,swx3,fine}
python3 $S/measure.py $S/after        # every numbered line, PASS/FAIL; --only S1,W2 for a subset
```

`ASHIFT` keeps the exposure-pushed sets comparable when the default white anchor moves.
`swx` and `swx3` are rendered at the audit exposure + ASHIFT, so every scene tone keeps its
distance to the white anchor, and W6 reads the LFI with the same shift. The Whites and
Highlights clip lines are written relative to the default clip point `C0`. `C0` is
measured on `top_steps` at value 0 (5.0 EV at baseline).

- `render.sh` runs `lumen-render sweep` (CPU `ReferenceRenderer`, `--no-dither`, sidecar
  as-shot Kelvin/tint/ISO, 1024 px, values -100,-50,0,50,100) on these inputs:
  - synthetic frames: `grey_ramp`, `hue_wheel`, `hard_edge`;
  - the audit probes `$A/probe/sky.lfi`, `edges.lfi` (1300 px) and `top_steps.lfi`
    (neutral steps at 0, 1, 2, 2.5, ... 9 EV);
  - eight real frames at base exposure: 6929 (A7 IV), 2545 (GX85), 4213, 1332, 983, 1569,
    1840, 2348;
  - `swx` at exposure +1.5 (6929, 4213, 2545) and +2 (983, 1840, hue_wheel), each plus
    ASHIFT;
  - `swx3` at exposure +3 (983), +2.5 (2545) and +2 (1332), each plus ASHIFT;
  - `fine`, which is `grey_ramp` at 23 values (-100…-10 in steps of 10, ±1, 0, 10…100) for
    all four keys.
- `measure.py` reuses the audit's `common.py` (OKLab, box filter). Baselines for the
  non-regression hue and texture lines are in `$S/baseline.json`. It was written once,
  from `$S/base`, with `--write-baseline`. Never rewrite it from a changed tree.
- The base tree is kept at `$S/base`. `python3 $S/measure.py $S/base` reproduces every
  "baseline" number below: 18 of 32 lines PASS at baseline, and the 14 that fail are the
  WS-05 defects.
- The audit scripts also run on either tree and agree with these numbers:
  `cd $S/after && PYTHONPATH=$A python3 $A/ramp.py`, the same for `shadows_an.py` and
  `halo_edges.py`, `recover.py swx` and `halo_real.py swx`.
- The exact-path Swift harness rebuilds against the working tree:
  `cd $A/harness && swift build -c release && ./.build/release/H slider whites`.

Units: "codes" are 8-bit sRGB code values, and luma is Rec.709 weights on the sRGB PNG. EV
is scene stops from mid-grey. Ramp positions are read from the grey_ramp row, which spans
-10…+4 EV. "Zone z*k*" is the `lumen-render` zone table, 10 equal bands of encoded
luminance of the reference tile (z0 = codes 0-25).

---

## A. Default white anchor: sensor white must reach white (WS-13 request, verified here)

WS-13 reported that with `defaultWhiteAnchorEV` = +5 EV real RAWs never reach 255: sensor
white renders at code 221, and +3.0 EV would match ACR. The constant is WS-05's
(ToneEngine.swift:115). I checked the claim independently, and it holds.

**Where sensor white sits in scene EV.** The proof decode puts the green channel's sensor
white at 1.0 with mid-grey at 0.18 (`scripts/proof/CORPUS.md`:59). So sensor white is at
t = log2(1/0.18) = **+2.47 EV**. That is the ISO saturation-based placement, about 2.5
stops of headroom over mid-grey. Apple's decode, which the app uses, is +0.19…+0.43 EV
brighter (CORPUS.md:80), which puts sensor white at **+2.66…+2.90 EV**.

**What the default renders there.** The exact display transform, from
`$S/anchorh/.build/release/AH anchors`, which sweeps the white anchor with all else
default:

| white anchor | +2.0 EV | +2.32 (diffuse 90 %) | **+2.47 (sensor white)** | +2.70 | +2.90 | +3.5 | clip |
|---|---|---|---|---|---|---|---|
| 5.00 (today) | 207.4 | 217.4 | **221.6** | 227.6 | 232.3 | 243.7 | +5.0 |
| 4.00 | 211.6 | 222.5 | 227.2 | 233.8 | 238.9 | 250.7 | +4.0 |
| 3.50 | 215.7 | 227.6 | 232.6 | 239.7 | 245.0 | 255 | +3.5 |
| 3.25 | 220.1 | 232.5 | 237.7 | 244.7 | 249.8 | 255 | +3.25 |
| **3.00** | 225.6 | 238.4 | **243.5** | 250.1 | 254.1 | 255 | +3.0 |
| 2.75 | 232.2 | 245.0 | 249.7 | 254.6 | 255 | 255 | +2.75 |

Mid-grey stays at 117.6 for every anchor, and the toe is unchanged.

**Real frames confirm it.** At exposure 0 and the default recipe, frames whose sensor
clipped have their brightest pixels at luma 221-222 and not one 255 pixel:

| frame | max luma | 255 pixels |
|---|---|---|
| 6929 | 221.0 | 0 % |
| 1569 | 221.6 | 0 % |
| 2348 | 221.9 | 0 % |
| 1332 | 221.3 | 0 % |

So the brightest thing a correctly exposed RAW can contain renders as light grey (code
221, about 87 %), never as white. Its chroma has already been bleached by the shoulder.
That is the owner's "pastel, washed-out" look.

**The target is +3.0 EV.** It puts this decode's sensor white at 243.5 and Apple's at
250-254, so near-white lands at 250-255 in the app without clipping. A diffuse highlight
0.5 EV under clip stays well separated (225.6 against 243.5). 2.75 clips Apple's
brighter decode (255 at +2.90), and 3.25 or higher leaves sensor white at 238 or below.

**What it does to the rest of the lane.** The shelves are fractions of the anchor, so the
builder must re-express them in absolute EV:
- **Highlights.** `highlightShelfEnd` 1.0 × 3.0 gives a slope of 1.5·2/3 = 1.0 stop per
  stop. `solveZonalLimits` would then bind Highlights -100 even at Contrast 0. The fix is
  to keep the shelf end at about +5 EV, i.e. highlightShelfEnd ≈ 5/3, or to shorten the
  range.
- **Whites.** `endShelfStart/End` 0.2/0.8 × 3.0 spans +0.6…+2.4 EV, which is deep in z6-z7
  (W4).
- **Whites range.** `whiteBlackRangeEV` 1.5 would take the Whites +100 anchor to +1.5 EV.
  The anchor coupling is being removed for F2 anyway (H6).
- Shadows and Blacks key off the black anchor and are unaffected.
- `contrastMapped` (WS-06), the grading wheels' zone axis (`GradeEngine`, via
  `RenderPlan`), the Zones panel axis (WS-08) and `AutoTone` all read the live anchor. Their
  owners are notified in NEEDS N8.
- This is a global look change, so the integrator signs off on it.

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| A1 | Sensor white reaches white without clipping. At default, the ramp code at +2.47 EV (sensor white, proof decode) is 238-250. At +2.66 EV it is at least 245, and at +2.90 EV at most 254.5 (Apple's decode). A diffuse highlight 0.5 EV lower (+2.0 EV) stays at least 8 codes below sensor white. | 238…250; ≥ 245 / ≤ 254.5; ≥ 8 | `--only A1` (grey_ramp, value 0) and `$S/anchorh/.build/release/AH anchors` | 221.0; 226.0 / 232.0; 14.0 | WS-05 (`defaultWhiteAnchorEV`) |
| A2 | Real frames with sensor clipping (6929, 1569, 2348, 1332) at exposure 0 and default: the brightest pixel is near white and almost nothing clips. | max luma ≥ 238; any-channel 255 ≤ 0.5 % | `--only A2` | 221.0-221.9; 0 % | WS-05 |

## 1. Shadows (F5): open the quarter tones, keep the black point, keep the texture

What Lightroom does: Shadows +100 opens the quarter tones strongly and leaves the darkest
values close to where Blacks puts them. It is local-adaptive, so shadow texture survives.
What happens here at baseline: the shadow window is a shelf at full +2 EV from -4.5 EV
down to the black anchor, so the deepest pixels get the largest lift. On the A7 IV frame
p1 rises more than p25 does (29.4 against 23.6 codes). The fix belongs to WS-05: give
`shadowWeight` a taper toward the black anchor (a bump that peaks near -2.5 to -3 EV), and
re-tune `shadowShelfEnd` and the range.

Feasibility check. I ran a 1-D model (pixel EV mapped through the measured ramp curve) of
one such bump, R 1.25 EV × smoothstep(0, 2.6) × (1 - 0.75·smoothstep(2.8, 4.8)). It gives
the following, which is why these thresholds are achievable and not trivial:

| frame | p1 rise (codes) | mean(p25, p50) rise | shadow std ratio | 1840 shadow-mean rise |
|---|---|---|---|---|
| 6929 | 7.5 | 27.2 | 1.53 | - |
| 4213 | 7.2 | 32.3 | 1.57 | - |
| 1840 | - | - | - | 18.4 (0.59 × baseline) |

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| S1 | Shadows +100 does not lift the black point. Measured as the rise of whole-frame luma p1 between Shadows 0 and +100 on 6929 and 4213. Both frames' p1 sits at about -4 EV (code 10.5). | ≤ 8.0 codes on each | `measure.py --only S1` | 29.4 / 29.2 | WS-05 |
| S2 | It still opens the quarter tones: the mean of the p25 and p50 rises stays within 15 % of today. | ≥ 0.85 × baseline: 6929 ≥ 15.2, 4213 ≥ 23.9 | `--only S2` | 17.9 / 28.1 | WS-05 |
| S3 | Shadow local contrast is kept. Measured as hp(+100) / hp(0): std of luma minus its 7×7 mean, on pixels below code 50 in the Shadows 0 render, on 6929, 2545, 1332, 983 and 1569. Lightroom loses none; the audit floor was 10 % and the owner asked for 5 %. | ≥ 0.95 on each | `--only S3` (same metric as `$A/shadows_an.py` "shHP") | 0.768, 0.792, 0.765, 0.841, 0.788 | WS-05 (the texture finer than the mask ε is WS-07, see NEEDS N3) |
| S4 | Not "lifted and flat": the spread of the shadow pixels does not shrink. Measured as std(+100) / std(0) of luma on the same shadow pixels, 6929 and 4213. | ≥ 1.00 on each | `--only S4` | 0.751 / 0.827 | WS-05 |
| S5 | Blacks owns zone 0, not Shadows. On the grey ramp, Shadows +100 moves z0 by at most 6.0 codes and by less than Blacks +100 moves it, and the -6 EV ramp code at Shadows +100 is at most 4. | Shadows z0 ≤ 6.0 and < Blacks z0; code at -6 EV ≤ 4 | `--only S5` | Shadows z0 11.5 against Blacks z0 7.1; code at -6 EV 10 | WS-05 |
| S6 | An authority floor, so S1/S5 cannot be passed by weakening the control. At Shadows +100 the ramp code at -2 EV is at least 63. The mean lift of shadow pixels on the two darkest frames, 1840 and 2348 (p50 near -3 EV), stays at least 0.6 × today's. The ProofRegistry floor for `tone.shadows` (30) is gated in T3. | code at -2 EV ≥ 63; 1840 ≥ 18.7; 2348 ≥ 17.4 | `--only S6` | 67.0; 31.2; 28.9 | WS-05 |

## 2. Whites (F7): a white-point control, progressive, with no dead travel

What Lightroom does: Whites sets the white clip point. Across its travel the clip moves by
about 1 to 1.5 stops, smoothly (Alt-drag shows clipping grow steadily), with no band where
the slider does nothing. Its effect is concentrated at the top of the range; Highlights
handles the upper midtones. What happens here at baseline: the Whites +100 anchor move
(-1.5 EV) and its tonal shelf (+1.3 EV, starting at +1 EV) stack. Whites +100 clips from
+2.5 EV, which throws away 2.5 of the 5 stops of headroom. The response accelerates, and
it moves z7 more than Highlights does. The 1.5-stop clip move in W2 is the Lightroom
rationale, and it equals this engine's own `whiteBlackRangeEV`.

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| W1 | The response is roughly linear over the travel, **in stops**. On the fine ramp, read the code at value v back through the value-0 ramp to get an equivalent EV shift d(v). Take the brightest of C0 - 2, C0 - 2.5 and C0 - 3 EV where +100 is still below 255 and +50 moves at least 0.05 EV. Measuring in stops keeps the line valid when A1 moves C0 and when the shoulder or the clip compresses codes. | (d100 - d50) / d50 ≤ 1.5 | `--only W1` | 2.94 at +2.0 EV (d50 0.40, d100 1.57 EV; codes 207.0 → 219.4 → 244.2) | WS-05 |
| W2 | The Whites +100 255-clip point on `top_steps` (neutral steps, first step with code ≥ 254.5) lies between C0 - 1.5 and C0 - 0.5. The low bound gives a clip move of at most 1.5 stops from the default C0. The high bound means +100 must still clip a frame that the default does not. | C0 - 1.5 ≤ EV ≤ C0 - 0.5 (3.5…4.5 at C0 = 5; 1.5…2.5 if A1 sets 3.0) | `--only W2` | 2.5 (C0 = 5.0) | WS-05 |
| W3 | No dead range from +60 to +100. On the fine ramp at C0 - 2 EV (+3 EV at baseline), every 10-point step from +60 to +100 moves the code by at least 0.5 (a step from an already-clipped value counts as 0). | min step ≥ 0.5 code | `--only W3` (reads `fine/whites`) | [1.0, 1.0, 0, 0] | WS-05 |
| W4 | Whites is isolated from Highlights' territory. On the ramp, Whites +100 moves z7 by no more than Highlights +100 does, and by at most 16.5 codes (Highlights' baseline). It moves z6 by at most 3.0 codes. | W z7 ≤ H z7 and ≤ 16.5; W z6 ≤ 3.0 | `--only W4` | W z6 6.3, W z7 25.7, H z7 16.5 | WS-05 |
| W5 | An authority floor on both sides. At Whites +100 the ramp code at C0 - 2 EV rises by at least 10. At Whites -100 the code at C0 - 1 EV drops by at least 12. | ≥ +10; ≥ 12 | `--only W5` | +21.0; 19.1 (249.0 → 229.9) | WS-05 |
| W6 | Whites -100 brings the brightest clipped data under 255. On 983 at exposure +3 the any-channel 255 share is not above baseline. Of the pixels that clip at Whites 0 and whose scene max channel is ≥ +4 EV, none is still 255 at -100. The +3.5…+4 EV band is not worse than baseline: those are chromatic pixels clipping at Y ≈ +2…+3 EV, which is NEEDS N1/N7. | any ≤ 1.15 %; ≥ +4 EV: 0.0 %; +3.5…+4 EV: ≤ 45.0 % | `--only W6` | 1.12 %; 0.0 %; 44.5 % (PASS at baseline: the bright data already unclip) | WS-05 non-regression (band: NR, WS-07/WS-13) |
| W7 | Whites +100 does not blow out real frames. Measured as the any-channel 255 share: 983 at +3, 2545 at +2.5, 1332 at +2. This follows from W2, and the thresholds sit near today's Whites +50 (8.7 %, 13.7 %, 0.7 %) plus margin. | 983 ≤ 22 %, 2545 ≤ 28 %, 1332 ≤ 10 % | `--only W7` | 32.3 %, 40.7 %, 16.5 % | WS-05 |

## 3. Hue (F1, F2, F3, F9): a tone slider must not ADD hue drift beyond the display transform

**Division of work, set by the programme director.** The blue → violet → pink drift of
bright saturated blues (F1), and the cyan swing of near-white skies (F3), are
`DisplayTransform` behaviour. WS-13 has accepted them as its spec lines 3.1-3.9: the outset
will undo the inset rotation, and the shoulder will bleach toward neutral at constant hue.
**WS-05 must not try to fix them.**

WS-05's obligation is narrower and exact: a Highlights, Shadows, Whites or Blacks move must
not ADD hue drift beyond what the display transform does to the same scene colour at the
same luminance. S7 multiplies RGB by a scalar gain g in scene-linear. So, for a uniform
patch, "slider at v" must render exactly like "slider at 0, with the scene colour scaled by
g". That is an exposure move of equal luminance effect.

Any difference comes from the slider changing the display transform itself. Today that
happens in one place, F2:
- `applyAnchors` moves `whiteAnchorEV` by ±1.5 EV for Whites ±100.
- The transform's blend weight depends on the anchor:
  `shoulderU = log2(peak/0.18) / whiteAnchorEV` (DisplayTransform.swift:396-399).
- So Whites re-hues saturated blues it applies no gain to, including midtone blues.

The fix is WS-05's: stop moving the display anchor for Whites (or move it far less), and
deliver the white-point move as gain through the shelf. `ToneEngine.anchors(for:)` and
`applyAnchors` are WS-05's.

H6 is the gate, and it is independent of whatever WS-13 does to the transform. H1 and H2
are the same claim seen through the full renderer (mask, LUT) where the slider's gain is
zero. H3 to H5 measure total drift. They stay as non-regression only while the display
transform is the base one. Once A1 or a WS-13 merge changes the transform, re-measure them
before and after on the same transform, or treat them as information. When they disagree,
read H6.

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| H6 | **No added drift.** On the exact path (`RenderPlan.exactColor`, no LUT, no mask), for 6 sky blues × scene luminance -2…+3.5 EV (step 0.5), compare the OKLab hue at slider v against the hue the default plan gives the same colour × g, where g is the slider's own S7 gain for that colour (`toneStageGain`). Take max \|Δh\| over patches with C ≥ 0.03 in both, for Highlights, Shadows, Whites and Blacks at ±50 and ±100. | ≤ 0.5° for every key/value | `(cd $S/anchorh && swift build -c release) && $S/anchorh/.build/release/AH added`, or `--only H6` | Highlights 0.00, Shadows 0.00, Blacks ≤ 0.05; **Whites -100 14.05°** (rec709_blue +2 EV), -50 7.59, +50 7.05, **+100 9.72°** (rec709_blue +0.5 EV) | WS-05 |
| H1 | Whites leaves midtone hue alone in the full render. On `hue_wheel` at exposure 0 (every patch at L 0.56, so midtones, where Whites' gain is zero), with chromatic pixels C > 0.03 at both values, take the worst 30° input-hue sector mean of \|Δh\| and the worst sector p99, for Whites -100 and +100. For comparison, Highlights ±100 measures 0.00 here and Shadows 0.19 / 0.7. | worst sector mean ≤ 0.5°; worst sector p99 ≤ 2.0° | `--only H1` | 2.35° (sector 240-270, +100); p99 7.92° | WS-05 |
| H2 | The same on the sky probe tiles (mask and LUT included): patches at luminance ≤ 0 EV, C ≥ 0.03 at both values, max \|Δh\| under Whites ±100. | ≤ 2.0° | `--only H2` | 7.7° (rec709_blue, 0 EV, +100) | WS-05 |
| H3 | Total drift at bright exposure, the owner's complaint: on `hue_wheel` at exposure +2 + ASHIFT, \|Δh\| p95 over chromatic pixels for H-100, H+100, W-100 and W+100. | each ≤ baseline + 1.0° (base transform only; see above) | `--only H3` | 7.5, 8.4, 10.3, 28.8° | NR (WS-13 mechanism). W2 and W4 are expected to lower W+100. |
| H4 | Total drift on the sky probe: patches at luminance ≤ +3 EV with C ≥ 0.03 at both values, max \|Δh\|. | each ≤ baseline + 1.0° (base transform only) | `--only H4` | H-100 9.1, H+100 3.4, W-100 14.6, W+100 9.7° | NR (WS-13) |
| H5 | Total drift on real skies: the `photo_sky.py` boxes on 983, 1840, 2545 and 4213, at base exposure and at the `swx` exposure, max \|Δh\| at ±100 (C ≥ 0.015 at both values). | each ≤ baseline + 1.0° (base transform only) | `--only H5` | sw: H 0.2, W 0.3; swx: H 1.7, W 19.5 (2545 sky) | NR (WS-13) |

Dependency on WS-13. Once WS-13's lines 3.1-3.9 land, the total drift in H3 to H5 should
fall for every slider without any WS-05 change. H6 should stay at ≤ 0.5° across that
merge. If it does not, the new transform has a slider-visible parameter coupling, and that
goes to the integrator.

Not a WS-05 line, recorded so the builder does not chase it: the 33³ finish LUT adds ±3-4°
of blue hue jitter against the exact path (F9, `H trajectory`). Preview (33³) and export
(65³) disagree on blue by up to 4°. That is NEEDS N5 (WS-13).

## 4. Highlights (F8): keep the recovery, do not lose more texture

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| R1 | Recovery is kept. Highlights -100 moves the `top_steps` 255-clip point at least 2 stops past the default C0, and the step at C0 reads at most 240. | clip ≥ C0 + 2.0; code at C0 ≤ 240 | `--only R1` | +7.0 EV (C0 = 5.0); 235.0 | WS-05 (non-regression) |
| R2 | Recovery on real clipping: any-channel 255 share at Highlights -100, 983 at exposure +3 and 2545 at +2.5. | ≤ 0.25 %; ≤ 0.05 % | `--only R2` | 0.19 % (from 2.17 % at 0); 0.00 % (from 0.35 %) | WS-05 (non-regression) |
| R3 | Bright-area texture under Highlights -100 does not get worse. Measured as hp(-100) / hp(0) on the `recover.py` boxes: 983 lantern and mountain snow (exp +2), 2545 roof and 4213 castle (exp +1.5). Lightroom keeps or raises highlight texture, so -11 to -33 % is a real defect. Most of it comes from the mask ε (WS-07, NEEDS N3). WS-05 can only soften the shelf's maximum slope (0.6 stops per stop today, a mapped slope of 0.4 near +2.5 EV) without giving up R1. If it does, REPORT records the gain. | each ≥ baseline - 0.02 | `--only R3` | lantern 0.672, snow 0.884, roof 0.775, castle 0.887 | NR (WS-07); WS-05 may improve |
| R4 | Highlights +100 clips no more than today: any-channel 255 share, 983 at +3 and 2545 at +2.5. | ≤ 13.5 %; ≤ 21.5 % | `--only R4` | 13.4 %; 21.4 % | WS-05 (non-regression) |

## 5. Blacks, isolation, monotonicity, identity (F10, F11, F12)

| id | claim | threshold | command | baseline | owner |
|---|---|---|---|---|---|
| B1 | Blacks keeps its authority, and may gain more if the builder moves zone 0 from Shadows to Blacks. Blacks -100 shadow-clip share (code 0, any channel) on 2348 and 1840; Blacks +100 p1 rise on 6929 and 2545. | ≥ 8.0 % / 12.0 %; ≥ 9.5 / 10.5 codes | `--only B1` | 9.2 % / 13.8 %; 11.3 / 12.5 | WS-05 (non-regression) |
| Z1 | Zone isolation on the grey ramp, max \|Δ\| at ±100 outside each control's territory: Highlights and Whites in z0-z4, Shadows in z5-z9, Blacks in z4-z9. | ≤ 1.0 code each | `--only Z1` | H 0.06, W 0.02, S 0.00, B 0.01 | WS-05 (non-regression) |
| Z2 | The same on a real frame, the 6929 zone table: Highlights in z0-z2, Whites in z0-z3, Shadows in z6-z9, Blacks in z5-z9. | ≤ 1.0 code each | `--only Z2` | 0.0 for all four | WS-05 (non-regression) |
| M1 | Monotone in the slider and in space. In the 23-value fine sweep on the grey ramp, for all four keys, a column whose code falls by more than 0.6 as the value rises is a slider violation. A row that falls by more than 0.6 left to right, at any value, is a spatial violation. | 0 / 0 | `--only M1` | 0 / 0 | WS-05 (non-regression) |
| M2 | ±1 moves at most 1 code anywhere on the ramp, for all four keys. | ≤ 1.0 | `--only M2` | 1.00 | WS-05 (non-regression) |
| M3 | Value 0 is an exact identity. `ToneEngine(tone: Tone()).isIdentity` is true. `ToneEngine.anchors(for: Tone())` returns exactly (`defaultWhiteAnchorEV`, -9). `RenderPlan(recipe: Recipe(), …).toneIsIdentity` is true, and the default finish table is unchanged. A non-zero value of any one slider is not reported as identity. | all true | `swift test --filter "EngineTests/testIdentityToneIsDetected"` plus the new test the builder adds (T2) | true | WS-05 (non-regression) |

## 6. Halos (F6): the spatial part belongs to WS-07; WS-05 must not amplify it

Halo amplitude scales with the shelf slopes, so a steeper Shadows bump (S1 to S4) or a
Whites gain shelf (W2) can make halos worse at 1-2 EV edges. These lines catch that.

| id | claim | threshold | command | baseline (width px / peak codes) | owner |
|---|---|---|---|---|---|
| HA1 | On the `edges` probe (13 vertical edges of 1-7 EV, 1300 px), the max halo width (px where \|code - plateau\| > 1) and peak, per control at ±100, over all edges. | each ≤ baseline + 2 px and + 0.5 code | `--only HA1` (same logic as `$A/halo_edges.py`) | H-100 25/5.0, H+100 17/4.0, S-100 25/3.9, S+100 29/5.3, W-100 12/2.6, W+100 34/7.6, B-100 6/2.0, B+100 9/2.0 | NR (WS-07) |
| HA2 | `hard_edge` (9.7 EV step): no halo at any value of any key. | 0 px | `--only HA2` | 0 | NR (WS-07) |
| HA3 | Real skylines, with `halo_real.py` on the `swx` tree (1840 at +2, 4213 at +1.5): excess p90 per control and value. The sky's own gradient inflates this metric, so the tolerance is 15 %. | each ≤ 1.15 × baseline | `cd $S/after && PYTHONPATH=$A python3 $A/halo_real.py swx` | H-100: 1840 17.9, 4213 15.9; H+100: 16.3, 13.8; W-100: 6.1, 3.2; W+100: 36.9, 27.0; S±100 1840: 7.8 | NR (WS-07) |

## 7. GPU parity and table keys

I checked by reading the code that every WS-05 function reaches the GPU only through
tables that `RenderPlan` bakes from the same `ToneEngine` the CPU uses. So a change made
inside ToneEngine is a change to both paths at once, in the same commit:

- **Gain.** `RenderPlan` builds `ToneEngine(tone:zones:)` (RenderPlan.swift:201), bakes
  `toneGainLUT` from `toneEngine.bakeGainLUTAndFloor()` (RenderPlan.swift:216-218) and
  the 32³/65³ `toneGainCubeBaked` from that same LUT (RenderPlan.swift:509-573).
  - The CPU `ReferenceRenderer.applyTone` reads `plan.toneGainLUT`
    (ReferenceRenderer.swift:242).
  - The GPU `RenderGraph.applyTone` reads `plan.toneGainCubeBaked` and
    `plan.toneGainScale` (RenderGraph.swift:895-905).
  - Neither renderer evaluates a weight function itself.
- **Anchors.** `DisplayTransform.forRecipe` calls `ToneEngine.applyAnchors`
  (DisplayTransform.swift:425-426). `RenderPlan` builds its transform from that
  (RenderPlan.swift:261). Both renderers apply the finish LUT that `RenderPlan` bakes from
  it (`plan.finishLUT`, RenderGraph.swift:269-278).

| id | claim | threshold | command | owner |
|---|---|---|---|---|
| G1 | The diff touches no renderer code. The change is confined to ToneEngine (and `BasicPanel` / tests). | `git diff --stat claude/inspiring-dirac-ulgpch -- Sources/LumenPipeline Sources/LumenCore/Engine/ReferenceRenderer.swift Sources/LumenCore/Engine/RenderPlan.swift Sources/LumenCore/Engine/DisplayTransform.swift` is empty | that command | WS-05 |
| G2 | `applyAnchors` writes only `whiteAnchorEV` and `blackAnchorEV`. These are the only tone-derived fields in the finish-table cache key (RenderPlan.swift:377-385). Any other `DisplayTransformParams` field written from Tone would be served stale from `PlanTableCache`. Every new input to the gain bake must come from `Tone` / `Zones`, which `ToneKeyInputs` already keys. | holds by reading the diff | read `ToneEngine.applyAnchors` in the diff | WS-05 |
| G4 | If A1 changes `defaultWhiteAnchorEV`, every anchor that does not come from `ToneEngine` is listed in REPORT.md, together with whether it must follow. Read from the code at base: `DisplayTransformParams.whiteAnchorEV = 5.0` (DisplayTransform.swift:67, WS-13), which `forRecipe` overwrites but which any direct `DisplayTransform(params)` keeps. `FilmLab`'s neutral transform (FilmLab.swift:1603-1606) is built without `applyAnchors`. `GradeEngine` has `whiteAnchorEV: Double = 5.0` defaults (GradeEngine.swift:98, 188, 369). `Zones.defaultPivots` is derived from `defaultWhiteAnchorEV` (Recipe.swift:604-607); its +4 EV "Bright" pivot would sit above a +3 EV anchor. None of these may be edited by WS-05. Each mismatch goes to NEEDS for its owner. | REPORT lists every site with a verdict | `grep -rn "whiteAnchorEV.*5\.0\|defaultWhiteAnchorEV" Sources` | WS-05 (report); owners fix |
| G3 | The existing CPU/GPU pairing tests stay green: `testBakedToneCubeTimesScaleEqualsTheGainTable`, `testTheToneCubeAndItsScaleStayAPairOnTheDRAFTPath`, `testToneGainLUTMatchesTheDirectEvaluation`, `ToneTwinClampTests`. macOS `gpu-parity.yml` is the integrator's gate. | pass | `swift test --filter "RenderPlan\|ToneTwinClamp\|EngineTests"` (Swift 6.1.2) | WS-05 |

## 8. Test gates (from LANE-BRIEF §2)

Use Swift 6.1.2 for tests (`export PATH=/opt/swift612/usr/bin:$PATH`). Swift 6.0.3
cannot parse LumenApp.

| id | claim | command | baseline |
|---|---|---|---|
| T1 | It builds clean. | `swift build --target LumenCore --target LumenRender` | clean |
| T2 | All core tests pass. The builder adds unit tests in `Tests/LumenCoreTests` for the measurable lines at engine level, without renders: S1/S5 as `stops(at:)` limits (Shadows +100 gain at -4 EV and at -6 EV against Blacks +100), W2/W4 (Whites +100 maps C0 - 1.5 EV to at or below the white anchor, and maps C0 - 0.5 EV to at least the anchor; Whites' gain at z7 is no more than Highlights'), H6 (for every slider, `exactColor(s)` equals the default plan's `exactColor(s · g)` within 0.5° of hue, so in particular Whites ±100 leaves the `DisplayTransform` unchanged for a colour it applies no gain to), A1 (`DisplayTransform.forRecipe(Recipe())` maps +2.47 EV to 238-250 and +2.90 EV below 254.5), M3. | `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` | 3044 tests, 0 failures |
| T3 | The ProofRegistry authority floors still hold for the four controls (`tone.highlights` 35, `tone.shadows` 30, `tone.whites` 30, `tone.blacks` 15, Tests/LumenCoreTests/Proof/ProofRegistry.swift:207-229). The control stays alive across its whole travel. | `swift test --filter ControlProofTests` | see the note below this table |
| T4 | No existing test is skipped or loosened. Some tests encode the behaviour this spec replaces, and those may be rewritten in the same commit, with the reason in REPORT.md. They are EngineTests `testShadowsIsAShelfAimedWhereShadowsAreVisible` (:231), `testWhitesAndBlacksMoveBothTheAnchorsAndTheCurve` (:361), `testTheEndShelvesOverlapTheZonalOnesAsTheCommentSays` (:526) and `testHighlightsCannotRenderPastDisplayWhite` (:728). If the Whites anchor move changes, they also include `GradeStripAxisTests` (:84, :98, :117), `MaskingTests` (:215, :298), `ColourAccuracyTests` (:55) and `AppliedReadoutTests` (:62). If A1 moves `defaultWhiteAnchorEV`, every test that pins the factory +5 EV anchor or a rendered code above mid-grey is affected. That includes `EngineIntegrationTests.testTheDefaultRenderingPutsTheAnchorsWhereItPromises` (:1700), `DisplayTransformShoulderRolloffTests`, `EngineTests.testTransformHitsAllFourAnchors` (:13) and the committed ControlProof records (`testTheCommittedRecordsStillDescribeWhatTheEngineDoes`). Each is updated to the new anchor with its invariant kept, and the list goes in REPORT.md. The invariant behind each test must still be asserted, for example "nothing renders past display white" and "the grading axis equals the rendered anchors". | `git diff` of Tests/ | - |

T3 baseline: **not measured.** In a debug build, `swift test --filter ControlProofTests`
was still inside `testEveryRegisteredControlIsAliveAcrossItsWholeTravel` after 25 minutes
and was killed by the timeout (exit 124). That is why the brief's baseline skips it. The
builder runs it in release, in the background, on the base commit and on the change:
`swift test -c release --filter "ControlProofTests"`. T3 passes if there is no new failure
for the four tone controls, plus, if A1 moved the anchor, for `tone.contrast` (NEEDS N8).
A failure that also occurs on base is listed as pre-existing.

## 9. Visual claims (judge at 100 %, before against after)

Before = `$S/base/...`, after = `$S/after/...`, the same path under each.

- **V1, Shadows on real foliage.** Sheets `sw/6929/shadows/sheet.png` and
  `sw/4213/shadows/sheet.png`. Look at the dark foliage and the deep shadow at 100 % from
  `tiles/tile_4_+100.png` against `tile_2_0.png`. At +100 the darkest accents must still
  read as near-black. The quarter tones must open at least as much as before. Leaf and
  bark texture in the opened shadows must look at least as crisp as at 0. The +100 tile
  must not read as a grey veil over the shadows, which is what the before tile shows.
- **V2, Whites travel.** Sheets `sw/top_steps/whites/sheet.png`,
  `sw/grey_ramp/whites/sheet.png` and `fine/whites/sheet.png`. Across -100…+100 the top
  steps brighten in visibly even increments. At +100 only the top one to one and a half
  stops below the default clip point C0 reach pure white. No two neighbouring tiles from +60 to +100
  look identical. The +1 to +2 EV steps barely move: that is Highlights' territory.
- **V3, Blues keep their hue.** Sheets `sw/hue_wheel/whites/sheet.png` and
  `sw/sky/whites/sheet.png`, plus `swx/hue_wheel/whites/sheet.png` at exposure +2.
  - At exposure 0, the Whites ±100 wheels show no visible hue change against 0 in the
    blue to violet sector (240-300°).
  - On the sky probe, the rows at -1 and 0 EV are visibly unchanged by Whites.
  - At exposure +2, Whites +100 blues are not more violet or pink than they were before.
  - Compare with `docs/quality/lanes/WS-05/evidence/before_sky_probe_blue_to_purple.png`
    and `before_hue_wheel_whites_plus2ev.png`.

- **V4, Sensor white is white (A1).** Sheets `sw/6929/highlights/sheet.png`,
  `sw/2348/highlights/sheet.png` and `sw/1569/highlights/sheet.png`, value 0 tile, before
  against after. Sensor-clipped areas (sky, specular highlights) read as white, not as
  light grey. Diffuse whites and bright clouds keep visible tonal separation, with no
  newly flat white patches. Mid-grey and shadows look unchanged. The before tiles show
  the "pastel" ceiling at code 221.

The builder ships at most 12 before/after PNGs (each under 400 KB) in
`docs/quality/lanes/WS-05/evidence/`, covering V1 to V4 plus S1/W2.

## 10. Baseline summary

`python3 $S/measure.py $S/base`: **18/32 PASS**.

The 14 lines that FAIL at baseline are the WS-05 defects:
- A1 and A2: sensor white renders at 221;
- S1, S3, S4 and S5: Shadows lifts the black point and flattens;
- W1, W2, W3, W4 and W7: Whites is too strong, accelerates and has a dead range;
- H6, H1 and H2: the Whites anchor coupling adds hue drift.

The NR lines and the remaining WS-05 non-regression lines all PASS at baseline, and must
still PASS after the change.


