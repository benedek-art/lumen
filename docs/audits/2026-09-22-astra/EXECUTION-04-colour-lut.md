# Execution 04 — colour-table fidelity: measured options, not a shipped fix

2026-09-22. AI-03 remains **open, P1**. This change adds two independent GPU
regression tests and this report. No shipping colour maths, tables, interpolation,
cache keys, shader, or creative appearance changed. Four fidelity assertions are
strict, explicitly labelled expected failures; a green aggregate test result must
not be reported as a fix for AI-03.

## Scope and decision

Investigated on `codex/lumen-colour-accuracy`, starting at `2efd71e` (the RAW repair
on the `40e1048` implementation base). macOS 27, arm64, Swift 6.4, native optimized
Core Image rendering. All inputs here are synthetic; no private photographs or
paths are needed or committed.

Do not replace the global colour cube with the experimental adaptive cube. It
dramatically improves many ordinary inputs, but misses narrow Point Colour
selections, mishandles signed and near-black values, and adds preparation and GPU
cost. It is not a faithful universal fix. Increasing a scalar cube dimension or
loosening a golden also does not address the architectural problem.

Recommended next step: a bounded exact-GPU **Mixer-only** implementation, selected
only for eligible recipes, with an independent signed/HDR pixel corpus and a
matched CPU reference route. Then a separate exact Basic Colour implementation.
Do not label either family-specific step as resolving the general AI-03 issue.

## The shipping failure, independently reproduced

`RenderPlan.swift:215–220` evaluates `GradeEngine.apply(ColorEngine.apply(scene))`
at a fixed lattice over per-channel `LumenLog`, then stores log-encoded outputs.
`RenderGraph.swift:107–111` runs the stock colour cube between the two log shapers.
There are only 32 or 64 intervals per channel across 24 stops: 0.75 or 0.375 EV
per interval. These are poor coordinates for narrow hue/chroma membership gates.
CPU tetrahedral versus GPU trilinear interpolation is an additional difference,
but CPU tetrahedral sampling also exhibits the large error; changing only the
interpolant cannot solve it.

The new `ColorTableAccuracyTests` compare the **actual GPU graph** to
`RenderPlan.exactColor`, which evaluates the colour engines and finish operations
directly. They do not use `referenceColor` or a second LUT as the oracle.
The recipe is otherwise neutral and denoising is off. Both original input RGB and
exact colour/grade output RGB are strictly positive, asserted outside quarantine.
Therefore these two regressions do not depend on negative-input clipping.

Metric throughout: `255 × max(abs(sRGB-transfer(actual Rec2020 RGB) −
sRGB-transfer(exact Rec2020 RGB)))`. These are **encoded Rec2020-channel code
equivalents**, not DeltaE and not final sRGB-primary image pixel differences.

| Recipe | Input scene-linear Rec2020 RGB | GPU 33 error | GPU 65 error |
| --- | --- | ---: | ---: |
| Aqua Mixer Luminance −100 | (0.38413364324424248, 0.59591710513566343, 0.64828909901873966) | 51.21167 | 37.13492 |
| Basic Saturation +100 | (0.78994447795661316, 0.51750730037644888, 0.21031789665386302) | 14.21915 | 31.33260 |

For Aqua, exact colour/grade RGB is (0.106532096, 0.205737366, 0.232635236).
The exact finished RGB is (0.127833321, 0.220671395, 0.249249294); the GPU 65
result is (0.242881194, 0.383300453, 0.422760129).
For Saturation, exact colour/grade RGB is (0.817175462, 0.476178238, 0.129531299).
The exact finished RGB is (0.660961116, 0.429770462, 0.133532749); GPU 65 returns
(0.664460778, 0.419362754, 0.062847927).

The larger cube makes that Saturation sample worse. A convergence test on one
coarse hue/exposure grid does not establish a worst-case bound for other colours.
The prior proof suite's baked-table parity/goldens do not establish accuracy
against the intended operations either. Existing convergence tests also use a
much gentler recipe and a sparse hue grid.

