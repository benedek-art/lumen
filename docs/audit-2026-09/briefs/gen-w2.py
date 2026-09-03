#!/usr/bin/env python3
"""Generate the 30 W2 audit briefs from one table, so a relaunch after a container
reset uses byte-identical prompts. Run from the repo root:

    python3 docs/audit-2026-09/briefs/gen-w2.py

Writes briefs/w2-common.md and briefs/w2-<code>.md. The known-open rows each area must
re-verify are pulled from ledger.md by area code at generation time.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AUDIT = ROOT / "docs/audit-2026-09"
BRIEFS = AUDIT / "briefs"

# code, title, files (exhaustive, repo-relative), the question, spec docs, gap-table area
AREAS = [
 ("A1", "Tone engine",
  ["Sources/LumenCore/Engine/ToneEngine.swift", "Sources/LumenCore/Engine/CurveStack.swift",
   "Sources/LumenCore/Engine/DisplayTransform.swift", "Sources/LumenCore/Recipe/Recipe.swift (Tone, Zones, CurveSet, ParametricCurve only)",
   "Sources/LumenCore/Model/ZoneWeights.swift", "Sources/LumenCore/Model/MonotoneCubic.swift",
   "Sources/LumenApp/ZonesPanel.swift", "Sources/LumenApp/CurveEditorView.swift", "Sources/LumenApp/BasicPanel.swift (Tone section only)"],
  "Is every tone control doing what its name says — monotonic, hue-stable, matched to the CPU reference at preview AND export scale? Where does it fall short of dt's sigmoid/filmic, LR's PV tone and C1's, in ways a photographer sees? Rendered (non-raw) files get a second display transform — what is the right rule?",
  ["docs/04-spec-tone.md", "docs/26-tone-baselines.md", "docs/27-slider-verification.md"], "A"),
 ("A2", "Slider feel & the control contract",
  ["Sources/LumenApp/LumenControls.swift (LumenSlider and the D45 contract — this area owns BEHAVIOUR; G2 owns its LOOK)",
   "Sources/LumenCore/Interaction/SliderDrag.swift", "Sources/LumenCore/Interaction/SliderEntry.swift", "Sources/LumenCore/Interaction/SpeedEdit.swift",
   "Sources/LumenCore/Interaction/DraftLadder.swift", "Sources/LumenCore/Interaction/EventRate.swift", "Sources/LumenCore/Interaction/HistoryCoalescing.swift",
   "Sources/LumenApp/DevelopPanel.swift (RecipeBinder and the footer)", "Sources/LumenApp/RenderRequest.swift"],
  "Drag precision, modifier keys, scrubby value entry, double-click reset, arrow nudge, type-in, undo granularity — against LR's and C1's slider grammar in the gap table. Is one drag exactly one undo step everywhere? Does any control publish per mouse event?",
  ["docs/12-spec-ux.md §12.5", "docs/24-slider-dossier-tone.md", "docs/29-keymap-reconciliation.md"], "A"),
 ("B1", "Colour science",
  ["Sources/LumenCore/Engine/WhiteBalanceEngine.swift", "Sources/LumenCore/Color/ColorSpaces.swift", "Sources/LumenCore/Color/Perceptual.swift",
   "Sources/LumenCore/Color/ColorMath.swift", "Sources/LumenCore/Color/LUT.swift", "Sources/LumenCore/Engine/ColorEngine.swift",
   "Sources/LumenCore/Recipe/Recipe.swift (RawParams, ColorAdjust, Mixer, MixerBand, PointColor only)"],
  "Correctness of chromatic adaptation, OKLab use, mixer band shapes and overlap, point-colour range/variance, vibrance vs saturation, skin protection, B&W mix — against C1's Color Editor and LR's HSL / Point Color / Calibration as the gap table states them. Hue stability under every control.",
  ["docs/05-spec-color.md", "docs/24-slider-dossier-color.md", "docs/audit/colour.md"], "B"),
 ("B2", "Grading",
  ["Sources/LumenCore/Engine/GradeEngine.swift", "Sources/LumenCore/Recipe/RecipeLook.swift (GradingWheels, Wheel, PrinterLights, Primaries only)",
   "Sources/LumenApp/LookPanel.swift (Colour Grading, Printer Lights and Primaries sections only)", "Sources/LumenApp/LumenControls.swift (LumenColorWheel only)"],
  "Wheel maths (K-044 inversion, K-049 pivots), zone weights, blending/balance semantics, printer lights — against LR Color Grading, C1 Color Balance and dt color balance rgb (R4 has the source lines). What keeps luminance monotonic in dt that Lumen lacks?",
  ["docs/05-spec-color.md", "docs/31-defect-audit.md round two #1, #6"], "B"),
 ("B3", "Colour panel UI",
  ["Sources/LumenApp/ColorPanel.swift"],
  "Can a photographer find and drive every colour control? MixerHueRing and MixerBandRibbon usability, swatch sampling and the eyedropper, the 'All bands' readout (K-042), B&W section, layout defects at 320/380/520 pt. Defects vs proposals kept apart.",
  ["docs/05-spec-color.md", "docs/28-ui-refresh.md §5.3", "docs/30-ui-rebuild.md"], "B"),
 ("C1", "Film engine",
  ["Sources/LumenCore/Engine/FilmLab.swift", "Sources/LumenCore/Recipe/RecipeLook.swift (FilmLab, FilmGrain, RenderParams only)",
   "Sources/LumenPipeline/RenderGraph.swift (S13 vignette+halation and the film chain only)", "Sources/LumenPipeline/Kernels.swift (addGlow, highlightEnergy only)",
   "Sources/LumenApp/LookPanel.swift (Film Lab and Display transform sections only)"],
  "Physical plausibility of the negative→print model, the stock roster against R7's 14-stock table, push/pull, halation (radius, threshold, colour; N-003 GPU mass 6% light), K-045 display-transform discard, Strength discontinuity. What R7 says is buildable in 24h — confirm or refute against the code.",
  ["docs/05-spec-color.md §Film Lab", "docs/audit/film.md", "w1/r7-film-grain.md"], "C"),
 ("C2", "Grain & halation UI",
  ["Sources/LumenCore/Recipe/Recipe.swift (CreativeGrain only)", "Sources/LumenCore/Recipe/RecipeLook.swift (FilmGrain only)",
   "Sources/LumenPipeline/Kernels.swift (grain only)", "Sources/LumenPipeline/RenderGraph.swift (grain placement only)", "Sources/LumenPipeline/PipelineRenderer.swift (exportedImage grain placement, K-065)",
   "Sources/LumenApp/EffectsPanel.swift (Grain section only)", "Tests/LumenCoreTests/CreativeGrainTests.swift"],
  "Why two grain systems; R7's merged-grain spec against both; size/roughness realism; resolution independence and preview↔export parity (R7 found a 0.5 px floor that breaks it and colour-stock blotching); K-065 grain-before-resize on export. Halation controls' UX.",
  ["docs/05-spec-color.md", "w1/r7-film-grain.md", "docs/33-speed-crop-and-the-blur-postmortem.md B2"], "C"),
 ("D1", "Looks & presets",
  ["Sources/LumenCore/Recipe/LookSubset.swift", "Sources/LumenCore/Recipe/RecipeLook.swift (Look, LUTReference, RenderParams only)",
   "Sources/LumenApp/AppState.swift (§Saved looks only)", "Sources/LumenApp/CatalogService.swift (looks only)", "Sources/LumenCore/Catalog/CatalogStore.swift (§Looks only)",
   "Sources/LumenApp/LookPanel.swift (Saved Looks section only)", "Sources/LumenApp/DevelopPanel.swift (Copy Look / Paste Look only)"],
  "What a 'look' carries vs LR presets (Amount, Adaptive, previews), C1 styles (layers, opacity), Luminar templates; the unreachable `look.lut` (import? or delete); K-027 Reset double tone map; K-010 presets with masks. Preset previews on the actual image — what would it cost here?",
  ["docs/05-spec-color.md", "docs/11-spec-output.md", "docs/31-defect-audit.md #13"], "D"),
 ("D2", "Effects",
  ["Sources/LumenCore/Image/DetailEngine.swift (S8 texture/clarity/dehaze and S13 vignette only — E2 owns sharpening in the same file)",
   "Sources/LumenCore/Image/SpatialOps.swift (dark-channel dehaze only)", "Sources/LumenPipeline/Kernels.swift (dehaze, detailGain*, detailRemap, vignette only)",
   "Sources/LumenApp/EffectsPanel.swift (Vignette, Lens Corrections, Soft Proof sections)", "Sources/LumenApp/BasicPanel.swift (Presence section only)"],
  "Halo behaviour of texture/clarity, dehaze colour cast and the missing GPU sky guard (K-090), Texture's measured weakness (K-099 — read the two reverted commits before proposing), vignette options against LR (style, midpoint, roundness, feather, highlights) and DxO ClearView.",
  ["docs/06-spec-detail.md", "docs/24-slider-dossier-detail.md", "docs/audit/detail.md"], "D"),
 ("E1", "Denoise",
  ["Sources/LumenCore/Image/DenoiseEngine.swift", "Sources/LumenCore/Recipe/Recipe.swift (Denoise, ClassicNR only)",
   "Sources/LumenApp/DetailPanel.swift (Noise Reduction section only)", "Sources/LumenPipeline/Kernels.swift (denoise*, hotPixel, bSpline5, box3, chromaMagnitude, mixChroma only)",
   "Sources/LumenPipeline/RenderGraph.swift (S3 only)", "Tests/LumenCoreTests/Proof/DenoiseQualityTests.swift"],
  "Quality on the ground-truth pair vs what R6 measured for NAFNet; ISO-aware defaults; K-028 wrong-overload reset; K-086 `.ai` on JPEG turns every stage off; K-087 reference starts at S6. Read R6's recommendation and say exactly where `AIDenoiseSplice` would be wired and what the classical engine keeps doing.",
  ["docs/07-spec-denoise.md", "w1/r6-denoise-decision.md", "docs/34-the-interactive-frame.md §5b"], "E"),
 ("E2", "Sharpening",
  ["Sources/LumenCore/Image/DetailEngine.swift (S4 capture sharpen and S12 sharpen only)", "Sources/LumenCore/Image/SpatialOps.swift (Richardson–Lucy only)",
   "Sources/LumenCore/Recipe/Recipe.swift (CaptureSharpen, ManualSharpen only)", "Sources/LumenCore/Export/ExportRecipe.swift (OutputSharpen only)",
   "Sources/LumenApp/DetailPanel.swift (Capture Sharpening and Sharpening sections only)", "Sources/LumenPipeline/Kernels.swift (sharpenDelta, edgeMap only)"],
  "K-075/K-088 capture radius stored and never applied, Richardson–Lucy uncalled and untested — wire or remove, with RT's capture sharpening (R4 has the source) as the reference; K-082/K-097 radius not in output pixels so export is less sharp than the judged frame; masking and halo suppression vs LR; output sharpening per medium.",
  ["docs/06-spec-detail.md", "docs/27-slider-verification.md §4", "w1/r4-opensource.md §E"], "E"),
 ("F1", "Mask canvas",
  ["Sources/LumenApp/MaskCanvas.swift", "Sources/LumenCore/Interaction/MaskHandles.swift", "Sources/LumenCore/Interaction/BrushStabilizer.swift",
   "Sources/LumenCore/Interaction/MaskOverlayRule.swift", "Sources/LumenApp/ViewerOverlays.swift (MaskOverlayView only)", "Sources/LumenCore/Model/BrushStroke.swift (geometry only)"],
  "\"Do everything in the circle.\" Hold every on-canvas gesture up against LR's grammar as R1 states it (move from inside, resize on edge handles, rotate on the edge, feather ring, ⌥/⇧/⌘ modifiers, duplicate, invert, pin behaviour): present / partial / absent, with the code path. K-004 brush pin, K-022 rotation units (re-verify after cc82116), polygon self-intersection, brush cursor/pressure/stabiliser, foreign pin swallowing pan.",
  ["docs/08-spec-masking.md", "docs/37-the-panel-audit.md §5.4", "w1/r1-lightroom.md §F"], "F"),
 ("F2", "Mask engine & performance",
  ["Sources/LumenCore/Image/MaskRaster.swift", "Sources/LumenPipeline/MaskGPU.swift", "Sources/LumenPipeline/MaskRasterCache.swift", "Sources/LumenPipeline/BrushPlaneCache.swift",
   "Sources/LumenPipeline/PipelineRenderer.swift (renderMaskAlpha, maskSource, mask raster sizing only)", "Sources/LumenPipeline/RenderGraph.swift (S11 local masks only)",
   "Sources/LumenPipeline/Kernels.swift (maskLinear, maskRadial, maskFold, maskInvert, blendMask, guided* only)", "Sources/LumenApp/AppState.swift (refreshMaskOverlay, refreshMaskThumbnails only)"],
  "N-001 just made the GPU fast path live for the first time — read gpu-parity's latest run for `MaskGPUParityTests` and report what it says. K-046 export mask edge at 1/1024; K-007 overlay reads the render's alpha; K-008 bounded local adjust; K-064 11 MP CPU mask at zoom; `renderMaskAlpha` bypassing every cache; `guidePlane` percentile sort; preview↔export parity of feather/refine/edge; `BrushPlaneCache` has no test.",
  ["docs/08-spec-masking.md §engine", "docs/36-masking-round-three.md", "docs/35-the-masking-rebuild.md §5"], "F"),
 ("F3", "Mask persistence & data integrity",
  ["Sources/LumenCore/XMP/XMPSidecar.swift", "Sources/LumenCore/XMP/XMPMerge.swift", "Sources/LumenCore/Model/BrushStroke.swift (encoding only)",
   "Sources/LumenCore/Catalog/BlobStore.swift", "Sources/LumenCore/Recipe/RecipeMasks.swift (Codable and validation only)",
   "Sources/LumenApp/AppState.swift (strokeSets, paste settings with masks, multi-photo edits only)", "Sources/LumenApp/CatalogService.swift (sidecar and blob paths only)"],
  "The data-loss set: strokes past ~26,300 points deleted by the sidecar; painting with a multi-photo selection overwriting other photos' strokes; inverted mask with a missing input selecting the whole frame; K-018 strokes outside both backups; K-015 same-basename sidecar collision. Round-trip fidelity of every MaskComponent field through XMP and the catalog.",
  ["docs/15-catalog.md", "docs/08-spec-masking.md", "docs/31-defect-audit.md data-loss"], "F"),
 ("F4", "Mask panel (post-rebuild)",
  ["Sources/LumenApp/MaskPanel.swift", "Sources/LumenApp/MaskFloatingPanel.swift", "Sources/LumenApp/AppState.swift (§mask overlay, maskPanel*, maskCreateBoardOpen only)",
   "Sources/LumenApp/LumenBehaviourGlyph.swift", "Sources/LumenCore/Recipe/RecipeMasks.swift (LocalAdjust.Group only)"],
  "A line-by-line Lightroom parity checklist of the panel as of 64ae6da against R1's Masks-panel section: every control LR has, present here or not; every defect visible in the code (widths at 272 pt, insets, pitch, dead state, controls wired to nothing — `brushParameters` was declared and uncalled until cc82116; find the next one). K-001 nine writers of `soloMaskOverlay`, K-003 Edge as a transfer graph, K-006 the register bundle, K-012 density.",
  ["docs/37-the-panel-audit.md", "docs/36-masking-round-three.md §6", "w1/r1-lightroom.md §F"], "F"),
 ("F5", "AI & range masks",
  ["Sources/LumenPipeline/VisionMattes.swift", "Sources/LumenCore/Image/MaskRaster.swift (lumaRange, luminosity, colorRange, similarity, similarityLine, aiSubject/Sky/Background/Object/Person/Landscape, depthRange only)",
   "Sources/LumenCore/Recipe/RecipeMasks.swift (MaskKind, LuminositySeries, MaskChannel only)", "Sources/LumenApp/MaskPanel.swift (range and AI component editors, kind rosters only)",
   "Sources/LumenApp/RenderCoordinator.swift (mattes only)", "Sources/LumenApp/AppState.swift (availableMattes, pendingMattes only)"],
  "Select Subject/Sky/Background quality and speed vs LR/C1/Luminar; K-084 unoffered kinds — confirm no path reaches them; K-085 matte orientation never verified (what test could?); `lumaRange` vs `luminosity` duplication; colour/luma range UX (eyedropper, range/feather handles) vs the gap table; per-person parts.",
  ["docs/08-spec-masking.md §AI", "docs/36-masking-round-three.md #8", "BUILDING.md §AI masks"], "F"),
 ("G1", "Panel layout & hierarchy",
  ["Sources/LumenApp/DevelopColumn.swift", "Sources/LumenApp/DevelopPanel.swift (DevelopSection, DevelopDisclosure, DevelopNote only)", "Sources/LumenApp/BasicPanel.swift",
   "Sources/LumenApp/DetailPanel.swift", "Sources/LumenApp/EffectsPanel.swift", "Sources/LumenApp/LookPanel.swift", "Sources/LumenApp/CropPanel.swift", "Sources/LumenApp/ZonesPanel.swift",
   "Sources/LumenApp/PanelLayout.swift"],
  "MEASURE. For every row in every panel at 320 / 380 / 520 pt: label width vs longest label, truncation, overflow, one-sided insets, row pitch, corner radius, heading orphaned from its content, box-in-box nesting depth, prose blocks that survive. Produce the checklist U2 will work from. Defects (S2) and taste proposals kept strictly apart — the direction is already decided (PLAN.md §UI direction).",
  ["docs/25-design-audit.md", "docs/28-ui-refresh.md", "docs/30-ui-rebuild.md", "docs/37-the-panel-audit.md §1"], "G"),
 ("G2", "Design system",
  ["Sources/LumenApp/LumenControls.swift (LOOK and consistency — A2 owns slider behaviour)", "Sources/LumenApp/LumenMenu.swift", "Sources/LumenApp/LumenSwitch.swift",
   "Sources/LumenApp/LumenSurface.swift", "Sources/LumenApp/LumenType.swift", "Sources/LumenApp/LumenBehaviourGlyph.swift", "Sources/LumenApp/LumenFocus.swift",
   "Sources/LumenApp/LumenHover.swift", "Sources/LumenApp/LumenScrollNudge.swift", "Sources/LumenApp/LumenViewerScroll.swift"],
  "Every token, size, radius, type size and colour actually used across the 54 app files vs the ladder (count them: how many distinct radii, pitches, font sizes exist?); contrast ratios; focus rings and hover states present/absent per component; dead components; duplicated primitives; K-035 cursor push/pop. The inventory U1 will implement against — with the target values from PLAN.md §UI direction.",
  ["docs/25-design-audit.md §1", "docs/12-spec-ux.md §12.7", "docs/28-ui-refresh.md §2.3"], "G"),
 ("G3", "Navigation & discoverability",
  ["Sources/LumenApp/Keymap.swift", "Sources/LumenCore/Interaction/KeyGrammar.swift", "Sources/LumenApp/ControlPalette.swift", "Sources/LumenCore/Interaction/ControlIndex.swift",
   "Sources/LumenApp/WorkspaceEntry.swift", "Sources/LumenCore/Interaction/Workspace.swift", "Sources/LumenApp/FilterBar.swift", "Sources/LumenApp/ContentView.swift",
   "Sources/LumenApp/LumenApp.swift", "Sources/LumenCore/Interaction/ArrowNavigation.swift", "Sources/LumenCore/Interaction/InspectionHolds.swift"],
  "Can every feature be reached and learned? Shortcut collisions; K-104 the decided key moves (L, B, ⌘B, F, S) — what exactly changes in Keymap/KeyGrammar/help; K-021 ⌘C/⌘V stealing text-field paste; K-005 next/prev mask; K-062 verify the rail fixed Cull's one-way door; K-094 Speed Edit; menu completeness; empty states; the help sheet. Against LR/C1 defaults in the gap table.",
  ["docs/12-spec-ux.md §12.3", "docs/29-keymap-reconciliation.md", "docs/30-ui-rebuild.md §2.4"], "G"),
 ("H1", "Viewer",
  ["Sources/LumenApp/LoupeView.swift", "Sources/LumenApp/ViewerOverlays.swift (all but MaskOverlayView and the crop overlays)", "Sources/LumenApp/CompareView.swift",
   "Sources/LumenApp/InspectionGain.swift", "Sources/LumenApp/LatencyHUD.swift", "Sources/LumenCore/Interaction/DraftLadder.swift", "Sources/LumenCore/Interaction/DraftResolution.swift",
   "Sources/LumenCore/Interaction/RefineBudget.swift", "Sources/LumenCore/Interaction/FrameDelivery.swift", "Sources/LumenCore/Interaction/ZoomLadder.swift",
   "Sources/LumenCore/Interaction/ContinuousZoom.swift", "Sources/LumenCore/Interaction/ViewerScroll.swift", "Sources/LumenCore/Interaction/ZoomRegion.swift", "Sources/LumenCore/Interaction/DecodeWarming.swift"],
  "Zoom grammar, progressive refine, before/after modes, pan feel, the 35 ms budget (w0/perf-baseline.md: drafts at 1280 are 60 ms p50 — why?), K-031 InspectionGain in body, K-032 ladder tautology, K-063 whole-sensor decode for a region; assessment mode and canvas-surround control (D46) — where they would go. HUD overlays as U4 will restyle them.",
  ["docs/12-spec-ux.md §12.2", "docs/34-the-interactive-frame.md", "docs/33-speed-crop-and-the-blur-postmortem.md"], "H"),
 ("H2", "Histogram & scopes",
  ["Sources/LumenCore/Image/Scopes.swift", "Sources/LumenCore/Image/RawTruth.swift", "Sources/LumenApp/HistogramView.swift", "Sources/LumenApp/ScopesView.swift",
   "Sources/LumenApp/ScopeData.swift", "Sources/LumenApp/RawTruthPanel.swift", "Sources/LumenApp/RawTruthFeed.swift"],
  "Correctness of every readout (which space, which clip thresholds, which proxy size), the draggable zones, the vectorscope's skin line, K-089 ⇧H is post-demosaic not CFA and the O overlay is unbuilt, K-098 waveform blank columns; speed of the feed per edit. Against LR's histogram interactions and C1's exposure warnings.",
  ["docs/04-spec-tone.md §histogram", "docs/10-spec-library.md §10.5", "docs/05-spec-color.md §scopes"], "H"),
 ("I1", "Render path",
  ["Sources/LumenApp/RenderCoordinator.swift", "Sources/LumenPipeline/PipelineRenderer.swift (render path — not export, not masks)", "Sources/LumenPipeline/RenderGraph.swift (stage order and graph assembly — not S11 local, not kernels)",
   "Sources/LumenCore/Engine/RenderPlan.swift", "Sources/LumenCore/Engine/PlanTableCache.swift", "Sources/LumenApp/RenderRequest.swift", "Sources/LumenApp/EditRevision.swift"],
  "The edit→frame path with NUMBERS: N-002 settle bakes tables every frame with zero hits (Whites 388 ms); K-047 stale-table cross-photo door; K-060 untouched recipe not a passthrough; K-063; redundant passes; actor contention; `@Published` fan-out re-bodies (the EditRevision rule is enforced by comment only — check every reader of currentRecipe declares it).",
  ["docs/14-pipeline.md", "docs/34-the-interactive-frame.md", "docs/23-master-plan.md §diagnosis"], "I"),
 ("I2", "Kernels vs the reference",
  ["Sources/LumenPipeline/Kernels.swift (every kernel)", "Sources/LumenCore/Engine/ReferenceRenderer.swift", "Sources/LumenCore/Image/ImageBuffer.swift",
   "Tests/LumenPipelineTests/KernelGoldenTests.swift (read the goldens' tolerances)"],
  "Per kernel: matches the reference? precision (K-050 fp16 log plane), clamping (K-048 log-luminance floor — now floored; verify), edge handling, ROI correctness for the general kernels, fusable passes; N-003 halation mass; TEXSPEC gpu/ref 0.74 at 3 px — why. Which goldens have tolerances loose enough to hide a defect.",
  ["docs/14-pipeline.md", "docs/20-proof-standard.md P5", "w0/perf-baseline.md"], "I"),
 ("I3", "Decode & memory",
  ["Sources/LumenPipeline/AppleRawSource.swift", "Sources/LumenPipeline/DecodeMaterializer.swift", "Sources/LumenPipeline/ImageSource.swift", "Sources/LumenPipeline/CaptureMetadataReader.swift",
   "Sources/LumenApp/ThumbnailLoader.swift", "Sources/LumenApp/PreviewStore.swift", "Sources/LumenCore/Catalog/PreviewCache.swift", "Sources/LumenCore/Interaction/DecodeWarming.swift",
   "Sources/LumenCore/Interaction/ThumbnailLadder.swift", "Sources/LumenApp/RenderCoordinator.swift (source cache and trimDecodeResidency only)"],
  "Cold-open path and cost, memory ceiling on 45 MP (K-036), cache keying and eviction across the six caches, embedded-preview path, decode warming, what a rendered (JPEG/HEIC) source gets wrong (K-091). Every cache: what it keys on, what it can serve stale, whether a test proves it.",
  ["docs/13-architecture.md", "docs/34-the-interactive-frame.md §5", "docs/10-spec-library.md §10.1"], "I"),
 ("J1", "Catalog store",
  ["Sources/LumenCore/Catalog/CatalogStore.swift", "Sources/LumenCore/Catalog/SQLite.swift", "Sources/LumenCore/Catalog/Schema.swift", "Sources/LumenCore/Catalog/PhotoMetadata.swift",
   "Sources/LumenCore/Catalog/QuickSignature.swift", "Sources/LumenApp/CatalogService.swift (threading and sidecar discipline)", "Sources/LumenApp/LumenApp.swift (close/backup wiring only)"],
  "Data safety: transactions, WAL, crash mid-write, K-017 catalog loss notice, K-019 backup never pruned, K-052 FTS never rebuilt, K-053/K-054 label and rating loss, K-055 no LIMIT per keystroke, K-056 first-open cost, K-057 prefix vs infix, K-059 pivot robustness; scan reconciliation correctness on rename/move.",
  ["docs/15-catalog.md", "docs/31-defect-audit.md round two", "docs/audit/library-ux.md"], "J"),
 ("J2", "Library & culling UX",
  ["Sources/LumenApp/GridView.swift", "Sources/LumenApp/FilmstripView.swift", "Sources/LumenApp/FilterBar.swift (behaviour — G3 owns its navigation role)", "Sources/LumenApp/ContentView.swift (Sidebar sections only)",
   "Sources/LumenApp/AppState.swift (§Library, §Culling actions, §Selection only)", "Sources/LumenCore/Interaction/ArrowNavigation.swift", "Sources/LumenCore/Interaction/ThumbnailLadder.swift", "Sources/LumenCore/Catalog/CatalogStore.swift (culling state, collections, stacks, keywords only)"],
  "Cull speed grammar against Photo Mechanic / LR Library / C1 Cull (R2): keys, auto-advance, survey/compare, flags/ratings/labels/keywords/stacks/albums completeness; selection model; K-066 grid scrolling never profiled; K-101 frame score unbuilt; the filter's live counts.",
  ["docs/10-spec-library.md", "docs/12-spec-ux.md §12.3", "w1/r2-captureone.md §J"], "J"),
 ("J3", "Export & ingest",
  ["Sources/LumenApp/ExportSheet.swift", "Sources/LumenCore/Export/ExportRecipe.swift", "Sources/LumenCore/Export/Dither.swift", "Sources/LumenCore/Export/SoftProofTransform.swift",
   "Sources/LumenApp/AppStateActions.swift", "Sources/LumenPipeline/PipelineRenderer.swift (export, exportedImage, renderHDRPair, write, applyMetadataPolicy only)",
   "Sources/LumenApp/IngestSheet.swift", "Sources/LumenCore/Ingest/RenameTemplate.swift", "Sources/LumenApp/DevelopColumn.swift (ExportRecipesSection only)"],
  "K-016 preset `try?` wipe, K-024 don't-resize resamples, K-025 Lanczos rim, K-026 metadata base dictionary, K-033 actor held for the batch, K-051 soft-proof perceptual clip, K-065 grain before resize, K-096 silent stage degradation on export, K-067 never profiled; export presets and resize modes vs LR/C1; K-100 ingest — ship or remove, with what it would take to ship.",
  ["docs/11-spec-output.md", "docs/10-spec-library.md §10.6", "docs/31-defect-audit.md correctness"], "J"),
 ("K", "Crop, lens & geometry",
  ["Sources/LumenCore/Model/CropGeometry.swift", "Sources/LumenCore/Model/Straighten.swift", "Sources/LumenApp/CropPanel.swift",
   "Sources/LumenApp/ViewerOverlays.swift (CropOverlayView, StraightenOverlayView only)", "Sources/LumenCore/Interaction/FrameOrientation.swift",
   "Sources/LumenCore/Recipe/Recipe.swift (Geometry, Crop, Upright, LensCorrections, Defringe, Heal only)", "Sources/LumenApp/EffectsPanel.swift (Lens Corrections section only)"],
  "Crop tool grammar vs LR (overlay cycling, aspect lock K-023 broken by angle, straighten ruler, R R reset), K-029 ⌘K arms crop without a panel; Upright/perspective and removeCA/defringe exist in the model with no UI — surface or delete, and what DxO's/LR's lens modules would require; K-093 Heal with no stage.",
  ["docs/09-spec-geometry.md", "docs/33-speed-crop-and-the-blur-postmortem.md Stream C", "docs/audit/geometry-output.md"], "K"),
 ("L", "State, history & app integrity",
  ["Sources/LumenApp/AppState.swift (structure, publication, editing, undo, gestures — not the library/mask sections other areas own)", "Sources/LumenApp/HistoryStack.swift",
   "Sources/LumenCore/Interaction/HistoryCoalescing.swift", "Sources/LumenApp/EditRevision.swift", "Sources/LumenApp/CommandState.swift", "Sources/LumenApp/AppUpdater.swift (read-only; frozen file — findings only)"],
  "Undo correctness (K-038 shared coalescing keys), the 'deliberately not published' rules honoured everywhere (K-030 zoomLevel publishes per pinch), force-unwraps and main-thread blocking (K-034), whether the L0 extension split in PLAN.md §W5 is feasible as drawn (which privates cross the boundary), updater safety.",
  ["docs/13-architecture.md §concurrency", "docs/23-master-plan.md §diagnosis", "docs/31-defect-audit.md perf"], "L"),
 ("M", "Recipe & serialization",
  ["Sources/LumenCore/Recipe/Recipe.swift (the Codable surface, versioning, defaults, renderIdentity)", "Sources/LumenCore/Recipe/RecipeLook.swift (Codable)", "Sources/LumenCore/Recipe/RecipeMasks.swift (Codable)",
   "Sources/LumenCore/Recipe/CanonicalJSON.swift", "Sources/LumenCore/Recipe/Fingerprint.swift", "Sources/LumenCore/Recipe/RecipeDecoding.swift", "Sources/LumenCore/XMP/XMPSidecar.swift (recipe encoding only)",
   "scripts/gen-fixtures.py (the recipe mirror, lines ~328–530)"],
  "Forward/backward compatibility, K-020 silent downgrade, K-043 dead wire fields (LocalAdjust ×5, Upright ×8, Heal, LUT) — delete vs keep with the pipelineVersion cost of each, K-059 pivot robustness, paste-settings subsets, fingerprint stability, and exactly what the fixtures mirror requires of any field change (the fixtures ceremony in PLAN.md).",
  ["docs/15-catalog.md §recipe", "docs/14-pipeline.md §pipelineVersion", "scripts/gen-fixtures.py header"], "M"),
]

COMMON = """# W2 audit — common brief

