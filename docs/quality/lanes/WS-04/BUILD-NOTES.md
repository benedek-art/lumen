# WS-04 build notes (builder scratch; fold into REPORT.md)

Measured on Linux, debug build, `.build/x86_64-unknown-linux-gnu/debug/LumenPackageTests.xctest
LumenCoreTests.ExposureQualityTests` (14 tests, 0 failures). Each test prints a `WS-04 Ln …` line;
the numbers below are copied from that log (`/tmp/claude-0/ws04-tests.log`).

## Code changes

| file | owned function | change |
|---|---|---|
| `Sources/LumenCore/Engine/ToneEngine.swift` | `ToneEngine.exposureGain` | `Num.clamp` → `Num.clampFinite(…, fallback: 0)`: NaN Exposure is gain 1, ±inf pin to ±10. New `static let exposureLimit = 10` (equals the slider hard range). Finite values unchanged bit for bit (`clampFinite` is `clamp` for non-NaN). |
| `Sources/LumenCore/Engine/WhiteBalanceEngine.swift` | `LinearStage` | `public static let outputLimit = 65504`. `apply` returns its input when `isIdentity`, else the matrix product clamped per channel to ±65504 (NaN passes through). `isIdentity` is now a stored `let` computed once in `init` (same 1e-12 test). |
| `Sources/LumenPipeline/RenderGraph.swift` | `RG.applyMatrix` | after `CIColorMatrix`, a `CIColorClamp` with min (−65504 ×3, 0) and max (65504 ×3, 1) via new `RG.limitedToHalfFloat`. Identity skip unchanged. macOS-only; not compiled here. |
| RP `---- S6` block, `BasicPanel` Exposure literal | — | no change needed (literal already −5…5 / −10…10 / 0 / 0.01). |

### Why the GPU clamp is in `applyMatrix` itself, not an S6-only path

`applyMatrix` has 17 callers (S6 at RG:210; finishScale, CreativeLUT display tap ×2, gamut
warning ×3, denoise rotation/broadcast ×5, S7 gain scale, dehaze ×2, local exposure, halation,
fallback tone). An S6-only function or parameter would need the S6 call line in
`RG.colorStageInput` changed, and that line is WS-01's (stage-chain rule 1). The clamp is
behaviour-neutral for every other caller:

- Inside ±65504 it passes values bit for bit. Values outside it cannot survive the main RGBAh
  context's store anyway (they become ±inf).
- In RGBAf contexts, only two callers can exceed it: the gamut gate (×4096) and dehaze's
  1/airlight normalization. Both are clamped to [0, 1] right after, where 65504 and anything
  larger read the same.
- Alpha leaves the matrix as the input alpha (`aVector` = (0, 0, 0, 1)), which is already in
  [0, 1], so the alpha clamp is the identity too.

Cost: one more fused per-pixel op where the matrix is not the identity.

## Per-line results

| # | Claim | Threshold | Measured | Verdict |
|---|---|---|---|---|
| 1 | S6 matrix = 2^EV·M(0) | ≤ 1e-15 | max rel err **0.0** (9 EV × 3 WB × 2 PL) | PASS |
| 2 | `LinearStage.apply` exact 2^EV, signs kept | ≤ 1e-12 | max rel err **0.0** over 4686 channels; negatives kept | PASS |
| 3 | render(R+EV k, x) == render(R, 2^k x), 11 recipes | ≤ 1e-9 | **0.0** on every recipe | PASS |
| 4 | EV 0 identity (buffers + CLI `cmp`) | bit-equal | gains 1 for 0 and −0; `linear.isIdentity` true; **0** differing floats; CLI 6929 @1024: no key / `=0` / `=-0.0` PNGs `cmp` identical (release build with this change) | PASS (V re-runs CLI) |
| 5 | grey @ EV 0 | 117.65 ± 0.5 | **117.646** | PASS |
| 6 | LUT33 ladder −3…+3; equality | ±0.5; ≤ 1e-9 | 20.32, 41.29, 72.72, 117.65, 168.74, 207.17, 234.51; equality diff **0.0** | PASS |
| 6a | exact ladder | ±0.5 | 20.32, 39.44, 70.41, 117.65, 168.58, 207.45, 234.51 | PASS |
| 7 | monotone at 0.01 EV | 0 falls | LUT33 **0**, exact **0** | PASS |
| 8 | max step per 0.01 EV | 0.70 / 0.62 | LUT33 **0.636** (scene 0.18 @ EV 0.01), exact **0.570** (scene 4 @ EV −4.47) | PASS |
| 9 | +0.01 EV moves grey | ≥ 0.3 | LUT33 **0.636**, exact **0.570** | PASS |
| 10 | hard clamp ±10 | exact | 10/11/12/1e6 → 1024; −10/−12/−1e6 → 1/1024; renders ±12 bit-equal ±10 | PASS |
| 11 | slider literal | source read | `range: -5...5, hardRange: -10...10, defaultValue: 0, step: 0.01` (BasicPanel.swift:466-469); equals `ToneEngine.exposureLimit` = 10 | PASS (V reads) |
| 12 | non-finite Exposure | finite; bit-equal EV 0; 0 NaN | NaN → 1, +inf → 1024, −inf → 1/1024; NaN render bit-equal EV 0; **0** NaN pixels | PASS |
| 13 | S6 clamp ±65504, CPU + GPU | values listed | apply(64, 1e3, 1e4) @ +10 = (65504, 65504, 65504); apply(−1e4, −1e3, −64) = −65504 ×3; apply(0.18) = 184.32 = 0.18·1024 exactly; finite for ±1e30; in-range `displayToWorking` bit-equal to bare matrix; GPU `CIColorClamp` in `applyMatrix` | PASS (CPU); GPU by code reading, macOS CI |
| 14 | RR finite + white at +10 | finite; neutral ≥ 254.5 | all channels finite; min neutral code **255.0** | PASS |
| 15 | N-1 in NEEDS.md | entry naming the line | `NEEDS.md` N-1: ReferenceRenderer.swift:68 `image.map { matrix.apply($0) }` → `plan.linear.apply` | PASS |
| 16 | GPU parity (macOS) | ≤ 1 fp16 ulp; 0 non-finite | `Tests/LumenPipelineTests/ExposureGPUParityTests.swift` written (`#if os(macOS)`); not runnable on Linux | PENDING macOS CI |
| 17 | existing suites | 0 new failures | Linux, debug: PlanTableCacheTests 27/0, EngineTests 62/0, AccuracyProbeTests 12/0, RobustnessTests 40/0, ColorScienceTests 61/0, MaskingTests 25/0, MaskWhiteBalanceTests 15/0, CreativeLUTTests 17/0, AsShotNeutralSanitationTests 8/0, EDRPreviewTests 13/0, EngineIntegrationTests 63/0, LookRenderPresetTests 8/0, MaskReferenceIdentityTests 8/0, PlanKeyMemoTests 3/0, ScaleHonestyTests 8/0, SliderEvidenceTests 7/0, SpotRetouchTests 16/0, DevelopPresetTests 19/0, ResetSemanticsTests 19/0 (tests/failures). Not completed: ControlProofTests (killed by my 1200 s timeout) and ProofSmokeTests (no summary line printed). | PASS for these; ControlProof/ProofSmoke and the full LumenCoreTests run are V's |

No existing test was changed.
