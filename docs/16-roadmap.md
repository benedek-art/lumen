# 16 — Roadmap

This document owns the build order: eight phases, each ending in a build the owner actually uses on real
photos, each gated by exit tests, all governed by standing rules that no phase may suspend. Feature
definitions live in docs 04–12; engine design in docs/13-architecture.md and docs/14-pipeline.md; storage in
docs/15-catalog.md. This doc decides only *when* and *why in this order*.

## Honest sizing, first

A full Lightroom clone is a multi-year, multi-person project — darktable has roughly 20 years of commits and
~95 processing modules, and still ships remedial UX (a welcome screen in 5.6, a warning dialog when new users
press Tab) to cope with its own surface area. Nobody should plan to rebuild that, and Lumen doesn't.

Three data points calibrate what one developer can actually do:

- **RapidRAW is the existence proof.** One solo developer (started at 18, working around an apprenticeship)
  shipped a usable Lightroom alternative in about 6 months, and by month ~14 (v1.6.1, Aug 2026) covered
  roughly 70% of Lightroom's surface — AgX pipeline, layered AI masking, HDR merge, pano, tethering — by
  reusing libraries aggressively (rawler, SAM 2, Depth Anything V2, LaMa) and shipping monthly. Its admitted
  weaknesses are exactly the deep-engine parts: X-Trans demosaic, polish, memory discipline.
- **Ansel is the cautionary tale.** darktable's most prolific contributor forked it and spent **four years in
  a feature-frozen architecture rewrite**; the result is still labeled alpha in 2026. Solo-forking a
  million-line GPL codebase, or entering an unbounded rewrite, is how solo projects die. Filmulator and
  PhotoFlow are the same story with less drama.
- **ART is the scope proof.** One developer cut RawTherapee's tool count roughly in half (~45 tools) and lost
  approximately none of the results. Tool count is a cost, not an asset.

Lumen's structural advantages over all three: one platform (macOS 15+, Apple Silicon), one user, and an OS
that ships the three hardest subsystems ready to use — a RAW engine (`CIRAWFilter`), a GPU imaging framework
(Core Image + Metal), and segmentation/vision models (Vision framework). We build the differentiating 30%:
culling speed, the develop engine's look, color depth, and the catalog. We do not build a demosaicer in v1
(that is the `RawSource` escape hatch, deliberately deferred — docs/14-pipeline.md).

**Planning estimates** (gates are exit tests, never dates — these exist only to keep ambition honest):

| Phase | Contents | Estimate |
|---|---|---|
| 1 | Walking skeleton | 2–4 weeks |
| 2 | Catalog + culling | 4–6 weeks |
| 3 | Develop engine | 6–10 weeks |
| 4 | Masking | 6–8 weeks |
| 5 | Denoise | 4–6 weeks |
| 6 | Color depth | 6–10 weeks |
| 7 | Film Lab + output + HDR | 6–8 weeks |
| 8 | Dailies | perpetual |

Total to the end of Phase 7: **roughly 9–13 months of steady solo work**, calibrated against RapidRAW's 14
months for a broader-but-shallower surface. Lumen trades RapidRAW's breadth (no pano/HDR-merge/tethering in
v1) for depth where the thesis lives (culling, color, denoise UX). If a phase runs 2× over estimate, the
correct response is cutting scope inside the phase, not extending it — the exit test defines the floor.

## Standing rules (every phase, no exceptions)

1. **Exit tests on real files.** Each phase ends with tests run on the owner's own library — real shoots,
   the owner's camera bodies, high-ISO night frames. We do not advance while an exit test fails.
2. **Ship-to-self weekly.** A release build lands in `/Applications` every week from Phase 1 onward and gets
   used for real photos. Course corrections happen in week 2, not month 6.
3. **Five-loop performance gate, enforced from Phase 1.** The five loops (docs/12-spec-ux.md, D47):
   first-browse, grid scroll (zero hitches at 120 Hz), slider drag (≤16.7 ms to visible change), photo
   switch, AI round-trip. The measurement harness exists from Phase 1; each loop joins the CI gate the day
   its feature ships. A feature that busts its loop does not ship — LR 15.4's pulled release is the standing
   reminder that stability and latency are user-facing features.
