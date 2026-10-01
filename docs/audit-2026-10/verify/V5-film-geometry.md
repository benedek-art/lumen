# V5 — film emulation, effects and geometry (Phase 1 verification)

Verifier: V5. Worktree branch `worktree-agent-aa7444777c40c1b31`, fast-forwarded to trunk
`a9a1d47` before any work (the worktree was created at `99c3727`, which does not contain
PR #5). Build dir `/tmp/lumen-build-v5`. Local commits: `74482ff` (test only, no pixels
move) and the commit adding this report. (The isolation sandbox refused a write to the
main-tree path, so the report is committed at the same relative path in the worktree.)

Constraint that shapes every verdict below: the PR #5 repairs in this area live in
`LumenPipeline` / `LumenApp`, and every test that covers them is `#if os(macOS)`
(`VignetteGeometryContractTests`, `FilmDisplayTransformAvailabilityTests`,
`AuditControlContractTests`). None of them compiles or runs on this Linux box, so the
"break it, watch it go red" step could not be done for them. Those verdicts are
**source-verified only**: I traced the mechanism and reasoned through what each test
would do with the fix reverted. The LumenCore facts behind them (gamma direction,
stock strengths, chain blend, halation gate, plate correlation) I measured on Linux with a
temporary probe test that is deleted, not committed.

## Verdict table

