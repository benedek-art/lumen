# Proof numerical portability investigation — October 7, 2026

Baseline is origin/main a4f646e; worktree branch codex/lumen-proof-portability preserves the prior rendering branch. Latest release-validation run37691834119/job113033668921 (macOS15.7.9, arm64) reproduces the same three field values observed in earlier Oct2 release CI and local macOS27 arm64 debug builds:

| Control | Field | Linux committed | Darwin measured | Absolute difference |
|---|---|---:|---:|---:|
| color.protectSkin | frontLoading | .4390639459131562 | .4390627432834667 | 1.2026296894451782e-6 |
| mixer.red.hue | meanSeparation | 4.430364179862741 | 4.43036303694729 | 1.1429154502806682e-6 |
| bw.red | meanSeparation | 19.936793222387614 | 19.936794653171145 | 1.4307835307647565e-6 |

Other compared fields match exactly (protectSkin mean separation differs9.17428476299e-7 but remains within existing bound). Original records have LinuxSwift6.1 provenance. Latest Mac release and localMac debug agree exactly despite different OS/toolchain optimization. The current Linux baseline lane passed. Thus integration rendering fixes are not implicated; variation is stable across these measured platforms. This evidence does not identify a responsible libm primitive or establish a universal2e-6 error bound.

A three-field Darwin whitelist with2e-6 tolerance would accommodate measured failures, but the whitelist would be derived from failures rather than an independent error analysis. It could mask a real small regression in these fields. No tolerance or golden change is justified yet. Existing1e-6 release failure is retained.

New opt-in `LUMEN_PROBE_NUMERICS=1` under ControlProbeHarness prints NUMERICS_BEGIN/END JSON for a colourChart probe. It includes each of24 patch centres at low/mid/high, Doublevalues and Float32bitpatterns through source, matrix/tone, exactS9twin, grade, sampledfinish, and final reference output. Compare identical snapshots on Darwin and Linux to find the first divergent stage; then narrow to its matrix reduction/transcendental/table bake. It also measures how moving each finite finalRGB sample oneFloat32ULP away from the low endpoint changes mean separation, authority and frontLoading. This is a sensitivity characterization, not an upstream error bound.

Negative controls retain rejection at1e-5 and.01 in both implicated metrics for all three controls. Nonfinite perturbations remain nonfinite; alpha remains exact. Normal probes omit diagnostics and the record drift gate remains unchanged.

## Characterization result and bounded conclusion

One finalFloat32ULP outward perturbation increases mean separation by4.86410403755e-6 (protectSkin),4.92865593316e-6 (redHue),5.15424653003e-6 (BWred). These sensitivity values exceed2e-6; they explain why a tiny aggregate difference can be plausible but cannot establish a stricter independent bound on upstream platform arithmetic. ProtectSkin's observed1.2026e-6 frontLoading divergence also exceeds the final-output oneULP midpoint sensitivity (~1.50e-7), so an upstream amplified difference remains to isolate. No numerical tolerance change was committed.

A separate ruler finding: `Sweep.cumulative` omits the zero starting render; its20 values correspond to steps1…20. `frontLoading` indexes element10, selecting step11 at55% travel. Existing commentary calls this the midpoint/first half. Fingerprints now use that actual55% setting so they reproduce committed metrics. A direct characterization regression asserts the current20-element cumulative contract and diagnostic alignment; the ruler itself is unchanged.

The manual-only `Proof numerical fingerprints` workflow builds the exact same source on ubuntu24.04 and macOS15, records sourceSHA and fulltoolchain/architecture, and runs only the three fingerprint probes. `LUMEN_RECORD_PROOFS=0`, contents permission is read-only, an always-run recorddiffcheck refuses fixture modification, and artifacts upload even after probefailure. Each artifact includes3 directly-written JSON files (avoiding XCTest stdout/stderr interleaving), each with72 nonempty patch-setting samples, finishEncoded and finishSampled intermediates; workflow validation rejects missing/extra controls or nonfinite JSON constants. It publishes no release and has no push/schedule trigger.

Local final fingerprint probes each complete in~8–10sec; their mean separation and frontLoading match Mac record diagnostics exactly. Scalar stage predictions are explicitly labeled as24 patch-centre samples, distinct from full-grid rendered output. Run the workflow after this source is integrated and compare files across platforms to isolate the first divergent arithmetic stage before selecting any new comparison contract.

Committed d70e4ac0b70a146d43f313052a90c8edfbdbba5d on codex/lumen-proof-portability, parenta4f646e. Native debug build green. Eight comparison/numerical negative-control tests green. Three final artifact probes green in6.918/7.168/6.879sec; all72-sample JSON files validate with no nonfinite constants, correct finish intermediates, exact55% settings and currentMac frontLoading values. Workflow YAML parses; release-policy24negativecontrols passed; diffcheck clean. Root owns combined sourcechecker and hosted matrix dispatch. No production sources, proof fixtures or comparison tolerances changed.