4. **Golden-image tests per pipeline stage.** Every stage gets a fixed-RAW → output-hash test the day it is
   written (docs/14-pipeline.md owns the harness and tolerances). This is what makes `pipelineVersion`
   honest and refactors safe.
5. **`pipelineVersion` from day 1.** Recipes carry it from the first persisted edit (docs/15-catalog.md);
   rendering changes are explicit, badged migrations — never LR's silent process-version upgrade.
6. **Replace-or-don't-ship.** A new tool must replace and migrate its predecessor or not ship. darktable's
   four coexisting tone mappers and two white-balance modules are the named anti-pattern.
7. **Nothing synchronous on the input path, ever.** No pipeline work on the GUI thread; recompute is always
   async (Ansel's cache discipline, D49; LR 15.0's blocking mask recompute is the named failure).
8. **Priorities in tension resolve as: image quality > interactivity > feature count.**
9. **Real RAW test corpus, built now.** Owner's bodies, high-ISO samples, borrowed DNGs of other brands,
   X-Trans samples, one ProRAW iPhone DNG (for semantic mattes), clipped-highlight and mixed-light torture
   frames. Golden tests and bake-offs both draw from it.
10. **Backlog by annoyance.** From Phase 8 onward (and for any mid-phase discretionary time), the thing that
    annoyed the owner most during real use gets built next. The backlog lives in GitHub issues; no roadmap
    theater.

## Phase map

```
P0 plan ─ P1 skeleton ─ P2 catalog+culling ─ P3 develop ─ P4 masking ─ P5 denoise ─ P6 color ─ P7 film/output/HDR ─ P8 dailies →
              │              │                   │            │            │           │            │
   usable:  open+edit+     daily culling      daily editor  LR-parity   flagship    beats-C1     the full
            export one     replaces PM/LR     for keepers   locals      denoise UX  color depth  thesis
```

Every phase's build is the owner's daily tool for that phase's job. That is the whole method.

## Phase 0 — The plan (done)

This document set: research, decisions, specs. The plan is the product of this phase; code starts in Phase 1.

## Phase 1 — Walking skeleton

Goal: open a folder of RAWs, see them, edit one with basic sliders, export a JPEG. Prove the spine end to end.

- App shell: SwiftUI window, three-pane layout (sources / center view / right panel), grid ↔ loupe switch
  (G/E from day 1 — the keyboard grammar starts here, docs/12-spec-ux.md).
- Folder scan (in-memory, no catalog yet); thumbnails from embedded RAW previews only — the browse path
  never decodes RAW, from the first build (D34).
- Loupe: Metal-backed zoomable/pannable image view on an fp16 extended-linear `CAMetalLayer` with
  `wantsExtendedDynamicRangeContent` set. This component is load-bearing for everything after — including
  Phase 7 HDR — so it is built correctly once (docs/13-architecture.md).
