# Findings discovered during the fix pass

The seven-domain audit produced 257 findings. These were found afterwards, while fixing
them — by agents substituting defects back to prove their own tests could fail, and by
the integrator merging. They are recorded here rather than folded into the domain files,
because how a defect was found is evidence about where to look for the next one.

---

**TEST-01 — `Swift.max` swallows a NaN, so about ten running maxima in the suite would
pass on a render that had gone entirely non-finite.** FIXED, and watched failing first.

Found by the colour/tone agent while proving one of its own new tests could fail:
removing a clamp produced NaN and the test **still passed**.

Verified empirically rather than argued from the standard library's source:

```
max(running, nan) = 3.0      <- the shape every accumulator in the suite uses
max(nan, running) = nan      <- the other order
```

`Swift.max(_:_:)` returns `y >= x ? y : x`, and every comparison against NaN is false, so
`max(accumulator, measured)` returns the accumulator untouched whenever `measured` is
NaN. A running maximum therefore steps silently over every non-finite pixel in a frame,
and the bound assertion it feeds then passes on a render that produced nothing but NaN.

Sites of that exact shape, at the time of writing: `RobustnessTests.swift` 357, 641, 679,
1251, 1553, 1680, 1844, 1856, 1897; `MaskingTests.swift` 96, 98;
`GeometryAndOutputTests.swift` 321, 322; `EngineIntegrationTests.swift` 82. Clamps of the
form `Swift.max(x, 0)` are a different case — they also absorb a NaN, but they are floors
rather than accumulators and their result is not what the assertion reads.

**Fixed with the first of the two options below**, not the preferred second, and the
reason is the sentence above about what the assertion reads. `assertEveryPixelFinite`
would add a new check beside every listed site and leave all of them still blind;
`runningMax`/`runningMin` in `Tests/LumenCoreTests/RunningExtremes.swift` make the
assertion that is already written the one that catches it. Eighteen sites, the ledger's
list plus the `lo` partner of a span and the `plateau` a trench is measured against.

**Two things the fix found that this entry did not predict.**

A running maximum was not the only swallower at its own site. `trench > 0 ? … : 0` at
`RobustnessTests.swift:1862` is the same shape wearing a different hat — a NaN fails
`> 0`, takes the else branch, and reports a trench of exactly zero — and so is the `where
exact[ch] >= cut && tabled[ch] >= cut` at :640, which skips a non-finite channel and
would report a colour-grade table that had gone entirely NaN as converging perfectly.
Fixing the maxima alone left one of those tests green on a render that was one-eighth NaN.

And the proof itself. Removing the zero-trace guard from `DetailEngine.structureTensor`
(`trace > 1e-12 ? Num.saturate(disc / trace) : 0`, a real division by zero on any flat
neighbourhood) makes `applyTexture` return **1024 non-finite pixels of 8192** on a frame
`testPositiveTextureDoesNotRimAHardEdge` already renders. Original test code: PASSED.
Fixed test code: FAILED, "dug a nan EV trench on the dark side of a clean edge". That is
the before-and-after nobody took when these were written.

**Why this was not urgent, kept because the reasoning still holds.** The primary failure
mode — a stage starts producing NaN — is already covered directly:
`testRenderSurvivesAPoisonedPixel`, `testTablesSurviveNonFiniteInput`, and the per-pixel
`isFinite` sweep in `testTheWholePipelineWithEveryStageOnProducesASanePicture`. What the
accumulators lost was the *second* line of defence, for a NaN arriving under a recipe
those tests do not exercise. Worth recording alongside it: the shipping render path is
hard to poison from the outside — a source pixel of `(nan, inf, -inf)` renders to
`(0, 0, 0)` under both a tone recipe and a broad one, because the cube stages map a
non-finite coordinate to index 0. The NaN this fix catches has to come from inside a
stage, which is exactly where the substitution above put it.

**The general lesson, which is the reason this file exists.** This is a check that cannot
fail, hiding inside the checks. The audit spent a day finding that shape in the product;
it lives in the test suite too, and the only reason it surfaced is that an agent was
required to watch its own new test go red before believing it.

---

**CAT-01 — `SQLITE_OPEN_CREATE` makes "is this file a healthy catalog?" answerable YES for
a file that does not exist.** BROKEN (found and fixed in the same pass).

Found by the library/output agent re-reading its own diff for LIB-04, not by a failing
test.

