# WS-05 needs from other lanes

These are causes the WS-05 spec found outside WS-05's owned functions. WS-05 does not edit
them. Each one has a non-regression line in `SPEC.md` that WS-05 must not make worse.

All numbers are on the base commit `84bcd7c`. Paths:
- `$A` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/audit`
- `$S` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/spec`

Renders are in `$S/base`. `python3 $S/measure.py <tree> --only <id>` re-measures a line.

---

## WS-07 (tone stage spatial application: guided mask, `logLuminance`, ε)

### N1. The zonal coordinate t ignores the max channel, so Highlights cannot reach a saturated blue sky (F4)

**Where.**
- `ReferenceRenderer.applyTone` builds the mask from `image.luminancePlane(space:)`, which
  is Rec.2020 Y (ReferenceRenderer.swift:234-240).
- `RenderGraph.applyTone` does the same through `logLuminance` (RenderGraph.swift:885,
  helper at :2020).
- `t` is therefore log2(Y / 0.18). A saturated blue has a low Y compared with its blue
  channel, so the tone engine treats it as a midtone while its blue channel is the one
  closest to clipping.

**Evidence.**
- Sky probe (`$S/base/sw/sky/highlights`; `cd $S/base && PYTHONPATH=$A python3 $A/sky_an.py highlights`):
  - rec709_blue at 0 EV luminance, whose B channel is code 247 at +3.4 EV: Highlights -100
    changes it by 0, because `highlightWeight(0) = 0`.
  - azure at +1 EV: B 237 → 232. Highlights -100 removes only 5 codes.
- 983 at exposure +2, sky Y at +0.67 EV and the blue channel at +1.8 EV: Highlights -100
  lowers sky OKLab L by only 0.011 (B 203 → 200).
- 983 at exposure +3 (`--only W6`): 44.5 % of the default-clipped pixels with scene max
  channel between +3.5 and +4 EV are still 255 at Whites -100. Those pixels have Y at
  about +2…+3 EV, which is below where Whites acts. Highlights -100 leaves 0.5 % of them
  clipped, because its shelf starts at 0 EV.

**Proposed fix.** Drive the mask from a norm that sees the max channel. Use the same norm
in both renderers:

- `n = max(Y, k·maxRGB)` with k ≈ 0.5–0.7, or
- `Y^(1-a)·maxRGB^a` with a ≈ 0.3–0.5.

The norm is still a scalar and still exposure-equivariant: scaling the input by 2^E shifts
log n by E. So the mask keeps its exposure-independence, the gain stays a scalar, and S7
stays hue-neutral. WS-05's weights need no change. With this, Highlights -100 becomes the
normal tool for a deep blue sky, as it is in Lightroom, and users stop reaching for Whites,
which has the hue problems in N4 and N6.

**Check.**
- On the sky probe, Highlights -100 on rec709_blue at 0 EV should reach B ≤ 235 (from 247).
- `--only R1,R2,H4,HA1` must not regress.

### N2. Halos at 1-2 EV edges (F6)

**Where.** The guided-filter mask radius is 2 % of the long edge (ReferenceRenderer.swift:237,
RenderGraph.swift:886). ε comes from `toneMaskContrastThresholdEV` = 0.375 EV
(ReferenceRenderer.swift:224). The GPU twin is `guidedSelfFilter` (RenderGraph.swift:2076).

**Evidence.**
- `edges` probe (`--only HA1`; `$A/halo_edges.py`), worst width / peak per control:

  | control | width | peak |
  |---|---|---|
  | Whites +100 | 34 px | 7.6 codes |
  | Shadows +100 | 29 px | 5.3 codes |
  | Highlights -100 | 25 px | 5.0 codes |
  | Shadows -100 | 25 px | 3.9 codes |

- There is no halo at a 9.7 EV step (`--only HA2`).
- Real skylines (`halo_real.py swx`):
  - 4213, Highlights -100: median 35 px, p90 excess 15.9 codes.
  - 1840, Whites +100: p90 excess 36.9 codes.
