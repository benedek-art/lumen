# WS-05 verification (round 2)

Verifier: an independent agent. I judged from `SPEC.md`, `NEEDS.md` and the diff only. I took
my own measurements before I read `BUILD-NOTES.md`.

- Lane branch: `quality/ws-05-zonal-tone` @ `a015a5b`. Diff: `git diff 79cb6fd a015a5b`.
- Anchor branch: `quality/ws-05-white-anchor` @ `65a0303`, one commit on top of the lane branch.
- Scratch: `V=/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/verify`.
  - Lane renders: `$V/lane`. Anchor renders: `$V/wa`. Extra photos: `$V/x_lane` and `$V/x_base`.
  - Crops: `$V/crops`. Analysis scripts: `$V/py`. Stress harnesses: `$V/vh_{lane,base,wa}`.

## Verdict

**Lane branch: FAIL.** Four spec lines fail: A1, A2, S3 and HA1. HA3 also fails one cell
of its own. A verifier PASS is not possible under LANE-BRIEF §2.

I tried to break the code and could not:
- every gate passes;
- the identity at 0 holds;
- the response stays monotone under 5,625 slider combinations;
- the GPU path is safe;
- hue drift is gone;
- the remaining tests are honest.

The engineering is sound. Of the failures, only two halo cells are a real regression
caused by this lane, and both are trades I would accept with numbers (§3). The rest are:
- a spec conflict (A1/A2 sit on a second branch, and that branch fails other lines);
- a metric that measures something other than its name (S3 and one HA3 cell);
- a cause in WS-07.

So most of what is left is an integrator decision, not more builder work. §5 lists the
small items the builder should still fix.

**Anchor branch: A1/A2 confirmed. Its claimed cross-lane failures are exactly the ones
it lists in T2 and in the seven T3 control failures.** The one mismatch: T3's
committed-records check moves 132 records, not the 127 listed. The 5 missing are the
`pointColor.*` records (§7).

## 1. Gates

| gate | result | evidence |
|---|---|---|
| T1 `swift build --target LumenCore --target LumenRender` (6.1.2, `.build612`) | PASS. Clean except 4 pre-existing Sendable warnings in `Ingest/VerifiedCopy.swift`, a file outside the diff | `$V/t1_build.txt` |
| T2 `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` (6.1.2) | PASS: 3051/3051, exit 0 | `$V/t2_tests.txt` |
| T3 `swift test -c release --filter ControlProofTests` | PASS: 6 tests, 0 failures. Authority / floor: highlights 55.84/35, shadows 47.97/30, whites 35.34/30, blacks 23.27/15, contrast 68.38/55. All monotone, 0 dead steps, nothing given back | `$V/t3_proof.txt` |
| G1 no renderer file in the diff | PASS. The diff stat for LumenPipeline, ReferenceRenderer, RenderPlan and DisplayTransform is empty | |
| G2 `applyAnchors` writes only the two anchors | PASS, read in the diff | |
| G3 CPU/GPU pairing tests | PASS, inside T2 | |
| M3 identity | PASS. `Tone()` is identity, its anchors are exactly (5, −9), and max \|stops\| is 0 on −12…+8 EV. A value of ±1 on any single slider is not identity | `$V/vh_lane.txt` |

## 2. Spec lines, measured by me

Command: `ASHIFT=0 bash $S/render.sh $V/lane`, then `python3 $S/measure.py $V/lane`. That
gives 28/32 PASS (`$V/measure_lane.txt`). HA3 comes from `halo_real.py swx`, run on base
and on the lane.

