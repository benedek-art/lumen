# 34 — Speed: the measured account

Written to be read COLD. This replaces an earlier draft of this file that planned a Metal
display path. **That plan was wrong and is cancelled** — §1 records why, because the way
it was wrong is the more useful lesson.

**Base:** branch `claude/photo-editor-design-plan-8ahzmm`, at or after `c3242e8`.
**Context:** `docs/33` §1 (the blur post-mortem; its three rules bind here).

Everything below is a MEASUREMENT or a code reading, labelled as one or the other. No
number in this document is an estimate unless it says so.

---

## 0. THE MEASUREMENTS

### 0.1 From the owner's machine (M4 MacBook Pro, 33 MP Sony ARW, latency HUD)

The decisive one. Same photo, same settle, same 4096 px:

| Noise Reduction | settle |
|---|---|
| **Off** | **30 ms** |
| **Classic** (the default) | **375.7 ms** |

Drafts, dragging Exposure at 3212 px:

| Noise Reduction | draft |
|---|---|
| Off | 20–40 ms, steady ~30 |
| Classic | 20–80 ms |

And at a smaller window, denoise off: settle 11–18 ms at 3212 px.

**Denoise is 92% of the settle.** The other fourteen stages — tone, colour, curves,
mixer, grade, output transform, dither — render 16.8 megapixels in 30 ms, about
560 MP/s. The hardware is not the problem and never was.

### 0.2 From this repository (Linux, `SpeedBenchTests`, `LUMEN_BENCH=1`)

The CPU half of every frame, which had never been timed:

| | |
|---|---|
| `RenderPlan(recipe:)` — exposure moved | 0.49 ms |
| `RenderPlan` — grade wheel moved (bakes the colour LUT) | 1.51 ms |
| `RenderPlan` — parametric curve moved | 0.82 ms |
| `ClassicalDenoise.gpuPlan` | 0.004 ms |

Per event, against a 16.6 ms budget for 60 fps: 3% for a tone slider, 9% for a grade
wheel. Not the bottleneck; not free either, and it explains the `536 bakes` in the
owner's HUD. Run them with `LUMEN_BENCH=1 swift test --filter SpeedBenchTests`.

### 0.3 What the numbers refuted

- **A comment this codebase reasons from is wrong.** `DraftLadder.stepUpFits` records "a
  draft at 2048 cost 8.5 ms". A draft at 3212 with denoise off measures ~30 ms — 2.4×
  the pixels for 3.5× the time, so the old number was never taken on this path. Treat
  every performance figure in a source comment as unverified.
- **A 169 ms draft reported in the first HUD reading does not reproduce.** Steady state
  is 20–80 ms. Part of that first figure was transient (cold decode, or contention).
  A single reading is not a measurement.

---

## 1. THE CANCELLED PLAN, AND WHY IT WAS WRONG

The first version of this document diagnosed the cost as `createCGImage` copying every
frame back to the CPU for SwiftUI to upload again, and planned a Metal display path —
texture pool, `CIRenderDestination`, `CAMetalLayer`, and the migration of eight consumers
that read the `CGImage`. A week of view-layer surgery.

It was proposed to the owner as the answer before anyone checked whether the arithmetic
worked. It does not: on unified memory the copy is not a bus transfer, and 25 MB does not
become 169 ms. The owner then asked to test before building, toggled one checkbox, and
the cost vanished.

**The rule this earns, beside `docs/33` §1's three:**

4. **A hypothesis that costs a week must survive an experiment that costs a minute.**
   Every performance claim in this project is now expected to name the measurement that
   would falsify it, before any code is written against it.

The Metal path may still be worth having some day — but not for this, and there is
currently no measurement that argues for it.

---

## 2. ROOT CAUSE 1 — DENOISE DOES NOT SCALE WITH RESOLUTION

**Status: measured (0.1), mechanism read from source.**

`ClassicNR` defaults to `chroma: 25`, so `plan.denoiseIsIdentity` is false for **every
photograph ever opened** and S3 runs on every frame of every drag. It is the most
expensive stage in the pipeline by an order of magnitude:

- 5 wavelet levels (`ClassicalDenoise.defaultLevels`), 31 px support at the deepest
- per level: subtract → shrink → subtract, where the shrink is a *neighbourhood* kernel
- hole spacing doubles per level to 16 px, so the deep levels read pixels ~80 apart —
  about the worst access pattern a GPU can be given
- plus forward VST, colour rotation, two edge maps, a guided filter for chroma, unrotate,
  restore

Roughly 30 passes at 6–17 MP with scattered reads.

