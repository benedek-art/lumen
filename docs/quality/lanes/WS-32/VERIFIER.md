# Verifier report, round 3 (final): lane K3 (WS-32 Point Colour, WS-33 Primaries)

Code under test: fe7c863. Branch HEAD is now cbcb102, which only respells `LookPanel.init` (`State(initialValue:)` → `.init(initialValue:)`; parses clean) and renames a test local. The engine is identical to fe7c863.

Verifier: the same agent as rounds 1 and 2. It changed no Sources/ or Tests/ files and made no commits. Earlier reports are kept at `/tmp/claude-0/vscratch/verifier-report-round1.md` and `…-round2.md`.

**Builds and tests**
- Release lumen-render rebuilt from fe7c863 at `/tmp/claude-0/verifier-release/release/lumen-render`.
- Test build in `/tmp/claude-0/verifier-build`; I checked the objects are newer than the sources.
- `PointColour|Primaries|ExactColorStage|PerPixelVarianceHelpTests|RecipeCodecToleranceTests`: **68 tests, 0 failures**. This includes the new `testAPaleColourOfAnotherHueIsNotReadAsATint`.
- ControlProofTests were not run, as instructed. CI's Proof sweep passed on fe7c863.

**Probes and evidence**
- Engine probes are linked against LumenCore (`/tmp/claude-0/vscratch/h`).
- measure.py output: `/tmp/claude-0/verifier-measure3.json`.
- Images: `/tmp/claude-0/vscratch/*_r3.png` and `/tmp/claude-0/vscratch/sw/blend_zoom_r3.png`.

## CPU, twin and kernel, read side by side (fe7c863)

All three compute the same things in the same order with the same constants:
- the share
- `g = gate(tC)·gate(C)`, with no fade
- `r = share > 1 ? 1/share : max(share, 0)`
- `mL = 0.5·tL`
- `over = max(tC, 0)`
- `mH = atan2(|cross|, dot)·(180/π) / 180 / (0.5·σH)`, with the same sign convention for `cross` (b·sA − a·sB)
- the mixture reading `ramp·(1 − smoothstep(0.5, 1, √(mL² + over² + mH²)))`, maxed with the absolute reading
- the hue rotation reading the absolute selection only, at `tH` or `tH/k`
- the early-out `weight > 0 || hueWeight > 0`
- the chroma-gated Variance terms

**Edge case.** The kernel's `atan(abs(ccross), cdot)` is undefined in GLSL at (0, 0), and it is computed unconditionally. It is used only when `ramp > 0`, which needs the pixel's chroma gate above 0 (C > 0.02), so the pixel's linear chroma is non-zero. Harmless, but unguarded (low).

**Twin vs engine.** Probed across extreme swatches: Range 0/100, refinements 0/100, Hue ±60, Variance −100/0/+100, and samples that are near-neutral, at the gate edge, with a negative channel, very dark, very bright, or saturated blue. Inputs were random colours, blends and near-greys. Worst normalized error 2.2e-5, with no NaN mismatches.

## Round-2 problems: status

| Round 2 | Status at fe7c863 |
|---|---|
| 1 Pollen speckle (2062) | **Reduced, not gone.** Core mean drop under Lum −80: 21.3 % → **7.7 %** (base 0.1 %). But per-pixel std rose 0.078 → **0.105**, max 46.8 %: 18 of 140 pollen pixels drop more than 20 %. It now reads as isolated dark pepper dots on the cream dot (`2062_blob_r3.png`). |
| 2 Non-monotonic with tight Sat range | **Fixed.** 0 of 26 082 blends rise, at 200 steps. That covers Range 0/50/100 × Sat range nil/0/100 × Lum range nil/0/100 × 6 neutrals × 4 lightnesses × 4 chromas × 12 hues. The per-setting sweep (Range 0/50/100 × Sat 0 / Lum 0 / both / Sat 25 / Sat 100 / Lum 100, 400 steps) finds 0 rises above 1e-3. The purple tight-Sat frame and the red blend frame render smoothly, with no line (`sw/blend_zoom_r3.png`). |
| 3 Undisclosed S4 loosening | **Fixed.** The SPEC now states it was loosened in round 2 and why. |
| 4 C 0.03–0.04 pixels gain weight | Still by design. C ≤ 0.02 gains exactly 0 for every case I probed. At C 0.03 the gain is up to +0.16; at C 0.04 up to +0.50 (skin and dark-red swatches, light pixels). These are pale tints inside the gate's ramp. |
| 5 REPORT.md | **Fixed.** The verdict table is filled in, S5 is reported as FAIL and S7 as BLOCKED, and the "satin sheen" claim is gone. Only `ROUND3_PLACEHOLDER` remains, as expected. |

