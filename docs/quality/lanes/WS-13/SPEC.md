# WS-13 Display transform (look.render.*): acceptance spec

Base: `84bcd7c` on `quality/ws-13-display-transform`. Audit: `$AUD/AUDIT.md`. Baselines below were measured on that commit.

```
export PATH=/opt/swift/usr/bin:$PATH
AUD=/tmp/claude-0/-home-user-lumen/b9ad9de4-19a6-5447-8139-7f0fbe5d5574/scratchpad/audit
BIN=/home/user/lumen/.build/x86_64-unknown-linux-gnu/release/lumen-render   # swift build -c release --product lumen-render
CHK="python3 $AUD/ws13_checks.py $BIN"        # sections: ramp hue cc bleach skin wheel sky skew black ident
CEV="python3 $AUD/ws13_corpus_ev.py $BIN"     # real-photo medians at given exposures
```

Every synthetic render uses `--no-dither --lut-size 65` and as-shot 6503.7 K / 9.77. Hue is OKLCh, output minus input.
"Curved presets" means Neutral, Soft, Punchy and Film Base. Baseline columns read N / S / P / F in that order.
`ramp` codes are the green channel of a grey patch at scene 0.18·2^EV.

## 1. Density: display mid-grey target 0.18 → 0.25 (curved presets)

| # | Claim | Threshold | Command | Baseline |
|---|---|---|---|---|
| 1.1 | Scene 0.18 → code 137 (0.25 display-linear) on every curved preset | 136…138 | `$CHK ramp`, column `0` | 118 / 118 / 118 / 118 |
| 1.2 | The pivot slope still equals `contrast` | Existing tests pass unchanged (2 % bar, tighter than ±0.05): `EngineTests/testContrastIsTheLogLogSlopeAtMidGrey`, `DisplayTransformShoulderRolloffTests/testThePivotSlopeIsContrastEvenAtTheExtremesOfContrastAndSkew`, `EngineTests/testSkewLeavesTheSlopeAtThePivotAlone`. The 8-bit `slope1/8` column is noise ±0.07 and only informative. | `swift test --filter 'testContrastIsTheLogLogSlopeAtMidGrey\|testThePivotSlopeIsContrast\|testSkewLeavesTheSlope'` | pass. slope1/8 1.470 / 1.150 / 1.877 / 1.569 |
| 1.3 | The anchors still land exactly: −9 EV (black anchor) and +5 EV (white anchor) | Codes 1 and 255 on every curved preset. `tone(anchor) == white` stays asserted in `testTheShoulderRollsOffIntoTheWhiteAnchorAtEveryDisplayPeak`. | `$CHK ramp`, columns `-9` and `+5` | 1 / 255 on all four |
| 1.4 | Toe stays dense at −5 EV | ≤ 14 on N, P and F; ≤ 22 on Soft (its toe is lifted by design: model 20.5) | `$CHK ramp`, column `-5` | 4 / 8 / 1 / 3 (model at 0.25: 11.5 / 20.5 / 4.3 / 9.6) |
| 1.5 | Neutral's shadows stay within the ACR3 shadows. ACR3 at −3/−2/−1 EV is 35.9/67.6/110.8. | Neutral ≤ 40 / 72 / 115 (ACR3 + 4) | `$CHK ramp`, columns `-3 -2 -1` | 20 / 40 / 71 (model 39.2 / 63.0 / 95.2) |
| 1.6 | Monotone on the 1/8-EV ramp from −12 to +8 EV, every preset and at `whiteTarget=400` | `minstep` ≥ 0 on every row. `EngineTests` `firstNonMonotonicX` tests pass. | `$CHK ramp`, column `minstep` | +0.0 on every row |
| 1.7 | Mid-grey stays absolute at every HDR peak | Column `0` = row 1.1 ±1 at `whiteTarget` 200 and 400. Unit: `tone(0.18) == 0.25` at 100/400/1600 %, by updating `EngineTests/testHDRPeakRaisesWhiteButNotMidGrey`. | `$CHK ramp`, rows `whiteTarget=` | 118 at 200 and 400 |
| 1.8 | Linear preset unchanged (identity, clip at peak) | Ramp row byte-identical to baseline; `EngineTests/testLinearPreset*` unchanged | `$CHK ramp` (Linear row) and `$CHK ident` (Linear hash) | row 1/17/41/60/85/118/162/221/248.6/255/255; hash a7804edbac |
| 1.9 | Real photos brighten by about +0.4…+0.5 EV equivalent. The new median at +0.3 must lie between the BASE medians at +0.65 and +0.90. | 6929 91.7…103.9; 2545 119.0…132.4; 983 76.3…86.5; 3437 76.8…88.1 | after: `$CEV $AUD/after_corpus 0.3 6929 2545 983 3437`; base bracket: `$CEV <dir> 0.3,0.65,0.7,0.8,0.9 …` on 84bcd7c | median at +0.3: 75.3 / 103.0 / 63.9 / 64.7 |
| 1.10 | Nothing new clips | `any255` ≤ 0.05 % on all four photos at +0.3 | same command as 1.9 | 0.00 % on all four |