- Sky holes inside the canopy get the foliage's gain. On 1840 the open sky against the
  sky holes reads -13.6 against -10.2 codes for Highlights -100, and +26.8 against +16.7
  for Whites +100 (AUDIT F6).

**Proposed fix.**
- A two-scale mask: a small-radius guided base (about 0.5 % of the long edge) blended into
  the 2 % base by the local edge confidence `a` of the large-radius filter. Or a second
  guided iteration with ε reduced at the larger radius.
- Make sky holes take the sky's gain by guiding with a downsampled luminance that keeps
  small bright regions.
- WS-05 will keep its shelf slopes at or below today's maxima (the spec checks HA1 within
  +2 px / +0.5 code), so the amplitude does not grow from WS-05's side.

### N3. Texture finer than ε is preserved; texture coarser than ε gets the per-pixel curve (F5 texture, F8)

**Where.** ε = 0.375 EV (ReferenceRenderer.swift:224). Foliage, snow and roof texture
with amplitude above about 0.4 EV is treated as edge, so the mask follows it and the
shelf's slope applies per pixel. That slope is 0.4 stops per stop at the steepest point
of Highlights -100.

**Evidence** (`--only R3`; `$A/recover.py swx`). Highlights -100, local contrast
hp(-100) / hp(0):

| box | hp ratio |
|---|---|
| 983 lantern | 0.672 |
| 983 snow | 0.884 |
| 2545 roof | 0.775 |
| 4213 castle | 0.887 |

Lightroom keeps or raises highlight texture with Highlights -100. Shadows +100 also lost
16-24 % at baseline (`--only S3`). WS-05's reshaped Shadows window is expected to remove
most of that loss, so this need is mainly for Highlights.

**Proposed fix.** Apply the gain to the base layer only and let the detail layer pass
through unscaled, the way a local-Laplacian or a base/detail tone mapper does:
`out = gain(mask) · base + (in - base)` in log space, with the detail term limited near
edges so that halos (N2) do not grow. A plain alternative is to raise ε to about
0.6–0.75 EV. That trades texture for halo width, so it has to be measured against HA1
and HA3.

**Check.**
- R3 ≥ 0.90 on every box.
- HA1 and HA3 do not get worse.

---

## WS-13 (DisplayTransform hue behaviour, finish table)

### N4. Bright saturated blues drift toward violet, magenta and pink in the display transform, and Highlights and Whites slide pixels along that drift (F1, the owner's "funky blue highlights")

**Status: ACCEPTED by WS-13** as their spec lines 3.1-3.9 (the outset undoes the inset
rotation; the shoulder bleaches toward neutral at constant hue), per the programme
director. WS-05 does not fix this. WS-05's own obligation is SPEC H6: a slider adds no hue
drift beyond the transform. H6 must stay at ≤ 0.5° across the WS-13 merge. The evidence
below stays as WS-13's reference.

**Where** (`DisplayTransform.apply`, DisplayTransform.swift:357-410).

1. **Static rotation.** The inset primary rotation is `rotation = RGB(0.02, -0.03, 0.06)`
   (:62, used at :272). It adds a constant +6…+8° to every blue before any slider moves.
   With rotation off, hue is within 1° of the scene; with it on, it is +6.7°.
2. **Luminance-dependent drift.** The blend weight
   `t·(1 - shoulderU²)` (:396-399) takes `shoulderU` from the **max channel**
   (`peak = inset.maxComponent`, :383). sRGB blue at mid-grey *luminance* has its B
   channel at +3.4 EV, so it is rendered mostly per-channel. Per-channel compression of B,
   with R held by the rotated inset, raises R/B, which reads as violet and then magenta.

**Evidence** (`$A/harness`: `H trajectory`, `H decompose`; `$A/trajectory.txt`,
`$A/decompose.txt`).

At the default recipe, the OKLab hue of sRGB blue (20, 30, 255), scene hue 265.6°, goes
276.9 → 292.8 → 309.3 → 323.2 → 326.3° from -2 to +3 EV. That is a +49° drift, ending
pink (`[245,161,255]` at +2 EV).

Decomposition for sRGB blue:

| path | hue |
|---|---|
| pure max-norm path | 277.7 → 279.2° (stable) |
| blend without rotation | 270 → 310° |
| shipped path | 279 → 326° |

