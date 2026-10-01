# Execution 05 — exact Mixer prerequisite, not a production route

2026-09-22. **AI-03 remains open, P1.** This change provides a non-enabled GPU
Mixer primitive and independent tests. No production renderer selects it. The
four strict expected fidelity failures in `ColorTableAccuracyTests` remain
unchanged; an aggregate green run must not be described as fixing them.

## Decision and rejected experiment

Work began at `e001428` on `codex/lumen-exact-mixer`, using macOS 27, arm64,
Swift 6.4, optimized native Core Image. All probes use synthetic colours.

Execution 04 proposed a family-eligible exact Mixer route. The experiment now
shows why that recommendation is insufficient: switching between an accurate
operation and the old inaccurate combined colour cube exposes the cube error as
a discontinuity when another control becomes nonzero. Strict eligibility prevents
double application, but does not make this boundary safe.

For Aqua Luminance −100 at the original positive input
`(0.38413364324424248, 0.59591710513566343, 0.64828909901873966)`, replacing only
S9/S10's Mixer-only cube with the analytic primitive reduced full-graph error
from 51.21167 to 1.69374 at 33, and from 37.13492 to 0.47310 at 65. Finish LUTs
were unchanged. These improvements were **not** sufficient for acceptance.

Then adding **0.001** to a second legal control produced these jumps:

| Added control | Intended exact jump | Candidate GPU jump, 33 | Candidate GPU jump, 65 |
| --- | ---: | ---: | ---: |
| Basic Saturation | 0.000251 | 50.175840 | 36.912189 |
| Vibrance | 0.000186 | 50.175840 | 36.912189 |
| Mixer Uniformity | 0.000056 | 50.175840 | 36.912189 |
| Red Primary Hue | 0.035707 | 50.175840 | 36.912189 |
| Shadows Tint Hue | 0 | 50.175840 | 36.912189 |
| Grade Master Hue | 0.000751 | 50.175840 | 36.912189 |

The metric is the same encoded Rec2020-channel code equivalent as Execution 04:
`255 × max(abs(sRGB-transfer(actual) − sRGB-transfer(reference)))`. It is not
DeltaE or a final sRGB-primary code difference. Exact comparison includes the
same finish operation. The tiny secondary moves reuse essentially the same
sampled table; the large difference comes from the rendering-algorithm switch.

The candidate changes to `RenderPlan`, `ReferenceRenderer`, `RenderGraph`,
`Kernels` and production regression assertions were removed completely. An
experimental patch and numeric JSONL were retained outside the checkout for
the audit. `testShippingGraphHasNoNewMixerEligibilityBoundaryJump` exercises all
12 boundaries against the unchanged shipping graph, with an ordinary 0.25-code
limit; it rejects the candidate even when its isolated accuracy tests pass.

## What the prerequisite implements

`ColorEngine.exactMixer` resolves only an otherwise isolated S9 Mixer: current
sanitized band arcs and clamped H/S/L values. This is **not** whole-pipeline
eligibility; it cannot see grading. `ExactMixer.apply` calls the original CPU
engine. `ExactMixerGPU` uses one compiled kernel with eight pairs of band parameter
vectors and twelve matrix-row vectors, not a recipe-specific shader or a sampled
colour cube. The engine's actual conversion context travels with the primitive.

The shader ports signed RGB-to-OKLab, raised-cosine normalized band weights,
chroma gating, the shared lightness shaping function, and inverse OKLab. CPU
matrices arrive as uniforms and constants supply the shader source; CPU `ColorEngine.apply` supplies
the independent numeric oracle. Signed cone responses, negative RGB and scene
headroom are not intentionally clamped at zero or one. Near-neutral zero adjustments return the
original pixel. Output alpha is preserved.

No production kernel-availability roster, table cache, recipe interpretation,
preview revision or image pixels change. There is no claim that the prerequisite
has already improved photographs in the application.

## Qualification

Native optimized qualification:

```sh
swift test -c release --jobs 2 --scratch-path <isolated-scratch> \
  --filter 'ExactMixer|ColorTableAccuracyTests|KernelGoldenTests'
```

- 5 new core tests: extraction, no-op/disabled state, shared sanitization, current
  recipe parameters and independence from upstream/downstream controls.
- 9 new GPU tests, with **ordinary** passing assertions, never expected failures:
  every H/S/L endpoint on all 8 bands, overlapping custom arcs, float/half formats,
  signed/neutral/highlight preservation, WB/exposure/Printer-Light prefix ordering,
  unchanged combined-family dispatch, original isolated Aqua regression, conversion
  context preservation, signed cone cancellation and all 12 continuity boundaries.
