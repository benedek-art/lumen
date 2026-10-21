# WS-05 verification, round 3 (final)

Verifier: an independent agent. I judged from `SPEC.md`, the round-2 `VERIFY.md` and the
diffs. I took every lane measurement before I read `BUILD-NOTES.md`.

- Lane branch: `quality/ws-05-zonal-tone` @ `43d5f2d`. Round-3 diff `git diff a015a5b 43d5f2d`,
  whole lane `git diff 79cb6fd 43d5f2d`.
- Anchor branch: `quality/ws-05-white-anchor` @ `04cc6cc` (= `dd0e274` "+5 → +3 EV" plus the
  round-3 `sweepStep` commit), on top of `43d5f2d`.
- Scratch: `V=/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/verify3`.
  - Renders: `$V/lane`, `$V/anchor` (spec set) and `$V/dark/{base,lane,v36,v38,v36w,vs1,vs2,vs3}` (dark frames).
  - Printouts: `$V/measure_lane.txt`, `$V/measure_anchor.txt`, `$V/ha3_lane.txt`, `$V/dark_table*.txt`.
  - Gate logs: `$V/t1_lane.txt`, `$V/t2_lane.txt`, `$V/t3_lane.txt`, `$V/t1_anchor.txt`,
    `$V/t2_anchor.txt`, `$V/t3_anchor.txt`.
  - Stress harnesses: `$V/vh_{lane,anchor,dd0,base}`, results in `$V/vh_*.txt`.
  - Scratch trees: `$V/src_*`. These are `git archive` extracts; the repo was not touched
    except for this file.

## Verdict

**Lane branch: FAIL. This is round 3, so per LANE-BRIEF §1 the remaining lines are
BLOCKED, not sent back.**

All five round-2 builder items are resolved, and I checked each one by test (§1). The
round-3 change is inert at the factory anchor: all 492 spec tiles are byte-identical to
round 2. The lane still measures 28/32. A1, A2, S3 and HA1 fail as spec lines, and HA3
fails two cells. None of these is a defect WS-05 can fix on its own. Each needs a spec
decision, the integrator, or WS-07 (§4).

**Anchor branch: its round-3 claims hold.**
- `sweepStep` removes every forward-clamp hit on its anchor (175 → 0 over 13,125 settings).
- Nothing moves at the default pivot: it is bit-identical there.
- T2 fails on exactly the 2 named foreign tests.
- T3 has exactly 8 failures, and its 132 moved records match NEEDS N15 one for one.

The branch still measures 27/32 (W4, W5, W6, S3 and HA1 fail). So it cannot pass the spec
as written either, and integrating it is the integrator's call (§6).

## 1. Round-2 items

| # | item | claim | what I did | result |
|---|---|---|---|---|
| 1 | Whites reached mid-grey on low anchors | `upperShelf` clamps every Whites window to start ≥ 0 EV and width ≥ 0.5 EV | Read the diff (`whiteWeight` and both `whiteRecoveryStops` shelves). Ran a harness through the mask constructor `ToneEngine(tone:baseWhiteAnchorEV:)`, which is what both `ReferenceRenderer.swift:357` and `RenderGraph.swift:2326` call. Grid: anchors 1.0…6.0 in steps of 0.25 × Contrast −100/−50/0/50/100 × pivot −2/0/1/2/3/4 × H ±100/±50/0 × W ±100/±50/0 × S 0/100. For each setting, `stops(t)` with Whites was compared to the same engine with Whites 0, for all t ≤ 0 | **0 differences** over 31,500 settings × 201 samples. Whites ±100 at t = 0 is 0.0000 on anchors 1…6, against 0.19 / −0.32 at +3 in round 2. Slider-value monotonicity of Whites holds on every anchor (0 violations). |
| 1b | No pixel changes at the default anchor | "neither clamp is active at +5" | Arithmetic: at +5 the windows are 1.2…4.4, 1.2…3.2 and 3.8…6.6, so both `max`es are no-ops and the `smoothstep` arguments are bit-identical. Rendered the full spec set and compared it with round 2's `a015a5b` renders | **492 / 492 tiles byte-identical** (`$V/cmp.py`). The 5,625-setting grid is unchanged from round 2 (50 inversions, worst 3.8e-5 EV; 0 clamp hits). |
| 2 | Stale comment in `gen-fixtures.py` | fixed | Read it: now "3.8 to 0.6 EV", hold "3.8 to 1.8", recovery "1.2 under to 1.6 over", next to constants 3.8 / 0.6 / 1.8 / 1.2 / 1.6. `upper_shelf` mirrors the Swift exactly | PASS |
| 3 | Dark-frame authority (7881) | table in BUILD-NOTES §8, and a comment in ToneEngine | Measured myself (§3) | Numbers reproduced. Argument holds (§3). |
| 4 | Anchor branch: 5 `pointColor.*` records | added to N15 under WS-32 | My T3 on `04cc6cc` (§6) | PASS: 132 = 132 |
| 5 | Rename the test | `testWhitesMovesTheClipPointByGainAndBlacksMovesItsAnchor` | Read the diff. It runs and passes in T2 | PASS. The doc comment above it still says "The anchor move is kept" (a cosmetic leftover). |

