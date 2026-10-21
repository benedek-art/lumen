# WS-05 report: Highlights, Shadows, Whites, Blacks

Lane branch `quality/ws-05-zonal-tone`. Companion branch `quality/ws-05-white-anchor` (not for merge yet).
Verdict after the brief's three build/verify rounds: **FAIL, with every remaining line BLOCKED outside WS-05.**
28 of 32 spec lines PASS; the other 4 cannot be fixed inside this lane without failing a line that passes now
(VERIFY-R3.md §7). All gates are green: T1 build, T2 3052 tests / 0 failures, T3 ControlProof 0 failures, G1 no renderer file touched.

## For the owner

1. The "funky blue highlights" come mostly from the display transform (blue drifts toward violet and pink by up to +49°). WS-13 owns the fix. Whites was adding up to 14° of its own drift; it now adds 0°.
2. Shadows +100 no longer lifts the black point into a grey veil: the darkest 1 % now rises 7.6 codes, against 29 before. The cost is that a very underexposed frame opens about half as much, so use Exposure first on low-key shots.
3. Whites is now even across its whole travel, clips at +4 EV instead of +2.5, and no longer has a dead top half.
4. Your call: the white point. Sensor white renders at code 221 today, which is the washed-out look. A +3 EV anchor puts it at 242 with nothing clipped. Compare the two in `evidence/white-anchor-owner.png` on the `quality/ws-05-white-anchor` branch.
5. Two edge halos got slightly wider (Whites −100: 2.6 → 5.0 codes; Shadows +100: 29 → 33 px). They are not visible at 200 %. WS-07's mask is the real fix.

Best evidence:
- `evidence/v1_shadows_6929_4213_before_after.png`: shadows open, black point holds.
- `evidence/v3_hue_wheel_whites_before_after.png`: Whites no longer re-hues blues.
- `evidence/white-anchor-owner.png` (anchor branch): the white point decision.

## Verdict per spec line (lane branch, measured by the round-3 verifier)

| id | measured | threshold | verdict |
|---|---|---|---|
| A1 | 221.0; 226.0 / 232.0; gap 14.0 | 238…250; ≥245 / ≤254.5; ≥8 | BLOCKED: passes on the anchor branch (242.0; 247.0 / 253.0; 17.0) |
| A2 | max luma 221.0–221.9, 0 % at 255 | ≥238, ≤0.5 % | BLOCKED: passes on the anchor branch (242–243) |
| S1 | 7.6 / 7.2 (base 29.4 / 29.2) | ≤8 | PASS |
| S2 | 20.5 / 29.8 | ≥15.2 / ≥23.9 | PASS |
| S3 | 0.859, 0.974, 0.837, 1.081, 0.983 (base 0.77–0.84) | ≥0.95 each | BLOCKED: the metric mixes in-shadow texture (up 1.5–2.4×) with shadow/midtone border contrast; needs a metric split or WS-07 N3 |
| S4 | 1.168 / 1.250 | ≥1.00 | PASS |
| S5 | z0 3.8 < Blacks 7.1; −6 EV code 2.0 | ≤6, <B; ≤4 | PASS |
| S6 | 70.0; 19.6 / 20.8 | ≥63; ≥18.7 / ≥17.4 | PASS |
| W1 | 0.98 (base 2.94) | ≤1.5 | PASS |
| W2 | clips at 4.0 EV (base 2.5) | 3.5…4.5 | PASS |
| W3 | min step 1.0 (base 0) | ≥0.5 | PASS |
| W4 | z6 0.0, z7 2.1 vs Highlights 16.5 | ≤3; ≤H | PASS |
| W5 | +13 / −13 | ≥10 / ≥12 | PASS |
| W6 | 0.76 %; 0 %; 0.8 % | ≤1.15; 0; ≤45 | PASS |
| W7 | 6.5 / 9.1 / 0.4 % (base 32.3 / 40.7 / 16.5) | ≤22 / 28 / 10 | PASS |
| H1 | 0.00°; p99 0.00° (base 2.35 / 7.92) | ≤0.5; ≤2.0 | PASS |
| H2 | 0.0° (base 7.7) | ≤2.0 | PASS |
| H3–H5 | all ≤ base +1° (Whites at +2 EV p95 28.8 → 2.0) | base +1° | PASS |
| H6 | worst 0.05°; Whites 0.00° (base 14.05) | ≤0.5° | PASS |
| R1–R4 | equal to base (clip at +7 EV; 983 0.19 %) | as spec | PASS |
| B1, Z1, Z2, M1, M2, M3 | as spec | as spec | PASS |
| HA1 | Shadows +100 33 px / 5.5 (base 29 / 5.3); Whites −100 24 / 5.0 (base 12 / 2.6); Whites +100 improved 34 → 14 px | base +2 px / +0.5 | BLOCKED: accepted trades, root cause WS-07 N2/N9; needs integrator waiver |
| HA2 | 0 px | 0 | PASS |
| HA3 | 2 cells over: Shadows +100 on 1840 (false fail: lifted dark branches, not sky); Whites −100 on 4213 sky 3.2 → 5.4 | ≤1.15× base | BLOCKED: WS-07 |
| G1–G3, T1–T4 | see VERIFY-R3.md §5 | | PASS |

