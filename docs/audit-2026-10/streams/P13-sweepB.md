# P13-sweepB — September S2/S3 sweep: grade/colour panels, design system, keymap, catalog, delivery, crop, updater, recipe format

Branch: `worktree-agent-aa56ce42a3bca3fa1`, on `claude/jolly-sagan-k7ch7z` at 0896556.
Sources: `docs/audit-2026-09/w2/{B2,B3,G2,G3,J1,J2,J3,K-area,L,M}.md`, `ledger.md`,
`w3/dispositions.md` and `STATUS.md`. Each row was checked against the code at 0896556. I did
not search for row ids, because fixes in this repo name the defect and not the row.

Local checks: `swift build --build-tests --scratch-path /tmp/lumen-build-p13` is clean.
These suites are green: LibraryQueryPacing, WorkspaceEntry, Workspace, Catalog,
SidecarAndIngest, SidecarReseed, RecipeCodecTolerance, CanonicalJSON, Zone*, CullUndoScale,
LastValueMemo, Crop* (62), ControlIndex, KeyGrammar, PasteSettings, LookRenderPresetDoor,
PointColorPick, MixerRingPress, UpdaterMainActor, ColorBalanceContract, ColorScience,
GradeLuminanceInversion and LibraryFilter. `scripts/gen-fixtures.py --check` passes.
`scripts/check-swift-surface.py` exits 0. Every LumenApp change is source-verified only, and
each one is pinned by a LumenCore-lane test that reads the source as text with comments
stripped, so these checks run on Linux.

**Proof records moved by this stream: none.** No commit touches a render stage that a
proof record exercises. M-03 changes the decoded pivots only for malformed foreign
arrays, and M-04 adds fixture cases without changing any existing fingerprint.

## Fixed in this stream

| Row | Sev | Status | Commit | Red with the fix substituted out | Records |
|---|---|---|---|---|---|
| J1-05 / K-055 search field re-ran the grid query per keystroke | S2 | FIXED (debounce half; the LIMIT half is REFUTED) | 010595b | 5 of 6 | none |
| K-029 ⌘K → Lens Corrections armed the crop rectangle with no panel | S2 | FIXED | d7e966c | 3 of 7 | none |
| M-02 row text kept a newer build's version | S2 | FIXED | 505f7c0 | 3 assertions | none |
| M-03 / K-059 short pivot array padded unsorted | S2 | FIXED | 7f81379 | 5 assertions | none |
| J2-02 undo half: 3 whole-roll copies per photo | S2 | FIXED (the way in had already landed) | 8dbe6a9 | 3 separate substitutions, each red | none |
| B3-04 mixer ribbon rebuilt per event | S2 | PARTIAL (ribbon memo; ring Canvas not made Equatable) | 92c2e2b | 2 of 3 | none |
| KG-04 locked crop at the floor broke on an angle change | S2 | PARTIAL (`reangled` fixed; the 60:1 typed ratio is a DECISION) | ce89724 | 72 assertions | none |
| K-034 updater blocked main on ditto/codesign | S2 | FIXED (blocking half; L-04 had fixed the message) | fd99e29 | 5 assertions | none |
| G3-04 masking flag raisable past its entry verb | S3 | FIXED (guard test) | 669aaa0 | 1 of 8 | none |
| G3-05 menu arity guard blind to ForEach / second file | S3 | FIXED | 525672c | 1 | none |
| G3-07 palette "lut"/"cube" → Film Lab | S3 | FIXED | 67efe3c | 2 | none |
| M-06 Paste Settings left the old version stamp | S3 | FIXED | b629b36 | 2 | none |
| M-04 Python mirror missed the lut/grain strips | S3 | FIXED (two fixture cases added; existing cases byte-identical) | 7609cd3 | Swift replay red; the Python self-check also refuses | none |
| B3-09 point-colour eyedropper armed with no photo | S3 | FIXED | 2177e4a | 2 | none |
| KG-05 "Original" read back as "1.626" | S3 | FIXED | 0f0cb4f | 1 | none |
| B3-05 double-click reset moved a handle first | S3 | FIXED | 42696cc | 1 | none |
| K-081 colour-balance semantic contracts owed | S3 | FIXED (tests only; the engine was already right) | 02c8098 | 56 assertions; the old three-moves test stays green under the same substitution | none |
| (found) undo of a cull under a lit filter left the grid stale | — | FIXED | 3feea51 | 1 | none |