| id | owner | measured (lane) | threshold | baseline | result |
|---|---|---|---|---|---|
| A1 | WS-05 | 221.0; 226.0 / 232.0; 14.0 | 238…250; ≥245 / ≤254.5; ≥8 | same | **FAIL** (the anchor is unchanged on this branch) |
| A2 | WS-05 | max luma 221.0–221.9, 0 % at 255 | ≥238, ≤0.5 % | same | **FAIL** (same reason) |
| S1 | WS-05 | 6929 7.6, 4213 7.2 | ≤8.0 | 29.4 / 29.2 | PASS |
| S2 | WS-05 | 20.5, 29.8 | ≥15.2, ≥23.9 | 17.9 / 28.1 | PASS |
| S3 | WS-05 (+WS-07) | 0.859, 0.974, 0.837, 1.081, 0.983 | ≥0.95 each | 0.768, 0.792, 0.765, 0.841, 0.788 | **FAIL** on 6929 and 1332 (better than base on every frame; see §3) |
| S4 | WS-05 | 1.168, 1.250 | ≥1.00 | 0.751 / 0.827 | PASS |
| S5 | WS-05 | z0 3.8 < 7.1; −6 EV code 2.0 | ≤6, <B; ≤4 | 11.5; 10 | PASS |
| S6 | WS-05 | −2 EV 70.0; 1840 19.6, 2348 20.8 | ≥63; ≥18.7, ≥17.4 | 67; 31.2; 28.9 | PASS (1840 has only 0.9 codes of margin) |
| W1 | WS-05 | 0.98 at +3 EV | ≤1.5 | 2.94 | PASS |
| W2 | WS-05 | clips at 4.0 EV (C0 5) | 3.5…4.5 | 2.5 | PASS |
| W3 | WS-05 | [1.0, 1.12, 1.23, 1.65] | min ≥0.5 | [1,1,0,0] | PASS |
| W4 | WS-05 | z6 0.0, z7 2.1 vs H 16.5 | | 6.3, 25.7 | PASS |
| W5 | WS-05 | +13.0; −13.0 | ≥10; ≥12 | +21; −19.1 | PASS (1 code of margin on each side) |
| W6 | WS-05 | 0.76 %; 0.0; 0.8 % | ≤1.15; 0; ≤45 | 1.12; 0; 44.5 | PASS |
| W7 | WS-05 | 6.5, 9.1, 0.4 % | ≤22/28/10 | 32.3, 40.7, 16.5 | PASS |
| H6 | WS-05 | worst 0.05° (B−100); W 0.00 at all four values | ≤0.5 | W 14.05° | PASS |
| H1 | WS-05 | 0.00; 0.00 | ≤0.5; ≤2 | 2.35; 7.92 | PASS |
| H2 | WS-05 | 0.0° | ≤2 | 7.7 | PASS |
| H3 | NR | 7.5, 8.4, 3.0, 2.0 | base +1 | 7.5, 8.4, 10.3, 28.8 | PASS |
| H4 | NR | 9.1, 3.4, 3.5, 1.6 | base +1 | 9.1, 3.4, 14.6, 9.7 | PASS |
| H5 | NR | sw H 0.2 W 0; swx H 1.7 W 0.9 | base +1 | W swx 19.5 | PASS |
| R1 | WS-05 | 7 EV; 235.0 | ≥7; ≤240 | same | PASS |
| R2 | WS-05 | 0.19; 0.00 % | ≤0.25; ≤0.05 | same | PASS |
| R3 | NR | identical to base | ≥ base −0.02 | | PASS |
| R4 | WS-05 | 13.4; 21.4 % | ≤13.5; ≤21.5 | same | PASS |
| B1 | WS-05 | 9.2, 13.8 %; 11.3, 12.5 | | same | PASS |
| Z1 / Z2 | WS-05 | ≤0.06 / 0.0 | ≤1.0 | | PASS |
| M1 / M2 | WS-05 | 0/0; 1.00 | 0/0; ≤1 | | PASS |
| HA1 | NR (WS-07) | s+100 **33/5.5** (base 29/5.3); w−100 **24/5.0** (base 12/2.6); w+100 14/3.0 (base 34/7.6); all others equal base | base +2 px / +0.5 code | | **FAIL**, two cells |
| HA2 | NR | 0 px | 0 | 0 | PASS |
| HA3 | NR (WS-07) | S+100 1840 **9.3** (base 7.8, 1.19×); W−100 1840 5.7 (6.1), 4213 **5.4** (3.2, 1.69×); W+100 3.0 / 3.0 (36.9 / 27.0); H and S−100 equal base | ≤1.15× base | | **FAIL**, two cells |

### Is measure.py measuring what each line claims?

I read `measure.py` and `halo_real.py` in full. Two lines measure something other than
their name says.

**S3 ("shadow local contrast / texture").** The metric is std(Y − 7×7 mean) over pixels
below code 50. It mixes two populations:
- **Interior** pixels, whose whole 7×7 window is below 50. This is texture.
- **Border** pixels, next to brighter tones. Their high-pass is the step to the neighbour.

Lifting shadows through an edge-aware mask reduces any such step by construction. A
global curve does too. My split, from `$V/py/s3dec.py`:

