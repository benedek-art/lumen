# Masking (AREAS 23-26) findings

App: `claude/loving-cray-d58nrb-integration` @ 805455c0, real app driven on hosted macos-15 runner (1x, 1440x900).

Runs:
- 45744323822: build failed (old driver copy on the requests branch); no scenarios ran.
- 45744762900 (run1b): 13 scenarios, `repro-run1-scenarios.json`; build OK.
- 45748254237 (run2): 9 scenarios, `repro-run2-scenarios.json`; build OK.
- 45754209368 (run3): 3 confirmation scenarios, `repro-run3-scenarios.json`; still queued at wind-down, results not read.

Fixtures: fiducial (7-colour grid) and raw (5D ColorChecker, A7IV trees/wall). Run folders `run1b/`, `run2/`. Key images in `img/`. Helpers: `ana.py`, `cells.py`, `st.py`.

## Findings (ranked)

1. MAJOR: one press of `O` brings back the persistent overlay.
   - `O` toggles show/hide only and never returns to Automatic (from Automatic: show, hide, show; run1b `mk-linear/state-o1..o3.json`, `app.maskOverlay.choice`).
   - While the choice is show, the overlay stays up through adjustments (`state-r8.json`: Exposure 2.5 with `overlayShown` true) until masking is left.
   - The panel control does cycle Auto/Show/Hide correctly (`mk-overlay` ctl1-3).
   - Correct: `O` cycles Auto/Shown/Hidden.
   - Confidence: high (the run3 pixel confirmation is pending).

2. MAJOR: the AI People mask selects 44.5% of a frame that has no person, and says nothing.
   - 5D ColorChecker frame: the chart case and foreground get the tint (`img/r1-ai5d-people-no-person.png`).
   - A7IV: the result is empty, but there is no "no people found" message either.
   - Subject and Background are correct and not mirrored on both raws.
   - Vision mattes are present on the runner.
   - Run 45744762900, scenarios `mk-ai-5d`, `mk-ai-a7`.

3. MAJOR: a drag in clear space (more than 33 pt from the shape) REPLACES the placed radial or linear instead of adding a new one.
   - Radial became a centre (0.30, 0.125), radii (0.002, 0.025) sliver; the thumbnail goes black (`img/r1-radial-sliver.png`, `mk-radial/state-outside1.json`).
   - Linear became a tiny (0.1, 0.12)-(0.2, 0.12) line (`mk-linear/state-outside-drag.json`).
   - A one-axis radial draw always gives a 0.002 radius.
   - Lightroom adds a new shape instead. Undo recovers.
   - Run 45744762900.

4. MINOR: switching local White Balance from Shift to Kelvin drops the visible warmth.
   - Shift temp 50 gives mean dRGB (+2.2, −0.3, −4.8) in the mask.
   - Click Kelvin: the panel shows 5923 K, tint 12; the recipe keeps temp 50 plus kelvin 5923; the render goes back to exactly the reference (0, 0, 0).
   - The picture jumps (`img/r2-temp-shift.png`, `img/r2-temp-kelvin.png`).
   - Run 45748254237, `m2-tones-5d`.

5. MINOR: ⇧[ and ⇧] (brush Feather) are dead from a real keyboard.
   - HID key-down arrives as `}` or `{` with the shift flag; `Keymap` matches `case "[", "]"` on key-down without folding, so feather stays 50.
   - The synthetic app path, which carries plain characters, changes it (50 to 60).
   - Run 45748254237, `m2-brushkeys` (also run1b `mk-brush`).

6. MINOR: dragging a shape's Feather or Rotation shows no overlay, while Edge sliders force it on.
   - Feather drag: 8 captured frames, no red shift (`img/r2-feather-drag-no-overlay.png`).
   - Expand drag: red shift +35 to +41 during the drag, gone after (`img/r2-expand-drag-overlay-shown.png`).
   - Both reshape the selection, so both should show it.
   - Run 45748254237, `m2-radial`, `m2-edge`.

7. MINOR: the component + Add / + Subtract kind board in the Masks box is squashed to half width.
   - Labels break mid-word ("Outlin/e", "Subje/ct").
   - The other button floats beside the board.
   - The Reuse/Another Mask tile is clipped at the box bottom, and clicking it added nothing (`img/r2-subtract-board-squashed.png`, `img/r2-add-board-squashed-reuse-clipped.png`).
   - Run 45748254237.

