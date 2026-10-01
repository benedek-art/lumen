# R1-reaudit: adversarial re-audit of the October fix streams

Agent: R1-reaudit. Base: `origin/claude/jolly-sagan-k7ch7z` at `064525e`. Branch: `worktree-agent-af8c12e625982314c`.
Build dir: `/tmp/lumen-build-r1`. Range audited: `git log 5047f1b..HEAD` (103 commits, 10 stream reports).

## How it was checked

- **Baseline.** `swift build --build-tests` is clean. `python3 scripts/check-swift-surface.py` exits 0. Every suite named below was green before any substitution.
- **Substitution.** For each stream, the riskiest landed mechanism was substituted out in the worktree. I chose the mutations myself, and where possible they differ from the stream's own. I then rebuilt, ran the filtered suite, and restored with `git checkout -- Sources/`. 16 substitutions were run in two batches plus two confirmation runs.
- **Source reading.** For the macOS-only code (LumenApp, LumenPipeline, workflows), I read every LumenApp/LumenPipeline hunk in the range that touches persistence, concurrency or new API names. Those verdicts are **source-verified only**.

## Verdicts

| Stream | Verdict | Substitutions I ran (red / green) | Notes |
|---|---|---|---|
| P1-ingest | CONFIRMED | S-04 walk limited to the planned name: IngestAdversarialTests **10 failures** in 3 tests. Restored: 25/25 | S-01/S-02/S-03 read in source. D1 (disambiguate twins) and D4 (cross-run identity = name chain + bytes) lose no data: the worst case is a redundant copy, or an identical-bytes frame treated as present. |
| P2-persistence | CONFIRMED, with residuals | REL-06: tokens compared whole (st_dev back in effect): AuditSourceIdentityTests **3 failures**. REL-02: rule 1 (an owned bare file wins) deleted: SidecarNamingTests **3 failures**. Restored: 8/8 and 11/11 | Residuals R2-a and R2-b below. REL-09 `close()` holds `sidecarLock` around `pendingSidecars`/`unsavedSidecars`. The Auto Tone landing closes the gesture through the idempotent `sliderGesture(active:false)`. |
| P3-masks | CONFIRMED | Duplicate-id repair disabled: MaskIdentityRepair **2 failures**. Restored: 3/3 | Brush strokes are content-addressed (`strokesRef`), so renaming a duplicate mask id orphans no blob. `scaledPresenceAmount` is the identity inside ±100, so d495ff6 moves only out-of-range values. DECISION 2 and 3 (⇧/⌥ handle semantics, a dab on a pin selects) are UI-direction changes made by default. See "Defaults that are not conservative". |
| P4-curves | CONFIRMED, one decision missing | AI-04 both branches off: CurveBlackLiftTests **3 failures** (purple `[.0268,.0061,.0674]` reproduced). S-05 old-style key restored: CurveAdversarialTests **2 failures**. Restored: 6/6 and 30/30 | No proof record moves. No record writes a point or luma curve; the parametric records sweep a neutral ramp; and `liftedLuma` equals the ratio form exactly on a neutral. Pixels do move for existing edits that lift black. **`renderingRevision` was not bumped and the report does not raise it.** See DECISION NEEDED 1. |
| P7-shell | CONFIRMED after two test additions (both WEAK-TEST, now fixed) | Duplicate-row fix, per-file guard compared as a string prefix: CatalogPathIdentityTests **stayed 3/3 green**. Fixed in `c5d3fb6` → 4 failures. `SourceOpening.plan`'s `isFileURL` filter removed: SourceOpeningTests **stayed 14/14 green**. Fixed in `4285276` → 3 failures. EINVAL dropped from the fallback set: ExclusivePublishTests **1 failure**. Restored: 4/4, 15/15 and 9/9 | Row-move data-loss review is below. No caller pattern-matches `RenderError.writeFailed`, so the export error type change is safe. `LaunchOpenQueue` hand-off is fine. |
| P8-raw | CONFIRMED (CI half source-verified) | `needsRaw9ColourBoundary` reverted to `== "9"`: RawDecoderNumberTests **1 failure**. Restored: 3/3 | Workflow YAML parses. The guard's `expected` count has no header row (16 positive manifest rows). The `skipped` regex matches XCTest's `-[Class test]' skipped` because `.` matches the space. |
| P9-layout | CONFIRMED | RollCursor revision check removed: **13 failures**. `canHold` ignoring the straighten angle: CropRatioLimitTests **1 failure** (176 accepted ratios did not hold). Restored: 17/17 and 5/5 | Catalog `width`/`height` come from `kCGImagePropertyPixelWidth` (unoriented), so transposing for EXIF orientations 5 to 8 in `BatchFraming.catalogFrame` is right. A batch target with an unknown frame is skipped, which is conservative. D3 (rectangle drag no longer fans out) is a behaviour change made by default. |
| P10-enums | CONFIRMED (app side source-verified) | Match: Any branch removed: LibraryFilterTests **45 failures**. Restored: 40/40 | Catalog/XMP encodings: `ColorLabel(storedName:)` lowercases like the deleted `appLabel`. The reconcile compares `state.label?.rawValue` with the row's own spelling, so the old lowercase re-write is unchanged. Flag mapping is total both ways. The SQL builder ORs text search under Any too, so the memory-path fix agrees. App-side compile hazards checked by hand (below). |
| P11-hygiene | CONFIRMED | String-literal handling off in both CommentBlanking copies: CommentBlankingTests **6 failures**. Restored | `Tests/LumenAppTests/CommentBlanking.swift` is the only file there without `#if os(macOS)`. It uses only stdlib, so it compiles on both platforms, and no other LumenAppTests file declares `blankingComments`. |
| F1-denoise | CONFIRMED | `classicOverlap = 24`: `testTheReceptiveFieldCountsEveryPass` **1 failure**, and the tiling test **1 failure** (seam 1.58e-5 > 1e-6). Restored | The new GPU goldens use only APIs that exist and already appear in the tree: `CIContext` options `.workingFormat` and `.cacheIntermediates`, `RenderGraph.Options(longEdge:noiseScale:)`, `ClassicalDenoise.contributingNoiseScale`/`effectiveLevels`. |

