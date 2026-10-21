# WS-28 lens corrections: verification round 2

Verifier: fresh agent. Branch `quality/c3-lens` at 9bda872, Linux, CPU only.

What I worked from:
- SPEC.md, AUDIT.md, NEEDS.md, REPORT.md and VERIFY-1.md.
- The diff `5801df5..HEAD`. It changes `LensStage.swift` (estimator and `DefringeParams`), `RenderGraph+Lens.swift` (`LensInputsCache`), the docs and the evidence sheets. No test changes. No kernel or warp changes.

Build and test state:
- Release `lumen-render` was already current with HEAD.
- The debug test bundle was rebuilt with throwaway test files. Those files were removed afterwards and `git status` is clean.

All renders:
- Command: `render --input corpus/lfi-native/<n>.lfi --long-edge 0 --no-dither`, with K/T/ISO taken from the sidecar.
- "off" = `removeCA=false profile=false`. The round-1 baselines `/tmp/claude-0/verify/r/*_caoff.png` are still valid, because that path is unchanged.
- "on" = `removeCA=true profile=false`. Fresh renders: `/tmp/claude-0/verify/r2/`.
- My fresh "on" renders are byte-identical to the builder's `/tmp/claude-0/r2/*_caon.png` for 1840, 4213, 2545, 3437 and 6001. 6929 differs because the builder rendered it with the profile on.

## VERDICT: FAIL (narrowly)

Every round-1 failure is fixed **on the path the spec measures**, the CLI. 2.6, 2.7 and 2.8 pass there for all six photos, with the builder's numbers reproduced exactly.

Two things still fail:

**1. The app's measurement path does not give the model that was verified.**
- `LensInputsCache.measure` ranks tiles on a 2048 px preview. The CLI ranks on the full frame.
- I emulated the app path on Linux: `estimate(nativeWidth:nativeHeight:preview:fetch:)` with a Core Image–style bilinear 2048 preview, and native tiles fetched from the same LFI.
- 1840, 4213 and 6929 come out consistent with the CLI.
- **3437:** the app path corrects blue about 0.3 px harder at the corner. Rendered, the 0.8–1.0 zone overcorrects to **+0.121 px** (seed 99: +0.120). Spec 2.6 allows at most 0.1 px of the opposite sign.
- **6001:** the do-no-harm frame gets a **0.50 px red / 0.55 px blue model** in the app path, where the CLI returns none. So 2.8's bit-identity does not hold in the app.
- An area-average preview gives the same result, so this is not an artefact of my emulation.

**2. Spec 3.5's count clause still fails, and REPORT does not mention it.**
- The clause asks for ≥ 50 % fewer fringe pixels in the 0.8–1.0 zone. On 1840 they fall by only 7 % at threshold 0.03 and by 8 % at 0.015.
- REPORT still has no per-line verdict table.

## Round-1 failures, re-checked

| Round-1 defect | Status | Evidence |
|---|---|---|
| D1: invented or overcorrected blue on 2545, 6001, 3437 | **Fixed on the CLI path.** 2545 B −0.004 / +0.026. 3437 B −0.041 / +0.073. 6001 returns no model and is bit-identical. | `r2/{2545,3437}_cmp.txt`, `*_cmp_s99.txt` |
| D2: preview and export measured at different scales | **Partly fixed.** Both now measure native tiles, in one cache entry that does not depend on decode size, so preview equals export. But the app path ranks on a 2048 px preview and the CLI on the full frame, and the models diverge (see D-A). | `vfy.txt`, `warp/` |
| D3 / 6.3: Defringe evidence showed no fringe | **Fixed.** The new sheet shows a violet rim at 0 that fades at 2 and is gone by 5. Nothing away from edges changes. | `evidence/defringe-sweep.png` |
| D4: cache race | **Fixed for correctness.** Every measurement uses the same native pixels, so whichever write lands last is the same model. Duplicate work is still possible: two first renders each open a full native decode. | code |
| D7: no minimum hue span | **Fixed** by `DefringeParams.spanned`: lo = hi widens to 10 units about the centre, clamped to [5, 95]; NaN is handled. The GPU twin reads the Swift-computed bounds, so nothing changes there. **No unit test.** | code |
| D9: REPORT incomplete | **Partly fixed.** 1.2 now has a per-camera table. There is still no per-spec-line verdict, and 3.5's count clause is not addressed. | REPORT.md |

