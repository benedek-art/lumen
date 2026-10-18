# Source-only scope of positive Amount LUT activation

Reviewed against production at `2b96ec49171132b7c0b1023ae01466b79afb096e`, byte-identical to B752/c7. This table classifies the mechanism under **isolated controls**, with all other local adjustments neutral. It does not report executed native cases beyond the separately recorded wheel diagnostic. Mixed controls can activate a table even when a row below does not.

| Local control | Route | Same domain-activation risk predicted from source |
|---|---|---|
| Contrast, Highlights, Shadows, Whites, Blacks | Pre-LUT | Yes when the scaled tone engine is nonidentity |
| Relative Temp/Tint | Pre-LUT | Yes while a scaled shift remains nonzero |
| Absolute Kelvin and optional Tint | Pre-LUT | Yes for nonzero Amount; the resolved balance reports nonidentity even when its matrix is identity |
| Hue | Post-LUT | Yes when scaled hue is nonzero |
| Colour Tint | Post-LUT | Yes with a tint and positive scaled tint strength; a tint object with zero strength alone does not require a table |
| Wheels/advanced grid | Post-LUT | Yes; the original nonneutral wheel makes a grade object present even if scaled grading becomes numerically identity |
| Saturation, Vibrance, Point Colour | Exact colour stage | No activation of this cube when isolated; this is not a certification of all other colour selectivity or continuity |
| Exposure | Direct gain matrix | No activation of this cube when isolated; included as an executed-control question in the native diagnostic |
| Texture, Clarity, Dehaze, Sharpness | Separate spatial paths | No activation of this cube when isolated; independent spatial nonlinearities and the recorded Dehaze disagreement remain separate |
| Local point curve | Separate S15b LUT | Analogous risk for a nonidentity stored curve and positive Amount; incoming domain is the display-linear/white-scaled picture, not the S11 scene input |

Trace: `Sources/LumenPipeline/RenderGraph.swift` `applyLocalAdjust`, `LocalPlan`, `applyLocal`, `applyLocalCurves`, `LocalCurvePlan`; `Sources/LumenCore/Engine/ReferenceRenderer.swift` direct local adjustment and `LocalWhiteBalance`; `Sources/LumenCore/Engine/ToneEngine.swift` strict identity predicates; `Sources/LumenCore/Engine/CurveStack.swift` `LocalCurve`; `Sources/LumenCore/Color/LUT.swift` and pipeline `cubeLookup`.

The table sampler clamps encoded input coordinates to [0,1]. The shaper endpoints are approximately −0.000004937137456 and 737.28 in the input units of the respective stage. At zero Amount, existing bypasses preserve input. At positive Amount, parameters scale before table baking, but normal compositing uses selection alpha alone. A table's input-domain projection therefore need not fade with Amount. Finite interpolation can also produce an in-domain floor; the independent endpoint oracle deliberately avoids treating an identity cube as exact throughout its interior.

For the local point curve, the CPU correctly mixes curve displacement by Amount and has a zero identity guard. The GPU still samples that operation through a bounded cube first. This is a **source-predicted analogous risk**, not an executed curve result or evidence that its units match S11.

Exact-zero predicates and floating-point underflow matter: scaled tone, hue or relative WB can eventually become identity; absolute Kelvin and the original-wheel presence predicate can remain active despite numerically identity math. This review found no approximate epsilon cutoff to guarantee continuity. It did not exercise every cross-control combination, blend mode, gamut, camera, export or GUI event.

Potential remedies—analytic evaluation, extending/extrapolating table domains, changing final strength blending or introducing versioned behavior—can change positive saved looks. No such change was made. The owner-facing priority is to retain the measured unresolved gate, establish its practical range and make a separate compatibility decision.

Follow-up candidate: absolute local WB now propagates the adaptation engine's exact identity flag. This removes a table only when the existing engine itself reports exact neutrality; nonneutral matrices/interpolation are unchanged. Native qualification is separately tracked. It does not resolve the other activation rows or fractional Kelvin reciprocal effects.
