# Practical signed-input Amount follow-up — native execution pending

Source baseline: `0a82064` (production source `a4bc150`). This candidate adds only
`LocalAmountSignedDomainCharacterizationTests`; it does not change production,
creative defaults, saved recipes, goldens, existing tolerances, or the existing
strict RED `LocalAmountEpsilonDiagnosticTests`.

## Exact scope

The opt-in synthetic fixture supplies sixteen actual Float32 RGB patches: negative
red magnitudes 0.03 through 0.00001; the independently calculated lower shaper
endpoint and values immediately around it; an in-domain negative value; zero,
ordinary mixed RGB, saturated mixed RGB with a negative channel, unit-range RGB,
and moderate HDR RGB `(16, 4, 1)`. It does not need a private photograph or claim
these values' frequency in real pictures.

For cubes 33 and 65, direct mask Amount and equivalent group Amount, it measures
Amount `0`, `1e-8`, `.01`, `1`, `25`, and `100`. Each stage record includes actual GPU
and analytical CPU-reference RGB values and differences for all sixteen patches.
Four zero stages must remain exactly identical. The epsilon projection equation
uses the independently expanded physical shaper endpoints, not the LUT sampler;
its explicitly limited comparison is red in the first ten patches. Normal-alpha
composites at `.25` and `.75` run at epsilon and 100 Amount, with scalar Float32
mask readback checked directly. Their independent blend equation uses the measured
GPU stage output, so a correct composite does not certify the adjusted stage.

Expected output is 24 stage records, 16 composite records and one summary, each
prefixed `LOCAL-AMOUNT-SIGNED`. All finite/input/zero/scalar-alpha/equation controls
are assertions. The equation readback checks retain the existing `1e-3` stage bound;
there is no new parity tolerance. CPU/GPU differences are measurements here, not a
new acceptance: the original strict diagnostic remains unchanged and RED.

```sh
LUMEN_LOCAL_AMOUNT_SIGNED=1 swift test -c release \
  --filter LocalAmountSignedDomainCharacterizationTests
```

Executed in cloud so far: Swift frontend syntax parsing and `git diff --check`
passed. A fresh unchanged LumenCore release build also passed in 73.13 seconds;
it did not execute this Core Image fixture. Native Apple SDK compilation, GPU
execution, output counts and actual signed-range measurements remain pending.
No GPU performance or camera acceptance is inferred from parsing or the Core build.

## Why no residual production repair was selected

Let `P` project channels onto the fixed LUT input domain and let `T_s` denote the
existing table at strength `s`. A linear residual extension would be

`R_s(x) = T_s(P(x)) + x - P(x)`.

It preserves every in-domain table result and removes the strength-zero domain
projection in the mathematical identity limit. It does **not** implement the
analytical adjustment outside that domain. Even the affine counterexample
`F_s(x) = (1+s)x` gives `R_s(x) = x + sP(x)` rather than `x + sx`; the error is
`s(P(x)-x)`. Nonseparable hue, grading and tonal-window operations have stronger
reasons not to infer their response at `x` from `P(x)`.

This extension also changes saved extended-input looks: relative to the current
positive-strength table result, the additive change is `x-P(x)`, irrespective of
the strength. Removing a discontinuity is therefore not proof of CPU accuracy or
creative compatibility. No such extension is installed by this change.

Current source has no analytical grading-wheel GPU kernel to reuse. Grading includes
signed OKLab conversion, Lumen UCS brightness, input-derived tonal windows and
resolved wheel/colour-balance limiter parameters. An analytical port needs its own
Float-uniform CPU twin, independent endpoint/interior/signed/HDR checks, zero and
cross-control continuity, mask/group and normal-alpha checks, real GPU performance,
and an explicit saved-look compatibility decision. A wheel-only route that changes
when a second control first becomes nonzero would itself require continuity proof.
Tone, local WB, hue/tint and local curves remain separate unqualified domains.

The subsequent owner Off-return/load observation interrupted deeper mathematical
experiments. No residual numerical experiment or analytical shader execution is
claimed here; the affine counterexample is a derivation, and this native fixture is
prepared for the next evidence run.
