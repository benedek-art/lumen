# WS-38 verification (independent verifier, round 2 diff c87a4ea..d4b801a)

## Verdict: FAIL

Every spec line except the three known open items (S37, S38, S39) passes when I re-measure it from a fresh cache. The default renders look like their stocks. The fail has two causes:

1. **A new visual regression at a legal setting.** On every colour negative, Film Exposure −2 combined with Push +1.5…+2 floods the shadows with a saturated green-teal. The red channel sits at 0, and the shadows get BRIGHTER as Film Exposure goes down. The base commit rendered the same settings as a dark, near-neutral muddy black. None of the spec lines catch this: S35 checks monotonicity against scene EV, and S23 is Tri-X only.
2. **The finish-LUT accuracy at the size the app actually previews with (33³) got worse, and not only for Velvia.** At 33³, Ektar measures p99 3.51 / max 7.65 and Velvia p99 3.94 / max 8.86, against neutral's 1.73 / 3.03. At baseline Velvia was p99 2.41. NEEDS.md documents this, but the lead's accepted open item names only Velvia. Until the NEEDS.md table change lands, Ektar's preview differs from its export by up to ~7.6 ΔE.

## Rebuild and tests

- `swift build --target LumenCore --target LumenRender`: clean. I forced a FilmLab.swift recompile and got no warnings in the changed files. The only warnings are in VerifiedCopy.swift, which predates this diff.
- `swift build -c release --product lumen-render`: OK.
- `swift test --skip-build --parallel --filter LumenCoreTests --skip ControlProofTests`: **3057 tests, 0 failures**. That is the base's 3044 plus the new FilmStockLookTests.
- `python3 scripts/gen-fixtures.py --check`: enginemath.json matches the committed fixture (3486 values), and all Linux checks pass.
- `scripts/check-swift-surface.py`: exit 1 on base and on HEAD alike, so this is pre-existing. HEAD adds one new flag: `XCTAssert` in FilmStockLookTests.swift:115,117,214 is "declared nowhere". It is a real XCTest symbol, but this is the first file to use bare `XCTAssert(`, so CI's surface step lists one more item.
- ControlProofTests (film specs): see the final report. These run serially in a debug build, and the run was still in progress when this file was written.

## Spec lines (fresh `measure.py --work <new dir>`)