Visual: V1, V2 and V3 PASS. V4 (sensor white reads white) passes only on the anchor branch.

## What changed and why

All code is in `ToneEngine` (WS-05's functions), plus the Shadows tooltip in `BasicPanel`. The GPU sees only the baked gain LUT/cube and the anchors, so CPU and GPU change together; no renderer file is in the diff.

- **Whites no longer moves the display white anchor.** The display transform's path-to-white blend is normalised by the anchor, so moving it re-hued blues that Whites applied no gain to (14°). The clip point now moves by gain: +100 is a 1.2 EV shelf (anchor −3.8 … −0.6 EV); −100 is a 0.9 EV hold plus a 1.0 EV recovery over white. Every Whites window goes through `upperShelf`, so Whites never reaches mid-grey at any anchor (31,500 settings checked).
- **The Shadows +100 lift tapers to 5 % between −3.15 and −4.15 EV,** so the black point stays with Blacks. Shadows −100 keeps the old shelf.
- **The Highlights shelf end is an absolute 5 EV.** It is identical to base at the +5 anchor and stays put if the anchor moves.
- **The limiter has a 1e-3 secant margin,** which fixed a sub-step dip `ZoneFlatteningTests` caught.
- **The Python mirror (`scripts/gen-fixtures.py`) and `Fixtures/enginemath.json` follow the Swift.**
- **Tests:** new `ZonalToneTests` (A1, S1/S5, W2/W4, R1, H6, M3, limiter, Whites guard). 15 existing tests were updated where they encoded the replaced behaviour; BUILD-NOTES §4 lists each with the invariant it still asserts. One was narrowed with a stated reason: FieldBaselineProbe's Shadows peak, "exactly 2.0" → "1.35…1.5", because the lift is now 1.5 EV by design.

## What is left, and who owns it

- **The white anchor, +5 → +3 EV** (`quality/ws-05-white-anchor`, A1/A2 PASS). It needs owner sign-off on the look, then WS-09 (Auto Tone threshold), WS-08 (Bright pivot), seven controls' proof floors and 132 re-recorded records (NEEDS N10–N15). W4/W5/W6 need amending for a +3 EV clip point, since two of them contradict each other there (BUILD-NOTES §7).
- **Dark-frame Shadows:** 7881 keeps 0.52× of base's lift. A 1-D curve cannot open its cloth (−3.6 EV) and hold the p1 of 6929/4213 (−3.9 EV) at once. The verifier's best alternative reached 0.56× and drew a band. The real fix is a local/adaptive Shadows (WS-07).
- **Blue drift in the display transform:** WS-13, accepted as their lines 3.1–3.9 (NEEDS N4–N6).
- **The mask driven by luminance only, halos, highlight texture:** WS-07 (NEEDS N1–N3, N9).
- **Minor, invisible:** the forward clamp fires on 3/1024 samples (4e-6 EV) at Contrast −100 / pivot +1 / Highlights −100 / Whites −100. A larger `secantMargin` would remove it.

Reports: AUDIT.md, SPEC.md, BUILD-NOTES.md, VERIFY.md (round 2), VERIFY-R3.md (round 3), NEEDS.md.
