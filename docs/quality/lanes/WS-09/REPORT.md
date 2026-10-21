# WS-09 Auto Tone (with WS-10 Match Total Exposures): report

Lane T5, branch `quality/t5-auto-tone`. WS-10 has its own `../WS-10/REPORT.md`; this file is the
lane summary for both.

## For the owner

1. Auto now predicts its own output and solves each slider to a target. 0/23 normal frames hit a sensible key before, 20/20 now (median 0.41-0.43).
2. Low-key frames stay low-key, and Auto no longer blows highlights: the jacket stays black, and clipping added by Auto is ≤ 0.47 % on every frame (old Auto added up to 1.34 %).
3. Look at `evidence/pair_6929_6933_old_vs_new.png`, `evidence/lowkey_2348_1192_old_vs_new.png` and `../WS-10/evidence/match_6929_6933_exif_vs_measured.png`.
4. Match Total Exposures now measures the shared view and falls back to EXIF only when frames don't overlap. EXIF alone left your A7 IV pair 0.30 EV apart; the measured match leaves 0.03 EV. Pans and odd zoom ratios are only sometimes found: that line is BLOCKED, but a miss falls back to EXIF and is never wrong.
5. Judge by eye: Contrast +20 / Whites +60 / Blacks −60 are common (Whites is weak, see NEEDS.md), and 1840 (dusk?) becomes daylight.

## Verdict per spec line

Measured with the commands in `SPEC.md` on all 25 corpus frames.

| Line | Result | Default look | Punchy | Linear | Old Auto (default) |
|---|---|---|---|---|---|
| S1 key 0.38-0.46 where protection did not bind, none above 0.46 | PASS | 20/20, max 0.425 | 15/15 | 10/10 | 0/23, medians 0.31-0.35 |
| S2 low-key (2348, 967) median ≤ 0.30 | PASS | 0.250 | 0.164 | 0.225 | 0.345 |
| S3 clip ≤ max(0.5 %, before + 0.5 %) | PASS | worst +0.47 % | +0.43 % | +0.47 % | +1.34 % (1192, 967 fail) |
| S4 crush, same rule | PASS | worst +0.11 % | +0.19 % | +0.36 % | +0.04 % |
| S5a p99 ≥ 0.85 on ≥ 18/25, every short frame excused | PASS | 18/25 | 19/25 | N/A (identity clip) | 7/25 |
| S5b p1 ≤ 0.05 on ≥ 21/25 | PASS | 21/25 | 23/25 | N/A | 21/25 |
| S6 6929/6933 Δmedian ≤ 0.01, Δmean ≤ 0.02 | PASS | 0.000 / 0.014 | 0.002 / 0.012 | 0.001 / 0.015 | 0.030 / 0.033 |
| S7 Vibrance ≤ 15, ≥ 5 unless the crush loop lowered it | PASS | 5..15 | 5..15 | 0..15 | 0 |
| S8 predicted vs rendered median ≤ 0.02 | PASS | max 0.012 | 0.018 | 0.004 | n/a |
| S9 unit tests | PASS | `AutoToneQualityTests` 11/11, `EngineTests` 62/62, `ExposureMatch*` 18/18 | | | |
| S10 no render change | PASS | no diff under `Sources/LumenPipeline`, `RenderPlan`, `ReferenceRenderer` | | | |
| S11 other looks | PASS | see the Punchy and Linear columns | | | |
| S12 nothing out of nothing, rescue the dark | PASS | all-black and all-blown get Tone(); 1840, 7881, 4213 and 6929 darkened 2.5-4 EV all get Exposure +3.4..+4 | | | |

The full `LumenCoreTests` suite (3,055 tests, `--parallel --skip ControlProofTests`, as CI runs it) passed
at the round-1 commit with Swift 6.1.2. The round-2 suite runs are listed under Verification below.

## What changed and why

**The old Auto never looked at its output.** `suggest` set each slider from a threshold on the
input histogram. Highlights fired only above +3 EV, and Whites/Blacks only on a "flat" scene. On the
corpus that put every median at 0.31-0.35 encoded, and 18/25 frames finished with p99 short of 0.85.
It also had no idea of low key: it lifted the black jacket to grey and blew the stained glass.

**New `AutoTone.auto(from:render:)`** (ToneEngine.swift):
- *Predictor.* It evaluates the real `ToneEngine` and `DisplayTransform` at the frame's own
  percentiles, so each candidate's rendered result is known before it is applied (S8: within 0.012
  of the render).
- *Coordinate descent, 4 passes.* The sliders are solved in turn:
  - Exposure places the median at 0.42 (faces at 0.50).
  - Whites put the brightest channel's 99.8th percentile at 0.98 (just clip).
  - Highlights acts only when the brightest 1 % would still crowd white, so it is protection
    rather than compression and does not fight Whites.
  - Shadows lifts the 4th percentile to 0.06 if it sits below that.
  - Blacks puts the darkest channel's 0.2nd percentile at code 1.
  - Contrast (≤ +20, pivoted on the subject) is used only when Whites or Blacks runs out of travel.
- *Highlight headroom.* Exposure alone may not push the brightest-channel 98th percentile past 0.93
  plus 0.5 EV. This is what keeps low-key frames low-key.
- *Closed loop* (`AutoTone.refine`). The prediction cannot see the gamut map, which clips a
  saturated channel while luminance is still well below white (1192's glass: 1.8 % clipped with none
  predicted). So the app renders the 512-px proxy once more with the answer, at most 3 times. While
  clip or crush exceeds the probe's own level + 0.5 %, Exposure comes down, Blacks comes up, or
  Vibrance comes down.