| Finding | Verdict | Evidence |
|---|---|---|
| **M06** vignette after off-centre crop + flip (cddbd3d), incl. rotation | **CONFIRMED, GPU path, source-verified only.** Reference path: no regression, but it has no geometry at all (see note) | `RenderGraph.applyVignette(geometry:)` now runs the vignette ellipse in the delivered (oriented) coordinate system. It takes `PipelineRenderer.geometryRects(...)`, the same function `applyGeometry` uses, and builds `axisX/axisY` rows from `rects.orientation` with the source-origin translation folded into `z`. Those rows match `applyGeometry`'s translate-to-zero followed by `orientation`, and I checked them against the CGAffineTransform convention (x' = a·x + c·y + tx). The centre and radii come from `rects.target.integral`. When there is no flip and no angle the rows are (1,0,−minX)/(0,1,−minY), so uncropped and axis-aligned renders are unchanged. Region previews crop the image after geometry has been applied, and the HDR path (`PipelineRenderer.swift:972-974`) builds first and then calls `applyGeometry`, so neither hands the vignette a partial frame. The test computes the expected burn independently in delivered pixels. It covers the finding's exact crop (.1/.1/.35/.7) with its reflected twin, angles ±13 and ±90 with and without flip, and a translated source origin. With the old crop-only centring substituted back, the flip case centres on the mirrored source rect (x 0.55–0.90 instead of 0.10–0.45) and fails the 0.002 bound. That is reasoned, not executed (macOS only). |
| **M08** Display Transform disabled during partial blend (f2d5def) | **CONFIRMED, source-verified only**, plus one P3 copy nit | `FilmDisplayTransformAvailability.replacingStock` now requires `film.amount >= 100` and a known stock. In the engine (`FilmChain.init`/`apply`), the blend is `clamp(amount/100,0,1)` and `base.mix(film, strength)`, where `base` is the recipe's solved transform (`RenderPlan.swift:267`). So below 100 the controls do reach pixels, and at 100 they don't. The controls in the disabled group are preset, contrast, skew, hue and black. At full strength none of them feeds `solved`, and `displayWhite` comes only from `whiteTarget` (`DisplayTransform.swift:161-165`). The test sweeps the boundary over every stock and ties the predicate to measured preset influence (> 1e-5 at 0/1/50/99, < 1e-12 at 100/101). With `amount > 0` substituted back, `testEveryKnownStockKeepsTheTransformEditableUntilFullStrength` and `testAvailabilityAgreesWith…` would both go red at 1/50/99. Nit: `.help(transformHelp)` sits on the Display Transform header unconditionally (`LookPanel.swift:1106`), so a photo with no film loaded still shows "Below 100% Film Strength, these settings remain part of the film blend…" (NEW-V5-3). |
| **M13** Ramp shape tooltip direction (2c70752) | **CONFIRMED, source-verified only** (help string) | `MaskRaster.levels` returns `pow(t, 1/g)` (`MaskRaster.swift:416-428`), and it is the only implementation. The GPU path takes its masks from `MaskRaster`, and `LumenPipeline` has no second levels routine. Measured on Linux: γ 0.5 → 0.25 and γ 2 → 0.7071 at t = 0.5. The help at `MaskPanel.swift:2094-2098` now reads "Below 1 … holds back and arrives late; above 1 it comes up early", which matches. The test pins both the numbers and the string, and reverting the string turns it red. Wording nit only, not a defect: "eases in" for γ > 1 is "ease-out" in animation terms (fast start, slow finish). |
| **M14** Velvia halation rows enabled (2c70752) | **CONFIRMED.** The test was thin, so I strengthened it (`74482ff`) | `halationSupported = stock.halationStrength != .zero`, and `.disabled(!halationSupported)` is applied to all three rows in `LookPanel.filmLabRows`. Velvia measured `halationStrength == .zero`, so both the engine `halationAmount` and the profile strengths are 0 at every Amount, Size and Redness. The existing test checked only the predicate's text and two stocks. New Core test `HalationControlTests.testEveryStocksHalationRowsAreLiveExactlyWhenTheEngineCanGlow` sweeps all 6 stocks × Size {0.5, 1, 2} × Redness {0, 50, 100} and checks the engine against the predicate. It is green (suite 8/8). A synthetic stock with strength (0, 0.01, 0) run through the same expression reports enabled-but-dead at Redness 100, which is the red case the test is there to catch. I could not mutate the roster in `Sources` to show red in place: the sandbox refused the temporary source edit. See NEW-V5-1/2. |
| **2c70752** control ranges as they touch film/effects | **CONFIRMED** for Black target and the halation rows. Two P3 copy issues | Black target: the engine clamps it to `min(clamp(b,0,15)/100, midGrey·0.5)`, i.e. 9 (`DisplayTransform.swift:164-166`). The track, hardRange, getter and setter are now all 0…9, and legacy values above 9 display as 9 with the recipe left untouched. The tone equality between 9 and 15 is pinned. Collateral (NEW-V5-2): for an **unknown** stock, `stock == nil`, so `halationSupported` is false and the panel shows both "This stock has no halation response." (`LookPanel.swift:1345`) and the "not a stock this build ships" caption. The rows are correctly disabled (no chain is built), but the first caption is wrong for that case. |
| **M07** Strength switches spatial effects on at full amplitude | **STILL REAL. Phase 2 spec below. Note that the C1-02 fix text is incomplete** | Measured (Portra, grain 45, halation 100): at Strength 1/50/100, `halationAmount` = 1.0/1.0/1.0, `grainAmount` = 0.054/0.054/0.054 and `halation(longEdgePixels:).strength.r` = 0.05/0.05/0.05. The chain does not exist at Strength 0 (`RenderPlan.swift:252`). This matches Astra's probe exactly. |
| **M09** GPU halation gate under-produces | **STILL REAL. Phase 2 spec below** | Measured reference `highlightEnergy` against the GPU pedestal `max(E−0.25,0)·2^0.3`: the GPU/reference ratio is 0 at E = 0.125, 0 at 0.25, 0.612 at 0.5, 0.750 at 1 and 0.9375 at 4. Identical to Astra M09 and September C1-01. The kernel is unchanged at `Kernels.swift:434-436`. |
| **M10** Film Exposure does not affect halation onset | **STILL REAL. Phase 2 spec below. The C1-07 acceptance test as written is wrong** | Measured at Film Exposure −2/0/+3: `clipLevel` 1.0/1.0/1.0, threshold 0.25/0.25/0.25, `energy(0.25)` 0.1387 every time, `energy(1)` 1.2311 every time. |
| **N-005** plateSeed field correlation | **NOT A DEFECT, sampling noise. Retire it and correct the comment** | The shipping seed reproduces r = 0.0880 / 0.0459 / −0.0376. Two baselines, 200 draws each. Plates from **unrelated random seeds**: mean r −0.013, sd 0.106, and 35% of pairs have abs(r) ≥ 0.088. Plates from **`plateSeed` offsets of random bases**: mean −0.00005, sd 0.112, 40.5% with abs(r) ≥ 0.088. The offset scheme adds no structural correlation. The 16 384 pixels are not 16 384 independent samples: the octave-0 lattice is about 8×8 and dominates the variance, so the effective N is about 100. The September argument "16 384 samples, so the first is real" (`dispositions.md:106`, repeated at `FilmLab.swift:719-727`) is a statistics error. The shipped plate is one fixed draw whose r happens to be +0.088. |
| **N-006** `normalizedWeights` unused, Amount × 1.75 | **STILL REAL, calibration only** | Measured: weights [1, 0.5, 0.25], sum 1.75. `normalizedWeights` (`FilmLab.swift:525`) still has no caller. Both renderers walk `weight = 1, ×decay` (`RenderGraph.swift:1430-1452`, `ReferenceRenderer.swift:492-502`). The two paths agree. |
| C1-01 | = M09, still open | as above |
| C1-02 | = M07, still open | as above |
| C1-03 | = M08, **fixed** by f2d5def | as above |
| C1-04 | fixed earlier (`f67582b`), unchanged | `halation(longEdgePixels:)` reads the recipe's size and redness (`FilmLab.swift:1607-1614`) |
| C1-05 roster six | still open (scope, not a defect) | `FilmStock.all` still has six stocks (`FilmLab.swift:398`) |
| C1-06 push/pull contrast-only | still open | `FilmLab.swift:1636` still has `1 + 0.18·push·…`. No fog term and no exposure loss in `apply` |
| C1-07 | = M10, still open | as above |
| C1-08 | = M14, **fixed** by 2c70752 | as above |
| C1-09 | = N-006, still open | as above |
| C1-10 mid-grey anchor on green only | still open | `EngineIntegrationTests.swift:967-968` still asserts `out.g` only |
| C1-11 symmetric logistic | still open (model scope) | no toe/shoulder terms |

