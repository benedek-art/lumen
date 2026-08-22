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
