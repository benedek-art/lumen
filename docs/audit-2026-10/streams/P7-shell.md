# P7-shell: app shell, opening/relaunch, viewer gestures, export robustness

Stream agent: P7-shell. Branch: `worktree-agent-a71c64effb66d1976`, based on
`claude/jolly-sagan-k7ch7z` at `5029bc3`. Build dir: `/tmp/lumen-build-p7`.
Inputs: `verify/V7-september-commits.md` (D1-D9, W1, W2, decision 6) and
`verify/V6-export-release-ui.md` (REL-04 notes 1-2, REL-12 note 4).

LumenApp and LumenPipeline do not compile on Linux. Each change there comes with a Linux test.
Where the logic could move, it went into LumenCore (`ViewerGestureGate`, `SourceOpening`,
`LaunchOpenQueue`, `ExclusivePublish`) and the test runs it for real. Where it could not
(SwiftUI structure), the test is a comment-stripped source pin scoped to the one body
that matters. The pins use the new `Tests/LumenCoreTests/ShellSourcePins.swift` helper. Those
halves are marked **source-verified** below. Every red run was a substitution: the
fix taken out (or the previous file put back), the test run, then the fix restored.

Final state: `swift build --build-tests` clean (no warnings in touched files). All stream suites
green together (124 tests). `check-swift-surface.py` exits 0, its fixture suite passes 27/27, and
`check-release-policy.rb` passes with 22 mutations rejected.

## Items

| Item | Status | Commit | Red / green | Proof records |
|---|---|---|---|---|
| D1 greyed header verb folds the section | FIXED (source-verified) | `62f5e6b` | previous LumenControls.swift: 1/1 fail; restored green | none |
| D2 Shift-Cmd-K on closed Keywords, no caret | FIXED (source-verified) | `93908a7` | previous ContentView.swift: 2/2 fail; restored green | none |
| D3 double-click zoom under Crop / masking | FIXED | `72b8d01` | guard line removed: 1/5 fail; previous LoupeView: 5 fail; restored 5/5 | none |
| D6 relaunch scans the common parent | FIXED | `47fa3b4` | `relaunch` -> `.folder`: 1/12 fail; previous AppState: 3 fail; restored 12/12 | none |
| D7 web link / empty selection replaces roll | FIXED | `d0e1469` | old plan semantics: 4/8 fail; previous AppState: 5 fail; restored 14/14 | none |
| D8 cold-launch Open With loses files | FIXED (source-verified) | `88d47b1` | previous LumenApp.swift: 2 fail; non-holding queue: 1 fail; restored 21/21 | none |
| Duplicate catalog rows for picked files | REAL, FIXED | `7e11652` | before fix: 12 failures in 3/3; after 3/3; 7 catalog suites (106 tests) green | none |
| D9 atlas generator prefers `.compact.json` | FIXED | `5419051` | previous load(): 1 case fails, exit 1; restored 4/4 | none |
| W1 overstated identity-hash comment | FIXED (comment) | `cecb90c` | comment only, so there is no red/green | none |
| W2 loosened 0.045 bound | FIXED | `8923161` | ratio check with a 25-cube rung: RED (0.0622 < 2 x 0.0410) where the old ordering check stayed green; restored green | none |
| Export ENOTSUP/EINVAL fallback + reason | FIXED (renderer source-verified) | `86dfdbf` | fallback removed: 9 failures in 6/9; previous renderer: 2; previous AppStateActions: 1; restored 9/9 | none |
| Release from a re-run of an old main run | FIXED | `686f5e7` | previous ci.yml: checker exit 1; new: exit 0 | none |

No commit touches rendering. **No proof record moves.**

### Notes per item

- **D1.** While the verb is disabled it carries a clear overlay with a content shape and an empty
  `.onTapGesture {}`. The innermost tap wins, so the click no longer reaches the row's
  `toggle()`. Nothing is drawn differently. Not fixed: the row's pointing-hand cursor
  still shows over the disabled glyph (the cursor region is the whole row). Device check: click
  the greyed Albums glyph, and the section must not fold.
- **D2.** When the section is closed, ⇧⌘K parks the request (`keywordFocusPending`) and opens
  the section without writing the focus. The field's `.onAppear` consumes the request and focuses
  on the next runloop turn. When the section is already open, the field is focused at once. The deleted
  keyword control was not restored. Device check: collapse Keywords, select a photo,
  press ⇧⌘K, and the caret must be in the field.
- **D3.** `ViewerGestureGate` in LumenCore. `continuous` (drag, pinch, wheel) refuses only
  while Crop is armed, as before. `doubleClickZoom` also refuses while masking or picking.
  All four gestures in LoupeView route through it.
- **D6.** `SourceOpening.relaunch` returns `.nothing` when a remembered picked set has no
  survivors. The app then opens nothing and shows a notice. A macOS AppState test is added to
  `AuditStateSafetyTests`.
- **D7.** `SourceOpening.plan`: only file URLs, and only browsable types, count. `.nothing` keeps
  the roll and remembers nothing. A directory among the sources is walked off-main *before*
  the roll is replaced, and an empty walk keeps the roll. A macOS AppState test is added (web link,
  two empty folders plus a .txt).