Initial optimized native run: **2 tests, 4 failures**, 0.482 seconds after build.
The unchanged three-code threshold is now under strict `XCTExpectFailure` at only
those four assertions. Finite RGB, nonzero GPU output, and positive original/exact
colour-stage inputs remain ordinary requirements. A future pass at one of these
assertions is an unexpected success and requires removing its quarantine.

## Bounded same-budget experiments

The exploratory harness used the two exact inputs plus 1,500 deterministic uniform
linear-Rec2020 RGB samples. PRNG seed 774123; state update
`state = state * 6364136223846793005 + 1442695040888963407` with UInt64 wrapping;
each sample component is `(state >> 11) / 2^53`. All seven audit recipes were
checked: Aqua Luminance −100, Basic Saturation +100, Red Mixer Hue +100, blue
global wheel at full saturation, grade Hue +180, grade global Saturation +100,
and the combined extreme primary settings from the original audit.

For comparing coordinate systems, an explicit eight-corner **trilinear** sampler
was used instead of `LUT3D.sample`'s tetrahedral sampler. The colour/grade result
then entered the same exact display transform on both sides. This isolates the
colour-table approximation from finish-table error. These numbers are therefore
not interchangeable with the full GPU graph numbers above.

Alternatives measured at both 33³ and 65³, without enlarging the cube:

1. Original log-RGB coordinates, but store `(output − input) / max(input RGB,
   0.0001)`, reconstructing a linear RGB residual instead of interpolating output
   logs. Helps many zero crossings but does not resolve coarse hue sampling.
2. HSV hue/saturation plus log maximum RGB. Improves hue resolution, but does not
   resolve narrow perceptual gates and has a signed-domain problem.
3. OKLCh hue, relative chroma `C/L`, and log `L³`; either RGB residuals or OKLab
   residuals. An OKLab residual is `(Lab(output) − Lab(input)) / max(L, 0.001)`.
4. The same perceptual representation, focusing 75% of the lightness coordinate
   on `0 ≤ L ≤ 1`, with the remaining 25% logarithmic through the original upper
   bound `cbrt(LumenLog.decode(1))`. No scene highlights were intentionally dropped
   to make unit-range results look better.
5. Recipe-adaptive separable hue/chroma/lightness axes on that focused domain.
   Curvature envelopes were measured across exposure/chroma/hue slices independent
   of the test samples; 20% uniform allocation prevents a quiet interval being
   starved. Knot density was proportional to square-root second difference, mixed
   with that uniform floor. Lookup and bake used the same immutable axes.

The adaptive preparation sampled hue at 1° over lightness
0.05/0.1/0.2/0.4/0.6/0.8/1/2/4 and C/L 0.01/0.03/0.06/0.12/0.24/0.45/0.75.
Chroma and focused-lightness axes each used 128 intervals, with 24 hue slices and
seven/six companion-axis slices respectively. This was an exploratory numerical
layout, not an assertion that those slices bound every possible recipe.

Worst code-equivalent error over the 1,502 inputs, 65³, exact finish on both sides:

| Recipe | Original log/log | Log input, RGB residual | Focused OKLCh, Lab residual | Adaptive OKLCh, Lab residual |
| --- | ---: | ---: | ---: | ---: |
| Aqua Luminance −100 | 37.15 | 39.12 | 4.86 | 0.70 |
| Basic Saturation +100 | 46.85 | 24.28 | 12.80 | 4.78 |
| Red Hue +100 | 26.63 | 8.75 | 4.60 | 0.62 |
| Global blue wheel | 18.99 | 3.35 | 0.05 | 1.35 |
| Grade Hue +180 | 30.75 | 15.52 | 0.41 | 0.37 |
| Grade Saturation +100 | 55.45 | 5.31 | 0.11 | 0.11 |
| Extreme primaries | 5.32 | 1.81 | 0.43 | 0.43 |

These expose real trade-offs. Adaptive axes make the blue-wheel result worse than
the fixed perceptual grid: 33³ worst error rises from 0.24 to 5.23. At 33³ Basic
Saturation still reaches 13.32. No choice in this experiment satisfies a universal
three-code bound. The unit-RGB diagnostic cube, which cannot be shipped for
extended-linear scenes, also leaves Basic Saturation at 10.70 worst error at 65³.

