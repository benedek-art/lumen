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

## Integrated release and diagnostic changes

The release candidate is uploaded and downloaded for digest verification before promotion. A new release object provides the fresh publication date required by the updater. The previous release, assets, and exact annotated-tag object are retained, and an fsynced recovery manifest records their IDs before public mutations. Promotion is not atomic: clients may briefly see a missing feed, and a network/cancellation failure during recovery may require manual restoration. Live promotion remains unqualified and has not been performed. Eighteen offline failure/recovery scenarios and 31 policy negative controls pass; eight adjacent updater decision tests passed in the agent branch. Independent review found no new blocker.

Proof diagnostics retain the committed records and 1e-6 release comparison. Eight focused tests and three generated chart probes pass. Moving each final RGB sample outward by one Float32 ULP changes mean separation by approximately 4.86–5.15e-6; this characterizes sensitivity and does not establish an upstream platform error bound. No 2e-6 whitelist was accepted. The existing frontLoading ruler samples 55% travel despite midpoint descriptions; diagnostics now follow the actual ruler without changing its math or records. A dispatch-only Linux/macOS fingerprint workflow records identical-source stage evidence without fixture writes or publication.

## Durable report integration

Versioned atomic local report files record paths and outcomes without image data, EXIF or recipes. UUID/revision guards prevent stale checkpoints overwriting terminal results. Running export checkpoints are coalesced; terminal reports are bounded by count/bytes, while malformed, unsupported and unfinished evidence is retained. Successful delivery remains successful if the report cannot be saved, and the UI reports that storage failure.

Start/final ingest reports distinguish source and primary/backup roles. Missing roles after cancellation are not claimed as delivered. A crash between start and final writes remains unknown; per-file ingest durability awaits a settled-result callback. Minimal Recent results access exposes the saved JSON and warns when it is an older checkpoint.

Twenty-six native report/cancellation tests and four actual generated-image AppState export tests passed in the agent branch. Independent read-only review found no new blocking defect. The combined production revision is f08e67c. The optimized suite executed 3,174 tests: 3,151 passed, 22 intentional skips, one unchanged proof-drift failure. All new report, Reset and updater tests passed. Subsequent 8d62b94 changes only checker tooling/fixtures; all-source checks pass and 35 checker fixtures retain their expected verdicts. No production/test Swift source changed after compilation.

## Final qualification and remaining work

Native optimized suite exit 1 is retained; release validation is not green. The sole failure is the same ControlProof comparison on three fields, with no new failing test case. The 31 release policy negative controls and 18 offline release recovery tests pass. The full source checker passes after recognizing valid async-let, implicit catch-error binding and Linux compilation conditions;35 miniature fixtures prove both accepted syntax and rejected mistakes.

APP-09 is verified offline, not through live GitHub promotion. APP-13 is implemented and tested, with midrun ingest outcomes explicitly unknown after a crash. UX-03 remains a partial matrix even though the confirmed Reset interruption bug is fixed. Private RAW/corpus/benchmark gates remain deferred. Next bounded workflow projects are per-photo snapshots and explicit relinking; appearance/model decisions still require real-photo evidence and compatibility policy.

Source publication: [PR #8](https://github.com/benedek-art/lumen/pull/8) is merged as bff081457a1560a537b59a37e43345b065997b41. The final merge carries the same production/test Swift sources qualified locally, plus checker tooling and evidence documents. Hosted CI and numerical comparison are still running; their status is not represented as a pass.