## 2. Highlight shoulder with a lower white anchor (in-lane part only)

Moving the default anchor itself is out of lane (§ Out of lane). `lumen-render` **cannot** isolate an anchor of +3 EV:
- `develop.tone.whites` reaches only +3.5 EV (5 − 1.5·100/100).
- Whites also adds its own tone shelf (`ToneEngine.whiteWeight`). Measured at whites=100: +2 EV → 244, sensor white → 254.8. The model with anchor +3.5 alone gives 232.7.

So this claim is unit-level.

| # | Claim | Threshold | Command | Baseline (model `$AUD/../model/curve.py`, which matches the real ramp within 0.6 code) |
|---|---|---|---|---|
| 2.1 | With `DisplayTransformParams.whiteAnchorEV = 3` (Neutral), sensor white `tone(1.0)` renders near white | encoded ≥ 240/255 | New test `DisplayTransformWS13Tests/testSensorWhiteNearsWhiteWithTheAnchorAtThreeEV` | 243.7 at mid 0.18; 245.1 at mid 0.25 |
| 2.2 | Same params: the shoulder rolls off, so no hard edge | Log-log slope strictly decreasing from +1 EV to the anchor (0.05-EV steps), and < 0.3 at anchor − 0.05 EV. Also add `whiteAnchorEV` 3 and 3.5 cases to `testTheShoulderRollsOffIntoTheWhiteAnchorAtEveryDisplayPeak`. | same test, plus `swift test --filter DisplayTransformShoulderRolloffTests` | model shoulder power clamps to 1.5 (aS 1.20), so it rolls off |

## 3. Blues: the outset undoes the inset rotation

Fix route: the outset fully inverts the inset ROTATION after the curve (AgX-style), and `purityRestore` keeps its meaning for attenuation only. The inset is unchanged.

| # | Claim | Threshold | Command | Baseline |
|---|---|---|---|---|
| 3.1 | Sky probes do not drift: #4A7FC0, CC3 blue sky, hue 240 and hue 270 at C 0.08, −3…+2 EV (where output C ≥ 0.02) | max \|dh\| ≤ 3° on every curved preset | `$CHK hue`, `skies … max` | 9.0 / 9.8 / 7.5 / 14.8 |
| 3.2 | LED blue sRGB(0,0,255) at 0 EV (ACR3 ref +11.6°) | \|dh\| ≤ 15° on every curved preset | `$CHK hue`, `LED@0` | +32.8 / +31.3 / +35.9 / +44.3 |
| 3.3 | Real skies (box mean) at exposure 0, +0.3 and +1 | \|dh\| ≤ 3° for 983 and 1840 on every curved preset | `$CHK sky` | 983 N +8.0/+6.8/+6.4 … F +12.6/+11.6/+11.1. 1840 N +3.4/+8.7/+7.1 … F +7.7/+13.5/+11.6 |
| 3.4 | Reds, oranges, yellows and greens hold: hues 0…150 at C 0.08 and at 75 % max, −3…+1 EV | Each probe ≤ max(5°, its baseline). The baseline is already over 5° for N 150hi 5.4, S 60hi 5.1, P 0hi 6.4 / 150hi 5.6, and F 60/90/150 up to 10.0. | `$CHK hue`, `warm/green per probe` | N 5.4, S 5.1, P 6.4, F 10.0 (worst) |
| 3.5 | The finish-table bars are not touched | `RobustnessTests/testEachTableTracksItsOwnExactEvaluationSeparately` and `EngineIntegrationTests/testTheInteractiveTableAgreesWithTheExportOne` pass with no edit to the tests | `swift test --filter 'testEachTableTracksItsOwnExactEvaluationSeparately\|testTheInteractiveTableAgreesWithTheExportOne'` | pass |

### 3b. Path to white keeps hue (added after WS-05 audit F1/F3: owner's "blue highlights are funky")

