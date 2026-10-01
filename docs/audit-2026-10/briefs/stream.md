# Phase 2/3 stream brief

You own one stream of fixes. Read `common.md` beside this file first.

## Start
Your worktree may have been created from an old `main`. FIRST run:
`git fetch origin claude/jolly-sagan-k7ch7z && git reset --hard origin/claude/jolly-sagan-k7ch7z`
Then read the verifier reports in `docs/audit-2026-10/verify/` that your task names.

## Work
- One commit per defect, each with its test, each test shown RED with the fix substituted out
  (say so in the commit body with the failure count). LumenApp/LumenPipeline changes cannot run here:
  write the test anyway (it runs on macOS CI), trace it by hand against the old code, and say
  "source-verified" in the commit body.
- Where a test file `return`s early on Linux, make the case run on Linux if the code under test is
  LumenCore. A check that never executes is not a check.
- Removing an `XCTExpectFailure` because the defect is now fixed is required, not optional.
- Keep each fix minimal and local to your stream's files. If you must touch a file another stream
  obviously owns (named in your task), keep the hunk tiny and mention it.
- Taste/contract decisions: pick the conservative behaviour that loses no data and moves no pixels for
  untouched controls, implement it, and list it under DECISIONS in your report so the owner can overrule.
  If the only options all change the look of existing edits, do NOT implement; spec it under DECISIONS.
- Before finishing: `swift build --build-tests --scratch-path /tmp/lumen-build-<you>` clean, your suites
  green, `python3 scripts/check-swift-surface.py` exit 0.

## Finish
Commit your report at `docs/audit-2026-10/streams/<your-name>.md` IN YOUR WORKTREE (writes to the main
tree are refused): per item — status (FIXED / PARTIAL / NOT-FIXED / NOT-A-DEFECT), commit SHA, red/green
evidence, proof records that move (or "none"). Then DECISIONS and FOUND-WHILE-FIXING.
Final message: a short table plus your branch name and commit SHAs. Do not push.
