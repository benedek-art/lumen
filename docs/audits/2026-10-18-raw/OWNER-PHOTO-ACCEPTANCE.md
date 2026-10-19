# Owner-photo acceptance checkpoint
Date: 2026-10-18
Pinned Git head: 0a82064e16453683b4682fc918042b504b3e65bd
Cloud-reported tested production source: a4bc1506e0e744f58089b56bfbc8953b2d3e6fc0

Scope and safety
Fresh optimized macOS build using Swift build engine. Owner RAW copies from Sony A7 IV and Panasonic GX85; originals unchanged. Photos, rendered crops, manifests and catalogs stayed local. No production source edits, pushes, merge, release or application installation during this acceptance run. Cloud worker owns source fixes and received findings throughout.

Observed results
1. Displayed denoise matrix: 16 actual owner RAWs, three native-resolution ROIs, ten modes = 480 rendered deliveries per full run. Modes include Off, imported Classic default, Classic25/50/100, Apple-decoder AI stand-in0/25/50/100, Off-return.
   First run, simultaneous with native consumer matrix: 48/48 AI0 checks exact; Off-return failed on one Sony fixture in all three ROIs. Maximum display code delta1; RMS codes .0313561964 / .0335760231 / .0296729593. Other Off-return checks exact.
   Single-photo fresh-process repeat: all checks passed.
   Full sequence repeat without concurrent consumer matrix: all checks passed, 37.864 seconds, including 48/48 AI0 and48/48 Off-return exact. Keep initial failure open: no tolerance changes and no claim of consistently deterministic output. Display response RMS measures change, not denoising beauty or noise reduction quality.

2. Native consumer matrix: five owner RAWs, unchanged/intermediate/eager boundaries, first/repeated delivery. Coverage includes Dehaze SDR, EDR half-float, scene/colour/mask/Point Colour samplers, and cropped actual TIFF16 write/readback. Five test methods include the active-component/padding harness.
   First run: two assertions failed for fixture2 Dehaze SDR intermediate-vs-eager first/repeat;173 changed components, maximum delta1 display code. Production first-repeat remained exact. Other test methods passed.
   Affected-photo fresh-process repeat: passed.
   Full matrix repeat:5 tests,0 failures,29.091 seconds. Retain first-run discrepancy pending decoder/display reconstruction diagnostic. First run had simultaneous workload; concurrency causality is not established.

3. Neutral absolute white balance focused build tests passed. This is narrow identity coverage, not broad camera-colour certification.

4. Native GUI smoke, disposable four-photo catalog: opened Panasonic RAW in Develop, exposure accessibility increment0.00→0.01, Undo restored0.00 and original histogram clipping readout. Numeric entry, mouse-up commit and reopen persistence were NOT accepted. Initial UI tool timeouts caused duplicate acceptance app launches; second process reported SQLite disk I/O on the disposable catalog. A clean distinct-bundle/temp-catalog harness was prepared but UI tool launch timed out. Treat persistence and catalog behavior here as inconclusive harness evidence, not an established production bug.

5. Sandboxed repeat invocations initially failed immediately with decodeFailed. Native decoder access resolved this; these attempts do not qualify as photo accuracy results.

Next actions, in priority order
- Cloud worker: retain exact identity assertions; add public RAW reconstruction coverage to isolate decode-key/cache recreation from downstream rendering. Recheck owner-photo failures on any candidate source revision.
- Clean single-instance native UI acceptance: precise numeric no-op and off-grid entry, mouse release final value, retarget during edit, undo/redo and process restart/reopen.
- Disposable XMP conflicts, dependency preservation, snapshots and queued export identity/failure.
- Masks: brush geometry, local neutral WB, Amount epsilon boundary, preview/JPEG/TIFF16/HDR comparisons.
- Denoise visual assessment at100% for both cameras/ISO ranges and isolated latency/memory measurement.
- Known existing blockers remain: local Amount positive-epsilon LUT-domain discontinuity; bright-flat Dehaze CPU/GPU disagreement. This checkpoint does not resolve either.

Raw logs, image outputs, filenames, private manifests and catalogs remain local. Two pre-existing empty duplicate audit logs were preserved locally and excluded from publication. This report contains no private photographs or original paths.

Publication note: these measurements remain pinned to 0a82064. The later cloud checkpoint 285708b includes production changes not exercised by this owner-photo run. See [CLOUD-REPORT.md](CLOUD-REPORT.md) for newer-source results and [TOMORROW-ACCEPTANCE.md](TOMORROW-ACCEPTANCE.md) for the remaining checklist. Publishing this document does not requalify the newer source.
