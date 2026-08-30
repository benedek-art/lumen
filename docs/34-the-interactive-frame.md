# 34 — The interactive frame: making a drag run at the display's rate

Written to be read COLD. This is the plan for the owner's *"I do feel some sort of
stepping instead of a smooth, continuous and fast feedback… I feel like I have to move it
a little bit before actually happening"* — the first performance complaint in this
project's history that arrives with a MEASUREMENT attached.

**Base:** branch `claude/photo-editor-design-plan-8ahzmm`, at or after `c7cb729`.
**Context:** `docs/33` §1 (the blur post-mortem — its three rules bind here),
`docs/33` §3 (Stream B, which this document supersedes and expands),
`docs/23-master-plan.md` M1b (the signpost vocabulary this plan uses).

---

## 0. THE MEASUREMENT, AND WHY IT CHANGES THE QUESTION

From the owner's latency HUD, dragging Exposure on a 33 MP ARW, fit, no masks:

    in/out       59/s   11fps
    input+draft  96.0 ms
    draft       169.3 ms  @3062
    settle      407.2 ms  @4096
    tables      1372h 536b 133s
    bake/stale   0/s   0/s
    rasters      0h 0b 0s

Read it carefully, because three things in it are load-bearing:

1. **59 events in, 11 frames out.** The coordinator IS coalescing correctly — five of six
   events are dropped before they cost anything. This is not a queueing defect.
2. **169 ms to render 3062 px.** The frame is 3062 × 2041 ≈ 6.25 MP. That is about
   **37 megapixels per second** through the develop graph. Sixty frames a second at this
   size needs 375 MP/s — a factor of ten.
3. **`rasters 0h 0b 0s`** — no mask work at all in this trace, and `bake/stale 0/s` means
   no table baking on the drag path either. The 169 ms is the GRAPH, on pixels, and
   nothing else.

**And it refutes a number this codebase has been reasoning from.** The comment on
`DraftLadder.stepUpFits` records "a draft at 2048 cost 8.5 ms" on this same machine.
2048 → 3062 is 2.2× the pixels; 8.5 ms should have become ~19 ms, not 169. Either that
measurement was taken on a recipe with almost every stage inert, or it was never a
measurement at all. **Treat every performance number in the source comments as unverified
until it is re-measured.** This plan produces the first honest ones.

---

## 1. WHY THE OBVIOUS ANSWER IS PROBABLY WRONG

The tempting diagnosis, and the one this document's author reached first and stated to
the owner before checking the arithmetic:

> every frame ends in `context.createCGImage(...)`, which renders on the GPU and copies
> the result back to CPU memory, which SwiftUI then uploads again to draw it.

That is a true description of the code and almost certainly NOT the 169 ms. On Apple
silicon the memory is unified: the "copy back" is not a bus transfer, and 25 MB of RGBA8
at any plausible bandwidth is single-digit milliseconds. **A hypothesis that would cost a
week of view-layer surgery must not be adopted because it sounds right.** See `docs/33`
§1, rule 1 — this project has already shipped one defect that a comment predicted.

The arithmetic that DOES reach 169 ms is pass count. `RenderGraph.build` runs fourteen
named stages, and several are multi-pass internally:

| Stage | Why it is not one pass |
|---|---|
| `applyDenoise` | profiled multi-scale NR, upstream of everything |
| `applyTone` | driven by an edge-aware **guided** mask — a guided filter is several passes |
| `applyPresence` | texture/clarity/dehaze, each with its own local statistics |
| `applyLocal` | per-mask, and each mask is its own subgraph |
| `applySharpen` | unsharp with halo suppression: blur + combine + mask |
| `applyHalation` | a wide blur, which at 6 MP is many passes |
| `applyLocalCurves`, `applyGrain`, `applyVignette`, matrices, shapers | one to a few each |

Fifty to a hundred kernel invocations at 6.25 MP in `RGBAh` (8 bytes per pixel, so ~50 MB
read and 50 MB written per pass) is 5–10 GB of memory traffic per frame. **That** reaches
169 ms, and it points at an entirely different fix from the display path.

**So the first milestone is not code. It is attribution.**

---

## 2. M0 — ATTRIBUTE THE 169 MS (do this before anything else)

Nothing below M0 may be started until M0 has produced a table. The two candidate
projects — a Metal display path and a graph reduction — share almost no code, and picking
wrong costs weeks.

### M0.1 Per-stage signposts