The red/green detail for each fix is in its commit body.

## The table: every S2/S3 row in scope

FS means FIXED-SINCE, followed by the mechanism. Rows marked "→ P7" or "→ P9" belong to
those streams.

### B2 — grading
| id | sev | claim | state |
|---|---|---|---|
| K-049 | S2 | grade pivots are `[0.33, 0.67]`, which is −4.38/+0.38 EV against the spec's −2.0/+1.5 | STILL-OPEN, `RecipeLook.swift:246`. Pixel-moving → DECISION 1 |
| K-081 | S3 | colour-balance contracts are owed | FIXED 02c8098 |
| B2-01 | S2 | the Brilliance limiter reports "nothing to limit" | FS: the fix wave landed it. `GradeEngine.swift:1040` notes the 64× ceiling, and `BrillianceMonotoneTests` pins it |
| B2-02 | S2 | the wheel paints SwiftUI HSB while the engine applies OKLab | FS: `wheelColors` is built from `Lumen.hueColor`, which is OKLCh (`LumenControls.swift:2043`) |
| B2-03 | S2 | a tint moves luminance by up to 0.15 EV and drives shadows negative | STILL-OPEN: `GradeEngine.swift:733` still translates a,b at constant L, and the header claim is still false. Pixel-moving → DECISION 2 |
| B2-04 | S2 | at Blending 0 the Luminance ring and Brilliance are inert | STILL-OPEN: no realised-strength readout exists. UI direction → DECISION 3 |
| B2-05 | S3 | the zone strip is drawn on a fixed 14 EV axis | STILL-OPEN (`LookPanel.swift:120`). NOT-FIXED, because it has to land with A1-03's Zones-panel axis (tone stream) or the two panels disagree |
| B2-06 | S3 | wheel modifier/keyboard grammar; printer lights have no coarse/fine step | STILL-OPEN → DECISION 4 |

