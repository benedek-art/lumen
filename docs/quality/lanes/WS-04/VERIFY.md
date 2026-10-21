# WS-04 Exposure: verifier report (round 1)

**Verdict: PASS** on every gating line (§1 lines 1–11, §2 lines 12–17), with one
deliverable gap that must be closed before push: the `evidence/` folder that §3 names
does not exist yet (see "Gaps" below). Sections 3 and 4 are human-judged and are not
gated by this report.

The verifier saw only SPEC.md, LANE-BRIEF §1, NEEDS.md, `git diff` and the two new test
files. BUILD-NOTES.md was not read. Every number below was re-measured.

## Build

- `swift build --target LumenCore --target LumenRender`: clean.
- `swift build -c release --product lumen-render`: clean.
- Test bundle built with `/tmp/claude-0/runtests.sh` (`CompareView.swift` reverted after the build,
  and `git status` shows it unmodified).
- Base binary for the A/B comparison: release `lumen-render` built in a worktree of
  `claude/inspiring-dirac-ulgpch` @ 84bcd7c. The worktree was removed afterwards.

## Per line

| # | Verdict | Measured |
|---|---|---|
| 1 | PASS | Max rel err of M(EV) against 2^EV·M(0) is **0.0** (test). An independent harness run also gave **0.0** at quarter-stop EVs from −10 to +10 for as-shot 2500 K/−50, 5000/0 and 10000/+80 with printer lights m −3 / r +5 / g +1 / b −4. |
| 2 | PASS | Max rel err is **0.0** over 4686 channels. Signs are kept, and EV +1 on (−0.3, …) gives < −0.59. |
| 3 | PASS | **0.0** on all 11 recipes. The harness also gave **0.0** for 8 more: highlights −100 / whites +100; highlights +100 / whites −100 / shadows −100 / blacks +100; printer lights (2, 3, −2, −3); WB 3000/−40; WB 12000/+60; Film Lab portra400 + vignette +60; and a lumaRange mask with local exposure +2 at amount 150 (that mask's effect on its own is 167 codes, so it was really applied). |
| 4 | PASS | Buffers: 0 differing floats. CLI with `--long-edge 1024` on 6929: no key, `exposure=0` and `exposure=-0.0` give identical files (`cmp` reports no difference). |
| 5 | PASS | **117.646** |
| 6 | PASS | LUT33: 20.32 / 41.29 / 72.72 / 117.65 / 168.74 / 207.17 / 234.51. EV k against the prescaled input: **0.0**. |
| 6a | PASS | Exact path: 20.32 / 39.44 / 70.41 / 117.65 / 168.58 / 207.45 / 234.51. |
| 7 | PASS | **0** falls on LUT33 and **0** on exact. The harness also stepped 1e-6 EV, 200 steps each, from 0, 1, 4.999, −5 and 9.99999: **0** falls, largest step 7.3e-5 codes. |
| 8 | PASS | LUT33 **0.636** (scene 0.18 at EV 0.01, limit 0.70). Exact **0.570** (scene 4 at EV −4.47, limit 0.62). |
| 9 | PASS | LUT33 **+0.636**, exact **+0.570**. |
| 10 | PASS | Gains for 10 / 11 / 12 / 1e6 are 1024; for −10 / −12 / −1e6 they are 1/1024. Renders are bit-equal (test). CLI: EV 12 and EV 10 PNGs are byte-identical on 6929 and 2545. |
| 11 | PASS | `BasicPanel.swift:466-469`: `range: -5...5, hardRange: -10...10, defaultValue: 0, step: 0.01`. This equals `ToneEngine.exposureLimit = 10`. |
| 12 | PASS | Gains for NaN / +inf / −inf are 1 / 1024 / 1/1024. The NaN plan is the identity, the NaN render is bit-equal to EV 0, and it has 0 NaN pixels. The harness found 0 non-finite pixels in the render and exactColor paths for NaN, ±inf and −0. The CLI rejects `exposure=nan` at recipe decode, so no NaN reaches the engine from the CLI. |
| 13 | PASS | `outputLimit = 65504`, defined once. EV +10 `apply(64, 1e3, 1e4)` gives (65504 ×3), `apply(−1e4, …)` gives −65504, and 0.18 gives 184.32 exactly. Inputs up to ±1e30 stay finite. The identity skip is unchanged on both paths. The CreativeLUT `displayToWorking` product is bit-equal. GPU (code reading): `CIFilter.colorClamp()` with `CIVector` min (−L, −L, −L, 0) and max (L, L, L, 1) is chained straight after `CIColorMatrix`. This is the same API and types as the existing `RG.clamped` at RenderGraph.swift:2186, the imports `CoreImage` and `CoreImage.CIFilterBuiltins` are present, and `CGFloat` → `CIVector(x:y:z:w:)` compiles. |
| 14 | PASS | All outputs are finite, and the minimum neutral code is **254.99999**. |
| 15 | PASS | NEEDS.md N-1 names `ReferenceRenderer.swift` `RR.render` line 68 `image = image.map { matrix.apply($0) }`. I checked, and lines 66–69 are exactly the S6 block. |
| 16 | PASS (code reading; macOS CI pending) | `ExposureGPUParityTests.swift` is wrapped in `#if os(macOS)`. Its imports (`CoreImage`, `XCTest`, `@testable LumenCore/LumenPipeline`) match `CreativeLUTParityTests.swift`. It uses `PipelineRenderer.buffer(from:context:)`, which is public at PipelineRenderer.swift:3002 with an RGBAf readback, and the `ImageBuffer.pixels` `[Float]` RGBA layout fits `bytesPerRow: width*16`. With the as-shot D65 plan at EV +10 the matrix is ≈1024·I, so `out[0,0].g == 65504` and `out[2,0].g == −65504` should hold, and the ramp at ±3 EV stays below 3.3e3, far inside fp16. The test cannot run on Linux. |
| 17 | PASS | All 14 `ExposureQualityTests` pass. LumenCoreTests: see "Full suite" below. |

## Breaking attempts

- **±10, ±12, 1e6, NaN and ±inf** through `RenderPlan`/`ToneEngine` directly: these are covered under lines 10 and 12, and nothing became non-finite. Scene values (64, 1e4, (1e6, 1e3, 1), 1e30, −1e4, (1e4, −50, 20)) at EV −12, −10, 0, 5, 10 and 12 produced 0 non-finite outputs on LUT33 and on exact.
- **`LinearStage.apply` with non-finite input:** a NaN input stays NaN, as documented. An inf channel through the real WB matrix gives NaN in the other channels, because 0·inf happens in the matrix product before the clamp. The test documents this and it is not a scene value, so it is not gating. On the GPU, Metal `clamp(NaN)` is implementation-defined (usually the low bound), so the CPU and GPU twins may differ for NaN input. That only matters if a NaN reaches S6, which line 12 prevents for the Exposure input.
- **The 1e-12 identity threshold:** EV 1e-13 counts as identity, and EV 2e-12 does not. This is the same test as `RG.applyMatrix`, so both renderers skip on the same plans.
- **Neighbours** (WB temp/tint, printer lights, highlights/whites, tone stack, masks with local exposure, Film Lab, vignette, clarity/dehaze): all pure-gain-equivalent with 0.0 code diff (line 3 above).
- **The other 16 `RG.applyMatrix` callers.** The main CIContext works in RGBAh (PipelineRenderer.swift:79). DecodeMaterializer's RGBAf context does not call `applyMatrix`. Per caller:
  - finishScale (278), fallback tone (2156), CreativeLUT workingToDisplay and displayToWorking (381, 390), proof workingToProof and the −1 negation (425–426), the tone gain scale (928), denoise Y0U0V0 rotations and broadcasts (694–765), halation weight (1818) and dehaze −ω (1207) all work on bounded values, so the clamp is a no-op for them.
  - The gamut gate ×1/ε (441) and dehaze 1/airlight (1194) can go past 65504 in-register. Both feed straight into a [0, 1] clamp: `blendMask`'s mask clamp, and the morphology minimum → `clamped(0, 1)`. 65504 and anything larger read the same there, so the output does not change.
  - Mask local exposure (1295) can go past 65504 only for scene values past fp16 anyway. It now stores 65504 instead of inf, which is an improvement and not a behaviour change for real data. Its next consumer is a log encode, whose domain tops out far below 65504.
  - No kernel tests for NaN or inf (grep for isnan/isinf/isfinite over Sources/LumenPipeline finds nothing), so no caller relies on inf/NaN propagation.
  - With opaque alpha (aVector (0, 0, 0, 1)), the alpha clamp [0, 1] is the identity.
- **Byte-identity against the base commit** (release `lumen-render`, long edge 1024, as-shot K/tint/ISO from the sidecars):
  - 6929_sony-ilce-7m4 and 2545_panasonic-dmc-gx85 at EV 0, +1, +3, −2, +10, −10 and +12 are byte-identical to base.
  - Synthetic grey_ramp and hue_wheel at EV 0, +1, +3 and −2 are byte-identical to base.
  - Sweep sheets (−2…+3 for 6929 and 2545, −3…+4 for grey_ramp) are byte-identical before and after. The metrics JSON differs only in `renderSeconds`.
  - This is expected: the CPU render path does not call `LinearStage.apply` until N-1 lands, and only `exposureGain`'s NaN branch and the unused clamp changed on the CPU side.

## Sheets opened (my own renders)

- **`sweep_6929_sony-ilce-7m4_NEW.png`**, Sony A7 IV, −2…+3: a smooth, even brightening. The white wall and the plaster bleach gradually to near-white at +3, with no colour fringes at the clip, no halo at the foliage edges and no posterisation. The foliage goes pale yellow-green at +3. That yellowing is the hue drift tracked as O1/O2, outside this lane.
- **`sweep_2545_panasonic-dmc-gx85_OLD.png`** (byte-identical to the NEW sheet), GX85, −2…+3: the sky stays blue and lightens to pale blue/white at +3, and it does not go cyan. The grass goes cream. At −2…0 the sky corner shows some blotchy patches. Since before and after are byte-identical this is pre-existing, and it is most likely the sheet's PNG quantisation or a noisy decode. It is worth a human look, but WS-04 did not introduce it.
- **`sweep_grey_NEW.png`**, grey ramp −3…+4: the patch steps are evenly spaced, nothing inverts, and the highlight end saturates progressively from +2. No banding within patches.

## Gaps (must close before push; not code defects)

1. **The evidence is missing.** `docs/quality/lanes/WS-04/evidence/` does not exist, so the files that SPEC §3 V1–V3 name for the human (`sweep_6929_a7iv_ev.png`, `sweep_2545_gx85_ev.png`, `crop100_6929_ev0_2_3.png`, `sweep_grey_ramp_ev.png`, `sweep_6929_a7iv_ev_before.png`) are absent. `REPORT.md` is also absent. The brief requires both on the branch.
2. **Line 16 runs on macOS CI only.** It was checked here by code reading, and CI must confirm it.
3. **Out of lane, observed while probing.** A saturated off-axis scene pixel (1e4, −50, 20) at EV +10 renders white through LUT33 but magenta (255/0/249) through the exact path. This is a LUT/exact disagreement in the display transform (WS-13), and it is identical on the base commit.

## Full suite (line 17)

I ran the full debug test binary with no filter and a 3000 s timeout. It stalled in
`ControlProofTests` (the run started at 01:48:58 and made no progress for more than 13 minutes),
at the same suite where the base-commit run (`/tmp/claude-0/base-tests.log`) also stopped. Up
to that point the branch matched the baseline: **426 passed, 0 failed**.

I then ran the remaining 326 LumenCoreTests suites, every one except `ControlProofTests`, in
three chunks. Result: **3054 tests executed, 3048 passed, 6 skipped, 0 failures**. That
includes `EngineTests`, `PlanTableCacheTests`, `AccuracyProbeTests`, `RobustnessTests`,
`ColorScienceTests` and `ExposureQualityTests`.

I also ran each of the five non-writing `ControlProofTests` tests on its own, with a 2400 s
timeout. All five timed out inside the suite's shared setup before any test case started.
The base commit stalls in the same place. I judge this as pre-existing and not caused by
WS-04, for two reasons:
- The CPU render output is byte-identical to base on every input I compared.
- The only other CPU consumer of the changed `LinearStage.apply` is `RenderPlan.exactColor`
  (RenderPlan.swift:595, 650). It changes only where |S6 output| > 65504, plus a sub-1e-12
  identity skip that now matches `RR.render`.

The LumenPipeline parity suites are macOS-only and do not build on Linux, so they were not run.
