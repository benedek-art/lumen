# WS-03 White balance: report

**Verdict: BLOCKED after 3 build/verify rounds.** 17 of 19 spec lines pass. Line 6 (no new clipping) fails, and so does visual claim V2 as it was worded. Both come from the sRGB output stage, which this lane does not own (NEEDS §2). Your 300 K bar for Auto is met on 3 of 5 chart frames.

## For the owner

1. Temp/Tint now use Lightroom's numbers. Type the Kelvin of the real light and a grey card goes neutral (worst ΔE00 0.010, was 9.29). Tint now runs along Lightroom's green/magenta axis (0.0° off, was 38.8°).
2. Auto WB exists: a menu entry plus a button next to the eyedropper. It fixes a tungsten room shot on Daylight (94–96 % of the cast corrected) and doesn't grey out skin.
3. Auto is within 300 K of the chart on 1346, 967 and 983. It misses on 864 (−708 K) and on 3914 (−772 K, where the Linux decode itself is 9.7 ΔE off).
4. Extreme Tint (−150) now crushes shadows on saturated frames, by up to +18 pp. The sRGB output clips colours Lightroom-strength tint pushes out of gamut, and the fix is gamut compression in another lane.
5. CI at f3ade99: the macOS app bundle (with the Auto button) builds, and GPU parity, UI layout, Proof sweep and engine-linux all pass. The one red job, the Swift-surface checker, fails identically on the base commit.

## CI (f3ade99)

- **Passing:**
  - GPU parity
  - UI layout
  - Proof sweep
  - CI/app-bundle (macOS build of Lumen.app, Auto UI included)
  - CI/engine-linux
- **Still queued at 09:40 UTC:** CI/test-fast and CI/build-macos. On the round-2 code (1150d93), build-macos passed; test-fast was cancelled by the next push.
- **Red but pre-existing:** CI/fixtures-linux, step "Swift surface", fails with the same findings on base 8e2f3b7 (`python3 scripts/check-swift-surface.py`, run on both commits). The findings are CommandLine in main.swift, the Metrics/RecipeKeys inits, the `set(_:forKey:)` labels and Font in LumenType.swift. The CommandLine line number moved only because the usage header grew. Not caused by WS-03.

## Evidence (best three)

- `evidence/before_tint_axis_skin_tones.png` vs `evidence/after_tint_axis_skin_tones.png`: Tint −150…+150 used to go yellow→violet. Now it goes green→magenta, the Lightroom way.
- `evidence/after_auto_cast_recovery.png`: three columns, the wrong-preset frame, the Auto result and the true answer. Frames 1332 (−100 mired), 4213 (+100) and 1346 (−150); Auto lands within 0.3 mired of the truth.
- `evidence/after_auto_charts.png`: as-shot | Auto | chart-neutral on 3914, 864 and 967 (V3).

## Verdict per spec line (verifier round 3, VERIFY-R3.md)

| # | Claim | Measured | Before | Result |
|---|---|---|---|---|
| 1 | As-shot pair is a bit-exact identity | 8/8 frames identical | 8/8 | PASS |
| 2 | One convention for slider and as-shot | xy diff 0; round trip 4e-12 via `ColorTemperature.temperatureAndTint` | 0.102 | PASS with deviation: the SDK's own inverse (`DNGTemperature.temperatureAndTint`) is inexact by design (0.0326 mired) and stays pinned by DNGTemperatureTests |
| 3 | Kelvin accuracy, 500 pairs | ΔE00 max 0.010 | median 2.47, max 9.29 | PASS |
| 4 | Tint hue matches Adobe | 0.0° | 38.8° | PASS |
| 5 | Sweeps monotone | 16/16 | PASS | PASS |
| 6 | No new clipping on sweeps | +5.92 pp highlights (skin_tones 2000 K), +18.32 pp shadows (983 tint −150), 10 tiles | baseline | **FAIL, outside WS-03** (sRGB output gamut; NEEDS §2) |
| 7 | Eyedropper round trip | 0.0019 mired / 0.0047 tint | 39.8 / 11.6 | PASS |
| 8 | Magenta guard: no inversion | a-drop 0.0020, no negative channels | 0.0135 | PASS |
| 9 | Presets neutralise their own illuminant | ΔE00 ≤ 0.01 | 4.2–6.0 | PASS |
| 10 | Temp travel mired-spaced | unchanged, SliderScaleTests pass | — | PASS |
| 11 | GPU twin | no pipeline/kernel diff; WB reaches GPU as the CPU RenderPlan matrix | — | PASS (macOS gpu-parity on final push) |
| 12 | Auto API + `lumen-render autowb` | builds, JSON parses on 25/25 frames | — | PASS |
| 13 | Auto chart IN | ΔE00 1.15 / 1.83 / 1.75 / 9.72 / 1.26, mean 3.14 (≤ 3.20) | as-shot mean 3.57 | PASS (thin margin) |
| 14 | Auto chart OUT, do no harm | mean 3.61 (≤ 4.07) | — | PASS |
| 15 | Daylight frames stay put | 6929 −7.8 mired; 2545 0 | — | PASS |
| 16 | Skin safe | skin_tones 0/0; skin_only chroma kept 1.00 | — | PASS |
| 17 | Neutral → as-shot, deterministic, fast | 0.000; 1 result over 5 runs; 0.145 s | — | PASS |
| 18 | Auto UI in presetRow | menu item + button, all symbols verified | — | PASS on review; compile = macOS CI |
| 19 | Tests | LumenCoreTests 3060 run, 0 failures (base 3044, 0); ControlProofTests 6/6 | — | PASS |
| V1 | skin_tones −150 green, +150 magenta | yes | — | PASS |
| V2 | 2545 sky stays blue across tint | teal at −150, violet at +150 | — | **FAIL as worded**: Adobe-strength tint moves the sky that far. The claim was wrong; the render follows Lightroom |
| V3 | as-shot / Auto / chart-neutral | Auto moves toward chart-neutral on 864 and 967 | — | PASS |

