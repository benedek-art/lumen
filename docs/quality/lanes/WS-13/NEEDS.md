# WS-13 needs from other lanes

- **WS-05, `ToneEngine.defaultWhiteAnchorEV` 5 → about 3.0.** With the anchor at +5, sensor white (+2.47 EV) renders at code 221, so no real RAW reaches 255. An anchor of +3 gives 244 at mid 0.18 and 245 at mid 0.25, which matches ACR3 (254 at +2.375 EV). It also restores the shoulder room needed to lift display mid-grey to 0.25 (`DisplayTransform.displayMidGrey`) without dropping highlight-control proof floors (round-1 data: zones.bright 25.4 < 30, zones.pivot.3 20.7 < 26, zones.pivot.4 26.2 < 31, sharpen.haloSuppression 23.2 < 25).
- **WS-04/WS-17.** After a 0.25 mid, about 0.4 EV of the density gap to Adobe remains. That gap is decode baseline exposure, not the curve.
- **WS-12.** The 33³ interactive finish table misses the exact transform by up to about 4.6° of hue on 1840's dark sky (65³: ≤ 0.6°). An sRGB/P3 output gamut map is also needed before encode: colours far outside sRGB drift up to 7° from per-channel clipping (spec 3.4).
- **WS-38 (Film).** When the mid lift lands, FilmLab's solve target should follow `displayMidGrey`.
- **controls.md.** blackTarget range is 0…9 (engine, keys, UI now agree).
