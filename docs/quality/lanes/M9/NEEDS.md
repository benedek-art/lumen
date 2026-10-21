# M9 · needs from other lanes

1. **Linux build of the base is broken (owner of `CompareView.swift`).** Swift 6.0.3
   (the Linux toolchain `cloud-setup.sh` installs) rejects the trailing comma after the
   last argument at `Sources/LumenApp/CompareView.swift:326` and `:569`
   (`gestureInFlight: { state.sliderGestureActive },` followed by `)`), so `swift test`
   on Linux fails to compile on `claude/inspiring-dirac-ulgpch` itself. M9 removed the
   two commas locally to run its gates and did NOT commit that change.

2. **WS-47 / WS-48 / WS-50 (`MaskRaster` CPU loops).** The CPU definitions stay the
   path for exports of masks the GPU declines and for every CPU-only kind. They are
   scalar Double loops through `Plane`'s Double subscript: at 4096×2731 on the Linux
   container colour range is 1.2 s, luminosity 0.76 s, the identity refine chain 93 ms
   (three full-plane `map`s for steps that are no-ops). Short-circuiting an identity
   `refined` and an identity `levels` would take ~90 ms off every CPU settle bake.

3. **WS-50 (refine chain).** Edge shift (EDT) and Blur keep a mask on the CPU. Blur is
   separable and local and is the next one worth a GPU twin (a 2-pass kernel with
   explicit taps, not `CIGaussianBlur`, whose large-σ path is approximate and would not
   hold parity). The guided refine already has GPU kernels in RG (WS-07); a mask-side
   twin would make AI masks with Follow interactive.

4. **WS-44 / M2 (brush).** A brush bake at the settle rung still resumes on the CPU
   (BrushPlaneCache header: 709 ms per appended stroke at 4096 on the container). M9's
   synchronous-bake rule makes the first DRAFT frame after a stroke exact when the bake
   is under 8 ms; the settle after it is still a CPU paint at up to 4096.

5. **App lane (`AppState.refreshMaskOverlay`).** `renderMaskAlpha` now takes the GPU
   path for eligible masks; the overlay compositing (`MaskOverlay.composite`) is still a
   per-pixel CPU loop on the app side.

6. **Restore the range masks' GPU path (integrator, after M4 landed beside M9).**
   `MaskGPU.rangeKindsOnGPU` is `false` on the integration branch since 84698be. What
   failed: macOS CI on 421e8bb (the first state with both M4 and M9), jobs `test-fast`
   (CI run 39547798685) and `gpu-parity` (run 39547798747):
   `MaskRangeGPUParityTests.testRangeKernelsMatchTheReference` and
   `testRangeKernelsHoldInHalfFloat` — share of pixels past 1e-3 at 0.069–0.077 for every
   Brightness/channel band at Smooth 25 (worst 0.6875 alpha), 0.12 for the inverted
   component, inverted Levels and Levels with gamma (worst 1.0); and
   `MaskSpeedTests.testTheRangeAlphaOverTheRealStageIsTheCPUDefinition` at 0.283 past 2e-3
   against 1e-3. M9's own branch was green (266/0) because it never had M4's changes: it is
   a semantic conflict, not an M9 kernel bug. M4 (WS-47/48) changed the CPU definition the
   kernels twin:
   - `MaskRaster.lumaRangeValue`: the shoulders are now CENTRED on From/To
     (`half = min(s · lumaShoulderEV / evSpan, hi − lo) / 2`, smoothstep over
     `lo ± half` and `hi ± half`, open ends at 0 and 1), where the kernels still ramp
     from `lo − shoulder` to `lo`;
   - `MaskRaster.rangeMeasured`: the luminance/channel measurement is denoised before the
     band is taken — two guided passes at `rangeMeasurementRadius` (round(longEdge / 800)
     px, so ≥ 1 px from 400 px up) with ε from a per-0.5 EV-bin MAD noise estimate. That is
     SPATIAL, so no pointwise kernel can match it at any production size;
   - the colour range is shading-invariant (M4 REPORT C1–C12), likewise not yet in the
     colour kernel.
   The fix: port `lumaRangeValue`'s centred shoulders and the colour range's new distance
   to `KernelLibrary.maskLumaRange` / `maskColorRef`, and give the GPU path M4's
   measurement — the box/guided passes exist in `RenderGraph` already (`guidedFilter`),
   with ε needing the per-bin noise table, either measured on the GPU (a reduction) or
   computed once per settle on the proxy and handed in as a 46-entry 1-D image. Then flip
   `rangeKindsOnGPU` back on; the six skipped tests (four in MaskRangeGPUParityTests, two
   in MaskSpeedTests) are the acceptance gate, unchanged. Until then range masks are CPU
   rasters again (M4's picture, M9's settle cache and cheap-bake rule still apply), so the
   per-frame lag on a global drag with a range mask is back to the pre-M9 cost.
