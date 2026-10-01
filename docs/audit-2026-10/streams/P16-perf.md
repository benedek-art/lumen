# P16-perf — engine performance on the paths a photographer feels

Branch: `worktree-agent-a2f9f24e26e386bc9` (merged with trunk `claude/jolly-sagan-k7ch7z` before finishing).

## How this was measured

- New instrument: `Tests/LumenCoreTests/InteractiveCostBenchTests.swift`, gated on `LUMEN_BENCH=1`.
  It breaks one slider tick into the objects `RenderPlan.init` builds and the keys it spells. It also
  prices cold 33³ and export 65³ table bakes, fingerprints and canonical forms, one mask raster, and
  the grid's catalog queries on a seeded 20 000-photo roll. `LUMEN_BENCH_KEEP=1` keeps the seeded
  catalog on disk so its SQL can be timed outside Swift.
- Release build: `swift build -c release --build-tests -Xswiftc -enable-testing`, then
  `LUMEN_BENCH=1 swift test -c release --skip-build --filter InteractiveCostBenchTests`.
- **The machine is shared and noisy.** It has 4 cores and the load average stayed at 28–34 for
  every run, with ~6 agents compiling at once. Each figure is a p50 over 41 repeats (11 for catalog
  rows, 3 for export bakes). I ran two adjacent *before* builds and two *after* builds of the same
  bench and give both values. Compare ratios, not absolutes. As one calibration point, a 33³ finish
  bake measured 144–192 ms here against the 15–24 ms that `PlanTableCache`'s header records on the
  owner's Mac, so this box is roughly 7–10× slower.

## Where the time goes (release, before this branch)

