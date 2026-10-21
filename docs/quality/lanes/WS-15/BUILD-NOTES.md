# WS-15 Dehaze: builder notes (draft for REPORT.md)

The builder wrote this; it is not a verifier verdict. The final measurement is `build-work/r7` (renders) plus `build-work/r7.txt` (the check output). **33 of 40 SPEC lines pass. 7 fail: P5, H1, H3, N1, N3, N4 and U (U2).** Separately, the existing ControlProof authority floor for `detail.dehaze` now fails (9.8 against a floor of 68; see "Pre-existing tests").

## Bottom line for a human

The new Dehaze is clean but too weak:
- **Fixed:**
  - no storm skies;
  - no crushed snow, walls or greys;
  - no magenta veil;
  - the airlight is stable and comes from the sky;
  - no slider jumps;
  - preview matches full size;
  - CPU and GPU share one definition.
- **Not fixed:** at +100, 4213 changes by a mean ΔE2000 of about 1. The old code changed it by 12.5, and Lightroom's +100 is much stronger than what we have now. See `evidence/10_4213_sweep.png`: before is the top half, after is the bottom half.

I could not find a form, within this lane's budget, that gives real veil removal (P5, U2, N3, N4, the proof authority floor) and also passes the halo lines (H1, H3), which measure exactly the inter-surface and texture changes that veil removal makes. See "Conflicts" below.

## Algorithm (what and why)

All slider-independent fields are measured once on a proxy whose long edge is fixed at `dehazeProxyLongEdge` = 256. `DetailEngine.dehazeField(proxy:guide:guideSquare:airlight:)` computes them. The CPU reference and the GPU twin both call it, so the two share one definition.

1. **Airlight** (`dehazeAirlightEstimate`).
   - Luminance is eroded over a wide, short window (5 % × 2 % of the proxy). This removes compact white objects: chart patches, lamp glass, the lid.
   - The result is weighted toward the upper frame: a 0.3 tilt, then a cut to 0.1 below 50–65 % of the height.
   - The selection is every pixel within 95 % of the best score. The airlight is the window-averaged colour of the selection.
   - The airlight's saturation is capped at 0.3.
   - The selection mask is exposed for U10.
   - Results: A1–A3 pass, and the selection is identical at 512 and 2048 px.
2. **Region fields.**
   - V is ω × the range-restricted minimum of the min channel. P is the range-restricted geometric mean of luminance. Both use a 3 % window, restricted to samples within ±1.5 EV of the centre, so each surface keeps its own black and level. A plain closing filled the gaps between tree tops with sky.
   - There is also a flatness field: Kuwahara (quadrant) std of the log guide.
   - These reach full resolution by **joint-bilateral upsampling**. Each pixel blends its 2×2 proxy neighbours, weighted by bilinear weight × guide similarity × block purity, with V and P blended in log space.
3. **Positive.**
   - Each pixel is turned about an **edge-following pivot**: a self-guided filter of the LumenLog guide, radius 1 % of the long edge, ε 0.25 EV².
   - The exponent comes from the haze model's own log-slope at the surface, `P/(P−V)`. It is capped at `dehazeMaxGamma` 2.25 and scaled by `dehazeStrength` 1.25 and by the amount. A sky guard (flat × bright relative to A) takes 70 % of it back.
   - A detail curve (`dehazeDetailCurve`) spares sub-0.05 ln noise and lets go of large negative deviations.
   - A black floor ramps from identity at true black to 0.65 at 1.5 × the frame's p1.
   - The brightening cap is 1 + 0.25·a.
   - Chroma is restored in OKLab at fixed hue **and fixed luminance**, by 0.5·(γ−1), capped at 1 + 0.25·a. The boost eases off for colours already near full saturation and is gamut-safe.
   - The airlight's colour is never subtracted, so neutrals stay exactly neutral.
4. **Negative.** This mirrors the positive side:
   - log contrast is compressed about the pivot by `c = a·0.6·distance`;
   - a surface lift `(1.5·A/pivot)^(0.12·c)` is applied;
   - chroma eases toward a near-neutral tint, 30 % of the airlight's chroma, at fixed luminance;
   - distance = `max(V/P / q90(V/P), sky)` × a ground-plane weight (0.3 at the bottom of the frame).
