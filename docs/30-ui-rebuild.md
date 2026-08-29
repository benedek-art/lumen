# 30 — The rebuild: from a set of decisions to a single object

**Commissioned 2026-08-29**, after the owner tested the Phase 4 build:

> "does it have to look like an Apple application? Like right now, it just looks like it was
> made in 2008 … There's just so much wording. It's not neat. The entire thing, there's so
> much clutter … I want an app that is quick, easy to use, and visually beautiful … right
> now it just looks outdated and old … it feels like Lightroom, but worse."

Four independent audits were run — visual design, UI copy, controls and interaction, and
whole-window composition. This document is what they add up to and what to do about it.
The audits are the evidence; this is the argument.

---

## 1. THE ONE DIAGNOSIS

Every audit praised the reasoning in this codebase and failed the result. That is not a
contradiction, it is the finding:

> **Lumen has been designed as a sequence of correct local decisions and never once as a
> single object.**

The comments argue well. Each constant has a defence. And the sum does not cohere, because
nothing has ever been decided at the level of the whole — there is no type scale, no
elevation ladder, no motion language, no spacing grid, no rule about what a word is for. A
theme file is not a design system. `Lumen` is a list of colours; a design system is a set
of decisions that make the next decision obvious.

The three symptoms the owner named map exactly onto three missing systems.

| He said | The missing system |
|---|---|
| "looks like it was made in 2008" | **Light** — no edges, no depth, no motion |
| "so much wording … so much clutter" | **Silence** — no rule for when a word is allowed |
| "limited to being able to touch it up slightly" | **The instrument** — the slider is too small to work in |

And a fourth he did not name, because he could not see it to name it:

| What he could not find | The missing system |
|---|---|
| "it's super difficult for me to navigate" | **The map** — 45 of 65 keys have no menu; two view modes have no control at all |

---

## 2. THE FOUR SYSTEMS

### 2.1 LIGHT — "nothing in this application has an edge"

The measured facts:

- The elevation ladder, darkest chrome to brightest control, spans **1.873:1**.
- The boundary between the photograph and the develop column is **1.135:1** — at or below
  the threshold at which an eye resolves an edge.
- **Four shadows in 24,797 lines of view code.** Zero materials. Zero blurs. Zero inner
  highlights. Three gradients, all on one control.
- **Five `withAnimation` calls in the entire app**, none of them on the accordion, the
  workspace switch, a value readout, a selection, or any hover.
- **220 font calls; 199 of them are 9, 10 or 11pt.** The ratio between 10 and 11 is 1.1. A
  scale needs ~1.2 to register as a step. 88% of all text is Regular weight.
- **Nineteen distinct greys**, with three disagreeing values for "recessed well" (0.09,
  0.115, 0.145) — two of them hard-coded outside the theme.
- **Section headers are the identical colour to the rows they govern.**
- Five hand-rolled ALL-CAPS styles at three sizes. A second typeface (SF Mono) at 23 sites
  where `.monospacedDigit()` was the answer.
- **67 tooltips against 5 hover handlers.** Zero `NSCursor` changes anywhere.
- 39 stock `.switch` toggles rendering in **Apple's default blue** — the only saturated
  colour in an app whose Law 7 forbids chroma, arriving uninvited.

The prior design audit (docs/25) diagnosed this correctly and prescribed the wrong cure: it
**removed the hairlines** on the theory that a five-step grey ladder would delineate
instead. The ladder that shipped spans 1.873:1 end to end. It cannot. **The app went
flatter after the redesign.**

Linear and Raycast run surface steps no larger than ours — ~1.14:1 — and read as solid
objects, because every surface carries a 1px top highlight and a real shadow. We have the
density and the honesty. **We are missing the light.**

### 2.2 SILENCE — "a control that needs a sentence has not been designed yet"

- **1,051 user-facing strings, 6,008 words.** 635 strings are 1–2 words (those are labels,
  and they are fine). **205 strings are full sentences carrying 4,187 words — 69% of every
  word in the app.**
- **Half the words in Lumen are explanation** (2,974 of 6,008: note bodies plus tooltips).
- **`DevelopNote` has 71 call sites and 2,108 words. 59 of them render as an
  "ⓘ How this works" row.**
- **146 words** stand between opening the app and making one ordinary edit — exposure,
  white balance, vignette. **43 of them are a paragraph explaining a feature does not
  exist.**
- On that path, **two of the three sections opened to reach a vignette contain no controls
  at all — only prose.** One of them names a "Look panel" that no longer exists.
- **Eleven sentences exist to explain a disabled state that does not look disabled**,
  including a menu item whose only purpose is to announce that it does not work.
- The word "Colour" appears as a heading **five times inside the Grade workspace**.
- Deleting 60 strings out of 1,051 removes **1,661 words — 27.6% of everything written.**
  The clutter is not diffuse; it is concentrated, and 71 of the sentences come from one
  component.

**The previous fix made it worse in a way that looked like an improvement.** Nineteen
always-visible paragraphs in the mask panel did not become zero rows — they became
nineteen rows reading "How this works". A tooltip that ships its own visible label is not a
tooltip; it is a permanent three-word advertisement for one.

