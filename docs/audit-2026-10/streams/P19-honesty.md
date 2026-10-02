# P19-honesty: panels that tell the truth where the engine already measures it

Stream agent P19-honesty. Base: `claude/jolly-sagan-k7ch7z` at `cbe7c66`. P14 was not on trunk yet,
so I merged its branch `worktree-agent-a8330061c8b71a04a` at `f28c0ba`. The merge was clean and
brings `ToneEngine.zoneFlattening`. Build dir `/tmp/lumen-build-p19`, Linux.

Every change is UI only. Each readout constructs the same engine `RenderPlan` constructs (the tone
stage, and the grade stage hung off the tone stage's live anchors) and only reads values from it.
The one new LumenCore file is `Sources/LumenCore/Engine/AppliedReadout.swift`. Only the three
panels and its tests reference it. No render path, table, kernel or ColorEngine plumbing was
touched. **No proof record moves.**

## Items

| Item | Status | Commit | Red / green | Proof records |
|---|---|---|---|---|
| AI-07: Zones flattening indicator | **FIXED** (P14 DECISION 3, option a) | `01bdd7a` | `AppliedReadoutTests`: 4 red with the readout forced to nil and the strip argument dropped; 5/5 green | none |
| AI-08: interim honesty for Even out hues / Point Variance | **FIXED** (help text only, no behaviour change) | `ece8d70` | `PerPixelVarianceHelpTests`: 2 red with the old help strings; 4/4 green | none |
| Sweep: engine limits the panels hid | **FIXED** for three; the rest are listed below | `71d08b4` | `EngineLimitReadoutTests`: 2904 assertion failures across 4 tests with the readouts forced off; 4 red with the panels at their previous text; 7/7 green | none |

### AI-07 (`01bdd7a`)
`AppliedReadout.zoneFlattening(tone:zones:)` returns three things:
- `ToneEngine.zoneFlattening()`, unchanged;
- the band's ends on the strip's own axis (`normalizedAxis` at the recipe's live anchors);
- a caption.

`ZonesPanel` passes the band to `ZonePivotStrip`. The strip washes it in the accent colour at 0.22
opacity, at least 2 pt wide. The panel prints the caption under the strip in the same style as the
bounded-Tint caption: `.lumenCaption`, secondary text, and nil whenever nothing is flattened. For
Darks +4 EV the caption reads: "Flattened: input −3.77…+0.08 EV renders as one tone, up to 2.20 EV
from what the zones ask."

There is no floor. With Darks alone, the clamp stays idle up to +1.25 EV, and its first band (at
+1.5 EV) is already 1.03 EV wide. The tests cover:
- an untouched register reports nothing;
- the values are the engine's own report;
- the placement follows the anchors that Whites and Blacks move;
- the band grows with the request;
- a source contract on the panel and the strip.

### AI-08 (`ece8d70`)
Both help strings now add "For now it works pixel by pixel, not on the neighbourhood: …".

Each claim was measured on the shipping `ColorEngine.apply`:
- Variance −100 maps 24.23/29.23/34.23° to 29.23°. Chroma lands on the swatch's chroma, and
  lightness moves halfway to the swatch's.
- Variance +100 doubles the hue offset.
- Even out hues 100 collapses ±5° to the band centre, in all eight bands.

The tests pin these claims to the engine, so the help must change on the day a spatial mean lands
(P14 DECISION 6, P5's S9 kernel). A scan with the literals joined pins the sentences themselves.

### Sweep (item 3)
Sites where an engine clamps, saturates or bounds a value:

| Site | Engine reports it? | Panel showed? | Now |
|---|---|---|---|
| `ToneEngine.effectiveHighlights/Shadows/Whites/Blacks` (monotonicity solve) | yes, documented "so the panel can show the applied value" | no | **caption under the Tone sliders**. Example: "Applied here: Highlights −94 of −100 — eased so no brighter tone renders darker." Whites and Blacks are labelled "(tone shelf)" because the solve never eases the anchor. |
| `GradeEngine.lumScale · jointScale` (zone wheels' Luminance) | yes | no | **caption under the wheel**. Shadows +1, Midtones +1, Highlights −1 at Blending 0 applies 2%. |
| `ColorBalanceGrid.appliedBrillianceScale` | yes | no (only a fixed ±20 heuristic) | **the Brilliance note carries the applied %**. Shadows +100 with Highlights −100 applies 34%. Shown in the warning style; appended to the ±20 warning when both hold. |
| `WhiteBalanceEngine.effectiveTint` / `ColorTemperature.clampedTint` | yes | yes (`boundedTintCaption`) | already honest; this is the idiom I copied |
| `CurveStack.bakeParametric` region-slider scale (`slopeLimit` × softKnee) | **no**, it is a private local | no | not done: it needs a public accessor in CurveStack first |
| Point curve / Zones forward clamp in bakes | Zones: yes (AI-07). Point curve: no | Zones now yes | point curve is the "unlimited tool"; same treatment possible once measured |
| `DisplayTransform` black target capped at midGrey×0.5 (Astra AI-09: typed 9–15 render identically) | implicit | no | not done: the range should be aligned or an applied value shown (P3 row) |
| `DenoiseEngine.effectiveLevels(width:height:)` | yes | not checked | not done |
| `ColorEngine.chromaGate` (hue moves fade on near-neutrals) | constant | no | by design, documented in the help; not a bound on a slider value |

## Checks
`swift build --build-tests` is clean. AppliedReadoutTests, EngineLimitReadoutTests and PerPixelVarianceHelpTests are green: 16/16. `check-swift-surface.py` exits 0 on the final tree.

## DECISIONS
1. **Zones wash colour.** The flattened band is drawn in `Lumen.accent` at 0.22 opacity. The other
   option is a hatch, or a red-family tint. The owner may prefer something else; the caption carries
   the numbers either way.
2. **Brilliance note style.** While the limiter holds the zone rows back, the note uses the
   existing `warn` (accent) style, the same style it already uses past ±20. The conservative
   alternative is secondary text, like the Tint caption.
3. **Captions are text, not slider-track marks.** Drawing the applied value as a ghost thumb on each
   eased slider would be more direct, but it changes `LumenSlider`, which every panel shares. I left
   it as a suggestion.

## FOUND-WHILE-FIXING
1. `CurveStack`'s parametric scale is a local inside `bakeParametric`. It is the one solved limiter
   that the engine does not publish, so no panel can show it without an engine change. That change
   would be small and pixel-identical.
2. The sweep caption under Tone also fires at Contrast −100 for a single slider (Highlights −100
   applies −94; Blacks +100 applies +91 on its shelf). This is exactly the case `ToneEngine`'s
   comment says "is FALSE whenever Contrast is negative". The caption makes that visible rather
   than changing it.

## Pixel identity
- `AppliedReadout` is referenced only from `ZonesPanel`, `BasicPanel`, `LookPanel` and its tests
  (`grep -rln AppliedReadout Sources Tests`).
- No file under `Sources/LumenPipeline` changed, and no engine file under `Sources/LumenCore/Engine`
  changed other than the new file.
- The P14 merge's own pixel change (`color.density` / `color.saturation`) belongs to P14 and is
  stated in its report.
