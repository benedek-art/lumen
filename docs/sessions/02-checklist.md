# Owner session B, continued — the overnight batch, verified by hand

Last night closed twelve queue items (docs/23: audit queue 1–7 and 9–12 plus the
histogram, dossier items 4, 5 and 7, the calibration contracts, the M1b
instrumentation). Most are engine- or CI-proven; the steps below are the ones only a
human at the real app can confirm. ~20 minutes. Write observations in plain words
under each "What I saw" — diagnosis happens repo-side.

**Build:** download the `Lumen.app` artifact from the newest green CI run on
`claude/photo-editor-design-plan-8ahzmm` (GitHub → Actions → CI → the run →
Artifacts), unzip, then in Terminal:

    xattr -dr com.apple.quarantine ~/Downloads/Lumen.app

**Fill in first:**

- CI run number the build came from: `……`
- Photo folder used: `……`

---

## 1. The HUD now counts the caches

⌥⌘L for the HUD. Drag Exposure for a few seconds, pause, read the two new lines:
`tables Xh Yb Zs` and `rasters …` (hits / bakes / stale-serves).

**Look at:** during a steady drag, `h` and `s` climb and `b` nearly stalls. If `b`
climbs with every event of a drag, write down which slider you were dragging — that
is a cache key being defeated and the number is the whole diagnosis.

**What I saw:** ……

## 2. Uniformity converges on YOUR sky

A photo with a real sky. Colour Mixer → Uniformity (all bands) → drag 0 → 100 slowly.

**Look at:** the sky's blues should pull TOGETHER — toward the sky's own average
blue — not slide as a body toward some other hue. (Until last night it converged on
a fixed 254° constant; now it measures this photo.) Then the caption under the
slider: it should say measured-mean, not core-arc.

**What I saw:** ……

## 3. The tint slider says when physics holds it

White Balance: set Temp somewhere warm (~2500 K), then drag Tint toward +150 magenta.

**Look at:** past a certain point the picture legitimately stops changing — and a
caption should now appear under Tint naming the bound ("Magenta is bounded by
physics at +NN for 2500 K"). No caption while the slider and the render agree.

**What I saw:** ……

## 4. A masked grade lives in the global zones

Add a radial mask over shadows-and-midtones, give it a strong blue Shadows wheel in
the mask's grade. Then, in the GLOBAL Grading panel, drag the shadow/midtone pivot
on the strip above the wheels left and right.

**Look at:** the masked grade's reach must FOLLOW the global pivot — dragging the
pivot up should visibly hand more (or less) of the masked region to the blue push.
(Until last night the masked grade ignored the global pivots entirely.)

**What I saw:** ……

## 5. Protect Skin now governs masked mutes

A photo with a face. Mask the face, set the mask's Vibrance to −80. Now flip the
GLOBAL Colour panel's Protect Skin between 0 and 70.

**Look at:** at 0 the masked mute bites the skin visibly harder than at 70. (The
protection used to be an invisible constant no control could move.)

**What I saw:** ……

## 6. A picked swatch grips the colour you clicked

Push Exposure +1.5 (leave it there). Point Colour → eyedropper → click a saturated
object. Drag the swatch's hue.

**Look at:** the hue drag must move THE THING YOU CLICKED, crisply — not a
neighbouring colour, not a watered-down grip. (The picker used to sample before the
tone move, so an exposed photo picked the wrong colour.)

**What I saw:** ……

## 7. On-image drags feel like sliders now

One long continuous drag each, watching for stutter: the crop rectangle (move a
corner around for a few seconds), a curve point, a histogram zone scrub, and a mixer
ring handle.

**Look at:** all four should feel exactly as fluid as a slider drag. Any one that
stutters rhythmically, name it — until last night each of these wrote to the catalog
on every mouse event.

**What I saw:** ……

## 8. Undo respects the photo switch

Drag Exposure on photo A. Arrow to photo B and IMMEDIATELY (within a second) drag
Exposure there too. Press ⌘Z, look, ⌘Z again, look.

**Look at:** the first undo reverts B (the photo on screen), the second reverts A —
never both in one step, never the off-screen photo first. (A fast switch used to
fold both drags into one step owned by photo A.)

**What I saw:** ……

## 9. The drag still never pops on release

The regression guard for everything above: on a photo with a mask + sharpening +
denoise, drag Whites and Blacks hard and release mid-motion, several times.

**Look at:** nothing may change at the moment of release — the picture at rest is
the picture the drag showed. Also glance at the HUD's settle number.

**What I saw:** ……

## 10. Anything else

Whatever annoyed you, verbatim, with what you were doing at that exact moment.

**What I saw:** ……