5. **GPU** (`RenderGraph.applyDehaze` with `Kernels.dehazeSource`).
   - It reads back two 256 px proxies (colour and guide) plus the guide² proxy, using a clamped Lanczos reduction.
   - It calls the same LumenCore field functions.
   - It uploads the fields as four nearest-sampled, half-texel-shifted upsamples, so the 2×2 joint-bilateral neighbours are colour-kernel samples.
   - It builds the pivot with the existing `guidedSelfFilter` and `logDecode`.
   - The kernel mirrors the CPU formulas line by line. Every constant is a `DetailEngine` static passed as a uniform.
   - **It has not been compiled or run.** It passes `swiftc -parse`, and I reviewed it by hand. One Swift issue found in review was fixed: tuple destructuring in a closure parameter.
   - The GPU's Lanczos proxy differs slightly from the CPU's area average.

## Physics notes

- Positive Dehaze is a contrast restoration whose amount comes from the dark-channel veil fraction. It is not a black-point subtraction.
- **Black-point subtraction was built and measured, and it fails the halo lines in principle.** Its log-slope `Y/(Y−V)` is unbounded near V. So the ordinary 0.7 EV brightness variation inside a dark forest became ±0.9 EV bands (r2–r4). The display transform then amplifies shadow log ratios by about 1.8×.
- Two other designs were also measured and failed:
  - pinning at the local maximum darkened the forest 0.9 EV against the meadow's 0.2;
  - a per-surface veil gain (`build-work/veilgain-rejected.patch`) drew bands at every edge from field noise, and still only reached authority 44.

## SPEC table (`build-work/r7.txt`, 2400 px renders, worst row)

| Line | Verdict | Worst / failing rows |
|---|---|---|
| I1 | PASS | 0 codes everywhere |
| P1 | PASS | ≤ 0.02 % new zeros (1840 was 0.39 % before the floor ramp) |
| P2 | PASS | min p1 ratio ≥ 0.70 at +50 |
| P3 | PASS | drift ≈ 0 to −0.1 EV |
| P4 | PASS | 4213 sky dL +0.0008 |
| P5 | **FAIL** | 4213 +50 1.107 (needs 1.12); +100 1.227 (needs 1.30); 983 1.125, 1840 1.105, 3437 1.102 (need 1.15) |
| P6 | PASS | 2545 mean 0.96 |
| P7 | PASS | worst 0.041 |
| C1 | PASS | 1.09–1.24 |
| C2 | PASS | ≤ 0.4° |
| C3 | PASS | max 0.63° |
| C4 | PASS | ≤ 0.0005 |
| C5 | PASS | snow +0.0025 |
| C6 | PASS | greys dL 0.0; hue OK after the saturation ease |
| C7 | PASS | band dL 0.0 |
| C8 | PASS | — |
| H1 | **FAIL** | one row: 4213 x800 dark side −0.392 (all other rows ≤ 0.3) |
| H2 | PASS | — |
| H3 | **FAIL** | one row: 3437 trunk dark side +0.572 |
| A1 | PASS | 0.000 in every forbidden box, at both sizes (U10 numbers) |
| A2 | PASS | 0.351 |
| A3 | PASS | distance 0, ratio 1.00 |
| N1 | **FAIL** | 3437 1.05 / 1.12 (needs 1.20); the other four landscapes pass |
| N2 | PASS | near ≤ 0.0015 |
| N3 | **FAIL** | far p1 lift 0.001–0.018 (needs 0.02) |
| N4 | **FAIL** | monotone everywhere; ratio 0.92–0.97 (needs ≤ 0.85) |
| S1 | PASS | — |
| S2 | PASS | max/min 1.08 |
| S3 | PASS | 1.04 |
| S4 | PASS | 1.05 |
| R1 | PASS | ≤ 0.03 |
| R2 | PASS | ≤ 0.10 |
| R3 | PASS | ≤ 0.02 |
| G1–G6 | PASS | — |
| U | **FAIL** | U2 only: ground contrast ×1.11 (needs 1.3); sky chroma ×1.24 passes; ΔE to the clear sky 20.4 → 19.9 passes. U1 and U3–U11 pass. |

## Conflicts I could not resolve (evidence in `build-work/`)

- **P5 / U2 / proof authority versus H1.**
  - The P5 box in 4213 holds 76 % of its detail energy in the meadow, and 89 % of that in strong bright-on-dark edges: the castle walls and the path.
  - Raising those edges' encoded contrast means expanding them against an un-followed pivot. That overshoots the 3.5 EV treeline, which H1 measures.
  - At γ 2.4 with pivot ε 0.5, P5 passed on all four frames, but H1 failed on 4213 (−0.59 / −0.85) and on 3437 (−0.42). The trade is monotone in every setting I tried; see the mini-runs in this lane's history.