## Broader domain gates reject the adaptive candidate

Additional independent corpora:

- 500 random linear-sRGB gamut samples, converted to Rec2020.
- 1,000 positive extended-linear samples with exposure spread from −12 to +12 EV.
- 500 signed RGB samples, each component uniform in [−0.2, 1].
- 97 positive neutral samples from −20 through +4 EV, plus exact zero, two negative
  greys and RGB(−0.05, 0.2, 0.4).
- Narrow Point Colour: sample (0.2, 0.4, 0.6), Range 0, Luminance −100.
- Combined edit: Basic Saturation +75, Aqua Luminance −75, grade Hue +90.

At 65³, the adaptive candidate still produces:

- Narrow Point Colour: **14.05** worst on the linear-sRGB corpus, despite a mean
  of only 0.071. A small average is particularly misleading for a selective tool.
- Combined edit: **24.88** worst on a positive extended-linear colour
  (11.774704737, 7.321831080, 144.021627505).
- Blue wheel: **112.88** on the *positive* neutral
  (2.041409308e−7, 2.041409308e−7, 2.041409308e−7).
  The normalized Lab residual is ill-conditioned here; it does not reproduce a
  nearly constant chromatic offset by interpolating against a black anchor.
- Signed-domain encode/decode round-trip error up to **0.9185 linear RGB**.
  `C/L` and a positive-L axis are not an extended-signed domain. Grade Hue's
  signed-corpus error reaches 213.21 code equivalents. Larger encoded differences
  outside normal display range are not literal visible 8-bit errors.

The positive extended corpus round-tripped the proposed input coordinates to
about 4e−12 linear, so its remaining colour error is not simply a clipped HDR
input. Conversely, the signed failures are structural and cannot be accepted as
interpolation tolerance. None of these experiments repairs the existing separate
signed-domain limitation of the finish cube.

## Native GPU prototype and costs

A nonshipping Core Image prototype implemented RGB↔OKLab conversion, adaptive
axis lookup through a 4,096-entry RGBAf one-row image, the unchanged-size stock
colour cube, and reconstruction of the Lab residual. It rendered the entire
1,502-sample strip, not just two hand-picked pixels.

Cube outputs had to be **normalized with paired per-channel offsets/scales**:
passing signed residual table entries directly to the stock cube did not preserve
them. That initial candidate produced gross errors and was rejected before the
figures below. Any production table representation must carry its domain and
output reconstruction metadata as one cache value, especially on stale-draft
paths; accepting an old table with new axes/scales is not a coherent transform.

Native adaptive GPU, colour stage then exact finish: Aqua corpus worst 1.67/0.74
at 33³/65³; Basic Saturation worst **13.10/4.82**. This closely tracks the CPU
trilinear experiment and independently confirms that the residual error survives
the actual GPU, not just the CPU sampler.

With the shipping finish stage also applied, the two original samples become:

| Original regression | Adaptive GPU 33 | Adaptive GPU 65 |
| --- | ---: | ---: |
| Aqua Luminance −100 | 1.4742 | 0.3777 |
| Basic Saturation +100 | **3.3196** | 0.6011 |

The broader failures above still disqualify this candidate.

The single cube payload remains 574,992 bytes at 33³ and 4,394,000 bytes at 65³
(RGBA Float32), plus a 65,536-byte adaptive-axis texture and a small metadata
record. This does **not** mean the prototype's total working set is unchanged:
normalization and upload make temporary copies. A 129³ payload alone would be
34,347,024 bytes, 7.8 times the 65³ payload, before upload copies; no global size
increase was made or proposed as the repair.

Timing is **exploratory, not isolated performance qualification**: other native
test lanes were active. Axis preparation alone measured 9–57 ms in one run and
31–229 ms for the same seven recipes in a busier run. It adds a substantial new
serial dependency before the parallel cube bake (original 33³ bakes in the first
experiment were approximately 0.4–5.6 ms). Per-pixel CPU conversion, three binary
searches, trilinear lookup and reconstruction commonly measured 0.2–0.7 μs, with
scheduling outliers; this is not a GPU throughput estimate.