`PipelineRenderer.signposter` already exists (`OSSignposter`, subsystem `dev.lumenapp`,
category `render`) and is used for one interval around the whole render. Extend it: one
`beginInterval`/`endInterval` pair per stage in `RenderGraph.build`, named exactly as the
stage functions are.

Core Image is lazy, so **wrapping the graph-building calls measures nothing** — they
return unevaluated `CIImage`s. The interval must be around a forced evaluation, which
means M0.1 is a HARNESS, not an instrumentation of the live path:

- a debug-only entry point that takes a recipe and a source, builds the graph stage by
  stage, and after each stage rasterizes a 1×1 sub-rect to force evaluation up to that
  point, recording cumulative time;
- differences between consecutive cumulative times attribute the cost.

This deliberately over-counts (each forced evaluation may discard cached intermediates);
its purpose is RANKING the stages, not costing them exactly.

### M0.2 The readback question, answered directly

One measurement settles §1: render the same graph twice on the owner's machine, once via
`context.createCGImage(...)` and once via `context.startTask(toRender:to:)` into a
`CIRenderDestination` backed by an `IOSurface`, and compare wall time. If they are within
noise, the display path is NOT the problem and M2 below is cancelled.

### M0.3 The pixel-count control

Render the same recipe at 1531, 2048, 3062 and 4096 px and record the times. If cost is
close to linear in pixels, the graph is bandwidth-bound and stage reduction is the lever.
If it is superlinear, something is scale-dependent (kernel radii in pixels rather than in
image fractions) and THAT is the bug.

**M0 acceptance:** a table in this document naming the three most expensive stages with
numbers, plus a yes/no on the readback, plus the scaling curve. Everything after this is
chosen from that table.

---

## 3. M1 — THE CHEAP WINS THAT ARE TRUE WHATEVER M0 SAYS

These do not depend on the attribution and can proceed in parallel.

### M1.1 Do not render what cannot be seen

At fit, a 33 MP photograph is displayed at ~6 MP: a linear downsample of about 2.3×. Any
stage whose spatial scale is finer than one device pixel at the current view scale
contributes **nothing the owner can see** and is being paid for in full on every frame of
every drag. Candidates, with their own comments already conceding the point:

- `applyDenoise` — its comment says the mask source skips it because "at a 1024 px proxy
  the noise it would remove is already averaged away by the downsample". The same
  sentence is true of a fit view of a 33 MP file.
- `applySharpen` — capture sharpening at a 2.3× downsample is below the display grid.
- `applyGrain` at fine pitches — same argument (`FilmGrainProfile.plateScale` already
  knows the pitch in pixels and has a half-pixel floor).

**The rule, and it must be a rule rather than a list**: a stage may be skipped in a DRAFT
when its characteristic radius in DEVICE pixels is below some threshold (start at 1.0),
computed from the stage's own parameters and the current scale. Put it in LumenCore as
`InvisibleStages` (or similar) with tests, so the argument is checkable and so the same
rule serves the compare panes and the scope proxy.

**The trap** (`docs/33` §1, rule 1): if skipping a stage is VISIBLE, this is the blur
defect wearing new clothes. The acceptance test is not "it is faster" but "the settle is
indistinguishable from the draft at fit, by pixel comparison, for every stage skipped".
A stage that fails that test is not eligible, however expensive.

### M1.2 Stop paying for the settle nobody sees

`settle 407 ms @4096` on a 3062 px viewport: the settle is rendering **4096 px for a
3062 px panel** — 1.8× the pixels, all of them discarded by the downsample to the panel.
`requestedLongEdge` buckets the container UP and clamps at `maxRenderLongEdge`; check
whether the bucket is overshooting, and whether the settle at fit should simply be the
viewport's own device size (which is what `maxUpscale = 1` already makes the draft).

This is possibly the single cheapest large win in this document: it costs nothing visible
by construction, because those pixels were never displayed.

### M1.3 Present on the display's clock

`in/out 59/s → 11 fps` is honest coalescing, but the frames that DO arrive are not
aligned to anything. Consider driving delivery from a `CADisplayLink`/`CVDisplayLink` so a
completed frame is presented at a refresh boundary rather than whenever it lands. This
does not make anything faster; it makes an uneven 11 fps read as a steady one, and
"stepping" is a complaint about evenness as much as about rate.

---

## 4. M2 — THE METAL DISPLAY PATH (conditional on M0.2)

**Run this only if M0.2 shows the readback and present path is material.** Recorded in
full because the owner asked for it planned, and because if M0.2 says yes, this is the
shape.

