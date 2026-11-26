# cropheal: Area 21 (crop and geometry) and Area 22 (heal and clone)

Branch `claude/loving-cray-d58nrb-test-cropheal`. Render-lab request commit 40996472 (manifests `renderlab/manifests/cropheal-geo.json` and `cropheal-heal.json`).
Real runs: **macOS render lab 45754243513** (shipping export and settled, finished 05:15 UTC) and the **Linux reference lane** (local).
**Driver batches did not run**: they were still queued at wrap-up (details at the end).
Paths below are relative to this folder.

## Findings (proven on a real run)

### 1. Heal makes a saturated navy disc on a neutral black card. Clone does not. (major)
- **What I did:** One Heal spot on photo 1346 (Canon 5D, colour checker), over the "+" mark on the black card: x 0.651, y 0.4535, radius 0.008, feather 50.
  The source is the same black card just above it (0.651, 0.42). Its rim touches the purple and yellow patches.
  I rendered the same spot as Clone for comparison.
- **What I saw (shipping, run 45754243513, job `heal-1346-plus`, 1:1 native crop):**
  - Heal disc centre, export: sRGB **(0.7, 0.8, 29.8)**. Settled: **(0.6, 0.7, 30.7)**. Red and green are crushed to 0.
  - The ring around the spot is a neutral **(53, 49, 50)**.
  - Clone at the same spot gives a neutral **(51, 49, 49)**.
  - The reference lane gives the same numbers: (0.6, 0.6, 30.6).
- **More cases:**
  - With natural sources (the next gutter crossing up, left or down on the card, `repro/plus.json`), a radius-0.008 heal comes out reddish **(92, 66, 70)** or orange **(100, 75, 47)** on a black card. Clone stays neutral (49 to 58).
  - On a patch corner (`1346-patchedge`), Heal leaves a green crescent where Clone leaves lavender.
- **Images:**
  - `img/heal-ref-1346-plus-navy-disc.png`. Tiles from left: before, markers (red = spot, cyan = source), none, heal, heal at feather 0, clone.
  - `img/ship-heal-1346-plus-export-sheet.png` and `img/ship-heal-1346-plus-settled-sheet.png`.
  - `img/heal-ref-plus-r0.008.png` and `img/heal-ref-1346-patchedge.png`.
- **Correct:** A heal on a neutral surface stays neutral, as Clone does and as Lightroom's heal does. Heal must never produce a colour that is in neither the source nor the surroundings.
- **Why (inference, not proven):** The closed-form Poisson membrane in `Core/Image/SpotRetouch.swift` adds the rim difference `I_dst - I_src` linearly in scene-linear. When the source rim is brighter or more coloured than the destination rim, the result goes below zero per channel and clips with a hue shift. Nothing clamps the result or blends in a ratio or log domain.
- **Repro:** `repro/cropheal-heal.json` (job `heal-1346-plus`), `repro/heal-ref.json`, `repro/plus.json`. Crops made with `repro/healcrops.py`.
- **Confidence:** High for the defect (the same numbers on shipping export, settled and reference).
- **Not measured:** how often auto-source or `/` lands on such a source. The driver run did not happen.

### 2. A cropped or straightened export comes out 1 px bigger than asked on both axes; a 1:1 crop is not square (minor)
- **What I did:** Exported at "long edge 1536" (PNG, run 45754243513, jobs `geo-raw` and `geo-portrait`).
- **What I saw:**
  - Every cropped or rotated real-RAW export has a long edge of **1537** (6929, 5812, 1346).
  - Uncropped exports are 1536.
  - A 1:1 crop of photo 5812 exports as **1536 × 1537** and settles in the viewer as 1024 × 1025: `img/ship-5812-1to1-export-1536x1537.png`.
  - Photo 6929, crop 0.3 × 0.55: the expected size is 1256.8 × 1536. Delivered: **1258 × 1537**, which is +1 on both axes.
- **Correct:** The long edge is exactly the requested value, and a 1:1 crop is square. Exact-size deliveries (1080 px, print sizes) depend on this.
- **Why (inference):** The fractional crop extent seems to be rounded outward (integral) after the scale.
- **Repro:** `repro/cropheal-geo.json`.
- **Confidence:** High.

