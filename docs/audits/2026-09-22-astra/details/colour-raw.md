# Independent tone, colour and RAW accuracy audit

Audited main: `99c37272b42c211a04262ceb98cfb39355d1ab99`. Newer development branch checked by source comparison: `origin/claude/photo-editor-design-plan-8ahzmm`, `a6e694103a3676e059847ac48b82c0031281ea53`. Environment: macOS 27, Apple Silicon, Swift 6.4. Audit date: 22 September 2026. No product source was changed.

## Bottom line

The application has considerably more serious colour engineering than its small size suggests: scene-referred exposure, CAT16 white balance, perceptual colour operations, bounded tone/grade solves, explicit transforms, and a substantial control-authority suite. But a passing control-authority test does not mean the image is correct.

Two problems deserve priority before trusting this build for a Lightroom-replacement workflow:

1. On all three supplied Sony RAWs, automatically opting into Apple RAW decoder 9 produces a severely cyan rendition in Lumen's Rec.2020 working context. The problem is already present in the decoded pixels. It is not a bad As Shot temperature, a denoise cast, or an exposure-slider error. Decoder 9 in its default/linear-sRGB working context does not exhibit the severe cast on the isolated test file.
2. The colour-table approximation can substantially change legal, intended colour edits even at the export-size 65-cube. Actual GPU probes confirm errors, not merely a disagreement between two CPU helpers. Some positive-input, positive-output corrections differ by tens of encoded-code equivalents.

Additional reproducible issues involve Point Color picking after earlier edits, lifted-black luma curves, curve handles, the WB picker's tint reach, silently flattened Zone response, and control labels/units. Several other issues are already known in the repository. The newer branch fixes main's Basic Contrast clipping, grading-wheel colour paint, and architecture-sensitive grade hash test; those should not be described as outstanding defects of that newer branch.

The 154-row `control-inventory.md` / `control-inventory.json` provides every exposed control in this audit area, its recipe field, UI and engine location, semantics, verification status, and finding links. `findings.json` is the structured finding ledger with triggers, exact source lines, confidence, history and branch status.

## What was actually checked

- Read the relevant SwiftUI wiring, model fields, algorithms, lookup-table construction, CPU reference route, Core Image graph and tests. Historical documents were used to distinguish existing debts from discoveries, not as proof that old defects remain.
- Compiled standalone probes against the audited core/pipeline object files. These did not modify the repository or its tests.
- Used deterministic scalar, hue/chroma, grey-ramp, scene-stop and colour-cube probes, including non-default combinations and hard-entry ranges.
- Compared intended `RenderPlan.exactColor`, table-based `referenceColor`, and the actual GPU `RenderGraph` on selected failures.
- Rendered the user's three copied ARWs without sidecars. Compared Apple defaults, flat decoder 7/8/9 configurations, Lumen's decoded materialization, and full Lumen rendering with/without denoise.
- Isolated RAW 9 across default, linear-sRGB, linear-P3 and linear-Rec.2020 working contexts with all measurements converted to the same output space.
- Cross-checked every finding against the newer development branch. That branch was source-compared, not separately built or executed.
- Root independently ran main's optimized `ControlProofTests`: six tests, zero failures, 111.605 seconds execution. The authority log contains exactly **135 registered control entries**, not 154. These are different censuses; the appendix includes handles and flags and excludes other audit areas.

Measurements called “encoded-code equivalents” apply the sRGB transfer curve to working Rec.2020 RGB and multiply max-channel error by 255. They are a useful nonlinear error scale, **not CIE Delta-E, perceptual JND, or literal final sRGB-primary output pixels**. Random Rec.2020 cube samples are a stress corpus, not a distribution of typical photos. A second corpus limited inputs to linear-sRGB gamut. Single-pixel GPU probes use neutral/default spatial operations.

## Control coverage and practical semantics

