# WS-03 White balance: verification report (verifier, round 2)

Branch `quality/ws-03-white-balance` at 66996aa. Base code: 8e2f3b7 (the spec commit). Round 1 was at
8c2f487. I formed every number below myself, from a clean worktree build, before reading BUILD-NOTES.md.

## Verdict: **FAIL**

Two items still fail. Both are unchanged from round 1, and the spec was not changed between rounds
(`git diff 8e2f3b7..HEAD -- docs/quality/lanes/WS-03/SPEC.md` is empty).

| Failing item | Why | Inside WS-03's control? |
|---|---|---|
| **Line 6** (no new clipping) | 10 tiles over the limit. Worst: +5.92 pp highlights (skin_tones 2000 K), +18.32 pp shadows (983 tint −150). These are the same tiles and numbers as round 1. | **No, not without failing line 4.** The crush comes from Adobe-strength tint (line 4 pins it) and from the 2000 K CAT16 lobes (N3), both clipped by the downstream display/gamut clamp (NEEDS §2). The spec owner has to choose between line 4 and line 6, or route gamut compression to its owning lane. |
| **V2** (sky never teal or purple) | The sky is teal at −150 and violet-purple at +150. | **No, as worded.** A green adaptation of blue sky is cyan under the Adobe tint axis that line 4 requires. The claim has to be restated. Separately, the evidence sheet is still 256-colour quantised, so the sky posterises in it. That part is inside WS-03's control. |

Every other line passes. Line 18 passes on code review only (not compilable on Linux).

The owner's original Auto bar (within 300 K and |Δtint| ≤ 8 of chart-neutral) is met on **3 of 5**
frames: 1346, 967 and 983. It is not met on 864 (−644 K) or 3914 (−742 K, +16.0 tint). This bar is not a
spec line. The spec restates it in mired (N1) and exempts 3914, and under that form 13c passes.

## Environment

- Clean worktree at HEAD (scratch, never committed). Its `Package.swift` drops LumenApp,
  LumenPipelineTests and LumenAppTests, because LumenApp does not compile with Swift 6.0.3 on Linux.
  That limitation is pre-existing on the base.
- `swift build --target LumenCore --target LumenRender` (debug) is clean, and so is
  `swift build -c release --product lumen-render`. Both were fresh `.build` directories. The only
  warnings are 2 in `Ingest/VerifiedCopy.swift`, which is not WS-03 code and is pre-existing.
- All measurements use that fresh release binary (`LUMEN_RENDER=…/wt/.build/release/lumen-render`).
- Tests: I ran the debug xctest bundle directly with every LumenCoreTests class named except
  ControlProofTests, because `swift test --filter` hits "Argument list too long". I ran
  ControlProofTests separately from a release build with `-enable-testing`.

| Run | Executed | Skipped | Failures |
|---|---|---|---|
| LumenCoreTests minus ControlProofTests (debug) | 3059 (3053 passed) | 6 | 0 |
| ControlProofTests (release, `-enable-testing`) | 6 | 0 | 0 |

The WS-03 suites all pass: WhiteBalanceConventionTests (7), TintGuardTests (14, including
`testNoInversionAcrossAsShotAndTargetGrid`), AutoWhiteBalanceTests (6),
MaskWhiteBalanceTests (15), WhiteBalancePresetNameTests (7), SliderScaleTests, EngineMathFixtureTests,
HuePreservationTests, ColorScienceTests and `EngineTests.testTheTempRowShowsTheNeutralTheRenderAdaptsFrom`.

## Per spec line

