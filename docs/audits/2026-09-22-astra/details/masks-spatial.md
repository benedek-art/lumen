# Independent audit: masking, detail, spatial effects, geometry and creative tools

Audit date: 2026-09-22. Primary checkout: `main`, `99c37272b42c211a04262ceb98cfb39355d1ab99`. Also source-compared every confirmed finding against `origin/claude/photo-editor-design-plan-8ahzmm` (`a6e6941`). No product files were changed.

## Bottom line

This is a substantial, genuinely working local-adjustment system, not a collection of inert sliders. The seven Classic denoise controls and five manual sharpening controls all moved pixels in independent endpoint probes; Classic CPU/GPU results were exceptionally close on the tested fixture. RAW capture sharpening, the Apple denoise stand-in, and built-in lens correction moved all three supplied ARWs. Mask geometry, algebra, range selectors, brush accumulation, edge-aware painting, local colour and curves, and film/creative grain have real implementations.

It is nevertheless not yet safe to assume that every mask edit is faithfully represented in final output. The most important faults are dependency handling for referenced masks, resolution-dependent brush strength and negative local sharpening, local curves escaping the selected blend mode, and a vignette being positioned on the wrong side of a flipped crop. Film Strength correctly blends tone but still behaves like an on/off switch for full-strength grain/halation. Several impressive-sounding features exist only as recipe fields, not tools: healing/cloning, perspective correction, defringe/moiré, local denoise, and most semantic AI masks.

There are 15 confirmed findings below (two P1, ten P2, three P3), plus one strongly suspected UI gesture issue kept separate. Severity here measures user-facing consequence, not repair cost. P1 = wrong final output or whole-frame unintended adjustment in a normal composition workflow; P2 = materially incorrect control/output contract; P3 = boundary/help/dead-state issue. The P1 conditions are specific and stated, not claims that all rendering is broken.

## Evidence and limits

Four standalone Swift probes imported the actual built `LumenCore` and `LumenPipeline` modules with `@testable`. They are independent of the repository test assertions. GPU checks use a linear float Core Image context. GPU runs required unsandboxed graphics access: the sandbox produced all-zero buffers, which were discarded as an environment failure, not an application finding.

Artifacts in this directory:

- `probe.swift` / `probe-results.jsonl`: mask blends, negative sharpness, mask references and final export cache, crop/vignette, film strength, local strength.
- `control-sweep.swift` / `control-sweep-results.jsonl`: five sharpening and seven Classic NR controls, Texture/Clarity/Dehaze, brush resolution/flow/density/Automask.
- `film-controls.swift` / `film-controls-results.jsonl`: actual GPU halation energy, stock gating, size, redness, exposure dependence.
- `real-photo.swift` / `real-photo-results.jsonl`: three copied ARWs decoded at 512 px long edge, capture/AI/lens endpoint comparisons. Originals untouched.
- `vision-photos.swift` / `vision-photos-results.jsonl`: actual on-device Subject/Background/People inference on all three photos, neutral image and matte/overlay PNGs. These images remain local.
- `control-inventory.json`: distinct control-role census with paths, range, verification status and finding links; shared colour roles and non-shipped placeholders explicitly flagged.
- `findings.json`: machine-readable findings with exact source locations, triggers, consequences, historical/branch status and missing tests.

Runtime measurements are of `main`. Branch persistence is established by source diff: among the relevant renderer, raster, recipe, geometry and panel files, the branch only changes display-transform Contrast to logarithmic travel and adds foreign-pin hit-area handling in `MaskCanvas`. Neither changes any confirmed finding. The branch itself was not rebuilt by this sub-audit. Whole-app interaction, save/reopen, export-file encoding and catalogue durability belong to the parent audit. Tablet-pressure hardware, photometric equivalence to Lightroom, camera/lens calibration quality, and semantic matte accuracy on a labelled portrait dataset were not established here. Three real-photo semantic-mask outputs were visually inspected, as recorded below.

## Confirmed findings

### M01 — Disabled image-dependent donor masks do not supply the picture their borrowers need [P1, high]

**Trigger:** create an image-dependent mask (Brightness Range is sufficient), reference its selection from a second mask, and disable the donor so only the borrower renders. No unusual sidecar editing is needed. A disabled mask is explicitly meant to continue lending its selection (`RecipeMasks.swift:25–28`).

**Cause:** `PipelineRenderer.maskSource` at `Sources/LumenPipeline/PipelineRenderer.swift:1615–1621` asks only `plan.masks` (enabled masks) and direct component kinds/refine fields whether a source image is needed. A `maskRef` says it does not directly read the picture. `MaskRaster.combine` subsequently resolves the reference from `plan.allMasks`, but the source has already been omitted. `maskReadsPicture` follows dependencies later, for caching, too late to repair the missing source. Brightness Range returns an empty plane without that source (`Sources/LumenCore/Image/MaskRaster.swift:1032`).

**Reproduction:** a disabled luma-range donor borrowed by an Exposure +1 mask has max alpha **0**. Enabling the donor produces max alpha **1**. Inverting the disabled donor produces **min=max=1**: a selective edit becomes a whole-frame correction. Probe `disabled_luma_donor` / `disabled_inverted_luma_donor`.

**Impact:** missing or whole-frame local adjustments on fresh renders and exports, not merely stale overlays. The same dependency pattern applies to colour/similarity/luminosity, donor Automask, and donor guided refinement. Only the luma/inverted-luma cases were executed.

**Next test/fix direction:** compute the needs-picture predicate over the contributing dependency closure; test an enabled borrower with a disabled image-dependent donor in a fresh `PipelineRenderer`, with and without inversion. Existing closure-helper tests are insufficient unless they exercise source construction. Historical F2 discusses the omitted traversal in a different cache/matte context; this is an independently reproduced missing-input/full-frame consequence. Persists on `a6e6941`.

