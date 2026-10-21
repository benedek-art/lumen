# WS-44 brush masks: audit (base 84bcd7c)

Auditor, 2026-10-21. All numbers come from base commit 84bcd7c plus the uncommitted `strokes` command.
A builder edited the shared worktree while this audit ran: `BrushRaster.swift` and `BrushLivePreview.swift` were added and `paint` was replaced. To keep the base clean, the audit used a separate copy built from `git archive 84bcd7c` plus `Strokes.swift`:
`$A/base/.build/release/lumen-render`. Here `$A` = `/tmp/claude-0/-home-user-lumen/c5cac81a-b1ea-5caa-99a2-37ea7cfb6e5b/scratchpad/audit`.
Scripts are in `$A/tools/` (`gt.py`, `automask.py`, `leak2.py`, `gate.py`, `timing.py`). The brushlab baseline on that binary is in `$A/brushlab_base/measure.json`.

## 1. Auto Mask on real photos (1024 long edge, Size 0.06 = r 30.7 px, Feather 50, Flow/Density 100)

**Ground truth.** Each object mask comes from the `.lfi`, area-downsampled with `decode_raw.area_downsample` and converted to OKLab. It is a colour threshold, limited to a loose ellipse prior, then the largest connected component, with holes filled.
- 4694 lemon: 33,330 px. 4694 apple: 35,668 px. 8559 red can: 28,556 px.
- Overlays: `$A/gt_4694.png`, `$A/gt_8559.png`.
- The boundary is good to about ±2 px, and dark rims and dirt are only partly in the mask. For that reason leak is also reported beyond a 3 px dilation.

**Strokes.**
- (a) An outline trace with the centreline 0.5 r inside the object: a full loop for the lemon and apple, the bottom edge for the can.
- (b) A straight stroke from the object centre across its edge onto the background.
- Mouse events are about 4 px apart.

| case | AM | leak % | leak % >3px | coverage (≤0.8r, in object) | 5th pct alpha | ms |
|---|---|---|---|---|---|---|
| lemon a | off / **on** | 27.4 / **14.0** | 20.6 / **10.0** | 0.998 / **0.954** | 0.998 / **0.675** | 6.7 / 45.6 |
| apple a | off / **on** | 27.3 / **15.0** | 21.0 / **10.4** | 0.999 / 0.986 | 0.999 / 0.981 | 6.7 / 46.4 |
| can a | off / **on** | 27.1 / **15.5** | 19.2 / **9.9** | 0.986 / **0.917** | 0.923 / **0.0** | 3.3 / 22.8 |
| lemon b | off / on | 45.4 / 41.5 | 43.8 / 39.9 | 0.982 / 0.981 | 0.908 / 0.888 | 1.8 / 12.3 |
| apple b | off / on | 34.8 / 35.2 | 33.3 / 33.7 | 0.985 / 0.972 | 0.937 / 0.831 | 1.9 / 13.8 |
| can b | off / on | 42.3 / 40.2 | 38.8 / 36.9 | 0.980 / 0.979 | 0.875 / 0.867 | 1.6 / 10.3 |

**Images** (100% crops, off on the left and AM on the right):
- `$A/am/crop_{lemon_a,apple_a,can_a,lemon_b,can_b}.png`
- Full overlays: `$A/am/<case>_{off,am}.png`
- Leak maps at 200% (green = inside, magenta = outside): `$A/am/leakmap_{lemon_a_am,can_a_am}.png`

**What the images show.**
- Auto Mask removes only half of the outside mass. It still paints a magenta collar on the potato, the tomatoes and the bowl next to the dark lower-left rim of the lemon.
- On the can, it leaves 1 px speckle on the concrete (26 isolated pixels) and a ragged, aliased edge.
- Inside the lemon, the shaded lower half drops out (5th-percentile alpha 0.675).
- Case (b) gives no protection at all: leak with Auto Mask on is within ±4 points of off. Every stamp samples the colour under its own centre, so once the centre is on the background, the background becomes the reference.

