# Next local-tone boundary: design only

Prepared after matrix fixes qualified at29ad3b0. No production candidate, native test, workflow, golden, default or tolerance change is implemented by this note. Frozen rendering must remain stable for the owner's separate private/native acceptance. Wheel Amount remains a distinct unresolved workstream.

## Smallest complete operator boundary

Replace ONLY S11 local tone's bounded RGB preLUT with a pure per-pixel scalar-gain stage. Keep the order currently defined by `ReferenceRenderer.LocalColourFront.colourStageInput` and `RenderGraph.applyLocalAdjust`:

1. Existing local exposure gain, before tone.
2. Exact local scalar-tone gain, driven by the current pixel, NOT a spatially filtered luminance mask.
3. Already-qualified exact local white-balance matrix.
4. Existing ExactColorStage passes (including ordered Point Colour references).
5. Existing hue/colour-tint/grade post stage, then local spatial adjustments; composite through mask alpha as today.

For finite scene-linear Rec.2020 pixel `c`, the intended CPU operator is:

```
Y = dot(Rec2020.luminanceWeights, c)
t = max(log2(max(Y, 0) / .18), -20)   // Num.safeLog2's nonpositive floor
s = ToneEngine.stops(at: t)
g = 2^s
out = (c.r*g, c.g*g, c.b*g)         // multiply ORIGINAL channels
```

The floor must be implemented without evaluating log2(0) in a branchless shader, e.g. log2(max(max(Y,0)/.18,2^-20)). There is no RGB projection, positive clipping or residual extension. A negative channel with positive Y remains a negative channel multiplied by the same gain; all-negative Y reaches the declared EV floor while its original channels survive. HDR above the LUT's previous RGB/EV domain must use the actual analytic response, not the final knot of a newly bounded 1D table.

The exact stage's identity predicate follows the already-constructed `ToneEngine.isIdentity`; Amount0 must bypass all work exactly. `Recipe.effective` resolves mask/group Amount; existing local scale is clamp(resolvedAmount,0,200)/100. Build the same scaled Tone as current LocalPlan, then let actual ToneEngine retain its existing clamps, solves and coupling. Do not replace this with interpolation between unscaled and fully-scaled rendered pixels: that is a different operator.

## Resolve once from actual engines

The new descriptor should be derived FROM the existing constructed `ToneEngine`, following `ColorEngine.exactStage`'s architecture. Its GPU Float twin must receive actual resolved state, not interpret the recipe independently or repeat the numerical monotonicity solves on GPU.

Actual symbols to carry:

- `ToneEngine.effectiveHighlights`, `effectiveShadows`, `effectiveWhites`, `effectiveBlacks`: the solved/eased amounts, not raw slider values. They already include the solve: do not multiply by `zonalScale` a second time.
- `ToneEngine.whiteAnchorEV`, `blackAnchorEV`: LOCAL anchors moved by the scaled local Whites/Blacks. Do not substitute global `plan.tone` anchors, fixed defaults or grading window anchors.
- The existing contrast amount/pivot and `contrastMapped` rules: clamp Contrast to±100, pivot to±4, slope1+.6*c/100, choose reach from the live local anchor on each side, retain `minContrastReachEV` and `contrastShoulderStart` behavior.
- Existing window definitions/constants from `highlightWeight`, `shadowWeight`, `whiteWeight`, `blackWeight`; use their sign/mirror conventions and actual EV amplitudes (`highlightShadowRangeEV`, `whiteToneEV`, `blackToneEV`).
- `ToneEngine.stops` sums solved `zonalStops`, `contrastMapped(t)-t`, and `zonePanelStops`. Current LocalPlan constructs `ToneEngine(tone: Tone(...))` with DEFAULT-NEUTRAL `Zones()`, so local zonePanelStops contributes zero today. Define/assert that scope explicitly. Do not accidentally inherit global Zones; if a future model adds local Zones, it must extend the descriptor and tests deliberately.

One small analytic tone kernel and resolved uniform descriptor/Float CPU twin is a plausible bounded next implementation. Sharing generated shader source and constants with Core is preferable to copied, drifting formula constants. ReferenceRenderer's existing Double engine must remain an independent oracle; do not make its expected result call the new Float twin.

Exposure stays separate even though the constructed local Tone contains its exposure field: `stops`, `gain` and the tone identity predicate do not incorporate that exposure. Applying it again in the new scalar stage would change the defined order and double the exposure.

Do NOT use global `RenderGraph.applyTone`: its spatial guided mask changes the operator. Do NOT substitute `ToneEngine.bakeGainLUT`: it samples a bounded axis and applies a forward monotonicity backstop (`clampedResponse`) that direct local `gain(at:)` does not use. A larger 1D table may improve an approximation but is not the exact operator defined above.

