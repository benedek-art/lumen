# LCh numerical correction — 2026-10-07

The existing absolute proof tolerance remains **1e-6** in every field. Only three control records (four fields) were corrected after tracing their drift to the same first LCh hue calculation. The other 141 records retain their previous values, including six controls with changes below tolerance.

Unmodified exact-source run [37699092460](https://github.com/benedek-art/lumen/actions/runs/37699092460) at 9ef817fc3e2f03ecf53959b487aa2fe33f2ce4bb traced identical uniforms, LMS, cube-root seeds/Newton results and Lab values. The first divergent primitive was atan2f at exact Float inputs y bits 1026310640 and x bits 1026067584: Linux produced 1061935362; Darwin produced 1061935361. A scratch interposer changing only this input to the Linux result reproduced every field of all three original Linux records on Darwin. The interposer is not production code.

An independent 90-digit Decimal arctangent calculation gives 0.796279983347270300317603626735924756387590159865259606415544603331674894827087845778443346 radians, 1.3286259363e-8 below the midpoint between those Float values. Therefore 1061935361 is the nearest Float. Exact Float inputs widen losslessly to Double; evaluation in Double then rounding to Float gives this result with ample margin before the unchanged Float degree conversion. This is a localized empirical portability correction, not a claim that every libm Double transcendental is universally correctly rounded. The direct regression rejects the former upper-ULP result without loosening any gate.

Run [37704880594](https://github.com/benedek-art/lumen/actions/runs/37704880594) at adbcbce2b9977bf645ac0a828bfef4073197d4b1 confirmed that Double evaluation rounds to 1061935361 on both Linux/macOS. Production changes only ExactColorTwin.lch; mixer target atan2 blending and GPU kernels remain unchanged. Existing CPU/GPU exact-stage and table-accuracy gates passed with the narrow patch. Independent axes, wrap, neutral and nonfinite tests also passed.

Run [37706173885](https://github.com/benedek-art/lumen/actions/runs/37706173885) measured all 144 registry controls with the original ProofRunner.measure and no fixture writes at 6eaf06eaf6a5afad0e323fd60e492f0eba3a0132. Ubuntu 24.04 x86_64 used Swift 6.1.2; macOS 15 arm64 used Apple Swift 6.1.2. Every changed field is retained in [full-registry-comparison.json](full-registry-comparison.json). Linux differs from the old ruler in 10 fields / 9 controls; Mac differs in 14 fields / 13 controls. Both exceed 1e-6 only in the same three fields. Patched Linux and Mac differ in five fields, all within the existing tolerance (largest 1.63905e-8). The three corrected records match exactly across both platforms.

Updated records from the hosted Linux artifact:

| Control | Field | Before | After |
| --- | --- | --- | --- |
| color.protectSkin | frontLoading |0.4390639459131562|0.4390627432834667|
| color.protectSkin | meanSeparation |1.3650580354770752|1.3650571180485989|
| mixer.red.hue | meanSeparation |4.430364179862741|4.43036303694729|
| bw.red | meanSeparation |19.936793222387614|19.936794653171145|

The related protectSkin mean is retained with its corrected control record even though its 9.17428e-7 delta is below the tolerance. No unrelated record was regenerated. Full artifact directory SHA256 values (sorted relative path + NUL + bytes + NUL) are recorded in the comparison JSON; source/toolchain files and raw snapshots remain in the workflow artifacts.

Validation after the four-field correction: both hosted 144-record snapshots agree with every corrected committed field under the unchanged 1e-6 contract (zero failures). Original optimized `ControlProofTests` also passed all six tests locally on Darwin, including the complete 144-control sweep, authority/liveness/range/reversal checks, committed-record drift and evidence generation; wall time 184.279 seconds. Production source was the exact narrow scratch copy matching the one-call patch. GPU parity and color-table accuracy tests passed separately. Owner RAW-image and interactive app checks remain separate qualification gates.


## Proof workflow execution configuration

The full proof workflow now defaults to `-c release` on pushes, nightly runs and manual dispatches. Manual dispatch can explicitly choose `debug` for comparison. Both configurations still execute the original `ControlProofTests`, all 144 controls and every existing tolerance; recording remains separately opt-in and defaults to false. Release optimization exercises shipping arithmetic and avoids the former 66–80 minute debug cost without reducing coverage. The local optimized full suite passed in 184.279 seconds; hosted run 37706173885 measured all 144 controls on Linux and macOS with strict corrected-ruler compatibility. These results justify the configuration change without promising a fixed hosted runtime.

The workflow follow-up was qualified in [run 37710960640](https://github.com/benedek-art/lumen/actions/runs/37710960640) at `4a56a27`: release configuration, all six original proof tests passed, zero failures. The hosted job took 9m40s including setup/build. Its source/test trees match `a9029e3`; subsequent `8ee85b8` changes only the Mac CI invocation to a complete optimized suite. The prior 66–80 minute debug figure is historical workflow documentation, not a controlled same-runner comparison.
