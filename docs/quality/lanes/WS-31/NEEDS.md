# WS-31 needs from other lanes

## UI

Written by the WS-31 UI builder (branch `quality/k2-ui-wip`). Each item names the owner from `docs/quality/workstreams.md`.

### 1. WS-32: `ColorPanel.pickBandButton` is no longer drawn

- U1 asks for an icon-only eyedropper with the same glyph and size as Point Colour's, and for the "Pick a colour" text to go.
- `pickBandButton` is owned by WS-32, so the mixer header now draws its own `mixerPickButton`. It arms and cancels `.mixerBand` exactly as `pickBandButton` did.
- `pickBandButton` is left in place, unchanged and unreferenced. WS-32 should delete it, or restyle it and have the mixer call it again. Either way is fine with WS-31.

### 2. WS-32: U6's grep hits a Point Colour help string

- `grep -nE '"[^"]*(OKLCh|feather|core [−-])[^"]*"' Sources/LumenApp/ColorPanel.swift` returns one hit, and it is not in the mixer: it is Point Colour's Range help, `"reaches — low is surgical, high feathers into "` (`pointColorSection`).
- Either WS-32 rewords it (for example "high blends into the neighbours"), or U6's grep is scoped to the mixer's functions. Every mixer string is clean.

### 3. WS-02: `AppState.mixerAllBands` is no longer read

- The "All bands" segment (a rigid group offset) is gone from the UI. U4 allows dropping it, and the reasons are in `ColorPanel.mixerHeaderRow`.
- `resolvePick` (`.mixerBand`) still writes `mixerAllBands = false`. That is harmless, and both that line and the property can be deleted by WS-02.
- `GroupMove` stays in LumenCore with its tests. The app no longer calls it.
- New property: `AppState.mixerAdjust: MixerAdjust` (`.hue/.saturation/.luminance/.band`, default `.band`), with the enum nested beside it. This is the one `@Published` line the spec allows. It is view state and never written to a recipe.

### 4. WS-02: E1 needs no routing change; the "switch to Band view" variant would

