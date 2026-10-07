# Rendering, colour, masks, healing and HDR audit

Baseline: main 5643497. Read-only review performed October 7, 2026. No repository changes, no whole-app build and no owner RAW images. Parent owns baseline test execution. Findings distinguish a newly verified fault from inherited measured limitations and unmeasured proposals. Historical audit reports are evidence of earlier measurements, not new results.

## Immediate actionable issue

### RENDER-01 [P1] Malformed painted healing coordinates can terminate the process

**New, source-verified with a numeric crash probe.** `Sources/LumenCore/Image/StrokeHeal.swift:100` validates finite values only. `resolve` multiplies normalized coordinates by dimensions, then `Int(floor(...))` / `Int(ceil(...))` at lines 127–130 before intersecting the image. Finite huge inputs overflow integer conversion; even finite input multiplication can yield infinity. `resample` at line 144 converts `ceil(total/spacing)` to Int BEFORE taking the 255-segment cap. Its cumulative lengths can overflow too. `alphaPlane` lines 240–243 repeats the unsafe conversion. `StrokeSourceSearch.window` lines 31–34 performs the same conversion with no finite validation at all.

**Evidence:** a small Swift interpreter probe of the exact resample expression using finite ±1e300 coordinates exited 133: `Double value cannot be converted to Int because the result would be greater than Int.max`. This did not invoke the app or its full function and is not claimed as an end-to-end imported-sidecar reproduction. Public core entrypoints definitively have the trap. Existing `StrokeHealTests` covers sensible geometry, curve boundaries, vertex cap and blend behaviour, but no huge finite coordinates.

**Repair contract:** reject invalid geometry before multiplication and/or safely intersect floating bounds with image extent BEFORE Int conversion. Bound segment count in Double before conversion; reject non-finite distances/length sums. Cover the window and alpha-plane sibling paths, and retouch dx/dy overflow as part of the same geometry validation. Preserve valid moderate off-canvas strokes rather than silently clipping their path endpoints. A malformed stroke should produce no healing (or an explicit decode rejection), never terminate or allocate a huge buffer.

**Tests:** NaN/infinity, ±greatestFiniteMagnitude, ±1e300, finite product overflow, total-length accumulation overflow, extreme finite source offsets, zero/negative dimensions, off-canvas but valid intersecting stroke, a fully off-canvas stroke, a normal 256-vertex-cap stroke. Use subprocess for red crash characterization if necessary; after repair ordinary unit tests suffice. No RAW/hardware required. Suggested exclusive ownership: StrokeHeal.swift, StrokeSourceSearch.swift and StrokeHealTests.swift.

## Known limitations verified against present source

### RENDER-02 [P2] Tiny mask component aliasing remains across part of the fit-resolution ladder

`Sources/LumenCore/Image/MaskRaster.swift:1460` (`brushSupersample`) and `brushFoldSize` cap the fine grid at the interactive ceiling. The October P15 report discloses fit rasters approximately 2049–2730 px receive no supersampling for minimum 0.002 brush size. Its 2550 line measurement was within tolerance; its 2050 thin multi-component estimate was outside tolerance. **Do not represent the extrapolated 2050 error as a new measurement.**

Plan: add systematic cross-resolution synthetic alpha tests around 2048/2049/2050/2550/2730 for Add/Subtract/Intersect/erase, widths/aspects and offsets. Measure cell alpha error and selected area independently. First close the regression-test gap; investigate analytic coverage or selective bounded supersampling before increasing whole-mask memory. Preserve normalized-coordinate selection and version preview caches if pixels change. Core synthetic tests possible today; latency and memory acceptance require Mac measurements.

### RENDER-03 [P2] Feather-zero tiny brushes soften differently at preview and export

`MaskRaster.swift:1535` sets `hardnessUsed = min(hardness, max(0, 1 - 1/max(radiusPx,1)))`. A nominal hard brush at radius 3 has one-third feather, whereas a sensor-size radius 6 has one-sixth. P15 explicitly did not separately measure Feather 0; tested feather cases were 50 and 80. This guard prevents aliasing, so removing it blindly is not a fix.

Plan: add feather 0/10/50/100 to resolution matrix; inspect shape, area and coverage against a high-resolution truth. Evaluate pixel-integrated coverage rather than changing recipe hardness with resolution. A render change requires reference/GPU parity and cache revision review. Hardware needed only for speed; synthetic quality characterization works now.

### RENDER-04 [P2] Brush endpoints can lose a last stamp depending on floating point

`MaskRaster.swift:1730` onward walks arc length while `carried + remaining >= spacing`; function returns `out` at 1744 without explicitly adding the endpoint. P15 documented 0.8/0.0025 boundary sensitivity and a 0.376 cell difference with a larger brush; present algorithm remains unchanged.

Plan: characterize paths immediately below/equal/above integer multiples of stamp spacing, reversed paths and different render sizes. Decide an endpoint deposition rule with fractional weight to avoid doubling flow when endpoint already has a stamp. Any new rule changes existing stroke tips; treat as a rendering compatibility decision with fixtures and revision update, not a safe arithmetic cleanup. No RAW required.

