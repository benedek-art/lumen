# P6-film — Film Lab stream report

Agent P6-film. Worktree branch `worktree-agent-a37568eb3b0c03aa7`, reset to
`origin/claude/jolly-sagan-k7ch7z` (`cc4cdd7`) before any work. Build dir
`/tmp/lumen-build-p6`. Inputs: `docs/audit-2026-10/verify/V5-film-geometry.md`,
`docs/audit-2026-09/w2/C1.md`. Nothing pushed.

## Summary

| Item | Status | Commit | Proof records that move |
|---|---|---|---|
| M09 / C1-01 GPU halation gate | FIXED (GPU, source-verified) | `9748122` | none (CPU untouched); GPU halation output moves |
| N-006 / C1-09 normalized bounce weights | FIXED, byte-identical | `7892cae` | none (byte-identical, measured) |
| N-005 plate correlation | NOT-A-DEFECT, retired; comment corrected | `ab5ccca` | none |
| C1-10 mid-grey anchor on green only | FIXED (test) | `87048ab` | none |
| C1-05 roster six | NOT-FIXED: scope, spec below | — | would add records |
| C1-06 push/pull contrast-only | NOT-FIXED: model change, spec below | — | `film.pushPull` |
| C1-11 symmetric logistic | NOT-FIXED: model scope, spec below | — | nine records |
| NEW-V5-2 unknown-stock halation caption | FIXED (source-verified) | `d831b30` | none |
| NEW-V5-3 blend help with no film | FIXED (source-verified) | `0894e57` | none |
| M07 Strength vs grain/halation | DECISION NEEDED: memo + patch | — | none of the 135 (see memo) |
| M10 Film Exposure vs halation onset | DECISION NEEDED: memo + patch | — | none of the 135 (see memo) |
| NEW-V5-1 Halo Redness on B&W | DECISION NEEDED: memo + patch | — | none of the 135 (see memo) |

Checks on the final tree: `swift build --build-tests` is clean.
HalationControlTests, EngineIntegrationTests, FilmLabDisplayTransformTests,
KernelRosterTests, GrainParityScanTests, GrainPlateTests and SliderEvidenceTests
are green. `python3 scripts/check-swift-surface.py` exits 0. Its kernel pass also
checks the new `lumenHalationEnergy` source for reserved words.

## Items

### M09 / C1-01: one highlight-energy gate on both paths. FIXED, `9748122`
- **Mechanism.** `lumenHighlightEnergy` was `max(E − clip/4, 0)·2^0.3`, a pedestal.
  The reference is `t = smoothstep(−4, 0, log2(E/clip)); H = t·E·2^(0.3t)`.
- **Fix.** A new kernel `lumenHalationEnergy(image, clip, protectEV, boostRange)`
  evaluates the reference expression per channel. It is in the `unavailableKernels`
  roster, so `KernelRosterTests` covers it. `RenderGraph.applyHalation` feeds it
  `profile.clipLevel` and the two `HalationProfile` constants. `highlightEnergy`
  stays the generic clamp, because the gamut flag and `logLuminance` use it with
  t = 0, b = 1. `HalationProfile.threshold`, `.boost` and the false "half-power
  point" comment are deleted.
- **Tests (macOS gpu-parity lane, source-verified).**
  - New `KernelGoldenTests.testHalationGateMatchesTheReferenceAcrossTheOnset`:
    flat fields at E = 0.125, 0.25, 0.5, 1 and 4, GPU glow against reference glow
    at the centre, 3% bound.
  - `testHalationGlowIsAsWideAsTheProfileSays` mass bound tightened from 30% to 3%.
  - Traced against the pedestal, the ratios are 0, 0, 0.612, 0.750 and 0.9375, so
    all five flat-field assertions and the tightened bound (E = 4, 6.25% light) go
    red. Not executed here, because LumenPipeline does not build on Linux.
- **Pixels.** GPU halation only. Preview and export glow rises to the reference's:
  from nothing at E ≤ 0.25, and ×1.63 at E = 0.5. There are no stored GPU halation
  golden images: the halation goldens are live GPU-vs-reference comparisons, so
  nothing needs re-baselining. The CPU proof records do not move, because
  ReferenceRenderer is untouched.

