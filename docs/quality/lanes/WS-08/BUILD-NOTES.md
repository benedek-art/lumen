# WS-08 build notes

Builder passes on base `c170432`. Round 1 is commit a859f9b and round 2 is f7137b5, which follows the lead's
design change and the SPEC amendments marked "Amended by lead, round 2". Round 2b is the commit on top of those.
It makes feasible touched pairs exact, replaces the conflict soft knee with a continuous cap at the span's capacity,
and applies the Z1.10 amendments marked "round 2b". All numbers are Linux, CPU
reference, release build. `core-tests` = `bash /tmp/claude-0/bin/core-tests.sh LumenCoreTests.<Class>`.

## What changed

- **`ToneEngine` (`zonePanelStops`, `zoneAxis`, `appliedZoneEV`, `zoneEase`, `zoneSlopeFloor`).** The crossfade
  kernel (`ZoneWeights`, which is shared) is untouched. The five numbers it blends are the *applied* zone EVs.
  - **Seam limit.** `L_i = 0.75 · 2 · gap_i / π`, with the gap measured in EV; this is 0.955 EV at the default
    pivots. A drop of at most `L_i` keeps the raised-cosine response at a slope of at least 0.25.
  - **Spill (round 2).** A touched zone is delivered exactly at its own pivot. Each untouched zone takes the value
    nearest 0 inside two bounds:
    - at least (the zone below it − L), chained back to the nearest touched zone;
    - at most (the zone above it + L), chained forward to the nearest touched zone.

    So the downhill neighbour of a zone that asks too much moves by exactly the excess, and that continues
    outward. Darks +3 gives Shadows +2.045, Midtones +1.090 and Lights +0.135. Brights −3 is the mirror. An
    untouched zone that no excess reaches stays at 0.
  - **Conflicts (round 2b).** A span between consecutive touched zones is left exactly as asked while its drop fits
    its capacity, the sum of its seams' limits. Only an infeasible span is scaled, and only down to exactly that
    capacity, so the applied value is continuous through the transition. No soft knee is used: a knee would either
    start below the capacity, holding back spans that fit, or end above it, breaking the floor. The scaling works
    like this:
    - a span pulled from both ends shares one scale;
    - otherwise a positive run is settled right to left and a negative run left to right.

    The untouched zones inside the span are then filled by the spill rule above.
  - **Axis.** The register sits on the default anchors' −9 … +5 EV (`zoneAxis`). `normalizedAxis` still uses the
    live anchors for its other callers.
- **`Zones` / `ZoneAdjust`.**
  - `minimumPivotGap` is now 1/14 and public.
  - New `movingPivot(_:to:in:)`, the drag clamp the panel uses.
  - `ZoneAdjust` keeps only `ev`; recipes with the old keys still decode.
- **`AppliedReadout`.** `ZoneEased` now carries `carriedFrom` / `conflictsWith`, and its caption says what happened:
  - "+2.05 EV carried from Darks" on a spilled-into row;
  - "Applied +0.95 of +3.00 EV (conflicts with Midtones)" on a scaled row.
  - `zoneFlattening` places its band with `zoneAxis`.
- **`ZonesPanel.swift`.** Each row that moved gets a caption under it. `movePivot` uses `Zones.movingPivot`, and
  the pivot's VoiceOver value is in EV. The header and caption comments are updated for the spill rule.
- **Recipe surface.** The `develop.zones.*.sat|falloff|wheel.*` rows are removed from `RecipeKeys.swift`. The three
  keys are dropped from `gen-fixtures.py` and `default-recipe.json`.
- **Tests.**
  - `ZonesResponseTests` (round 2 adds `testALoneZoneSpillsItsExcessIntoItsNeighbours` and
    `testAConflictIsEasedAndKeepsTheFloor`).
  - Updated: `ZoneFlatteningTests`, `ToneTwinClampTests`, `AppliedReadoutTests`, `ProofRegistry.zones` and its 10
    records, `RobustnessTests`, `RecipeCodecToleranceTests`, `ResetSemanticsTests`, `SavedLookTests` and
    `RawDenoiseRecipeTests`.
  - Two snapshot cases are appended at the end of `PanelSnapshotTests.renderPanels`.
  - The `LayoutMetricSupport.swift` citations are updated, and `check-citations.py` reports only the base's
    unlanded set. Base had ZonesPanel.swift:85, a comment citation; it is :90 now, the same comment.
- **Evidence (12 files, each < 400 KB) and the tool `tools/ramp_ev_kink.py`.**

## Per spec line (SPEC as amended in round 2)

