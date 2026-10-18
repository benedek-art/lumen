# Local/group Amount positive-epsilon diagnostic

Source baseline: `c7fbdd806fa79f348bff51bf687aeaff24fe05c3`. No production code, saved looks, defaults, existing tests or tolerances changed.

## Executed evidence

- Fresh optimized Linux `LumenCore` build: exit 0, 71.934 seconds. `build-provenance.json` records the command and matching full Core pre/post source manifests; no dependency exemptions.
- Extracted actual `LocalPlan` plus actual fresh Core probe: compilation exit 0; execution terminated with signal 4 before any output. `execution.log` is empty, and no numeric results were produced. This is an unresolved Linux execution limitation, not a CPU or GPU pass. `provenance.json` retains the compile command, object/source hashes and failure.
- New native diagnostic: Swift syntax parsing and whitespace checking only in this environment. macOS compilation and execution remain owed.

Reproduction uses a required NEW output directory so archived evidence cannot be overwritten:

```sh
python3 docs/audits/2026-10-18-raw/local-amount-epsilon/build-core.py --source-root "$PWD" --output-dir /tmp/lumen-epsilon-new-run
python3 docs/audits/2026-10-18-raw/local-amount-epsilon/run-probe.py --output-dir /tmp/lumen-epsilon-new-run
```

The first command refuses an existing directory. The runner requires the new build provenance and refuses any existing probe artifacts. It reads original fixture sources without modifying them, and writes the binary/logs/results only to the requested output. Toolchain dependency paths remain relative to the source workspace parent. Historical archived provenance retains the exact earlier command and output locations; maintained scripts now protect it. The extracted helpers and `executed-probe.swift` preserve exactly what was compiled. The zero-bypass-disabled helper is an isolated diagnostic copy, never a production mutation. The intended portable matrix did not execute successfully and contributes no numeric acceptance.

## Source-derived mechanism, not executed GPU results

Mask raster geometry does not include Amount. Group Amount multiplies mask Amount; the result scales adjustment parameters. For a nonneutral local wheel, any positive Amount retains a local grade and post LUT, including when scaled engine values are numerically identity. Exact zero bypasses that path. There is no final blend by Amount: S11 composites with selection alpha only.

The LUT sampler clamps encoded coordinates to its domain. Independently expanding the declared shaper gives lower endpoint `0.18 * 2^(-10.5) * (1 - 1.5 * ln(2)) = -4.937137455737602e-6` and upper endpoint `0.18 * 2^12 = 737.28`. Direct CPU local grading has no equivalent LUT-domain clamp. Thus the source predicts a finite positive-epsilon jump for signed and HDR pixels. For input -0.01 and alpha .25, the predicted clamp-only displacement is .0024987657156360656. For input 1024 and alpha .75, it is 215.04. These are analytic source calculations, not measured rendering results. Exposure-only uses direct gain and does not establish that every local adjustment has this issue.

## Pending native causal diagnostic

```sh
LUMEN_LOCAL_AMOUNT_EPSILON=1 swift test -c release --filter LocalAmountEpsilonDiagnosticTests/testCurrentPositiveAmountDomainAndCPUAgreement
```

The optional test runs actual `RenderGraph.applyLocalAdjust`, actual full S11 `applyLocal`, and actual `ReferenceRenderer` on four signed/in-domain/HDR constant patches. Twenty stage records cover cubes 33/65, direct mask/group strength, and Amount 0, 1e-8, .0001, .01, 1. Two additional exposure-only stage controls use direct gain with independently calculated expected output. Four epsilon composites balance soft selection alpha .25/.75 across both axes and cube sizes; one additional zero-alpha composite requires exact input identity. The asserted totals are 22 stage and 5 composite records. Group masks use Amount 50 and group Amount twice the requested value, obtaining the same effective strength as direct masks. No camera files or colorspace calibration are involved.

All records are emitted as `LOCAL-AMOUNT-EPSILON` JSON before aggregate assertions. The test strictly checks finite outputs, exact zero-stage identity, record counts, CPU/GPU agreement for all three RGB channels at four patch centers at the existing 1e-3 readback bound, and an independently expanded clamp-domain/normal-alpha equation at epsilon ONLY for R in the two out-of-domain patches. Those are exact cube endpoints; in-domain channels can carry finite log-cube interpolation error, so they are logged but do not enter the independent endpoint assertion. The all-channel CPU/GPU parity check remains strict. The exposure-only independent gain assertion still covers every sampled channel. No desired-continuity assertion is substituted for measurement. CPU/GPU parity may be RED and must remain a reported unresolved gate; the independent equation can also fail, in which case the proposed mechanism is not runtime qualified. There are no expected-failure annotations or enlarged HDR tolerances.

