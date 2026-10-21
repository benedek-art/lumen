# WS-06 Contrast & Pivot: audit

Auditor pass. No source code changed. Branch `quality/ws-06-contrast-pivot`.

Scope: `tone.contrast` and `tone.contrastPivot`, which means `ToneEngine.contrastMapped`
(ToneEngine.swift:647), the constants above it (`contrastShoulderStart` 0.2,
`minContrastReachEV`), and the Contrast and Pivot rows in `BasicPanel.toneRows`
(BasicPanel.swift:475-496).

Where the outputs are:

- Sheets and crops: `/tmp/claude-0/ws06/audit/`.
- Measurement scripts: `/tmp/claude-0/ws06/scripts/`. These are `curve.py` (a Python port
  of `contrastMapped`), `ramp.py`, `checker.py`, `lrmodel.py`, `huewheel_bin.py`,
  `smooth.py`, `crop.py` and `mkedge.py`.
- Swift probe linked against the release LumenCore objects:
  `/tmp/claude-0/ws06/swift/probe.swift`.
- Raw numbers: `/tmp/claude-0/ws06/work/*.txt`.

Photos used:

| Id | Camera | Content |
|---|---|---|
| 6929 | Sony A7 IV | foliage, wall |
| 2545 | Panasonic GX85 | sky, hard shadow |
| 983 | Canon 5D IV | HDR snow, lantern, Passport chart |
| 2242 | Panasonic GX850 | saturated jigsaw |
| 2348 | Panasonic G9 | low key, black jacket |
| 4694 | Canon R5 | saturated fruit, dark surround |
| 1346 | Canon 5D | ColorChecker Passport |

There are no people in the corpus, so `synthetic/skin_tones` stands in for portraits. Each
photo was rendered with the as-shot Kelvin, Tint and ISO from its sidecar.

## How the control works

Contrast changes the tone curve in log-exposure, t = log2(Y/0.18):

```
mapped(t) = pivot + d · mix(slope, 1, smoothstep(0.2, 1, |d|/reach))
d         = t − pivot
slope     = 1 + 0.6·c/100
reach     = distance from the pivot to the live white anchor (+5 EV) or black anchor (−9 EV)
```

S7 turns this into a scalar gain, `2^(mapped − t)`. The gain is looked up through the
edge-aware guided luminance mask and multiplied into the scene-linear RGB, before the
display transform.

Two consequences follow from this design:

1. **R:G:B ratios are kept exactly.** The display transform (huePreservation 100, ratio
   path through the midtones) keeps OKLab hue and C/L about constant. So Contrast changes
   lightness only. Absolute chroma goes up with lightness and down with darkness, and
   "saturation" (C/L) does not move.
2. **The curve is evaluated per mask value, not per pixel.** Near edges, and on detail
   smaller than the mask radius (2% of the long edge), pixels get the gain of their
   neighbourhood.

## Findings

### 1. Identity is exact: FINE

At contrast 0 the S7 stage is skipped (`toneIsIdentity`, ReferenceRenderer.swift:73), so
the output is bitwise identical to the default recipe at every pivot:

- PNGs are byte-identical with `cmp` for pivot −4, 2.37 and +4 on 6929 (dithered) and on the
  colorchecker. Pivot 3 on grey_ramp is also identical.
- In the Swift probe, `isIdentity` is true and `bakeGainLUT().samples` equals the default
  LUT for pivots −4, −1.3, 0, 2.7 and 4.

### 2. The 1D curve is monotone, has the right fixed points, and is linear in the slider: FINE

Source: `work/curve.txt`. The grid was contrast −100…100 in steps of 25 × pivot
{−4, −2, 0, 2, 4}, with t from −9 to +5 in 1e-4 EV steps.

- **Monotone everywhere.** The minimum derivative is 0.4105, at contrast +100 (at
  +3.85 EV for pivot 0). At contrast −100 it is 0.40, at the pivot.
- **Fixed points hold.** The pivot, the white anchor and the black anchor all map to
  themselves with an error of 0.0 in every case.
- **The slope at the pivot is exactly 1 + 0.6·c/100.** Every displacement is exactly linear
  in c. For example, the shift at +2 EV is −1.012, −0.506, 0, +0.506 and +1.013 for c = −100,
  −50, 0, +50 and +100. There is no dead range.
