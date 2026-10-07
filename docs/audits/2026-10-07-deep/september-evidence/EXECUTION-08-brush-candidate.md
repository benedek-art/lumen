# Integration note

This report describes isolated experimental branch `codex/lumen-brush-state`, implementation `283111a9b8897bd0f4e50a38efec54c42c038c70` and warning revision `e7780f8`. **Only this report is integrated here; none of that candidate's raster/cache/routing changes are enabled on the repair branch.** Reproduction commands below refer to the isolated candidate, not this branch. The candidate remains local, not a public branch dependency.

# M04 — partial repair: retained brush-component coverage

Status: **EXPERIMENTAL, NON-SHIPPING CANDIDATE. M04 remains open for mask-wide
algebra/refinement and useful mixed-brush interactive performance.**

**Do not enable this branch's raster unconditionally in production or cherry-pick
the complete implementation into the shipping path.** The real mixed-size preview
benchmark takes 17.24 seconds cold and 15.66 seconds per append at only 1024 pixels.
Bounded memory and exact component pixels do not make that behavior acceptable for
interactive painting. This branch intentionally preserves the qualified candidate
and its evidence for review; it is not a production-readiness sign-off.

This change repairs resolution-dependent Flow/Feather and paint/erase accumulation
inside one brush component. It does not claim that arbitrary compositions of
subpixel components, mask refinement, or every final output stage are
resolution-invariant. No mask-algebra, film, colour, or creative operator was
changed. The implementation starts from `e088737`.

## Safe integration boundary

Keep this full candidate isolated from the shipping renderer. Documentation,
reproduction fixtures and the strict expected-failure mask-wide test can be carried
forward immediately. If the new component primitive is useful as a reference
oracle, extract it behind an **explicitly invoked, non-enabled experimental API**
with direct tests; do not switch `accumulatedBrushPlane`, `BrushPlaneCache` or the
shipping graph to it by default. This branch currently switches those paths for
end-to-end qualification, so wholesale cherry-picking is not that safe boundary.

Promotion requires both mask-wide algebra correctness at the existing pixel bounds
and evidence of useful latency for the mixed tiny/broad-brush workload, with
cooperative cancellation. A route that avoids whole-frame fine replay must preserve
the measured 4096 reference and selection semantics. Silently reducing resolution,
changing brush strength, or disguising a slow render as a successful cached preview
is not an acceptable fallback. The immediate recommendation is to retain this
candidate as a non-enabled reference and leave M04 open, not to spend unbounded time
optimizing it during this repair batch.

## Evidence before repair

All numbers below are actual raster or rendered-pixel measurements, from optimized
native Swift on arm64 macOS, not formula-only agreement. Fixtures use the same
normalized content crop across different frame sizes.

* Original Size .01, Feather50, Flow10, Density80 horizontal stroke, 256/512/1024/4096:
  crop coverage `.000638820289 / .001661443263 / .002842454069 / .004308865569`.
  The 256-pixel preview held only 14.83% of the 4096-pixel reference coverage.
* A minimum hard dot (Size .002) disappeared at 256 and 512 pixels. The expected
  normalized circle area in the 2:1 fixture is `.00000628318530718`.
* An initial, **uncommitted and rejected**, per-stroke supersampling candidate
  corrected single strokes but averaged away the subpixel history after each
  stroke. Four overlapping Size .002 paints produced 2.1514 times as much crop
  coverage at 256 as at 4096. Three paints followed by one eraser produced
  **4.4140 times** as much. Exact resumed/cold agreement alone did not detect this.
* Dense hard-dot phase tests caught a further 7.03% area miss with four fine samples
  per radius. Hard edges now require eight; smooth profiles retain four.

Original red logs: `/private/tmp/lumen-mask-scale-red.log` and
`/private/tmp/lumen-mask-scale-green2.log`. The additional phase-test red log is
`/private/tmp/lumen-brush-state-phase.log` (three failing phase assertions).

## Implementation and API

