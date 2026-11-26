# Mac queue note from the orchestrator (read once, then carry on)

The macOS queue is the bottleneck: at last count 5 running and about 19 waiting. A large share of the waiting jobs were full CI and UI-layout runs started by pushes that only added render-lab manifests on `claude/loving-cray-d58nrb-test-*` branches (CI ignores only `docs/**`, so `renderlab/manifests/**` starts it).

Integration commit fd256da6 changes the workflow triggers: CI and UI layout now ignore `claude/loving-cray-d58nrb-test-*` and `claude/loving-cray-d58nrb-driver` branches and the `driver/**` and `renderlab/**` paths, and on fix branches CI runs only `test-fast` (not `build-macos` or `app-bundle`). GitHub evaluates the workflow files ON THE PUSHED COMMIT, so you only get this once your branch contains fd256da6.

What to do:
- Testers: before your next push, `git fetch origin && git merge --no-edit origin/claude/loving-cray-d58nrb-integration`, then amend the merge commit's message to include `[skip ci]` (`git commit --amend -m "merge integration [skip ci]"`), and push. From then on your request pushes start only the render lab. If you prefer not to merge, put manifests INLINE in `docs/renderlab-request.json` instead of committing files under `renderlab/manifests/`.
- Fixers: merge integration the same way before your next push (resolve conflicts carefully; integration now also contains the zoom fix, which touched `LoupeView.swift` placement code and `requestedLongEdge`, and the render lab). Your final full-CI push then costs 3 macOS jobs instead of 5.
- Everyone: one macOS request with many jobs or scenarios beats several small ones. Do not re-request a run that is merely queued.
