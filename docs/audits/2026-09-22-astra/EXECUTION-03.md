# Verified repairs — execution record 03

## Parallel implementation scope

The owner explicitly approved three Astra implementation agents. Each works from the same committed safety checkpoint (`40e1048`) in an independent checkout and branch. No agent may merge, publish a release, install the app, or upload photographs. Root reviews and integrates tested commits into draft PR #5, then repeats combined regression checks.

The independent lanes are:

- AI-01 / AI-15: RAW decoder selection, colour boundary and immutable native dimensions.
- M01 / M02: referenced-mask source preparation and dependency-aware alpha invalidation.
- REL-06 / REL-07: source replacement, cache invalidation and exact preview provenance.

Red results before product changes: RAW **3 tests / 48 failed assertions** on all three private Sony RAW fixtures; referenced masks **5 tests / 10 failed assertions** through the actual GPU pipeline; source/preview caches **4 tests / 7 failed assertions** using real temporary-image replacements and a controlled publication interleaving. These are regression reproductions, not completed repairs; final verification follows integration.

## UI contract corrections (AI-09, AI-13, M13, M14)

New contract tests first ran **4 tests / 12 failed assertions** against the original controls. An initial missing test-initializer argument was corrected before this red run and is not counted as a product failure.

The implementation aligns Black target's typed range and binding with the existing engine ceiling of 9. Legacy values above 9 display their effective value without rewriting recipes on load; reset still clears the override. Grading Luminance help describes its actual 1.5-stop neutral-axis reach and notes zone limiting. Ramp shape help follows the actual inverse-gamma direction. All three halation controls are disabled for a stock with no halation response, with a visible explanation; stored creative parameters are retained.

Verification is a combination of numerical engine controls and source-level UI wiring assertions plus adjacent layout/mask/grading tests: **60 tests, zero failures**. Three existing layout precision expectations remain explicitly marked as expected failures by the inherited suite; they were not changed. A transient native build reported a metadata change on an unchanged source file; the successful build was rerun before counting tests. These checks do **not** replace hosted native interaction/accessibility verification. No image mathematics, tolerances, goldens, or intended stock look changed in this UI batch.

## AI-06 — full-range white-balance picker

The regression builds grey-card samples by inverting legal manual corrections, applies a different current WB, then asks the picker to recover a neutral. It covers negative and positive hard-range tints across 3,200–12,000 K plus ordinary sRGB-space controls. Before repair: **3 tests / 15 failed assertions**.

The coarse search and returned value now use the engine's full ±300 tint range. Forward evaluation retains the existing temperature-dependent physical tint guard. Simply expanding that range left one positive-tint case outside the unchanged 0.003 relative-channel residual limit. A bounded, strictly improving pattern-search refinement now follows the narrow Kelvin/tint minimum instead of being trapped inside the coarse seed's rectangular refinement window.

Final adjacent verification: **120 tests, zero failures**, including the new cases, existing WB/colour-preservation tests, tint guard tests and the existing picker bisection-cost bound. No tolerance changed. This improves sampled neutralization; it is not a universal claim about illuminant calibration or non-neutral objects selected with the picker.

## M01 / M02 — integrated referenced-mask changes

Agent commit `9b5d738` was reviewed and integrated as `9b14267`. Image preparation now follows reference dependencies, including disabled and inverted/transitive donors and explicitly requested disabled thumbnails. Alpha identity includes the selection-only dependency closure, referenced brush availability and matte generation. Local adjustments and cosmetic fields do not cause an alpha rebake.

The original **5 tests / 10 failed assertions** pass after repair. Expanded qualification passed **60 tests, zero failures**, including current-root/duplicate-target semantics, finite cycles, group-disabled donors, ordinary selection reuse, and regenerated same-kind mattes. An inherited adversarial test that intentionally documented the stale-root answer now rejects it. Cache memory/retention budgets are unchanged; larger retained raster caches remain a separate performance task.

Cross-review with the preview lane reproduced a further same-path Automask invalidation issue (**one test / one failure**, max linear channel difference 0.175399 versus a fresh renderer). Cache-clear races are being tested with semaphore-controlled work before repair. These follow-on changes and combined full-suite verification are not yet included in the counts above.

The follow-on repair was integrated as `51c1ca1` from agent commit `b70c699`. Deterministic clear regressions produced four failed assertions in two of three race tests; the same-key new-request negative control passed before and after. The repair clears Automask prefixes, gives old picture-dependent work a distinct source-generation key, and guards both alpha publication and queue bookkeeping against obsolete work. Broad agent qualification: **541 tests, 11 existing RAW-corpus skips, zero failures**. No original tolerance or golden changed. The preview lane supplies detection of actual source replacement.

## UX-02 — panel resize gesture