`BrushRasterState` explicitly owns the projected `Plane`, stroke prefix, and sparse
64×64 fine-grid tiles. `Plane` itself has no brush provenance or new fields.
`accumulatedBrushRaster` is the retained-state API; `accumulatedBrushPlane` remains
the projection convenience API and accepts explicit state when resuming.

Sampling resolves the smallest brush in the component, with additional hard-edge
area sampling. Stamp spacing and spline sampling are source-normalized rather
than floored to an output pixel; a one-pixel inward hardness rim no longer erodes
small strokes. All strokes accumulate on the same component lattice, in the same
order and using the existing Flow, Density, pressure, Automask and erase equations.
Projection occurs after the component's complete stroke fold.

A same-grid append reuses the exact retained prefix. A smaller brush requiring a
finer grid replays the prefix; it never invents fine coverage by upsampling the
averaged output. Reported stroke-work counters include that replay. Prefix edits,
undo, wrong dimensions and invalid counts also replay. An unchanged completed
prefix returns its already-projected pixels without re-projecting the fine tiles.

The old `(plane, count)` resume tuple is replaced by explicit state. An explicitly
constructed coarse base has a documented pixel-constant interpretation; it is not
represented as recovered brush history. Product callers retain genuine state.

`BrushPlaneCache` now charges the output, fine tiles, dictionary capacity, explicit
base if present, retained stroke buffers and conservative container headers. Draft
retention is bounded by both 12 entries and 48 MiB; settled retention by 96 MiB.
These are **retained-cache bounds, not whole-process RSS**. No resolution ceiling
is used to change a selection silently.

Cache `clear()` increments a generation. Work started before clear cannot publish
over a newer same-key state. The renderer's existing source-generation key and
source-change clear remain complementary protections.

## Active memory and supported work

Fine storage is limited to **1024 tiles per active component accumulator**, or
16,777,216 bytes (16 MiB) of Float sample payload, plus array capacity and bounded
tile/dictionary overhead. On this macOS allocator a 4096-Float tile reserves 5112
Floats; therefore the measured 1024-tile **allocated element capacity is 20,938,752
bytes (19.97 MiB)** before container headers. Cache accounting includes that capacity.
When that accumulator would overflow, its partial coverage is discarded
and the complete component is replayed in bounded spatial batches. Every stroke is
folded into a batch before projection. This is the same sampling and arithmetic,
not a lower-resolution fallback. Exact retained/streamed pixel equality is tested
with forced one- and two-tile batches, including paint/erase and tiny sparse dots.

The streaming path collects no full-frame tile-index list. It scans bounded stamp
data to jump between occupied row/column regions, sorts at most 1024 tile keys,
and uses a one-pixel placeholder rather than an output-sized image for each batch.
It returns an exact projected plane but no resumable fine prefix. That projection
can be reused unchanged; appending to it requires full component replay.

The actual full-frame test places four Size .5 hard dots and a Size .002 stroke on
a 256² output. Its selected support covers over 77% of the frame; the shared fine
lattice is 8192². A fully resident fine lattice would require 256 MiB. The measured
peak accumulator is **1024 tiles / 16 MiB** of sample payload, and the final state
charges **279,584 bytes**, including reserved array capacity. The test took 0.222
seconds in the final qualifying optimized run (0.208–0.555 in earlier runs under
varying concurrent system load). This
demonstrates the storage boundary, not performance of every long-stroke mask.

Other storage remains explicit:

* Output projection is `4 × width × height` bytes, plus allocator capacity. The
  implementation can temporarily hold old and new projected planes: conservatively
  two output frames per accumulation, apart from caller/cache-held older results.
  A 4096×2730 output is 42.66 MiB; an 8192×5461 output is 170.66 MiB. There is no
  hidden full-size fine plane or per-batch output plane.
* A retained prefix may coexist with its copy-on-write successor. Thus a new 1024-tile
  fine working set can coexist with an older 1024-tile prefix, normally charged to the
  cache. Cache clear/eviction does not revoke an in-flight caller's ownership.
  These are per-render bounds; concurrent callers multiply active storage.
