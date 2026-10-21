# WS-32 Point Colour: acceptance spec (lane K3)

Owner functions: the WS-32 row in `docs/quality/workstreams.md`. Primaries (WS-33) have
their own spec in `../WS-33/SPEC.md`; both were built by lane K3.

Commands. `T` = `swift test --parallel --filter <suite>` (Swift 6.1.2, Linux).
`M` = `python3 docs/quality/lanes/WS-32/tools/measure.py --bin NEW --base-bin BASE
--work /tmp/k3m --only <part>` (needs `corpus/`). Frames 2062 and 2348 are rendered with
their ISO and as-shot WB from the sidecar, so the app's default classic NR runs, as in the
app.

| # | claim | threshold | measured by |
|---|---|---|---|
| S1 | A swatch whose shifts and Variance are all zero is an exact identity, and so is an unset refinement against an explicit 50 | bit-identical | `T PointColourQualityTests/testAnUnsetRefinementIsExactlyTheMasterRange`, existing `PointColour*` suites |
| S2 | Pick, then shift: the sampled colour turns by exactly the Hue shift, at every Range | ±1e-6° | existing `PointColourHueOrderTests` |
| S3 | Tight: a neutral grey, a colour 90° away, skin and foliage are not selected by a sky swatch at Range 0/50/100; a neutral stays out with the Hue refinement at 100 | weight < 0.05 | existing `PointColourSelectionTests`; `T PointColourQualityTests/testANeutralIsNotSelectedAtAnyRangeOrHueRefinement` |
| S4 | Smooth: across a linear-light blend from the swatch colour to a neutral, the weight falls monotonically (1000-step and 400-step sweeps, 5 swatches × 3 neutrals × 3 Ranges) and tracks the blend fraction | monotonic; abs(w − α) < 0.4 everywhere; w(0.5) ≥ 0.12 (base: 0.00); w(neutral) = 0 | `T PointColourQualityTests/testAMixtureWithANeutralFades…`, `…/testEveryBlendIsMonotonic` |
| S4b | A near-neutral pixel (C ≤ 0.02) gains nothing from the mixture reading | equals the absolute-only weight to 1e-9 | `T PointColourQualityTests/testANearNeutralPixelGetsNothingFromTheMixtureReading` |
| S5 | 2062: Saturation −100 on a petal leaves less saturated rim in the 30–70% blend band round the petal | rim chroma left ≤ 0.80 × base's | `M rim` → `rim_chroma_left` |
| S6 | 2348: Luminance −80 on the red stripe: no regression (the stripe was already 97% fully selected; the remaining 3% is weave and stitching speckle, S7) | under-selected stripe pixels ≤ base's | `M stripe` → `holes_pct` |
| S7 | No speckle on noisy frames: per-pixel selection noise in the transition band | lower than base | numpy model of the selection on 2062/2348 (REPORT) |
| S8 | Variance −100 evens blotchy skin and keeps its texture, and never tints a selected grey (`T …/testVarianceDoesNotTintASelectedGrey`) | LF hue and chroma spread ≤ 0.2× input; pore texture ≥ 0.95× (base 0.50); blue strip and grey patch unchanged (ΔE 0) | `M skin` |
| S9 | Range refinements: each widens or narrows only its own axis | per test | `T PointColourQualityTests/testEachRefinementActsOnItsOwnAxisOnly` |
| S10 | The panel's selection strip draws the render's own weight | within 0.03 of the render | `T PointColourQualityTests/testTheSelectionWeightIsTheOneTheRenderApplies`, `…SelectionStrip…` |
| S11 | GPU twin: the Float32 twin matches the Double engine on mixtures, refinements and Variance | EXECUTION-05 gate (3e-5 · scale, κ-widened) | `T PointColourQualityTests/testTheTwinMatchesTheEngineAcrossMixturesRefinementsAndVariance`, `ExactColorStageTests` |
| S12 | Wire format: refinements are optional; old recipes decode, and a swatch without them encodes without the keys | test | `T PointColourQualityTests/testRefinementsAreOptionalOnTheWire` |

Visual claims (a human judges these from the named images):

- V1 `evidence/ws32-2062-petal-edges.png`: after Saturation −100 and Luminance −80 the
  petal's soft edge fades out the way the defocus does, with no saturated ring.
- V2 `evidence/ws32-skin-variance.png`: Variance −100 evens the redness and keeps the
  pore texture (base: flat and plastic).
- V3 UI snapshot `panel-grade-colour-point-colour.png` (and `…-point-refined.png`): the
  swatch's three move rows carry its colour, a three-row selection strip sits under
  Range, three indented refinement rows follow it, and each chip shows before | after.