8. MINOR: the only component can be set to Subtract or Intersect, which silently empties the mask.
   - The effect vanishes, the thumbnail goes black, and the row reads "Invert minus Radial…" (`img/r1-only-component-subtract-empties-mask.png`).
   - Run 45744762900, `mk-algebra`.

## Taste and design questions
- The expanded Masks box covers about 38% of the photo.
- Hidden outranks row hover (AREAS 23 journey 3 expects hover to still work).
- Colour Pick is local (radius 0.15) while Colour Range is global, and the UI does not say so.
- Local Saturation is strong (channels clip to 0 at an effective +40).
- Edge Soften 100 is very weak on an already-feathered radial (the selection changes by 0.04 or less).
- Footer Undo is session-wide, so it can undo another photo's mask edit.
- Brush strokes live in the catalog blob store and the XMP sidecar holds only the reference.

## Working (proven on runs 45744762900 and 45748254237)

### Entering and leaving masking
- `M` from Grid or Develop enters masking; `M`, `Esc` and the back button leave it.
- `⌫` with no mask does not reject the photo.
- `O` enters masking.

### Overlay rule (main journey)
- Shown while creating.
- Hidden on adjusting.
- Shown on row hover, hidden on leaving the row.
- Never shown outside masking (state, and a pixel red shift of 0).
- ⌥O cycles modes and ⇧O cycles tints.

### Drawn components
- **Linear:** draw, move, falloff, swing, ⌘ new shape and ⇧ 15° snap are exact. The effect is 0 above the start line, ramps across the band and is full below.
- **Radial:** draw, move, rim resize, rotate, Feather 0 and 100, Rotation and the `'` invert key all work.
- **Brush:**
  - strokes land where drawn;
  - one ⌘Z removes exactly one stroke and redo restores it;
  - ⌥-erase, the Eraser toggle and the Size slider work;
  - `[` and `]` change size;
  - digit keys set Flow, not the rating;
  - `A` toggles automask, not auto-advance.

### Local adjustments
- All 14 local sliders act only inside the mask: 0.00 change outside, about half in the gradient band.
- Strength 0 gives no effect and 200 gives exactly 2x the EV.
- Local tones on the real raw hit the right luminance bands.

### Combining components (algebra)
- Add, Subtract and ⌥-Intersect give the correct pixel profiles.

### Range components
- Colour Range on the fiducial changes only the red cells (median −49.9 on red, 0 on the other colours).
- On the ColorChecker, raising Tolerance widens the selection (4.8% to 13.2% of the area).
- Brightness Range drops colours in luminance order as From rises.
- Luminosity Level narrows the selection.

### Two photos selected
- Mask edits go only to the primary photo; the other photos get no recipe entry and no sidecar.

### Switching photo
- No mask leaks to the next photo.
- Coming back, the brush mask and its strokes are intact.
- A stroke made right before leaving masking is kept.

### Undo and redo
- 8 linear steps undo and redo exactly.
- The radial steps undo exactly.
- Deleting a mask with ⌫ and then ⌘Z restores it with the same id.

### XMP sidecar
- The sidecar matches the live recipe after each journey.

## Unfinished (one line each)
- Run 45754209368: read results for `m3-okey-adjust` (pixels of an Exposure drag after `O`), `m3-kelvin-5d` (Kelvin back to Shift) and `m3-outline` (lasso and 4-corner outline).
- Leaving masking or switching photo in the middle of a drag: the driver cannot interleave steps.
- Another Mask and deleting the mask it points at: blocked by the clipped tile (finding 7) and the "Points at" popover.
- Row ⋯ menu (Rename, Duplicate, Duplicate and invert, Group, group Strength), Filter with 15 masks, dragging the box: popovers with no driver names.
- Overlay modes 4-6 and the other tints in Colour Overlay mode.
- Colour Along a Line, Applies, Colorize, local Curve, local wheels, Point Colour, Ceiling, Steadiness, Stay inside edges, tablet pressure.
- Mask export against loupe parity (render lab).
- Typing values into Strength was unreliable ("0", "200", "100" not applied, "50" applied); possibly Area 11.
