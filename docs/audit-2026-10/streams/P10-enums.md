# P10-enums: PR #2's deferred enum and filter-grammar refactor, redone

Agent: P10-enums. Base: `bfc40a9` (`origin/claude/jolly-sagan-k7ch7z`). Branch: `worktree-agent-a41eb887ede1cc490`.
Build dir: `/tmp/lumen-build-p10`. Inputs: the deferral note in `6abf721`'s message and PR #2 (`36354d7`, branch `origin/claude/nostalgic-jepsen-7517b7`).

Final state:
- `swift build --build-tests` is clean.
- `LibraryFilterTests` passes 40/40 on Linux.
- `CullingEncodingTests` passes 7/7 on Linux, including a real SQLite catalog round trip.
- These suites are unchanged and green: `FacetCountTests`, `SidecarReseedTests`, `CaptureSharpenScopeTests`, `FrontDoorTests`, `ResetSemanticsTests`.
- `python3 scripts/check-swift-surface.py` exits 0. Its `switches` pass confirms every switch over `PhotoFlag` and `ColorLabel` is exhaustive.
- LumenApp cannot compile here. Every LumenApp hunk is **source-verified**, not compiled. "How the app side was checked" below describes what that covered.

Each red count below comes from substituting the fix out in the worktree, rebuilding, running the suite, and restoring.

## Items

| Item | Status | Commit | Red with the fix substituted out | Proof records that move |
|---|---|---|---|---|
| 1. One `PhotoFlag`, one `ColorLabel`, unlabelled as `nil`; `coreFlag` and all other translation deleted; encodings unchanged | FIXED (app side source-verified) | `2d8ddbb` | Case-sensitive `storedName`: 2 failures. Sidecar flag mapping corrupted (`.unflagged` written as pick): 14 failures. | none |
| 2. `LibraryFilter` and `PhotoFormats` public in `LumenCore/Library/`; PR #2's `LibraryFilterTests` ported | FIXED | `2d8ddbb` | Sentence sorted by `rawValue`: 3 failures. `hiddenCriteriaCount` counting search text: 2. Unlabelled branch of `matches` inverted: 3. | none |
| 3. Newer behaviour preserved (`cullCounts`, Delete masking guard, Stack/Unstack/Keyword chords, sidebar Unflagged row, `hiddenCriteriaCount`, status-bar sentence) | DONE | `2d8ddbb` | Not applicable. No PR #2 file was taken. Each site was edited in place on the current tree. | none |
| Found: the memory path ignored Match: Any | FIXED | `53b8995` | 45 failures: 40 of 96 catalog-agreement cases, plus 5 in direct tests. | none |

### 1. The enums — `2d8ddbb`
**What was deleted:**
- LumenApp's `PhotoFlag` (`rejected`/`none`/`picked`).
- LumenApp's six-case `ColorLabel: Int`.
- In `CatalogService`: `coreFlag`, both `appFlag`s, `sidecarFlag`, `appLabel` and `coreLabel`.

**Unlabelled is now `ColorLabel?` = nil.** This applies to:
- `PhotoItem.label`
- `HistoryStack.Culling.label`
- `CatalogService.StoredState.label`
- `AppState.CullCounts.labels`, now `[ColorLabel?: Int]` so the nil key counts unlabelled photos as `.none` did.

**What replaced the translation.** The only real boundary left is the sidecar's `lumen:flag` word. It is now `SidecarFlag(_:)` and `PhotoFlag(_:)`, plus `ColorLabel(storedName:)`, all in `LumenCore/Library/CullingEncoding.swift`. `ColorLabel(storedName:)` lowercases its input, as `appLabel` did. `PhotoFlag` and `ColorLabel` gain `displayName` for the sentence. The SF Symbol and SwiftUI colour stay in LumenApp as extensions.

**Encodings are byte-identical.** `CullingEncodingTests` checks this against literal tables copied from the deleted code:
- **Catalog flag integers.** -1, 0 and 1 decode to the same decisions and write back the same integers.
- **Sidecar flag words.** `reject`, `none` and `pick` round-trip.
- **Stored label names.** `red` through `purple`, and NULL, round-trip and keep their old sort slot (0–5).
- **Odd spellings.** `Green` and `PURPLE` read as before. `none`, `""`, `To Print` and `orange` read as unlabelled, as before.
- **Full round trips.** Every one of the 3×6 decisions survives `XMPSidecar.serialize`/`parse` and a real `CatalogStore` column.

Nothing on the app side was `Codable`, so no other encoding exists.

### 2. The grammar — `2d8ddbb`
**What moved.** `LibraryFilter`, `ISOBand`, `StackFilter` and `PhotoFormats` are now public in `Sources/LumenCore/Library/`.
- `matches` reads a five-member `LibraryFilterable`, and `PhotoItem` conforms to it.
- `query(sortKey:)` is the core entry point. A one-line LumenApp extension keeps `query(sort: SortOrder, …)` for the two app call sites.
- `browsableContentTypes` uses `UTType`, so it stays in LumenApp as an extension. `FrontDoorTests` still finds it in `AppState.swift`.

