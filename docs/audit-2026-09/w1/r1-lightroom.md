# R1 — Lightroom Classic 15.5 (Aug 2026), control-by-control

Refresh of `docs/02-research-lightroom.md` against the current release, at the resolution the
audit asked for. Per area: capability · how it works · tag · **Lumen would need** (from `Sources/`,
grepped 2026-09-01 — a "present in code" note is a grep hit, not a behavioural verification;
the auditor still runs it).

Tags: `[search: url]` = a search-result summary stated it · `[knowledge]` = training, not
re-verified · `[docs/02 §n]` = already in the repo. helpx.adobe.com, jkost.com,
lightroomqueen.com and mastering-lightroom.com are all egress-blocked for fetch (each tried
once); every web claim below therefore rests on search summaries, not full pages.

Version context (unchanged from docs/02 §1): 15.5 shipped 2026-08-03. 15.5 headline list per
Adobe's announcement and Lightroom Queen: Feather + Edge on masks (extended to AI masks), Render
to DNG, temporary crop-shield opacity, Flatten AI Edits (supports Generative Expand round-trips),
Denoise fixes `[search: https://community.adobe.com/announcements-673/lightroom-classic-v15-5-is-here-better-masking-controls-render-to-dng-and-more-1635193]`
`[search: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/]`.

---

## A · Tone & sliders

### A.1 The slider contract (brief item 7)

