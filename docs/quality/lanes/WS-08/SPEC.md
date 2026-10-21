# WS-08 spec: Zones register

From `AUDIT.md` and the lead's decisions Z1–Z8. Every line is PASS/FAIL.

- `core-tests` = `bash /tmp/claude-0/bin/core-tests.sh <XCTestFilter>`.
- `BIN` = `$(swift build -c release --show-bin-path)/lumen-render`.
- Tools are in `docs/quality/lanes/WS-08/tools/`.
- [macOS-CI] = checked only on the macOS runners.
- `y(t) = t + zonePanelStops(t)` is the zone response on its own, with tone sliders at default.
- Pivots are p0…p4 with EVs T0…T4, through the default anchors (−9/+5 EV).
- `a_i` is the applied (eased) EV of zone i.

Owned: `ToneEngine.normalizedAxis/zonePanelStops`, `Zones`/`ZoneAdjust`, `ZonesPanel.swift`, `ZonePivotStrip`,
`AppliedReadout.zoneFlattening`. Lead-granted: the zone rows of `Sources/LumenRender/RecipeKeys.swift`, and
`scripts/gen-fixtures.py` + `Fixtures/default-recipe.json` (the Python mirror of the Recipe defaults). `ZoneWeights` is
NOT changed: four other lanes call `crossfade`.

## Z1. Monotone, seam-free, texture-keeping response (in `zonePanelStops`)

The cause is the 2 EV pivot gaps with a raised-cosine crossfade, whose peak slope is π/2 × the secant. The response
inverts once an adjacent-zone difference passes 4/π ≈ 1.27 EV, and WS-07's forward clamp then posterizes whole EV
bands (audit Z-1: Darks +3 renders −3.75…−0.85 EV as one grey). The fix eases the EVs before they reach the curve,
the way `solveZonalLimits` does for the six sliders. The clamp then never fires on a Zones-only recipe.

*Amended by lead, round 2: the round-1 ease scaled a lone zone's request, so Darks +3 applied +0.954 and the slider travel past
~0.76 EV added ~0.2 EV — a dead range LANE-BRIEF §4 forbids.* **Spill rule.** With `L_i = 0.75 · 2 · gap_i / π`
(the gap in EV; 0.955 EV at the default pivots), a request is HONOURED at its own pivot. When a seam's drop exceeds
`L_i` and the downhill neighbour is untouched (requested 0), that neighbour moves by exactly `drop − L_i`, and on
outward: Darks +3 → Shadows +2.05 → Midtones +1.09 → Lights +0.14 at the default pivots, and the mirror for negative
requests (Brights −3 pulls Lights/Midtones/Shadows down). Only where two TOUCHED zones disagree by more than the seams
between them can carry is a request held back, by the round-1 scaling/soft-knee ease over that span.

Grids. **G5** = {−3, −1.5, 0, 1.5, 3}^5 at the default pivots, with global ∈ {0, 3}. **G3** = {−3, 0, 3}^5 on each of:
four min-gap pivot sets (one adjacent pair at exactly 1 EV, the others default); `[0, 1/14, 2/14, 3/14, 4/14]`; and 50
seeded random ascending sets with every gap ≥ 1 EV. All lines below are in new
`Tests/LumenCoreTests/ZonesResponseTests.swift`, `core-tests ZonesResponseTests`.

- **Z1.1** `testMonotoneWithATextureFloor`. For every combination in G5 and G3, sampled over t ∈ [−12, +8] EV at 0.01
  EV steps, `(y(t+0.01) − y(t)) / 0.01 ≥ 0.25 − 1e-9`. Today: min −1.36 at Darks +3.
- **Z1.2** `testNoSlopeBreakAnywhere`. One-sided slopes with δ = 1e-5 EV, at every 0.05 EV sample and exactly at each
  pivot, satisfy `|y'(t⁺) − y'(t⁻)| ≤ 0.01`, on G5 and G3. This rules out C0 joins at pivots, at the end shelves, and
  at any knot the builder adds.
