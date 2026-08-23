# 19 — The basics, made great

Doc 18 aimed at "70% of every feature". Five independent audits then measured the app
and the owner used it, and both said the same thing from different directions: the
engine is strong and the things a photographer touches every day are not. This
document narrows the target to those things.

## What changed about the goal

**Dropped: beating DXO at denoise.** It needs a trained network and it was never what
this editor is for. Tier 1 is a competent classical wavelet denoiser — measured, at
Luminance 25, it keeps 20.4% of the noise while holding 0.885 correlation with real
texture, where a matched Gaussian holds 0.424. That is honest and useful. If Tier 2
lands it will be a model somebody else trained, and the panel will say so.

**Dropped: Lightroom feature parity.** No ingest engine, no virtual copies, no HDR
merge, no tethering, no panorama, no print module. Lightroom is twenty years of that
tail and matching it is not a goal.

**Kept and sharpened: the creative darkroom.** Film stocks, per-channel density grain,
halation, printer lights, primaries, grading wheels, the colour-balance grid — the
audits scored these 72–80 and called the grain model ahead of Lightroom and Capture
One. This is the part with no equivalent in the competition, and it is why the app
exists. It needs saveable looks and LUT import to be usable, not more engine.

## The bar for "basic"

A control is basic if the owner touches it on an ordinary edit. That list:

open a folder · cull with flags · white balance · the six tone sliders · the curve ·
HSL · Texture / Clarity / Dehaze · a gradient mask · a brush mask · sharpen · denoise ·
crop · save a look · apply that look to another photo · export

Nothing else is in scope until every one of those is good.

## Phase 1 — the sliders feel right

The owner's report: "its slow finiky", and "while I'm dragging a different colour
comes up on the screen and then when I let go it applies something different."

| Fix | What it was |
|---|---|
| One LUT size for draft and settle | Draft baked at 17³, settle at 33³. Measured over 30 000 in-gamut colours, size 17's p99 error is 0.1465 — **37 of 255 levels** — against size 33's 0.0767. The drag preview was a different picture, worst in exactly the highlights and saturated tones a photographer watches |
| Draft follows the viewport | A fixed 1024 px blown up 2–3× into a Retina loupe, so the drag frame was soft as well as miscoloured |
| Canonicalization off the input path | `saveRecipe` ran 4 JSON encodes + 4 decodes of the whole recipe on the main actor per mouse event — ×40 on a batch drag — to build a string it then handed to a background queue |
| `AppState.photos` memoised | 1.68 ms to rebuild at 5 000 frames (+2.41 ms under filename sort), read from seven places, re-evaluated on every published write: ~12 ms of main-actor bookkeeping per mouse move before a pixel was requested |

## Phase 1, second pass — the first session on a Mac

Phase 1's four fixes had never been seen by a human. The owner ran the app on a Mac for
the first time and the loudest complaint was still responsiveness: *"Right now the
sliders are really slow. Everything is super unresponsive. The image isn't really
updating very well"*, and *"there are lots of zoom in, zoom out things that happen when
I'm not pressed on the image full screen."* He also reported Highlights, Whites and
Blacks as not working.

**Highlights was not dead, and the drag was not eaten.** The screenshot reads Highlights
2, Shadows 7, Whites 11, Blacks −7 — tiny values on ±100 controls, where Phase 2's
measured authorities are 55.8 / 47.6 / 23.3 code values at full travel. The offered
explanation was that the interface dropped most of his gesture. It does not hold: the
drag is relative, so the value is a pure function of where the pointer is now relative to
the press, and event coalescing keeps the newest sample. A drag to the end of the track
that loses every event but one still reports the end of the track. On the ~158-point
track the develop column affords, a ±100 control moves 1.27 units per point — Highlights
2 is one and a half points of travel, Whites 11 is nine. Those are presses that moved a
few pixels. The picture never answered him, so he never committed to a gesture.