`SQLiteDatabase.init` opens with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`. So probing
a path that is not there does not fail — it creates an empty database, and an empty
database passes `PRAGMA quick_check` perfectly. The new open-time restore lists the backup
directory and then probes each name in turn, so a backup removed between the listing and
the probe would have been *recreated empty*, passed, and restored over a catalog that was
only damaged. Guarded with one `fileExists` in `CatalogStore.probeQuickCheck`, and pinned
by two assertions in `testAFirstRunHasNothingToCheckAndSaysSo` — the second of which
asserts the probe left no file behind, because without the guard it does.

**The general shape, which is what makes it worth recording.** Any predicate of the form
"can this file be used" that reaches SQLite through this `init` inherits a *creation* side
effect. Every present and future caller of `SQLiteDatabase(path:)` that is asking a
question rather than opening a store has the same hazard. The narrower fix would be an
open flag; the reason it was not taken here is that no existing caller wants read-only
semantics, and adding a parameter used by one call site is a worse trade than one guard
at the call site that needs it. If a second such probe appears, that trade flips.

---

**DOC-01 — BUILDING.md understates the library, in the direction nobody checks.** FAKE
(inverted: a limitation that has been lifted and is still listed).

Found while fixing LIB-10, which only bites if the SQL query path is live.

The known-limitations list says "`PhotoQuery`, the FTS index and the fourteen chip indices
are built and unused, because `FilterBar` filters in memory". `AppState.swift:1034` calls
`catalog.photos(matching:)` and `FilterBar` branches on `isLibraryQueryLive` in four
places, so the SQL path ships. Not fixed here because it belongs with whoever owns the
library-query work and can say what else moved with it.

Worth its own entry because every other finding in this pass runs the other way — a claim
that overstates what ships. **A stale limitation is the same defect with the sign flipped,
and it is harder to catch**: nobody re-reads a list of things that do not work looking for
one that now does, and the cost is a future agent budgeting to build something twice.

---

**TEST-02 — `PhotoMetadata.parseEXIFDate` and `parseEXIFOffset` have no tests of any
kind.** UNPROVEN.

Found while adding `parseEXIFSubsec` between them for LIB-26b.

All three are pure, `public static`, in LumenCore, and run on Linux — the file's own
header says the reason they live there is that `CaptureMetadataReader` "would need a file
to exercise". Two of the three have never been exercised at all. `parseEXIFDate` carries
the whole capture-time sort: it hand-parses `2026:08:20 14:55:35`, pins the calendar to
UTC, applies the camera's stated offset, and range-checks six fields — including a leap
second at `(0...61)`. A sign error on the offset moves every photo from a trip by hours
and the library sorts confidently wrong. Cheap to close: a dozen assertions, no fixtures,
no platform.

---

**GEO-17 — the CPU fallback preview applies no geometry, and the fix is not the one-liner
the audit costed.** BROKEN, disclosed rather than fixed. Recorded here because the
*reason* is reusable.

`PipelineRenderer.renderReference` goes decode → denoise → `ReferenceRenderer.render` →
`cgImage`, and never calls `applyGeometry`. So whenever the core kernels are missing the
preview shows the whole frame: no crop, no straighten, no flip. Everything else about it
is correct, which is what makes it dangerous — it reads as a good render of a photograph
the user did not compose.

The audit called this "one line — `applyGeometry` is stock Core Image". It is not.
`applyGeometry` takes a `CIImage`; this path holds an `ImageBuffer`. Geometry must stay
LAST (applying it before the stages would move every source-normalized mask), so the
bridge has to run on the rendered buffer — and that bridge crosses the row-order
convention `KernelGoldenTests` documents at length: Core Image extents are bottom-up, the
UI hands down a top-down fraction, and `CIImage(bitmapData:)` is a third convention again.
Its own words: a probe with the flip missing "returns a perfectly plausible colour, just
the one mirrored about the centre line".

Nothing on this path compiles on the machine the fix would be written on. Writing it blind
trades a wrongly-framed preview for a possibly upside-down one, which is a worse trade —
so the note the user sees now names the missing crop, straighten and flip, and the fix
waits for a Mac and one golden.

**The general point, which is the reusable part.** An audit estimate of "one line" is a
claim about a fix, and claims get checked exactly like the findings do. Three estimates in
this pass came in wrong in both directions: `quick_sig` was costed at 80–110 lines and
needed ~240 (the extra being a size probe so a first folder open hashes nothing at all),
FILM-08's magnitude was overstated by an order of magnitude, and this one was understated
because the estimator saw a call site and not a coordinate system.

---

**PROOF-01 — two mixer controls are not monotone over their travel.** MEASURED, and the
metric was the thing that needed fixing. Neither is a defect in `ColorEngine`.

The 46-control sweep found `mixer.magenta.sat` and `mixer.red.hue` change direction
somewhere in their travel. Both are still recorded with `isMonotone: false`, because that
is a true statement about the measurement; what has changed is that the record now also
carries `givenBack` — how much of its own effect a control hands back, in code values —
and the suite asserts a ceiling on that number for all 46 controls, the mixer included.

**`mixer.magenta.sat` is the ruler, not the control.** On chart patch 17 the post-mixer
lightness and hue hold at 0.58292 and 344.248° at every one of the 21 settings while
chroma steps linearly 0 → 0.29101; the band weights are `[0,0,0,0,0,0,0,1]` with the
chroma gate at 1.0, so the patch sits dead centre in magenta and (c) — a patch near a band
boundary — is ruled out by measurement rather than by argument. `RenderPlan.exactColor`,
which evaluates the same recipe without the tables, is monotone at all 21 steps in the
channel that carries the peak. Only the 65³ colour-grade table reverses, and its error
there converges away with table size, which is what makes it interpolation:

```
mixer magenta sat +90, patch 17 green, scene-linear
  exact  0.031798    33³  −0.000779    65³  0.002685    129³  0.030754
```

4.84 code values of table error at 65³, against a reversal of 0.46 in a travel of 85.81.
The sweep runs at 65³ because docs/18 measured that 33³ contributes 0.197 stops of its
own; the table is right for the job and its residual error is simply larger than 1e-9.

**`mixer.red.hue` reverses with the tables removed too, and the recorded hypothesis was
wrong.** Red's feather does straddle the wrap point — its arc runs 351.73°…66.73° — but
band membership is evaluated on the STAGE INPUT hue, which no slider moves, and patch 15's
weights are `[1,0,0,0,0,0,0,0]` at every setting. Nothing crosses a boundary. What is
actually happening is that the engine is exactly monotone in the axis it moves (L 0.50023
and C 0.15267 held, hue stepping 4.5° per 10 units — the 45° at ±100 that
`hueRangeDegrees` promises) while the patch's BLUE channel is driven through zero:

```
mixer red hue, patch 15 blue, scene-linear after the mixer
  +40  0.01238     +60  0.00073     +80  −0.00784     +100  −0.01379
```

Past that crossing the colour is outside the gamut and picture formation, not the mixer,
decides what blue is rendered; the rendered value flattens at ~24 code values and drifts
back up by 0.95. The peak CHORD from one end of a curve is not a monotone function of the
angle. This is docs/20 P4's circular-control clause arriving at the mixer: an angular
control measured by a straight-line distance will reverse, and the answer is a different
metric, not an exemption.

**What the assertion is now.** `givenBack < 5% of authority`, on every control. The two
above are the only ones in the registry that give anything back at all — 0.53% and 0.88%
— and the other forty-four give back exactly zero, so the ceiling sits six times over the
worst reading and an order of magnitude under anything a photographer could see. The
shape it exists to catch is DETAIL-14's: a slider whose top half undoes part of its bottom
half. Verified able to fail.

**The general point, and it is the reusable one.** The boolean was measuring the ruler as
well as the thing, at a tolerance six orders of magnitude finer than the ruler's own
error, and nothing in its name said so. Two of the three candidate explanations for a
finding like this — a defect in the code, or a defect in the probe — were the ones on
file; the one that turned out to be right for `magenta.sat` was neither, and it was only
separable because `RenderPlan.exactColor` exists to be measured against. A metric that
cannot be compared with an exact evaluation of the same thing cannot tell its own error
from the code's.

**PROOF-02 — overshoot, now measured on the seven controls that can produce it, and
split by direction.** MEASURED. (Six was a miscount; the list below has always had seven.)
`detail.dehaze` is the fix working; the metric was reporting two different facts as one
number, and no longer does.

In sRGB code values beyond the input's own range, at full travel:

```
detail.dehaze    51.14      sharpen.amount   41.51
detail.texture   19.67      sharpen.radius    6.40
detail.clarity    4.29      sharpen.detail    0.99
                            sharpen.masking   0.00
