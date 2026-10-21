# WS-08 build notes

Builder pass on `quality/ws-02-08-pickers-zones` (base `c170432`). All numbers are Linux, CPU reference, release
build. `core-tests` = `bash /tmp/claude-0/bin/core-tests.sh LumenCoreTests.<Class>`.

## What changed

- **`ToneEngine` (`zonePanelStops`, new `zoneAxis`, `appliedZoneEV`, `easedZoneEV`, `zoneSlopeFloor`).**
  - The crossfade kernel is untouched (`ZoneWeights` is shared). The five numbers it blends are now the *applied*
    zone EVs.
  - A seam between pivots i and i+1 may fall by at most `limit = 0.75 · 2 · gap / π`, the gap measured in EV. That is
    0.955 EV at the default gaps, where the raised cosine's steepest slope reaches −0.75, so the response runs at
    0.25 stops per stop.
  - A larger drop is eased with `Num.softKnee`, using the same 0.8 knee `easedScale` uses. Below the knee it is
    exact; above it, it approaches the limit and never reaches it.
  - Only the zone that pulls a seam downhill is scaled, toward zero. A positive zone pulls its right seam down, a
    negative zone its left seam.
  - Order of solving:
    1. mixed-sign seams first, with one shared scale;
    2. positive runs, right to left;
    3. negative runs, left to right.

    Each seam is solved against its neighbour's applied value. There are no cycles, because each zone is the
    pulling end of at most one seam.
  - The axis is the default anchors' −9 … +5 EV, through `ToneEngine.zoneAxis`. `normalizedAxis` keeps its
    live-anchor meaning for its other callers.
- **`Zones` / `ZoneAdjust` (Recipe.swift).**
  - `minimumPivotGap = 1/14`, now public.
  - New `movingPivot(_:to:in:)`, the panel's drag clamp, moved into LumenCore. A legacy too-close pivot can stay
    where it is or move away from its neighbour, never toward it.
  - `ZoneAdjust` keeps only `ev`. Old keys are still decoded, because a keyed container ignores keys it does not
    ask for.
- **`AppliedReadout`.**
  - New `ZoneEased`, `zoneNames` and `zoneEasing(tone:zones:)`. Entries appear when `|requested − applied| > 0.005`.
  - `zoneFlattening` now places the band with `zoneAxis`.
- **`ZonesPanel.swift`.**
  - Each eased row shows a caption: "Applied +0.95 EV — eased so no brighter tone renders darker."
  - `movePivot` calls `Zones.movingPivot`, and `normalizedPivots` uses `Zones.minimumPivotGap`.
  - The pivot handle's VoiceOver value is in EV, e.g. "−2.00 EV", instead of a percentage.
  - The header comment now says why the dead fields are gone.
- **`RecipeKeys.swift`.** The `develop.zones.*.sat|falloff|wheel.*` rows are removed.
- **`scripts/gen-fixtures.py` `zone_adjust()` and `Fixtures/default-recipe.json`.** The three keys are dropped.
  The fixture was regenerated, and `gen-fixtures.py --check` passes.
- **Tests.**
  - New `ZonesResponseTests`.
  - Rewritten: `ZoneFlatteningTests`, `ToneTwinClampTests`, `AppliedReadoutTests` (zones), `ProofRegistry.zones`
    and its 10 records.
  - Edited: `RobustnessTests`, `RecipeCodecToleranceTests`, `ResetSemanticsTests` and `SavedLookTests`. The
    reasons are below.
  - Two new snapshot cases are appended at the end of `PanelSnapshotTests.renderPanels`.
  - The line citations in `LayoutMetricSupport.swift` are updated: the Zones rows moved down 5 and 11 lines.
- **Evidence and tools.** `tools/ramp_ev_kink.py` is new. Six evidence PNGs were added, so the folder now holds 11
  files, each under 400 KB.

## Per spec line