| Fix | What it was |
|---|---|
| The release is a sample | `onEnded` set a flag and ignored `value.location`, so what a drag was worth depended on whether a motion event beat the mouse-up — and that is exactly the sample a blocked main actor loses. Drag arithmetic moved to `SliderTrack` / `SliderDrag` in LumenCore, where it is tested |
| The backfill stopped holding the catalog's only lane | `backfillMetadata` ran its whole paged loop — the transactions AND a file open plus a megabyte hash per photograph — inside one `queue.async`. For minutes, every recipe write, grid query and preview lookup sat behind it. It now drives from a `maintenance` queue and holds the lane for one transaction at a time |
| Decode workers suspend instead of blocking | `previewState` was `queue.sync` from eight `Task.detached` workers. A blocked cooperative thread cannot run anybody else's continuation, so with the pool full the render actor got no turn and every `await` in the refine driver stopped resuming — the interface moves, the picture does not. Now `async` through the existing continuation |
| Render coalescing that can actually drop | The generation ticket is claimed when a request *enters* the serial actor, so a queued backlog always compares as current and every superseded frame of a drag was rendered in full. `.task(id:)` had already cancelled those tasks; `produce` now reads `Task.isCancelled` |
| `catalogID` memoised | `persist` ran `allPhotos.first(where:)` — a linear scan of the source, per changed photo, per mouse event, for an id `editTargets` already carried. 200 000 URL comparisons per event on a 40-frame batch drag at 5 000 files |

**The unexpected zoom is two defects, neither of them a stray gesture.** There is no
magnify or scroll handling anywhere in the app and `zoomLevel` has one writer, so the
shape everybody looked for does not exist. What does: (1) the viewer's press gesture
toggled the zoom whenever the pointer moved under three points, on a gesture covering the
whole canvas whose pan branch returns early at fit — so at fit *every* press, including
one on the grey surround and one meant to focus the window, zoomed in, and the next
zoomed out; and (2) above fit the frame is drawn at `proxyPixels × ratio`, while the
draft pass is asked for exactly half the settle's long edge — so the photograph halved
and doubled on every render, which during a drag is every mouse event. `ViewportClick`
and `DraftResolution` in LumenCore are the two rules, with tests.

**The blue rectangle** the owner asked about is macOS's own focus ring on `.focusable()`.
The viewer must stay focusable — the bare-key grammar depends on it — so the ring is
suppressed with `.focusEffectDisabled()`. Law 7 makes chrome zero-chroma grey precisely
so nothing in the surround biases a colour judgement, and a saturated blue rectangle
framing the photograph is the largest chroma on screen. Nothing replaces it: the ring
answered "does the image have focus", and the question actually being asked is "why did
my keys stop working", whose answer is always a text field having taken focus — which the
ring never said.

**None of this was run.** There is no Swift toolchain reachable from the environment this
was written in (download.swift.org answers 403 through the proxy), so `swift test` and
`swiftc -parse` were both unavailable; the LumenCore tests added here are unrun and every
claim above is read from source. The two Python gates were run and stay green. This is
still audit UX-01: the five loops have no instrumentation, and until a signpost trace
exists on the owner's Mac, "the sliders feel right" remains a code-inspection claim.

## Phase 2 — the sliders are accurate

Measured authority over −8…+5 EV, full travel, in sRGB code values:

```
Exposure ±2 EV  169.5      Contrast    81.6      Highlights  79.4
Shadows          74.6      Whites      18.2      Blacks       2.9
```

- **Blacks moves the picture by 2.9 of 255 levels.** Below the visible threshold on an
  8-bit display. The ±1.5 EV anchor move lands in a toe that already puts scene −4 EV
  at code 9.4, so it has nowhere to act.
- **Highlights delivers 87% of its effect in its first half** (0→−50 moves 30 levels,
  −50→−100 moves 4.7) and its strength varies **×3.9 with Contrast** and ×1.8 with
  Whites, through the per-window soft cap that `solveZonalScale` replaced.
- **Sharpen Detail runs backwards.** Measured gain at a 2 px period, Amount 100:
  Detail 0 → 1.99, Detail 100 → 1.16. The reference goes 2.00 → 2.00.