### 3. Heal smears an uncovered blemish into the whole disc (minor; this is how Poisson healing works, so it may be taste)
- **What I saw:** When the "+" mark reaches the rim of a radius-0.005 spot, Heal turns the disc into a grey glow **(115, 107, 109)** on a **(50, 50, 50)** card. Clone removes the mark cleanly.
- **Images:** `img/heal-ref-plus-r0.005.png`. The text spot on photo 5812 shows the same smudge: `img/heal-ref-5812-text.png`.
- **Run:** Reference lane only.
- **Confidence:** High. Lightroom behaves similarly when a spot is too small.

## Tested and working (run 45754243513 unless marked)
- **Crop at angle 0 is pixel-exact:** centred and off-centre crops on `chart:detail` and `chart:colorChecker`, export and settled. Sizes match exactly; mean |delta| against a hand crop of the uncropped export is 0.02 to 0.05. No softening. Details: `repro/geo-chart-check.txt`.
- **Flip is exact:** mean |delta| 0.4 to 0.5 against a mirrored uncropped render. Flip plus an off-centre crop is also exact.
- **Rotation sizes match the inscribed-rectangle maths:** angles +5, -12, +45, +0.3, plus a +30 rotation with flip and crop (within 1 px). No black corners at any tested angle, up to 45°.
- **Rotation geometry agrees with a PIL bicubic rotation of the uncropped export** on the colour checker: mean |delta| 1.3 to 2.4.
  - The `chart:detail` chirp differs by 9 to 40 from PIL, including at +0.3°. That is consistent with a different resampling kernel on a near-Nyquist chirp, not with misplacement. Not judged as a defect.
- **The order is rotate-then-mirror:** the +30 / flip / crop case matches it at mean |delta| 1.6. So flipping a straightened photo keeps it level.
- **Portrait file (5812, EXIF orientation 8), no transposition:**
  - A 4:3 landscape crop exports as 1536 × 1152 (correct aspect 1.333).
  - Off-centre crop and ±8° rotation keep the aspects the maths predicts (settled 308 × 846, 834 × 1435).
  - The earlier "transposed portrait" defect is absent on the export side.
- **Heal and clone spots survive export:** with all spots applied, export changes against no spots, and export-vs-settled mismatch is identical with and without spots (6929: 4.21, which is the known A7 IV viewer/export issue; 5812: 0.79; 1346: 1.97).
- **Clone is clean and neutral** with every source tried. **Heal on smooth texture** with a matching source (6929 white wall, 1346 background) is invisible at feather 50 (reference lane).

## Taste
- The default spot radius is 0.01 of the long edge, which is a 140 px diameter on a 33 MP frame. That is large for dust.

## Code-reading leads, NOT proven (they are in the queued driver batch 1, scenario named)
- **Rotate-by-drag may be unreachable at full frame at 0°** (`crop-rotate`, step `surround`). `CropOverlayView.rotateGesture` requires `startsOnThePicture`, and the picture lies wholly inside the rectangle at 0°.
- **Esc may revert to the framing from before an earlier visit** (`crop-esc-second-session`). `CropTool.beginSession` keeps the first baseline per photo, and leaving the Crop workspace does not end the session.
- **Return does nothing in Crop.** This is deliberate per the code, but unlike Lightroom.

## Could not test
- **Driver batch 1** (request 08b2ce1e, run 45751407713, 11 scenarios) was still queued at 05:25. It covers:
  - Crop: handles, undo and redo, rotate drag and Angle extremes, R R, crop at 1:1, Esc in a second session, Straighten by line with flip, A7 IV crop with a frame-aspect check, crop-then-heal coordinates.
  - Heal on the A7 IV and 5D: `/` cycling, move, Size, Delete, undo, Visualize Spots, brush stroke, 1:1 views.
- **Driver batch 2** (request 243b300f) was queued. It covers ratio presets, the orientation swap button, Custom 2.39:1 / 1:0 / abc, the Flip toggle, and the heal bar through named targets.
- **Next run:** run `python3 driver/tools/results.py <sha> --out DIR` for both and read the states. `repro/gen1.py` and `repro/gen2.py` regenerate the scenarios.
- **Portrait in the UI:** no decodable portrait file in the driver fixtures (the X-H2 RAF fails on macos-15).
- **Heal at 1:1 on real photos with app-chosen sources:** needs the driver output.
- **Crop on the Linux lane:** not implemented there.