### New observations (not in any ledger)

- **NEW-V5-1 (P3): on Tri-X 400, Halo Redness is a hidden Amount control.** Tri-X
  has `halationStrength` (0.04, 0.04, 0.04), so its rows are enabled. Its chain is
  monochrome: measured red-in (0.3, 0.18, 0.18) → 0.2225 on all three channels. Redness
  100 takes the profile strength to (0.04, 0, 0), so on a B&W stock Redness never adds
  colour and only cuts the glow to the red record's luma share. Phase 2 needs an owner
  decision: disable Halo Redness when `stock.monochrome`, or define what it means there.
  **DECISION NEEDED** (UI direction).
- **NEW-V5-2 (P3): wrong halation caption for an unknown stock** (see the 2c70752 row).
  Fix: gate the caption on `stock != nil && !halationSupported`.
- **NEW-V5-3 (P3): Display Transform help shows when no film is loaded** (see the M08 row).
  Fix: apply `.help(transformHelp)` to the header only when
  `state.currentRecipe.look.filmLab != nil`. Note: `FilmDisplayTransformAvailabilityTests`
  counts exactly two `.help(…transformHelp)` occurrences, so update that count with the fix.
- **M06 reference-renderer note.** `PipelineRenderer.renderReference` never calls
  `applyGeometry` (GEO-17; labelled "crop, straighten and flip are not applied" at
  `RenderCoordinator.swift:363-379`, and export refuses this path). Its vignette
  (`DetailEngine.vignette`, `ReferenceRenderer.swift:105-108`) is centred on the full
  frame, which is the frame that path delivers, so it is self-consistent and not an M06
  regression. When GEO-17 lands, `DetailEngine.vignette` must take the crop, flip and
  angle the same way the GPU path now does, or the fallback will burn the sensor centre
  of a cropped frame. That is a hard prerequisite for the GEO-17 work. Also by design:
  with `skipCrop` (crop tool open), the vignette stays centred on the pending crop rather
  than on the full frame being shown.

## Phase 2 specs

### M07 / C1-02 — Strength must scale grain and halation
**Files:** `Sources/LumenCore/Engine/FilmLab.swift` (`halationAmount` :1574, `grainAmount`
:1585, **`halation(longEdgePixels:)` :1607**). The renderers follow automatically: `GrainPlan.film`
reads `grainAmount` (:1279), and both `applyHalation`s build their profile through
`halation(longEdgePixels:)`.
**Correction to C1-02's fix text.** Multiplying `halationAmount` by `strength` alone does
**not** scale the glow. `halationAmount` is only the gate (`RenderGraph.swift:176`,
`ReferenceRenderer.swift:114`). The gain is `HalationProfile.strength`, built from
`recipe.halation` inside `halation(longEdgePixels:)`. Pass
`amount: stock == nil ? 0 : recipe.halation * strength` there, and multiply `grainAmount` by `strength`.
**Semantics (DECISION NEEDED):** linear amplitude scaling makes the output
`(1−s)·base(c + s·g) + s·film(c + s·g)`. That is not the exact "blend of the whole
chain", which would be `(1−s)·base(c) + s·film(c + g)` and needs a second halated image.
Linear scaling is continuous and cheap. The owner should choose.
**Acceptance (LumenCore, Linux-runnable):** Portra with grain 100 and halation 100,
through `ReferenceRenderer` on a flat 0.18 field and on a 4.0 block. Assert grain σ(Strength 1) <
0.03·σ(100) and `halation(...).strength.r`(1) < 0.02·(100). Also assert Strength 0→1 total
pixel change < 3 code values. Substituting the unscaled getters back must turn all of them red.
**Pixels:** identity at Strength 100. The six `film.<id>.strength` records
(`tonalColourWedge`, sweep 0…100) will move if their recipe carries the stock's default
grain or halation. Re-pin them.