| # | Measured (round 2) | Threshold | Result |
|---|---|---|---|
| 1 | 8/8 bit-identical (`identity.py`). The `displayed` test passes. | 8/8 | **PASS** |
| 2 | WhiteBalanceConventionTests pass. Same deviation as round 1: the round trip is exact through `ColorTemperature.temperatureAndTint`. The literally named `DNGTemperature.temperatureAndTint` is the SDK's inexact port (0.03 mired), and it is pinned by its own tests. | 1e-9; 0.01 | **PASS with deviation** (outside WS-03: the SDK inverse is faithful by design) |
| 3 | 500 pairs: ΔE00 median 0.000, p90 0.000, max 0.010 | < 0.5 | **PASS** |
| 4 | 21 cases: max \|Δhue\| 0.0°, max \|C ratio − 1\| 0.000. At 6504/+9.77, +75 gives 325.7° and −75 gives 152.6°. | 3°, 0.10 | **PASS** |
| 5 | 16 sweeps monotone (2000 K excluded per N3) | 5e-4 | **PASS** |
| 6 | Worst +5.92 pp highlights, +18.32 pp shadows. 10 failing tiles, identical to round 1: skin 2000 K; 6929 2000 K; 3914 2000 K and 2500 K; 864 2000 K and tint −150/−100/−50; 983 tint −150; 2545 tint −150. | +0.5 / +1.0 pp | **FAIL** (see verdict) |
| 7 | `testTheEyedropperReturnsTheIlluminantsAdobeNumbers` passes | 0.1 mired / 0.3 tint | **PASS** |
| 8 | TintGuardTests pass, including the no-inversion grid and the clamp-free bands. | 0 neg; drop ≤ 0.003 | **PASS** |
| 9 | Presets exact. Largest ΔE00: Daylight 0.00, Cloudy 0.00, Shade 0.00, Tungsten 0.01, Fluorescent 0.00, Flash 0.00. PresetName tests pass. | < 0.5 | **PASS** |
| 10 | SliderScaleTests pass. `SliderDrag.swift` diff is empty. `BasicPanel.swift:227 scale: .reciprocal`. | as stated | **PASS** |
| 11 | `Sources/LumenPipeline` diff is empty. The grep finds comments only (`AppleRawSource.swift:46-50`). | as stated | **PASS** (macOS gpu-parity not observable here) |
| 12 | Builds. `autowb` JSON parses on all 25 corpus frames. The LumenRender diff is now `AutoWB.swift`, the dispatch case, and the usage text in `CLI.swift` and `main.swift`. The usage edits go beyond "only the dispatch case", but they are documentation the lead asked for, so I accept them. | builds; parses | **PASS** |
| 13 | IN ΔE00: 1346 1.05, 967 1.76, 983 1.55, 3914 9.63, 864 **1.15**. Mean **3.03**. Δmired/Δtint vs chart-neutral: 1346 +3.9/+1.5, 967 −2.9/−4.2, 983 −7.4/+2.2, 864 +5.6/+0.8. | (a); (b) ≤ 3.20; (c) 12/8 | **PASS** (13b margin is now 0.17, up from 0.08) |
| 14 | OUT ΔE00: 1.71, 2.18, 1.87, 9.59, 0.73. Mean 3.22. | each ≤ as-shot + 2.5; mean ≤ 4.06 | **PASS** |
| 15 | 6929: −5.3 mired / −1.4 tint. 2545: +0.6 / −0.5. | 15 / 10 | **PASS** |
| 16 | skin_tones: +0.39 / +0.04. skin_only: 0.0 / 0.0, chroma kept 1.00, max \|Δhue\| 0.0°. | as stated | **PASS** |
| 17 | flat_grey 0.000 / 0.000. 5 runs give 1 distinct result. Median 0.081 s. | 0.1; 1; 0.25 s | **PASS** |
| 18 | The app diff is unchanged since round 1 except `boundedTintCaption`. All symbols re-checked (below). | grep; scope; macOS CI | **PASS on review**, compile unverified |
| 19 | All LumenCoreTests and ControlProofTests pass (table above). | pass | **PASS** |

## Owner's original bar: Auto (chart IN) vs chart-neutral, within 300 K and |Δtint| ≤ 8

| Frame | Auto | Chart-neutral | ΔK | Δtint | Result | As-shot ΔK / Δtint | Confidence |
|---|---|---|---|---|---|---|---|
| 1346 | 5339.7/−6.03 | 5453.9/−7.57 | −114 | +1.53 | PASS | −28 / +3.65 | 0.70 |
| 967 | 4805.5/+11.36 | 4740.3/+15.51 | +65 | −4.16 | PASS | +100 / −4.58 | 0.67 |
| 983 | 5135.5/+15.39 | 4947.3/+13.15 | +188 | +2.24 | PASS | +149 / +2.38 | 0.89 |
| 3914 | 4713.6/+48.15 | 5456.0/+32.17 | **−742** | **+15.98** | FAIL | −748 / +15.99 | 0.12 |
| 864 | 10379.1/+11.99 | 11023.5/+11.16 | **−644** | +0.82 | FAIL | −1659 / +5.28 | 0.86 |

