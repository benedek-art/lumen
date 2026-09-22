# Lumen — independent whole-app audit

## Verdict

Lumen is a substantial working photo editor with a credible creative foundation. It is not yet a dependable Lightroom replacement for important work. The problem is not simply that the sliders need a little tuning: several failures sit underneath them, in RAW decoding, lookup-table approximation, mask dependencies, coordinate systems, cache identity and saved-state ordering. Fixing a slider's visible response without first stabilizing those layers can calibrate it against the wrong pixels.

“80% done” is plausible as a description of the visible interface, but it is not a defensible estimate of the remaining engineering. The missing work includes both deep correctness and genuinely absent capabilities. This audit does not establish that Lumen is more accurate or faster than Lightroom, and it does not pretend to have found every possible defect.

No product fixes were made. No branches were merged, no commits or issues were posted, and no original photograph or user catalog was edited. Tests used a fresh checkout, isolated databases and copies of the supplied photographs. The `pix` folder contains three ARW files and two Lumen XMP sidecars, not five RAW files.

## Where you left off

The last merged version is `main` at `99c37272b42c211a04262ceb98cfb39355d1ab99`, September 3. Its merge brings twelve days of develop, masking, audit and repair work together. The final merged changes include saturation/hue corrections, highlight/shadow separation, joint tone/grade limiter work, and mask erosion fixes.

Newer work exists on `claude/photo-editor-design-plan-8ahzmm`, ending at `a6e694103a3676e059847ac48b82c0031281ea53`, September 6. That work includes contrast endpoint protection, grading-wheel hue agreement, mixer band naming, render-contrast slider travel, selected-file opening, zoom/layout changes and a corrected slider evidence atlas. These changes are not all in `main`. The user does not know which branch their installed build came from, so findings identify their branch applicability explicitly.

This matters: the failing cross-platform hash test is already repaired on that branch, and main's contrast-clipping finding is addressed there. But most of the severe new findings are in code unchanged by the branch, and its selected-file workflow adds two catalog regressions. A blanket merge is not an audited release strategy.

## What is genuinely good

- **A useful architecture.** A platform-independent recipe/math/catalog core, a separate Apple render pipeline, and a native application layer make controlled testing and targeted replacement possible. Non-destructive recipes, inspectable XMP and catalog backups are sound product choices even though some state transitions are currently unsafe.
- **Real creative depth.** The colour mixer, point colour, grading wheels, printer lights, curves, authored film responses, halation, grain and local colour tools are implemented. Mask components, references, folders, range selection and local curves/wheels can support sophisticated edits.
- **Working detail tools.** Independent pixel probes found all seven Classic denoise controls and all five manual sharpening controls live. Classic CPU/GPU agreement was very close on the tested fixture; meaningful noise/detail/edge-retention tests already exist. This is not a panel of placeholders.
- **Several careful interaction decisions.** Reciprocal temperature travel, separate soft/hard ranges, numeric entry, fine scrubbing, explicit reset semantics, embedded-preview labelling and histogram provenance are thoughtful. Native index-based navigation and workspace/panel flows worked in the isolated UI host.
- **Substantial existing test investment.** The suite contains numerical tests, production GPU tests, app-layer tests, adversarial cases and proof records. Historical defects really have been fixed; the detailed reports deliberately identify stale accusations that should not be repeated.

## What is most dangerous

### 1. The starting pixels are not reliable on this machine

On all three supplied Sony RAWs, fresh Lumen recipes force Apple decoder9 although Apple's per-file default is8. With Lumen's linear-Rec.2020 working space, decoder9 produces a strong red loss/cyan cast before the Lumen adjustment stack. The same file is healthy under decoder8. Further isolation shows decoder9 is healthy with the default/linear-sRGB working space and worsens with wider working spaces: this is a tested decoder/working-space integration failure, not a claim that all decoder9 processing is broken.