| frame | interior (base → lane) | border (base → lane) | border share of shadow px |
|---|---|---|---|
| 6929 | 1.14 → **1.77** | 0.76 → 0.82 | 67 % |
| 2545 | 1.45 → 2.39 | 0.78 → 0.92 | 70 % |
| 1332 | 1.37 → 1.92 | 0.75 → 0.79 | 30 % |
| 983 | 1.31 → 2.01 | 0.77 → 0.93 | 21 % |
| 1569 | 1.31 → 2.08 | 0.76 → 0.92 | 57 % |

Texture inside the shadows rises 1.5–2.4× on every frame. What fails is contrast across
shadow/midtone borders. It also improved on every frame, but stays under 0.95. No gain
curve through today's mask can keep that while also lifting the shadows (S2/S6). It
needs the base/detail split in NEEDS N3 (WS-07). The builder's statement on this is
correct.

**HA3, Shadows +100 on 1840.** The "sky" side of the detected edge holds thin dark
branches. I split the peak excess by the pixel it lands on (`$V/py/ha3dec.py`):

| case | peak on sky-bright pixels, p90 | peak on dark branch pixels, p90 |
|---|---|---|
| base | 0.0 | 10.4 |
| lane | **0.0** | 12.3 |

The Shadows ×8 delta map (`$V/crops/ha3_1840_sp100_delta.png`) shows the sky delta flat at
0 in both trees. So this cell measures the intended lift of silhouetted branches, not a
halo. That HA3 cell is a false FAIL.

The same split for Whites −100 shows a real sky-side increase:
- 4213: 2.2 → 4.8;
- 1840: 3.2 → 4.7.

## 3. The failing lines: caused here and avoidable, or not?

**A1/A2.** These are deliberately on the second branch. Neither branch passes the whole
spec on its own:
- the lane branch fails A1/A2;
- the anchor branch fails W4, W5(+), W6 and a worse HA1 (§6).

The builder's W4/W5 conflict at C0 = 3 is real. W5 needs +10 codes at C0 − 2 = +1 EV, and
W4 needs zone 6 (which contains the +1 EV patch) to move at most 3 codes. These are
opposite demands on the same tone. This is a spec decision for the integrator, not a
build defect.

**S3.** Not caused by this lane: it improved on every frame (worst 0.77 → 0.84). Not
avoidable in WS-05 (§2). The spec should split the line: interior ≥ 0.95, border ≥ base.

**HA1, Shadows +100: 33/5.5 against 29/5.3.** This is a real regression caused by the
lane's lift shape, but only the width breaks tolerance (+4 px over a 2 px allowance). The
peak, +0.2 codes, is within its +0.5 allowance. Per edge (`$V/py/edges_per.py`):
- the 0 / −1 EV edge worsened, 18 px / 3.0 → 33 px / 5.0;
- −3/−5 improved, 15 / 4.0 → 0;
- −1/−3 right side improved, 10 / 2.9 → 6 / 1.1;
- 2.5/−0.5 improved, 9 → 4.

The other side of the trade:
- the black point is held, p1 rise 29.4 → 7.6 codes;
- the shadows are no longer flattened (S4 0.75 → 1.17);
- texture is kept (above);
- zone 0 goes back to Blacks.

The builder's variant table shows that every lift which removes the edge cost breaks S1
or S6. I could not re-run those variants without editing source. The table is consistent
with the geometry: the bump's rising side is held at 0.64 stops per stop by the
RobustnessTests floor with Contrast −100.

On 100 % crops of 6929 and 4213 (`$V/crops/v1_*`), I see no halo at a visible scale. The
veil is gone. **I accept this trade.** The width tolerance needs integrator sign-off.

**HA1/HA3, Whites −100: 24/5.0 against 12/2.6; 4213 sky 5.4 against 3.2.** This is
caused by this lane, and it is a real halo. At base, Whites −100 was mostly a white-anchor
move, applied per pixel, so it could not halo. H6 forbids that move, because it re-hued
blues by 14°. As a gain, it has to go through the guided mask.

The amount comes from the "hold" shelf at +1.2…+3.2 EV, which pulls the +2.5 EV
plateaus. The hold is what delivers W5 (−13 against a floor of 12, so 1 code of margin).
Raising it toward the anchor collides with Contrast +100's flat shoulder under the
RobustnessTests floor. So inside WS-05 there is no room to cut it materially.