- **The slider ends are not reciprocal.** This is a weakness, covered in finding 7.
  Slope 1.6 is +0.68 stops of log-slope, and 0.4 is −1.32. So Contrast −100 flattens about
  twice as hard as +100 steepens.
- **At −100 the curve is steeper than identity near the anchors** (maximum derivative 1.59).
  Any inverse-S curve with pinned ends must do this. On the −100 ramp it shows as a lifted,
  steep last two stops: 3 EV → 210 and 4 EV → 244, against 234.5 and 249 at contrast 0. See
  `syn_grey_ramp_contrast.png`. The kink is mild, not a defect.
- **Clipping on grey_ramp: none at any setting.** The count of code-255 and code-0 columns is
  0 for all 45 contrast × pivot renders, and there are no non-monotone steps. Distinct codes
  in the ramp row go from 249 at contrast 0 to 244 at −100 and 253 at +100.

### 3. The effect is concentrated in a ±1 to 2 EV midtone band and the top two stops are compressed hard: WEAKNESS

Source: `work/ramp.txt`, sheet `syn_grey_ramp_contrast.png`.

Display slope in codes per EV, at pivot 0:

| EV | −4 | −2 | 0 | +2 | +3 | +3.5 |
|---|---|---|---|---|---|---|
| contrast 0 | 8 | 28 | 51 | 32 | 22 | 16 |
| contrast +100 | 2 | 21 | 81 | 25 | 6 | 4 |

At +100 the extra slope sits only inside about ±1.5 EV. Already at +2 EV and −2 EV the
display slope is lower than at contrast 0. That is the 0.2 hold: the straight section runs
to only +1.0 EV and −1.8 EV.

The top two stops lose most of their separation. Across +2…+4 EV, contrast 0 spans codes
207→249 (42 codes); +100 spans 235→253 (18 codes), which is 2.3× flatter.

On a real photo (983 at exposure +1.5, `photo_983_exp+1.5_contrast.png`):

- Bright pixels (code ≥ 200 at contrast 0): their spread falls from std 8.30 to 5.69 codes.
- Pale chart patches and snow nearly merge to white.
- Highlight clipping (any channel at 255) goes from 0.001% to 0.439%.

The shadow side behaves the same way. At −4 EV, code 10 becomes code 2. Code-0 pixel share
at +100:

| Photo | Contrast 0 | Contrast +100 |
|---|---|---|
| 1346 | 0.53% | 8.97% |
| 4694 | 0.007% | 4.38% |
| 2348 | 0.66% | 3.14% |
| 2545 | 0% | 0.16% |
| 983 | 0% | 0.26% |

Visually, the 2348 jacket folds go to black (`crop_2348_jacket_c0_c100.png`), and dark skin
(MST 9-10) goes nearly black on `syn_skin_tones_contrast.png`.