**Why: the gate measured on a synthetic edge** (`$A/gate/gate_result.json`). Grey 0.18 meets grey with a known OKLab ΔE. The stroke runs 0.5 r from the edge.

| ΔE | 0.06 | 0.08 | 0.10 | 0.12 |
|---|---|---|---|---|
| gate for one stamp (`1−smoothstep(.06,.12)`) | 1.0 | 0.741 | 0.259 | 0.0 |
| alpha across the edge, Flow 100 stroke | 1.0 | 1.0 | **0.986** | 0.0 |
| alpha across the edge, Flow 30 stroke | 0.994 | 0.973 | **0.689** | 0.0 |

About 20 stamps overlap each pixel, so any partial gate builds up toward 1. The soft fade [τ, 2τ] becomes a hard step at ΔE ≈ 0.11.

This is plain Euclidean OKLab with L weighted like chroma. As a result:
- ±0.10 L (about ±0.7 EV of shading on grey 0.18) is painted at full strength.
- The lemon's own shading, ΔE 0.19 from its lit side, is refused.
- Red can (C 0.08–0.11) against grey concrete (C 0.008) is only ΔE ≈ 0.1, so it leaks.

## 2. Paint cost per stroke (base, `--repeat 3`, one horizontal stroke 0.8 × width, Feather 50, flat noisy grey input)

Source: `$A/timing/timing.json`. A stamp is laid every 0.1 r, so a stamp costs (2r)² pixels.

| long edge | size | r px | stamps | ms off / AM | ms per radius off / AM | µs per dab off / AM |
|---|---|---|---|---|---|---|
| 1024 | 0.02 | 10.2 | 801 | 3.0 / 21.3 | 0.04 / 0.27 | 3.8 / 26.6 |
| 1024 | 0.08 | 41 | 201 | 11.1 / 84.0 | 0.55 / 4.20 | 55 / 418 |
| 1024 | 0.2 | 102 | 80 | 27.7 / 205 | 3.5 / 25.7 | 343 / 2534 |
| 2560 | 0.02 | 25.6 | 801 | 20.0 / 143 | 0.25 / 1.78 | 25 / 178 |
| 2560 | 0.08 | 102 | 201 | 68.9 / 578 | 3.4 / 28.9 | 343 / 2876 |
| 2560 | 0.2 | 256 | 81 | 174 / 1283 | 21.7 / 160 | 2144 / 15839 |
| 4096 | 0.02 | 41 | 801 | 71.0 / 352 | 0.89 / 4.40 | 89 / 439 |
| 4096 | 0.08 | 164 | 201 | 205 / 1357 | 10.2 / 67.9 | 1018 / 6753 |
| 4096 | 0.2 | 410 | 80 | 440 / 3371 | 55 / 421 | 5427 / 41617 |

**What this works out to.**
- Paint costs about 8–9 ns per bbox pixel per stamp (13 ns at 4096, where the resumed-plane copy adds about 45 MB). Auto Mask costs about 62 ns, 7.4× more, because `toLab` runs per pixel per stamp, about 20 times for each pixel.
- Stroke cost is roughly 40·r·length px², so it scales with resolution².
- A 30-radius stroke at Size 0.08 costs 103 ms at 2560 with Auto Mask off and 870 ms with it on; at 4096 it costs 0.3 s off and 2.0 s on.

## 3. Mouse event to visible stroke (base code)

**On each mouse event** (`MaskCanvas.dragBrush`, around line 1305):
1. Pressure is read from the NSEvent.
2. `BrushStabilizer.next` runs.
3. The event is dropped if it moved less than 0.5 view points.
4. The point is appended, `livePoints = points` (an O(n) array copy plus a SwiftUI invalidate), and the Canvas redraws.
5. `drawBrush` strokes a straight-segment polyline through all `livePoints` in white at 32% opacity (18% when erasing), with width = diameter and round caps.