- **80% of the Colour denoise slider is inert.** Chroma kept: 0→100%, 10→10.5%,
  20→2.8%, then flat to 100. Every shipped ISO anchor from ISO 400 up sits in the dead
  zone, so the Colour half of the ISO defaults changes nothing.

### Where the six sliders are now

Same measurement — peak sRGB code separation between the two ends of the travel, over
−8…+5 EV — after rebuilding the zonal windows as shelves and replacing the per-window
monotonicity caps with one solved scale over the whole zonal sum:

```
Exposure ±2 EV  169.5      Contrast    81.6      Highlights  55.8
Shadows          46.8      Whites      47.6      Blacks      23.1
```

Blacks was 2.9 and Whites 18.2, because both only moved the display anchors, into a toe
and a shoulder that had already compressed the tones they were aiming at. They carry a
tonal shelf of their own now, on top of the anchor move, sitting above and below where
Highlights and Shadows have already saturated so the two pairs act on different tones.

Highlights and Shadows read lower than the 79.4 and 74.6 above and are stronger
controls than those numbers were. Those were bumps: peak gain halfway to the anchor,
falling back to zero AT it, so Highlights −100 did nothing whatever to the brightest
values — 87% of its effect landed in the first half of its travel. A shelf saturates
instead of returning, which spends the range where a photographer is looking:

| | first half | second half |
|---|---|---|
| Highlights −100 | 16.3 | 23.0 |
| Shadows +100 | 13.2 | 19.6 |
| Whites +100 | 16.3 | 24.5 |
| Blacks +100 | 6.8 | 8.0 |

Every slider now splits 40–56 / 60–44 instead of 87 / 13. And Highlights −100 pulls a
scene value at +4 EV from code 250 to 214, and at +5 EV from 255 to 234 — recovery from
clipped white, which is the one thing the control is for and the one thing the bump
could not do.

**The sliders stopped moving each other.** `effectiveHighlights` at Highlights 100 is
1.0000 at every Contrast setting from −100 to +100; it used to run 0.218 → 0.857, a
×3.9 swing in what one slider meant depending on where a different one sat. Shadows +60
applies 0.6000 with Highlights at −100, +100 or absent; it used to become 0.338.

What replaced the per-window caps is one scale over the whole zonal sum, and because
`mapped(t) = contrastMapped(t) + scale × zonal(t)` is linear in that scale, the largest
safe value is closed-form rather than searched: one sweep, 0.048 ms, against 10.9 ms
for the bisection it started as. It is exactly 1 — no coupling at all — for 98.8% of
edits with all five sliders inside ±60 (±40 on the end points), and for every setting
whatever at Contrast ≥ +80, where the base slope has room to spare. It binds only where
the four windows together would run the response downhill, and there it eases onto the
limit rather than clipping at it, so the top of the slider still moves: Contrast −100
with Blacks sweeping 0→100 walks code 20.9 → 48.0 with a step at every stop.

**Nothing flattens any more.** The baked tone curve's monotonicity clamp fires on 0 of
1024 samples for every one of the 242 combinations of all five sliders at ±100. Clamping
alone, without the solve, left 160 flat at two sliders and 497 at five — 16% and 49% of
the tonal axis rendering as a single value.

### The curve

The point curve was already exact — it lands on its own control points to 0.000000, so
a photographer who places a point gets that point. The four parametric sliders were not.

**Between 30% and 53% of every parametric slider applied the identical curve.** Darks
and Lights stalled at setting 47, Shadows and Highlights at 70, and every setting above
that rendered the same picture. The cause was one shared peak shift — 0.35 encoded units
for all four regions — which the monotonicity limiter then cut back to whatever each
region's own width could actually carry. The regions are not the same width: the middle
two are half the outer two at the default splits, and the splits are user-movable down
to 0.02 apart, so one number was never going to be right for four of them.

**And where it bound, it bound at slope zero.** A single slider at full deflection put a
dead-flat segment in the curve — a posterized band, reachable on all four sliders on
their own. The limiter's definition of safe was "not an inversion", and flat is not an
inversion.

