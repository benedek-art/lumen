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