| line | status | what / measured |
|---|---|---|
| Z1.1 | PASS | `testMonotoneWithATextureFloor` over G5 (6250) and G3 (243 × 56 pivot sets, including a legacy 0.28 EV gap). Spilled seams run at exactly the floor, so the slowest slope is 0.25 within the 1e-9 tolerance (base −1.36). |
| Z1.2 | PASS | `testNoSlopeBreakAnywhere`. The largest one-sided jump is under 0.01; round 1 measured 0.0036. Spill only changes the five values the C¹ crossfade blends. |
| Z1.3 | PASS | `testNoOvershootAndPeaksAtThePivot`. `testMovingAPivotMovesWhereTheZoneActs` and `testTheGlobalZoneTrimIsFlat` are unchanged. `testEachZoneMovesItsOwnPivotAndNoOther` keeps +1 EV and its exact own-pivot assertion, and now expects the next pivot up to carry 1 − L = 0.045 EV (amended). |
| Z1.4 | PASS | `testSmallMovesAreExact`: for \|ev\| ≤ 0.75, `appliedZoneEV == ev` bit-exactly, the own pivot is within 1e-9 and the other pivots are 0. |
| Z1.5 | PASS | `testSmallMovesMatchTodaysResponse`: the max deviation is 0, because it is the same kernel and nothing spills below 0.955. |
| Z1.6 (amended: no dead range) | PASS | `testTheEaseNeverGoesDead`: for each zone alone, −3…+3 in 0.25 steps, d(y at own pivot)/d(slider) is 1.000 (≥ 0.99), and applied = requested to 1e-12. |
| Z1.6b (new) | PASS | `testALoneZoneSpillsItsExcessIntoItsNeighbours`: Darks +3 gives pivots 3.000 / 2.045 / 1.090 / 0.135 / 0 (± 0.01; the values ± 0.001). The Brights −3 mirror also holds. |
| Z1.7 (amended) | PASS; panel [macOS-CI] pending | `testTheEaseIsReported` and `AppliedReadoutTests.testAnEasedZoneIsNamedWithTheAmountTheRenderApplies`. Darks +3 gives entries for Shadows, Midtones and Lights: "+2.05 / +1.09 / +0.14 EV carried from Darks". Darks +3 with Mid −3 gives "Applied +0.95 of +3.00 EV (conflicts with Midtones)" and "Applied −0.95 of −3.00 EV (conflicts with Darks)". |
| Z1.8 (amended 2b) | PASS | `testEasingIsLocal`: Darks +3 with Lights +0.5 delivers Darks 3 (± 1e-12) and Lights 0.5, with no conflict entry; round 2 applied 2.96 there. With Mid −3 and Brights +1, Brights stays 1 and Mid −3 is delivered. `testTheConflictCapIsContinuousAndMonotone` sweeps Darks 0…3 in 0.01 steps, against Lights +0.5 (capacity 2.865) and against Midtones −1 (capacity 1.910). Darks is exact while the span is feasible and the span's drop equals the capacity (± 1e-9) after. No step exceeds 0.01 and Darks never falls. Past the capacity, a same-sign span holds Darks at Lights + 2.865, because the other request is honoured. |
| Z1.8b (new) | PASS | `testAConflictIsEasedAndKeepsTheFloor`: Darks +3 / Mid −3 apply +0.954 / −0.954, Shadows stays at 0 between them, and slope ≥ 0.25. |
| Z1.9 | PASS | `testTheClampNeverFiresOnAZonesOnlyRecipe`: nil for all 6250 G5 recipes. |
| Z1.10 (amended 2b) | PASS on falling seams, flatness and minSlope; one rising-seam reading at noise level | See the table below. |
| Z1.11 | PASS (code review); [macOS-CI] pending | Nothing under `Sources/LumenPipeline` or the kernel registry changed. `RR.applyTone:242` reads `plan.toneGainLUT`, and `RG.applyTone:897` reads `plan.toneGainCubeBaked`, which `RenderPlan` bakes from the same table. No pipeline test pins a zone value. |
| Z1.12 | DONE | See "Tests changed". |
| Z2.1 | PASS | Default pivots are unchanged, and `AccuracyProbeTests` passes. |
| Z2.2 | human | Pivots were not moved. |
| Z3.1 | PASS | `testWhitesAndBlacksDoNotMoveTheZones`: within 1e-12, and the peak moves 0.000 EV (base ±0.96 / ±0.54). The `AppliedReadoutTests` placement test is inverted. |
| Z4.1, Z4.2 | PASS | `testPivotDragKeepsAOneStopGap` and `testDecodedRepairUsesTheOneStopGap`. G3 includes a legacy 0.28 EV gap. |
| Z5.1 | PASS | `cmp` of base and round-2 `render` on grey_ramp, colorchecker, 6929, 2545 and R5 4694 at Darks 0: all byte-identical. `testMovingOnlyPivotsChangesNothing` passes. |
| Z7.1 | PASS | `lumen-render keys \| grep -c 'zones.*\(sat\|falloff\|wheel\)'` = 0. |
| Z7.2 | PASS | `testLegacyZoneFieldsDecodeAndRenderIdentically`. |
| Z7.3 | PASS | `CanonicalJSONTests`, the fingerprint fixtures and `RawDenoiseRecipeTests`' sparse canonical JSON and fingerprints are unchanged, and `gen-fixtures.py --check` passes. Only the FULL-tree digest pin moved; see below. |
| Z7.4 | DONE | `ResetSemanticsTests`, `SavedLookTests` and `RecipeCodecToleranceTests` drop the dead arguments. |
| Z8.1, V1, V2 | [macOS-CI] pending | `panel-develop-zones-default` and `panel-develop-zones-darks3-pivot`. In the second, the Shadows, Midtones and Lights rows show their carried amounts, and Darks shows none because it is delivered. |
| V3 | human | `evidence/r5-darks-after-crop100.png` uses the audit's crop located by template match (RMS 0). At Darks +3, delivered in full, the shadows lift a lot and the lemon-peel and potato texture survive, with no flat patches outlined by the mask. |