| Gesture | LrC behaviour | Tag |
|---|---|---|
| Drag knob | Linear, value shown live in the readout | [docs/02 §2.3] |
| **⇧-drag** | Slows the drag for fine placement (not ×10 — the opposite) | [search: https://community.adobe.com/t5/lightroom-classic-discussions/how-to-adjust-only-1-value-on-the-slider/td-p/11454018] |
| **⌥-drag** on Exposure/Highlights/Shadows/Whites/Blacks | Threshold clipping view (Whites/Highlights/Exposure clip on black; Blacks/Shadows on white; r/g/b/c/m/y = channel combos). On Sharpening/NR/Defringe/Range-Refine ⌥-drag = the panel's own visualisation. | [docs/02 §2.3, §2.13, §2.18] |
| Scrubby on the number | Click-drag left/right on the numeric readout | [docs/02 §2.3] |
| Type-in | Click the number → text field; Enter commits; no arithmetic | [knowledge] |
| **Hover + ↑/↓** | Default step: 5 units on ±100 sliders, **0.10** on Exposure | [search: same thread] |
| **⇧+↑/↓** | 10 units / **0.33** EV | [search: same thread] |
| **⌥+↑/↓** | 1 unit / **0.02** EV (the fine step) | [search: same thread] |
| Arrows inside the focused number field | Smallest increment (1 / 0.01); ⇧ enlarges | [search: same thread] |
| **Double-click label or knob** | Reset to default (a 2025 build briefly broke this and drew complaint threads) | [docs/02 §2.3, docs/00 Law 19] |
| Double-click a **group** name ("Tone", "Presence") | Resets the whole group; ⌥ held turns headers into "Reset Tone"/"Reset Presence" click targets | [search: https://fstoppers.com/lightroom/keyboard-shortcuts-actually-speed-lightroom-classic-718346] [docs/02 §2.3] |
| **⇧-double-click** a slider label | Per-slider Auto (Whites/Blacks = histogram-endpoint stretch; others = ML value) | [docs/02 §2.3] |
| **Auto** button (⌘U) | Sets Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Vibrance, Saturation only; analyses pre-crop | [docs/02 §2.5] |
| Wheel over a slider | Nothing by default (scroll pans the panel) | [knowledge] |

**Lumen would need:** `Sources/LumenCore/Interaction/SliderDrag.swift` has ⇧ = fine drag (matches
LrC's ⇧-slows), `SliderEntry.swift` adds arithmetic entry (`+=0.3`, `*2` — beyond LrC).
`Sources/LumenApp/LumenControls.swift` header states the shipped contract: click-row focus,
←/→ nudge one step, ⇧ ×10, ⌥-scroll nudge, double-click reset, per-row auto ("Set … automatically"),
and lists as *absent*: ⌘-double-click to auto, ⇧⌥-drag to hard limit, hold-to-sweep. Gaps vs LrC:
**⌥-arrow fine step**, hover-without-focus arrow nudge (Lumen requires row focus; LrC only hover),
↑/↓ vs Lumen's ←/→ axis, ⇧-double-click-label auto.

### A.2 Tone model (brief item 8)

- **Exposure ±5 EV**: PV2012 is not linear gain — midtone-weighted with automatic highlight
  roll-off; +1.0 ≈ +1 stop in midtones, brights compress. **Contrast ±100**: S-curve pivoting
  near mid-grey (community: ≈ L*50). **Highlights/Shadows ±100**: range-targeted compression;
  Highlights never moves the white point, works inside the boundary Whites sets. **Whites/Blacks
  ±100**: set the clip points; ⌥-drag shows clipping. Defaults all 0. Panel order Exposure,
  Contrast, Highlights, Shadows, Whites, Blacks. [docs/02 §2.3]
- **Tone Curve**: icon tabs Parametric | Point (RGB) | R | G | B. Parametric: four region sliders
  (Highlights/Lights/Darks/Shadows ±100) + three split triangles under the graph (default
  25/50/75 %, draggable; double-click a split resets it [knowledge]). Point: click-to-add;
  drag; right-click → Delete Control Point / Flatten Curve; typed Input/Output (0–255 or %);
  legacy Linear / Medium / Strong Contrast preset menu still present on the point curve
  [knowledge]. **Refine Saturation 0–100 (default 100 = legacy chroma amplification)**.
  TAT ⌘⌥⇧T drags up/down on the image. Panel eye latches off with ⌥-click. [docs/02 §2.7]
- **Histogram**: five draggable zones (Blacks | Shadows | Exposure | Highlights | Whites),
  hover names the slider, drag moves it; corner triangles hover = temporary clip overlay,
  click = latched, **J** toggles both; readouts in "Melissa RGB" 0–100 %. [docs/02 §2.6]

**Lumen would need:** `Sources/LumenApp/HistogramView.swift` implements the five-zone scrub +
two channel-diagnostic triangles (present). `Sources/LumenApp/CurveEditorView.swift` has
Parametric/Point/Luma/channel modes with movable splits (present); `refineSaturation` appears in
`Recipe.swift` only — auditor: confirm it reaches a kernel. Legacy contrast-preset menu:
not found (acceptable omission per docs/02 §6.2).

---

## B · Colour & grading

### B.1 Point Color (brief item 3)

| Control | Behaviour | Tag |
|---|---|---|
| Eyedropper | Click samples a colour (loupe-assisted); ⇧-click not used here — each click adds a **new swatch, up to 8** per photo and per mask | [search: https://lightroomkillertips.com/get-to-know-point-color-in-lightroom-classic/] |
| Swatch | Split original/adjusted; selected swatch has a pin at the sample point on the image; rows removable with × | [docs/02 §2.9] [knowledge] |
| Colour field + luminance ramp | 2-D hue×sat field with draggable dot; separate vertical luminance rectangle; dragging either writes the Shift sliders | [search: https://mastering-lightroom.com/point-color-lightroom-classic/] |
| Hue Shift / Saturation Shift / Luminance Shift | Relative to the sample; all ±100 (numeric ranges not in any reachable source — `[knowledge]`) | |
| **Range** 0–100, default 50 | Master falloff; right = wider set of pixels affected | [search: https://lightroomkillertips.com/get-to-know-point-color-in-lightroom-classic/] (default value `[knowledge]`) |
| Range disclosure ▸ | Three sub-fields — Hue / Saturation / Luminance range — each a bar with two end arrows + a numeric box | [search: same] |
| **Visualize Range** checkbox | Everything outside the range renders grayscale, in-range stays coloured; ⌥-drag on any shift/range slider shows the same live | [search: same] [docs/02 §2.9] |
| **Variance** −100…+100 (15.0) | Negative pulls hues near the sample together (evens polarised skies, unifies skin); positive pushes them apart; preserves texture | [search: https://www.digitalcameraworld.com/tech/software/lightroom-has-a-new-slider-and-its-a-game-changer-for-fixing-red-skin-meet-the-new-color-variance-tool] |
| Availability | Global (Color Mixer › Point Color tab) and inside every mask's Color section | [docs/02 §3.3] |

**Lumen would need:** `Sources/LumenApp/ColorPanel.swift` has `pointColorSection`, swatches,
`variance` (13 files incl. kernels). Auditor: check for a Visualize-Range toggle and for the three
independent H/S/L range sub-controls; grep found `range`/`visuali` only generically.

### B.2 Mixer, Color Grading, Calibration, Vibrance (brief item 9)

- **Color Mixer**: 8 bands (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta), Hue/Sat/Lum
  each ±100; view selector Hue | Saturation | Luminance | All; TAT moves every band containing the
  clicked hue proportionally. **B&W** tab replaces it under Treatment = Black & White (**V**):
  8 sliders ±100 + Auto. [docs/02 §2.8, §2.12]
- **Color Grading**: views 3-Way | Shadows | Midtones | Highlights | Global. Per wheel: rim drag =
  Hue 0–360, radial = Saturation 0–100, Luminance ±100 slider under each; **Blending 0–100
  (default 50)** = zone overlap width, **Balance ±100 (default 0)** = shifts the shadow/highlight
  boundary. Modifiers on the wheel: ⌘ = hue-only, ⇧ = sat-only, ⌥ = fine. Zone pivots invisible.
  [docs/02 §2.10]
- **Calibration**: Process dropdown (Version 1–6), Shadows Tint, Red/Green/Blue Primary Hue &
  Saturation ±100 each. [docs/02 §2.11]
- **Vibrance vs Saturation**: Vibrance ±100 is non-linear (boosts low-sat more, clips less,
  protects skin hues); Saturation ±100 is linear/global. [docs/02 §2.4]

**Lumen would need:** `RecipeLook.swift` `GradingWheels` has global/shadows/mid/high, blending,
balance **and `pivots`** (beyond LrC); `Primaries` present; `ColorPanel` mixer has 8 bands +
`uniformity`. ⌘/⇧ wheel modifiers: not grepped — auditor check in `LumenControls`/wheel view.

---

## C · Film & grain

- **Effects › Grain**: Amount 0–100 (default 0), Size 0–100 (default 25), Roughness 0–100
  (default 50). Monochrome luminance grain applied late; no per-channel or stock model. Also a
  **local** Grain slider inside masks (Effects section of the mask panel, since PV6).
  [docs/02 §2.18, §3.3] [search: https://helpx.adobe.com/sg/lightroom-classic/help/masking.html]
- Film "looks" exist only as Creative profiles / third-party presets (LUT-based); no film
  simulation engine. [docs/02 §2.1]

**Lumen would need:** `CreativeGrain` (Amount/Size/Roughness) in `Recipe.swift` on the
density-domain `FilmGrainProfile`; `FilmLab.swift` is beyond LrC. Local grain per mask: auditor
check `RecipeMasks.swift` adjust keys (grep saw `exposure…tint` list; grain not confirmed).

---

## D · Looks / presets & effects

### D.1 Presets (brief item 6)

| Capability | How it works | Tag |
|---|---|---|
| Panel | Develop left column; groups are collapsible folders; user groups + Adobe's (Premium: Portraits, Landscape, B&W, Cinematic, Travel, Vintage…; **Adaptive: Portrait, Sky, Subject**) | [search: https://lightroomkillertips.com/adaptive-presets-in-lightroom-classic-part-1/] |
| Hover preview | Hovering a preset live-previews on the Loupe image **and** the Navigator; Preferences › Performance › "Enable hover preview of presets in Loupe" can restrict it to the Navigator | [search: https://helpx.adobe.com/lightroom-classic/help/apply-presets.html] |
| **Amount** 0–200 (default 100) | Above the preset list; moves every slider the preset saved by a relative factor; unsaved sliders untouched. Greyed out unless the preset was saved with **Support Amount Slider** checked; the checkbox itself is disabled when the preset contains settings that cannot scale (e.g. profile-only, curves in some cases) | [search: same] [search: https://community.adobe.com/t5/lightroom-classic-discussions/preset-amount-slider/m-p/13136226] |
| Adaptive presets | Store an AI mask *recipe* (Subject/Sky/People) + local settings; on apply the mask is recomputed on the target photo; require the AI models locally; visible "Update AI settings" if stale | [docs/02 §2.20] [search: https://asktimgrey.com/2022/10/24/adaptive-presets-in-lightroom-classic-12/] |
| ISO-adaptive presets | Saved from ≥2 photos at different ISOs; linear interpolation between anchors; usable as raw default | [docs/02 §2.20] |
| Save dialog | Checkbox tree of every panel; "Support Amount Slider"; group picker; on save, preset writes an `.xmp` in `Develop Presets/` | [knowledge] |

**Lumen would need:** `Sources/LumenApp/LookPanel.swift` line ~167 states "No hover preview
either (audit UX-17 wants one)". `Look` struct copies "plus look-tagged masks" (an adaptive-preset
seed). No preset-level Amount found (`LUTReference.amount`, `filmLab.amount` are per-stage).

### D.2 Lens Blur (brief item 4)

| Control | Behaviour | Tag |
|---|---|---|
| Apply checkbox | Triggers monocular depth estimation (Sensei) on first use; if the file has a **device depth map** (HEIC Portrait) a ⋯ menu offers "Use device depth"; no ⋯ = no embedded depth | [search: https://helpx.adobe.com/in/lightroom-classic/help/lens-blur.html] [search: https://www.lightroomqueen.com/community/threads/lens-blur-with-camera-depth-maps.48785/] |
| Blur Amount 0–100, default 50 | Intensity | [search: helpx lens-blur] |
| Bokeh | Circle, Bubble, 5-blade, Ring, **Anamorphic** (oval) — Adobe's help lists five; docs/02 listed "Cat-eye" as a sixth (unverified). **Boost** slider brightens specular highlights | [search: helpx lens-blur] |
| Focal Range | Horizontal depth strip (near→far); a white rectangle = in-focus band; drag the body to move it, drag either edge to widen/narrow. Clicking on the image sets focus to that depth | [search: helpx lens-blur] |
| Visualize Depth | False-colour overlay keyed to the strip's colours; white = in-focus band | [search: helpx lens-blur] |
| Refine | Brush painting **Focus** or **Blur** into the depth map; brush Size/Feather/Flow | [search: helpx lens-blur] |
| Cost | Depth model runs once per photo, seconds to tens of seconds; well-documented session-wide GPU slowdown; no panel eye | [docs/02 §2.17] |

**Lumen would need:** absent (only a `depthMap` mention in `MaskRaster.swift`); `depthRange`
mask kind exists in `RecipeMasks.swift` without a depth source.

### D.3 Vignette (brief item 14)

Post-Crop Vignetting: **Style** Highlight Priority (default) / Color Priority / Paint Overlay;
**Amount −100…+100 (0)**, **Midpoint 0–100 (50)**, **Roundness −100…+100 (0)**, **Feather
0–100 (50)**, **Highlights 0–100 (0)** — Highlights enabled only when Amount < 0 in the two
Priority styles. Lens-Corrections › Manual also has a pre-crop Vignetting Amount/Midpoint.
[docs/02 §2.18] [knowledge for defaults 50/50]

**Lumen would need:** `EffectsPanel.swift` vignette is EV-denominated with Amount + Feather only
(comment: "no Highlight/Colour Priority dropdown … position in the pipeline does that work").
Absent vs LrC: Midpoint, Roundness, Highlights.

---

## E · Denoise & sharpening

### E.1 Denoise (brief item 5)

- Since **14.4** (Jun 2025) Denoise, Raw Details and Super Resolution are **toggles in the Detail
  panel**, non-destructive; the Enhance dialog and the `-Enhanced-NR.dng` side-car are gone.
  Result raster is cached in `<catalog>.lrcat-data`. First enable runs the model; **Amount 0–100
  (default 50) is greyed until that run completes**, then re-blends instantly without recompute;
  toggling off/on does not recompute. Batch: select many → enable in one go (14.4 forum threads
  on how). [search: https://blog.thomasfitzgeraldphotography.com/blog/2025/6/lightroom-144-released-big-changes-to-raw-details-denoise-and-super-resolution] [search: https://mastering-lightroom.com/lightroom-classic-update-june-2025/]
- Greyed out when the file is not a mosaic raw: mRAW/sRAW, linear DNG, JPEG/TIFF/PSD/PSB, and
  already-denoised legacy DNGs. Adobe's UI gives no reason (open idea thread). [search: https://community.adobe.com/t5/lightroom-classic-ideas/p-tell-the-user-why-denoise-and-raw-details-are-greyed-out/idi-p/13748744]
- Speed: GPU-scaled; 15.4 added Apple Neural Engine (M4 Mini 32 MP 40 s → 13 s; M1 Air 85 → 25 s;
  M4 Max ≈ 5 s); 15.4 was pulled for posterisation, fixed in 15.5. [docs/02 §2.15]
- Enabling Denoise auto-enables Raw Details; sharpening and manual NR still apply after, on the
  denoised raster. [docs/02 §2.15, §2.14]
- Render to DNG (15.5) is the new way to bake a denoised/edited file to a portable DNG. [search: Lightroom Queen 15.5]

**Lumen would need:** `DenoiseEngine.swift` implements a cached S2 artifact + Amount blend
(matches the post-14.4 design) and S3 classical NR; `DetailPanel.swift` has a Denoise fold.
Wire carries only luma/chroma/hotPixels — the four LR sub-sliders are engine constants (stated in
the file header).

### E.2 Sharpening & manual NR (brief item 10)

Sharpening: Amount 0–150 (raw 40 / JPEG 0), Radius 0.5–3.0 (1.0), Detail 0–100 (25), Masking
0–100 (0); **⌥-drag each** = grayscale / edge / high-freq / white-sharpened-black-protected
previews; only live at ≥100 % zoom (a preview-zoom warning shows otherwise) [knowledge for the
zoom rule]. NR: Luminance 0–100 (0) + Detail (50) + Contrast (0); Color (raw 25) + Detail (50) +
Smoothness (50). Masks get a single **Sharpness** (−100…+100) and **Noise** slider. [docs/02 §2.13–2.14, §3.3]

**Lumen would need:** `DetailPanel.swift` deliberately has no Radius row; ⌥-preview modes not
found by grep (`clipping` hits are histogram). Local Sharpness/Noise in masks: check
`RecipeMasks` `detail` adjust group (grep saw `case light / colour / detail`).

---

## F · Masks

### F.1 On-canvas grammar — Radial Gradient (⇧M)

| Element / gesture | Behaviour | Tag |
|---|---|---|
| Create | Click-drag from corner-to-corner of the ellipse's bounding box. **⌥-drag** draws from the centre outward. **⇧-drag** constrains to a circle. Release = component created, panel selects it | [search: https://community.adobe.com/questions-675/can-t-move-or-rotate-radial-gradient-mask-in-lightroom-classic-963035] |
| **⌘-double-click** on empty canvas | Creates a radial centred on and covering the cropped image | [search: https://jkost.com/blog/2024/09/making-selective-edits-using-the-masking-tools-in-lightroom-classic.html] |
| **⌘-double-click** inside an existing radial | Expands that radial to cover the cropped image | [search: same] |
| Plain double-click | Commits and closes the tool | [search: same] |
| Centre pin | Grey dot at ellipse centre; drag inside the ellipse = **move**; the pin shows the mask's colour dot; hover shows the overlay temporarily | [search: https://helpx.adobe.com/lightroom-classic/help/lightroom-radial-filter.html] [docs/02 §3.2] |
| Four edge handles | Small squares at N/S/E/W of the ellipse; drag = resize that axis; **⇧-drag a handle preserves aspect**; **⌥-drag scales from the opposite corner** rather than the centre | [search: helpx radial-filter] [search: community thread above] |
| Feather ring | Inner concentric dashed ellipse; drag it in/out to set **Feather 0–100 (default 50)**; ring vanishes at 0 | [search: helpx radial-filter] |
| Rotate | Hover just **outside** the ellipse edge (between handles) → cursor becomes a curved-arrow rotate icon; drag rotates about the centre; **⇧ snaps to 15°** | [search: helpx radial-filter] [search: community thread] |
| Drag outside the ellipse | Starts a **new** radial (same mask if Add/Subtract is armed, else new mask) | [knowledge] |
| Invert | Panel checkbox per component; `'` inverts the selected component | [docs/02 §3.1] |
| Duplicate | **⌘⌥-drag** the pin, or right-click pin › Duplicate | [search: https://blogs.adobe.com/jkost/2013/04/lightroom-5-beta-duplicating-local-adjustments-in-the-develop-module.html] |
| Delete | Select → **Delete/Backspace** | [search: same] |
| Pin visibility | Toolbar **Show Edit Pins**: Auto / Always / Selected / Never (also Tools › Tool Overlay); **H** toggles Auto↔Never; in Auto the pins hide while the pointer is off the image | [search: https://www.lightroomqueen.com/community/threads/lightroom-classic-mask-color-overlays-not-showing-up.47110/] |

### F.2 Linear Gradient (M)

- Create: click-drag; the drag length = the feather span. Three lines: top = 100 % (full effect
  beyond it), centre line through the pin = 50 %, bottom = 0 %. **⇧-drag** constrains to
  horizontal/vertical. **⌥-drag** draws out symmetrically from the click point. [search: https://creativepro.com/gradient-tools-lightroom/] [search: https://mastering-lightroom.com/linear-gradient-lightroom-classic/]
- Edit: drag the pin = move; drag either outer line = change feather span (asymmetric: only that
  side moves); **⌥-drag an outer line** moves both symmetrically; hover the centre line → rotate
  cursor, drag rotates about the pin, **⇧ snaps 15°**. [search: same]
- No Feather slider in the panel (span *is* the feather); Invert per component; duplicate/delete
  as radial. Bidirectional gradient exists in Lightroom mobile/desktop (Aug 2026), not in LrC.
  [docs/02 §3.2]

### F.3 Brush (K)

| Item | Behaviour | Tag |
|---|---|---|
| Cursor | Two concentric circles: inner = Size (100 % flow), outer = Feather boundary; crosshair at centre; the ring recolours red-ish when erasing [knowledge for colour] | [search: https://imagen-ai.com/valuable-tips/lightroom-brushes/] |
| Size | `[` / `]` (0.1–100, panel slider); also ⌥-scroll [knowledge] | [search: same] |
| Feather | `⇧[` / `⇧]` (0–100) | [search: same] |
| Flow | Digit keys **1–9 = 10–90 %, 0 = 100 %**; two digits quickly = exact (5,4 → 54 %). Flow accumulates per pass | [search: same] |
| Density | Panel slider 0–100; opacity ceiling per stroke, never accumulates past it | [search: same] |
| Pressure | Tablet pressure drives **Flow** (not size); known Windows/Wacom flakiness | [search: https://community.adobe.com/t5/lightroom-classic-discussions/wacom-pen-pressure-not-working/td-p/12018516] |
| Brush A / B | `/` toggles two saved brush configurations | [search: imagen] |
| Erase | Hold **⌥** = temporary eraser; the Erase tab has its own Size/Feather/Flow/Density | [docs/02 §3.2] |
| Auto Mask | **A** toggles; edge-aware stamping keyed on the colour under the crosshair | [docs/02 §3.2] |
| Stroke editing | Strokes are not individually editable; erase or `'` invert; "Convert to brush" not offered for AI masks in 15.5 (unverified) | [docs/02 §3.1] |

### F.4 Range masks

- **Luminance Range**: eyedropper click (point) or drag (box) samples a band; panel shows a
  luminance bar with **two range handles** (lo/hi) and **two feather/falloff handles** outside
  them; **Smoothness 0–100 (default 50)**; **Show Luminance Map** checkbox = grayscale luma view.
  [search: https://photographylife.com/range-masks-explained-lightroom] [docs/02 §3.2]
- **Color Range**: eyedropper click or drag-box; **⇧-click adds up to 5 samples**; **Refine
  0–100** widens/narrows tolerance; **⌥-drag Refine** = high-contrast grayscale matte preview.
  [search: https://mastinlabs.com/blogs/photoism/how-to-use-luminosity-and-color-range-masks-in-lightroom]
- **Depth Range**: enabled **only** for files with an embedded depth map (iPhone Portrait HEIC);
  greyed otherwise; Lens Blur's estimated depth does **not** feed it. Range handles as luminance.
  [search: https://lightroomkillertips.com/what-lightrooms-depth-range-feature-does-and-how-to-use-it/]

### F.5 AI selections

| Tool | Produces | Notes | Tag |
|---|---|---|---|
| Select Subject | One raster component "Subject" | 15.2/15.4 new models; failure = "Something went wrong" | [docs/02 §3.2] |
| Select Sky | "Sky" | | [docs/02] |
| Select Background | "Background" (own model, not simply ¬Subject) | | [docs/02] |
| Select Objects | **Brush Select** (scribble, snaps to boundary) or **Rectangle Select** (box); each stroke/box = one component | | [search: https://mastering-lightroom.com/select-objects-lightroom-classic/] |
| Select People | Face-detect pass → chips per person (thumbnail, "Person 1…"); pick one or several; per person **10 checkboxes**: Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Clothes, Entire Person; toggle "Create N separate masks" vs one combined | | [search: https://community.adobe.com/t5/lightroom-classic-discussions/use-people-masking-for-specific-edits-in-lightroom-classic-quick-tips/td-p/13683492] |
| Select Landscape (14.3) | Checkboxes: Sky, Mountains, Architecture, Vegetation, Water, Snow, Natural Ground, Artificial Ground; separate or combined | | [search: https://mastering-lightroom.com/landscape-masking-lightroom-classic/] |
| Refresh | AI rasters are tied to source pixels; a stale one shows a warning badge and an **Update** button on the mask row ("Update AI Settings"); 15.0 made batch-sync refresh manual per photo | | [docs/02 §3.4] |

### F.6 The Masks panel, top to bottom

1. **Header**: "Masks" + panel close; hovering the header shows nothing extra. Below it the
   **Create New Mask** roster (icons + labels, one per row): Subject, Sky, Background, Objects,
   People, Landscape · Brush, Linear Gradient, Radial Gradient · Range: Color Range, Luminance
   Range, Depth Range (three visual groups). [search: https://mastering-lightroom.com/lightroom-classic-masks-panel/] (exact order `[knowledge]`)
2. **Mask rows** ("Mask 1", "Mask 2"…): live grayscale thumbnail · disclosure chevron ·
   name (double-click to rename) · **⋯ menu**: Rename, Duplicate Mask, Invert Mask, Duplicate and
   Invert Mask, Delete Mask, Delete Empty Masks, plus "Intersect Mask with ▸" (Subject, Sky,
   Background, Objects, People, Landscape, Brush, Linear, Radial, Color Range, Luminance Range,
   Depth Range) · eye toggle (hover-only) · overlay colour swatch. [search: https://helpx.adobe.com/lightroom-classic/help/masking.html]
3. **Component rows** under the chevron: thumbnail, name (e.g. "Radial Gradient 1"), inline
   Invert checkbox (or via ⋯), ⋯ menu: Rename, Invert, Convert to Add / Convert to Subtract,
   Duplicate, Delete. [search: same]
4. **Add / Subtract** buttons on the selected mask (text buttons with + / −); holding **⌥**
   relabels them to Intersect (community-documented). [docs/02 §3.1]
5. **Per-mask Invert** checkbox; the mask's **Amount** slider (**0–200, default 100**; ⌥-drag the
   pin scrubs it; ⌥-drag the slider shows the matte); 15.3+ **Feather 0–100** and **Edge
   −50…+50** rows on each mask (15.5 on AI masks too). [search: https://photofocus.com/software/mask-amount-slider-lightroom-classic/] [docs/02 §3.2]
6. **Show Overlay** checkbox (shortcut **O**), overlay **mode** dropdown: Color Overlay, Color
   Overlay on B&W, Image on B&W, Image on Black, Image on White, White on Black (**⌥O** cycles);
   colour swatch (**⇧O** cycles red/green/white/black; click = colour picker + opacity). Overlay
   auto-shows on hover/create and hides while a slider drags. [docs/02 §3.2]
7. Then the adjustment stack for the selected mask, sections in order: **Amount** (above) ·
   **Light** (Exposure, Contrast, Highlights, Shadows, Whites, Blacks) · **Color** (Temp, Tint,
   Hue + Use Fine Adjustment, Saturation, Color tint swatch, **Point Color**) · **Effects**
   (Texture, Clarity, Dehaze, Grain Amount/Size/Roughness) · **Detail** (Sharpness, Noise, Moiré,
   Defringe). No local curve, no local grading wheels. Each section header has a reset. [search: https://helpx.adobe.com/sg/lightroom-classic/help/masking.html] [docs/02 §3.3]
8. Panel collapse: the Masks panel is a floating/docked panel (toggle docked via its ⋯); **⇧W**
   opens/closes masking; Esc leaves the tool. [docs/02 §3.1]

**Lumen would need (F, whole):**
`Sources/LumenCore/Interaction/MaskHandles.swift` has radial grabs move/resizeMajor/resizeMinor/
feather/rotate/create and linear move/start/end/startBand/endBand/create, with **15° snap**
(present). Not found: ⌥-from-centre creation, ⇧-circle constraint, ⌘-double-click fill, ⌘⌥-drag
duplicate (panel Duplicate exists), Delete-key on a mask (Keymap handles Delete ~line 521 —
auditor: check target), Show-Edit-Pins Auto/Always/Selected/Never + **H**.
`BrushStroke.swift` has size/feather/flow/density/erase/automask + per-point pressure; `MaskCanvas`
has `[`/`]`, `⇧[`/`⇧]`, ⌥-erase; **flow digit keys absent** (digits are ratings in `Keymap`).
`RecipeMasks.swift` kinds cover brush/linear/radial/lumaRange/colorRange/similarity/aiSubject/
aiSky/aiBackground/aiObject/aiPerson/aiLandscape/depthRange, ops add/subtract/**intersect**, refine
`feather`(Refine)/`edge`/`blur`(Soften). `VisionMattes.swift` serves only foreground-instance +
person; **no sky/background/landscape/people-parts models, no depth source**. `MaskPanel.swift`
row menu: Rename, Invert selection, Duplicate, Duplicate and invert, Delete; component "Invert
this"; overlay mode menu + O/⇧O/⌥O in `Keymap`. Missing vs LrC: "Intersect mask with ▸" submenu,
Convert to Add/Subtract, Delete Empty Masks, per-mask Amount **pin scrub**, Luminance-map view.

---

## G · UI/UX (layout, keys)

- Develop layout: left = Navigator, Presets, Snapshots, History, Collections; right = Histogram,
  toolstrip (Crop R, Remove Q, Red Eye, Masking ⇧W), Basic … Calibration; filmstrip below;
  **Tab** hides side panels, **⇧Tab** all, **F** full-screen, `\` before/after, **Y** side-by-side,
  **⌥Y** split, **⇧Y** toggle split orientation, **⇧R** Reference view, **L** lights-out cycle.
  [docs/02 §2.20, §4.2] [knowledge for Tab/⇧Tab/F]
- Solo mode (⌥-click a panel header) — one panel open at a time; right-click header → Solo Mode,
  Customize Develop Panel (reorder/hide panels). [knowledge]
- Zoom: **Z** toggles, ⌘= / ⌘−; **Space** = temporary zoom; scroll = pan. [knowledge]

**Lumen would need:** `Keymap.swift` has g/e/c/n, p/x/u, 0–9, `\`, y, r, m, o, `'`, b, l, d,
h/⇧h, s/⇧s, a, f, z, `[`/`]`, Space; `LumenMenu.swift` for menu parity (Law 17). Panel solo/
customise: not grepped.

---

## H · Viewer & scopes

Histogram = the only scope (no waveform/vectorscope); channel-diagnostic clip triangles; **J**
overlay; HDR mode splits SDR|HDR with per-stop dashed lines and **Visualize HDR Ranges**; Soft
proof (**S**) with gamut warning triangles and "Simulate Paper & Ink". [docs/02 §2.6, §2.19]
[knowledge for soft proof]

**Lumen would need:** `Scopes.swift` / `ScopesView.swift` (parade/waveform/vectorscope) exceed
LrC; `RawTruthPanel.swift` covers the raw histogram. Soft proof: `SoftProofTransform.swift` present.

---

## I · Pipeline & performance

- AI work is **synchronous with the UI**: mask recompute on photo switch (0.5–10 s freezes with
  AI masks), Lens Blur depth on apply, Denoise (background since 15.3, badge in the toolbar).
  AI rasters live in `.lrcat-data`; delete-and-regenerate is the community fix for black masks.
  [docs/02 §3.4, §5]
- Rendering is process-versioned (PV1–6); any edit silently upgrades to PV6. [docs/02 §1]
- Preview pipeline: Minimal / Embedded & Sidecar / Standard / 1:1 previews + Smart Previews
  (2560 px lossy DNG); Camera Raw cache size in Preferences; GPU "Auto/Custom" toggles. [docs/02 §4.1, §4.4]

**Lumen would need:** `DraftLadder.swift`, `RenderCoordinator.swift`, `MaskRasterCache.swift`
exist for async recompute — auditor verifies nothing blocks on the input path (Law 12).

---

## J · Library / culling / export / ingest (brief items 11–12)

### J.1 Culling

- Views **G/E/C/N**; **P/X/U**, **1–5** (0 clears), **6–9** labels (red/yellow/green/blue;
  purple has no key), **Caps Lock** = auto-advance, **⇧+key** advances once. [docs/02 §4.2]
- **Compare (C)**: left Select, right Candidate; **↓ swaps**, **↑ promotes Candidate → Select**;
  ←/→ steps the Candidate; zoom synced (lock icon), **X Y** toggles link. [search: https://jkost.com/blog/2024/06/using-compare-and-survey-view-in-lightroom-classic.html]
- **Survey (N)**: arrows move the focus cell; **X** on the hovered cell removes it from the
  survey (not a reject); click a cell's flag/rating chrome directly. [search: same]
- **Filter bar** (`\` in Grid): tabs Text · Attribute · Metadata · None; Text: field dropdown
  (Any Searchable / Filename / Caption / Keywords / Searchable Metadata / IPTC / EXIF…) × rule
  (Contains / Contains All / Contains Words / Doesn't Contain / Starts With / Ends With) —
  operators inside the text: `+word` = starts with, `word+` = ends with, `!word` = exclude.
  Attribute: flag (≥/=), rating ≥ = ≤, colour labels, kind (master/virtual/video), edit
  status, AI status (15.3). Metadata: up to 8 columns, OR within a column, AND across. Lock
  icon pins the filter across folders; saved filter presets. [docs/02 §4.3] [knowledge for text operators]
- **Quick Develop** (Library right panel): relative buttons per control — single ‹ › ≈ ⅓ stop
  (Exposure) / ±5 units, double ‹‹ ›› ≈ 1 stop / ±20; applies to the whole selection; WB and
  Treatment menus; **⌥ held turns Clarity/Vibrance into Sharpening/Saturation**. [search: https://jkost.com/blog/2024/07/using-the-quick-develop-panel-in-lightroom-classic.html] [docs/02 §4.3]
- **Painter tool**: spray keywords/labels/flags/ratings/presets/rotation/target collection across
  thumbnails. [docs/02 §4.2]

### J.2 Export (⌘⇧E)

| Section | Controls | Tag |
|---|---|---|
| Presets | Left list: Lightroom Presets (Burn Full-Size JPEGs, Export to DNG, For Email, For Email (Hard Drive)) + User Presets, folders; Add/Remove | [knowledge] |
| Export Location | Specific folder / Same folder as original / Choose later; Put in Subfolder; Add to This Catalog; Existing Files: Ask / Choose new name / Overwrite / Skip | [knowledge] |
| File Naming | Template editor (Filename, Sequence, Date, Custom Text…) | [docs/02 §4.1] |
| File Settings | Format JPEG/PSD/TIFF/PNG/DNG/Original/AVIF/JPEG XL; Quality 0–100; Color Space sRGB/AdobeRGB/ProPhoto/Display P3/Rec 2020/…; Limit File Size To; bit depth; HDR output | [docs/02 §2.19] [knowledge] |
| Image Sizing | Resize to Fit: **Width & Height / Dimensions / Long Edge / Short Edge / Megapixels / Percentage**; units px/in/cm; Resolution ppi; **Don't Enlarge** | [search: https://havecamerawilltravel.com/workflow/lightroom-resize-images-lightroom/] |
| Output Sharpening | Sharpen For **Screen / Matte Paper / Glossy Paper** × Amount **Low / Standard / High**; scales with output size | [search: same] |
| Metadata | Include: **Copyright Only / Copyright & Contact Info Only / All Except Camera Raw Info / All Except Camera & Camera Raw Info / All Metadata**; **Remove Person Info**; **Remove Location Info**; Write Keywords as Lightroom Hierarchy | [search: https://lightroomkillertips.com/controlling-metadata-export/] |
| Watermarking | Checkbox + Watermark Editor: Style **Text / Graphic**; text options (font, style, align, colour, shadow); Watermark Effects: Opacity, Size (Proportional/Fit/Fill), Inset H/V, **Anchor 3×3 grid**, Rotate; saved as named watermark presets | [search: https://helpx.adobe.com/lightroom-classic/help/using-watermark-editor.html] [knowledge for anchor grid] |
| Post-Processing | Do nothing / Show in Finder / Open in app / Export actions folder | [knowledge] |
| Export with Previous (⌘⌥⇧E); batch multiple presets at once (checkbox list) | | [knowledge] |

**Lumen would need:** `ExportRecipe.swift` has formats jpeg/heif/tiff/png; colour spaces incl.
P3/Rec 2020; `ResizeMode` none/longEdge/shortEdge/width/height/megapixels (**no Dimensions,
Width&Height, Percentage**); output sharpening none/screen/matte/glossy × low/standard/high
(present); watermark **text only** (position 5-way, opacity, size %, inset — no graphic, no 3×3
anchor/rotate); metadata as includeEXIF/CameraSerial/GPS/Keywords + copyright/contact (no
person-info strip; no named presets). `FilterBar.swift` has All/Any grammar (beyond LrC),
auto-advance visible toggle; `CompareView.swift` has twoUp/survey + synced zoom — ↓ swap / ↑
promote not grepped. Quick-Develop-style relative batch: not found. Painter: not found.

---

## K · Crop / lens / geometry (brief item 13)

- **Crop (R)**: Aspect menu (As Shot/Original, 1×1, 4×5 / 8×10, 8.5×11, 5×7, 2×3 / 4×6, 4×3,
  16×9, 16×10, Enter Custom…), padlock (**A** toggles lock), **X** swaps orientation, **⇧-drag**
  keeps ratio, Angle slider ±45 with Auto (Level via Upright), **Straighten tool** = ruler icon
  or **⌘-drag** anywhere; **O** cycles overlays (Grid, Thirds, Diagonal, Triangle, Golden Ratio,
  Golden Spiral; Tools › Crop Guide Overlay › Choose Overlays to Cycle), **⇧O** flips the
  overlay's orientation, **H** hides the guide; 15.5 crop-shield opacity (temporary). Image
  moves under a fixed frame. [search: https://lightroomkillertips.com/10-awesome-lightroom-cropping-shortcut/] [docs/02 §2.18]
- **Transform**: Upright buttons **Off / Auto / Guided (⇧T) / Level / Vertical / Full**; Guided
  = draw 2–4 guides with a loupe, live after 2; ⌥-click a mode re-analyses [knowledge]; manual
  Vertical / Horizontal / Rotate ±10 / Aspect / Scale / X / Y Offset; **Constrain Crop**.
  Lens profile first, then Upright (Upright reanalyses if lens profile changes — a badge). [docs/02 §2.18]
- **Lens Corrections**: Profile tab (Remove CA, Enable Profile Corrections, Make/Model/Profile,
  Distortion/Vignetting 0–200); Manual tab (Distortion, Defringe purple/green amount 0–20 + hue
  ranges, eyedropper, ⌥-drag B&W view; Vignetting). [docs/02 §2.18]

**Lumen would need:** `CropPanel.swift` has ratio menu + padlock + recent custom aspects +
orientation swap + angle + ruler + `CropOverlayStyle` (thirds, golden, plus others — Grid/
Diagonal/Triangle/Spiral: auditor check the enum); `Straighten.swift` present. **Upright /
Guided: not found by name** (grep hits for "guided" are guided-filter). Defringe: 5 files.

---

## L · State / undo

- **History** (left panel): every edit, unlimited, per catalog, click to time-travel, hover
  previews, no branching (editing from a past step truncates forward); ⌘Z undo is separate and
  unlimited within a session. **Snapshots**: named states, alphabetical, right-click Update with
  Current Settings; snapshots sync via XMP. **Reset** button (⇧⌘R) returns to defaults; ⌥ turns
  it into "Set Default…". [docs/02 §2.20] [knowledge]
- Copy/Paste (⌘⇧C/V) checkbox tree incl. masks; 14.5 saved subsets; **Previous** (⌘⌥V); Sync…
  (⌘⇧S) from the most-selected photo; **Auto Sync** toggled by ⌘-click on Sync; Match Total
  Exposures (⌘⌥⇧M). [docs/02 §2.20] [knowledge]

**Lumen would need:** `HistoryStack.swift` has coalesced history + named, timestamped snapshots
(present); `LookSubset.swift` for copy subsets; Auto-Sync indicator: not grepped.

---

## M · Recipe / serialization / sidecars

- Develop settings live in the `.lrcat` SQLite; **Automatically write changes into XMP**
  (Catalog Settings › Metadata) writes `.xmp` side-cars for raws and embeds for DNG/JPEG/TIFF;
  batched every ~10 s since 14.4; ⌘S forces a write. Masks are serialised parametrically in XMP
  (`crs:MaskGroupBasedCorrections` with `CorrectionMasks`, gradient geometry as normalised
  coordinates, brushes as `Dabs` strings) but **AI rasters and Denoise results are not in XMP**
  — they live in `<catalog>.lrcat-data`, so another catalog re-runs the model. Process Version
  `crs:ProcessVersion="15.4"` etc. [docs/02 §3.4, §4.4] [knowledge for XMP tag names]
- Presets are `.xmp` files (`crs:` namespace) in `Develop Presets/`; profiles are `.xmp`
  (`crs:RGBTable`/LUT) or `.dcp`. [knowledge]
- Render to DNG (15.5) bakes edits into a linear DNG; Flatten AI Edits bakes generative results.
  [search: Lightroom Queen 15.5]

**Lumen would need:** `XMPSidecar.swift` + `XMPMerge.swift` present; `CanonicalJSON.swift` /
`Fingerprint.swift` for recipe identity; `MaskRasterCache.swift` for regenerable AI rasters
(the docs/02 §6.5 "never `.lrcat-data`" verdict).

---

## New relative to docs/02–03

- Slider keyboard increments as numbers: ↑/↓ = 5 (Exposure 0.10), ⇧ = 10 (0.33), **⌥ = 1
  (0.02)**; ⇧-drag *slows* a drag rather than multiplying it.
- Radial/linear on-canvas grammar at handle level: ⌥-drag = draw from centre, ⇧-drag = circle /
  axis constrain, ⇧ on a handle = keep aspect, ⌥ on a handle = scale from opposite corner, rotate
  affordance appears just *outside* the rim and snaps 15° with ⇧, **⌘-double-click** = fill the
  cropped frame (new or existing), plain double-click commits, **⌘⌥-drag** duplicates, Delete
  key deletes; linear outer-line ⌥-drag = symmetric feather.
- **Show Edit Pins** Auto / Always / Selected / Never and **H** as its toggle.
- Brush flow digit keys incl. two-digit entry; `/` toggles brush A/B; tablet pressure maps to
  Flow only.
- Masks panel ⋯ menu contents at row and component level, incl. "Intersect Mask with ▸" submenu,
  Convert to Add/Subtract, Delete Empty Masks.
- Per-mask section order Light → Color → Effects → Detail, with Grain Amount/Size/Roughness local.
- Point Color: up to 8 swatches, Range disclosure with three H/S/L range bars, Variance ±100
  semantics (negative unifies, positive separates).
- Lens Blur: Adobe lists **five** bokeh shapes (Anamorphic, not Cat-eye); device depth via the
  panel ⋯ menu; focus-range strip drag semantics.
- Denoise post-14.4 mechanics: Amount greyed until first compute; toggle off/on does not
  recompute; greyed file classes enumerated; Render to DNG replaces the side-car workflow.
- Export: full Resize-to-Fit mode list incl. Width & Height and Percentage; five metadata
  include levels + Remove Person / Location Info.
- Compare ↑/↓ swap/promote; Survey X removes a tile; Quick Develop ⌥ swaps Clarity/Vibrance for
  Sharpening/Saturation.
- 15.5 also shipped **Flatten AI Edits** in Classic.

## Could not verify

- Exact Create-New-Mask roster order and the presence of a separate "Objects" vs "Landscape"
  grouping line (summaries agree on membership, not order).
- Point Color numeric ranges for the three Shift sliders and Range's default (50 is from memory).
- Whether Lens Blur's sixth "Cat-eye" shape exists in 15.5 (help lists five).
- Convert-to-Brush availability per component type in 15.5.
- Crop angle limit ±45; Transform slider bounds beyond Rotate ±10.
- "Selected" as a fourth Show-Edit-Pins state (one source lists "Auto, Always Selected, Never").
- Whether Vibrance is available locally in any 15.x build.
- All helpx/jkost/lightroomqueen/mastering-lightroom pages: unreachable for full-text fetch, so
  every claim tagged `[search]` rests on a search summary.