### M2.1 What it is

Stop producing a `CGImage` per interactive frame. Instead:

1. The renderer owns a small **pool of `MTLTexture`s** (triple-buffered, IOSurface-backed,
   sized to the viewport and re-allocated only when it changes).
2. Each frame renders with `context.startTask(toRender:from:to:at:)` into a
   `CIRenderDestination` wrapping the next free texture. `CIRenderTask.waitUntilCompleted()`
   off the main actor.
3. The view is an `NSViewRepresentable` hosting a `CAMetalLayer`; presenting a frame is
   handing it the texture, not building an image.

### M2.2 What it must not break — the real work is here

The `CGImage` is not only drawn. Everything below reads it, and each needs an answer
BEFORE any code is written:

| Consumer | Current source | Answer needed |
|---|---|---|
| `plate()` / `Image(decorative:)` | the CGImage | replaced by the Metal layer |
| `ProxyResampling` interpolation | SwiftUI `.interpolation` | becomes the sampler state in the Metal pipeline; the RULE stays in LumenCore |
| `InspectionGain.displayed` (`[`/`]`) | wraps the CGImage | a shader uniform, or a tiny extra pass |
| `PixelSampler.make(from:)` (readout, clipping, mask overlays) | the CGImage | **needs CPU pixels.** Read back on demand — `samplerNeeded` already gates it, and it is not needed during a drag |
| `BeforeAfterSplit` / `BeforeAfterPair` | two CGImages | two textures, or keep these on the CGImage path |
| Crop canvas rotation | SwiftUI `rotationEffect` on the image | layer transform, or keep crop on the old path |
| Compare / survey panes | CGImages | keep on the old path; they are small and not dragged |
| Export, HDR, `renderFullSize` | CGImage | **untouched. Do not migrate the export path.** |

The honest scope: **the loupe's own plate migrates; nothing else does.** A flag selects
the path, the CGImage path stays as the fallback for no-Metal machines and for every
surface not listed as migrated.

### M2.3 Colour is the risk that will bite

The current call is explicit: `format: .RGBA8`, `colorSpace: sRGB`, from an
extendedLinearITUR_2020 working space. The Metal path must reproduce that transform
EXACTLY — the layer needs its `colorspace` set and its pixel format chosen to match, and
`wantsExtendedDynamicRangeContent` left alone until the HDR path is deliberately
addressed.

A colour shift here would be the worst possible outcome: an app whose entire premise is
that the picture is honest, quietly grading every photograph differently. **Acceptance is
pixel comparison against the CGImage path on a ramp and on a real frame, not "it looks
the same".**

### M2.4 Sequencing

1. Spike behind a flag: the Metal layer displays the frame, nothing else changes. Measure.
2. Colour verification harness (M2.3) before any interaction work.
3. Resampling, inspection gain, overlays.
4. Sampler read-back on demand.
5. Fallback policy and flag removal.

---

## 5. VERIFICATION, GIVEN THAT NOTHING HERE COMPILES ON THE FREE LANE

`LumenPipeline` and `LumenApp` are macOS-only; the Linux lane parses them and nothing
more. So:

- **LumenCore holds every rule** — the invisible-stage threshold, the resampling decision,
  the present cadence. That is where the tests live, and it is why M1.1 says "put it in
  LumenCore" rather than inline.
- **`gpu-parity` is the safety net for colour.** It compares the GPU graph against the CPU
  reference. It does NOT cover the display path, so M2.3's comparison harness is a NEW
  test, and it must run somewhere a Mac exists.
- **The owner's HUD is the acceptance instrument.** Every milestone states its target as
  a number he can read off: `draft` ms at viewport size, and the `in/out` ratio.

**Targets, stated once:** `draft` under 16 ms at viewport resolution (60 fps), `in/out`
approaching 1:1, and the picture pixel-identical to today's at rest. Sharpness is not
available as currency — `DraftLadder.maxUpscale` stays at 1 (`docs/33` §1, rule 3).

---

## 6. WHAT THIS DOCUMENT DELIBERATELY DOES NOT DO

- It does not start with the Metal path, though that is what was asked for, because the
  measurement that would justify it has not been taken. M0.2 is one experiment and it is
  cheap. If it says the readback is material, M2 begins that day.
- It does not tune the draft ladder. That lever is spent and the trade it makes is
  forbidden.
- It does not touch the export path. Nothing in this document may make an exported file
  differ by one code value.
