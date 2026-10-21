# WS-28 lens corrections: verification round 1

Verifier: a fresh agent working from SPEC.md, AUDIT.md, NEEDS.md and the diff `9068ded..5801df5`. The local base ref `claude/inspiring-dirac-ulgpch` is stale, so the lane's own commits are e3e48a3..5801df5.
Build: release `lumen-render` and the debug test bundle, both current with HEAD. The only local change is the uncommitted CompareView patch. Linux, CPU only.
All renders: `lumen-render render --input corpus/lfi-native/<n>.lfi --long-edge 0 --no-dither --as-shot-kelvin K --as-shot-tint T --iso I` with K/T/I from the sidecar `recipe_hint`.
- "off" = `removeCA=false profile=false`
- "on" = `removeCA=true profile=false`

Script: `/tmp/claude-0/verify/render.sh`. Outputs: `/tmp/claude-0/verify/r/`.

## VERDICT: FAIL

Remove CA works well on the two frames the builder measured (1840 D850, 4213 Z7II). It fails the spec on the other two CA frames (2545 GX85, 3437 T7i) and on the do-no-harm frame 6001.

The 1840 pass also holds only for the CLI's measurement at native size. The app measures CA on a decode capped at 6144 px. On that decode the same photo overcorrects past the spec's limit.

Defringe meets its ΔE bound. It misses the auditor-tool fringe-count bound, and the evidence sheet shows no visible fade.

## Identity checks (re-measured)

- **Off renders match the base commit byte for byte.** For all 6 photos, `removeCA=false profile=false` is byte-identical (`cmp`) to the auditor's pre-lens-stage baseline renders `/tmp/claude-0/audit/render_<n>.png` (1840, 4213, 2545, 3437, 6929, 6001).
- **Synthetic frames.** All 7 `corpus/synthetic/*.lfi` render byte-identical with the default recipe and with `removeCA=false profile=false`. The estimator returns "none" on each. Hard_edge and hue_wheel at Defringe 20/20 are also byte-identical to the default.
- **The builder's renders reproduce.** My 1840 removeCA=true, exposure +1 render is byte-identical to `/tmp/claude-0/ev/1840_nikon-d850_ca-true.png`. The builder's `*_ca-true.log` files are stale (02:01) and show an older CA model, but the PNGs (02:44) match the current binary.

## Spec lines

