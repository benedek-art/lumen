<!-- docs/25 — Visual/UX design audit and direction proposal, 2026-08-26, at
406c8de, commissioned by the owner ("this looks a lot like very old Apple... I'd
love to do a deep and honest visual and UI UX design"). The critique's file:line
references are to that commit and go stale as the plan below lands; docs/23 M2's
UI bullet is the live status. Owner decision pending: Option A first (recommended,
a strict subset of B) vs straight to B. -->

I've read the chrome code in full — `LumenControls.swift`, `DevelopPanel.swift`, `ContentView.swift`, `FilterBar.swift`, the visual parts of `LoupeView.swift`, `GridView.swift`, `FilmstripView.swift`, `HistogramView.swift`, `BasicPanel.swift`/`DetailPanel.swift` composition — plus the design law in `docs/00-vision.md` (Law 7) and its full spec in `docs/12-spec-ux.md` §12.7. Here is the audit.

---

# Lumen — Visual/UX Design Audit

*Branch 406c8de · All paths relative to `/home/user/lumen/Sources/LumenApp/` unless noted*

## 0. Verdict in one paragraph

The owner's instinct is exactly right, and it is worth being precise about *which* Apple this looks like: not current macOS, but **pre-Yosemite utility-panel AppKit** — Aperture 2.0, the Shake-era dark tool. The tell is not the darkness; Lightroom and Capture One are dark. The tell is that the UI is built from **1px separator lines, one near-uniform ~10–11pt type size, flat same-value gray rectangles, and icon-above-caption button grids** — the four signatures of 2008 Mac pro apps. The bones underneath are genuinely excellent: the information density, the one-slider contract, the honesty affordances (badges, disabled-with-reason menus, the filter sentence), and the keyboard-first grammar are assets most commercial tools don't have. This is a **surface problem concentrated in one enum and five files**, which is the best possible kind of design problem.

---

## 1. Honest critique — what produces the "old Apple" read

### 1.1 There is no elevation ladder — two surfaces and a pile of hairlines

The entire theme is `LumenControls.swift:47–64`: two background values (`panelBackground` 0.14, `viewerBackground` 0.16), one control value (0.20), and a `separator` (0.26). Regions are then delineated almost entirely by **1px `Divider().overlay(Lumen.separator)` lines** — `ContentView.swift:22, 37, 44`, `DevelopPanel.swift:252, 254, 260`, sidebar `ContentView.swift:161, 166–170`, plus 1px vertical rules between filter-bar groups (`FilterBar.swift:572–576`) and 1px bottom/top rules on the filter bar and filmstrip (`FilterBar.swift:68–72`, `FilmstripView.swift:77–81`). Hairline-partitioned flat gray **is** the pre-Yosemite AppKit look. Lightroom, Capture One, and Darkroom all delineate regions by *surface-value change and spacing*; lines are reserved for instruments. Worse, the ladder is inverted: the viewer surround (0.16) is *lighter* than the panels (0.14), so the photograph — the one thing that should sit in the calmest field — sits in the brightest chrome region of the window.

### 1.2 The type has no scale, and the hierarchy it does have is upside down

Census: row labels 11pt (`LumenControls.swift:127`), values 11pt mono (`:311`), section headers **10pt** caps (`:391`), chips 10pt (`FilterBar.swift:597`), notes/badges/group-labels 9pt (`DevelopPanel.swift:193–194`, `LumenControls.swift:579`, `FilterBar.swift:580`, `ContentView.swift:403`), wand icon 9pt (`LumenControls.swift:141`), grid rating stars **7pt** (`GridView.swift:253`). The section header — the highest-level element in the panel — is *smaller* than the rows it governs. There are also three separately hand-rolled caps-label styles (10pt/0.6 tracking in `LumenSectionHeader`; 9pt/0.5 in the sidebar `ContentView.swift:402–407`; 9pt/0.5 in `FilterBar.swift:578–583`). Tiny gray ALL-CAPS labels at Lucida-Grande-era sizes over near-black is the second signature of the old look. Nothing anywhere is allowed to be big enough to anchor the eye; the panel reads as an undifferentiated gray column and you *scan* instead of *land*.

### 1.3 Contrast: the app misses its own spec, in the small sizes where it hurts

`docs/12-spec-ux.md` §12.7 demands ≥4.5:1, target 7:1. Measured: `secondaryText` (0.58) on `panelBackground` (0.14) ≈ **5.1:1** — passes AA, misses the 7:1 target, and this pairing carries most of the UI at 9–11pt. On chips (`controlBackground` 0.20) it drops to ≈ 4.7:1. The collapsed `DevelopNote` renders at `secondaryText.opacity(0.75)` (`DevelopPanel.swift:196`) — composited ≈ **3.5:1 at 9pt, a hard WCAG failure** in the one place the app explains itself.

### 1.4 The chrome is darker than Law 7 allows

This is the audit's most interesting finding because it makes the redesign *spec compliance*, not taste. Law 7 (`docs/00-vision.md:154–157`) and D46 (`docs/12-spec-ux.md` §12.7) prescribe chrome in the **18–25% reflectance-equivalent zone** — read strictly, that's linear 18–25%, i.e. sRGB signal ~0.46–0.53, darktable's "middle gray for color-critical work"; read loosely as signal, the floor is 0.18. The shipped panels are **signal 0.14 ≈ 1.7% reflectance** — an order of magnitude below the strict floor and below even the loose one. The spec's own cited failure mode (Bartleson–Breneman, Hunt) is precise: a too-dark surround makes the photographer over-cook contrast and saturation and deliver too-dark prints. The "old Apple gloom" and the Law 7 violation are the same bug. (Also §12.7's canvas-surround control, Lights Out, and ⌘B assessment mode are all unbuilt — no hits in `Sources/` — and the honest path to true 18% gray judgment is that assessment mode, not painting the whole chrome mid-gray.) One outright chroma violation in chrome: `catalogStatus` renders `.orange` (`ContentView.swift:177`).

### 1.5 State is a gray wash; the accent defined for state is almost never used

Every selected/active state in the app is the same idiom: a ~30% white wash — section switcher `Lumen.fillColor.opacity(0.30)` (`DevelopPanel.swift:298`), chips 0.35 (`FilterBar.swift:608`), sidebar rows 0.28 (`ContentView.swift:429`), segmented 0.35 (`LumenControls.swift:433`). A faint lighter wash on flat gray reads as *hover* or *disabled*, not *selected*. Meanwhile `Lumen.accent` — documented at `LumenControls.swift:56–58` as "used only for state that must be noticed" — appears in the entire app as a 4pt dot (`:396`), an emphasized badge (`:582`), and the status-bar count (`ContentView.swift:477`). The slider's modified state, the single most load-bearing "notice this" in a develop tool, is carried by an opacity change of mid-gray fill (0.5 → 0.9, `LumenControls.swift:184`) whose visible contrast against the track computes to ≈ **1.8:1** — near-invisible — plus a subtle label brightening. In Lightroom you can read "what did I touch" down a panel in half a second; here you genuinely can't, despite the code doing extra work (fill-from-default!) to make it possible.

### 1.6 There are no hover states and no focus states — in a keyboard-first app

One `onHover` exists in the entire app, and it's functional (histogram clipping triangles, `HistogramView.swift:308`). No control responds to the cursor arriving; no control can visibly hold focus. The file's own header (`LumenControls.swift:21–34`) correctly explains the keyboard nudge is blocked partly because "there must be a visible focus ring in a chrome that is deliberately zero-chroma and near-featureless" — i.e., a designed focus treatment is a *prerequisite for a planned feature*, not just polish. Modern-Mac feel (Darkroom, Pixelmator Pro, C1) is substantially *made* of 100ms hover/press transitions; their absence is a third signature of the old look.

### 1.7 The filter bar is ~20 same-weight targets in one 10pt strip

`FilterBar.swift:40–59`: three caps group labels + three chips + a "≥" glyph + five 10pt stars + five 14px swatches + an Unlabelled chip + RAW-only + Edited + Metadata menu + All/Any + search field + sort menu + direction + auto-advance mini-switch + size slider — separated by 1px rules, everything 9–10pt, everything the same value. Nothing recedes, so everything shouts quietly. The *grammar* is superb — the OR-within-group/AND-between-groups model and the spelled-out query sentence (`FilterBar.swift:454–500`) is better product thinking than LR's filter bar — but the visual weight of the always-on chip farm is chip noise. LR hides the whole bar behind `\`; C1 folds filters into a panel. The sentence row is the keeper; the chip row is what needs discipline.

### 1.8 The footer button grid is the single most "2008" element

`DevelopPanel.swift:420–445`: eight icon-above-9pt-caption bordered tiles in a 4×2 grid — the iPhoto/Aperture toolbar idiom, extinct in every reference app. These are verbs, most with key equivalents; they don't need to be tiles.

### 1.9 Assorted smaller tells

- **"Default" badge on every clean section** (`DevelopPanel.swift:131–134`): chrome announcing the *absence* of information, repeated ~10 times per panel; the modified dot already carries the signal. Noise.
- **Mini `.switch` toggles** inline in rows (`LumenControls.swift:563–566`, `FilterBar.swift:398–399`) — System Settings furniture inside a pro density panel; a checkmark/pill reads better at this scale.
- **Corner radii scatter**: 2, 3, 4 across chips/cells/badges (`GridView.swift:221–238`, `FilterBar.swift:609`, `LumenControls.swift:584`) — close enough to look accidental rather than systematic.
- **Grid cells** are competently restrained (deliberately no shadow/gradient for scroll performance, `GridView.swift:9` — right call), but selection is a 1–2px gray `strokeBorder` (`:219–224`) where primary-vs-selected-vs-unselected are three grays (`:179–181`); with an accent reserved for "must be noticed," primary selection is the textbook use.
- **Histogram** sits in a `Color.black.opacity(0.55)` well (`HistogramView.swift:118`) — actually the *right* instinct (wells go darker) applied nowhere else in the app.
- 7pt stars (`GridView.swift:253`) and 8pt glyphs (`ContentView.swift:305, 416`) are below any Mac legibility floor.

### 1.10 What is genuinely good — do not touch the soul

For balance, and because a redesign that sands these off would be a failure: the **22pt row / 320pt panel density** matches LR almost exactly and suits a working tool; the **fill-from-default slider semantics with the neutral tick** (`LumenControls.swift:177–195`) is *better* than LR's fill-from-left; soft-drag/hard-type ranges; the "As Shot" honesty; disabled sort keys that say what they're waiting for (`FilterBar.swift:341–369`); the query sentence; the loupe badge honesty ("EMBEDDED PREVIEW", "PROXY", `LoupeView.swift:922–952`); the empty state's one-line trust statement (`ContentView.swift:499`); zero gratuitous animation. The redesign's job is to give this discipline a visual language of equal quality — not to make it prettier at density's expense.

---

## 2. Two design directions

Shared constraint, both options: **Law 7 holds absolutely.** Chrome stays zero-chroma gray; the one accent stays desaturated slate (or is dropped to pure value contrast); the wheel hues and label swatches remain the only documented exceptions; the photo's surround stays neutral and calm. Panel order, the D45 slider contract, the keymap, and the density envelope (±10% rows per screen) do not change in either option.

### Option A — "The same soul, executed beautifully" (evolutionary, low risk)

**The idea:** keep every layout decision and every idiom's position; replace the two-gray-plus-hairlines model with a real five-step elevation ladder, give the type an actual scale, make modified/selected/hover/focus states legible, and delete the noise (separator rules, "Default" badges, caps-label triplication). A user's hands notice nothing; their eyes notice everything.

**Token spec (all zero-chroma, sRGB signal values):**

| Token | Value | Role |
|---|---|---|
| `surroundCanvas` | 0.165 | loupe/grid/compare photo field — calmest surface, now *darkest region* |
| `windowBase` | 0.18 | status bar, filmstrip — Law 7 loose floor |
| `panel` | 0.20 | sidebar, develop column, filter bar |
| `insetWell` | 0.145 | histogram well, text fields, slider grooves, chip-group wells — *depth goes down, not lines* |
| `controlSurface` | 0.24 | buttons, chips at rest |
| `controlHover` | 0.27 | +hover |
| `controlActive` | 0.31 | selected/pressed |
| `hairline` | white 0.28 @ 60% | only where two same-value surfaces must still divide (rare) |
| `textPrimary / textSecondary / textTertiary / textDisabled` | 0.92 / 0.66 / 0.50 / 0.38 | secondary on panel now ≈ 6.3:1 |
| `accent` | keep (0.45, 0.58, 0.72) | see policy |

**Type scale (SF Pro / SF Mono):** section header **11pt semibold, caps, tracking 0.8, `textSecondary`** (now ≥ row labels); row label 11pt regular `textSecondary` → `textPrimary` when modified; value 11pt mono; notes 10pt `textTertiary` (fixes the 3.5:1 failure); chips/menus 11pt; **floor: nothing below 10pt** (stars, wand, plus-glyphs all rise). One `LumenCapsLabel` component replaces the three hand-rolled versions.

**Spacing/radii:** 4pt grid. Rows stay 22pt; inter-section gap 8→16pt; panel side padding 10→12pt. Radii: 3 (swatches) / 5 (controls, chips) / 7 (wells, cards) — nothing else.

**Accent policy (Law 7-compatible):** accent appears only at marker scale — the modified dot (4→5pt), the focus ring, and the *primary* selection border in grid/filmstrip. Never as a fill, never as area.

**Slider:** groove becomes a 4pt `insetWell` capsule (carved, not painted-on); fill stays neutral but the states separate for real — unmodified fill 0.42 gray, modified fill 0.72 (≈ 4:1 against groove); neutral tick unchanged; thumb 10pt with a 1px 0.10 rim (edge, not glow), grows to 12pt and appears "lifted" on hover/drag; **thumb hidden until row-hover on unmodified rows** (LR's exact trick — collapses visual noise of 15 white dots per panel; needs owner sign-off). `SliderDrag.thumbGrabRadius` and all geometry untouched.

**Section header:** modified dot in accent; "Default" badge deleted; **Reset appears on header hover only**; header row gets the 16pt top rhythm instead of a hairline.

**Filter bar:** delete the 1px separators and the FLAG/RATING/LABEL caps labels (chips are self-labeling); each group's chips sit *inside one `insetWell` capsule* with 2pt-inset pills, active pill `controlActive` + `textPrimary` — three quiet clusters instead of twenty floating targets. Sentence row unchanged. Mini-switch → labeled pill toggle.

**Focus/hover:** one `lumenHoverable()` modifier: hover = surface +0.03, 100ms ease; focus = 1.5px accent ring @ 60% — this is the prerequisite `LumenControls.swift:26–28` names for the keyboard nudge.

**Footer:** two rows of compact horizontal icon+11pt-label buttons (borderless, hover surface), not tiles.

### Option B — "Modern pro" (Capture One-class, braver)

**The idea:** the panel becomes a layered instrument: sections are soft cards on a slightly darker base, no hairlines inside the column at all, mixed-case headers with a real scale, values in visible pill wells that advertise their click-to-type, and the filter bar collapses to a one-line toolbar with the query sentence as the always-visible truth. Depth comes from surface value, never drop shadows (shadows don't read on dark UI; C1 doesn't use them either).

**Tokens:** ladder as Option A plus `sectionCard` 0.215 (radius 8, 10pt inner padding, 10pt gaps between cards), `valuePill` = `insetWell` at radius 4, top-edge highlight white @ 4% 1px on cards (the "lit from above" cue), HUD overlay black @ 72% for loupe badges. Surround `0.165` plus the **spec'd D46 canvas-surround control** (right-click: white/light/mid/dark/black) and Lights Out — Option B builds the rest of §12.7 since it's already committed design.

**Type:** section headers **12pt semibold mixed-case `textPrimary`** (C1's tool-title idiom — caps retire to the sidebar); labels 11pt; values 11pt mono inside pills; notes 10pt; section-switcher tabs get 9→14pt icons *with 9pt labels under them* or become a text tab row — pure-glyph tab bars are the one place Lumen is *less* discoverable than LR.

**Controls:** rows 26pt (density cost ≈ 2 fewer visible rows per screen — the deliberate trade); slider groove 5pt in-well with 1px inner top shade; thumb 12pt flat with rim; modified = fill 0.72 + accent dot + pill border accent @ 50%. Segmented and chips share the pill-in-well system. Filter bar: one 30pt row — Flag ▾ / ★ ▾ / Label ▾ / Metadata ▾ menus with lit counts, search, view controls; the full chip clusters drop down only while the bar is expanded (`\` toggles, matching `⌘\` clear); sentence row always visible.

**Both options — what does not change:** Law 7 / zero-chroma; panel logic, order, and 320pt width; the entire keymap and bare-key culling grammar; the D45 slider contract and its tested geometry; fill-from-default semantics; every honesty affordance (badges, disabled-with-reason, the sentence); the no-gratuitous-animation stance (transitions cap at ~120ms, matching `FilmstripView.swift:94`).

---

## 3. Implementation plan (sequenced, every push shippable via the self-updating app)

Recommendation: **ship Option A first** — its ladder and type scale are strict subsets of B, so B remains reachable as steps 10–12 rather than a rewrite. The owner reacts to each push in the running app.

| # | Change | Files | Effort | Risk | Notes |
|---|---|---|---|---|---|
| 1 | **Token ladder**: restructure `Lumen` enum into semantic tokens (surround/base/panel/well/control/hover/active + text tiers); alias old names to new so all ~40 call sites compile, then migrate call sites; fix `.orange` status text | `LumenControls.swift:47–64`, `ContentView.swift:177` | M | Low | **Owner checkpoint 1 — the big one.** Chrome rises toward the Law 7 zone; darktable users report a brighter chrome "feels wrong" for a session before edits start proofing better. Ask him to live with it for one full edit session on his calibrated display before judging, and to compare an export against LR. |
| 2 | **Type scale + one caps-label component**; kill all sub-10pt; fix note contrast | `LumenControls.swift`, `ContentView.swift:402`, `FilterBar.swift:578`, `DevelopPanel.swift:190–196`, `GridView.swift:253` | S | Low | Pure text attributes. |
| 3 | **Section header + DevelopSection**: drop "Default" badge, hover-reveal Reset, accent dot, 16pt rhythm, delete panel-internal hairlines | `LumenControls.swift:372–414`, `DevelopPanel.swift:112–162, 252–260` | S | Low | **Owner checkpoint 2:** hover-only Reset is a taste call; trivially revertible. |
| 4 | **Slider polish**: groove well, fill states, thumb rim + hover-reveal, row hover wash | `LumenControls.swift:156–297` | M | Medium | Visual only — `SliderTrack`/`SliderDrag` (tested, in LumenCore) untouched; verify hit targets unchanged. **Owner checkpoint 3:** slider *feel* is his muscle memory; get his hands on it same-day. |
| 5 | **Filter bar regroup**: chip clusters in wells, delete separators + group caps, pill toggle for auto-advance | `FilterBar.swift` | M | Medium | Layout only; all filter logic and counts untouched. **Owner checkpoint 4** (his culling loop lives here). |
| 6 | **Footer verbs**: tiles → compact horizontal buttons | `DevelopPanel.swift:365–445` | S | Low | |
| 7 | **Grid/filmstrip selection**: accent primary border, hover wash, 10pt stars | `GridView.swift:179–254` | S | Low | Keep the no-shadow cell rule. |
| 8 | **Hover/focus modifier app-wide** (`lumenHoverable`, focus ring) | new small file + call sites | M | Medium | Unblocks the keyboard-nudge prerequisite named at `LumenControls.swift:26–28`; the keymap handoff itself stays a separate, later decision. |
| 9 | **Sidebar pass**: unified rows on new tokens, section rhythm | `ContentView.swift:130–446` | S | Low | |
| 10–12 | *(Option B, if the owner wants more after living with A)*: section cards + mixed-case headers; value pills; collapsed filter toolbar; canvas-surround control + Lights Out (D46) | `DevelopPanel`, `FilterBar`, `LoupeView`, `AppState` | M/M/L | Medium | Surround control needs new persisted state + context menu; it is already-specified work (docs/12 §12.7), not scope creep. |

**Needs the owner's eyes mid-way:** step 1 (the gray ladder on *his* display — everything else calibrates against it), step 4 (slider feel), step 5 (filter bar), and the two taste calls: hover-only Reset and hover-reveal thumbs. Everything else can ship on judgment.

**Success test, stated up front so we can be honest later:** after step 5, a screenshot should still read instantly as "dense pro tool," the modified state should be readable down a panel in under a second, and nothing in the window should be more interesting than the photograph — which was always the design's own stated goal (`ContentView.swift:3–5`); the current execution just undershoots it.
