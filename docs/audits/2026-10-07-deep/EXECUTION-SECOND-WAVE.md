# Autonomous second repair wave

Starting revision: a4f646e on consolidated main, after merged PR #7.

The owner authorized continuing autonomously with parallel repair work. This wave uses isolated branches and generated/synthetic inputs. No release, installation, private RAW upload, or appearance qualification is included.

## Assigned work

- APP-09: Stage and verify a release candidate before replacing updater assets; preserve known-good delivery and recover from partial promotion. Tests use a mocked GitHub API, never live publication.
- Proof portability: Investigate the three tiny macOS proof differences independently of the passing Linux baseline. Any numerical contract change needs causal evidence and negative controls; observed failures alone do not justify raising tolerance.
- APP-13: Persist truthful per-file import/export result reports, including partial and interrupted operations and visible report-write failure.
- UX-03: Extend real AppState interruption tests; check Reset during an unfinished slider gesture preserves a separate undo boundary.

## Qualification

Review independent commits, integrate into one branch, run targeted and adjacent tests, source checks, and the combined optimized suite. Record exact revision, failures, and skipped private-photo gates before publishing reviewed source changes to the approved repository. Main CI build, app bundle, fixtures, Linux engine, GPU parity, and layout checks passed on the prior consolidated source. Release validation failed and is under investigation.

## Latest evidence

Hosted macOS 15 optimized validation of merge 1a0c91a matched local macOS 27 qualification: 3158 tests, 22 intentional skips, one failed ControlProof test. The three reported field deviations match the earlier unchanged-baseline measurements exactly. This corroborates portability drift but does not establish a justified replacement numerical bound.

A new Reset interruption regression failed before the repair: Reset retained the active gesture epoch, coalesced into the drag, and Undo Reset could not restore the dragged value. The repair closes the gesture before recording Reset. The repaired regression and adjacent AppState/history/reset tests passed: 33 tests, zero failures, optimized native build. The pre-fix regression produced four failing assertions; the one-line gesture closure fixed all four.
