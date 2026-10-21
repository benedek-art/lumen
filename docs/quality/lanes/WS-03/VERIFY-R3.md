# WS-03 White balance: verification report (verifier, round 3, final)

Branch `quality/ws-03-white-balance` at 056d188. The spec is unchanged since 8e2f3b7. Since round 2
(1150d93), the code diff touches only `AutoWhiteBalance.swift` (a rewrite) and `AutoWhiteBalanceTests.swift`
(one new test). I formed every number below myself before reading BUILD-NOTES.md. Fresh scratch worktree
at HEAD. Its `Package.swift` drops LumenApp, LumenPipelineTests and LumenAppTests, because LumenApp does
not build on Linux; that is pre-existing and was never committed. Measurements used a fresh release
`lumen-render`.

## Verdict: **FAIL**

The same two items fail as in rounds 1 and 2. Both need a spec decision; neither is a build defect.
Every other line passes. Auto now recovers large casts when it finds a credible neutral (details below).

| Failing item | Measured | Inside WS-03's control? |
|---|---|---|
| **Line 6** (no new clipping) | The same 10 tiles as rounds 1 and 2. Worst: +5.92 pp highlights (skin_tones at 2000 K) and +18.32 pp shadows (983 at tint −150). | **No.** It comes from Adobe-strength tint (line 4 pins this) and from the CAT16 lobes at 2000 K (N3), clipped by the downstream display/gamut clamp. Line 4 and line 6 conflict, so the owner has to choose between them or send gamut compression to its own lane. |
| **V2** (sky never teal or purple) | The sky is teal at −150 and violet-purple at +150. The lawn is green, not yellow, at −150. | **No, as worded.** Adobe's tint axis (line 4) turns blue sky cyan or violet. The claim needs restating. The evidence is now unquantised, which was the only part inside WS-03's control. |

## Gates

- `swift build --target LumenCore --target LumenRender` (debug) and `swift build -c release --product
  lumen-render` are clean. The only warnings are pre-existing ones in `Ingest/VerifiedCopy.swift`.
- LumenCoreTests, every class except ControlProofTests (debug xctest; there are too many classes for
  `--filter`): **3060 executed, 6 skipped, 0 failures**.
- ControlProofTests (release, `-enable-testing`): **6/6 pass**.
- WS-03 suites:
  - AutoWhiteBalanceTests 7/7, including the new `testAWrongAsShotIsRecovered`;
  - WhiteBalanceConventionTests 7/7;
  - TintGuardTests 14/14;
  - MaskWhiteBalanceTests 15/15;
  - WhiteBalancePresetNameTests 7/7;
  - SliderScaleTests 15/15;
  - `testTheTempRowShowsTheNeutralTheRenderAdaptsFrom` passes.

## Per spec line