The gamut soft-clip holds hue, so it is not involved.

Slider-induced drift, which is this mechanism seen through WS-05's sliders:

| measurement | command | H-100 | H+100 | W-100 | W+100 |
|---|---|---|---|---|---|
| hue_wheel at exposure +2, \|Δh\| p95 | `--only H3` | 7.5° | 8.4° | 10.3° | 28.8° |
| sky probe, max \|Δh\| | `--only H4` | 9.1° | 3.4° | 14.6° | 9.7° |

The 2545 sky box at exposure +1.5 shifts -19.5° with Whites +100 (`--only H5`).

**Proposed fix.** Make the path to white hue-stable.

- Compute the per-channel result, then re-hue it to the hue of the ratio (max-norm) path
  in a perceptual space (OKLab / IPT), keeping the per-channel lightness and chroma. Or
  measure `shoulderU` on a luminance-weighted norm instead of the raw max channel, so a
  saturated blue at mid luminance is not treated as near-white.
- Revisit the blue rotation (0.06 rad). It is the whole of the static +6.7° offset.

**Acceptance proposal.** On the exact path, the sRGB-blue trajectory from -2 to +3 EV
drifts ≤ 10°, and mid sky has an offset of ≤ 2° against the scene hue.

**WS-05 coupling to note.** `shoulderU = log2(peak/0.18) / whiteAnchorEV`, so the blend
depends on the white anchor. WS-05 is removing or shrinking the Whites anchor move to
pass H1/H2 (F2). If WS-13 makes the blend independent of the live anchor, for example by
normalising by the default 5 EV, WS-05 could later bring back a full anchor move without
hue cost.

### N5. The 33³ finish LUT adds ±3-4° of hue jitter on blues; preview and export disagree (F9)

**Where.** The finish table is baked at the plan's `lutSize`: 33 for preview, 65 for
export (RenderPlan.swift:370-426). Lattice spacing is 0.75 EV per node across 24 EV of
log space.

**Evidence** (`H trajectory`, exact against `referenceColor`):
- mid sky at -1.5 EV: 260.5° exact, 264.6° at 33³.
- mid sky at +3 EV: 260.6° exact, 256.3° at 33³.
- With Highlights -100 at +3 EV, mid sky moves -0.3° exact but +3.3° through the LUT.
- At 65³ the difference is ≤ 1°.

**Proposed fix.** One of:
- 65³ for preview, if the PlanCostProbe budget allows;
- tetrahedral interpolation;
- a denser shaper near the shoulder (+1…+5 EV), where blues bend.

**Acceptance proposal.** \|exact - LUT\| ≤ 1° on the `H trajectory` blues from -2 to
+3 EV.

### N6. Near-white skies swing toward cyan on the way to white (F3)

**Status: ACCEPTED by WS-13**, covered by their lines 3.1-3.9 (the shoulder bleaches toward neutral at constant hue). WS-05 keeps only the strength part (W2, W4, W7) and H6.

**Where.** The same per-channel branch as N4. Pale and cyan skies move toward cyan
(per-channel hue 253 → 230°) as they approach white.

**Evidence** (`$A/slider_hue.txt`, `H slider`):

| patch | setting | Δh | chroma |
|---|---|---|---|
| mid sky at +3 EV | Highlights +100 | -28° | 0.049 → 0.005 |
| mid sky at +2 EV | Whites +100 | -23.9° | |
| azure at +2 EV | Whites +100 | -25.5° | |
| cyan sky at +2 EV | Whites +100 | -21.9° | |
| 2545 sky | Whites +100 | -19.5° | 0.076 → 0.016, B clipped on 100 % of the box |

**Proposed fix.** The same as N4: desaturate toward white at constant perceptual hue.
WS-05's part is strength. W2, W4 and W7 move the Whites +100 clip from +2.5 to at least
+3.5 EV, which keeps most real skies out of this region.

### N7. Chromatic pixels clip in one channel at a scene max channel of about +3 EV (information, low priority)