- 65 existing `KernelGoldenTests`, unchanged.
- 2 existing `ColorTableAccuracyTests`, unchanged, with the same **4 strict
  expected fidelity assertions**. Their values still reproduce Execution 04.

Both final native runs passed **81 tests, 0 unexpected failures, 0 skips**,
retaining those 4 expected assertions. The repeated run forces a real `.RGBAh`
destination for the half-format case, rather than only requesting a half working
context that Core Image could optimize away. Float32 raw-stage maximum error
was `1.171e-5 × scale` over the 48 endpoint recipes, and `1.226e-5 × scale` on
the overlapping custom-arc recipe, where
`scale = max(1, maxAbs(input), maxAbs(expected))`. The unchanged float32 gate is
`3e-5 × scale`; explicit half-float output measured `8.745e-4 × scale` against
the unchanged `0.003 × scale` gate.
Original Aqua as an isolated exact primitive measured **0.0000583 code equivalents**
against the direct engine, under the original ordinary three-code threshold.

Each broad comparison uses 1,570 float32-quantized inputs: the original Aqua
sample, signed/HDR sentinels, 65 neutral exposure samples from −20 to +12 EV,
1,152 hue/chroma/exposure combinations, 48 exact hue-seam/chroma-gate neighbours,
and 300 seeded signed random colours. Endpoints alone exercise 75,360 pixel/recipe
pairs. The oracle is original `ColorEngine.apply`, not a baked LUT, shader-generated
reference or copied golden. GPU kernel compilation, finite output and nonzero
original-regression output are ordinary assertions; unavailable GPU is not skipped.

### Numerical diagnosis, not a widened tolerance

The first actual GPU endpoint corpus failed seven raw-stage assertions: up to
`6.40e-5 × max(1, |input|, |expected|)` against a `3e-5` float32 bound. Signed
RGB `(3.283846139907837, 0.6904295086860657, -0.6745206713676453)` has an almost
cancelling blue cone response. Input values were already float32-quantized for
**both** CPU oracle and GPU upload; directly reading the GPU input confirmed the
same values. This was not a comparison against unrepresentable Double inputs.

The intended blue cone response was `4.45038678e-5`; the shader produced
`4.4361936e-5`. Directly rendering matrix literals identified source-constant
precision loss, independent of the Mixer. On this runtime, the literal
`0.10010263127936` produced float bit pattern `1036845720`, versus correctly
rounded `1036845724`; two other coefficients differed by one ULP each. A small
cone error is amplified by the signed cube root and can shift hue membership.

One signed Newton cube-root refinement improved other errors but did not solve
that cancellation: six endpoint assertions still failed. Supplying the four CPU
matrices as uniforms, instead of decimal source literals, moved the same cone
response to `4.4491546e-5` and the diagnostic pixel's endpoint errors below `1e-5`
relative. The cube-root refinement remains; the original numeric bounds remain
unchanged. This is a measured implementation change, not a new LUT golden or an
excluded signed domain.

### Cost and limits

The primitive's logical uniform payload is 92 float scalars (368 bytes before
vector alignment/framework overhead), independent of cube size, plus one compiled
kernel. It allocates no colour table: a conventional RGBAf 33³ table's data is
574,992 bytes, and 65³ is 4,394,000 bytes. These are representation sizes, **not**
measured process-memory savings; production still uses its unchanged cubes.

No quiet timing window was available during this prerequisite qualification.
Therefore no interactive-frame-rate, native-export-speed or peak-memory claim is
made. Tests force actual render completion, but their wall time is not a rendering
benchmark. Native timing and working-set measurements remain prerequisites for
enabling any complete exact chain. CIKL source compilation uses the platform's
deprecated runtime kernel API, consistent with existing kernels; this is not yet
a Metal-library migration or a multi-GPU/platform qualification.

## A bounded fully exact S9/S10 route

The next implementation should port pure pixel arithmetic in independently
verified pieces, then enable the **whole** S9/S10 chain together. Existing CPU
intent is the reference: no band re-anchoring, density redesign, new neighbourhood
model or creative change is part of this repair.

### State and stage boundaries

Resolve immutable GPU parameters in the existing engines, sharing sanitization,
matrices, window definitions, constants, measured per-band target hues and
recipe-dependent limiter solutions. Do not duplicate these in a second UI-side
compiler. Keep recipe/table caching changes separate until correctness is gated.

Within S9, retain these values explicitly:

1. `s9Input`: signed scene-linear RGB after S6/S7.
2. `preMixer`: primary-remapped and shadow-tinted S9 input. Under today's shipping
   flat-neighbourhood semantics this is also the fixed variance reference.
