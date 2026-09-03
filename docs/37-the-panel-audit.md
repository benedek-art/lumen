# 37 — The panel audit

Four independent passes over `MaskPanel.swift` (2604 lines) and everything it touches,
run against two sentences from the owner after using the round-three build:

> "What I see right now is a box inside of a box inside of a box inside of a box."

> "I don't know what Ubrush is… It looks odd. It looks random. It looks like it was just
> put there… the entire settings is just difficult to use. It's genuinely difficult to
> look at because it is so kind of unorganized."

Both are literally true, and the audit found the mechanism for each. The point of this
document is that **neither was a matter of taste**. Every complaint named a specific
number in the source.

---

## 1. THE MEASUREMENTS

| | |
|---|---|
| Controls on screen at once, brush mask, nothing adjusted | **60** |
| Of those, sliders | **29 — only 24 distinct** |
| Scroll height for one mask with one component | **≈1930 pt** |
| Share of the column that is section headers | **20% (8 × 48 pt)** |
| Sliders carrying a tooltip | **0 of 24** |
| Filled rectangles crossed to reach one slider | **3, two of them the same colour** |
| Distinct left edges inside one zone | **5** |
| Row pitch spread between adjacent siblings | **22–33 pt** |
| Corner radii in use, against three tokens | **6** |

---

## 2. THE FIVE FINDINGS THAT WERE MINE

Every one of these was introduced by a previous round, and three of them by round three —
the round that was written to fix this panel.

### 2.1 The glyph was eating the label it was drawn to explain

`Lumen.labelWidth` is 86, and `LumenControls.swift:250` documents that it was *measured*:
"86 fits every name that exists". `LumenBehaviourGlyph.width` was 44, and `LumenSlider`
paid for the picture **out of the label**: `max(86 − 44 − 4, 28)` = **38 points**, about
six characters.

So the four controls carrying a glyph were exactly the four whose names ellipsized —
`Follo…`, `Expa…`, `Softe…`, `Max s…` — while `Steadiness`, which is longer than
`Soften edge` and carries no glyph, rendered in full.

**Width-independent.** The text columns are fixed and only the track grows, so dragging
the panel from 320 to 520 un-truncates nothing. The feature added in round three to answer
*"I want to know what Feather does before I even click it"* was deleting the word that
says what it is.

### 2.2 `∪` is a capital U

`opGlyph(.add)` returned U+222A, drawn 11 pt semibold **monospaced**, five points from a
word set in the same grey. At that size the set-union operator is a U with no crossbar and
no serifs. The row read as one token: **"Ubrush"**. In the caption-sized subtitle, `∪`
read as a lowercase **a** — hence "a Brush".

It was also redundant: Add / Subtract / Intersect is spelled out in a segmented control
two rows below. Set-theory notation was never the register for a panel whose job is to be
legible at a glance.

### 2.3 The boxes were real, and the innermost ones were blank

`MaskEditor` fills with `Lumen.panel`. `zone(_:asks:)` filled with `Lumen.panel`.
Identical fill, identical `.flush` elevation — so the inner card's entire visual output
was a 1 px 5.5 %-white hairline against a background of exactly its own value, about
**1.05:1**, where `LumenSurface`'s own header puts the eye's floor at 1.135:1.

Four zones spent **72 pt of track budget and ~140 pt of scroll** on a boundary nobody
could see. What was legible was the indentation, which is why the complaint is about
boxes rather than about colour. `DevelopColumn.swift:496` had already learned this for the
accordion — "six drop shadows stacked down a scrolling column is a pile of floating
tiles" — and the mask panel reintroduced the tiles one level down.

### 2.4 Seven controls drawn twice

`componentParameters` hit `case .brush: brushParameters()`; `body` drew the same seven
again as its own zone. `usesBrush` is true **exactly** when that case is reached, so they
were never apart: Size, Feather, Flow, Max strength, Steadiness, Eraser and Stay inside
edges were on screen twice, ~1400 points apart, bound to the same `MaskBrushStore` and
moving together. The zone's doc comment said it existed to *replace* the inline copy. The
copy was never deleted.

