# Evidence guide

Audit date: 22 September 2026. Environment: Apple M4, macOS 27 (26A428), Swift 6.4. This is an audit, not a patch set or release certification.

- `native-tests.log`: main baseline, debug, excluding separately run expensive control proofs.
- `control-proofs.log`: all six optimized main ControlProofTests; 135 proof-registry entries.
- `latest-tests.log`: full optimized newer-branch suite.
- `latest-timing-rerun.log`: isolated optimized PlanCostProbeTests rerun. Its ratio target also failed; do not report this suite as green.
- `image/`: colour math, actual GPU table and RAW decoder probes, measured results and structured findings.
- `masks/`: production mask/spatial probes, real-photo Vision results and structured findings.
- `reliability/`: catalog/ingest/cache/export/recovery probes and observations. Some App-layer service harnesses use model stubs around unchanged production services; see the detailed report for the distinction.
- `AppProbe.swift` and open/closed gesture logs: production AppState undo/persistence reproduction and negative control.
- `BranchProbe.swift` and log: exact newer-branch common-parent algorithm replay. The production catalog consequence is separately reproduced in reliability's core probe.
- `UiAuditHost.swift`: isolated entry point displaying production views, not the distributed app bundle. It avoids automatic updating and uses scratch paths. Coordinate-driven pointer gestures were unavailable; do not claim they were tested end to end.

The full report links exact source revisions. Most bespoke dynamic probes ran against main; unchanged-source comparison establishes their newer-branch applicability. Building and running the newer branch's suite is not equivalent to rerunning every bespoke probe there.

These sources are evidence harnesses, not a turnkey testing package: build/module paths and fixture paths describe this audit machine. RAW originals, databases, executable binaries, compiler caches and credentials are intentionally not included. Personal-photo thumbnails and UI screenshots are included locally; keep the report private.

No calibrated Lightroom reference exports, large multi-camera corpus, long-duration memory soak, full VoiceOver study or physical stylus test was performed. No claim of finding every possible bug is made.
