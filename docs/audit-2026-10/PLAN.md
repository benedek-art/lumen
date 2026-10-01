# October run — plan and resume point

Trunk: `claude/jolly-sagan-k7ch7z` = `main` + PR #5 (`codex/lumen-verified-repairs`), merged 5047f1b.

After a container reset: `git fetch origin claude/jolly-sagan-k7ch7z && git reset --hard origin/claude/jolly-sagan-k7ch7z`,
read this file and `STATUS.md`, relaunch any stream whose report under `verify/` or `streams/` is missing.

| Phase | What | Output |
|---|---|---|
| 1 Verify | 7 adversarial verifiers over PR #5's repairs and the 4–6 Sept commits | `verify/V*.md` |
| 2 Fix | ~20 streams in waves of ≤6, worktree per stream, one push per wave behind CI | `streams/*.md` |
| 3 Features | GPU denoise, LUT stage, HDR viewport groundwork, Heal slice, slider a11y, batch geometry | `streams/*.md` |
| 4 Close | re-audit, perf, docs/39, owner report | `docs/39-*.md` |

Rules carried from the September runs: push after every verified landing; ≤6 agents at once;
every fix has a test shown red with the fix removed; LumenApp/LumenPipeline compile only on CI
`build-macos`, so `scripts/check-swift-surface.py` (exit code, not grep) is mandatory locally;
pixel-moving changes go through the proof ceremony (`proof.yml`); no model identifiers in pushed text.