| # | Measured (round 3) | Result |
|---|---|---|
| 1 | 8/8 bit-identical (`identity.py`). The `displayed` test passes. | PASS |
| 2 | WhiteBalanceConventionTests pass. The deviation from rounds 1 and 2 stands: the exact round trip goes through `ColorTemperature.temperatureAndTint`, while the SDK port `DNGTemperature.temperatureAndTint` is inexact by design. | PASS with deviation (outside WS-03) |
| 3 | 500 pairs: median 0.000, p90 0.000, max 0.010 ΔE00 | PASS |
| 4 | 21 cases: max \|Δhue\| 0.0°, max \|C ratio − 1\| 0.000 | PASS |
| 5 | 16 sweeps monotone | PASS |
| 6 | 10 tiles over the limit (see verdict) | **FAIL**, outside WS-03 |
| 7 | Eyedropper test passes | PASS |
| 8 | TintGuardTests pass, including the no-inversion grid | PASS |
| 9 | Presets exact. Max ΔE00 0.00 everywhere except Tungsten, at 0.01. | PASS |
| 10 | SliderScaleTests pass. The `SliderDrag.swift` diff is empty. `.reciprocal` is at `BasicPanel.swift:227`. | PASS |
| 11 | The `Sources/LumenPipeline` diff is empty. The grep finds only comments (`AppleRawSource.swift:46-50`). | PASS (macOS CI not observable here) |
| 12 | Builds. `autowb` JSON parses on all 25 corpus frames. The API is unchanged. | PASS |
| 13 | IN ΔE00: 1346 1.15, 967 1.83, 983 1.75, 3914 9.72 (limit 9.98), 864 1.26. **Mean 3.14** (limit 3.20, margin only 0.06; round 2 was 3.03). Δmired/Δtint: +6.0/−1.8, −3.3/−4.2, −8.4/+2.8, +6.2/+0.9. | PASS |
| 14 | OUT ΔE00: 3.53 (limit 3.71), 2.29, 2.02, 9.71, 0.49. Mean 3.61 (limit 4.07). | PASS (1346 margin 0.18) |
| 15 | 6929 −7.8 mired / −1.5 tint. 2545 0.0 / 0.0. | PASS |
| 16 | skin_tones 0.00 / 0.00. skin_only 0.0 / 0.0, chroma 1.00, \|Δhue\| 0.0°. | PASS |
| 17 | flat_grey 0.000 / 0.000. 1 distinct result over 5 (and over 7 more runs). Median 0.145 s on an idle machine (round 2: 0.08 s). | PASS |
| 18 | No app code changed since round 2. The `Auto` menu item and button are present (`BasicPanel.swift:379, 397`). | PASS on review (does not compile on Linux) |
| 19 | All LumenCoreTests and ControlProofTests pass | PASS |
| V1 | Regenerated with the spec command: **byte-identical** to the committed sheet. −150 is green, +150 magenta-pink, and ±75 skin still reads as skin. | PASS |
| V2 | See verdict | **FAIL**, outside WS-03 as worded |
| V3 | 864: Auto greys are indistinguishable from chart-neutral. 3914: Auto ≈ as-shot, so it is no bluer or more magenta. 967: a small move toward neutral. Nothing looks less natural than as-shot. | PASS |

## Owner's bar: Auto (chart IN) within 300 K and |Δtint| ≤ 8 of chart-neutral

| Frame | Auto | Chart-neutral | ΔK | Δtint | Result |
|---|---|---|---|---|---|
| 1346 | 5281/−9.4 | 5454/−7.6 | −173 | −1.8 | PASS |
| 967 | 4816/+11.3 | 4740/+15.5 | +76 | −4.2 | PASS |
| 983 | 5161/+15.9 | 4947/+13.1 | +214 | +2.8 | PASS |
| 864 | 10316/+12.0 | 11024/+11.2 | **−708** | +0.9 | FAIL |
| 3914 | 4684/+47.4 | 5456/+32.2 | **−772** | **+15.2** | FAIL |

The bar is met on **3 of 5** frames, the same as round 2. The 864 miss is worse than round 2's −644 K.
BUILD-NOTES says the cause is the 20–50-mired ambiguity cut, and that without it 864 lands at −309 K. I
did not rebuild without the cut to check this. The bar is not a spec line; in the spec's mired form
(13c), with 3914 exempt, it passes.

## Cast recovery

### Builder's harness (`cast_recovery.py`)

The cast is made by the engine model, and the reference is Auto's own uncast answer. My run reproduces
BUILD-NOTES exactly: **74 of 163 cells pass** (|residual| ≤ 15 mired and ≤ 8 tint).

| Cast | Pass | Median recovered |
|---|---|---|
| −150/−100 mired | 10/19 | 100 % |
| −50/−25 | 7/24 | 42 % |
| ±10 | 24/24 | 70 % |
| +25/+50 | 3/24 | 38 % |
| +100/+150 | 14/24 | 99 % |
| tint ±20 | 16/24 | — |

Per frame:

- **Full recovery at ±100/±150:** 1346, 967, 983, 4213, 1332, ColorChecker; 864 for positive casts.
- **Partial:** 6929 about 80 %, 3582 30–50 %, 7881 about 15 %.
- **None:** 2545 and skin_tones (0 % everywhere).

### My independent checks (scripts in scratchpad `verify3/own/`)

