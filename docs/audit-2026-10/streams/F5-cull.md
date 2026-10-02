# F5-cull — culling assists (docs/10 §10.6, README Phase 8)

Branch: the worktree branch `worktree-agent-a1dd240d6c1583fab`, based on `claude/jolly-sagan-k7ch7z` @ 0896556.
Feature stream rather than defect stream: everything below is new behaviour. "Red" here means
each defence or wire was substituted out and the test that pins it was watched fail.

## Items

| # | Item | Status | Commit | Evidence |
|---|---|---|---|---|
| 1 | Sharpness / focus score in LumenCore | BUILT | 479cc6c | `CullingAssistTests` 23 green. Red: no 1 px presmooth → noise case 2 failures (grainy 5 px-defocused frame 0.93 vs clean sharp 0.79); no noise floor → 1 failure; no resample to the 1024 px analysis edge → invariance 7 failures (scores spread 0.27 across 768/1000/1280 px previews); plain mean instead of subject weighting → bokeh case 1 failure |
| 2 | Burst / near-duplicate grouping (capture time + DCT pHash) | BUILT | 479cc6c | Grouping cases green; time-only grouping → hash-split case 1 failure |
| 3 | Eyes closed / face sharpness via Vision (macOS) | BUILT, source-verified | 479cc6c (geometry), 28107d9 (Vision) | Eye-outline axis ratio pinned on Linux (roll-invariant within 0.01). Vision calls behind `#if canImport(Vision)`; failure degrades to `faces = nil`, never to a lost score |
| 4 | Storage via a proper migration | BUILT | 49f5e8b | cache migration 3 (ADD COLUMN + 2 indexes). A real version-2 cache with a scored row migrates keeping the row and another detector's `junk`. Red: migration dropped from the list → 2 failures (`no such column: fs.noise`) |
| 5 | Filter grammar facets (LibraryFilter) + sort | BUILT | 49f5e8b, 28107d9 | `softFocus`, `closedEyes`, `burst` (Any / In a burst / Not in a burst), catalog-only, counted, compiled, in the sentence. `LibraryFilterTests` 40 green; `CullingEvidenceCatalogTests` 18 green. Red: softFocus not mapped into the query + scan deletes removed → 6 failures. Sharpness sort enabled in the menu (aesthetic stays pending) |
| 6 | Background compute, no keystroke-path work | BUILT, source-verified | 28107d9 | `CatalogService.analyzeCulling`: own `.background` QoS lane, one photo at a time, serial catalog queue entered once per 16-frame chunk read/write; reports ≤ every 5 s + once at the end; one `allPhotos` assignment per report. Grid cell reads `photo.attention` (a field), no lookup; the master switch is a stored `let` read once at launch |
| 7 | Subtle grid badge | BUILT, source-verified | c455f99 (model), 28107d9 (view) | 7 pt neutral dot top-right, tooltip = number behind it. Dot set == chip set on a real catalog; closed-eyes input dropped from `CullingAttention.evidence` → 1 failure |
| 8 | Changed file keeps stale evidence | FIXED (found while building) | 49f5e8b | `scan()` now deletes `frame_score`/`face` for a replaced file, as it already did previews/artifacts. Red with the deletes removed (counted in item 5's 6 failures) |

Proof records that move: **none.** No render path, recipe field or default is touched; the pass
writes `cache.db` only.

`swift build --build-tests --scratch-path /tmp/lumen-build-f5` clean; `python3 scripts/check-swift-surface.py`
exit 0 (and `scripts/test-check-swift-surface.py` exit 0). Suites run green on the final tree:
CullingAssistTests, CullingEvidenceCatalogTests, LibraryFilterTests, CatalogTests, FacetCountTests,
SavedLookCatalogTests, AuditSafetyTests. The one whole-suite run (no filter) died silently at
04:42 partway through (304 cases passed, 0 failures, no exit line; the box was running several
other agents' suites at the time), and was not repeated, per the "once" rule.

## What the numbers are

- Sharpness: Laplacian-of-Gaussian (σ 1 px) variance on Rec. 709 luma of the embedded preview,
  area-resampled to a 1024 px long edge; noise floor = (lower-quartile |LoG| / 0.3186)² subtracted
  per 8×8 tile; energy = ½·centre-weighted mean + ½·mean of the sharpest 10 % of tiles;
  score = 1 − exp(−rms / 0.004). Measured from pixels rather than ISO, because embedded JPEGs are
  already noise-reduced by the camera.
- Burst: chained per body (serial, else model), gap ≤ 2 s from the previous frame AND pHash
  Hamming ≤ 12/63. Evidence order sharpest first, unscored last. Writes `burst_id`/`burst_rank`
  in `cache.frame_score` only.
- Eyes: 4·area/(π·width²) of each eye outline in image pixels, 0.10…0.30 → 0…1, a face = its more
  open eye; stored in `cache.face.eyes_open`, which the existing `closedEyesThreshold` (0.35) reads.

## DECISIONS (implemented conservatively; owner may overrule)

1. **Score calibration.** `scoreScale = 0.004` and the existing `softFocusThreshold = 0.35` were
   set on a synthetic fixture (soft-focus flag at ~3–4 px of defocus at the 1024 px analysis
   edge). Chosen to under-flag: a real, detailed frame reads higher. Needs a real-shoot pass.
2. **No auto-stacking.** The spec's "Auto-stack bursts: on" would collapse every burst in the
   grid on first open (stacks default collapsed) — a visible UI change. Bursts are evidence rows
   plus a filter; turning them into `stack` rows is left as the photographer's keystroke.
3. **No "best of burst" filter.** Hiding all but the sharpest frame is an auto-pick (D37). The
   rank exists (`burst_rank`, tooltip "2nd sharpest") for a compare-seed later.
4. **Master switch without UI.** `cullingAssists.enabled` (default on) is a defaults key read at
   launch; there is no Settings pane to put it in.
5. **Chip placement.** Evidence chips live in the existing Metadata menu ("Culling evidence",
   "Bursts") rather than a separate evidence group in the bar.
6. **Dot style.** White 7 pt dot with a dark ring, top-right; spec says "one neutral dot".
7. **Strictness slider** (spec 0–100) not built; thresholds are the PhotoQuery defaults.

## Not done / limits

- Aesthetic sort, junk/black-frame detection, the face strip UI and per-face badges: not built.
- The pass does not pause while the user pages; it relies on background QoS (efficiency cores).
  Not measured on a Mac — LumenApp cannot run here.
- Face rects are only as good as the embedded preview (≤ 1536 px decode).
- Grid dots refresh after a rescan only when the pass reports again (it reruns after every backfill).

## FOUND-WHILE-FIXING

- `scan()` keeps `cache.raw_stats` for a replaced file (same shape as item 8; `raw_stats` is keyed
  on the file). Not touched — not this stream's table.
- `docs/15-catalog.md` §15.3 still shows the original `frame_score` DDL; the executable schema is
  ahead of the spec text.