| Path | Cost (p50) | Share / note |
|---|---|---|
| Slider tick, untabled control (Texture), all tables hit | 1.05–1.40 ms | of which **key spelling 0.67–0.96 ms (48–90%)** |
| Slider tick, Exposure (draft) | 1.41–1.64 ms | key spelling plus the exact 32³ tone cube (0.22–0.24 ms) |
| · colour-grade key (7 subtrees through JSONEncoder→JSONDecoder) | 0.43–0.71 ms | largest single piece of a warm tick |
| · tone-cube key / finish key | 0.19 / 0.05 ms | |
| · ToneEngine, bakeGainLUT, CurveStack, ColorEngine, GradeEngine, DisplayTransform | 0.004 / 0.06 / 0.03 / 0.002 / 0.0005 / 0.009 ms | not hotspots |
| Settle after a tabled control: cold 33³ bake | colour-grade 144–164 ms, finish 162–172 ms | inherent arithmetic, **the settle's dominant cost** (see SPEC 1) |
| Export, per photograph: 65³ bakes, uncached by design | finish 1 077–1 452 ms, colour-grade 989–1 192 ms | **export throughput's CPU floor** (see SPEC 2) |
| `RecipeFingerprint.fingerprint` (settle frame's preview identity, every save) | 5.8 / 9.9 ms (min 1.76) | `tree(of: Recipe())` was 0.83 ms of every canonical form |
| `CanonicalJSON.decodeRecipe` | 13.4–14.3 ms (min 3.4–3.6) | the same baseline, re-encoded |
| Grid query `photos(matching:)`, 20k roll, any sort | 185–307 ms | runs on every chip and every **filtered cull keystroke** |
| `facetCounts(for:)` (filter popover) | 622–727 ms | keyword axis ~65% (12 correlated EXISTS counts) |
| `photos(keyword)` | 69–86 ms | the same correlated EXISTS |
| `cullCounts` / `countPhotos(all)` | 12–16 / 0.4 ms | fine |
| Mask raster, radial, 1024×683 | 0.17 ms | context only. The mask caches belong to P15 and the settle work (8.5 s → 140 ms) has landed. |

## Items

| # | Item | Status | Commit | Before → after (p50) | Red/green | Proof records |
|---|---|---|---|---|---|---|
| 1 | Canonical forms re-encoded the constant `Recipe()` baseline on every call | FIXED | `11902e5` | canonicalRecipeJSON 2.16 / 9.91 → 1.13 / 1.11 ms; fingerprint 5.83 / 9.88 → 1.31 / 1.23 ms; decodeRecipe 14.3 / 13.4 → 2.01 / 1.89 ms | `CanonicalDefaultsBaselineTests`: 2 failures with the memo removed (10 trees for 5 calls; 2 for one fingerprint), green with it | none: output byte-identical |
| 2 | Every slider tick re-encoded 11 recipe subtrees to spell plan keys that had not changed | FIXED | `da4d98c` | Texture tick 1.40 / 1.05 → 0.15 / 0.20 ms (~7×); Exposure tick 1.41 / 1.64 → 0.90 / 1.75 ms (min 1.25 / 1.31 → 0.75 / 0.95) | `PlanKeyMemoTests`: 3 failures with RenderPlan back on `PlanTableCache.key` (11 encodes where 0 / 2 / 7 are due), green with it | none: keys byte-identical, so tables and frames are identical |
| 3 | The keyword chip was a per-photo correlated EXISTS; the popover paid it once per keyword | FIXED | `a12bb72` | facetCounts(all) 654 / 694 → 469 / 339 ms; facetCounts(★2+) 682 / 622 → 513 / 410 ms; photos(keyword) 86 / 82 → 56 / 43 ms | `CatalogQueryCostTests.testTheKeywordChipIsNotACorrelatedSubqueryPerPhoto` red with EXISTS restored (1 failure); brute-force equivalence green on both forms | n/a |
| 4 | The grid refresh read all 31 columns of every row to keep id and ISO | FIXED (LumenApp half source-verified) | `2e20b48` | grid order, 20k roll: 185–272 → 29–55 ms (captureTime); 176–260 → 41–43 ms (rating sort) | `testTheGridRefreshAsksForTheOrderNotWholeRows` red with AppState restored (2 failures). Order/ISO identical over 72 sort × direction × filter combinations | n/a |
| — | Instrument | — | `ea5971a` | — | — | — |

Next-photo in cull: there is no `LumenCore` hotspot to fix. `RollCursor` already indexes the roll,
and STATUS.md measured the keystroke cost as SwiftUI publishes. With a filter or a rating sort
active, a cull decision also triggers the grid query, and item 4 is that query.

Not fixed, by design: the tone cube re-bakes on every tone tick (0.22–0.24 ms). It is kept exact on
purpose (`RenderPlan`'s comment on `toneKey`: the stale path caused the Contrast/Blacks flicker).

## SPECS — need macOS (Instruments or the macOS runner); not attempted

1. **Parallel table bake.** A cold 33³ bake is ~36 000 independent evaluations of a pure closure.
   Splitting `LUT3D(size:)` across `DispatchQueue.concurrentPerform` slices gives byte-identical
   tables. Expected settle saving on an M-series Mac: 15–24 ms → ~3–5 ms per table. Two things need
   macOS before it ships. First, Instruments (Time Profiler plus the System Trace thread view) must
   confirm that the bake closures (`ColorEngine`, `GradeEngine`, `FilmChain`, `CurveStack`) hold no
   shared mutable state. Second, the bake must not starve the render actor or the `bakeQueue` drain
   during a drag. **Owned by P5** (colour-table plumbing), so I did not touch `LUT.swift` or
   `PlanTableCache`.
2. **Export-size tables for batch export.** Each exported photograph bakes finish, colour-grade and
   tone at 65³ (~1.1–1.5 s per table here, roughly 150–200 ms each on the Mac), and nothing is
   cached above the interactive size. A batch of N frames sharing one look pays this N times. Caching
   one export-size entry per slot (~6.6 MB each) would make frames 2…N free. This is a memory-policy
   change in `PlanTableCache` (P5) and needs a macOS export-throughput trace to size it. See DECISIONS.
3. **Main-thread work per filtered cull keystroke.** `refreshLibraryQuery` builds a
   `[Int64: URL]` dictionary over `allPhotos` (20k entries) and a full `compactMap` on the main actor
   for every result. It needs a Time Profiler capture on a 20k roll to price it against the 8.3 ms
   frame. If it matters, build the dictionary once per roll change.
4. **GPU half of the draft/settle frame.** `DragProbeTests` and `PerfProbeTests` run only on the
   macOS runner. Items 1–2 here remove CPU time in front of the GPU work; whether the README's
   "one display frame" now holds for Whites/Saturation settles needs a DRAGPROBE re-run on CI
   (`gpu-parity`) and a comparison with `docs/audit-2026-09/w0/perf-baseline.md` row for row.

## DECISIONS

- **Export-table retention (SPEC 2).** Holding one 65³ table per slot after an export costs about
  20 MB resident. In return, every frame after the first in a same-look batch skips about 0.5 s of
  CPU (Mac estimate). `PlanTableCache`'s header calls holding export tables "pure waste", which is
  true for a single export and false for a batch. This is the owner's call and P5's file, so I
  have not implemented it.
- **Comment refuted by measurement:** `refreshLibraryQuery`'s doc comment says the grid query is
  "cheap enough to call on every chip, keystroke and cull decision: it is one indexed statement". On
  a 20k roll it was 185–307 ms here (the ORDER BY uses a temp b-tree over the whole scope), and is
  29–55 ms after item 4. I left the comment alone. It is the owner's claim, and the owner should
  decide whether it now holds.

## FOUND-WHILE-FIXING

- `RenderPlan.init` builds a second `ToneEngine` inside `DisplayTransform.forRecipe` (0.004 ms).
  Measured; too small to fix.
- `PlanTableCache.renderIdentity(for:)` runs a `stat` per preview plan through `SourceFileIdentity.read`.
  It is not measurable on Linux without the pipeline; I note it for the SPEC 4 trace.
- Facet keyword domain (`GROUP BY k.id ORDER BY COUNT(DISTINCT photo.id)`) still costs ~66 ms on a
  20k roll. It is the next-largest piece of `facetCounts`.
- Hunks outside my stream: `RenderPlan.swift` (P5's area), with three key call sites swapped for
  the memo and no change to tables, staleness or pairing; `AppState.swift` and `CatalogService.swift`
  (one call site plus one wrapper).