- `CIRAWFilter` decode with `decoderVersion` pinned and `isDraftModeEnabled`/`scaleFactor` draft path;
  sliders: exposure, temp/tint, highlights, shadows, NR on/off (Apple's stage; ours replaces it in Phase 3).
- Export current photo to JPEG (quality + long-edge resize), color-managed to sRGB.
- Perf harness v1: instrumented measurements of first-browse, photo switch, slider drag; golden-test harness
  v1 with the first fixture RAWs.

**Exit test:** cull a real shoot's folder by eye and export 5 edited JPEGs we'd actually post. Slider→screen
under 50 ms at fit zoom on the M-series dev machine. Perf harness produces numbers in CI.

## Phase 2 — Catalog + culling

Goal: Lumen becomes the daily culling tool, replacing Photo Mechanic/LR for the highest-frequency job, and
edits survive restart. The full spec is docs/10-spec-library.md; docs/15-catalog.md owns storage.

- GRDB/SQLite catalog (WAL, `VACUUM INTO` backups), folder registration, background scan + FSEvents
  watching. Folders are the library; no import ceremony (D34).
- Multi-level preview cache with the **embedded-JPEG fast path**; direction-aware prefetch (8 ahead / 2
  behind at fit; current±1 at 1:1). Cull paging <50 ms, gated only by key repeat.
- **Culling grammar** (D35): P/X/U, 1–5, 6–9, G/E/C/N, auto-advance default-on and visible, survey + 2-up
  compare with synced zoom, hold-key loupe, painter-mode bulk tagging.
- **Raw-truth instruments** (D36): true raw histogram with per-channel clipped-percent stats, hold-key
  shadow-boost and highlight-inspect overlays, focus peaking — at cull time, on the embedded-preview path.
- Edit recipes persisted per photo + XMP sidecars (custom namespace); copy/paste settings.
- Flags/ratings/labels, filter bar (OR across criteria from day 1 — D39), sort; batch export with presets.
- One-screen verified ingest (D38): card auto-detect, streamed xxHash + re-read verify, primary + backup
  destination, rename/folder templates.

**Exit test:** point Lumen at a 5,000-photo archive; first grid appears under 1 s; grid scrolls with zero
dropped frames at 120 Hz; quit/relaunch loses nothing; cull a full event shoot start-to-finish measurably
faster than in LR (wall-clock, same shoot), with zero "wait for preview" moments. Ingest a real card with
verification and cull from the embedded previews while it copies.

## Phase 3 — The develop engine

Goal: Lumen's own adjustment stack downstream of the Apple RAW stage, injected at `linearSpaceFilter`
(docs/14-pipeline.md). This is where the rendering becomes ours. Full spec: docs/04-spec-tone.md and the
Phase-3 subset of docs/06-spec-detail.md.

- Scene-referred linear Rec.2020 fp16 working pipeline with prefix caching and downstream-only recompute
  (D48/D49) — the cache discipline is built now, not retrofitted.
- The six-slider tone contract (D6): Exposure ±5 EV, Contrast/Highlights/Shadows/Whites/Blacks ±100, on
  guided-filter EV-zone weighting (halo-free where LR halos).
- WB: Kelvin 2000–50000, Tint ±150, CAT16 core, eyedropper with loupe (D9).
- **The one display transform** (D8): AgX/sigmoid-class, hue-preserving, display-peak-parameterized from its
  first commit — SDR and HDR share this code path, which is what makes Phase 7 cheap.
- Curves: parametric + point + R/G/B + Luma, luminance-preserving default, TAT everywhere (D10).
- Histogram with draggable zones, clipping triangles, selectable readout space (D12).
- Vibrance/Saturation on the H-K-aware UCS model from the start (D21) — cheap math now, avoids a visible
  look change later.
- Capture sharpening default-on (auto-radius RL deconvolution) + Texture/Clarity/Dehaze on the shared
  base-detail decomposition + vignette (D23/D24). Enough detail machinery to finish real edits.
- Crop/straighten with LR grammar (D31); Apple lens corrections + Remove CA checkbox (D32 subset).
- Crop-aware, face-weighted Auto that sets visible slider values (D11, base version).
- History/undo ring, snapshots, before/after views. Golden tests for every stage listed above.

**Exit test:** re-edit 10 previously-LR-edited photos across the owner's genres; results equal or better to
the owner's eye, verified in side-by-side exports. Slider→visible change ≤16.7 ms at fit view; full-quality
refine ≤200 ms. Sky/land boundary shows no halo where LR's Shadows/Highlights produces one. Golden suite
green; five-loop gate green.

## Phase 4 — Masking

Goal: local adjustments at LR semantics with darktable engineering, plus the AI stack. Full spec:
docs/08-spec-masking.md.

- Mask framework: masks = component stacks with add/subtract/**intersect**/invert; parametric storage;
  versioned, self-healing raster caches; guided-filter feathering at full res; recompute always async (D28/D30).
- Components: brush (edge-aware automask, separate eraser), linear/radial gradients, luminance range with
  band handles, color range, similarity point/line (D28).
- AI: Vision subject/person instance masks; SAM 2.1-small click-to-select with cached encoder embeddings;
  sky model; depth range via Depth Anything V2 Small for every photo; BiRefNet for hair-grade mattes (D30).
- Per-mask Amount 0–200 + per-component amount; feather + edge-shift refinement on every mask (D29).
- The framework contract that matters for sequencing: **any develop tool can run inside a mask.** Phase 6's
  color tools become maskable the day they land, with zero retrofit — including the local tone curve and
  local grading wheels LR still lacks.

**Exit test:** replicate 5 typical LR mask edits (sky darken, subject lift, background desat, radial
vignette, brushed dodge) with equal or better edges on real photos, including one wind-blown-hair frame
where SAM/BiRefNet must beat LR's Select Subject. Mask recompute never blocks the UI (typed slider input
during recompute stays at ≤16.7 ms). Batch-apply a masked preset across 50 frames; recompute runs in the
background queue with visible progress.