```

Three readings that mean different things, and the distinction matters more than the
numbers. `sharpen.amount`'s overshoot EQUALS its authority, because on a step edge the
halo IS the sharpening — an unsharp mask that did not overshoot would not be doing
anything. `sharpen.masking` at exactly 0.00 is a gate behaving like a gate. And
`detail.texture` at 19.67 with `detail.clarity` at 4.29 is the rim the panel used to deny
and now discloses (DETAIL-04), on a shipping path that runs a guided band where the
halo-free property belongs to a local Laplacian that does not ship.

**`detail.dehaze` at 51.14 is not an overshoot.** Every code value of it is BELOW the
veiled frame's own darkest value, and none of it is above the brightest. Measured on
`ProofFrames.hazySky`, whose neutral render spans 97.80…204.18:

```
amount   above scene white   below the floor   worst excursion   at code 255
  +25         0.0000%             1.98%             10.91            0.000%
  +50         0.0000%             6.92%             23.04            0.000%
  +75         0.0000%            17.93%             36.37            0.000%
 +100         0.0000%            33.51%             51.14            0.000%
```

docs/19 recorded the earlier dehaze putting a tenth of a test frame above scene white at
+50 and nearly half at +100. That is the number in the first column, and it is zero at
every setting. Nothing clips either: the darkest output sits at 46.66 of 255. The whole
51.14 is the black point coming back down, which is what removing a veil is.

**And it lands where a black-point restoration should.** At +100, 84.11% of GROUND pixels
sit below the veiled floor and **0.00%** of sky pixels do — the opposite of the failure
this was checked for, because the haze is thickest in the sky (the dark-channel
transmission runs 0.080 at the top row to 0.783 at the bottom) and the sky guard raises
the floor there. Negative travel produces no excursion in either direction at any setting.

**Against the reference implementation's floor**, which is the comparison that settles
whether the amplification is still capable of the docs/19 failure. He, Sun & Tang (CVPR
2009) invert with `t0 = 0.1`, a tenfold amplification of `(I − A)`, and the Lumen dehaze
docs/19 condemned used the same 0.1. The dark-channel map here is still floored at 0.02
and reaches 0.0803 on this frame, but that map is not what the inversion divides by: the
sky guard and `dehazeDistance` raise it to an effective `tv` of 0.5262…0.8061, so the
amplification actually applied is at most **1.90×**, and the structural floor
`tMin = mix(0.55, 0.05, 0.20) = 0.45` caps it at 2.22× anywhere. That is a fifth of the
paper's, and it is why the frame cannot be driven above its own white. The estimator also
under-reads the airlight on this frame — (0.4364, 0.5039, 0.6690) against the (0.55, 0.62,
0.78) the frame was built with — which makes the correction gentler, not harsher.
P6 tier (b): a published paper, and the delta is a design difference, not an error.

**No ceiling declared, and this is the reason.** On the metric as it stood, a ceiling on
`detail.dehaze` would have been a promise about how much of the black point the control is
allowed to restore — a bound on the control WORKING, which tightening later would be a bug
rather than an improvement. That is exactly the promise this file warns against. What is
worth binding is the above-white number, which is now recorded separately as
`overshootAbove` and measures 0.00 at both ends of the travel. **Recommended: an
`overshootCeiling` of 2.0 on `detail.dehaze`** — under the 2.9-of-255 level docs/19
established as the threshold of invisibility, so it is a promise a photographer would
notice being broken, with enough margin that retuning the sky guard does not turn the
suite red on an estimate. Not applied here: `ProofRegistry.swift` is owned by another
agent this round, and the change is one argument on one entry.

**The split, on all seven controls that can produce an excursion.** This is the table the
single number was hiding:

```
                  above    below