The hue-preservation weight is switched off across the shoulder by `shoulderU`, measured on the MAX channel, so a saturated blue renders mostly per-channel and walks +49° through violet and magenta to pink (sRGB blue −2→+3 EV), while pale and cyan skies swing −20…−38° toward cyan on their way to white. Fix route: in the shoulder, bleach toward neutral at constant hue (mix the hue-stable result toward an achromatic value of the same display level) instead of fading into the per-channel branch. Per-channel character stays available below Hue preservation 100.

| # | Claim | Threshold | Command | Baseline |
|---|---|---|---|---|
| 3.6 | Blue probes hold hue all the way to white: sRGB blue (20,30,255), deep sky (40,90,190), azure (30,120,220), mid sky (90,140,200), pale sky, CC blue sky; −2…+3 EV at scene luminance, where output C ≥ 0.02 | max \|dh\| ≤ 5° on presets with huePreservation 100 (N, S, P); ≤ 12° on Film Base (70, per-channel by design) | new test `DisplayTransformWS13Tests/testBluesHoldHueOnTheWayToWhite` (exact `DisplayTransform.apply`, gamut nil and sRGB gamut), and the same probes through `lumen-render` at 65-cube | sRGB blue +49°, deep sky +10.5°, mid sky +6.7° offset (WS-05 AUDIT F1) |
| 3.7 | Full hue ring holds hue: 24 hues at C 0.08 and 75 % max, −2…+3 EV | max \|dh\| ≤ 6° (N, S, P); p95 ≤ 4° | same test, ring section | not measured at base for +3 EV; WS-05 reports radial creases near blue/cyan |
| 3.8 | The roll-off still reaches white: for every probe of 3.6/3.7 output chroma is non-increasing from the bleach onset (+1.5 EV) upward and ≤ 0.02 at the white anchor; output luminance monotone. Amended in round 3: the original "+1 EV" onset bleached sunlit greens a stop early (primaries.gPurity proof authority 39.7 < 44); Adobe keeps chroma until much nearer clip. | as stated | same test | per-channel bleach does this today |
| 3.9 | No hue folds: hue_wheel at exposure 0 and +2, adjacent-pixel OKLab hue jump p99.9 ≤ 2° where C ≥ 0.03 | as stated | `$CHK wheel` (add a hue-jump column) | WS-05 sees radial creases near blue/cyan |

## 4. Saturation: purity restore and attenuation, not a saturation boost

| # | Claim | Threshold | Command | Baseline |
|---|---|---|---|---|
| 4.1 | Neutral ColorChecker mean chroma / truth (C* > 8). The Adobe-Standard-like ref measures 1.21. | 1.05 … 1.20 | `$CHK cc` | 0.920 |
| 4.2 | Preset order kept | CC chroma Soft < Neutral < Punchy | `$CHK cc` | 0.883 < 0.920 < 0.965 (F 0.931) |
| 4.3 | Overexposure still bleaches: 12 hues at 75 % max | Mean and max output C at +4 and +5 EV ≤ baseline + 0.005 per preset | `$CHK bleach` | +4 EV N 0.057/0.108, S 0.068/0.124, P 0.034/0.076, F 0.034/0.077 |
| 4.4 | No gamut ridge on the hue wheel at exposure 0 and +2 | OKLab neighbour Δ p99.9 ≤ 0.006, max ≤ 0.10, every curved preset | `$CHK wheel` | p99.9 0.0036…0.0048; max 0.031…0.079 |
| 4.5 | Skin hue: Monk tones MST 2-9 | max \|dh\| ≤ 4° on N, S and P; ≤ 6° on Film Base | `$CHK skin`, `max\|dh\| MST2-9` | 7.2 / 6.9 / 4.6 / 13.4 |

## 5-7. Skew, black target, identity

| # | Claim | Threshold | Command | Baseline |
|---|---|---|---|---|
| 5.1 | No dead skew range | Each 0.25 step from −1 to +1 changes the −4 EV or the +2 EV code by ≥ 1. Both codes are non-decreasing in skew. | `$CHK skew` | Dead −0.75 → −0.5 (both Δ 0). Codes at −4: 7 → 11; at +2: 203 → 217. |
| 5.2 | Skew 0 is the identity | skew=0 hash equals the default hash | `$CHK skew` | 9ae1d7962d = 9ae1d7962d |
| 6.1 | One black-target range everywhere: `lumen-render keys` (RecipeKeys.swift:311), the RecipeLook.swift:131 comment, the DisplayTransform clamp and LookPanel.swift:1336 | Advertised max == live max | `$CHK black`, `keys` line and the last distinct value | keys 0…15, live 0…9, UI 0…9 |
| 6.2 | No two integer values in the advertised range render identically | `identical-output groups: []` | `$CHK black` | [[9 … 15]] |
| 7.1 | Every default is the identity | Nothing set == Neutral, and each preset bare == the preset plus its own contrast, skew, huePreservation and blackTarget set explicitly (all `OK`) | `$CHK ident` | all OK |
| 7.2 | Presets stay distinct and ordered | 5 distinct hashes; `slope1/2` Soft < Neutral < Punchy | `$CHK ident`; `$CHK ramp` | 5 of 5; 1.133 < 1.404 < 1.866 |