Both are gone. Each region's amplitude is now solved from its own shape, to a slope
floor of 0.2 rather than to zero, so a lone slider is monotone by construction and never
meets the limiter at all:

```
                 at 50    at 100   second half   min slope at 100
  Shadows ±100    12.8     25.7        50%            0.20
  Darks   ±100    15.3     30.6        50%            0.20
  Lights  ±100    16.2     32.4        50%            0.20
  Highl.  ±100    13.3     26.7        50%            0.20
```

Exactly half the effect in each half of the travel, every region, both directions, and
no setting between 1 and 100 that repeats the one before it. Peak authority costs 15–20%
against the old numbers — Darks moved 38.3 code values, now 30.6 — and the old peak was
only ever reachable at setting 47 and above, all of which rendered the same picture.

The floor and the knee are one decision, not two: a lone slider leaves the curve with
slope `parametricMinSlope`, and the combination limiter would let it go
`1 / (1 − 0.2) = 1.25` times further, which is exactly `1 / 0.8`. So the lone slider sits
precisely at the knee and is applied exactly. Combinations that genuinely conflict —
Shadows up against Darks down — are eased onto their limit rather than clipped at it, and
bottom out at slope 0.0126: a hard compression band, monotone, with no flat sample
anywhere. That is what asking two neighbours to fight means, and the point curve stays
the unlimited tool for anyone who wants more.

The solve is closed form, like the tone one and for the same reason: **0.50 ms per bake,
against 7.90 ms** for the forty-sweep bisection it replaced. `ZoneWeights` no longer
allocates a weight vector per sample either, which the tone engine's zone panel was also
paying for.

### Clarity

The GPU was applying between **1/2.6 and 1/48 of the gain the reference specifies**.
Measured against `DetailEngine.applyClarity` on five frames, at Clarity +30: 0.00988 EV
against 0.02704 on a 24 px texture, 0.00420 against 0.02553 on a 64 px one, and 0.00025
against 0.01193 on the spatial golden's own frame.

Two causes, and the second hid the first. The gain was `exp2(k·Δ)` — a linear gain on
the detail band with an amplitude nobody had checked against the reference — while the
reference parameterizes Clarity by a remap EXPONENT, `α = max(1 − 0.7·amount·w, 0.05)`
applied as `σ·(|Δ|/σ)^α`. A power law with α < 1 expands a small band far harder than a
linear gain does: at Δ = 0.1 EV and Clarity +30 it adds 50% where `k` adds 33%. And the
band is small, because the base is edge-preserving by design. The GPU now applies the
reference's own remap to a single band. Strength lands between 0.5× and 1.3× of the
reference instead of between 0.02× and 0.4×.

The gap that remains is the algorithm. The reference is a local Laplacian over six
remap levels and a five-level pyramid; one band cannot reproduce it, and the difference
shows up as a rim beside a hard edge — measured on a clean 3 EV step, 0.0117 EV at
Clarity +30 and 0.127 EV at +100, against the local Laplacian's 0.0014 and 0.0049. For
scale, the two-base construction that preceded the current one left 0.72 EV there. A
local Laplacian on the GPU is what closes it, and that is not done.

**The test that should have caught this could not.** It asserted that Clarity +30 moved
a 64×32 frame by more than 0.001, on a frame whose only texture is `cos(x·π)` — Nyquist
detail, put there deliberately so the FINE band could see it. Clarity's band is built at
radius 3 on that frame and responds to almost none of it, so the assertion was reading
the ramp leaking through, and it read 0.00098 against a bar of 0.001. A presence bar
cannot separate "weak" from "absent" when the frame contains nothing for the stage to
act on. It now runs on a frame with 12 px structure and compares the GPU's movement to
the reference's on the same frame, which is the ratio that was 1/48.

### Texture — measured, not fixed

The same measurement, run on the stage beside Clarity: **1.8× to 17× under the
reference**, at Texture ±40, on seven frames.

