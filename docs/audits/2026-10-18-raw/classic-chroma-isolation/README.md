# Chroma Detail isolation on a fixed synthetic field

Nine actual CPU `ClassicalDenoise` calls executed against the fresh optimized Core objects in `/workspace/scratch/2982a056243e/build-final-core/x86_64-unknown-linux-gnu/release`. The declared source checkout and isolated diagnostic checkout both had HEAD `5d1ff3a`; their **complete Core source manifests match exactly**, with no mismatch exemptions. `provenance.json` records both manifests, checkout states, compiler command, actual executed harness hash, module/object/binary hashes and execution status. These are source snapshots compared with the fresh-build reference, not an independent reconstruction of compiler inputs or whole-app/native qualification. The existing fresh-core build provenance is recorded in `../CLASSIC-INDEPENDENT-PROJECTION.md`.

The generated input is exactly the prior ISO6400/seed17 `chroma-high` field: raw f32 XXH64 **`4177df68f4a227fc`**, asserted before running Classic. Its deterministic RNG, analytic field and direct RGB MSE/sine/cosine/DC metrics are copied verbatim from the successful preceding diagnostic. No production wavelet serves as the oracle. All nine outputs are finite; Off is exactly identical to input. No input clipping was applied and the noisy input has zero negative or above-one RGB channels.

## Executed observations

Luminance NR is **zero** in all six Color Detail cases. Other controls remain fixed within each block; complete configurations appear in `metrics.csv`.

| Configuration | Color Detail positions | MSE / Off | Amplitude retention | Full output comparison |
|---|---|---:|---:|---|
| Chroma25; ISO-resolved other fields | 0, 50, 100 | 1.916640 | 0.314664 | All three f32 pixel arrays exactly equal |
| Chroma100; standard other fields | 0, 50, 100 | 2.423117 | 0.166774 | All three f32 pixel arrays exactly equal |
| Luma25 only; ISO-resolved other fields | Chroma0 | 0.871736 | 0.940932 | Separate control |
| Luma100 only; standard other fields | Chroma0 | 0.948132 | 0.898675 | Separate control |
| Off | Luma0, Chroma0 | 1.000000 | 1.004325 | Exact input identity |

Thus the observed flat Color Detail response persists with Luminance NR disabled. It was not caused solely by active Luminance NR hiding a Color Detail response. The separate luma-only controls also show that the original combined-master measurements included luma-stage influence on this field. Neither conclusion proves that Color Detail is ineffective globally or establishes an appropriate default.

The clean RGB direction is `(1, -0.2627/0.6780, 0)`: its published linear Rec.2020 luminance coefficient is zero. Its projection onto the arithmetic-mean orthonormal Y0 axis `(1,1,1)/sqrt(3)` is **0.3536483286**, not zero. Production Classic applies a nonlinear per-RGB variance-stabilizing transform **before** the Y0U0V0 rotation. Consequently constant Rec.2020 linear luminance does not mean constant actual VST Y0; the raw linear coefficient is not claimed to equal actual VST Y0 amplitude. Luma-only attenuation is therefore not by itself a luma/chroma separation correctness failure.

Source inspection suggests the chroma-magnitude edge map can explain missing Color Detail authority for a period-four sign-changing field of nearly constant magnitude. That remains a **hypothesis**, not a demonstrated causal explanation: this run did not mutate or replace the production edge map, inspect its internal plane, or remove the later smoothing pass. The new causal isolation concerns the luma master only. No noise-estimator/model/default, production math, existing test, tolerance or golden changed.

This is one 64×64 analytic pattern, one ISO and one seed with variance-matched Gaussian RGB noise. It does not certify macOS GPU agreement, camera noise calibration, natural-texture beauty, private-photo acceptance or AI model quality. Raw metrics report phase and DC as well as MSE/amplitude; no new quality acceptance threshold was imposed.

## Reproduce

`executed-harness.swift` is the exact successful Swift source. The first compile attempt had an ambiguous String initializer and made **no Classic calls**; that compile failure/provenance is preserved separately. Explicit String typing resolved it. Successful compilation/execution both returned zero.

The executed invocation was `python .../classic-chroma-isolation/run.py`; exact compiler and executable commands are in `provenance.json`. The retained reproduction wrapper now requires a fresh output directory so it cannot overwrite this archived result:

```sh
python docs/audits/2026-10-18-raw/classic-chroma-isolation/run.py /tmp/lumen-chroma-isolation-new
```

Update the documented toolchain/build paths in the wrapper for another machine and build a matching release LumenCore first. The wrapper refuses unequal complete Core manifests. It changes no maintained script or required CI job. Run time in provenance describes this tiny diagnostic, not application or camera performance.
