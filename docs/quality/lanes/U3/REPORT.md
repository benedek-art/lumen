# U3: viewer, Compare and editing workflow (report)

Branch `quality/u3-viewer-workflow` from `claude/inspiring-dirac-ulgpch` (9068ded).
Baseline snapshots: `ui-snapshots:claude-inspiring-dirac-ulgpch/a93efb2/`. After: `ui-snapshots:quality-u3-viewer-workflow/3685198/` (41 of 41 written).

## For the owner

1. Zoom to 1:1 (Z), hold Space and drag. It should pan and stay at 1:1, and a quick tap of Space should go back to Fit.
2. With two photos selected, press C, then Z, then − and +. Both frames should zoom together.
3. Select three photos and click **Sync…** in the develop footer. Then click **Copy…**: it opens the checkbox sheet (⌘C still copies everything at once).
4. Press Y for side by side and ⇧Y for split. Check that the BEFORE and AFTER labels read clearly at the top.
5. Pinch, wheel-zoom and pan at 1:1 on a 33 MP RAW. Smoothness can't be seen in a PNG.

## Ranked UX defects (audit against Lightroom Classic Develop)

| # | Defect | Evidence | Status |
|---|---|---|---|
| 1 | **Space held while zoomed snapped to Fit.** Space toggled on key-down, so the Adobe hand-tool reflex (hold Space, drag) zoomed out first and then had nothing to pan. | `Keymap.swift` `case " "` called `toggleZoom()` on press | **Fixed.** Pressing Space at Fit zooms to 1:1 under the cursor, so a press-and-drag is LR's space-drag. While zoomed, the release decides: a tap goes to Fit, and a hold that panned or zoomed leaves the zoom where it is (`LoupeViewport.spaceDown/spaceUp`). |
| 2 | **Holding Space beeped once per key repeat.** Repeats fell through to the system as unclaimed keys. | `CullAdvance.allowsRepeat` rejected `" "`, and the event was returned to AppKit | **Fixed.** Repeats are claimed in the loupe, in Compare and during the grid peek. |
| 3 | **Before/after side by side drew both pictures on the floor of the viewer**, with the top half empty and the BEFORE badge under the FIT/MASK HUD. | `evidence/before-side-by-side-bottom-pinned.png` (snapshot c21fb24). `BeforeAfterPair.pane` was a `.bottomLeading` ZStack, so the fitted image was bottom-aligned too. | **Fixed.** The picture is centred inside the matte and the label moved to the top (Lightroom's placement). |
| 4 | **The pinned mask overlay stayed on the Develop loupe after Esc left masking.** The red wash plus the "MASK · Sun" badge stayed up with no editor to remove them. | `window-1512x982-develop-zoom-1to1.png` @ c21fb24 | **Fixed** in the loupe: drawn only while masking (`shownMaskOverlay`). The state clean-up is in NEEDS 3. |
| 5 | **No matte at Fit.** The picture ran flush into the sources sidebar and the develop column (0 px each side). Arming Crop shrank it by 48 px a side, so the frame jumped about 6%. | `evidence/before-develop-fit.png`, `before-crop-armed.png`: picture spans x 462→2148 at fit and 511→2101 in crop (3024 px window) | **Fixed.** `LoupeGeometry.fitMatte` = 24 pt is used by fit, crop and Compare. After: 510→2100 at fit and 511→2101 in crop, so there is no jump. `evidence/after-develop-fit.png` |
| 6 | **Z, −, + did nothing in Compare, and Space zoomed the hidden loupe behind it.** The next E then opened the loupe at 1:1. | `CompareSync` was a private `@StateObject`; the Space case had no mode guard | **Fixed.** `CompareSync.shared`; the keys drive it, and it resets to Fit when the mode changes to Compare. `window-1512x982-compare-zoom-1to1.png` |
| 7 | **Footer Copy was copy-everything with no choice, and there was no Sync.** The selective dialog and Sync were reachable only as ⇧⌘C / ⇧⌘S in the menu bar. | baseline `window-1512x982-develop.png` footer | **Fixed.** **Copy…** opens the checkbox sheet, and **Sync…** appears when more than one photo is selected (`evidence/after-compare-fit.png`). Titles measured at 320 pt: `LayoutMetricTests` green. |
| 8 | **The histogram card changed height with the scope feed.** The "Binned: scope render, no proof" row came and went, so every section header jumped 19 pt while paging photos. | baseline develop vs grade: first header at y 577 vs 539 px | **Fixed.** The note is a chip inside the graph well, and headers now sit at the same y in both windows (c21fb24). |
| 9 | Paste is lit with an empty clipboard | footer | **Not fixed** (needs an AppState getter, NEEDS 1). |
| 10 | Two-pane before/after ignores ⌘B / L surround | `BeforeAfterPair` paints a constant | **Not fixed** (NEEDS 5). |
| 11 | Develop window snapshots claim "Tone open" but show every section closed | baseline captions vs PNG | Harness issue (NEEDS 4). |

## Verdict per spec line (Lightroom parity)

| Spec line | Verdict | Notes |
|---|---|---|
| Zoom to 100% with Z or space-drag, and Fit | **PASS** (after fix) | Z toggles Fit ↔ 1:1 under the cursor; Space press-drag; ⌘= / ⌘− and the wheel/pinch ladder snap to Fit. |
| Smooth pan | **PASS by code**, owner to feel | Drag, wheel and arrows all go through one clamped `panTo`; the zoom hold scales a layer instead of re-laying out. Item 5 of the owner list. |
| Before/after `\`, side by side, split | **PASS** (after fix 3) | `\` full flip, Y side by side, ⌥Y top/bottom, ⇧Y split. New snapshots: `-develop-before-after-side`, `-split`. |
| Histogram clipping indicators (J) | **PASS** | Corner triangles are lit by the shared `ScopeReadout.clipping`; J toggles both overlays; hovering a triangle peeks. |
| Shortcuts for every workspace | **PASS** | ⌘1–⌘5 for Cull/Develop/Crop/Grade/Deliver, plus G, E, C, N, R (crop), M (masks), D (Detail). |
| Copy/paste with a selective dialog | **PASS** (after fix 7), Paste gating open | ⇧⌘C sheet; footer Copy…; ⌘C / ⌘V instant; ⇧⌘V without masks; ⌥⌘C/V Look. |
| Sync to selection | **PASS** (after fix 7) | ⇧⌘S sheet, ⌥⇧⌘S no dialog, footer Sync… with more than one selected. |
| Reset per section | **PASS** | `DevelopSection(onReset:)` on 46 sections; ⇧⌘R resets the photo. |
| History | **PASS** | History section in Develop (HistoryPanel); ⌘Z / ⇧⌘Z with named steps. |
| Filmstrip navigation | **PASS** | ←/→ page and the strip scrolls the cursor to centre; ⌘←/→ page while zoomed. |
| Loupe background and margins | **PASS** (after fix 5) | 24 pt matte on `state.surroundColor`; crop uses the same inset. |

SPEC.md lines: S1 PASS (48 px = 24 pt each side, measured). S2 PASS (fit 510→2100 vs crop 511→2101). S3, S4 and S5 PASS by code (verifier rounds 1–2). S6 PASS (`LayoutMetricTests` green on macOS). S7 PASS (headers equal y). S8 PASS (5 new states written).

## What changed

- `LoupeView.swift`:
  - `LoupeGeometry.fitMatte` / `fitArea` are used in `ratio(forZoom:)`, `trueFitZoom` and `drawnFull`, so overlays, pan clamps and the pinch fit-snap agree. `cropInset = fitMatte`.
  - `LoupeViewport.spaceDown/spaceUp/cancelSpaceHold`; any pan or zoom during the hold marks it used.
  - `shownMaskOverlay` gates the loupe's mask overlay to masking.
- `Keymap.swift`: Space repeats claimed; zoomed Space is the hand; the peek release wins; Z, −, + and Space drive Compare.
- `CompareView.swift`: `CompareSync.shared`, `zoomIn/zoomOut`, matte on panes. `ContentView.swift` fits Compare on mode entry.
- `DevelopPanel.swift` footer: Copy…, Sync….
- `HistogramView.swift`: provenance chip in the well.
- `ViewerOverlays.swift` `BeforeAfterPair.pane` (outside my listed files, but it is the before/after view this lane owns by spec): centred, top labels.
- `KeyGrammar.swift`: Space row text.
- Tests:
  - `LayoutMetricTests`: the footer row is now 3 across, which is stricter.
  - `ScopeTests`: the note budget is −10 pt for the chip padding, which is stricter.
  - `PanelSnapshotTests`: 5 states appended.

## Gates

- Linux: `swift build --target LumenCore` clean. LumenApp can't be parsed by the Linux Swift 6.0.3 because of a pre-existing trailing comma in `CompareView.swift` (base 9068ded, lines 325/568, macOS-only syntax), so Core tests ran from a scratch copy with only those two commas removed. The keymap, scope, design-system and surround text-scan suites (116 tests) passed after one fix: a raw corner-radius literal, replaced with `Lumen.radiusChip`.
- Verifier (fresh agent, diff + spec only): round 1 FAIL (3 defects: Compare 1:1 snapshot reset by `onAppear`, blind toggle on Space release, stale hold eating the grid-peek release), all fixed; rounds 2 and 3 PASS.

## CI (head 3685198)

UI layout ✅ (LayoutMetricTests, incl. the 3-across footer and the note budget) · UI snapshots ✅ 41/41 · GPU parity ✅ · Proof sweep ✅ · CI (`ci.yml`): queued on the shared macOS runner when this was written; earlier heads' runs were superseded by later pushes, none failed.

## Three best before/after images

1. Fit matte: `evidence/before-develop-fit.png` → `evidence/after-develop-fit.png` (picture flush to both panels → 24 pt matte, crop no longer jumps: compare `before-crop-armed.png`).
2. Side by side: `evidence/before-side-by-side-bottom-pinned.png` → `evidence/after-side-by-side.png` (pictures on the viewer floor under the HUD → centred, labelled at the top).
3. Compare: baseline had no Compare snapshot and no keyboard zoom → `evidence/after-compare-fit.png` (matte, Copy… / Paste / Sync… footer) and `evidence/after-compare-zoom-1to1.png` (Z, both panes synced at 1:1).
