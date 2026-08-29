<!-- docs/28 — the UI/UX refresh plan, commissioned by the owner 2026-08-29 ("the ui ux
is rough... the whole app needs a refresh and a massive one at that... make it better than
lightroom in terms of ui as well now"). Built from a code inventory, competitive research
against nine editors, a SwiftUI feasibility survey against the app's performance
architecture, and five screenshots of the running app. It ABSORBS docs/25's open steps
rather than superseding that document wholesale; docs/23 M-numbering remains the live
status. -->

# 28 — The UI/UX refresh

> This document plans the interface. docs/25 audited the *visual execution* and its
> Option A is half-landed; this one adds the *information architecture*, the colour
> affordances and the speed affordances, and folds docs/25's open steps in by number so
> none of them is silently dropped.

## Context

Lumen's features work. Its interface has not been designed — it has accreted, one
correct feature at a time, and the owner has now looked at the tabs he does not use
daily and found them "rough", "cluttered", "hard to understand" and "clunky". The brief:
a full UI/UX refresh, scoped against the competition, aiming to be better than Lightroom
on interface as well as on engine, phased so it can be executed over time.

This document is built from four sources: a code inventory, competitive research against
nine editors, a SwiftUI feasibility survey against Lumen's performance architecture, and
direct reading of five screenshots the owner supplied (Basic, Zones, Colour Mixer,
Detail, Look). The screenshot observations are recorded first because they are primary
evidence of what the app actually looks like in use.

**One dependency stated up front.** The slider-smoothness work from the preceding session
is shipped but **unverified on the owner's machine**. Phase 4 changes how many slider rows
are in scope per mouse event, so it must not begin until that verification exists —
otherwise a regression there and a regression here become indistinguishable.

### The finding that shapes everything

**Most of what the owner is asking for is already the committed spec, and was skipped.**
`docs/12 §12.12` mandates four workspaces, a Simple register by default, and per-panel
disclosure. `docs/12 §12.1` already groups the panels Develop-vs-Look and already says
Masks is a docked panel, not a tab. `docs/25` is an owner-approved visual redesign whose
steps 3–9 are open. So this is not a redesign from scratch; it is **building the interface
that was specified, plus three genuinely new things**: coloured tracks where colour is the
information, one home for colour, and the speed affordances.

### The seven phases at a glance

| # | Phase | Owner sees | Risk |
|---|---|---|---|
| 1 | Legibility and density | labels stop truncating; panels stop being documentation | low |
| 2 | Colour where colour is information | Temp/Tint/mixer tracks carry their own meaning | low |
| 3 | Reclaim the chrome | the two-row filter bar is gone; sidebar regroups | medium ⚑ |
| 4 | Workspaces and accordions | 8 tabs → 4 workspaces, solo-by-default | **high** ⚑ |
| 5 | One home for colour | Colour and Grading adjacent; one big wheel; picker-first | medium ⚑ |
| 6 | Speed | arithmetic entry, scrubby readout, ⌘K palette, Speed Edit | medium |
| 7 | Focus and keyboard | focus ring, nudge, the owed keymap reconciliation | medium |

Phases 1–2 are pure win with no muscle-memory cost and could ship in a day or two each.
Phase 4 is the one that needs the owner's hands the same day it lands.

---

## Part 1 — What the screenshots show

*(Direct observation. Five tabs, one window, a 239-photo folder.)*

### 1.1 The top bar is two rows and carries fourteen controls

Row one, left to right: `FLAG` label · Pick · Reject · `Unflagged 239` · `RATING ≥`
five stars · `LABEL` five colour chips · `Unlabelled 239` · `RAW only` · `Edited` ·
`Metadata ▾` · `All` · search field · sort control (`Capture time ▾`) · sort-direction
arrow · `Auto-advance` toggle · grid toggle · zoom slider.

Row two: `No filter — showing every photo` on the left, `239 photos` on the right.

Three different kinds of thing are mixed on one surface with no visual separation:
**filters** (flag, rating, label, RAW only, Edited, Metadata, search), **view state**
(sort, auto-advance, grid, zoom), and **status** (the counts, the second row). The owner
is right that this does not deserve a full-width bar; more precisely, it does not deserve
to be *one* bar, because it is three unrelated bars stacked.

### 1.2 The left sidebar mixes five unrelated jobs

`Open Folder…` (action) · date + volume path (status) · All / Picked / Rejected counts
(filter) · ALBUMS (navigation) · KEYWORDS (metadata editing) · STACK (a teaching
paragraph plus one action) · `Keyboard` (help).

Nothing groups these, nothing is collapsible, and two sections — KEYWORDS and STACK —
are inert on a fresh folder while still occupying full height. STACK in particular spends
three lines of prose explaining a feature before offering a single button.

### 1.3 The app teaches inside the panels, at considerable cost

Multi-sentence explanatory paragraphs found in five screenshots alone:

- **Colour Mixer / Uniformity** — four lines, including "Texture-preserving convergence
  needs a spatial pass the shipping graph does not run yet; today it moves the whole
  pixel." This is a note about an unshipped implementation detail, in the panel, in
  front of the photographer.
- **Colour Mixer / band readout** — "Red — centred on 29.2° in OKLCh, core −22°/+22°,
  feather 15°/15°."
- **Colour Mixer / Luminance** — "Luminance holds chroma: a darkened sky stays as blue
  as it was."
- **Colour Mixer / Point Colour** — "No swatches yet. Add one to shift a single colour…"
- **Detail / Sharpening** — three lines about pixel-denominated sharpening and preview
  resolution.
- **Look** — a boxed "this is what a saved look carries" paragraph, plus a second
  paragraph under Saved Looks, plus two more under Colour Grading.
- **Sidebar / Stack** — three lines.

Plus at least six `ⓘ How this works` disclosure rows, three of them stacked
consecutively at the bottom of Detail.

Rough estimate: **25–40% of the vertical space in Colour, Detail and Look is prose.**
The writing is good — genuinely better than most apps' — but its placement is wrong.
It is reference material occupying the position of controls.

### 1.4 Labels are truncated, which is a plain defect

Observed clipped: `Luminance D…`, `Luminance C…`, `Colour Smoo…`, `Halo Suppre…`,
`Uniformity (a…`. The label column is a fixed 78 pt (`Lumen.labelWidth`) and the names
do not fit. A photographer cannot tell `Luminance Detail` from `Luminance Contrast`.

### 1.5 No slider carries any information beyond its position

Every track is the same grey. Temperature does not run blue→yellow. Tint does not run
green→magenta. Exposure does not run dark→light. The hue sliders in the Colour Mixer are
not tinted with the hues they act on. This is the owner's specific complaint and it is
the single highest ratio of perceived quality to implementation effort in the whole
refresh.

### 1.6 There are eight develop tabs

Counted from the icon row. The owner remembers "6ish" and wants "3-4" — the gap between
his memory and the actual count is itself evidence that the tab bar is not legible.

### 1.7 Technical controls sit in prime real estate

Directly under the histogram: `Working % | sRGB 255 | Output 255` and a readout
`0.00% white · 19.59% black`. Correct and useful to an expert; occupying the most
valuable strip of the right panel.

### 1.8 What is already good and must survive

- The **histogram** is well drawn and correctly placed at the top.
- The **filmstrip** is clean and legible.
- The **dark, low-chroma palette** is right for photo work — the picture is the only
  saturated thing on screen.
- The **Zones strip** and the **Colour Grading zone strip** are genuinely novel direct
  manipulation, better than Lightroom's equivalent.
- The **prose itself** is excellent writing. It needs relocating, not deleting.
- Row height, value alignment and the general typographic rhythm are tidy.

---

## Part 2 — Code inventory

### 2.1 Eight tabs, ~135 sliders

`PanelSection` (AppState.swift:175-198): Basic, Zones, Curve, Color, Detail, Effects,
Masks, Look. Icon-only switcher, title in a tooltip only (DevelopPanel.swift:293-315) —
which is why the owner remembered six.

| Tab | Sliders | Other controls | Always-visible prose blocks |
|---|---|---|---|
| Basic | 16 | preset menu, eyedropper, 2 disclosures | 3 |
| Zones | 6 | 5 draggable pivots | 2 |
| Curve | 4 | 6-way channel selector, plot, 3 splits | 2 |
| Color | 17 | hue ring (4 handles), ribbon, 16 swatches | 7 |
| Detail | 15 | toggle, 3-way segmented | 15 |
| Effects | 4 | 5 toggles, 2 menus, segmented, button | 8 |
| **Masks** | **~35 + per-component** | 13 mask kinds, 4 wheels, embedded curve | 18 |
| **Look** | **38** | 4 wheels, 2 strips, 4 steppers, 2 pickers | 12 |

Masks and Look are each larger than the entire Basic panel three times over. Look alone
has 38 sliders in one scroll.

### 2.2 The prose problem is bigger than the screenshots suggested

**67 multi-sentence copy blocks in the develop surface**, of which ~37 are permanently
visible. Estimated always-visible prose: **~700 pt in Masks, 550–700 pt in Look, ~300 pt
in Color** — two to three full panel-heights of reading matter.

A prior mitigation already exists and is the precedent for going further: `DevelopNote`
now collapses to a `ⓘ How this works` row with the text in a tooltip
(DevelopPanel.swift:166-171), after the owner's earlier complaint of "so much text that
is honestly unnecessary". Four notes remain deliberately `prominent` — all four are
honesty disclosures about unshipped behaviour. Nineteen `caption()` blocks in Color/Look
and eighteen `note()` blocks in Masks never got the same treatment.

### 2.3 The design tokens are already a coherent system

`enum Lumen` (LumenControls.swift:47-98) is a proper elevation ladder — `surroundCanvas`
0.165 → `windowBase` 0.18 → `panel` 0.20 → `controlSurface` 0.24 → hover 0.27 → active
0.31, wells carving *down* to 0.145 — with exactly one hue: a desaturated slate blue
accent, rgb(0.45, 0.58, 0.72). Metrics: `rowHeight` 22, `panelWidth` 320,
`labelWidth` 78, `valueWidth` 52.

This is better than most apps have. The refresh should extend it, not replace it.

### 2.4 THE CENTRAL TENSION: the zero-chroma law

`LumenControls.swift:36-37` states a deliberate law — **no chroma anywhere in the
chrome** — so that the photograph is the only saturated thing on screen and colour
judgement is never contaminated by the interface. Every groove and fill is neutral grey
*on purpose*. The only colour in the whole app is the mixer swatches, the hue ring, the
grading wheels and the label chips.

The owner's request for a blue→yellow Temp track is a direct amendment to this law.
It must be made consciously, and it can be made narrowly — see §5.2.

### 2.5 The slider's deliberate omissions

The header (LumenControls.swift:21-34) lists what was left out on purpose: keyboard
nudge, arithmetic entry, scrubby-drag on the readout, ⌥-scroll, ⌘-double-click-to-auto,
⇧⌥-fine-drag, haptic detents. Several of these are exactly the "speed up the process"
affordances the brief asks for.

### 2.6 What must survive

One slider implementation with one interaction contract; deviation-reading fill plus
neutral tick plus rest/modified separation (answers "what did I change?" down a whole
panel at a glance); one undo step per drag via `RecipeBinder` coalescing; the
**engine-drawn instruments** (zone strips, hue ring, band ribbon, curve plot all render
the engine's own evaluation, so picture and maths cannot disagree — the genuine
differentiator over Lightroom); the histogram as an *input device*; per-photo modified
baselines; and the honesty-over-dead-controls policy, whose volume is the problem but
whose principle is right.

## Part 3 — Competitive analysis

### 3.1 Group counts across the field

| App | Develop groups | Count | Container | Solo |
|---|---|---|---|---|
| Lightroom Classic | Basic, Tone Curve, HSL/Color, Color Grading, Detail, Lens, Transform, Effects, Calibration | 9 | accordion | **yes, famous** |
| **Lightroom cloud** | **Light, Color, Effects, Detail, Optics, Geometry** | **6** | accordion | not needed |
| Camera Raw | Basic…Calibration | 9 | accordion | no |
| Capture One | Library, Capture, Lens, Color, Exposure, Details, Adjustments, Metadata, Output, Batch | 10 tabs | icon tabs → stacks | per-tool |
| DxO PhotoLab | Light, Color, Detail, Geometry, Effects, Local | 6 | filter buttons | no |
| darktable | base, tone, color, correction, effects (+active, favorites) | 5–7 | icon tabs | optional |
| Photomator | one flat list | 1 (~17) | accordion | no |
| Apple Photos | Adjust, Filters, Crop | 3 | accordion | no |

**Consensus: accordions inside at most ~6 semantic groups. Nine-plus is where complaints
start.** Lumen's eight *tabs* with no accordion inside them is the worst of both.

**Lightroom cloud is the existence proof.** Six groups, Tone Curve demoted *into* Light,
Color Mixer and Color Grading nested *into* Color. Reviewers call it "remarkably clean";
every criticism is about missing capability, never about the panel design.

### 3.2 The slider-colour rule, which resolves the Law 7 tension

Adobe and Capture One independently follow the same discipline:

- **Coloured**: Temp (blue→yellow), Tint (green→magenta), every HSL band slider (hue
  sliders show the span the band shifts between, saturation runs grey→vivid of that band,
  luminance runs dark→bright of it), and the luminance ramp under each grading wheel.
- **Not coloured**: Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Blending,
  Balance — every tonal control stays neutral.

Capture One's own documentation says the Kelvin and Tint sliders are coloured
*"to make it easier to visualize the direction of the white balance change."*

**The rule to adopt: a gradient track means the slider's axis IS a colour direction.**
Colour everything and nothing reads; colour only the colour axes and every coloured track
becomes self-teaching. This is a narrow, principled amendment to Law 7 rather than an
abandonment of it — and note the owner's own example, an exposure ramp, is the one the
field deliberately does *not* do.

### 3.3 Nobody keeps a filter bar in the develop surface

- **Lightroom**: the full filter bar exists only in the Library grid, hidden behind `\`.
  In Develop there is a compact filter cluster at the filmstrip's right end.
- **Capture One**: a Filters tool inside the Library tab, with live counts per star/colour.
- **Photomator**: a filter *popover* at the filmstrip's right edge; flags as hover
  overlays on thumbnails.
- **darktable**: hover overlays on thumbnails; rating filter in the lighttable only.

**Input is keyboard-first everywhere (P/X/U, 1–5, auto-advance); filtering is a popover or
a counts cluster anchored to the browser.** The owner's instinct is the market's position.

### 3.4 Nobody embeds explanatory prose in adjustment panels

The convention is delayed tooltips (darktable's are the richest in the industry), or
Luminar Neo's ⓘ-per-tool hover. Vertical space in the tool column is the scarcest
resource in the genre — Lightroom's loudest papercut complaints are about *scrolling*.
Lumen spends that exact resource on paragraphs.

### 3.5 The failure mode Lumen already has, named by the industry

ON1 Photo RAW's chronic complaint is **overlap between Develop and Effects causing
"uncertainty about which panel to use."** Lumen's colour work is split across **Color**
(mixer, point colour, B&W) and **Look** (grading wheels, printer lights, primaries, film
lab). That is the same defect, and it is almost certainly why "going through
functionality for the grading like the colours and stuff is hard to understand".

The counter-example: Lightroom cloud put *all* colour in one place and is praised for it.

### 3.6 Interactions the field loves, that Lumen could take

- **Solo Mode** (LR's most-recommended setting — make it the default, not an option).
- **Speed Edit** (Capture One: hold a key, drag anywhere on the image; "extremely rapid
  and immersive… true precision without a Loupedeck"). Already specified for Lumen as
  D44 and unbuilt. No macOS-native editor has it.
- **Picker-first colour targeting** (C1: eyedrop a colour, the band selects itself).
- **The quick-access panel** (darktable: favourite sliders from many modules aggregated
  into one flat panel; users report doing almost all their editing there).
- **Per-tool bypass toggles** on group headers, which Lightroom users envy.
- **A ⌘K control palette** — darktable has module search, Adobe has nothing, and on macOS
  this reads as deeply native. It removes the "where does that slider live" tax that
  *every* grouped IA imposes.

### 3.7 The cautionary tale

Capture One 15.3 merged its tabs into fewer, bigger ones and users revolted so hard the
company shipped a "Default Legacy" workspace to restore the old layout. The lesson is
"don't churn IA on an installed base" — which is why doing this **now**, with one user
who is actively asking for it, is close to free.

## Part 4 — Constraints

### 4.1 THE BIG ONE: what the owner is asking for is already the spec

`docs/12-spec-ux.md §12.12` (decision D3, "two registers, one tool") mandates:

- **Four workspaces** — *Cull* (no panels, filmstrip + badges), *Develop* (default),
  *Grade* (Look panels + scopes), *Deliver* (soft-proof + recipes) — switchable from the
  toolbar. Adopted from Capture One, explicitly.
- **A Simple register as the default**, showing only WB, Tone's six sliders, Looks, Crop,
  Masks, Export — with the Full register one visible click away, and a "3 hidden panels
  active" indicator so state never becomes secret.
- **Per-panel disclosure**: every panel leads with its one-click entry point (Auto in
  Tone, stock cards in Film Lab), deeper machinery exactly one triangle away.

The spec even names the failure mode Lumen currently exhibits: *"the reason darktable
still intimidates despite having this exact feature is that dt defaults to the full set —
defaults, not options, set perceived complexity."* Lumen today has no register at all and
eight flat tabs.

**So the plan is not "invent a new IA". It is "build the IA that was specified and
skipped."** That is a far stronger position: it inherits the reasoning, the competitive
argument, and the owner's own prior sign-off.

`docs/12 §12.1` also already carries the canonical panel order as a table, grouped
**Develop** (WB, Tone, Render, Curve, Presence, Detail/Denoise, Optics) vs **Look**
(Looks, Color, Grading, Film Lab, B&W, Effects), with **Masks floating/docked via a key,
not a tab** (docs/12:108) — which is exactly the 8→2-groups collapse being asked for.

### 4.2 A redesign is already in flight and must be superseded explicitly

`docs/25-design-audit.md` (2026-08-26) is a prior, owner-commissioned visual audit. It
diagnosed "pre-Yosemite utility-panel AppKit" and offered **Option A** (evolutionary) and
**Option B** (Capture One-class). **The owner chose Option A. Steps 1–2 landed** — the
token ladder and type scale now visible in `LumenControls.swift:47-98`. **Steps 3–9 are
open**: section headers, slider polish, filter-bar regroup, footer verbs, grid selection,
the hover/focus modifier, the sidebar pass.

*[Corrected 2026-08-29, after reading the code instead of docs/25's own status line: the
sentence above was taken from that line and it was stale. Commit `a80673c` had already
landed step 6 and most of steps 3, 4 and 7. What genuinely remained is set out at the
foot of Phase 1, and docs/25 now carries a status header mapping every one of its nine
steps to where it went. The lesson, since it will recur across seven phases: **a status
line in a planning document is a claim about the past, and the code is the only record
of it.** Check the code.]*

This refresh must fold those in rather than restart. Several map one-to-one onto the
owner's new complaints (step 5 *is* the filter bar; step 3 *is* the section headers).

`docs/00 §3` sets the amendment rule: *"either the decision is wrong or this document
gets amended explicitly. Nothing drifts silently."*

### 4.3 Law 7 is constitutional, and the colour request amends it

`docs/00-vision.md` Law 7 — chrome is zero-chroma, 18–25% grey — is cited at ~14 sites in
the code. **Both** options in docs/25 declare "Law 7 holds absolutely". The stated reason
is Bartleson–Breneman: a coloured or too-dark surround makes a photographer over-cook
contrast and saturation and deliver bad prints.

The owner's blue→yellow Temp track is therefore a constitutional amendment, not a style
tweak. §5.2 proposes the narrow version and the argument for it.

### 4.4 What will break if touched carelessly

- **The keymap is doubly pinned.** `KeyGrammarTests` reads every `.keyboardShortcut` in
  the app sources *as text* and asserts set-equality against
  `LumenCore/Interaction/KeyGrammar.swift` — **and it runs on Linux**, so it cannot be
  dodged. Every shortcut change needs a same-commit KeyGrammar edit.
- **The publish topology is load-bearing.** `CommandState` and `EditRevision` exist
  because whole-window invalidation per mouse event made every slider tick. A 48-event
  drag may cost `CommandState` exactly one publish, and `DragBroadcastTests` counts them.
  `EditRevision`'s header states the rule: any view reading a recipe **must** declare
  `@EnvironmentObject var edits: EditRevision` or it renders once and never updates again.
- **The slider's geometry is pinned in LumenCore.** `SliderDragTests` bakes in
  320 − 78 − 52 = 158 pt of track. Changing `labelWidth` to fix the truncated labels
  moves a tested constant.
- **135 controls are proof-swept in CI** (`proof.yml`, ~66–80 min, nightly) against
  committed records. Renaming or regrouping controls touches that registry.

### 4.5 Verification is asymmetric — and this is the biggest practical risk

`LumenCore` builds and tests on Linux. **`LumenApp` compiles only on macOS.** Nothing
visual can be verified on the dev machine; the surface checker catches missing symbols
and labels but explicitly *misses everything type-level* — optionality, enum cases,
generics, conformance. The standing history is "one masked macOS compile error per blind
push."

Mitigation, and it is the established pattern: **push every rule that can be arithmetic
or state down into LumenCore where Linux tests pin it** (`InspectionHolds`,
`FrameDelivery`, `ContinuousZoom`, `KeyGrammar` are the precedents), and keep LumenApp as
thin presentation. A workspace/register model is exactly such a rule.

### 4.6 Unbuilt but already-committed spec this refresh should claim

Speed Edit (D44); workspaces + registers (§12.12); canvas-surround control, Lights Out
and ⌘B assessment mode (§12.7/D46); Tab/⇧Tab chrome collapse; TAT; the Looks browser
(§12.9); a history panel; and the remaining D45 slider items — **arithmetic typed entry,
scrubby-drag on the readout, ⌥-scroll, keyboard nudge** — whose stated prerequisite is a
designed focus ring (docs/25 step 8). Those four are precisely the "whatever to speed up
the process" the owner asked for.

### 4.7 A keymap reconciliation is owed

The shipped grammar has diverged from docs/12's canonical map (`L` went to the Look panel
instead of Lights Out, `⌘B` to target album instead of assessment mode, `F` to the
filmstrip, `M` to masks). The code comments defer this to "one deliberate pass over the
whole keymap". A workspace model forces that pass — it needs keys of its own.

## Part 5 — The design

### 5.1 Information architecture: four workspaces, accordions inside

Replace the eight-tab icon strip with the **four workspaces docs/12 §12.12 already
specifies**, each holding a short accordion stack in the canonical order of docs/12 §12.1:

| Workspace | Key | Contains | Sections |
|---|---|---|---|
| **Cull** | `1` | filmstrip/grid, badges, filter popover, no develop column | 0 |
| **Develop** | `2` | White Balance · Tone (Zones inside) · Curve · Presence · Detail (Denoise inside) · Optics | 6 |
| **Grade** | `3` | Looks · Colour (Mixer, Point Colour, B&W) · Grading (wheels, printer lights, primaries) · Film Lab · Effects | 5 |
| **Deliver** | `4` | Soft proof · Export recipes | 2 |

**Masks leaves the tab strip entirely** and becomes a docked panel toggled by `M`,
available in *any* workspace — which is what docs/12:108 already specifies ("floating/
docked via a key") and what masking actually needs, since you mask while developing *and*
while grading.

This preserves D4 — the Develop/Look split is "the split that is the product" — by making
it **spatial** (two workspaces) rather than two tabs among eight.

**Solo mode is the default**, ⌥-click to keep multiple open. Lightroom's most-recommended
setting, and here it is also a performance feature (§5.5).

**Simple register by default**: Develop shows WB, Tone, Presence; Grade shows Looks and
Colour. Everything else is one visible "Show all" click away, with a "4 hidden sections
active" indicator so nothing is ever secret. This is verbatim docs/12 §12.12, and its
own text names the failure Lumen has today: *"dt defaults to the full set — defaults, not
options, set perceived complexity."*

### 5.2 Colour: the Law 7 amendment, stated narrowly

**Amendment to Law 7:** *chroma is permitted in a control's track if and only if that
control's axis is itself a colour direction, at a scale no larger than the 4 pt track.*

Permitted, and nothing else:

| Control | Track |
|---|---|
| Temp | blue → yellow, multi-stop, **computed on the mired axis** so the visual midpoint is the real 5500 K |
| Tint | green → magenta |
| Mixer Hue (per band) | the hue span that band can shift between |
| Mixer Saturation | grey → vivid, in that band's hue |
| Mixer Luminance | dark → bright, in that band's hue |
| Wheel luminance ramps | black → white |

Explicitly **not** coloured: Exposure, Contrast, Highlights, Shadows, Whites, Blacks,
Texture, Clarity, Dehaze, Blending, Balance. Adobe and Capture One both refuse these, and
an exposure ramp would put a light-to-dark gradient beside a photograph being judged for
exposure — the precise contamination Law 7 exists to prevent.

Two consequences from the feasibility survey that must be built in from the start:

- **On a tinted track the gradient IS the track — suppress the deviation fill.** The
  fill-from-default capsule paints solid grey over the groove and would occlude exactly
  the hue information the gradient exists to show. Modified state on those rows rides the
  label brightening, the readout and the section dot.
- **The neutral tick must flip to black/white with opacity**, or it vanishes against
  saturated stops.

Stops are **static constants** in the `Lumen` enum (precedent: `LumenColorWheel.wheelColors`).
Never computed in `body` from recipe values — that would drag `EditRevision` observation
into every track and allocate per pass. Per-frame cost is then effectively zero: the
gradient's identity never changes during a drag; only the thumb offset does.

### 5.3 Colour: one home, one wheel at a time

The split between the Color tab and the Look tab is the ON1 "which panel do I use?"
defect. In the Grade workspace, Colour and Grading become **adjacent sections of one
stack**.

Two learnability changes, both taken from the field:

- **Picker-first mixer** (Capture One's most-praised colour idea): the eyedropper is the
  *primary* control. Click a colour in the photo → that band selects itself and its three
  sliders appear. Today the user must know which of eight bands owns a colour.
- **One large wheel, not four cramped ones.** A `Shadows · Midtones · Highlights · Global`
  segmented control above a single big wheel, luminance ramp below, Blending and Balance
  at the bottom. Lightroom's three-wheel model is the most learnable in the field
  precisely because it shows one thing at a time with fixed spatial meaning.

### 5.4 The chrome the owner named

- **The two-row filter bar is deleted.** Filtering becomes a popover at the filmstrip's
  right edge showing live counts per star/flag/label (Capture One's counts in
  Lightroom's location). The **query sentence survives** — it is the best thing in the
  current bar and better product thinking than Lightroom's — relocated to the status bar.
  Rating input stays keyboard-first (`P`/`X`/`U`, `1`–`5`) plus hover overlays on
  thumbnails. Reclaims two full rows of window height.
- **The sidebar** regroups into: Library (folder, counts) · Albums · Keywords · Stacks,
  each collapsible, inert sections collapsed by default, the teaching paragraph moved to a
  tooltip. `Keyboard` moves to the Help menu where it already has ⌘/.
- **Prose**: the 19 always-visible `caption()` blocks and 18 `note()` blocks adopt the
  ⓘ-collapse mechanism that already exists for `DevelopNote`. The **four `prominent`
  honesty notes stay visible** — they disclose unshipped behaviour and that policy is
  right. Target: no adjustment panel taller than its controls.

### 5.5 What the architecture can afford

From the feasibility survey, and these are constraints on the design, not notes for later:

- **Per-event cost ∝ expanded slider rows in the workspace.** Today one panel of ≤16 rows
  re-bodies per mouse event. A workspace stacking Develop's six sections could put ~40
  rows in scope. Solo-by-default and collapsed-by-default secondary sections are what
  keep this at parity — which is why solo mode is load-bearing, not decorative.
- **`DevelopSection` and `DevelopDisclosure` currently build their content eagerly**
  (`self.content = content()`), so a collapsed section still constructs every
  `LumenSlider` struct on every parent pass. Storing `let content: () -> Content` and
  invoking it inside the `if` makes collapsed sections genuinely free. **This must land
  before workspaces, or the IA change ships a regression.**
- **Layout state never goes on `AppState` as `@Published`.** Expansion is per-section
  `@AppStorage` (persistence free, invalidation scoped) or one small `PanelLayout`
  observable read only by the develop column, with equality-guarded setters on the
  `CommandState` pattern. If the menu bar ever needs a workspace fact, add a sixth field
  to `CommandState` — never forward `PanelLayout.objectWillChange` into `AppState`.
- **Hover is row-local `@State`** in panels; in the grid and filmstrip it is **one
  `onContinuousHover` on the container** deriving an index from geometry, because
  per-cell tracking areas are a measured macOS 15 scrolling cost.
- **The `@Observable` migration stays out of this refresh.** It inverts the semantics
  every rule above depends on and needs its own change with its own measurements.

## Part 6 — Phased plan

Every phase is shippable; `app-bundle` publishes each push to the rolling dev build, so
the owner reacts in the running app. Owner checkpoints marked **⚑**.

### Phase 1 — Legibility and density (low risk, no IA change)

1. **Truncated labels**: `Lumen.labelWidth` 78 → 94; retitle "Uniformity (all bands)" →
   "Uniformity" (its caption already says the rest); update the `SliderDragTests` fixture
   comment, which is prose rather than a pinned property. Track goes 158 → 142 pt, a 10%
   resolution change well under the step-snap floor. Visual pass over the four other
   files sharing the constant (ExportSheet, IngestSheet, EffectsPanel, BasicPanel).
2. **Lazy section content** — the `() -> Content` fix above. Invisible, unblocks Phase 4.
3. **Prose collapse**: `caption()` and `note()` adopt the ⓘ mechanism; four `prominent`
   notes stay.
4. **docs/25 step 3**: section headers — drop the "Default" badge, hover-reveal Reset,
   accent modified dot, 16 pt rhythm, delete panel-internal hairlines. ⚑ *(hover-only
   Reset is a taste call)*
5. **docs/25 step 6**: footer 4×2 icon-tile grid → compact horizontal buttons.

**Correction to items 4 and 5, written after reading the code rather than docs/25's own
status line.** docs/25 says "steps 3–9 are open"; that line is stale. Commit `a80673c`
("the visible half of design step 3-4-6-7") had already landed the Default badge's
removal, the accent dot, the slider fill separation, the grid/filmstrip accent selection
and the footer's tiles → horizontal verbs, and said in its own message that it was
holding two taste calls: hover-only Reset and hover-reveal thumbs.

So what actually remained, and what shipped:

- **Step 3.** The 16 pt rhythm moves out of `DevelopSection` and into
  `LumenSectionHeader.topRhythm`, so a section built by hand out of a header — which is
  how Colour, Look and Masks build all fourteen of theirs — gets the same boundary as one
  built through `DevelopSection`. That is what let the ten inter-section `Divider()`s go
  (2 in Colour, 5 in Look, 3 in Masks), plus the three that fenced the develop column's
  own bands: the section switcher and the footer now sit on `windowBase` 0.18 against the
  body's `panel` 0.20, which is the ladder's own answer to "how do two regions divide".
  **Two hairlines deliberately survive** — ColorPanel's Uniformity rule and ZonesPanel's
  Global rule — because neither fences two sections; each marks a change of *scope inside
  one*, from the selected band to every band, and from per-zone to the whole axis. Space
  alone would read as an ordinary row gap there, and misreading those rows produces a
  wrong edit rather than an ugly panel. Both now carry a comment saying so.
  Hover-only Reset shipped: opacity rather than an `if`, so the header does not reflow
  under the pointer that summoned it. **Still the ⚑ taste call — one line to revert.**
- **Step 4 (thumbs).** `a80673c` held hover-reveal thumbs as the second taste call and
  that hold stands; it is not folded in here.
- **Step 5.** Already done, except that `a80673c`'s comment claimed "borderless at rest"
  while the code painted `controlSurface` under all eight verbs — eight filled rectangles
  at the foot of the column. Now borderless at rest, surface on hover. A rest fill draws a
  *mode*; every one of these fires once and returns.
- **Open question for the owner, not decided here.** All eight footer verbs now have a
  menu item *and* a key equivalent (⇧⌘A, ⇧⌘R, ⌘Z, ⇧⌘Z, ⌘C, ⌘V, ⌥⌘C, ⌥⌘V). Whether they
  still earn two rows at the foot of the develop column is a density call, not a defect,
  so it stays his.

### Phase 2 — Colour where colour is information ⚑

6. Optional `trackStops` on `LumenSlider`; static stop tables in `Lumen`; Temp computed
   through `SliderTrack.fraction(of:)` on the mired axis.
7. Suppress the deviation fill and re-tone the neutral tick on tinted rows.
8. Amend Law 7 in `docs/00-vision.md` and the shared-constraint line in `docs/25`,
   explicitly, per the docs/00 §3 amendment rule.

**What shipped, and the two decisions taken inside it.**

Eleven tracks now carry their own axis: **Temp** (blue→amber), **Tint** (green→magenta),
the mixer's **Hue / Saturation / Luminance** for whichever of eight bands is selected, and
the **lightness bar under each of the four grading wheels**. Every tonal control is
untouched, including the exposure ramp the owner asked for by name — see Part 7 item 1;
that call is still his to overrule and it is one entry in a table.

`LumenTrackStop` anchors a stop to a **value, not a position**, and the track places it
through the same `fraction(of:)` that decides where the thumb is drawn. That indirection
is the whole design: on the mired axis 5500 K sits at 0.663 of the Temp track, so stops
written positionally would have put neutral at the midpoint and called 3850 K white.
Three Linux tests in `SliderDragTests` pin that — the anchors climb in order, both ends
reach the ends, and the midpoint is 3850 K — so the gradient cannot drift from the
control if a range is ever retuned.

- **The mixer's tracks say scope as well as colour.** In *All bands* they go back to the
  neutral groove: a track wearing Blue's colours while the drag also pulls skin toward
  Orange would be the panel lying. The stops are static reference colours built once from
  `bandSwatchComponents`, on the same doctrine as the swatches — the ribbon draws live
  geometry, the tracks say which band you are in. A track that re-coloured itself under a
  Hue drag would be an instrument reporting on itself.
- **The wheel bar is a value ramp, and it needed a bug fixed first.** That bar is a
  `LumenSlider` with an empty title inside a 108-point column, and an untitled row was
  still reserving the full 94-point label column — 158 points of layout asked of 108, with
  the track squeezed to nothing. So the caption under the wheels has been promising that
  "the bar under each wheel is the zone's own lightness" over a bar too narrow to read.
  Untitled rows no longer reserve the label column; Phase 1's 78→94 had made an existing
  defect 16 points worse.

### Phase 3 — Reclaim the chrome ⚑

9. Filter bar → filmstrip-edge popover with live counts; query sentence to the status bar;
   *(shipped, with one deviation from this line — see below)*
   hover rating overlays on thumbnails. *(The owner's culling loop lives here.)*
10. Sidebar regroup into four collapsible sections; prose to tooltips.
11. **docs/25 steps 7 and 9**: grid/filmstrip accent selection, 10 pt stars, sidebar rows.

**Item 9 as shipped — two rows of fourteen become one row of five.**

The strip now holds search, a **Filter** button badged with the number of active
*criteria* (not chips: three flag chips lit is one clause of the query, and a badge
counting chips would say 5 where the sentence says 2), a **Clear** that appears only when
something is filtered, then sort, direction, auto-advance and thumbnail size. Everything
else moved rather than went away — the criteria into the popover, where they finally have
room for **per-chip counts under every star and every label swatch**, and the query
sentence and photo count into the status bar.

Three decisions inside it worth writing down:

- **The popover is anchored to the Filter button, not to the filmstrip's edge as this
  plan said.** The filmstrip is optional in Lumen (`state.showFilmstrip`, and it is
  hidden entirely when the roll is empty), so a filter reachable only from it is a filter
  that disappears. Photomator can anchor there because its filmstrip is permanent.
- **Clear stayed out of the popover, and this is a correctness point rather than a
  layout one.** It carries ⌘\ (docs/10 §10.8, "one key back to everything"), and a
  `.keyboardShortcut` on a view that is not in the hierarchy is never registered — so
  filing it inside a popover would have left the shortcut in the source, still passing
  `KeyGrammarTests` (which reads shortcuts as *text*), and dead in the running app. That
  is the exact class of defect this codebase's honesty policy exists to prevent, arriving
  through the test that is supposed to catch it.
- **The sentence now lives on `LibraryFilter`, not in a view.** Two surfaces read it —
  the status bar shows it, the popover shows the same words back inside the control that
  produced them — and two hand-rolled versions of a sentence that is meant to be
  authoritative is one too many. *Follow-up worth doing separately:* `LibraryFilter` sits
  in `AppState.swift` and so compiles only on macOS, which leaves the query grammar
  docs/10 §10.8 calls a differentiator untestable. Moving it to LumenCore means
  reconciling two different `PhotoFlag`/`ColorLabel` pairs (Int-raw in LumenApp,
  String-raw in `CatalogStore`) — a real refactor, and not one to bundle into a UI change.

**Item 10 as shipped — the sidebar's five jobs become four sections.**

It was an action, a folder path, three counts, three catalog structures and a help button,
stacked with hairlines between them and no grouping, in a column whose own idiom appeared
nowhere else in the app. Now: **Library · Albums · Keywords · Stack**, each a
`LumenSectionHeader` — the same component the develop panels use, which retires the third
of the three hand-rolled caps-label styles the audit counted (§1.2) and lifts it off the
9 pt floor. Rules gone, the header's 16 pt boundary in their place, as in Phase 1.

- **Expansion is `@AppStorage`**, never a published field on `AppState`: it persists for
  free and invalidates this column alone. Keywords and Stack start closed, because both
  are inert until a photo or a stack is selected and both were section-height ways of
  saying "nothing yet". Nothing is secret — a closed section holding state wears the
  accent dot, which is the same mark the develop panels use for "there is something in
  here", now doing the job docs/12 §12.12 asks of its hidden-panel indicator.
- **The near-miss worth recording.** ⌘B, ⌘K and ⌘G all live in these sections, and a
  `.keyboardShortcut` inside a collapsed section is not in the hierarchy and is not
  registered — the identical defect item 9 avoided for ⌘\, one commit earlier, arriving
  by a different door. Every shortcut-bearing button now sits **above the fold**, under
  its header and outside the `if`. That is also just what docs/12 §12.12 asks for on its
  own merits: each section leads with its one-click entry point and keeps the deeper
  machinery one triangle away. **General rule for Phase 4, where whole panels become
  collapsible: a section that folds may not be the only home of a keyboard shortcut.**
- **The culling counts became controls.** "Picked 14" beside an album list that selects
  on click is a row a photographer will click, and it did nothing — which is a good part
  of what "hard to understand" meant. They now write the flag criterion the Filter
  popover writes, and stay in step because both read `state.filter`. "Showing" is gone:
  the status bar says "12 of 239" beside the sentence explaining why.
- The Stack teaching paragraph took the ⓘ row (`DevelopNote`), and its text was wrong as
  well as long — it pointed at "the Metadata chip", which item 9 had just moved into the
  Filter popover. The sidebar's `Keyboard` button is gone; it is ⌘/ in the Help menu.

**Item 11** is complete: accent selection and 10 pt grid stars landed in `a80673c`, and
the sidebar rows landed here.

**Hover rating, the tail of item 9.** Shipped in its own push, so a scrolling regression
would be attributable to exactly one commit. Hovering a grid cell reveals five stars in
the badge strip and each is a target; the strip is unchanged on cells that already carry
a rating, and unchanged everywhere in the filmstrip, whose 96-point cells are too small
for five eleven-point targets. Three things kept it honest:

- **`PhotoCell` stays value-typed.** Its own header states the contract — "it never reads
  AppState, so a rating written three cells away does not invalidate the whole sheet" —
  so the click arrives as a closure. That closure is `AppState.ratingSink`, stored on the
  same `lazy var` pattern as `sliderGestureSink`, because building it inside the grid's
  `body` would mean sixty new closure identities on every pass of a view that re-bodies
  on selection, on scroll and on every culling keystroke.
- **The click selects, then rates.** `setRating` acts on `editTargets`, so a click on an
  unselected thumbnail would otherwise rate whatever was selected elsewhere on screen.
  Selecting first is what every grid in the field does with a click, and it leaves the
  keyboard grammar as the single implementation of what a rating means — including the
  toggle (clicking the third star of a 3 clears it) and auto-advance, which will move on
  after the click exactly as it does after the keystroke.
- **Hover is cell-local `@State`.** Nothing reaches AppState, so a pointer crossing one
  thumbnail invalidates one thumbnail. This is the per-cell `.onHover` §5.5 flagged as an
  unmeasured macOS 15 scrolling cost; the container-level `onContinuousHover` alternative
  it describes remains available, and the reason to take the simple road first is that
  the cost is *unmeasured* rather than known — sixty tracking areas in a lazy grid is not
  obviously the shape that hurts, and one owner session settles it either way.

### Phase 4 — Workspaces and accordions ⚑ (the IA change)

12. `Workspace` model in **LumenCore** — membership, order, register, solo rules — with
    Linux tests. Presentation stays in LumenApp.
13. Four workspaces replacing the tab strip; `1`–`4` keys; accordion sections with
    solo-by-default; expansion in `@AppStorage`/`PanelLayout`.
14. Masks out of the tab strip → docked panel on `M`, available in every workspace.
15. Simple/Full register with the hidden-sections indicator.
16. Same-push counting test: a workspace switch costs one publish; a 48-event drag costs
    `PanelLayout` zero.

### Phase 5 — One home for colour ⚑

17. Colour and Grading adjacent in Grade.
18. One large wheel + `Shadows · Midtones · Highlights · Global` segmented.
19. Picker-first mixer: eyedropper promoted to the primary control, band auto-selects.

**Items 18 and 19 shipped ahead of item 17**, because they do not need the workspaces.
Item 17 is adjacency inside the Grade workspace and therefore waits on Phase 4, which
waits on the slider verification; 18 and 19 are the Look and Colour panels' own
interiors, and they are the half of this phase that answers "going through functionality
for the grading like the colours and stuff is hard to understand and overall clunky".
Neither raises per-event cost — one wheel in scope is strictly less than four.

**Item 18 — one wheel, at more than twice the diameter.** Four 68 pt wheels in a 320 pt
column, in a 2×2 grid with no cue about which zone you were in. A puck is placed by eye
at a radius, so half the radius is half the precision for the same hand movement; that
is the mechanical half of "clunky". Now a `Shadows · Midtones · Highlights · Global`
segmented control over one 150 pt wheel. What one-at-a-time costs is the at-a-glance
answer to "what did I change?", which this app is built to answer down a whole panel — so
`LumenSegmented` gained a `marked` set and each zone holding a grade wears the accent dot,
the same mark a modified section header wears. The dot test is `sat != 0 || lum != 0`,
identical to `isNeutral`'s, so a lit dot and a lit section header cannot disagree; hue
alone is deliberately not enough, because a hue with no saturation grades nothing and
marking it would report a change the picture cannot show.

**Item 19 — the picker is the primary control, and the engine already knew the answer.**
Using the mixer began with a question the panel would not answer: which of Red, Orange,
Yellow, Green, Aqua, Blue, Purple, Magenta owns the colour you want to change? A
photographer knows the sky and the skin; nobody knows which 45° arc of OKLCh they fall
in, and guessing wrong means three sliders that appear to do nothing — the Density lesson
again, arriving through the user's mental model instead of through a disabled control.

The answer lives in **LumenCore**, where Linux tests can reach it:
`ColorEngine.dominantBand` is the argmax of the same membership vector the pixel loop
uses. Reading `bandWeights` rather than comparing against `bandHueCentres` is the whole
design — the ring's handles are draggable, so a widened Blue really does own hues the
default geometry gives to Aqua, and an answer derived from the centres would contradict
the ring on screen. `DominantBandTests` pins that (11 tests), including the reshaped-ring
case and the refusal: a near-grey returns nil rather than a random band, because below
the chroma gate a hue angle is noise and selecting from it would put three sliders in
front of a decision nobody made.

One cost, stated: `selectedBand` and `allBands` moved from `ColorPanel`'s `@State` to
`AppState`, because the pick resolves on the render actor and has to write its answer
somewhere the panel will see. A band click now publishes and re-bodies the window. That
is affordable precisely because it is a *click* — `CommandState` exists to keep per-mouse-
event work off this path, and one publish per deliberate selection is what that budget
was protecting.

### Phase 6 — Speed

20. **Arithmetic typed entry** (`+0.3`, `*2`) — parser in **LumenCore**, Linux-tested.
21. **Haptic detents** at defaults via `.alignment`, gated on *crossing* not proximity.
22. **⇧ fine-drag** — must accumulate per-event deltas or rebase `dragStartValue`;
    `travelled` is currently absolute from `startLocation`, so naive scaling causes a
    mid-gesture jump. Arithmetic into LumenCore first.
23. **Scrubby-drag on the readout** — `DragGesture(minimumDistance: 3)` so tap-to-type
    survives.
24. **⌘K control palette** — type a slider name, it scrolls to and focuses. Nobody in the
    field has this; on macOS it reads as native.
25. **Speed Edit (D44)** — hold a key, drag anywhere on the photo. Capture One's
    most-praised feature; no macOS-native editor has it.
26. **⌥-scroll** last of the six: wheel events have no end phase, so the gesture sink
    needs a timeout or every tick is a SQLite write and a scope re-bin.

**Items 20 and 22 shipped together**, both as LumenCore arithmetic with Linux tests and a
thin wire-up, which is this plan's own "Linux-provable halves first" rule.

**Item 20 — the grammar, and the trap it is shaped around.** `40` and `-40` replace the
value; `+= 0.3`, `-= 0.2`, `* 2`, `/ 2` change it. **Figma's convention — a leading `+`
or `-` is relative — is deliberately not used.** Figma's numeric fields are mostly
non-negative dimensions; Lumen's are Exposure at ±5, the tone sliders at ±100 and Tint at
±150, so typing a negative absolute is routine. The readout pre-fills with the current
value and selects it, so "replace it all with `-40`" is *the* way to set −40 — and under
Figma's grammar that would silently mean "subtract 40 from 30" and land on −10. A control
that quietly does something else with a number a photographer typed is worse than one
that cannot do arithmetic at all. `*` and `/` need no `=` because no number begins with
them. `SliderEntry` also refuses what `Double(_:)` accepts — `nan`, `inf`, `1e999`,
hex floats, `/ 0`, and an *overflowing result* from finite inputs — because a non-finite
value in a recipe is not a bad render but data loss.

**Item 22 — ⇧ fine-drag, and the performance shape that matters more than the maths.**
The arithmetic is as this plan predicted: `travelled` is absolute from the press, so
scaling it the instant ⇧ goes down also scales the travel already spent and the thumb
jumps backward. `FineDrag` carries an anchor that moves only when the modifier does.

The part not predicted here, and the one that would have quietly cost the session's
drag-smoothness work: **a `@State` write is a view invalidation.** A gearbox stored on
every mouse event publishes on every event of every drag — including the majority that do
not move the value, because the pointer has not crossed a step — which is exactly the
per-event cost `CommandState` and `EditRevision` exist to keep off this path. So
`FineDrag.resolving` returns a replacement *only when the gear changed*, and the view
writes only then; the mutating form stays for readability and the tests. `FineDragTests`
pins that as a property, alongside the ones that matter to the hand: toggling ⇧ never
moves the value, twenty toggles do not drift it, and a coarse drag through `FineDrag` is
arithmetically identical to the old direct call at every sample.

⚑ **Blocker found for item 24, recorded before it bites.** ⌘K is taken — it is "Keyword
the selection" in the sidebar, attached to a visible control and in `KeyGrammar`. The
control palette needs a different key, or the keyword verb does, and that is a keymap
decision belonging to **item 30's one deliberate pass over the whole grammar** rather
than to whoever happens to build the palette first.

### Phase 7 — Focus, keyboard, and the owed reconciliation

27. Focus ring (docs/25 step 8): `.focusable()` + `.focusEffectDisabled()` + own ring.
28. Non-published `sliderHoldsFocus` on `AppState` so `KeyDispatcher` yields the arrows —
    it cannot currently see SwiftUI focus on a custom control, so arrows would page photos
    through a focused slider.
29. Keyboard nudge, now unblocked.
30. **The keymap reconciliation** docs/12 and the code comments both defer: shipped
    grammar vs canonical map, decided in one pass, mirrored into `KeyGrammar.swift`.

## Part 7 — Calls I made on the owner's behalf, all overrulable

Stated plainly because the owner was away while this was written, and because each of
these is taste rather than evidence.

1. **Colour only where colour is the axis.** The owner asked for "a light to dark on
   exposure". I have deliberately excluded it: neither Adobe nor Capture One ramps tonal
   sliders, and a light-to-dark gradient sits next to a photograph being judged for
   exposure. If the owner wants it anyway, it is one entry in the stop table — but Law 7
   should then be amended to say so, rather than quietly.
2. **Four workspaces, not one flat six-group stack.** Lightroom cloud proves six flat
   accordion groups is enough, and it would be simpler. I chose workspaces because D4 —
   the Develop/Look split — is described in `docs/00` as "the split that is the product",
   and collapsing it into one stack erases it. If the owner does not care about that
   split, the flat six-group stack is less work and less risk.
3. **Masks leaves the tab strip.** Specified in docs/12, and right — you mask while
   developing and while grading — but it is the biggest change to where things live.
4. **Solo mode on by default.** Lightroom ships it off and it is their most-recommended
   setting; here it is also what keeps per-event cost at parity. Still a taste call.
5. **The query sentence survives** the filter bar's deletion, moved to the status bar. It
   is better product thinking than Lightroom's filter bar and deserves to outlive its
   container.
6. **`@Observable` stays out.** It is the natural end state and would make `EditRevision`
   redundant, but folding it into a UI refresh would make any regression untraceable.
7. **Phase order.** Legibility and colour first because they are pure win at low risk and
   restore confidence before the disruptive IA change. If the owner would rather see the
   4-workspace structure immediately, Phases 1 and 4 can swap — at the cost of judging a
   new IA through the old truncated, prose-heavy panels.

## Part 8 — Documents this one amends

Per `docs/00 §3` — *"either the decision is wrong or this document gets amended
explicitly. Nothing drifts silently."*

- **`docs/00-vision.md`** — Law 7 gains the colour-axis exception. **Due in Phase 2**,
  in the same commit as the first coloured track, not before and not after.
- **`docs/25-design-audit.md`** — its Option A steps **3, 6, 7, 9** are absorbed into
  Phases 1 and 3, and step **8** into Phase 7. Steps 1–2 are already landed. A pointer
  at the head of docs/25 should say so, so the next reader does not execute it twice.
- **`docs/23-master-plan.md`** — the live status doc gains a milestone for this work and
  its checkboxes, updated in the same commit as each phase, per its own rule.
- **`docs/12-spec-ux.md`** — **not** amended. Everything in Part 5 either implements
  §12.12 and §12.1 as written or is a new affordance those sections do not forbid. If
  Phase 4 ends up deviating from the specified workspace names or membership, that is
  the moment to amend §12.12, and the deviation must be argued in the commit.

## Part 9 — Verification

- **Every phase**: `swift test --skip ControlProofTests` green on Linux before push;
  `check-swift-surface.py` clean; CI green on `build-macos`, `test-fast`, `engine-linux`,
  `fixtures-linux`, `app-bundle`, plus `gpu-parity` when Sources change.
- **New platform types** (`NSHapticFeedbackManager`, `KeyPress`, `FocusInteractions`,
  `PointerStyle`, `HoverPhase`) must be added to the surface checker's `KNOWN` list or the
  Linux lane goes red.
- **Every new observable ships with its counting test in the same push**, on the
  `DragBroadcastTests` pattern. This is the tripwire that protects the fix from tonight.
- **Blind-CI discipline**: `LumenApp` compiles only on macOS and the surface checker
  misses everything type-level. So — (a) Linux-provable halves first (the arithmetic
  parser, the fine-drag maths, the workspace model all go into LumenCore with tests);
  (b) quarantine novel APIs into leaf files (`LumenHover.swift`, `LumenFocus.swift`) so
  errors cluster; (c) burn **one deliberate API-probe push** exercising every new
  signature once — focusable + ring, `onKeyPress`, haptics, the scroll shim — before
  wiring anything app-wide.
- **Owner sessions** at the ⚑ marks, per docs/23's standing rule that nothing advances
  unverified. Phase 3 and Phase 4 are the two that change muscle memory and need hands-on
  judgment the same day they ship.
- **Success test, stated now so it can be checked honestly later**: the develop column
  fits its controls without prose; "what did I change?" is answerable down a panel in
  under a second; no window chrome is more interesting than the photograph; and the
  drag-frame budget from tonight's work is unchanged — same `draft` and `after` numbers on
  the LatencyHUD before and after Phase 4.