detail.texture    18.56    19.67
detail.clarity     4.29     3.61
detail.dehaze      0.00    51.14
sharpen.amount    41.51    29.48
sharpen.radius     6.40     4.48
sharpen.detail     0.13     0.99
sharpen.masking    0.00     0.00
```

Every rimming control has both lobes, because that is what a rim is. `detail.dehaze` — the
one whose single number was the largest on the list and the one that got investigated —
has only the lower one. Read as one number it was the worst offender; read as two it is
the only control in the registry that never pushes a pixel above the frame's own white.

**Why the other six are still unasserted.** Unchanged: they are measurements, and they
become promises when someone has decided what the right answer is. What the split adds is
that the decision is now askable for each separately — a maximum never said which lobe was
being bounded.

---

The entries below come from the sweep that added the Look panel to the registry — the
grading wheels, printer lights, primaries, Point Colour, the Zones panel, the B&W mix,
the film stocks and the two classical denoise masters. Sixty-five controls, measured the
same way the first forty-six were.

**PROOF-03 — all three Primaries purity sliders spend their positive half against a
clamp, and Red spends all of it there.** BROKEN, recorded rather than fixed.

Measured on `tonalColourWedge`, ±100, which is the panel's range and the engine's:

```
primaries.rPurity   authority 77.96   front-loading 100.0%   1 dead step
primaries.gPurity   authority 63.35   front-loading  96.2%   0 dead steps
primaries.bPurity   authority 114.68  front-loading  92.4%   0 dead steps
```

Front-loading is the share of the total effect delivered by the first half of the travel.
At 100.0% the positive half of Red purity delivers **nothing at all**: the render at +10
and the render at +100 are the same distance from the render at −100, and one adjacent
pair is byte-identical.

The cause is in `ColorEngine.safeChromaticity`, and it is arithmetic rather than a bug in
the ordinary sense. Purity rescales a primary's distance from the white point by
`1 + purity/100 × 0.5`, and the result has to stay somewhere a matrix can be built from —
`y > 0.002`, `x > 0.001`, `x + y < 0.999`. **Rec.2020's red primary is (0.708, 0.292), so
x + y is exactly 1.000**: it is already outside that test before the slider is touched, and
every outward push bisects straight back to the boundary. Green has a little headroom
(x + y = 0.967) and blue runs into the `y > 0.002` limit at about +31 instead. Each of the
three saturates; red saturates immediately.

The function's own header calls this out — "Purity at ±100 can push a primary off the
chromaticity plane entirely (Rec.2020's blue leaves y > 0 well before the slider ends)" —
so the shrinkage is deliberate. What nobody had measured is that the shrinkage eats *half
a slider*, and that a photographer dragging Red purity from 0 to +100 is dragging a
control that stopped responding at +10.

Not fixed here, and the reason is that the fix is a design decision rather than a repair:
the honest options are to re-scale the slider so its positive half maps onto the headroom
that actually exists (different for each primary), to let the working space be a bigger
one before the remap, or to disclose the limit in the panel. All three change what saved
recipes mean. `primaries.rPurity` declares its plateau in the registry — the first control
to use `ControlSpec.declaredPlateauSteps` — so the sweep records it as a known one step
rather than failing, and the day it becomes zero the test goes red and somebody has to say
which fix landed.

**PROOF-04 — the Zones panel's dark end is below the visible threshold.** UNPROVEN,
recorded with its number.

```
zones.dark.ev     authority  4.74 over ±3 EV      zones.pivot.0   authority 10.47
zones.shadow.ev   authority 37.76                 zones.pivot.1   authority 95.05
zones.mid.ev      authority 177.01                zones.pivot.2   authority 161.94
zones.light.ev    authority 201.71                zones.pivot.3   authority 86.71
zones.bright.ev   authority 58.17                 zones.pivot.4   authority 114.93
zones.global.ev   authority 215.25
```

Dark moves the picture by 4.74 of 255 levels across its whole travel — six stops of
exposure, from −3 to +3. docs/19 called Blacks a control the photographer cannot see at
2.9, and this is 1.6× that.

**This is not the probe.** The frame is `neutralRamp`, which docs/20 names for tone and
which spans −8…+5 EV; the travel is the panel's own −3…+3 rather than the ±5 a drag can
reach; the control needs no companion. The cause is where the zone SITS: `Zones.defaultPivots`
puts Dark at 0.08 on the normalized tonal axis, which between the −9 and +5 EV anchors is
−7.88 EV, and an 8-bit display has about two code values left down there. A six-stop lift
of something that renders as black renders as black.

So the finding is not that the multiply is wrong. It is that **the Zones panel ships six
sliders of which one cannot be seen**, and the lever is the default pivot rather than the
gain. `zones.pivot.0` at 10.47 is the same fact from the other side: the boundary of an
invisible region is nearly invisible too.

Worth adding, because it is the kind of thing that reads as damning and is not: Bright
delivers 99.8% of its authority in its NEGATIVE half. Its pivot sits at +3.88 EV, so
raising it pushes tones that are already at display white further above it and the
rendering clips them back. A highlight zone whose positive half is a shoulder is arguably
the shoulder working. It is recorded because the number should be somebody's decision and
not a surprise.

**PROOF-05 — two INVALID PROBEs I caught in my own sweep, both from the frame being too
SMALL rather than from containing the wrong thing.** Probe errors, recorded because the
class is new.

This repository has now recorded five instances of a control measured on the wrong frame,
and every previous one was about CONTENT: `colorDetail` on a neutral frame, `hotPixels` on
a frame with no hot pixels, Sharpen Masking on a field with nothing to withhold from. These
two are about RESOLUTION, and they are the first of their kind here.

```
film.halation    on stepEdge (128 px)     authority  4.31   — sub-pixel blur
film.grain.size  on neutralRamp (256 px)  authority  0.00   — 20 dead steps of 20
```

Both stages are denominated in **microns at the film gate**, not in pixels. Halation's
first bounce is 65 µm on a 36 mm gate, which is `0.065 / 36 × longEdge` pixels — a σ of
0.23 px at 128, so no light crosses the edge the control is being measured at. Grain's
plate cell is a pitch on the print times the render's pixels per print millimetre, floored
at half a pixel so a cell can never be finer than the sampling grid; on a 256-pixel ramp
that product is 0.04 to 0.17 across the whole of Grain Size, so every setting lands on the
floor and all twenty-one renders come out byte-identical.

Read without the arithmetic, `authority 0.00, 20 dead steps` is the strongest possible
statement that a control is inert — stronger than anything docs/19 recorded. It was wrong.
`ProofFrames.wideStepEdge` (2048 px) and `ProofFrames.grainField` (4096 px) are sized from
that arithmetic, and `testTheFilmGateFramesAreBigEnoughForTheirKernels` restates it so the
frames cannot quietly shrink back under their kernels.

**The general lesson, which is why this is an entry and not a footnote.** docs/20 said "the
smallest synthetic frame that contains what it acts on" and everyone, including me, read
"contains" as being about content. For any stage whose kernel is denominated in a physical
unit — a film gate, a sensor pitch, a print size — a frame can fail to contain the control's
subject by being too coarse to resolve it. The frame table now says so.

**PROOF-06 — Grain Size is inert below about 1500 pixels of long edge, and half-clamped at
preview resolution.** BROKEN, recorded rather than fixed.

The arithmetic that made PROOF-05 a probe error says something real about the shipping
path once it is pointed at real render sizes. `FilmGrainProfile.plateScale` is
`pitch_on_print_mm × pixels_per_print_mm`, floored at 0.5 so a plate cell cannot be finer
than the sampling grid. For Portra 400 at the default 10-inch print that is
`0.000333 × size × longEdge` pixels:

```
long edge   Grain Size 0.5    Grain Size 1.0    Grain Size 2.0
   256          0.04              0.09              0.17        all floored
  2048          0.34              0.68              1.37        bottom floored
  6000          1.00              2.00              4.00        none floored
