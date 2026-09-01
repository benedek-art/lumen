# W3 verification — common brief

You are one of two independent verifiers for ONE audit area. Your job is to **refute**
what the auditor wrote. Findings that survive both of you reach the implementation
wave; findings either of you rejects do not. You never see the other verifier's work.

Input: `docs/audit-2026-09/w2/<code>.md` (the auditor's file) and the auditor's brief
`docs/audit-2026-09/briefs/w2-<code>.md` (so you know what files and questions were in
scope). Repository root: `/home/user/lumen`, at HEAD.

## The rule that applies to every finding
Do not trust the auditor's quotation. Open the cited file at HEAD and read the
surrounding sixty lines yourself. If there is no `file:line`, the finding is REJECTED
for lack of evidence, whatever its prose says.

## Lens A — "is this even a defect?"  (`w3/<code>-a.md`)
For each finding and each known-open disposition:
1. **By design?** Read the doc comment above the cited code. This codebase explains its
   deviations in prose — grep the file for `deliberately`, `on purpose`, `the fix is`,
   `NOT a`, `used to`. A documented decision that the auditor disagrees with is a
   `proposal(taste)`, not a defect; downgrade it and say so.
2. **Already fixed?** Is the quoted code actually present at HEAD? `git log -3 --
   <file>` is allowed (read-only). Cite the commit if it was fixed.
3. **Duplicate?** Is it a K- row in `docs/audit-2026-09/ledger.md` under another id, or
   the same defect the auditor also filed under a different finding? Name the id.
4. **Scope?** Is it inside the files the brief assigned? A finding about another area's
   file is routed, not rejected — say which area.

## Lens B — "does the evidence hold, and is the severity right?"  (`w3/<code>-b.md`)
For each finding:
1. **Does the quoted code do what the finding says it does?** Trace the call path two
   hops each way. A control "wired to nothing" needs the grep that shows zero callers.
2. **Severity.** S1 = data loss / crash / wrong pixels in the delivered file / a control
   that silently does nothing. S2 = a visible defect, or a parity gap against a concrete
   row of `w1/gap-table.md`. S3 = polish. Re-assign if the evidence supports a
   different tier, and say why.
3. **Numbers.** A performance claim without a number or a traced call count is
   REJECTED. If a LumenCore test can measure it on this box in under two minutes
   (`/opt/swift/usr/bin/swift test --filter <X>`), run it and report the number.
4. **Reproducibility.** If the ONLY way to know is a macOS compile or run (LumenApp and
   LumenPipeline do not compile here), the verdict is PLAUSIBLE_NEEDS_MAC — and say
   which existing test in `Tests/LumenPipelineTests` or `Tests/LumenAppTests` would
   prove it, or that none does.
5. **The fix and its test.** Does the proposed fix touch only files the plan's W5
   ownership map (`docs/audit-2026-09/PLAN.md` §W5) gives to that area's stream? Would
   the proposed test actually go red with the defect substituted back? If the finding
   has no test, say what one would be.

## Verdicts
`CONFIRMED` · `PLAUSIBLE_NEEDS_MAC` · `REJECTED` · `DUPLICATE(<id>)` · `ROUTE(<area>)`
Default to REJECTED when the evidence does not hold up. A verifier who confirms
everything has not verified anything.

## Output
Write `docs/audit-2026-09/w3/<code>-<a|b>.md`:
- a table: finding id · title (short) · auditor's severity · your verdict · your
  severity · one-line reason naming the file:line you checked;
- the known-open dispositions you disagree with, with why;
- "Confirmed, ranked" — the CONFIRMED ids ordered S1 → S3;
- "Needs a Mac" — ids with the test that would settle each.
Return a ≤120-word receipt: counts per verdict, the file path.

## Rules
Read-only outside your one output file. No git writes. 20 minutes; past it, write
what you have, mark PARTIAL, return. No model names, no session ids.