## Phase 5 — Denoise

Goal: the flagship experience — classical NR always live, AI denoise cached and instantly blendable, beating
DxO/Topaz's patch-preview UX outright. Full spec and bake-off protocol: docs/07-spec-denoise.md.

- Tier 1 classical, always-live: profiled Poisson-Gaussian VST + edge-aware wavelet (chroma aggressive/auto,
  luma gentle), hot-pixel control (D26). Ships first; replaces the Apple NR checkbox from Phase 1.
- Tier 2 AI: cached non-destructive splice with instant Amount; **full-image preview** (the visible
  differentiator over DxO's magnifier patch and Topaz's patch preview); ≤10 s per 45MP frame on Apple
  Silicon (Core ML/ANE, fixed 512–768 px tiles, fp16); background queue with progressive grid results and
  viewing-priority scheduling (D26).
- The bake-off, run on the owner's high-ISO corpus before committing a model: NAFNet vs SCUNet vs Restormer
  (all license-verified MIT/Apache), judged against the owner's old LR AI Denoise exports.
- ISO-adaptive defaults interpolated between per-ISO anchors, settable as import default (D27); local NR in
  masks.
- Cached-artifact plumbing (versioned, self-healing — D52) shared with Phase 4's mask caches.

**Exit test:** ISO 6400+ frames from the owner's bodies denoise in ≤10 s, look at least as good as the
owner's LR AI Denoise exports in blind A/B, and the Amount slider blends instantly with zero recompute.
A 200-frame event batch denoises in the background while culling continues, viewed frames jumping the queue.
No DNG duplicates anywhere.

## Phase 6 — Color depth

Goal: the color story that beats Capture One — every tool landing already maskable. Full spec:
docs/05-spec-color.md. This is also where the **Develop/Look split** (D4) becomes user-visible: grading,
B&W, and (next phase) Film Lab live in the portable Look layer, applied set-wide.

- Color Mixer: 8 bands with smooth periodic falloff, DxO-ColorWheel-style arc with core+feather handles,
  eyedropper-to-band, Uniformity slider (D13).
- Point Color-class sampled swatches with Variance, global and per-mask (D14).
- Color grading: 3-way wheels + Global with visible, draggable zone pivots; darktable color-balance-rgb
  disclosure (chroma/saturation/brilliance × zones) in the UCS with H-K handling and always-on soft gamut
  mapping (D15).
- Printer lights: master + R/G/B trims in log space, keyboard-steppable at ~1/12 stop (D16).
- Skin tools: skin uniformity, vectorscope skin-tone line groundwork, skin-protected vibrance (D17).
- Primaries panel (D19); B&W 8-band mix with state preservation and auto-suggest (D20).
- Local tone curve + local grading wheels inside masks — the single clearest color-depth win over LR (D29),
  free because Phase 4 built the framework for it.

**Exit test:** grade a 20-frame set with one Look applied set-wide and per-frame Develop trims; match a
reference frame across mixed light using printer lights only, under 60 seconds per frame. Replicate a
C1-style skin-uniformity edit and a Resolve-style shadows/mids/highs grade; export side-by-sides that the
owner prefers over their C1/LR attempts. Every color tool passes the one-frame rule while dragging.