### 2.5 The heading hierarchy said the opposite of the nesting

A zone label was `size: 10, secondaryText`. A section header **inside** it is
`size: 12, primaryText`. The parent was 17 % smaller and a full contrast step fainter than
its child, eight times over. The eye builds an outline from size and value; here they
contradicted the structure, so the panel read as a flat run of headings with small grey
words between them.

---

## 3. THE OVERLAY HAD FIVE INPUTS AND NO TESTS

`grep soloMaskOverlay Tests/` returned nothing. Nine writers of one variable, in a
`@MainActor` class whose initializer opens a catalog on disk and which therefore cannot be
constructed in a unit test. It produced three defects, and every one was a **guard**.

**One menu click darkened the app.** "Keep it showing" pinned; "Keep it hidden" cleared
the overlay and left `maskOverlayPinned` **true**. `flashMaskOverlay`, `hoverMaskOverlay`
and `setMaskEdgeGesture` all open with `guard !maskOverlayPinned`. So showing once and
hiding once disabled every ambient overlay for the rest of the photograph — no creation
flash, no hover preview, no matte while dragging an edge — with nothing on screen saying
so, and only `O` able to undo it.

**A flag written on every press and read by nothing.** `maskOverlaySuppressed` was set by
the Effect zone and consulted only by its own dedup guard. Hovering a row during an
Exposure drag defeated the suppression outright; a flash arriving mid-drag put the red
back over the pixels being judged.

**There was no persistent state at all.** Every path was a 1400 ms countdown or a pointer
dwell. Worse: for **brush, linear, radial and outline** — the four kinds you draw — the
creation flash rendered *nothing*, because an undrawn mask's alpha is zero and
`colorOverlay` composites `c.mix(tint, a·s)`, which at `a = 0` is the photograph byte for
byte. Painting did not raise it either. **A brush mask could go from creation to a
finished adjustment without the red having been visible for one frame** — which is exactly
what the owner reported.

And `overlayControls(_:)`, 52 lines building the Show-overlay switch, the mode menu and
the tint menu, had **zero call sites**. Its own doc comment argued "a control that only
exists as a keystroke is a control most people never find" while not being drawn. The
entire visible surface of the state machine was two items in a `⋯` menu and a badge.

### The rule now

> **A mask's overlay is persistent from the moment it is created until the first time an
> Effect control is touched, and hover-only afterwards; it is forced on while an Edge
> control is dragged and forced off while an Effect control is; and `O` overrides
> everything.**

The phase ends on the first **Effect** press, not the first change of any kind — refining
an edge is still selection work, and the overlay is the only place a selection is visible.
The code already knew that distinction (the Edge zone and the Effect zone call different
hooks), so the concept was free. It ends on the *press* rather than the release, so the
overlay is out of the way for the very first adjustment.

Setting it on an undrawn mask is right rather than merely harmless: nothing is selected, so
nothing should be washed red, and the moment the first stroke lands the alpha stops being
zero and the overlay is already standing there. **The feedback arrives with the selection
instead of before it.**

---

## 4. WHAT LANDED

| What | Where | What convicts a broken version |
|---|---|---|
| The label column stops truncating | `LumenBehaviourGlyph.inRowWidth` = 26, name before glyph | — (macOS lane) |
| Every label starts at the same x | `LumenControls.swift` label/glyph `HStack` | — |
| `∪ Brush` → words | `opName`, `opPhrase` | 3 tests, macOS lane: no set-theory operator may appear in a photographer-facing string |
| The invisible zone card | `zone` draws no surface | — |
| Zone headings outrank their sections | `zone` uses `LumenSectionHeader` | — |
| Seven brush controls drawn once | `componentParameters` `case .brush: EmptyView()` | — |
| "Edge" printed once | zone owns the chevron, dot and Reset | — |
| Three tautological captions gone | `asks:` is optional; only Brush passes one | — |
| 14 tooltips where there were none | every Edge, brush, Strength and Contribution slider | — |
| The pin is clearable | `unpinMaskOverlay` | `MaskOverlayRule` — 11 tests, Linux lane |
| Suppression is authoritative | `MaskOverlayRule.ambientAllowed` | ditto, 4 assertions convict |
| A mask stays lit until adjusted | `beginPersistentMaskOverlay`, `mayStandDown` | ditto |
| Leaving a row falls back, not dark | `afterHoverExit` | ditto |
| `⇧O`/`⌥O` stop pinning silently | `cycleMaskOverlayMode`/`Tint` | — |
| The overlay strip is drawn | `overlayControls` called from the What zone | — |
| Twelve items out of the row menu | overlay section deleted | — |

