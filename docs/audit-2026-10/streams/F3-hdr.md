# F3-hdr: the HDR viewport, first slice

Stream agent F3-hdr. Base: `claude/jolly-sagan-k7ch7z` at `0896556`. Worktree branch
`worktree-agent-a12f64bf9d9b765f6`. Build dir `/tmp/lumen-build-f3`, Linux. Task: README says
"ISO 21496-1 gain-map maths. The HDR viewport is not built." Spec sources are docs/11 §"The EDR
editing viewport" and §"HDR export", docs/14 §7 and docs/13's EDR row.

LumenPipeline and LumenApp cannot build here. Their changes are **source-verified**: every AppKit,
Metal and Core Image member was checked by name, the code was traced by hand, and
`scripts/check-swift-surface.py` exits 0 (its fixture suite passes 27/27). The LumenCore half
runs on Linux, and every test in it was shown red under a mutation.

## Items

| Item | Status | Commit | Red / green | Proof records that move |
|---|---|---|---|---|
| Headroom arithmetic: white target, badge, plate placement, content settings (LumenCore) | **BUILT** | `0872292` | `EDRPreviewTests` 12/12 green on Linux. Mutations: quantize-before-compare 74 red (the first draft had this bug), round-up 167 red in 4 tests, no potential guard 15 red, full target ¼ stop off 661 red incl. the gain-map round trip | none |
| HDR rendition vs gain-map decoder round trip (LumenCore) | **BUILT** | `0872292` | `testAGainMapDecoderReproducesThePreviewedRendition`: ReferenceRenderer SDR and HDR, 8-bit per-channel map, `GainMap.reconstruct` returns the previewed frame at full headroom (half-step bound) and the SDR base at zero headroom | none |
| EDR frame from the renderer (`renderPreviewEDR`, half-float extended-linear sRGB, own table-cache identity) | **BUILT**, source-verified | `f6744e4` | `EDRPreviewRenderTests` (macOS): EDR frame vs `renderHDRPair.hdr`, SDR settle byte-identical beside EDR passes, SDR draft byte-identical after an EDR pass (red traced by hand against a shared identity), regions agree | none |
| Loupe toggle, CAMetalLayer EDR view, headroom badge, coordinator pass | **BUILT**, source-verified | `3b3cdee` | `testWithThePreviewOffTheSDRFrameIsTheCallItWas` (Linux, source scan): 1 red with `edrWhiteTarget:` threaded into the SDR call, green restored | none |
| SDR byte-identity with the preview off | **HELD** | `f6744e4`, `3b3cdee` | By construction, `renderPreviewDelivery` is untouched, the coordinator's SDR call has the same arguments, and the EDR pass sits behind `if let edrWhiteTarget`. Pinned by the source scan above. On macOS the SDR settle and draft bytes are compared with and without an EDR pass on the same cache | none |

## What it does

View ▸ **HDR Preview** turns it on. It has no key and is off at every launch.

1. `EDRDisplay` watches `NSScreen.main`'s `maximumExtendedDynamicRangeColorComponentValue` and
   `maximumPotentialExtendedDynamicRangeColorComponentValue`. It updates on
   `NSApplication.didChangeScreenParametersNotification`, on `NSWindow.didChangeScreenNotification`
   and on a 1 s poll, only while the preview is on. It publishes only when the headroom crosses an
   eighth of a stop.
2. `EDRPreview.whiteTarget` picks the render:
   - **nil** (the SDR frame only) when the preview is off, or the potential headroom is under ⅛ stop.
   - **The export's own HDR white** when the display covers the content. This is
     `100·2^clamp(headroomEV,0,4)`, the same expression as `HDRSettings.whiteTargetPercent`, held to
     it with `==`. The content settings come from the first enabled gain-map export recipe, else the
     first gain-map recipe, else +2 EV.
   - **The display's own headroom, rounded down to ⅛ stop**, when the display covers less than the
     content. This is docs/14 §7's `min(content peak, display headroom)`. It rounds down because a
     CAMetalLayer does not tone-map.
   - **100** on a capable panel that has not raised its headroom yet. This puts the EDR layer on
     screen, which is what makes the OS raise the headroom.
3. With a target set, `RenderCoordinator.produce` still renders the SDR frame exactly as before.
   After that it calls `renderPreviewEDR`, which runs the same graph, geometry and region at the
   target. The result is RGBAh in `extendedLinearSRGB` with no dither. The coordinator keeps it only
   if its region and size match the SDR frame's.