**How the tests were ported.** PR #2's file was ported to the current grammar.
- Added `hiddenCriteriaCount` tests.
- Added `PhotoFormats` tests: case-insensitivity, raw/rendered disjoint, and RAW-only compiling to every raw extension.
- Dropped PR #2's test that pinned the Match: Any gap as current behaviour. It is replaced by the fix below.

**Order is preserved:**
- The memory-path label sort keys on `metaSlot`, with nil as 0. That is the old Int order; `rawValue` is a String now and would sort alphabetically.
- The sentence reads labels in chip order.
- A cleared label's history row still reads "None".
- Flag order is unchanged.

### Found while fixing: Match: Any in memory — `53b8995`
**The defect.** `matches` ANDed every criterion whatever the toggle said. The SQL path ORs them under `matchAny`. So with no catalog, the grid and the chip counts (`FilterBar.memoryCount`) answered a different question from the sentence above them. PR #2 had found this and pinned it as a gap rather than fixing it.

**The fix.** Under Any:
- Each lit memory criterion is one verdict, still OR-ed within itself.
- A photo passes if any verdict passes.
- A criterion that is not lit is not a reason to pass.

The All path is the old code, untouched.

**The pin** is an agreement test against a real catalog: 54 photos (every flag × rating × label × file type) and 96 filters (every combination of the four criteria both paths can evaluate, with the toggle off and on). For each filter, the rows `CatalogStore.photos(matching:)` returns must equal the rows `matches` keeps. All 48 All cases already agreed; 40 of the 48 Any cases did not.

## How the app side was checked (no compiler here)
- **Grep sweep.** Every old name was grepped before and after: `.picked`, `.rejected`, `.none`, `label != .none`, `ColorLabel.none`, `coreFlag`, `coreLabel`, `appFlag`, `appLabel(`, `sidecarFlag(`, `flagName`. Each changed site was then re-read. The only hits left are in comments that describe the history.
- **Silent Optional traps.**
  - `photo.label != .none` would still compile against `ColorLabel?`, with different meaning, so it was rewritten to `!= nil` or `if let`.
  - `labelCount(.none)` and `toggleLabel(.none)` would have bound to `nil`, so they became explicit `labelCount(nil)` and `includeUnlabeled`.
  - In `HistoryStack.cullingDetail`, `before?.label` flattens to `ColorLabel?`. That was checked to be equivalent: a nil `before` always returns from the flag branch first.
- **Generic method references.** `filter(clicked.matches)` was rewritten as a closure, so it does not depend on generic method-reference inference.
- **Typecheck harness.** A throwaway harness in `LumenCoreTests` reproduced the changed app shapes against the real LumenCore and compiled cleanly on Linux, then was deleted. It covered:
  - `PhotoItem` and its `LibraryFilterable` conformance
  - `CullCounts` and its `[ColorLabel?: Int]` subscript
  - the `setFlag`/`setLabel` toggles
  - the label-count closure
  - `cullingDetail`
  - the `persistRecovered` comparison
  - the `SidecarLabelPolicy` call
  - the test loop over `[ColorLabel?]`
- **Imports.** Every file that names a moved type was checked for `import LumenCore`. `CullCountsTests.swift` was the one file missing it, and it is added.
- **Tests updated.** `CullCountsTests` and `HistoryPanelTests` now use the new cases. `HistoryPanelTests` gains `testCullingRowsKeepTheirWordsAcrossTheEnumMerge`, which runs on the macOS lane only.
- **No compatibility shim was needed.** Every old case name had a direct replacement and every call site was converted. Nothing aliases the old names.

**Files touched in other streams' areas.** All hunks are kept to the changed lines:
- `ContentView.swift` (sidebar counts): 5 lines plus one comment word.
- `GridView.swift`: 6 lines.
- `LumenApp.swift` (Photo menu): 3 lines.
- `Keymap.swift`: 4 lines.

Expect trivial conflicts at most with the sidebar/open/export and layout streams.

## DECISIONS
- **D1. Match: Any in memory now ORs (`53b8995`).** I treated this as a defect, not a taste call. The toggle is documented to flip the join between criteria, and the SQL path already does that. It only changes what the no-catalog fallback shows while Any is on. The owner can revert `53b8995` alone if the old behaviour is wanted.
- **D2. Wording kept.** A cleared label's history row still reads "None", the old `.none` display name. Something like "No label" may read better; that is the owner's call.

## FOUND-WHILE-FIXING
- The Match: Any memory-path defect above.
- **Text search differs between the two paths.** The SQL text search also matches keywords, camera and lens. The memory path only matches the filename. The agreement test leaves text out for that reason. It is a real but declared difference, because in memory mode the bar hides the chips the memory path cannot answer. Not changed.
- **Stale comments fixed.** `CatalogStore.saveRecipe`'s note and `RecipeReset.swift`'s header said `PhotoFormats` "lives in the app target". Both are reworded; the design reason (callers pass `isRendered`, the store does not interpret paths) still holds.