## 8. Gates

| # | Claim | Command | Baseline |
|---|---|---|---|
| 8.1 | Build clean, no new warnings in touched files | `swift build --target LumenCore --target LumenRender` | clean |
| 8.2 | Linux suite green with Swift 6.1.2 | `export PATH=/opt/swift612/usr/bin:$PATH; swift test --parallel --scratch-path .build612 --filter LumenCoreTests --skip ControlProofTests` | 3044 / 3044 pass |
| 8.3 | Tests that encode the old 0.18 display mid-grey are changed in the same commit, each named in REPORT.md with the reason. Expected: `EngineTests/testHDRPeakRaisesWhiteButNotMidGrey`, `DisplayTransformShoulderRolloffTests/testTheSDRPresetsKeepTheirShape`, `EngineIntegrationTests/testEveryStockAnchorsMidGrey`, `CurveHDRAxisTests`, `FilmLabHDRMidGreyTests`. | `grep` the diff | n/a |
| 8.4 | ControlProofTests records re-recorded only for this change | `LUMEN_RECORD_PROOFS=1 swift test -c release --filter ControlProofTests/testTheCommittedRecordsStillDescribeWhatTheEngineDoes`, then `git diff --stat Tests/LumenCoreTests/Proof/records`, then `swift test -c release --filter ControlProofTests` without the variable passes. Every record renders through this transform, so expect most of them to move. REPORT lists them, and `render.*` dead steps may only shrink, and a shrink (6.2) is declared in ProofRegistry. | records committed at 84bcd7c |

## Visual claims (human judges, `evidence/`, `--long-edge 1024`)

- **V1** `evidence/983_1840_sky_before_after.png`: base vs after at +0.3, Neutral, with `$AUD/corpus/{983,1840}_adobe_ref+0.3.png` beside them. The skies read blue, not slate or lavender. Snow and the lantern are brighter, and nothing is clipped.
- **V2** `evidence/6929_2545_density.png`: base, after and Adobe ref at +0.3. The after density sits between base and the ref. The shadows stay dense, not milky or lifted-flat.
- **V3** `evidence/presets_colorchecker_huewheel.png`: the four curved presets on the ColorChecker and the hue wheel at 0 and +4 EV. Saturation is visibly ordered Soft < Neutral < Punchy. There is no ridge or banding at the gamut edge, and +4 EV bleaches toward white with no pastel wash.

## Out of lane (goes in NEEDS.md, not code)

- **WS-05 `ToneEngine.defaultWhiteAnchorEV = 5`.** At an anchor of +5, real RAWs never reach 255.

  Modelled with mid 0.25:

  | Anchor | Sensor white (+2.47 EV) | +1 EV | +2 EV |
  |---|---|---|---|
  | +5 | 224.8 | 179.4 | 212.4 |
  | +3.5 | 235.4 | 181.9 | 220.5 |
  | +3.0 | 245.1 | 185.3 | 229.2 |

  With mid 0.18, sensor white is 221.6 / 232.7 / 243.7. An anchor of +3.0 is the one that matches ACR3, which reaches 254 at +2.375 EV. Whites ±100 then spans +1.5…+4.5 EV.
- **WS-04/WS-17 decode baseline exposure.** About 0.4 EV of the 0.86 EV gap is left after line 1.1. It belongs to the decode or exposure baseline, not to the curve.
- **WS-12 finish domain.** Needed only if § 3 cannot hold 3.5 without the rotation's sign change (commit 9e6f717).
- **Auto exposure.** Auto reads `transform.tone` (ToneEngine.swift:1032). A brighter mid-grey changes what Auto proposes, so its owner re-checks its targets.
- **`docs/quality/controls.md`.** Its blackTarget range line is outside the lane folder.
- **Tooling.** `lumen-render sweep --key look.render.preset` refuses string values.