| # | Measured | Result |
|---|---|---|
| 1.1 | `/tmp/claude-0/ci/raw2.txt` has `lens-probe:` lines for 6929 (geometry, CA off/on, vignetting rings beside record) and 2545 (same, "no embedded record"). Also 2547, 2607, 5283, 5812, 6168, 6934. | PASS |
| 1.2 | `REPORT.md` is untracked. At ~03:00 it held `VERDICT_PLACEHOLDER` and a `VERIFY_CA_SUMMARY` stub, and no per-camera numbers. | FAIL (incomplete) |
| 2.1 | `testEstimatorRecoversConstantMagnification`, `…Cubic…` and `…NotFooledBySurfaceColour` pass. | PASS |
| 2.2 | `testCorrectionLeavesUnderAFifthOfATenthOfAPixel` passes. | PASS |
| 2.3 | Unit test passes. Plus 7/7 synthetic frames byte-identical (above). | PASS |
| 2.4 | `testRemoveCAOffIsIdentity` passes. | PASS |
| 2.5 | `testColourEdgesDoNotInventCA` passes. | PASS |
| 2.6 1840 | Zone 0.6–0.8: R +0.490→+0.079 (−84 %), B −0.177→−0.007. Zone 0.8–1.0: R +0.520→+0.051 (−90 %), B −0.103→**+0.089** (sign flip, inside 0.1). | PASS (CLI path only, see D2) |
| 2.6 4213 | Zone 0.6–0.8: R −0.228→+0.047 (−79 %), B −0.155→+0.059. Zone 0.8–1.0: R −0.275→+0.063 (−77 %), B −0.187→+0.011. | PASS |
| 2.6 2545 | R improves (0.217→0.002, 0.224→−0.023). **B −0.038→−0.165 (0.6–0.8) and −0.015→−0.176 (0.8–1.0)**: over 0.15, and a blue misregistration created where there was none. Seed 99 gives −0.174 / −0.180. | **FAIL** |
| 2.6 3437 | **B 0.6–0.8: −0.511→−0.209** (0.209 > 0.15; reduction 59 % < 60 %). B 0.8–1.0: −0.576→−0.090 OK. R 0.3–0.6 gets worse, −0.033→−0.120. Seed 99: −0.505→−0.213. | **FAIL** |
| 2.7 6929 | Worst \|after\|−\|before\|: B zone 0.8–1.0, 0.012→0.043 = +0.031. All other zones +0.025 or less, or improved. | PASS |
| 2.7 6001 | **B zone 0.8–1.0: +0.071→−0.248 = +0.177 worse** (limit 0.05). Model B k0 = 1.60e-4, a 0.74 px blue correction at the corner. | **FAIL** |
| 2.8 | 6929 2400 px decode (`corpus/lfi`): estimator "none", on/off byte-identical. Native: the estimator returns a model (max 0.093 px against the 0.08 threshold), so on ≠ off. The spec's condition ("if the estimator returns none") is not met there. | PASS at 2400 / N.A. native |
| 3.1–3.4 | Unit tests pass. | PASS |
| 3.5 ΔE | Purple 5 / Green 5 vs Defringe off (removeCA on in both), whole frame ΔE2000. 1840: mean 0.038, p99 1.31, max 12.7, 3.5 % px changed. 4213: mean 0.0001, 0.008 % px changed. My ΔE2000 matches the Sharma test pairs (2.0425, 1.0000). | PASS (< 0.5) |
| 3.5 count | Auditor tool, zone 0.8–1.0, purple+green fringe edges per 1000. 1840 @0.03: 7.8→4.0 (−49 %; purple alone 7.4→3.3, −55 %; only about 21 edges). 1840 @0.015: 53.6→46.9 (−12.5 %). 4213 @0.03: 0→0 (nothing to measure). 4213 @0.015: 4.2→3.9 (−7 %). | **FAIL** (≥ 50 % not met at 0.015; borderline or unmeasurable at 0.03) |
| 4.1–4.3 | Unit tests pass. | PASS |
| 4.4 | 6929 profile on vs off (removeCA off in both), mean display-linear luminance. Ring 0.9–1.0 rises **+0.458 EV relative to r < 0.2** (0.8–0.9: +0.388; 0.6–0.8: +0.252). Script `/tmp/claude-0/verify/ring.py`. In range, with 0.008 of margin. The tone curve compresses it; the record says 0.54 EV for that ring. | PASS (marginal) |
| 5.1, 5.2 | macOS CI only. | NOT VERIFIABLE HERE (code review below found no twin mismatch) |
| 6.1 | `evidence/1840-corner-ca.png`: red/magenta rims fade with Remove CA on, no halo. My crops agree. | PASS |
| 6.2 | The spec names `4213-castle-ca.png`; the file is `4213-treeline-ca.png`. Paired magenta/green twig rims are reduced, no halo. | PASS on content, file name mismatch |
| 6.3 | `evidence/defringe-sweep.png`: the 6929 crop at 0/2/5/10/20 shows no visible purple fringe and no visible progression. My crop at x6200 y600 (Purple 20) removes the vivid violet segments, but the dominant blue-violet rim around the sky gaps stays. | **FAIL** (claim not demonstrated) |
| 6.4 | `evidence/6929-vignette.png` and my own full-frame off\|on: corners lifted, no ring, no new clipping (clipped 0.00 % both). | PASS |

Unit tests: `LumenCoreTests.LensStageTests` 15/15 pass (60.9 s). `SliderEvidenceTests` 7/7 pass. I stopped the full bundle after 475 passed and 0 failed: it sat in `ControlProofTests` for more than 30 minutes while a second full run (not mine) competed for CPU. The whole-suite gate is unconfirmed by me.

## Defects, ranked

