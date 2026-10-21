# WS-45 needs (changes in functions other lanes own)

## N1 → WS-01 / WS-42: blend local adjustments in a perceptual domain, not scene-linear

`ReferenceRenderer` S11 (`base.mix(result, a)`) and `RG.compositeLocal` / `KR.blendMaskSource`
mix the adjusted and unadjusted pixel linearly in scene-linear light. A gradient's alpha is
symmetric, but the visible transition is not: on flat 0.18 grey the 50 % L* point of a
linear gradient (axis y 0.2→0.8) sits at y = 0.536 for −2 EV and y = 0.402 for +2 EV, i.e. at 0.561 and 0.337 of the span (0.5 nominal;
audit/AUDIT.md, auditor measurement through the full tone curve). So a brightening
gradient looks as if it is placed 16 % of its width toward the zero end, and a radial at
Feather 100, +2 EV, reaches half its visible effect at r = 0.665 instead of ~0.5.

Lightroom scales the slider values by the mask (Exposure × alpha in EV), which gives
0.538 / 0.462 of the span at ±2 EV in the alpha-only model (within 4 %; not measured through the tone curve). Suggested fix, owned by S11's owner: for the
exposure term at least, apply `gain^alpha` (EV-weighted) instead of `mix(base, base·gain,
alpha)`, CPU and GPU together. Spec line S13 is BLOCKED on this; nothing in the rasterizer
can correct it, because the right correction depends on the adjustment.

## N2 → whoever owns `Sources/LumenApp/CompareView.swift`

Lines 326 and 569 use a trailing comma before `)` in a call. Swift 6.0.3 (the Linux lane
toolchain) rejects it, so `swift test` cannot build on Linux at the base commit. Lane M3
patched it locally (not committed) to run LumenCoreTests.
