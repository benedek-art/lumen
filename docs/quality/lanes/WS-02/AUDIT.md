# WS-02 audit: eyedroppers & pick routing

Branch `quality/ws-02-08-pickers-zones`. Read-only audit, no source changed. Severity key:
**BUG** (wrong result or dead state), **LR-GAP** (works, but below Lightroom), **COSMETIC**.
AS = `Sources/LumenApp/AppState.swift`, PR = `Sources/LumenPipeline/PipelineRenderer.swift`,
RC = `Sources/LumenApp/RenderCoordinator.swift`, RG = `Sources/LumenPipeline/RenderGraph.swift`.

## 0. Routing table (what each target calls today)

| target | RC entry | PR sampler | tap | radius |
|---|---|---|---|---|
| `.neutral` | `solveNeutral` RC:931 | `sampleSceneLinear` PR:2360 | `source.decode` (pre-S3, pre-S5, pre-S6) | 2 (5x5 src px) |
| `.newPointColor` / `.pointColor(i)` / `.mixerBand` | `samplePointColorReference` RC:907 | `sampleColorStageInput` PR:2496 | `RG.colorStageInput(maskSource: true)` then `ColorEngine.selectionInput(tap)` | 2 |
| `.maskSample` | `sampleMaskReference` RC:839 | `sampleMaskStageInput` PR:2445 | `RG.localStageInput(maskSource: true)` | 2 |
| `.maskPointColor` | same | same, then `RR.localSelectionInput` (RR:396) | local stage input, then mask exposure/tone/WB and earlier swatches | 2 |

No caller passes `radius`. It is always the default of 2, at full decode resolution, whatever the zoom.

## 1. Sample space per target

**1.1 Neutral: correct space, and the as-shot handling checks out.** The decode runs at
camera-reference WB, so the as-shot neutral arrives as R=G=B (WhiteBalanceEngine.swift:4-6;
corpus sidecars say the same). `solveNeutral` applies `wb.matrix` and `neutralizing` inverts
it (WBE:239), so the search runs on the decoded value. That value is then pushed through
`adaptation(target→asShot)` (WBE:245), the same model `RenderPlan` uses. The residual is
"R=G=B in linear Rec.2020", which is D65 white in the space `sampleMean` reads back
(`extendedLinearITUR_2020`, PR:2620). The two agree. No fix needed.

**1.2 BUG (minor): no validity guard on the neutral sample.** RC:935 refuses only
`maxComponent <= 1e-9`. In practice it never refuses, so the "Too dark there" message (AS:4012)
is unreachable. There is also no clip check. A click on a specular highlight or a blown sky
(channel ≥ clip in the 5x5) solves a confident, wrong WB. Fix (inside `solveNeutral`'s
sampler, which is owned): have `sampleMean` also return the window's max and min. Refuse when
any channel reaches the decode's clip level, or when luminance is below about 0.002
(-6.5 EV under mid-grey, where the solve is mostly noise; see §2). Give a separate status
message for each case.

