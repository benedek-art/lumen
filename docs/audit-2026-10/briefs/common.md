# Common brief — every October agent reads this first

Repo: /home/user/lumen (or your worktree). Lumen is a macOS RAW editor in Swift: `LumenCore`
(pure Swift, builds and tests on this Linux box), `LumenPipeline` + `LumenApp` (macOS only; CI compiles them).

## Tooling
- `export PATH=/opt/swift/usr/bin:$PATH`
- Use YOUR OWN build dir so parallel agents do not fight over `.build`:
  `swift build --build-tests --scratch-path /tmp/lumen-build-<yourname>` then
  `swift test --skip-build --scratch-path /tmp/lumen-build-<yourname> --filter <Suite>`.
  The machine has 4 cores shared by ~6 agents: filter tests, never run the whole suite more than once.
- `python3 scripts/check-swift-surface.py` — the only local check on LumenApp/LumenPipeline. Read its EXIT CODE.
- Context: `docs/audits/2026-09-22-astra/` (Astra audit: findings.json, repair-ledger.json,
  REPAIR-PLAN.md, EXECUTION-0*.md, SUPPLEMENTAL-BACKLOG.md), `docs/audit-2026-09/` (the September
  Claude audit: STATUS.md, w2/*.md findings, w3/dispositions.md), `docs/38-the-grind.md`, `BUILDING.md`.

## Discipline (non-negotiable; each was learned by a defect shipping)
1. A fix lands with a test that goes RED when the fix is substituted back. Do it: break, watch red, restore.
2. A check that cannot fail is not a check. Watch for tests that skip, early-return on Linux,
   collapse duplicates into Sets, sweep only a diagonal, or match words in comments.
3. Never skip, disable, loosen, or XCTExpectFailure a test to get green. Removing an
   XCTExpectFailure because the defect is now FIXED is correct and expected.
4. A change that moves rendered pixels for any of the 135 proof records in the control registry must
   say so explicitly in your report (which records, why) — the owner re-pins them through proof.yml.
   Prefer fixes that are identity for untouched controls.
5. Do not make taste decisions for the owner. Anything that changes the look of a default, a UI
   direction, or a documented contract goes in your report as a DECISION NEEDED, not into the code.
6. No model names/identifiers in any file or commit message.
7. Commit messages: this repo's style is a plain sentence describing what was wrong/what changed
   (see `git log`), body explains mechanism and measured evidence. End every commit message with:
   Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01Qi55kk4VMTq7EAVRaZaHyR
8. Do NOT push. Do NOT touch any git remote. The orchestrator lands and pushes.