* Stamp/spline arrays, input strokes and source images are separate from fine tile
  storage. Control-point reservation is capped at 100,000 points per stroke;
  spline/stamp exhaustion uses the existing 400,000 dense / 200,000 stamp guards.
  Array growth and container overhead mean these payload counts are not exact RSS.

`BrushRasterSafety` explicitly refuses unsupported work before rendering. It checks
finite positive brush sizes, the above control-point/sampler bounds, integer and
half-integer fine-coordinate representability below 2^51, and a named limit of
2^34 clipped stamp-support sample visits. The last is a finite safety fence, **not
a latency guarantee**; a legitimate sixty-stroke Size .1 session at 8192 exceeds
the earlier candidate 2^30 threshold and must not be rejected just to make a test
cheap. The boundary is tested separately with exactly 289 versus 288 visits.

Compatibility is not inferred from the current .002 UI slider. `MaskCanvas`
historically accepted .0005 at stroke creation, and a .0005 dot remains supported
without payload changes. Even two isolated 1e-10 dots are supported without
traversing their enormous empty lattice. A 1e-12 dot combined with broad coverage
is refused for actual work cost; a 1e-30 size is refused for coordinate precision.
NaN, infinities, nonpositive sizes and sampler exhaustion are refused, not clamped.
This is not a claim that every malformed field of an imported sidecar is validated.

Refusal preserves all stored strokes. Preview uses the existing labeled degraded
preview path; regular export, HDR and CPU reference rendering throw the typed
refusal. Alpha-thumbnail rendering returns no alpha. Referenced disabled donors
are validated, unrelated disabled masks do not block rendering, and an invalid
inverted brush cannot accidentally become a full-frame selection. Those paths are
covered by actual pipeline tests.

## Pixel results after repair

* Size .002 four-paint crop coverage at 256/512/1024/4096:
  `.001300008356 / .001300008345 / .001300008349 / .001300008351`.
* Size .002 three-paint/one-erase coverage:
  `.000438447745 / .000438447747 / .000438447742 / .000438447744`.
* Size .01 three-paint/one-erase coverage differs by about 0.054% between 256 and
  4096. The unchanged test bound is 4%.
* Minimum hard-dot area is `.00000619888305664` at all four original test sizes,
  98.66% of analytic area instead of disappearing. The separate 128-phase test
  checks off-grid locations at 96 and 256 with the same 4% area bound.
* The original 4096 smooth-stroke peak `.63397145` and crop coverage
  `.004308865569116804` are explicitly pinned. Hard-brush antialiasing intentionally
  changes the previous inward pixel-rim error, rather than preserving that error.
* Actual GPU local blend, three-paint/one-erase, +1EV, matching scene crop:
  `.0003156824969 / .0003156823714 / .0003156823859` at 256/1024/4096.
* Native 16-bit final export, two disjoint brush components borrowed through disabled
  donors and two inversions, active group50% × mask200%, +.25EV:
  crop gains `.0002503264695 / .0002481014380 / .0002410525378`.
  Each borrowed export matches its direct-component counterpart within 1e-6;
  scale-to-reference gains remain inside the unchanged 4% bound. This is not
  pixelwise identity after nonlinear picture formation.

A +.01EV 8-bit/default-dither probe showed roughly 11% relative variation in its
very small final signal. A resolved quarter-stop 16-bit fixture and an independent
scene-linear GPU blend test qualify this repair without claiming that final-output
precision/encoding sensitivity was fixed. No product encoding was changed.

## Remaining M04 failure, explicitly tracked

For three identical Size .002, Feather50, Flow10, Density80 paints, one component's
whole-frame area is `.0019918822` at every tested size. Intersect that brush with an
identical second component under the existing `a*b` rule:

| Width | Intersected coverage |
| --- | ---: |
| 256 | .000316343995 |
| 512 | .000633867673 |
| 1024 | .001267785396 |
| 4096 | .001438295525 |