## Spec lines (measured this round)

| # | Measured | Result |
|---|---|---|
| 1.1 | `/tmp/claude-0/ci/raw2.txt`: 33 `lens-probe:` lines, including 4 for 6929.ARW and 4 for 2545.RW2. | PASS |
| 1.2 | REPORT §1 table: distortion, CA off→on and vignetting ring ratio for 6929, 6934, 2545 and 2547, with what is and is not corrected. | PASS |
| 2.1 | `testEstimatorRecoversConstantMagnification`, `…Cubic…` and `…NotFooledBySurfaceColour` pass. | PASS |
| 2.2 | `testCorrectionLeavesUnderAFifthOfATenthOfAPixel` passes (63.6 s). | PASS |
| 2.3 | `testCAFreeFrameIsAnExactIdentity` passes. | PASS |
| 2.4 | `testRemoveCAOffIsIdentity` passes. | PASS |
| 2.5 | `testColourEdgesDoNotInventCA` passes. | PASS |
| 2.6 1840 | 0.6–0.8: R +0.490→+0.051 (−90 %), B −0.177→−0.075. 0.8–1.0: R +0.520→−0.009 (−98 %), B −0.103→+0.032. | PASS (CLI) |
| 2.6 4213 | 0.6–0.8: R −0.228→+0.028, B −0.155→+0.071. 0.8–1.0: R −0.275→+0.015, B −0.187→+0.069. All reductions ≥ 63 %. | PASS (CLI) |
| 2.6 2545 | 0.6–0.8: R +0.217→−0.022, B −0.038→−0.004. 0.8–1.0: R +0.224→−0.022, B −0.015→+0.026. Seed 99 agrees within 0.008. | PASS (CLI; the emulated app path also passes, all zones ≤ 0.04) |
| 2.6 3437 | 0.6–0.8: B −0.511→−0.041 (−92 %). 0.8–1.0: B −0.576→+0.073 (−87 %). R untouched (no model). Seed 99: −0.032 / +0.086. | PASS (CLI). **Emulated app path FAILS:** 0.8–1.0 B +0.121, see D-A |
| 2.7 6929 | No model; on and off are byte-identical (`cmp`). | PASS |
| 2.7 6001 | No model; byte-identical. | PASS (CLI). Emulated app path: worst zone +0.047 worse (B 0.8–1.0), inside 0.05 |
| 2.8 | 6929 and 6001 return no model at native size (CLI), and on/off are byte-identical. | PASS (CLI). **Not true in the app path for 6001** (D-A) |
| 3.1–3.4 | Unit tests pass. LensStageTests 15/15 in 148.6 s. | PASS |
| 3.5 ΔE | P5/G5 against Defringe off (Remove CA on in both), whole frame. 1840: mean ΔE2000 0.0385, p99 1.32, 3.5 % of pixels changed. 4213: mean 0.0001. | PASS |
| 3.5 count | Auditor tool, zone 0.8–1.0, purple+green per 1000. 1840 @0.03: 4.5→4.2 (−7 %); purple 3.4→3.4. 1840 @0.015: 44.6→40.9 (−8 %). 4213 @0.03: 0→0. 4213 @0.015: 2.1→0 (about one edge). | **FAIL**, and not reported |
| 4.1–4.3 | Unit tests pass. | PASS |
| 4.4 | Vignetting path unchanged. A fresh `6929_vigon` is byte-identical to round 1's, so round 1's +0.458 EV stands. | PASS (marginal, as before) |
| 5.1, 5.2 | macOS CI only. The kernels and `warp` are unchanged since round 1, so round 1's twin review stands. | Not verifiable here |
| 6.1 | `1840-corner-ca.png`: red/magenta rims gone with CA on, no halo. | PASS |
| 6.2 | `4213-treeline-ca.png` (the spec name is now aligned): magenta/green twig rims reduced, no halo. `3437-corner-ca.png` is subtle but cleaner. | PASS |
| 6.3 | `defringe-sweep.png` (6929, r ≈ 0.71): progressive fade 0→2→5, gone by 10–20; nothing changes off the edges. The crop is not a corner, and the blue-violet part of the rim (outside the default range) remains, as REPORT §3 says. | PASS |
| 6.4 | Unchanged since round 1. | PASS |