## Z1.10 (amended, round 2b)

Re-measured on the round-2b build: `ramp_check.py` → `/tmp/claude-0/ws08-after`, then `ramp_ev_kink.py` on that
directory and on the base renders.

| recipe | minSlope (≥ 0.10) | kinkFall (≤ 0.5) | kinkRise | base kinkRise |
|---|---|---|---|---|
| Darks +3 | 0.21 | 0.26 | 0.05 | 0.05 |
| Darks +1.25 | 0.19 | 0.33 | 0.12 | 0.12 |
| Mid −3 | 0.15 | 0.32 | 1.16 | 2.43 |
| Mid +3 | 0.18 | 0.30 | 1.12 | 1.12 |
| Lights −3 | 0.17 | 0.31 | 0.77 | 1.81 |
| Shadows +3 | 0.15 | 0.27 | 1.52 | 1.52 |
| Brights −3 | 0.18 | 0.31 | **0.06** | 0.00 |
| Darks +3 & Mid −3 | 0.21 | 0.33 | 0.27 | 1.92 |
| Sh +3 / Mid −3 / Li +3 | 0.23 | 0.29 | 0.94 | 4.39 |

- kinkFall ≤ 0.5 passes on all 9 recipes; the worst is 0.33 (base up to 0.94).
- kinkRise is at or below base on 8 of 9.
- Brights −3 reads 0.06 against a base of 0.00. It has no rising seam at all: every zone value is ≤ 0 and falls
  toward Brights, so analytically du/dt ≤ 1 everywhere. The measured maxSlope of 1.18 there, and Darks +3's 0.05 in
  both builds, are noise in the inverted render: dither and the mask, in windows where du/dt barely exceeds 1. I
  record it as noise, not as a fail. The lead or verifier may judge it otherwise.
- EV-domain flatness: minSlope ≥ 0.15 on every recipe, so there is no flat run at slope < 0.10.
- `ramp_check.py`'s display-code flatEV is 0.00 on 8 recipes and 0.24 on Mid −3. Per the amendment this is a
  display-toe effect: the spilled seams run at the 0.25 floor, under 1 code/EV in the toe.

## Z1.10 after the spill (round 2 analysis, kept for the record)

The spill delivers the whole request, so a zone at ±3 has a seam rising by 3 EV over a 2 EV gap on its uphill side.
Two things follow.

- **maxKinkEV on those 5 recipes is the base's own number, not something the spill added.** The uphill seam is
  untouched by the ease, and the base measured mid−3 2.59, mid+3 1.12, light−3 2.10 and shadow+3 1.52 on this same
  tool. For any C¹ kernel, raising 3 EV over 2 EV means the slope has to climb to about 2.5 or more and come back
  down, so the analytic slope change is at least about 0.3 per 0.1 EV. The raised cosine gives 0.37; the pipeline
  measures more.
  - Under round 1 this passed, because the request itself was cut to 0.95 EV.
  - Either the threshold applies only to the ease (falling) side, or a lone ±3 zone must not be delivered in full.
    The lead decides.
- **flatEV for Mid −3 (0.24 EV).** Mid −3 spills down to Shadows −2.05 and Darks −1.09, so its two seams below
  mid-grey run at exactly the 0.25 floor. In the display toe a quarter stop per stop is under 1 code/EV, which is
  what `ramp_check.py` counts as flat. In the EV domain the same stretch measures slope ≥ 0.15.
  - A spill that ran at a higher floor than the 0.25 slope floor would clear it: for example, moving the neighbour
    by `drop − L(0.4)`. That puts more lift into the neighbours than the lead's exact-excess rule, so I have not
    done it without a decision.

