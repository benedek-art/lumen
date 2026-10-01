# P11-hygiene — the instruments themselves

This stream checks that the checkers can fail. A green lane counts as evidence only if a broken tree would have turned it red.

Branch: worktree `agent-a65724bb4612c7119`, based on `claude/jolly-sagan-k7ch7z` @ `bfc40a9`. Nothing was pushed.

| # | Item | Status | Commit |
|---|------|--------|--------|
| 1a | Surface checker, labels pass: stdlib calls were judged against in-tree methods with the same name | FIXED | `9389cea` |
| 1b | Surface checker, values pass: a tuple binding hid behind a same-named annotated value | FIXED | `e576101` |
| 2 | 21 copies of a comment stripper that could not see string literals | FIXED | `88c3c9d` |
| 3 | `raw-corpus.yml` triggered only when its own file changed | FIXED | `df372c0` |
| 4 | Sweep for tests that cannot fail | PARTIAL (cheap ones fixed, the rest written up below) | `97fd4b8` |

No proof records move. Only `Tests/`, `scripts/` and one workflow file were touched. `Sources/` is unchanged.

---

## 1a. Labels pass vs stdlib names — FIXED `9389cea`

**What was wrong.** `items.drop(while:)` was checked against the in-tree `func drop(_:)` and reported as a label mismatch.

**Fix.** `STDLIB_SIGNATURES` in `scripts/check-swift-surface.py` lists the exact stdlib signatures for the four in-tree names that collide with stdlib methods:
- `drop(while:)`
- `firstIndex(of:)` and `firstIndex(where:)`
- `merge(_:uniquingKeysWith:)`
- `round()` and `round(_:)`

The table is consulted only when both of these hold:
- the call has a value receiver;
- every visible in-tree declaration has already failed to match.

The name is still checked. `METHOD_SKIP` was not touched.

**Fixtures.**
- `good-stdlib-label-collision`: red on the old checker (`drop(while) declared: _`), green now.
- `bad-intree-label-not-in-stdlib-table`: `drop(count:)` is flagged both before and after the change. This proves the table did not switch the name off.

## 1b. Values pass vs tuple bindings — FIXED `e576101`