**Also checked in round 3:**
- **Variance on greys.** −100 and +100 under Sat range 100 or Range 100 give output chroma 0.00000 on the engine and the twin, which differ by 1e-7 or less.
- **Hue order and folding.** 5 samples × Range 0/50/100 × Hue range 0/50/100 × Sat range 0/100 × shifts ±30/±60. Each was swept over the sample's hue ±90° in 0.25° steps, at the sample's L and C, at 0.6·C one step lighter, and at 0.35·C. Result: **0 reversals in 1 080 sweeps**.

## Spec lines

| # | measured | verdict |
|---|---|---|
| S1 | tests | PASS |
| S2 | `PointColourHueOrderTests` pass; my probe finds 0 hue-order reversals | PASS |
| S3 | tests | PASS |
| S4 | monotonic everywhere I probed, refinements included; spec case w(0.5) 0.138, max abs(w − α) 0.385; thresholds 0.12 / 0.4, disclosed | PASS |
| S4b | tests; my probe finds 0.000 extra weight for C ≤ 0.02 | PASS |
| S5 | rim chroma left **0.650** vs base 0.742 = **0.875×** (threshold ≤ 0.80×) | **FAIL**. REPORT.md states this honestly |
| S6 (no regression) | 3.004 % vs base 3.004 % | PASS |
| S7 | Transition-band high-pass std of the per-pixel L drop: 2062 0.081 vs base 0.084; 2348 0.092 vs base 0.093. But isolated specks (drop more than 0.2 above the 5×5 median) on the 2062 crop number **672 vs base 617**, and the pollen pepper is new | **FAIL / BLOCKED**. REPORT.md marks it BLOCKED on WS-34. Note that the pollen pepper appears **with the default NR on** (`--iso 6400`), which REPORT's "mild with default NR" understates |
| S8 | hue LF 0.113, chroma LF 0.087, pores 0.989 (base 0.498), blue/grey ΔE 0, grey not tinted | PASS |
| S9 | tests | PASS |
| S10 | tests | PASS |
| S11 | tests; my probe gives 2.2e-5 worst. REPORT says "GPU parity workflow green on macOS", but that run was for 88e91aa: GPU parity for fe7c863 was **cancelled**, and cbcb102's is queued. Not proven for the current kernel | PASS on Linux; macOS GPU parity not verified |
| S12 | tests | PASS |
| P1 | tests (round 1: 5⁶ settings, Mixer, Tint) | PASS |
| P2 (≤ 0.004, honest restatement) | 0.00299 (base 0.00344) | PASS |
| P3 (honest restatement, verified in working space in round 2) | smallest step ratio 0.152 (rHue); R/G/B Saturation 0.596 / 0.678 / 0.617; 0 dead steps; 0 reversals | PASS |
| P4 | tests | PASS |
| P5 | tests | PASS |
| P6 | tests | PASS |
| P7 | not run, as instructed; CI's Proof sweep on fe7c863 passed | PASS (CI) |
| V1 (2062 petal edges) | Saturation −100: rim a little greyer than base. Luminance −80: the edge is still dotted at the boundary, much like base. The pollen has pepper dots | not met cleanly; REPORT says so |
| V2 (skin) | covered by S8 numbers | PASS |
| V3 (Point Colour snapshots, cbcb102 set, extracted to `/tmp/claude-0/snaps/quality-k3-point-colour/cbcb102/`) | Against baseline a93efb2: the three move rows carry the swatch's colour; a three-row strip sits under Range; three indented refinement rows (Hue / Sat / Lum range) follow; the refined state shows 80 and 25. The rest of the panel is pixel-identical between 88e91aa and cbcb102; only the strip changed. The strip is darker, but only slightly: mean −7…−11 levels, minimum about 70/255 against about 80. The unselected stretch still reads as lit, so a human should judge whether the falloff is readable | PASS (with that note) |
| WS-33 V2 (`panel-grade-grading-primaries-open.png`, cbcb102) | The Primaries fold is open. Rows read Red/Green/Blue Hue and Red/Green/Blue Saturation. Each track shows its axis: red is magenta → orange, green is yellow → cyan, blue is cyan → purple, and each saturation track runs grey → vivid. Shadow Tint and Tint Purity are unchanged | PASS |