### Proof records

None of the streams' commits moves a proof record. I checked P4's claim (above) and P3's (d495ff6 is the identity inside ±100). My two commits are tests only.

## Confirmed defects

Both are WEAK-TEST: the code is right, but the test that should hold it could not fail. Each is fixed with a substitution-proven test.

1. **P7 duplicate-row fix (`7e11652`): the per-file component comparison was untested.** `day1`/`day10` were only tested as sibling folders, which the folder-level relation already separates. The reachable case is different. `/shoot/day1` is registered and `/shoot` is opened, listing `day10/a.NEF`. A string-prefix comparison then moved day1's rated row onto day10's frame, and day1's own `a.NEF` got a fresh unrated row. That is silent re-attribution of edits.
   - Fix: test `testASiblingWhoseNameExtendsARelatedFolderDoesNotTakeItsRow`, commit **`c5d3fb6`**.
   - Red with the string-prefix guard: 4 failures. Green: 4/4.
2. **P7 open plan (`d0e1469`): the `isFileURL` filter was untested.** The web-link test used a link with no extension, so the type filter refused it on its own. Two drops reach the filter and nothing else stops them:
   - A picture dragged out of a browser (`https://…/a.jpg`). Without the filter it becomes a picked set rooted at `/shoot`.
   - A link ending in "/". Without the filter it becomes `.folder(link)`, and the app's `isDirectory` stats the *local* path of that link.

   Fix: test `testAWebLinkToAPhotographOrAFolderIsNotASource`, commit **`4285276`**. Red: 3 failures. Green: 15/15.

No WRONG verdicts. I found no regression that loses data.

## Data-loss review (no defect found; reasoning kept for the record)

- **P7 row moves (`adoptRowsFromRelatedFolders`).**
  - It runs inside `scan`'s transaction.
  - It only moves rows *into* the folder being scanned, and only for names this folder does not already hold. So a pre-existing duplicate is never merged or overwritten.
  - Edits, history, albums, stacks, keywords and `source_identity_<id>` are all keyed by photo id and travel with the row. Sidecars and the unsaved-sidecar record are keyed by absolute path, which does not change.
  - A row that comes in `missing` is restored by the ordinary loop.
  - A folder rooted at `/` relates to everything. That is intended (a cross-volume picked set). The cost is P7's declared D3: the row follows the latest open.
- **P2 REL-06 scan.** A missing stored token is adopted, and a differing token is confirmed against `quick_sig` before any wipe. The current token is stored after every row, so a remount costs one read per file once, not per scan. Residuals:
  - **R2-a (not a defect, note).** When the token differs and the `signature` closure returns nil (the file is unreadable at scan time: permissions, a dataless cloud file, a share dropping mid-scan), the row is treated as changed. Its quick_sig, EXIF and previews are wiped and the backfill rebuilds them. That is recoverable and the pixel-safe direction, but it is still a wipe from a transient read failure. Spec if wanted: on a nil signature, keep the row and do not store the new token, so the next scan re-asks.
  - **R2-b (performance, note).** On a filesystem that renumbers inodes on remount (some SMB/exFAT setups), every file in the folder costs a 1 MB read inside the scan's write transaction once per remount.
  - **Content changed beyond the first MB at identical size and mtime-second.** The catalog no longer invalidates this case (quick_sig matches). In-session pixels are still right, because `RenderCoordinator` and `PlanTableCache` key on the full token. The disk preview's `PreviewStore.scope` also carries the token, so the stale preview is not served. Only the EXIF columns can be stale. Accepted.