### B3 — colour panel
| id | sev | claim | state |
|---|---|---|---|
| K-042 | S3 | "All bands" readout is a mean, and the thumb springs back | FS: `GroupMove` (LumenCore), the same fix as B3-01 |
| K-095 | S3 | the eyedropper has never been exercised by a human | NEEDS-MAC |
| B3-01 | S2 | All bands destroys the spread | FS: `GroupMove.moved` translates rigidly (`ColorPanel.swift:745-787`) |
| B3-02 | S2 | a click anywhere in the ring throws a handle | FS: `MixerHueRing.grab` hit test |
| B3-03 | S2 | `.pointColor(index:)` has no caller | FS: `tapSwatch` → `beginPick(.pointColor(index:))` |
| B3-04 | S2 | ribbon and ring rebuilt per event | PARTIAL 92c2e2b. The ring's 180-wedge Canvas and its closure-holding views are still not Equatable |
| B3-05 | S3 | double-click reset moves a handle first | FIXED 42696cc |
| B3-06 | S3 | the ring cannot select a band | STILL-OPEN. A press inside the ring is now inert (B3-02); routing it to `dominantBand` → DECISION 5 |
| B3-07 | S3 | chips set a cursor but have no hover paint | STILL-OPEN: `ColorPanel` has 0 `lumenHoverable` sites. Visual → DECISION 5 |
| B3-08 | S3 | `PointColorSwatchTests` cannot fail at the call site | STILL-OPEN. This is test hygiene (P11's area), so I left it for them |
| B3-09 | S3 | the point-colour eyedropper arms with no photo | FIXED 2177e4a |
| B3-10 | S3 | Point Colour has no Visualize Range | STILL-OPEN. Needs a render stage → DECISION 5 |

### G2 — design system
| id | sev | claim | state |
|---|---|---|---|
| K-006 | S2 | control-register bundle | CHANGED: radii are tokens (one numeric `cornerRadius:` left), autoName and the Kelvin axis are fixed. What remains is G2-07 and G2-10 |
| K-035 / G2-05 | S3/S2 | cursor push/pop unbalanced | FS: `LumenCursorModifier`, one balanced modifier for all three cursors |
| G2-02 | S2 | `.lumenHeading` dead | FS (U1; w3 dispositions) |
| G2-04 | S2 | 198 raw font sizes | FS: about 35 raw against 234 token uses, with a ratchet |
| G2-06 | S2 | elevation names dead | FS (w3) |
| G2-07 | S2 | hover/focus are one-file systems | CHANGED: `lumenInteractive` and `lumenFocusRing` exist (the U1 half), but there are only 5 `lumenInteractive` call sites. The U5 sweep → DECISION 6 |
| G2-08 | S3 | animations over 120 ms | FS: three named motions in `LumenMotion`; `motionFold` 0.28 and `motionReadout` 0.22 are deliberate tokens |
| G2-09 | S2 | no HUD material | FS: `lumenHUD`/`hudFill` |
| G2-10 | S3 | 4 pt grid violated | STILL-OPEN: `spacing:` 6×60, 2×27, 3×21, 5×15, 1×12, 10×5. Visual → DECISION 6 |
| G2-11 | S3 | `LumenCapsLabel` in three sizes | FS (w3) |
| G2-12 | S3 | glyph radii off the ladder | REFUTED (ledger: 2.5 on an 8 pt box is correct) |

### G3 — keymap
| id | sev | claim | state |
|---|---|---|---|
| K-005 | S2 | no next/previous-mask key; no held solo | STILL-OPEN (0 hits). Choosing a key → DECISION 7 |
| K-021 | S2 | ⌘C/⌘V/⌘A taken from text fields | FS: the `TextEditingFocus` carve-out in the action, ⌘X Cut bound, and `PasteboardCarveOutTests` |
| K-029 | S2 | ⌘K Lens arms the crop rectangle | FIXED d7e966c |
| K-037 | S3 | arity guard top-level only | FS; residual G3-05 FIXED 525672c |
| K-062 | S2 | Cull is a one-way door | FS (edge rail) |
| K-094 | S3 | Speed Edit not wired | STILL-OPEN → DECISION 7 (moves S/H to key-up) |
| K-104 | S2 | decided keymap | FS in code. docs/12 §12.3 still says `F` is Focus peaking (`docs/12-spec-ux.md:249`) and gives the old `S`/`⇧S` meanings (`:268`) → DECISION 7 |
| G3-01 | S2 | ⌘B attached twice | FS: one site, `LumenApp.swift:278`; the attachment test lists rather than sets |
| G3-02 | S2 | `R` inside masking arms the crop | FS: `toggleCropTool` leaves masking (`WorkspaceEntry.swift`) |
| G3-03 | S2 | four sidebar chords die with ⌥⌘S | FS: ⌘G, ⇧⌘G, ⇧⌘K and ⌘B moved to `LumenCommands`. The proposed structural "shortcut only in an always-mounted file" test was not added |
| G3-04 | S3 | `setMasking(true)` not guarded | FIXED 669aaa0 |
| G3-05 | S3 | arity guard blind to ForEach and other files | FIXED 525672c |
| G3-06 | S3 | 29 key actions have no menu item; the reference sheet has no Escape | STILL-OPEN → DECISION 7 |
| G3-07 | S3 | palette "lut"/"cube" | FIXED 67efe3c |

### J1 — catalog
| id | sev | claim | state |
|---|---|---|---|
| K-017 | S2 | losing the catalog is announced in 10 pt hideable text | STILL-OPEN (`ContentView.swift:412`) → DECISION 8 |
| K-019 / J1-04 | S2 | nothing backs up or prunes | FS: J1-04 landed (`BackupRetention`, `BackupPolicyTests`) |
| K-055 / J1-05 | S2 | grid query has no LIMIT and no debounce | Debounce FIXED 010595b. LIMIT REFUTED: `libraryOrder` is the whole roll |
| K-056 | S2 | first open runs as one `queue.sync` | STILL-OPEN (`CatalogService.swift:255`). NOT-FIXED: it needs restructuring plus a measurement at 5k and 50k frames |
| K-057 / J1-06 | S3 | FTS is prefix-only, the LIKE fallback is infix | STILL-OPEN (`CatalogStore.swift:3794` vs `:3891`) → DECISION 9. The FTS tests do run on this SQLite; the fallback branch still has no test |
| J1-02 | S2 | `ftsEnabled` is a `let` | FS (w3) |
| J1-03 | S2 | stale flush | FS d386442 |

### J2 — culling
| id | sev | claim | state |
|---|---|---|---|
| K-066 | S3 | grid and decode never profiled | CHANGED: the mechanism (J2-06) is fixed, but nothing has been measured. STILL-OPEN as a measurement |
| K-101 | S3 | `frame_score` has no writer | STILL-OPEN (feature) |
| J2-02 | S2 | a cull copies the roll once per photo | FS for the way in (`mutateTargets` assigns once). Undo half FIXED 8dbe6a9; stale-grid undo FIXED 3feea51 |
| J2-03 | S2 | live counts from three corpora | FS: `CatalogStore.facetCounts(for:)`, one `FacetCounts` |
| J2-04 | S2 | stacks invisible in the grid | STILL-OPEN → DECISION 10 |
| J2-05 | S3 | assisted-review filters unwired | STILL-OPEN (`CatalogStore.swift:932-934`; no writer, no caller) → DECISION 10 |
| J2-06 | S3 | a cursor move rebuilds the id list | FS: `RollCursor`, and `CullScaleTests` forbids `map(\.id)` and linear searches |

### J3 — delivery (fixes belong to P7)
| id | sev | claim | state |
|---|---|---|---|
| K-024, K-025, K-026, K-096 | S2 | resize, edge clamp, metadata base, degraded kernel | FS (verified in J3 September; code unchanged since) |
| K-065 | S2 | export grain laid before resize | FS 6425f60 |
| K-033 | S2 | export holds the actor for the whole batch | CHANGED: held per file. Cancel landed (`cancelExport`); the per-file stall remains (`RenderCoordinator.swift:475`) → P7 |
| K-051 | S2 | perceptual soft proof clips at L ≥ 1 | STILL-OPEN (`Perceptual.swift:333`). Pixel-moving soft-proof work for the colour/export owner → DECISION 11 |
| K-067 | S3 | export never profiled | STILL-OPEN |
| K-100 | S2 | verified-copy ingest not built | FS: `VerifiedCopyDriver` ("Ingest copies bytes") |
| K-103 | S3 | watermarking exists but docs/11 says it does not | CHANGED (docs only) |
| J3-03 | S2 | export does not gamut-map to the destination | FS: `deliveredProof` is in the export plan (`PipelineRenderer.swift:387-398`) |
| J3-04 | S2 | keywords never written | STILL-OPEN (no `IPTCKeywords`; the toggle has no help text) → P7 |
| J3-05 | S2 | `{date}` is the creation date | STILL-OPEN (`AppStateActions.swift:463`) → P7 |
| J3-06 | S2 | per-channel output sharpen | STILL-OPEN (`PipelineRenderer.swift:2300`). Pixel-moving → DECISION 11 |
| J3-07 | S2 | export cannot be cancelled; loupe freezes | PARTIAL: cancel is FS; the per-file stall is open → P7 |
| J3-08 | S3 | no `{seq}` token | STILL-OPEN → P7 |

### K — crop/geometry
| id | sev | claim | state |
|---|---|---|---|
| K-023 | S2 | ratio lock broken by an angle change | FS for a single photo (`reangled`). The multi-selection case is KG-01 → P9 |
| KG-01 | S2 | batch geometry uses the primary's frame | skipped (P9 owns it) |
| KG-02 | S2 | `O` while cropping | FS (`enterMasking`) |
| KG-03 | S2 | cropped portrait never reconciles its orientation | STILL-OPEN (`AppState.swift:317`, `LoupeView.swift:1164`). NOT-FIXED: the honest fix learns orientation from the decoded extent upstream of the crop (pipeline plus app), which is more than a local hunk |
| KG-04 | S2 | the floor breaks a lock | PARTIAL ce89724 (`reangled`). `centred(aspect: 60)` on 3:2 → DECISION 12 |
| KG-05 | S3 | "Original" reads as a decimal | FIXED 0f0cb4f |
| KG-06 | S3 | dead geometry fields in `renderIdentity`; two Resets | STILL-OPEN → DECISION 13 (moves `recipe_fp`) |
| KG-07 | S3 | keyboard and overlay half of the crop grammar | STILL-OPEN → DECISION 12 |

### L — state and updater
| id | sev | claim | state |
|---|---|---|---|
| K-030 / L-06 | S2/S3 | zoom publishes on `AppState` per pinch | FS: zoom lives on the viewport, guarded (`LoupeView.swift:158-163`, `ZoomBroadcastTests`) |
| K-034 | S2 | updater blocks main | FIXED fd99e29 |
| K-038 | S2 | shared coalescing keys | CHANGED: curve points carry their index (938f17d), and gestures coalesce by epoch. `"crop"`, `"geometry.reset"` and `"geometry.revert"` still fold two keyed edits inside 1.2 s, which is the documented window rule |
| L-02 | S2 | the coalescing suite drove one key | FS (`HistoryCoalescingTests` two-key gesture cases) |
| L-03, L-04 | S2 | updater identity and message | FS (w3 dispositions) |
| L-05 | S3 | `HistoryStack` snapshots unwired | STILL-OPEN (`HistoryStack.swift:228-235`) → DECISION 14 |
| L-07 | S2 | do not split `AppState.swift` | NOT-A-DEFECT (a proposal; the file is still whole) |

### M — recipe format
| id | sev | claim | state |
|---|---|---|---|
| K-043 / M-05 | S3 | Upright and `heal` round-trip unread, undocumented | STILL-OPEN → DECISION 13 |
| K-059 / M-03 | S2 | pivot padding | FIXED 7f81379 |
| M-02 | S2 | text vs column version | FIXED 505f7c0 |
| M-04 | S3 | Python mirror strips | FIXED 7609cd3 |
| M-06 | S3 | paste version | FIXED b629b36 |
| M-07 | S3 | `pipelineVersion` hashed into `recipe_fp` | STILL-OPEN → DECISION 13 |

## DECISIONS

These are not implemented, because each one changes pixels, the look of the app, or a
documented contract.

1. **K-049, grade pivots.** Deriving `GradingWheels.defaultPivots` from the documented
   −2.0/+1.5 EV through the engine's anchors gives `[0.5, 0.75]`, and moves every recipe
   that relies on the default pivots. **Records:** every grading-wheel and colour-balance
   zone record (`look.wheels.*`, `colorBalance.*` zone axes).
2. **B2-03, tint luminance.** Two options: restore the input luminance (or H-K brightness)
   after the a,b translation, or scale `maxABOffset` by L, which is darktable's shape.
   Either way, docs/05's "soft gamut clip permanently on" must be built or struck.
   **Records:** wheel hue/sat records.
3. **B2-04, honesty readout.** Publish `lumScale` and `brillianceScale` to the panel and read
   out the realised strength when the limiter binds, as the Highlights slider does. This
   moves no pixels but changes the UI.
4. **B2-06, wheel grammar.** ⌘ hue-only, ⇧ sat-only, ⌥ fine, a focus key 1–4, numeric
   entry. Printer lights need ⇧ coarse and ⌥ fine, which means moving channel selection
   off ⌃⌥⇧. Quarter-point steps need `PrinterLights` to become `Double`, which is a format
   change.
5. **B3-06, B3-07, B3-10, mixer and point-colour UI.** (a) Route a press inside the ring to
   `ColorEngine.dominantBand`. (b) Replace `.lumenClickCursor()` with
   `.lumenInteractive(radius: Lumen.radiusChip, on: <surface>)` at the five chip/button
   sites; the open question is which surface value to lift from. (c) Visualize Range is a
   render stage.
6. **G2-07, G2-10.** The U5 hover/focus sweep, and choosing a spacing scale (4/8/12/16)
   for 271 sites. Both are visual, and neither moves proof pixels.
7. **K-005, K-094, G3-06, K-104 docs.** (a) Pick a next/previous-mask key and a held-solo
   key. (b) Wire Speed Edit (S and H move to key-up). (c) Add menu items for the 29
   key-only actions, or generate the menus from `KeyGrammar`. (d) Add Escape to the
   keyboard reference sheet. A `.cancelAction` cannot go on the Done button, which already
   carries `.defaultAction`, so the choice is a hidden cancel button or `onExitCommand`;
   neither can be verified without a Mac. (e) Amend docs/12 §12.3's `F` and `S`/`⇧S` rows.
8. **K-017.** How loudly to announce "catalog unavailable": a sheet, or a persistent
   banner outside the hideable sidebar.
9. **K-057 / J1-06.** One search meaning for both branches: narrow the fallback to token
   prefix, or add infix to FTS. Whichever is chosen, test both branches by forcing the
   fallback.
10. **J2-04, J2-05.** A stack-count badge and expand control in the grid cell. For the
    assisted-review predicates: delete them, or surface them behind `hasFrameScores`.
11. **K-051, J3-06, export pixels.** A perceptual soft proof above L = 1, and a
    luminance-only output sharpen. Both change delivered pixels. P7 and the colour owner
    should decide.
12. **KG-04 remainder, KG-07.** A typed ratio above 20× the frame's is unrepresentable
    at the 0.05 floor: either cap `aspect(fromText:)` by the frame, or lower
    `minimumCropFraction`. KG-07 covers the guide cycle on `O` inside Crop, the shield
    opacity control, and a ⌘-drag ruler.
13. **KG-06, M-05, M-07, `recipe_fp` changes.** Strip `upright`, `removeCA` and `defringe`
    (and adopt the LUT tripwire for `heal`) in `renderIdentity`, and decide whether a
    `pipelineVersion` bump busts the cache. Each one changes `recipe_fp`, so it needs the
    fixtures ceremony, and the Python mirror must move in the same commit. Proof records:
    none (fingerprints, not pixels), but every cached preview is invalidated once.
14. **L-05.** Wire `HistoryStack` snapshots (an Edit-menu item plus persistence), or delete
    the four members and the "until snapshots ship" comment in `CatalogService`.
15. **Made in this stream, open to overrule.**
    - M-03: a padded pivot list that does not ascend falls back to the defaults whole. A
      full-length list that is out of order is sorted and spaced at the panel's 0.02 gap.
      A padded list that does ascend is kept, as the existing tolerance test pins.
    - J1-05: the debounce is 180 ms, matching the scopes. Clearing the text and lighting
      a chip are answered immediately.
    - K-029: jumping to Lens while the crop tool is armed now disarms it, the same as
      leaving the workspace. `⌘3` and the rail still arm it.
    - B3-05: a stationary press on a ring handle no longer moves the handle to the click
      angle. It only grabs.

## FOUND-WHILE-FIXING

- **Undoing a cull under a lit filter left the grid stale.** FIXED in 3feea51. Only the
  cull keystroke re-ran the catalog query. Undo restored the badges, but the frame's grid
  membership stayed as it was: an un-rejected frame stayed in a "Rejected" grid.
- **The LUT stage stream must touch three places in one commit.** They are Swift's
  `copy.look.lut = nil`, the Python mirror's lut clause (added here), and the
  `lutNoStageReads` fixture case, whose fingerprint equals the default only while no stage
  reads a LUT. `ControlIndexTests.testNoControlAnswersForALUTWhileNoStageReadsOne` stops
  asserting on that same day, so the "lut" alias can come back with its control.
- **"stdlib" in the task.** The only stdlib item I found is STATUS.md's third
  surface-checker false-finding class (stdlib method names colliding with in-tree
  declarations). That is checker hygiene, which belongs to P11; I did not touch it.
- **`check-swift-surface.py` counts braces inside string literals.** One of my tests
  searched for `"…currentAspectName: String {"`. That left CropDragTests' member index
  empty, and the checker exited 1, reporting four unrelated `frameAspect` arguments. I
  removed every brace literal from this stream's tests in 997f5e4, and the checker exits
  0. The checker itself is P11's: an unbalanced brace in any test's string literal
  silently truncates that type's member index.
- **`KeyGrammarTests` and `WorkspaceEntryTests` each carry a private copy of the
  comment stripper.** I copied it into three new test files as well, to keep this stream
  out of test-infrastructure files. Sharing one copy is a P11 item.
