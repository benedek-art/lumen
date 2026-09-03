# W2 audit — common brief

You are one of thirty auditors. You own ONE area, listed in your own brief. Thirty
people reading the same 76k lines for different questions is only efficient if each
reads exactly their files for exactly their question — so stay inside your list, and
where a file is shared, answer only the question your brief says you own in it.

## Read first, in this order
1. `docs/audit-2026-09/PLAN.md` — the plan; especially §"Decisions already taken" and,
   for UI areas, §"The UI direction" (the direction is DECIDED; do not re-propose one).
2. `docs/00-vision.md` — the laws. `docs/12-spec-ux.md` for anything UI. `docs/20-proof-standard.md` — what "proven" means here.
3. Your area's spec docs (in your brief).
4. `docs/audit-2026-09/w1/gap-table.md` — your area's section: how the competitors do
   it and what Lumen has. (If the file is not there yet, read the relevant `w1/r*.md`
   sections directly.)
5. Your area's rows of `docs/audit-2026-09/ledger.md` (listed in your brief).
6. Then EVERY LINE of your owned files. Not a skim. The defects this codebase ships
   are "built but unwired" and "comment says X, code does Y" — neither is visible from
   a summary.

## Two lessons from this morning, so you do not repeat them
- **A green lane is not evidence.** `MaskGPUParityTests` was green for months because
  it skipped itself (`XCTSkipUnless`) when the kernels it tests failed to compile. Look
  for skips, for sentinels whose roster is incomplete, for tests that pass when the
  feature's call site is deleted. Cite them as findings.
- **The comment is not the code.** `componentParameters` returned `EmptyView()` for
  brushes with a comment saying the brush zone draws them — and the brush zone had
  been deleted. Read what the code reaches, not what the prose says it reaches.

## Known-open rows first
For each `K-nnn` row assigned to you: STILL-OPEN / FIXED-SINCE / CHANGED (say what
changed), with `file:line` evidence. One line each. Do not re-describe the finding;
cite its id. If you find it was never true, say REJECTED and why.

## Then new findings — at most 20, ranked, prefer fewer and stronger
Each finding, in this exact shape:

```
### <AREA>-<nn> — <title, one line>
severity: S1 | S2 | S3          (S1 data loss / crash / wrong pixels / silent no-op control;
                                 S2 visible defect or parity gap; S3 polish)
confidence: measured | traced | inferred
class: defect | parity-gap | proposal(taste)
size: S | M | L
evidence: <file:line> — quoted code, and for perf a NUMBER or a traced call count
how the owner sees it: <one or two sentences — what happens on screen / to the file>
fix: <files, approach, and THE TEST that goes red with the defect substituted back>
```
"Slow", "confusing", "could be better" are not findings without a number, a trace, or a
concrete gap-table row. A `proposal(taste)` must say which decided direction it fits.

## Output
- Write `docs/audit-2026-09/w2/<code>.md`: a header with your area and files read,
  the known-open dispositions, then the findings.
- Return a ≤150-word receipt: counts by severity, the two findings you are surest of,
  the file path. The file is the deliverable; the return is a receipt.

## Rules
- READ-ONLY. No edits to any file except your own output. No git. No builds that write
  (you may run `swift test --filter <X>` on LumenCore; never `swift build` of the app —
  LumenApp and LumenPipeline do not compile here and that is expected).
- 30 minutes. Past that, write what you have, mark the file PARTIAL at the top, return.
- No model names, no session ids in the file.
