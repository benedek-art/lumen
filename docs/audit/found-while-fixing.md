# Findings discovered during the fix pass

The seven-domain audit produced 257 findings. These were found afterwards, while fixing
them — by agents substituting defects back to prove their own tests could fail, and by
the integrator merging. They are recorded here rather than folded into the domain files,
because how a defect was found is evidence about where to look for the next one.

---

**TEST-01 — `Swift.max` swallows a NaN, so about ten running maxima in the suite would
pass on a render that had gone entirely non-finite.** UNPROVEN (the safety net, not the
product).

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

**Why this is not urgent, stated so nobody re-derives it.** The primary failure mode — a
stage starts producing NaN — is already covered directly: `testRenderSurvivesAPoisonedPixel`,
`testTablesSurviveNonFiniteInput`, and the per-pixel `isFinite` sweep at
`RobustnessTests.swift:1518`. What the accumulators lose is the *second* line of defence,
for a NaN arriving under a recipe those tests do not exercise.

**The cheap fix, when it is worth doing.** Not forty call sites. Either a NaN-propagating
`maxKeepingNaN` used only where an accumulator feeds a bound — after which the existing
`XCTAssertLessThan` fails on its own, since `NaN < bar` is false — or a shared
`assertEveryPixelFinite(_:)` called by the tests that render whole frames with broad
recipes. The second is fewer edits and catches the thing itself rather than its shadow.

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

**PROOF-01 — two mixer controls are not monotone over their travel.** UNPROVEN, recorded
rather than asserted past.

The 46-control sweep found `mixer.magenta.sat` and `mixer.red.hue` change direction
somewhere in their travel. Both are recorded with `isMonotone: false` in their proof
records, and the monotonicity assertion is NOT yet applied to the mixer, because asserting
a property before understanding whether it should hold is how a suite acquires a test
nobody trusts.

`mixer.red.hue` has an innocent explanation available: red is the band that straddles the
wrap point in hue space, so a shift can carry patches across it and the measured direction
reverses without anything being wrong. That is a hypothesis, not a finding — it needs
checking against the band's actual boundaries.

`mixer.magenta.sat` has no such explanation. A band's saturation should move one way over
its travel. It is the one to look at first.

**PROOF-02 — overshoot, now measured on the six controls that can produce it.** Recorded,
not asserted.

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

`detail.dehaze` at 51.14 is the one worth a second look. docs/19 recorded that an earlier
dehaze put a tenth of a test frame above scene white at +50 and nearly half at +100, and
that was fixed; whether 51 code values of excursion on a veiled sky is the fix working or
the fix incomplete is not something this harness can say on its own.

**Why none of these is asserted yet.** A ceiling is a promise about what the code may do,
and every promise in this repository that turned out to be false started as somebody's
reasonable guess. These are measurements. They become promises when someone has decided
what the right answer is, and the records make that decision visible whenever it happens.

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