### M02 — Editing a referenced donor leaves the borrower's cached alpha stale, including final small-image exports [P1, high]

**Trigger:** on an image at or below the raster-cache retention ceiling (1024 px), export an enabled mask borrowing a donor polygon; move the donor; export again using the same renderer.

**Cause:** `Sources/LumenPipeline/PipelineRenderer.swift:1477–1491` keys a mask raster by the borrower's own JSON, own stroke references/counts, matte-kind names and source key. The referenced donor recipe is absent. `Sources/LumenPipeline/MaskRasterCache.swift:150–159` accepts an exact hit even when stale rasters are disallowed; `:238–239` retains small rasters. A final export is therefore not automatically a fresh bake at native sizes ≤1024.

**Reproduction:** synthetic native 256×128 image, disabled left-hand polygon donor, enabled borrower Exposure +1. After moving the donor to the right, repeat export through the held renderer changes by **0**. A fresh renderer differs from the stale export by **0.2379624546** max red-channel value. Probe `reference_cache_small_export` drives `exportedImage`, not only a helper.

**Impact:** delivered small JPEG/PNG/screenshot edits can be based on an earlier mask shape. Larger exports bypass this particular retained-small-raster path, but that does not fix interactive dependency invalidation.

**Next test/fix direction:** recursively fingerprint referenced selections, including their relevant stroke/matte dependencies; test same-renderer export before/after a donor edit at both 512 and 4096 px. The cache header already admits the incomplete reference key but assumes settled rasters are thrown away; the reproduced native-small export is a new consequence of that acknowledged problem. Persists on the newer branch.

### M03 — Local point/parametric curves ignore Brightness-only / Colour-only mask blending [P2, high]

**Trigger:** choose Brightness only or Colour only for a mask, then edit its local channel curve.

**Cause:** the regular local adjustment pass honours `MaskBlend`. The separate local-curve pass does not: `Sources/LumenCore/Engine/ReferenceRenderer.swift:240–258` directly mixes the curve result; `Sources/LumenPipeline/RenderGraph.swift:1010–1030` always uses `blendMask`, never `blendMaskMode`.

**Reproduction:** opaque mask over RGB(.30,.18,.11), red curve `[0,0], [.5,.8], [1,1]`, preserve-luminance disabled. Normal, Brightness only and Colour only yield the same result: R/G **1.666667→4.034906**, luminance **.207372913→.319357595**. Thus Brightness only changes chroma and Colour only changes brightness. Both CPU execution and GPU wiring confirm it.

**Next test/fix direction:** apply the selected blend contract to S15b as well, using the stage's proper luminance coefficients. `MaskBlendTests` need actual local curves, not only the main local adjustment pass. No matching historical finding found. Persists on branch.

### M04 — Brush Flow/Feather produce different opacity at preview and export resolutions [P2, high]

**Trigger:** paint a narrow, low-flow stroke. Size 1% of the frame, Feather 50, Flow 10, Ceiling 80 already exposes the problem.

**Cause:** `Sources/LumenCore/Image/MaskRaster.swift:1438–1452` uses normalized brush diameter, but forces stamp spacing to at least one raster pixel and imposes a one-pixel feather rim. Each overlapped stamp accumulates opacity (`:1508–1513`), so a downsampled raster receives fewer/weaker overlapping stamps.

**Reproduction:** identical .1→.9 horizontal stroke on 2:1 frames: peak alpha **.081769 at256**, **.258361 at512**, **.439656 at1024**, **.633971 at4096**. The common 1024 draft and 4096 output differ by ~44% relative opacity. At UI minimum Size .002, a centred hard dot produces alpha **0 at256 and512**, **.237618 at1024**, **1 at4096**. A valid brush setting can be invisible on a small native file.

**Next test/fix direction:** density-correct resampling/stamping or rasterize consistently and downsample coverage; prove opacity, not just normalized radius, across resolutions. Existing flow accumulation tests do not establish resolution consistency. No matching historical finding found. Persists on branch.

### M05 — Negative local Sharpness is a fixed pixel blur, almost disappearing on export [P2, high]

**Trigger:** use negative Sharpness on a mask for skin or background softening, then compare a preview with full resolution.

**Cause:** `Sources/LumenCore/Engine/ReferenceRenderer.swift:376–377` and `Sources/LumenPipeline/RenderGraph.swift:989–994` use at most **2.5 render pixels**, rather than a frame-denominated sigma. Positive local/global sharpening does use frame-denominated scaling.

**Reproduction:** same 32-cycle-per-frame sine texture, Sharpness −100. CPU contrast retained: **.145510 at256**, **.886531 at1024**, **.992502 at4096**. GPU: **.138734**, **.885203**, **.991102**. The pipelines agree on the wrong resolution dependence. This is not a Core Image radius-vs-sigma error; that earlier hypothesis was tested and discarded.

**Next test/fix direction:** define a frame-based softening radius and test a fixed scene pattern at multiple dimensions. New adjacency to historical sharpening-scale fixes; persists on branch.

### M06 — Off-centre crop + horizontal flip displaces the vignette outside the delivered crop [P2, high]

**Trigger:** an off-centre crop, a negative vignette, then Flip horizontal.

**Cause:** `Sources/LumenApp/CropPanel.swift:381–389` reflects `crop.x` when flipping to keep the framed subject. `Sources/LumenPipeline/RenderGraph.swift:1323–1330` positions the pre-geometry vignette from that post-flip crop without transforming its centre back to source coordinates. `applyVignette` does not receive angle/flip.

**Reproduction:** uniform .18 image, crop x=.1/y=.1/w=.35/h=.7, Amount −2 EV, Feather75. Before flip: centre and brightest pixel **.1800000**. After flip and the UI's crop-x reflection: centre and brightest pixel **.0450000**—the entire delivered crop receives full −2 EV attenuation. Geometry alone should not convert an edge vignette into uniform darkening.