4. `PhotoRenderModel.edrImage` sits beside `image`, and both are set in one `apply`. The canvas draws
   `EDRImageView` behind its stack and puts a transparent stand-in where the plate was.
   `EDRImageView` is an NSView backed by a `CAMetalLayer` (`.rgba16Float`, `colorspace`
   extendedLinearSRGB, `wantsExtendedDynamicRangeContent`, `framebufferOnly = false`). Core Image
   renders into the drawable with `render(_:to:commandBuffer:bounds:colorSpace:)`.
5. The badge reads `HDR · +2.0 EV`, `HDR · +1.2 OF +2.0 EV` or `HDR · SDR DISPLAY`.

`model.image` stays the SDR frame. The scopes, readout, clipping, peaking, the developed-preview
cache and the before plates therefore measure the SDR rendition (the gain map's deliberate base)
whether the preview is on or off.

## DECISIONS

1. **Opt-in toggle vs "no mode switch".** docs/11 says HDR should just look HDR with no ceremony,
   and ⌥H should snap to SDR. I built the conservative inverse instead: off by default, a View-menu
   item, and no key. Making it the default changes the look of the loupe for every user on an EDR
   Mac. It should wait until the owner has seen it on a panel. Owner's call: default on/off, and
   whether ⌥H means "HDR preview" or "SDR proof".
2. **Below the content's headroom: transform at the display peak vs what a gain-map viewer shows.**
   I implemented docs/14 §7: re-run the transform with white equal to the display's headroom.
   Photos, given the exported file on that display, would instead show the base plus a
   partially weighted gain (`GainMap.reconstruct`, weight = display/content). The two agree at full
   headroom and at zero, and differ in between. The docs/11 "delivery preview" with its three stops
   (This display / Low headroom / SDR only) is the place to show the decoder's view. It is not built.
3. **Which export recipe's HDR settings.** The first enabled gain-map recipe, else the first
   gain-map recipe, else +2 EV. The owner may prefer a per-session choice in the badge.
4. **Wide gamut.** The EDR frame is extended-linear sRGB, so colours outside sRGB that the 8-bit SDR
   frame clips survive in HDR mode on a P3 panel. Turning the preview on can therefore change
   saturated colours slightly as well as highlights. The alternative is clamping negatives, which
   throws the gamut away.
5. **Before/after in HDR mode.** The split and the `\` flip draw the SDR before and the SDR after,
   so they compare edits rather than renditions. Two-pane compare is SDR too. An HDR before
   rendition is possible (the before model would take the same target) if the owner wants it.
6. **No slew.** docs/14 asks for the white target to glide over about 200 ms when headroom changes.
   This slice re-renders once per ⅛-stop step.

## FOUND-WHILE-FIXING

- **`ExportRecipe.hdrIsWritable` is still `false`.** No file carries a gain map yet, so the preview
  shows the rendition a gain-map writer *would* encode (`renderHDRPair.hdr`). Building the writer is
  a separate stream.
- **Cost.** With the preview on, each request evaluates the graph twice: SDR for the instruments and
  EDR for the screen. The draft ladder measures the sum and steps down. A cheaper design shares the
  graph up to S14 (docs/14 §7, "one shared S14-input checkpoint") and needs a Mac to measure.
- **Cache identity.** Any second rendition at a different display white, on the same photograph,
  through the draft stale door, borrows the other's finish table under a shared identity. The EDR
  pass is filed under `"<identity>|edr"`, and `EDRPreviewRenderTests` holds the SDR draft to the
  bytes it has with no EDR pass. An EDR settle can adopt shared exact-hit colour-grade/tone-gain
  entries into the EDR identity, so a following SDR *draft* may bake those exactly instead of
  serving them stale. That changes what the SDR draft shows, though only while the preview is on
  (when it is not on screen), and only for edits that move those keys.
- **Needs a Mac to confirm:**
  - that the OS raises `maximumExtendedDynamicRangeColorComponentValue` once the EDR layer shows
    SDR-white content (on panels that report 1.0 at rest);
  - that the CI→drawable render is upright;
  - that the container-sized layer composes correctly under the SwiftUI overlays.
  `EDRImageView` deliberately does not rely on SwiftUI transforming or clipping a hosted NSView.
- **Downscale quality.** The EDR layer resamples with linear (or nearest) sampling, not the SDR
  plate's high-quality interpolation. A Lanczos pass would match it when the frame is larger than
  the viewport.
- `check-swift-surface.py` did not know `CAMetalLayer`, `CALayer`, `Metal`, `QuartzCore` or
  `NSObjectProtocol`, and read `MTLCommandBuffer.commit()` as the updater's `commit(inReleaseBody:)`.
  Both hunks are small and the fixture suite still passes.