Unit tests: `LumenCoreTests.LensStageTests` 15/15 pass.

The full Linux bundle run (`/tmp/claude-0/alltests2.log`) had not finished when I stopped:
- 466 passed, 0 failed so far.
- It has been inside `ControlProofTests` since 04:55; at 05:33 it was still running.
- It never reached "Executed N tests". The whole-suite gate is still unconfirmed.

## Defects, ranked

### D-A (high): app path ≠ verified path. Tile ranking scale changes the model; 3437 overcorrects and 6001 gets a correction

What differs between the two paths:
- `LensInputsCache.measure` ranks tiles on a `rankingLongEdge = 2048` readback. For 6024–8256 px frames that is s ≈ 0.25–0.34, with the ranking step at 1 preview px.
- `Renderer.lensInputs` (CLI) calls `estimate(full)`, which ranks on the native frame (step 4).
- Different tiles survive, the band medians move, and the gates (sign, outer band, 0.12 px floor) flip.

Emulation:
- Throwaway `VfyScaleTests`, source kept at `/tmp/claude-0/verify/VfyScaleTests.swift`.
- Core Image `transformed(by: scale)` is emulated as bilinear, `extent.integral`, top-down rows, clear outside.
- Native tiles are fetched from the full LFI.

Corner shift in px at r = .5 / .7 / .9 / 1 (`/tmp/claude-0/verify/vfy.txt`, `vfy_b1.txt`):

| photo | CLI `estimate(full)` | app path (2048 preview) |
|---|---|---|
| 1840 | R +.31/.42/.53/.57, B −.14/−.19/−.25/−.28 | R +.31/.41/.48/.51, B −.12/−.17/−.21/−.24 |
| 4213 | R −.22/−.29/−.34/−.35, B −.26/−.34/−.41/−.44 | R −.24/−.31/−.35/−.36, B −.30/−.38/−.40/−.40 |
| 2545 | R +.25/.30/.30/.27, B −.07/−.10/−.13/−.14 | R +.25/.31/.35/.36, **B none** |
| 3437 | B −.51/−.79/−1.16/−1.38 | **B −.58/−.95/−1.46/−1.78** (area preview −1.84) |
| 6001 | **none** | **R +.08/.19/.38/.50, B +.53/.63/.61/.55** (area preview: R …/.50, B …/.38) |
| 6929 | none | none |