You are one of thirty auditors. You own ONE area, listed in your own brief. Thirty
people reading the same 76k lines for different questions is only efficient if each
reads exactly their files for exactly their question — so stay inside your list, and
where a file is shared, answer only the question your brief says you own in it.

## Read first, in this order
1. `docs/audit-2026-09/PLAN.md` — the plan; especially §"Decisions already taken" and,
   for UI areas, §"The UI direction" (the direction is DECIDED; do not re-propose one).
2. `docs/00-vision.md` — the laws. `docs/12-spec-ux.md` for anything UI. `docs/20-proof-standard.md` — what "proven" means here.
3. Your area's spec docs (in your brief).
4. `docs/audit-2026-09/w1/gap-table.md` — your area's section: how the competitors do
   it and what Lumen has. (If the file is not there yet, read the relevant `w1/r*.md`
   sections directly.)
5. Your area's rows of `docs/audit-2026-09/ledger.md` (listed in your brief).
6. Then EVERY LINE of your owned files. Not a skim. The defects this codebase ships
   are "built but unwired" and "comment says X, code does Y" — neither is visible from
   a summary.

## Two lessons from this morning, so you do not repeat them
- **A green lane is not evidence.** `MaskGPUParityTests` was green for months because
  it skipped itself (`XCTSkipUnless`) when the kernels it tests failed to compile. Look
  for skips, for sentinels whose roster is incomplete, for tests that pass when the
  feature's call site is deleted. Cite them as findings.
