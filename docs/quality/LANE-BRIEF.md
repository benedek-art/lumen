# Lane brief

Every quality lane works from this file. One lane = one workstream in `workstreams.md`.
You own the functions that row lists and nothing else. The goal is not "the control does
something". The goal is that a photographer who knows Lightroom would trust it.

## 0. Setup (first 5 minutes)

```
bash scripts/proof/cloud-setup.sh
export PATH=/opt/swift/usr/bin:$PATH
swift build -c release --product lumen-render        # ~2 min
python3 scripts/proof/gen_synthetic.py corpus/synthetic   # synthetic frames, seconds
bash scripts/proof/fetch_corpus.sh                         # full RAW corpus, ~2 GB, ~10 min; run in background
```

`lumen-render keys` lists every settable recipe path. `lumen-render sweep` renders a labelled
contact sheet plus metrics (ΔE2000, zone table, clipping, hue histogram). Read the header
of `Sources/LumenRender/main.swift`. Inputs, conventions and corpus contents are documented
in `scripts/proof/CORPUS.md`. Lightroom references, when they exist, are in
`corpus/lightroom/` with the same photo ids.

`ReferenceRenderer` (CPU) is the definition of the image. The GPU path must match it, and
macOS CI (`gpu-parity.yml`, `ci.yml`) checks that. So you fix the CPU definition and its
GPU twin together, in the same commit, and keep the existing parity tests passing.

## 1. Roles

Run these as separate subagents. The builder never verifies its own work.

1. **Auditor.** Render sweeps of every control in the lane on the synthetic frames AND at
   least 6 real corpus photos (include the A7 IV and GX85 frames). Look at every sheet with
   the Read tool at 100% crops, not only the thumbnails. Write down what is wrong, with the
   numbers and the image paths. Check what Lightroom does (Adobe docs, Camera Raw behaviour,
   the reference exports if present) and what the physics or colour science says.
2. **Spec.** Turn that into a numbered acceptance spec: each line a measurable claim with a
   threshold and the command that measures it (e.g. "Highlights −100 moves zones 0-4 by
   < 1 code", "grain autocorrelation at any lag ≥ 8 px < 0.05", "saturation +50 changes
   OKLab hue by < 1°"). Plus 2-3 visual claims a human can judge from a named sheet.
   Write it to `docs/quality/lanes/WS-NN/SPEC.md` before any code changes.
3. **Builder.** Fix the code until the spec passes. CPU reference and GPU kernel together.
   Add or update unit tests in `Tests/LumenCoreTests` for the measurable lines. Keep the
   change inside the lane's owned functions. If you need a change in a function another lane
   owns, write it in `docs/quality/lanes/WS-NN/NEEDS.md` instead of making it.
4. **Verifier.** Fresh agent, sees only the spec and the diff. Rebuild, re-run every
   measurement, open every before/after sheet, and try to break it: extreme values, other
   photos, interaction with neighbouring controls, the GPU kernel reading differently from
   the CPU code. Verdict PASS or FAIL with reasons.
   FAIL goes back to the builder with the report. Up to 3 build/verify rounds. After the
   third FAIL, stop and write what is left in the report as BLOCKED. Do not fake a pass.

## 2. Gates before you push

- `swift build --target LumenCore --target LumenRender` clean.
- `swift test --filter LumenCoreTests` passes on Linux (or list the exact pre-existing
  failures, proven pre-existing by running them on the base commit).
- Every SPEC line marked PASS with the measured number.
- Verifier PASS.
- Never skip, disable or loosen an existing test to get green. If an existing test encodes
  the old wrong behaviour, change it in the same commit and say why in the report.

## 3. Output

Commit on your lane branch `quality/ws-NN-short-name`, branched from
`claude/inspiring-dirac-ulgpch`. Push it. Contents:

- the code and tests
- `docs/quality/lanes/WS-NN/SPEC.md`, `REPORT.md` (verdict per spec line, numbers,
  what you changed and why, what you could not fix, anything a human must judge)
- `docs/quality/lanes/WS-NN/evidence/*.png`: before/after sheets, at most 12 files,
  each under 400 KB (use `--long-edge 1024` or crops)

Do not edit `docs/` outside your lane folder, do not write new plan documents, and do not
touch another lane's functions. Do not merge into other branches or open PRs; the
integrator does that. Commit messages end with the attribution lines your session gives you.

## 3b. UI lanes: seeing the interface

Every push to any branch runs `.github/workflows/ui-snapshots.yml` on a macOS runner, which
renders 36 panel, overlay and full-window PNGs (real views, real fonts, 2x, dark) and
publishes them to the `ui-snapshots` branch under `<branch with / replaced by ->/<short sha>/`:

```
git fetch origin ui-snapshots
git show origin/ui-snapshots:<branch-dashed>/LATEST          # newest sha
git worktree add /tmp/snaps origin/ui-snapshots              # then open PNGs with Read
```

The baseline set is `claude-inspiring-dirac-ulgpch/a93efb2/`. A UI lane's auditor works from
those images; its verifier waits for the lane branch's own snapshot set (about 15 min after
push; re-run `git fetch` until `LATEST` shows your sha) and compares before and
after side by side. If a state you need isn't captured, add it to
`Tests/LumenAppTests/PanelSnapshotTests.swift` (append only; don't reorder). Layout metrics
tests (`ui-layout.yml`) must stay green. Interaction feel (drag latency, gestures) can't be
seen in a PNG: reason about it from the code, and list what the owner must try by hand in
REPORT.md.

## 4. What "good" means here

Lightroom is the floor, not the ceiling. When the maths and Lightroom disagree, say so and
pick the one a photographer would prefer, with the image that proves it. Smooth, monotonic
response across the whole slider range. No halos, no hue shifts that weren't asked for, no
banding, no clipping that wasn't asked for, no dead ranges. The default value of every
control is an exact identity.