- **P2 REL-02 `SidecarNaming.resolve`.** I traced the four transitions plus the darktable case. One narrow change from before: a Lumen-written qualified file that no longer parses (truncated) no longer pins the photo to the qualified name (rule 4 may pick the bare name). The old code returned qualified on mere existence. The bytes are not deleted, and nothing reads them today either, so this is not data loss.
- **P10 encodings.** Verified as above. `CullingEncodingTests` pins literal tables, and `CatalogStore` reads the flag via `PhotoFlag(rawValue:) ?? .unflagged`, unchanged.
- **P1 ingest identity.** The alias check runs per frame after the primary is written, so on a case-insensitive volume `…/photos` stats to the same inode as `…/Photos` and is refused. The start-time sheet check can miss a case-only alias on not-yet-existing paths, but the engine catches it.

## Concurrency and macOS-only API review (source-verified)

- `LumenAppDelegate.application(_:open:)` keeps `MainActor.assumeIsolated`. `attach` is called from `.onAppear` (main). The target is in Swift 5 mode.
- `ModifierKeys` is not actor-isolated. It is written only from the `flagsChanged` local monitor (main thread), and `KeyDispatcher` removes both monitors in `uninstall` and `deinit`.
- `AppState.openSources(.expand)`: the walk runs in `Task.detached` through `nonisolated static expand`, and lands with `MainActor.run` plus a `scanGeneration` check. Two `.expand` opens started before either lands share a generation, and the later finisher wins. That is a cosmetic race, not data loss.
- `RenderCoordinator` (actor): `knownIdentities` is actor state. Forgetting renderer state only on a real identity change is right, because the renderer's caches are per-session.
- **API names (a non-existent member breaks build-macos).** Every new member is real and exists since macOS 12, against a deployment target of macOS 15:
  - accessibility: `.accessibilityAdjustableAction`, `.accessibilityAction(named:)`, `.accessibilityElement(children:)`
  - `NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged])`
  - `CIRAWDecoderVersion(rawValue:)`, `CVPixelBufferCreateWithBytes`
  - Darwin calls `renamex_np`, `RENAME_EXCL`, `link`, `open(…, O_CREAT|O_EXCL)`, `ENOTSUP`/`EOPNOTSUPP`/`EINVAL`

  Every cross-module call I checked is `public`:
  - `DetailEngine.scaledPresenceAmount`, `RawParams.decoderNumber`, `RawParams.needsRaw9ColourBoundary`
  - `ISOBand`/`StackFilter` (`id`, `rawValue`, `range`), `PhotoFormats.*`
  - `ColorLabel(storedName:)`, `SidecarFlag(_:)`/`PhotoFlag(_:)`

  `PhotoItem` satisfies `LibraryFilterable` (`flag`, `rating`, `label: ColorLabel?`, `isRaw`, `filename`). No LumenApp extension redeclares `displayName`. No `ColorLabel.allCases` loop lost a `.none` entry: the chip row uses its own five-element `labelOrder`, and Unlabelled is a separate chip.

## Defaults that are not conservative (for the owner, not code defects)

- **P4: no `PreviewCache.renderingRevision` bump for AI-04/baf9c96** (DECISION NEEDED 1). Existing edits that lift black on the luma curve, or on the master curve under Preserve Luminance, now render differently below the lift. Developed previews already on disk under the same `recipe_fp` keep the old (purple or discontinuous) look in the grid until the recipe changes, while the loupe and exports show the new look.
  - P3 raised the same trade for d495ff6. P4 did not raise it.
  - Options: bump `renderingRevision` (invalidates every cached preview once), or accept the mismatch.
- **P3 F1-04/F1-05.** ⇧ on a radial resize handle now keeps the ratio instead of snapping to a circle, and a no-travel dab on another mask's pin now selects that mask instead of stamping. These are interaction changes made by default. They are listed in P3's DECISIONS and need the owner's confirmation.
- **P9 D3.** A rectangle drag on a multi-selection now edits only the photo it is drawn on. The previous fan-out was the defect, but "edit one" rather than "sync per-target" is a product choice.
- **P7 D3.** A photo row moves to whichever related folder last scanned it, so a folder-scoped grid of the other folder stops showing it until reopened.

## Commits (local, not pushed)

- `c5d3fb6` The duplicate-row fix's component comparison inside a related folder had no test
- `4285276` The open plan's file-URL filter had no test that its type filter did not already cover
- plus the commit that adds this report.

Branch: `worktree-agent-af8c12e625982314c`.