Apple explicitly describes RAW9 as opt-in, not the default. Apple DTS also documents a related custom-working-space tint problem for iPhone DNG; that is supporting platform context, not proof that the Sony reproduction is the same bug. [Apple RAW9 guidance](https://developer.apple.com/videos/play/wwdc2026/305/), [Apple DTS discussion](https://developer.apple.com/forums/thread/843445).

### 2. The GPU can disagree materially with the intended colour function

The chosen fixed-size colour cubes do not resolve some legal narrow-gated edits accurately enough. An independently checked Aqua luminance case differed by about37 encoded-code equivalents even at the65³ export table; the33³ preview differed by about51. A lifted-black luma curve also creates a near-black discontinuity and a purple cast in the actual GPU path. These are not fixed merely by making every control numerically nonzero or by comparing two renderers that share the same approximate table.

That error metric applies an sRGB transfer curve to working Rec.2020 RGB and scales the channel difference by 255. It is not Delta-E, a perceptual threshold or a literal final sRGB-pixel difference; the detailed colour report defines the test conditions.

### 3. A mask can render the wrong selection or a different strength

A disabled image-dependent donor can leave a referencing mask with no source picture, and inversion can turn the result into a whole-frame correction. Donor edits can also leave a borrower's cached alpha stale, including repeated final exports of small native images. Brush opacity and negative local sharpening vary strongly by resolution. Local curves bypass the chosen Brightness-only/Colour-only blend contract. These are trust failures in selective editing, not requests for more mask types.

### 4. Visible edits and persisted edits can disagree

Undo during an open slider gesture leaves the correct value in memory but flushes the pre-undo pending value into both the catalog and XMP. A preview can be stored with a newer recipe fingerprint despite containing older pixels. A temporarily locked healthy catalog can be mistaken for corruption and replaced with an older backup. Original replacement, sidecar naming transitions, ingest verification and export destination races have additional specific failure cases in the reliability report.

### 5. The newest branch can confuse photograph identity

Its common-parent calculation continues collecting matching path components after the first mismatch. Selecting similarly named files in sibling directory trees can therefore produce a false root and collapse two originals into the same catalog row; changing one recipe changes the other's catalog recipe. Separately, a selected subset is passed to a full-folder reconciliation operation, making unselected, still-present photos disappear from normal album queries until a full rescan.

## What is missing, not merely buggy

Healing/cloning/repair, perspective/Upright correction, local denoise, local defringe/moiré and several semantic mask types are recipe placeholders or unimplemented paths, not usable tools. Subject/background/aggregate-people Vision paths exist; sky/object/depth and per-person/body-part workflows are not equivalent completed capabilities. The app does not ship its own neural RAW-denoising model; its labelled AI stand-in uses Apple's decoder. Film stock names are authored models, not independently established matches to measured film scans.

HDR maths and recipe fields do not amount to a finished HDR viewport or gain-map export. The visible HDR preset/badge is especially confusing while the export sheet itself states that delivered files are plain SDR. These gaps should be removed from completion claims until their actual user workflows work.

For comparison, Adobe documents local masking curves, subject/sky/object/people selection and modern enhancement tools. Lumen's README claim that Lightroom lacks local curves is stale; that cannot count as a competitive advantage. Local wheels, mask references and portable Look separation are more defensible areas of creative differentiation, subject to fixing their correctness. [Adobe masking documentation](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/masking.html), [Adobe's introduction of masking curves](https://blog.adobe.com/en/publish/2023/04/18/new-adobe-lightroom-ai-innovations-empower-everyone-edit-like-pro), [Adobe enhancement documentation](https://helpx.adobe.com/lightroom-classic/help/enhance-details.html).

## The repair order I recommend

1. **Protect edits and identity.** Resolve catalog lock recovery, gesture/undo persistence, selected-file identity/subset reconciliation, sidecar transitions, ingest verification and export races. Acceptance: crash/restart, lock contention, rapid undo, source replacement and same-name originals cannot silently alter another photo or resurrect a rejected edit.
2. **Establish a trustworthy RAW baseline.** Pin a tested decoder policy, handle its working-space and state-dependent dimensions correctly, and keep the three supplied ARWs as local regression fixtures. Acceptance: neutral settings do not produce the observed cast; dimensions remain true before/after previews, zoom and export.
3. **Make render accuracy independent of approximation.** Compare actual GPU output against the intended exact functions at colour boundaries, near black, narrow selection ranges and extreme-but-legal values. Set explicit perceptual/code-value limits. Do not merely regenerate golden files until tests go green.
4. **Make masks invariant under context.** Test disabled/reference donors, edit invalidation, blends, group strength, preview/export resolutions and geometry combinations end to end. Acceptance: the same selection and intended strength survive preview, settle, export and reopen.
5. **Tune slider feel and speed against that stable pipeline.** Use useful midrange travel, small-step continuity, predictable combined controls, actual pointer-to-frame latency and final-quality settle latency. A fast stale draft and a correct current frame must be reported separately.
6. **Close personal-workflow gaps.** Prioritize healing, perspective and the mask/denoise tools you actually need before adding more film names or surface polish. Use a shoot-level acceptance checklist rather than percentage-complete language.
7. **Then decide whether to retire Lightroom.** Run the same representative shoot through both apps, blind-compare matched exports, and verify reopen, delivery metadata, printing and recovery. This audit has no calibrated Lightroom reference exports or exhaustive camera/lens dataset, so it cannot certify superiority.

## Audit coverage clarification

No defensible percentage of the application inspected was measured. This was a broad whole-app engineering audit with deep investigation of selected areas, not an exhaustive every-line, every-control-combination or every-workflow verification. “Audit complete” referred to finishing this investigation and its deliverables, not complete product certification. The original request was more exhaustive than the testing ultimately achieved.

Coverage varied between source tracing, existing executed tests, bespoke dynamic probes and actual interface inspection. Every native slider drag and brush gesture was not exercised; coordinate-driven pointer automation was unavailable. Real-photo testing used three Sony RAWs. Broader camera/lens validation, matched Lightroom comparisons, long-duration stability/memory tests, full accessibility testing and remaining end-to-end workflows are still needed before claiming readiness.

## How to read the evidence

The consolidated ledger contains 47 findings: 13 P1, 28 P2 and 6 P3. This includes known issues independently revalidated and three main-branch findings already fixed on the newer branch; it is not a claim of 47 newly discovered, still-open bugs. There are 327 recorded control roles, including shared roles and explicitly marked hidden/unavailable fields, not 327 independently certified sliders.

Execution covered 2,321 main baseline tests (12 skipped, one platform-dependent hash failure), all six optimized main control-proof tests covering 135 registry entries, and 2,398 tests on the newer branch (14 skipped, one timing failure). An isolated optimized rerun reproduced the newer branch's timing-target miss: draft plan construction was 26.8% of settle cost against a required below-25% ratio. That is an unresolved benchmark target, not proof of broken image output. The latest build was tested, while branch applicability of bespoke findings remains source-crosschecked unless stated otherwise.

Actual optimized main rendering was encouraging once warm: exposure changes had median6.6–8.6ms and95th-percentile9.3–19.0ms across the three photos at1536px. First previews took0.87–1.57seconds after source initialization, and native exports3.08–3.63seconds. These are pipeline measurements, not full pointer-to-screen latency. Fast colour-changing drafts deliberately served stale tables; their speed must not be confused with immediately correct pixels.

P1/P2/P3 are repair priorities, not counts of affected photos or estimates of effort. Each detailed finding records its trigger and scope. “Reproduced” means an executed counterexample; “source-confirmed” means the production code establishes the issue but the complete GUI workflow was not independently driven. Branch persistence based on unchanged source is labelled as such. Hypotheses are separate.

The control inventory distinguishes controls that moved pixels in a dedicated probe, controls covered by existing executed tests, source-traced controls, conditional controls and hidden model-only fields. It does not claim every combination, image type or aesthetic outcome was exhaustively certified. A green endpoint test proves a control is alive, not that its response is perceptually right.

The audit host inspected real production views but used an isolated application entry point and scratch library. Signing/file-provider and screen-capture limitations are documented and are not counted as product defects. The branch/version uncertainty is preserved rather than hidden.


## Finding index

| ID | Priority | Finding | Branch status |
|---|---|---|---|
| AI-01 | P1 | Forced Apple RAW9 plus Lumen's wide-gamut working space turns all three supplied Sony RAWs cyan | persists by source comparison; relevant math/call sites unchanged |
| AI-03 | P1 | Legal color edits lose substantial accuracy in both preview and export color tables | persists by source comparison; relevant math/call sites unchanged |
| BR-01 | P1 | Opening selected files from sibling trees can merge two photographs into one catalog identity | new in latest branch a6e6941; multi-file workflow absent on main |
| BR-02 | P1 | Opening a selected subset marks unselected photographs as missing | new latest-branch caller misuse of unchanged catalog API; main has no selected-subset caller |
| M01 | P1 | Disabled image-dependent donor fails to supply source to referenced mask | persists |
| M02 | P1 | Referenced donor edits do not invalidate borrower alpha cache | persists |
| REL-01 | P1 | Healthy exclusively locked catalog is restored from stale backup | persists; source identical |
| REL-02 | P1 | New same-basename RAW sibling inherits another photo's sidecar edits | persists; source identical |
| REL-03 | P1 | Already-present ingest certifies matching truncated source and destination | persists; source identical |
| REL-04 | P1 | Export final publication overwrites a file created during rendering | persists; source identical |
| REL-05 | P1 | Sidecar sibling resolution makes folder registration quadratic | persists; catalog and naming source identical |
| REL-12 | P1 | Test failures do not gate the automatic update release | persists; only test timeout/comments changed |
| UX-01 | P1 | Undo during a slider gesture saves the value that was just undone | persists by source comparison; apply/flush logic unchanged |
| AI-02 | P2 | Point Color picker and selection use different stages after mixer or primaries edits | persists by source comparison; relevant math/call sites unchanged |
| AI-04 | P2 | Luma curve black lift is discontinuous and makes neutral deep blacks purple on the GPU | persists by source comparison; relevant math/call sites unchanged |
| AI-05 | P2 | Point curve handles do not lie on the displayed composite trace when parametric edits are active | persists by source comparison; relevant math/call sites unchanged |
| AI-06 | P2 | WB neutral picker cannot reach the full tint range accepted by the slider | persists by source comparison; relevant math/call sites unchanged |
| AI-07 | P2 | Zone exposure combinations silently flatten broad tonal intervals | persists by source comparison; relevant math/call sites unchanged |
| AI-08 | P2 | Uniformity and Point Variance still operate without the texture-preserving local mean | persists by source comparison; relevant math/call sites unchanged |
| AI-11 | P2 | Main still has an architecture-dependent raw-double hash test already corrected on the other branch | fixed in newer Claude branch; current-main finding |
| AI-12 | P2 | Basic Contrast clips highlights despite promising pinned endpoints | fixed in newer Claude branch; current-main finding |
| AI-14 | P2 | Grading wheel painted hue and engine hue use different color systems on main | fixed in newer Claude branch; current-main finding |
| AI-15 | P2 | RAW9 changes mutable nativeSize after downscaled decode, breaking Lumen's preview scale contract | persists by source comparison; AppleRawSource and PipelineRenderer unchanged |
| M03 | P2 | Local curves ignore mask Brightness-only and Colour-only blend mode | persists |
| M04 | P2 | Brush alpha depends on raster resolution, not just source-normalized stroke | persists |
| M05 | P2 | Negative local Sharpness uses fixed 2.5-pixel blur | persists |
| M06 | P2 | Vignette positioned incorrectly after off-centre crop and horizontal flip | persists |
| M07 | P2 | Film Strength switches spatial effects on at full amplitude | persists |
| M08 | P2 | Display Transform disabled during partial film blend although still active | persists; Contrast .log travel branch change is unrelated |
| M09 | P2 | GPU halation gate materially under-produces low-highlight glow versus reference | persists |
| M10 | P2 | Film Exposure does not affect halation onset | persists |
| M11 | P2 | Mask Strength above100 scales Texture/Clarity only in GPU | persists |
| M15 | P2 | AI Amount enabled on rendered inputs without any denoise consumer | persists |
| REL-06 | P2 | Replacing an original at its URL retains stale source pixels, preview and quick signature | persists; source identical |
| REL-07 | P2 | Old developed preview receives a newer recipe fingerprint | persists; source identical |
| REL-08 | P2 | Catalog backup publishes final DB before blob backup can fail | persists; source identical |
| REL-09 | P2 | Sidecar write failure never invokes visible failure reporting | persists; source identical |
| REL-10 | P2 | JPEG encoder writes 72 PPI despite requested 240 PPI | persists; source identical |
| REL-11 | P2 | Supplied Contact metadata is absent in JPEG, HEIC, TIFF and PNG output | persists; source identical |
| UX-02 | P2 | Panel resizing accumulates the full gesture translation repeatedly | persists; same closure on latest branch |
| UX-03 | P2 | Custom editing sliders do not expose adjustable accessibility semantics | persists by source comparison; no slider accessibility modifiers added |
| AI-09 | P3 | Black target accepts values9–15 that render identically | persists by source comparison; relevant math/call sites unchanged |
| AI-10 | P3 | Geometric mixer band labels split common orange and green colors across neighboring controls | partially mitigated: names Green/Blue become Mint/Azure, underlying geometry unchanged |
| AI-13 | P3 | Wheel Luminance tooltip understates the actual scene exposure range by3x | persists by source comparison; relevant math/call sites unchanged |
| M12 | P3 | Custom60:1 and1:60 crop locks silently resolve to other ratios | persists |
| M13 | P3 | Ramp shape tooltip describes opposite direction from gamma formula | persists |
| M14 | P3 | Velvia exposes enabled Halation/Size/Redness despite zero-strength stage | persists |

## Detailed deliverables

- [Overview](details/overview.md)
- [Colour & RAW](details/colour-raw.md)
- [Masks & spatial tools](details/masks-spatial.md)
- [Reliability & performance](details/reliability.md)
- [Colour control inventory](details/colour-controls.md)
- [UI inspection notes](details/ui-inspection.md)
- [Test results](details/test-results.md)
- [Structured findings](findings.json)
- [Control inventory](control-inventory.json)

Standalone visual report: Lumen-Audit.html. Reproduction source/logs: evidence/. Actual UI captures: screenshots/. Photo and mask comparisons: image-evidence/. No RAW originals are included in this deliverable.