### N-006 / C1-09: normalized bounce weights. FIXED, byte-identical, `7892cae`
- **Calibration.** `HalationProfile.strengthCalibration = 1.75` is a named literal,
  the old raw sum. It is folded into `strength`, so `strength` is the gain on a
  unit-sum field and Amount no longer depends on `bounceCount`. The stock literals
  keep their measured values. The per-instance `decay` and both `weight *= decay`
  walks are gone.
- **Deviation from V5's literal spec, on purpose.** V5's spec multiplies each
  bounce by `normalizedWeights[k]`. I built that first and measured it. It is NOT
  byte-identical: the reference accumulates the field in an f32 `ImageBuffer`, and
  4/7, 2/7 and 1/7 are not dyadic. 51 of the 63 halation proof-sweep renders and
  51 of the 60 glowing stage configurations moved by one f32 ULP (5.96e-8). The
  proof drift tolerance is 1e-6 code values, and one ULP is about 1e-5 code values,
  so records could have drifted.
- **What shipped instead.** The renderers accumulate with the raw dyadic shape
  (1, ½, ¼, which scale an f32 field exactly) and apply
  `fieldGain = strength / weightSum`. Mathematically that is
  `strength · Σ normalizedWeights[k]·G_k∗H`. `normalizedWeights` documents the
  relation. If the owner wants the literal per-bounce form anyway, it costs one f32
  ULP on most halation pixels.
- **Byte-identity proof.** A temporary probe (deleted, not committed) hashed the
  f32 bits of:
  - the 63 full `ReferenceRenderer` renders of the `film.halation`,
    `film.halationSize` and `film.halationRedness` sweeps (21 steps each);
  - `applyHalation` on the wide step edge for all 6 stocks × 3 Size/Redness pairs
    × Amount 35/100 × long edge 2048/6000 (72 configurations).

  Before and after: **all hashes identical** (`cmp` clean).
- **Tests (Linux).**
  - `testTheRendererAppliesBounceWeightsThatSumToOne`: on a flat field the
    reference adds exactly `strength·H(E)`. On the pre-change code it read 1.75:
    red, 1 failure.
  - `testNormalizingTheBouncesMovesNoPixel`: rebuilds the pre-change stage and
    requires zero difference over 5 stocks × 3 settings.
  - Red evidence: with `combine` using `strength` (no normalization), 16 failures.
    With the per-bounce `normalizedWeights` form, 15 failures (1 ULP each).
    Restored: 10/10 green.
- **Pixels.** None.

### N-005: plate-seed correlation. NOT-A-DEFECT, retired, `ab5ccca`
V5 showed the 0.088 is one draw from a null distribution with sd ≈ 0.11. The
effective sample count is about 100, not 16 384, because the ~8×8 octave-0 lattice
dominates the variance. Unrelated seeds give 35% of pairs at |r| ≥ 0.088, and
`plateSeed` offsets give 40.5%. Changes:
- The misleading comment in `FilmGrainProfile.noiseMixWeights` (formerly
  FilmLab.swift:719-727) is corrected.
- `docs/audit-2026-09/w3/dispositions.md` N-005 now records the retirement.

Not reseeded. Comment and docs only, no pixels.

### C1-10: mid-grey anchor asserted on green only. FIXED, `87048ab`
`testEveryStockAnchorsMidGrey` now asserts R, G and B at 1e-4, where it used to
assert G at ±0.01.
- **Red evidence.** I put a temporary `printGain.r`/`filmGain.r` ×1.01 after the
  solve. The test then failed 8 times: red on the five colour stocks, and all
  three channels on Tri-X, whose monochrome mix carries red into its grey. Every
  green value stayed inside ±0.01, so the old assertion passes under that mutation.
- Restored: green. Test only.

### C1-05: roster is six. NOT-FIXED (scope), re-verified
`FilmStock.all` (FilmLab.swift:398-405) is still Portra 400, Gold 200, Ektar 100,
Tri-X 400, Velvia 50 and Cine 250D. This is not a defect: adding stocks is a
product decision, and each new stock brings a new `film.<id>.strength` proof record.
- **Spec.** Add Portra 160/800, Vision3 500T (+ a rem-jet-removed high-halation
  variant), HP5+ and T-Max 400 as `FilmStock` literals, marked authored-not-fitted.
  `FilmStock` needs no new fields.
