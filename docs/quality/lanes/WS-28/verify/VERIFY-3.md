# WS-28 lens corrections: verification round 3 (final)

Verifier: fresh agent. Branch `quality/c3-lens` at 6458d84. Linux, CPU only.

What I worked from:
- LANE-BRIEF §1 and §4, SPEC.md, AUDIT.md §6, REPORT.md, VERIFY-1.md and VERIFY-2.md.
- The diff `9bda872..HEAD -- Sources Tests`.

Build and test state:
- Release `lumen-render` and the debug test bundle were rebuilt from HEAD.
- Nothing under `Sources/` or `Tests/` was edited, and `git status` is clean.

All renders:
- Command: `render --long-edge 0 --no-dither`, with K/T/ISO taken from the sidecar. "off" and "on" both set `profile=false`.
- Baselines are round 1's `/tmp/claude-0/verify/r/*_caoff.png`.
- Fresh "on" renders are in `/tmp/claude-0/verify/r3/`. They are byte-identical to the builder's `/tmp/claude-0/r2/*_caon.png` for all six photos, so the builder's numbers reproduce exactly.

## VERDICT: FAIL

Round 2's defect D-A (the app and the CLI ranking tiles differently) is **fixed**. The CLI and the app now share one measurement path, and the models agree within 0.03 px on all six photos.

Three corpus lines fail on that shared path:
- **2.6:** 3437 overcorrects blue to **+0.114 px** in r 0.8–1.0 (seed 99: +0.124). The limit is 0.1.
- **2.7:** 6001's blue in r 0.8–1.0 goes from +0.071 to **−0.203 px**, which is 0.132 px worse. The limit is 0.05.
- **2.8:** 6001 is no longer bit-identical, because it now gets a model.

The 3.5 count clause still fails. It is now reported in REPORT.md, and the argument given there holds.

REPORT.md does **not** state the 2.6, 2.7 or 2.8 failures. Its §2 table still shows round-2 numbers: 3437 at +0.073 "PASS", and 6001 as "no model: bit-identical, PASS". §2 also says "the CLI measures on its input at full size". At HEAD all three statements are false.

This is the third FAIL. Per the brief, what is left goes into the report as BLOCKED.

## Spec lines (measured this round)

