# P12-sweepA — the September audit's open S2/S3 rows in tone, looks, detail, viewer, performance

Branch: `worktree-agent-ab968e194d942e42a`, on `claude/jolly-sagan-k7ch7z` at 0896556.
Scope: every S2/S3 row (and every K-row the W2 auditor re-verified) in
`docs/audit-2026-09/w2/{A1,A2,D1,D2,E1,E2,H1,H2,I1,I2,I3}.md`, plus L-02. Each row was
checked against the code as it is at 0896556, not against the ledger: the September
history is squashed into 99c3727 / 5047f1b, so a fix is found by reading the symbol the
row names, never by grepping the row id.

Local checks: `swift build --build-tests` clean; the suites named per commit are green;
the whole LumenCore suite was started once (build at 20219b8) but had not finished when the
run closed: under a load average of ~32 it was still in the C-suites after two hours, with 0
failures in the output flushed so far — so the whole-suite run is NOT a completed check; the
per-commit filtered suites are;
`scripts/check-swift-surface.py` exits 0; `scripts/recite-slider-inventory.py` re-pointed
the citations the DetailPanel change moved. LumenApp/LumenPipeline halves are
source-verified (they compile on macOS only).

## Fixed in this stream

| Row | Sev | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|---|
| I3-03 `Int(_:)` on a file-derived size traps at 4 of 5 sites | S2 | FIXED | c3d60a6 | guard removed → test TRAPS ("Double value cannot be converted to Int…"); bare `Int(` restored at two sites → scan fails naming both; 16/16 | none |
| E1-01 / K-028 Noise row reset stamps the primary's ISO baseline on the selection | S2 | FIXED | 762d5d8 | value resolved from another file (the panel's old shape) → 6 failures; 17/17 | none |
| E2-03 `estimatePSFSigma` √2 too wide, texture reads as the 2.0 ceiling | S2 | FIXED | ebc8ed3 | RT inverse restored → 4 failures (1.40–1.47×); every bump counted → 2 failures (exactly 2.0); 3/3 | none (no caller) |
| L-02 coalescing suite green under L-01 (one key per fixture) | S2 | FIXED (test) | 9edd638 | LumenAppTests, source-verified: `gestureEpoch: nil` → 96 steps not 1 | none |
| H1-02 before rendition stretched on cropped photos (+ a JPEG's before was a second tone map, found while fixing) | S2 | FIXED | 9435ebe | `Recipe(pipelineVersion:)` restored → 5 failures; 19/19 | none (viewer only) |
| H1-05 compare panes draw drafts nearest-neighbour | S2 | FIXED | e3fcd16 | old predicate restored → 1 failure naming the line; 7/7 | none |
| H1-06 `[`/`]` never reach the two-pane before/after; one-slot memo misses 100% and outlives key-up (half of K-031) | S2 | FIXED | 5b78a7c | plain `Image(decorative: image` restored → 1 failure; memo test macOS, source-verified | none |
| H1-03 window resize mints a render key + RAW decode per pixel | S2 | FIXED | 91d5474 | `ceil(drawn)` restored → 8 failures; 14/14 | none (viewer asks only) |
| D1-04 Paste Look always enabled; a copy with nothing selected empties the clipboard | S2 | FIXED | f31a890 | LumenAppTests, source-verified: `hasCopiedLook` absent (compile red); `.map` form → both clipboards empty | none |
| E2-07 `captureSharpen` ignores `auto == false` | S3 | FIXED | 922f7e1 | old guard + local strength restored → 1 failure; 2/2 | none (no caller) |
| D2-04 Feather tooltip "a twelfth" (measured 0.0407) | S3 | FIXED | dd24bf4 | "a twelfth" restored → fails at 2.05×; 12/12 | none |
| A1-05 tone comments state a shelf geometry the constants do not have | S3 | FIXED (comment + pinning test) | 3bbd605 | test holds the stated numbers; red against the old −5.9 | none |
| E1-06 colour-edge bar asserted at stale ISO literals | S3 | FIXED (test) | 9d9d099 | ISO 25600 anchor → 100: derived row fails (0.873 < 0.90), literal row would not; 9/9 | none |
| E1-08, E1-09, H2-10, D2-05, H1-04 stale comments | S3 | FIXED (comments) | 1cb4bc5 | comments only; existing guards hold the stated facts | none |
| K-061 `bakeChannelLUTs` would drop preserveLuminance + luma if wired | S2 | FIXED (removed) | 20219b8 | no caller; compiler is the guard | none |
| H1-08 before rendition denied the floor and the visible ceiling | S3 | FIXED | 11c4cbb | argument removed from renderBefore → 1 failure; 15/15 | none |

## The table — every S2/S3 row in the eleven files, as of 0896556

State key: **FIXED** here (SHA above) · **FIXED-SINCE** (mechanism named) · **STILL-OPEN** ·
**REFUTED** · **NEEDS-MAC** (cannot be verified or measured on this box) · **DECISION**
(open, and every fix changes pixels, a contract or a feel — see DECISIONS).

### A — tone (A1) and the slider contract (A2)

| Row | Sev | Claim | State |
|---|---|---|---|
| K-039 | S2 | Render Contrast linear where docs/04 says log | FIXED-SINCE — `SliderScale.log`, the row at `LookPanel.swift:1172` (fe3d38a) |
| K-040 | S2 | Zones ±3 track runs 2.5× past monotonicity | STILL-OPEN → DECISION D-3 (track still `-3...3`, hard ±5) |
| K-061 | S2 | `bakeChannelLUTs` uncalled, would drop coupling | FIXED 20219b8 (removed) |
| K-078 | S3 | Owner's Lightroom reference exports owed | STILL-OPEN (owner input, not code) |
| K-079 | S3 | Highlights/Shadows targets vs dt/RT owed | STILL-OPEN (no external target in tree) |
| K-080 | S3 | Temp-writes-its-Kelvin as a full-pipeline contract | NEEDS-MAC (display half closed; needs RAW fixtures) |
| K-091 | S2 | Rendered files get a second display transform | FIXED-SINCE — `Recipe.asImported` writes Linear for rendered files; residue is A1-04 |
| K-092 | S2 | `ZoneAdjust.wheel/.sat/.falloff` unread wire fields | CHANGED, still unread (panel no longer draws them); wire-or-remove is a format decision |
| A1-01 | S2 | Contrast +100 burns 1.9 stops at the anchors | FIXED-SINCE — anchor-denominated reach (9bcac9f, V7-verified; moves pixels, re-pinned then) |
| A1-02 | S2 | Brights' positive half renders one picture | STILL-OPEN → DECISION D-4 |
| A1-03 | S2 | Whites/Blacks silently drag every Zones pivot | STILL-OPEN → DECISION D-5 (`normalizedAxis` still on live anchors) |
| A1-04 | S3 | Linear preset ignores the anchors; Highlights half-shelf on JPEGs | STILL-OPEN → DECISION D-6 |
| A1-05 | S3 | Comments claim the end shelves start where the zonal ones saturate | FIXED 3bbd605 (comment + pinning test); the geometry change is DECISION D-7 |
| K-041 | S3 | `wand` passed by 0 call sites | FIXED-SINCE — the parameter is deleted (`LumenControls.swift:507` says why) |
| A2-02 | S2 | Undo cut by a stopwatch, not the gesture | FIXED-SINCE — gesture epoch (L-01). The converse half (two quick drags of one slider fold) is kept by design and pinned (`testDifferentGesturesStillFollowTheOlderKeyAndWindowRule`) |
| A2-03 | S2 | Double-clicking a track costs two undo steps | STILL-OPEN — the press-jump and the reset are two gestures with two epochs and two keys. Fix lives in `LumenControls.swift` (slider stream's file); not touched |
| A2-04 | S2 | ↑/↓ on a focused slider do nothing | FIXED-SINCE (W3: `onKeyPress(.upArrow/.downArrow)` + cross-file check) |
| A2-05 | S2 | Five keys carry two decisions | PARTIAL: curve points per-index (`CurveEditing.pointCoalescingKey`), grain keys split (C2-07), denoise reset its own key (762d5d8). STILL-OPEN: `wb.preset` for as-shot and illuminant (`BasicPanel.swift:436/443`), `geometry.crop.aspect` for every ratio (`CropPanel.swift:698`) — undo granularity is a feel decision, DECISION D-8 |
| A2-06 | S2 | Mask-canvas release commits with no key | FIXED-SINCE — the release commit runs inside `onEnded` before the `defer { sliderGestureChanged(false) }`, so it carries the drag's epoch and the epoch clause folds it whatever the key |
| A2-07 | S3 | Readout scrub gain pinned to a 426 pt track | STILL-OPEN (`LumenControls.swift:618`, slider stream's file) |
| A2-08 | S3 | Speed Edit fine 0.1 vs slider 0.25, comment says they match | STILL-OPEN → DECISION D-9 (docs/12 §12.4 says Shift ×10 / Alt fine — a third answer) |
| A2-09 | S3 | docs/12 §12.5's arithmetic examples are refused | STILL-OPEN (doc amendment) |
| A2-10 | S3 | ⌥ does nothing on any slider | STILL-OPEN (feature) |
| A2-11 | S3 | Speed Edit is model-only | STILL-OPEN (feature; 0 callers) |
| A2-12 | S3 | Coalescing window 1.2 s vs docs 2 s | DECISION (recorded by P4, `streams/P4-curves.md`) |
| L-02 | S2 | Coalescing suite green under L-01 | FIXED 9edd638 (app-level two-key fixtures) |

### D — looks (D1) and effects (D2)

| Row | Sev | Claim | State |
|---|---|---|---|
| K-010 | S3 | Develop presets carrying masks | STILL-OPEN (blocked on a mask register; tripwire `SavedLookTests` still correct) |
| K-027 | S2 | Looks header Reset applies a second tone map | FIXED-SINCE (per-target starting render; and D1-01, S1, closed the travel doors) |
| D1-02 | S2 | Rename Look unreachable | FIXED-SINCE — row menu Apply/Rename/Delete (`LookPanel.swift:425-441`), `LookBrowserVerbTests` |
| D1-03 | S2 | Save-over and Delete destroy without asking | FIXED-SINCE — "Replace" button + inline warning; in-row Delete confirmation |
| D1-04 | S2 | Paste Look always enabled; copy with no selection clears | FIXED f31a890 |
| D1-05 | S2 | No look Amount on the wire | FIXED-SINCE — `LookSubset` amount, `LookAmountTests` |
| D1-06 | S2 | Look browser: no thumbnails, groups or search | STILL-OPEN (feature; `look.grp` still unwritten) |
| D1-07 | S3 | `look.lut` lights the Looks dot with no way to set it | STILL-OPEN — deliberately left: the October plan's Phase 3 builds the LUT stage, which makes the dot right again |
| D1-08 | S3 | Unknown preset name renders Neutral silently | STILL-OPEN (`DisplayTransform.preset(named:)` `default: .neutral`, case-sensitive) |
| D1-09 | S3 | Delete Look reports success on a failed write | STILL-OPEN (`CatalogService.deleteLook` still returns Void; no honest failure fixture on this box) |
| K-090 | S2 | Dehaze sky guard reference-only on the GPU | STILL-OPEN → DECISION D-1 (P8 spec) |
| K-099 / D2-01 | S2 | Texture selects by contrast, not scale | STILL-OPEN → DECISION D-2 (P8 spec) |
| K-058 (Texture clause) | S2 | GPU Texture gain has no ±4 EV limit | FIXED-SINCE (`Kernels.swift` clamps; d495ff6 fixed the >±100 local clamp) |
| D2-02 | S2 | Presence goldens measure at a frame/longEdge pair no renderer produces | STILL-OPEN — `KernelGoldenTests` still passes `longEdge: 1600` on 64-128 px buffers; `structureRadius` floors at 2 vs the reference's 1. The floor change moves GPU pixels below ~400 px; this is the prerequisite of D-2 and belongs in that landing |
| D2-03 | S2 | Vignette ships 2 of 5 controls; Midpoint ≡ Feather on this geometry | STILL-OPEN → DECISION D-10 |
| D2-04 | S3 | Feather tooltip overstates Feather 0 by 2.05× | FIXED dd24bf4 |
| D2-05 | S3 | `vignetteInnerRadius` doc describes a wiring that no longer exists | FIXED 1cb4bc5 (comment) |
| D2-06 / I2-06 | S3 | Reference vignette takes no crop | STILL-OPEN — and wider now: the GPU (cddbd3d) maps the ellipse through crop, flip, rotation and integral bounds; a crop-only reference would still differ on any rotated crop. Wants the reference geometry stage `RenderCoordinator` already defers |

### E — detail and denoise (E1, E2)

| Row | Sev | Claim | State |
|---|---|---|---|
| K-028 / E1-01 | S2 | Noise row reset stamps primary's ISO baseline | FIXED 762d5d8 |
| K-070 | — | AI denoise integration | STILL-OPEN (phase 3 feature) |
| K-074 | — | `contributingNoiseScale` parked | STILL-OPEN by decision |
| K-076 | S3 | capture/AI amounts measurable only on macOS | NEEDS-MAC |
| K-086 / E1-02 | S2 | `.ai` on a rendered file removes the denoise that ran | PARTIAL by P8 (089ab26: tooltip); engine half is P8's DECISION 2 |
| K-087 / E1-05 | S3 | `ReferenceRenderer.render` has no S3 | STILL-OPEN → DECISION D-11 (moving S3 inside changes every reference render of a default recipe) |
| E1-03 | S2 | Noise profiler: no caller, biased | PARTIAL by P8 (7ee0bc4) |
| E1-04 | S3 | Denoise quality gate cannot judge the R6 decision | STILL-OPEN (proof-frame redesign; test-hygiene stream's ground) |
| E1-06 | S3 | Stale ISO labels in the colour-edge test | FIXED 9d9d099 |
| E1-07 | S3 | Four Tier 1/2 surfaces with no caller | STILL-OPEN (`noiseOnlyView`, `LocalNoiseAdjust`, `shouldAutoQueue` still uncalled; wire-or-delete) |
| E1-08 | S3 | DenoiseEngine §12.7 header bullet stale | FIXED 1cb4bc5 |
| E1-09 | S3 | "serialize sparsely" comment false | FIXED 1cb4bc5 (comment; making it sparse would move every fingerprint again) |
| K-075 / K-088 | S2 | `capture.radius` stored, not applied; RL uncalled | STILL-OPEN (wire-or-remove). E2-03 and E2-07 make "wire" safe |
| K-082 / K-097 / E2-04 | S2 | Sharpen radius in render pixels | FIXED-SINCE (frame-denominated sigma; STATUS "CLOSED in the final run", five `sharpen.*` records moved then) |
| E2-01 | S2 | Output sharpening is per-channel USM, fringes colour | STILL-OPEN → DECISION D-12 (changes every exported file with output sharpening) |
| E2-03 | S2 | `estimatePSFSigma` √2 too wide, ceiling on texture | FIXED ebc8ed3 |
| E2-05 | S2 | Radius tooltip says no view shows export sharpening | FIXED-SINCE (rewritten with E2-04's closure, `DetailPanel.swift:306-314`) |
| E2-06 | S2 | Reference and GPU build S12's fine band from different images | STILL-OPEN → DECISION D-13 |
| E2-07 | S3 | `captureSharpen` ignores `auto == false` | FIXED 922f7e1 |
| E2-08 | S3 | Capture toggle tooltip claims no test exists | FIXED-SINCE (`captureToggleHelp` rewritten to the precise residue) |

### H — viewer, lights-out, scopes (H1, H2)

| Row | Sev | Claim | State |
|---|---|---|---|
| K-031 | S2 | `InspectionGain` full-res CI render inside `body`, one-deep memo, never cleared | PARTIAL — memo and key-up clearing FIXED 5b78a7c; the synchronous transform in `body` remains (STILL-OPEN) |
| K-032 | S2 | Draft ladder taught the asked size | FIXED-SINCE (W2 verified all three clauses) |
| K-083 | S3 | Loupe not Metal/EDR | STILL-OPEN (phase 3 HDR groundwork) |
| H1-02 | S2 | Before rendition stretched on cropped photos | FIXED 9435ebe |
| H1-03 | S2 | Resize mints a key and a decode per pixel | FIXED 91d5474 |
| H1-04 | S2 | Survey cells draft at the settle's resolution under a "512" comment | NOT-A-DEFECT as a cost (the settle is the cell's own 512-2048 extent, ladder-governed); stale comment FIXED 1cb4bc5 |
| H1-05 | S2 | Compare panes use the replaced resampling predicate | FIXED e3fcd16 |
| H1-06 | S2 | `[`/`]` no-op in the two-pane modes | FIXED 5b78a7c |
| H1-07 | S3 | `record` re-derives the answer without the caller's floor | STILL-OPEN — traced: while `maxUpscale == 1` the floor equals the ask at fit, so the deafness has no observable consequence today; the fix (`record(…notBelow:)`) is right but has no test that can go red until the floor and the ask differ |
| H1-08 | S3 | Before rendition denied the floor and the visible ceiling | FIXED 11c4cbb |
| H1-09 | S3 | `ClippingOverlayView.fullFrame` unreachable | STILL-OPEN → DECISION D-14 (wire to ⌥ or delete) |
| K-089 | S2 | `⇧H` not CFA; proxy; no sweep driver; no `O` overlay | NEEDS-MAC / STILL-OPEN (all four parts unchanged) |
| K-098 / H2-04 | S3 | Waveform blank columns | FIXED-SINCE (`ScopeReadout.traceColumns`, `ScopeMathTests`) |
| H2-01 | S2 | Clipped % on a 512 px box average | FIXED-SINCE (`ScopeTap` counts at native resolution) |
| H2-02 | S2 | Readout-space picker never reaches the bins | FIXED-SINCE as specified (space passed through; spaces the 8-bit sRGB tap cannot honour are refused and said so — `scopeTransform(requested:)`) |
| H2-03 | S2 | Scopes frozen for the whole of every drag | STILL-OPEN (`LoupeView.swift:1414` feeds settles only). M-size, LumenApp-only: draft frames need a per-frame hook in `PhotoRenderModel.load`, a throttle and a draft provenance; not attempted without a Mac to tune it |
| H2-05 | S3 | `⇧H` cached per file but the decode is recipe-dependent | STILL-OPEN (`clippingStatistics` decodes with the edit's recipe) |
| H2-06 | S3 | Raw histogram binned and never drawn | STILL-OPEN (feature) |
| H2-07 | S3 | No tests for waveform/parade/vectorscope | FIXED-SINCE (`ScopeMathTests`, 30 cases) |
| H2-08 | S3 | Headline "% white" is luma | FIXED-SINCE (headline and triangle are one computation) |
| H2-09 | S3 | `J` unbound; one overlay end at a time | STILL-OPEN (keymap/feature) |
| H2-10 | S3 | Skin-line header calls a resolved discrepancy open | FIXED 1cb4bc5 |

### I — pipeline, parity, caches (I1, I2, I3)

| Row | Sev | Claim | State |
|---|---|---|---|
| K-047 | S1 | (re-verified) stale-table door | CHANGED (W2), residuals S3 — not re-opened here |
| K-060 | S2 | Untouched recipe not a passthrough (finish table) | STILL-OPEN → DECISION D-15 (a passthrough moves every default render) |
| K-063 | S2 | Region render pays a whole-sensor decode | STILL-OPEN, NEEDS-MAC (decode before raster rect, `PipelineRenderer.swift:539-543`) |
| N-002 / I1-01..05 | S2/S3 | settle join/steal, probe, counters, settle loop, promote-on-hit | FIXED-SINCE (`joinedBakes`/`deferredBakes`, `anyBakePending(for:)`, `inFlightIdentity`; closed at db43c41 per ledger) |
| I1-06 / I1-07 | S2 | ContentView / EditRevision rule | FIXED-SINCE (read moved to `MaskFloatingPanelHost`; `EditRevisionRuleTests`) |
| I1-08 | S3 | Proofed map uncacheable on the draft path | STILL-OPEN (perf; the poisoning argument makes it a careful change) |
| K-048 | S2 | GPU log plane has no floor | FIXED-SINCE (W2 verified) |
| K-050 | S2 | fp16 log plane quantum exceeds presence ε | STILL-OPEN → DECISION D-16 (moves presence pixels) |
| I2-01 | S2 | `blendMaskMode` in no roster | FIXED-SINCE (`KernelRosterTests`) |
| I2-02 / N-003 | S2 | Halation GPU pedestal vs reference smoothstep | STILL-OPEN — film stream (P6) |
| I2-03 | S2 | Spatial parity bar 0.25 prints nothing | PARTIAL — now prints `SPATIALPARITY …` every run; the bar is still 0.25 awaiting the lane's number (NEEDS-MAC) |
| I2-04 | S2 | No grain GPU↔reference comparison | FIXED-SINCE (`testGrainMatchesTheReferenceRenderer`) |
| I2-05 | S2 | Plate-builder test never checks `renderPixelsPerCell:` | FIXED-SINCE (`GrainParityScanTests`) |
| N-005 | S3 | Plate seeds correlate | REFUTED (I2: 57th percentile of a proper null) |
| N-006 | S3 | `normalizedWeights` unused | STILL-OPEN — film stream (P6) |
| K-036 / I3-02 | S2 | Decode budget unreachable | FIXED-SINCE (budget corrected to the reachable 1344 MiB; STATUS) |
| K-068 | S3 | Cold vs warm open unmeasured | STILL-OPEN (I3-06 is its mechanism) |
| I3-01 | S2 | Settle filed at the fit rung whatever its size | FIXED-SINCE (`recordDeveloped` reads the image's extent) |
| I3-03 | S2 | `Int(_:)` traps on a file-derived size | FIXED c3d60a6 |
| I3-04 | S3 | `invalidatePreviews` has no caller | STILL-OPEN (persistence path; P2's file) |
| I3-05 | S3 | Memory LRU not keyed by recipe at the fit rung | STILL-OPEN (`ThumbnailLoader.Key` gained `sourceIdentity`, not a fingerprint) |
| I3-06 | S3 | Decode HUD discards every hit | STILL-OPEN (`LatencyHUD.decodeHitCeiling`) |

## DECISIONS

Each of these is open, and each fix changes pixels for existing edits, a documented
contract, or the feel of a control. Not implemented.

| # | Row | What the fix is | What moves |
|---|---|---|---|
| D-1 | K-090 | P8's spec: give `lumenDehaze` the EV log-luminance and gradient planes and lift the floor per pixel, `mix(tMin, 0.9, saturate(bright·flat))`; negative branch `max(1 − raw, skyness)` | `detail.dehaze` (sky +0.69 EV mean at +100), every look/edit with Dehaze ≠ 0, `KernelGoldenTests` |
| D-2 | K-099 / D2-01 (+ D2-02) | P8's spec: Texture and Clarity onto the à-trous band stack S12 already builds, raised-cosine window around `bandCenter(longEdge)`; in the same landing, D2-02's goldens at the real `longEdge` and `structureRadius` floored at 1 | `detail.texture`, `detail.clarity`, every Texture/Clarity edit; GPU presence below ~400 px long edge |
| D-3 | K-040 | Narrow the Zones track to the monotone ±1.27 EV, or make the per-zone gain monotone-limited like the six sliders | `zones.*.ev` records if the gain changes; nothing if only the track narrows (stored values outside it stay) |
| D-4 | A1-02 | (a) Brights pivot +4 → ~+2.5 EV (a `pipelineVersion` migration) or (b) asymmetric positive half like Whites/Blacks | `zones.bright.ev` (frontLoading 0.9976), every Brights edit |
| D-5 | A1-03 | `normalizedAxis` on the DEFAULT anchors so a zone means a fixed EV; grading wheels share the axis and move with it | every edit combining Whites/Blacks with Zones or grading wheels; zones/grade records only if measured with Whites/Blacks ≠ 0 |
| D-6 | A1-04 | Linear branch maps `[blackAnchor, whiteAnchor]` linearly; rendered sources get their own white anchor (+2.47 EV) for the shelves | every JPEG/HEIC/TIFF edit using Whites, Blacks or Highlights |
| D-7 | A1-05 geometry | Move `endShelfStart` up to where Highlights saturates (and re-solve `whiteToneEV`) | `tone.whites` (authority 47.6 today would fall) |
| D-8 | A2-05 rest, A2-03 | `wb.preset.asShot` / `wb.preset.<illuminant>`, `geometry.crop.aspect.<ratio>`; the track double-click as one step | undo granularity only — a feel decision (quick preset browsing currently folds into one step) |
| D-9 | A2-08 | Speed Edit's modifier: Shift ×10 / Alt fine (docs/12 §12.4), or ⇧ fine at the slider's 0.25 (the code comment), or keep 0.1 (`SpeedEditTests.testShiftIsATenth`) | nothing renders; Speed Edit has no caller yet |
| D-10 | D2-03 | Unpin the vignette's outer edge (centre/half-width), add Midpoint and Roundness with defaults that reproduce today exactly | none at defaults; it is a UI and wire-format addition |
| D-11 | K-087 / E1-05 | Move S3 into `ReferenceRenderer.render` (noise scale on `Inputs`) and delete the `PipelineRenderer` compensation | every reference render of a default recipe (chroma 25 is not identity) — 30+ goldens' baselines, and any proof record taken through the reference |
| D-12 | E2-01 | Output sharpening through `sharpenDelta` + `lumaRatio` instead of per-channel `CIUnsharpMask` | every exported file with output sharpening on (the stock web recipe is Screen·Standard); no develop record |
| D-13 | E2-06 | Build the reference's S12 fine band from the current image, as the GPU does | reference renders with sharpening plus any of colour/grade, presence or masks; `sharpen.*` only if measured with those on |
| D-14 | H1-09 | Wire `fullFrame` to ⌥ while the clipping overlay is up, or delete it | none |
| D-15 | K-060 | An identity short-circuit for the finish table on untouched recipes | every untouched preview (3.5 → 0.9 code values), i.e. the baseline every record compares against |
| D-16 | K-050 | Presence guide on an EV plane, or variance as `box((I − mean)²)` | `detail.texture`/`clarity` on the GPU |

Two behaviours chosen here that the owner may want to overrule:

- **H1-02 — what "before" shows.** Before is now *this file as imported, framed like the
  edit*: crop, straighten, flip and upright travel; the lens profile does not (it is a
  correction, part of what the edit did). The alternatives — before uncropped, drawn at
  its own aspect, or before carrying the lens correction too — are one line each in
  `Recipe.beforeRendition`. On a JPEG the before is now on the Linear transform, i.e.
  the file as opened, instead of a second tone map.
- **H1-03 — the 256 px bucket now binds at fit.** Viewer renders can be up to 255 px
  larger than the drawn extent (never smaller). The test that pinned 3504 for the 50%
  zoom draft cap now reads 3584.

## FOUND-WHILE-FIXING

- **A JPEG's before rendition was a second tone map.** `beforeRecipe` was the type's
  default `Recipe()`, so on every rendered file the before pane ran the Neutral sigmoid
  over the camera's — the K-027 / D1-01 mechanism through the comparison view. Fixed with
  H1-02 (9435ebe).
- **`copySettings()` had D1-04's shape too**: ⌘C with nothing selected emptied the
  settings clipboard. Fixed in f31a890.
- **`DevelopFooterButton` ignored `isEnabled`** — a `.plain` button under `.disabled`
  stops firing and changes nothing else, the `LumenToggleRow` defect one struct over.
  Fixed in f31a890 so the new `.disabled` reads as disabled.
- **More `Int(_:)` over CIImage extents** in `PipelineRenderer` (`:550, :727, :820, :945,
  :1127, :1559, :2021, :2055, :2469`) and `DecodeMaterializer.swift:146`. These read the
  DECODED image's extent, not the file's header, so they are a step further from
  untrusted input than I3-03's five; an infinite extent (an unbounded CIImage reaching
  them) would still trap. Not changed — outside the row, and in files the colour/export
  streams are editing.
- **docs/06 §11.2's `σ = sqrt(1/ln r)`** is right for the CFA-green geometry it describes;
  the code's luminance geometry needs the factor of two. The doc was left alone (it is
  internally consistent); `estimatePSFSigma`'s comment now says which is which.
- **A2-06 is closed by L-01's epoch** by an ordering detail worth knowing: `MaskCanvas`
  commits the release inside `onEnded` before its `defer { sliderGestureChanged(false) }`
  runs, so the nil-keyed release still carries the drag's epoch. Reordering that `defer`
  would silently reopen A2-06.
