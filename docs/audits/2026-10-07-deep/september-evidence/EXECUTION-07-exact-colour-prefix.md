# Execution 07 — non-enabled Primaries, Shadows Tint and Uniformity prefix

2026-09-22. Step 2 of Execution 05's staged exact-colour plan. **AI-03 remains
open, P1.** The production colour cube and its four strict expected accuracy
failures are unchanged. This work is an independently tested prerequisite, not
a change to photographs rendered by the application. **Uniformity's antipodal
branch remains a release blocker.** Three newly measured numeric assertions are
strict expected failures, in addition to the four unchanged production LUT ones.

## Scope and shared state

Branch `codex/lumen-exact-colour-prefix`, based on `e402ef6`. Native macOS 27,
arm64, Swift 6.4, optimized tests. Only synthetic inputs are used.

`ColorEngine.exactColorPrefix` exposes the original engine's already resolved
primary-remap matrix, identity flags, shadow-tint offsets, sanitized Mixer arcs
and H/S/L values, clamped Uniformity and per-band target directions. Primaries'
chromaticity safety checks and white-point normalization remain in the original
CPU resolver. Uniformity targets still use a finite renderer measurement for
each band when available, otherwise that band's sanitized core midpoint.

The existing `ExactMixer` is a narrow wrapper around this same resolved prefix.
Its earlier exclusion rules and independent regression tests remain in place.
`ExactMixerGPU` delegates to the same new `ExactColorPrefixGPU` kernel; there is
no second copy of the Mixer arithmetic to diverge later.

Active Point Colour, Basic Colour and B&W are excluded until their own ports are
verified. Identity is represented explicitly and returns the original image.
The extraction predicate is **not** a production routing decision: enabling a
partial exact route would recreate the discontinuity measured in Execution 05.

## Preserved arithmetic and ordering

The shader follows the current original CPU intent:

1. Apply the resolved primary matrix, bypassing it on exact identity.
2. Measure luminance on that remapped colour. Shadows Tint uses the existing
   −3 EV pivot, 1.5 EV half-width, raised-cosine window and −20 EV log floor.
   Apply the resolved a/b translation through signed OKLab; do not clip negative
   channels or impose a display white ceiling.
3. Measure Mixer membership and the chroma gate on the resulting **pre-Mixer**
   colour. Aggregate all band H/S/L moves before applying any of them.
4. Blend Uniformity's target directions on the unit circle using the same gated
   normalized weights. Apply the original shortest-angle convergence, including
   the existing resultant-magnitude guard. Uniformity does not select from a hue
   already changed by the H/S/L move.
5. Apply the combined moves and return signed scene-linear RGB.

The current shipping CPU path has a flat neighbourhood: its variance reference
is the same pre-Mixer colour. This port preserves that limitation deliberately.
It does not introduce a guided filter, infer a new spatial mean, remeasure band
targets after WB, or redesign band centres, names, arc geometry or convergence.
Future Point Colour work must retain this pre-Mixer reference through the new
swatch operations, as documented in Execution 05.

Matrix rows remain uniforms, not decimal shader literals, preserving the
precision repair identified in step 1. The same signed cube-root refinement is
used for all OKLab conversions. The CPU oracle remains original
`ColorEngine.apply`, not the new resolver, shader or a LUT sampled from either.

## Qualification

Native optimized qualification uses:

```sh
swift test -c release --jobs 2 --scratch-path <isolated-scratch> \
  --filter 'ExactColorPrefix|ExactMixer|ColorTableAccuracyTests|KernelGoldenTests'
```

The broad first numerical qualification passed 94 tests, with no unexpected
failures or skips, retaining the original four AI-03 expected assertions. A final
targeted angle probe then found the defect below. It is not acceptable to describe
that earlier green corpus as full qualification of Uniformity.

The additional failures were first recorded as **ordinary red** GPU tests: two
assertions for explicitly supplied antipodal targets, then one for genuine
image-derived targets. Only those three unchanged `3e-5` numeric comparisons are
now inside strict `XCTExpectFailure`. Kernel availability, usable images, finite
RGB, nonzero GPU output, valid sidecar round-trip, finite measured targets and the
positive measured-case input/exact output remain ordinary assertions outside the
quarantine. Existing production tests and goldens are unchanged.

The final selected run has 6 new core tests, 9 new prefix GPU tests, the previous
5 core/9 Mixer GPU tests, 65 existing kernel goldens and 2 original colour-table
tests: **96 tests, zero unexpected failures and zero skips**, with **7 known
expected numeric assertions** (4 original, 3 new). The native command exited 0;
all three new expected comparisons reproduced their recorded errors unchanged.

