# WS-47 needs from other lanes

## WS-42 (mask overlay): an on-image luminance map while a Brightness Range is selected

Lightroom's Luminance Range has "Show Luminance Map": the photograph drawn as its own
luminance in grey, with the selected band washed in the overlay colour. Lumen now has the
panel half of that (`LumaBandStrip` under From/To/Smooth: the band and its falloff on the
fixed −10…+4 EV axis), but the on-image half is an overlay mode, which is
`MaskOverlay.Mode` / `MaskRaster.composite` / `MaskOverlayView`, all WS-42's.

What it needs, concretely:
- a mode (or an automatic variant of `imageOnBW`) that, when the active component is
  `.lumaRange`, draws the picture as grey = the band's measured channel mapped from the
  −10…+4 EV axis to 0…1 (the same normalization `MaskRaster.lumaRangePlane` uses, so the
  grey a pixel shows is where it sits on the strip), with the selection on top;
- the measurement should be the denoised one the mask thresholds
  (`MaskRaster.rangeMeasured`), so the map shows what the band actually sees.

Nothing in WS-47 blocks on this; the band renders correctly without it.
