# WS-05 build notes

Builder, round 2. Two commits, neither pushed:

1. **`quality/ws-05-zonal-tone`** (this file, §1-§6): all the slider work, default white
   anchor kept at **+5 EV**.
2. **`quality/ws-05-white-anchor`** (branched from 1, §7): `defaultWhiteAnchorEV` 5 → 3 and
   what ToneEngine needs for it. It moves tests owned by other lanes; §7 lists them.

Round 1 (one commit with both) was replaced because the anchor move left WS-08/WS-09
tests red on the lane branch.

Paths (`S` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/spec`,
`P` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad`):
- after-renders of the lane branch: **`$P/lane1`** (`ASHIFT=0 bash $S/render.sh`);
  `ASHIFT=0 python3 $S/measure.py $P/lane1` printout in `$P/measure_lane1.txt`;
- base renders `$S/base`; models and scans in `$P/bh/`.

## 1. What changed on the lane branch, and why

Everything is in `ToneEngine`'s WS-05 functions, plus the Shadows tooltip in
`BasicPanel`. The GPU sees it only through the gain LUT / cube and the anchors that
`RenderPlan` bakes from `ToneEngine`; no renderer file changed (G1 diff is empty).

| change | why |
|---|---|
| Highlights shelf full at `highlightShelfEndEV` = 5 EV (was 1.0 x the white anchor) | Identical shelf on the +5 anchor (so R1-R4 and HA for Highlights equal base exactly). In EV it keeps its 0.6 slope if the default anchor moves (§7). |
| Whites no longer moves the white anchor (`anchors(for:)` returns the base white anchor) | H6/H1/H2: the display transform's path-to-white blend is normalised by the anchor (`shoulderU`), so moving it re-hued blues Whites applied no gain to (14.05° at base). The clip point moves by gain only. `applyAnchors` still writes only `whiteAnchorEV`/`blackAnchorEV` (G2). |
| Whites +100: 1.2 EV over `smoothstep(anchor − 3.8, anchor − 0.6)` (+1.2 … +4.4 EV) | W2 (clips at +4.0 = C0 − 1), W1 (linear in stops by construction), W3/W5 at C0 − 2 = +3 EV, W4 (zone 6 still, zone 7 2.1), W7. Slope 0.56. |
| Whites −100: a 0.9 EV hold over anchor −3.8 … −1.8 plus a 1.0 EV recovery over anchor −1.2 … +1.6 (`whiteRecoveryStops`) | W5(−) and W6, and the `RobustnessTests` four-way floor: a mirrored −100 falls where Contrast +100's shoulder is flattest (+3.85 EV) and the corner solved to 0.42 against 0.62; this shape solves to 0.687 (Python mirror of the solver, `$P/bh/solver.py`). |
| Shadows +100: a 1.5 EV lift rising over 0 … −3.5 EV and tapering to 5 % over −3.15 … −4.15 EV (`shadowLiftWeight`); Shadows −100 keeps the old 2 EV shelf | S1/S5 (black point stays Blacks'), S2/S6, and the `RobustnessTests` floor for one control against Contrast (rising side falls at 0.64 stops/stop → 0.615 ≥ 0.60; a −3.0 EV peak gave 0.53). −100 keeps the shelf, so it stays a rising window that is never eased, and its halos equal base. |
| `secantMargin` 1e-3 on the solved zonal limit | The lift's slope peaks inside a 0.05 EV sweep interval; one bake sample fell 8.7e-6 EV and `ZoneFlatteningTests` caught the forward clamp firing. |
| `scripts/gen-fixtures.py` (the Python mirror of ToneEngine) and `Fixtures/enginemath.json` | The mirror changes with the Swift (its header says so). All Linux-side checks in the script pass. |

## 2. Spec lines on the lane branch (ASHIFT = 0, C0 = 5.0 EV)

`measure.py`: **28/32 PASS**. A1/A2 are the anchor branch's lines.

| id | result | measured | threshold |
|---|---|---|---|
| A1 | FAIL (by design here) | 221.0; 226.0 / 232.0; 14.0 — base values, anchor unchanged | see §7 |
| A2 | FAIL (by design here) | max luma 221.0-221.9, 0 % clipped — base | see §7 |
| S1 | PASS | 6929 7.6, 4213 7.2 | ≤8.0 |
| S2 | PASS | 6929 20.5, 4213 29.8 | ≥15.2, ≥23.9 |
| S3 | **FAIL** | 6929 0.859, 2545 0.974, 1332 0.837, 983 1.081, 1569 0.983 (base 0.768 / 0.792 / 0.765 / 0.841 / 0.788) | ≥0.95 each |
| S4 | PASS | 1.168, 1.250 | ≥1.00 |
| S5 | PASS | S z0 3.8 < B z0 7.1; −6 EV 2.0 | ≤6.0, <B; ≤4 |
| S6 | PASS | −2 EV 70.0; 1840 19.6, 2348 20.8 | ≥63; ≥18.7, ≥17.4 |
| W1 | PASS | 0.98 at +3.0 EV (d50 0.39, d100 0.77 EV) | ≤1.5 |
| W2 | PASS | +100 clips at 4.0 EV | 3.5 … 4.5 |
| W3 | PASS | 1.00, 1.12, 1.23, 1.65 | min ≥0.5 |
| W4 | PASS | W z6 0.0, W z7 2.1 vs H z7 16.5 | z7 ≤ H, ≤16.5; z6 ≤3.0 |
| W5 | PASS | +13.0 at C0 − 2; −13.0 at C0 − 1 | ≥10; ≥12 |
| W6 | PASS | any-clip 0.76 %; ≥+4 EV 0.0 %; +3.5 … +4 EV 0.8 % | ≤1.15; 0.0; ≤45.0 |
| W7 | PASS | 983 6.5 %, 2545 9.1 %, 1332 0.4 % | ≤22 / 28 / 10 |
| H1 | PASS | 0.00 ; 0.00 | ≤0.5; ≤2.0 |
| H2 | PASS | 0.0° | ≤2.0 |
| H3 | PASS | H−100 7.5, H+100 8.4, W−100 3.0, W+100 2.0 (base 7.5 / 8.4 / 10.3 / 28.8) | base +1 |
| H4 | PASS | 9.1, 3.4, 3.5, 1.6 (base 9.1 / 3.4 / 14.6 / 9.7) | base +1 |
| H5 | PASS | sw H 0.2, W 0; swx H 1.7, W 0.9 (base W 19.5) | base +1 |
| H6 | PASS | worst 0.05° (Blacks −100); Whites ±50/±100 0.00; H and S 0.00 | ≤0.5 |
| R1 | PASS | 7.0 EV; 235.0 at C0 | ≥7.0; ≤240 |
| R2 | PASS | 0.19 %; 0.00 % | ≤0.25; ≤0.05 |
| R3 | PASS | 0.672, 0.884, 0.775, 0.887 (= base) | ≥ base −0.02 |
| R4 | PASS | 13.4 %; 21.4 % (= base) | ≤13.5; ≤21.5 |
| B1 | PASS | 9.2 %, 13.8 %; 11.3, 12.5 | ≥8/12; ≥9.5/10.5 |
| Z1 | PASS | H 0.06, W 0.00, S 0.00, B 0.01 | ≤1.0 |
| Z2 | PASS | 0.0 all | ≤1.0 |
| M1 | PASS | 0 / 0 | 0 / 0 |
| M2 | PASS | 1.00 | ≤1.0 |
| HA1 | **FAIL** | h−100 25/5.0, h+100 17/4.0, s−100 25/3.9 (all = base); **s+100 33/5.5** (base 29/5.3); **w−100 24/5.0** (base 12/2.6); w+100 14/3.0 (base 34/7.6); b 6/2.0, 9/2.0 | base +2 px / +0.5 |
| HA2 | PASS | 0 | 0 |
| HA3 | **FAIL** (2 cells) | `halo_real.py swx`: H = base; S−100 7.8 = base; **S+100 1840 9.3** (base 7.8, 1.19x); W+100 3.0 / 3.0 (base 36.9 / 27.0); W−100 1840 5.7 (base 6.1), **4213 5.4** (base 3.2) | ≤1.15x base |
| G1 | PASS | `git diff --stat claude/inspiring-dirac-ulgpch -- Sources/LumenPipeline .../ReferenceRenderer.swift .../RenderPlan.swift .../DisplayTransform.swift` is empty | empty |
| G2 | PASS | `applyAnchors` writes only the two anchors; new gain inputs come from `Tone` | reading |
| G3 | PASS | RenderPlan / ToneTwinClamp / EngineTests pairing tests green in T2 | pass |
| G4 | n/a here | the anchor does not move on this branch; §7 | |
| M3 | PASS | `testIdentityToneIsDetected`, `ZonalToneTests.testZeroIsAnExactIdentityAndAnyOneSliderIsNot` | true |

### What could not be met, and why (the spec is not loosened)

**S3 against S6 and S1.** S3's high-pass is dominated by shadow pixels that border
brighter ones. On 6929, pixels whose whole 7x7 window is under code 50 keep 1.9x their
texture at +100; the border pixels carry 86 % of the variance and lose contrast because
the dark side is lifted and the bright side is not (`$P/bh/s3m.py` decomposition). A
per-pixel model of the S lines over the whole bump family (`$P/bh/s3scan*.py`; it reads
0.02-0.04 low on S3 against real renders) gives a best S3 of 0.949 only with 1840 lifted
10.7 codes (S6 needs 18.7), and ≈0.86 when S1 ≤ 8 and S6 ≥ 18.7 both hold. Real renders
this round, trying to raise S3 at anchor 5:

| lift (height, peak, taper start…end, depth) | S1 6929/4213 | S3 6929 / 1332 | S6 1840 | HA1 s+100 | HA3 S+100 1840 |
|---|---|---|---|---|---|
| **1.5, −3.5, −3.15 … −4.15, 0.95 (shipped)** | 7.6 / 7.2 | 0.859 / 0.837 | 19.6 | 33 / 5.5 | 9.3 |
| 1.5, −4.0, −3.15 … −4.15, 0.95 | 7.5 / 7.2 | 0.872 / 0.852 | **17.1** | 25 / 4.7 | 7.3 |
| 1.4, −3.8, −3.2 … −4.2, 0.95 | **8.2** / 7.9 | 0.871 / 0.851 | **17.3** | 22 / 5.0 | 7.5 |
| 1.5, −3.75, −3.3 … −4.2, 0.95 | **10.6** / 9.7 | 0.853 / 0.837 | 20.0 | 32 / 5.7 | 8.2 |
| 1.5, −4.0, −3.4 … −4.25, 0.95 | **13.7** / 13.1 | 0.855 / 0.842 | 19.7 | 27 / 4.8 | 7.3 |
| 1.6, −4.0, −3.3 … −4.2, 0.95 | **11.4** / 10.6 | 0.850 / 0.837 | 20.3 | 28 / 5.5 | 7.8 |

No variant raises S3 by more than 0.015, and every one that does breaks S1 or S6. The
shipped one is the only one that meets S1, S2, S4, S5 and S6 together. Keeping the
contrast across a lifted border is the base/detail split in NEEDS N3 (WS-07).

**HA1 / HA3: two cells each, all spatial** (NEEDS N9). Highlights and Shadows −100 are
equal to base. Whites −100 was an anchor move at base, and a per-pixel transform change
cannot halo; H6 forbids that move, so −100 is a gain and goes through the guided mask.
Shadows +100 opens the quarter tones near mid-grey more than the old shelf, and the
table above shows that the variants which pass HA fail S1 or S6.

**Lines that held only on one anchor.** Round 1 (anchor +3) could not meet W4 zone 6
together with W3/W5: there C0 − 2 = +1 EV, and the grey ramp's zone 6 is two thirds the
+1 EV step patch. On the +5 anchor C0 − 2 = +3 EV, in zone 9, and W1-W7 all pass. §7
repeats the conflict for the anchor branch.

## 3. Gates on the lane branch

- **T1** `swift build --target LumenCore --target LumenRender` (Swift 6.0.3): clean. The
  only warnings are pre-existing Sendable warnings in `Ingest/VerifiedCopy.swift`.
- **T2** `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` (Swift
  6.1.2, `--scratch-path .build612`): **3051 tests (3044 + 7 new), 0 failures.**
- **T3** `swift test -c release --filter ControlProofTests`: see §5.

## 4. Tests (T4): added, and changed with the invariant kept

Added `Tests/LumenCoreTests/ZonalToneTests.swift`, 7 tests:
- S1/S5: Shadows +100 at −4 EV is under 0.25 x the quarter tones; below −5 EV it is under
  Blacks +100 and under 0.1 EV; −6 EV renders ≤ 4 codes.
- Shadows: −100 is the 2 EV shelf, +100 the tapered lift.
- W2/W4/W1: the +100 clip lies between C0 − 1.5 and C0 − 0.5; −100 carries C0 + 0.9 back
  under white; Whites ≤ Highlights up to +1.3 EV; zero at the shelf start; +50 is exactly
  half of +100. The anchor is unchanged and neither end is eased at Contrast 0.
- R1: Highlights −100 maps C0 + 2 onto C0.
- H6: the exact path, 6 blues x −2 … +3.5 EV x 4 sliders x ±50/±100, adds ≤ 0.5° beyond
  the default plan at the same gain, and Whites ±100 leaves `forRecipe(...).params`
  equal to the default.
- M3, and "a single zonal slider is never scaled at Contrast 0".

Changed, because each encoded the behaviour the spec replaces. Each still asserts its
invariant; none is loosened:

| test | change | invariant still asserted |
|---|---|---|
| EngineTests `testWhitesAndBlacksMoveBothTheAnchorsAndTheCurve` | white anchor now asserted EQUAL; clip point asserted to move by gain both ways (C0 − 1 reaches white at +100, C0 + 1.5 goes under at −100); Blacks still moves its anchor | Whites/Blacks have authority, mid-grey untouched |
| EngineTests `testWhitesBrightensThroughTheTransform` | compares rendered tone through the (now identical) transform with each engine's gain; asserts params equal | Whites +100 brightens a highlight |
| EngineTests `testTheEndShelvesOverlapTheZonalOnesAsTheCommentSays` | new shelf numbers (+1.2 … +4.4 EV; Highlights 0.145 / 0.960 there) | the comment's geometry is held as numbers |
| EngineTests `testAPivotPastTheWhiteAnchorStillCannotPushAPixelPastIt`, ColourAccuracyTests `testContrastKeepsTheWhiteAnchorFixedWhenWhitesPullsItBelowThePivot` | the anchors 4.0 / 3.8 / 3.5 EV that Whites +67/+80/+100 used to make are now passed as `baseWhiteAnchorEV` (how a mask engine sees a lowered global anchor) | same anchors, same pivots: Contrast pins the anchor and never pushes past it |
| AccuracyProbeTests `testTheToneEndpointsDeliverTheirDocumentedEV` | Shadows +100 peak = `shadowLiftRangeEV` (1.5); added Shadows −100 = 2.0 and Whites −100 = hold + recovery (1.9) | each documented constant is the delivered peak |
| FieldBaselineProbeTests `testPrintsTheToneRecoveryBaseline` | Shadows +100 peak 1.5 | the partition at mid-grey; documented peak |
| MaskingTests `testAMasksWhitesAndBlacksMoveThePictureOnTheirOwn` | bar is 0.9 x `whiteToneEV` (1.2) instead of > 1.0 with 1.3 | a mask's Whites/Blacks move most of their shelf, mid-grey still |
| GradeStripAxisTests (2 tests) | the anchor move is driven by Blacks (span 15.5 vs factory 14, miss 0.214 EV) instead of Whites; plus "Whites leaves the axis at 14" | strip draws the rendered crossfade; Balance handle lands where released |
| PlanTableCacheTests (2 tests), PlanCostProbeTests | the finish-table re-keying control is Blacks, not Whites | cache key / stale-serve / bake-count contracts |
| `Fixtures/enginemath.json` | regenerated by the updated mirror | Swift and Python agree |
| `Proof/records/tone.shadows.json`, `tone.whites.json` | re-recorded (§5) | the records describe what the engine does |

## 5. T3 (ControlProof, release)

`swift test -c release --filter ControlProofTests` (Swift 6.1.2, `--scratch-path .build612r`).
- Base worktree (`84bcd7c`): 6 tests, 0 failures (`$P/t3_base.log`).
- Lane branch: **6 tests, 0 failures** (`$P/t3_lane2.log`), after the two records below
  were updated.

Floors (authority / ProofRegistry floor): `tone.highlights` 55.84 / 35 (= base),
`tone.shadows` 47.97 / 30, `tone.whites` 35.34 / 30, `tone.blacks` 23.27 / 15 (= base),
`tone.contrast` 68.38 / 55 (= base). All monotone, 0 dead steps, nothing given back.

**Only two committed records moved, both WS-05's own controls**, and they are updated in
this commit (`Tests/LumenCoreTests/Proof/records/tone.shadows.json`, `tone.whites.json`).
Every other control's record is unchanged:

| record | committed → now | why | fix or regression |
|---|---|---|---|
| `tone.shadows` | authority 47.19 → 47.97; mean separation 13.64 → 9.67; front-loading 0.408 → 0.405 | +100 is the tapered lift: the deepest third of the neutral ramp is no longer lifted (S1/S5), so the mean step between sweep values shrinks while the total range of the control does not | fix (SPEC S1, S5) |
| `tone.whites` | authority 47.77 → 35.34; mean 9.46 → 5.76; front-loading 0.49 → 0.70; smallest live step 2.06 → 1.08 | the 1.5 EV anchor move is gone (it re-compressed the whole shoulder, which is what made the old authority large and also what re-hued blues); Whites now acts on the top 3.8 EV only and clips 1 stop earlier at +100 instead of 2.5 | fix (SPEC H6, W2, W4, W7). Authority is still above the 30 floor; front-loading 0.70 is the shelf concentrating at the top of the ramp |

## 6. Evidence (lane branch)

`docs/quality/lanes/WS-05/evidence/`, before = base, after = `$P/lane1`:
`v1_shadows_6929_4213_before_after.png` (100 % crops: Shadows 0, before +100, after
+100), `v2_whites_top_steps_before_after.png`, `v3_hue_wheel_whites_before_after.png`
(sw and swx at exposure +2: after-Whites +100 no longer washes the wheel out),
`v3_sky_probe_whites_before_after.png`. The four `before_*` files are the audit's.