Paired native 1920×1080 GPU graph renders, same shipping finish and synchronized
RGBAf readback, two warm-ups and five recorded samples each:

| Recipe | Original median | Adaptive median |
| --- | ---: | ---: |
| Aqua Luminance −100 | 6.24 ms | 9.48 ms |
| Basic Saturation +100 | 9.05 ms | 11.26 ms |

These measurements show that the prototype has a nonzero lookup cost; they do
not establish a device-wide interactive regression budget. Preparation cost and
domain failures already rule it out independently of those noisy timings.

## A bounded next implementation, with explicit gates

1. **Safe prerequisite, no pixel change:** extract a resolved colour-stage value
   containing the authoritative CPU engines/parameters, identity and eligibility
   predicates, and a direct `apply` oracle. Bake and exact-reference entry points
   should use that value, avoiding a third reconstruction of the recipe in the
   shader uploader. Add independent tests for the primitive signed cube-root and
   matrix operations before enabling a route. Keep the direct oracle outside any
   LUT or shader helper under test.
2. **Exact Mixer-only route:** eligible only when primaries/tint, Point Colour,
   Basic Colour, B&W and grade are identity. Start with the full H/S/L band
   membership model, user arcs and chroma gate. Either implement Uniformity with
   measured mean hues correctly or explicitly exclude it from eligibility; do not
   silently substitute the canonical target. Use one compiled kernel and uniforms,
   not shader-source compilation per gesture. This removes the colour-table bake
   for eligible recipes. CPU reference rendering must use the exact same route
   selection, while tests compare the independent direct engine.
3. **Exact Basic Colour-only route:** separately qualify Vibrance/Saturation,
   Density, Protect Skin, H-K brightness, chroma compression and hue restoration.
   Do not simplify the model to an RGB saturation matrix or weaken skin protection
   to make interpolation easier. Mixed or unsupported recipes retain the existing
   route until explicitly qualified.
4. **Composition, then remaining families:** make stage order explicit before
   enabling both analytic families in one recipe. Otherwise a residual fused cube
   can accidentally apply the Mixer twice or grade the wrong stage input. Point
   Colour needs creation-order semantics and stage-correct samples. B&W needs its
   pre-saturation band source. Exact grade needs the current joint limiter, tonal
   windows and anchor rules. These are separate, testable milestones, not one
   unreviewable shader port.
5. **Release gate for every enabled route:** pass the original assertions without
   expected-failure wrappers; compare raw scene-linear stage outputs before the
   finish, then the whole graph. Include signs, zero, near black, highlights,
   neutral ramps, hue seams, user arc extrema, ±100 endpoints, narrow selections,
   combinations and every render tier. Verify fallback routing is explicit and
   unchanged for ineligible recipes. Measure cold/warm 1080p and native-size
   rendering on a quiet machine, including plan preparation and peak residency.
   Bump persistent rendering revision only when shipping pixels change.

Analytic kernels will have a CPU/GPU maintenance burden. Parameter/constant
sharing and direct pixel-oracle tests mitigate it; replacing those tests with
baked LUT parity would recreate the blind spot this investigation exposed.
No exact-GPU performance claim has been made before implementing and measuring
that stage. AI-03 remains open until the eligible scope is stated and proved;
the separate finish-domain issue is not implicitly closed by an exact S9/S10.

## Verification and retained evidence

Run the always-on regression and adjacent kernel checks:

```sh
swift test -c release --jobs 2 --filter 'ColorTableAccuracyTests|KernelGoldenTests'
```

Native result: **67 tests, zero unexpected failures, zero skips, four explicitly
expected AI-03 assertion failures**. The 65 existing kernel tests passed normally.
No production source changed, so no rendering cache revision is needed here.

The local investigation retained `ColourDomainProbe.swift`,
`colour-domain-results.jsonl`, `colour-focus-results.jsonl`,
`colour-adaptive-results.jsonl`, `colour-adaptive-extended-results.jsonl`,
`colour-red.log` and `colour-quarantine-qualification.log` for the integrator.
The final extended file is the normalized-residual GPU run; earlier prototype
compile failures and unnormalized-output runs were not used for its measurements.
Only the small permanent tests and this report are proposed for integration.
