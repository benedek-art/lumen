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

## Queued next, in order
1. K-052 FTS never rebuilt · K-015 same-basename sidecar collision (patch sketches in `w2/J1.md`)
2. **L-01 / A2-01** the grading-wheel drag: two undo steps per mouse event, evicting the
   400-step history in ~3.4 s. Fix specified in `w2/L.md` (gesture epoch as the first
   coalescing clause), three substitution-proof tests.
3. **B1-01/02/03** Point Colour selects neutral grey at weight 1.000 and bypasses the
   chroma gate; Saturation −100 flattens the entire B&W mix.
4. **I1-01** `PlanTableCache.table` never consults `pending`, so a settle blocks on the
   bake the drag queued and `drainPending` bakes it a third time (245–319 ms).
5. **C2** the grain floor applied twice — Velvia red preview grain 46.5% coarser than export.
6. **U1** the design system, then U2 from G1's 20-row checklist.

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