```

So on an export the slider works across its whole travel. At a preview long edge around
two thousand pixels its lower half is against the floor, and below about fifteen hundred
the whole control is. The photographer drags Grain Size, sees the coarse half respond and
the fine half do nothing, and the file they export behaves differently from the screen
they set it on.

docs/20 P5 names this exact shape as a defect in its own right — "a per-pixel edge gate
that keeps 17.8% of a delta at preview scale and a different fraction at export scale has
passed a same-scale comparison and still lies to the user about what they are judging".
The floor itself is correct and necessary; what is missing is any acknowledgement that it
swallows a control at the sizes people edit at. The candidate fixes are to sample the
plate with a proper reconstruction below one cell rather than clamping, or to say so in
the panel. Both are somebody's decision, not a repair.

**PROOF-07 — fifteen of the sixty-five new controls are not monotone, and twelve of them
have an explanation.** Recorded, not asserted, on the same terms as PROOF-01.

```
grade.global.hue     grade.mid.hue      grade.high.hue     grade.shadows.hue
primaries.rHue       primaries.bHue     pointColor.hue
primaries.rPurity    primaries.gPurity  primaries.bPurity
zones.pivot.2        zones.pivot.3      grade.blending
pointColor.range     film.grain.size
```

The four grading hue wheels are non-monotone BY CONSTRUCTION: cumulative separation on a
circle rises to the antipode and falls back to zero, which is what a closed travel looks
like and is why `isCircular` exists. The three hue rotations can carry a colour across the
wrap point, which is PROOF-01's hypothesis about `mixer.red.hue` appearing three more
times. The three purities are PROOF-03's clamp. `film.grain.size` is stochastic — a
different plate scale is a different noise realization, not a further step in one
direction.

That leaves three without an account: `grade.blending`, `pointColor.range` and the two
middle zone pivots. All four are controls that move a BOUNDARY rather than a magnitude, so
a peak-separation metric wandering as the boundary sweeps past different content is at
least plausible. Plausible is not established, and none of them is asserted against until
somebody has decided what monotonicity should mean for a control whose job is to move a
line rather than to push in a direction.


---

**UX-23 — the EXIF backfill occupies the catalog's only serial queue for the length of a
folder, and eight decode workers block cooperative threads behind it.** FIXED, read from
source, never measured.

Found while tracing what blocks the input path during a slider drag. `backfillMetadata`
ran its whole paged loop inside one `queue.async` block: `photosMissingMetadata`, a
`CaptureMetadataReader.read` (file open plus EXIF parse) per row, `setMetadata`, then a
`QuickSignature.compute` (one megabyte read plus hash) per row, five thousand of each,
without ever yielding the queue. Everything the user can feel goes through that queue —
`saveRecipe` behind every slider event, `previewState` in front of every thumbnail, every
grid query — so for the duration of a cold scan all three were stopped.

The compounding half is `previewState`, which the preview cache's own author flagged as
the thing to measure first: it was a `queue.sync` called from `Task.detached` decode
workers, of which there are eight. The cooperative pool is about as wide as the machine
has cores, and a blocked cooperative thread cannot run another task's continuation — so
with the pool parked inside `queue.sync`, the render actor gets no turn and every `await`
in the viewer's refine driver stops resuming. The main actor is a separate executor, so
the interface keeps moving while the picture does not. That is the reported shape:
"everything is super unresponsive… the image isn't really updating very well".

Fixed by driving the backfill from a separate `maintenance` queue with the file work on
its own thread and only the statements inside `queue.sync`, and by making `previewState`
`async` through the existing `onQueue` continuation so its callers suspend rather than
block. Neither changes what is computed. Neither has a test, and cannot in this
repository: `Sources/LumenApp` has no test target (UX-01). What would settle it is a
signpost around one backfill chunk and around `previewState`, on a Mac.

---

**UX-24 — the render coalescer claims its ticket on entry to a serial actor, so it can
never drop a backlog.** FIXED, read from source, never measured.

`RenderCoordinator.render` does `latestGeneration = max(latestGeneration, generation)` and
then compares against it. The ticket is issued on the main actor but claimed when the
request ENTERS the actor, and the actor is serial with a synchronous `renderPreview`
inside it — so requests queued behind an in-flight render have not raised the number, and
each raises it itself on arrival and compares as current. A drag delivers an event every
8–16 ms and a preview render costs tens of milliseconds, so the queue grew for the whole
gesture and every superseded frame was rendered in full, decode included.

The signal that drops it was already present and unread: the viewer drives renders from
`.task(id: RenderKey)`, which cancels the previous task the moment the id changes, so a
superseded request arrives already cancelled. `produce` checked staleness three times and
`Task.isCancelled` never. It does now, before the decode.

---

**UX-25 — every press on the loupe canvas toggled the zoom, and the draft pass drew the
photograph at half size above fit.** FIXED, read from source, never observed.

The owner reported "lots of zoom in, zoom out things that happen when I'm not pressed on
the image full screen". The search shape suggested — a scroll or magnify gesture reaching
the viewport — does not exist: there is no `MagnificationGesture`, no `MagnifyGesture` and
no scroll-wheel handling anywhere in the app, and `zoomLevel` has exactly one writer. Two
other things produce the symptom.

The press gesture asked only `travel < 3` on a `DragGesture(minimumDistance: 0)` attached
to the whole canvas, and its pan branch returns early whenever the frame does not overflow
the viewport — so at fit the gesture was a zoom toggle and nothing else. A press on the
letterbox surround, a click to bring the window forward, a press held while deciding, a
modifier-click: all of them jumped to 1:1 and the next dropped back. `ViewportClick` now
requires the release to land on the drawn photograph, to be under half a second, and to
carry no modifier.

The second is not a gesture at all and does not move `zoomLevel`. Above fit the frame is
drawn at `proxyPixels × ratio ÷ displayScale`; at fit the ratio is derived from the same
extent and the two cancel, above fit they do not. The viewer asks for a 4096 px settle and
the refine driver takes `max(1024, min(4096/2, 2048))` = 2048 for the draft, while
`renderPreview` scales the decode by `maxLongEdge ÷ native` identically for both — so the
draft's extent is exactly half and the photograph is drawn at half size until quality
lands. Every render, which during a drag is every mouse event. `DraftResolution` gives the
draft the settle's own long edge wherever the geometry can see the difference.

---

**UX-26 — a drag that loses its interior is harmless; a drag that loses its END is not,
and `onEnded` was throwing the end away.** FIXED, tests written and UNRUN.

Recorded because the theory it displaced was reasonable and wrong. Highlights, Whites and
Blacks were reported dead at 2, 11 and −7 on ±100 controls, and the offered reading was
that the interface had dropped most of the gesture. The drag is relative —
`dragStartValue + (location.x − startLocation.x) / width × span` — so the value is a pure
function of the pointer's current offset from the press, with no accumulator; AppKit's
event coalescing keeps the newest sample and discards the older ones, which is exactly the
one that survives. Dropping the interior of a gesture cannot shrink it. On the ~158-point
track the develop column affords, those three readings are 1.6, 8.7 and 5.5 points of
travel: small gestures, not lost ones.

What the slider did drop is the release. `onEnded` set `isDragging = false` and ignored
`value.location`, so the value a drag was worth depended on whether a motion event arrived
before the mouse-up — which is precisely the race a blocked main actor loses. The
arithmetic now lives in `SliderTrack` / `SliderDrag` in LumenCore with tests, and the
release resolves through it like any other sample.

---

**ENV-01 — the Swift toolchain was unavailable for most of this batch and appeared before
the end of it, so the four commits before this one understate their own verification.**

`scripts/install-linux-toolchain.sh` failed at the fetch — the agent proxy answers 403 to
CONNECT for `download.swift.org`, the release tarballs are not GitHub assets, and there
was no `swiftc` on the machine. Every commit in this batch was therefore written blind,
and each says so. A toolchain then appeared at `/opt/swift` partway through (Swift 6.1.2,
installed by something outside this session), and everything was run afterwards. The code
is unchanged by that; only what can be claimed about it is.

What the run says:

    swift test --filter LumenCoreTests --skip ControlProofTests
      641 tests, 0 failures, exit 0   (612 before this batch, plus the 29 added)
    swiftc -parse -swift-version 5 $(find Sources -name '*.swift')   exit 0
    scripts/check-swift-surface.py   exit 0
    scripts/gen-fixtures.py --check  exit 0

**Verified able to fail, four substitutions, each the SHIPPED defect put back:**

| Substituted | Result |
|---|---|
| `DraftResolution.draftLongEdge` returns `max(fit, min(settled/2, 2048))` — the viewer's own draft arithmetic | 5 of 8 `DraftResolutionTests` red, incl. "the frame changed size between the draft and the settle at 1.0/2.0/1.25/8.0" |
| `ViewportClick.togglesZoom` returns `press.travel < travelTolerance` — the one comparison the loupe shipped | 6 of 8 `ViewportClickTests` red |
| `SliderDrag.endedValue` ignores `travelled` and returns `resolve(start)` — the release the slider threw away | `testTheReleaseCarriesTheGestureToWhereThePointerActuallyIs` red at 0.0 against 100.0, plus two more |
| `SliderTrack.valueAtPress` ignores `x`; `thumbGrabRadius` set to 2 | `testAPressOnTheTrackLandsWhereItWasPressed` and `testGrabbingTheThumbIsWiderThanTheThumbIsDrawn` red |

A fifth substitution proved the new parse gate: an unbalanced brace in `LoupeView.swift`
returns exit 1 with `expected '}' in struct`. Reverted; the tree is byte-identical to the
state that exits 0 on all four gates.

**And one thing the surface checker cannot see, worth recording because a clean run from
it reads as more than it is.** Three probes were run against it. A misspelt static
reference (`LoupeView.draftLongEdgeXX`) was caught. A wrong argument label at a STATIC
call site (`SliderDrag.endedValue(track:from:travel:)`) was caught. The SAME wrong label
two lines away on an INSTANCE call — `geometryOfDrag.value(from:travel:)` against a
declared `value(from:travelled:)` — was NOT caught, and the run exited 0. Its header is
honest that it sees labels and not types; it is also blind to some labels on lowercase
receivers, and `swiftc -parse` does not see them either. Only a compile does.

---

## WB-01 — The temperature slider spends 73% of its travel on 4% of its effect

FIXED. The owner's first Mac session: *"Why does it go from 2,000 Kelvin to 50,000
Kelvin? Also, I don't think that anything even changes above like 15,000 Kelvin."*

Both halves are correct, and this is the measurement. A 0.18 neutral, adapting from a
5500 K as-shot, swept across the panel's own 2000–50000 K range; the quantity is the
path length the result traces through sRGB code values, which is what the eye is being
asked to notice.

| | code values travelled | share of a LINEAR track |
|---|---|---|
| 2000 → 15000 K | 241.59 | 27.1% |
| 15000 → 50000 K | **11.14** | **72.9%** |

By fifths of a linear track: **93.3 / 4.3 / 1.4 / 0.6 / 0.4 %**. The last fifth of the
Temp slider is 0.4% of the control.

The axis this should have been on has been named in this repo since before the slider
was written. `ColorTemperature.temperatureAndTint` searches in mireds and says why —
*"the axis that is perceptually even in Kelvin and the reason every camera UI steps in
mireds underneath"* — and `BasicPanel` carried a comment admitting the row above it was
linear *"until LumenSlider grows a scale transform"*. It has now grown one:
`SliderScale`, in LumenCore next to the rest of the drag arithmetic, where it is tested.

On the mired axis the same range spends its fifths **21.4 / 33.6 / 18.8 / 15.6 / 10.5 %**
— worst fifth within 3.2× of the best, against 233× before. The property that matters is
the match between the two tables: above 15000 K is now 9.7% of the track and carries
4.4% of the change, so travel buys change at roughly a constant rate. `SliderScaleTests`
asserts exactly that, and asserts the linear axis fails it, so the fix cannot be quietly
reverted.

The range is unchanged at 2000–50000 K. It matches the field and the documented spec;
what was wrong was never its width but where its travel went.

## WB-02 — The magenta half of the tint slider inverted the picture

FIXED, and this one is a genuine engine defect rather than a scale problem. The owner:
*"if I try to tint it blue, it goes from slightly blue to an entirely full blue visual,
so it's very bad."*

`ChromaticAdaptation.adapt` divides by the cone response of the illuminant it is adapting
*from*. Push tint far enough toward magenta and the chromaticity leaves the region any
light source occupies, the S (blue) cone response falls **through zero**, and the
adaptation matrix passes through a pole and comes out the far side with a negative blue
gain. Adapting a 0.18 neutral at 2750 K with tint +80, before the fix:

    RGB(-0.040, -3.101, 33.579)

Negative luminance, and a blue channel 186× the neutral it started from — not a magenta
cast, an inversion.

The pole sat **inside the range the slider could be dragged to**, and moved with
temperature:

| temperature | S cone crosses zero at tint |
|---|---|
| 2000 K | **+45** |
| 2750 K | **+80** |
| 5500 K | +185 |
| 10000 K | +275 |

So on any frame warmer than about 5000 K, the magenta half of the tint slider inverted
the photograph before a third of its travel — worst on exactly the tungsten and
candlelight frames where a magenta correction is most often wanted.

The guard is a floor on the cone response, `ColorTemperature.tintConeFloor = 0.15`,
which is really a ceiling on the blue gain of 1/0.15 ≈ 6.7×. A floor rather than a fixed
tint limit is the right shape because the bound then means the same thing at every
temperature and the admissible tint falls out of it: +36 at 2000 K, +87 at 3200 K, +128
at 4500 K, +156 at 5500 K. 0.15 is the largest floor that leaves the shipped ±150 range
untouched at and above 5500 K, so no daylight recipe anyone already has renders
differently.

The panel range is deliberately **not** narrowed to follow the bound. The bound moves
with temperature, so a contracting slider would either strand the readout above what the
render used or rewrite a tint the photographer had set — and losing his number while he
scrubs temperature past a warm value and back is worse than a slider whose last few
points are inert on a 2000 K frame. Past the bound the slider goes on moving and the
picture stops changing, which is an ordinary thing for a control to do.

**The number that matches his sentence.** A pole does not just reach a wrong value, it
JUMPS there — and the jump is between two settings the slider steps through one at a
time. Stepping tint by its own unit across every temperature a camera can report, the
largest single-step change in the adapted neutral was:

| | worst one-unit tint step |
|---|---|
| before the guard | **4212.58** (at 12000 K, tint +290) |
| after | **0.1477** |
| an ordinary step, 5500 K mid-range | 0.0012 |

One click of the slider was worth three and a half million ordinary clicks. "Slightly
blue to an entirely full blue" is a precise description of that. `TintGuardTests`
asserts the worst step stays under 0.5.

**What the guard does NOT do, stated so it is not read as more than it is.** It removes
the pole; it does not gamut-map. Two things remain true and are correct:

- A strongly magenta as-shot neutral adapted to daylight can still put one channel
  slightly negative (measured: −0.0039 on a 0.18 input, about 2%). That is a real
  out-of-gamut colour — more saturated than Rec.2020's green primary — not a failure,
  and the test asserts luminance and boundedness rather than claiming non-negativity.
- Driving BOTH ends to extremes (a 15000 K shade frame adapted to 2000 K with full
  magenta) still reaches −1.49 / +17.9. That is a huge but finite, monotone,
  continuous edit — the control doing what it was asked. Unguarded the same sweep
  reached −28.5 / +85.0.

The property that was broken was continuity, and that is the one now held.

**Reproduced independently.** These two findings were first measured on a branch that
was destroyed before it could be merged, and were re-derived from scratch here against a
Python mirror of `ColorSpaces.swift`. The 2750 K / +80 case came back bit-for-bit
identical — `RGB(-0.040, -3.101, 33.579)` — which is why the lost branch's other claims
are recorded rather than discarded. The temperature fifths differ slightly from what that
branch reported (89.6 / 6.7 / 2.1 / 1.0 / 0.6 against the 93.3 / 4.3 / 1.4 / 0.6 / 0.4
above); the numbers in this file are the ones this tree can reproduce, and the ones the
tests assert.

## WB-03 — Two claims from the lost branch that are NOT yet verified here

Recorded so they are not lost a second time. Neither has been re-derived, and neither
should be treated as established.

- **`minTint` / `maxTint` were declared with zero readers.** `maxTint` now has one
  (`tintLimit`'s fallback). `minTint` still has none.
- **The exposure proof measures 40% of the drag.** The panel is −5…+5 (hard −10…+10);
  `ProofRegistry`'s `tone.exposure` sweeps ±2, while every other tone control sweeps its
  full panel range. This looks like an oversight rather than a decision, but widening it
  re-pins a committed record and is left for its own change. It is a coverage gap, not a
  defect: ±5 EV is the same range Lightroom ships.

## PROOF-08 — Two controls were being proved over part of their own travel

The proof records are the answer to "does this control work", so a record that measures
less than the control is a claim about a slider the photographer does not have. Every
registry spec whose id maps to a panel slider was cross-referenced against that slider's
declared range. Fourteen could be compared automatically; three disagreed, all in Basic:

| spec | swept | panel | coverage | |
|---|---|---|---|---|
| `raw.temp` | 3000–9000 K | 2000–50000 K | 12% | **deliberate**, and documented in the spec |
| `raw.tint` | ±100 | ±150 | **67%** | undocumented |
| `tone.exposure` | ±2 | ±5 | **40%** | undocumented |

`raw.temp` is the one that is fine. Its spec explains that sweeping the declared range
would report a control delivering ~97% of its effect in the first fifteenth of its
travel — which is true, and is a fact about Kelvin rather than about the engine, so the
spec deliberately measures the photographic range and `SliderScaleTests` measures the
other half. That argument survives WB-01: the axis fix is in the slider, and this spec
was never measuring the slider.

The other two are now swept over their panel ranges. `raw.tint` at ±150 is entirely
admissible at the 5500 K neutral `RenderPlan` adapts from — the guard's bound there is
+156 — so it measures real travel throughout rather than running into a clamp.

Both re-pin their records. `.github/workflows/ci.yml` grew a `record_proofs` dispatch
input for exactly this: a manual run sets `LUMEN_RECORD_PROOFS` and uploads the rewritten
records as an artifact, so a deliberate change can be re-recorded without a Swift
toolchain in the tree. It is gated on `workflow_dispatch` and can never fire on a push,
because the drift test is the thing that makes an ACCIDENTAL change visible and a lane
that silently re-records is a lane that proves nothing.

**The remaining 29 specs could not be compared this way** — their ids are built in loops
(`grade.\(id).hue`, `zones.\(id).ev`, `mixer.\(band).\(axis)`) and their ranges come
from arrays rather than literals. Whether those match their panels is not established
here, and saying so is the point: this pass checked 14 of 43.

## A correction, recorded because it was stated before it was checked

While reading `ci.yml` I concluded that `swift test ... | tee proof.log` followed by
`status=$?` captured tee's exit code, and that the proof lane was therefore incapable of
failing. That is wrong. GitHub runs `shell: bash` as
`bash --noprofile --norc -eo pipefail {0}`, so pipefail is already set and the pipeline
carries the first non-zero status; `set +e` turns off errexit without touching it. The
refutation was already on screen — `engine-linux` reported three failures on run 178
through exactly this construct. Recorded here rather than quietly deleted, because "the
check cannot fail" is the most valuable kind of finding when true and the most misleading
when not, and the habit that produces it is the same one that produced the three refuted
theories in MAC-07.

## PROOF-09 — Thirteen shipping sliders have no proof record at all

This is the registry's own standard, not an imported one. Its header states the contract
in a sentence: *"a control absent from this file is a visible omission."* There is no
documented exclusion list, so absence is a gap by construction.

Cross-referencing every `LumenSlider` that names a binder key against the registry's spec
ids — after mapping the four sharpen aliases (`detail.sharpen.amount` is the panel's key
for the registry's `sharpen.amount`, and likewise radius/detail/masking) and the two
denoise ones (`denoise.classic.luma` ↔ `denoise.luma`, `.chroma` ↔ `denoise.chroma`) —
**17 of 31 keyed sliders had no spec, of which 13 survive the aliasing**:

| panel | slider | key | range |
|---|---|---|---|
| Basic | Density | `color.density` | 0…100 |
| Basic | Protect Skin | `color.protectSkin` | 0…100 |
| Detail | Radius (capture) | `detail.capture.radius` | 0.4…2.0 |
| Detail | Amount (capture) | `detail.capture.amount` | 0…150 |
| Detail | Halo Suppression | `detail.sharpen.haloSuppression` | 0…100 |
| Detail | Luminance Detail | `denoise.classic.lumaDetail` | 0…100 |
| Detail | Luminance Contrast | `denoise.classic.lumaContrast` | 0…100 |
| Detail | Colour Detail | `denoise.classic.colorDetail` | 0…100 |
| Detail | Colour Smoothness | `denoise.classic.colorSmoothness` | 0…100 |
| Detail | Hot Pixels | `denoise.classic.hotPixels` | 0…100 |
| Detail | Amount (AI denoise) | `denoise.amount` | 0…100 |
| Effects | Vignette Amount | `look.vignette` | −3.0…1.0 |
| Effects | Angle | `geometry.angle` | −45…45 |

Two of these are named in existing audit items as needing a GPU before they can be
proved (`geometry.angle` sits with GEO-16/GEO-17), and the capture-sharpening pair has
its own history in DETAIL-11. The other ten are not blocked on anything; they were simply
never registered.

Worth being exact about what this does and does not say. It does NOT say these controls
are broken — several are covered by ordinary tests elsewhere in the suite. It says they
have not been put through the six questions docs/20 asks of every control, so nobody can
say from the records whether they are alive across their travel, have visible authority,
are monotone, or hand back part of their own effect. That is the difference between
"nothing has reported this broken" and "this is proven to work", which is the whole
distinction the proof programme exists to hold.

Not fixed here. Adding thirteen specs means choosing a frame, an authority floor and a
shipping reader for each, and re-pinning thirteen records through the CI recording lane —
it is its own piece of work, and doing it badly would produce thirteen records that assert
nothing. Recorded as the largest remaining gap in the proof programme.

**The range audit itself is now complete**, which the previous entry could not say: all
46 registry specs were compared against the panels. Only three sweeps disagreed with
their panel's range (PROOF-08), and only three specs use non-literal bounds
(`printer.master`, `printer.\(id)`, `zones.pivot.\(index)`), which take theirs from the
engine's own limits and so cannot drift from the panel independently. The grading wheels
(`grade.\(id).hue/sat/lum`) have no panel `range:` to compare against because they are
wheels rather than sliders.

## PROOF-10 — The lane silently re-recorded instead of checking, for one full run

Self-inflicted, in the commit that added the recording input, and worth writing down at
length because the commit message for that change contains the exact warning it then
violated: *"a lane that silently re-records is a lane that proves nothing."*

The recording input was wired as a step-level environment variable:

```yaml
env:
  LUMEN_RECORD_PROOFS: ${{ inputs.record_proofs && '1' || '' }}
