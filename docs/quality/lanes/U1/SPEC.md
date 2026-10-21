# U1: design system, spacing and panel layout

Baseline: `ui-snapshots:claude-inspiring-dirac-ulgpch/a93efb2/`. All snapshots are 2x, so
1 pt = 2 px. Measurements were taken by scanning luminance transitions along single
pixel rows and columns of the PNGs (`scan.py` in the lane notes below), not by eye.

## 1. Audit: defects in the baseline

Column edge = x 0 of a 380 pt panel snapshot. Card edge = the section card's 1 px rim.

1. **Labels hug the card wall.** Card rim at x 8 px (4 pt from the column); "Exposure"
   glyphs start at x 30 px (15 pt from the column, **10 pt inside the card**), on a card
   whose corner radius is 14. `panel-develop-tone.png` y 124.
2. **Value pills hug the right wall.** Pill stroke ends at x 732 px, card rim at 750 px:
   **9 pt** to the card edge, 10 pt to the column. Same file, every row.
3. **The focus highlight has zero inset.** Highlight spans x 28–732 px; label glyph
   starts at x 30 (1 pt in) and the pill's stroke sits on the highlight's right edge
   (0 pt). Text and pill read as touching the highlight. `panel-develop-tone.png`
   y 96–152, `panel-develop-detail.png` y 314–370, `column-masking.png` y 592–648.
4. **The card chevron is not in the label column.** Header chevron glyph at x 41 px
   (20.5 pt), labels at 15 pt: a 5.5 pt step at the top-left of every card.
5. **Folds are indented a second, different amount.** "Zones" / "Noise Reduction"
   chevron at x 66 px (33 pt), title at x 98 px (49 pt) vs the card title at 58 pt.
   Three left edges (15, 20.5, 33) in one card. `panel-develop-tone.png` y 592.
6. **Subsection titles sit on the label column but folds do not.** "Capture Sharpening"
   starts at 14 pt; "Noise Reduction" chevron at 33 pt in the same card.
   `panel-develop-detail.png`.
7. **No type hierarchy between card and subsection.** "Tone" (card), "Zones" (fold),
   "Colour Mixer" (subsection) and "Capture Sharpening" are all `.lumenHeading`
   12 pt semibold, same colour. `panel-grade-colour-point-colour.png` y 56 vs y 144.
8. **Off-grid vertical rhythm.** Header→first row gap 6 pt, fold top 10, subsection top
   20, histogram card padding 8/8/6, column stack spacing 10 vs card gap 8. Only 8 is on
   the 4 pt grid's 8 pt step. Card-header to "Capture Sharpening" centre is 51 pt
   (`panel-develop-detail.png` y 56 → 159) against 34 pt to the first row in Tone.
9. **Four different left edges at the top of the column.** Filename at x 20 px (10 pt),
   histogram well at 24 px (12 pt), card labels at 15 pt, masking "‹ Develop" at 10 pt.
   `column-develop-tone-open.png`, `column-masking.png` y 450.
10. **Column gutter 4 pt.** Cards sit 4 pt from the column edge and from the rail
    divider, against an 8 pt gap between cards: the outside margin is half the inside
    one. `window-1512x982-develop.png`.
11. **Secondary text fails AA on the focus fill.** Unmodified slider labels are
    `secondaryText` 0.62; on the focused row's `controlActive` 0.31 that is **3.06:1**
    ("Amount" in `panel-develop-detail.png`). On `controlSurface` 0.24 it is 4.05:1.
12. **Tertiary text fails AA everywhere.** 0.48 on the 0.20 panel is **2.96:1**, and it
    carries information, not only disabled state: mask counts, caps labels, filter
    counts, history "ahead" rows (30 call sites).
13. **Header hover fill outset (4) differs from the row's (0).** Two highlight
    geometries in one card.

Out of my lane, written to `NEEDS.md`: the Film Lab stock menu ends 7 pt short of the
pill column (`panel-grade-film-lab-stock.png`, x 718 vs 732; `LumenMenu`); the
masking Curve editor's segmented control is inset 8 pt deeper than the rows
(`column-masking.png` y 1336; T2); the footer's 4-then-2-then-2 button grid.

## 2. Token spec

All in `enum Lumen` (`LumenControls.swift`), so every lane reads the same numbers.

| token | value | meaning |
|---|---|---|
| `space1…space6` | 4, 8, 12, 16, 20, 24 | the grid |
| `columnGutter` | 8 | column edge → card edge, and the footer's inset |
| `cardPaddingH` | 12 | card edge → content, both sides |
| `cardPaddingV` | 8 | card edge → header / last row |
| `cardGap` | 8 | between cards, and between histogram and first card |
| `headerContentGap` | 8 | header → first row in a card, subsection or fold |
| `subsectionGap` | 16 | space above an in-card subsection title (was 20) |
| `foldGap` | 8 | space above a fold (was 10) |
| `rowHighlightOutset` | 6 | focus and hover fills extend this far past the content column, so the text sits 6 pt inside the fill and the fill sits 6 pt inside the card |
| `disclosureGlyphWidth` | 8 | chevron column: the glyph's leading edge lands on the label column |
| `contentInset` | 20 | `columnGutter + cardPaddingH`: where every text column in the develop column starts |
| type: `lumenSectionTitle` | 13 pt semibold | card title (new) |
| type: `lumenHeading` | 12 pt semibold | subsection / fold title (unchanged) |
| type: labels / values | 11 pt regular / 11 pt mono | unchanged |
| `secondaryText` | 0.70 | was 0.62 |
| `tertiaryText` | 0.61 | was 0.48 |
| focus fill | `controlHover` 0.27 | was `controlActive` 0.31 |

The 6 is the one half-step on the grid, and it exists to split `cardPaddingH` evenly.

## 3. Acceptance lines

Measured on this branch's snapshot set (2x, px = 2 × pt), same scan method.

| # | claim | threshold |
|---|---|---|
| S1 | slider label glyph to card rim | ≥ 12 pt (was 10) |
| S2 | value pill stroke to card rim | ≥ 12 pt and equal to S1 ± 1 pt (was 9 vs 10) |
| S3 | focus highlight: label inset and pill inset inside the fill | both 6 ± 1 pt (was 1 and 0) |
| S4 | card chevron glyph left edge vs label left edge | ≤ 1.5 pt apart (was 5.5) |
| S5 | fold chevron left edge vs label left edge | ≤ 1.5 pt apart (was 18) |
| S6 | distinct left edges in the column header area (filename, histogram card, card labels, masking back button text) | filename, back-button chevron and card labels within 1.5 pt of 20 pt |
| S7 | card title larger than subsection title | 13 vs 12 pt, visible in `panel-grade-colour-point-colour.png` |
| S8 | every spacing literal in the owned containers is a token on the 4 pt grid (6 only as `rowHighlightOutset`) | grep of the diff |
| S9 | WCAG AA: primary, secondary, tertiary text on panel 0.20, and secondary on the focus fill | ≥ 4.5:1 (computed from the tokens) |
| S10 | `LayoutMetricTests` and `ScopeTests` green on macOS CI | green |
| S11 | track at the 380 pt default stays ≥ 190 pt for a ±100 row | 190 (was 202; the cost of S1/S2) |

Visual claims for a human, before/after side by side:
V1 `panel-develop-tone.png`: the text no longer looks pressed against the card, the
highlighted row has air on both ends.
V2 `column-develop-tone-open.png`: filename, histogram, cards and footer share one
left margin.
V3 `panel-grade-colour-point-colour.png`: "Colour" reads as the card, "Colour Mixer"
and "Point Colour" read as parts of it.