The 256 result is **21.9944%** of the 4096 reference. The reason is
`E[a] × E[b] != E[a × b]`: each component currently projects before mask-wide
algebra. Levels, guided refinement and other nonlinear operations have analogous
ordering concerns. Disjoint multi-component/group/reference routing is tested and
correct; that is not a claim about overlapping subpixel compositions.

`testKnownMaskWideIntersectionStillNeedsDeferredProjection` preserves the actual
failing 4% equality as a **strict expected failure** on macOS. Non-macOS XCTest
explicitly skips that known-failure tracker. A summary of “zero failures” from
XCTest must always be accompanied by the fact that this expected failure remains.

## Responsiveness remains a separate limitation

The rasterizer is synchronous. There is no cooperative cancellation check inside
the stamp, tile, spline or projection loops. Superseding an app render can prevent
publication, but does not promptly stop already-running brush computation. Large
streamed components also replay every stroke on append rather than resuming a
discarded fine prefix. Scanning stamp data again for each occupied spatial batch
trades work for bounded memory. The 2^34 support-visit fence does not bound this
repeated search/spline overhead tightly, and is not an interactive deadline.

These are **open performance limitations**, not passed responsiveness claims.
The batch implementation preserves exact pixels and historical stroke support;
it does not make every supported sixty-stroke mask interactive. Follow-up work
should add cooperative cancellation through the caller/API and improve exact
replay/indexing without changing brush resolution or selection semantics.

Measured optimized native diagnostics on this arm64 Mac, with all agent CPU/GPU
build/test lanes paused (a brief git checkout was reported near the end, so these
are not laboratory-clean timing guarantees):

| Fixture | Cold | 59/60-stroke prefix | Append | Exact cold/append |
| --- | ---: | ---: | ---: | --- |
| 4096×2730, sixty Size .1 strokes | 3.652 s | 3.569 s | 63.09 ms / 1 stroke | Yes |
| 1024×682, minimum hard dot + those sixty strokes | 17.243 s | 16.965 s | 15.659 s / all 61 strokes | Yes |

The ordinary fixture alternates Feather60/10, Flow55, Density90, seven curved
control points per stroke, and erases every fifth stroke. Its state is 44,763,408
charged bytes and needs no fine tiles. The mixed fixture inserts a Size .002 hard
dot first; it streams the component on an 8192×5456 fine lattice, returns 2,820,432
charged bytes, and peaks at 832 fine tiles (13,631,488 sample bytes; 17,012,736 bytes
of allocated element capacity). This is an intentionally realistic adverse
combination, **not practically usable for interactive painting** in its current
CPU replay implementation. The finite work fence admits it; the fence is not
evidence that it is fast. No 8192-output timing was run after observing this limit.

The earlier 4096 run during the root test suite took 5.644/9.932 seconds cold/head
and 214.77 ms append, illustrating why concurrent timings must not be treated as
stable performance regressions. No timing assertions were added or weakened.

Reproduce the diagnostic after the native release build above:

```sh
swiftc -O -module-cache-path /private/tmp/lumen-brush-state-20260922/ModuleCache \
  -I /private/tmp/lumen-brush-state-20260922/arm64-apple-macosx/release/Modules \
  scripts/bench-brush-state.swift \
  /private/tmp/lumen-brush-state-20260922/arm64-apple-macosx/release/LumenCore.build/*.o \
  -lsqlite3 -o /private/tmp/lumen-brush-state-bench
/private/tmp/lumen-brush-state-bench 4096
/private/tmp/lumen-brush-state-bench 1024 mixed
```

Timing logs: `/private/tmp/lumen-brush-state-bench-4096.log` and
`/private/tmp/lumen-brush-state-bench-1024-mixed.log`.

## Verification