| line | status | what / measured |
|---|---|---|
| Z1.1 | PASS | `ZonesResponseTests.testMonotoneWithATextureFloor`, run over G5 (6250 combinations) and G3 (243 × 56 pivot sets, including a legacy 0.28 EV gap). Slowest slope: **0.25003** (base: −1.36), at Shadows +3 with every other zone at −3 on a random 1.2 EV-gap set. |
| Z1.2 | PASS | `testNoSlopeBreakAnywhere`. Largest one-sided slope jump: **0.0036** (threshold 0.01), on the legacy 0.28 EV gap set. |
| Z1.3 | PASS | `testNoOvershootAndPeaksAtThePivot`. `testMovingAPivotMovesWhereTheZoneActs` and `testTheGlobalZoneTrimIsFlat` pass unchanged. `testEachZoneMovesItsOwnPivotAndNoOther` had to change; see "Spec contradiction" below. |
| Z1.4 | PASS | `testSmallMovesAreExact`: for \|ev\| ≤ 0.75, `appliedZoneEV == ev` bit-exactly (a knee guard makes "exact" mean exact). The own pivot is within 1e-9 and the other pivots are 0. |
| Z1.5 | PASS | `testSmallMovesMatchTodaysResponse`: the max deviation is 0, because it is the same kernel at default anchors with an un-eased EV. |
| Z1.6 | PASS | `testTheEaseNeverGoesDead`. The smallest step is at +2.75 → +3 EV and still gains 3.3e-4 EV at the pivot (threshold 1e-4). Applied amounts: +1 → 0.890, +1.5 → 0.942, +3 → 0.954, +5 → 0.955. |
| Z1.7 | PASS (CI part [macOS-CI] pending) | `testTheEaseIsReported` and `AppliedReadoutTests.testAnEasedZoneIsNamedWithTheAmountTheRenderApplies`. Darks +3 gives exactly one entry: Darks, applied 0.9541. The panel caption is scanned by `testTheZonesPanelReadsTheReadoutAndDrawsIt`. |
| Z1.8 | PASS | `testEasingIsLocal`. With Darks +3 and Lights +0.5, Lights = 0.5. With Mid −3 and Brights +1, Brights = 1. |
| Z1.9 | PASS | `testTheClampNeverFiresOnAZonesOnlyRecipe`: `zoneFlattening()` is nil for all 6250 G5 recipes. |
| Z1.10 | PARTIAL; see below | `ramp_check.py`. minRatio ≥ 0.10: PASS (worst 0.14, base −0.29). flatEV ≤ 0.05: PASS (0.00 everywhere, base up to 1.59). negSpanEV ≤ 0.05: 0.05 on 7 recipes, **0.06** on dark+3 and dark+3,mid−3. maxKink ≤ 0.5: **FAIL as measured**, 0.83–3.15. A plain Exposure +0.95 scores 3.13 and 0.07 on the same tool, so these two numbers measure the display toe, not the zones. The EV-domain companion `tools/ramp_ev_kink.py` measures the zone response itself: every recipe has kink ≤ 0.48 (base up to 4.86) and slope ≥ 0.14 (base −0.12). |
| Z1.11 | PASS (code review); [macOS-CI] pending | Nothing under `Sources/LumenPipeline` or the kernel registry changed. `RR.applyTone:242` reads `plan.toneGainLUT`; `RG.applyTone:897` reads `plan.toneGainCubeBaked`, which `RenderPlan` bakes from the same `toneGainLUT` (RenderPlan.swift:517–575). No `LumenPipelineTests` test pins a zone value. |
| Z1.12 | DONE | See "Tests changed". |
| Z2.1 | PASS | `Zones.defaultPivots` is unchanged, and `AccuracyProbeTests` passes unchanged. |
| Z2.2 | human | Pivots were not moved; the lead may overrule (SPEC table). |
| Z3.1 | PASS | `testWhitesAndBlacksDoNotMoveTheZones`: equal within 1e-12 for Whites ±100 and Blacks ±100, and the Mid peak moves 0.000 EV (base −0.96 / +0.96 / −0.54 / +0.54). The `AppliedReadoutTests` placement test is inverted. |
| Z4.1 | PASS | `testPivotDragKeepsAOneStopGap`. `ZonesPanel.movePivot` uses `Zones.movingPivot`. |
| Z4.2 | PASS | `testDecodedRepairUsesTheOneStopGap`, and Z1.1–Z1.3 hold on the legacy 0.28 EV gap set (it is in G3). `RecipeCodecToleranceTests` needed one changed number; see below. |
| Z5.1 | PASS | `cmp` of base and branch `render` for grey_ramp, colorchecker, 6929, 2545 (and R5 4694): all byte-identical. `testMovingOnlyPivotsChangesNothing` passes. |
| Z7.1 | PASS | `ZoneAdjust` holds only `ev`. `lumen-render keys \| grep -c 'zones.*\(sat\|falloff\|wheel\)'` = **0**. |
| Z7.2 | PASS | `testLegacyZoneFieldsDecodeAndRenderIdentically`: decodes, gives an equal `Recipe` and an equal `toneGainLUT`, and re-saves with no sat, wheel or falloff key. |
| Z7.3 | PASS | `CanonicalJSONTests` and the fingerprint fixtures pass unchanged: `Recipe()` is sparse-encoded, so its canonical JSON is `{"pipelineVersion":N}` either way. `gen-fixtures.py --check` passes. |
| Z7.4 | DONE | `ResetSemanticsTests:56` (the `bright.sat` line is dropped), `SavedLookTests:73` and `RecipeCodecToleranceTests:496` (only `ev:` is kept). These were data only. |
| Z8.1 | [macOS-CI] pending | `panel-develop-zones-default` and `panel-develop-zones-darks3-pivot` are appended at the end of `renderPanels`. Both render `ZonesPanel(showsSectionHeader: false)` in `SnapshotSectionCard(.tone, …)`. The second sets Darks +3 and the Shadows pivot at −2.75 EV through `Zones.movingPivot`. |
| V1, V2 | [macOS-CI] pending, human | Each eased row shows "Applied +0.95 EV …" under it. The pivot readout is in EV (VoiceOver value); no hover readout was added. |
| V3 | human | `evidence/r5-darks-after-crop100.png` uses the same 340 px crops as `r5-darks-0-1.25-3-crop100.png`, located by template match (RMS 0). At Darks +3 (applied +0.95) the lemon peel and potato texture survive, with no flat patches or mask outlines. |