- **Z1.3** `testNoOvershootAndPeaksAtThePivot`. On each interval [T_i, T_i+1], `zonePanelStops` lies within
  `[min(a_i, a_i+1), max(a_i, a_i+1)] ± 1e-9`. Below T0 it equals a_0 and above T4 it equals a_4, plus global, ± 1e-9.
  This keeps "a zone acts most at its own pivot". Existing tests `testMovingAPivotMovesWhereTheZoneActs` and
  `testTheGlobalZoneTrimIsFlat` stay unchanged and pass. *Amended by lead, round 2: `RobustnessTests.testEachZoneMovesItsOwnPivotAndNoOther`
  keeps +1 EV and its own-pivot assertion; the next pivot up the axis now carries 1 − L = 0.045 EV, which is what is
  true under the spill rule, and the test says so.*
- **Z1.4** `testSmallMovesAreExact`. For a single zone with |ev| ≤ 0.75 at the default pivots, `a = ev` exactly. At its
  own pivot `zonePanelStops` = ev ± 1e-9, and at the other pivots 0 ± 1e-9. *Amended by lead, round 2: under the spill rule nothing spills
  below |ev| = L = 0.955 EV; the 0.75 cases are kept.*
- **Z1.5** `testSmallMovesMatchTodaysResponse`. For a single zone at |ev| ≤ 0.5 at the default pivots,
  `max_t |new − ZoneWeights.exposureStops(old axis)| ≤ 0.02 EV` over [−12, +8]. A photographer's existing small zone
  edits must not visibly move.
- **Z1.6** `testTheEaseNeverGoesDead`. *Amended by lead, round 2 (no dead range).* For each zone alone at the default pivots and
  v ∈ [−3, 2.75] in 0.25 steps, `(y(T_z) at v+0.25 − y(T_z) at v) / 0.25 ≥ 0.99`, and the zone's applied value is v
  (± 1e-12): a lone zone is delivered in full at its own pivot over the whole slider.
- **Z1.6b** `testALoneZoneSpillsItsExcessIntoItsNeighbours`. *Amended by lead, round 2.* Darks +3 at the default pivots gives
  `zonePanelStops` at the five pivots = 3, 3 − L, 3 − 2L, 3 − 3L, 0 (± 0.01 EV; L = 0.955), i.e. Shadows +2.045,
  Midtones +1.090, Lights +0.135 (± 0.001). Brights −3 is the mirror.
- **Z1.7** `testTheEaseIsReported`. New `AppliedReadout.zoneEasing(tone:zones:) -> [ZoneEased]`, one entry per zone with
  `|requested − applied| > 0.005 EV`, each holding the zone name, requested and applied. It is empty for Z1.4's cases.
  *Amended by lead, round 2:* for Darks +3 it has exactly three entries, Shadows, Midtones and Lights, each carried from Darks and captioned
  in photographer words ("+2.05 EV carried from Darks"); Darks itself has none. For Darks +3 with Midtones −3 (a
  conflict) Darks and Midtones each have an entry naming the other ("Applied +0.95 of +3.00 EV (conflicts with
  Midtones)"), with |applied| < 3. ZonesPanel shows the caption under the row that moved ([macOS-CI], Z8 snapshot).
- **Z1.8** `testEasingIsLocal`. Darks +3 with Lights +0.5 leaves Lights applied at 0.5 ± 1e-9. Mid −3 with Brights +1
  leaves Brights at 1 ± 1e-9. A zone separated from the conflict by an untouched zone is never scaled. *Amended by lead, round 2: a lone
  zone is never scaled (Mid −3 there applies −3 ± 1e-12).*
- **Z1.8b** `testAConflictIsEasedAndKeepsTheFloor`. *Amended by lead, round 2.* Darks +3 with Midtones −3: both held back (|applied| < 3),
  the untouched Shadows between their applied values, slope ≥ 0.25 − 1e-9 over [−12, +8].
