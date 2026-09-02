# The grind — live status

The resume point. After a container reset or a context compaction, do this and nothing
else first:

```
git fetch origin claude/photo-editor-design-plan-8ahzmm
git reset --hard origin/claude/photo-editor-design-plan-8ahzmm
cat docs/audit-2026-09/STATUS.md
```

Then relaunch the briefs under `briefs/` whose output files are missing, and continue
from the first unchecked wave below. The plan is `/root/.claude/plans/enchanted-skipping-rocket.md`
(also mirrored as `docs/audit-2026-09/PLAN.md`).

## Decisions (owner's; never re-ask)
Find first, then fix · backlog first, then new · publish `dev-latest` on every green
landing · involvement: the U0 mockup checkpoint only, then the report · all docs/32 §4
deferrals lifted · UI: Option B "Modern pro", whole · rows 24 pt · keymap: `L`→Lights
Out, `B`→album, `⌘B`→assessment, `F`/`S` stay · denoise: free + best, delivery mine
(download-on-first-use), timing mine.

## Waves
- [x] W0 — ledger K-001…K-104, perf baseline, 42 briefs
- [x] W1 — 7 dossiers + gap table
- [x] U0 — mockup published and **APPROVED** by the owner ("build it")
- [x] W2 — **13 of 13 areas audited** (the trimmed set): C1 F3 F5 · A2 B1 C2 F1 F4 G1 G2 I1 J1 L
- [ ] W3 — verification of the ~90 findings W2 produced
- [ ] W4 — triage into landing order
- [~] W5 — implementation IN PROGRESS, see Landings
- [ ] W6 — re-audit, perf after, docs/38, report

## Decisions taken since the plan
- Audit trimmed from 30 areas to 13 (owner: "trim discovery, spend it on fixes").
- **L0 dropped** — the four-file `AppState` split. The L audit confirms it was right:
  7 privates would widen across stream boundaries, 73 `@Published` and 13 `didSet`
  cannot move, and it is unverifiable locally on the SHA every worktree branches from.
- **Two UI-direction entries corrected** where the approved mockup silently reverted the
  owner's own recorded requests (see PLAN.md §The UI direction): radii stay 6/9/14, and
  hover paints only clickable things, never a slider row. His words beat my mockup.
- **One fix refused**: writing `xmp:Rating` = −1 for a reject. It broke a pinned
  contract (`testFlagAndRatingSurviveEachOther`) that exists so a frame can be four
  stars AND rejected. The read half landed; the interop gap is written up.

## Landings (SHA · what · CI)
| SHA | Landing | CI |
|---|---|---|
| cc82116 | base | green |
| d5d7136 · 64ae6da · fce5936 | N-001: three dead GPU mask kernels revived (two reserved words, then a vertical flip); checker pass 13 + 2 fixtures | gpu-parity **green** on fce5936 |
| 903ad4d | `ci.yml` `paths-ignore: docs/**` | green |
| 6f07572 | **F3-01** canvas gesture no longer writes to every selected photo · **F3-03** an absent mask input no longer selects the whole frame when inverted | in 27b8372's run |
| 2083f92 | **F4-01** picker flags keyed by mask · **F4-02** `MaskSelection.activeComponent` — a disclosed-but-unselected mask stops editing another mask's component | cancelled by the next push |
| 27b8372 | **F1-01** Delete removes the mask, not the photograph | build-macos ✅ app-bundle ✅ engine-linux ✅ fixtures ✅ test-fast running |
| 7bd7fdf | **K-053** a rating keystroke stops deleting another tool's colour label · **K-054** Lightroom's reject survives the trip in | held until 27b8372 reports |

**Seven S1s landed.** Four were found tonight (F3-01, F3-03, F4-01, F4-02); two of those
were regressions in code that shipped this morning.

## Landed, batch 2 (after ac5570d)