| # | Measured | Result |
|---|---|---|
| 1.1 | `/tmp/claude-0/ci/raw2.txt`: 33 `lens-probe:` lines, including 4 for 6929 and 4 for 2545. | PASS |
| 1.2 | REPORT §1 per-camera table is unchanged and still correct. | PASS |
| 2.1 | `testEstimatorRecoversConstantMagnification`, `…Cubic…`, and the new `testPreviewRankedNativeTileEstimate` pass. | PASS |
| 2.2 | `testCorrectionLeavesUnderAFifthOfATenthOfAPixel` passes (106 s). | PASS |
| 2.3 | `testCAFreeFrameIsAnExactIdentity` passes. | PASS |
| 2.4 | `testRemoveCAOffIsIdentity` passes. | PASS |
| 2.5 | `testColourEdgesDoNotInventCA` and the new `testSignMixedChannelIsLeftAlone` pass. | PASS |
| 2.6 1840 | 0.6–0.8: R +0.490→+0.046 (−91 %), B −0.177→−0.056. 0.8–1.0: R +0.520→−0.038 (−93 %), B −0.103→+0.045. | PASS |
| 2.6 4213 | 0.6–0.8: R −0.228→+0.021 (−91 %), B −0.155→+0.056. 0.8–1.0: R −0.275→+0.012 (−96 %), B −0.187→+0.053. | PASS |
| 2.6 2545 | 0.6–0.8: R +0.217→−0.037 (−83 %), B −0.038→−0.050. 0.8–1.0: R +0.224→**−0.062** (−72 %), B −0.015→−0.033. | PASS. Regressed from round 2's −0.022 but inside the limits. |
| 2.6 3437 | 0.6–0.8: B −0.511→−0.024 (−95 %). 0.8–1.0: B −0.576→**+0.114** (seed 99: −0.584→+0.124). R has no model: −0.039→−0.044. | **FAIL** (overcorrection > 0.1) |
| 2.7 6929 | No model; on and off are byte-identical (`cmp`). | PASS |
| 2.7 6001 | B 0.8–1.0: +0.071→**−0.203** (+0.132 worse). Every other zone improves: R 0.8–1.0 +0.326→+0.096, B 0.3–0.6 +0.197→−0.021, B 0.6–0.8 +0.247→+0.018. Seed 99 is identical. | **FAIL** |
| 2.8 | 6929 is bit-identical. 6001 gets a model (R +0.48 / B +0.54 px at the corner) and is not bit-identical. | **FAIL** (6001) |
| 3.1–3.4 | Unit tests pass, including the new `testDefringeHueMinimumSpan`. | PASS |
| 3.5 ΔE | 1840 at P5/G5 against Remove CA on, whole frame: mean ΔE2000 **0.0386**, p99 1.32, 3.5 % of pixels changed. 4213 was 0.0001 in round 2; the Defringe code is unchanged. | PASS |
| 3.5 count | 1840, zone 0.8–1.0, purple+green per 1000 @0.03: 5.4→3.8 (**−30 %**). Inner zones *rise* (0–0.3: 0.8→4.6). The counts are about 15 edges out of 2,700. | **FAIL**, stated in REPORT |
| 4.1–4.3 | Unit tests pass. | PASS |
| 4.4 | A fresh `6929_vigon` is byte-identical to round 2's. My ring measure gives **+0.458 EV**. | PASS (low edge of 0.45–0.70) |
| 5.1, 5.2 | Not runnable here. CI passed on a939139 (gpu-parity, ui-layout, ui-snapshots, build-macos, test-fast, app-bundle, engine-linux). The `a939139..HEAD` source diff touches no kernel: it changes the CPU estimator, the CLI, and the macOS-only `LensInputsCache`. So the parity result stands. **The new `LensInputsCache` code has not been through a macOS compiler at HEAD.** By reading it, it is well typed. | PASS on a939139; HEAD macOS build unconfirmed |
| fixtures-linux | `check-swift-surface.py` at HEAD finds the same issues as the lane base 84bcd7c and as origin 9068ded (1 symbol, 6 inits, 5 labels, 1 target). Only the counts differ. Both exit 1. | Same as base |
| 6.1 | Own crop, 1840 top-right (r ≈ 0.85), `r3/crops/1840_TR.png`: cyan/red branch rims visible off, gone on, no halo, no softening. | PASS |
| 6.2 | 4213 model is within 0.01–0.02 px of round 2's; that sheet still applies. | PASS |
| 6.3, 6.4 | Defringe and vignette code are unchanged. | PASS (round 2 stands) |

Other Linux tests run:
- `LensStageTests`: 18/18 pass in 280 s (`r3/lenstests.log`).
- `SettingsSubset` 14, `ResetSemantics` 19, `SliderEvidence` 7 and `RecipeCodecTolerance` 10: all pass.
- I did not re-run the whole bundle. The last full run, on 9bda872, gave 3073 passed and 0 failed.

## Path parity (round-2 D-A): fixed

**From reading the code** (`CLI.swift` `lensInputs` against `RenderGraph+Lens.swift` `LensInputsCache.measure`):
- Both call `estimate(nativeWidth:nativeHeight:preview:fetch:)`.
- Both use a 2048 px long-edge ranking preview.
- Both fetch tiles at native pixels in top-left frame coordinates:
  - The CLI copies rows directly.
  - The app converts to Core Image's bottom-left origin with `(x, H−y−h, w, h)`, which is correct.
- Both have the same bounds guard.

**Remaining differences:**
1. Preview resampling. The CLI uses an area average (`InputImage.downsample`, rounded size). The app uses Core Image `transformed(by:)`, which is bilinear with no prefilter, and `integral` adds a partial row.
2. The input. The app measures Apple's decode with `Recipe()`; the CLI measures the LibRaw LFI. This cannot be tested on Linux.

**Measured.** I compiled a standalone program against the release LumenCore objects (`r3/emu/main.swift`, output in `emu1.txt`). Its CLI mode reproduces the render logs exactly.

Corner shift in px at r = 1:

| photo | CLI area preview | app-style bilinear preview |
|---|---|---|
| 3437 | B −1.472 | B −1.444 |
| 6001 | R +0.483, B +0.538 | R +0.480, B +0.539 |
| 2545 | R +0.350, B none | R +0.353, B none |
| 1840 | R +0.624, B −0.295 | R +0.609, B −0.274 |
| 4213 | R −0.335, B −0.391 | R −0.336, B −0.401 |
| 6929 | none | none |

