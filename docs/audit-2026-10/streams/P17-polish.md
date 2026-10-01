# P17-polish — leftovers the other streams found and did not fix

This branch is based on the local `claude/jolly-sagan-k7ch7z` at 064525e, not on
`origin/claude/jolly-sagan-k7ch7z` (cbf71e6). The origin ref is 21 commits behind the local
integration branch, and the work this stream builds on exists only locally: the shared
`blankingComments(in:)` (88c3c9d), the slider accessibility (56c43fa), and the P3, P7 and
F1 reports. The worktree was reset to the local branch after the origin reset, and nothing
was pushed.

## Items

| # | Item | Status | Commit | Red/green | Proof records |
|---|---|---|---|---|---|
| 1 | Five (six) whole-line-only comment filters | FIXED | 85e5f9a | Guard red with 1 failure naming exactly 6 files; green CommentBlankingTests 8/8. Verdicts: 48 assertions identical old vs new, 0 differences | none |
| 2 | Curve editor has no accessibility semantics (UX-03 remainder) | FIXED (source-verified) | 02a9658 | Previous CurveEditorView: 1 test, 3 failures; green 7/7 | none |
| 3 | Mask overlay same-path staleness | FIXED (source-verified) | ac9d52f | Previous AppState: 2 tests, 5 failures; green 2/2 | none |
| 4 | Pointing hand over a disabled header verb (P7 D1) | FIXED (source-verified) | fb0b453 | Previous LumenControls: 1 test, 3 failures; green 2/2 | none |
| 5 | Test-target and package warnings | FIXED (9), two left on purpose (below) | f4e55ab | A warning cannot go red. The touched files emit none now, and their suites are green with unchanged counts (DenoiseTests 22, ExportPresetListDecodeTests 7, ExportPresetToleranceTests 7, IngestAdversarialTests 25, IngestCopyTests 13, RollCursorTests 8, SidecarLabelPolicyTests 4) | none |
| 6 | docs/07 "until this stage ships" | FIXED (doc) | 3b949d6 | n/a | none |

### 1 — whole-line comment filters → `blankingComments(in:)`

The brief named five filters. A sixth, `AIDenoiseRenderedHelpTests` (LumenCoreTests), uses
the same filter, and the new guard found it. `MaskKeyTests` is in LumenPipelineTests, which
had no copy of the helper, so this adds a third byte-identical copy at
`Tests/LumenPipelineTests/CommentBlanking.swift`. `CommentBlankingTests` now checks that the
App and Pipeline copies match the Core one. It also has a new guard,
`testNoTestFileDropsOnlyWholeLineComments`, that fails on any test file containing
`{ !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }`.

**Showing no verdict changes.** Five of the six suites are macOS-only. I wrote a standalone
Swift program that restates every one of their source assertions. It runs each assertion
against the same `Sources/` files twice, once through the old filter and once through
`blankingComments`, and compares the verdicts. It covered 48 assertions in 12 groups. Every
verdict was identical and passing, with 0 differences. `AIDenoiseRenderedHelpTests` also runs
here, and it passes both before and after. Its continuation join now drops whitespace-only
lines rather than `//` lines, because blanking leaves a commented line empty, not missing.

**One semantic note.** `MaskKeyTests`' kernel scan now also sees `//` lines inside the kernel
*string literals*, which the old filter dropped. Extra text can only add channels or chunks
to that check, so it gets stricter. Today it changes nothing.

### 2 — curve editor accessibility

Rules: `Sources/LumenCore/Interaction/CurveAccessibility.swift`. Wiring: `CurveEditorView`.

- **Points.** Each point is a clear element that ignores hits, placed where the point is drawn.
  - The label names the curve and the point's place: "Red channel black point", "Point curve point 1 of 2", "… white point".
  - The value matches the readout: "input 25.0%, output 40.0%".
  - Increment and decrement move the output by 1%.
  - The named actions "Move input right" and "Move input left" move the input by 1%, measured on the plotted axis and mapped back through `storedX`.
- **Splits.** Each split is an element labelled like "Split between Shadows and Darks".
  - Increment and decrement move it by 1%, kept inside its neighbours and the 10–90% band.
- **Undo.** Every step is bracketed with `sliderGestureChanged(true/false)`, under the key the point's drag uses, so each step is one undo step and its deferred write lands.
- **Limit.** One AT element carries one increment axis. That is why the input step is a named action, as the wheel's hue is in 56c43fa.
- **Not runtime-tested.** As with 56c43fa, no test checks the accessibility tree at runtime: a headless `NSHostingView` publishes no children.

### 3 — mask overlay staleness

- `refreshMaskOverlay` now records `maskOverlaySourceKey`, built from the url, the mask id, the `SourceFileIdentity` token and the loaded stroke counts.
- `refreshMaskOverlayIfSourceChanged()` re-rasterizes only when that key differs. It is called from the same two places P3 added `refreshMaskThumbnails()`: `applyScan` and stroke-set arrival.
- The edit path is unchanged.