On 1346 and 983, Auto is slightly further from chart-neutral in Kelvin than as-shot is. Its ΔE00 is still
within 13a.

## Visual claims

- **V1, PASS.** I regenerated the sheet with the spec command, and it is byte-identical to the committed
  one. −150 reads green, not olive. +150 reads magenta-pink, not violet (before it was blue-violet).
  ±75 skin still reads as skin. −75 is olive-khaki, which is the borderline case.
- **V2, FAIL as worded.** I regenerated it unquantised at 512 px. The lawn is green at −150 (before it was
  yellow-olive), so that half passes. The sky is teal at −150 and blue-teal at −75. At +75 it is
  blue-violet, and at +150 violet-purple. It is better than before at both ends, but "never teal or
  purple" is not met. The committed `after_tint_2545_gx85.png` is still palette-quantised and visibly
  posterises the sky.
- **V3, PASS.** I regenerated it. Committed tiles agree with mine to ≤ 1.5 codes per tile mean; the
  committed sheet is ¾ size and quantised. I cropped at 100 %:
  - **864:** as-shot greys are visibly blue. Auto greys are nearly indistinguishable from
    chart-neutral, a hair cooler.
  - **3914:** Auto ≈ as-shot, so it is no bluer or more magenta. It also does not correct the cast.
  - **967:** a small move toward neutral.
  - Nothing in the Auto column looks less natural than as-shot.
- The other evidence files (`before_*`) were opened. They are before-state sheets consistent with the
  audit.

## Break attempts on what changed

### Auto on all 25 corpus frames

Auto is plausible everywhere. The largest moves from as-shot:

| Frame | Move |
|---|---|
| 864 | −10.4 mired (+1014 K), −4.5 tint, conf 0.86 |
| 7301 | −4.3 mired, −8.0 tint |
| 4213 | −7.7 mired (+347 K) |
| 1332 | −5.5 mired |

- 8 frames return as-shot (confidence ≤ 0.01).
- Runtime is 0.076-0.106 s per frame.
- I rendered as-shot against Auto for 864, 7301 and 4213 at 640 px. All three move toward neutral:
  - 864: whole-frame OKLab b −0.0133 → −0.0077 (blue cast removed).
  - 7301: a +0.0024 → −0.0008, b −0.0131 → −0.0092 (stone a touch less pink).
  - 4213: b −0.0019 → +0.0017 (overcast, slightly warmer).
- None looks unnatural.

### Skin

- skin_tones and skin_only pass (line 16).
- With a synthetic cast, skin_tones stays near as-shot for every cast except 12000 K. There it moves
  +12 mired of the 70 needed, at confidence 0.77. That is a partial correction in the right direction,
  not a greying.

### Auto falls off a cliff past about 25 mired (new finding; not a spec line)

On the synthetic ColorChecker, which has six clean greys, I created a known cast with the inverse Adobe
matrix from as-shot 6504/+9.77.

| Cast | Result |
|---|---|
| ±5…±20 mired | 67-106 % of the move recovered, conf 0.70-0.91 |
| −30 / −40 mired (light 8080 / 8791 K) | **0 %**, conf 0.00 |
| +30 / +40 mired (light 5442 / 5161 K) | **5 % / 0 %** |
| Real lights 3000/0, 4000/+10, 5000/+5, 12000/+10, 5500/+30 | **0 %**, returns as-shot exactly |
| Tint ±10/±20 | 73-94 % recovered |

- The cause is the near-neutral window (`windowStart` 0.15 ln-chroma around as-shot) together with the
  prior. Greys outside that window are invisible to Auto, so confidence drops to 0.
- So Auto refines a camera's estimate. It cannot rescue a frame shot on the wrong preset (tungsten light
  on Daylight WB), which is the classic case Lightroom's Auto fixes.
