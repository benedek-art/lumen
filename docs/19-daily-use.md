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

### Texture

The same measurement, run on the stage beside Clarity: **1.8× to 17× under the
reference**, at Texture ±40, on seven frames.

Two causes, both structural. The band came off a single edge-preserving guided base,
whose threshold is 0.1 EV — so it keeps 86% of any texture whose local excursion exceeds
a tenth of a stop, which is essentially all real texture, and Texture acted on the
residue. And the coefficient was `amount × 0.9`, where `DetailEngine.applyTexture`
normalizes its window to `referenceBandWeight(halfWidth: 1.6)` = 1.617.

The GPU now builds the reference's own band: `Σ wℓ · (sℓ − sℓ₊₁)` over the à-trous
stack, with the raised-cosine window `bandCenter` places for the resolution. Positive
Texture measures **1.00× the reference on every frame tested** — an exact match, not an
approximation. Negative Texture, which is gated by local structure, measures 0.94–1.00×
above 256 px; below that the GPU floors the coherence window at radius 2 where the
reference floors at 1, which is a deliberate departure documented at `structureRadius`.

That window is also what makes Texture scale-honest — `bandCenter` is
`1 + clamp(log2(longEdge / 2560), −1, 2)`, so the same setting means the same amount of
texture in a fit view and in a 61 MP export. One fixed radius cannot do that, and the
guided base was one fixed radius.

Only the smooths a non-zero weight reads are built: three à-trous passes at the default
centre, five at the largest.

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