- **D8.** `LaunchOpenQueue` holds Finder opens until `attach`. onAppear opens the held files
  *instead of* `reopenLastFolder`. Device check: quit Lumen, then Open With > Lumen on a RAW.
- **Duplicate rows.** Reproduced in LumenCore: the same file under `/shoot/day1` (`a.NEF`)
  and `/shoot` (`day1/a.NEF`) got two rows. The same happened opening a card root after a
  subfolder. `CatalogStore.scan` now looks a file it does not know up by absolute path in
  registered ancestor and descendant folders (compared by path component), and moves that row in
  with its id, edits, history and albums. Opening the original folder moves the row back.
- **D9.** The file named `<id>.json` wins whatever sorts first. The new
  `scripts/test-gen-slider-atlas.py` runs in the fixtures-linux lane.
- **W1.** The header now says what the hash pins: the joint factor is exactly 1 on single-tool
  recipes, which is equivalent to the in-loop assertion. It does not pin the tree before 4903db2.
- **W2.** Measured once with a 129-cube (55 s to bake, so not kept in the test): 17v65 0.1194,
  33v65 0.0410, 65v129 0.0260, 33v129 0.0420. The interactive cube's own error against a much
  finer cube (0.0420) accounts for the whole preview/export gap, so 0.045 is that gap plus about 10%.
  The comment says so, and it corrects a mislabelled figure (0.0867 is 17v33, not 17v65). The
  ladder now requires the gap to at least halve when the cube doubles (measured ratio 2.91).
  Before, it only required the gap to shrink. The tolerance is unchanged.
- **Export.** `ExclusivePublish` tries RENAME_EXCL first; the renderer still supplies
  `renamex_np`, so the existing pins are untouched. On ENOTSUP, EOPNOTSUPP or EINVAL only, it
  falls back to `link()`, then to an `open(O_CREAT|O_EXCL)` claim followed by a rename over
  the claim. Each fallback refuses an existing name with EEXIST. Every other errno is reported
  as it came. The batch status line now appends the reason: lost race,
  unsupported volume, or the contact message. `check-swift-surface.py` KNOWN gained the POSIX
  errno and `O_*` names (small hunk, in a file another stream may also touch). The V6
  acceptance (an `hdiutil -fs ExFAT` image on a Mac) is still outstanding.
- **Release.** publish-release runs `git ls-remote origin refs/heads/main` and refuses unless
  the result equals `GITHUB_SHA`, before anything is tagged. The policy checker requires that step:
  unconditional, ordered before `gh release create`, and failing with exit 1. Six new negative
  controls cover it.

## DECISIONS (conservative choice implemented; the owner can overrule)

1. **D6: notice, memory kept.** When every remembered picked file is gone, the launch shows
   "The photographs open last time are no longer there — choose what to open" and opens
   nothing. The remembered set is NOT cleared, because the files may be on a volume that is not
   mounted yet. The cost is that the notice repeats every launch until something else is opened.
2. **D7: one empty folder still opens.** One folder on its own is still a plain folder open,
   even if it is empty, as it always was. Only a picked set or a mixed set that comes out empty is
   refused. A stray unsupported file beside one folder no longer turns the open into a picked set.
3. **Duplicate rows: the row follows the latest open.** A photo row moves to whichever related
   folder last scanned the file. Folder-scoped queries (the grid of a folder not currently open)
   therefore no longer show a row that another open has taken. **Existing duplicates in a catalog
   are left alone.** Merging two rows' albums and histories is a migration with real choices in
   it, and it is not implemented.
4. **Release: a refusal fails the job.** A superseded run's publish job now ends red
   rather than skipped. It is visible and fail-safe, but it shows as a failure on manual re-runs.
5. **Export reasons are worded by me.** The three reason strings in `ExportPublishError` and the
   D6/D7 notices are new UI copy.

## FOUND-WHILE-FIXING

- The earlier W2 comment attributed 0.0867 to "17-against-65". It is 17-against-33, and
  17-against-65 is 0.1194. Corrected in `8923161`.
- `check-swift-surface.py` does not parse string literals. A `"\""`, `"{"`, `"//"` or `"/*"`
  in a test helper desynchronised it, and it reported members of the helper type as missing.
  `ShellSourcePins.swift` spells those characters as `\u{..}` escapes or concatenations. Any
  future comment-stripping helper will hit the same thing.
- `ExportCancelAdversarialTests` and `SoftProofExportTests` pin the literal text
  `renamex_np(from!, to!, flags)`. That is why the renderer still owns the `renamex_np` call
  and passes it into `ExclusivePublish` as the injected exclusive rename.
- The D1 pointing-hand cursor over a disabled verb (V7 D1 sub-point) is not fixed. It needs
  either a per-region cursor or a gate on the row's `.lumenClickCursor`.

## Commits (oldest first)

`686f5e7`, `5419051`, `cecb90c`, `8923161`, `72b8d01`, `62f5e6b`, `93908a7`, `7e11652`,
`d0e1469`, `47fa3b4`, `88d47b1`, `86dfdbf`, plus this report.