```
  frame                     +40 off by    −40 off by
  64x32 Nyquist ripple        17.1x          4.0x
  256x256, 2 px detail         2.1x          2.0x
  256x256, 4 px detail         6.0x          6.0x
  256x256, 8 px detail         3.9x          3.7x
  256x256, 16 px detail        2.1x          2.0x
  1024x256, 4 px detail        5.9x          5.9x
  1024x256, 16 px detail       1.8x          1.8x
```

Two causes. The band comes off a single edge-preserving guided base whose threshold is
0.1 EV, so it keeps 86% of any texture whose local excursion exceeds a tenth of a stop —
essentially all real texture — and Texture acts on the residue. And the coefficient is
`amount × 0.9`, where `DetailEngine.applyTexture` normalizes its window to
`referenceBandWeight(halfWidth: 1.6)` = 1.617.

**Porting the reference's band exactly was tried and reverted, and what it found is the
reason this is still open.** Building `Σ wℓ · (sℓ − sℓ₊₁)` over the à-trous stack made
positive Texture measure 1.00× the reference on every frame — and turned two goldens red:

- `testPresenceDoesNotRimAHardEdge`: Texture +100 dug a 1.21 EV trench beside a clean
  3 EV step, against a bar of 0.30. **The reference digs 1.39 EV on the same frame.** So
  the bar asserts a property the specification does not have, and the GPU was clearing it
  by being too weak to rim. À-trous bands carry edges; that is what they are.
- `testNegativeTextureSmoothsTextureMoreThanEdges`: the coherence gate moved the edge by
  0.0426 and the texture by 0.0136. The reference on the same frame moves the edge by
  **0.00000** and the texture by 0.00207 — its gate closes completely at an edge. So the
  GPU's coherence is not closing, and that test was passing only because the guided base
  left nothing at the edge for the gate to fail on.

So there are three defects here, not one, and they were hiding each other: Texture is
2–6× weak, the reference's positive Texture rims at 1.4 EV, and the GPU's coherence gate
does not close at edges. Fixing the first alone makes the picture worse, which is why the
port was reverted rather than shipped. The shape of the real fix is an edge-aware band
that still carries the à-trous window's content and scale honesty — guided smooths in
place of the à-trous ones, or an explicit edge gate on positive Texture as well as
negative — and it has to change the reference and the GPU together.

#### The rim, fixed: the second defect

Positive Texture had no gate at all, on either path — `applyTexture` read
`a >= 0 ? 1.0 : (1 − coherence)` and the render graph passed `gate = nil` and called the
ungated kernel. The band it gains still contains the edge, so the gain rims it. Measured
on the presence golden's own clean 3 EV step:

```
              rim (EV)   authority on flat texture
  +25          0.4291                     0.000524
  +50          0.7478                     0.001050
  +100         1.3852                     0.002111    bar: 0.30
```

It is over the bar at every setting, +25 included.

The gate cannot simply mirror the negative one. `1 − coherence` at full depth would also
flatten hair, fabric weave and foliage, which are the subjects positive Texture exists
for. Coherence separates them cleanly enough to gate on — measured across three frames,
fine parallel lines sit at **0.19**, a smooth ramp at **0.00**, and a hard step at
**1.00** — so the positive gate is `1 − smoothstep(0.35, 0.85, coherence)`: fully open
below the fine-detail end, fully closed on a genuine edge.

```
              rim (EV)   authority on flat texture
  +25          0.1495                     0.000524
  +50          0.1886                     0.001050
  +100         0.2668                     0.002111    bar: 0.30
```

Under the bar at every setting, and the authority column is **bit-identical** — the gate
costs nothing where it is open, which on this frame is everywhere except the step.

The residual 0.2668 EV does not move when the thresholds move: on this frame coherence
is binary, so threshold placement cannot explain it. It is the structure tensor's support
being narrower than the band's — the tensor is smoothed at `workingRadius / 4` = 1 px
while the band reaches several — so the band carries edge energy into pixels the gate
correctly calls flat. Closing that means dilating the gate to the band's reach, which is
another Metal pass; the gate above is two lines on a plane the GPU already samples. The
cheap 5.2× came first on purpose.

