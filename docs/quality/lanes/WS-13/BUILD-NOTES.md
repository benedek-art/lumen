# WS-13 build notes: round 2 (commit 5a1b43d, on top of 44ab5e1)

Round 1 (mid-grey 0.25) is superseded. The lead set display mid-grey back to 0.18 because a lift under the +5 EV white anchor broke four highlight-authority floors. Density waits for WS-05.

All measurements below use release `lumen-render` built from 5a1b43d. Full output is in `build/after_r2.txt` and `build/corpus_r2.txt`.

## What the transform does now
- **Mid-grey split.** `sceneMidGrey` = `displayMidGrey` = 0.18. The split is kept so a later lift is one constant. `blackTargetRange` = `displayMidGrey`·50 = 0…9. The engine clamp, RecipeKeys and RecipeLook read it, and LookPanel uses the literal `0...9` that its precision test parses.
- **Rotation.** The outset undoes the inset rotation in full; `purityRestore` acts on attenuation only. Values: 0.4 (base value), Punchy 0.6. The inset is unchanged.
- **Hue-stable branch.**
  - It is taken in the output basis.
  - The path to white bleaches toward the grey of its level at constant OKLab hue, keyed on luminance:
    - onset +0.8 EV, `pathToWhite` 1.2;
    - Punchy and Film Base 1.5;
    - L walks quadratically;
    - the out-of-gamut residual is carried through.
  - Per-channel character (huePreservation < 100) hands over by half the shoulder.
- **Colour.** Colour comes from `chromaGain`, a constant-hue OKLab gain that tapers past C 0.12. Values: Neutral 1.5, Soft 1.4, Punchy 1.55, Film Base 1.45.
- **Skew mapping.** The gaining side spans min(½, cap), the losing side spans −1. This change and the black range are the only ones left in `gen-fixtures.py` / `enginemath.json`. The fixture differs from base in 2 values.
- **Out of lane.** FilmLab and ToneEngine differ from base only by the rename. No GPU kernel reimplements any of this: the finish table bakes `apply`.

## Spec lines (N/S/P/F)
| # | Measured | Verdict |
|---|---|---|
| 1.1, 1.4, 1.5, 1.7, 1.9, 1.10 | base density (code 118) | DEFERRED (with WS-05 anchor; round-1 numbers kept below) |
| 1.2, 1.3, 1.6, 1.8 | pivot tests unedited pass; anchors 1/255; minstep 0; Linear a7804edbac | PASS |
| 2.1/2.2 | anchor +3 sensor white ≥240 and rolls off (unit, mid 0.18); rolloff test has anchor 3/3.5 cases | PASS |
| 3.1 | skies max 3.5/2.8/3.4/3.3 (≤3); exact unit test ≤3 | FAIL N/P/F by ≤0.5° (restore 0.4 residue + 8-bit; it was 1e-12 at restore 1, see ceilings below) |
| 3.2 | LED 5.7/5.6/5.2/8.3 (≤15) | PASS |
| 3.3 | 983 ≤3.3 (P@0 3.3); 1840 up to +4.6 at +0.3 (33³ table; base 8.7) | FAIL |
| 3.4 | out-of-sRGB 75 %-max probes: max 7.5 (150hi) | FAIL (sRGB clip downstream; base passed only by being desaturated) |
| 3.5 | finish-table tests unedited | PASS |
| 3.6/3.7/3.8/3.9 | exact unit tests (N/S/P ≤5°/6°, chroma non-increasing ≥+1 EV, ≤0.02 at anchor, hue-fold p99.9 <2°) | PASS |
| 4.1 | N 1.124 | PASS |
| 4.2 | S 1.059 < N 1.124 < P 1.185 (F 1.082) | PASS |
| 4.3 | +4 EV N .045/.067, S .045/.066, P .031/.047, F .027/.041; +5 ≤.003/.007 (base ≥ .034/.076, +.005) | PASS |
| 4.4 | p99.9 ≤.0043, max ≤.021 | PASS |
| 4.5 | MST2-9 3.0/3.2/1.6/3.7 | PASS |
| 5.1/5.2 | −4 EV 5→11, +2 EV 203→227, every step ≥1, monotone; skew 0 hash = default | PASS |
| 6.1/6.2 | keys 0…9 = live = UI; no identical pair inside 0…9 (the checker's 9…15 group is outside the range) | PASS |
| 7.1/7.2 | all OK; 5 distinct; slope 1.156 < 1.404 < 1.866 | PASS |
| 8.1/8.2 | build clean; Swift 6.1.2 suite 3055/3055 | PASS |
| 8.4 | 144 records re-recorded. ControlProofTests: 5/6 green, **primaries.gPurity 39.7 < floor 44** | FAIL (1 floor) |

## Ceilings (lead item 3): root causes and fixes
- **grade.blending**
  - Hand-back scales with how much purity saturated colours keep: restore 1 gave 16–17 (pinned 13.78 +5 % = 14.47), restore 0.4 gives 13.0.
  - Fix: restore 0.4, with colour from a gain that tapers on saturated colours. Now 14.00.
- **primaries.bHue and Colour Balance sat/chroma**
  - The max-channel walk in the bleach (it rescaled a bleached colour's peak) made them hand back. Removing it: cb ≈0–2.
  - bHue then traced to the linear L walk. Quadratic L gives 4.14 (pinned 11.96).
- **primaries.gPurity authority (open)**
  - It is 53 with the bleach off and 39.7 with it on. The luminance-keyed bleach takes chroma from the bright chart greens.
  - A later onset (+1.5 EV, power 2) restores ~45, but breaks SPEC 3.8: chroma rises ~5 % between +1 EV and the onset.
  - Tried and rejected:
    - constant-chroma "hold" (gPurity 33.9);
    - squared L alone (39.7).
  - Lead decision: relax 3.8's "from +1 EV" to "from the onset", or the owner re-measures the floor.

## Tests changed (vs base)
Each entry is a rename or a strengthening:
- **Pure renames to the split constants:** EngineMathFixtureTests, EngineTests, FilmLabHDRMidGreyTests, LookRenderPresetTests.
- **DisplayTransformShoulderRolloffTests:** the SDR mirror moves to the new skew mapping, and the rolloff test gains anchor 3 / 3.5 cases.
- **ProofRegistry:** render.black high reads `blackTargetRange` (still 9).
- **New:** DisplayTransformWS13Tests (11 tests).

EngineIntegrationTests and LookPanelPrecisionTests are identical to base.

## For NEEDS.md
- **WS-05:** white anchor ~+3 EV, then lift `displayMidGrey` to 0.25. Round 1 measured code 137, shadows 24/47/83, corpus medians +0.3 EV (88.8/120.9/75.1/76.3). The proof floors fell at a +5 anchor.
- **Spec model:** `model/curve.py` slope term uses 0.18 (makes 1.9's bracket unreachable at slope 1.5).
- **WS-12:** the 33³ table gives ±3–5° hue on 1840's sky (65³ ≤0.6°). Add an sRGB/P3 output gamut map before encode (3.4).
- **Primaries owner:** gPurity floor vs the path to white (above).
- **Auto:** reads `transform.tone`; unchanged at 0.18.
