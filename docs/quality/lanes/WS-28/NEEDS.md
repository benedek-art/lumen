# WS-28 needs from other lanes

## WS-01 (chain owner): four call lines, applied in this branch as isolated hunks

The lens stage has to sit in the chain to render at all, which is the defect the
inventory named. The lines are one-liners touching nothing else; WS-01 may move or
re-own them.

- `RenderGraph` gains `public var lensInputs: LensInputs = .none` (next to `healStrokes`).
- `RenderGraph.colorStageInput`: `image = applyLens(image, plan: plan)` right after S3
  (`applyDenoise`), before S5.
- `PipelineRenderer.makeGraph`: `graph.lensInputs = LensInputsCache.shared.inputs(url:
  sourceURL, decoded: decoded, context: context)`.
- `PipelineRenderer.renderReference`: `staged = LensStage.apply(...)` after S3, the
  graph's position.
- `lumen-render` (`Renderer.render`, `Renderer.prepare`): the same call, plus
  `--lens-raw`.

Open for WS-01: the eyedropper and mask-source stage inputs (`sampleMaskStageInput`,
`sampleColorStageInput`, `maskSourceImage`) build `RenderGraph()` without `lensInputs`,
so they see Defringe but not the CA warp or the Sony vignetting gain. The colour
difference is at most the vignetting gain in the corners of a Sony frame. Setting
`lensInputs` there the way `makeGraph` does closes it.

`LensInputsCache.forget(url)` should be called wherever `bandHues` is dropped for a URL
(file replaced on disk).

## WS-58 (registries)

- Append `("lensWarp", lensWarp), ("defringeLogLuma", defringeLogLuma),
  ("defringeWindow", defringeWindow), ("defringeApply", defringeApply)` to
  `KernelLibrary.unavailableKernels`. Until then a lens kernel that fails to compile
  drops the stage on the GPU path silently (the CPU path still applies it);
  `KernelLibrary.unavailableLensKernels` and `LensStageGPUParityTests.testTheLensKernelsCompile`
  report it meanwhile.
- `SliderEvidenceTests`: rows for `geometry.lens.removeCA` (toggle) and the six
  `geometry.lens.defringe.*` keys were appended in this branch, pointing at
  `LensStageTests` contracts. Re-own as you see fit.

## WS-17 (`AppleRawSource`)

Nothing to change in the decode. Facts for that lane, from the probe and run
39478505162: `isLensCorrectionEnabled` is supported and default-on for the A7 IV and
GX85, and toggles distortion; it does not correct the A7 IV's recorded vignetting
(this lane applies it after the decode, gated on the same `lens.profile` flag). If a
future macOS starts applying the Sony vignetting record at decode, the two would
stack: `LensProfileRawCorpusTestsProbe` logs the on/off ring ratio beside the record so
that change is visible in the RAW corpus lane.

## Linux toolchain (whoever owns `CompareView`)

`Sources/LumenApp/CompareView.swift:326` and `:569` end an argument list with a trailing
comma, which Swift 6.0.3 (the cloud Linux toolchain) rejects, so `swift build` / `swift
test` of the whole package fails on Linux at the base commit. This lane patched it
locally to run tests and did not commit the patch.