Every gate decision is the same. So the CLI now verifies what the app does, and therefore **the 2.6, 2.7 and 2.8 failures above are also what the app does.**

## Break attempts

| Attempt | Result |
|---|---|
| 3437 rotated 90° (`r3/lfi/3437_rot90.lfi`) | Model B −1.45 px at the corner (unrotated −1.47): estimation is now orientation-stable for 3437. Rendered 0.8–1.0 B −0.582→+0.076 (inside the limit), against +0.114 unrotated. Same lens, ±0.04 px apart, on either side of the 0.1 limit. |
| 6001 rotated 90° | **Blue model disappears** (R only, +0.39 px at the corner). Rendered: B unchanged in every zone, R 0.8–1.0 +0.326→+0.145. This orientation would pass 2.7. The blue decision on 6001 depends on orientation. |
| 3437 centred 80 % crop (same optical centre, same pixels) | Model B −0.50 px at the crop corner. The full-frame model at the same physical radius is −1.00 px. Band medians at the same physical radius: crop −0.35/−0.38, full frame **−1.14/−1.13** (`r3/emu/bands.txt`). Rendered on the crop: 0.8–1.0 B −0.500→−0.269 (−46 %), 0.6–0.8 −0.378→−0.215 (−43 %). That would fail 2.6's 60 % rule. **The same pixels get half the correction when the frame's edges move.** |
| Split-half gate, inspected | Halves are a checkerboard of neighbouring 48 px tiles, so both halves see the same objects. Per-band blue medians of the two halves agree within 0.01–0.25 px on 3437 and 6001 (`bands.txt`). The gate catches tile-sampling noise but cannot catch content-driven bias. It removed neither failure. No unit test exercises a disagreement or the shrink. |
| 6001 band medians against the auditor tool | The estimator reads B **+0.68 px** in band 0.8–0.9. The tool reads +0.071 in zone 0.8–1.0. The estimator is measuring something other than what the tool sees: the frame's purple and magenta flowers and bokeh are the likely source. |

## Own 100 % crops: would a photographer see harm?

All crops are 2× nearest neighbour. Top row is the image; bottom row is OKLab chroma ×4. Off on the left, on on the right. Files are in `/tmp/claude-0/verify/r3/crops/`.
- **`6001_BL.png`** (r ≈ 0.77, green stems against dark, purple flower, gain ×3), **`6001_BR.png`** (r ≈ 0.78, bark and a bright label) and **`6001_TL.png`** (r ≈ 0.93, defocused tree against sky): no difference visible in the image, and the chroma view is barely distinguishable. The −0.2 px blue overshoot on 6001 is a metric failure, **not visible harm**. That corner is defocused or dark wherever the tool sees edges.
- **`3437_TL.png` and `3437_TR.png`** (r ≈ 0.88, branches against sky, highlights through leaves): no new halo or softening in the image. The chroma view shows the rim pattern rearranged, with no clear gain or loss. The +0.114 px overcorrection is **not visible** on this soft frame.
- **`1840_TR.png`**: a clear improvement.

## Defects, ranked

### D1 (high, REPORT honesty): REPORT.md does not state the failing lines and keeps stale passes

What REPORT says at HEAD:
- §2 table: 3437 B 0.8–1.0 "+0.073 PASS". Actual: +0.114.
- §2 table: 6001 "no model: bit-identical, PASS (2.7)". Actual: −0.203 B and a model.
- §2 text: "The CLI measures on its input at full size". It now uses the 2048 preview ranking.
- "For the owner": "cuts corner colour misregistration by 88–96 %". Actual: 72–96 %, with 3437 overshooting.
- `VERIFY2_PLACEHOLDER` and the §5 placeholders remain.

The 1840 and 2545 rows are also stale; they hold round-2 values.

Only 3.5 is reported as FAIL. The builder's own `/tmp/claude-0/r2/*_cmp.txt` shows both the 2.6 and 2.7 failures, so the report does not reflect what the builder measured.

**Plain bug (documentation).**

### D2 (high): 2.6 on 3437, blue overcorrected to +0.114 px in r 0.8–1.0

- The estimator's full-frame band medians for r 0.6–0.8 are about −1.14 px.
- The same pixels read −0.35 px in a centred crop, and the tool reads −0.51.
- So the model (−1.47 px at the corner) is driven by which content falls in which band, not by the lens.
- Round 2 ranking gave +0.073, this round +0.114, rotated +0.076, seed 99 +0.124.