## Tests changed, and why

- **`RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther`.** It is back at +1 EV, the base value, with the
  exact own-pivot assertion unchanged. It now expects the next pivot up the axis to carry 1 − L = 0.045 EV and every
  other pivot 0. That is what the spill rule makes true; Brights has no pivot above it and carries nothing. Round 1
  had lowered the value to 0.75; that change is reverted.
- **`RecipeCodecToleranceTests`.**
  - The Mid +1.0 → `zonePanelStops(0) = 1.0` case is restored to base, because spill delivers it exactly.
  - Still changed: a short `wheel` decodes to the default `ZoneAdjust()` (the key is removed), and the
    touching-pivot repair expects `0.3 + minimumPivotGap` instead of 0.32 (Z4.2).
  - The `zone()` helper drops the dead arguments.
- **`ZoneFlatteningTests`.**
  - Darks +2 and +4 alone now assert nil, which is the fix.
  - The measurement uses Contrast −100 + Darks +3, which now flattens −3.179 … +2.217 EV, worst 0.402. The spilled
    curve runs at the floor over a wider span, and contrast −100 takes it below 0. That is the backstop's job; see
    NEEDS.
  - `testTheReportedBandIsFlatInTheBakedTable` uses Contrast −100 + Darks +0.95. At +3 the clamp fires in two
    places and the report merges them into one span (audit Z-10, WS-07's), which is not flat end to end.
- **`ToneTwinClampTests`.** It uses Contrast −100 + Darks +3, with the in-band probe at −2.5 EV. Its assertions are
  unchanged and are WS-07's.
- **`AppliedReadoutTests`.**
  - Untouched cases: nothing at Darks +0.75, and no flattening for Darks +4 alone.
  - The eased-zone test asserts the three carried rows and the conflict caption.
  - The clamped-band caption becomes "−3.18…+2.22 EV" and "0.40 EV".
  - The placement test is inverted (Z3).
  - The mark grows with Contrast.
  - The panel scan also pins the easing call and its caption.
- **`RawDenoiseRecipeTests.defaultFullTreeDigest`.** It changes from 68b478a3b73cfdea to 7121a0e06775a66f. The full
  default tree is `default-recipe.json`, which Z7.3 changes on purpose; the sparse canonical JSON and both
  fingerprints in the same test are unchanged.
- **`ProofRegistry.zones` and records.** Re-measured, with floors at 70 %:

  | control | base authority | round 2 authority | floor |
  |---|---|---|---|
  | dark | 75.52 | 87.80 | 61 |
  | shadow | 163.97 | 174.99 | 122 |
  | mid | 194.19 | 214.17 | 149 |
  | light | 129.34 | 192.68 | 134 |
  | bright | 43.23 | 110.16 | 77 |
  | global | 215.25 | 215.25 | 150 |

  - Brights is no longer near-dead on the ramp, because Brights −3 now pulls Lights and Midtones down.
  - `alternatingZones` goes from ±2 to ±0.375: five touched zones 4 EV apart would be a conflict and get eased.
  - Pivot travels are now inside neighbours ± 1/14. Authorities and floors: 2.04 / 24.21 / 23.76 / 19.90 / 12.42 (round 2b; the cap replacing the knee moved pivots 1–3 by ≤ 0.2, because a pivot dragged within ~1 EV of a neighbour shrinks that seam below the 0.75 EV companion step),
    floors 1 / 16 / 16 / 13 / 8.
  - The Light pivot's `declaredReversal` becomes nil (givenBack 0).

## Test runs

- Targeted: ZonesResponseTests, ZoneFlatteningTests, ToneTwinClampTests, AppliedReadoutTests,
  EngineLimitReadoutTests, RecipeCodecToleranceTests and RobustnessTests: green after round 2.
- Full LumenCoreTests (release, round 2b): 3076 tests, 6 skipped, **0 failures**, after re-recording the three
  pivot records the cap moved. Round 2 had 3075 tests and 0 failures.
- Full LumenCoreTests (release, round 2): 3075 tests, 6 skipped, **0 failures**; the base had 3058 tests and 0
  failures. Z1.1 printed a slowest slope of 0.2500008 and Z1.2 a largest slope break of 0.0036.
  `swift build --target LumenCore --target LumenRender` is clean.
  `check-swift-surface.py`, `gen-fixtures.py --check` and `check-citations.py` report base-equivalent results.

## For the verifier

- The sweep sheets are palettised to 256 colours to stay under 400 KB, so banding in the skies is the palette.
  Judge texture from `r5-darks-after-crop100.png`.
- What a photographer sees now: every zone does what its slider says at its own pivot across the whole ±3, and the
  rows it carries say "carried from …". Only two touched zones that cannot both be honoured are held back, and both
  rows say so.