What Lightroom does: PV2012 Contrast also compresses the highlights and shadows, and it
rolls off rather than hard-clipping. But Lightroom's highlights are usually handled by its
own adaptive highlight compression, and Adobe recommends setting Contrast for midtones only
([Adobe help](https://helpx.adobe.com/ca/lightroom-classic/desktop/help/tone-control-adjustment.html)).

The behaviour is correct for an S-curve. What is open is how much of the shoulder to give
up for midtone slope. The trade table in the `contrastShoulderStart` comment covers the
zonal-limiter side of this, but not the loss of highlight separation.

### 4. Hue is stable where nothing clips; the larger shifts belong to the display transform and finish table: FINE for WS-06 (out-of-lane notes)

Sources: `work/checker65.txt`, `work/huewheel.txt`.

**Colorchecker, 18 chromatic patches, 65-cube (export) finish table, patch means:**

| Contrast | Mean \|Δh\| | Max \|Δh\| |
|---|---|---|
| +100 | 0.53° | 1.92° (orange yellow, max code 244) |
| +50 | 0.30° | 0.95° |
| −100 | 0.32° | 1.33° |

**Hue wheel, binned in 15° hue bins:**

| Wheel placement | Ring | Max \|Δh\| at ±100 |
|---|---|---|
| At the pivot | r 0.2-0.7 | ≤ 0.54° |
| At −2 EV | inner ring | ≤ 2.75° |
| At −2 EV | r 0.5-0.97 | ≤ 0.95° |
| At +1.5 EV | r 0.2-0.4, in gamut | ≤ 2.03° |
| At +1.5 EV | r 0.5-0.7, 30% of pixels have a channel clipped | ≤ 7.34° (blue, 255-270°) |
| At +1.5 EV | r 0.85-0.97 | 12.7° |

The shifts at +1.5 EV come from the display transform's response to exposure, not from
Contrast. An exposure change of ±0.81 EV, equal to Contrast ±100's gain at +1.5 EV,
reproduces them: 7.54° and 11.38° against 7.34° and 11.47°
(`tiles/hw65_expeq`, `syn_hue_wheel_exp1.5_contrast.png`).

**Out of lane (finish table, WS-12):** at the 33-cube interactive table, low-chroma skin
patches swing 2-4° in hue for any small exposure change. Light skin goes 41.3° → 44.9° for
+0.15 EV of plain Exposure. At 65 the swing is ≤ 0.5°. This makes Contrast look like it
shifts skin hue in the preview (light skin +4.0° at +50 on the 33 table). It is not
Contrast's doing.

What Lightroom does: Lightroom's curves lock hue by mapping the max and min channels and
interpolating the middle one. Martin Evening reports hue shifts are "usually within ±3°"
([Peachpit LR curves PDF](https://ptgmedia.pearsoncmg.com/imprint_downloads/peachpit/peachpit/lightroom4/pdf_files/LRCurves.pdf)).
Lumen is at or better than that.

### 5. Contrast adds no saturation; Lightroom does, on purpose: WEAKNESS (the most visible gap)

Sources: `work/lrmodel.txt`, `work/smooth.txt`, `syn_colorchecker_contrast.png`,
`photo_6929_contrast.png`.

**Lumen.** OKLab C/L is unchanged across the whole slider:

- Colorchecker chromatic mean Δ(C/L): −1.6% at +100, −0.5% at +50, +0.2% at −100.
- 6929 mean C/L is 0.0653 at every step from −100 to +100. On 2545 it is 0.0556-0.0558.

Absolute chroma therefore falls wherever contrast darkens:

- Patch-mean ΔC at +100: −3.1% overall. Blue −27%, purple −28%, dark skin −15%.
- Whole-frame mean C at +100: 6929 −19% (0.0247 → 0.0201), 4694 −29%, 983 −22%.

Visually, +100 reads as darker and duller. The 6929 foliage and the 1346 blue patch (navy,
`crop_1346_whitepatch.png`) both lose colour.

**What Lightroom does, documented.** Mark Hamburg (Adobe): Lightroom and Camera Raw
"preserve hue but adjust saturation to match with contrast changes because having
saturation and contrast get out of sync tends to look rather odd". Thomas Knoll: they chose
the "mild saturation boost" because it gives "more pleasing, film-like results". The 2023
Refine Saturation control applies only to the point curve, not to the Contrast slider
([Peachpit LR curves PDF](https://ptgmedia.pearsoncmg.com/imprint_downloads/peachpit/peachpit/lightroom4/pdf_files/LRCurves.pdf),
[Andrew Haysom](https://andrewhaysom.myportfolio.com/refine-saturation-slider)).

**Quantified Lightroom-like band.** I applied Lumen's own grey-ramp tone curve to the
contrast-0 rendered patches two ways. One is a per-channel RGB curve. The other is the
documented hue-locked curve (the DNG SDK RefBaselineRGBTone construction: max and min
channels go through the curve and the middle channel is interpolated). Chromatic-patch
means:

| | Contrast +50 | Contrast +100 | Contrast −100 |
|---|---|---|---|
| Hue-locked ΔC | +16.3% | +29.1% (C/L +27%) | −48.5% |
| Per-channel ΔC | +17.1% | +30.9% | −49.0% |
| Lumen ΔC | −1.2% | −3.1% | +1.0% |

Hue-locked max \|Δh\| at +100 is 5.7°, against 6.7° per-channel.

So a Lightroom-style Contrast at the same tonal strength would add roughly +15% chroma per
+50. That is an upper bound: this curve is steep (log-slope 1.6), it was applied in display
sRGB rather than ACR's linear ProPhoto space, and Lightroom's actual +100 is probably milder
in tone. A realistic target is +8…+20% C/L at +100.

### 6. Edge behaviour at strong contrast: a visible gradient band at about 1 EV edges, none at large edges: WEAKNESS (owned by WS-07)

Sheets: `syn_midedge_contrast.png` (a synthetic frame from `scripts/mkedge.py`),
`crop_midedge_1EV_halo_x2.png`, `syn_hard_edge_contrast.png`.

**1 EV step (−0.5 | +0.5 EV), 1600 px wide, mask radius 32 px:**

- At +100, edge contrast is lower right at the edge. Over about 40 px the dark side rises
  79 → 86 and the bright side falls 159 → 153, so 6-7 codes of reverse gradient.
- At −100 it is a classic halo: the dark side dips 109 → 103 and the bright side rises
  130 → 137.
- Both bands are visible in the 2× crop.

**Large edges are clean:**

- 4 EV (−2 | +2): ≤ 2 codes.
- 5 EV (−4 | +1): ≤ 3 codes.
- hard_edge (+4.5 / −5 EV): no visible halo. Those tones sit near the anchors, where
  Contrast is the identity.

No halo is visible at the sky and tree edge on 2545 (`crop_2545_sky_tree.png`).

What Lightroom does: global Contrast is a plain curve with no spatial support, so it cannot
halo. Lumen's Contrast inherits the tone mask that suits Highlights and Shadows. Whether
Contrast, a global curve control, should use the mask at all is a design question for
WS-07.

### 7. Smooth across the slider but front-loaded toward the negative side: WEAKNESS

Source: `work/smooth.txt`; sheets `photo_6929_contrast_step10.png` and
`photo_2545_contrast_step10.png`, 21 values from −100 to +100 in steps of 10.

- There are no jumps or reversals. The per-step mean \|Δluma\| decays smoothly: 6929 goes
  from 3.11 down to 1.37, 2545 from 2.58 down to 1.21.
- The per-step gain in RMS luma contrast falls steadily from 1.85 (at −100) to 0.62 (at
  +100) on 6929, a factor of 3.0. On 2545 it goes from 2.25 to 1.03.
- Going from 0 to +100 adds 8.2 RMS (39.2 → 47.4). Going from 0 to −100 removes 14.7.
- The proof record (`Tests/LumenCoreTests/Proof/records/tone.contrast.json`) shows
  `frontLoading` 0.635.

There are two causes. The slope mapping is linear (1 ± 0.6), not log-symmetric (finding 2).
And the display shoulder and toe absorb the steepening on the + side. A Lightroom user
expects +50 and −50 to be about equal and opposite.

### 8. Pivot holds in output; ±4 EV is wide and mostly acts as a brightness control at the ends: FINE / WEAKNESS

Sources: `work/ramp.txt`, sheets `syn_grey_ramp_pivot_at_c100.png` and
`photo_6929_pivot_at_c100.png`.

- **The pivot is fixed in display output.** The rendered code at the pivot EV stays put for
  all contrasts: pivot −4 at code 10, −2 at 41, 0 at 118 (117.5 at +100), +2 at 207. Pivot +4
  moves 249 → 250 at negative contrast, one code of LUT interpolation. Mid-grey 0.18 is held
  at pivot 0, which `AccuracyProbeTests.testContrastLeavesMidGreyExactlyAlone` also pins.
- **The range runs from code 10 to code 249.** Pivot −4 EV renders at code 10 and +4 EV at
  code 249, nearly the whole display range. At the ends Contrast mostly becomes exposure. On
  6929 at contrast +100 the median code is:

  | Pivot | −4 | −2 | 0 | +2 | +4 |
  |---|---|---|---|---|---|
  | Median code | 140 | 84 | 44 | 20 | 11 |

  The picture moves about 3.5 stops of median brightness, and at pivot +4 it is nearly
  black.
- **The ends are not dead.** With the default anchors the one-sided reach is never zero: at
  pivot +4 the white reach is 1 EV. In the ramp, contrast moves the zones on both sides at
  every pivot (RMS 37-59 codes at ±100).
- **One dead range.** When Whites ≥ +67 pulls the white anchor below 4, the pivot is clamped
  to the anchor. At Whites +100, pivot 3.5 to 4.0 renders identically (max diff 0.0000 EV, in
  the Swift probe). That is a dead 0.5 EV of slider travel which the panel does not show.
- **Unit and sign are clear.** The unit is EV from mid-grey, and positive means the hinge
  sits on a brighter tone. Lightroom has no equivalent: its Contrast pivot is fixed and not
  documented, and only Tone Curve point edits come close.
- **Range.** Given that ±4 EV covers codes 10-249 and that outside about ±2.5 EV the control
  acts as a brightness slider, ±3 EV (codes 20-234) would lose nothing useful. That is a
  judgement call.

### 9. Interaction with the other tone sliders: FINE (contrast is never scaled)

Source: Swift probe, `work/probe.txt`.

- **Contrast is never scaled by the limiter.** With Highlights −100 and Shadows +100 at
  contrast +100, the contrast slope at the pivot is still 1.600 (total 1.588), and
  zonalScale is 0.846. In the full five-way case at contrast −100 the contrast slope is
  0.400, total 0.395, and zonalScale 0.461. `solveZonalLimits` treats the contrast term as
  slack, as documented.
- **Contrast does scale its neighbours.** Applied amounts of the single slider at ±100:

  | Contrast | Highlights −100 | Shadows +100 | Blacks +100 |
  |---|---|---|---|
  | −100 | −0.937 | 0.619 | 0.909 |
  | 0 | −1 | 1 | 1 |
  | +100 | −0.846 | 1 | 1 |

  All other single sliders apply at 1.000. These match the trade table in the
  `contrastShoulderStart` comment. Any change to the hold or the slope law moves them.
- **The full tone map is monotone** over contrast {−100…100 step 25} × pivot {−4…4} ×
  H/S/W/B ∈ {−100, 0, 100}^4. The worst minimum derivative is −0.0008 (c −100, pivot 0,
  h −100, s +100, w −100, b −100). That is a sampling residue between the solver's 0.05 EV
  step and this 0.01 EV probe, and the bake's forward clamp catches it. Negligible; it
  belongs to WS-05.
- **Exposure runs first.** It is applied in the S6 matrix before S7, so the pivot is on the
  exposed image, the same order as Lightroom. The anchors follow Whites and Blacks
  (`testTheContrastFixedPointFollowsTheAnchorsWhitesAndBlacksMove`).

### 10. UI rows and tooltips: Contrast's tooltip is partly untrue: BUG (copy)

BasicPanel.swift:475-496:

| Row | Range | Step | Default | Decimals | Track |
|---|---|---|---|---|---|
| Contrast | −100…100 | 1 | 0 | 0 | `Lumen.contrastStops` |
| Pivot | −4…4 | 0.01 | 0 | 2 | none |

Neither row has a hardRange.

- **Contrast tooltip:** "…while the ends of the scale stay pinned, so it cannot clip a
  highlight." On grey it is true, with 0 code-255 columns at any setting. On colour and on
  real photos it is not true:
  - 983 at exposure +1.5: highlight clipping goes 0.001% → 0.439% at +100. This comes from
    channel clipping of bright colours and from the mask giving small bright details their
    neighbourhood's gain above 1.
  - The tooltip says nothing about shadows, which Contrast crushes to code 0 (up to 9% of
    pixels, finding 3).
- **Pivot tooltip:** "the tone it holds still. Raise it to anchor the brights and let
  contrast work the shadows". This is accurate. At pivot +2 the shift at −4 EV is −2.17 EV
  against +0.56 at +3. It does not warn that a raised pivot with + contrast darkens the whole
  picture (finding 8).

### 11. Tests that constrain any change

**Hard constraints on the curve:**

- `EngineTests.testContrastHitsItsSlopeAtThePivot` pins slopes 1.6, 1.3 and 0.4 at
  c = 100, 50 and −100.
- `testContrastPivotHoldsStill`.
- `testContrastLeavesTheExtremesOfTheLogScaleAlone` checks ±12 EV.
- `testContrastCannotPushAPixelPastTheDisplayAnchors`.
- `testTheContrastFixedPointFollowsTheAnchorsWhitesAndBlacksMove`.
- `testAPivotPastTheWhiteAnchorStillCannotPushAPixelPastIt`.
- `testContrastIsMonotoneAcrossTheWholeScaleAtEverySetting`.
- `RobustnessTests.testToneIsMonotoneAcrossTheWholeContrastRange` (about line 1955) and
  `testRenderedLuminanceIsMonotoneAtExtremeSettings`.
- `ColourAccuracyTests.testContrastKeepsTheWhiteAnchorFixedWhenWhitesPullsItBelowThePivot`.
- `AccuracyProbeTests.testContrastLeavesMidGreyExactlyAlone`, within 0.25 code.
- `MaskingTests.testAMaskedContrastPinsTheGlobalDisplayAnchorsNotTheFactoryOnes`. The local
  masked Contrast uses the same `contrastMapped`.

**Golden fixture:** `EngineMathFixtureTests.testContrastMappingMatchesTheReference` checks
`Fixtures/enginemath.json` at 1e-12, generated by `scripts/gen-fixtures.py`
(`contrast_mapped`). Any curve change must regenerate it.

**Numbers that depend on the hold and the slope:**

- `AppliedReadoutTests` around line 134: Highlights −100 at contrast −100 reads "−94", and
  Blacks reads "+91 of +100".
- `RobustnessTests` limiter cases around lines 1027-1320.
- The trade table in the `contrastShoulderStart` comment. Its comment says "The generator
  asserts all three numbers".
- `ZoneFlatteningTests:77`.

**Proof registry:** `ProofRegistry` has `tone.contrast` with authorityFloor 55 (the record
stands at 68.38, frontLoading 0.635, deadSteps 0, smallestLiveStep 2.58). It has
`tone.contrastPivot` with authorityFloor 20, probed at contrast 50 over −4…4. Changing the
Pivot range means changing this entry and `lumen-render keys` (ProofRegistry-sourced).

**Display transform test with the same name, not about this control:**
`testContrastIsTheLogLogSlopeAtMidGrey` is about `look.render.contrast`.

## Recommended direction

1. **Add a Lightroom-like saturation coupling, kept mild and hue-locked.** Target OKLab C/L
   of about +10…+20% at +100 and about +5…+10% at +50 for in-gamut midtone colours. Negative
   contrast should take chroma down symmetrically, but less than Lightroom's roughly −45%,
   say −15…−25% at −100. Keep the hue drift ≤ 1-2°, using the measured mean 0.5° and max
   1.9° as the bar not to regress. Drive it from the local log-slope of the contrast curve,
   so it vanishes at the anchors and in clipped regions.
   - This cannot live in `contrastMapped`. S7 is a scalar gain. It needs a chroma term in
     the S7 multiply (a per-pixel `(gain, chromaScale)` pair), owned by WS-07, or a coupling
     into the WS-16 saturation pass.
   - Record it in `NEEDS.md`. Do not grow it inside WS-06.
2. **Make the slider symmetric in log-slope.** Use slope = 2^(k·c/100) instead of
   1 + 0.6·c/100. For example k = log2(1.6) ≈ 0.678 keeps +100 at 1.6 and makes −100 equal
   to 0.625, not 0.4. Alternatively keep −100 at 0.4 and raise +100 to 2.5, which needs the
   hold lowered for monotonicity.
   - This evens out the 3:1 per-step authority ratio (finding 7). It also eases the
     −100-side limiter scaling (Shadows +100 0.619, Blacks 0.909).
   - It changes `testContrastHitsItsSlopeAtThePivot`, the fixture and the authority record,
     so re-check `authorityFloor` 55.
3. **Shoulder and hold.** 0.2 is defensible on the monotonicity and limiter grounds already
   documented. But the spec should add a highlight-separation bar, for example "codes
   spanned by +2…+4 EV at contrast +100 ≥ 60% of contrast 0", against today's 43%.
   - One option is an asymmetric hold: a longer straight section on the 9 EV shadow side
     and a softer, earlier shoulder on the 5 EV highlight side. The slope is spent where the
     reach is.
   - Also add a shadow bar for code-0 growth on 1346 and 4694 at +100.
4. **Pivot.** Keep EV units and the sign. Consider narrowing to ±3 EV, or keep ±4 and grey
   out or label the part above the live white anchor. A raised pivot needs a tooltip clause
   saying it darkens the picture under + contrast.
5. **Fix the Contrast tooltip.** Drop "cannot clip a highlight". Say the white and black
   points stay fixed, and that strong settings compress the brightest and darkest tones.
6. **Out of lane, for the integrator:**
   - The 33-cube finish table swings low-chroma hue 2-4° per small exposure change (WS-12).
   - Bright saturated colours rotate up to 12° with exposure at +1.5 EV (WS-13).
   - The tone mask band at about 1 EV edges under strong global contrast (WS-07).