## Spec contradiction: Z1.3's "unchanged" test vs Z1.1 / Z1.4

`RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther` sets each zone to **+1 EV** and asserts that its own pivot
moves by exactly 1 ± 1e-9.

Z1.1 forbids this. A lone zone at +1 EV over a 2 EV gap, under the raised cosine Z1.5 requires, has a minimum
slope of 1 − π/4 = 0.215 < 0.25. Z1.4 itself places exactness at |ev| ≤ 0.75, from 0.8 × 0.955.

No kernel that stays within Z1.5's 0.02 EV of the raised cosine can apply +1 exactly and keep the floor. The only
change made is the amount: **1 → 0.75**, the top of Z1.4's exact range. The tolerance is unchanged, and the test
keeps its meaning (a zone moves its own pivot by what it asks and nobody else's).

`RecipeCodecToleranceTests.testAnOrderedArrayIsStillOrderedAfterTheDecoderFillsItIn` had the same problem:
Mid +1.0 was expected to give `zonePanelStops(0) = 1.0`. It now uses Mid +0.5, which gives 0.5.

## Tests changed, and why

- **`ZoneFlatteningTests.testDarksAloneFlattensTheBandTheAuditMeasured`.**
  - Darks +2 and +4 alone now assert **nil**: that is the fix.
  - The band measurement moves to Contrast −100 + Darks +3, measured at −3.179 … −2.123 EV, worst 0.055.
  - `testTheReportedBandIsFlatInTheBakedTable` uses the same recipe.
- **`ToneTwinClampTests`.**
  - `darksPlan` becomes Contrast −100 + Darks +3 (was Darks +4 alone), and the in-band probe moves −2.0 → −2.5 EV
    to stay inside the new band.
  - The assertions are unchanged; they are WS-07's.
- **`AppliedReadoutTests`.**
  - The untouched case now also asserts that Darks +4 alone shows no flattening, and that `zoneEasing` is empty
    inside the knee.
  - The Darks +4 caption test becomes Contrast −100 + Darks +3, with caption "−3.18…−2.12 EV" and "0.05 EV".
  - `testThePlacementFollowsTheAnchorsWhitesAndBlacksMove` is **inverted** (Z3): placement is `zoneAxis`, not the
    live `normalizedAxis`.
  - `testTheMarkGrowsWithTheRequest` grows with Contrast (−80 → −100), because the zone request itself is eased now.
  - New `testAnEasedZoneIsNamedWithTheAmountTheRenderApplies`.
  - The panel scan also pins the easing call and its caption.
- **`ProofRegistry.zones` and records.** Re-measured, and floors set at 70 %:

  | control | authority | floor |
  |---|---|---|
  | dark | 24.31 | 17 |
  | shadow | 51.97 | 36 |
  | mid | 93.84 | 65 |
  | light | 65.86 | 46 |
  | bright | 31.16 | 21 |
  | global | 215.25 | 150 (unchanged) |

  - `alternatingZones` changes from ±2 to ±0.375.
  - Pivot travels are now inside neighbours ± 1/14: dark 0–0.23 (unchanged), shadow 0.43–0.57, mid 0.58–0.71,
    light 0.72–0.85, bright 0.86–1.0.
  - Pivot authorities and floors:

    | pivot | authority | floor |
    |---|---|---|
    | dark | 2.04 | 1 |
    | shadow | 24.24 | 16 |
    | mid | 23.82 | 16 |
    | light | 19.72 | 13 |
    | bright | 12.42 | 8 |

  - The Light pivot's `declaredReversal` 5.158 becomes nil: every zone record now measures monotone with
    givenBack 0.
  - The zone authorities drop by design: a lone zone at ±3 applies about ±0.95 EV.
- **`RecipeCodecToleranceTests`.**
  - Line 357: a short `wheel` now decodes to the default `ZoneAdjust()`, because the key is removed.
  - The touching-pivots repair expects `0.3 + minimumPivotGap` instead of 0.32 (Z4.2 says the repair uses the new
    gap; the spec's "RecipeCodecToleranceTests unchanged" holds for the identity part only).
  - Line 496: `zone()` drops the dead arguments.
  - Mid +1 becomes +0.5 (see above).
- **`RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther`.** +1 becomes +0.75 (see above).
- **`RawDenoiseRecipeTests.defaultFullTreeDigest`.** The pinned XXH64 of the FULL default tree changes from
  68b478a3b73cfdea to 7121a0e06775a66f, because that tree is `default-recipe.json`, which Z7.3 changes on purpose. In
  the same test, the sparse canonical JSON, the fingerprint and the denoise-input fingerprint are unchanged.

## Test runs

- Targeted: ZonesResponseTests, ZoneFlatteningTests, ToneTwinClampTests, AppliedReadoutTests,
  EngineLimitReadoutTests, RecipeCodecToleranceTests, ResetSemanticsTests, SavedLookTests, CanonicalJSONTests,
  CurveMathTests, DesignSystemTests, MathTests, AccuracyProbeTests, RobustnessTests: 202 tests, 0 failures.
  RawDenoiseRecipeTests passes after the digest update.
- Full LumenCoreTests (release): 3073 tests, 6 skipped. The only failure was the digest above, which is fixed and
  re-run green. ControlProofTests passes, including the committed-record drift check.
- `swift build --target LumenCore --target LumenRender`: clean, with only pre-existing warnings.
  `check-swift-surface.py`, its fixture suite, `swiftc -parse` of the touched macOS files and
  `gen-fixtures.py --check` all pass.

## For the verifier

- The evidence sweep sheets are 256-colour palettised to fit under 400 KB, so the banding visible in the skies is
  from the palette, not the render. Judge texture from `r5-darks-after-crop100.png`, which is full colour.
- What a photographer will notice: Darks/Shadows/Mid/Lights at ±3 now move their pivot by about ±0.95 EV, not ±3,
  and say so on the row. Brights + and Darks − are never eased. Two zones pushed in opposite directions share the
  limit (Shadows +3 / Mid −3 → +0.48 / −0.48).