**Evidence.** On 983 at exposure +3, about half of the default-clipped pixels have a scene
max channel of only +2.7…+3.6 EV and Y of +1.4…+3.0 EV. A neutral at that max channel
renders at about code 234-243, but these render 255 in one channel. Whites -100 cannot
unclip them (44.5 % of the +3.5…+4 EV band remains, `--only W6`). Highlights -100 does
unclip them (0.5 % remain), because it lowers Y-driven t from 0 EV up.

**Ask.** Confirm whether this is the intended output-gamut behaviour (display gamut soft
clip after the outset, DisplayTransform.swift:403-410), or a per-channel shoulder artefact
of the same blend as N4. If it is the blend, the N4 fix covers it.

---

## Notices: what WS-05's SPEC line A1 changes for other lanes

### N8. The default white anchor moves from +5.0 to about +3.0 EV

**Request and verification.** This is WS-13's request, verified in WS-05 `SPEC.md` §A.
The proof decode puts sensor white at +2.47 EV, and Apple's decode at +2.66…+2.90 EV. Both
render at code 221-232 today, and no real frame at exposure 0 has a single 255 pixel (6929,
1569, 2348 and 1332 max out at luma 221-222). With the anchor at 3.0 they render at
243-254.

This needs no code change in another lane. It changes what other lanes measure against,
because they read the live anchor:

| owner | where | effect |
|---|---|---|
| WS-06 | `contrastMapped` | The highlight-side reach is `whiteAnchorEV - pivot`, so it shrinks from 5 to 3 EV at the default pivot. Contrast's shoulder starts earlier and its authority above mid-grey changes. Re-check the `tone.contrast` authorityFloor 55 (ControlProof). |
| colour grading | `GradeEngine` | The zone axis is built from the plan's anchors (RenderPlan.swift:202-204). The highlight crossfade moves down by 2 EV. `GradeStripAxisTests` pins agreement and will follow automatically. |
| WS-08 | `ToneEngine.normalizedAxis` / Zones panel | The normalized axis spans the anchors, so zone pivots map to different scene EVs above mid-grey. |
| `AutoTone` | `sceneEV(displayLuminance:)` | It inverts the transform between the anchors, so its statistics follow. |
| WS-13 | hard-coded anchors outside ToneEngine | `DisplayTransformParams.whiteAnchorEV = 5.0` (DisplayTransform.swift:67) and FilmLab's neutral transform (FilmLab.swift:1603-1606) do not go through `applyAnchors`. Decide whether Film Lab's neutral should follow the new default. |
| WS-08 | `Zones.defaultPivots` | It is derived from `defaultWhiteAnchorEV` (Recipe.swift:604-607), so the pivots keep their scene EVs, -4…+4. With the anchor at +3, though, the "Bright" pivot at +4 EV lies past display white. Re-place it (for example at +2.5 EV). |
| colour grading | `GradeEngine` defaults | The `whiteAnchorEV: Double = 5.0` defaults (GradeEngine.swift:98, 188, 369) only matter for callers that do not pass the plan's anchors. Check them. |
| integrator | committed records | The committed ControlProof records and any golden image with tones above mid-grey change. This is a global look change for the owner to sign off. |

---

## Added by the WS-05 builder

### N9. WS-07 (halos): what WS-05's reshaped Shadows and Whites cost at edges

Measured on the lane branch (default white anchor +5 EV, so every scene tone is where it
was at base; `ASHIFT=0`):

| control | HA1 `edges` probe (width px / peak codes) | HA3 real skylines (excess p90) |
|---|---|---|
| Highlights ±100 | 25 / 5.0 and 17 / 4.0 — identical to base (same shelf) | identical to base |
| Shadows −100 | 25 / 3.9 — identical to base (same shelf) | 1840 7.8 = base |
| **Shadows +100** | **33 / 5.5** against 29 / 5.3 | **1840 9.3** against 7.8 (1.19x; tolerance 1.15x) |
| Whites +100 | 14 / 3.0 against 34 / 7.6 (better) | 1840 3.0 against 36.9, 4213 3.0 against 27.0 (better) |
| **Whites −100** | **24 / 5.0** against 12 / 2.6 | 1840 5.7 against 6.1; **4213 5.4** against 3.2 |