**Next test/fix direction:** apply in final cropped coordinates or map the vignette centre/axes through the exact inverse geometry. Add asymmetric crop + flip/angle image tests. Historical GEO16 notes a smaller straighten mismatch; this flip consequence is independently new and more severe. Persists on branch.

### M07 — Film Strength does not scale the film's grain or halation [P2, high]

**Trigger:** load a stock with spatial effects and move Strength 0→1→100.

**Cause:** `RenderPlan` creates a chain at any positive amount; `FilmChain` builds a solved stock for any positive blend. `Sources/LumenCore/Engine/FilmLab.swift:1585–1587` returns full grain amplitude, and `:1607–1613` passes the unscaled halation amount. Only the tonal blend uses Strength correctly at `:1524–1528`.

**Reproduction:** Portra defaults: grain amplitude is **0** at Strength0 and **.054** at both Strength1 and100. Halation red strength is **.0175** at both1 and100 (the graph skips the absent chain at0). Pulling Strength back cannot pull these effects back. This is a discontinuity, not a claim that grain pixels cannot change as underlying density changes.

**Next test/fix direction:** define and test a whole-chain blend for spatial stages, especially 0→1. Historical **C1-02 still open**, independently revalidated. Persists on branch.

### M08 — Display Transform controls are disabled while they still form most of a partially blended film image [P2, high]

**Trigger:** Film Strength anywhere 1…99.

**Cause:** `Sources/LumenApp/LookPanel.swift:1117–1119` disables the transform; `:1142–1148` marks it inert for any amount>0. But `FilmChain.apply` mixes the user's solved transform with film at Strength/100. At Strength1 the transform is **99%** of the picture, not replaced.

**Impact:** the active Contrast/Skew/Hue keep/Black target and preset controls cannot be adjusted through their UI while still affecting output. UI help also incorrectly says loading a stock replaces the transform.

**Next test/fix direction:** inert only at full replacement; explicitly describe partial blending. Existing `FilmLabDisplayTransformTests` prove partial base influence, but no test ties UI enabled state to it. Historical **C1-03 still open** (not C1-01). Branch's Contrast log-scale change does not fix the disable predicate.

### M09 — GPU halation has a different onset/energy response from the reference [P2, high]

**Cause:** `Sources/LumenPipeline/Kernels.swift:434–436` uses `max(E−threshold,0)*boost`; `Sources/LumenCore/Engine/FilmLab.swift:541–550` uses a smooth log-space gate. The comment claiming a half-power match is not supported by the functions. The recent radius/sigma fix is real but separate.

**Reproduction:** flat-field actual GPU glow / analytic CPU reference glow is **0 at scene .125 and .25**, **.612163 at .5**, **.750000 at1**, **.875000 at2**, **.937500 at4**. Both use the same three blur weights; flat interiors remove blur shape from the comparison. GPU at .5 adds .0269313 red versus reference .0439937.

**Impact:** the preview/export look is materially weaker than the reference contract precisely in moderately bright, non-clipped regions. CPU proofs cannot stand in for GPU fidelity here. This is CPU/GPU disagreement, not preview-vs-export divergence because both production paths are GPU.

**Next test/fix direction:** one shared energy function and low-highlight goldens, rather than only a very bright block with broad tolerances. Historical **C1-01 still open**, independently GPU-measured. Persists on branch.

### M10 — Film Exposure does not change the halation energy threshold [P2, high]

**Cause:** halation runs before the display/film chain, while Film Exposure is applied only inside `FilmChain.apply` at `Sources/LumenCore/Engine/FilmLab.swift:1526`. `:1613` fixes clipLevel=1 regardless of film exposure.

**Reproduction:** Film Exposure −2 and+3 both report clip=1 and threshold=.25; the spatial stage gets the same input. Brightening the film exposure changes film tone but not which source highlights reach the film-base-scatter stage.

**Impact:** the claimed exposure/halation relationship is not implemented. This is a creative-model fidelity issue, not proof of exact physical behavior of a named stock.

**Next test/fix direction:** decide/document whether this is intentionally post-exposure-independent bloom; otherwise shift the energy threshold into film exposure coordinates. Test an equivalent exposure change made at film and scene stages. Historical **C1-07 still open** (heading is “Halation does not see Film Exposure”). Persists on branch.

### M11 — Mask Strength >100 disagrees between CPU and GPU for Texture/Clarity [P2, high]

**Trigger:** Texture100 or Clarity100 and mask Strength100→200.

**Cause:** CPU `Sources/LumenCore/Image/DetailEngine.swift:264` / `:343` clamps incoming amounts to ±100 after local strength scaling; GPU `Sources/LumenPipeline/RenderGraph.swift:680` / `:743` uses the scaled values without the same amount clamp. Mask panel help at `MaskPanel.swift:331–333` says values past100 exaggerate every adjustment.

**Reproduction:** patterned128² fixture, Texture: CPU max change **0**, GPU **.01151948**; Clarity: CPU **0**, GPU **.06672521**. The overall CPU/GPU Texture/Clarity algorithms also differ, but these numbers isolate the above100 contract.

**Related boundary:** absolute Kelvin WB saturates its mix at1 (`ReferenceRenderer.swift:433`); Strength100 and200 give exactly the same result, unlike relative Temp/Tint. Do not describe Strength as uniformly extrapolating every local adjustment.

**Next test/fix direction:** define per-control strength composition, align CPU/GPU, test 0/50/100/200 and group×member strength. The effective group multiplier can reach400 while local stages cap the aggregate at200—also a documented-versus-effective ceiling to decide. New finding; branch unchanged.

