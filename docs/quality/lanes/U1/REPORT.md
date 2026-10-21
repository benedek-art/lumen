# U1 report: design system, spacing and panel layout

Branch `quality/u1-design-system`. Baseline snapshots `claude-inspiring-dirac-ulgpch/a93efb2`,
after snapshots `quality-u1-design-system/dcd20b4` (the evidence images come from this set; the
histogram inset change in 82792d2 lands after it, see S6).
All measurements are on 2x PNGs, 1 pt = 2 px.

## For the owner

1. Labels and numbers now sit 12 pt inside every card on both sides (were 10 and 9), and the cards have an 8 pt margin to the column edge.
2. A highlighted row has 6 pt of fill around its text and pill instead of none; open Tone and click Exposure.
3. Chevrons, the filename and the masking back button all start on the same edge as the slider names.
4. Grey text is brighter: every text colour passes WCAG AA now (worst case 4.6:1, was 3.0:1).
5. Cost: 12 pt of slider track at the default width (202 → 190), so a ±100 slider is 0.95 pt per step instead of 1.01. Drag the column 10 pt wider to get back over 1.0; making 390 the default is your call.

Try by hand: tab through sliders with the keyboard (the focus fill should sit inside the card), and hover card headers (the hover fill should match the focus fill's shape).

## Verdict per spec line

| # | measured after | before | verdict |
|---|---|---|---|
| S1 label to card rim | 12.0 pt ("Exposure"), 11.5 on C/H glyphs | 10 | PASS |
| S2 pill to card rim | 11.0 pt to inner rim, 12.0 to frame; within 1 pt of S1 | 9 | PASS on the amended line (see SPEC amendments) |
| S3 text / pill inside focus fill | 6.5–7 / 6.0 pt | 1 / 0 | PASS |
| S4 card chevron vs labels | 1.0–1.5 pt | 5 | PASS |
| S5 fold chevron vs labels | 1.0–1.5 pt | 15.5 | PASS |
| S6 shared left edge | filename 21, "‹ Develop" 20.5, labels 20.5–21 pt | 11 / 10.5 / 15 | PASS. Histogram exempt: its card edge aligns with the others, its well and readout keep the baseline 12 pt so the clipping readout still fits at 320 pt |
| S7 card vs subsection title | 13 vs 12 pt (width ratio 1.078) | equal | PASS |
| S8 spacing literals on the grid | column, card, footer, histogram, header: tokens | — | PARTIAL: inner literals remain in the masking bar (6/5/3) and histogram readout row (6/5) |
| S9 WCAG AA | primary 9.15, secondary 5.99, tertiary 4.58 on 0.20; secondary 4.56 on focus fill | 4.72 / 2.96 / 3.06 | PASS |
| S10 layout + scope tests on macOS | UI layout green on dcd20b4; ScopeTests + citation fixed in 82792d2 | — | see CI below |
| S11 track at 380 pt | 190 pt (groove x224–603) | 202 | as designed |

## What changed and why

- `enum Lumen` gained a 4 pt spacing scale and named insets (`columnGutter` 8, `cardPaddingH` 12, `cardPaddingV` 8, `cardGap` 8, `headerContentGap` 8, `subsectionGap` 16, `foldGap` 8, `rowHighlightOutset` 6, `disclosureGlyphWidth` 8, `contentInset` 20).
- `lumenSectionTitle` (13 pt semibold) for card titles; subsections keep `lumenHeading`.
- Text ramp 0.86 / 0.70 / 0.61 (was 0.86 / 0.62 / 0.48); focus fill 0.27 (was 0.31).
- `lumenFocusSurface` draws its fill 6 pt past the row on each side.
- `LumenSectionHeader`: `level` parameter; with `lumenColumnGrid` on (set by the develop column) the chevron box is 8 pt and the hover outset 6 pt.
- Containers: `WorkspaceSectionView`, `HistorySection`, `MaskEditor`, `MaskingReturnBar`, `DevelopSection`, `DevelopDisclosure` (8 pt fold indent removed), the column header, scroll column, footer and histogram card all read the tokens.

Tests changed, each re-pinned to what the code does rather than loosened: `LayoutMetricSupport` reads `scrollInset`/`cardInset` from the tokens; `testTheLayoutChainThisSuiteMeasuresIsTheOneInTheSource` pins the token expressions and now asserts the fold header has no inset; the Display Transform header chrome is re-derived (the old one over-charged 8 pt for padding that nets to zero); `ScopeTests` pins the column gutter; the expected-failure message says 390 pt (was 378, stale before this lane too after the card went in). The snapshot harness wears the same tokens as the column.

## Verifier rounds

Round 1 (on ecdec4c): FAIL. The shared header defaults moved and dimmed the sidebar headers and reached both sheets; subsection titles in `secondaryText` rendered darker than the rows under them; three comments were stale; S2 missed its own threshold by the inner-rim convention. All four addressed in the following commit (opt-in `lumenColumnGrid`, primary subsection titles, default `topRhythm` back to 20 outside the column, comments fixed, S2 restated). 

Round 2 (on dcd20b4 + 82792d2): FAIL on stale text only. Measurements, sidebar and sheet isolation, test re-pins and the CI fixes all passed. The doc on `Lumen.defaultPanelWidth` and four test comments still quoted the pre-U1 chain (142/202 pt, 0.710/1.010, a 378 pt column); a DevelopPanel comment still said fold titles are `secondaryText`; this report named the wrong snapshot set. All corrected in the next commit: the `defaultPanelWidth` doc now says plainly that the default no longer clears the ~1.0 floor and that 390 would. Round 3 result is recorded under CI.

## CI

On dcd20b4: UI snapshots, UI layout, GPU parity, proof sweep green. CI red on three items: ScopeTests clipping headline (209.8 pt in a 206.9 pt slot, this lane, fixed in 82792d2), the slider inventory citing LumenControls.swift:2222 (this lane, re-cited), and fixtures-linux's surface check ("Font is in LumenRender", LumenType.swift:30), which fails identically on a93efb2 and is not this lane's.

## Not fixed (in NEEDS.md)

Film Lab stock menu ends 7 pt short of the pill column; masking curve editor inset 8 pt deeper than the rows; footer button grid misaligned row to row; sidebar left on its own grid.

## Evidence

`evidence/01-tone.png`, `evidence/02-column-masking.png`, `evidence/03-colour-hierarchy.png` are the three best. 04–08 cover Detail, Crop, Film Lab, the develop column and the window's right panel; 09 shows the sidebar unchanged. All are from dcd20b4, so the histogram card in 02, 07 and 08 shows the 8 pt inner inset that 82792d2 reverted to the baseline 4.

## Linux checks

All 74 resolvable LumenCore suites that read app sources pass. The full LumenCore run was stopped by a 25 min timeout in `ControlProofTests` (466 passed, 0 failed before it); that suite renders and reads no U1 file. Building tests on Linux needs a local trailing-comma fix in `CompareView.swift` (Swift 6.0.3), pre-existing and not committed.