### RENDER-05 [P2] One thin stroke makes an entire mixed brush mask expensive

Shared supersample folding affects every component; the October P15 measured worst mixed 59 ordinary + 1 tiny stroke cases at ~4× settle and cold repaint costs. A 2048 fine held plane can consume ~42.7 MB; only two fit in the stated 96 MB settle budget. Three components can churn and pay cold repaint costs. These are **old Linux timings**, not this Mac's measurements.

Plan: benchmark cold/warm/resumed editing at 1024/2048/2550 with 1/3/8 components and 10/60/200 strokes. Instrument cache evictions and raster/fold timings separately. Explore localized dirty regions, stamp tiling or coverage-aware integration. Do not solve by unbounded caching, by dropping masks in draft, or by weakening selected alpha. GPU brush painting is a substantial project; shared CPU rasterizer is currently correctness authority.

### RENDER-06 [P2/product] Colour Uniformity and Point Variance flatten fine colour texture

`ColorEngine.swift:415` sends `localMean:c`; the honest contract at 422–443 explains missing neighborhood image. `ExactColorStage.swift:120` Mixer pass readsReference false; Mixer code at 349–381 is flat per-pixel convergence; Point reads a fixed pre-Mixer reference, not a spatial mean. Existing `ColorPanel.swift:212–223` and 464–473 already tell the user texture flattens. **Do not create a task to add this already-existing disclosure.**

Plan: prototype a guided mean of stage input with a second input for Mixer and Point; preserve high-frequency residual while converging low-frequency mean. Clarify radius/scaling/edge handling, cache key prefix, behaviour under primaries and local adjustments. Add noisy skin/sky procedural patches, edges between two hues, low chroma, exposure-scale and preview/export consistency fixtures. This is a new rendering behaviour and needs version policy plus visual acceptance later. It is not today's most urgent release blocker.

### RENDER-07 [P2/product] Widening one mixer band reduces a neighbor's own-centre authority

`ColorEngine.swift:680–715` normalizes membership weights; `ExactColorStage.swift:354–367` mirrors it. October P14 measured Orange own-centre weight ~0.5027 when Red core widens to 44 degrees, and all widened cores ~0.3358. Present math is unchanged.

Plan: decide whether overlapping normalized bands are intentional. Two valid designs: show normalized actual weights/reach on ring, or cap contribution before neighbor centers with matching visual geometry. A geometry cap changes drag meaning; do not quietly implement it as a numerical bug fix. Add synthetic legal-arc sweeps and CPU/GPU parity for all handles/asymmetries; test weight sum and own-centre authority for chosen contract.

### RENDER-08 [P2/product] B&W common-mode gain, band names and H-K magnitude need choices

P14 disclosures remain: moving all B&W bands uniformly changes chromatic patches while greys hold; historical green/skin colours split across adjacent bands; H-K brightness correction is intentionally very damped. These are not all self-evident defects. The existing Mint/Azure renaming and dominant-band selection address naming honestly without moving pixels.

Plan: preserve today's default rendering until a new behavior is defined. For B&W, compare uniform gain, subtract-mean normalization and dedicated overall exposure, with continuity and saved-look fixtures. For band names, prefer measured eyedropper navigation before re-anchoring centers. For H-K, compare intended perceptual brightness model across hue/chroma/exposure on synthetic wedges before changing constants. Any change can affect many saved edits and proof records; verify migration/version support, not merely proof re-pinning. Owner visual comparisons eventually required.

### RENDER-09 [P2/investigation] Downstream display formation may explain measured saturation hue rotation

P14 found full-render density/saturation hueRotation records 3.59/8.38 degrees despite essentially hue-preserving S9-only output. Existing gamut clipping test covers the gamut clip rather than complete picture formation/curve/display sequence. Do not assume all measured shift is a bug; tone/gamut response can legitimately differ.

Plan: add stage-isolation probes through S9, grade, picture formation, display curve and clip, with in-gamut and out-of-gamut patches, saturated tonal wedges and negative working-space channels. Identify the first stage responsible; define hue/lightness acceptance before implementation. CPU probes work without RAW, GPU comparison on Mac. Preserve current proof records unless intentionally approved output changes have independent evidence.

### RENDER-10 [P2/performance] Multi-recipe and SDR/HDR exports rerender shared upstream work

`PipelineRenderer.swift:930–941` explicitly admits the master-image sharing design is unbuilt. `export` invokes exportedImage and exportedHDRImage separately, and deliveredRendition rebuilds graph per delivery. A lazy CIImage decode can be cached, but that does not mean expensive graph evaluation is shared.

Plan: measure separate S3–S13/shared finish/delivery costs, prototype a materialized master keyed by source identity, recipe, working/display settings and HDR white target. Preserve grain at delivery resolution, resize/no-resize geometry, output sharpening, watermark, dither, and metadata. Do not share masters across mismatched HDR white targets. Add synthetic multi-output equivalence and cancellation/memory bounds tests; Mac export timing required.

### RENDER-11 [P2/UX] Painted healing has automatic source selection but no manual source re-picking