### M12 — Accepted extreme crop ratios cannot be represented by the crop minimum [P3, high]

**Trigger:** enter a valid custom60:1 or1:60 ratio.

**Cause:** `Sources/LumenCore/Model/CropGeometry.swift:557–578` accepts the ratios, while `:154–165` and `:296–305` enforce width and height≥.05. `CropPanel.swift:695–726` stores the requested lock even when the fitted crop cannot satisfy it.

**Reproduction:** 6000×4000 source: requested60 becomes **30**, requested1/60 becomes **.075 (3:40)**, while requested3 correctly becomes3. The UI can display a ratio lock that is untrue.

**Next test/fix direction:** reject/limit ratios according to source geometry/minimum extent, or permit the necessary thin crop. Test accepted-range endpoints, not only common ratios. Historical `w2/K-area.md` custom-ratio finding still open; branch unchanged.

### M13 — Ramp shape help describes the inverse of the actual control [P3, high]

`Sources/LumenApp/MaskPanel.swift:2094–2098` says below1 comes up early and above1 holds back/arrives late. `Sources/LumenCore/Image/MaskRaster.swift:416–427` uses `t^(1/gamma)`: at alpha .5, gamma .5 yields **.25**, gamma2 yields **.7071068**. Above1 raises mask density; below1 lowers it. Fix the explanation or deliberately change the contract, and test the help's stated direction. Newly identified; branch unchanged.

### M14 — Velvia exposes three halation sliders that cannot affect output [P3, high]

`Sources/LumenCore/Engine/FilmLab.swift:343` gives Velvia zero halation strength. `:1574–1579` skips the stage for it regardless of Amount. `Sources/LumenApp/LookPanel.swift:1339–1380` shows enabled Halation, Halo Size and Halo Redness for every stock. Probe confirms Velvia Halation100 still gives amount=0 and redStrength=0, while the other five stocks respond.

This is a disclosed/disable-state problem, not an argument that reversal film must physically halate. Disable/explain inapplicable controls or support an explicitly creative override. Historical **C1-08 still open**, now also covering the two newly added subordinate controls. Branch unchanged.

### M15 — AI Amount is exposed on rendered files although only the RAW decoder consumes it [P2, high]

`Sources/LumenApp/DetailPanel.swift:671–695` allows AI stand-in and Amount on rendered files; a tooltip acknowledges that it cannot operate there. `Sources/LumenPipeline/AppleRawSource.swift:317–336` is the production consumer. `RenderedImageSource.decode` has no matching denoise operation. For ordinary non-manually-overridden Classic masters, selecting AI also suppresses the Classic master values through `ISODefaults.coupled`, leaving no AI processing to replace them on rendered input.

Thus the exposed Amount slider does not denoise JPEG/PNG/TIFF input; this is not evidence that the RAW slider is dead (it is live on all three ARWs below). Disable/gate the mode on unsupported input or implement the rendered-input pass; preserve the already-correct manually overridden Classic coupling behavior. This is a current disclosed capability gap with a misleading enabled control, not a claim that a neural AI engine exists. Source-confirmed, not a dedicated rendered-input runtime probe. Branch unchanged.

## Suspected interaction issue — keep separate from confirmed findings

**Polygon vertex drag accumulation (likely P2):** `Sources/LumenApp/MaskCanvas.swift:600` reads the current component path on each gesture update; `:643–658` adds the total drag-from-start delta to that already modified vertex and commits. Unlike gradient/radial drags, no origin path/vertex is saved. A sequence of +1,+2,+3-pixel events can accumulate +6 rather than ending at+3. This is strong source evidence but was not independently driven through SwiftUI in this sub-audit. Parent was asked to reproduce it in the UI. Unchanged on the newer branch; do not present as a measured UI result without that check.

## Complete control inventory for this area

Status key: **live/probed** = independent pixels/scalars moved; **live/traced** = UI binding reaches an implementation, no exhaustive image-quality claim; **conditional** = requires amount/input/stock/shape; **hidden wire-only** = stored recipe field, not a shipped adjustment; **defect** references above. Paths below are relative to the audited repository.

### Detail, presence, denoise

| Controls / valid UI travel | UI → engine | Status and important semantics |
|---|---|---|
| Capture sharpening On/Off; Amount0…150 (auto100) | `DetailPanel:115–223` → `CaptureSharpen.strengthFraction`, `AppleRawSource:317–318` | Live/probed RAW; rendered input disabled. This is Apple's decoder sharpening, not Lumen's own estimated-PSF RL stage. Optional capture radius is wire-only. |
| Manual Sharpen Amount0…150 | `DetailPanel:296` → `RenderGraph.applySharpen`, `DetailEngine.applySharpen` | Live/probed; starts at0, separate from capture sharpening. |
| Radius.5…3; Detail0…100; Masking0…100; Halo Damping0…100 | `DetailPanel:320–381` → same stage | All four independently live. Frame-denominated radius; effects cannot resolve identically below a pixel on tiny previews. The initial tiny-fixture apparent dead Radius was invalid and was retested at1024. |
| Texture, Clarity, Dehaze −100…100 | Detail presence UI → `DetailEngine:262+ / 341+ / 385+`, `RenderGraph:635–800` | Live/probed. CPU/GPU Texture and Clarity are different approximations; do not equate CPU quality proofs with exact production response. M11. |
| Denoise Off / Classic / AI stand-in | `DetailPanel:507–511` → `Denoise`, `ISODefaults.resolved`, `AppleRawSource` | Classic real. AI is an Apple RAW-decoder stand-in, not a shipped neural model. RAW live; rendered Amount issue M15. |
| Classic Luminance0…100 | `DetailPanel:535–560` → `ClassicNR.luma`, `ClassicalDenoise`, `RenderGraph.applyDenoise` | Live/probed. Sets lumaUserSet, so manual values survive AI coupling. ISO-adaptive otherwise. |
| Luminance Detail0…100; Contrast0…100 | `DetailPanel:585–599` → Classic engine | Both live/probed; Luma must be active for meaningful appearance. |
| Classic Colour0…100 | `DetailPanel:603–623` → Classic engine | Live/probed; sets chromaUserSet. |
| Colour Detail0…100; Smoothness0…100 | `DetailPanel:624–641` → Classic engine | Both live/probed with active Colour. Smoothness uses a capped blotch mixture; current quality tests protect saturated edges. |
| Hot Pixels0…100 | `DetailPanel:644–652` → Classic hot-pixel pass | Live/probed independently of the masters. |
| AI Amount0…100 | `DetailPanel:671–695` → `AppleStandIn`, `AppleRawSource:333–334` | Live/probed on RAW. It scales Apple's luma/chroma reduction, not an AI inference-strength result. M15 on rendered files. |

