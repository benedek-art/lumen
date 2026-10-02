# P21-geomopen: KG-03 (cropped portrait orientation) and K-056 (first open of a card)

Branch: `worktree-agent-a11eaf92d634df3db`, on `claude/jolly-sagan-k7ch7z` at cbe7c66.
Local checks: `swift build --build-tests --scratch-path /tmp/lumen-build-p21` is clean.
`FrameOrientation*` (13 tests) and `BatchFraming*` (9 tests) are green. The
`check-swift-surface.py` result is given under KG-03.

**Proof records moved by this stream: none.**

| Item | Status | Commit | Red with the fix substituted out | Records |
|---|---|---|---|---|
| KG-03 cropped portrait never reconciles its orientation | FIXED (LumenCore rule + tests; LumenApp wiring source-verified) | e119443 | 33 failures across 5 of 7 tests | none |
| K-056 first open runs as one long block | NOT-FIXED (out of time; spec below) | — | — | — |

## KG-03: FIXED, e119443

**What was wrong.** The primary photograph's orientation was stored in one AppState flag.
That flag was reset on every selection change, and the only thing that could set it was a
whole-frame delivery. A portrait whose recipe already has a crop or an angle never gets a
whole-frame delivery outside the crop tool. So for the whole visit, these all worked
against the landscape sensor size:

- the crop overlay
- MaskCanvas and MaskOverlayView
- the neutral picker
- the primary's framing writes (`framingFrame` → `BatchFraming`)

Render and export use the decoded, already-rotated image size in `geometryRects`, so they
were right. Non-primary batch targets were also right, because they use
`BatchFraming.catalogFrame` (the stored size rotated by EXIF). The result was three
consumers working from two different frames.

**What the fix does.** The rule now lives in one place, `FrameOrientation.Memory` in LumenCore:
- It keeps one answer per photograph, and the answer survives selection changes.
- A whole-frame delivery counts as evidence, and it outranks the catalog.
- The catalog frame also counts as evidence. It is the same frame the non-primary targets
  use, and it always describes the whole photograph, so a crop cannot mislead it.
- A cropped delivery is never evidence. It cannot set an answer and it cannot clear one.

`FrameOrientation.deliversWholeFrame` replaces the predicate that used to live in the view.
AppState reads the stored answer when the selection changes and gives the memory the
catalog frame in `refreshPrimaryFrameSize`. LoupeView passes every delivery to the memory.

**Evidence** (`Tests/LumenCoreTests/FrameOrientationMemoryTests.swift`):
- **Agreement.** On a cropped portrait at 3°, these all now equal what the render's frame
  gives and what the non-primary path gives:
  - the overlay frame
  - `CropGeometry.resolve`, which `geometryRects` is built on
  - `BatchFraming` `.angle`, `.aspect` and `.swapOrientation`
- **Unchanged cases.** A sweep covers 4 sensor shapes × EXIF 1/3/6/8 × RAW and rendered
  sources × 5 geometries × crop tool on and off. Every uncropped case and every
  non-transposed case gives exactly the old frame and identical `Resolved` rectangles. The
  sweep checks that it visited more than 100 such cases.
- **Only the defect moves.** Cropped portraits whose recipe was saved from the sideways
  sensor frame are the only cases that change, and each one moves to the correct frame.
- **Red run.** I ignored the catalog evidence and restored AppState and LoupeView from
  HEAD: 33 failures across 5 of 7 tests.
- **LumenApp.** Source-verified only, pinned by two comment-stripped source tests that run
  on Linux.

**`check-swift-surface.py`.** The first run's exit code was lost, because I captured it
after a pipe. The rerun had not finished when I handed back. **Re-run it before landing.**

## K-056: NOT-FIXED (spec for the next stream)

I traced the code but changed nothing. The finding has drifted since September:

- **Current state.** `registerAndLoad` (`CatalogService.swift:249`) no longer runs on the
  main actor. `AppState.swift:~2702` calls it from `Task.detached`.
- **Remaining stall.** It still does the whole card inside one `queue.sync`
  (`CatalogService.swift:255`):
  - relocation probe
  - per-file `QuickSignature.compute`
  - `store.scan`
  - a per-photo loop doing `restoreStrokes`, `persistRecovered`, and a savepoint plus a
    `reindexText` per field

  That serial queue also serves thumbnails and grid queries, so nothing appears until the
  whole card is done. Then `applyScan` publishes the roll in one go on the main actor.

**Proposed shape:**
1. Split `registerAndLoad` into one `queue.sync` per chunk of about 500 files, so
   thumbnails and grid queries can run between chunks.
2. After each chunk, hop to the main actor once with the accumulated `stored`. `applyScan`
   must then:
   - rebuild `photos` (`libraryOrder` stays the whole listing; only `stored` grows)
   - bump the `RollCursor` revision (the P9 contract)
   - not add any per-keystroke work
3. Keep the `scanGeneration` guard on every chunk.
4. Launch the EXIF backfill only after the last chunk.
5. Measure on Linux through the `CatalogStore.scan` path with a synthetic 5k-file folder,
   comparing chunk time against whole-card time.

**Owed:** P7's `SourceOpening` change and the recipe-wipe atomicity comment in `applyScan`
both need re-reading before step 2. Today the wipe and the roll swap happen as one step,
and chunked publication must keep that.

## DECISIONS
None needed. KG-03 changes no render or default; only overlay and framing-write frames
change for cropped portraits.

## FOUND-WHILE-FIXING
- `ImageSource.nativePixelSize` and `AppleRawSource.nativePixelSize` mean different
  things. A rendered file reports its size after EXIF rotation (it loads with
  `applyOrientationProperty`). A RAW reports the sensor size before rotation. The memory
  copes because it compares shapes only. A pipeline-level fix would report the decoded
  size, rotated, for both, and the reconciliation would then never have anything to do.
