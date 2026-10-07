# Proof numerical portability investigation — 7 October 2026

The optimized macOS 15 CI run 37691834119 (job 113033668921) reproduces the same three differences measured on the unchanged October baseline and local macOS 27. The records were generated on Linux with Swift 6.1; Linux baseline checks passed.

| Control | Field | Linux record | Darwin measurement | Absolute difference |
|---|---|---:|---:|---:|
| color.protectSkin | frontLoading | .4390639459131562 | .4390627432834667 | 1.2026296894451782e-6 |
| mixer.red.hue | meanSeparation | 4.430364179862741 | 4.43036303694729 | 1.1429154502806682e-6 |
| bw.red | meanSeparation | 19.936793222387614 | 19.936794653171145 | 1.4307835307647565e-6 |

Other failing-record fields match exactly, except protectSkin mean separation, whose 9.17428476299e-7 difference is within the existing 1e-6 bound. The repeated values support platform sensitivity, but do not identify the responsible primitive or establish a replacement bound. A three-field 2e-6 whitelist was rejected because it would be derived from the observed failures.

## Added evidence

The opt-in numerical probe records the same source revision and toolchain on Linux and macOS. For each of the three controls it samples 24 chart patches at three settings, recording Double values and Float32 bit patterns at the source, linear/tone, exact colour stage, grading table, encoded finish, sampled finish and final output. These patch-centre predictions are distinguished from full-grid rendered metrics.

Moving every finite final RGB sample outward by one Float32 ULP increases mean separation by approximately 4.8641e-6, 4.9287e-6 and 5.1542e-6 for the three controls. This demonstrates sensitivity, not an upstream platform error bound. The protectSkin frontLoading difference also exceeds the measured final-output midpoint ULP sensitivity (~1.50e-7), so upstream amplification remains to be isolated.

The existing frontLoading ruler omits the initial zero render from its cumulative array. Element 10 therefore measures step 11 at 55% travel, despite comments describing a midpoint. Diagnostics and a characterization test now follow that actual ruler; the ruler, records and comparison math are unchanged.

## Verification and next step

Eight focused numerical/comparison tests and three local artifact probes passed. Each artifact has 72 finite samples and the expected intermediate stages. Negative controls retain rejection of material 1e-5 and .01 perturbations. The combined source checker and optimized suite are recorded in EXECUTION-SECOND-WAVE.md.

The dispatch-only Proof numerical fingerprints workflow uses read-only permissions, disables record writes, checks the records remain unchanged and uploads exact-source evidence. It has no scheduled or push trigger. Compare its Linux/macOS artifacts to locate the first divergent stage, then narrow the responsible arithmetic before proposing an independently justified comparison contract.

The original 1e-6 release gate remains red. No production rendering math, saved appearance, proof fixture or comparison tolerance changed in this investigation.