### 2.3 THE INSTRUMENT — "142 points is not enough road"

The develop column is 320pt. After padding, a 94pt label column and a 52pt value column,
the slider gets **142pt of track.**

> **The chrome is wider than the instrument: 146pt of text against 142pt of control.**

What that costs:

| Control | pt per unit | device px per unit |
|---|---|---|
| Any ±100 (Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Vibrance, Saturation, every mixer band…) | **0.710** | 1.42 |
| The same inside a disclosure | 0.670 | 1.34 |
| The same with a legacy scrollbar showing | 0.635 | 1.27 |
| **Exposure, per 0.01 EV step** | 0.142 | **0.284** |

- On a ±100 control, **one device pixel of mouse movement is 0.70 units**, and the value
  snaps to integers — so there is no stable middle. **28.9% of the integer values cannot be
  landed on by dragging the track at all.**
- **Exposure's declared step is sub-pixel.** The track physically cannot express the
  resolution its own readout advertises; the smallest available drag is ~3.5 steps.
- For scale: Lightroom at its narrowest is 0.97 pt/unit, Capture One ~1.20. **We are 27%
  coarser than Lightroom's worst case**, and we are the only one of the two that cannot be
  resized.
- The groove is **4pt tall with a 10pt thumb** — the handle is 2.5× the height of the thing
  it slides in.
- **The precision instrument has 2.7× less hit area than the coarse one.** The scrubby
  readout (2.13 pt/unit) is a 52×22 target; the coarse track (0.71) is 142×22.
- **Nothing in the develop column meets 24×24** except the workspace tabs and the grade
  wheel. The printer-light steppers are **12×12 with a 32pt dead zone between them**, in a
  row that wastes 78pt of empty space.
- **The scrollbar is a layout bug, not a preference.** Ten of eleven scroll views show
  indicators and the modifier that would hide them appears nowhere in the codebase. On a
  mouse, opening a section makes the column overflow, the 15pt legacy scroller appears and
  *insets the content* — **every slider in the panel gets 10.6% narrower.**

The arithmetic in `SliderDrag.swift` is the best-reasoned code in the repository and **none
of these findings are about the math.** They are about there not being enough road for it
to drive on.

### 2.4 THE MAP — the app has capabilities nothing surfaces

- **45 of 65 keyboard actions have no menu item. There is no View menu.**
- **There is no view-mode control anywhere in the window.** Compare and Survey have zero
  pointer entry point of any kind; the only way to discover them is `C` and `N` in a sheet
  behind ⌘/.
- **⌘1 "Cull" does not enter the culling view.** `PanelLayout.select` mutates the layout and
  never touches `viewMode` — structurally it cannot, since `WorkspaceLayout` lives in
  LumenCore. The app's most prominent switcher is named after a mode it does not enter.
- **SpeedEdit is fully built, tested, and referenced nowhere in `Sources/LumenApp`.**
- **Snapshots and virtual copies** have schema, storage and methods, and no caller.
- **400 labelled history steps exist and nothing renders them** — the entire surface is two
  footer buttons.
- **Clipping warnings** — the most-reached-for control in any raw editor — are two
  unlabelled 11pt triangles with no key and no menu.
- **The Simple/Full register door** hides 7 of the app's 13 sections behind one 10pt line
  below the fold.
- The top bar's thumbnail slider **does nothing in three of four view modes.** The codebase
  diagnosed exactly this for the keyboard and fixed it there, and left the pointer version
  in place. Its decorative grid glyph is what the owner mistook for a view switcher.
- **"239" appears four times in the window**, in three phrasings, two highlighted as active
  selections. The filename appears twice, ~990pt apart.

---

## 3. THE COMPOSITION FINDING THAT REORDERS THE ROADMAP

For an 1800×1169 window, chrome is **41.28%**. The photograph is **49.35%** on a 3:2
landscape frame, **31.05%** on a portrait one, **37.70%** in the grid.

Then the arithmetic that matters:

```
Remove the top bar AND the status bar   →  landscape photograph: +0.00 points
Hide the sidebar                        →  landscape photograph: +19.95 points
```

**A landscape photograph in this window is width-limited.** Every horizontal band deleted
returns letterbox, not picture. The sidebar is worth more than every other composition
change combined — and it is also among the cheapest, because the app declares no
`columnVisibility`, no toggle and no sidebar row in its own 65-row keyboard reference, so
nothing regresses.

This does not mean the vertical bands stay. It means they are a tidiness argument, not a
photograph argument, and should be sequenced as such.

---

## 4. THE PLAN

Four phases, sequenced by **felt improvement per unit of risk** rather than by depth. The
first is almost entirely deletions and constants; the last is the only one that needs new
architecture.

### Phase A — The first day (deletions and constants)

Everything here is a constant change or a deletion. No new abstractions, no logic touched.
This is the phase that answers "is it quick, is it beautiful" fastest.