- **N3 / N4 versus H3.**
  - N4 needs the far box's OKLab-L std to fall 15 %. That is an inter-surface change.
  - H3 forbids a dark trunk being lifted more than 0.3 EV relative to the meadow beside it.
  - Lift share 0.3 gave N4 0.89–1.00 with H3 3437 +1.14. Lift share 0.12 gives N4 0.92–0.97 with H3 +0.57.
  - A physical forward veil lifts dark objects more than bright ones by construction. H3 as written forbids that next to the trunk.
- **In my opinion** H1 and H3 compare an edge's near side with a "plateau" that, on 3437 and 4213, is a *different surface*. Darkening or lifting by surface level is then indistinguishable from a halo. I did **not** change any threshold.

## Pre-existing tests

- **`Proof/records/detail.dehaze.json`: re-recorded.** I measured it with a temporary dehaze-only probe, because the full class's setUp measures every control and did not finish within an hour in a debug build. The probe has been deleted.
  - authority 96.80 → 9.79
  - meanSeparation 37.05 → 4.97
  - overshootBelow 51.06 → 5.75 (the old crush to below the frame's range)
  - frontLoading 0.44 → 0.58
  - hueRotation 1.365 → 1.381
  - Why it changed: the old algorithm crushed the hazySky ground below its own range, which the spec's P1/P2 forbid.
- **`ControlProofTests` authority floor (68) for dehaze: NOT changed, and it will FAIL** (measured 9.79). I won't lower it. I believe a correct dehaze on hazySky (25–75 % veil) *should* move it strongly. The authority shortfall is the same weakness as U2 and P5.
- **`FieldBaselineProbeTests.testPrintsTheDehazeBaseline`** and **`ScaleHonestyTests`:** unchanged, and both pass on the new code.
- **GPU goldens:** I reasoned about these but could not run them. They are in `LumenPipelineTests/KernelGoldenTests`: `testDehazeDoesNotRotateHue`, `...KeepsPixelsAboveBlack` and `...MaskedAverage`.
  - Hue: the luminance ratio and the OKLab chroma scale at fixed hue keep hue exactly.
  - No negatives: the chroma scale is gamut-safe and the floor is ≥ 0.
  - The masked-average test exercises helpers that still exist.
  - Risk: the "moved > 0.01" assertion on the smooth 32 px frame. The positive effect there is chroma only, and it is small.

## Gates

| Gate | Result |
|---|---|
| `swift build --target LumenCore --target LumenRender` (6.0.3) | Clean: no warnings in the touched files. The VerifiedCopy warnings were there before this change. |
| `swiftc -parse` on all Sources (6.1.2) | Clean. |
| `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` (6.1.2, `/home/user/build61`) | 3055 tests: the 3044 baseline tests plus 11 new. **1 failure, the new U2.** |
| ControlProofTests | No dehaze filter exists. A dehaze-only run fails the authority floor; see above. |
| `check_spec --swift` | `tools/check_spec.py` runs `swift test` with 6.0.3, which cannot build the LumenApp target. `build-work/check61.py` runs the same script unchanged, with only that step swapped to 6.1.2. |

## Files

| File | Change |
|---|---|
| `Sources/LumenCore/Image/DetailEngine.swift` | Dehaze cache; `airlight()` / `transmission()` / `dehazeField()`; the dehaze section: constants, field functions, upsampling, per-pixel functions. File-header sentence updated. |
| `Sources/LumenPipeline/RenderGraph.swift` | `applyDehaze`, plus new `dehazeProxy` and `dehazeNeighbours`. |
| `Sources/LumenPipeline/Kernels.swift` | `dehazeSource` and its doc comment. |
| `BUILDING.md` | The single dehaze-gap bullet replaced by one sentence (G6). |
| `Tests/LumenCoreTests/WS15DehazeSpecTests.swift` | New (U1–U9, U11). |
| `Tests/LumenCoreTests/WS15DehazeAirlightCorpusTests.swift` | New (U10). |
| `Tests/.../Proof/records/detail.dehaze.json` | Re-recorded. |

`RG.channelMinimum` is now unused, and I left it in place. The BasicPanel Dehaze literal is untouched. I have no NEEDS.md items.

## Evidence

12 sheets in `evidence/`, each under 400 KB, with the baseline above the current render:

| Sheet | Shows |
|---|---|
| 01 | 4213 horizon |
| 02 | 1840 treeline |
| 03, 04 | 983 snow peak, snow foreground |
| 05, 06 | 3437 and 4213 negative veil |
| 07 | 6929 wall |
| 08 | 2545 sky and tree |
| 09 | 3437 trunk |
| 10, 11 | 4213 and 2545 sweep sheets |
| 12 | Preview against full size (512 vs 2048→512, ±60) |
