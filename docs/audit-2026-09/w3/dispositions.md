# W3 — verifying the audit against the code that now exists

W2 wrote 122 findings across thirteen areas. Twenty-four of them are named in
`ledger.md` because their fix landed and the commit said so. **The other 98 had no
recorded disposition at all**, and the first thing this pass established is that "no
disposition" was not the same as "open": most of the S1 rows had already been fixed, by
landings that named the defect and not the finding.

That gap is the finding about the process. A ledger that records only what its author
remembered to cross-reference is a ledger that grows a phantom backlog — and a phantom
backlog is worse than no backlog, because the next person works from it.

## Method

Each row was checked against the code as it stands at `1e3773d`, not against the code
W2 read. Where the finding named a file and a symbol, that symbol was read. Where it
named a count, the count was re-taken. A row is only marked FIXED where the mechanism
that fixes it is visible — a landing, a test, or the code itself — never because it
seemed likely.

The automated first pass (does any file name the finding id?) was **discarded as
unreliable**: it reported F1-01, F3-04, F4-01, F4-02 and J1-01 as unmarked, and all five
verify as fixed. Fixes in this project name the defect, not the audit row.

## S1 — all ten verify FIXED

| Finding | State | The mechanism |
|---|---|---|
| B1-01 Point Colour Range is not a selection | FIXED | `pointSigmaL/C/H` and `pointRangeBase` on `ColorEngine`; the range is a scale on the base, not a widening to neutral |
| B1-03 Negative Saturation switches the B&W mix off | FIXED | `apply` captures `bandSource` before `applyVibranceSaturation` and passes it to `applyBlackAndWhite(_:bandSource:)`; `testTheMixSurvivesNegativeSaturation` |
| F1-01 Delete while masking flags the photograph rejected | FIXED | `Keymap.swift` — `if PanelLayout.shared.layout.isMasking { state.deleteActiveMask() }` ahead of `setFlag(.rejected)`, with the reasoning written in |
| F3-01 painting replaces every selected photo's strokes | FIXED | landed with the data-loss batch |
| F3-02 the sidecar drops the whole payload past ~20k points | FIXED | `BrushStroke.PayloadDecision` — `.none` / `.payload` / `.tooLarge(characters:)`, so "too big" is a value and not a nil |
| F3-03 a missing input counts as usable, so an inverted mask floods | FIXED | landed with the data-loss batch |
| F3-04 blobs live in a directory no backup covers | FIXED | `BlobStore.backUp(to:)` / `restore(from:)`, wired into `CatalogService.backup()` beside the `VACUUM INTO`, named after the snapshot it belongs to |
| F4-01 one picker flag serves every disclosed mask | FIXED | `componentPickerOpen` / `subtractPickerOpen` are `Set<String>` keyed by mask id, through `pickerBinding` |
| F4-02 a disclosed mask edits the selected mask's component index | FIXED | a per-mask accessor replaced the shared `activeComponentIndex` at every child of `maskDetail` |
| J1-01 `.sidecarWins` writes the wrong recipe, untested | FIXED | K-015 removed the shared file; `SidecarAndIngestTests` now covers `.sidecarWins` at three call sites |

## S2 — fixed in this pass

| Finding | The mechanism |
|---|---|
| **I1-06** `ContentView` reads `currentRecipe` without observing `EditRevision` | the declaration, with the reason: `showsMaskPanel` gates the floating Masks box on `!masks.isEmpty` and had no invalidation source — it re-bodied only because `addMask` also writes published selection state, which is coincidence holding up a contract |
| **I1-07** the `EditRevision` rule is enforced by comment only | `EditRevisionRuleTests` — per-declaration scan with the two non-`View` helpers carved out by name and by their callers. **Its own first draft passed its substitution proof**, because the doc comment explaining the rule contains the word `EditRevision`; comments are stripped now |
| **L-03** the updater checks the bundle is *signed*, never *whose* signature | a `sha256:` line in the release body, published by CI from the bytes it uploads and verified before anything unpacks the archive. Fails closed |
| **A2-04** ↑/↓ on a focused slider do nothing | `onKeyPress(.upArrow/.downArrow)` on `LumenSlider`, and a cross-file check: the dispatcher stands down for all four arrows the moment a slider takes focus, so the slider must catch all four or the key is SWALLOWED — worse than either alternative, because the photographer cannot tell an ignored key from an eaten one |
| **J1-02** `ftsEnabled` is a `let`, so a broken index fails the write | `private var`, and `reindexText` no longer throws: it logs once, turns the index off for the session, and every text query takes the LIKE fallback `isTextIndexAvailable` already exists to describe |