#### The strength: attempted, measured, reverted again

With the rim gated, the band port reverted in 4a58716 was put back and taken out a second
time. Recording it so the third attempt starts here rather than at the beginning.

**What the attempt proved.** Two of the three defects closed, and macOS CI confirmed both:
positive Texture reached **1.00× parity** with the reference (the assertion the port added
passed), and `testPresenceDoesNotRimAHardEdge` passed *with the à-trous band in place* —
which it could not do before the gate existed. The port's original red goldens were not
mistakes in the port.

**What it ran into.** `testNegativeTextureSmoothsTextureMoreThanEdges` went red at edge
0.04258 / texture 0.01364. That was not the gate. The golden hands `applyPresence` a
`longEdge` of 1600 with a 64 px frame, and `structureRadius` sizes the coherence window
off that number — 8, where the reference sizes it off the buffer and gets 1. The reference
inverts identically at the same width:

```
  window   texture     edge     ordering
  1        0.01764   0.00029    correct     <- what a 64 px buffer earns
  4        0.01744   0.00563    correct
  8        0.01679   0.04736    INVERTED
  GPU      0.01364   0.04258    INVERTED
```

Clamping the window to what the buffer earns fixed that golden — and broke the rim one, at
0.38 EV against the 0.30 bar. Widening the window fixes the rim and costs discrimination;
narrowing it fixes discrimination and costs the rim.

**The real shape of it.** The gate has two radii and the code has one. It is *measured* on
the structure tensor at a window proportional to the frame — that proportionality is what
tells a coherent edge from the texture beside it — and *applied* to an à-trous band that
reaches several pixels. A closure only as wide as the measurement leaves the band's edge
energy in pixels the tensor has already, correctly, called flat. That residue is the rim,
and no single radius satisfies both. Three ways of proving it:

```
  measurement window     1        2        3        4        6        8
  rim (EV, +100)       0.2668   0.1774   0.1327   0.1148   0.1108   0.1104
  discriminates?        yes      yes      yes      yes       NO       NO
```

The rim plateaus at 4 — the band's reach — and discrimination fails from 6. Flooring the
measurement at 4 satisfies both of those and gates small buffers flat: local Texture
stopped moving entirely on the 24×16 frame.

**Why dilation is not yet the answer either.** Decoupling the two radii — measure narrow,
dilate the closure to the band's reach — does work on its own terms, and by a wide margin:
rim 0.2668 → **0.1108**, authority on flat texture bit-identical, discrimination passing at
*both* narrow and wide measurement windows. It fails somewhere else. On a frame carrying a
strong smooth gradient — the local-adjust test's 8 EV ramp over 16 px — the tensor reads
coherence near 1 almost everywhere, the few open pixels get closed by the dilation, and
positive Texture dies completely (0.0 against a 1e-4 bar).

That last one is the finding worth keeping, because it is not about dilation. **The
positive gate is too aggressive on a strong smooth gradient.** A ramp is not an edge and a
photographer expects Texture to work on a sky, but `coherence` is ratio × strength and a
steep ramp scores high on both. The gate that shipped is safe only because it is narrow
enough not to reach the open pixels; widening it in any direction exposes the same thing.

So the next attempt is not "port the band again". It is: make the gate distinguish a
*gradient* from an *edge* — a ramp has consistent orientation and near-zero second
derivative where an edge does not — and only then decouple the two radii. Until that
holds, the band port trades quiet weakness for a dead slider on skies, which is worse.

What is left of the three: Texture is still 2–6× weak. The rim is fixed. The negative-side
window divergence is understood and fixed in the reverted work, and should be re-applied
with the next attempt rather than rediscovered.

### The sweep: every slider, measured

Clarity at 1/48 and Texture at 1/17 both sat behind green tests. That is not a
reassuring hit rate, so every remaining control was swept the same way — authority at
full travel, and whether each of twenty steps changes the render at all.

**86 controls measured. Two dead, both fixed.**

