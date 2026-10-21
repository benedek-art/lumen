# WS-44 needs from other lanes

1. **LoupeView, the `MaskCanvas(...)` call (~line 2036): pass `picture: cg`.** One
   argument. `MaskCanvas` now draws the stroke being painted as its real coverage
   (`BrushLivePreview`), and with Auto Mask on it needs the displayed preview to show where
   the cut falls while painting. Without it the live stroke shows the uncut brush and the
   cut appears when the render lands. Default is nil, so nothing breaks before this lands.

2. **MaskRasterCache / PipelineRenderer mask bake (WS-43 or the pipeline owner): the draft
   frame after a mouse-up serves the stale mask raster.** Auditor finding (AUDIT.md,
   latency section): nothing calls `MaskRasterCache.hasPendingBake`, so the first frame
   after a stroke commits shows the mask without it and the stroke appears at settle. The
   live stroke now lingers 0.7 s and fades, which hides most of this, but the effect itself
   (exposure etc.) still arrives one settle late.
