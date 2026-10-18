# GPU Dehaze sky-contract candidate

Base `0a82064` (tested production source a4bc150). This is a source candidate, not executed native acceptance. Prior independent scalar/native divergence evidence remains in `../dehaze-formula/`; the exact pre-change characterization source is archived here. No CPU equations, old goldens, existing tolerance values, defaults or profiles change.

## Intended correction and compatibility

The documented CPU sky evidence is `s = smoothstep(.5,2,log2(max(Y/.18,2^-20))) * (1-smoothstep(.05,.35,sqrt(lambda1)))`, clamped to [0,1]. The gradient tensor uses central differences, a box of radius `max(workingRadius/4,1)` with repeated border pixels, and its largest eigenvalue. The candidate computes this exact definition on GPU, rather than substituting the existing Sobel/LumenLog structure helper. It lifts the positive transmission floor from base .45 toward .9 and uses `max(1-transmission,s)` in the negative branch. The new log-EV kernel is in the core required-kernel availability roster.

Sky fields use the image before Texture/Clarity, matching the CPU decomposition lifetime. They are computed independently of the existing encoded transmission guide. GPU airlight/transmission still use the existing post-detail image and proxy estimator; CPU uses its pre-Presence decomposition and a different airlight selection estimator. Those are explicit remaining cross-control/estimator differences. This patch does not establish general CPU/GPU dehaze parity.

On a neutral flat .8 plateau with separate A=1 plateau, t=.24, sky=1: +100 changes .55555556 to .77777778; -100 changes .9368 to .98. At +35 the new result is .79222222; at -35 it is .863. These are analytic expectations supported by the earlier plateau characterization, not new candidate execution. Brightness/flatness below sky thresholds gives s=0 and the prior scalar equations. Saved images in sky-qualified regions intentionally change, globally and within masks. This is a documented-reference correction with a creative compatibility cost, not aesthetic retuning.

## Native gates owed

```sh
swift test -c release --filter DehazeSkyContractTests
swift test -c release --filter DehazeSkyFieldTests
```

The old characterization is transparently migrated to the independent documented contract, retaining the historical GPU equations as explicit negative controls. No failed old output assertion is silently deleted. New tests cover:

- Actual log-EV and tensor magnitude versus independent finite sums, radius 1 and 4, asymmetric spatial structure, frame boundaries and negative/zero luminance. Existing 1e-3 stage bound; CPU f32 intermediate writes are not assumed to be unlimited Double precision.
- Independent positive and negative kernel equations with colored airlight, nine brightness/gradient combinations and two strengths. These isolate sky terms from airlight/transmission estimator differences.
- Actual global presence and local/group amount with soft .25/.75 masks, signs, zero and +/-35/100; a nonzero Texture/Clarity plateau control. Alpha uses raw RGBAf data, not a color-managed CIColor constant.
- A distinct spatial fixture comparing actual applyPresence to explicit pre-Presence skySource; an actual post-Presence old-expression control must disagree by more than 1e-3. That causal gap is an unexecuted fixture assumption until macOS runs.
- Full-source graph tile readbacks and nonzero translated extent. These do not certify rebuilding the estimator from independently cropped source tiles, nor native export scheduling or every preview scale.

Causal mutations, one at a time in `Kernels.swift`, restoring source afterward:

1. Positive: `float t = max(raw, mix(floorT, 0.9, sky));` -> `float t = max(raw, floorT);`
2. Negative: `float distant = max(1.0 - raw, sky);` -> `float distant = 1.0 - raw;`

The corresponding direct positive/negative methods isolate the changed branch; the opposite-sign equation control must remain green. The field tests are independent of these final-combination mutations. Logs and counts should distinguish baseline, each mutant, source restoration, skips and failures. New fixture failures remain diagnostic evidence; do not widen tolerances to force green.

## Performance and execution limits

New fields add one log-EV pass, two central-difference convolutions, tensor construction, box smoothing and eigenvalue magnitude, with intermediate image residency. There are no added CPU image readbacks in the sky computation, and amount zero returns before these fields. Existing global airlight stats readbacks remain. This is a logical graph/pass count, not measured GPU memory or execution cost. Native tests print completed global render time including existing estimator cost; first/repeat comparable baseline/candidate timing remains required before a performance conclusion.

Swift syntax parsing and patch whitespace checks passed in Linux. Apple SDK compilation, GPU execution, new fixture assumptions, tiled/translated readback assertions and native performance remain pending. No camera/colorimetric, private-photo, GUI or subjective quality acceptance is claimed.
