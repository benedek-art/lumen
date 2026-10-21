# WS-32 / WS-33 needs from other lanes (lane K3)

## WS-34 (exact colour stage plumbing): a smoothed reference for the point pass

The one Point Colour spec line this lane cannot close inside its own functions is
speckle on un-denoised high-ISO frames (S7). The selection is evaluated per pixel in a
colour kernel, so chroma noise in the transition band flips pixels in and out of the
selection. Measured with a numpy model of the selection on 2062 (ISO 6400) with no NR,
the weight's noise across the transition band is 0.30 (base 0.32) and 22 pixels per
thousand flip by more than half against their 5×5 median. With the app's default classic
NR in front, flips drop to 0.1 per thousand on 2062 and 3 per thousand on 2348. That is
why the app mostly looks right, but it isn't a guarantee.

The seam already exists: `ExactColorStage.Pass.readsReference` and the point kernel's
second `__sample`. What is missing is the image that goes into it:

1. In `RG.applyColorStage` and the CPU twin (`ExactColorTwin.run` /
   `ExactColorStage.apply(to:)`, `ReferenceRenderer` line ~92), compute an edge-aware
   smoothed copy of the stage input (guided filter, radius ≈ 2 px at preview scale, guided
   by itself), once per frame, cached against the recipe prefix as docs/05 describes.
2. Hand that copy to every `point` pass as `ref`, always (not only when Variance is set).
3. Then K3/WS-32 moves the selection (`selectionWeights`, twin `point`, kernel
   `lumenColourPoint`) to read the reference's LCh and linear chroma, and applies the
   shifts to the pixel. Variance then gets its real neighbourhood mean as well, which
   `apply(_:localMean:)` was written for.

Parity: the GPU guided filter and the CPU one must agree to the existing
`gpu-parity.yml` gate. That's the reason this isn't done here.

## WS-58 (recipe schema): the three Range refinements

`PointColor` gained `hueRange`, `satRange` and `lumRange` (`Double?`, nil = 50 = follow
the master Range). They're optional and omitted when nil, so canonical JSON, fingerprints
and every stored sidecar are unchanged for unrefined swatches. Two follow-ups belong to
the schema lane:

- `XMPSidecar` / Lightroom import: Lightroom's `crs:PointColors` carries `HueRange`,
  `SatRange` and `LumRange` per swatch. They could map onto these fields if the import
  maps point colours at all.
- `ControlIndex` / search: the three new rows ("Hue range", "Sat range", "Lum range")
  may want index entries.

## Masks lane: local Point Colour panel

Mask swatches run the same engine, so the mixture selection and Variance change apply
to them automatically. The mask panel's Point Colour fold doesn't show the refinement
rows or the selection strip. `PointSelectionStrip(swatch:)` and the three
`LumenSlider`s can be reused as they are.

## docs/audit owner

`docs/audit/found-while-fixing.md` PROOF-03 (the three Primaries purity sliders spend
their positive half against a clamp) is fixed by WS-33. The entry should be marked fixed.
That file is outside this lane's folder.