- **Z1.9** `testTheClampNeverFiresOnAZonesOnlyRecipe`. `ToneEngine.zoneFlattening()` is nil for all of G5. It is read
  only; it is WS-07's function.
- **Z1.10** Pipeline confirmation on the CPU reference: `BIN=… python3 tools/ramp_check.py /tmp/claude-0/ws08-after`.
  This renders `grey_ramp.lfi` at native 2800 px for 9 Zones recipes plus default. *Amended by lead, round 2: the display-code
  `minRatio`/`negSpanEV`/`maxKink` metric is replaced by the EV-domain measure
  `python3 tools/ramp_ev_kink.py /tmp/claude-0/ws08-after` (it inverts the default render to read back the tone the
  pipeline rendered). Reason: a plain Exposure +0.95 fails the display-code metric (maxKink 3.13, negSpanEV 0.07), so
  it measures the display toe, not the zones.* Pass for every recipe: `maxKinkEV ≤ 0.5` (change of du/dt over
  0.1 EV) and `minSlope ≥ 0.10` from `ramp_ev_kink.py`, and `flatEV ≤ 0.05` from `ramp_check.py`. Today (EV
  domain): Darks +3 −0.12 / 0.94; Mid −3 −0.12 / 2.59; Shadows +3 / Mid −3 / Lights +3 −0.11 / 4.86 (min slope /
  kink).
  Evidence: before/after `ramp-transfer-*.png` and the R5 4694 100 % crop at Darks 0 / +1.25 / +3.
- **Z1.11** CPU/GPU stay one definition. Code review: the diff touches nothing under `Sources/LumenPipeline` or the
  kernel registry. Both paths consume the LUT baked from `ToneEngine.stops` (RR.applyTone:242 `plan.toneGainLUT`;
  RG.applyTone:897 `plan.toneGainCubeBaked`, built from the same bake). [macOS-CI] `gpu-parity.yml` and
  `ToneShippingGoldenTests` stay green.
- **Z1.12** Tests that encode the old clamp and must change in the same commit, each with its reason in REPORT:
  - `ZoneFlatteningTests.testDarksAloneFlattensTheBandTheAuditMeasured` and `testTheReportedBandIsFlatInTheBakedTable`
    need a recipe that still reaches the clamp (e.g. Contrast −100 + Darks +3), or move to asserting nil.
  - `ToneTwinClampTests` must reach the clamp the same way. Its assertions are WS-07's and stay.
  - `AppliedReadoutTests` zone cases are rewritten for `zoneEasing`.
  - `ProofRegistry.zones` floors are re-measured under that file's 70 % rule. The pivots' companion `alternatingZones`
    (±2 EV, a 4 EV seam that is now eased) becomes ±0.375 EV, a 0.75 EV seam inside Z1.4's exact range, so each pivot is measured on an un-eased seam. Pivot travels
    stay within neighbours ± `minimumPivotGap`.

## Z2. Default pivots: NOT moved

Decision from data (`tools/pivot_authority.py`, `tools/scene_percentiles.py`).

- On 25/25 corpus frames the 99.9th percentile of scene luminance is ≤ +2.5 EV. That is the sensor clip: raw 1.0 is
  +2.47 EV. At most 2.3 % of pixels lie above +2 EV.
- Brights' pivot at +4 EV is above every un-pushed raw value. Zones read scene tone before Exposure: Brights ±1 with
  Exposure +1.5 still measures mean ΔE ≤ 0.13.
- Brights ±1, minimum of the two signs, mean ΔE2000 on 8 frames (6929, 6933, 2545, 1569, 4694, 983, 1840, 4213):
  - today (−4/−2/0/+2/+4): ≤ 0.00
  - audit proposal (−3.1/−1.7/0/+1.5/+3.0): ≤ 0.05
  - (−4/−2/0/+1/+2): ≤ 0.16
  - (−3/−1.5/0/+1.25/+2.25): ≤ 0.11