| Family | Rows | Coverage and important limitations |
|---|---:|---|
| White balance | 2 | Temp/Tint traced to CAT16; neutral/inverse tests reviewed; full negative tint picker failure reproduced; real As Shot matrix verified identity. |
| Basic tone | 7 | Exposure, Contrast/Pivot and four tonal controls. Exact exposure units, same-half/sign limiter and baked tone path inspected. Main contrast clipping reproduced; newer branch's live-anchor fix verified in source. |
| Global colour | 4 | Vibrance, Saturation, Density, Protect Skin. Perceptual chroma/skin gates inspected; positive-input saturation cube failure reproduced. |
| Zones | 11 | Six exposure controls and five pivots. Curve response swept densely in scene EV; broad flattened intervals reproduced. |
| Parametric curves | 7 | Four tonal adjustments and three splits. Stage ordering and endpoint contracts inspected; composition/point-handle mismatch measured. |
| Point curves | 6 | Master, Luma, R/G/B and Preserve Luminance. Luma zero endpoint and GPU neutral failure reproduced; RGB/master curves are creative operations, not inherently hue-neutral. |
| Mixer and range handles | 57 | Eight H/S/L triplets, Uniformity and four arc handles per band. Partition/range geometry traced; named-colour weights measured; narrow-gate LUT error reproduced. |
| Point Color | 5 | Per-swatch H/S/L, Range, Variance. Picker domain/ordering and texture behaviour reproduced. Dynamic swatches share these control-role rows. |
| B&W | 9 | Eight colour-mix controls and treatment flag. Shared canonical hue partition, scene-Y conversion, neutrality and pipeline order inspected; band-label caveat applies. |
| Grading wheels/zones | 16 | Four H/S/L wheels, Balance, Blending and two pivots. J-based brightness units measured; main's HSB paint mismatch source-confirmed; hue/grade LUT sweeps run. |
| Colour balance | 14 | Hue shift, Vibrance, Chroma/Saturation/Brilliance in four zones. Existing joint limiter tests reviewed; exact/table sweeps include moderate and extreme saturation. |
| Printer lights | 4 | Master and RGB printer points traced to log-light gains. Existing authority proof passed; no new isolated arithmetic defect established. |
| Primaries | 8 | Three hue/purity pairs, shadow tint/purity. Safe-chromaticity bounds, declared plateaus and interaction with Point Color inspected; combined-extreme cube sweep run. |
| Display transform | 4 | Contrast, Skew, Hue keep, Black target. Anchors, zero behaviour and hard-entry limits inspected. Black target dead numeric range reproduced; new branch changes Contrast track mapping only. |

“Source inspected / existing proof passed” is deliberately weaker than “no defect exists.” This is comprehensive enumeration and targeted behavioural testing, not an exhaustive Cartesian sweep of every possible recipe.

## Priority evidence

### AI-01 · P1 · Reproduced: RAW 9 plus custom wide-gamut working context corrupts these RAW colours

Source: `Sources/LumenPipeline/AppleRawSource.swift:75–80` automatically selects `supportedDecoderVersions.last` and falls back only if `outputImage` is nil. A non-nil lazy image says nothing about pixel correctness. All three files default to decoder 8 and advertise versions 7, 8 and 9. Lumen chooses 9.

The flat comparison disables Apple picture-forming stages and uses the same as-shot WB. Measurements are mean linear Rec.2020 RGB and fraction of pixels with **any** nonpositive component:

| File | Decoder 8 mean RGB | Decoder 9 mean RGB | Nonpositive: 8 → 9 |
|---|---|---|---:|
| A7401502 | .13383, .13308, .12248 | .03374, .15026, .11354 | 0.0685% → 43.56% |
| A7401654 | .04709, .05536, .03064 | −.00815, .06674, .02395 | 2.73% → 74.27% |
| A7401693 | .06031, .06658, .04785 | −.00732, .07997, .03952 | 0.261% → 79.86% |

This metric does not mean all those pixels render black; it quantifies the large negative-channel population accompanying visible red loss. The saved PNGs and root's native-app observation confirm the cyan effect. Rewriting identical as-shot WB changes means only around 1e−7. Lumen's default WB matrix is exactly identity. Disabling denoise leaves the cast.