The 32 new test methods cover repeated paint/erase across sizes, minimum dots and dense phase
positions, every prefix split including the 96-pixel thumbnail, exact cold/resume
equality, changed-grid replay, undo/edit/invalid-extent guards, reference strength,
no hidden `Plane` provenance, draft count and both-rung byte eviction, oversized
uncached results, Automask source isolation, and a semaphore-controlled clear race
with a new same-key render published before old work completes. They also cover
bounded full-frame streaming, historical/sparse tiny strokes, explicit work-domain
refusal and all render/export refusal routes. No sleeps are used for race sequencing.

The expanded optimized native run executed **609 tests, 11 RAW-corpus skips and
zero unexpected failures** in 28.05 seconds after build. There were **three expected assertion failures across
two methods**: the new strict M04 mask-wide intersection tracker, and two existing
assertions in the baseline duplicate-ID dependency tracker. Log:
`/private/tmp/lumen-brush-state-final-qualified.log`. The earlier 504-test adjacent run
also had those three expected assertions, not only the new one.

The retained-capacity fixture first failed at a charge of 1,008 bytes versus at
least 252,768 bytes of reserved projection/seed/stroke-buffer payload. Accounting
now uses array capacity rather than element count; this test passes without any
pixel math change. Red log: `/private/tmp/lumen-brush-capacity-red.log`.

The source-surface checker reports only three existing base-branch false positives:
the cross-test `Source` name collision (two diagnostics) and typed `for kind:` in
`MaskReferencePipelineTests` (one). Those were already corrected in the integration
branch and this lane does not edit that test file. Newly added multiline field
declarations pass the checker. Log: `/private/tmp/lumen-brush-state-surface-final.log`.

Reproduce the broad native lane:

```sh
swift test --build-system native -c release --jobs 2 \
  --scratch-path /private/tmp/lumen-brush-state-20260922 \
  --filter 'LumenPipelineTests|Brush|Mask|Polygon|MissingMaskInput|RobustnessTests'
```

## Proposed next bounded work: shared subpixel composition

1. Introduce an explicit selection-grid descriptor (output extent, fine factor,
   source-coordinate origin), shared by the root mask and its dependency closure.
   Preserve first-wins IDs, cycle handling, disabled-donor semantics and existing
   component operations. A component needing a finer grid forces exact replay or
   evaluation on that grid, never interpolation of a projected alpha.
2. First bound the change to **neutral-refine** masks: evaluate all component
   inversions/amounts, max/min/product folds and referenced selections in fine tiles;
   project only the final root result. Keep generic `Plane` and recipe formats
   unchanged. Pin the 4096 reference, add overlapping paint/subtract/intersect,
   inverted/transitive references and cold/cache/export comparisons before repair.
3. Retain only byte-accounted fine tiles, or replay evicted tiles. Stream the mask
   compositor's tile working set rather than allocate a complete giant fine plane.
   Budgets govern retention/work scheduling, never geometric resolution or alpha.
   A bounded row/tile API must state which component state it can resume exactly.
4. Treat refinement as a second explicit batch, not a presumed free extension.
   Pointwise levels can remain on fine tiles. Gaussian/guided operations need halos
   and source sampling on the shared lattice. The guide's global percentiles and
   Edge Shift's whole-frame signed-distance/ramp statistics require exact global
   passes or a separately verified tiled equivalent; they cannot be approximated
   with per-tile normalization without changing the selection.
5. Promote the expected failure only when the real full-mask pixel test passes at
   the existing tolerance. Keep M04 partial until applicable refine paths are also
   qualified. Include cache clear races, byte budgets, minimum-size strokes and
   large mixed-size components in the next red/green tests.

The 17-second mixed-preview fixture must also be a performance qualification input
for this next architecture. Sharing a fine grid across more components can amplify
that cost. Cooperative cancellation and a faster exact tile fold (or a separately
qualified spatially adaptive evaluation with explicit error bounds) need their own
bounded red/green work; simply increasing the allowed sample-work fence is not a
responsiveness fix.

This is a correctness-preserving compositor change, not a new mask operation or a
request to redesign the creative meaning of Intersect/Subtract/Refine.