What a photographer gets for it:
- added hue drift 14.05° → 0.00° (H6);
- hue-wheel drift at +2 EV 10.3° → 3.0° (H3);
- sky-probe drift 14.6° → 3.5° (H4).

What it costs: about 2.5 more codes of rim on bright skies against darker ground. On
`$V/crops/ha3_4213_stretch.png` (4213 at exposure +1.5, Whites −100, sky stretched to the
full range, 200 %), I see no visible glow above the treeline. Whites +100's halo also
fell sharply (34/7.6 → 14/3.0, and 36.9 → 3.0 on 1840). **I accept this trade. The fix
belongs to WS-07 (NEEDS N2/N9).**

## 4. What I tried to break, and what happened

**Combinations and monotonicity.** I ran an exact-path harness (`$V/vh_*`) over:
- H, S, W, B at −100, −50, 0, 50, 100;
- Contrast at −100, 0, 100;
- pivot at −2, 0, 2.

That is 5,625 combinations, run on lane, base and anchor branch:

| | base | lane | anchor branch |
|---|---|---|---|
| requested curve inversions (0.01 EV grid) | 75, worst 9.6e-6 EV | 50, worst 3.8e-5 EV | 75, worst 1.8e-4 EV |
| forward clamp fired in the bake | 0 | **0** | **25** (≤4 flat samples, C+100 pivot 2, all four at ±100) |
| a single slider eased at Contrast 0 | never | never | never |
| worst-corner limiter scale | 0.349 | 0.315 | 0.407 |
| mid-grey moved, Contrast 0 | 0 | 0 | 0 |
| slider-value inversions (v → v+5, any t) | 114 (Blacks under Contrast +100) | 57, same place | 57 |

Reading the table:
- On the lane, nothing is worse than base except a slightly lower worst-corner scale and
  sub-1e-4 EV secant noise.
- `secantMargin` (1e-3) changes every binding limit by 0.1 %, which is invisible.
- The Blacks + Contrast slider-value inversions already exist at base, and the lane
  halves them.

**Extremes on renders.** On the 3582 frame (Nikon Z6, not used by the builder), I swept:
- Shadows at Contrast −100;
- Shadows at Contrast +100 with Blacks −100;
- Whites at Highlights −100 with Contrast +100;
- Whites at Exposure +3;
- Whites at Exposure −3 with H/S/B +100 and Contrast −100;
- Shadows at Exposure +3 with H/W/B −100 and Contrast +100.

Per-pixel slider monotonicity: ≤0.012 % of pixels drop by more than 1.5 codes from one
value to the next (base 0.002–0.047 %). There is no new clipping, except where expected:
Whites +100 at Exposure +3 clips 13 % against base 48.7 %.

**Other photos.** These five were not used by the builder or the spec: 1192 X-T10,
3582 Z6, 4144 A7C, 7881 R5 II, 6933 A7 IV.

| frame | Shadows +100 p1 rise, base → lane | shadow mean rise, base → lane |
|---|---|---|
| 3582 | 19.2 → 0.4 | 30.8 → 26.1 |
| 4144 | 23.2 → 0.4 | 29.7 → 24.2 |
| 6933 | 29.2 → 6.7 | 27.1 → 27.1 |
| 1192 | | 29.5 → 22.8 |
| **7881** | | **27.3 → 14.3 (0.52×)** |

7881 is a very dark still life: p25 is at code 9 and p50 at 18. Shadows +100 now barely
opens the cloth (`$V/crops/x_7881_shadows.png`), because the taper is fixed in scene EV
(−3.15…−4.15). This is below the 0.6× authority intent S6 sets for the dark frames. It is
not a spec line, but it is a real usability cost on under-exposed frames. Lightroom's
Shadows adapts to the image. Recorded as item 3 in §5.

**Neighbouring controls.**
- Contrast: the pivot tests were rewritten with the same anchors through
  `baseWhiteAnchorEV` and still pass. The limiter behaviour is covered above.
- Zones panel: unchanged, and `zonePanelStops` is untouched.
- Grading axis: `GradeEngine` reads `ToneEngine.anchors(for:)`, so Whites no longer
  shifts the grade axis. This is consistent with the render (GradeStripAxisTests).
- Masks: the local `ToneEngine` gets `baseWhiteAnchorEV` = the global anchor, which is
  always 5 on this branch. CPU and GPU (`LocalPlan.preLUT` → `tone.gain(at:)`) both
  evaluate the same `ToneEngine`.
