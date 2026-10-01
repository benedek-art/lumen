# V4: colour science and RAW decode verification

Verifier: V4. Base: `claude/jolly-sagan-k7ch7z` at `a9a1d47`. Worktree branch
`worktree-agent-a5401831d908e4ddb`. Build dir `/tmp/lumen-build-v4`, Linux, swift
debug build. Each "red" below comes from substituting the fix out in the worktree,
rebuilding, running the filtered suite, and then restoring the file with `git checkout`.
LumenPipeline and LumenApp code was not compiled here: verdicts on that code say
"source-verified only". The macOS-only string tests in `AuditControlContractTests` were
reproduced with a Python copy of their exact assertions, run against the current
sources (green) and against the `2c70752^` sources (red).

(Written in the worktree because the session's isolation refused a write to the main-tree
path `/home/user/lumen/docs/audit-2026-10/verify/V4-colour-raw.md`. Committed on the worktree
branch so the orchestrator can lift it.)

## Verdict table

| Finding / commit | Verdict | Evidence |
|---|---|---|
| **AI-01** forced RAW9 + wide working space (1965507) | **INCOMPLETE** (source-verified only), plus **WEAK-TEST** on CI | The mechanism is correct for the reproduced trigger. `init` no longer forces `supportedDecoderVersions.last`, and Apple's per-file default is pinned (`AppleRawSource.swift:77-82`). Every RAW9 decode, whether a miss or a first native/inspection ask, goes through the required `DecodeMaterializer.materialize(…, evaluatingIn: .raw9LinearSRGB)`, which evaluates in extended-linear sRGB at RGBAf and writes an extended-linear Rec2020 RGBAh plane. If that fails it returns nil and never falls back to the lazy RAW9 image (`:396-399`). Cache hits store only materialized RAW9 entries (bytes > 0), so the promotion path cannot hand back a lazy RAW9 image. **Gap:** the boundary is selected by `filter.decoderVersion.rawValue == "9"` (`:396`). Every other decoder comparison in the file normalizes with `.filter(\.isNumber)`. Apple's DNG variants carry a suffix (`version8DNG` is `"8.dng"`), so a RAW9 DNG decoder named `"9.dng"` would skip the colour boundary and evaluate lazily in the Rec2020 context, which is the failure AI-01 reproduced. The private tests use the same `== "9"` check (`supportsRaw9`), so a DNG in the corpus would be skipped silently. **Tests:** `RawDecodeBoundaryTests` (always on, macOS) checks the materializer contract only. Every decoder-selection and pixel assertion is in `AuditRawAccuracyTests`, which `XCTSkip`s unless `LUMEN_AUDIT_RAW_DIR` is set. No workflow sets it, although `raw-corpus.yml` already downloads a 16-file public RAW corpus under `LUMEN_RAW_CORPUS` and runs only `--filter RawCorpusTests`. On CI, no test fails if `init` goes back to forcing `.last`. |
| **AI-15** RAW9 mutates nativeSize (1965507) | **CONFIRMED** (source-verified only), with a test gap noted | `originalNativeSize` is captured in `init` before any scaled decode. `nativeLongEdge`, `nativePixelSize` and `captureMetadata.pixelSize` all read it. Every renderer scale planner (`PipelineRenderer.swift:250,535,1605,1967,2414`, `RenderCoordinator.swift:396,435,598,609`) goes through those properties. No other read of `filter.nativeSize` remains in Sources. The private test asserts invariant metadata across scale, draft and cache transitions. It does **not** assert the delivered extent (`max(extent) ≈ scale × nativeLongEdge`), which is the 4× pixel-area symptom in the finding. That gap is minor, and the test is private and opt-in anyway (see AI-01). |
| **AI-06** WB picker tint range (41a50d8) | **WRONG on the number; fixed here** (b5a4ee0) | 41a50d8 widens the search to ±300 and adds a pattern search. Substituted out, `AuditWhiteBalancePickerTests` goes **15 assertions red** (2 of 3 tests). Restored, it is 3/3 green, so the range fix itself holds. **Disagreement with the September magenta guard:** the residual goes through `adaptation` → `chromaticity` → `clampedTint`, so every tint past `tintLimit(kelvin:)` renders identically. The search keeps the first grid or refinement point it meets past the bound and returns that number. Measured with as-shot 5500 K/0 and current identity: 2000 K returned **+10.0 where the render uses +3.546**, 2500 K returned 30.0 vs 29.738, 2800 K 45.83 vs 45.70, 3200 K 66.5 vs 66.30, 4000 K 101.0 vs 100.84. In a wider probe sweep the worst gap was 6.45 tint units, and the residual was always below 7.6e-5, so the pixels are right. The recipe stores the larger number, though, and `BasicPanel.boundedTintCaption` (threshold 0.5) would print "Magenta is bounded by physics at +4 for 2000 K" right after the user's own click. The September contract, `ColorTemperature.temperatureAndTint` ("reports the tint the render would actually use", pinned by `TintGuardTests.testTheEyedropperReportsATintTheRenderWillActuallyUse`), was not honoured by the WB picker. **Fix b5a4ee0:** the return value goes through `clampedTint` at the returned Kelvin. This is pixel-identical because `chromaticity` applies the same idempotent clamp. New test `testThePickerReportsTheTintTheRenderWillUse`: **12/15 red** without the clamp, green with it. With the fix: AuditWhiteBalancePickerTests 4/4, TintGuardTests 12/12, HuePreservationTests 27/27, EngineTests 58/58. Cost: the eyedropper does at most 92 bisections (guard < 300) and takes about 300 ms per pick in a **debug** build (no release timing taken). |
| **AI-09** Black target 9–15 identical (2c70752) | **CONFIRMED** (source-verified only for the UI half) | `DisplayTransform.swift:164-166` caps at `min(b, midGrey*0.5)` with `midGrey` a constant 0.18, so the effective ceiling is exactly 9 for every recipe. The row now uses `range 0...9, hardRange 0...9`, a get-clamp so legacy >9 overrides display as 9, and a set-clamp. `blackTarget` has no other UI writer. Python copy of the test's three string assertions: pass on HEAD, **3/3 fail on `2c70752^`**. The engine half (`tone(9) == tone(15)`) is a true identity. The test is `#if os(macOS)`, so it runs only on the macOS lane. |
| **AI-13** wheel Luminance tooltip (2c70752) | **CONFIRMED** (source-verified only for the UI half) | Help now reads "up to 1.5 stops on neutral tones each way. Overlapping zone edits may be eased…". Measured on Linux for **all four** wheels, not just the global one the test checks: global ±1.500 EV; shadows, mids and highs ±1.497–1.500 EV (where the joint limiter applies, `lumScale` is 0.998). The text is accurate for every wheel the shared help covers. Python copy of the string assertions: pass on HEAD, **2/2 fail on `2c70752^`**. |
| **AI-11** raw-double hash test | **CONFIRMED** | `GradeJointLimiterTests.testEitherSideUntouchedRendersBitIdentically` compares within the same process against `GradeEngine(…, forcingJointScale: 1)`. No transcribed constant remains, and there is no other FNV-of-`bitPattern` constant anywhere in Tests. Substitution: shipping `lumScale` nudged by one ulp (`lum.nextUp`, `jointScale` left at 1) turns **only the hash assertion red** (line 311). So the hash leg is live on its own and the per-recipe `jointScale == 1` check is not what catches it. GradeJointLimiterTests 11/11 green restored. Note: the test now guards "joint correction is identity on single-tool recipes" and no longer guards "nothing else in the grade engine moved". The proof registry covers the second; it is not a gap for AI-11. |
| **AI-12** Contrast clips highlights (89a43d1, fe3d38a, ec156b9 on top of 9bcac9f) | **CONFIRMED** | `contrastMapped` eases its slope to exactly 1 at the LIVE anchors (`reach = whiteAnchorEV − pivot`), using `smoothstep(0.2, 1, |d|/reach)`. Measured through `ToneEngine.stops` and the neutral `DisplayTransform`: the finding's sample (+3.5 EV, Contrast +100) now maps to 4.164 EV and **0.9704 display (not clipped)**. +4.5 EV at Contrast +50 gives 0.9921 and at +100 gives 0.9941. Display reaches 1.0 only at the anchor (+5 EV) at every setting. Substituting back the old window (`smoothstep(4, 12, |d|)`) turns EngineTests **422 assertions red** across `testContrastCannotPushAPixelPastTheDisplayAnchors` and `testTheContrastFixedPointFollowsTheAnchorsWhitesAndBlacksMove`. Restored, 58/58. The BasicPanel tooltip ("ends pinned, cannot clip a highlight") is now true. The documented exception, pivot pushed past the anchor at Whites ≥ +67, makes Contrast dead on that side; it does not clip (ec156b9). fe3d38a (log-scaled Render Contrast track) is view-only and moves no proof record. |
| **AI-14** wheel paint vs engine hue | **CONFIRMED** | The ring is painted through `Lumen.hueColor` (OKLCh → working → sRGB), and `WheelTint` reads `wheel.hue` as an OKLab ab angle. Substitutions: swapping cos/sin in `WheelTint` gives **WheelHueAgreementTests 49 red**. Restoring `Color(hue:saturation:brightness:)` for `wheelColors` gives **DesignSystemTests.testTheColourInstrumentsAreNotPaintedInHSB 2 red**. Residual measured on Linux with the same conversion: painted-stop hue error up to **4.3°** (at 210°, from the sRGB gamut clamp at L 0.72 / C 0.16) and up to 4.5° at gradient midpoints between the 30° stops. Before the fix it was a 29.6° mean and 50.3° worst. The paint side is pinned by a source-text count, not numerically. That is acceptable because `Lumen.hueColor` is shared with the mixer ring. |
| **000d345** mixer band names | **CONFIRMED** | Restoring "Green"/"Blue" turns `MixerBandNameTests.testEveryBandIsNamedForTheColourAtItsOwnCentre` **2 red** (43.29° and 31.76° against a 22.5° limit). Restored, 3/3 green. DominantBandTests 11/11. The rename is positional and moves no recipe or pixel. The remaining "Green" strings in LumenApp are `ColorLabel` (catalog flags) and unrelated. |
| **2c70752** control ranges and help (whole commit) | **CONFIRMED** (source-verified only) | Covers AI-09 and AI-13 above. The mask "Ramp shape" help direction matches `MaskRaster.levels` (γ 0.5 gives 0.25, so it holds back). The three Halation rows are disabled for zero-halation stocks, with a caption. All 12 Python-copied assertions pass on HEAD and **all 12 fail on `2c70752^`**. `LayoutMetricSupport` inventory updated (hard 0...9). |
| **AI-03** colour-table accuracy | **Still red; no production fix exists** | See "Where AI-03 stands" below. |