The production arithmetic was extracted without changing its behaviour, then exercised with repeated cumulative translations, overshoot/reversal, return to origin and a new gesture. Before repair: **2 tests / 5 failed assertions**. The calculation now holds one starting width through a gesture instead of repeatedly subtracting the full translation from the current width. Gesture completion and cancellation clear the starting value; persistence remains on completion.

Focused arithmetic and adjacent layout/state checks: **23 tests, zero failures** (the inherited layout expected failures remain unchanged). Native pointer-event and cancellation delivery are not established by these pure calculation checks.

## AI-01 / AI-15 — integrated RAW qualification

Agent commit `2efd71e` was reviewed and integrated as `1965507`. New sources use Apple's per-file selected decoder rather than forcing the last advertised version; supported explicit recipe pins remain honored. Native dimensions are captured before any scaled decode. Every RAW9 path, including its first native/export/picker request, now establishes a real extended-linear-sRGB evaluation boundary before conversion to the pipeline's extended-linear Rec2020 half-float buffer.

Beyond the original **3 tests / 48 failed assertions**, a fresh native first-read/cache test failed all **18 tile comparisons** across three private RAW fixtures before repair (worst absolute linear-channel error 0.547688). Qualification passed **129 tests, zero failures or skips**: 14 pipeline tests, 108 adjacent residency/draft/capture tests and 7 app budget tests. RAW9 native first/cache error is at most 0.000488; preview first/cache at most 0.001953, consistent with the final half-float buffer. Explicit decoder switches, unsupported-pin fallback and original dimensions also pass.

A synthetic nonzero-origin fixture exposed a separate materializer defect: correct extent metadata but zero pixels. Source-to-destination coordinate mapping is now explicit, with throwing render-task completion. Signed negative values, highlight headroom, alpha, tag, extent and byte accounting pass both evaluation paths. The independent RAW8 oracle matches its pre-existing half-intermediate evaluation contract; the RAW9 oracle uses float intermediates. Tolerances were not increased.

Limits: three Sony RAWs on one macOS/Apple Silicon host are not universal camera qualification. RAW9 now pays a full native demosaic and approximately 250 MiB at 33 MP even for a subsequent small picker read. The existing 512 MiB and 16,384-pixel allocation bounds remain; a required boundary that cannot allocate or render fails rather than returning wrongly coloured lazy pixels. Native RAW9 above roughly 67 MP needs a future tiled solution. Other decoders retain their previous lazy-first-native policy. Persistent cache revision invalidation is now integrated through the preview lane below. No photographs or original XMP data are committed.

## REL-06 / REL-07 — source generations and preview provenance

Agent commit `38f7083` was integrated as `fb2a990`. Source objects, thumbnails, signatures and registered source metadata now use a stat generation (device, inode, size, nanosecond modification/change times). Observed replacement clears source-dependent renderer caches. Metadata/signature work and preview publication recheck the captured generation; an old completion cannot certify new pixels. Developed previews carry their exact rendered recipe/source identity, and proofed, cropped-region, fallback or otherwise ineligible output cannot be published as a normal full-frame preview.

Preview payloads use a renderer-revision/source namespace and unique publication names. Stale registered payloads and failed/rejected publications are cleaned up. Cache path resolution rejects absolute paths, parent traversal and existing symlink escapes. The RAW change first raised the revision to 2; M05 below raises it to 3 so old local-softening pixels cannot survive either.

Agent qualification: **140 tests, zero failures or skips**, including 13 new regressions. Earlier red: **4 tests / 7 assertions**. The companion mask-generation tests are described above. This is not a filesystem watcher or atomic snapshot of an externally edited original: changes are detected on rescan/next request, some filesystems can evade the stat token, and metadata-only changes can cause harmless misses. Cross-platform compilation, broader network-volume testing, crash-orphan sweeps and RSS stress remain separate qualifications.

## REL-05 — indexed sidecar sibling lookup

Agent commit `ce9adf4` was integrated as `cf508cf`. The old resolver classified N(N−1) sibling candidates for N unique RAW names: 9,900 / 39,800 / 159,600 at N=100/200/400. The new directory-scoped basename index classifies each listed name once; 20,000 names and 80,000 lookups require 20,000 classifications. These deterministic counts, not elapsed-time thresholds, are the acceptance test.

Qualification: **161 tests, zero failures or skips**, including ownership/legacy/Adobe controls, unselected siblings, case/duplicate parity, directory isolation, rescan add/remove and 1,001 distinct synthetic registration rows. Ownership rules did not change. Listing/index creation now holds the existing memo lock, preventing old in-flight work from republishing after invalidation; slow/network directory contention remains a limit. Placeholder-file registration timings are not RAW decode or UI benchmarks.

## M05 — frame-denominated local softening