No placement that keeps Mid at mid-grey makes Brights live on ≥ 6 real frames. Moving the pivots would gain Lights at
most 2× (0.09–1.54) and would cost the following:

- every existing zone edit moves, because sparse JSON stores no pivots for defaults;
- a recipe-version migration (WS-58);
- uneven gaps, which lower Z1's exact range;
- the docs/04 contract.

Brights is inert on raws because there is no content up there, not because of a bug. Pivots stay where they are.

- **Z2.1** `Zones.defaultPivots` is unchanged. `AccuracyProbeTests.testTheDefaultZonePivotsSitAtTheirDocumentedEVs`
  stays as it is and passes.
- **Z2.2** Human judgement (REPORT): the lead may overrule this decision with the table above. If so, that test changes
  in the same commit and the migration goes to NEEDS (WS-58).

## Z3. Zones fixed in stops around mid-grey

- **Z3.1** `zonePanelStops` maps t through the DEFAULT anchors, via a new `ToneEngine.zoneAxis(_:)`, and so does the
  readout's x placement. `normalizedAxis` keeps its live-anchor meaning for its other callers. The test is
  `ZonesResponseTests.testWhitesAndBlacksDoNotMoveTheZones`: with Mid +1, and each of Whites ±100 and Blacks ±100,
  `zonePanelStops(t)` equals the untouched-tone value within 1e-12 for all t ∈ [−12, 8]. The Mid peak (found at
  0.001 EV) moves by < 0.01 EV. Today it moves −0.96 / +0.96 / −0.54 / +0.54 EV.
  `AppliedReadoutTests.testThePlacementFollowsTheAnchorsWhitesAndBlacksMove` encodes the old coupling and is inverted
  (placement must NOT move), with the reason given.

## Z4. Minimum pivot gap = 1 EV

- **Z4.1** `Zones.minimumPivotGap = 1 / (defaultWhiteAnchorEV − defaultBlackAnchorEV)` (= 1/14), public. ZonesPanel
  uses it in place of its private 0.02. Drag clamping moves into LumenCore as
  `Zones.movingPivot(_ index:, to:, in:) -> [Double]`, used by `ZonesPanel.movePivot`. Tests
  `ZonesResponseTests.testPivotDragKeepsAOneStopGap` check the following:
  - the result is ascending with every gap ≥ minimumPivotGap − 1e-12;
  - a drag past a neighbour stops at neighbour ± gap;
  - on a legacy set with a 0.02 gap (0.5, 0.52), the pivot can still be dragged away from its neighbour (it never
    sticks), and it is never pushed toward it.
- **Z4.2** `Zones.decodedPivots` stays the identity on every strictly ascending list, so no stored recipe moves
  (`RecipeCodecToleranceTests` unchanged). Its repair of out-of-order or touching lists uses the new gap.
  `testDecodedRepairUsesTheOneStopGap`. Z1.1–Z1.3 hold on legacy gaps < 1 EV as well: the ease uses the actual gap.

## Z5. Identity

- **Z5.1** `Recipe()` renders byte-identically before and after: `cmp` of `$BIN render --input X --out o.png` for
  grey_ramp, colorchecker, 6929 and 2545, on base vs branch. Pivots-only edits stay an exact identity:
  `ToneEngine.isIdentity` is true and `zonePanelStops ≡ 0`. `ZonesResponseTests.testMovingOnlyPivotsChangesNothing`.

## Z7. Dead wheel / sat / falloff removed

Why: no stage reads them (audit Z-7; byte-identical renders with every one set). Colour Grading already does colour by
tonal range on the same axis and kernel (`look.wheels`, `colorBalance`). Making them real would turn S7 into a colour
stage in WS-07's code, with new kernels, goldens and a cube. Falloff contradicts the two-zone partition that Z1 relies
on. Today they still re-bake the S7 cube (they are in `ToneKeyInputs`), mark Tone modified (`WorkspaceModification`)
and change fingerprints.