- **Latent defect.** `whiteWeight` and `whiteRecoveryStops` lost their `hi > 0` guard and
  now start at `anchor − 3.8 EV`. With a base anchor below 3.8 EV, Whites reaches across
  mid-grey: at a base anchor of 3.0, Whites +100 is 0.19 stops and Whites −100 is
  −0.32 stops at 0 EV. The upper limiter sweep starts at 0, so it does not see that part.
  This is unreachable on the lane branch, because nothing lowers the global anchor any
  more. On the anchor branch the start moves to anchor − 2.4, so it is also safe there.
  It is a trap for any later anchor change (item 1 in §5).

**GPU.** No new per-pixel term exists outside `stops(at:)`. `bakeGainLUTAndFloor` →
`toneGainLUT` / `toneGainCubeBaked` is the only route on both paths, and
`applyAnchors` → `finishLUT` the only other. The new windows are pure functions of `t`
and of the anchors in `Tone`. Nothing is CPU-only.

**Visual checks, at 100 %, before against after.**

| claim | result | what I saw |
|---|---|---|
| V1 Shadows | PASS | `$V/crops/v1_6929_gate.png`, `v1_6929_foliage.png`, `v1_4213_treeline.png`. At +100 the leaf gaps, the area behind the car and the trunk bases stay near-black. The quarter tones open as much as before. The grey veil in the base +100 is gone. Gate slats and leaves are as crisp as at 0. |
| V2 Whites | PASS | `$V/crops/v2_top_steps.png`. The steps brighten evenly. +100 whitens only from +4 EV, the +1/+2 EV steps barely move, and −100 recovers the top steps. |
| V3 hue | PASS | `$V/crops/v3_wheel_sw.png` and `v3_wheel_swx.png`. At exposure 0, Whites ±100 is indistinguishable from 0 in the blue–violet sector (base +100 pushed it violet). At +2 EV, lane +100 is not more violet or pink: base +100 washed the wheel out to pastel, the lane does not. |
| V4 | FAIL on the lane branch, by design | On the anchor branch, PASS (`$V/crops/v4_wa.png`): the 6929 wall, the 2348 shelf whites and the 1569 sky read white, with mids and shadows unchanged. |

**T4: every modified existing test.**

| test | change | verdict |
|---|---|---|
| EngineTests `testWhitesAndBlacksMoveBothTheAnchorsAndTheCurve` | asserts white anchor equal, plus two new clip-point-by-gain assertions | same invariant, now through gain. The name is stale. |
| `testWhitesBrightensThroughTheTransform` | adds params-equal | same invariant, stronger |
| `testTheEndShelvesOverlapTheZonalOnesAsTheCommentSays` | new numbers for the new shelf | kept |
| `testAPivotPastTheWhiteAnchorStillCannotPushAPixelPastIt` / ColourAccuracyTests | same anchors (4.0/3.8/3.5) via `baseWhiteAnchorEV` | same invariant. It now covers the mask route rather than a slider route, because the slider route no longer exists. |
| AccuracyProbeTests | Shadows +100 peak = `shadowLiftRangeEV` (1.5) | invariant kept ("constant is the delivered peak"). Adds two new assertions (S−100, W−100). |
| FieldBaselineProbeTests | max-in-window went from `== 2.0 ± 0.05` to `(1.35, 1.5]` | **slightly loosened**, with a stated reason: the taper means the best patch reads under the peak. `shadowPeak.shift == 1.5 ± 0.05` is still exact. Acceptable. |
| MaskingTests | bar went from > 1.0 to > 0.9 × 1.2 = 1.08 | stricter |
| GradeStripAxisTests (2) | driven by Blacks, plus "Whites leaves the axis at 14" | same invariant, stronger |
| PlanTableCacheTests, PlanCostProbeTests | Whites → Blacks as the anchor-moving control | same contract. The `tone.whites` row is gone from the finish-key list, which is correct, since Whites no longer keys that table. |
| Proof records shadows/whites | re-recorded | consistent with T3: authority 47.97 and 35.34, above floors 30/30 |
| `enginemath.json`, `gen-fixtures.py` | the mirror follows | fine. Comment bug (item 2 in §5). |

No test was skipped or disabled.

## 5. Items for the builder

These are small. Nothing here needs a redesign.