## Phase 7 — Film Lab, output recipes, HDR

Goal: the finishing layer — physically-grounded film looks, an export engine C1-class or better, and the
HDR headline. Specs: docs/05-spec-color.md (Film Lab, D18), docs/11-spec-output.md (D40–D42).

- **Film Lab**: preset-first panel; per-channel characteristic curves in log-exposure→density space,
  subtractive density saturation, halation (red-dominant, pre-curve, linear light), density-domain grain
  (mid-density-peaked, per-channel size, print-size-anchored), single Push/Pull coupling
  contrast+grain+crossover. 5–10 stocks done deeply; spectral bake to 3D LUTs offline. Clean-room from
  Giorgianni & Madden / Hunt — spektrafilm is GPLv3 and stays reference-only (docs/17-appendix.md).
- **Multi-recipe simultaneous export** (D40): checkbox recipes, one Export click emits all, background queue.
- Color-managed export + soft proofing with gamut warning; automated output sharpening
  (Screen/Matte/Glossy × Low/Std/High) at export (D41, D24 pass 3).
- **HDR stills** (D42): EDR viewport goes live (the Phase 1 layer + Phase 3 display-peak parameterization
  pay off here); gain-map authoring — HEIC via Core Image `.HDRImage`, Ultra HDR JPEG via libultrahdr;
  SDR-proof toggle; 10-bit PQ HEIF + 16-bit TIFF secondary.
- Watermarking; external-editor round trip.

**Exit test:** export one wedding set through three recipes (web sRGB 2048px, print Adobe RGB full-res
sharpened, HDR HEIC) in one click; the HDR HEIC renders correctly in Apple Photos/Preview and degrades
deliberately to its SDR rendition; the Ultra HDR JPEG lights up on an Android phone and stays clean in an
SDR browser. One film stock passes the owner's "would I ship this look to a client" bar on a 30-frame set,
with grain that survives print-size inspection.

## Phase 8 — Dailies (perpetual)

Everything below is specced (docs 04–12) and enters by **annoyance priority** — whatever real use misses
most gets built next. Expected early picks, in predicted order of annoyance:

1. **Heal/clone + dust removal** (D33): PatchMatch-family heal with gradient-domain blending, editable pins;
   MI-GAN/retrained-LaMa content-aware remove with re-grained fills; one-click Dust Removal with per-spot
   review. Predicted first out of the queue — healing is the one daily job Phase 2–7 builds still
   round-trip elsewhere.
2. **AI culling assists** (D37): burst grouping, eyes-open/focus badges per face, sharpness scoring,
   black-frame detection, optional aesthetics sort. Evidence, never verdicts; flags only.
3. **Speed Edit** (D44): hold-key + drag anywhere with on-image ghost readout, applied to selection.
4. **Zones panel** (D7): the Resolve-HDR-grade disclosure above the six sliders — stops-denominated
   per-zone exposure/color/saturation with draggable pivots on the histogram.
5. **Scopes** (D22): RGB parade, luma waveform, vectorscope with skin-tone line, one disclosure away in the
   grading context.
6. **Guided Upright + full transform + manual defringe** (D32 remainder).
7. Smart-album extensions, stacks polish, second pinnable viewer window, ISO 12646 assessment mode (D46).
8. Auto-tone personalization from the owner's own edit history (D11 long-term — never trained on
   non-commercial datasets).
9. 2× fidelity Enhance upscale (PLKSR/DAT-light class), after denoise, flagged honestly.
10. `RawSource` v2: LibRaw (CDDL) + own Metal demosaic (RCD default, LMMSE high-ISO, Markesteijn X-Trans),
    "inpaint opposed" highlight reconstruction, and the raw-domain Bayer denoiser (D26 v2) — the escape
    hatch becomes the engine when CIRAWFilter's ceiling is actually hit, not before.

No exit tests here in the phase sense; each shipped item carries its spec's own budgets and joins the
five-loop gate and golden suite like everything else.