## Phase 2 specs (non-CONFIRMED)

### AI-01: RAW9 boundary selection on DNG decoders (source-level gap)
- **Files:** `Sources/LumenPipeline/AppleRawSource.swift:396`, and
  `Tests/LumenPipelineTests/AuditRawAccuracyTests.swift` (`supportsRaw9`, the `versions`
  loop in `testNativeDimensionsDoNotDependOnDecoderScaleDraftOrCache`, and `oracle`'s context choice).
- **Trigger:** a DNG (or any file) whose RAW9 decoder `rawValue` is not exactly `"9"`
  (for example `"9.dng"`, following `version8DNG == "8.dng"`), selected either as Apple's
  per-file default or through an explicit `develop.raw.decoderVersion = 9`. The `resolvedVersion`
  match uses numeric normalization, so 9 resolves to `"9.dng"`, but the boundary test fails
  and the lazy image is evaluated in the Rec2020 pipeline context.
- **Fix:** select the boundary with the same normalization used everywhere else, e.g.
  `Int(filter.decoderVersion.rawValue.filter(\.isNumber)) == 9`, factored as one static
  predicate used by the source and the private tests. Before touching the code, confirm on
  macOS 27 what `supportedDecoderVersions` returns for a DNG.
- **Acceptance:** a macOS test that builds `CIRAWDecoderVersion(rawValue: "9.dng")` and
  asserts the predicate is true, and false for `"8"`/`"8.dng"`. It must be red with
  `== "9"` and green with the predicate.

### AI-01 / AI-15: put the RAW qualification on a lane that can fail
- **Files:** `.github/workflows/raw-corpus.yml`, `AuditRawAccuracyTests.swift`.
- **Gap:** `AuditRawAccuracyTests` reads `LUMEN_AUDIT_RAW_DIR`, which no workflow sets. The
  corpus lane sets `LUMEN_RAW_CORPUS` and filters to `RawCorpusTests`. So
  `testUnpinnedSourceUsesTheDecoderAppleSelectedForTheFile`, which does not need RAW9 and
  would catch a return to forcing `.last` on any macOS, never runs in CI.
- **Fix:** have the corpus step also run `AuditRawAccuracyTests` with
  `LUMEN_AUDIT_RAW_DIR: ${{ env.CORPUS_DIR }}`, and extend the lane's "every manifest file was
  reached" guard to that class's `raw-pixel-check:` lines. The RAW9-specific tests will
  `XCTSkip` on runners without RAW9, and that skip must show in the lane summary.
- **Also (AI-15):** in the native-dimension test, assert the delivered size,
  `abs(max(extent.width, extent.height) − scale × longEdge) ≤ 2` for non-draft asks. That is the
  finding's 5120-for-2560 symptom, and today the test checks metadata only.
- **Acceptance:** the lane log shows the class executed on all corpus files. Locally,
  re-forcing `supportedDecoderVersions.last` in `init` turns
  `testUnpinnedSourceUsesTheDecoderAppleSelectedForTheFile` red on any file whose default is
  not its last supported version.

### AI-06: done here (b5a4ee0). Nothing left for Phase 2.

## Where AI-03 stands

**Status:** red confirmed, P1, open. There is no production repair on the trunk.
- `5e1cfb2` added `ColorTableAccuracyTests` (macOS GPU). Its four fidelity assertions (Aqua
  Mixer Luminance −100 and Basic Saturation +100, at 33³ and 65³) sit under **strict**
  `XCTExpectFailure`. A green aggregate run of that suite is not a fix.
- `0ae6776` added a **non-enabled** exact-Mixer primitive: `ColorEngine.exactMixer`,
  `LumenCore/Engine/ExactMixer.swift`, `LumenPipeline/ExactMixerGPU.swift`, and tests
  (`ExactMixerPrimitiveTests` 5/5 green here; the GPU tests are macOS only). No renderer selects it.
- EXECUTION-05 tried and rejected a per-recipe Mixer-only route. When any other control
  becomes nonzero, the route falls back to the combined cube, which is a **50.18-code jump
  (33³) / 36.91 (65³)** for a 0.001 move. `testShippingGraphHasNoNewMixerEligibilityBoundaryJump`
  now guards that boundary.
- **No Linux-lane test exists for AI-03.** It also reproduces on CPU with the tetrahedral
  sampler. Measured here with `RenderPlan.referenceColor` against `exactColor`: Aqua
  **39.8 / 35.8** codes (33/65), Saturation **12.2 / 37.4** (the 65³ cube is worse, matching
  EXECUTION-04's GPU numbers of 51.2/37.1 and 14.2/31.3).

**Smallest production fix, with the measurement behind it.** The two confirmed regressions
are both S9 (`ColorEngine`) families. The discontinuity EXECUTION-05 found comes from
switching routes per recipe, not from having an analytic stage. So the smallest fix that
closes the four expected failures without a routing jump is:

> Run the **whole of S9 (`ColorEngine.apply`) analytically and unconditionally**: one GPU
> kernel with a CPU twin, never per-recipe eligible. Keep **only S10 (`GradeEngine`)** in the
> colour cube, which is baked and skipped exactly as today when grade is identity.

I emulated this on CPU: exact `ColorEngine`, then a grade-only `LUT3D` sampled
tetrahedrally, then the shipping finish table.

| Case | CPU combined cube (33/65) | Exact S9 + grade-only cube (33/65) | Finish-table floor (33/65) |
|---|---|---|---|
| Aqua Mixer Lum −100 | 39.82 / 35.84 | **1.10 / 0.48** | 1.10 / 0.48 |
| Basic Saturation +100 | 12.25 / 37.42 | **1.42 / 0.28** | 1.42 / 0.28 |
| Aqua + Grade hue 0.001 (boundary) | 39.82 / 35.84 | **1.10 / 0.48** (no jump) | 1.10 / 0.48 |
| Aqua + Grade hue 180 | 39.59 / 35.59 | 1.18 / 0.23 | 1.11 / 0.20 |

The split reaches the finish-table floor, under the unchanged 3-code bound, and turning on
grade moves the result by less than 1e-4 codes. The work is EXECUTION-05 steps 1–5:
Primaries/Shadow tint, Mixer with Uniformity (measured band mean hues), ordered Point
Colour reading the pre-Mixer reference, Basic Colour (Vibrance/Saturation/Density/Skin/H-K),
and B&W reading `bandSource`. All of them go into one always-on S9 kernel. Steps 6–7 (exact
grade) remain for the separate grade-cube error. The same split has to reach every
consumer of the fused table: `RenderPlan.colorGradeLUT`, `RenderGraph`, the per-mask
`LocalPlan` bake, `ReferenceRenderer`/`referenceColor`, and the colour-mask source taps.
The persistent rendering revision needs a bump. **Pixels move for every proof record with
a non-identity ColorEngine** (mixer.*, color.*, pointColor.*, primaries.*, bw.*); the owner
re-pins them through proof.yml. **DECISION NEEDED** (owner): EXECUTION-05 recommends porting
S9 and S10 together. The measurement above says S9 alone closes the confirmed regressions
without a discontinuity, at the cost of leaving grade-family cube error (for example the
signed-domain and Grade-hue cases in EXECUTION-04) for a later step. Phase 2 should first
add a Linux CPU twin of the four expected failures (`referenceColor` vs `exactColor` on the
two inputs, recorded as a finding in the pattern used at `MaskDependencyAdversarialTests:545`),
so that engine-linux can see AI-03.

## Collateral observations (not regressions of the verified commits)
- **The D50 decoder pin is never persisted.** Nothing in Sources writes
  `develop.raw.decoderVersion`, and `CaptureMetadata.decoderVersion` has no consumer. Apple's
  per-file default is pinned per source object only, so if a macOS update changes a file's
  default, renders shift and the recipe fingerprint (`dv=-`) does not see it. 1965507's
  comments ("Explicit recipe pins remain honoured") are true, but only for recipes that
  arrive already carrying a version. **DECISION NEEDED** on whether first open should write
  the pin.
- RAW9 now materializes every decode, including draft rungs: about 250 MiB at 33 MP, and
  decodes above the 512 MiB ceiling fail closed (decodeFailed) rather than render cyan. This
  is a documented trade, and it is reachable only when RAW9 is the per-file default or explicitly pinned.
- 41a50d8 doubled the picker's coarse grid. It takes about 300 ms per pick in a debug build;
  release was not measured.

## Rendered-pixel impact of my commit
None. b5a4ee0 changes only the Kelvin/Tint numbers the WB picker *reports*. The rendered
matrix is bit-identical, and no proof record sweeps the picker.

## Local commits
- `b5a4ee0` The WB picker wrote magenta tints the render does not use
  (`Sources/LumenCore/Engine/WhiteBalanceEngine.swift`, `Tests/LumenCoreTests/AuditWhiteBalancePickerTests.swift`).
- The commit that adds this report (see `git log -1` on the branch).

Worktree branch: `worktree-agent-a5401831d908e4ddb` (reset onto `claude/jolly-sagan-k7ch7z`
`a9a1d47` before work; it had been created at the old `main`). `scripts/check-swift-surface.py`
exit 0. Nothing pushed.
