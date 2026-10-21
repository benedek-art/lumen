# T2 tone curves: acceptance spec (WS-11 parametric, WS-12b point / RGB / luma / Preserve Luminance)

Written from the audit of baseline 9068ded. Codes are 8-bit sRGB codes. `$A` is `docs/quality/lanes/WS-12b/scripts/` (the auditor's exact Python ports and
measurements; run them from a scratch folder, `lr.sh` renders their inputs). "cube 33" is
the interactive finish table, "cube 65" the export one.

## Measurable

| # | claim | threshold | measured by |
|---|---|---|---|
| S1 | The default curve is an exact identity, and so are explicit identity point/luma/R/G/B lists | 0 differing pixels on colorchecker, skin_tones, hue_wheel at cube 33 and 65 | `lumen-render render` default vs explicit identity, byte compare |
| S2 | The point curve never overshoots its control points | max overshoot ≤ 1e-12 over 3000 random point sets (half non-monotone) | `$A/m2_overshoot.py` (exact port of `MonotoneCubic`) |
| S3 | The curve as its own stage (`CurveStage`) equals the exact curve | ≤ 0.25 code max on S, steep, dip, lift, parametric, per-channel and all-curves sets, neutral ramp + 4000 random colours, SDR and white 2.5; ≤ 0.5 on the editor's steepest possible cliff | `swift test --filter CurveStageTests` |
| S4 | The RENDERED curve equals the drawn curve on grey_ramp at the preview size | p99 ≤ 1, max ≤ 2 codes, cube 33 and 65, for the S3 sets | `$A/m1_drawn_vs_applied.py` |
| S5 | Preview and export are the same picture | steep curve on 1840 (D850 sky): max ≤ 2 codes cube 33 vs 65; sky OKLab hue within 2° of the exact curve | `$A/m3_sky.py` |
| S6 | No banding from steep curves | 0 empty histogram bins between p1 and p99 in sky crops (dither on and off); no slope corner in the ramp output that the drawn curve does not have | `$A/m3_ramp_banding.py`, `$A/m3_sky.py` |
| S7 | Preserve Luminance ON keeps hue on a contrast curve | S-curve: colorchecker \|ΔH\| ≤ 1.5° max, hue wheel ≤ 1.5° p95 (cube 65) | `$A/m4_preserve.py` |
| S8 | RGB curves are per-channel and exact at identity | identity: S1; R lift moves R only on the encoded axis | `$A/m5_rgb.py` |
| S9 | Parametric: monotone, live, isolated | min slope > 0 at every setting; no two adjacent integer settings render the same curve; Highlights ±100 moves zones 0–4 by < 1 code and Shadows ±100 zones 5–9 by < 1 code | `$A/m6_param.py`, sweeps in `$A/sw/` |
| S10 | Parametric splits: the engine uses the bounds the editor draws | `regionCentres(raw) == regionCentres(sanitizedSplits(raw))` for out-of-range splits | `swift test --filter CurveStageTests/testTheEngineReadsSplits` |
| S11 | The histogram behind the curve is the curve's INPUT, on the tab's own channel | on 6929 (A7 IV) with the S-curve, EMD between the backdrop and the true pre-curve luma ≤ 0.01 (was 0.067); and the backdrop does not move when the curve changes | `swift test --filter CurveGestureBackdropTests`, `$A/m8_histogram.py` with the pulled-back backdrop |
| S12 | A click on empty graph adds a point on the curve and does not move the curve at the click; a click beside a point never yanks it | 0 change at the click x; ≤ 3 codes elsewhere (spline re-solve); existing point unchanged | `swift test --filter CurveGestureBackdropTests` |
| S13 | Drags move by the pointer's displacement; ⌥ is 1/10 fine adjust; toggling ⌥ mid-drag never jumps | exact to 1e-12 | `swift test --filter CurveGestureBackdropTests` |
| S14 | Delete by double-click, ⌥-click (no travel > 2 pt), context menu, drag out; anchors are never deleted | call-site scans + existing anchor tests | `swift test --filter "CurveMathTests|CurveGestureBackdropTests"` |
| S15 | The press target is larger than the drawn point | hit radius 10 pt vs dot radius 4 (5.5 lit) | `CurveMathTests.testTheDrawnPointStaysSmaller…` |

## Visual (judged from the macOS snapshot set)

- V1 `panel-develop-curve-point.png`: the histogram sits behind the S-curve, points are
  clearly visible and the lit one is distinguishable, quarter and eighth grid readable.
- V2 `panel-develop-curve-red.png`: you can tell at a glance that the red channel is
  active (red trace, red backdrop, red frame, red label) and the green curve shows faint.
- V3 `panel-develop-curve-param-values.png` vs the baseline `panel-develop-curve.png`:
  the regions, the splits and the parametric values read as before.

## Decisions

- Non-monotone point curves stay allowed (Lightroom allows them; a dip is a creative tool).
  What is forbidden is overshoot between points, and inversion from the parametric sliders.
- Preserve Luminance keeps D10's meaning: curve the luminance and keep saturation (chroma
  scales with lightness). A brightening curve's hue turn comes from the sRGB clamp after
  the curve, not from the curve (audit finding 5: the scaled values stay inside Rec.2020).
  That clamp is outside this lane (NEEDS.md).