- **Proof ceremony.** One `film.<id>.strength` record per stock against floor 59
  (`ProofRegistry.film` stocks list). `testEveryStockAnchorsMidGrey` (now
  three-channel) and the monotonicity sweeps cover them automatically.
- **Acceptance.** A stock whose `named` returns nil fails its own record's P1/P3.

**DECISION NEEDED** (which stocks, and their authored parameters).

### C1-06: push/pull is contrast-only. NOT-FIXED (moves records), re-verified
Still `γ × (1 + 0.18·push·(1 ± 0.03))` (FilmLab.swift `build`), `pushTint·push`,
and grain ×(1+0.35·push) and pitch ×(1+0.15·push) (`FilmGrainProfile.init`). There
is no fog term and no exposure loss, and pull uses the same coefficients.
- **Spec (C1's, confirmed against current code).** In `build`:
  - `negative.dMin += 0.04·push`;
  - γ factor 0.12 instead of 0.18;
  - `interlayer × (1 + 0.10·push)`;
  - halve every coefficient for push < 0.

  The half-stop speed loss must go in `apply`: `scene = c·2^(filmExposure −
  0.5·push)`. `solveGains` re-anchors 0.18 after `build` and would cancel a scene
  gain placed there.
- **Acceptance.** On the wedge at push +2 against 0, the output at −6 EV is LOWER.
  Move the exposure term into `build` and the assertion goes red.
- **Pixels.** `film.pushPull` moves. The six strength records use push 0, so they
  do not. This is a look change: **DECISION NEEDED** before landing.

### C1-11: symmetric logistic. NOT-FIXED (model scope), re-verified
`FilmStage.response` is still `s = 1/(1+exp(−x)); d = dMin + delta·s`, with no
toe/shoulder terms and no datasheet fixture.
- **Spec.** `FilmCharacteristic` gains `toe`/`shoulder` RGB, and `response` uses
  `x·(1−t)` for x<0 and `x·(1+s)` for x≥0, with authored t/s per R7.
- **Docs.** Document in docs/05 the two model limits: `solveGains` plus the
  per-channel paper-white normalisation remove every global cast, and the print's
  Dmin/Dmax cancel in the normalisation.
- **Acceptance.** At −3 EV with t = 0.35 the response sits above the symmetric curve
  by more than 0.05 D and matches it at 0 EV. With t = s = 0 it goes red.
- **Pixels.** Nine records move: six strength records, exposure, pushPull and
  halation. Taste and ceremony, so **DECISION NEEDED**.

### NEW-V5-2: unknown stock captioned "no halation response". FIXED, `d831b30`
The caption is now gated `if stock != nil && !halationSupported`.
`AuditControlContractTests` extracts the `if` line right before the caption, with
comments stripped, and requires that exact gate. The old `if !halationSupported {`
fails it. Source-verified (macOS test). No pixels.

### NEW-V5-3: blend help with no film. FIXED, `0894e57`
`FilmDisplayTransformAvailability.blendHelp(for:)` returns `transformHelp` for a
shipped stock and "" (no tooltip) for nil or an unknown stock, since neither builds
a chain. The header and the Strength row both use it.
- **Tests.** The new pure-function test sweeps nil, unknown and every shipped stock
  at 0/1/50/100. The source test counts two `blendHelp` sites and zero bare
  `.help(...transformHelp)`. The old source has 0 and 2, so it fails both.
- Source-verified. No pixels.

## DECISIONS

All three patches below were checked on this tree. I applied each one together
with its tests and built. The new tests went red without the source change and
green with it:
- M07: 4 failures, then green.
- M10: 4 failures, then green.
- NEW-V5-1: 2 failures, then green.

With all three applied, the film suites (HalationControlTests,
FilmLabDisplayTransformTests, EngineIntegrationTests, GrainPlateTests,
LookAmountTests, CreativeGrainTests, SliderContractTests, ScaleHonestyTests,
EngineMathFixtureTests) were green: 161 tests. The one exception is NEW-V5-1's
expected update to `testNormalizingTheBouncesMovesNoPixel`'s legacy replica,
which is included in its patch.

Afterwards all three were reverted. The patches are relative to `87048ab`. M07 and
M10 both touch `halationProfile(...)`, so whichever lands second needs a trivial
rebase.

### M07: Strength switches grain and halation on at full amplitude
**What happens.** At Strength 1, 50 and 100, Portra with grain 45 and halation 100
measures `grainAmount` 0.054 and halation strength.r 0.0875 at all three Strengths.
At Strength 0 no chain exists. So 0→1 pops full grain and the full glow on.

**Options.**
- **A. Linear amplitude** (recommended). Scale `grainAmount` and the halation
  profile amount by `strength`. The output is
  `(1−s)·base(c+s·g) + s·film(c+s·g)`: continuous and cheap. The chain's grain and
  glow also enter the user's half of the blend at reduced amplitude.
- **B. Exact chain blend.** `(1−s)·base(c) + s·film(c+g)`. This needs a second,
  un-halated, un-grained image through the base transform: about 2× spatial cost on
  the film path and a restructure of both renderers. It is not worth it for a
  continuity fix.
- **C. Keep as is**, and document that Strength blends tone only.

**Proof records.** None of the 135 move:
- The six `film.<id>.strength` records sweep Strength with `FilmLab(stock:amount:)`,
  which has halation 0 and grain 0, so `0·s = 0`.
- Every other film record is at Strength 100, where `x·1.0 == x` exactly.

**Who sees it.** Any saved edit with Strength < 100 and grain or halation > 0. The
panel's default recipe for a stock carries the stock's grain and halation defaults,
so a typical partial-Strength edit loses grain and glow in proportion. The decision
is needed because that changes the look of existing edits.

**Recommendation.** A. It is the only option that makes Strength continuous without
a renderer restructure, and it is identity at Strength 100.

**Patch** (`git apply`):
```diff
--- a/Sources/LumenCore/Engine/FilmLab.swift
+++ b/Sources/LumenCore/Engine/FilmLab.swift
@@ public func halationProfile(longEdgePixels: Int,
         guard let s = stock else { return nil }
         return HalationProfile(stock: s,
-                               amount: recipe.halation,
+                               amount: recipe.halation * strength,
                                size: size ?? recipe.effectiveHalationSize,
@@ public var grainAmount: Double {
         guard solved != nil else { return 0 }
-        return grain.amount * FilmGrainProfile.densityScale
+        // × Strength (M07): grain belongs to the film half of the blend, so it fades
+        // with it instead of switching on at full amplitude at Strength 1.
+        return grain.amount * FilmGrainProfile.densityScale * strength
     }
@@ public func halation(longEdgePixels: Int) -> HalationProfile {
+        // × Strength (M07): the glow's GAIN is `HalationProfile.strength`, built from
+        // this amount — `halationAmount` is only the gate, so scaling it would not
+        // fade anything.
         HalationProfile(stock: stock ?? FilmStock.portra400,
-                        amount: stock == nil ? 0 : recipe.halation,
+                        amount: stock == nil ? 0 : recipe.halation * strength,
```
Test, appended to `HalationControlTests`:
```swift
    func testStrengthScalesGrainAndHalationAmplitude() {
        func chain(_ amount: Double) -> FilmChain {
            var lab = FilmChain.defaultRecipe(for: .portra400)
            lab.amount = amount
            lab.halation = 100
            lab.grain.amount = 100
            return FilmChain(lab, displayWhite: 1.0)
        }
        let full = chain(100)
        let fullGlow = full.halation(longEdgePixels: 3000).strengths.r
        XCTAssertGreaterThan(full.grainAmount, 0)
        XCTAssertGreaterThan(fullGlow, 0)
        for amount in [1.0, 50] {
            let part = chain(amount)
            XCTAssertEqual(part.grainAmount, full.grainAmount * amount / 100, accuracy: 1e-12)
            XCTAssertEqual(part.halation(longEdgePixels: 3000).strengths.r,
                           fullGlow * amount / 100, accuracy: 1e-12)
        }
    }
```
Note that V5's C1-02 correction is right: scaling `halationAmount` (the gate) alone
fades nothing. The gain is the profile amount.

### M10: Film Exposure ignores halation onset
**What happens.** At Film Exposure −2, 0 and +3, `clipLevel` is 1.0 every time. The
glow is computed on the un-exposed scene, so +2 does not make a 0.25 sky halate, and
−2 keeps a clipped highlight glowing at full strength.

**Options.**
- **A. Tie the onset to Film Exposure** (recommended).
  `clipLevel = 2^−filmExposure` in `halation(longEdgePixels:)`, with the same
  default in `halationProfile`. This is physically exact: `highlightEnergy` is
  homogeneous, `H_{clip=1}(c·2^x)/2^x == H_{clip=2^−x}(c)`. The GPU gate, now the
  same expression after M09, follows with no shader change.
- **B. Declare halation an independent creative bloom.** Document that Film
  Exposure moves only the curve, and keep the code.

**Proof records.** None of the 135 move:
- `film.exposure` has halation 0, so the stage is skipped.
- The halation records sit at exposure 0, where `pow(2, −0) == 1.0` exactly.

**Who sees it.** Saved edits with Film Exposure ≠ 0 and Halation > 0: glow grows
with +EV and shrinks with −EV.

**Recommendation.** A. Halation is "the energy that reaches the base", which is
after the film exposure. V5's corrected acceptance test (film-exposure domain, not
equal pre-chain mass) is the one included here.

