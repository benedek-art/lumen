# Phase 1 verifier brief

You are an ADVERSARIAL verifier. PR #5 (Codex "Astra" repair programme) landed fixes that its own
ledger marks "verifying". Your job is to try to DISPROVE each fix assigned to you, against the code as
it stands on this branch. Default to skepticism: a fix is CONFIRMED only when you have seen the
mechanism in code AND seen its regression test go red with the fix substituted out (do it: revert
the relevant hunk temporarily in your worktree, run the filtered test, restore). For code in
LumenApp/LumenPipeline that cannot compile here, reason from source and say "source-verified only".

The ledger is `docs/audits/2026-09-22-astra/repair-ledger.json`; the original findings with
reproduction detail are `docs/audits/2026-09-22-astra/findings.json`; execution records
`EXECUTION-0*.md`. Find the commit for a finding with `git log --oneline origin/main..HEAD -- <file>`
or `git log -S`/`--grep`; many ledger rows have `commit: null` (cc30178, 40e1048, 41a50d8, 2c70752,
ad1e7c4, 6566cdf carry several each).

For each finding decide:
- CONFIRMED — fixed, test is substitution-proof, no regression found.
- WEAK-TEST — fix is right but the test cannot fail / does not cover the finding's trigger. Say exactly what test is missing.
- INCOMPLETE — fix covers part of the trigger space. Give the concrete uncovered input.
- WRONG — fix is incorrect or introduces a regression. Give the reproducer.
- Also note any collateral regression the commit caused elsewhere.

You MAY fix a WEAK-TEST or small INCOMPLETE finding yourself in your worktree (tests + minimal code),
committing locally with a proper message; leave anything larger for Phase 2 with a precise spec.
Do NOT push.

Write your report to the ABSOLUTE path given in your task (a markdown file in the MAIN tree, not your
worktree): a table of finding → verdict → evidence (commands run, red/green counts), then for each
non-CONFIRMED a "Phase 2 spec" paragraph (files, exact trigger, acceptance test). Finish with the
names of any local commits you made and your worktree branch name.
Your final message: the verdict table plus your worktree branch name and commit SHAs.