**UI code.** There were no UI changes in round 3 apart from cbcb102's one-line init respelling, and `swiftc -parse` passes on it. The cbcb102 snapshot set arrived during my run (`LATEST` = cbcb102).

## Remaining problems

1. **MEDIUM: S5 fails** (0.875× vs 0.80×). The builder gives the trade-off: a tighter mixture hue test keeps the pollen out but also clips the rim where the warm plate is not neutral. It is disclosed.
2. **MEDIUM: 2062 pollen pepper at default NR (S7).**
   - Under Luminance −80, 18 of 140 pollen pixels are darkened more than 20 % (max 47 %); base darkens none.
   - Across the whole crop, isolated specks number 672 vs base 617.
   - Repro: `measure.py --only rim`, then compare `2062_lum_new.png` with `2062_lum_base.png` at rows 97–107, cols 502–516. Visual: `/tmp/claude-0/vscratch/2062_blob_r3.png`.
   - REPORT marks S7 BLOCKED on WS-34 and says speckle is "mild with default NR". This frame was rendered with the default NR.
3. **LOW: Hue shifts on soft edges are cut as before.** The rotation reads the absolute selection only, so a Hue move leaves the 40–85 % blend band of a soft edge unrotated, while Saturation and Luminance now fade there. This is not a regression and REPORT explains it, but the edge behaviour is inconsistent between the three move rows.
4. **LOW: the kernel's unguarded `atan(0, 0)`** (see the CPU/twin/kernel section). Unreachable while the gate holds.
5. **NOT VERIFIED:**
   - **macOS GPU parity** for the current kernel (fe7c863's run was cancelled).
   - **UI snapshots:** now judged from the cbcb102 set (see the V3 and WS-33 V2 rows). The only open point is how readable the strip's falloff is, which a human must judge.
   - **The 88e91aa CI failures**, which I looked at for context:
     - Its Proof sweep failed on the unre-recorded records; fixed later.
     - Its fixtures-linux failure includes a `State(...)` name confusion that cbcb102 addresses. The other findings there (AppState/PanelLayout labels, LumenType `Font`) are in files this lane did not touch.

## Overall: **FAIL**

This is the third and final round. Per the brief, the lane is **BLOCKED** on S5 (0.875× vs 0.80×) and S7 (pollen pepper; needs WS-34). macOS GPU parity for the current kernel is still unverified (cbcb102's run was queued). The UI lines PASS on the cbcb102 snapshots.

The rest is verified PASS, and the round-1/2 defects are fixed:
- blend monotonicity, including refinements;
- near-neutral safety;
- Variance on greys;
- CPU/twin agreement;
- hue order;
- every Primaries line;
- honest restatements of P2, P3, S4 and S6.

REPORT.md is honest about S5 and S7. It should add the two points above: the pollen pepper occurs with default NR, and GPU parity has not run on the current kernel.