| SHA | Landing | Proof |
|---|---|---|
| 31ef62a | **L-01 / A2-01** a grading-wheel drag is one undo step, not two per mouse event — gesture epoch as the first coalescing clause | substitution: "480 is not equal to 1 — a four-second wheel drag produced 480 undo steps" |
| 3fbb096 | **B1-02** Point Colour stops rotating the hue of near-neutrals — chroma gate hoisted out of the Variance branch | substitution: "60.00000000000068 is not less than 1.0", both controls stay green; `pointColor.hue` proof record expected to move — re-pin pending the local drift run |
| cf9fb58 | **I1-01 + I1-03** a settle joins or steals the bake the drag already queued (245–319 ms off the release of Whites/Saturation); background bakes and joins counted on the HUD (`d`/`j`); `resetStats` zeroes per-slot traffic too | substitution in two rounds: read-side door removed → "2 is not equal to 1"; store-side pending clear removed → "baked twice: once by the settle and once again by the drain" |
| 56008bf | **C2-01** (corrected) the blue grain record is the same texture in preview and export — one half-pixel floor, not two | 5 tests; the red/green no-op is pinned across 6 stocks × 4 resolutions |

**Audit corrections made while landing** — recorded because W3 would otherwise re-find them:
- **C2-01 named the wrong channel.** The double floor is provably a no-op for `sizeScale ≤ 1`
  (red 0.8, green 1.0): `max(max(x,½)·s, ½) = max(x·s, ½)` for `s ≤ 1`. It is real for BLUE
  at 2.0 (Velvia 17.2 %, Ektar 0.45 % preview↔export divergence → exactly 0 after). The
  red 46 % / green 17 % divergences the finding headlined are the floor itself and need
  R7 C.2.3's band-limited plate — **still open**, filed as C2-01b.
- **G2-12's glyph radius** (2.5 in `LumenBehaviourGlyph`) is correct: the canvas is 14 pt
  tall, the box ~8, and `radiusChip` on it is a capsule. Reverted with the reasoning in
  the file.
- **G2's "pitch = 24" for the slider row** would have made the column tighter than the
  build the owner called "back to back to back" — his words beat the mockup (third time
  this round: radii, hover, now pitch). Reconciled: row 24 (his number), inner air kept,
  the vestigial outer point (it separated HOVER fills, and hover is gone) dropped →
  pitch 28, on the grid, exactly what he approved.
- **The mockup's focus ring** on slider rows contradicts *"it gets a blue border around
  it, which I don't want"* (`LumenFocus.swift`). Scoped: rows keep `lumenFocusSurface`;
  `lumenFocusRing` exists for controls with no groove (menu trigger, switches).