## Independent qualification before integration

Retain all existing tolerances/goldens and exact zero checks. New tests must use only stable preexisting production APIs where possible so the entire old RenderGraph can be restored as a causal baseline. Bound failure logs using counts/first example/max error, with explicit finite guards.

Required controls:

- Ordinary positive patches and ramps, plus an independently computed contrast central region: away from the existing shoulder, mappedEV=pivot+slope*(t-pivot), hence gain=2^((slope-1)*(t-pivot)). This tests an equation without using the new stage as its own oracle.
- A panel-only shelf control (e.g. Highlights), using actual exposed resolved amount and independently evaluated existing smoothstep/window expression. Include transition endpoints and both signs; preserve existing cross-control solves.
- Signed channel with positive IN-DOMAIN luminance, all-negative luminance at the−20EV floor, exact zero, near-zero positive luminance, and HDR luminance above the old axis. These distinguish channel projection from a scalar EV-domain error. Keep fixtures representable as finite Float after the intended gain; do not invent new overflow policy.
- Amount0, positive epsilon, small/partial/full/200%, both mask and group equivalents. Include endpoints where actual parameter clamping/solves bind, not an assumption that200% doubles the already-rendered100% delta.
- Actual scalar-mask RGBAf alpha0/.25/.75/1 with exact readback, Normal blend equation `(1-alpha)*base + alpha*adjusted`, preserved alpha and exact zero identities. Do not use colour-managed CIColor to author scalar alpha.
- Tone+qualified WB matrix and tone+exact colour, with independent ordered intermediate expectations. Preserve Point Colour selection reference order. Tone+wheel/hue/tint/curve must have separate stage taps/attribution because their remaining LUT domains can still clip; do not incorrectly require this tone-only change to close all existing downstream discrepancies.
- Existing tone authority/monotonicity/cross-control and global rendering tests remain unchanged. GPU tests compare actual new stage against actual existing Core gain equations, rather than only Float-twin agreement.

Causal gate: candidate strict tone-only signed/HDR/epsilon tests GREEN; restore the entire frozen old RenderGraph with identical new tests and kernel definitions retained; require active cases to fail while ordinary/neutral/zero controls remain healthy. Restore exact source/test hashes. A compile failure, skip or incomplete records is not the expected causal RED. Mutate one genuinely causal coefficient/Amount application only if a second targeted mechanism proof is needed; do not accumulate redundant tests.

## Compatibility and performance gates

No claim of bit-identical positive edited output is credible: removing the old log-cube interpolation changes some in-domain pixels, and correcting its projection intentionally changes signed/HDR output substantially. Preserve all untouched stages, saved parameters, defaults and exact neutral behavior. Archive old/candidate/direct-Core values, max and distribution errors at both old33/65 fidelities; identify affected operator/input domain explicitly. Do not approve a new broad error bound merely because candidate looks better on average.

The existing portable16-case characterization is decision evidence, not GPU certification. In it, ordinary positive error improved with cube size while signed/HDR projection error did not; this motivates scalar evaluation but does not validate a particular shader.

Measure completed changing-Amount work, including descriptor resolution, graph assembly and synchronous Float readback, against the identical fixture/test on the old source. Separate cold/first use from later frames, preserve native environment/provenance, and report ordered measurements without inventing a latency threshold or GUI/RAW acceptance. Existing renderer cache/plan-key/source-revision semantics must remain correct if the new descriptor is cached. Availability must be honest: adding a kernel to the full roster alone does not imply `coreAvailable` automatically selects CPU; choose/report a safe missing-kernel policy explicitly.

## Wheel boundary stays separate

Ordinary four-wheel plus advanced-grid grading requires a complete exact `GradeEngine` boundary, not the local tone kernel. A future `GradeEngine.exactStage` can carry actual private WheelTint results, resolved ZoneWindows, context matrices, lumScale/jointScale, grid parameters and appliedBrillianceScale. Existing CPU solvers remain authoritative; GPU ports only the actual per-pixel `GradeEngine.apply` and `ColorBalanceGrid.apply` operations, including stage-input tonal-axis measurement, OKLab offsets, LumenUCS/H-K brightness/chroma relations, grid coupling and finite fallback.

Existing ExactColorStage math utilities can be shared, but its Shadows Tint kernel has different EV weighting/axes and is not a grading substitute. No residual-domain extension, hand-selected wheel subset or Amount epsilon cutoff is justified as a general fix. Even after exact local tone is qualified, wheel/curve Amount continuity and saved-look compatibility remain open until independently addressed.
