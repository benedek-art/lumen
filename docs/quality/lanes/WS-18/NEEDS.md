# WS-18 / WS-17 needs from other lanes

1. **Mask lane (local Sharpness).** `RenderGraph.applyLocal` and
   `ReferenceRenderer`'s local stage call S12 through the old entry points
   (`RenderGraph.applySharpen(_:_:longEdge:)`, `DetailEngine.applySharpen(_:params:decomposition:)`),
   which now take the buffer as native (decode scale 1) because they have no scale to
   hand. Global S12 reads the decode scale (`options.noiseScale` on the GPU,
   `ReferenceRenderer.Inputs.decodeScale` on the CPU) so Radius is native sensor pixels.
   Local Sharpness should pass the same scale (`SharpenStage(_, decodeScale:)` /
   `applySharpen(_:params:decodeScale:)`); until it does, a masked Sharpness on a fit
   preview uses a radius `1/scale` times wider in sensor terms than on export.
   Negative local Sharpness still uses `frameDenominatedSigma`; that is the mask lane's
   call.
2. **WS-21/22 (denoise).** Nothing changed in their code. S4 now runs after S3, so
   Classic NR sees un-sharpened noise (it used to receive Apple's at-demosaic
   sharpening). `.ai`'s Apple stand-in still runs inside the decode, before S4.
3. **WS-58 (recipe reset).** No change needed. `detail.capture.radius` keeps its wire
   name; it is now read (native-pixel PSF σ, 0.4–2.0).