Owner's bar, Auto vs chart-neutral (chart in frame): 1346 −173 K, 967 +76 K, 983 +214 K (met). 864 −708 K and 3914 −772 K / +15 tint (missed).

## What changed and why

- **Convention** (`ColorTemperature.chromaticity`, `temperatureAndTint`): target Temp/Tint now go through the DNG SDK mapping, the same one the as-shot pair already used. Before, the two used different curves, so "5500/+10" in Lumen was 5309/+17 in Lightroom.
- **Magenta guard** (`tintLimit(kelvin:asShot:)`, `clampedTint(…asShot:)`, `adaptation`, `effectiveTint`): the guard now depends on the as-shot. The old one checked a fixed 5500 K and missed inversions from cool as-shots.
- **Auto** (new `AutoWhiteBalance.swift`): an absolute search over 16,236 candidate lights in CAT16 log-chroma. For each candidate it scores near-neutral share, grey ladder (brightness span), whether the brightest 2 % come out neutral, and skin defined after correction. It blends near-neutral, white-patch and grey-world 1 : 0.1 : 0.05, falls back to as-shot when confidence is low, and never sees the chart rectangles.
- **UI**: Auto item in the WB menu and an Auto button beside the eyedropper (`BasicPanel.presetRow`). The magenta-bounded caption is reworded for when no magenta is available. Auto writes plain Temp/Tint, so the menu then reads Custom or a preset name.
- **App plumbing**: new functions only, `AppState.applyAutoWhiteBalance()` and `RenderCoordinator.solveAutoWhiteBalance(url:recipe:)`.
- **Tools and tests**:
  - `lumen-render autowb` and `tools/cast_recovery.py`.
  - New: WhiteBalanceConventionTests, AutoWhiteBalanceTests and guard-grid tests.

## Tests changed because they encoded the old convention

AccuracyProbe, ColorScience, EngineMathFixture (fixture regenerated by `scripts/gen-fixtures.py`, WB section only), three HuePreservation tests, and one TintGuard test. All of them pinned the old Lumen-only locus or the fixed-5500 K guard. The `raw.temp`/`raw.tint` proof records were re-recorded. Each reason is in BUILD-NOTES.md.

## What is left

- **Line 6 / V2**: compress the output gamut instead of clipping it (NEEDS §2). A per-channel (diagonal) adaptation would cut −150 clipping from 24 % to 2.5 % of pixels on 983, but it misses Lightroom's tint direction by 5.9°.
- **Auto, 20–50 mired casts**: only 35–55 % is corrected. That is deliberate: at that size a warm white surface or a blue cloth looks the same as a camera error, and full correction breaks line 14 (1346 chart-out ΔE 6.47). Setting `ambiguity.cut = 0` trades line 14 for recovery. Without the cut, 864 would land at −309 K.
- **Auto, no neutral in frame**: it returns as-shot (8 of 25 corpus frames), even under a large cast.
- **Defect found in round 3, not fixed**: on a synthetic ColorChecker at 2500–3000 K, a clipped white patch lets a bright yellow patch become the reference white, so confidence drops to 0 and Auto returns as-shot. White-patch selection should reject strongly chromatic candidates.
- **3914**: the as-shot from the Linux X-Trans decode is 9.7 ΔE off. Its chart greys are 3.4 % of luminance and the bark outscores them.
- **2000 K end**: crushes shadows (68 % on 3914). That happens downstream of WS-03 and is noted for the tone/output owners.
- **NEEDS**:
  - §1 WS-02: `neutralizing` should report the as-shot-aware tint (cosmetic).
  - §3: stale comment in AppleRawSource.

Full working: AUDIT.md, SPEC.md, BUILD-NOTES.md, VERIFY.md, VERIFY-R2.md, VERIFY-R3.md, NEEDS.md.
