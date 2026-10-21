# M8 (WS-53/54/55) — requests to other owners

Changes this lane needed outside its own functions, or made in someone else's function
with the minimum footprint and recorded here for acknowledgement.

## WS-01 (render chain)

1. **Acknowledge: one line in `ReferenceRenderer.render`.** S11's call now reads
   `applyMasks(image, plan: plan, alphas: alphas, space: space, noiseScale: inputs.noiseScale)`,
   and `ReferenceRenderer.Inputs` gained `noiseScale: Double = 1` (last init parameter,
   defaulted, so every existing call compiles unchanged). A mask's Noise rows obey S3's
   preview rule (`ClassicalDenoise.scaled(noiseScale:)`: identity at ≤ 0.5), so S11 needs
   the same scale S3 was given. The CLI (`Sources/LumenRender/CLI.swift`) passes it.
2. **Request: `PipelineRenderer.renderReference` should pass the scale too.** Today it
   applies S3 with `scale * scale` and then builds `ReferenceRenderer.Inputs(strokeSets:
   aiMattes:)` without it, so the CPU fallback runs local Noise at full strength on a
   preview where the GPU graph (`options.noiseScale`) skips it. One argument:
   ```swift
   inputs: ReferenceRenderer.Inputs(strokeSets: strokeSets,
                                    aiMattes: mattes[source.url]?.planes ?? [:],
                                    noiseScale: scale * scale))
   ```
   Not made here because that function is not this lane's.
3. **D3 (SPEC 12), not fixed.** Local presence (texture/clarity/dehaze/sharpness) runs at
   S11, after S9 colour and S10 grade; global presence runs at S8, before them. With
   vibrance 30, saturation 10 and a shadow grade, a full-frame local Dehaze ±100 differs
   from global by mean 3–4 codes, max 60; Clarity +100 max ≈ 30 (AUDIT D3). Tone-only
   edits: 0. The fix is moving the spatial half of the local set ahead of S9 (or running
   S9/S10 on the local result consistently), which reorders the chain on both renderers.

## T4 (S3, classical NR on the GPU)

4. **Acknowledge: `RenderGraph.applyDenoise` was split, no arithmetic changed.** Its body
   moved verbatim into `static func applyClassicalDenoise(_ image: CIImage, engine:
   ClassicalDenoise, noiseScale: Double) -> CIImage` (the `KernelLibrary.denoiseAvailable`
   guard moved with it); `applyDenoise` is now the identity guard plus a forward with
   `plan.classicalDenoise` and `options.noiseScale`. `applyDenoise`'s signature is
   unchanged, so `KernelGoldenTests` still calls it as before. Why: the mask's Noise rows
   must run the S3 kernels with a different engine (`LocalNoise.engine(for:plan:)`),
   and a copy of forty nodes would be two implementations to keep in parity.
5. **Request: negative local Noise.** Lightroom's mask Noise goes to −100 ("less NR
   here"). That needs, at S11, either the pre-S3 picture or the residual S3 removed, and
   nothing keeps either. This lane ships 0…100 only.
6. **Request (optional): a residual noise profile.** Local Noise thresholds against the
   sensor profile carried to S11 (`LocalNoise.profile`), not against what global NR left.
   Stacked on a strong global Luminance it therefore shrinks a little harder than "the
   same engine at a higher setting" would. A `ClassicalDenoise.residualProfile` (or
   equivalent) would let the local stage threshold against the noise actually present.
7. **Note:** `LocalNoiseAdjust` in `DenoiseEngine.swift` (additive `classicStrength`,
   `aiWeight`) is an unused design model; the shipped local Noise is `LocalNoise`. Delete
   or align at the owner's discretion (not edited here: DenoiseEngine.swift is T4's).

## S12 owner (`DetailEngine.applySharpen` / the S12 stage) + WS-01

8. **Lightroom-style negative Sharpness.** In Lightroom, local Sharpness 0…−50 fades the
   global sharpening inside the mask, −50 cancels it, −50…−100 blurs. Here S12 runs after
   S11 on the whole frame, so a masked −100 blur is partly re-sharpened by global Amount.
   Doing it properly needs S12 to read a per-pixel weight (1 − alpha·fade) built from the
   mask alphas, on both renderers; WS-01 for carrying the alphas past S11. This lane
   only removed the dead zone (√t radius, SPEC 3).

## WS-14 (global presence engines)

9. **D4 — Mask Amount > 100 plateaus differently per control.** Dehaze is flat 100→200
   (±100 clamp), Sharpness +100 flat above 150 and −100 flat above 100, Clarity nearly flat
   150→200 (α floor in `localLaplacian`), Texture keeps scaling to 2×
   (`DetailEngine.scaledPresenceAmount`). Monotonic everywhere, but inconsistent.
10. **D5 — Clarity +100 speckles grass** (global engine; local = global shows it).

## WS-58 (control index) and the UI layout inventory

11. `ControlIndex` lists no mask controls; if search should reach mask rows, add Noise /
    Colour Noise alongside the others.
12. **`Tests/LumenAppTests/LayoutMetricSupport.swift` needs two rows and six citations
    moved**, or `LayoutMetricSelfTests.testEveryCitationInTheInventoryLandsOnTheRowItNames`
    goes red on macOS. Generated with `scripts/recite-slider-inventory.py HEAD --write`
    plus the two new rows; patch at `/tmp/claude-0/m8/build/layout-inventory.patch`:
    ```
    SliderSpec("Noise", "MaskPanel.swift:2435", .developTop, 0...100, step: 1),
    SliderSpec("Colour Noise", "MaskPanel.swift:2439", .developTop, 0...100, step: 1),
    Sharpness 2429→2446, Temp 2944→2963 (×2), Tint 2956→2975 (×2),
    maskWheelBar "(MaskPanel.swift:3011)"→"(MaskPanel.swift:3030)"
    ```
    `callSiteCount` is unchanged (`adjustSlider` rows are not `LumenSlider(` sites).
13. `Tests/LumenPipelineTests/LocalSofteningScaleTests.testZeroIsIdentityAndThe…`
    sweeps Sharpness −50 at Amount 99…101 at 2048 px "through sigma 1". With the √t
    radius −50 sits at σ ≈ 1.41, so the sweep no longer crosses the 9-tap/CIGaussianBlur
    boundary (it still passes). Sharpness −25 puts it back on σ = 1.0 exactly.

## C3 (defringe), a global moiré engine, WS-40 (grain)

14. Local Defringe stays carried-not-rendered until C3's global defringe renders
    (`MaskDeadFieldTests.testTheGlobalEnginesTheBlockedTwoWaitOnAreStillAbsent` will say
    when). Local Moiré needs a global moiré engine, which nobody owns yet. Local Grain:
    WS-40 to decide whether it should exist at all (Lightroom masks have none) and to
    settle the stock/creative amplitude normalisation first.

## Finish-table precision (observed while measuring SPEC 5)

15. Local curve vs the same global curve differs only by the global curve's table error,
    and that error grows with curve steepness: a steep S (0.3→0.12, 0.7→0.9) reaches 12–13
    codes at lut 33 and 4–5 at 65 on all 7 photos; moderate curves stay ≤ 2 at 65 but
    reach 4–7 at 33 on a few. Byte-identical to the base commit; the local side is the
    exact one.