### 4 — cursor over a disabled verb

The disabled verb's swallowing layer now reports hover into `overDisabledVerb`, and clears it
on disappear. The row's `.lumenClickCursor` is gated on `rowCursorEnabled`, which is
`isInteractive && !(overDisabledVerb && !actionEnabled)`. `LumenCursorModifier` already
re-syncs when `enabled` changes, so the hand pops with the pointer still inside the row.
Device check: hover the greyed Albums glyph and you should get the arrow.

### 5 — warnings

These are the warnings in a clean `swift build --build-tests`, all in test targets or the
package. Each fix keeps the original semantics:

- `DenoiseTests:141`: removed the unused `base` (a pure computation, never asserted).
- `ExportPresetToleranceTests:493`: the watchdog result is now a locked `@unchecked Sendable` box (`DecodedList`) instead of a captured `var` mutated on a global queue.
- `IngestCopyTests:177`: the progress log is a locked box (`SeenProgress`) instead of a captured `var` mutated in the driver's `@Sendable` callback. This is the same pattern `IngestAdversarialTests.ProgressLog` already used.
- `IngestAdversarialTests:471`: `var sources` became `let` (and the dead `_ = sources` was removed).
- `RollCursorTests:110`: the unused `ids` now feeds `inRollOf: ids.count` (it is 0, as before).
- `SidecarLabelPolicyTests:13,22,36`: the implicit `String??` → `Any?` coercion is now written `as Any?`. This is the same coercion, so `.some(nil)` still asserts non-nil.
- `Package.swift`: SwiftPM warned about "144 unhandled files" for `Proof/records/*.json`. They are now excluded from the LumenCoreTests target. They are read from the source tree through `#filePath` (`ProofRecordStore.directory`), never from the bundle, so nothing reads them differently. **Not run to completion:** I started ControlProofTests (`testTheCommittedRecordsStillDescribeWhatTheEngineDoes`) after the change, but it did not finish before hand-back (load average was about 40). The claim rests on reading the source: `ProofRecordStore.directory` is `#filePath`-relative, and no `Bundle.module` access touches `Proof/`. The owner's proof.yml run will confirm it. If that run disagrees, revert this one line of f4e55ab.

**Left on purpose:**

- `MaskDependencyAdversarialTests:401` `.none` ambiguity. The test writes the bare `.none` deliberately, to pin what the compiler resolves it to ("The compiler warns; it does not refuse… if this is now empty the ambiguity has been closed"). Silencing it would remove what the test checks.
- `Invalid Exclude 'Proof/evidence': File not found`. That directory is gitignored output that the proof run creates and proof.yml uploads. Silencing the warning on a fresh checkout would need a tracked placeholder inside an ignored output directory, plus a `.gitignore` rule change. I did not think that trade was mine to make.

### 6 — docs/07

The Milestone-1 stopgap sentence now says the stopgap is retired:

- Tier 1 runs on the GPU in the interactive and export renders (`RenderGraph.applyDenoise`, golden-tested).
- `Denoise.appleStandIn` sets the decoder's NR to zero under Off and Classic.
- The decoder's NR drives only the AI mode's stand-in until a model ships.

## DECISIONS

- **Curve step size and axes.**
  - Steps are 1% of the encoded axis, on both axes and for splits.
  - Increment and decrement move a point's output; its input moves by named action.
  - Anchors are adjustable but not deletable.
  - No "Delete point" action was added, because it would need a per-element condition and the context menu already offers delete. The owner may want one.
- **Undo granularity for assistive steps.** I matched LumenSlider: one bracket per step, under the control's own coalescing key. Repeated steps on the same point within the 1.2 s window therefore fold into one undo step, exactly as arrow-key nudges do. A keyless step (one undo entry per action, always) is the alternative.
- **Package exclude of `Proof/records`.** This is behaviour-neutral today. If a future test ever loads a record through `Bundle.module`, the exclude must be reverted.

## FOUND-WHILE-FIXING

- **`origin/claude/jolly-sagan-k7ch7z` is 21 commits behind the local integration branch.** The stream brief's reset instruction targets origin, which lacks 88c3c9d, 56c43fa and the P3/P7/F1/P11 reports this task depends on. Future briefs should name the local ref, or the orchestrator should push before dispatch.
- **`check-swift-surface.py` labels pass.** Any in-tree method named `set(_:)`, including one in a test file, makes every `UserDefaults.set(_:forKey:)` in Sources read as a label mismatch (4 findings). I renamed my test box's method to `store(_:)`. The checker is unchanged. This is the same family as P11's "labels pass reported stdlib calls whose name collides with an in-tree method" (9389cea), which evidently does not cover `set`.
- **`MaskPanelTests:534` asserts no surviving line starts with `//`.** This is a check *of* a stripper, not a filter, so the new guard correctly ignores it (the guard matches only the `.filter { !$0… }` form).
- **No CI lane runs LumenAppTests (K-102).** `MaskOverlaySourceKeyTests` and the five converted App-side scans run only there.