- **The comment is not the code.** `componentParameters` returned `EmptyView()` for
  brushes with a comment saying the brush zone draws them — and the brush zone had
  been deleted. Read what the code reaches, not what the prose says it reaches.

## Known-open rows first
For each `K-nnn` row assigned to you: STILL-OPEN / FIXED-SINCE / CHANGED (say what
changed), with `file:line` evidence. One line each. Do not re-describe the finding;
cite its id. If you find it was never true, say REJECTED and why.

## Then new findings — at most 20, ranked, prefer fewer and stronger
Each finding, in this exact shape:

```
### <AREA>-<nn> — <title, one line>
severity: S1 | S2 | S3          (S1 data loss / crash / wrong pixels / silent no-op control;
                                 S2 visible defect or parity gap; S3 polish)
confidence: measured | traced | inferred
class: defect | parity-gap | proposal(taste)
size: S | M | L
evidence: <file:line> — quoted code, and for perf a NUMBER or a traced call count
how the owner sees it: <one or two sentences — what happens on screen / to the file>
fix: <files, approach, and THE TEST that goes red with the defect substituted back>
```
"Slow", "confusing", "could be better" are not findings without a number, a trace, or a
concrete gap-table row. A `proposal(taste)` must say which decided direction it fits.

## Output
- Write `docs/audit-2026-09/w2/<code>.md`: a header with your area and files read,
  the known-open dispositions, then the findings.