Sharpen endpoint RMS (CPU / GPU) on1024×128: Amount **.0255746/.0263120**; Radius **.0115313/.00759307**; Detail **.00315971/.00299151**; Masking **.00602784/.00644435**; Halo Damping **.0119775/.0122840**. These establish that the controls are wired, not that every end value is aesthetically desirable.

Classic endpoint RMS at ISO3200 synthetic128×96: Luminance **.00674673**, Luma Detail **.00382283**, Luma Contrast **.000656754**, Colour **.00840068**, Colour Detail **.000062344**, Colour Smoothness **.00308304**, Hot Pixels **.00188183** (CPU; GPU agrees to roughly3e−8 RMS at tested high endpoints). Small colour-detail change is real, not zero.

Global presence CPU/GPU high-end RMS mismatch on the deliberately textured128×96 fixture: Texture **.00533524**, Clarity **.0328782**, Dehaze **.00269551**. The fixture stresses small render-size scales and does not prove that these absolute errors generalize to full photographs. CPU Texture uses multiscale à-trous bands, GPU a guided fine band; CPU Clarity uses local-Laplacian logic, GPU a guided mid band. This known approximation gap remains a test/quality risk beyond M11.

Actual supplied RAW checks (512-px decode, RMS over RGB):

| File / ISO | Capture0→150 | AI Amount0→100 | Lens off→on |
|---|---:|---:|---:|
| A7401502.ARW /500 | .00169750 | .00112836 | .18584278 |
| A7401654.ARW /12800 | .000795857 | .000365633 | .03293646 |
| A7401693.ARW /3200 | .000380210 | .000170650 | .04206139 |

Lens differences include geometry/resampling and should not be read as a correction-quality score. Apple's decoded native long edge reported3504 for these files; no claim is made here that this equals the camera sensor's full active dimensions (the image sub-audit separately found mutable decoder dimensions). Noise profile production defaults use ISO; `NoiseProfile.estimate(from:)` exists but is not called by this production path. Calibration is generic ISO modelling, not a measured per-camera profile.

### Real-photo Vision quality and latency

The probe used the **actual production neutral rendition** (`PipelineRenderer.matteSourceImage`, long edge1024) and the actual `VisionMattes.generate` implementation, not a direct external image/model service. Source images were683×1024. Subject returned same-size mattes; People returned1512×2016 planes which the production fitting logic scales to the source frame. Background was generated from the same Subject result and had **zero complement error** on all three.

| Photo | Subject result | People result | Warm inference Subject / People |
|---|---|---|---:|
| A7401502 | All three people plus the held sign;44.06% mean coverage. Gross outline aligns, but gaps/fine edges need manual checking. | All three people;39.63% mean coverage. Excludes most sign, but its right area remains contaminated and hair edges are approximate. |359 /479ms |
| A7401654 | Seated/leaning foreground person;24.02% mean coverage; gross outline and open arm gap sensible. | Same person;23.85% mean coverage, finer hair edge than Subject. No labelled boundary score asserted. |183 /398ms |
| A7401693 | Small airborne figure correctly isolated;1.753% mean coverage. | **Effectively misses the person:** no pixels above alpha.5, maximum.0431 and mean alpha1.54e−7. |193 /406ms |

Neutral render preparation in the warm recorded pass cost1.01–1.37s, separate from inference. The first cold People request in the preceding run took2.226s (Subject473ms); these are single-run observations under current machine load, not a benchmark percentile or guaranteed UI latency. Repeated mask values were identical across the two runs.

The displayed neutral renditions have a strong cyan/green cast also covered by the independent image-accuracy audit; it is the image the production segmenter actually sees on this main checkout. Therefore do not attribute the small-person failure solely to the model, or extrapolate its frequency from three photos. Nevertheless it is a concrete workflow result: **Subject worked where People did not**, so the user needs a fallback rather than an assumption that either semantic button always succeeds.

Representative local diagnostics, all beneath `work/audit/masks/`:

- `A7401502-subject-overlay.png` and `A7401502-people-overlay.png`: person/sign distinction and residual contamination.
- `A7401654-people-overlay.png`: larger-person boundary example.
- `A7401693-subject-overlay.png` and `A7401693-people-overlay.png`: obvious small-person success versus miss.
- Corresponding `*-neutral.png` and `*-matte.png` files allow inspection without overlay tint. Red overlay is a local diagnostic composite at40% alpha, not a screenshot of the app UI. No user images were uploaded externally.

### Mask construction, hierarchy and refinement

