# Inherited Claude fixes — independent native qualification

Qualification branch: `codex/lumen-inherited-fix-verification`, based on `998fde887e359bbb8d7f41fafb33ee871c80c5d7`. Native macOS 27 / Apple Silicon / optimized Swift build, isolated scratch directory, two build jobs. No product source, original test threshold, original photo, or user catalog was changed. No network/upload/release action.

Qualification-only commit: `28bb43cc677c8ebbab1075f14a79ef6eab97c946` (two new native test files, six tests). Clean worktree; no push/merge. The report is kept outside the repository for root publication.

Integration: `75b4e15` on the repair branch. Root tightened the two new GPU kernel-availability guards from skip to ordinary failure: missing kernels must fail this native qualification. The measured 174-test run had no skips, so its results are unchanged; the integrated guards require a fresh run. This report is now published as repository context rather than remaining only in scratch.

## Outcome

| Finding | Qualified outcome |
| --- | --- |
| AI-11 | **Inherited fix verified on native arm64 within the same-process oracle's scope.** The architecture-dependent transcribed hash is gone; both implementations are compared on the executing machine. This run is not an additional Linux/x86 execution. |
| AI-12 | **Inherited partial improvement; red residual confirmed. Do not close as verified.** Both original audited clipping examples pass exact and real GPU checks, but an allowed moved-white-anchor / high-pivot combination still violates the pinned-endpoint claim and clips an originally unclipped highlight. |
| AI-14 | **Inherited hue-convention fix verified in the engine and actual SwiftUI paint colors.** In-gamut paint agrees within 0.001°; the shipped high-chroma ring still has bounded sRGB clipping error. Native pointer coordinates/gradient interpolation and physical display calibration are not certified. |

## Credit and source identity

These are **Claude's inherited improvements**, not new Astra production fixes:

- `1590e1f5790628a43b5a3a6533b1a0b704a736c2`: same-process grading hash comparison and the test-only `forcingJointScale` seam.
- `9bcac9fc1f8712feb25671f06624af07f5785588`: live-anchor contrast mapping, shared OKLCh wheel paint, initial regressions and independent fixture updates.
- `89a43d1`: contrast shoulder hold changed to 0.2 to retain midtone authority; `ec156b9` corrected the explanation to the shipped curve.

`ToneEngine.swift` and `GradeEngine.swift` are byte-identical to the audited newer Claude tip `a6e694103a3676e059847ac48b82c0031281ea53` in this qualification checkout. Their remaining contrast boundary behavior is inherited, not introduced by the later crop/cache repairs. No rollback or production correction was attempted.

## AI-11 — remove the cross-architecture oracle, preserve bit-identity scope

The old audit observed an Apple Silicon raw-double FNV hash of `5029306187037463546` versus the Linux-derived constant `12301920802024793674`, while semantic scale checks passed. Those are **historical audit values**, not newly remeasured hashes here.

Current `GradeJointLimiterTests.swift:292` constructs 312 single-tool recipes and 228 neutral/off-neutral probes per recipe: **71,136 color evaluations per implementation**. The shipping solver and `forcingJointScale: 1` predecessor model now run in the same process. Their FNV-1a hashes of raw output bits/scales are compared to each other, not to an architecture-specific literal. Per-recipe exact checks retain `jointScale == 1` and the unchanged applied Brilliance scale. `GradeEngine.swift:322` defaults the override to nil; no production caller supplies it.

All **11 GradeJointLimiterTests** passed natively, including the bit-identity comparison and composed-model/limiter controls. This verifies the repaired oracle on the shipping CPU architecture and structurally removes the particular portability mistake. It does not assert that different architectures produce identical raw floating-point bits, nor does this lane claim a fresh second-architecture execution.

## AI-12 — original examples improved, broader claim still false

### Original audited cases: verified improvement

Existing live-anchor, monotonicity, slope, fixture, limiter and GPU golden tests were run unchanged. New independent tests feed the original two audit cases through both `RenderPlan.exactColor` and real `RenderGraph` GPU output in linear Rec2020:

| Contrast | Scene EV | Contrast-mapped EV | Exact output (gray) | GPU33 RGB | GPU65 RGB |
| --- | --- | --- | --- | --- | --- |
| +100 | +3.5 | 4.164453125 | 0.970415514 | 0.945092 / 0.943833 / 0.942576 | 0.964042 / 0.963570 / 0.963078 |
| +50 | +4.5 | 4.558007813 | 0.992064233 | 0.990323 / 0.990297 / 0.990386 | 0.988060 / 0.987278 / 0.987825 |

All are finite, genuinely rendered, and below display white. Existing GPU parity bounds were retained (0.035 interactive / 0.018 export); no threshold was loosened. This is not a claim of exact CPU/GPU color fidelity—the known sampled-LUT error remains visible in the numbers.

The inherited ToneShippingGolden contrast +60 case also passes: maximum GPU/reference difference **0.01677 at 33** and **0.00992 at 65**, inside its unchanged bounds.

### Newly confirmed residual: allowed pivot lies above moved white