- Return a ≤150-word receipt: counts by severity, the two findings you are surest of,
  the file path. The file is the deliverable; the return is a receipt.

## Rules
- READ-ONLY. No edits to any file except your own output. No git. No builds that write
  (you may run `swift test --filter <X>` on LumenCore; never `swift build` of the app —
  LumenApp and LumenPipeline do not compile here and that is expected).
- 30 minutes. Past that, write what you have, mark the file PARTIAL at the top, return.
- No model names, no session ids in the file.
"""

def ledger_rows():
    """Every K-/N- row as (id, area, severity, source, finding). Split on the cell
    separator rather than a regex: the trailing verdict/disposition cells are empty
    until W4, and an empty cell is `| |`, which a `\\| [^|]* \\|` pattern cannot see."""
    rows = []
    for line in (AUDIT / "ledger.md").read_text().splitlines():
        if not line.startswith("| K-") and not line.startswith("| N-"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        rows.append((cells[0], cells[1], cells[2], cells[3], cells[4]))
    return rows

def area_matches(code, area_field):
    parts = [p.strip() for p in area_field.split("/")]
    for p in parts:
        if p == code:
            return True
        if len(p) == 1 and code.startswith(p):   # bare 'E', 'F', 'J' → every sub-area
            return True
    return False

def main():
    BRIEFS.mkdir(parents=True, exist_ok=True)
    (BRIEFS / "w2-common.md").write_text(COMMON)
    rows = ledger_rows()
    written = []
    for code, title, files, question, specs, gap in AREAS:
        mine = [r for r in rows if area_matches(code, r[1])]
        cross = [r for r in rows if r[1] in ("misc", "tooling", "—")]
        out = [f"# W2 — {code} · {title}", "",
               "Read `briefs/w2-common.md` first. Output: `docs/audit-2026-09/w2/" + code + ".md`.", "",
               "## The question", question, "",
               "## Files you own (read every line)"]
        out += [f"- `{f}`" for f in files]
        out += ["", "## Spec and prior audit to read"] + [f"- `{s}`" for s in specs]
        out += [f"- `docs/audit-2026-09/w1/gap-table.md` §{gap}", ""]
        out += ["## Known-open rows to re-verify (STILL-OPEN / FIXED-SINCE / CHANGED / REJECTED, with file:line)"]
        out += [f"- **{r[0]}** ({r[2] or '—'}, {r[3]}): {r[4]}" for r in mine] or ["- none assigned"]
        if cross:
            out += ["", "## Cross-cutting rows (FYI — disposition only if you touch them)"]
            out += [f"- **{r[0]}**: {r[4]}" for r in cross]
        out += ["", "## Timebox", "30 minutes. Read-only. No git.", ""]
        (BRIEFS / f"w2-{code}.md").write_text("\n".join(out))
        written.append((code, len(mine)))
    print("wrote w2-common.md and", len(written), "area briefs:")
    print(" ".join(f"{c}({n})" for c, n in written))

if __name__ == "__main__":
    main()
