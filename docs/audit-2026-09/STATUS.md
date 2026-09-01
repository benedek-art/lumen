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
- [x] W0.1 tree synced to origin `cc82116`
- [x] W0.2 ledger skeleton created
- [x] W0.3 web access probed — WebSearch works; WebFetch blocked on adobe/arxiv/darktable-docs/rawpedia/wikipedia, **works on github.com + raw.githubusercontent.com**
- [x] W0.4 perf baseline captured → `w0/perf-baseline.md` (from gpu-parity run 33553464942)
- [x] W0.5 known-open ledger written → `ledger.md` (K-001…K-104)
- [x] W0.6 W1 briefs written → `briefs/w1-*.md` (common + R1–R7 + R-S)
- [x] W1 research: R1–R7 all landed and committed (944f3da, 5f043c3, +r4/r7); R-S synthesis running → `w1/gap-table.md`
- [x] U0 mockup + pitch published → link below (awaiting the owner's yes)
- [ ] W2 audit (Agent fan-out, 20 at a time) → `w2/*.md` — 20 running, 10 queued
- [ ] W3 verify (two lenses per area) → `w3/<code>-a.md`, `w3/<code>-b.md`
- [ ] W4 triage → `ledger.md` rows dispositioned, `w5/streams.md`
- [ ] W5 L0 foundation split landed
- [ ] W5 J data-loss batch landed
- [ ] W5 L recipe-safety batch landed
- [ ] W5 engine window 1 landed + proof ceremony
- [ ] U0 yes received → UI streams unblocked
- [ ] W5 U1 design system landed
- [ ] W5 U2/U3/U4 landed
- [ ] W5 engine window 2 landed + proof ceremony
- [ ] W5 U5 polish landed
- [ ] W6 re-audit, perf after, `docs/38-the-grind.md`, report artifact

## Landings (SHA · what · CI)
| SHA | Landing | CI |
|---|---|---|
| cc82116 | base — masks panel per-mask disclosure, placement, drag, overlay draft | green |
| ff0bf93 | W0 — ledger, briefs, baseline, plan (docs only) | green |
| d5d7136 | W0.7a — N-001: `long`→`edge` in the linear/radial kernels; `unavailableMaskKernels` roster; sentinel widened | gpu-parity red: sentinel found `maskFold` dead too (expected class of failure) |
| 64ae6da | W0.7b — `out`→`folded` in `maskFold`; checker pass 13 (kernel reserved words) + 2 fixtures | gpu-parity red: **parity tests ran for the first time — GPU alpha vertically mirrored** (23 failures). Dev build mirrored for ~8 min. |
| fce5936 | W0.7c — `h − (y − oy)` in both generator kernels | **gpu-parity GREEN** (33563101474). ci.yml pending. N-001 closed. |
| a60b016 | W1 closes — gap table, W3 brief, mechanism change (docs only) | — |
| a1e13c8 | N-001 closed in ledger/status (docs only) | — |
| 903ad4d | ci.yml `paths-ignore: docs/**` — docs pushes no longer cancel code runs | pending; this run is fce5936's code + the yml |

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