Ordinary prefix parity corpus: 1,360 float32-quantized colours per recipe, including
signed and HDR sentinels, 65 neutral exposures from −20 to +12 EV, 1,008
hue/chroma/exposure combinations, 270 band-seam/chroma-gate neighbours and nine
Shadows Tint window-boundary samples. The eight Primaries/Tint controls at both
endpoints give 21,760 pixel/recipe pairs. Uniformity is checked at 0, 0.001, 1, 50
and 100 with canonical, measured and asymmetric custom-arc targets. Mixed H/S/L,
Primaries, Tint and Uniformity retain their original order. A true `.RGBAh`
destination is used for the half-float check.

| Ordinary corpus | Maximum raw relative error | Unchanged bound |
| --- | ---: | ---: |
| All 16 Primary/Tint endpoints | 3.620e-7 | 3e-5 |
| Uniformity: default/measured/custom arcs | 3.802e-6 | 3e-5 |
| Mixed Primaries/Tint/HSL/Uniformity | 8.633e-6 | 3e-5 |
| Mixed, materialized half-float output | 9.469e-4 | 0.003 |

Relative error divides the largest absolute RGB difference by
`max(1, maxAbs(input), maxAbs(expected))`. This is not DeltaE or a display-code
metric. These maxima explicitly **exclude** the separately reported failing
antipodal cases; they are not a universal fidelity bound.

## Reachable unresolved antipodal defect

At Uniformity 50, a shortest-angle deviation just below +180° and one just above
it select opposite half-turns. A tiny Float/Double angle disagreement then creates
a large output difference. The original CPU field itself has a discontinuity at
this boundary; simply choosing another constant tie-break is not a fidelity fix.

The first reproduction supplied all eight targets as 0° or 180°. Identically
float32-quantized inputs near 180°/0° differed from the original Double engine by
**0.88240091** in a raw channel. This was not input-storage rounding in only one
side of the comparison.

The issue is also reachable without manually inventing target arrays:

1. Use a legal recipe with Uniformity 50. Set all bands' core half-arcs to 5° and
   feathers to 22.5°, except bands 3 and 4, whose cores are 44° and feathers 60°.
   The automated test round-trips these finite settings through canonical recipe
   JSON and the actual XMP serializer/parser, and checks recipe equality.
2. Supply two positive proxy-image colours to the existing
   `ColorEngine.measureBandMeanHues`, using the recipe's real sanitized arcs:
   `(0.308785617351532, 0.18422016501426697, 0.06051457300782204)` and
   `(0.21766723692417145, 0.1832602471113205, 0.44326499104499817)`.
   The measured targets of bands 3/4 become approximately 64°/292°. A rare
   full-resolution query colour need not appear in the small statistics sample.
3. Query positive RGB
   `(0.11826113611459732, 0.27397552132606506, 0.22000643610954285)`.
   Its measured hue is about 178.000001°; the blended target is about 358°.

| Result | R | G | B |
| --- | ---: | ---: | ---: |
| Original CPU | 0.174091817 | 0.205139669 | 0.472382270 |
| Candidate GPU | 0.268178374 | 0.208754584 | 0.050031062 |

The raw error is **0.422351208**. Source samples, query and exact output are all
positive; this cannot be attributed to the separate negative-domain LUT defect.
This is a controlled synthetic construction through the real measurement path,
not a claim that the issue was observed in a supplied private photograph.

The CPU also jumps by approximately 0.422351 between adjacent representable query
colours straddling this angular boundary. Matching its branch in FP32 is therefore
qualitatively different from reducing an ordinary smooth arithmetic error.

One bounded alternative was measured and rejected: compute relative angle with
`atan2(cross(target, Lab.ab), dot(target, Lab.ab))` instead of subtracting rounded
degree angles. It corrected the initial three samples but produced another
**0.88240089** failure near hue 0°. This improves some conditioning but does not
resolve the discontinuous field, and it was not adopted. No error threshold was
increased; no failed case was removed from the recorded evidence.

## Remaining integration gates

An explicit boundary/precision contract is required before Uniformity can be
qualified for a production exact route. Changing its convergence to a continuous
model would be a creative-semantics decision, not a hidden GPU-port optimization.
Alternatively preserving the current Double branch requires a separately proven
precision strategy; repeated local FP32 adjustments are not proof. Do not activate
this partial prefix, use a per-family exact/LUT fallback switch, or call the three
new expected failures a completed repair.

No persistent rendering revision change is needed because production pixels do
not change. No speed or peak-memory improvement is claimed: there is no enabled
production route to benchmark. The future full exact S9/S10 chain still needs
Point Colour, Basic Colour, B&W and grade ports, independent mixed-stage and
continuity tests, all renderer consumer wiring, and quiet native performance
qualification before activation.