During the drag, nothing is rasterized and the recipe is not touched. The cost is microseconds. The catch is that the user sees a stand-in, not the stroke:
- no feather, Flow, Density, Auto Mask or erase result, and no adjustment effect;
- straight chords where the raster will use Catmull-Rom. On the six-event flick fixture the spline sits up to **25.4 px** off the preview polyline.

**On mouse-up** (`commitBrushStroke`):
1. `livePoints = []`, so the white trail disappears at once.
2. The whole `BrushStrokeSet` is re-encoded to JSON (60 strokes × 300 points ≈ **0.96 MB**), hashed with xxh64, and written as a new blob by `MaskCanvas.apply(.strokes)` → `catalog.blobs.store` on the main actor. Each stroke writes the whole set again, so 60 strokes leave about 29 MB of superseded blobs.
3. `state.remember`, then `updateRecipe` sets `strokesRef`.

**Draft render** (`PipelineRenderer`, around lines 1800–1860, `allowStaleRasters: draft`):
- The key's `strokesKey` count changed, so `MaskRasterCache.plane` **serves the previous raster, without the new stroke**, and queues the bake on `lumen.maskraster.bake`.
- Nothing calls `MaskRasterCache.hasPendingBake`. The only `anyBakePending` caller is `PlanTableCache`'s. So a finished draft bake never triggers a new frame.

**Settle** (40 ms debounce, `RefineBudget.loupe`, then `allowStale: false`):
- The bake runs inline. `BrushPlaneCache.plane` checks the prefix: `Array(prefix(n)) == held.strokes`, which is O(all points).
- It resumes the held plane at the fold size (settled budget 96 MB, so only two 4096 planes) and paints only the new stroke.
- `MaskRaster.combine` runs, then `image(from:)` copies the plane into a `CIImage(bitmapData:)` (.Rf, 17.5 MB at 2560, 45 MB at 4096) for the GPU.
- Brush planes never take the `MaskGPU` closed-form path, which covers gradients only.

**What the user sees.** From release until settle lands, the stroke is gone. That gap is the debounce (40 ms), plus the stroke paint (above), plus the full-graph settle render. At 2560 a 30-radius stroke is at least about 150 ms with Auto Mask off and about 0.9 s with it on.

**Other full repaints:**
- An undo, or any change that is not a prefix, repaints the whole set. 60 such strokes at 2560 take about 4.1 s off and 35 s with Auto Mask.
- A brush with Auto Mask keys on the S6–S10 picture fingerprint, so every exposure or tone nudge repaints all of its strokes.
- A stroke with r < 3 px forces a fold grid up to 4× (`brushSupersample`).

## 4. Lightroom behaviour

Partly sourced. Adobe's masking page returned 403, so the slider definitions here are from search snippets of it and the rest is **from knowledge**.
- **Size:** diameter. `[` and `]` change it, as does the scroll wheel.
- **Feather:** shown as the gap between the inner and outer circles; Shift+`[`/`]`.
- **Flow:** "rate of application". A stroke at Flow 50 deposits about 50%, and only separate strokes build up (two passes give about 75%). Number keys set Flow.
- **Density:** "amount of transparency"; a ceiling that passes never exceed.
- **Erase:** Alt/Option, with **its own Size/Feather/Flow set** (knowledge); erase at Flow 50 removes about half.
- **Auto Mask:** "confine strokes to areas of similar color". It samples under the centre crosshair as the brush moves, so dragging the centre across an edge paints the other side, as in our case (b). Edges are colour-plus-contrast based and fairly tight, and shading on one object is followed (knowledge). The cursor shows a `+` at the centre when Auto Mask is on.
- **Pen pressure:** modulates Flow, not Size, in LR Classic (knowledge; low confidence, and reports conflict).
- **Feedback:** the adjustment and the `O` overlay update live under the brush while painting. There is no grey stand-in and no gap on release (knowledge).
- **Shift:** Shift-click draws a straight line.