## U1 — in progress on the tree (uncommitted until the drift run frees `.build`)
Tokens: text 0.86/0.62/0.48 · `hoverLift` +0.03 additive via `Lumen.hovered(on:)` ·
`focusRing` accent@60 1.5 pt · `hudFill` black@72 + `lumenHUD()` · `rowHeight` 24 ·
type 12 semibold / 11 / 10 / 11 tabular. Radii **unchanged** (6/9/14 + `radiusTab` 12 —
the rail tab's own argument stands). 53 section headers to mixed case through
`.lumenHeading` (it had zero call sites); `LumenCapsLabel` to one size (10). Cursor leak
(G2-05) closed by one balanced modifier for all three cursors. Switch spring 0.22→0.12;
checkbox hover on the surface not `.brightness`. Menu: hairline retired, glyphs to the
10 pt floor, trigger gets additive hover + focus ring. Slider readout is a pill (well
fill, modified border in the 0.72 grey), `valueWidth` 44→48 with the pill's air inside
the column. Badge → HUD pill. `DesignSystemTests`: three prohibitions (no hover/ring on
the slider row, headings through the token, cursor pushes only through the modifier) and
five ratchets (raw font sizes 199, 9 pt 37, raw radii 34, hand-rolled HUD fills 19).
**Correction to d15e663's own message:** it says the slider row's pitch becomes 28. It
does not — the row is 24, its padding makes 28, and the panels stack rows at
`VStack(spacing: 2)`, so the pitch is 30. The touch target (28) and the owner's row
number (24) are both right; the stack's two points are U2 item 5's, changed per file
with each stack's contents read rather than by a blind sweep of thirty-one sites. The
comment in `LumenControls.swift` now carries the arithmetic.

**And `valueWidth` is 52, not the 48 that first landed.** G1 §2 measured the binding
case — Black target's `15.000` at three decimals, 41.2 pt while scrubbing, where the
readout goes medium weight — and said a pill needs ≥ 52. At 11 pt that is ~37.8, which
makes 48 sufficient by two tenths of a point: inside the error of estimating a font
metric, for four points of track worth 0.03 pt per unit at the default width.

**Deferred to U5:** toggle-row keyboard focus — space is a global hold key in `Keymap`,
so the row would need the dispatcher yield the slider has.

## Queued next, in order
1. Commit + push U1 once `DesignSystemTests` runs; watch build-macos closely — twelve
   app files with no local compiler.
2. Re-pin `pointColor.hue` if the drift run reports it moved (ceremony per PLAN.md).
3. K-052 FTS never rebuilt · K-015 same-basename sidecar collision (`w2/J1.md`)
4. **B1-01** Point Colour sigmas (proof ceremony) · **B1-03** Saturation −100 kills the B&W mix
5. **I1-02** the DragProbe settle row samples values the draft never visits · **I1-04** the
   `anyBakePending` settle loop re-renders whole frames while waiting
6. **C2-01b** band-limited plate (the real red/green parity fix) · **C2-02** colour stocks
   lay three decorrelated fields (chroma noise 2.45× luma) · **K-065** grain before resize
7. **U2** panels to the grid from G1's checklist · U3 shell + keymap · U4 viewer/masks · U5

## Rule learned: docs-only pushes cancelled the code push's CI
`ci.yml` triggered on every push and its concurrency group cancels in progress, so
each STATUS/ledger push cancelled the run verifying the previous code push — and its
`app-bundle`. Fixed in `ci.yml` with `paths-ignore: docs/**`. For W5: commit docs with
the code they describe, and never push prose while a code run is in flight unless
the run is already past `app-bundle`.

## Mechanism change (W2/W3), recorded
The Workflow tool caps concurrency at min(16, CPUs−2) per run and this box has 4 CPUs
→ 2 agents at a time; a 30-area run would take hours. The Agent tool fan-out ran seven
research agents concurrently without a cap, so W2 audits run that way (one background
agent per area, briefs unchanged) and W3 runs as **two independent refuters per area**
— lens A (by-design / already-fixed / duplicate / scope) and lens B (evidence /
severity / numbers / reproducibility / the test) — writing `w3/<code>-a.md` and
`w3/<code>-b.md`. W4 treats a finding as CONFIRMED only when both lenses confirm it.
The per-finding refuter design stays in `briefs/w3-common.md` as the standard each
lens applies to every finding.

## W2 progress
- 21:52 launched F1–F5, I1–I3 (masks + pipeline) — before the gap table, since those
  areas lean on code and K-rows.
- 21:57 gap table landed (a60b016); launched A1, A2, B1, B2, B3, C1, C2, D1, D2, E1,
  E2, G1. **The Agent tool caps at 20 concurrent** — G2, G3, H1, H2, J1, J2, J3, K, L,
  M are queued and launch as the first batch frees slots (~22:22). On a reset: launch
  any area whose `w2/<code>.md` is missing, 20 at a time.
- W3 (two lenses per area) launches per area as its `w2/<code>.md` lands.

## Streams (W5)
_not started_

## Notes
- **U0 mockup published**: https://claude.ai/code/artifact/d2b27d8f-e938-4f72-a402-2d638cd52f9b
  (Develop / Masking / Cull scenes, Current ↔ Proposed toggle, live slider states, `B`
  for assessment mode). Awaiting the owner's yes/adjust; UI streams wait on it.
- W1: r1, r2, r3, r5 on disk and committed (944f3da); r4, r6, r7 running.
- N-001 chain: d5d7136 (`long`→`edge`) → sentinel found `maskFold` dead too → 64ae6da
  (`out`→`folded`, checker pass 13) → parity tests ran for the first time: **GPU alpha
  vertically mirrored** (23 failures / 3 tests) → flip fix pushed. **64ae6da's dev
  build drew mirrored gradient masks** (app-bundle publishes regardless of tests) —
  superseded within ~15 min. Lesson for W5: an engine landing that un-skips tests can
  ship a regression through app-bundle before the lane reports; treat "first real run
  of a previously-skipped test" as an engine-window event.
