# WS-02 needs (changes outside the lane's owned functions)

Each item names its owner. None of these were made by WS-02.

1. **Disarm on context change** (AppState selection/workspace owners, LoupeView). `primarySelection.didSet`,
   workspace change (`enter(_:)`), `setMasking`, crop arm (`R`) and compare entry should call `cancelPick()`, so a
   stale prompt and the armed button styling do not linger. C2 (`PickArming`) makes the WRITE safe — a click on
   another photo or a moved index is refused with a message — but the prompt still shows until that click or Esc.
   This is the reverse direction of G1 (which refuses arming inside crop / two-pane).
2. **LoupeView `sourceFrameSize == nil` gate** (LoupeView). Do not mount `NeutralPickerOverlay` (or refuse the
   click) while `sourceFrameSize` is nil: the fallback `cg` size is the already-cropped preview, so on a cropped or
   straightened photo a click before the frame report lands maps through the wrong frame, and the sample-window
   radius is computed against the wrong source size (audit §3).
3. **MaskPanel armed styling and toggle-off** (WS-48 / MaskPanel). The mask "add sample" (MaskPanel ~1974, ~2574)
   and mask point-colour (~2634) buttons show no armed state and re-arm on a second press instead of cancelling.
   The WB button (H4) and ColorPanel's mixer / add-swatch buttons already toggle and show the armed look.
4. **Marquee sampling and a live loupe / RGB readout** (later, above Lightroom). A drag inside the catcher could
   define a rectangle mean for every target (the `DragGesture` is already there and collapses to its end point).
5. **S5 heal before the neutral sample** (audit §1.5). `sampleSceneLinearWindow` reads the raw decode, so a click
   on a healed spot samples the un-healed pixel. A fix applies `RenderGraph.applySpots` (and heal strokes) to the
   decode before the window read.
6. **Upright** (WS-25). The day `geometry.upright` is rendered in `applyGeometry`, `PipelineRenderer.geometryRects`
   AND `LumenCore.PickGeometry` must be extended together; `PickGeometryParityTests` will fail otherwise.
7. **Silent edge-snap** (cosmetic, PipelineRenderer `sampleMean`). The window clamps the click into [0,1] and
   intersects with the extent; a click at the very edge averages a smaller, shifted window without saying so.
8. **WS-03 courtesy note** (BasicPanel). H4 changed exactly two modifier arguments of the White Balance eyedropper
   button (~388-392): `.background` and `.foregroundStyle` now switch on `state.pickTarget == .neutral` (accent
   fill, black glyph when armed). No layout change; the line count of the file grew by two because each ternary
   was wrapped at the file's width.
