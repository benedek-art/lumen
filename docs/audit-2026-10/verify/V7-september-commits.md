# V7: the 29 unreviewed September commits under PR #5

Verifier: V7. Worktree branch `worktree-agent-a3417b3df9a5aff93`. I reset it from `99c3727` to the
trunk tip `a9a1d47` (claude/jolly-sagan-k7ch7z = main + PR #5) and reviewed there.
Build dir: `/tmp/lumen-build-v7`.
Scope: `git log --author=Claude --since=2026-09-03 5047f1b^2 ^99c3727`, 29 commits from 4 to 6 September.

Nothing in LumenApp/LumenPipeline compiles on Linux. For those files every verdict is
**source-verified only**, unless a Linux text-scan test covers the file. When a later commit
(mostly Astra `cc30178`) already repaired a defect, the defect is still listed against the
commit that introduced it, marked FIXED-LATER.

## Contrast proof records: re-pinned honestly

`9bcac9f` (A1-01) and `89a43d1` (shoulder hold 0.2) move pixels. `89a43d1` re-pinned
`tone.contrast` (authority 81.42 -> 68.38, mean separation 45.25 -> 30.41) and
`tone.contrastPivot` (114.57 -> 100.29) by hand. In the same commit it added the 9 records
4268c0d owed: `render.contrast/skew/hue/black`, `film.halationSize/Redness` and
`look.grain.amount/size/roughness`. That made the set 144.

- **All 11 agree with the engine on trunk.** For each id I ran
  `LUMEN_PROBE_CONTROL=<id> ...xctest LumenCoreTests.ControlProbeHarness/testProbeOneControl`.
  Each returned `"agrees": true`, and fresh authority equalled committed authority to the last
  digit. For example, tone.contrast measured 68.38186617000542 against 68.38186617000542
  committed.
- The `authorityFloor: 55` for tone.contrast is **unchanged**. No floor was lowered to fit
  the change.
- `fe3d38a` moves no pixels, which matches its claim. `SliderScale` is view-only, and the proof
  sweeps `render.contrast` directly.
- **Not recorded anywhere: mask-local Contrast moves too.** `ReferenceRenderer.applyLocalAdjust`
  and the GPU `LocalAdjust` init (`RenderGraph.swift:1946`) both build a `ToneEngine` with
  `contrast: adjust.contrast*scale`. So every mask with a non-zero Contrast renders differently
  after 9bcac9f and 89a43d1. No proof record covers `mask.*` (it is dispositioned out), so
  nothing failed. The commit messages do not mention it either. CPU and GPU share the engine,
  so they do not diverge.
- I could not finish the full 144-record check
  (`ControlProofTests/testTheCommittedRecordsStillDescribeWhatTheEngineDoes`) locally. It was
  killed at my 60-minute background limit after about 75 CPU-minutes on a box shared with 6
  agents. So I only verified the records these commits touched. The owner's proof.yml run is
  still the authority for the other 133.

## Verdict table

| # | Commit | Subject (short) | Verdict | Evidence |
|---|---|---|---|---|
| 1 | 4a633da | test-fast ceiling 15 -> 25 | OK | Superseded by bb60dc3 (35). The `status=$?` after the `tee` pipe is correct because GitHub's bash runs with `-o pipefail`. |
| 2 | c6af8a7 | sources list hover / unselected not dimmed | OK | Source-verified. Row is on `Lumen.rowHeight` (owner's 24 pt), hover is gated on clickability. The temporary A/B switch was removed in ce46a30. |
| 3 | 73bec03 | `SidebarVerb` replaces `.borderless` | OK (note) | Source-verified. The B tooltip matches the keymap decision. It deletes the sidebar "Keyword the selection" control, which docs/29 section 2.2's owner decision assumes exists (see Decisions). |
| 4 | 139f062 | fold governs its contents; folder header | **DEFECT** x2 (source-verified) | D1: a disabled header verb's click falls through to the header's `onTapGesture`. D2: Shift-Cmd-K focus lands on a field mounted in the same transaction. |
| 5 | 1590e1f | grade-joint hash vs architecture | WEAK-TEST | The engine change (`forcingJointScale`, default nil) is identity. The new hash comparison is redundant with the in-loop `jointScale == 1.0` assertion (see W1). |
| 6 | ce46a30 | selected row = accent at 0.30 | OK (decision) | The owner rejected the bar, not "chose accent". Law 7 trade (see Decisions). |
| 7 | ff2cb5d | `zoom` moved off `AppState` | OK | Source-verified. Every reader moved. `ScopeData` reads `LoupeViewport.shared.zoom` imperatively, so no lost invalidation. `ZoomBroadcastTests` is macOS-only. |
| 8 | cad5927 | pan clamp to drawn/2; drag always pans; double-click toggles | **DEFECT** (source-verified) | D3: the double-click `SpatialTapGesture` is the only viewer gesture not gated on `cropArmed` (or masking). |
| 9 | 2a6b30c | picker takes files; ingest default template | **DEFECT** x3 | D4 commonParent (FIXED-LATER cc30178). D5 restricted open marked the rest of the folder `missing` (FIXED-LATER cc30178, `completeListing`). D6 relaunch falls back to scanning the whole common parent (OPEN). |
| 10 | b8d6d4f | expansion off main actor | DEFECT (minor, OPEN) | D7: it dropped the "Nothing there Lumen can open" guard. An empty or non-file selection now opens an empty roll and persists it. |
| 11 | a9dd6b1 | CGFloat literal in PanClampTests | OK | Test-only. |
| 12 | 8720975 | `panTo` replaces `panBy` | OK | Source-verified. One clamped write per event, guarded. |
| 13 | 85c1645 | anchored zoom in one block; HUD noteInput | OK (untested) | Source-verified. The `anchoredZoom` handshake is correct for coalesced events. No test covers the one-pass claim. |
| 14 | bb60dc3 | zoom layout hold; MaskCanvas hit area; ceiling 35 | OK (WEAK-TEST note) | Source-verified. `scaleEffect` comes before `offset` (correct). The hold is disallowed while masking or picking. `ZoomLayoutHoldTests` only covers the `stretch` arithmetic, not the release. |
| 15 | db11b18 | drop, Finder open, shared entry field | **DEFECT** (source-verified) | D8: a cold-launch Finder open can be dropped. D7 is reachable by dropping a web link. |
| 16 | 60a71cc | root stops observing `EditRevision` | OK | Substitution: putting `@EnvironmentObject private var edits: EditRevision` back on `ContentView` turned `testTheWindowShellDoesNotObserveThePerEventEditSignal` RED; it is GREEN restored. `recipes` is not `@Published`, so the fix is real. |
| 17 | 86a8f97 | SliderEvidenceTests; proof.yml paths | OK | Test and CI only. |
| 18 | 4268c0d | 9 specs + ground-truth doc | OK | All 9 records probe as agreeing (above). |
| 19 | 9bcac9f | A1-01 contrast anchor; wheel hue; histogram quantize | OK, **moves pixels** | Substitution: the old 4->12 EV relax window turned `testContrastCannotPushAPixelPastTheDisplayAnchors` (2.1289 != anchor) and `testTheContrastFixedPointFollows...` RED; GREEN restored. Also moves mask Contrast (unrecorded, above). |
| 20 | 5f2b814 | app icon from geometry | OK | Running `scripts/make-appicon.py` reproduces all 10 committed PNGs byte-identically (`git status` clean afterwards). |
| 21 | 89a43d1 | shoulder hold 0.2 | OK, **moves pixels**; WEAK-TEST on one test | Substitution: hold 0.0 turned `EngineMathFixtureTests.testContrastMappingMatchesTheReference` RED. I checked the monotone minimum independently: 0.41048 at u = 0.770. W2: `testTheInteractiveTableAgreesWithTheExportOne` was loosened from 0.04 to 0.045. |
| 22 | fe3d38a | Render Contrast log track | OK | Substitution: removing `scale: .log` from LookPanel turned `testTheRenderContrastRowAsksForTheLogAxis` RED; GREEN restored. `SliderScale.log` round-trips correctly. |
| 23 | 000d345 | Green->Mint, Blue->Azure | OK | Substitution: the old names turned `MixerBandNameTests` (43.29 and 31.76 > 22.5) and `DominantBandTests` RED. No name-keyed import or persistence path exists (bands are positional). Astra AI-10 is still open: geometry is unchanged and there is no "Green" band. |
| 24 | 53a01bb | probe harness; stale layout tables | OK | Test-only. Harness tests `XCTSkip` without env vars. |
| 25 | 9b9e549 | registry as JSON | OK | Test-only. |
| 26 | 5b08ab6 | layout inventory citations | OK | macOS test-only; not runnable here. |
| 27 | 147da90 | atlas generator | OK | Script; no committed atlas consumes it yet. |
| 28 | ec156b9 | contrast comment numbers | OK | Comment/doc only. The code diff is empty, and I reproduced its 0.410481 figure independently. |
| 29 | a6e6941 | generator skips non-verdicts | **DEFECT** (minor, latent) | D9: "first file wins" in sorted order prefers `bw.aqua.compact.json` over `bw.aqua.json`. Reproduced with a two-file fixture: `load()` kept the compact one and skipped the canonical one. |

Also run: `python3 scripts/check-swift-surface.py` exits 0. `RenderContrastScaleTests`
(2/2), `EditRevisionRuleTests` (2/2) and `FrontDoorTests` (6/6) pass on trunk.
`EngineTests` passes 58/58 on trunk; the hold-0 substitution did not turn it red. All
substitutions were reverted (`git status` clean).

## Defects and weak tests: Phase 2 specs

**D1 (139f062): a disabled section-header verb toggles the fold.** `LumenSectionHeader`
(LumenControls.swift) puts the `onAction` Button, `.disabled(!actionEnabled)`, inside an HStack that
carries `.onTapGesture { toggle() }` and `.lumenClickCursor(isInteractive)`. A disabled SwiftUI Button
does not consume the click, so the ancestor's tap fires.
- Reproducer: Albums section with no target album. Click the greyed tray glyph and the section collapses or expands.
- Same for Stack with fewer than 2 selected.
- The pointing hand also shows over the disabled glyph.
- Fix: when the verb is disabled, give it a `.contentShape` with its own no-op `.onTapGesture` (or `.allowsHitTesting(true)` plus a swallow).
- Acceptance: a macOS UI check, or a text-scan test asserting the disabled verb swallows taps. Device-confirm first.

**D2 (139f062): Shift-Cmd-K may not land the caret.** The commit moved `keywordEntry` inside
`if keywordsExpanded`, and Keywords ships CLOSED. The `.onChange(of: keywordRequests.requests)`
handler sets `keywordsExpanded = true` and `keywordFieldFocused = true` in the same update,
before the `TextField` exists. `@FocusState` writes to a view that is not mounted yet are
commonly dropped.
- Reproducer (device): collapse Keywords, select a photo, press Shift-Cmd-K. The section opens with no caret.
- Fix: set focus on the next runloop turn (`DispatchQueue.main.async`, or `.onAppear` of the field when a request is pending).
- Device-confirm.

**D3 (cad5927): a double-click silently zooms under the crop tool and masks.** Drag
(`dragGesture`), pinch (`magnifyGesture`) and scroll (`applyScroll`) all start with
`guard !cropArmed`. The new `.simultaneousGesture(SpatialTapGesture(count: 2))`
(LoupeView.swift, about line 1346) does not. Before this commit, a double-click at fit was inert by design.
- Reproducer: loupe at fit, arm Crop, double-click on the picture. `viewport.zoom` becomes 1:1 unseen; disarm Crop and the picture jumps to 1:1. This is the hazard the drag guard's own comment describes.
- In masking, a quick double-click while placing or brushing also toggles zoom.
- Fix: `guard !cropArmed, !panel.layout.isMasking, state.pickTarget == nil else { return }` (the `zoomHoldAllowed` set).
- Acceptance: extract the gate into a pure predicate shared by all four viewer gestures, and test that it is false while crop is armed.

**D4 (2a6b30c), FIXED-LATER in cc30178.** `commonParent` used `for ... where a == b`, which
collects matching components after a mismatch. The fix (`guard a == b else { break }`) is pinned
by `AuditStateSafetyTests.testCommonParentStopsAtFirstDifferentComponent` (macOS).

**D5 (2a6b30c), FIXED-LATER in cc30178.** A restricted open passed the partial list to
`CatalogStore.scan`, which marked every other photo in that folder `missing = 1`. The fix is now
`completeListing: restriction == nil`.

**D6 (2a6b30c), OPEN: relaunch can scan the whole common parent.** In `reopenLastFolder`, when
`lumen.lastFolder.files` is non-empty but every remembered path is gone, `files.isEmpty` passes
`restrictedTo: nil`. That opens the common parent unrestricted.
- Reproducer: Open... two loose frames, one each from `~/Desktop` and `~/Downloads` (root = `~`). Trash both and relaunch. Lumen recursively scans and registers the entire home folder.
- With files picked from two volumes, root is `/`.
- Fix: if a remembered restriction exists and nothing survives, open nothing (or the empty state with a message), never the bare root.
- Acceptance: a macOS AppState test with a remembered restriction whose files are deleted asserts `folderURL == nil` (or an empty roll), not a scan of the root.

**D7 (b8d6d4f, reachable via db11b18), OPEN: an empty or non-file selection replaces the roll.** The move to
`openFolder(root, restrictedTo: Set(urls))` removed the "Nothing there Lumen can open" guard, and
nothing filters `!url.isFileURL`.
- Reproducer: drag a web link (or a folder containing no supported files plus nothing else) onto the window. The current folder closes, an empty grid opens rooted at the link's path or that folder, and that choice is remembered for relaunch.
- Fix: in `openSources`, keep only file URLs. Keep the cheap file-extension filter on the main actor and do directory expansion in the task, then restore the empty-result message (from the task, before `applyScan`).
- Acceptance: `openSources([URL(string:"https://x/y")!])` leaves `folderURL` unchanged.

**D8 (db11b18): a cold-launch Finder open can be lost.** `LumenAppDelegate.state` is assigned in the
window's `.onAppear`. `application(_:open:)` delivered during launch, before the first view appears,
hits `state?` as nil and is dropped silently; `reopenLastFolder` then opens the previous folder instead.
- Fix: buffer `pendingOpenURLs` in the delegate and drain them in `.onAppear` after (instead of) `reopenLastFolder`.
- Acceptance: a FrontDoorTests text pin that the delegate stores URLs when `state` is nil and that `onAppear` drains them. Device-confirm with Open With on a quit app.

**D9 (a6e6941), minor and latent.** `load()` iterates `sorted(os.listdir())` and keeps the first
verdict per id, and `.compact.json` sorts before `.json`. Fix: skip `*.compact.json` (or prefer
the file whose stem equals the id). Acceptance: the two-file fixture keeps the canonical file.

**W1 (1590e1f): the identity hash is now tautological.** `forcingJointScale: 1` makes the "pre-fix"
render `(…)*lumScale*1`, which is bit-equal to the shipping one whenever `jointScale == 1.0`. The
loop already asserts that at accuracy 0 for all 312 recipes, so the hash comparison can only fail
when that assertion already has. It no longer pins "the tree before 4903db2", only "the joint
factor is 1". This is acceptable as the property that matters (Astra AI-11 asks for exactly this
same-process form), but the claim in its comment ("stronger than the constant") overstates it.
Optional: reinstate the Linux constant under `#if os(Linux) && arch(x86_64)` as a second,
platform-scoped pin.

**W2 (89a43d1): a test bound was loosened from 0.04 to 0.045.** In
`EngineIntegrationTests.testTheInteractiveTableAgreesWithTheExportOne` the bound moved from 0.04 to
0.045 (measured 0.0410). The added "ladder" only asserts that the 33-cube beats a 17-cube, which
any well-behaved trilinear table does. So the new guard cannot catch a composed-transform defect
smaller than the 17-cube's error (0.0867). The commit message argues this openly, but it is a
loosened tolerance under discipline rule 3. Stronger acceptance: also assert the 65-against-129
rung (0.0260) is below the 33-against-65 rung, so the gap demonstrably converges rather than
merely being ordered.

## Decisions the owner should see (not defects; the agent made these calls)

1. **Contrast is softer by design** (9bcac9f/89a43d1). Authority went 81.42 -> 68.38 and mean
   separation 45.25 -> 30.41, about a third less midtone separation at the ends of the slider.
   The 0.2 hold is a trade the agent picked. The zonal limiter now takes up to 38% of
   Shadows +100 at Contrast -100 (scale 0.619) and up to 35% in the four-way corner (0.6468).
   The test invariant "positive contrast never binds" was replaced with floors of 0.60 and 0.62.
   It fixes A1-01, but it is a change to how a default control feels.
2. **The sidebar selection is accent at 0.30** (ce46a30). The owner said only "I don't really like
   this left side border". Choosing chroma in the chrome against Law 7 was inferred, not stated.
3. **The sidebar "Keyword the selection" control was deleted** (73bec03). docs/29 section 2.2's
   recorded owner decision says "the sidebar control's label and KeyGrammar entry both move with
   it", which presumes the control stays. Shift-Cmd-K survives in the Photo menu.
4. **Drag never zooms and double-click toggles fit/1:1 both ways** (cad5927). The commit says the
   owner chose "wheel zooms, drag pans", but no doc records it. Add it to STATUS "Decisions".
5. **Pan reach is now drawn/2** (any pixel can reach the centre), including the compare panes.
   The bound jumps from 0 to drawn/2 as soon as `drawn > container` on an axis.
6. A **restricted open roots the catalog at the common parent**. The same file opened as part of
   its own folder and as part of a picked set gets two photo rows (folder-relative names differ:
   `a.NEF` vs `day1/a.NEF`). Sidecar reconciliation carries the recipe across, but albums and
   history split. This is suspected, not reproduced: confirm in Phase 2 before deciding.

## Local commits

None to code. This report is committed in the worktree only, because the tool sandbox blocked
writing the main-tree path. Every substitution was reverted.
Worktree branch: `worktree-agent-a3417b3df9a5aff93`.