A behavior fix could affect positive creative values and requires a separate compatibility decision supported by native evidence. This diagnostic establishes no camera, subjective quality, exhaustive cross-control, or continuity acceptance.

Independent read-only review found no fixture/API/equation blocker: RGBAf stride, source readback, matched group/direct strength, endpoint scope, counts and failure propagation checked. This is source review, not native execution. All-pixel finite/zero checks and four-center RGB parity are distinct.

## Subsequent failure-classification attempt

The original SIGILL evidence above is unchanged. A single run of the identical SHA256-verified binary with `SWIFT_BACKTRACE=enable=yes,interactive=no` and a new output directory exited0 in0.363s. This does not establish why the original launch failed. Matching full current Core manifests were rechecked before execution. See backtrace-attempt/ for exact command, binary hash, all640 numeric rows and analysis; no binary is committed.

This executed the extracted actual LocalPlan helper with actual fresh Core LUT/Grade/RenderPlan, **not native GPU or full S11**. It produced160 finite stage pairs and32 exact zero-stage checks;640 emitted alpha rows are finite,128 zero rows exact,320 direct/group rows matched exactly. It uses cubes17/65 and Amount0/1e-10/.0001/.01/1, distinct from the pending native33/65 and1e-8 matrix. At grade Amount1e-10/cube65, inputR−.01→tableR−.000004937137466/directR−.010000000000011; inputR1024→tableR737.28/directR1024.000000000095. At alpha.75 the independent normal blend yields−.002503702853100 and808.96 respectively. These measurements support the source-derived table-domain mechanism but do not substitute for actual GPU/reference qualification or a continuity repair.

To reproduce the later backtrace-mode question without overwriting evidence, use a fresh directory: `python3 docs/audits/2026-10-18-raw/local-amount-epsilon/build-core.py --output-dir /tmp/lumen-epsilon-new --source-root "$PWD"`, then `python3 docs/audits/2026-10-18-raw/local-amount-epsilon/run-probe.py --output-dir /tmp/lumen-epsilon-new --swift-backtrace enable=yes,interactive=no`. The output directory must not preexist for the build and must contain only that build before running the probe. Existing toolchain paths are intentionally recorded; adapt the toolchain location explicitly on another host.

Hosted4fba compilation stopped at `pow(2,12)` ambiguity before all pixel execution. The follow-up test changes only pow literals to explicitDouble, preserving every equation, input, assertion and tolerance.

## First executed native result at2b96

[Diagnostic job117697384495](https://github.com/benedek-art/lumen/actions/runs/39134924311/job/117697384495), macOS15.7.9(24G830)/arm64/Xcode16.4(16F6):1 test,**2 assertion failures**,11.110s. All22 stage records are valid: four zero-Amount cases exactly matched input/CPU; both exposure-only controls had CPU/GPU error0 and independent gain error7.10e-8. All four wheel epsilon cases (mask/group ×33/65) produced R−.000004937138783 and737.280029297 versusCPU−.009999999776 and1024; stage maximum CPU/GPU difference286.719970703. The independent out-of-domain stage endpoint oracle had no failure. This is executed evidence of a positive-Amount discontinuity/parity gap, not a fix or quality acceptance.

The four soft-alpha equation failures also exposed a **fixture error**: CIColor constants were colour-managed in the linear context, consistent with requested.25/.75 becoming approximately.050876/.522522. These are not production-mask regressions. One composite JSON line was interleaved with XCTest stderr;27 records parse and one does not. The summary reports22 stage/5 composite records, but the strict workflow coverage parser correctly failed rather than silently accepting incomplete JSON. Raw selected output and27 intact records are archived in public-native-2b96ec4.log / valid-native-records-2b96ec4.json; the corrupt record was not invented or reconstructed.

The follow-up fixture supplies scalarRGBAf mask data with nil colorSpace, requires direct exact mask-alpha readback, and writes each JSON record directly through FileHandle instead of buffered print. Existing inputs, CPU/GPU1e-3 bound, endpoint equations and strict assertions stay unchanged. A corrected native run is still required. The broader production wheel/domain gap is retained as an unresolved gate.