- Whites −100 was mostly an anchor move at base, which acts per pixel in the display
  transform and cannot halo. SPEC H6 forbids that move (it re-hued blues by up to 14°),
  so −100 is now a gain and goes through the guided mask like every S7 control. Any −100
  that darkens a sky against its foreground by the amount W5 asks for (≥12 codes at
  C0 − 1 EV) has this edge cost with today's mask.
- Shadows +100 opens the quarter tones more than the old shelf near mid-grey (S2), so the
  gain step across a 0 / −1 EV edge is larger. Measured trade on the same frames: a lift
  peaking at −4.0 EV instead of −3.5 brings HA1 to 25 / 4.7 and HA3 1840 to 7.3, but
  1840's shadow lift falls to 17.1 (S6 floor 18.7); peaking at −3.75 keeps S6 (20.0) but
  lifts the black point (S1 10.6 > 8). WS-05 keeps S1 and S6.
- The fix that removes all of these is N2's (two-scale or base/detail mask).

---

## Added by the WS-05 builder for the white-anchor commit (`quality/ws-05-white-anchor`)

Everything below follows from `defaultWhiteAnchorEV` 5 → 3 alone; none of it is on the
lane branch `quality/ws-05-zonal-tone`. Each item is outside WS-05's functions. Two of
them leave a core test failing that WS-05 may not fix (BUILD-NOTES.md §7).

### N10. WS-09 (Auto Tone): the highlight-recovery threshold is an absolute +3.0 EV

**Where.** `AutoTone.suggest` fires recovery on `percentileEV(0.995) + exposure > 3.0`
(ToneEngine.swift, AutoTone section, `if hi > 3.0`). `AutoTone.SceneHistogram` censors its
reading at the transform's white anchor.

**Effect of A1.** With the default white anchor at +3 EV the censored reading cannot
exceed 3.0, so Auto never recovers a blown sky. `EngineTests.
testAutoRecoversABlownSkyThroughTheRealMeasurement` fails: the brightest half-percent
measures 2.929 EV (< 3.0) and Auto writes Highlights 0.

**Ask.** Make the threshold relative to the transform's white anchor (it was 2 stops
under the old +5 EV anchor; `whiteAnchorEV - 2` keeps that meaning, or the threshold
the Auto owner prefers). The test's invariant is right and should stay as it is.

### N11. WS-08 (Zones): `Zones.defaultPivots` puts Bright past display white

**Where.** `Zones.defaultPivots` (Recipe.swift:604-607) maps −4/−2/0/+2/+4 EV through
`ToneEngine.defaultWhiteAnchorEV`. With the anchor at +3 the Bright pivot is at
normalized 1.083, past the end of the axis (`normalizedAxis` saturates at 1).

**Effect.** `RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther` fails: Bright +1 EV
moves its own pivot by 0.50 stop instead of 1, and Light +1 EV moves the Bright pivot by
0.50. The default-recipe fixture (`Fixtures/default-recipe.json`, `zones.json`, via
`scripts/gen-fixtures.py`) and the full-tree digest in `RawDenoiseRecipeTests` were
regenerated by WS-05 to the new pivots, because they mirror the Swift defaults.

**Ask.** Re-place the Bright pivot inside the axis (for example +2.5 EV) or derive the
pivots so all five stay in [0, 1]. This is already flagged in N8; it now has a failing
test.

### N12. G4 sites that hard-code the old +5 EV white (no edit by WS-05)