## S2 / S3 — verified FIXED by the U and engine landings

`G2-04` the type scale nothing used (198 raw / 61 token → **35 raw / 234 token**) ·
`G2-06` the elevation ladder's dead names (27 uses outside their definition) ·
`G2-09` the HUD material that did not exist (`lumenHUD` / `hudFill`, 9 uses) ·
`G1-03` the Crop section's doubled heading (`only:`, held by
`testAPanelTheColumnHeadsDoesNotDrawItsOwnHeadingToo`) · `G2-05`/`K-035` the unbalanced
cursor pushes · `G2-02` `.lumenHeading` at 53 headers · `G2-11` `LumenCapsLabel` at one
size · `G1-08` three row pitches → one `Lumen.rowGap` · `G1-10` the panels' raw radii and
font calls · `G2-08` the animations over the 120 ms ceiling (three motions now) ·
`I1-05` `table` not promoting on hit · `A2-01`/`L-01` the gesture epoch · `C1-04` halation
Size and Redness (= C2-05, landed `f67582b`).

## Corrections to the audit

**J1-02 named the wrong callers.** It said `photo_fts` write failures reach `setRating`
and `setLabel` and surface as the culling write's "Could not save the flag or rating".
They do not. A rating is not in the text index — the FTS columns are filename, ext,
camera, lens, job and keywords — and `setRating`, `setLabel` and `setFlag` all go through
`batchUpdate`, which never reindexes. The first version of the test asserted the audit's
claim and failed, which is how the claim got checked.

The finding narrows and survives: the seven paths that DO reindex are `upsertPhoto`,
`setJob`, `scan`, `setMetadata` (both forms), `addKeyword` and `removeKeyword`. So the
real failure is a keyword the photographer typed, a job name, or the EXIF backfill
mid-scan — quieter than a rating keystroke and no less wrong, since all three are
committed to `main` before the index is touched.

**The automated triage was worse than useless.** Asking "does any file name this finding
id" reported F1-01, F3-04, F4-01, F4-02 and J1-01 as unmarked; all five verify as fixed.
Fixes in this project name the defect, not the audit row — which is the right habit and
means an id-based sweep can only ever mislead.

## Still open, ranked

**S2, with a mechanism named and no owner yet**

- `J1-03` `flushSidecars` writes from a stale in-memory read · `J1-04` `close()` does not
  back up · `J1-05` the grid query has no LIMIT and no debounce.
- `B1-04…08` the colour-science group (band ring authority, Density's hue rotation,
  the H-K term's magnitude, B&W level normalisation, band naming). Each moves pixels
  and each wants its own proof ceremony.
- `C1-01…08` the film group, minus the four that landed.
- `F1-02…06`, `F4-03…06`, `F5-01…03` the mask-canvas and mask-panel groups.
- `G1-01/02/04/05/06` the layout truncations. These need MEASUREMENT at 320/380/520 pt
  and cannot be verified from source; they are the one group where the audit's evidence
  is stronger than anything this pass could add without a running app.
- `L-02` the coalescing suite is green under L-01 because every fixture drives one key ·
  `L-04` the "your build is untouched" alert on the path where it is not.

**S3** — 37 rows, none of them load-bearing. `A2-12` (the coalescing window is 1.2 s
where docs/12 §12.10 says 2 s) is verified still 1.2 and is a one-constant change nobody
should make without deciding which document is right.

**Two found while landing, not by the audit**

- `N-005` `plateSeed(channel:)`'s three "independent" fields correlate at
  r ≈ 0.088 / 0.044 / −0.040 over 16 384 samples.
- `N-006` `HalationProfile.normalizedWeights` exists and neither renderer uses it, so
  Halation Amount is scaled by the raw bounce sum 1.75. The two paths agree, so it is a
  calibration question and not a parity break.