Agent commits `a58af77` and `e088737` were integrated as `d597019` and `d835ec8`. Negative local Sharpness now scales with the frame, preserving the original 2.5-pixel maximum at the 2,560-pixel reference. A small separable convolution matches the CPU's discrete Gaussian below one pixel; larger radii retain the existing Gaussian. Qualification: **149 tests, zero failures or skips**, covering CPU/GPU output across sizes, reference look, zero strength, the one-pixel transition and adjacent kernel/local/blend/robustness suites.

The initial scale probe measured CPU contrast retention 0.1455 at 512 pixels versus 0.9703 at 4,096; GPU 0.1394 versus 0.9690. One inherited liveness fixture was only 24 pixels wide, where the corrected radius falls below the existing no-op threshold. Its unchanged >0.0001 liveness assertion now uses a spatially resolved 1,024-pixel fixture. No numerical tolerance or golden changed. Brush coverage (M04) remains separate: a candidate single-stroke correction failed repeated paint/erase tests and is not included.

## REL-10 / REL-11 — delivered metadata

Agent commit `a2ad737` was integrated as `d9713fb`. JPEG now writes nested TIFF/JFIF density as well as the generic DPI pair; fractional TIFF density remains intact and pixels are not resampled. Contact uses standard IPTC creator email/website fields instead of the legacy key that ImageIO dropped. An explicit contact replaces an inherited contact block. Source-metadata removal remains before explicit additions.

Red: **5 native tests / 10 intended failed assertions** (eight missing contacts, two JPEG density failures). Green: **52 tests, zero failures or skips**, including 13 new tests, actual JPEG/HEIC/TIFF/PNG files and 10-bit HEIC. Independent property/XMP enumeration and `sips` readback confirm contact/density and unchanged dimensions; source immutability, privacy opt-outs, no-clobber and temporary cleanup controls pass. A preliminary HEIC copyright assertion was corrected to accept its existing standard TIFF alias before counting the red run.

The existing UI asks for one email or site. Unsupported nonempty prose is now rejected explicitly before rendering, not silently dropped or mislabeled; nil/blank remains allowed. UI validation/caption integration is described below. This is one OS/encoder's readback qualification, not every external metadata reader or camera-private field.

The UI follow-up was integrated as `3d8e25b` (agent `e49c15e`). Contact errors appear inline and identify/select the first offending enabled recipe in the footer; disabled-invalid presets do not block export, and both the button and action guard the batch. The old unverified-delivery note now states measured format coverage and reader limits. A separate malformed-host/email probe reproduced **14 failed assertions across five tests** before its narrow validator correction. Qualification: **49 tests, zero failures/skips**. Root's subsequent denoise/layout/export selection below also exercises the integrated validation. No preset string is rewritten by validation. The warning selects the recipe but does not auto-scroll to Contact; full native sheet layout is not yet verified.

## M15 — rendered-input denoise availability

The original mode choices were first extracted without changing behaviour. **Three new tests produced four failed assertions**: rendered inputs could select the decoder-only mode, its Amount was available, and a persisted unsupported recipe had no disabled-row/explanation contract. RAW mode availability was a passing negative control.

Rendered files now offer Off/Classic instead of a RAW-only AI stand-in. Older or pasted AI recipes are retained rather than rewritten during view construction: their Amount control is disabled and a visible explanation directs the photographer to Classic. RAW choices, amount behaviour, manually overridden Classic coupling and pixel mathematics are unchanged.

Integrated qualification: **108 tests, zero unexpected failures or skips**, covering availability contracts, capture/denoise/ISO behaviour, layout inventory/self-checks, export validation and actual-file metadata. Existing expected layout precision failures remain unchanged. These are pure capability/source-wiring checks plus adjacent engine/encoder tests, not a pointer-driven JPEG denoise demonstration. Slider source citations were updated to the new control locations, without altering metric limits.

## M03 — local-curve mask blend contract

Both the CPU reference and GPU S15b local-curve pass now apply the mask's Normal, Brightness-only or Colour-only blend before alpha interpolation. GPU local adjustments and local curves share the same compositor; Normal retains its existing kernel. Persistent preview rendering revision is raised to 4 so old local-curve results are not reused.

The corrected independent compositor regression first produced **4 tests / 43 failed assertions**, with Normal and neutral controls passing. An earlier oracle compared exact CPU curves directly with the existing GPU curve LUT and also caught unrelated approximation error; before the product fix, it was corrected to measure the Normal/unmasked GPU curve and independently apply blend algebra. This isolates the blend contract rather than loosening a curve-fidelity tolerance or claiming the LUT is exact.