Sources: helpx Masking (lightroom-classic/desktop/process-and-develop-photos/masking.html, via search snippet), slrlounge.com Adjustment Brush tutorial, imagen-ai.com "lightroom brushes".

## 5. Defects (base 84bcd7c)

1. **Flow has no effect within a stroke** (stamp deposits compound about 20×).

   | Flow | 1 | 5 | 10 | 25 | 50 | 100 |
   |---|---|---|---|---|---|---|
   | stroke centre alpha (expected = Flow) | 0.178 | 0.632 | 0.872 | 0.996 | 1.0 | 1.0 |

   The same at 1024 and 4096. Two crossing Flow 50 strokes give 1.0 where 0.75 is expected (`$A/flow/`, brushlab `flow50`).
2. **Erase ignores Flow:** erase at Flow 50 leaves 0.0 where 0.5 is expected (brushlab `erase`).
3. **Feather is broken along a stroke.** The stroke's 50% point, as a fraction of r, against the dab and cursor:

   | Feather | stroke 50% point (r) | dab / cursor (r) |
   |---|---|---|
   | 50 | 0.867 | 0.745 |
   | 100 | 0.793 | 0.476 |

   Maximum error against the dab profile is 0.58–0.64. The 10–90% edge at Feather 100 is only 0.24 r wide. The cursor's inner ring lies.
4. **Pressure does nothing.** A ramp of 0.1→1 paints 0.839 / 0.999 / 1.0 / 1.0 / 1.0 where 0.163 / 0.376 / 0.601 / 0.826 / 1.0 is expected. Width stays 80–82 px.
5. **A scribble builds up on itself:** a Flow 50 stroke that doubles back paints 1.0 (brushlab `scribble50`).
6. **Auto Mask gate saturates:** the one-stamp gate at ΔE 0.10 is 0.26, but a stroke gives 0.986. The edge is a hard step at ΔE ≈ 0.11, and partial gates build up into leak.
7. **Auto Mask leaks:** in case (a) it leaves 14–15.5% of the mass outside the object (10% beyond 3 px). With Auto Mask off the figure is 27%; an LR-grade tool should be about 3% or less.
8. **Auto Mask has no stroke memory:** in case (b) leak is 35–42%, the same as off (±4 points).
9. **Auto Mask breaks on shading:** in-object coverage 5th percentile is 0.675 on the lemon, and on the can it is 0.0, because dirt patches are refused. Euclidean ΔE gives L the same weight as chroma, so ±0.7 EV of shading counts as "different" while red against grey is "similar".
10. **Auto Mask produces speckle:** 26 isolated speckle pixels on the concrete at the can's edge; the gate is per pixel with no prefilter or connectivity.
11. **Auto Mask is 7.4× the cost** of a normal stroke: 62 against 8.4 ns per pixel per stamp. A Size 0.08 stroke of 20 radii takes 1.36 s at 4096 and 0.58 s at 2560.
12. **Paint cost grows with r·length** and is about 20 times the one-pass coverage work. Size 0.2 at 4096 takes 55 ms per radius of travel with Auto Mask off.
13. **The live preview is not the stroke:**
    - a white 32% polyline with no feather, Flow, Density, Auto Mask or effect;
    - it differs from the Catmull-Rom raster by up to 25.4 px on fast strokes;
    - on release it vanishes and the stroke is missing until settle, at least 40 ms plus paint plus render, because the draft serves a stale raster and `MaskRasterCache.hasPendingBake` has no caller.
14. **Each mouse-up re-encodes and stores the whole set:** about 0.96 MB for 60 × 300 points, on the main actor, and blob storage grows O(N²).
15. **Undo and any non-prefix edit repaint every stroke:** 60 strokes at 2560 take about 4 s off and 35 s with Auto Mask. Any tone edit forces the same full repaint for a brush that uses Auto Mask.
16. **Erase shares the paint brush's Size/Feather/Flow.** LR keeps a separate erase brush (knowledge).
17. **The cursor shows no Auto Mask sample point:** there is no `+` crosshair (`drawBrush` draws rings only).
