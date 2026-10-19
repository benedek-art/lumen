# Local tone domain: bounded actual-Core characterization

Source base222cf96276d9e9c3a027c2f0ed18404a73401014. No production, native test, workflow, old assertion, golden, default or tolerance changes. This is evidence for deciding whether a future exact scalar-tone port is justified, not a proposed remedy or parity acceptance.

The driver builds the current tone-only LocalPlan table expression using actual public ToneEngine/LumenLog/LUT3D functions. It evaluates ACTUAL Float cube bytes with explicit8-corner trilinear interpolation matching shipping topology; it does NOT call `LUT3D.sample`, which uses tetrahedra. It compares with independently written luminance row arithmetic, the actual declared ToneEngine.gain function, and per-channel multiplication of the ORIGINAL RGB. A separate calculation through actual RGBColorSpace.luminance/Num.safeLog2/RGB multiplication verifies that independent arithmetic matches the Core-defined local-tone equation. It does not execute the whole ReferenceRenderer or Core Image graph, nor derive creative tone gains from an external calibration standard.

Cases: Contrast60 and Highlights60 separately, local Amount0/1e−8/1/100, cube33/65. Four inputs: signed R with positive in-domain luminance `(-.01,.18,.3)`, all-negative `(-.01,-.02,-.03)`, HDR luminance above the shaper axis `(2048,1024,512)`, and ordinary positive `(.18,.3,.5)`. All64 patch/configuration measurements are logged in16 compact case records plus one summary. The amount is divided by100 before scaling the selected panel parameter. Amount0 bypasses the table, exactly as production LocalPlan; its four patch outputs are required to remain exact. All outputs must be finite. Independent direct row arithmetic must match the actual Core equation within1e−12; this is an arithmetic consistency control, not a new renderer acceptance threshold.

## Executed result

Compile0, one execution0, no retry or signal failure. All129 current Core Swift hashes matched the release build's complete recorded manifest before compilation/linking. Swift6.1.2, x86_64 Linux, `-O`, actual release Core object files; no stubs or extracted replacement engine. Compiler, command/environment, full source comparison/expected manifest, raw output and exit statuses are archived in `evidence/`. `SHA256.json` fingerprints the driver, runner and evidence.

All Amount0 cases are exact, every result finite, and independent arithmetic matches the actual Core equation exactly. Selected maximum channel errors between historical table route and direct Core equation:

| Panel / Amount | Signed positive-Y | All-negative floor | HDR above axis | Ordinary positive,33 /65 |
| --- | ---: | ---: | ---: | ---: |
| Contrast60 /1e−8 | .009995062862 | .029995062863 |1310.72 |7.98e−12 /7.98e−12 |
| Contrast60 /100 | .0090643576 | .029995062863 |1310.72 |.000183558 /.000090385 |
| Highlights60 /1e−8 | .009995062863 | .029995062863 |1310.72000017 |1.87e−12 /1.87e−12 |
| Highlights60 /100 | .009995062863 | .029995062863 |3011.24515934 |.000259680 /.000132152 |

The ordinary control improves with the larger cube. Signed-channel and HDR projection errors do not disappear at larger cube size. At epsilon, a live table is approximately channel projection while Amount0 bypasses it. A signed channel can be outside the RGB cube even when its pixel luminance lies safely inside the tone axis. An all-negative pixel uses the direct scalar equation's−20EV floor but its ORIGINAL negative RGB survives; the table instead projects each channel close to the cube lower endpoint. HDR has both a channel-domain problem and a luminance-axis extent question; it must not be treated as merely ordinary interpolation error.

## Decision and limitations

A luminance-driven scalar gain multiplied into original RGB would avoid the independent channel projection. These results justify investigating that operator, not installing an unproven implementation. The global tone path is not a drop-in substitute: it uses a spatial guided mask and a baked gain response with its own forward monotonicity backstop/resampling, whereas local CPU uses direct per-pixel gain. Any scalar approximation must qualify the−20EV floor, high-luminance range, solved tone windows/anchors and zero continuity without inheriting another clamp. Native Float arithmetic, GPU kernel execution, masking/composites, mixed WB/colour/grade and real-photo compatibility are not measured here. Existing positive local-tone saved looks can change if the operator is corrected; no saved-look identity or general Amount closure is claimed.

## Reproduce without overwriting evidence

Use a release Core build whose complete manifest matches the chosen source tree. The runner refuses an existing output directory and refuses compilation/execution if any Core source differs. It executes the diagnostic once and records failures rather than retrying. Example with this session's actual paths (not a claimed second execution):

```bash
python3 docs/audits/2026-10-18-raw/local-tone-domain/run-probe.py \
  --source-root /workspace/scratch/2982a056243e/lumen-local-tone-domain \
  --build-release /workspace/scratch/2982a056243e/build-neutral-kelvin-core/x86_64-unknown-linux-gnu/release \
  --build-manifest docs/audits/2026-10-18-raw/local-tone-domain/evidence/expected-build-core-sha256.json \
  --swiftc /workspace/scratch/2982a056243e/swift/usr/bin/swiftc \
  --dependency-root /workspace/scratch/2982a056243e/swift-deps \
  --output-dir /workspace/scratch/2982a056243e/local-tone-domain-reproduced
```
