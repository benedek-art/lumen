# WS-19/20/21 needs from other owners

1. **A per-photo noise profile in `RenderPlan` (WS-01 prologue + WS-17 `AppleRawSource`).**
   S3's profile is `NoiseProfile.forISO(captureISO)`, one curve for every camera. After
   this lane's recalibration it reads 7 of 8 corpus bodies within ±30 %, but ISO alone
   cannot know the sensor: the full-frame A7C at ISO 2000 is read 1.53× too noisy (so it
   gets about 1.5× the smoothing it needs) while the Four Thirds GX850 at the same ISO is
   read 0.87×. Either pass the camera's sensor class / model into `RenderPlan` so a
   per-body table can apply, or run `NoiseProfile.estimate(from:)` once on a native-
   resolution crop at decode and cache it in the catalog (docs/07 §2.4 already describes
   this). The engine needs nothing else: `ClassicalDenoise(_:profile:)` takes any profile.
2. **Hot pixels in the CFA domain (WS-17).** The new pass handles demosaic smear, but a
   σ 0.5 px star on one red or blue photosite is indistinguishable from a hot pixel after
   demosaic. Before demosaic it is not (a star lights its neighbours' photosites). docs/07
   §2.5 v2.
3. **Registry rows (WS-58).** Two kernels appended to `KernelLibrary.unavailableKernels`
   as single-line hunks (`hotPixelFill`, `chromaEdgeMap`); `chromaMagnitude` is no longer
   called by S3 but stays compiled and listed (append-only roster).
4. **Pre-existing, not this lane:** `Sources/LumenApp/CompareView.swift:326,569` use
   trailing commas in call arguments (Swift 6.1). The Linux toolchain the lane brief
   installs (6.0.3) cannot build `LumenApp`, so `swift test` fails to build on the base
   commit. Tests in this lane were run with that file patched locally and not committed.