`HealCanvas.swift:225–251` stores provisional offset then asynchronous auto result with stale-edit guard. Stroke source drawn at 455–488. Existing spot source drag/re-pick is separate; painted stroke selection/deletion has no equivalent source edit path.

Plan: add selected stroke source dragging and explicit re-pick with undo/coalescing, content-addressed blob regeneration, recipe save/backup persistence, source-window invalidation, selection stability and async result guard. Test crop/rotate coordinate transforms, clone vs heal, undo/redo and reopening synthetic image. No RAW required. Distinct owner from RENDER-01 if changes need integration ordering.

### RENDER-12 [P1/release/investigation] RAW success policy accepts geometrically valid black decoder output

`RawDecodeAcceptance.swift:29–39` rejects invalid extent/native size only. `RawCorpusTests.swift:1534–1545` and 1728 document the Leica monochrome failure happens before Lumen WB, including Apple's untouched route. It is wrong to declare every mostly-black RAW unsupported because legitimate near-black photographs exist.

Plan: classify failure with decoder capability / metadata and known corpus evidence; add a clearly scoped refusal for confirmed unrenderable decode cases only when criteria are reliable. Keep generic all-black detection diagnostic, not automatic blanket rejection. Need corpus files or existing reproducible fixture to certify hardware behavior; owner's own photos not required. R-7 chroma ceiling tests at 1463–1490 use guessed threshold and a supposed neutral patch, so distinguish a known-neutral fixture from arbitrary scene statistics before treating Nikon/Panasonic alarms as colour defects. Parent owns corpus lane diagnosis.

## Items already implemented: avoid duplicate backlog

* Exact S9 runs via `ExactColorStage`; outdated reports referring to baked S9 tables are stale.
* Zones flattening warning is implemented in `ZonesPanel.swift:126–138` via AppliedReadout plus marked strip. P14's "panel does not show it" status was superseded.
* Mixer Uniformity and Point Variance have truthful per-pixel disclosure in ColorPanel; no need to add a second explanatory paragraph.
* Painted healing reaches both reference and GPU graph; it is not an unwired feature.
* HDR gain-map writable export and EDR preview are connected. Validation and performance work remain, not first-time wiring.
* Grain runs at final delivery resolution; do not revive historical downsample-before-grain claim.
* Mask raster cache source-identity and generation guards are implemented; hypotheses about cross-photo stale masks require a fresh reproducer.
* AI denoise remains a stand-in, and UI labels it as such (`DenoiseControlAvailability.swift:10`). Dedicated model availability is not a one-line bug fix.

## Rendering validation programme without owner photos

1. Harden malformed geometry; normal-path before/after output must be byte-identical.
2. Add synthetic mask golden matrix for hardness, flow, density, pressure, automask, component algebra, negative/off-frame coordinates and fine-resolution transitions. Keep alpha truth distinct from code-under-test outputs.
3. Add procedural heal sources with known blemishes, ramps, crosses, repeated textures and boundary cases; verify colour, continuity and source management, not only CPU/GPU agreement.
4. Add stage-isolated colour/chart/wedge fixtures and independent invariants: neutral stability, continuity, finite output, hue error in well-defined regimes, monotone tone, energy under denoise and output grain amplitude.
5. Denoise: current NoiseProfile estimator includes slope-fitting repair, but generic ISO anchors and slider calibration remain first cuts (`DenoiseEngine.swift:18–20` and 70–75). Synthetic noisy ramps/flat fields/channels can verify estimator bias, threshold monotonicity and texture retention; real cameras still needed for final tuning.
6. HDR: test generated gradient through SDR/HDR pair, matched geometry/resolution/colour space, highlights above one, gain-map metadata roundtrip, unsupported export formats, file readability and resize/watermark parity. Display brightness/visual highlight acceptance requires compatible display.
7. Render/cache: change one prefix field at a time, source replacement, matte generation, brush content, missing payload → present payload, donor mask updates, draft→settle and EDR toggles. Assert exact settled output matches cold render; temporary draft stale behavior is intentional only within same source.
8. Performance: release profile normal/thin masks, long heal strokes, denoise at native size, export recipes and HDR pairs; cap memory and separate decode from graph from delivery. Record machine/OS, warmup and percentile distribution.

## Suggested agent waves and acceptance

Wave 1 safe owner: heal geometry hardening (RENDER-01), then targeted core tests; parent-owned release/corpus diagnosis. Wave 2 independent characterization owners: mask matrix (02–05); stage-isolation colour/HDR fixtures (06–09); source UI (11). Wave 3 measured optimization owners: selective brush work and export shared master, after synthetic parity/latency baselines. Avoid simultaneous ColorEngine/ExactColorStage changes from multiple agents. Do not bundle unrelated visual taste changes into reliability PRs.

Every repair report should include a failing example or measurable issue, expected contract, changed files, before/after evidence, relevant test results, preview cache/version consideration and an explicit real-photo/hardware gate. Green parity proves consistency rather than pleasing rendering. Keep unvalidated aesthetic changes marked pending instead of declaring the whole pipeline ready.