**Reachability:** the current Basic panel allows Whites +100 (`BasicPanel.swift:536`, range −100…100, no wider typed hard range), Pivot +4 (`:490`, range −4…4, hardRange nil) and Contrast −100 (`:476`, range −100…100, hardRange nil). The new App test reads these actual rows and checks the shared ToneRow/SliderTrack numeric resolution accepts those values. No hand-edited malformed recipe is needed.

**Trigger:** use Whites +100, Pivot +4, initially Contrast 0. Feed a neutral scene sample at +1.75 EV. Change only Contrast to −100.

- White anchor = **+3.5 EV**, below the allowed pivot +4.
- `contrastMapped(whiteAnchorEV)` = **3.8**, not the promised fixed point 3.5.
- Exact baseline RGB ≈ **0.787114644**; after Contrast −100, RGB is display white to floating-point precision.
- Shipping 33-table GPU baseline RGB = **(0.780876875, 0.777235985, 0.778023422)**; changed output = **(1,1,1)**.
- Shipping 65-table GPU baseline RGB = **(0.774283409, 0.774110734, 0.774361968)**; changed output = **(1,1,1)**.

`ToneEngine.swift:593–609` chooses the anchor by the sign of `t − pivot`. A white anchor below the pivot therefore takes the *lower*-anchor reach, so the side-specific zero-reach guard does not pin it. `stops(at:)` also adds the zonal tonal fields; the tests preserve the fixed-point violation and the actual composite-render clipping as separate claims, not as a claim that one local guard change would necessarily repair every composite interaction.

**Blind spot:** the inherited moved-anchor test varies Whites/Blacks with the default pivot; the pivot sweep uses default anchors. Neither intersects a moved white anchor with a pivot outside it. Monotonicity alone does not rule out flattening at display white.

**Ordinary red first:** six independent qualification tests ran with **four ordinary numeric failures**: moved anchor, exact output, 33 GPU clipping, 65 GPU clipping. Four tests passed; two tests failed. No availability/nonfinite/setup/control failure occurred. Log: `lumen-inherited-boundary-red.log`.

**Quarantine after red, not a repair:** only those four numeric assertions now sit in individually strict expected-failure scopes. Kernel availability, source construction, finite/nonblack output and the baseline-unclipped controls remain ordinary checks. Unexpected success will require revisiting the quarantine. No production code changed. AI-12 must remain **inherited partial / red confirmed**, with Claude's demonstrated improvements retained.

## AI-14 — read the actual native paint, not merely source text

Existing WheelHueAgreementTests (3) verify the engine offset's angle, saturation/chroma direction and exact neutrality; DesignSystemTests prevent the old HSB initializer in the app's color instruments. New App tests read actual `LumenColorWheel.wheelColors` through SwiftUI Color → NSColor → sRGB, independent of source spelling.

- 48 hue samples at in-gamut C = 0.04 agree with the engine's `WheelTint` direction within **0.001°**.
- The 13 real ring stops (12 unique angles plus the closing stop) match an independent OKLab → sRGB conversion route within **0.000001 per encoded channel**. The two closing colors agree.
- At the shipped L = 0.72 / C = 0.16, **4 of 12** unique stops require sRGB component clipping. Their round-trip error across the full ring is **mean 0.760516960° / maximum 4.275261272°**.
- The actual legacy SwiftUI HSB paint, recreated as a negative control at those same 12 angles, yields **mean 29.439322182° / maximum 49.472442364°**. These are new 12-stop measurements; the historical 24-angle 29.6°/50.3° numbers are not represented as a fresh rerun.

The shared hue convention is repaired and independently observed; “the paint always reproduces the exact selected hue” would still overstate gamut-limited display colors. The test reads color components, not a hosted gradient screenshot, click/drag trajectory, or a calibrated physical display. No camera/profile accuracy claim follows from this UI-paint verification.

## Runs and artifacts

- `lumen-inherited-existing.log`: **168 existing tests passed**, no failures/skips (141 core, 1 shipping GPU, 26 app); original thresholds unchanged.
- `lumen-inherited-independent.log`: initial 3 independent tests passed, no failures/skips (the original contrast cases plus two actual native paint checks).
- `lumen-inherited-contrast-boundary.log`: standalone exact-core boundary sweep; `InheritedContrastBoundaryProbe.swift` is the no-file-IO source alongside this report.
- `lumen-inherited-boundary-red.log`: the 6-test ordinary red described above, with the UI reachability control.
- `lumen-inherited-qualified.log`: final combined run **174 tests, 0 unexpected failures, 0 skips; 4 individually strict expected numeric failures**. Counts: 141 core + 4 pipeline + 29 app. Build 10.34 seconds; suite execution approximately 5.6 seconds. Six new native tests are in the two new qualification files. The expected failures are the confirmed unresolved AI-12 boundary, not a product repair.

All inputs were synthetic scene values or native color objects; no RAW file, personal photo, original catalog, or user-data network access was used. New regression files are native-only because they exercise Apple's GPU/UI APIs and strict expected-failure facility. Hosted Linux evidence, broader camera behavior, native pointer interaction, display calibration, and full mixed-control image coverage remain separate qualifications.