3. `moved`: Mixer result, then each Point Colour swatch in creation order.
4. `bandSource`: result after Mixer and Point Colour, **before** Basic Colour.
5. `s9Output`: Basic Colour followed by B&W, whose band selection reads
   `bandSource` while its luminance reads the modified colour.

Do not recapture the variance reference from post-Mixer RGB. Point Colour Variance
must continue to read the same pre-Mixer reference even after previous swatches
modify the current pixel. Do not introduce a guided-filter neighbourhood as a
side effect of this accuracy port: that would change existing creative intent.

S10 measures its tonal axis from `s9Output` once. Wheels and the advanced grid
both use that unchanged axis. Wheels' tint precedes brightness, then the grid's
Hue → Chroma → Vibrance → Saturation → Brilliance sequence remains literal.
Keep wheel `lumScale`, grid `brillianceScale`, and their joint limiter resolved
by the existing CPU solvers. Do not recompute zones after a wheel brightness move
or solve monotonicity per pixel on the GPU. Printer Lights remain in S6.

### Port and verification order

| Bounded step | Port | Required independent gates before proceeding |
| --- | --- | --- |
| 1, this prerequisite | Mixer H/S/L and signed OKLab | All bands/endpoints; custom arcs; gate/seam neighbourhoods; neutrals; signed/HDR; actual GPU |
| 2 | Primaries matrix and Shadows Tint, then Uniformity | Neutral preservation; tint window endpoints; measured/fallback target hues; circular seams; combinations with Mixer |
| 3 | Ordered Point Colour, including Variance | Range endpoints; narrow selections; overlapping swatches; same fixed pre-Mixer reference; ±100 variance; no post-move reselection shortcuts |
| 4 | Basic Saturation/Vibrance, Skin protection and Density | Original positive Saturation regression; H-K brightness preservation at density zero; density endpoint; signed inputs; highlights and rolloff boundaries |
| 5 | B&W | All eight band endpoints; pre-Basic Colour membership at Saturation −100; chroma gate; disabled treatment exact no-op |
| 6 | Grade wheels and advanced grid | Original exact stage input axis; near-black blue-wheel regression; all pivots/blending/balance; joint limiter; mixed extreme wheels/grid; untouched-side identity |
| 7 | Enable full exact S9/S10 consistently | Original four regressions become ordinary passing assertions; broad mixed corpus; every family crosses zero without a routing jump; all renderer consumers and timing/memory gates |

Each intermediate primitive stays non-enabled. Use a shared private shader source
library for signed OKLab, H-K and shared weighting functions, but maintain the
independent original CPU arithmetic as the test oracle. One fused S9 kernel can
keep `preMixer` and `bandSource` in registers; swatches should use a fixed maximum
plus active-count uniforms only if the recipe's existing count semantics allow
that bound. Otherwise use ordered fixed kernels or a parameter buffer, without
silently dropping valid swatches. A separately verified S10 kernel is reasonable;
do not prematurely combine it with S9 before the stage tests are diagnostic.

A residual colour cube is not an acceptable substitute for the unported stages:
besides leaving their fidelity and signed-domain failures, a simple post-Mixer
`ColorEngine` invocation changes the variance reference and may change B&W
selection history. A per-recipe exact/cube switch recreates the discontinuity.

### Integration and performance acceptance

Only after all exact S9/S10 primitives pass should `RenderPlan` carry the complete
resolved chain, `RenderGraph` replace the one combined cube, and the software
fallback use direct exact CPU operations in the same order. Kernel unavailability
must select a truthful exact fallback or visible failure, never silently select
the inaccurate route. Preserve original finite guards and identity fast paths.

Update every shared stage tap (preview, export, before/after, colour-mask source,
local-stage source and reference rendering), not just the main preview graph.
Add tests for mixed S6/S7 and downstream presence/local/display stages to prove
no double application or stage reordering. Increment the persistent rendering
revision when this future production pixel change is integrated; this non-enabled
prerequisite does not require one.

Measure warmed GPU render time at representative interactive resolutions, native
export time, plan construction under slider drag, peak working-set/intermediate
buffers, and cold kernel compilation on a quiet native device. Compare matching
CI formats and force render completion. Test all-zero, one control and many-control
recipes; report hardware and medians/tails. Do not assume fewer cube allocations
means a faster pixel shader, or accept average speedup with a broken drag boundary.
The exact chain can remove colour-cube baking, but finish tables remain separate
and their approximation error remains outside the claim of this S9/S10 repair.