| owner | site | does it need to follow? |
|---|---|---|
| WS-13 | `DisplayTransformParams.whiteAnchorEV = 5.0` (DisplayTransform.swift:67) | Only for callers that build a transform without `forRecipe`/`applyAnchors`. Every render path goes through `applyAnchors`, which now writes +3. Yes, for consistency. |
| WS-13 / Film Lab | `FilmLab` neutral transform (FilmLab.swift:1603-1606) is built from `DisplayTransformParams.neutral`, so it keeps +5 | Owner decides; it is a separate neutral, not the recipe's. |
| colour grading | `GradeEngine` `whiteAnchorEV: Double = 5.0` defaults (GradeEngine.swift:98, 100, 188, 369) | Callers that pass the plan's anchors are fine (RenderPlan does). Defaults should follow. |
| detail (vignette) | `DetailEngine.swift:821-822` and `RenderGraph.swift:1730`: `highlightThreshold = 0.18 * 2^5 / 2` "default scene white is mid-grey + 5 stops" | Yes: the highlight-protection threshold is now 1 stop above display white instead of 1 stop under it. CPU and GPU twins together. |
| WS-08 | `Zones.defaultPivots` | N11. |
| plan cache | `PlanTableCache.swift:13` comment says the anchors are `defaultWhiteAnchorEV − 1.5 · whites` | Comment only: Whites no longer moves an anchor. The key itself is correct (it keys the anchors). |
| WS-06 | `contrastMapped` comments (ToneEngine.swift, "Whites ≥ +67 pulls the white anchor below 4") | Comment only: Whites no longer moves the anchor. |

### N13. WS-06 (Contrast): the reach on the white side is now 3 EV

With the anchor at +3, Contrast +100's shoulder is flattest (slope 0.41) at +2.3 EV, where
Highlights' shelf is steepest. So the limiter now holds Highlights −100 back at Contrast
+100 (applied −67) instead of at Contrast −100 (it applied −94 there before, and is
unscaled now). WS-05 kept every `RobustnessTests` floor (single control vs Contrast
≥ 0.60: Shadows +100 0.615; four-way corner ≥ 0.62: 0.676) by shaping Shadows +100 and
Whites −100 around it. `tone.contrast`'s ProofRegistry floor (55) is in T3.

### N14. WS-07 (halos): what the anchor adds to N9

`--only HA1`, anchor branch against the lane branch (same slider shapes up to the
anchor-relative Whites retune):
- **Highlights ±100**: 29 / 6.9 and 25 / 5.0 against 25 / 5.0 and 17 / 4.0. Highlights'
  gain is identical on both branches (`smoothstep(0, 5, t)` x 2 EV, `highlightShelfEndEV`).
  The halo grew in codes only because the +3 EV anchor makes the display curve steeper
  where the edges' bright sides sit (+1.5 … +2.5 EV: 189 → 222 codes at +5, 202 → 245
  at +3).
- Shadows ±100 and Whites −100 are N9's (s+100 33 / 5.5 on both branches; w−100 24 / 4.0
  here, 24 / 5.0 on the lane branch); Whites +100 is 34 / 7.1 here against 14 / 3.0 on
  the lane branch, because its shelf sits in the steeper part of the +3 anchor's curve
  (base 34 / 7.6).

### N15. ControlProof (T3) on the anchor branch, by owner

`swift test -c release --filter ControlProofTests`: base 0 failures, lane branch 0, this
branch 8 (`/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/t3_anchor.log`). None is a floor of the four tone controls or Contrast
(`tone.highlights` 59.57 / 35, `tone.shadows` 47.97 / 30 — unchanged from the lane
branch, `tone.whites` 45.61 / 30, `tone.blacks` 23.27 / 15 unchanged, `tone.contrast`
64.93 / 55). The seven control failures:

| owner | control | measured | floor / declared |
|---|---|---|---|
| WS-06 | `tone.contrastPivot` dead at 2 of 20 steps | pivots above +3 EV clamp to the live anchor in `contrastMapped` | 0 dead |
| WS-18 | `sharpen.haloSuppression` dead at 5 of 20 steps | | 0 dead |
| WS-35 | `grade.blending` authority 17.3 | the grading axis is −9 … +3 now | 26 |
| WS-08 | `zones.bright.ev` 23.8, `zones.pivot.4` 25.3 | Bright pivot past the axis (N11) | 30, 31 |
| WS-33 | `primaries.bHue` hands back 18.1 | | 12.6 |
| WS-40 | `look.grain.size` hands back 18.9 | | 15.4 |

And `testTheCommittedRecordsStillDescribeWhatTheEngineDoes`: **127 committed records
move** (every control measured on a frame with tones above mid-grey). They are NOT
re-recorded here; that is the integrator's sign-off on the global look change (the test
prints every new record). By owner:

| owner | count | records |
|---|---|---|
| WS-04 | 1 | `tone.exposure` |
| WS-06 | 2 | `tone.contrast`, `tone.contrastPivot` |
| WS-05 | 2 | `tone.highlights`, `tone.whites` |
| WS-16 | 12 | `color.saturation`, `color.vibrance`, `color.density`, `color.protectSkin`, `bw.red`, `bw.orange`, `bw.yellow`, `bw.green`, `bw.aqua`, `bw.blue`, `bw.purple`, `bw.magenta` |
| WS-03 | 2 | `raw.temp`, `raw.tint` |
| WS-11 | 3 | `curve.darks`, `curve.lights`, `curve.highlights` |
| WS-14 | 2 | `detail.texture`, `detail.clarity` |
| WS-15 | 1 | `detail.dehaze` |
| WS-18 | 5 | `sharpen.amount`, `sharpen.radius`, `sharpen.detail`, `sharpen.masking`, `sharpen.haloSuppression` |
| WS-31 | 25 | `mixer.red.hue`, `mixer.red.sat`, `mixer.red.lum`, `mixer.orange.hue`, `mixer.orange.sat`, `mixer.orange.lum`, `mixer.yellow.hue`, `mixer.yellow.sat`, `mixer.yellow.lum`, `mixer.green.hue`, `mixer.green.sat`, `mixer.green.lum`, `mixer.aqua.hue`, `mixer.aqua.sat`, `mixer.aqua.lum`, `mixer.blue.hue`, `mixer.blue.sat`, `mixer.blue.lum`, `mixer.purple.hue`, `mixer.purple.sat`, `mixer.purple.lum`, `mixer.magenta.hue`, `mixer.magenta.sat`, `mixer.magenta.lum`, `mixer.uniformity` |
| WS-35 | 16 | `grade.global.sat`, `grade.global.lum`, `grade.global.hue`, `grade.shadows.sat`, `grade.shadows.lum`, `grade.shadows.hue`, `grade.mid.sat`, `grade.mid.lum`, `grade.mid.hue`, `grade.high.sat`, `grade.high.lum`, `grade.high.hue`, `grade.blending`, `grade.balance`, `grade.pivot.shadow`, `grade.pivot.highlight` |
| WS-37 | 4 | `printer.master`, `printer.r`, `printer.g`, `printer.b` |
| WS-33 | 8 | `primaries.rHue`, `primaries.rPurity`, `primaries.gHue`, `primaries.gPurity`, `primaries.bHue`, `primaries.bPurity`, `primaries.tintHue`, `primaries.tintPurity` |
| WS-08 | 10 | `zones.shadow.ev`, `zones.mid.ev`, `zones.light.ev`, `zones.bright.ev`, `zones.global.ev`, `zones.pivot.0`, `zones.pivot.1`, `zones.pivot.2`, `zones.pivot.3`, `zones.pivot.4` |
| WS-38 | 6 | `film.portra400.strength`, `film.gold200.strength`, `film.ektar100.strength`, `film.velvia50.strength`, `film.cine250d.strength`, `film.trix400.strength` |
| WS-19 | 6 | `denoise.luma`, `denoise.chroma`, `denoise.lumaDetail`, `denoise.lumaContrast`, `denoise.colorDetail`, `denoise.colorSmoothness` |
| WS-20 | 1 | `denoise.hotPixels` |
| WS-36 | 14 | `cb.hueShift`, `cb.vibrance`, `cb.chroma.global`, `cb.chroma.shadows`, `cb.chroma.mid`, `cb.chroma.high`, `cb.saturation.global`, `cb.saturation.shadows`, `cb.saturation.mid`, `cb.saturation.high`, `cb.brilliance.global`, `cb.brilliance.shadows`, `cb.brilliance.mid`, `cb.brilliance.high` |
| WS-41 | 1 | `look.vignette` |
| WS-40 | 3 | `look.grain.amount`, `look.grain.size`, `look.grain.roughness` |
| WS-13 | 3 | `render.contrast`, `render.skew`, `render.hue` |