### M09 / C1-01 — one highlight-energy gate on both paths
**Files:** `Sources/LumenPipeline/Kernels.swift:434-436` (`lumenHighlightEnergy`),
`RenderGraph.swift:1419-1424`, and `FilmLab.swift:560-576` (delete `threshold`/`boost` and
the false "matched at the half-power point" comment).
**Fix:** kernel `float ev = log2(max(e,1e-6)/clip); float t = smoothstep(-4.0, 0.0, ev);
out = t*e*exp2(0.3*t)` per channel. Pass `clipLevel`, `protectEV` and `boostRange`.
**Acceptance (macOS gpu-parity):** a flat-field GPU-vs-reference glow-mass test at E = 0.25,
0.5, 1, 4 with a 3% bound (today: 0, 0.61, 0.75, 0.94). Tighten
`testHalationGlowIsAsWideAsTheProfileSays` from 30% to 3%. Substituting the pedestal back must
turn both red.
**Pixels:** GPU halation only. The CPU proof records (`film.halation*`) do not move. The GPU
halation goldens move by up to 40% at low E and need to be re-baselined.

### M10 / C1-07 — Film Exposure must move halation onset
**DECISION NEEDED first.** Astra frames it as "tie to exposure or declare an independent
creative bloom". If tied, then:
**Fix:** `FilmLab.swift:1607` `halation(longEdgePixels:)` →
`clipLevel: pow(2, -filmExposure)` (and the same for `halationProfile`). That is
physically exact, because `highlightEnergy` is homogeneous: `H_{clip=1}(c·2^x)/2^x ==
H_{clip=2^-x}(c)`. The glow is added before the chain multiplies by `2^x`, so the glow
the film sees is correct. The GPU pedestal is homogeneous the same way, so M09 does not change this.
**Correction to C1-07's acceptance test.** "Exposure +2 on a 0.25 patch = exposure 0 on a
1.0 patch, same glow mass" fails under the correct fix, because the pre-chain masses
differ by exactly 2^x. Compare in the film-exposure domain instead:
`2^x · glowMass(x, c) == glowMass(0, c·2^x)` within 1e-9, for x ∈ {−2, +2, +3} and c ∈ {0.25, 1}.
Substituting `clipLevel: 1.0` back must turn it red.
**Pixels:** moves `film.exposure` if that record's recipe carries halation. Otherwise identity
at exposure 0.

### N-006 / C1-09 — normalise bounce weights
**Files:** `RenderGraph.swift:1430-1452` and `ReferenceRenderer.swift:492-502` should use
`profile.normalizedWeights[k]`. Multiply `HalationProfile.measuredStrength` and every stock's
`halationStrength` by 1.75 in the same commit so pixels stay the same, and remove the
`weights`/`decay` walk. **Acceptance:** the applied weights sum to 1 at `bounceCount` 3 and
4, and the reference halation output on Portra matches the pre-change output within
1e-12. The weights test goes red if raw weights are substituted back.
**Pixels:** none, by construction. If any record moves, the rescale is wrong.

### N-005 — retire it
Not a defect (see table). A one-paragraph change: correct the comment at
`FilmLab.swift:719-727` and dispositions N-005 to say the 0.088 is one draw from a null
distribution with sd ≈ 0.11, because the effective sample count is about 100, not 16 384.
Optional and a taste call (**DECISION NEEDED**): choose a `defaultPlateSeed` whose three
plates have abs(r) < 0.02. That moves every grain golden and every grain proof record, so I don't recommend it.

### NEW-V5-1/2/3
Each is a one-line `LookPanel` change plus a source-wiring assertion in
`AuditControlContractTests` / `FilmDisplayTransformAvailabilityTests`. NEW-V5-1 needs the
owner's decision first.

## Local commits
- `74482ff` "The halation rows' enable predicate was checked against two stocks, not the
  roster": `Tests/LumenCoreTests/HalationControlTests.swift` only. `HalationControlTests` is
  8/8 green on Linux. `scripts/check-swift-surface.py` exit 0. No pixels move.
- The commit adding this report.

Worktree branch: `worktree-agent-aa7444777c40c1b31` (based on trunk `a9a1d47`).