**1. Absolute truth, synthetic scenes, wrong preset.** I lit two scenes with a known light L and decoded
them at as-shot 5500/+10. The scenes were the synthetic ColorChecker and a "room" of random coloured
blocks plus an off-white wall with a luminance gradient. I lit them with Bradford, which differs from the
engine's CAT16 (a model mismatch), and also with CAT16. Truth is L itself, not Auto's own answer.

- **Room scene:**
  - 2850 K and 3200 K (a tungsten frame on Daylight): residual −6 to −8 mired, +2 to +3 tint, which is
    94–96 % recovered;
  - 9000 K and 12000 K: 92–97 %;
  - tint-only casts (5500/+30 and −15): within 7 mired and 4.4 tint.
- **25–50 mired band:**
  - 4000 K: 55 % recovered. 4500 K: 34 %. 6500 K: 47 %. 7500 K: 46–52 %.
  - 15–30 mired of residual stays on the photo. This is the deliberate cut, and it behaves as described.
- **ColorChecker, CAT16:** 2850 K 99 %, 3200 K 99 %, 12000 K 100 %. Band casts 39–45 %.
- **New defect (a cliff inside WS-03's control).** ColorChecker under Bradford at **2500–3000 K returns
  as-shot exactly, with confidence 0.00**. That is 0 % recovery of a 150–220 mired cast. The same scene
  under CAT16 recovers 99 %.
  - At 25 % exposure, the Bradford case also recovers (2840/+0.8).
  - Darkening only the yellow patch (3 % of the frame) to 70 % makes it recover perfectly (2851/+0.5).
  - Cause: once the white patch clips, the brightest unclipped 2 % is the yellow patch. The white-patch
    agreement term `exp(-(dwp/0.25)²)` multiplies into quality, so it pushes the true grey candidate below
    the 0.02 quality floor.
  - So one bright saturated object can make Auto do nothing on an otherwise easy tungsten frame. The
    failure is all-or-nothing rather than a graceful degradation.
  - It is the same mechanism class as the round 2 cliff, though much narrower.

**2. Self-consistency on 14 corpus frames that `cast_recovery.py` does not use.** Casts of ±25, ±50,
±100 and ±150 mired were made with CAT16 and with Bradford.

- **Recovered at ±100/±150:**
  - 2062: residual ≤ 6 mired;
  - 7301: ≤ 2.3;
  - 3437: ≤ 15, except −150 under CAT16 at −14.8;
  - 832 and 2348: about +30 and +17. These are constant offsets: the large-cast answer is the full move,
    and the uncast answer is the 40 %-cut one. They are not failures to recover.
- **Partial:**
  - 8559: −80 to −98 mired left at −100/−150 under both casts. At +100/+150 it recovers fully under
    Bradford but only partly under CAT16 (+44/+72 left).
  - 6933: 30–51 mired left.
- **Offset:** 6001 sits 20–30 mired / 5–19 tint from its uncast answer at every cast.
- **None at all (6 of 14 frames):** 4694, 1840, 1192, 4144, 1569 and 2242 have no credible neutral.
  Auto returns whatever as-shot it is given (confidence 0), so a 150-mired cast stays 150 mired.
  - This is the designed fallback and matches the spec's low-confidence rule.
  - With the ladder rule it also explains skin_tones and 2545 (0 % in the builder's table).
  - The claim "Auto recovers large casts" holds only on frames where it finds a neutral: in the whole
    corpus, 8 of 25 frames return as-shot.
  - Isolated cast-dependent pickups show that invariance is not exact under model mismatch. Example: 1569
    under Bradford recovers fully at +100 but not at +150 or −100.

**Summary for the owner.**
- Large casts (≥ 80 mired) are now recovered to within about 10 mired on frames with real neutral
  evidence. That is a real fix of the round 2 cliff.
- The 25–50-mired band is recovered only 35–55 %, by design. The cut buys line 14, and BUILD-NOTES states
  this trade honestly.
- Frames with no neutral evidence are not corrected at all, at any cast.
- The white-patch gate can zero out an easy tungsten frame.

## Break attempts

- **Autowb on all 25 frames:**
  - Deterministic: 3 runs give 1 distinct result on each frame.
  - Time per frame is 0.11–0.18 s.
  - Biggest moves:

    | Frame | Move |
    |---|---|
    | 832 | +24.2 mired (3009 → 2804 K) |
    | 3582 | +23.1 mired |
    | 6001 | −14.4 mired / −10.9 tint |
    | 7301 | −10.2 tint |
    | 3437 | +8.4 tint |
    | 864 | −9.8 mired |
    | 8559 | −12.0 mired |

  - I rendered as-shot | Auto for 832, 6001, 3582, 8559 and 7301 (640 px) and looked at each:
    - 832: the beige wall goes nearer grey;
    - 3582: the curtain goes nearer white;
    - 6001: a slight warm/green change, flowers white;
    - 8559: slightly warmer;
    - 7301: the stone is a touch less pink.
  - All are plausible, and none looks unnatural.
- **Warm-surface scenes:**
  - 4694 (fruit): no move, confidence 0.
  - 2062 (red tablecloth): Temp unchanged, −2.3 tint.
  - 8559 (red can): Auto raises Temp 5185 → 5529, so the render gets *warmer*, not neutralised toward
    blue.
  - None is pushed blue. **PASS.**
- **Blue scene, 1840 (sky):** no move, confidence 0, so it is not warmed. **PASS.**
- **Skin:** skin_tones and skin_only are unmoved (line 16). Under casts, skin_tones stays at as-shot
  (0 % recovery): skin-safe, at the cost of not correcting a skin-plus-flat-grey frame.
- **Frame-specific hacks:** none. `AutoWhiteBalance.swift` and `AutoWB.swift` contain no frame IDs,
  chart rectangles, `charts.json` or `CHART_MASK`. The only regions are caller-supplied `excluding`.
  Tuning constants are global.
- **Determinism and timing:** 17b and 17c pass. Time is up from about 0.08 s to about 0.145 s, still
  under 0.25 s.

## Evidence

There are 8 PNGs, all under 400 KB; the largest is 351 KB. I opened every one.

- **V1:** byte-identical to my regeneration.
- **V2:** now RGB (unquantised) at 1200 px, and the sky no longer posterises.
- **V3:** read as above.
- **`after_auto_cast_recovery.png` (1332 −100, 4213 +100, 1346 −150):** the Auto column matches the truth
  column visually.
  - It shows only best-case frames (100 % in the table). It does not show the 25–50 band, the partial
    frames, or the frames with no recovery. That is fair as an illustration but not representative.
- **`before_*`:** before-state sheets consistent with the audit.

## Builder's claims compared with mine

- BUILD-NOTES round 3 matches my numbers to the printed digit:
  - lines 13–17;
  - the owner-bar table;
  - the cast_recovery band table (74/163);
  - the 25-frame movers.
- Its explanation of the ambiguity band and of the 2545 and skin_tones zero-recovery is honest.
- **Not stated by the builder:**
  1. The white-patch cliff (ColorChecker tungsten under Bradford, confidence 0).
  2. That 6 of the 14 frames I added never recover any cast (they are among the "8 frames return
     as-shot").
  3. The 13b margin shrank to 0.06.

## What a pass needs

1. **Spec owner (outside WS-03):**
   - Line 6: exempt tint ≤ −50 and 2000 K, or route gamut compression to its own lane.
   - V2: restate it as "sky turns cyan at −150 and violet at +150, as in Adobe's model".
2. **Owner decision:**
   - Accept the 20–50-mired cut, which keeps line 14 and leaves 864 at −708 K. The alternative is
     `ambiguity.cut = 0`, which recovers the band and reaches 864 at about −309 K (builder's figure) but
     fails line 14.
   - Accept 3/5 on the 300 K bar.
3. **Inside WS-03 (recommended, not spec-blocking):**
   - Soften the white-patch gate so that a saturated brightest patch cannot zero a strong grey ladder.
   - Add a representative row (a band cast and a no-neutral frame) to the cast-recovery sheet.
