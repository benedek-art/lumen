# Analytic local-tone candidate; qualification pending

Prepared from d55d685334d098effefe3ff6a329ab03845fbb36, production baseline equal84c8e15. This candidate is isolated on codex/local-tone-native-d55d685 until native compilation, strict equation/CPU tests, causal restoration and existing goldens have executed. It is not an accepted fix or a wheel/curve accuracy certification.

## Scope and arithmetic

The existing ToneEngine still resolves/sanitizes the five local tone controls, anchors and monotonicity coefficients. ExactLocalToneStage packs those resolved values and evaluates the existing scalar shelves/contrast analytically on current scene RGB luminance, with the existing -20EV safe-log floor. Original signed/HDR RGB is multiplied by exp2(stops). Exposure remains upstream; exact WB and colour remain downstream; hue/tint/grade post-tables and spatial/mask blending stay ordered as before. There is no RGB projection into LumenLog's bounded axis, epsilon cutoff, tolerance change or creative-default retune.

The renderer diff is confined to S11 applyLocalAdjust and LocalPlan:44 added/30 removed lines including comments. Exact unchanged-function checks confirmed applyDenoise, applyPresence, applyGrain, applyLocalCurves and applyLocalSoftening are byte-identical to84c8e15. No export stage, geometry or global-tone operator is changed. A complete line-level diff is preserved separately.

The original tone-only preLUT is lazily constructed only for a genuine missing/failed-kernel fallback (or explicit diagnostic access). The full kernel roster reports localTone availability; coreAvailable does not automatically choose CPU for this kernel. That fallback retains the historical bounded-domain limitation and is not covered by a claim of exact tone. Positive edited-tone pixels can intentionally change from the old interpolation approximation; saved-look byte identity is not claimed. Neutral/Amount0 exact identity remains required.

## Independent gates

ExactLocalToneBoundaryTests has six methods:
-224tone configurations:7individual/mixed cases ×2mask/group axes ×8Amount values(0,1e-8,.0001,1,25,50,100,200) ×2table sizes. Signed, all-negative,zero,tiny-positive,ordinary andHDR patches are compared to an independent scalar expansion of existing solved coefficients AND the unchanged Double reference, at the existing1e-3 bound. Tone-only33/65 results must be identical.
-80scalar-mask-alpha/order configurations, including exposure→tone→WB→exact-colour.
-Literal former contrast45/temp30/sat35/vibrance20 table fixture must now be cube-independent and agree with CPU.
-Nonopaque signed/HDR stored-RGB behavior with alpha0/.25/.75/1; this is not an assertion of unpremultiplied semantic equivalence.
-Exact neutral controls.
-12changing-Amount completed graph/readback timings on32×4generated input. Plan construction is excluded. These are not RAW/GUI/perceptual latency claims.

Checked Float destinations are NaN-initialized and awaited; unwritten/nonfinite data fails. The old table-size-plumbing test retains its numeric/authority thresholds but explicitly adds hue17, an operator that still actually uses a post-table. Its original now-exact fixture is retained separately above. No golden data is rewritten.

The dedicated workflow requires six actual passing methods/no skips and224/80/12 record counts, then restores the WHOLE84c8e15 RenderGraph with the same tests. Five active methods must execute with real assertion failure(s), while the separate neutral method stays green; compile errors/skips cannot qualify causal RED. It restores the exact candidate file and requires all six green again. Historical aggregate RED is not evidence that every individual method failed unless logs show it.

## Open gates

No candidate code has been executed in the disconnected cloud executor. Hosted macOS CI is the compiler/GPU gate. Strict wheel/grade Amount boundary remains independently unresolved and its assertion/tolerance is unchanged. General finite-domain cancellation, missing-kernel fallback, real-camera color calibration and subjective detail/denoise acceptance are not certified.

The local worker's generic OwnerPhotoFootprintContinuityTests.swift is integrated unchanged from da9e0e09a8729d0214a6cfabc4553ec10dc32bd8 (blob83988524e5a538d91d643054def340551143f742). Its private images, paths, logs and measurements are not imported. It remains opt-in and is not counted as executed by ordinary suites.
