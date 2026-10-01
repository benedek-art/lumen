# C1-healgpu: the GPU heal spot rewrote the whole picture

Stream agent C1-healgpu. Base: `origin/claude/jolly-sagan-k7ch7z` @ 1c6ac52. Build dir `/tmp/lumen-build-c1`.
Input: the first macOS run of `SpotRetouchGPUParityTests` (run 36831443096; excerpts in
`docs/audit-2026-10/ci/ci-SpotRetouchGPUParityTests.txt`), against F4-heal's a2181a7.

| Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|
| S5 on the GPU changed every pixel of the frame, and every spot case was 0.34–0.54 from the reference | FIXED (source-verified; the macOS lane is the check) | 82ec0cd | `SpotRetouchCoreImageModelTests` on Linux: with the kernel and graph changes substituted out, 32 failures, including the lane's exact count (63,358 pixels moved at 331×197) and all 15 of its error values. With the fix: 4/4 green. | none |

No proof record moves. Spots are new in a2181a7 and no proof record carries one. A recipe without spots never reaches `applySpot`.

## Root cause

**What was wrong.** `lumenSpotApply` returned the opaque input pixel, `vec4(base.rgb, base.a)`, at every pixel where the spot's alpha is 0. `RenderGraph.applySpot` then laid that output over the picture with `applied.composited(over: image)`. The kernel was applied with `CIKernel.apply(extent: box, roiCallback:arguments:)`.

For a general kernel, that `extent` is the domain of definition. It is a promise that the output is clear outside the extent. Core Image relies on the promise and does not enforce it. Core Image evaluated the kernel over the box plus a one-pixel margin and kept the result as a texture. That margin is outside the disc, so its pixels were opaque copies of the input. The source-over composite then read the texture clamp-to-edge across the whole frame. Every pixel of the photograph became the nearest pixel of the opaque margin.

**Evidence, from the lane log** (63,360 per-pixel failure lines, parsed):

- At 331×197 the box is x 112..<153, y 78..<119.
- Every moved pixel holds the input value of the nearest pixel of the rectangle x 111...153, y 77...119. That rectangle is the box grown by one pixel.
- GPU (0, 0) = (0.23477380, 0.31401575, 0.24684645). This is the input at (111, 77), recomputed from the fixture.
- (330, 0) is input (153, 77), (0, 196) is input (111, 119), and (330, 196) is input (153, 119).
- The value counts per row and column fit the same pattern. For example, each value on the right-hand strip appears 177 times, which is 331 − 154.
- The margin ring itself, and nothing else outside the box, equals the input. That gives 63,526 − 168 = 63,358 failures.

**A model that reproduces the lane exactly.** I wrote a Python and then a Swift model of that behaviour:

- The kernels are transliterated from `Kernels.swift`.
- They are evaluated over the extent plus one pixel.
- The result is read clamp-to-edge and composited source-over.

The model reproduces all 15 of the lane's "GPU is X from the reference" numbers. The 12 single-spot cases match to 1e-9; for example, 0.40102419257164 for heal at 256×256. The 3 two-spot cases match to 1e-5. It also reproduces the lane's 63,358 count exactly. Inside the spot, the model uses the kernel's own coordinate arithmetic and agrees with `SpotRetouch` to 1e-6.

**What was checked and found right** (traced by hand and confirmed by the model):

- The `h − y` flip between the reference's top-down pixels and Core Image's bottom-up frame, for both `destCoord()` and sample points. `CIImage(bitmapData:)` puts row 0 at the top.
- `samplerTransform` usage and texel centres at +0.5.
- `clampedToExtent()` matching `ImageBuffer.bilinear`'s clamped edge.
- The ROI callbacks: the destination and the offset source ±2 for the apply kernel, and both discs ±(r+2) for the rim.
- The rim lookup at `(k + 0.5, 0.5)`, and premultiplication (alpha 1 throughout).

The errors of 0.34 and above were all the smeared margin. They were not a coordinate error.

## Fix

Two guards. Each one alone is sufficient in the model, and the source carries both.

- `lumenSpotApply` returns `vec4(0.0)` wherever the spot's alpha is 0. The kernel is then clear outside its disc, which keeps the domain-of-definition promise. Premultiplied source-over is `S + D·(1 − Sa)`. With S = 0 that gives D exactly, so pixels no spot reaches are the input's own bytes. Where alpha is greater than 0 the output alpha is 1, so the result is S exactly.
- `RenderGraph.applySpot` composites `applied.cropped(to: box)`, so nothing Core Image might read outside the box can be opaque.

## Tests

**`Tests/LumenCoreTests/SpotRetouchCoreImageModelTests.swift`** (new, runs on Linux):

- `testTheModelReproducesTheMacOSLane`: the old shape gives all 15 lane values and the four corner pixels.
- `testEitherGuardAloneKeepsThePictureOutsideItsSpots`.
- `testTheShippedSpotGraphLeavesThePictureOutsideItsSpots`: reads both guards from the comment-stripped source, runs the model on all 5 cases at 3 sizes, and requires 0 moved untouched pixels and agreement to 1e-6.
- `testTheScanFindsTheGuards`: shows the scan is not vacuous.

With the fix reverted: 32 failures. With the fix: green.

**`Tests/LumenPipelineTests/SpotRetouchGPUParityTests.swift`** (macOS):

- New `testPixelsNoSpotReachesAreTheInputsOwnBytes`. It requires byte identity at every pixel where no spot's alpha reaches, including inside the box, for every case at every size. Failures are counted, so a regression reports once per case.
- The existing tests are unchanged. The 1e-3 parity tolerance is untouched.

## DECISIONS

None. This is a defect fix with no change in look. The 1e-3 tolerance stays as F4-heal set it. Once the lane is green, its measured worst error says whether it can be tightened.

## FOUND-WHILE-FIXING

- **The rule to watch for elsewhere:** a general kernel applied over an extent smaller than the frame, then composited, must be clear outside its effect. Every other general kernel in `Kernels.swift` covers the whole input extent. The watermark composite in `PipelineRenderer` composites a text generator, which is clear by construction. I found no other instance.
- **The model's margin is inferred, not documented.** "Evaluated over extent + 1 px, read clamp-to-edge" is inferred from the lane, which it reproduces exactly. It is not documented Core Image behaviour. The fix does not depend on the margin's size, because both guards hold for any margin.
- **`testTheGraphRetouchesBeforeTheLinearStage` passed on the broken lane**, because both of its sides went through the same broken stage. It is an ordering test and cannot see this class of bug. It is left as is.
