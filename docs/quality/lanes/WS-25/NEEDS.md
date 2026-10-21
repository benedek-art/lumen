# WS-25 needs from other lanes

1. **WS-58 (kernel roster, `Kernels.swift`).** S16's three kernels live in
   `LumenPipeline/GeometryResampler.swift` (`GeometryKernels`), not on
   `KernelLibrary.unavailableKernels`. If one fails to compile, `applyGeometry` falls back to
   Core Image's bilinear transform (framing right, softer) without the preview's "Reduced"
   note. Ask: add `GeometryKernels.unavailable` to the roster, one append-only line.
2. **RenderCoordinator / preview owner.** `renderReference` now applies geometry (WS-01
   hunk, see REPORT). Two follow-ups in `RenderCoordinator.swift:~433`: the comment and the
   `note` string saying "crop, straighten and flip are not applied to this preview" are
   now false and should go; and the crop tool's `showingUncropped` should be passed through
   once `renderReference` grows a `skipCrop` parameter (WS-01 to add, one argument to
   `GeometryStage.apply`/`GeometryMap(skipCrop:)`, which already exists).
3. **WS-41 (vignette).** `RenderGraph.applyVignette` evaluates the ellipse in the
   straighten/flip frame and ignores Upright. With an Upright set, the vignette is centred
   on the pre-perspective frame, so it can sit off-centre on a strongly corrected picture.
   The map it needs is `GeometryMap.sourceToOutput` (projective, so a kernel row change,
   not an affine one).
4. **WS-23/24 (crop overlay).** The Guided tool is mounted in `LoupeView.cropCanvas` with a
   6-line hunk (`UprightGuideOverlayView`). Moving or deleting an individual guide (Lightroom
   lets you drag an endpoint) is not built; only add and Clear.