**What was wrong (P1's case).** One function declared `var found: (url:, digest:)?` and also `let found: IngestDigest`. The checker only sees annotations that start with a capitalised type, so the tuple binding was invisible. It then reported `found.url` and `found.digest` as missing members of `IngestDigest`.

**Fix.** A `let`/`var` whose annotation opens with `(` or `[` (a tuple, array or dictionary) now marks that name as ambiguous within the function. This is the same treatment an inferred binding already gets.

**Fixtures.**
- `good-tuple-shadows-annotated-name`: reproduces P1's shape. Red on the old checker (2 findings), green now.
- `bad-annotated-member-beside-tuple`: a different annotated name in the same function still gets flagged (`landed.byteSize`).

**Evidence for 1a and 1b.**
- `python3 scripts/test-check-swift-surface.py`: all 31 fixtures behave.
- The same suite with `--checker <old copy>` fails exactly the two new good fixtures.
- With the intermediate checker (1a only), it fails only the tuple fixture.
- Every pre-existing bad fixture is still flagged by name.
- On the real tree, checker output is byte-identical before and after both changes: 13192 label sites checked, exit 0.
- The final tree, including this stream's new tests, gives 13254 label sites, exit 0.

## 2. Shared, string-aware comment blanking — FIXED `88c3c9d`

**What was wrong.** 21 files carried a copy of a comment stripper that could not see string literals: 18 in LumenCoreTests (one of them, `ExportPresetToleranceTests`, as an inline loop) and 3 in LumenAppTests (`HistoryPanelTests`, `RenderBudgetTests`, `ScopeTests`).

**Fix.** There is now one helper, `blankingComments(in:)`, in `Tests/LumenCoreTests/CommentBlanking.swift`. A byte-identical copy lives at `Tests/LumenAppTests/CommentBlanking.swift`, because test targets cannot share a source file without a new package target. The helper:
- handles code, comments and string literals in one pass: `"…"`, `"""…"""`, raw `#"…"#`, and `\(…)` interpolation, which it treats as code again;
- handles nested block comments;
- turns every comment character into a space and keeps newlines, so the stripped text has the same length and the same line numbers as the file.

Each of the 21 files now calls the helper. Each hunk replaces a private function body with one call, so call sites are unchanged. Four doc comments that said "copied" were updated.

**Fixture.** `CommentBlankingTests` is in LumenCoreTests, so it runs on Linux. It has 7 tests:
- `"https://…"` survives, and its trailing comment is blanked to spaces of the same length;
- a quote inside a comment does not open a string;
- nested block comments;
- multi-line, raw and interpolated literals;
- an unterminated quote stops at the end of its line;
- the App copy is identical to the Core copy;
- no test file carries its own string-blind stripper again. Before the switch, this test named exactly the 21 files.

**Red/green.** With the naive stripper substituted in, 6 of 7 tests fail (14 assertions). After restoring the helper, 7 of 7 pass.

**No verdict changed.**
- **LumenCore.** I ran the 19 LumenCore suites that use the stripper (193 tests) before and after the switch and diffed the sorted per-test verdicts. The only difference is the new guard test flipping from failed to passed.
- **LumenApp.** The 3 App suites cannot run here, so they are source-verified instead. I ported both strippers to Python and ran them over every file in `Sources/`:
  - For every file those three suites scan (`HistoryPanel`, `DevelopColumn`, `RenderCoordinator`, `DevelopPanel`, `HistogramView`, `ScopesView`), the two strippers agree on all non-whitespace content.
  - None of those suites' search strings depends on whitespace.
- **Where the two strippers differ.** They disagree on 7 files today, up from the 4 named in September: `AppUpdater`, `ExportRecipe`, `IngestPlan`, `XMPMerge`, `XMPSidecar`, `ExactMixerGPU`, `Kernels`. Every case is a `//` inside a string literal. Of the 21 suites, only `ColorPanelReachTests` and `PreviewRungTests` scan one of those files (they scan all of `Sources/LumenApp`, which includes `AppUpdater`), and both stay green.

## 3. `raw-corpus.yml` path triggers — FIXED `df372c0`

**Fix.** The push trigger now lists, besides the workflow file itself:
- `Sources/LumenPipeline/AppleRawSource.swift`
- `Tests/LumenPipelineTests/RawCorpusTests.swift` (the test that reads the manifest)
- `AuditRawAccuracyTests.swift`
- `RawDecodeBoundaryTests.swift`
- `Tests/LumenPipelineTests/RawCorpus/**`

**About the manifest.** Today the manifest is a heredoc inside the workflow file, so the workflow's own path already covers it. The `RawCorpus/` path is where the workflow's comments say the manifest will move, so the trigger survives that move.

**Evidence.** The YAML parses, and `scripts/check-release-policy.rb` passes ("16 unsafe mutations rejected").

**Note.** This lane runs only `--filter RawCorpusTests`. A change to the two boundary suites now re-runs the real-file corpus, but it does not run those suites in this lane; the macOS test lanes run them.

## 4. Tests that cannot fail — PARTIAL `97fd4b8`

### Fixed: Set comparisons where a duplicate is the defect
| File:line | What a duplicate would have hidden |
|---|---|
| `CatalogTests.swift:519-521` | an OR of two ISO bands returning a photo twice |
| `CatalogTests.swift:697` | a text query returning a photo twice |
| `PreviewCacheTests.swift:487-488, 495-496, 546, 559, 560` | a preview rung stored or returned twice |
| `MaskDependencyAdversarialTests.swift:122` | a mask rendered twice |
| `UnsavedSidecarRecordTests.swift:26` | a sidecar debt recorded twice |
| `InspectionHoldTests.swift:156` | two holds claiming one key |
| `CanonicalJSONTests.swift:93` | two fixture cases sharing a name, so one replays the other's recipe |
| `GrainParityScanTests.swift:297` | a SECOND `grainPlate` builder, which is the thing the test exists to catch |
| `BackupPolicyTests.swift:243` (`assertNewestSurvives`) | a backup name both kept and deleted |

All 135 tests in the touched suites pass. These are strengthenings with no source change: a duplicate changes the count and the sorted array but not the Set.

### Fixed: a test that only printed a timing
`AccuracyProbeTests.swift:437` `testWhatAFinerToneCubeCostsToBake` now also asserts that the timed call baked a full `size³×4` finite cube. No time bound was added; see the decision D1 below.

### Written up, not fixed: early `return` on Linux in front of XCTExpectFailure
The code under test is LumenCore. I removed the `#else return` locally and ran the bodies on Linux today. **Every one of these defects is still live**, so none of the expectations can be removed. On macOS the expectations are strict, so a fix would surface there.

`CurveAdversarialTests.swift` (the `return` is at the line in brackets):
- `:263` [272] `testGroupMoveToARailAndBackIsBitForBit` — 102,614 ulp round-trip failures
- `:310` [319] `testGroupMoveIsRigidForEveryInRangeSet` — 104,561 failures
- `:344` [353] `testAZeroBandComesHomeToExactlyZero` — 0 comes back as −7.1e−15
- `:390` [399] `testGroupMoveOnValuesOutsideTheRange` — spread 150 becomes 110, not reversible
- `:413` [422] `testGroupMoveOnASpreadWiderThanTheRange` — frozen in both directions
- `:434` [443] `testMeanAndMovedAgreeAboutWhichSetsAreLive` — produces NaN
- `:495` [504] `testTwoDeletionsAtOneIndexAreTwoUndoSteps` — two deletions fold into one undo step

`RollCursorAdversarialTests.swift`:
- `:28` [37] — answers 2 where `firstIndex` answers 0
- `:64` [73] — answers 1 vs 0
- `:90` [99] — answers 1 vs 0

What these need is a fix to the defect in GroupMove / CurveEditing / RollCursor, which belongs to other streams. A cheaper instrument would be a Linux branch that asserts the finding is still present (an inverted assertion) instead of `return`. That way Linux also notices the day the defect is fixed. I did not do this: it is ten non-mechanical hunks in files other streams own.

### Written up, not fixed: macOS-only XCTExpectFailure
- `LumenAppTests/LayoutMetricTests.swift:209, 245, 288` — the precision floor at a panel width of 320. This is still live (`minimumPanelWidth = 320`, `defaultPanelWidth = 380`). It is an owner trade-off, already documented in the test.
- `LumenPipelineTests/ColorTableAccuracyTests.swift:66` — strict, AI-03 is unresolved. It cannot run here. If the colour stream closes AI-03, the strict expectation turns red and the expectation must be deleted.

### Not a defect (checked)
- **Sets that are correct as written:**
  - `IngestAdversarialTests:373` — the count is asserted on the line above.
  - `LookRenderPresetTests:276` — the claim is about the set of distinct presets.
  - `WorkspaceTests:50` — count checked at :52.
  - `BackupPolicyTests:90` — count checked at :92.
  - `MaskPanelTests:328` — a duplicated kind would be harmless.
  - `SpeedEditTests:81`, `SavedLookTests:137, 152` — dictionary keys, unique by type.
  - Every `Set(x).count == x.count` assertion is a correct uniqueness check.
- **Timing tests that do assert something:**
  - `PlanCostProbeTests:96` — telemetry with a 30 s "broken" bound; the real property is tested at :158.
  - `PerfProbeTests:68` — asserts non-nil output and a 10 s bound.
  - `AuditSidecarScalingTests:23` — asserts classification counts; the time is only printed.
- **Tests with no visible assertion:**
  - The `LayoutMetricTests` tests all go through `report()`, which calls `XCTFail`.
  - `ControlProofTests:276 testWriteTheEvidenceSheets` produces artifacts by design.
- **XCTSkip:** the FTS5 skips in `CatalogTests` do not skip on Linux; all 63 tests execute.

## DECISIONS
- **D1. No time bound on the bake-cost probe.** `AccuracyProbeTests:437` now proves the work happens, but any millisecond bound is a performance threshold. On this box the measurements are 7 ms at 32³, 19 ms at 48³ and 65 ms at 65³ (debug build). Setting such a threshold is the owner's call.
- **D2. Blanking instead of deleting.** The shared helper blanks comments to spaces rather than deleting them, because offsets must survive stripping. The 21 call sites previously deleted comments. No verdict changed (see item 2). `MaskPanelTests.stripComments` was already correct but deletes. I left it alone because it is not one of the 21, and switching it could move its window-based assertions.

## FOUND-WHILE-FIXING
- **Line-filter strippers.** Five scans drop only the lines that START with `//`. Trailing comments and block comments survive, so a search string can match prose:
  - `LumenPipelineTests/MaskKeyTests.swift:215`
  - `LumenAppTests/AuditControlContractTests.swift:16`
  - `LumenAppTests/ModifierKeysTests.swift:30`
  - `LumenAppTests/AuditDenoiseAvailabilityTests.swift:23`
  - `LumenAppTests/FilmDisplayTransformAvailabilityTests.swift:93`

  They are string-safe, so not part of the 21. They are an easy next step: a call to `blankingComments(in:)` (LumenPipelineTests would need its own copy).
- **The disagreement list grew.** The naive and correct strippers now disagree on 7 `Sources/` files, not the 4 recorded in September (see item 2).
- **App tests gated to macOS.** Five LumenAppTests files import only LumenCore and scan LumenApp text: `CullScale`, `ExportCancelAdversarial`, `FocusPeakingMount`, `KeyGrammar`, `PasteboardCarveOut`. They run on macOS `test-fast`. The Linux CI lane filters to LumenCoreTests, so removing their `#if os(macOS)` would buy no CI coverage. Not a defect.
- **`ExportPresetToleranceTests.swift:493`** has a Swift 6 concurrency warning (mutation of a captured `var out`). It predates this stream and was left alone.