**And the defect, precisely.** `ClassicalDenoise.scaled(noiseScale:)` exists for the
interactive path, and it scales the profile's VARIANCE — it makes the denoise gentler at
reduced resolution. It does not reduce `levels`, so the pass count is identical at every
scale. **The cost is scale-invariant while the benefit falls with scale.** At fit, the
decode has already downsampled 7008 px to 3212 and averaged most of the noise away; the
app then pays full price to remove what is no longer there. The same file already makes
this argument for the mask source: *"at a 1024 px proxy the noise it would remove is
already averaged away by the downsample."*

### The fix

1. **`levels` must fall with the decode scale.** A level whose support describes
   structure finer than the decode's own sampling describes nothing. This is arithmetic,
   not taste: level `j` has support `2^(j+1) − 1` px at full resolution, so at scale `s`
   the levels below `log2(1/s)` are measuring averaged-out noise. Put the rule in
   LumenCore beside `defaultLevels`, with tests.
2. **Skip S3 entirely on DRAFT frames at fit**, subject to the acceptance test below.
3. Consider whether `chroma: 25` should apply at preview scale at all.

**Acceptance — and this is the part that must not be waived.** The test is NOT "it is
faster". It is that the settle is **indistinguishable by pixel comparison** from the same
frame rendered with full levels, at fit. A level that changes the picture is not eligible
for removal however expensive it is. Skipping visible work is the blur defect wearing new
clothes (`docs/33` §1).

**Expected:** settle 375 ms → ~60 ms; draft 80 ms → ~30 ms.

---

## 3. ROOT CAUSE 2 — THE SETTLE RENDERS PIXELS NOBODY SEES, TWICE

**Status: read from source, corroborated by the owner's HUD (`draft @3212`,
`settle @4096` on the same frame).**

`DraftResolution.visibleCeiling` caps a render at what the panel actually draws. It is
applied to the DRAFT and not to the SETTLE. `LoupeView.requestedLongEdge` buckets the
CONTAINER's long edge to 256 px and clamps at `maxRenderLongEdge` (4096), which for a
PORTRAIT photograph in a landscape pane is much larger than the drawn extent.

Two consequences, and the second is the expensive one:

1. **1.63× wasted pixels.** The settle renders 4096 px and the panel displays 3212. Those
   pixels are discarded by the downsample that follows. Nothing visible changes if they
   are never rendered.
2. **TWO RAW DECODES PER PHOTOGRAPH.** `AppleRawSource.DecodeKey` includes `scaleFactor`.
   Draft at 3212 and settle at 4096 are two different scale factors, so they are two
   cache entries and two full demosaics of a 33 MP file — one of which exists only to be
   thrown away. **This is a load-time defect, not just a frame-time one**, and it is the
   most likely single contributor to "five to ten seconds to open a photo".

### The fix

Apply `visibleCeiling` to the settle's ask as well, so draft and settle agree on one
size. One decode per photograph, and the settle stops rendering a third more pixels than
the screen has. This is free by construction — the discarded pixels were never displayed.

**Expected:** settle −40% before the denoise fix is counted; one demosaic per photo
instead of two on open.

---

## 4. ROOT CAUSE 3 — THE COLOUR LUT REBAKES PER EVENT

**Status: measured (0.2).**

A grade-wheel drag rebuilds the plan at 1.51 ms per event, against 0.49 ms for a tone
slider — the difference is the colour LUT bake. At 60 fps that is 9% of the budget spent
on the CPU before the GPU is asked for anything, and it matches the `536 bakes` the HUD
reported. `PlanTableCache` exists and is hit 1372 times, so the cache works; the question
is whether a moving wheel can reuse a neighbouring bake rather than minting one per event.

Lower priority than §2 and §3. Recorded because it was measured.

---

## 5. WHAT HAS NOT BEEN MEASURED

Stated so nobody claims these are fine:

- **Grid scrolling and thumbnail decode.** Never profiled.
- **Export.** Never profiled. Note `exportedImage` defers grain until after the resize
  and still gates on the film chain, so creative grain on an export is laid at decode
  resolution (`docs/33` §3).
- **Cold open vs warm.** The owner's 5–10 s may be first-open only, in which case
  prefetch matters more than decode speed. §3's duplicate decode is the first thing to
  fix regardless.
- **Masked settles at zoom.** `maskRasterCeiling` caps at 4096 and `MaskRaster.combine`
  is CPU. The owner's trace showed `rasters 0h 0b 0s` — no masks — so this is unmeasured,
  not absolved.

---

## 6. ORDER OF WORK

1. **§3, the visible ceiling on the settle.** Smallest change, helps both frame time and
   load time, cannot alter a pixel.
2. **§2, denoise levels scaled by decode scale.** The big one. Gated on the pixel
   comparison.
3. Re-measure on the owner's machine with the HUD. Targets: settle under 30 ms at
   viewport size, draft under 16 ms, `in/out` approaching 1:1.
4. Only then look at §4, and at the unmeasured paths in §5.

`DraftLadder.maxUpscale` stays at 1. Sharpness is not currency (`docs/33` §1, rule 3).