`MaskOverlayRule` lives in **LumenCore**, and `AppState` calls it rather than restating
it — a copy of a rule beside the rule is how the two drift. Every one of its four
predicates was substitution-proved: restoring each original bug turns tests red (4, 1, 1
and 2 failures respectively), restoring the fix turns them green.

---

## 5. STILL OPEN, IN ORDER

1. **The full overlay precedence.** `MaskOverlayRule` holds the three guards that had
   bugs. The precedence between a pin, an edge drag, a hover and a flash is still
   expressed by the order in which nine methods write `soloMaskOverlay` — the shape that
   lost the pin. Moving it means making those methods set inputs and recompute once,
   which is a refactor of live view state on a target this repository cannot compile
   locally. Written down rather than half-done.
2. **The navigator split.** The mask list and the component stack move into a fixed band
   under the histogram, a *sibling* of the column's `ScrollView` rather than a child, so
   the list stops scrolling away when you reach Exposure. Recommended over a floating
   panel: at the 1180 pt minimum window the centre pane is ~511 pt and a Lightroom-sized
   navigator covers 43–51 % of the photograph, over a pane that is a live gesture surface.
   A Detach button gives the literal Adobe arrangement to anyone who wants it.
   **Blocked on** `AppState.refreshMaskThumbnails`, which rebuilds serially, one `await`
   per mask, keyed on the mask-source fingerprint — survivable while the list scrolls
   away, not survivable once it is always on screen.
3. **The Edge zone off its sliders.** Ramp from / to / shape are a Levels dialog on the
   alpha channel (`MaskRaster.levels` is black point, white point, gamma). They are also
   the only three Edge sliders with no behaviour glyph, because their meaning is 2-D and
   the glyph column is one line tall. One transfer graph over the alpha histogram replaces
   all three; Follow edges becomes Off / Gentle / Strong; Expand and Soften become one
   drag on the boundary in the overlay.
4. **Brush masks have no pin.** `MaskCanvas.anchor(of:)` falls through `default: continue`
   for `.brush`, so the commonest kind has no representative on the photograph — it cannot
   be clicked, scrubbed, or told apart from another brush mask without the list. The
   centroid of the stroke set is the anchor. Then pins get a horizontal scrub for
   Strength, which `MaskAlgebra.swift:9` says the architecture was shaped for and which
   was never built.
5. **Comparing masks.** No next/previous-mask key exists anywhere in `Keymap`, and
   isolating one of three masks costs four toggles because `enabled` is the only lever.
   A held-key solo turns a fifteen-click comparison into a keypress.
6. **The remaining register entries.** Toggle rows that are pixel-for-pixel a slider at
   zero; nine label-left rows with no value column; the 22/28/33 pt pitch spread; six
   corner radii against three tokens; Light and Colour with no modified dot and no Reset;
   the mask's Temp on a linear Kelvin axis where the global one is reciprocal; mask
   Exposure and Contrast missing the coloured tracks their global twins have; a mask
   named "Brush 1" while `autoName` sits wired to a placeholder that can never show;
   clicking a mask's name putting a caret in a field instead of selecting the mask.

---

## 6. THE LESSON WORTH KEEPING

Three of the five findings in §2 were introduced by round three — the round written to fix
this panel. Each was a good idea implemented without measuring what it displaced: the
glyph took half the label column, the zone card took 18 pt per zone to draw nothing, the
Brush zone was added and the thing it replaced was left behind.

**A feature that improves one thing and is never measured against what it costs is a
feature that ships a regression.** The measurements in §1 took four passes over one file
and would have taken minutes at the time.