Qualification: **115 tests, zero failures or skips**, including red-channel, luma and parametric curves, 50/100/200 strength, partial alpha, stacked curves, brightness chromaticity/colour luminance invariants, neutral controls, kernels, referenced masks, softening and preview invalidation. CPU and GPU compositor gates remain 1e-6. Signed/zero-luminance behaviour is covered by the adjacent existing blend tests; these new local-curve fixtures use positive colour. Native dropdown interaction and local-curve LUT fidelity remain separate qualifications.

## M06 — vignette in delivered crop coordinates

The S13 GPU vignette now receives the complete geometry, using the same source-to-oriented transform and target rectangle as final delivery. The shader transforms its coordinate field, not the photograph: vignette remains before halation and picture formation, with unchanged falloff, highlight protection and dither. Nonzero source origins are normalized consistently. The ellipse uses the integral rectangle Core Image actually delivers, including fractional and rotated crops. Persistent preview rendering revision is raised to 5.

Baseline red: **3 tests / 20 assertions** across off-centre crop/reflected flip, ±13°/±90° rotations, a translated source, and −4/0/+2 EV. The first correction fixed the main geometry failures but retained one +2 EV failure (0.00660 against 0.002). Explicit readback-bound accounting did not change that failure: the cause was fractional requested bounds versus Core Image's integral delivered crop. Aligning the product's ellipse to delivered bounds resolved it without relaxing the gate.

Qualification: **146 tests, zero failures or skips**, including all kernel goldens, crop arithmetic, vignette response/feather/banding, local-curve blends, the non-enabled exact Mixer, and integrated cache-count/publication regressions. Maximum observed error against an independently evaluated delivered-coordinate vignette is 4.98e-7 in linear channels. Axis-aligned default controls retain their existing response. This is production GPU geometry qualification, not a new full-geometry implementation for the software reference renderer or a pointer-driven crop workflow. Private-photo visual comparisons and a fresh combined full suite remain separate checks.

## Combined integration status

The first combined optimized run executed **2,470 tests, 14 skipped, six failed assertions**. Four were stale structural expectations: a fixed-width source scan no longer reached the decoder fork, five slider source addresses had shifted, and a precision test still expected the replaced Black target upper bound. Those expectations are corrected without deleting their checks. Two failures came from the existing draft-versus-settle timing ratio under concurrent work; no timing threshold was relaxed.

The second combined optimized run, including private RAW fixtures and the later commits above, executed **2,493 tests, 14 skipped, two failed assertions**. Both remaining failures are the unchanged timing ratio: Whites draft 7.43 ms versus settle 13.89 ms, and Saturation 2.13 versus 7.29 ms, against the existing 4× separation rule. A separate two-test probe still failed Whites (3.21 versus 9.77 ms), while other agent compilation was active. This is an open performance investigation, not proof that all failures are external noise. All other tests had no unexpected failures, including four explicitly expected AI-03 assertions and the inherited expected layout failures. The source checker's own 27 good/bad fixtures pass.

The subsequent timing investigation and stronger replacement regression are documented in [execution record 06](EXECUTION-06-plan-cost.md), integrated as `5fd2585`. Real per-slot counts disproved the ratio's synchronous-bake inference even during a coordinated quiet window. Four deliberate cache faults were detected by the replacement. This is a test correction, not a claimed product speed improvement; a fresh combined run is still required.

The published safety checkpoint `40e1048` passed every required main CI job plus the separate GPU and UI-layout workflows. Checkpoint `9836d68` also passed all required CI jobs and separate GPU/UI-layout workflows; its longer proof workflow was still running when this note was written. Release validation and publication were correctly skipped on this repair branch. These results do not certify newer unpushed commits.

The isolated native host opened a temporary two-photo catalog using copied inputs, without an updater or the installed library. Both the default decoder and explicit RAW9 reached the settled production viewer (the embedded-preview marker disappeared, and the scope declared the on-screen rendered frame). Local screenshots show natural colour without the prior cyan cast. The stock warning appears for Velvia and disappears for Portra. Native Undo removes the temporary film edit and exposes Redo; Redo restores the stock and warning. Normal quit persisted decoder9/Portra in the copied photo's XMP. This is a small native smoke test, not a complete interaction study or camera certification; small slider rows still lack adjustable accessibility semantics. The control-disabled source tests pass, but offscreen pointer interaction and resize gestures remain unverified because the inspection bridge returned `noWindowsAvailable` for coordinate/scroll actions. Its initial observation also took over 20 minutes; that delay is not attributed to Lumen rendering. Screenshots and private inputs remain local only.

AI-03 remains unresolved: four strict expected accuracy assertions now preserve the known failures against an independent exact-colour oracle. They are not repairs or passing fidelity results. See [the colour-table investigation](EXECUTION-04-colour-lut.md) for rejected approaches and the bounded exact-stage plan.