**Patch:**
```diff
--- a/Sources/LumenCore/Engine/FilmLab.swift
+++ b/Sources/LumenCore/Engine/FilmLab.swift
@@ public func halationProfile(longEdgePixels: Int,
                                 redness: Double? = nil,
-                                clipLevel: Double = 1.0) -> HalationProfile? {
+                                clipLevel: Double? = nil) -> HalationProfile? {
         guard let s = stock else { return nil }
@@
                                longEdgePixels: longEdgePixels,
-                               clipLevel: clipLevel)
+                               clipLevel: clipLevel ?? pow(2.0, -filmExposure))
     }
@@ public func halation(longEdgePixels: Int) -> HalationProfile {
                         longEdgePixels: longEdgePixels,
-                        clipLevel: 1.0)
+                        // The film sees `c · 2^filmExposure` (`apply`), so the scene
+                        // value that reaches the film's clip is `2^−filmExposure`.
+                        // Exact: `highlightEnergy` is homogeneous, H_{clip=1}(c·2^x)/2^x
+                        // == H_{clip=2^−x}(c), and the GPU gate is the same expression.
+                        clipLevel: pow(2.0, -filmExposure))
     }
```
Test:
```swift
    func testFilmExposureMovesTheHalationOnset() {
        func profile(_ x: Double) -> HalationProfile {
            var lab = FilmChain.defaultRecipe(for: .portra400)
            lab.halation = 100
            return FilmChain(lab, filmExposure: x, displayWhite: 1.0)
                .halation(longEdgePixels: 3000)
        }
        for x in [-2.0, 2.0, 3.0] {
            for c in [0.25, 1.0] {
                let scale = pow(2.0, x)
                let lhs = scale * profile(x).highlightEnergy(RGB(gray: c)).r
                let rhs = profile(0).highlightEnergy(RGB(gray: c * scale)).r
                XCTAssertEqual(lhs, rhs, accuracy: 1e-9 * Swift.max(rhs, 1))
            }
        }
    }
```
Red on today's code: 4 of the 6 cases fail. The 2 that pass are both above the clip
at x > 0, where the gate is already homogeneous.

