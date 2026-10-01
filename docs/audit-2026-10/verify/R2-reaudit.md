# R2-reaudit: adversarial re-audit of the second landing batch

Re-auditor R2. Base: `origin/claude/jolly-sagan-k7ch7z` @ `cbe7c66`. P15-brush was not on it yet, so
I merged the local branches in this order: P15 (`…abab4979`), P13 (`…aa56ce42`), F2 (`…a057a438`),
P18 (`…ae222ea5`) and P14 (`…a8330061`). F3, F4 and P6 were already on the base. Build dir
`/tmp/lumen-build-r2`. The run was closed early by the orchestrator, so some items below are
source-only, and the report says which.

Two merge conflicts came up, and both were resolved by hand:
- **`CatalogStore.saveRecipe`, P13 against trunk.** This conflict is the interaction (a) asked about. See R2-1.
- **`ControlIndex` Film Lab aliases comment, P13 against F2.** I took F2's comment, because the aliases do move to `look.lut`.

After the merges and my fixes:
- `swift build --build-tests` is clean.
- `check-swift-surface.py` exits 0. It checks 42 kernel sources and 162 switches.
- 270 tests passed with 0 failures across Catalog, CanonicalJSON, CreativeLUT, SpotRetouch,
  ControlIndex, PasteSettings, RecipeCodecTolerance, SidecarNewerFormat, SidecarReseed,
  WorkspaceEntry, KeyGrammar, SliderEvidence, ResetSemantics, SavedLook, WorkspaceModification,
  SpotSection, DesignSystem, GrainParityScan, KernelRoster, EDRPreview and RawDecodeAcceptance.
  CanonicalJSON was red before R2-2.

## Verdict table

| Stream | What I checked | Verdict | Evidence |
|---|---|---|---|
| F4-heal × P13 M-02 | Whether the M-02 text clamp downgrades a spot recipe | **DEFECT on merge, FIXED** (`d91abfe`) | P13 clamped column and text to `currentPipelineVersion` (2). A spot recipe was stored as `{"pipelineVersion":2,…spots…}`, so a v2 build would overwrite the healing. With the clamp on `currentPipelineVersion`, the new test fails 5 assertions and P13's M-02 test fails 2. With `statedVersion` removed, it fails 2. Restored: green |
| P13 × F2 | Python fingerprint mirror vs the LUT stage | **DEFECT on merge, FIXED** (`994f0a6`) | P13 7609cd3 strips `look.lut` unconditionally and pins a fixture `lutNoStageReads` (Amount 100 = default fp). F2 now hashes a rendering LUT, so `CanonicalJSONTests.testEveryFixtureCaseIsReplayed` fails after the merge. The mirror now follows Swift. Mutation (Swift strip made unconditional): red on `lutRenders`. Restored: green |
| F4-heal | Version observer, newer-build guards, XMP round trip | CONFIRMED | `SpotRetouchTests` 16/16. `statedVersion` is raise-only. Paste Settings (P13 `adoptingSettings`) re-raises through the `develop` observer. `XMPSidecar.writableFields` compares against `supportedPipelineVersion` |
| F2-lut | Does a LUT recipe get downgraded or stripped on save? | CONFIRMED (no) | LUT keys are v2 vocabulary and raise no stated version, so the clamp cannot strip them. `CreativeLUTTests` 16/16 after the merge |
| F3-hdr | macOS API names | CONFIRMED, source-verified | Each member exists on macOS 15: `NSScreen.maximum(Potential)ExtendedDynamicRangeColorComponentValue`, `CAMetalLayer.wantsExtendedDynamicRangeContent`/`colorspace`/`framebufferOnly`, `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)`, `CIImage.samplingNearest/Linear`, `CIColor.clear`, `NSWindow.didChangeScreenNotification`, `CGColorSpace.extendedLinearSRGB`. The in-tree members `renderPreviewEDR` calls exist with these signatures after all merges (`decode(recipe:draft:scaleFactor:)`, `makeGraph(…maskRasterCeiling:)`, `PreviewDelivery(image:regionUnit:fullPixelSize:decodeMilliseconds:)`). P18's null-extent refusal sits in `AppleRawSource.decode`, so it covers the EDR path too |
| F4-heal | macOS API names | CONFIRMED, source-verified | `CIKernel.apply(extent:roiCallback:arguments:)`, `KernelLibrary.spotBoundary/spotApply/retouchAvailable`, `PipelineRenderer.buffer(from:context:)` and the `SpotGeometry` fields all exist. The CIKL sources compile only at runtime. Note: if they fail to compile, `retouchAvailable` is false and the GPU renders **without** spots silently. `KernelRoster` covers the names, not the compilation |
| P15-brush | `renderingRevision` bump | CONFIRMED (6 → 7) | Only P15 bumps it in this batch. P14's Density change also moves pixels for every recipe with Saturation > 0 and Density > 0 and did not bump it. Because both land in one push, the single bump to 7 covers both. **If P14 ships separately from P15, it needs its own bump.** |
| P15-brush | Fine-grid memory budget | **INCOMPLETE (perf), source-reasoned, not fixed** | See R2-3 |
| P14 | Density restore weight | CONFIRMED | My mutation: weight `smoothstep(0, gateHiChroma, C)`, an intermediate width not used by P14. Result: `testDensityHoldsHueAcrossItsWholeTravelOnTheTonalWedge` fails 20 times, up to 7.63°. Restored |
| P14 | Re-pinned proof records (`color.density`, `color.saturation`) | NOT RE-PROBED | I ran out of time. The re-pin rests on P14's own `ControlProbeHarness` agrees:true runs. The changed line is reachable only when Saturation > 0 and Density > 0, and I agree with that reachability argument. The GPU S9 bakes `ColorEngine` into the cube, so the GPU path takes the change automatically. `ExactMixerGPU` mirrors the mixer, not Density |
| P6-film | N-006 normalized bounce weights | CONFIRMED | My mutation: `strengthCalibration` 1.75 → 1.7. Result: `HalationControlTests` fails 15. Restored |
| P13 | Paste Settings stamp (b629b36) | CONFIRMED with a note | `max(target, source)` keeps a v3 stamp after pasting a spot-less develop over a spotted target. That over-states the version, which is safe: it only costs a v2 build write access to that photo |
| P18 | `RawDecodeAcceptance` | CONFIRMED (Linux tests green). I did not mutate it myself | Not re-mutated |

