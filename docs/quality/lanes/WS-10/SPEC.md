# WS-10 Match Total Exposures: acceptance spec

Owned: `AppStateMatchExposure.swift`, `Engine/ExposureMatch.swift`. Shared tooling added:
`lumen-render match` (new file `Sources/LumenRender/MatchCommand.swift`, one dispatch line).

Audit finding that shapes the spec: on the corpus pair the EXIF says 6933 (1/80, f/5.6, ISO 640)
was captured 0.68 EV brighter than 6929 (1/50, f/5.6, ISO 250). Registered at full resolution
(6933's footprint located in 6929 by normalized cross-correlation, NCC 0.90) the pixels are
0.39 EV brighter. Lightroom's EXIF-only rule therefore leaves the pair 0.30 EV apart the other way.

```
B=.build/x86_64-unknown-linux-gnu/release/lumen-render
$B match --input corpus/lfi/6929_sony-ilce-7m4.lfi --input corpus/lfi/6933_sony-ilce-7m4.lfi \
  --shutter 1/50 --aperture 5.6 --iso-exif 250 --shutter 1/80 --aperture 5.6 --iso-exif 640 \
  --as-shot-kelvin 4987 --as-shot-tint 21.1 --as-shot-kelvin 4987 --as-shot-tint 21.1
python3 docs/quality/lanes/WS-10/tools/pair_residual.py <matched exposure for 6933>
```

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| M1 | The pair is equalised: residual on the registered overlap after Match | \|median\| and \|log-mean\| residual <= 0.10 EV | pair_residual.py |
| M2 | The measured overlap finds the pair | NCC >= 0.9 at proxy scale; measured offset within 0.05 EV of the full-resolution registration | `lumen-render match` vs pair_residual.py `residualBeforeLogMeanEV` |
| M3 | Frames that share no view fall back to EXIF (Lightroom's rule) | `measureOverlap` returns nil below NCC 0.75; plan uses EXIF | `ExposureMatchMeasuredTests.testFramesThatShareNoViewAreNotMeasured`, `testAMeasuredFrameIsMatchedOnItsMeasurementNotItsEXIF` |
| M4 | Crop and re-aim do not fool it | synthetic 1.5x crop, off-centre, +0.39 EV: measured within 0.05 EV, both directions | `ExposureMatchMeasuredTests.testOverlapMeasuresACroppedReaimedFrame` |
| M5 | Every existing EXIF contract still holds (rounding, clamping, skipping, summaries) | existing `ExposureMatchTests` unchanged and passing | `swift test --filter ExposureMatch` |
| M6 | One undo step, status line says what basis was used | summary ends "by measured brightness" when measured | `testAMeasuredFrameIsMatchedOnItsMeasurementNotItsEXIF` |

Visual claim: `evidence/match_6929_6933_exif_vs_measured.png`, the measured-match 6933 tile and the
6929 tile (same view) read as the same exposure; the EXIF-match tile is visibly darker.