| ID | Verdict | Measured |
|---|---|---|
| S1 | PASS | max \|Δ\| 0.40 (Velvia) |
| S2 | PASS | P 1.19, G 1.39, E 1.51, T 1.44, V 1.79, C 1.26 |
| S3 | PASS | order holds |
| S4 | PASS | P 4.29, G 3.64, E 3.52, T 3.54, V 2.23, C 4.21 |
| S5 | PASS | max rise 1.9 (Cine); 255 only past the shoulder |
| S6 | PASS (amended) | P [−1.7, +3.3], C [0, +5.2]; V up to +38.6, T +16.4 (no 255 clipping on photos) |
| S7 | PASS | P [+1.0, +3.7], C [−1, +1], E [−3.9, 0] |
| S8 | PASS | P 3.0/2.8, others ≤ 2.0 |
| S9 | PASS | worst 0.22% (Cine); Velvia ramp 0% |
| S10 | PASS | P 2, E 1, V 3, T 0 |
| S11 | PASS (amended, tighter) | Gold R−B [0, +7], hi +5.6; Cine B−R +5.5 / R−B +4.8; Portra [0, +4], hi +2.6 |
| S12 | PASS (amended) | P 0.99, G 1.10, E 1.25, V 1.29, C 0.94 |
| S13 | PASS (amended) | photos V 1.49 > E 1.39 > G 1.26 > P 1.09 > C 0.99 |
| S14 | PASS (amended, tighter) | P 1.09, G 1.26, E 1.39, V 1.49, C 0.99 |
| S15 | PASS (amended) | P 1.29, G 1.39, C 1.20, E 1.76, V 1.78 |
| S16 | PASS | C ratio 1.06–1.18, Δh −3.4…+2.9, ΔL ≤ 0.019 |
| S17 | PASS | all inside the bands |
| S18 | PASS | V +2.5…+7.3 (violet), others in band |
| S19 | PASS | max Δh ≤ 8.8 |
| S20 | PASS | 0% clipped on every stock; p5 min ≥ 29 |
| S21 | PASS | Δh p90 ≤ 7.2; over-range luminance ratio 0.98–1.00 |
| S22 | PASS | blue +22, purplish blue +20, sky +8.7, red −4.9, green −10.8, yellow −7.0 |
| S23 | PASS | worst 1 code |
| S24 | PASS (amended) | lemon − dish 36.4 (neutral 36.9); tomato 37.0 vs 46.7 (0.79) |
| S25 | PASS | 0 codes over 24 renders |
| S26 | PASS (amended) | frac50 0.46–0.61 (Cine 0.61 with tol 0.21) |
| S27 | PASS | \|shift\| ≤ 0.01 EV |
| S28 | PASS | chroma ratio 0.67–0.71 |
| S29 | PASS | slope ratio 0.70–0.81, cast +1.3…+5.0 |
| S30 | PASS | max error 0.14 EV |
| S31 | PASS | ×0.75–0.78 / ×1.23–1.26 / ×1.49–1.53 |
| S32 | PASS | +1: ≥ +1.08, +2: ≥ +1.60, pull ≤ −0.67 |
| S33 | PASS (amended) | ev250 drops 1.4–1.7 EV at push +2 |
| S34 | PASS | 0 / 0 codes |
| S35 | PASS | 0 of 126 |
| S36 | PASS | all ok |
| S37 | FAIL (known) | 65³: Velvia max 4.9 (p99 1.04); Ektar 1.85/3.8. At 33³ (today's preview): Ektar 3.51/7.65, Velvia 3.94/8.86, Portra 1.56/4.23 |
| S38 | FAIL (known) | vs neutral: Portra 1.54, Cine 1.8 |
| S39 | FAIL (known) | vs neutral: Cine 1.57, Portra 1.9, Gold 2.0; pair Ektar–Velvia 1.69 |

36 of 39 pass.

## Amendments: justified or moving the goalposts?

- **S6, upper bound dropped for the contrasty stocks.** Justified. More contrast at grey necessarily raises p99.9, and no photo clips to 255. The guard against grey whites stays.
- **S11, Portra added.** This tightens the spec. Fine.
- **S12, chart bands lowered (Velvia 1.35 → 1.22 floor).** Partly goalpost-moving. The gamut argument is real: the chart patches sit near the sRGB edge. The amendment is acceptable only because S14 was tightened in the same round and saturation is now gated on photos.
- **S13.** Mixed. The chart gaps were relaxed (0.05 → 0.03) and the Ektar–Gold photo gap was raised (0.08). Acceptable.
- **S14.** Tighter and higher bands. Not goalpost-moving.
- **S15, 1.40 → 1.80 for Ektar and Velvia.** Goalpost-moving: the new limit sits just above the measured 1.76 / 1.78. This line existed to stop a vibrance curve, and Velvia does behave like one on muted colours. With chroma gain 3.4, a cream cake turns olive-yellow (2062; `brk/crop_2062_cake.png`). The gamut argument explains the spread on the chart, but it does not show that the gain on muted colours is right. A human should judge whether Velvia's muted-colour boost is too strong.
- **S24, separation ≥ neutral − 2.** Physically justified: panchromatic film renders yellow darker relative to cyan-green. Note that Tri-X's "rich tonality" is no longer above neutral (36.4 vs 36.9), and the tomatoes sit at 0.79 of neutral.
- **S26, quantisation tolerance.** Justified: Cine's ΔE100 is only 1.18.
- **S33, metric changed to EV of code 250.** Justified. At push +2 the old window lies in the shoulder, and white arrives 1.4–1.7 EV sooner, which is a large and real effect.
- **S37, film measured at 65³.** Goalpost-moving with respect to what ships today. Interactive preview is 33³, and there Ektar and Velvia regressed well past baseline (see above). It is honest only once NEEDS.md lands, and even at 65³ Velvia still fails.
- **S38 and S39.** Relaxed, and they still fail for Portra and Cine. Known.

## Visual judgement (100% crops in the scratch `brk/` folder; measure sheets in `m/`)

- **Portra.** Warm-neutral and gentle, with clean whites and good skin across MST 1–10. Shadows are slightly lifted and warm (p1 up to +3.7). Pleasant.
- **Gold.** Golden-warm, with golden skin. Foliage goes slightly olive. Reads as Gold.
- **Ektar.** Punchy reds, a deep slightly cyan sky, dense shadows. Recognisable. On 6929 the foliage is darker and more olive than I would expect from Ektar.
- **Velvia.** Dense, very saturated, emerald greens, violet blues. The 983 sky is violet-blue, as authored. The dark blue cloth on 4694 goes violet, which is strong but on-brief. Muted creams and yellows go yellow-olive (2062).
- **Tri-X.** Neutral, with a lighter sky and darker reds. Tonality is fine but not richer than neutral.
- **Cine 250D.** Teal shadows and warm skin. Very close to neutral otherwise (S38/S39).
- **Highlights** roll off on all six. No hard clip, no NaN, no black holes on 9 corpus photos. On every stock × photo, the share of pixels with |Δh| > 30° is 0.
- **Exposure and push sheets on 2545.** These read like a lab: brightness is stable and push adds contrast.

## Break tests

- **The regression.** Film Exposure −2 + Push +2 (and −2/+1.5, −1.5/+2) on Portra, Ektar, Gold and Cine produces green-teal shadows with R = 0. The 1192 wall region, Portra at push +2:

  | Film Exposure | 0 | −1 | −1.5 | −2 |
  |---|---|---|---|---|
  | RGB | (3.7, 3.3, 2.5) | (4.2, 5.0, 3.1) | (0.2, 14.7, 5.5) | **(0, 34.6, 17.9)** |

  On grey_ramp, max \|R−B\| = 39 codes and \|G−(R+B)/2\| = 22. 80% of 1192 pixels have a channel at 0, against 1.2% for neutral. The base commit gives (5.9, 6.9, 4.4) here.

  Images:
  - `scratchpad/verify/brk/ext_1192_portra400.png` (top-right tile)
  - `scratchpad/verify/brk/corner_3582_portra.png` (bottom-left and right tiles: the window turns teal)
- **Neighbouring controls** behave sensibly:
  - exposure ±3, contrast ±100 and look.render.contrast 0.1/10: no clipping.
  - saturation −100 and B&W with Gold: neutral within 2 codes.
  - white 400 and black 15: the film picture is unchanged, by design (paper white = SDR white).
  - WB 2000 K: Ektar puts 45% of pixels on the gamut boundary vs neutral's 16%. This is a heavily blue frame mapped to the boundary, so it looks acceptable.
- **Fine sweeps** (0.1 steps; Film Exposure on xramp and hue_wheel, push at Film Exposure 0 and −2):
  - Max adjacent mean change ≤ 1.4 codes, with no jumps on the ramp.
  - The Velvia wheel has a 67-code per-pixel step, but that is a gamut crease moving with exposure. Neutral at +2 EV has the same creases.
- **Amount** 0/1/2/5/10/25/50/75/90/99/100: mean |Δ| rises strictly and near-linearly on Ektar, Velvia and Portra.
- **GPU path.** RenderGraph and Kernels hold no film tone constants. They read `halation(longEdgePixels:)`, `grainAmount`, `grainDMax` (`printCurve.dMax`, unchanged values) and the baked finish LUT. Nothing needed updating.
- **LookPanel.** The push slider takes `stock?.push.range` for both its range and its clamp. That reads correctly, and the surface check reports nothing for LookPanel. Minor: a stored push of +2 on Velvia, carried over from another stock, renders as +1 (the engine clamps) while the stored value stays 2.

## Scope

- The engine changes stay inside FilmLab.swift: FilmCharacteristic, FilmCrossover, FilmStock, the new FilmColor and FilmPushResponse, and the FilmChain build, solve and render.
- The LookPanel change is in `filmLabRows` only. RenderPlan is untouched.
- **Halation (WS-39).** No semantic change: the strengths are unchanged and only the proof-record numbers were refreshed.
- **Grain (WS-40).** Two side effects, neither a change to the grain code:
  - The density-grain injection inside the old `render` was dead code (it was always passed zero), and it is gone.
  - Velvia's push is now clamped to +1, so its grain push scaling is clamped too.
- **Proof-registry floors** were lowered per stock (Portra strength 59 → 8, film.exposure 130 → 53), and a declared reversal was added for film.exposure. Each change is explained in place. This loosens existing proof tests; the reasons given are consistent with the rebuild, but a reviewer should know.