## R2-1: the clamp interaction (fixed, `d91abfe`)

`CatalogStore.saveRecipe` now stores `min(Recipe.statedVersion(recipe.pipelineVersion,
develop:), supportedPipelineVersion)` in both the column and the text.
- `supportedPipelineVersion` keeps a spot recipe at 3.
- `statedVersion` also raises a hand-made or sidecar-imported document that holds spots under "2". The decoder reports such a document as written, so before this it was stored at 2.

P13's M-02 test now uses `supportedPipelineVersion + 1` as "newer". A v3 recipe is this build's own.

**Remains (not fixed):** `CatalogService`'s sidecar stamp in LumenApp (`min(recipe.pipelineVersion,
supportedPipelineVersion)`) has the same hand-made-document gap. It should use `statedVersion`
in the same way. This is a one-line change and source-only.

## R2-2: the Python mirror (fixed, `994f0a6`)

`render_identity` now does three things, matching Swift:
- drops `look.lut` when `ref` is empty or Amount ≤ 0 (absent keys read as the decoder reads them: ref "", amount 100);
- otherwise blanks `name`;
- checks that renaming a LUT keeps the fingerprint.

The fixture swaps `lutNoStageReads` for `lutAtAmountZero` and `lutRenders`. Every other case is byte-identical.

## R2-3: P15 fine planes thrash the settle rung (spec, not fixed)

`BrushPlaneCache.store` sends any plane whose long edge is over `maskRasterLongEdge` (1024) to the
96 MB `settled` rung. Since 9c01936, a thin-stroke **draft** plane is painted at the fold size:
3072×2048, about 24 MB. So draft planes now compete with settle planes (4096×2731, about 44.7 MB at a 2048 fit) for the
same 96 MB. P15's report counts only settle planes ("two thin-stroke components held").

**Trigger.** Two thin-stroke brush components (one mask with two brush components, or two masks),
a fit of 2048 or less, and painting. Each stroke does draft A, draft B, settle A, settle B, which is 137 MB of
planes cycling through a 96 MB LRU:
- After settle B, the list keeps `[B-s, A-s]` and evicts both drafts.
- The next draft A misses, and the drafts then push A-s out.

In steady state every draft and every settle is a cold repaint of the whole set. P15's own numbers put a
cold repaint at about 4× its old cost (17.2 s vs 4.4 s at 2048 on this box). Before P15, the drafts sat in
the count-bounded `entries` rung (12 × 1024-px planes) and never touched this budget.

**Phase 2 spec.** File the rung by the REQUESTED raster size, not the plane size: a fine plane
for a draft request goes to a draft rung. Two ways to do that:
- `plane(…)` passes the requested size to `store`;
- or give fine draft planes their own small byte budget.

The owner decides the memory number. Acceptance: a macOS `MaskReferencePipelineTests` case
with two thin components at a 1024 draft and a 2048 settle, over three strokes, asserts
`BrushPlaneCache.currentStats.resumed` grows on every pass and `repainted` stays at its first-pass
count.

## Not done (time)

- I did not re-probe P14's two proof records with `ControlProbeHarness`.
- I did not mutate F3's LumenCore `EDRPreview` maths. Its 12 tests are green.
- I did not mutate P18's or P15's red/green myself. `BrushResolutionTests` and the mask suites were not
  re-run after the merge. Only the suites listed at the top were.

## Commits (worktree branch of `agent-acd084c346e07dc47`)

- Merge commits for P15, P13 (CatalogStore conflict resolved to `supportedPipelineVersion`), F2
  (ControlIndex comment), P18 and P14.
- `d91abfe`: catalog clamp honours the spots' version (R2-1).
- `994f0a6`: Python mirror follows the LUT stage (R2-2).
- This report.
