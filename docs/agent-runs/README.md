# Agent test-and-fix runs

How to run, and continue, a session where one orchestrator agent sends out fixer and tester agents against the real app. Run 1 is written up in `2026-11-26-run-1.md`; read that for what was covered and what is still open.

## Starting the next run

Open a new Claude Code session on this repo, use Opus as the orchestrator, and paste:

> Continue the Lumen agent test-and-fix run. Read `docs/agent-runs/README.md` and the latest `docs/agent-runs/*-run-*.md` first. Start from the "Next run" section of the latest run log. Develop on a new integration branch created from `claude/loving-cray-d58nrb-integration` (or from `main` if that PR has merged). Use Opus agents only. Stop new work 50 minutes before my deadline of <time>, then merge what is proven, open a PR into `main`, and update the run log.

## The pieces

| Piece | What it is | Where |
|---|---|---|
| Driver | Runs the real app on a hosted `macos-15` runner and drives it with real HID mouse, trackpad and key events. Returns screenshots, a state dump, a frame timeline and a pass/fail verdict per scenario. | `driver/README.md`, `Sources/LumenApp/Driver/`, `.github/workflows/driver.yml` |
| Render lab | Recipe in, pixels and stats out, through the app's real export and viewer render paths on macOS, plus a Linux reference lane that runs locally in seconds on charts and decoded RAW "plates". Contact sheets, viewer-vs-export compare, 1:1 crops. | `renderlab/README.md`, `renderlab/CONTROLS.md`, `.github/workflows/render-lab.yml` |
| Area map | 30 test areas covering the whole app: every control, shortcut and journey, with what correct looks like and the known gaps. | `driver/AREAS.md` |
| Fixer rules | Shared brief every fixer reads first. | `docs/agent-runs/FIXER-RULES.md` |
| Tester rules | Shared brief every tester reads first. | `docs/agent-runs/TESTER-RULES.md` |
| Integration branch | Where proven fixes are merged together. Only the orchestrator merges into it. | `claude/loving-cray-d58nrb-integration` |
| Driver requests branch | Shared branch that driver runs are requested on. `request.py` pushes a docs-only commit there. It must carry the same `Sources/LumenApp/Driver` as the code under test or the build fails. | `claude/loving-cray-d58nrb-driver` |

Rule files are copied into the orchestrator's scratchpad at the start of a run (agents are pointed at the scratchpad copy so the orchestrator can edit them mid-run); replace `<scratchpad>` with the real path when you do.

## How a run works

1. **Orchestrator** (one agent, Opus) reads the run log, picks the work, writes short briefs that point at the rule files, launches agents, triages findings, merges proven fixes, and keeps the Mac queue clear. It does not do the fixing itself.
2. **Fixers** (Opus, one per subsystem, never two in the same files) work in their own git worktree on `claude/loving-cray-d58nrb-fix-<topic>`, prove each fix with a real driver or render-lab run, and report before/after numbers.
3. **Testers** (Opus, one per area group) find and prove problems with the same tools, write at most 12 ranked findings per area to `<scratchpad>/findings/<area>/FINDINGS.md`, and do not fix app code.
4. Orchestrator dedupes findings, hands each to the owning fixer (or starts one), and merges a fix only once its real-run numbers meet the bar.

## Hard-won rules (each one cost time in run 1)

- **The macOS queue is the bottleneck, not tokens.** About 5 macOS jobs run at once account-wide. Every agent must batch work into few, large requests and use the Linux lanes first.
- **Workflow triggers are read from the pushed commit.** CI and UI layout ignore `claude/loving-cray-d58nrb-test-*` and `-driver` branches and the `driver/**`, `renderlab/**`, `docs/**` paths only on branches that contain integration commit fd256da6. A branch made from an older base still starts 3 to 5 macOS jobs on every push. Merge integration (with `[skip ci]` in the merge message) before pushing.
- **`[skip ci]` in a commit message skips every push-triggered workflow,** including the render lab and driver. Use it on iteration and merge commits, never on a request commit.
- **Manual dispatch and cancel return 403** through the GitHub integration in this environment. Runs can only be started by pushes; queued runs cannot be cancelled. Hence the request-file design.
- **Subagent pushes are sometimes refused by the permission system** when the push permission was relayed by the orchestrator rather than given by the owner. Agents must not retry; they commit locally and the orchestrator pushes `worktree-agent-<id>` to their branch.
- **Keep the driver requests branch in sync** with the driver code on the branch under test (`git checkout origin/<integration> -- Sources/LumenApp/Driver driver/README.md`, commit with `[skip ci]`, push). A mismatch makes every run against that ref fail to build, silently from the tester's point of view.
- **`request.py --ref` needs a full 40-character SHA** or a branch name; short SHAs fail.
- **Never trust a fix that was argued from code.** Run 1 found two "fixes" that were regressions at real input speed and one test that had passed for months while measuring a number the app did not use.
- **Hosted runners are a 3-core VM with a paravirtual GPU.** Trust directions and ratios, not absolute milliseconds; run timing scenarios at least twice. Very large images (24 MP and up) were never drawn by the VM's compositor; that turned out to be a real app problem (asking for full-resolution frames below 1:1), not only a VM artefact.
- **Line-number citations:** `Tests/LumenAppTests/LayoutMetricSupport.swift` cites slider call sites by line. Any edit above a slider in a panel file breaks `LayoutMetricSelfTests`. Fix with `python3 scripts/recite-slider-inventory.py <base> --write`.

## Linux toolchain in the cloud container

`sh scripts/install-linux-toolchain.sh` (about 1 minute), then `export PATH=/opt/swift/usr/bin:$PATH`. Builds and tests `LumenCore` only; `python3 scripts/check-swift-surface.py` is the local check on macOS-only code (about 2 minutes).