**1.3 BUG: the global Point Colour / Mixer tap skips S8 Presence and S3 denoise.**
`sampleColorStageInput` builds the stage with `Options(maskSource: true)` (PR:2516). The
render's colour stage receives the image after `applyPresence` (RG:217-219 runs only when
`!maskSource`). Dehaze moves levels and colour, and Clarity/Texture move local levels, so with
Dehaze set the stored swatch sits off the pixel S9 compares. This is the same class as AI-02,
one stage earlier. The doc comment on `sampleMaskStageInput` ("maskSource: true matches the
raster's own source") is right for masks and was copied to the one tap where it is wrong. Fix
(owned): use `maskSource: false` in `sampleColorStageInput`. The cost is a lazy region with
the presence blur's support, which is acceptable for a click.

**1.4 OK, with one stated approximation: the mask taps.** `colorRangePlane`
(MaskRaster.swift:1380) compares in OKLCh against the stored linear RGB of the same
`localStageInput`. Stored space and compared space are the same. The approximation is that
the raster's input is a 1024 px proxy while the sample is 5x5 at full resolution (PR:2433).
On a 24 MP frame one proxy pixel is about 6x6 source px, so the noise levels are similar by
accident. With the §2 change they would be matched on purpose.

**1.5 Note: the neutral misses S5 heal.** The render's S6 input is post-S3/S5, but
`sampleSceneLinear` reads the raw decode, so a click on a healed spot samples the un-healed
pixel. Denoise does not matter for a mean. Low priority. A fix would apply `RG.applySpots` to
the decode before `sampleMean`.

**1.6 BUG: an armed pick outlives everything except Esc and its own button** (see §5). The
catcher re-mounts on the next photo, so `.neutral`, `.newPointColor` and `.pointColor(i)` write
into a photo the pick was not armed on. `.pointColor(i)` can hit a different swatch, or none,
after a `−`. `.maskSample(maskID:component:)` holds an index, so after `removeComponent`
(MaskPanel:2560) the next click lands in the component that slid into that slot. A
`maskID` from another photo is a silent no-op, and AS:4135 then clears the status, so the
user sees nothing. The in-flight race is handled: AS:3986 disarms before the hop and
`selectionStillOnPickedPhoto` (AS:3998) guards the write. Fix (owned): store the photo URL and
a target identity in the armed state (`PickTarget` + `armedFor: URL`). `resolvePick` should
refuse, with a message, when the photo or the indexed object has changed. `cancelPick` should
be called from the selection change (needs AS `primarySelection.didSet`, not owned; write it in
NEEDS).

**1.7 BUG (minor): silent cap.** `.newPointColor` and `.maskPointColor` stop at 8 inside
`updateRecipe` (AS:4083, 4129), and the status is then set to nil. Arming is blocked at 8
(ColorPanel:597, MaskPanel:2636), but the multi-select fan-out can still hit the cap. Fix
(owned): check the count before writing and say "8 swatches is the limit".

## 2. Sample size

**What Lightroom/ACR do.** The WB Selector averages a **5x5 grid of screen pixels** at 100% zoom
or less, and 5x5 image pixels above 100%. Zooming out averages a larger area; Adobe staff
confirm the 5x5 grid ([Adobe community, 5x5 grid](https://community.adobe.com/t5/lightroom-classic-ideas/p-add-options-for-larger-sample-sizes-for-white-balance-eyedropper-tool/idc-p/12265462);
[ACR sample size thread](https://community.adobe.com/t5/camera-raw-discussions/how-do-i-check-and-or-change-the-sample-size-of-the-eyedropper-in-adobe-camera-raw/m-p/11875793);
[averaged-reading idea](https://community.adobe.com/t5/lightroom-classic-ideas/p-averaged-white-balance-reading-with-white-balance-selector/idi-p/12249642)).
The loupe shows the sampled grid with RGB values ([Peachpit, LR4 WB tool](https://peachpit.com/articles/article.aspx?p=1930494)).
Colour Range: click, Shift-click to add (up to 5), and **drag a rectangle** to sample an area,
which is recommended for gradients like skies
([Lightroom Killer Tips](https://lightroomkillertips.com/exploring-range-mask-options-color/);
[Masters Academy PDF](https://mastersacademy.com/wp-content/uploads/2020/06/MA_LR-ACR-Range-Mask.pdf)).
The same marquee drag reportedly works for the ACR eyedroppers (unverified against Adobe
docs). Users still complain that 5x5 wanders by a pixel move, so Lightroom is the floor here.

**Lumen today: 5x5 SOURCE px always** (PR:2362, 2448, 2499). In the 1512x982 window the viewer
is about 843 pt, or 1686 device px, wide (window-1512x982-develop.png). At Fit, one point covers
7.1 source px on a 24 MP 6024-px frame, 8.3 on a 33 MP A7 IV and 9.8 on a 45 MP frame. The
5x5 window is therefore about 0.6x0.6 pt, **smaller than one screen point**: it averages less
than the user can aim at. Lightroom's 5x5 device px at Fit on 24 MP is about 18x18 source px.

**Measured wander.** Six RAWs were decoded at native resolution with `decode_raw.py
--long-edge 0` (corpus .lfi files are area-downsampled to 2400 px, which hides noise). I took
the 3 flattest near-neutral 64 px patches per frame and simulated 120-300 clicks within ±8 px.
The solved neutral comes from the real `WhiteBalanceEngine.neutralizing`, through a scratch
binary linked to LumenCore. The table gives the **std-dev across adjacent clicks**, as
mired / tint units (median of 3 patches):

| frame (ISO) | 1x1 | 5x5 (today) | 11x11 | 21x21 | 41x41 |
|---|---|---|---|---|---|
| 1332 Canon 77D (3200), level 0.2 | 29.8 / 30.8 | **14.7 / 14.7** | 6.8 / 6.8 | 2.6 / 2.7 | 0.7 / 0.5 |
| 2348 Panasonic G9 (3200), level 0.09 | 28.5 / 21.1 | **15.3 / 10.7** | 8.2 / 4.3 | 3.3 / 1.7 | 1.0 / 0.7 |
| 2062 Canon X9 (6400), level 0.37 | 19.7 / 16.6 | **10.4 / 9.1** | 4.7 / 4.0 | 2.2 / 1.6 | 0.8 / 1.0 |
| 6933 Sony A7 IV (640) | 7.0 / 5.0 | **3.1 / 2.3** | 1.7 / 1.2 | 0.8 / 0.6 | 0.3 / 0.2 |
| 2545 Panasonic GX85 (200), sky | 8.8 / 8.6 | **5.7 / 5.6** | 3.8 / 3.7 | 2.2 / 1.8 | 1.2 / 0.9 |
| 4213 Nikon Z7 II (100) | 3.9 / 4.3 | **1.9 / 2.2** | 1.0 / 1.1 | 0.3 / 0.4 | 0.2 / 0.1 |

The green-channel CV at 5x5 is 2-4% at ISO 3200-6400. Going from 1x1 to 5x5 cuts noise by
only about 2x, not 5x, because demosaic correlates neighbours. At ISO 3200 the 5x5 neutral
wanders ±15 mired / ±15 tint at 1σ (p5-p95 spread about 50 mired, about ±600 K at 5000 K)
between two clicks on the same grey card. That is far above a visible WB step (about 5 mired).
21x21 brings every frame under 3.5 mired. The windows overlap at ±8 px jitter, so the 21/41
columns slightly flatter the result. Scratch scripts (not in repo): `/tmp/claude-0/-home-user-lumen/570f3fe6-32ea-58a4-833c-55f6084bcf78/scratchpad/py/noise.py` and `solve.py`.

**Proposal (LR-GAP, owned for the sampler and `resolvePick`; the overlay needs a one-line pass-through):**
- Side in source px = `max(5, ceil(5 × sourcePxPerDevicePx))`, capped at 63. This is Lightroom's
  5x5 screen-pixel rule with a 5 source-px floor above 100%. `PR.displayedPixelsPerSourcePixel`
  (PR:2677) already provides the ratio. `NeutralPickerOverlay` passes it with the click;
  `resolvePick(on:sourceX:sourceY:radius:)` forwards it to the existing `radius:` parameter of
  all three samplers. At Fit on 24 MP this gives about 19 px, which the table puts at about 3 mired at ISO 3200.
- Above Lightroom: let a drag in the catcher define a marquee (mean of the rectangle) for
  every target. The `DragGesture` is already there (ViewerOverlays:2304) and today collapses a drag to its end point.
- Make the measured number part of the spec: "5 adjacent clicks on 1332 patch: solved
  neutral sd < 4 mired at Fit".

## 3. Coordinate mapping

- **Crop / straighten / flip: consistent.** `sourceNormalized` (PR:2638) inverts the very
  `geometryRects` (PR:2302) that `applyGeometry` (PR:2704) draws with, and the crop is inscribed
  (`CropGeometry.resolve`), so the displayed frame has no empty wedges. A click can therefore
  never map outside the source. `sampleMean` clamps to [0,1] anyway (PR:2601), and that clamp
  is a silent edge-snap. The guard should refuse instead (COSMETIC).
- **Zoom / pan: consistent.** The catcher is laid out on `drawnFull` (LoupeView:1946), so it is
  never region-relative. It sits inside `.scaleEffect(stretch).offset(offset)` (LoupeView:2110),
  and SwiftUI reports `value.location` in the view's untransformed local space.
  `zoomHoldAllowed` is false while picking (LoupeView:2540), so `stretch` is 1.
- **Lens profile: consistent.** It is applied inside the decode (`isLensCorrectionEnabled`,
  AppleRawSource.swift:372). The samplers and the render read the same warped decode.
- **Upright: not rendered anywhere.** `geometry.upright` has no consumer in LumenPipeline or
  RR. Today that is not a mismatch, but the day it lands in `applyGeometry` the mapping
  breaks unless `geometryRects` is extended at the same time. Flag for the Upright lane.
- **BUG (narrow): wrong `sourceSize` fallback.** The catcher uses `sourceFrameSize ?? cg size`
  (LoupeView:2099). `primaryFrameSize` is nil'd on every photo switch (AS:358), and `cg` is the
  already-cropped preview, so a click on a cropped or straightened photo before the frame
  report lands maps through the wrong frame. Orientation is reconciled by
  `FrameOrientation.Memory`, which also learns only from a delivered whole frame, so a portrait
  RAW can briefly carry a transposed size. With identity geometry the size cancels out and
  nothing goes wrong; with a crop it does. Fix: do not mount the catcher (or refuse the click)
  while `sourceFrameSize == nil` (LoupeView, not owned → NEEDS).
- **BUG: the armed pick has no catcher in two viewer modes.** With the crop tool armed,
  `content` draws `cropCanvas` (LoupeView:1813), and with a two-pane before/after it draws
  `BeforeAfterPair` (:1817). Neither mounts `NeutralPickerOverlay`. `W` or a panel button arms
  the pick there, the prompt shows, and clicks go to the crop handles or do nothing. Fix:
  `beginPick` should refuse with a message (or leave the mode) when crop is armed or a two-pane
  compare is up (owned `beginPick` can read `LoupeViewport.shared`).
- **Tests: none.** No test anywhere covers `sourceNormalized`/`displayedNormalized`
  (`grep -rn sourceNormalized Tests/` → 0). They are `#if os(macOS)` CoreGraphics code.
  Proposal: a pure `CropGeometry.sourcePoint(displayedU:v:geometry:sourceWidth:sourceHeight:)`
  and `.displayedPoint(...)` in LumenCore. That is 2x2 rotate+flip arithmetic plus the
  `resolve` rects, which is already pure and Linux-tested (CropGeometryTests.swift). PR's pair
  would become thin wrappers. Tests: round trip < 1e-9 over angle ∈ {−45,−7.3,0,12}, flipH,
  crops; corners of the displayed frame land inside the source; a known 90°/flip case. Adding
  the function to CropGeometry belongs to the crop lane → NEEDS; the wrappers are WS-02's.

## 4. Cursor and feedback

- Armed: crosshair (`lumenPickCursor`, LumenHover:97, balanced pop on disappear) and a 2 pt
  accent border around the image (ViewerOverlays:2289). Prompts (AS:121-129): "Click something
  neutral grey in the picture." / "Click the colour to work on." / "Click a colour — its band
  selects itself." / "Click the colour this mask should select." / "Click the colour to work on
  inside this mask." They appear in the 22 pt status bar under the filmstrip (ContentView:1295),
  far from the image, and **none mention Esc** (COSMETIC → add "— Esc to cancel").
- **LR-GAP: no sample-area indicator or loupe.** Lightroom shows a magnified grid with the RGB
  readout under the WB selector. Lumen shows nothing about where or how big the sample is.
  Proposal: a ring or square at the §2 side, in screen points, following the pointer. Live
  readout optional.
- **Armed state not visible on the WB button** (BasicPanel:384-391 has the same fill and
  foreground armed or not; only `.help` changes). The mixer (ColorPanel:625) and point-colour add
  (ColorPanel:410) buttons do show it. **The mask "add sample" and mask point-colour buttons
  show no armed state and do not toggle off** (MaskPanel:1974, 2574, 2634): pressing again
  re-arms. COSMETIC/BUG.
- After the pick: neutral says "Neutral picked — 5120 K, tint 4" (AS:4021). Mixer says "Red
  selected." **Point colour and mask picks clear the status to nil** (AS:4135), so the only
  feedback is the image changing. Proposal: "Swatch 3 added" / "Sample 2 of 8 added" / "Swatch 1
  re-sampled".
- Click outside the image (letterbox): the catcher covers `drawn` only. The click falls through
  to the pan layer and the pick stays armed, which is fine. A drag inside the image while armed
  is taken as a pick at release, so panning needs scroll/pinch (acceptable; becomes the marquee in §2).

## 5. Escape and disarm paths

| path | disarms? | evidence |
|---|---|---|
| Esc, nothing focused | yes | Keymap:643 |
| Esc while a slider holds focus | **first Esc only drops slider focus**; prompt and crosshair stay; second Esc cancels | Keymap:640 returns nil before the pick check. Clicking a panel eyedropper does not take focus from a slider |
| same button again | WB, W key, mixer, point-colour add, swatch chip: yes. **Mask add-sample / mask swatch: no** | BasicPanel:379, ShortcutParityKeys:36, ColorPanel:570/594/611; MaskPanel:2574/2638 |
| switch photo | **no** (re-mounts on the new photo, §1.6) | no `cancelPick` in `primarySelection.didSet` (AS:346-400) |
| switch panel / workspace / enter masking / Grid | **no** | `setMasking`, `enter(_:)` don't touch `pickTarget`; `showGrid` leaves it armed; the catcher re-mounts on the next loupe visit |
| crop armed / two-pane compare | armed with no catcher (§3) | LoupeView:1813-1823 |
| pick in flight | disarmed before await; guarded on return | AS:3986, 3998 |

Fix: (a) in the Esc branch, check `pickTarget` *before* `sliderHoldsFocus` (an armed pick is
the innermost thing, since the user clicked a picker after the slider), or have `beginPick`
resign slider focus. Keymap is not owned → NEEDS. (b) `cancelPick()` on selection change,
workspace change, `setMasking`, crop arm and compare entry → NEEDS for each owner. Within the
owned code, `resolvePick` refuses a stale target (§1.6) as defence in depth.

## 6. UI snapshots (baseline `claude-inspiring-dirac-ulgpch/a93efb2/`)

Looked at: `panel-develop-white-balance.png` (eyedropper icon at right of the preset row, unarmed),
`panel-grade-colour-point-colour.png` ("Pick a colour" mixer button and the point-colour
eyedropper, both unarmed, two swatches), `window-1512x982-develop.png` (viewer extent, status bar).
**Not captured:** any armed picker, the armed image border, the status prompt, a Colour Range or
Colour Pick mask component (with its add-sample chips), or the mask point-colour picker. The
cursor cannot be captured. Cases to append to `PanelSnapshotTests.renderPanels` /
`renderWindow`:
1. `panel-develop-white-balance-armed`: `state.beginPick(.neutral)` then render `.whiteBalance`.
   This should look identical to the unarmed shot today, which documents the §4 defect.
2. `panel-grade-colour-armed`: after `addPointColours`, `beginPick(.newPointColor)`, then render.
   Also `.pointColor(index: 0)` and `.mixerBand`.
3. `panel-masks-colour-range`: a mask with a `.colorRange` component carrying 2 samples, plus
   `beginPick(.maskSample(maskID:component: 0))`.
4. `window-1512x982-develop-picking`: `state.enter(.develop); state.beginPick(.neutral)` and render
   `ContentView` (border plus status prompt in situ).

## Owned vs NEEDS summary

Owned fixes: §1.2 clip/dark guard; §1.3 `maskSource:false` in `sampleColorStageInput`; §1.6
armed-for identity and stale-target refusal; §1.7 cap message; §2 radius parameter through
`resolvePick` and the samplers; §3 `beginPick` refusing in crop/two-pane; §4 prompt text and
post-pick messages. NEEDS: LoupeView (`sourceFrameSize` nil gate, zoom ratio pass-through,
sample ring), ViewerOverlays (radius and marquee in the catcher), Keymap Esc order,
selection/workspace/masking `cancelPick` hooks, CropGeometry pure mapping (crop lane),
BasicPanel and MaskPanel armed styling and toggles, Upright lane awareness of `geometryRects`.