```

On a push `inputs.record_proofs` is null, so the expression yields the **empty string** —
and GitHub sets the variable anyway. `ControlProofTests.isRecording` asked
`environment["LUMEN_RECORD_PROOFS"] != nil`, and `Optional("")` is not nil. So every push
took the recording branch: the drift test wrote 111 records into the runner's checkout,
`continue`d past every comparison, and reported an empty drift list.

Two details made it invisible:

- The step's own guard was `if [ -n "$LUMEN_RECORD_PROOFS" ]`, which tests for NON-EMPTY.
  The shell said "not recording" and Swift said "recording" about the same variable, so
  the banner that would have announced it never printed.
- The `Keep the re-recorded records` upload is gated on `inputs.record_proofs` directly,
  which was correctly falsy — so the rewritten records were never uploaded either. They
  were written, used to make the lane green, and thrown away with the runner.

**What it cost.** Run 181 reported `proof-linux` green while the measurements had really
moved. From that run's own authority listing against the committed records:

| control | measured | committed |
|---|---|---|
| `tone.exposure` | **251.54** | 169.07 |
| `raw.tint` | **154.97** | 100.13 |

Both were expected to drift — the sweeps had just been widened to their panel ranges —
and a green lane is exactly what should not have happened. The tell was in the timing:
the drift test passed in **0.084 seconds**, when re-measuring 111 controls takes minutes.
It was writing files, not comparing them.

**Scope.** The defect existed only between the commit that introduced the `env:` block
and this one. Runs before it — including run 177, which verified the decode-tolerance and
responsiveness merges — used the old step and are unaffected. Run 181's `proof-linux` is
void; its other five jobs are not.

**Fixed at both ends, because either alone would have been enough to hide it.** The
variable is now exported inside the step, only when the input is literally `true`, so it
is absent rather than empty on a push. And `isRecording` no longer accepts presence: it
requires a value that means yes, rejecting empty, `0`, `false`, `no` and `off`. A check
whose failure mode is "silently stops checking" should be hard to turn on by accident.

**The lesson, stated plainly because it is the second time this session.** The other was
reading `status=$?` after a pipe as tee's exit code and concluding the lane could not
fail — wrong, and the refutation was already on screen. Both mistakes are the same shape:
reasoning about whether a check works from the shape of the code rather than from what it
did. The timing was in the log the whole time. 0.084 seconds is not a measurement.