New test `ZonalToneTests.testWhitesNeverReachesMidGreyAtAnyWhiteAnchor`: it asserts exact 0
at t ∈ {−3, −1, −0.01, 0} and `stops(at: 0) == 0`. It is a fair guard. My harness covers a
denser grid.

### What I found in the new code (latent, unreachable on either branch)

- **The `minimumUpperShelfWidthEV` comment understates its reach.** It says the 0.5 EV
  floor "can only happen on an anchor under +1.1 EV". That is true for the +100 shelf. But
  the −100 hold shelf (`a − 3.8 … a − 1.8`) hits the floor for every anchor below +2.3 EV,
  where its slope is 1.5 × 0.9 / 0.5 = 2.7 stops per stop. Between +2.3 and +3.8 the shelf
  is narrower than at +5.
- The effect, with the lane's constants: a lone Whites −100 at Contrast 0 is eased.
  - Applied scale: 0.84 at +3, 0.52 at +2.5, 0.35 at +1.
  - This breaks the file's own claim that "a single Whites −100 is never scaled at
    Contrast 0" on those anchors.
  - It leaves secant inversions of up to 6e-4 EV, which the forward clamp catches (≤5 flat
    samples).
- **Reachability.** It is unreachable on both branches:
  - the global anchor is a constant (+5 on the lane, +3 on the anchor branch);
  - Whites no longer moves it;
  - masks inherit the global anchor.
- On the anchor branch's retuned constants, +3 is clean (scale 1.0, 0 inversions). Base
  is far worse at low anchors (inversions up to 2.5e-2 EV at +1).
- **Disposition: note only.** A comment fix for whoever lowers the anchor next.

## 2. Gates

| gate | result | evidence |
|---|---|---|
| T1 (6.1.2, `.build612`) | PASS. Clean apart from the 4 pre-existing Sendable warnings in `Ingest/VerifiedCopy.swift`, which is outside the diff | `$V/t1_lane.txt` |
| T2 (6.1.2) | PASS: **3052 tests, 0 failures**, exit 0. That is 3051 in round 2 plus the new guard test | `$V/t2_lane.txt` |
| T3 (release, `.build612r`) | PASS: 6 tests, 0 failures. Authority / floor: highlights 55.84 / 35, shadows 47.97 / 30, whites 35.34 / 30, blacks 23.27 / 15, contrast 68.38 / 55. All monotone, 0 dead, 0 given back. No committed record moves | `$V/t3_lane.txt` |
| G1 | PASS. `git diff --stat 84bcd7c 43d5f2d` (= merge-base with `claude/inspiring-dirac-ulgpch`) on LumenPipeline, ReferenceRenderer, RenderPlan and DisplayTransform is empty. Under `Sources/`, only `ToneEngine.swift` and `BasicPanel.swift` change. Same on the anchor branch | |
| G1b (no per-pixel term outside the baked LUT / anchors) | PASS. `upperShelf` and `sweepStep` are pure functions of `t`, `Tone` and the anchors. They are reached only via `stops(at:)` → `bakeGainLUTAndFloor` (CPU `toneGainLUT`, GPU `toneGainCubeBaked`) and via the limiter solve. `applyAnchors` is untouched | read |
| G2 / G3 / M3 | PASS. `applyAnchors` is unchanged; the pairing tests are inside T2; identity holds (harness: `isIdentity` true, anchors (5, −9), max \|stops\| 0) | |