**D1 (high): the estimator invents or overcorrects blue CA on 2545, 6001 and 3437; spec 2.6 and 2.7 fail.**
- **2545:** Model B k0 = +1.34e-4 (about +0.27 px at r 0.9). The auditor tool reads B-G about 0 before, both in the LFI (−0.075/−0.032) and in the PNG (−0.038/−0.015), and −0.17 px after. My roof crop shows the magenta ridge spots reduced but a new blue-violet rim along the roof top edge.
- **6001:** Model B 0.74 px at the corner. The corner zone gets 0.18 px worse.
- **3437:** B is under-corrected mid-frame (0.209 left in 0.6–0.8), and the R error in 0.3–0.6 grows. The k0 + k2·r² shape does not fit this lens.

Because Remove CA defaults to on, these frames change by default for the worse by the spec's own metric.
- Evidence: `/tmp/claude-0/verify/r/{2545,3437,6001}_cmp.txt`, `*_cmp_s99.txt`
- Crops: `/tmp/claude-0/verify/r/crop_2545_roof.png`, `crop_2545_fence.png`
- At 2400 px the 2545 and 6001 models are larger again: 2545 B k0 2.0e-4; 6001 B k0 3.07e-4.

**D2 (high): the app's measurement path is not the path the spec measured.**
- The CLI estimates at native size. `LensInputsCache` estimates on the decode, capped at `maximumMeasureLongEdge` = 6144, and previews at whatever size they decode (≥ 1200).
- The estimator is not scale-consistent on real photos. Its doc comment admits this for 1840.
- 1840 model R shift at r = 1, in native px: 0.485 measured at 8256 (CLI), 0.81 measured at 6144, 0.81 measured at 2560. For B: −0.32, −0.34, −0.43.
- Rendering the 6144 px bicubic downsample off/on: zone 0.8–1.0 R-G goes +0.379 → **−0.145 px**, and r = 1 fit +0.429 → −0.263. That is overcorrection past the 0.1 px limit of 2.6.
- So an app export of a D850 or Z7II (8256 px) uses a model that fails 2.6. The preview also shows a different CA correction than the export until a larger decode re-measures.
- Evidence: `/tmp/claude-0/verify/brk/1840_6144_cmp.txt`, `1840_6144_*.log`, and the model lines from `brk/1840_2560.lfi`.

**D3 (medium): Defringe Purple at its default hue range does not reach 6929's fringe, the auditor's designated Defringe frame.**
- At Purple 20, native, the auditor tool (@0.015) reads corner purple-fringe edges 226.7→214.8 per 1000 (−5 %) and the other zones +1…+7 %. Only 0.197 % of pixels change.
- `defringe_direct.py` on the same frame: purple-class pixels (279–351°) −84 %, blue class (230–279°) −6 %.
- The auditor saw this fringe as "blue-violet to purple", and the blue part lies outside 279–351° plus the 10° feather.
- The evidence sheet (6.3) shows nothing changing.
- Which Defringe metric I believe:
  - The ΔE bound (local action, no global shift) is real. Mean ΔE 0.038 / 0.0001; pixels away from edges change by 0.
  - `defringe_direct.py` was added in the builder's evidence commit 5801df5, not by the auditor. It classifies pixels by the implementation's own default band (279–351°). So it confirms the code desaturates what it was designed to select; it is close to circular.
  - The auditor's tool asks whether the visible fringes went away, and on 6929/1840/4213 it says mostly not. On 1840/4213 its counts are too small (about 20 edges at 0.03) to carry a ≥ 50 % criterion, so 3.5's count clause is weak on those frames either way.
  - So I trust the auditor tool for the claim that matters to a user, and the direct tool only as proof of mechanism.
- Evidence: `/tmp/claude-0/verify/r/6929_p20_cmp.txt`, `crop_6929_p20.png`, the `defringe_direct` output in this report.

**D4 (low): `LensInputsCache.inputs` race.** Measurement runs outside the lock, then `held[url] = Entry(...)` is written unconditionally. A smaller measurement (preview) that finishes after a larger one (export) overwrites the better entry. The write should keep the larger `measuredLongEdge`. Two concurrent first renders also both pay the readback (up to about 400 MB) and the estimate. This is wasted work, not a correctness problem.

**D5 (low): synchronous estimation in `makeGraph`.** The first render per photo, and each ≥ 1.5× larger decode, reads the decode back and runs the estimator on the render thread. On Linux CPU, a full CLI render at long edge 128 took 2.2 s total (2560 px input) and 3.7 s (6144 px input), estimator included.

