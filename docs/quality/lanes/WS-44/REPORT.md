# WS-44 Brush masks: report

Branch `quality/m2-brush-masks`. Base `84bcd7c`. Audit `AUDIT.md`, spec `SPEC.md`, cross-lane
asks `NEEDS.md`. Builder, auditor and verifier were separate agents; two verify rounds.

## For the owner

1. Paint at Feather 0, 50, 100. The stroke edge should sit between the cursor's two rings and look like a click (dab) stretched. Before, Feather 100 painted a hard bar.
2. Flow 30: one pass gives 30 %, a second stroke on top builds. Option-erase at Flow 50 should halve the paint, not delete it.
3. While dragging, the red wash is the real stroke (soft edge, Flow, erase). After release it fades over ~0.4 s into the rendered mask. Tell me if the drag feels laggy on a full-screen stroke.
4. Auto Mask: start on the object, trace its edge with the cross just inside, then drag off it. Paint should stop at the edge. With a tablet, pressure should change strength.
5. One line is still needed in LoupeView (NEEDS.md #1). Until it lands, the live Auto Mask stroke shows uncut and the cut appears on release.

## Verdict per spec line

| # | Line | Before | After | Verdict |
|---|---|---|---|---|
| S1 | Stroke cross-section = dab profile, max error (Feather 0/25/50/75/100) | 0.155 / 0.510 / 0.581 / 0.616 / 0.638 | 0.0007 / 0 / 0 / 0 / 0 | PASS |
| S2 | Feather 100 50 % point (target 0.476 r) | 0.793 r | 0.476 r | PASS |
| S3 | Single dab unchanged | 0.005 | 0.005 | PASS |
| S4 | Flow 50 single / crossed (0.50 / 0.75) | 1.00 / 1.00 | 0.500 / 0.750 | PASS |
| S5 | Density 60 ceiling over 3 passes | 0.60 | 0.600 | PASS |
| S6 | No build-up within one stroke (Flow 50 scribble) | 1.00 | 0.500 | PASS |
| S7 | Erase Flow 100 / Flow 50 leaves (0 / 0.5) | 0.0 / 0.0 | 0.000 / 0.500 | PASS |
| S8 | Pressure ramp 0.1→1, centre at x=160..860 | 0.84, 1, 1, 1, 1 | 0.113, 0.326, 0.551, 0.776, 1.0 (expected = local pressure, within 0.012) | PASS |
| S9 | Fast strokes gap-free; 2-event flick at Flow 30 ripple | peak 1.0; flick painted 0.995 | peak 1.0; flick 0.300, ripple 0.000 | PASS |
| S10 | Auto Mask outline trace: leak ≤ 3 %, coverage ≥ 0.85 | leak 14.0 / 15.0 / 15.5 % (Auto Mask on); off 27 % | leak 5.3 / 13.4 / 4.3 % (lemon / apple / can); beyond 3 px of the object 2.9 / 8.0 / 1.1 %; coverage 0.93 / 0.91 / 0.93 | **FAIL** (threshold miss, see below) |
| S11 | Auto Mask crossing the edge: mass beyond ≤ 3 % | 41.5 / 35.2 / 40.2 % | 0.0 / 0.0 / 2.3 % | PASS |
| S12 | Per-stroke cost, size 0.08, 2400 px: ≥5× plain, ≥10× Auto Mask | 73.5 ms / 522 ms | 7.5 ms (9.8×) / 102 ms (5.1×); verifier, shorter stroke: 9.8× / 6.8× | plain PASS, **Auto Mask FAIL** |
| S13 | Point-by-point (live) = whole stroke | n/a | max diff ≤ 1e-6 | PASS |
| S14 | Identities (empty, Flow 0, Density 0, NaN points) | exact | exact | PASS |
| S15 | Resolution independence (BrushResolutionTests) | pass | pass | PASS |

S10: the lemon and can halve their leak (14.0 → 5.3, 15.5 → 4.3 %); the apple barely moves on
this metric (15.0 → 13.4 %). Tighter gates were measured (τ 0.05 and 0.045, lightness weight 0.25–0.3). They cut the
lemon leak to 2.7 % but drop apple coverage from 0.91 to 0.27 and lemon to 0.63: holes in the
object instead of a fringe outside it. A fringe is erasable, holes mean repainting, so I kept
τ 0.06. Most of the apple "leak" is its shadowed limb, which the colour-threshold ground truth
excludes (leak maps in the verifier's scratch); real leaks are onto the potato's shaded flank
and the yellow-green bowl rim, colours within the gate of the object.

S12 Auto Mask: per-pixel cost is now the feature conversion (three cube roots and a log, once
per pixel per stroke) plus the accepted-colour loop. 3.9× / 5.1× / 7.2× at size 0.02 / 0.08 / 0.2.

## What changed

- `Image/BrushRaster.swift` (new): the stroke is the dab profile of the distance to the
  Catmull-Rom centreline (slab per segment, exact-span wedge per joint, two end caps), max
  within the stroke, composited once: `a + c·(density − a)` / `a·(1 − c)`. Flow is per pass,
  pressure scales the deposit, the eraser respects Flow. No stamps, so no beading.
- Auto Mask: shading-invariant features (a/L, b/L, 0.2·ln L), an accepted-colour set grown only
  from homogeneous centre samples within τ of an accepted colour, deposit spread only through
  pixels connected to what the stroke already painted. Features cached once per pixel
  (`calloc` scratch).
- `MaskRaster.paint` uses it; `stampCenters`/stamp loop removed. `stampProfile` unchanged (shared
  with WS-48 similarity points).
- `Interaction/BrushLivePreview.swift` (new) + `MaskCanvas`: the stroke being painted is the
  real coverage tinted red, under the cursor; on mouse-up it fades (`Lumen.motionReadout`,
  0.15 s hold) instead of vanishing before the render lands. Auto Mask draws a cross at the
  sample point. `MaskCanvas(picture:)` added (default nil).
- `lumen-render strokes` (new): rasterizes a stroke-set JSON over a photo; PNG overlay, PFM
  plane, per-stroke timing. `brushlab.py` and `tools/automask.py` measure everything above.

## Latency: mouse event to visible stroke

Before: each event appended a point and SwiftUI redrew a hard white path (no feather, flow or
cut). On release the path vanished; the blob was re-encoded and stored; the draft frame served
the stale mask raster (nothing calls `MaskRasterCache.hasPendingBake`); the stroke appeared at
settle (40 ms debounce + paint at settle size + full render + `CIImage(bitmapData:)` upload of
the plane). Measured paint per stroke, 2400 px, size 0.08: 73.5 ms plain, 522 ms Auto Mask.

Per-dab cost (dab = 0.1 r of travel, size 0.08 at 2400 px): **306 µs → 31 µs** plain,
**2164 µs → 422 µs** Auto Mask. Size 0.2: 1858 → 167 µs, 14307 → 1985 µs.

Live path per mouse event (1500 px view, 100 pt brush, 300 events): **115 µs → 23 µs** plain,
**738 µs → 149 µs** Auto Mask (raster work only; plus building the overlay image from the
touched rect, a memcpy of up to ~6 MB for a full-view stroke, to be judged on the Mac).

Not fixed here: the stale draft raster (NEEDS.md #2), the whole-set blob re-encode per stroke
(O(N²) storage, AUDIT #14), and the full repaint when an Auto Mask stroke set sees a new
picture fingerprint (any tone edit). The plane upload is unchanged.

## Called it this way

- No build-up within one stroke (Flow is per pass, a second pass is a second stroke). Lightroom
  appears to behave this way; I could not confirm from Adobe's docs (403).
- Pressure drives Flow, not Size. Guess at Lightroom's behaviour, marked as such in AUDIT.md.
- Thin brushes at low resolution: a 1.5 px wide stroke now keeps its true area, so its peak is
  lower than the old saturated stamps gave (size 0.003 at 512 px: 0.68 of the 2048 px peak, was
  0.85). From size 0.02 up there is no difference.

## Verification and CI

Three verify rounds (fresh agent each time, spec + diff only):

- Round 1 (f4ec381) FAIL: S10 and S12 Auto Mask misses; D1 my hand-written animation broke
  `DesignSystemTests.testEverythingAnimatesThroughTheThreeMotions`; D5 live layer drawn over the
  cursor; D7 Catmull-Rom flattening up to 1.7 px off on S-shaped segments; D4 LoupeView never
  passes `picture:` (NEEDS.md #1). Fixed D1, D5, a first pass at D7.
- Round 2 (41b2e63) FAIL: D1, D5 confirmed fixed; D7 still 1.06–1.26 px. Fixed by doubling the
  subdivision until every sub-chord is measured within 0.2 px.
- Round 3 (ccad0bb): D7 fixed (worst 0.141 px; feather-0 render vs true curve max 1.0 → 0.19),
  no cost regression, nothing broke under fuzzing (±1e300 coordinates, 20k-point jitter, cusps).
  All 3056 LumenCoreTests pass (ControlProofTests skipped as in CI). **Lane verdict: FAIL on the
  two declared threshold misses, S10 and S12 Auto Mask. BLOCKED on those per the brief; no
  in-lane defect is open.**

Left as is, noted by round 3: the flatness loop runs before the 400k work guard, so a
pathological 100k-point jitter is slower (121 → 469 ms) with identical output; `strokes
--metrics` throws on ±1e300 input (stroke length is infinite, JSON cannot encode it).

`check-swift-surface.py` fails on base 84bcd7c in four sections (LumenRender Metrics/RecipeKeys/
main, AppState labels, LumenType Font); this branch adds nothing to them.

CI on ccad0bb (04:49 UTC): engine-linux PASS (all LumenCoreTests), GPU parity (macOS) PASS,
Proof sweep PASS; fixtures-linux FAIL only on the four pre-existing surface sections listed
above. UI layout (macOS, builds the app) PASSED on 41b2e63, which already had this
MaskCanvas; build-macos, test-fast, app-bundle and UI layout on ccad0bb were still queued
(macOS queue ~50 runs deep).
