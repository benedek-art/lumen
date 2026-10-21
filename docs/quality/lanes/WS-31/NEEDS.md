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

### 6. Engine builder (WS-31): the band names

- U2 needs the rows labelled Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
- The panel reads `ColorEngine.bandNames`, which still says "Mint" and "Azure". Renaming them, along with the band geometry, makes U2 pass with no UI change.
- `MixerBandNameTests` pins Magenta as the widest name, and that stays true.
- `blackAndWhiteSection`'s help mentions "Azure" by name. That function is not WS-31's, so whoever owns it should update the word when the rename lands.

### 7. Swatch and track colours follow `ColorEngine.bandHueCentres`

- Nothing is needed for this. When the centres move, the swatches, the ring and every track recolour from the new centres.
- Checked with a Python port of `ColorPanel.paint(h:)` on both the current centres and [24, 57, 100, 142, 195, 258, 295, 332], after 8-bit quantisation:
  - worst swatch hue offset: 0.23° (current) and 0.32° (LR-like)
  - Saturation-track midpoint: 0.54° and 0.61°