Rendered impact:
- **Method.** Warp the LFI with the model, then render with Remove CA off and chroma NR 0. With the CLI model this is byte-identical to the in-pipeline render, so the method is exact. With the default chroma NR 25, warping before NR shifts the medians by up to 0.09 px, so I used NR 0.
- **3437 app model:** 0.8–1.0 B −0.685 → **+0.121** (seed 99 +0.120). The CLI model on the same NR 0 basis gives −0.035. This fails 2.6's opposite-sign limit of 0.1. It is not visible at 100 % on this soft frame (`r2/crops/3437_TR_app.png`).
- **6001 app model:**
  - R 0.8–1.0: +0.429 → +0.208 (better).
  - B 0.8–1.0: +0.117 → −0.164 (+0.047 worse, just inside 2.7's 0.05).
  - B 0.3–0.6 / 0.6–0.8: from about +0.23 / +0.32 to −0.05 / +0.03.
  - Net, the frame is changed by default, which 2.8 says must not happen. Not visible in my crops (`r2/crops/6001_BL_app.png`).
  - Note: on 6001 the auditor tool reads R 0.33–0.43 px in the corner zone. Whether 6001 "has no CA" is itself on a knife-edge.

The same fragility shows elsewhere:
- 3437 rotated 90° (a portrait-oriented decode) gives B −1.75 px at the corner against −1.38 unrotated. A radial model should not depend on orientation. Rendered, it lands at +0.088 in the 0.8–1.0 zone (inside the limit, barely).
- Caveat: on macOS the app measures Apple's decode, not the LibRaw LFI, so its real models differ again. The point stands: the corpus numbers in REPORT §2 describe the CLI's tile ranking, not the app's.

Fix direction:
- Rank the same way in both paths: the CLI should call the tile path with the same 2048 px ranking preview, or the app should rank at native size.
- Then re-verify 2.6–2.8 on that path.

Evidence: `/tmp/claude-0/verify/vfy.txt`, `vfy_b1.txt`, `warp/3437_{cli0,app0,rot0}_cmp.txt`, `warp/3437_app0_s99.txt`, `warp/6001_app0_cmp.txt`, `warp/6001_app0_s99.txt`, `warp/2545_{cli,app}_cmp.txt`.

### D-B (medium): spec 3.5's count clause is unmet and unreported

- Purple 5 / Green 5 leaves the auditor tool's corner fringe counts on 1840 at −7 % (@0.03) and −8 % (@0.015). The purple class did not move at all (3.4 → 3.4).
- 4213 has nothing to count.
- REPORT §3 discusses only 6929 and the ΔE bound.
- Either the clause is met, or REPORT must state the FAIL with an argument (for example, that counts are too small to carry ≥ 50 %, and that the tool's purple class lies outside the 279–351° band). The spec owner then decides.

Evidence: `/tmp/claude-0/verify/r2/1840_dfr_0.03.txt`, `1840_dfr_0.015.txt`, `4213_dfr_*.txt`.

### D-C (medium): no tests for the new code

The diff `5801df5..HEAD -- Tests` is empty. Untested:
- the native-tile estimate path `estimate(nativeWidth:…fetch:)`;
- the top-left → bottom-left tile conversion;
- the band-median and sign gates;
- `DefringeParams.spanned` (minimum hue span).

The lane brief requires tests for measurable lines. A test that runs `estimate(full)` and the tile path with a downscaled preview, and asserts agreement on a synthetic frame, would also have caught D-A's class of problem.

### D-D (low): first-open cost and duplicate work in `LensInputsCache`

- The measurement is synchronous in `makeGraph`.
- It opens a second `AppleRawSource` and decodes at scale 1, then renders a 2048 px ranking readback (which needs the whole native demosaic) plus up to 600 crop renders of a lazily evaluated `CIRAWFilter` output.
- Whether those crop renders stay ROI-bounded on macOS cannot be measured here. If each one re-runs the RAW pipeline, first open of a 45 MP file could take tens of seconds. REPORT lists this for hand-testing; it should be timed on macOS before merge.
- Two concurrent first renders of one URL each pay this in full; there is no in-flight dedupe.

### D-E (low): vignette record re-read on every small render

- The separate `vignettes` cache was removed.
- For decodes under 1200 px nothing is cached, so every `makeGraph` call reads 4 MB of the RAW and walks its TIFF (thumbnails, small preview rungs).

### D-F (low, info): Green Defringe touches teal foliage shadow edges

- 1840 at Green 5, left edge at r ≈ 0.76: some blue-green leaf-shadow edges are pulled toward grey in the chroma view. They are barely visible in the image.
- Whole-frame mean ΔE is 0.0385; max 12.9 on 3.5 % of pixels.
- Lightroom's Green defringe behaves similarly, so this is info, not a spec failure.
- Evidence: `/tmp/claude-0/verify/r2/crops/1840_dfr_L.png`.

### D-G (docs)

- `Sources/LumenRender/main.swift:112` still says the CA model is measured "on the input at ≤ 4000 px"; the CLI measures at full size.
- REPORT §5 placeholders remain (LINUX, CI, VERIFY2), as expected.

## App path: coordinate conversion, by reasoning

- `zeroed(full)` moves the native extent origin to (0, 0).
- A tile at top-left (x, y, w, h) becomes the Core Image rect `(x, H − y − h, w, h)`.
- `PipelineRenderer.buffer` renders `extent.integral` with `render(toBitmap:)`, which writes the top row first. That is the convention the full-frame readback (and round 1's path) already relied on.
- So tile rows map to frame rows y…y+h−1 correctly.
- Bounds are guarded, so nothing outside the frame is fetched.
- The 2048 preview's height is non-integral (for example 1365.3). `integral` adds a partly clear top row, so the ranking grid is offset by up to 1 preview px (about 4 native px). That moves ranking windows by under 10 % of a tile. My emulation reproduced this offset, and an area preview without it gives the same model, so it is not the cause of D-A.
- Orientation: both decodes come from the same source type and are oriented the same way. The model is normalised to the half-diagonal and centred, so scale and 90° rotation do not affect how it is applied. They do affect how it is estimated (D-A).
- Measuring with `Recipe()` means Apple's distortion correction is on even when the user turns the profile off. The effect on a normalised CA scale is a few per cent. Negligible.

## Break attempts

| Attempt | Result |
|---|---|
| One-channel CA (red only, 0.5 px at the corner, injected into 6929) | Recovered R +0.23/.34/.48/.55 against true .25/.35/.45/.50. B stays none. App path identical. **Held.** |
| Very dark frame (4213 and 6929 at −7 EV with shot and read noise) | Model none on both: no invented CA. Real CA is lost in the noise, a safe failure. **Held.** |
| Heavy vignetting (2.5 EV corner fall-off on 4213 and 6929) | 4213 model within 0.04 px of the original; 6929 none. **Held.** |
| Coloured texture (2545 foliage, red/grey roof) | CLI B is now corrected only 0.14 px and the zones stay ≈ 0. App path: B none. Roof crop: magenta ridge spots reduced, a faint orange line on the gutter edge at ×4 chroma only. **Held.** |
| Rotated 90° (3437, 6001) | 6001 stays none. 3437 B corner −1.75 against −1.38 px: orientation-dependent, but inside the limit when rendered (+0.088). **Weak** (part of D-A). |
| Own 100 % crops in regions the builder did not pick | 3437 top-left and top-right, 2545 top-right branches and roof, 6001 bottom-left: no new halos, no visible softening, no visible harm. |
| Defringe hue span (lo = hi, reversed, NaN) | Correct by reading `spanned`. |

## Files

- Fresh renders and comparisons: `/tmp/claude-0/verify/r2/`
  - `<id>_caon.png`, `<id>_cmp.txt`, `*_s99.txt`
  - `1840/4213_p5g5.png`, `*_dfr_*.txt`
  - `6929_vigon.png`
  - `crops/`
- App-path emulation renders: `/tmp/claude-0/verify/warp/` (`*_off0`, `*_on0`, `*_cli0`, `*_app0`, `*_rot0` .png and `*_cmp.txt`)
- Estimator emulation output: `/tmp/claude-0/verify/vfy.txt`, `vfy_b1.txt`, `vfy_b2.txt`
- Throwaway test sources (not in the repo): `/tmp/claude-0/verify/VfyScaleTests.swift`, `VfyWarpTests.swift`
- Scripts: `/tmp/claude-0/verify/render2.sh`, `render3.sh`, `crop.py`, `de2000.py`