The working-space isolation is decisive. On A7401502 with RAW 9, default/linear-sRGB gives healthy mean RGB [.133965, .138112, .124154] and 0.331% nonpositive pixels; linear-P3 gives [.097522, .142875, .117251] and 5.271%; linear-Rec.2020 gives [.033745, .150265, .113542] and 43.556%. Decoder 8 stays essentially invariant across all four contexts. This is a **RAW 9/custom-working-space integration failure on the tested OS/cameras**, not evidence that RAW 9 is universally broken.

Root independently verified related Apple context: [WWDC 2026 RAW processing session](https://developer.apple.com/videos/play/wwdc2026/305/) describes RAW 9 as opt-in, not the default; [Apple DTS's related RAW 9 working-space tint report](https://developer.apple.com/forums/thread/843445) concerns a different iPhone/DNG case. That related report must not be presented as proof of the identical Sony bug.

Direction: respect and pin Apple's per-file default for new images, and explicitly validate any RAW 9 opt-in path. A separately validated decoder working context followed by conversion may be viable; it requires real rendered-pixel tests. Existing explicit recipe decoder choices must remain reproducible. Source unchanged on newer branch.

Evidence: `RawProbe.swift`, `RawSpaceProbe.swift`, `raw-all-results.txt`, `raw-space-results.jsonl`; particularly `raw-v9-working-default.png` versus `raw-v9-working-linear-rec2020.png`.

### AI-03 · P1 · Reproduced: colour-table approximation changes the intended correction substantially

Source: `Sources/LumenCore/Engine/RenderPlan.swift:214–221`; `Color/LUT.swift:27–49,161–162`; `Sources/LumenPipeline/Kernels.swift:1118–1123`.

Set Aqua Mixer Luminance −100 with all other controls neutral. For scene Rec.2020 [.384134, .595917, .648289], exact colour-stage output is [.106532, .205737, .232635], but the 65-cube returns [.202614, .348038, .384925]. Both input and exact output are positive: this case is **not explained by clamping negative working channels**.

| Route | Final linear working RGB | Max encoded-code equivalent error |
|---|---|---:|
| Intended exact operations | .127833, .220671, .249249 | — |
| Actual GPU, preview 33 | .300511, .459364, .499690 | 51.21 |
| Actual GPU, export 65 | .242881, .383300, .422760 | 37.13 |

Global Saturation +100 yields another positive-input/positive-colour-output case with GPU errors 14.22 at cube 33 and 31.33 at cube 65. More samples do not guarantee a smaller error at a particular location when narrow nonlinear features move relative to the grid.

A 1,500-sample stress corpus has mean/max encoded errors at cube 65 of .84/12.46 for Red Mixer Hue +100, 1.82/35.84 for Aqua Luminance −100, 2.40/37.42 for Basic Saturation +100, and 6.19/46.10 for Colour Balance Global Saturation +100. Some stress-corpus errors also include known negative-output/domain limitations; the isolated positive example above is the cleaner proof.

A 700-sample *sRGB-gamut input* corpus at Colour Balance Saturation +25 gives mean .31/max 5.35; +50 gives .91/7.66; +100 gives 2.99/29.90. Respectively 5, 77 and 249 samples exceed 3 code equivalents. This is not a claim that every moderate edit visibly fails, but it rules out “only fantastical RGBs” as a complete explanation.

The intended smooth perceptual operation is sampled into a coarse fixed log-grid over 24 stops. Narrow hue windows, chroma gates and skin protection can be smaller than a cell. CPU tetrahedral and GPU trilinear interpolation introduce an additional distinction. Comparing the GPU only with a CPU route that already uses the same baked table cannot prove fidelity to the intended mathematics.

Known negative finish-domain clipping is a separate, still relevant limitation. Do not merge it with this positive-case reproduction. Core colour math and bake/graph files are unchanged on the newer branch.

### AI-02 · P2 · Reproduced: Point Color picker targets the wrong stage after preceding colour edits

`ColorEngine.swift:417–422` applies primaries, then mixer, then Point Color. The picker (`PipelineRenderer.swift:1991–2010`, `RenderGraph.swift:123–153`) samples before primaries/mixer.

With Red Mixer Hue +100, pick that same red and request Point Saturation −100. At Range 0, actual chroma remains .1198007 of an original .12. At default Range 50 it remains .0426767. A correctly post-mixer sampled target reaches approximately zero chroma. This was reproduced directly using the actual stage order. The sampler's `maskSource` path also skips denoise/presence; that additional consequence is source-confirmed, not separately photograph-probed.

Earlier pre-tone picker fixes do not address this intra-colour ordering issue. Existing membership tests use a matching sample with preceding controls neutral. Newer branch unchanged.

### AI-04 · P2 · Reproduced: a raised Luma black endpoint is discontinuous and can tint grey purple

`CurveStack.swift:290–294` skips the luma correction when luma is at or below its epsilon. Set Luma curve [[0,.2],[1,1]]. Exact black stays black despite the plotted raised endpoint; a small positive value jumps to approximately .0331 linear.

Through the GPU, neutral scene 1e−8 should become neutral [.033596, .033596, .033596]. It instead becomes [.027359, .006368, .067010] at 33 and [.048389, .011588, .117056] at 65. The missing zero limit, display-transform zero singularity (`DisplayTransform.swift:324–338`), and sharply varying baked field create an especially bad interpolation boundary. GPU trilinear interpolation samples coloured off-diagonal corners whereas the CPU's tetrahedral diagonal behaves differently.

This is not ordinary floating-point noise. A raised-black neutral ramp should be an actual GPU regression test. Newer branch unchanged.

## Other findings and creative limits

| ID | Severity / evidence | Trigger and effect | Main / newer branch |
|---|---|---|---|
| AI-05 | P2, source + numerical reproduction | Parametric Lights 50 plus master points [[0,0],[.6,.7],[1,1]]: raw handle is at (.6,.7), displayed composite trace at x=.6 is .756543—16.96 px away in a 300 px plot. Lights 100 makes it 32.03 px. Trace and editable handles use different domains. `CurveEditorView.swift:312,603–617,644–647`. | New finding; persists. |
| AI-06 | P2, reproduced | Manual Tint accepts ±300, but WB picker searches/clamps ±150. A sample exactly neutralizable at 5500 K / −250 is solved to 8474.6 K / −150 and retains OKLCh C=.034829. `WhiteBalanceEngine.swift:167–194`, `BasicPanel.swift:278–279`. | New finding; persists. |
| AI-07 | P2, reproduced known gap | Zones Darks +2 makes approximately 1.813 scene EV nearly flat; +4 makes 3.894 EV flat, with up to 2.204 EV difference from requested direct response. The prefix-max bake preserves monotonicity by erasing separation, without applied-value feedback. `ToneEngine.swift:512–517,566–567`. | Known K-040 / tone queue item 3; persists. |
| AI-08 | P2, reproduced known limit | Point Variance −100 sends input hue texture 24.23°, 29.23°, 34.23° all to 29.23°. The existing local-mean overload would preserve the ±5° texture, but the shipping single-pixel colour LUT cannot use it. Analogous Uniformity limit. `ColorEngine.swift:373–376,672–684`, `RenderPlan.swift:218`. | Known COLOR-07; persists. Measured band-mean targets **are** wired now; old claims that they are absent are stale. |
| AI-09 | P3, reproduced | Black target numeric hard range accepts 12 and 15, but 9, 12 and 15 all resolve to .09. Ordinary track correctly ends at 9. `LookPanel.swift:1200–1207`, `DisplayTransform.swift:164–165`. | New finding; persists. |
| AI-10 | P3, measured known semantics | Equal-angle OKLCh bands put common sRGB orange 49.70% Red / 50.30% Orange, pure green 49.84% Yellow / 50.16% Green. B&W shares this partition. Weights are smooth and sum to one; labels do not imply photographic colour ownership. `ColorEngine.swift:95–115,560–597`. | Known COLOR-01; newer branch renames Green/Blue to Mint/Azure, geometry unchanged. |
| AI-11 | P2, test-infrastructure, source-confirmed | Main native test hash 5029306187037463546 differs from Linux-pinned 12301920802024793674. Semantic jointScale/appliedBrilliance checks pass. Raw Double hash is architecture-sensitive. `GradeJointLimiterTests.swift:242–295`. | Known, fixed by same-process comparison in newer branch (1590e1f); not evidence of image regression. |
| AI-12 | P2, reproduced known main defect | Basic Contrast +100 maps scene +3.5 EV to +5.6 EV and clips to 1, versus .902351 at Contrast 0. +50 clips scene +4.5 EV. Tooltip promises pinned endpoints, but relaxation uses ±12 rather than live display anchors. `ToneEngine.swift:491–502`, `BasicPanel.swift:483–488`. | Known A1-01; **fixed** in newer branch (9bcac9f). |
| AI-13 | P3, reproduced units mismatch | Wheel Luminance tooltip promises half a stop; global ±1 actually changes neutral scene light by ±1.5 EV because it scales cube-root J by half a stop before cubing. `LumenControls.swift:1933–1935`, `GradeEngine.swift:233–246`. | New mismatch; persists. |
| AI-14 | P2, source-confirmed known main defect | Wheel paint uses HSV angle, engine uses OKLab a/b angle. Colour beneath puck is not the tint selected. `LumenControls.swift:1982–1984`, `GradeEngine.swift:213–216`. | Known B2-02; **fixed** by OKLCh paint in newer branch. Historical angular measurements not rerun here. |

Further practical limits deserve explicit UI language even when not called fresh defects:

- **Primary purity does not have uniform authority.** The registry itself declares Red Purity's plateau because Rec.2020 red is already on x+y=1; the safe-chromaticity clamp cannot push it farther. Green and blue also front-load against their bounds. This is a deliberate physical/safety constraint, not proof that the positive half has useful fine control. See `ProofRegistry.swift:739–747`.
- **Many saturation controls are intentionally different.** Basic Saturation/Vibrance, mixer saturation, wheel tint radius, Colour Balance Chroma/Saturation, and primary purity are not interchangeable or expected to preserve the same brightness measure. The inventory records their distinct engine paths. It would be misleading to call every brightness change a bug.
- **Tonal/grade limiting changes requested amounts.** Avoiding folds and clipping requires coupling in some combinations. Existing basic-tone and joint-grade limiters are thoughtful. Zones' silent prefix-max replacement is a weaker contract; the exact scalar helper is not its baked shipped response.
- **No universal Lightroom numerical match was established.** The app's custom perceptual coordinate systems and scene/display ordering differ. Tests demonstrate internal identities, authority and selected failures, not Adobe rendering equivalence.
- **Scene-referred does not mean every downstream LUT accepts signed HDR colours.** Current nonnegative log-domain approximation can alter negatives produced by valid wide-gamut operations. This is separate from the more surprising positive-case errors above.

### AI-15 · P2 · Reproduced follow-up: RAW 9 makes native dimensions state-dependent

Sources: `AppleRawSource.swift:93–101,241`; `PipelineRenderer.swift:519–524,1918`. Lumen reads native dimensions directly from its mutable `CIRAWFilter`. Under RAW 9, that property is no longer invariant after a downscaled decode.

All three originals have ImageIO/EXIF dimensions 7008 × 4672. Fresh filters at scale 1 report that size and deliver portrait 4672 × 7008 with decoder 7, 8 or 9, lens correction on or off. Decoder 7/8 continue reporting the original size after small-scale/draft operations. RAW 9 reports 3504 × 2336 after scaled output is requested.

The actual `AppleRawSource` (not just a standalone platform filter) reproduces this sequence using the renderer's `target/nativeLongEdge` calculation:

| Requested long edge | Advertised native before | Actual decoded long edge | Advertised native after |
|---:|---:|---:|---:|
| 512 | 7008 | 512 | 3504 |
| 2560 | 3504 | 5120 | 7008 |
| 2560 | 7008 | 2560 | 3504 |
| 2560 | 3504 | 5120 (cache hit) | 3504 |
| 2560 | 3504 | 5120 (cache hit) | 3504 |

The direct platform filter oscillates; Lumen's cache can lock in the oversized decode while metadata remains half size. A 5120-long-edge buffer has four times the area of the intended 2560 buffer. This is a decoded-size/metadata defect, **not a measured performance multiplier**: concurrent audit work prevents clean timing claims. Consumers such as preview planning and native-coordinate calculations should not depend on this changing value.

Importantly, **this did not cause demonstrated native-export resolution loss**. Scale 1 restores full native dimensions, and root independently exported all three actual JPEGs at 4672 × 7008 after previews. The finding is deliberately limited to reproduced preview/source-state behaviour and downstream metadata risk. Capture immutable original dimensions, test them after every decode/cache state, and retain actual delivered extents separately. The relevant source is unchanged on the newer branch.

Evidence: `RawSizeProbe.swift`, `RawStateProbe.swift`, `RawScaleOscillationProbe.swift`, `RawSourceStateProbe.swift` and their saved result files.

## Test-suite strengths and blind spots

The existing suite is worth retaining. It tests neutral identities, zero semantics, inverse WB behaviour, direction, hue/chroma properties, partition smoothness, tone monotonicity/limits, grade joint limiting, and whether controls visibly move selected frames. The optimized proof run passed all six tests and all 135 golden authority records.

But the suite's contracts are narrower than user expectations:

- An “alive” slider can move the wrong colour or have the wrong selection domain.
- A broad authority floor cannot detect a huge error on one boundary colour.
- A golden generated from the table-based reference can pin a flawed approximation.
- A synthetic source cannot exercise camera decoder selection or working-space negotiation.
- Individually neutral controls do not test combinations such as mixer then Point Color or parametric then point editing.
- A same-platform or cross-platform raw floating-point bit hash is not an appropriate universal semantic oracle.
- The UI's hard numeric range, help units and control paint require tests beyond engine arithmetic.

The next accuracy tests should compare intended exact operations against actual GPU pixels on narrow hue/chroma boundaries, neutral ramps with lifted black endpoints, signed/highlight inputs, and pairwise non-default combinations. Keep real camera files in the decoder qualification loop and test both the platform default and every version the app actively chooses.

## Reproduction and artefacts

All probe sources and results are under `work/audit/image`. No products or originals were edited; supplied RAW copies were read only. PNGs are diagnostic sRGB renderings, not colour-reference target photographs.

- `Probe.swift`: full-range WB picker, Point Color stage ordering, Zone dense response, luma endpoint, deterministic 1,500-colour approximation stress sweep, named-band weights.
- `FocusedProbe.swift`: separate exact/baked colour-stage comparison, moderate sRGB-gamut-input sweeps, Black target hard limit.
- `GPUColorProbe.swift`: actual Core Image graph pixels for Aqua luminance, saturation, and raised-luma-black examples.
- `SmallProbe.swift`: parametric/point handle coordinate mismatch, main Contrast clipping, grading wheel EV, and Point Variance texture limit.
- `RawProbe.swift`: per-version RAW comparisons and full Lumen decode/render.
- `RawSpaceProbe.swift`: same RAW 8/9 inputs across four working contexts.
- `RawSizeProbe.swift`, `RawStateProbe.swift`, `RawScaleOscillationProbe.swift`, `RawSourceStateProbe.swift`: decoder and actual source/cache size-contract follow-up.

For scalar probes, link the audited `LumenCore.build/*.swift.o` with the matching built `Modules` directory. GPU probes additionally link `LumenPipeline.build/*.swift.o`. The build used here lives under `/private/tmp/lumen-astra-audit-build-20260922/arm64-apple-macosx/debug`. Example from the workspace:

```sh
xcrun swiftc -module-cache-path work/audit/image/module-cache \
  -I /private/tmp/lumen-astra-audit-build-20260922/arm64-apple-macosx/debug/Modules \
  work/audit/image/Probe.swift \
  /private/tmp/lumen-astra-audit-build-20260922/arm64-apple-macosx/debug/LumenCore.build/*.swift.o \
  -o work/audit/image/probe
work/audit/image/probe
```

Use a normal native process with GPU access for Core Image probes: the restricted sandbox can return zero pixels, which is an environment failure, not an app image. The probes used for the reported GPU/RAW numbers ran outside that restricted sandbox. They are isolated tests, not an app performance benchmark; other audit tests were running concurrently.