- E1 as specced is done in the panel. In Band view, the pick's `mixerBand` write moves the swatch ring. In Hue, Saturation and Luminance views, the picked band's row wears the focus surface until the view changes (`ColorPanel.mixerSection`'s `onChange`).
- Limit: a pick that resolves to the band already in `mixerBand` publishes no change, so no row lights up. Fixing that needs a pick counter or event from `resolvePick`, for example `@Published var mixerPickSerial: Int` bumped on every `.mixerBand` resolution, which the panel would watch instead.
- If the owner would rather have a pick jump to Band view, that is one line in `resolvePick`'s `.mixerBand` case: `mixerAdjust = .band`.

### 5. WS-02 (+ WS-31 panel): E2, drag-on-image targeted adjustment

This is not built: it needs pick routing and a loupe gesture, which WS-02 owns. The contract:

- **Arming.** A new `PickTarget.mixerTargeted`, armed from a second mixer header button that WS-31 adds once the target exists. It is persistent: it stays armed across drags until Escape or a re-press, unlike the one-shot `.mixerBand`.
- **Gesture.** Press-drag on the loupe. On press, sample the colour stage input at the point, the way `.mixerBand` does (`sampleColorStageInput`).
  - Compute weights with `ColorEngine.bandWeights(hue:arcs:)` on the live arcs (`ColorEngine.bandArcs(recipe.develop.mixer.bands)`), multiplied by the chroma gate.
  - If the gated total is ≈0 (a grey pixel), write nothing and set `statusMessage = "No colour to work on there — that pixel is grey."`
- **Write.**
  - Vertical travel maps to slider units, about 1 unit per pt (⇧ fine at ×0.25, as `FineDrag` does).
  - The attribute is `mixerAdjust` (`.hue/.saturation/.luminance`). In `.band` view it is Luminance, Lightroom's default.
  - Each band b gets `delta × w_b / max_b w_b`, clamped to ±100, through one `updateRecipe(coalescingKey: "mixer.targeted.<attribute>")`, so a drag is one undo step. The `sliderGestureChanged(true/false)` bracket goes around the drag.
- **Feedback.** Crosshair cursor (`lumenPickCursor`). Status text names the dominant band and the attribute ("Orange + Red · Luminance"). The panel highlights the rows it is moving, using the same `pickedRow` surface as E1.

### 6. Band names (done) and WS-16: the B&W help still says "Azure"

- The engine commit renamed `ColorEngine.bandNames` to Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta, so the mixer rows read as U2 asks with no UI change. `MixerBandNameTests` still pins Magenta as the widest name.
- **WS-16** (owns `ColorPanel.blackAndWhiteSection`): its slider help reads "The classic moves: drop Azure for a dramatic sky" (ColorPanel.swift ~1000). There is no band called Azure any more; the word should be "Blue". The B&W sliders take their titles from `bandNames` while B&W stays on the legacy 45° grid (Engine E-2), so WS-16 may also want to say which hues those rows cover.

### 7. Swatch and track colours follow `ColorEngine.bandHueCentres`

- Nothing is needed for this. When the centres move, the swatches, the ring and every track recolour from the new centres.
- Checked with a Python port of `ColorPanel.paint(h:)` on both the current centres and [24, 57, 100, 142, 195, 258, 295, 332], after 8-bit quantisation:
  - worst swatch hue offset: 0.23° (current) and 0.32° (LR-like)
  - Saturation-track midpoint: 0.54° and 0.61°
- Verify round 1 changed the paint to read as the canonical colours: lightness 85% of the way to each hue's sRGB cusp from 0.45, chroma 95% of the display's, capped at 0.22. Yellow reads clean rather than mustard, and Red deep rather than coral. On the engine's centres the port gives a worst swatch offset of 0.18° and a worst Saturation-track midpoint of 0.76°.

### 8. Shared kit: an opt-in label parameter on `LumenSlider`

- `LumenSlider.labelAtFullStrength` (default `false`) keeps the name at `primaryText` at the default value. The mixer's Hue, Saturation and Luminance rows pass `true`; without it seven of eight band names read as disabled.
- It is purely additive: the last declared property, so no existing call site changes. Any lane that owns `LumenControls.swift` is welcome to rename it.
- New view state on `AppState`: `mixerRangeExpanded` (the Band range fold), so the snapshot suite can open it.

## Engine

Written by the WS-31 engine builder. Each item names the owner from `docs/quality/workstreams.md`.

### E-1. WS-01 / WS-58: pin pre-WS-31 recipes to the old mixer maths (SPEC T5)

The renderer has no per-version dispatch, so every existing recipe that touched the Mixer re-renders with the new geometry. To keep old recipes bit-identical (docs/14 §8.2, D52) the owner of `Recipe.pipelineVersion`, the cache key and the migration UI needs to:

- bump `pipelineVersion` and dispatch `ColorEngine`'s mixer block, `ExactColorTwin.mixer` and `ExactColorKernelSource.mixer` on it;
- give the old path these constants, which are all still in the tree or recoverable from git (base 9068ded):
  - centres `ColorEngine.uniformBandHueCentres` (29.23 + 45k), arcs `ColorEngine.uniformArcs` (core 22.5/22.5, feather 15/15), wire core/feather read as absolute degrees, feather floor 2°, min reach 27.5° per side;
  - hue: `Σ w·gate·(slider/100)·45°` over the membership weights;
  - saturation: `C·max(0, 1 + Σ pulls + Σ gated pushes)`, no roll-off;
  - luminance: `L + Σ w·gate·(slider/100)·lumShape(L)` (κ = 1, `lumShape` is unchanged and still used by Point Colour);
  - gate: `chromaGate` (smoothstep 0.02…0.06);
- the badged opt-in migration (old → new geometry) with a before/after preview. Stored `MixerBand.core/feather` need no rewrite: the wire default `[22.5, 22.5]/[15, 15]` resolves to the new per-band default under the new wire semantics (`ColorEngine.bandArcs`).

### E-2. WS-16 (B&W mix): B&W still uses the legacy 45° grid

WS-31 moved only the Mixer. To keep `BlackAndWhiteMixTests` and the goldens unchanged, the B&W mix now reads `ColorEngine.uniformBandWeights(hue:)` (CPU, one line in `applyBlackAndWhite`) and the GPU finish pass packs `ColorEngine.uniformBandHueCentres` (one line in the `ExactColorStage.init` prologue that feeds the finish pass, WS-16/WS-34). Both are behaviour-preserving renames of what they read before. If the B&W owner wants B&W bands to match the Mixer's (the names Green/Blue now describe the Mixer's centres, not the legacy grid's), that is their change and their pipelineVersion question. The B&W help text in `ColorPanel.blackAndWhiteSection` still says "Azure" (ColorPanel.swift:973).

### E-3. WS-13 (display transform): hue is not uniform through the default rendering

Measured on the base binary with no Mixer edit at all (scratch probe, numbers in BUILD-NOTES.md):

- On the SPEC's hue ramp, the slope of displayed hue against scene hue runs from 0.41 to 1.61 on row L 0.4 C 0.06 (0.61–1.51 at L 0.6). A rigid scene-hue rotation therefore reads as a display slope of up to ~4 and down to ~0.4 relative to the untouched render, which is what fails H2 (3.9) and pulls H3 down to 21.6° on Purple/Magenta although the stage moves those centres 27.6°.
- Scaling a skin colour's scene chroma ×1.5 or its lightness ×0.8 at constant scene hue moves its DISPLAYED hue by up to 5–8° (and 12–18° for MST 9/10 at L×0.65). That is K2's 14° on MST 8: the stage holds hue to 1e-9.

### E-4. WS-02 / WS-32: the UI must write ring handles through `wireHandles`

`MixerBand.core/feather` are now wire units relative to each band's default (22.5 / 15 = "this band's default on this side"), not degrees. `ColorPanel.moveHandle` (ColorPanel.swift:397) still treats `MixerBand.defaultCore` as degrees around `bandHueCentres`. Use `ColorEngine.bandArcs(bands)[i]` to read degrees, edit the arc in degrees, and write back `ColorEngine.wireHandles(for: arc, band: i)`. Clamp in degrees to `bandCoreMinDegrees…bandCoreMaxDegrees` (3.4…44) and `bandFeatherMinDegrees…bandFeatherMaxDegrees` (12…60); `bandArcs` re-applies the per-side minimum reach.

### E-5. Spec owner: K4 and N4 cannot both pass

K4 needs Orange lum ±100 to move MST 10 (scene C 0.011) by ≥0.015 display L, which needs a mixer gate ≥ ~0.34 at C 0.011. N4 needs hue-wheel pixels of display C 0.01–0.02 (scene C 0.0115–0.023, all hues, L 0.565) to move ≤ 0.03 under all-bands ±100, which needs the gate ≤ ~0.2 across that whole range. A gate monotone in C cannot do both, and neither can one in C/L (MST 10's 0.042 equals the hue wheel's at C 0.024). The build keeps N4 (greys and grey-wall chroma noise stay untouched), so MST 1, 2, 9 and 10 (C 0.011–0.021) do not respond. K5 (MST 3–8 spread ≤ 3) is held at 3.9 by K3 on MST 6/7 together with MST 3/4's Orange share (0.42–0.44), which cannot rise without breaking G1 (sRGB yellow) or G4 (foliage) at transitions wide enough for X5.
