# Current product and qualification state — 7 October 2026

The app has a substantial working engine and desktop workflow. The October 2 main merge is newer than the saved September repair checkout. Treat the newest implementation as the baseline and preserve older safety contracts and evidence selectively; merging every branch wholesale would restore obsolete experiments.

## Built and connected

| Area | Current capabilities | Remaining practical gate or gap |
|---|---|---|
| Library | SQLite catalog, folder scans, ratings/flags/labels, hierarchical catalog keywords, filters/albums and culling | Explicit missing-original relink; smart-album scope; large-catalog native performance |
| Ingest | Streaming copy/digest verification, disambiguation, independent landing checks, cancellation and eject refusal | Filesystem alias coverage strengthened today; actual disconnect/volume tests later |
| Develop engine | White balance, tone, zones, curves, presence, sharpening, film, colour mixer/B&W and exact S9 colour path | Real photos; platform proof record drift; spatial Uniformity/Variance product choice |
| Local edits | Painted masks and healing, source search, local controls and reusable blobs | Hard minimum brush size has a measured resolution boundary; manual heal-source UI; target-device latency |
| Framing | Per-photo batch crop/angle/reset/Original controls | All-or-none ratio/reciprocal safety repaired today; physical interaction review later |
| History | Session undo/redo and discrete edit boundaries | Named per-photo snapshots are not persisted/wired despite an old README stage claim |
| Portable edits | XMP field-preserving merge, sidecar ownership, keyword leaf projection, durable owed-edit recovery | Refusal/removal recovery repaired today; full hierarchical interoperability remains separate |
| Delivery | Multiple output formats, collision policies, HDR path, density metadata, contact sheet support | Catalog keyword additions merged into delivery; embedded-source removal needs authority; persistent cancellable queue and more output controls; durable per-file reports are now implemented |
| Updater | Public rolling-release lookup, digest check, signature integrity, staged bundle replacement | Relaunch/cleanup/main-actor work repaired today; actual installation/relaunch/volume qualification later |
| Engineering | macOS compilation, Linux engine/fixtures, GPU parity, proof and UI-layout workflows | Full optimized proof drift blocks existing publication; separate corpus/UI checks need aggregate exact-SHA qualification |

## Honest completion accounting

A connected feature, a passing regression, a passing full suite, and a photographer accepting the output are separate milestones. Today's ledger uses explicit states. It does not convert test counts to a completion percentage or call all 84 backlog entries defects.

The repair priorities are data preservation and deterministic crashes first, workflow reliability second, synthetic quality characterization third, then product projects. Saved-look changes require an explicit compatibility policy and real-photo acceptance. That includes brush deposition, spatial colour models, film defaults and output sharpening.

## Known baseline and environment issues

- Hosted main release validation already failed ControlProofTests on three metric records. Rounded reports hid differences slightly above 1e-6. Do not blindly loosen the bound or overwrite goldens.
- The public RAW corpus showed a Leica Monochrom black decode also present through Apple-default/ImageIO paths, and Nikon Z30/GH5S neutral-patch alarms against an explicitly guessed chroma threshold. These require scoped decoder refusal and threshold investigation, not general black-image rejection or automatic camera-colour correction.
- Local sandbox service restrictions caused nil Core Image readbacks/encoder failures. The same compiled healing GPU suite passed 4/4 outside the sandbox; actual generated-image metadata exports also passed. Final integrated testing must use service access rather than interpret nil readback as numerical disagreement.
- Default Swift/Xcode dSYM generation was blocked by sandbox permissions. Native Swift build system with isolated caches compiles the whole app; keep actual test outcomes separate from compilation.

## Next sequence

1. Integrate the proven safety and workflow repairs, review the combined tree and run exact-revision meaningful tests.
2. Keep release publication opt-in while RAW/native UI qualification is deferred. A push to main remains a code consolidation, not implicit photo acceptance.
3. Investigate proof/platform metrics with fieldwise diagnostics and measure mask boundaries. Do not convert uncertainty into aesthetic repairs.
4. Execute the detailed master plan in bounded waves: durable reports, relink, snapshots and scope; then metadata interoperability and performance; then visual product choices.
5. When originals are available, qualify camera decoding, skin/sky/foliage/B&W/HDR, local-edge/brush quality, native controls and update installation. Record device, source, SHA and output format.

The full integrated run discovered three baseline exact-colour kernels failing on macOS 27. A semantics-preserving Boolean syntax repair restored compilation and passed existing accuracy/parity tests. Reduced preview provenance refusal was correct and remains unchanged. The initial 3157-test run failed 42 assertions and skipped 78; it is not the final qualification result. The final rerun after those repairs executed 3158 tests: 3135 passed, 22 intentional skips, one reproduced baseline proof-drift failure. All repair-related checks passed.

Final consolidation status: 20 confirmed defects repaired, catalog keyword additions delivered without deleting embedded source tags, all source checks green, and 3158 optimized tests with only the known baseline proof-drift failure. Local and GitHub main are consolidated through [PR #7](https://github.com/benedek-art/lumen/pull/7). No updater release was published; longer hosted checks remain visible on the PR/main workflows.

## Autonomous second wave

Reset now ends an interrupted slider gesture before recording its own undo step. Ingest/export reports survive restart and expose truthful per-file outcomes through Recent results. Release staging verifies a new candidate before promotion and retains the old release/assets/tag object with recovery evidence; no live promotion occurred. A manual Linux/macOS numerical fingerprint workflow supports investigation without changing proof records or the1e-6 gate.

Combined optimized qualification: 3,174 tests, 3,151 passed, 22 intentional skips, one unchanged proof-drift failure. All-source checks pass; 35 checker fixtures, 31 release-policy controls and 18 mocked release recovery scenarios pass. See EXECUTION-SECOND-WAVE.md for contracts and limits. Per-file ingest crash checkpoints, live promotion, private RAW appearance and native daily-use acceptance remain open.