**D6 (low): slight R/B softening.** At the top 2 % G edges (r > 0.6), R/B gradient magnitude falls 1.6–3.8 % on (1840 R 0.983 B 0.984; 4213 R 0.963 B 0.962; 3437 0.997), against G 0.994–0.999. This is the Catmull–Rom resample. It is not visible in crops and is within the auditor's 10 % proposal.

**D7 (low): Defringe hue range has no minimum span.** Reversed lo/hi is silently swapped (Purple 10 at 70/30 is byte-identical to 30/70, which is fine). lo == hi still acts over the ±10° feather, and there is no 10-unit minimum span as in Lightroom. Out-of-range values clamp correctly: Amount 1e9 / −50 is byte-identical to 20 / 0.

**D8 (info): extreme Defringe settings behave like Lightroom.**
- Purple 20 at the default range draws a 1 px grey outline on the lavender ColorChecker patch edge (`/tmp/claude-0/verify/syn/cc_zoom.png`).
- Green 20 touches the foliage-green patch edge.
- Full hue ranges 0–100 at 20/20 on 6929 change 23 % of pixels (ΔE p99 12.4) and grey the foliage outlines.
- Green 20 at the default range on foliage: 6929 mean ΔE 0.038, 2545 mean ΔE 0.005. Foliage is protected.

**D9 (docs):** REPORT.md is unfinished (placeholders). The evidence file name differs from spec 6.2.

## Break attempts that held

- **Off-centre crop.** The top-right quarter of 1840 puts the optical centre at a crop corner. The estimator returns a model; the tool's zone medians move by 0.06 px or less. The real CA is not removed but nothing is harmed.
- **Small and rotated input.** Small (1032 px): the model is about 0.09 px, negligible. Rotated: not rendered (the radial model is invariant under it).
- **Exposure.** Exposure +1 does not change the CA model, which is measured on the input. Defringe's edge test is in stops, so it is exposure-invariant.
- **White balance.** Defringe selects on as-shot colours (the stage sits before S5). In the app, decode-time WB is already in the pixels. Not tested further.
- **Vignetting.** The probe shows Apple does not apply the Sony vignetting record (on/off ring ratio 0.9996), so there is no double correction.

## GPU twin review (by reading; NOT run)

`LensKernelSource.lens` against `LensStage.warp` and `catmullRom`:
- **Pixel centres.** `destCoord` gives pixel centres, matching Swift's `x + 0.5`. The centre is `extent.midX/midY`, which equals the Swift `w/2, h/2` when the extent origin is 0. `makeGraph` always passes the full scaled decode (a region is applied later), so the centre is the optical centre.
- **Y-flip.** CI's flipped y is harmless because every operation is radial or symmetric.
- **Resampling.** Tap bases (`floor(q − 0.5) + 0.5 + (i − 1)`) and the weights order (`x, y, z, w` = taps −1..2) match Swift.
- **Edges.** `clampedToExtent` matches Swift's index clamp at texel centres.
- **ROI reach.** `ceil(maxShift) + 3` covers the 2-tap reach plus margin.
- **Vignetting.** It multiplies all three channels, as Swift does, and at a neutral scale the resample hits exact centres.

Defringe twins:
- `step(k, radius)` matches the Swift loop.
- The max goes in r and the min in g, and the apply kernel reads `window.r − window.g`.
- The hue wrap `floor(x + .5)` vs Swift `.rounded()` differs only at exactly ±180°, where `abs` makes them agree.
- The negative-hue fix and the cube-root sign handling are equivalent.
- Argument order matches in `applyLens` and `applyDefringe`.

Residual risks, both already in NEEDS.md:
- A kernel that fails to compile drops the stage on GPU only (not yet on `unavailableKernels`).
- The eyedropper and mask-source graphs lack `lensInputs`.

## Files

- Renders and comparisons: `/tmp/claude-0/verify/r/` (`<id>_caoff/caon/p5g5/p20/vigon.png`, `<id>_cmp.txt`, `<id>_dfr_*.txt`)
- Break tests: `/tmp/claude-0/verify/brk/`
- Synthetic identity: `/tmp/claude-0/verify/syn/`
- Scripts: `/tmp/claude-0/verify/{render.sh,ring.py,de2000.py,crop.py}`