1. **Kill every scrollbar.** `.scrollIndicators(.never)` on all eleven scroll views. This
   is simultaneously what he asked for and the fix for a real layout bug — it removes the
   15pt gutter that today shrinks every track by 10.6% whenever the column overflows.
2. **Widen the instrument.** `labelWidth` 94 → 86, `valueWidth` 52 → 48, column padding
   10 → 8, track height 4 → 6, thumb 10/12 → 12/14.
3. **Delete the 59 "How this works" rows** in one edit — make non-prominent `DevelopNote`
   render `EmptyView()` and move its text onto the control's `.help`.
4. **Delete the Looks banner** and its verbatim duplicate 60 lines below it.
5. **Delete the sections that contain only prose** — Retouch, and the "Auto — not wired
   yet" menu item. Absence is quieter than an apology.
6. **Animate the disclosures.** One `withAnimation` around `PanelLayout.commit` plus a
   `.transition` on the section body. Highest beauty-per-line in the entire audit.
7. **Delete the four folds that hide fewer than three rows** — Pivot (one slider), Advanced
   (two), Overrides (two), Display Transform (a fold whose content is a fold).
8. **Fix the two duplicate headers** — Film Lab under Film Lab, Soft Proof under Soft
   Proof, and the mask dock printing "Masks" above `MaskPanel`'s own "Masks".

### Phase B — The light

The design system, as a system. This is where the app stops looking like 2008.

9. **`lumenSurface()`** — a 1px top-highlight gradient border plus a real shadow, applied to
   every surface that should read as an object. This alone is the difference between flat
   grey and buttery, and it is the highest-leverage single change in the audit.
10. **One type scale.** Three sizes with real ratios, not 9/10/11. One caps component
    replacing five. `.monospacedDigit()` replacing SF Mono at all 23 sites.
11. **Section headers become headers** — `primaryText`, one size up, a real container.
12. **`lumenHoverable()`** — 5 hover states become ~200. Plus `NSCursor.resizeLeftRight`
    over every scrubby number, which is the cheapest way to make a hidden feature visible.
13. **Tint the toggles**, or replace them. Apple's default blue must not be the only
    saturated colour in a zero-chroma app.
14. **Raise `separator` 0.30 → 0.42** so the remaining structural dividers actually divide.

### Phase C — The silence

15. Work the 35 DELETE and 15 REPLACE-WITH-DESIGN verdicts from the copy audit.
16. **Design the disabled state** so eleven sentences retire. A control that cannot be used
    should not be drawn, or should be visibly inert — not annotated.
17. **Rename.** `Grade → Grading → Colour Grading → Colour balance` is four headings and
    three of them are the same word. `Optics` hides the crop tool. And the jargon list:
    Preserve Luminance, Uniformity, Brilliance, Printer Lights, Display Transform.

### Phase D — The map

18. **A View menu**, giving ~20 orphaned keys a home. Cheapest possible fix for "difficult
    to navigate", because it makes the app's own capabilities readable for the first time.
19. **A view-mode control**, and **make ⌘1 Cull actually enter the culling view.**
20. **Hide the sidebar outside Cull**, bound to `Tab`. +19.95 points of photograph.
21. **Delete the top bar as a band**; redistribute its six controls to a real toolbar and
    the View menu, and delete the thumbnail slider outright.
22. **Cut the status bar to one clause** and merge it into the toolbar.
23. **Resizable develop column**, 320–480, defaulting to 380 — which takes the slider from
    0.71 to 1.07 pt/unit, past Lightroom's default.
24. **Wire SpeedEdit.** It is built, tested and reachable from nothing.
25. **Surface history.** 400 labelled steps deserve a list.

---

## 5. WHAT DOES NOT CHANGE

Stated because a rebuild is where good things get thrown out with bad ones.

- **`SliderDrag.swift` and the whole `LumenCore/Interaction` layer.** Every audit that
  touched it called it the best-reasoned code in the repository. Relative drags that
  survive dropped events, crossing-not-proximity detents, the mired axis, the gearbox that
  rebases rather than scales. None of the findings are about the math.
- **The honesty affordances.** Double-click-to-reset that survives the drag gesture, the
  crossing-detent haptic, the focus ring, the per-row modified state, the draggable
  histogram zones. These are better than the commercial tools.
- **The engine.** Nothing in this document touches a pixel of the render path.
- **The keyboard grammar.** It is more complete than the menu that should expose it; the
  fix is the menu, not the grammar.

---

## 6. THE SUCCESS TEST

Not "does it look better" — that cannot fail honestly. These can:

1. **A ±100 slider reaches every one of its 201 values by dragging the track.** Today 58 of
   them cannot be landed on.
2. **One ordinary edit — exposure, white balance, vignette — costs fewer than 60 words on
   screen.** Today it costs 146.
3. **No section of the interface contains only prose.** Today two do, on the vignette path.
4. **Every keyboard action has a menu item.** Today 45 of 65 do not.
5. **A 3:2 landscape photograph occupies more than 65% of the window.** Today it occupies
   49.35%.
6. **The develop column's track width does not change when a section opens.** Today it
   changes by 10.6%.
7. **The owner opens the app and does not have to be told where anything is.**