- **Z7.1** `ZoneAdjust` keeps only `ev` (stored property, `init`, `CodingKeys`). The doc comment and the ZonesPanel
  header comment say why. The RecipeKeys rows `develop.zones.*.sat|falloff|wheel.*` are gone, and `$BIN keys | grep -c
  'zones.*\(sat\|falloff\|wheel\)'` prints 0.
- **Z7.2** `ZonesResponseTests.testLegacyZoneFieldsDecodeAndRenderIdentically`: a recipe JSON with
  `"zones":{"mid":{"ev":0.4,"sat":30,"wheel":[0.1,-0.2],"falloff":0.2}}` decodes without error through
  `CanonicalJSON.decodeRecipe`. Its `RenderPlan.toneGainLUT` equals that of the same recipe without the dead keys.
  It re-encodes with no `sat`/`wheel`/`falloff` key. Dropping never-rendered values on re-save is intended.
- **Z7.3** `canonicalRecipeJSON(Recipe())` and `RecipeFingerprint.fingerprint(Recipe())` are byte-identical to base.
  Check by printing both on base and branch through a LumenCore probe, or with the existing `CanonicalJSONTests` and
  fingerprint fixtures passing unchanged. `scripts/gen-fixtures.py` `zone()` and `Fixtures/default-recipe.json` drop the
  three keys together, and `CanonicalJSONTests` passes.
- **Z7.4** Tests that set the dead fields only as data drop those arguments, with the reason given:
  `ResetSemanticsTests:56` (`bright.sat`), `SavedLookTests:73`, `RecipeCodecToleranceTests:496`.

## Z8. Panel (snapshots, append-only to `PanelSnapshotTests.swift`) [macOS-CI]

- **Z8.1** `ZonesPanel` is rendered directly in a `SnapshotSectionCard`, so it does not depend on BasicPanel's private
  `zonesExpanded` fold. There are two cases: `panel-develop-zones-default`, and `panel-develop-zones-darks3-pivot`
  (Darks +3, Shadows pivot dragged to −2.75 EV). Neither carries a failure note in `index.md`. `ui-layout.yml` stays green.

Visual claims (human judges, lane branch `ui-snapshots`):

- **V1** `panel-develop-zones-default.png`: five labelled rows plus Global, and a pivot strip whose handles can be told
  apart and grabbed. Nothing is clipped at the column width.
- **V2** `panel-develop-zones-darks3-pivot.png`: the Darks row shows the applied value (Z1.7) next to the requested +3.
  The strip shows the moved Shadows pivot. If the builder adds a pivot EV readout (hover or drag), it reads in EV, not
  in percent.
- **V3** `evidence/r5-darks-after-crop100.png`: at Darks +3, lemon-peel and potato texture survive in the lifted
  shadows, with no flat patches outlined by the mask edge (compare with `r5-darks-0-1.25-3-crop100.png`).

## Non-goals (to NEEDS.md)

- WS-07: the GPU tone cube is 32³ interactive / 65³ export along grey. It needs a 1D gain texture or ≥ 256 grey
  samples, plus a zones parity golden (audit Z-6). WS-07 also owns `zoneFlattening`'s under-reporting, and the clamp
  backstop for zones combined with Contrast or the six sliders (the zone ease ignores them).
- Integrator: docs/04 §Zones (dead fields gone; pivots are fixed in stops; the ease).
- WS-58: none required, since pivots did not move. `WorkspaceModification` and `ToneKeyInputs` stop seeing the dead
  fields as a side effect of Z7. Verify, no edit.
- WS-35: `GradeEngine.normalizedAxis` has the same Whites/Blacks coupling as Z3.
- WS-05: make `zonesExpanded` injectable, so the fold snapshot `panel-develop-tone-zones-open` works.
- Later: a histogram behind the pivot strip, and an auto-fit of pivots to the image's histogram (darktable-style).
  These would be the real answer to "Brights does nothing on this photo".
