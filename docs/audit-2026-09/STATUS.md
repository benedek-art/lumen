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
- [ ] U0 mockup + pitch published → link below
- [ ] W2 audit (3 workflow runs) → `w2/*.md`
- [ ] W3 verify (pipelined) → `w3/*.md`
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
| ff0bf93 | W0 — ledger, briefs, baseline, plan (docs only) | pending |
| _next_ | **W0.7** — N-001: gradient-mask kernels compile again (`long`→`edge`), sentinel widened. A deliberate deviation from find→verify→fix: the finding is CI-log-verified, one file, no stream in flight, and it is the owner's most-felt complaint. **Watch gpu-parity: `MaskGPUParityTests` will RUN for the first time ever** — if parity fails, revert the kernel rename (keep the sentinel) and file for F3/I. | pending |

## Streams (W5)
_not started_

## Notes
- **U0 mockup published**: https://claude.ai/code/artifact/d2b27d8f-e938-4f72-a402-2d638cd52f9b
  (Develop / Masking / Cull scenes, Current ↔ Proposed toggle, live slider states, `B`
  for assessment mode). Awaiting the owner's yes/adjust; UI streams wait on it.
- W1: r1, r2, r3, r5 on disk and committed (944f3da); r4, r6, r7 running.
- d5d7136 (N-001 kernel fix): **gpu-parity FAILED** — first-ever execution of
  `MaskGPUParityTests`. Diagnosing; per the failure protocol a parity mismatch reverts
  the rename and files the defect for F3/I.