| Group | Controls | Result |
|---|---|---|
| Global colour | vibrance, saturation, density, skin protection, mixer uniformity | alive, monotone |
| Colour Mixer | 8 bands × hue/sat/lum = 24 | alive, monotone, 30–160 code values at full travel |
| B&W mix | 8 bands | alive, monotone |
| White balance | temperature, tint | alive, monotone |
| Grading wheels | 4 zones × sat/hue/lum, balance | alive, monotone |
| Colour balance grid | hue shift, vibrance, 3 axes × 4 zones | alive, monotone |
| Printer lights | master, R, G, B | alive, monotone |
| Primaries | 3 hues, 3 purities, tint hue/purity | alive, monotone |
| Presence | texture, clarity, dehaze | alive, monotone |
| Sharpen | amount, detail, masking, halo | alive, monotone |
| Vignette | | alive, monotone |
| Denoise | 7 ClassicNR sliders | alive |
| **Grading Blending** | | **dead from 80 to 100 — fixed** |
| **Sharpen Radius** | | **7-position switch across 0.5…3.0 — fixed** |

**Blending** clipped its crossfade half-width at `(highPivot − shadowPivot)/2` with a
hard `min`. On the default pivots that binds at 79.3, so every setting from 80 up
rendered byte-identical. The ceiling is real — past it the mid zone's weight goes
negative — so the request is eased onto it with the same knee the tone engine and the
parametric curve use.

**Sharpen Radius** was worse: `SpatialOps.gaussianBlur` is a three-box approximation
with integer widths, so thirteen of twenty settings across the whole range rendered
byte-identical. It is also a GPU/reference disagreement no golden could catch, because
`CIGaussianBlur` is continuous in sigma while the reference stepped. Below sigma 8 the
reference now uses an exact separable Gaussian at 4σ support; boxes stay above it, where
a feather radius is tens of pixels and one integer step is under a percent.

### What the sweep found that is not a defect

- A grading wheel's **hue** reads as "no movement at full travel" because the control is
  circular: 0° and 360° are the same setting.
- **`color.density`** is inert when Saturation is negative. That is what a dye-density
  model means — but the panel shows the dial either way, so half its uses are a control
  that cannot do anything.
- **`denoise.hotPixels`** saturates by about 35: once every hot pixel is caught, more is
  more of nothing. On subtler spikes the threshold would still matter.

Two of the "dead" readings were **the probe's fault, not the code's**, and both are worth
recording because they are the same trap this document keeps finding in other people's
tests. `colorDetail` measured dead on a near-neutral frame — it scales the shrinkage
threshold where the *chroma* edge map is high, and a neutral frame has no chroma edges.
`hotPixels` measured dead on a frame with no hot pixels. Both came alive the moment the
frame contained what the control acts on.

### Denoise behaviour, quantified

The sliders are wired. What they do is a separate question, and the numbers are not
flattering. RMS error against the clean frame, ISO 6400, hot-pixel sites and the edge
excluded, plus what survives of a saturated colour edge (clean = 0.5200):

```
                  off      25      50      75     100    colour edge at 100
  Luminance     0.0180  0.0150  0.0145  0.0149  0.0154        0.5149
  Colour        0.0180  0.0097  0.0105  0.0115  0.0126        0.3364
  Colour Smooth 0.0091  0.0100  0.0109  0.0119  0.0129        0.3264
```

**Colour at 100 is worse than Colour at 25 on both axes** — more residual error and 35%
of a saturated colour edge gone. Luminance has a shallow optimum around 50 and gives
some of it back by 100. That is the "70 as wiring, not as behaviour" line above, with
numbers attached: the useful part of the Colour slider is roughly its first quarter, and
the rest is bleeding colour for no gain.

### The gaps in the sweep, closed

The 86-control sweep skipped five controls and mis-measured a sixth. All six are alive:

| Control | Full travel | Notes |
|---|---|---|
| Exposure | 194 code values | applied at S6, so the S7 sweep never saw it |
| Contrast pivot | 72 | |
| Grading zone pivots | 43 and 65 | |
| Mixer band core / feather arcs | 7–29 | 16 controls, 8 bands × 2 sides × 2 rings |
| Point Colour hue / sat / lum / range / variance | 63–150 | |
| Grading wheel hue | continuous | see below |