### NEW-V5-1: Halo Redness on B&W stocks
**What happens.** Tri-X has strengths (0.04, 0.04, 0.04) and a monochrome chain.
Redness 100 takes the profile to (0.04, 0, 0), which the monochrome mix turns into
less glow, not red glow. Redness is a hidden second Amount there.

**Options.**
- **A. Disable the row on monochrome stocks only**, with no engine change. This is
  misleading for any saved Tri-X edit with Redness > 0: the value still darkens the
  glow but can no longer be edited.
- **B. Engine ignores Redness on monochrome stocks, and the panel disables the row**
  (recommended). One meaning everywhere, and no stuck value.
- **C. Define Redness for B&W**, for example as a spectral weighting toward the
  red-sensitive end of a panchromatic emulsion. This is new modelling and needs a
  spec.

**Proof records.** None of the 135 move:
- `film.halationRedness` is on Portra.
- `film.trix400.strength` has halation 0.

**Who sees it.** Saved Tri-X edits whose Halo Redness ≠ 0 (default 0): their glow
returns to full.

**Recommendation.** B.

**Patch:**
```diff
--- a/Sources/LumenCore/Engine/FilmLab.swift
+++ b/Sources/LumenCore/Engine/FilmLab.swift
@@ HalationProfile.init
-        let red: Double = Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
+        // A monochrome stock has one record, so "toward red" has no colour to move
+        // to: on Tri-X it only cut the glow to the red strength's luma share
+        // (NEW-V5-1). Redness is held at the stock's own 0 there.
+        let red: Double = stock.monochrome
+            ? 0
+            : Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
--- a/Sources/LumenApp/LookPanel.swift
+++ b/Sources/LumenApp/LookPanel.swift
@@ LumenSlider(title: "Halo Redness", …
-                .disabled(!halationSupported)
+                .disabled(!halationSupported || stock?.monochrome == true)
--- a/Tests/LumenCoreTests/HalationControlTests.swift
+++ b/Tests/LumenCoreTests/HalationControlTests.swift
@@ testNormalizingTheBouncesMovesNoPixel (legacy replica)
-                let red = Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
+                let red = stock.monochrome
+                    ? 0 : Num.clamp((redness ?? stock.halationRedness) / 100.0, 0, 1)
```
Test:
```swift
    func testHaloRednessDoesNothingOnAMonochromeStock() {
        func strengths(_ redness: Double) -> RGB {
            var lab = FilmChain.defaultRecipe(for: .triX400)
            lab.halation = 100
            lab.halationRedness = redness
            return FilmChain(lab, displayWhite: 1.0).halation(longEdgePixels: 3000).strengths
        }
        let neutral = strengths(0)
        XCTAssertGreaterThan(neutral.g, 0)
        for redness in [50.0, 100] {
            XCTAssertEqual(strengths(redness).maxAbsDifference(neutral), 0, accuracy: 1e-15)
        }
    }
```
If B lands, `AuditControlContractTests.testAllThreeHalationControlsRespectStockCapability`
needs its Halo Redness row to accept the extended `.disabled(...)` expression. Its
`row.contains(".disabled(!halationSupported")` prefix still matches as written.

