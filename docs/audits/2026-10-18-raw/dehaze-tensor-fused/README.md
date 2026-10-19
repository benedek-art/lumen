# Fused Dehaze central tensor candidate

Base `0e9e4a4`. This candidate changes only two production GPU source files. Existing Dehaze field/sky/global/local/group/tile tests and tolerances are unchanged.

The prior implementation produced two central-derivative images using 3x3 convolutions with +/-4 taps and then divided each by eight while packing the tensor. The new GENERAL CIKernel takes four +/-1-pixel samples from the existing exact log-EV plane and packs `gx*gx, gy*gy, gx*gy, 1`, where each derivative is half the opposite-sample difference. This removes two logical derivative image passes/transients. The existing box blur, eigenvalue magnitude, radii, sky formulas, field lifetime, airlight/transmission and all other stages remain unchanged.

Source/ROI review:

- Every tap is at destination coordinate plus a unit axis displacement, converted through `samplerTransform`. There are no hard-coded zero-origin coordinates or normalized-width assumptions.
- The source is the full log-EV plane clamped to its existing extent, so frame boundaries repeat the border pixel. The output extent remains the original finite image extent.
- `applyNeighbourhood` receives reach 1, expanding every requested source ROI by one pixel in both axes. Downstream box smoothing retains its existing separate neighbourhood requirements. Cropping a finished full-source graph preserves this dependency; independently rebuilding from cropped source is still outside this qualification.
- The tensor channel order remains Jxx, Jyy, Jxy, alpha 1. A simultaneous derivative sign reversal from convolution convention leaves this tensor invariant. The existing finite-sum oracle includes asymmetric structure and both gradient directions.
- The GENERAL kernel is compiled with `makeGeneral`, uses sampler rather than __sample, and is included in the required core-kernel availability roster. Failure therefore blocks the GPU route rather than silently pretending Dehaze succeeded.

Mathematical equivalence does not itself prove native arithmetic or performance. Multiplication/division by powers of two in the removed stencil is replaced with the equivalent half-difference. Apple/Core Image compilation, unchanged finite-sum fields and tiled/translated native tests must verify real implementation precision. No assertion or tolerance is loosened.

```sh
swift test -c release --filter DehazeSkyContractTests
swift test -c release --filter DehazeSkyFieldTests
```

Swift syntax parsing and patch whitespace checks passed in Linux. Native execution and paired completed-cost comparisons remain pending. No speed, GPU-memory, RAW, camera or visual-quality acceptance is claimed from logical pass reduction.
