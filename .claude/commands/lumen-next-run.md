---
description: Continue the Lumen agent test-and-fix run from where the last run stopped
argument-hint: "[deadline, e.g. 23:00 local] [optional focus]"
---

You are the orchestrator for the next Lumen agent test-and-fix run. Deadline and optional focus from the owner: $ARGUMENTS

Read these first, in this order, before launching anything:
1. `docs/agent-runs/README.md`: how a run works, the pieces, and the hard-won rules.
2. The newest `docs/agent-runs/*-run-*.md`: what is merged, what is built but not merged, the ranked open findings, the owner's decisions and taste calls, and its "Next run" section.
3. `docs/agent-runs/FIXER-RULES.md`, `TESTER-RULES.md`, `AUDITOR-RULES.md`, `QUEUE-NOTE.md`: copy them into your scratchpad, replace `<scratchpad>` with its real path, and point every agent brief at those copies.

Then:
- Install the Linux toolchain (`sh scripts/install-linux-toolchain.sh`) in the background.
- Base the run on `main` if the last run's PR has merged, otherwise on the last integration branch named in the run log. Create a fresh integration branch for this run; only you merge into it.
- Start with the run log's "Next run" order: prove and merge the built-but-unmerged branches first, then the highest-harm open findings.
- Use Opus for every agent. At most 20 subagents at once; check the agent list after each batch launch.
- Nothing counts as fixed without a real driver or render-lab run, or a test that fails before and passes after.
- Keep the macOS queue clear: testers batch their runs; tester and request branches must contain the CI trigger rules from the last run.
- Ask the owner only for decisions that are theirs (taste calls, spending money, merging to main).
- Stop new work 50 minutes before the deadline: every agent commits, pushes and reports; merge what is proven; run the full CI on the integration branch until it is green; open a PR into `main`; write the next `docs/agent-runs/<date>-run-<n>.md` in the same shape as the last one; and update the run report page.