## 3. The dark-frame trade

Shadows 0 → +100 at exposure 0. "Mean" is the luma rise of the pixels below code 50 at
Shadows 0. The ratio is against base `84bcd7c`, which I built myself. The p1 is S1's
metric. Source: `$V/dark_table.txt` and `$V/dark_table2.txt`.

| tree (taper start…end, depth 0.95) | 7881 mean (ratio) | 2062 | 1840 (S6 ≥ 18.7) | 2348 (S6 ≥ 17.4) | 6929 p1 (S1 ≤ 8) | 4213 p1 | S4 6929 / 4213 |
|---|---|---|---|---|---|---|---|
| base | 27.3 (1.00) | 27.4 (1.00) | 31.2 | 28.9 | 29.4 | 29.2 | 0.751 / 0.827 |
| **lane −3.15…−4.15** | **14.3 (0.52)** | 26.6 (0.97) | 19.6 (0.63) | 20.8 (0.72) | **7.6** | **7.2** | 1.168 / 1.250 |
| −3.6…−4.15 | 16.7 (0.61) | 27.0 | 23.4 | 23.0 | 18.9 | 18.1 | 1.078 / 1.121 |
| −3.8…−4.15 | 17.5 (0.64) | 27.1 | 24.5 | 23.8 | 21.1 | 21.1 | 1.054 / 1.091 |
| −3.6…−4.6 (builder's row) | 18.0 (0.66) | 27.2 | 24.7 | 24.0 | 20.4 | 20.1 | 1.040 / 1.091 |
| sharper: −3.45…−3.85 | 14.8 (0.54) | 26.7 | 20.5 | 21.1 | 5.6 | 4.9 | 1.136 / 1.221 |
| sharper: −3.35…−3.95 | 14.6 (0.54) | 26.7 | 20.2 | 21.0 | 6.8 | 6.1 | 1.141 / 1.228 |
| sharper: −3.55…−3.80 | 15.2 (0.56) | 26.8 | 21.0 | 21.4 | 6.1 | 4.2 | 1.126 / 1.203 |

**The builder's table is reproduced.** On the lane, 7881 measures 0.52×, 2062 0.97× and
1840 0.63×. The −3.6…−4.6 row gives 0.66× and a 6929 p1 rise of 20.4. S1, S4 and S6 match
`measure.py`.

**Where the tones sit in scene EV** (`$V/evmap.py`, luma mapped through the value-0 grey
ramp):
- 7881's shadow pixels (77 % of the frame) are at p10 / p50 / p90 = −5.5 / −3.6 / −2.1 EV.
  34 % of them sit in [−4.5, −3.5).
- The 1st percentile of 6929 and of 4213 is at −3.90 EV, inside that band.

**Does the argument hold?** "A 1-D EV curve can't open 7881's cloth at −3.5…−4.5 EV and
also hold the p1 of 6929/4213 at the same EV." **Yes, it holds.**
- I tested the family the builder did not: sharper tapers, which the rising side's
  monotonicity does not constrain.
  - With S1 held, the best 7881 reaches is **0.56×**.
  - Every shape that reaches the 0.6× intent puts 6929's p1 at about +19 codes, against a
    limit of 8.
- One caveat on the builder's wording.
  - BUILD-NOTES says "nothing beats the shipped shape on S1".
  - That is false for the sharper family: −3.55…−3.80 is better than the shipped shape on
    S1 (6.1 / 4.2), S6 (21.0 / 21.4) and 7881 (0.56).
  - It does not change the conclusion.
  - I would not adopt it either. It expands the band it crosses at about 8.6 stops per
    stop. On 7881 it draws a visible darker crescent on the cloth at lower right
    (`$V/crops/x7881_full.png`, 4th panel).
- **Visually** (`$V/crops/x7881_full.png`: 0, base +100, lane +100, vs3 +100):
  - the lane still opens the cloth and the weave reads;
  - base opens it further, under the grey veil the lane removed.
- I accept the trade. A lift that adapts to the frame would need image statistics in the
  tone curve, which is outside WS-05's functions. The ToneEngine comment now states the
  cost and says "Exposure first".

## 4. Per-line table, lane `43d5f2d`

`ASHIFT=0 BIN=… bash $S/render.sh $V/lane`, then `python3 $S/measure.py $V/lane`: 28/32.
H6 was re-run after rebuilding `$S/anchorh` against the lane. The `AH` binary in place
before that was linked to another tree and printed 0.11 for B−100. HA3 comes from
`halo_real.py swx` on `$V/lane`.

| id | measured | threshold | result | if failing |
|---|---|---|---|---|
| A1 | 221.0; 226.0 / 232.0; gap 14.0 | 238…250; ≥245 / ≤254.5; ≥8 | **FAIL** | BLOCKED |
| A2 | max luma 221.0 / 221.6 / 221.9 / 221.3, 0 % at 255 | ≥238, ≤0.5 % | **FAIL** | BLOCKED |
| S1 | 7.6 / 7.2 | ≤8.0 | PASS | |
| S2 | 20.5 / 29.8 | ≥15.2 / ≥23.9 | PASS | |
| S3 | 0.859, 0.974, 0.837, 1.081, 0.983 | ≥0.95 each | **FAIL** (6929, 1332) | BLOCKED |
| S4 | 1.168 / 1.250 | ≥1.00 | PASS | |
| S5 | z0 3.8 < 7.1; code at −6 EV 2.0 | ≤6, <B; ≤4 | PASS | |
| S6 | 70.0; 19.6 / 20.8 | ≥63; ≥18.7 / ≥17.4 | PASS | |
| W1 | 0.98 | ≤1.5 | PASS | |
| W2 | 4.0 EV (C0 = 5) | 3.5…4.5 | PASS | |
| W3 | [1.0, 1.12, 1.23, 1.65] | min ≥0.5 | PASS | |
| W4 | z6 0.0, z7 2.1 vs H 16.5 | ≤3.0; ≤H, ≤16.5 | PASS | |
| W5 | +13.0; −13.0 | ≥10; ≥12 | PASS | |
| W6 | 0.76 %; 0.0 %; 0.8 % | ≤1.15; 0; ≤45 | PASS | |
| W7 | 6.5 / 9.1 / 0.4 % | ≤22 / 28 / 10 | PASS | |
| H1 | 0.00; p99 0.00 | ≤0.5; ≤2.0 | PASS | |
| H2 | 0.0° | ≤2.0 | PASS | |
| H3 | 7.5, 8.4, 3.0, 2.0 | base +1 | PASS | |
| H4 | 9.1, 3.4, 3.5, 1.6 | base +1 | PASS | |
| H5 | sw H 0.2 W 0; swx H 1.7 W 0.9 | base +1 | PASS | |
| H6 | worst 0.05° (B−100); W 0.00 at ±50 and ±100 | ≤0.5 | PASS | |
| R1 | 7 EV; 235.0 | ≥7; ≤240 | PASS | |
| R2 | 0.19 / 0.00 % | ≤0.25 / ≤0.05 | PASS | |
| R3 | 0.672, 0.884, 0.775, 0.887 | ≥ base −0.02 | PASS | |
| R4 | 13.4 / 21.4 % | ≤13.5 / ≤21.5 | PASS | |
| B1 | 9.2 / 13.8 %; 11.3 / 12.5 | ≥8 / 12; ≥9.5 / 10.5 | PASS | |
| Z1 | H 0.06, W 0.00, S 0.00, B 0.01 | ≤1.0 | PASS | |
| Z2 | 0.0 all | ≤1.0 | PASS | |
| M1 | 0 / 0 | 0 / 0 | PASS | |
| M2 | 1.00 | ≤1.0 | PASS | |
| HA1 | s+100 **33 / 5.5** (base 29 / 5.3); w−100 **24 / 5.0** (base 12 / 2.6); w+100 14 / 3.0 (base 34 / 7.6); the other five equal base | base +2 px / +0.5 | **FAIL**, 2 cells | BLOCKED |
| HA2 | 0 px | 0 | PASS | |
| HA3 | S+100 1840 **9.3** (base 7.8, limit 8.97); W−100 4213 **5.4** (base 3.2, limit 3.68); W−100 1840 5.7 (6.1); W+100 3.0 / 3.0 (36.9 / 27.0); H±100 equal base | ≤1.15 × base | **FAIL**, 2 cells | BLOCKED |

Every number above equals round 2's. The pixels are identical, so §2-§3 of `VERIFY.md`
(the S3 interior/border split, the HA3 decomposition, the 100 % visual claims V1-V3)
carry over unchanged.

### Classification of the failing lines

- **A1 / A2: BLOCKED (spec decision and integrator sign-off).**
  - The fix exists. It is the anchor branch, and there A1/A2 pass (242.0; 247.0 / 253.0;
    max luma 242-243.1).
  - Merging it is not a WS-05 builder action:
    - the anchor branch fails W4 / W5 / W6. The C0 = 3 conflict between W4 and W5 is
      geometric: VERIFY §3 shows both lines make demands on the same +1 EV patch;
    - it fails two core tests owned by WS-09 and WS-08;
    - it moves 132 committed records across 22 owners.
  - The spec must amend W4/W5/W6 for C0 = 3, and the integrator must sign off on the
    global look change.
- **S3: BLOCKED (spec metric, or WS-07 N3).**
  - Texture inside the shadows rises 1.5-2.4× on every frame. What stays under 0.95 is
    contrast across shadow/midtone borders.
  - Any lift through today's edge-aware mask reduces that border contrast by
    construction.
  - It improved on every frame (worst 0.77 → 0.84).
  - To resolve it: split the metric (interior ≥ 0.95, border ≥ base), or deliver WS-07's
    base/detail split.
- **HA1: BLOCKED (integrator waiver; the root cause is WS-07 N2/N9).** The two cells are
  the halo cost of trades round 2 accepted with numbers:
  - **Shadows +100.** The width rises by 4 px at the 0/−1 EV edge. That buys the black
    point (S1), the spread (S4) and zone 0 for Blacks.
  - **Whites −100.** The peak rises from 2.6 to 5.0 codes. Whites −100 used to move the
    display anchor and must now act through the guided mask, because H6 forbids the
    anchor move (14° of added hue).
  - Inside WS-05, the only levers trade straight back into S1 / S6 / W5 / H6, and the
    builder's variants show this.
- **HA3: BLOCKED.**
  - The S+100 / 1840 cell is a metric artefact: the excess sits on dark branch pixels, and
    the sky side is 0.0 in both trees. That needs a spec decision: restrict the metric to
    sky-bright pixels.
  - The W−100 / 4213 cell is the same real halo as HA1's Whites −100 cell. The fix
    belongs to WS-07 (N2/N9). The integrator decides on a waiver.

**There is no DEFECT among them.** No failing line can be fixed inside WS-05's functions
without failing a line that passes now.

## 5. Trying to break the lane

- **Grid at the factory anchor, with pivots extended to +1, +2.5, +3 and +4**
  (13,125 settings: H, S, W, B at −100…100 × Contrast −100/0/100 × 7 pivots).
  - New finding: on the lane, **the forward clamp fires in 25 settings**, all of them
    Contrast −100, pivot +1, H−100, W−100 (with any S and B). Each flattens ≤3 of 1,024
    bake samples, and the requested drop is ≤4e-6 EV.
  - Base fires 0 times on the same grid. Round 2's grid used pivots 0 and ±2 only, so it
    missed this.
  - It is invisible (far below 1 code) and the backstop does its job. It is the same
    class as the anchor branch's round-2 corners, which `sweepStep` fixed. On the lane,
    `sweepStep` would not reach it (the reach at pivot 1 is 4 EV, so the step stays
    0.05); a slightly larger `secantMargin` would.
  - **Minor, non-blocking, fixable in WS-05.** It changes no spec line: M1 is 0 / 0.
- **Anchors 1…6** (§1): the guard holds everywhere. Below +2.5 EV, Whites −100 is
  eased and secant inversions are clamped. This is latent and unreachable.
- **Whites and Contrast extremes, and masks, at the shipping anchor.** The code is
  bit-identical to round 2, so round 2's render tests on 3582 and the five extra frames
  still apply. The mask route uses the same constructor and the global anchor.

## 6. Anchor branch `04cc6cc`

- **Renders.** `ASHIFT=-2`, `$V/anchor`, built from the extracted tree. The spec set is
  **byte-identical to round 2's anchor renders** (492 / 492). `measure.py`, with `AH`
  linked to this tree (`$V/mspec_anchor`), gives **27/32**:
  - **A1 PASS**: 242.0; 247.0 / 253.0; gap 17.0.
  - **A2 PASS**: max luma 242.0 / 243.1 / 242.6 / 242.0, 0 % at 255.
  - FAIL: S3 (0.860 / 0.837), W4 (z6 4.7), W5 (+6.0 against ≥10), W6 (NaN: the band is
    empty), HA1 (h−100 29 / 6.9, h+100 25 / 5.0, s+100 33 / 5.5, w−100 24 / 4.0).
  - H6 measures 0.11° (B−100).
- **`sweepStep`.** I compared `04cc6cc` with `dd0e274` (the same branch before
  `sweepStep`) over 13,125 settings: Contrast −100/0/100 × pivots −2/0/1/2/2.5/3/4 ×
  H, S, W, B at five values each.
  - **Forward clamp: 175 → 0** settings (most flat samples 4 → 0).
  - **Requested inversions: 425 → 50.** The remaining 50 are lower-half, worst 3.8e-5 EV,
    and identical to the lane's.
  - **Default pivot 0, any Contrast, and every pivot at Contrast 0: bit-identical.** I
    compared the effective H/S/W/B scales and an FNV hash of the 1,024-sample baked LUT.
    So nothing at the default pivot moves.
  - Changes occur only at pivot ≥ +1 with Contrast ≠ 0, where the limit tightens slightly
    (for example 0.493 → 0.485), as intended.
  - The pivot clamp in `sweepStep` matches `contrastMapped`'s. A reach of 0 floors the
    step at 0.01, so it costs at most 500 steps per half.
  - Monotone in the slider: on anchors 1…6, 0 Whites slider-value violations.
- **T2** (6.1.2, extracted tree): 3053 tests, exactly 2 failing, both named:
  - `EngineTests.testAutoRecoversABlownSkyThroughTheRealMeasurement` (2.929 against
    > 3.0; WS-09, N10);
  - `RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther` (Bright pivot 0.5; WS-08,
    N11).
  - Nothing else fails.
- **T3** (release): **6 tests, 8 failures**.
  - The seven control failures are exactly N15's:
    - `tone.contrastPivot` dead 2;
    - `sharpen.haloSuppression` dead 5;
    - `grade.blending` 17.27;
    - `zones.bright.ev` 23.81;
    - `zones.pivot.4` 25.26;
    - `primaries.bHue` hands back 18.12;
    - `look.grain.size` hands back 18.89.
  - The eighth is the records test: **132 moved records. The set equals N15's table
    exactly** (`comm` of the two id lists is empty both ways), including the 5
    `pointColor.*` records under WS-32.
  - Tone floors: highlights 59.57 / 35, shadows 47.97 / 30, whites 45.61 / 30, blacks
    23.27 / 15, contrast 64.93 / 55.

**Verdict on the anchor branch.** Everything it claims is confirmed. It fixes A1/A2 and
nothing else regresses beyond what it declares. It is not a standalone PASS: W4, W5, W6
and HA1 fail under the current spec. Merging it needs, from the integrator:
- the W4/W5/W6 amendment for C0 = 3;
- an HA1 decision on Highlights;
- sign-off on the global look change, with the 132 records re-recorded;
- the WS-09 and WS-08 follow-ups (N10, N11).

## 7. Small notes for whoever touches this next (none blocks)

1. On the lane, Contrast −100 at pivot +1 with H−100 and W−100 trips the forward clamp
   (≤3 flat samples, ≤4e-6 EV). Base does not. `secantMargin` or a finer upper sweep
   would remove it.
2. The `minimumUpperShelfWidthEV` comment says +1.1 EV. For the −100 hold shelf it is
   +2.3 EV, and a lone Whites −100 is eased at Contrast 0 below +3.8 EV with the lane's
   constants.
3. The doc comment above the renamed EngineTests test still says "The anchor move is
   kept".
4. BUILD-NOTES §8, "nothing beats the shipped shape on S1": sharper tapers do (§3), but
   not on 7881's ratio in any way that matters, and they band.
5. Measuring: `$S/anchorh` must be rebuilt against the tree under test before H6 / A1 are
   read. A stale `AH` silently reports another branch's H6.