| Controls | UI → engine | Status / qualifications |
|---|---|---|
| Enable, rename, reorder, duplicate/delete masks; grouping/folder collapse; group Enable/Strength0…200 | `MaskPanel`, `Recipe.effective` at `Recipe.swift:107–114`, `RenderPlan:466–474` | Live/traced. Groups multiply members and retain disabled selections as reference donors by design. Folder is not a composited adjustment layer. M01/M02 break some donor workflows. |
| Mask Strength0…200; Normal / Brightness only / Colour only | `MaskPanel:327–335` → `ReferenceRenderer.applyMasks`, `RenderGraph:902–928` | Ordinary blend implementation sound; M03 curves exception, M11 strength exceptions. |
| Whole-mask Invert | `MaskRaster.refined:438–442` | Live/traced, before Follow/Edge Shift/Soften/Levels, so dilation grows the actually selected region. Missing-input inversion protections exist, except M01 source omission case. |
| Add / Subtract / Intersect; component Invert; Contribution0…100 | `MaskPanel:1399–1463` → `MaskAlgebra`, `MaskRaster:274–282` | Live/traced; ordered zero-seeded fold: add=max, subtract=min(a,1−b), intersect=a*b. This is not additive paint opacity. First Intersect alone is empty by that explicit algebra. |
| Brush Size.002….5 frame-long-edge; Feather0…100; Flow1…100; Ceiling0…100 | `MaskPanel:1691–1728` → `BrushStroke`, `MaskRaster.paint` | All live/probed; M04 cross-resolution. Flow25 one centre stamp=.25, four=.683594 at ceiling100; ceiling50 gives .125/.341797. Lower ceiling does not erase earlier denser paint. |
| Eraser; temporary Option eraser; Shift connect; tablet pressure | `MaskCanvas:1220–1338` → stored stroke fields and pressure | Implemented/traced. Pressure read from event, fallback1. No real tablet validation and no tilt model. Erase multiplies alpha toward0. Per-stroke settings are captured, changing a slider is not retroactive. |
| Steadiness0…100 | `MaskPanel:1733` → `BrushStabilizer`, `MaskCanvas` | Live/traced pulled-string stabilizer; stroke finalization closes endpoint gap. No independent hardware-latency test. |
| Stay inside edges / Automask | brush state→ `MaskRaster.paint:1460–1504`, Pipeline source eligibility | Live/probed: red/blue boundary far-side alpha0 with Automask versus1 without. Disabled referenced donor caveat M01. |
| Linear Gradient start/end/span/translate/rotate; Shift15° snap | `MaskCanvas.dragLinear` → `MaskRaster.linearPlane`, `MaskGPU` | Live/traced. Span defines feather; no separate linear feather slider. CPU/GPU formulas/pixel centres share conventions. |
| Radial centre/radii/rotation−90…90; Feather0…100; translate/resize/rotate | `MaskPanel:1500+`, `MaskCanvas.dragRadial` → raster and GPU radial | Live/traced. Long-edge metric avoids non-square rotation skew. Rotation is180° periodic; values outside±90 normalize equivalently. |
| Outline/Polygon/Lasso; add/delete/move corner; Feather0…100 | `MaskPanel:1579+`, `MaskCanvas.dragOutline` → `MaskRaster.polygonPlane` | Raster implemented; suspected vertex-drag issue separate above. Feather is symmetric around the outline despite help saying inward. No Bezier pen or whole-path transform UI. |
| Brightness Range From/To−10…4EV; Smooth0…100; channel Brightness/R/G/B/max/min | `MaskPanel` range rows / bounders2766–2786 → `MaskRaster:1032–1050` | Live/traced. Scene signal's log2 axis, not EV relative to middle grey. Bounders prevent reversed UI range. M01 when borrowed from disabled donor. |
| Luminosity Lights / Darks / Midtones; Level1…5, step.1; channel | `MaskPanel` luminosity rows → `MaskRaster:1232+` | Implemented/traced normalized power families. Midtone family must not be interpreted as the same monotonic narrowing as Lights/Darks without inspecting the formula. |
| Colour Range samples (up to8), Tolerance0…100 | sample picker + `MaskPanel` → `MaskRaster:1253–1290` | Live/traced OKLCh tolerance. One slider jointly widens L/C/h; no independently adjustable three-dimensional sample range. |
| Similarity points (positive/negative), gradient; Reach1…100; Colour/Brightness selectivity0…100 | `MaskPanel:1856–1891`, canvas→ `MaskRaster:1313–1385` | Live/traced. Reach is source-long-edge based; selectivity tightens when increased. This is a useful creative capability beyond basic gradients. |
| Mask Reference donor picker, invert/op/contribution | `MaskPanel`→ `MaskRaster.referenced`, `MaskDependency` | Implemented but M01/M02 must be fixed for reliable layered reuse. Cycles/depth guarded; missing targets skipped. |
| Subject / Background / People | mask creation→ `VisionMattes:85–150` | On-device Vision paths executed on all three supplied RAW photos. Background complements subject exactly; people selects the aggregate, not separately editable named people/body parts. Observed small-person miss above; no labelled quality benchmark. |
| Sky / Object / Landscape / Depth Range | `RecipeMasks:328–350`, panel provider gating | No bundled models; not functioning creation tools. UI gates/explains legacy unsupported recipes. Hidden/disclosed gap, not a live slider bug. |
| Follow0…100 | `MaskPanel` refine→ `MaskRaster:392–398,445–451` | Guided edge refinement, radius≈2%long-edge×value/100, integer rounded. Low values can be subpixel/no-op at draft sizes; source required. |
| Edge Shift−50…50; Soften0…100 | refine→ `MaskRaster:454+` | Signed-distance expansion/erosion to≈1%long-edge; Gaussian sigma≈1%long-edge. Frame scaling present. |
| Black floor0…100; White ceiling0…100; Ramp shape.2…5 | `MaskPanel:2070–2098` → `MaskRaster.levels:416–427` | Levels percentages now unambiguous at0/1/2; previously reported unit-sniffing bug fixed. M13 reversed help only. |
| Overlay six modes; tint red/green/white/black; opacity; component/mask selection | `MaskOverlayRule`, `MaskPanel:1200+`, `PipelineRenderer.renderMaskAlpha:1547+` | Real alpha overlay now, not an old uniform tint fallback. Overlay source decode capped1024; do not promise native-resolution inspection of every raster edge. Parametric render masks can still be full-resolution GPU. |