1. **Guard the Whites windows against low anchors.** Clamp the start of `whiteWeight`
   and `whiteRecoveryStops` at ≥ 0 EV, or restore a guard. Add a test that
   `ToneEngine(tone: Tone(whites: ±100), baseWhiteAnchorEV: a).stops(at: 0) == 0` for
   a ∈ {2.5, 3, 3.5, 5}. Today a base anchor below 3.8 makes Whites move mid-grey, out of
   the limiter's view.
2. **Fix the stale comment** in `scripts/gen-fixtures.py` on the lane branch. It says
   "one shelf from 2.4 to 0.4 EV" next to constants 3.8 / 0.6.
3. **Dark-frame authority.** Report Shadows +100 on under-exposed frames, with a number
   in REPORT.md. On 7881 the shadow lift is 0.52× base. Either show that the S6 floor
   holds on the corpus's darkest frames, or say plainly that Shadows +100 on a low-key
   frame now needs Exposure first.
4. Anchor branch: add the 5 `pointColor.*` moved records to NEEDS N15, with their
   owner.
5. Optional: rename `testWhitesAndBlacksMoveBothTheAnchorsAndTheCurve`, since Whites no
   longer moves an anchor.

## 6. For the integrator: decisions only you can make

- **A1/A2 against W4/W5/W6.** Choose the anchor branch and amend W4/W5/W6 for C0 = 3, or
  ship the lane branch and leave A1/A2 open.
- **S3.** Amend the metric: interior ≥ 0.95, border ≥ base. As written it cannot pass
  without WS-07 N3.
- **HA3.** Restrict `halo_real.py` to sky-bright pixels. The Shadows +100 / 1840 cell is
  a false FAIL (§2).
- **HA1 waivers, pending WS-07 N2.** Shadows +100: width +4 px at the 0/−1 EV edge.
  Whites −100: 2.6 → 5.0 codes. Both trades are justified in §3.

## 7. Anchor branch (`65a0303`), judged separately

Renders are `$V/wa` (`ASHIFT=-2`); the printout is `$V/measure_wa.txt`, 27/32 PASS.

- **A1 PASS**: 242.0; 247.0 / 253.0; gap 17.0.
- **A2 PASS**: max luma 242.0 / 243.1 / 242.6 / 242.0, 0 % at 255.
  Both match the builder's numbers exactly.
- **Its own failures**:
  - S3 (0.860 / 0.837);
  - W4 (z6 4.7);
  - W5 (+6.0 against ≥10);
  - W6 (NaN: the +3.5…+4 EV band is empty, so the line cannot be evaluated on this tree);
  - HA1. Here Highlights halos are also worse, at 29/6.9 and 25/5.0 against 25/5.0 and
    17/4.0, which the lane branch does not have.
  - My stress harness also shows a new effect: the forward clamp fires in 25 extreme
    corners (Contrast +100, pivot 2), with ≤4 flat bake samples. Base and lane have 0.
- **T2** (6.1.2, extracted tree): exactly the two claimed cross-lane failures, and no
  others (`$V/wa_t2.txt`):
  - `EngineTests.testAutoRecoversABlownSkyThroughTheRealMeasurement` (WS-09, reads 2.929
    against > 3.0);
  - `RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther` (WS-08, Bright pivot moves
    0.5).
- **T3** (release, `$V/wa_t3.txt`): 6 tests, 8 failures.
  - The seven control failures are exactly the seven in NEEDS N15: `tone.contrastPivot`
    dead 2/20, `sharpen.haloSuppression` dead 5/20, `grade.blending` 17.3, `zones.bright.ev`
    23.8, `zones.pivot.4` 25.3, `primaries.bHue` 18.1, `look.grain.size` 18.9. None is a
    floor of the four tone controls or Contrast.
  - **The record list is incomplete.** `testTheCommittedRecordsStillDescribeWhatTheEngineDoes`
    reports **132** moved records, not the 127 claimed. All 127 listed are present. The 5
    not listed are `pointColor.hue`, `pointColor.luminance`, `pointColor.range`,
    `pointColor.saturation` and `pointColor.variance`, and their owning lane is not named.
    They do not move on the lane branch or on base, where T3 has 0 failures. The builder
    should add them to N15 with their owner.

So the anchor branch's claims hold for A1/A2 and for every test failure it names, except
those 5 unlisted records. Integrating it still needs the W4/W5/W6 spec amendment, an
HA1 decision for Highlights, and the integrator's sign-off on the global look change.