**Recommendation: BLOCKED.** This is the variance and bias of a content-measured estimator with no lens profile. It is not a coding slip. A damping factor would pass 3437 but is unvalidated elsewhere, and the third round is spent.

Evidence: `r3/3437_cmp.txt`, `3437_s99.txt`, `3437rot_cmp.txt`, `3437crop_cmp.txt`, `emu/bands.txt`.

### D3 (high): 2.7 and 2.8 on 6001, a model where the spec expects none, and blue corner 0.132 px worse

- The CLI's switch to preview ranking (needed to fix D-A) made the CLI inherit the model the app path already produced in round 2.
- The split-half gate keeps it, because both halves see the same flowers.
- The spec's premise does not hold for this frame. The auditor tool reads real red CA of +0.326 px in the corner zone, which is ≥ 0.2, the size that 2.6 would *require* to be corrected. The red correction is a genuine improvement (+0.326→+0.096).
- The blue failure has the same root as D2: the estimator reads B +0.68 px in band 0.8–0.9 where the tool reads +0.07.
- Orientation flips the blue decision: rotated, 6001 passes.

**Recommendation: BLOCKED.**
- 2.8 is a spec-premise conflict. A Remove CA that corrects 6001's real red CA cannot be bit-identical. The spec owner should move 6001's red channel under 2.6.
- 2.7's blue part is the D2 estimator limitation.

There is no visible harm at 100 %.

Evidence: `r3/6001_cmp.txt`, `6001_s99.txt`, `6001rot_cmp.txt`, `crops/6001_*.png`.

### D4 (medium): 3.5 count clause, about 30 % against ≥ 50 %

- The builder's argument checks out against the tool's documented method (steps 4 and 6). The fringe "excess" is measured − predicted, where the prediction is interpolated from the edge's two flat sides. A pixel desaturated beside green foliage departs from that prediction toward magenta and is still counted as purple.
- That fits my data: the counts *rose* in the inner zones when Defringe was applied, while ΔE stayed at 0.0386.
- The sample is also tiny, about 15 corner edges.

**Recommendation: BLOCKED** (metric defect; the spec owner decides).

Evidence: `r3/1840_dfr.txt`.

### D5 (medium): the split-half stability gate is weaker than REPORT and the commit message imply, and is untested

- Neighbouring interleaved tiles are not independent samples of the lens, so the gate cannot catch the failure class it was written for (content-driven models).
- There is no unit test with halves that disagree, and none for the "shrink to weaker half" step.

**Plain gap.**

### D6 (low): new `LensInputsCache` code not compiled at HEAD

`RenderGraph+Lens.swift` is macOS-only, and macOS CI last ran on a939139. By reading, it is correct.

**Unbounded `vignettes` entries:** a URL rendered only below 1200 px adds an entry to `vignettes` but never to `order`, so it is never evicted. The leak is tiny. **Plain bug, low.**

### D7 (low): 2545 and 1840 red now overshoot slightly more than in round 2

- 2545 r 0.8–1.0: −0.022 → −0.062.
- 1840 r 0.8–1.0: −0.009 → −0.038.

Both are inside the limits. This is the same estimator drift as D2. Info.

## Files

- Renders: `/tmp/claude-0/verify/r3/<id>_caon.png` and `.log`; `3437rot_*`, `3437crop_*`, `6001rot_*`, `6929_vigon`, `1840_p5g5`.
- Metrics: `/tmp/claude-0/verify/r3/<id>_cmp.txt` and `.json`; `*_s99.txt`; `1840_dfr.txt`.
- Transformed inputs: `/tmp/claude-0/verify/r3/lfi/` (rot90, crop0.8; made by `xform.py`).
- Path emulation: `/tmp/claude-0/verify/r3/emu/main.swift`, `emu1.txt`, `bands.txt`.
- Crops: `/tmp/claude-0/verify/r3/crops/{6001_BL,6001_BR,6001_TL,3437_TL,3437_TR,1840_TR}.png`.
- Tests: `/tmp/claude-0/verify/r3/lenstests.log`, `t_*.log`.
- Surface checker: `/tmp/claude-0/verify/r3/surface_{head,base84,base}.txt`.