Brush pins are still absent (`MaskCanvas.anchor:1732–1771` covers geometry/similarity/polygon, not brush); this is a navigability gap when many painted masks accumulate, not missing paint. The newer branch fixes foreign-pin hit-testing swallowing background viewer gestures; do not report that old bug as current on the branch.

### Local adjustment inventory

| Controls | UI → engine | Status |
|---|---|---|
| Exposure−4…4; Contrast/Highlights/Shadows/Whites/Blacks−100…100 | `MaskPanel:2110+` → `ReferenceRenderer.applyLocalAdjust:285+`, `RenderGraph.LocalPlan` | Live/traced; local tone has real tables. Zone anchors are shared global window definitions, not a second unrelated local calibration. |
| Shift Temp/Tint−100…100; absolute Kelvin2000…50000, Kelvin Tint±150 | `MaskPanel:2845–2959` → `LocalWhiteBalance:388+`, local colour LUT | Live/traced. Kelvin has its own amount interpolation, saturated above100; relative mode scales the shift. |
| Hue±180; Saturation/Vibrance±100 | local colour section→ local plan | Live/traced. |
| Colorize enable, target colour, Amount0…100 | local colour→ `colorTint`, `colorTintStrength` | Live/traced luminance-preserving colourization. Not a hidden field. |
| Local point/channel/parametric Curves; preserve luminance mode | `MaskPanel:2230–2275` → `applyLocalCurves` atS15b | Live; M03 blend violation. The ability to curve only a selected region is substantial creative coverage. |
| Four local grading wheels (shadows/midtones/highlights/global; wheel position/HSL fields) | `MaskPanel` wheel editor→ `LocalAdjust.wheels`, local plan | Live/traced; inherits global zone windows. No independent local zones. |
| Local Point Colour samples up to8; Hue±60, Sat/Lum±100, Range0…100, Variance±100 | local PointColour editor→ local colour plan | Live/traced. Local selective colour is implemented; accuracy of the shared engine belongs to colour audit. |
| Texture/Clarity/Dehaze/Sharpness±100 | `MaskPanel:2370–2402` → local spatial stages | Live; M05 negative Sharpness, M11 strength semantics. Local positive Sharpness is a single amount, not a full local Radius/Detail/Masking suite. |
| Local Luma NR / Chroma NR / Moiré / Defringe / Grain | `RecipeMasks:652–691` | **Hidden wire-only**, not rendered. Comments explicitly explain missing stages. Do not count them as available controls merely because JSON round-trips. |

### Film, grain, vignette, lens and crop

| Controls | UI → engine | Status |
|---|---|---|
| Film stock None / Portra400 / Gold200 / Ektar100 / Tri-X400 / Velvia50 / Cine250D | `LookPanel:1317` → `FilmStock.all`, `FilmChain` | Six real authored stocks, separate negative/print or reversal handling. No measured match to real film/Lightroom established here. |
| Strength0…100 | `LookPanel:1323` → film tonal blend | Tonal blend live/correctly uses chosen display transform; M07 spatial discontinuity, M08 disabled base controls. |
| Film Exposure−2…3; Push/Pull−1…2 | `LookPanel:1329–1338` → `FilmChain.apply/build` | Live/traced. Exposure not seen by halation (M10). Push/pull is authored response modification, not evidence of calibrated film processing. |
| Halation0…100; Halo Size.5…2; Halo Redness0…100 | `LookPanel:1339–1380` → shared `halation` profile | All three wired. Size endpoints give sigma .924444/3.697778 at1024; Redness0→100 gives green strength .015→0. M09 CPU/GPU gate, M14 Velvia dead state. |
| Film Grain0…100; Grain Size.5…2 | `LookPanel:1394–1411`, `EffectsPanel:263–296` → `GrainPlan.film` | Live/traced. Both panels now share identity/defaults correctly. Strength caveat M07. |
| Creative Grain Amount/Size/Roughness0…100 | `EffectsPanel:311–342` → `CreativeGrain`, `GrainPlan.creative` | Implemented. Size≈7…56µm at35mm gate; roughness redistributes octaves with normalized energy. Only used when a film stock isn't rendering. No separate local grain. |
| Film print size | wire `FilmLab.printSize` | Hidden/inert by design; cancels mathematically from gate-based grain. Old inert print-size menu removed. No format/gate control presently. |
| Vignette Amount−4…2EV; Feather0…100 | `EffectsPanel:131–172` → `RenderGraph.applyVignette`, `DetailEngine` | Live/traced, M06 crop flip. No midpoint/roundness/centre/highlight-protection UI; highlight protection fixed in engine. |
| Built-in lens profile toggle | `EffectsPanel:442–453` → `AppleRawSource:336` | RAW-only; live on all three supplied files. No selectable manufacturer/lens-profile database UI. |
| Remove CA; Purple/Green Defringe Amount/Hue bounds | `Recipe.swift:1394–1453` | Hidden wire-only; no production stage/UI. Apple profile may do decoder-owned corrections, but these recipe fields themselves have no consumer. |
| Crop free/lock; presets/custom; portrait↔landscape; original; reset/revert/done | `CropPanel`, `CropGeometry` → `PipelineRenderer.applyGeometry` | Real geometry; M12 extreme accepted ratios. Ratio locks are pixel-aspect-aware for normal ratios. |
| Angle−45…45; straightening ruler; Flip horizontal; guides | `CropPanel:356–389`, crop overlay→ shared geometry mapping | Implemented. Geometry and source/display inverse shared with masks. Four guides, not every competitor's guide set. No90° rotation/vertical flip/perspective UI found. |
| Upright Vertical/Horizontal/Rotate/Aspect/Scale/Offset X/Y/Strength | `Recipe.swift` Upright | Hidden wire-only; no perspective render stage. |
| Heal/Clone/Repair | `Recipe.swift:1457+` Heal | Stroke reference/count placeholder only; no operative tool/render stage. Major Lightroom-replacement capability gap, not an inert visible slider. |