- *Vibrance* is +5..+15 from the proxy's mean OKLab chroma: more on muted frames, less on saturated
  ones. Saturation is never touched.
- *Guards.* On the Linear look (identity clip) Auto writes no Whites, Blacks or Contrast. A frame
  whose brightest 1 % renders within 5 codes of black, or whose darkest 1 % renders within 5 codes
  of white, is left alone. Underexposed frames with real content are still rescued.
- *Statistics.* The proxy read (`AutoTone.statistics(encodedSRGB:)`) now also returns
  brightest/darkest-channel histograms, mean chroma and clip/crush fractions. The app and
  `lumen-render` share the one loop.

**App** (`AppStateActions`):
- The probe zeroes tone and Vibrance, then calls `auto`, then the refine loop.
- `applyAutoToneSuggestions` lands `AutoTone.Result` (tone + Vibrance) as one undo step. The
  `[URL: Tone]` overload is kept for existing tests.
- The pixel read moved into LumenCore, where it is tested.
- The Auto button help text now mentions Vibrance.

**Tooling.**
- `lumen-render auto` runs the app's exact path headless. `--legacy` gives the old heuristic for
  comparison.
- `tools/auto_corpus.py` writes the sheets and the table; `tools/spec_check.py` evaluates S1-S8.

**Existing tests.** None loosened. `suggest(from:)` is kept unchanged, documented as legacy, and its
`EngineTests` still pass.

## Verification

- Round 1: the verifier returned FAIL.
  - WS-09 passed on the default look but crushed blacks under Linear (S4 fail on 6 frames).
  - Degenerate frames got wild values (an all-black frame got Exposure +4, Whites +60).
  - Vibrance sat at +15 on 24/25 frames.
  - WS-10 measured offsets for 4 unrelated corpus pairs (worst 1.8 EV).
- Round 2 fixes:
  - darkest-channel Blacks target plus a crush loop;
  - Linear guard;
  - degenerate guard;
  - Vibrance rescaled to the corpus chroma range (now 5..15 across frames);
  - Match switched to a quadrant-minimum gradient correlation.
- Round 2: the verifier returned FAIL, narrowly. Every spec line passed and all round-1 defects
  were fixed, but:
  - The degenerate guard (on the median) turned Auto off on real frames 3 EV under.
  - Match missed pans over about 15 % and in-between zooms.
  - Match took 0.5 s per frame.
  - `lumen-render match` ignored `--set`.
- Round 3 fixes:
  - the guard now reads the extremes;
  - zoom × window search with a minimum window size, threshold 0.65;
  - the median is taken only at the winning placement (1.7 s per pair, renders included);
  - `match` honours `--set`.
- **Round 3: FAIL on WS-10 M7 only.** Every WS-09 line passed on all three looks, and the round-2
  defects were fixed. M7 (Match recall on pans and in-between zooms) is **BLOCKED**: details and next
  step in `../WS-10/REPORT.md`.
- Full `LumenCoreTests` (3,062 tests, Swift 6.1.2, `--parallel --skip ControlProofTests`) passed at
  round 3 with 0 failures.
- Residual round-3 notes for a human:
  - The all-black guard judges the frame as the look renders it, so a raw 4 EV under is rescued on
    the default look but left alone on Punchy (its p99 renders under code 5). Linear leaves an
    unclipped float frame 3.5 EV over alone.
  - Very deep rescues (4-5 EV under) land darker than Auto predicts: 1840 at −4 EV renders a median
    of 0.078 against 0.138 predicted.

## What I could not fix / human judgement

- **Whites reach** (NEEDS.md #1). Whites +100 moves white only 1.5 EV. On flat frames Auto ends at
  Whites +60 plus Contrast +20 and is still short of just-clip on 6 frames. The fix belongs to WS-05.
- **Busy slider values.** Contrast +20 on 17/25, Whites +60 on 15/25, Blacks −60 on 14/25. On screen
  the renders do not look over-processed to me (no halos, no banding at 100 %). A photographer may
  still read the numbers as heavy-handed.
- **Specific frames.** 1840 reads as dusk and Auto makes it daylight (+2.89 EV). 4213's overcast sky
  goes near white. Lightroom does both too, but a human should judge.
- **Absolute key.** 0.42 is my call ("a touch under mid-grey"). No Lightroom reference exports
  exist in `corpus/lightroom/`, so nothing compared Auto against LR's own Auto.
- **Auto WB.** WS-03 has no `AutoWhiteBalance` yet (spec only on `origin/quality/ws-03-white-balance`),
  so Auto Tone does not call it.
- **Not checked here.** LumenApp cannot compile on Linux. The app diff was type-checked through a
  Linux stand-in by the verifier; macOS CI is the real check.

## Evidence (256-colour PNGs to stay under 400 KB; full-size via the tools)

- `evidence/pair_6929_6933_old_vs_new.png`: tone at zero, old Auto, new Auto. **Best #1.**
- `evidence/lowkey_2348_1192_old_vs_new.png`: low-key jacket and stained glass. **Best #2.**
- `evidence/flat_1840_4213_old_vs_new.png`: flat and dusk frames.
- `evidence/corpus_new_auto_before_after.png` and `corpus_old_auto_before_after.png`: all 25 frames.
- `../WS-10/evidence/match_6929_6933_exif_vs_measured.png`. **Best #3.**