## Sequencing rationale

**Culling before developing (P2 before P3).** The owner culls every shoot but grades a fraction of it;
culling is the highest-frequency pain and the fastest full replacement win (Photo Mechanic's job, D1). It
also builds the performance culture on the easiest ground — embedded JPEGs and prefetch, no pipeline — so
the five-loop discipline is muscle memory before the hard rendering work starts.

**Masking before denoise (P4 before P5).** Both need the same infrastructure: versioned cached artifacts,
async background recompute, invalidation on upstream change. Masking builds it against cheap rasters where
bugs are visible and low-stakes; denoise then reuses proven plumbing for expensive ML artifacts. The
reverse order would have the flagship feature debugging the foundation.

**Color depth after masking (P6 after P4) — the deliberate inversion of LR's history.** Adobe built color
tools first and has spent a decade unable to retrofit them into masks (no local tone curve, no local wheels
in 2026 — D29). Landing the mask framework first, with the contract that any develop tool runs inside a
mask, means every color tool ships locally applicable on day one. The clearest single color-depth win in
the plan is a sequencing decision, not an algorithm.

**Denoise before color (P5 before P6).** Denoise sits upstream of color in the pipeline
(docs/14-pipeline.md); grading decisions made on noisy previews get re-litigated after NR lands. The
owner's low-light workload also makes denoise the more urgent daily gap, and the bake-off wants the stable
Phase 3 engine underneath it — nothing else.

**Film Lab late, designed early (P7, architecture from day 1).** The Film Lab needs three stable substrates:
the display transform (curves are authored against it), the grading engine (crossover interacts with
wheels), and print-size-anchored grain (interacts with output scaling). Building it earlier means
rebuilding it. But its *slots* are reserved from day 1: the Look layer exists architecturally from Phase 3
(D4), the recipe schema carries the film block from the first `pipelineVersion` (docs/15-catalog.md), and
the pipeline stage order fixes where halation and grain live (docs/14-pipeline.md). Late implementation,
zero migration.

**HDR in Phase 7, not Phase 8.** Because D8 makes the display transform display-peak-parameterized from
Phase 3 and Phase 1 builds the EDR-capable viewport, HDR output is mostly export plumbing by the time P7
arrives — cheap to ship, and a headline differentiator no incumbent (LR included) treats as first-class on
macOS. Deferring a cheap headline is bad economics.

**Zones panel and scopes in Phase 8.** Both are disclosure layers over engines that must exist first (tone
engine, grading engine). The six sliders cover the overwhelming majority of edits (D6/D7's split exists
precisely for this); shipping the advanced face before the simple face is proven daily-usable would invert
the product's own doctrine (D3).

**Heal in Phase 8 despite being a daily.** Honest tradeoff: heal quality worth shipping (PatchMatch +
gradient-domain + re-grained ML fills) is a deep, separable investment with no coupling to the pipeline
work in P3–P7. Until then the occasional heal round-trips to an external editor — annoying, which is
exactly why the annoyance queue exists and why heal is predicted first out of it.

## Risk register

| # | Risk | Exposure | Mitigation | Tripwire |
|---|---|---|---|---|
| 1 | **CIRAWFilter opacity** — Apple's RAW stage is a black box; demosaic/NR/highlight behavior can shift with OS updates; per-camera support is OS-tied | Rendering changes under our feet; unsupported bodies; quality ceiling | Pin `decoderVersion`; golden tests on the Apple stage output specifically; `RawSource` protocol seam from day 1 (docs/14-pipeline.md); LibRaw/CDDL escape hatch specced and slotted (P8) | A golden test on the Apple stage fails after an OS update; a camera the owner shoots isn't supported |
| 2 | **Core ML conversion pain** — ANE is fp16-only; dynamic shapes and exotic ops (window attention, Mamba scans) convert badly; torch.export parity incomplete | AI denoise/masking miss latency budgets or quality targets | Fixed 512–768 px tile shapes; torch.jit.trace path; fp16 numerical validation in the bake-off before committing a model; GPU fallback accepted; Metal 4 `MTL4MachineLearningCommandEncoder` migration planned, not required (D51) | Bake-off model runs >2× its budget or diverges from fp32 reference beyond tolerance |
| 3 | **Scope creep** — the darktable failure mode: 95 modules, additive evolution, no deletion | The 9–13 month plan silently becomes 3 years | Replace-or-don't-ship rule; every feature needs its spec's "Vs. the field" verdict before code; annoyance queue is the only intake; phases cut scope rather than extend | Any phase 2× over estimate; any feature in progress that no spec doc owns |
| 4 | **Solo-dev sustainability** — Ansel's 4-year alpha, Filmulator's dormancy | Project stalls, owner returns to LR | Every phase ends in a build the owner needs daily (sunk-benefit, not sunk-cost); ship-to-self weekly; no rewrite phases ever; maximal platform reuse; the plan is the spec, so future Claude sessions resume cold | Two consecutive weeks without a shipped self-build; a "temporary" branch older than a month |
| 5 | **macOS API churn** — annual OS cycle (15 → 26 → 27 beta); Metal 4 and `GenerateIterativeSegmentationRequest` are moving targets | Rework; features stranded on beta APIs | Baseline macOS 15; new APIs adopted only behind availability checks with a shipped fallback (SAM path exists regardless of macOS 27's segmentation API); OS-beta testing each summer against the golden suite | Golden or five-loop regression on an OS beta; an availability-gated feature with no fallback path |
| 6 | **Performance erosion** — death by a thousand features; LR 15.0's blocking mask recompute, LR 15.4's pulled release | The "fast" pillar quietly dies | Five-loop gate in CI from Phase 1; budgets in every spec entry; nothing synchronous on the input path (rule 7); Ansel-style prefix caching keeps costs downstream-only | Any loop metric regresses release-over-release; a hitch >16.7 ms appears in the slider trace |
| 7 | **License contamination** — GPL reference code (darktable/RT/spektrafilm), AGPL (RapidRAW), model weights with unclear provenance (Big-LaMa), non-commercial datasets (PPR10K/FiveK), PatchMatch patent posture | Legal exposure; forced rewrites | License ledger + clean-room policy in docs/17-appendix.md; three-layer check (code/weights/training data) before any model ships; verification queue items resolved before the feature that needs them; counsel on PatchMatch before P8 heal ships | Any dependency entering the build without a ledger row; a model shipping with an unverified weights line |
| 8 | **AI quality shortfall on the owner's cameras** — public-benchmark models may underperform on real high-ISO frames from these specific bodies; SAM edges may lose to LR on hair | Flagship features land flat | Bake-offs on the owner's corpus are exit tests, not demos (P4/P5); classical Tier 1 always present and always live; per-task model slots make swapping models cheap (darktable 5.6's registry pattern) | Blind A/B on own corpus loses to the owner's old LR exports |
| 9 | **Catalog or cache corruption** — the trust-killer; LR's `.lrcat-data` black-mask folklore is the named anti-pattern | Data loss; owner stops trusting the tool | Originals read-only forever; WAL + `VACUUM INTO` scheduled backups; XMP sidecars as a second, human-readable copy of every recipe; caches versioned and self-healing (delete-and-rebuild is always safe, D52) | Any cache read error that surfaces to the user as broken state instead of a rebuild |
| 10 | **Rendering drift** — old edits silently change appearance across engine versions | The non-destructive promise breaks | Golden tests per stage; `pipelineVersion` on every recipe; explicit badged migration with side-by-side old/new preview, never silent upgrade (D52) | A golden hash changes without a `pipelineVersion` bump in the same commit |

## What v1.0 means

v1.0 is the end of Phase 7: the owner culls, develops, masks, denoises, grades, films, and exports —
SDR and HDR — entirely in Lumen, faster than the LR workflow it replaced, with every phase's exit tests
green and the five-loop gate enforced in CI. Phase 8 never ends, and that is the point: the annoyance queue
is the product working as designed — a tool maintained by the photographer it serves.