- The response is also non-monotone: a 20-mired cast is corrected by 67 %, and a 30-mired cast by 5 %.
- This is inside WS-03's control (tuning in `AutoWhiteBalance`), but no spec line tests it. Widening the
  window would put lines 14 and 16 at risk; BUILD-NOTES' 1346 and 864 OUT cluster analysis gives the
  reason. I report it for the owner. It does not change the verdict.

### Caption code (`boundedTintCaption`)

The caption calls `WhiteBalanceEngine(asShotKelvin:asShotTint:targetKelvin:targetTint:)` (default
`space`), then `.effectiveTint`. That is `ColorTemperature.clampedTint(kelvin:tint:asShot:)`, which is
exactly `adaptation`'s tint. It does not call `tintLimit` directly. All signatures match
(`ColorSpaces.swift:497/519`, `WhiteBalanceEngine.swift:87`).

- `pictureBound` returns a value in [−300, 300], so `Int(effective.rounded())` cannot trap. A NaN
  fails the `<` guard and returns nil.
- On identity, `effectiveTint` returns `target.tint`, so there is no caption.
- With value ≤ 0, the text "No magenta is available at N K from this file's as-shot neutral — the render
  holds tint at −13 and stops there" is true: any slider value above the bound renders at the bound.
  That includes 0, and it includes a green slider value above a more negative bound.
- With value > 0, the text is unchanged in meaning.
- Nits:
  - The negative number prints with an ASCII hyphen ("-13"), not the "−" the comments use.
  - "and stops there" is redundant.
  - On a 15000 K as-shot at 2000 K, the slider at 0 renders as −13 (slightly green). The caption says
    this, so it is honest.

### LumenApp symbols, all present

- `primarySelection`, `recipe(for:)`, `statusMessage`, `renderCoordinator`.
- `updateRecipe(coalescingKey:label:targets:_:)` (AppState:4204).
- `primaryAsShotNeutral` (BasicPanel `asShotNeutral`).
- `RenderCoordinator.source(for:)` (private, same actor).
- `ImageSource.nativeLongEdge: Double`, `decode(recipe:draft:scaleFactor:)`, `asShotTemperature`,
  `asShotTint`.
- `PipelineRenderer.buffer(from: CIImage, context:)` (PipelineRenderer:3002).
- `CIFormat.RGBAh`, `CGColorSpace.extendedLinearITUR_2020`.
- `.lumenGlyphBody`, `Lumen.controlBackground`, `Lumen.primaryText`, `Lumen.radiusChip`.
- `LumenMenuItem(title:symbol:detail:isSelected:isEnabled:action)`.

### `lumen-render` usage

- Running with no arguments prints the `autowb` line. A missing `--input` and a malformed `--exclude`
  give clear errors.
- The usage line does not say that `--as-shot-kelvin/--as-shot-tint` matter for `autowb`. The "shared"
  line covers it, and the default is 5500/0. Minor.

## Builder's claims compared with mine

- BUILD-NOTES round-2 numbers match mine to the printed precision:
  - line 13: 1.05/1.76/1.55/9.63/1.15, mean 3.03;
  - lines 14-17;
  - the owner-bar table: −114/+66/+188/−645/−742 K;
  - the 25-frame movers.
- The builder states plainly that the 300 K bar fails on 864 and 3914. I agree with the stated reason for
  864: the paper and step clusters average out at about 10 600 K at best. I did not re-derive 3914's
  cluster analysis.
- **Not stated by the builder:** the ≈25-mired cliff above.

## What a pass needs

1. **Line 6 and V2** need a spec decision, not a build round:
   - Line 6: exempt tint ≤ −50 and 2000 K, or hand gamut compression to its owning lane (NEEDS §2).
   - V2: restate it as "sky turns cyan at −150 and violet at +150, as Adobe's model does".
2. **Inside WS-03:** re-export V2 evidence unquantised, for example a crop under 400 KB.
3. **Owner decision:** accept Auto as a refine-only estimator (3/5 on the 300 K bar), or ask for
   large-cast recovery. The second option would need new spec lines and would put lines 14 and 16 at risk.