**A grading wheel's hue was never dead — the metric was wrong.** Hue is circular, so
"authority at ±full travel against a neutral" compares 0° with 360°, which are the same
setting, and reports no movement. Measured properly, every 10° step from 0 to 360 changes
the picture in all four zones and 360° renders exactly as 0°. That is a permanent test
now, run against `GradeEngine` directly rather than through a render — building a
`RenderPlan` per step bakes a 65³ cube and took 51 seconds for what now takes 0.049.

**Three "dead" readings in the first run were the probe's fault, not the code's**, and
they are the same mistake this document keeps recording in other people's tests: driving
a control past its own bounds. Point Colour Hue is a **±60° slider** — the panel's range
and the engine's `pointHueShiftLimit` agree exactly — and the probe pushed it to ±100.
The mixer's arc handles were pushed past `bandCoreMaxDegrees`. A control that saturates
outside its own slider is not a dead control.

What is left is one genuine saturation, and it is deliberate: a band's **feather** is
inert over the bottom 5% of its travel, because `fb = max(fb, bandMinReachDegrees − cb)`
widens the feather to hold a minimum smooth reach. The comment on it says why — the core
is what the user drew and the feather is how it lets go — and a guaranteed smooth falloff
is worth more than 3° of one slider.

### Crop

Crop had **no test of any kind**: the arithmetic lived in `PipelineRenderer`, which is
`#if os(macOS)`. Two defects, both fixed, both now tested from Linux.

**Straighten exposed the empty corners.** `applyGeometry` took the crop as a fraction of
`out.extent.applying(orientation)` — the axis-aligned *bounding box* of the rotated
frame, which is 12% larger in area than a 3:2 picture at 5°. So the default crop of the
whole frame on any straightened photograph included all four of the triangular wedges
rotation leaves behind, and nothing in the repository computed an inscribed rectangle to
save it. The frame a crop is a fraction of is now the largest rectangle that fits inside
the rotated picture, so any crop is inside the picture by construction at every angle.

**The aspect lock did not survive a drag.** Pick 3:2, drag a corner, and the crop
silently became free-form — after which the menu read the rectangle back and reported
"Custom". There were also only four handles, so "a little off the top" meant dragging a
corner and then fixing the width it had also changed. Eight handles now, and the lock
holds through the drag, the clamp and the floor — clamping the offending edge on its own
is exactly how a lock becomes "Custom" the moment it touches the frame.

### Export

Sizing is correct and now pinned: across three sensor shapes, three straighten angles,
three crops and all six resize modes, the rendered size matches the size the sheet
promises to within a pixel. `export()` does not resize to `targetSize` — it crops, asks
for the dimensions, then hands the renderer the long edge of that answer — and nothing
had checked that those two agree.

**Copyright and contact were never written.** Both have a text field in the export sheet
and a slot in `MetadataPolicy`, and nothing read them: a photographer who typed a
copyright line got a file with no copyright in it. Copyright now goes to TIFF Copyright
and IPTC CopyrightNotice, contact to IPTC Contact, and both are written *after* the
metadata drops rather than before — an export with EXIF off drops the whole TIFF
dictionary, so writing first would have put the copyright in the bathwater.

## Phase 3 — the daily workflow

- **Save a look.** Not a preset browser of other people's presets — the owner's own
  looks, stored in the catalog, applied to any photo in any folder.
- **LUT import.** The `.cube` parser exists and is tested; it needs an importer, a
  stage that reads `look.lut`, and a place in the panel. DaVinci exports would load.
- **UI truncation.** The histogram readout tabs overlap; sweep the panel for the rest.

## What this document does not do

It does not score anything. Doc 18's scores were claims about features; the five audits
replaced them with measurements, and those live in the audit records rather than here.
The only number that matters for this plan is whether the owner wants to keep using the
app after an hour with it.