## Historical claims checked against current code

Keep these distinctions when synthesizing the whole-app report:

- **Fixed:** old local/parametric gradient scale/coordinate arithmetic problems; modern CPU/GPU gradients share long-edge/pixel-centre math. Not a claim that all canvas gestures are correct.
- **Fixed:** missing brush/AI input inversion/intersection poisoning is guarded by `isEvaluable`; M01 is a different failure where a valid donor is resolved but its image source wasn't built.
- **Fixed:** cross-photograph raster identity is now in the key. M02 is reference dependency mutation on the same photo, not the old cross-photo identity bug.
- **Fixed:** Automask source eligibility on direct brushes; independently exercised. Borrowed disabled Automask source remains M01's adjacent case.
- **Fixed:** matte dependency generation follows references into disabled donors (`MaskDependency.wantedMattes`, comment in `RecipeMasks:337+`). Do not conflate that with `maskSource` for image-dependent masks.
- **Fixed:** Film's partial tonal blend now uses the user's solved display transform; old K-045/film engine discontinuity claim is stale. M08 UI and M07 spatial behavior remain.
- **Fixed:** halation Gaussian radius now uses the shared sigma helper, not sigma×3. M09 energy gate remains.
- **Fixed:** Halo Size/Redness are exposed, routed and tested. Old C1-04 absent-control claim is stale.
- **Fixed:** film and creative grain are deferred to output-grid formation, including crop factor. Do not repeat the old downsampled-export-grain bug without new evidence.
- **Fixed:** stock grain Amount/Size bindings now share the correct field identity/defaults across Effects and Film Lab. Old duplicate-key/default claims are stale.
- **Fixed:** Classic NR has meaningful current quality tests (`Tests/LumenCoreTests/Proof/DenoiseQualityTests.swift`): full-deflection denoising vs noisy input, colour-edge retention, monotonic strength mapping, cap on destructive blotch mixing, ISO defaults near measured optimum, luma-detail retention. Old “only smoke tests” claim is false.
- **Fixed:** AI coupling preserves explicitly edited Classic luma/chroma master values via userSet flags (`DenoiseEngine.swift:1824–1829`). Old “AI always zeroes user values” claim is false.
- **Fixed:** capture sharpening On/Off reaches the RAW decoder through `strengthFraction`; probed live. Lumen's separate RL capture implementation still is not the production Apple path.
- **Branch-only fixed:** foreign mask pins swallowing viewer background gestures (`MaskCanvasHitArea`); Contrast slider log travel (`LookPanel`). Source-only branch check, not this sub-audit's runtime target.
- **Still open:** C1-01/02/03/07/08 as described above; extreme crop-ratio accepted range; absence of healing/perspective/local denoise/many model-based AI masks. The exact historical headings, not unverified old line numbers, define these mappings.

## Creative capability assessment

Strong foundation: ordered add/subtract/intersect components; independent component inversion/contribution; geometric, range, luminosity and similarity masks; references and mask folders; guided edge refinement; pressure/flow/ceiling/Automask brush; local channel curves, point colour, wheels and colorization; dedicated film response, halation and density-domain grain. These can express sophisticated colour separation, dodge/burn, background isolation and stylized finishing without a Lightroom-shaped panel clone.

Highest practical gaps for a personal Lightroom replacement: healing/cloning/content-aware repair; perspective/architectural correction; local denoise and local defringe/moiré; dependable references; subject/person sub-selections and sky/object/depth segmentation; brush pins and richer brush presets; image-anchored grain seed/format control; LUT import or a more expansive finishing stack (coordinate the latter with colour/look audit). The observed People miss on the small airborne figure is a concrete quality limitation within the shipped semantic tools, not a universal model failure; Subject provided a usable fallback on that file. More named stocks are optional creativity, not a substitute for correcting Strength/exposure behavior.

Avoid interpreting authored film constants or comments saying “measured” as a demonstrated fit to real emulsion scans. This audit found functional controls and mathematical models, not calibration datasets or independent validation of stock authenticity. Likewise the Apple stand-in is real RAW denoise, but not a bundled state-of-the-art neural raw-denoising system.

## Highest-value next validation work

1. Real pipeline reference-dependency tests: donor edit, disabled donor, inverted donor, group-off donor, image-dependent/brush/AI donors; repeated preview and final export, native512 and4096.
2. Masked end-to-end control proofs: channel curves in all blend modes; absolute vs relative WB atStrength0/50/100/200; group×member strength; Texture/Clarity CPU/GPU under the same normalized contract.
3. Resolution assertions for brush **coverage and alpha**, negative Sharpness, small refine values, overlay versus delivery—not just parameter radius math.
4. Geometry-composed spatial effects: asymmetric crop, flip, angle, output resize, vignette and grain combined. Use uniform/ramp charts so movement cannot hide errors.
5. Film full-chain monotonicity near Strength0; low-highlight halation GPU goldens; Film Exposure coupled with glow; disabled-state tests for unsupported stock/input controls.
6. Independent visual fixtures for skin, foliage, high-ISO colour blotches, sky gradients and backlit hair. Existing quality tests are a meaningful start; endpoint nonzero tests do not establish aesthetically appropriate response or Lightroom equivalence.
