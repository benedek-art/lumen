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