### Other decisions
- **N-006 implementation form**: `fieldGain` rather than per-bounce
  `normalizedWeights`. Byte-identity forced this choice; see the N-006 section.
- **NEW-V5-3**: the blend help is also suppressed for an unknown stock, not only
  for "no film loaded". An unknown stock builds no chain either.
- **C1-05 / C1-06 / C1-11**: specs above, not implemented. Each moves or adds proof
  records, or is taste.

## FOUND-WHILE-FIXING
- **The probe cost.** On this shared box, one full `ProofRunner.measure` sweep of
  13 film specs did not finish in 30 minutes. The byte-identity proof therefore
  hashed renders without re-deriving the records. That is a stronger check:
  identical f32 renders give identical records.
- **The September C1-07 acceptance test** ("exposure +2 on 0.25 = exposure 0 on
  1.0, same mass") is wrong, as V5 said. Measured on today's code: x = +2, c = 1
  already satisfies the film-domain identity, and only below-clip cases fail. The
  included test uses the film-exposure domain.
- **`KernelGoldenTests` comment.** It said the 0.02 background sat "four and a
  half stops below the reconstruction's onset", which only described the
  pedestal's onset. Corrected in `9748122`: 1.6 stops below the smoothstep's.
- **`HalationProfile.halationProfile(... clipLevel:)` callers.** No test passes
  `clipLevel` explicitly today, so M10's change of default from `1.0` to `nil` is
  source-compatible.
