# 07 — Denoise

Flagship feature #1. The owner shoots low-light/night and high-volume events; denoise quality and denoise
*workflow* both sit on the critical path of every shoot. The goal, stated as a sentence: **PureRAW-class
ambition on quality, Lightroom's non-destructive grammar, and a batch experience neither DxO, Topaz, nor
Adobe ships** — full-image previews, cached artifacts instead of duplicate files, and a queue that never
takes the machine away from you.

The strategic read that shapes everything below: by 2026 the raw-denoise quality race has converged.
Per the maintained comparisons (Finding the Universe, Fstoppers, 2025–26), the LR-vs-DxO gap has closed
to pixel-peeping level; DxO still edges ahead on extreme-ISO fine texture (feathers, foliage), Lightroom
is at worst "a touch softer," Topaz is third on raw. Nobody switches editors for denoise quality alone
anymore. They *would* switch for denoise workflow — and that is where every incumbent is still bad.

Verdict ledger for this doc (each feature entry carries its own "Vs. the field"):

| Versus | Verdict |
|---|---|
| Lightroom Classic 15.5 AI Denoise | **Match quality (v1), beat workflow**: full-image preview parity is already theirs since 14.4 — we add local NR modulation, non-raw input, first-class ISO-adaptive defaults, and a batch queue that isn't anomalously slow |
| DxO DeepPRIME XD2s/XD3 (PL8-era; PL9 unverified) | **Consciously worse on extreme-ISO fine texture for now** (their raw-domain model + 20-year lab dataset is the ceiling; our v2 aims at it). **Better at everything else**: full-image preview vs magnifier patch, cache vs 2–4× Linear DNG bloat, background queue vs hour-long machine monopoly, never refusing a camera |
| Topaz Photo AI 3.x | **Beat predictability**: no Autopilot that silently applies, no model-choice roulette, deterministic cached results. Concede their non-raw specialties (motion-blur rescue, extreme upscale-and-restore) as out of scope |

---

## The field in 2026 (how the incumbents actually work)

### DxO — the quality reference and its lineage

DeepPRIME runs **joint demosaic + denoise as one CNN on the raw mosaic** — denoise before demosaic
artifacts are baked in — stacked on lab-measured per-lens optics modules. Generations: PRIME (2013,
classical, minutes/image) → DeepPRIME (PhotoLab 4, 2020) → DeepPRIME XD (PL6, 2022) → XD2 (PureRAW 4,
Feb 2024) → XD2s (PL8, Oct 2024, fixed XD's crunchy-bokeh artifacts) → XD3 with X-Trans beta (PureRAW 5,
Apr 2025). PhotoLab 9 presumably carries XD3 (unverified this sweep). The control surface is minimal by
design: a Luminance slider 0–100 (default 40) plus an XD-generation detail-forcing control; chrominance
is fully automatic — DxO's bet is that chroma NR has no tradeoff worth exposing. Two structural warts:
**no full-image preview** (DeepPRIME renders only inside a ~1:1 magnifier patch; the full image appears
at export), and the PureRAW workflow taxes users with 2–4× Linear DNG copies per frame. Astro lore:
XD-class models can eat faint stars; DxO's own guidance is to moderate Luminance for starfields.

### Adobe — the incumbent that finally got the design right

LR AI Denoise (12.3, Apr 2023) is the same raw-domain joint architecture (Eric Chan, "Denoise
Demystified"). It took Adobe two years to fix the storage model: until 14.4 (Jun 2025) it wrote a
separate `-Enhanced.dng`; since then it is a **Detail-panel toggle + Amount 0–100 (default 50)** — one
computation, then Amount changes and on/off are instant, nothing written to disk. 15.4 (Jun 2026)
finally enabled the Apple Neural Engine (M4 Mini 32MP: 40 s → 13 s; M1 Air: 85 s → 25 s; M4 Max ~5 s at
45MP) — and shipped a posterization regression severe enough that Adobe pulled the release, fixed in
15.5. Constraints that remain: raw-only (no JPEG/TIFF), no local application, and a community-reported
batch anomaly (~5× slower per image in batch than singly). The 14.4 design is the one to copy; the
two-year DNG detour is the one to skip.

### Capture One — late and quiet

C1 (16.8.4) shipped its AI denoise years behind Adobe and DxO, and it plays no role in the 2026
quality-comparison literature (feature specifics unverified this sweep; teardown in
docs/03-research-competitors.md). What C1 *does* contribute to this doc is a classical-era nicety:
a dedicated **single-pixel/hot-pixel control** that night shooters miss in Lightroom.

### darktable 5.6 — the open-source proof of architecture

darktable's classical "denoise (profiled)" remains the best-documented classical design: per-camera/ISO
Poisson-Gaussian noise profiles → variance-stabilizing transform → wavelet/NLM shrinkage (aggressive
chroma, gentle luma). Its 5.6 (Jun 2026) AI subsystem adds ONNX-runtime neural restore with an open
model zoo: raw denoise = joint denoise+demosaic on Bayer CFA (RawNIND UtNet2, output to DNG), RGB
denoise = NIND U-Net / NAFNet (output to TIFF), one active model per task, split patch preview, and two
deliberate strength semantics — raw strength is a linear blend at sensor level, RGB strength is a
wavelet-band-selective texture restore. The weakness is the DNG/TIFF round-trip workflow; the strength
is the task/model registry and the "scene integrity" policy. We take the registry and the policy, and
integrate in-pipeline instead of round-tripping (vkdt's jddcnn shows in-pipeline is the better home).

### Topaz Photo AI 3.x — the cautionary tale on trust

Separate RAW models (Normal/Strong/Extreme) pre-demosaic plus non-raw models for JPEG/TIFF, wrapped in
**Autopilot**, which detects subject/faces, estimates noise and blur, and auto-applies models and
strengths. Reviews consistently praise the batch speed and criticize the opacity: "everything comes out
looking like AI," plastic skin, crunchy feathers, model-choice roulette. Third on raw denoise; wins
where DxO can't play (JPEG/TIFF/scans, motion blur). Design lesson, verbatim from the research:
auto-*suggest* with visible, reversible decisions beats auto-*apply*.

### Quality standings and speed (2025–26, r06/r03-verified)

| | DxO XD2s/XD3 | LR AI Denoise 15.5 | Topaz Photo AI 3.x | darktable 5.6 | Lumen plan |
|---|---|---|---|---|---|
| Domain | Raw mosaic (joint) | Raw mosaic (joint) | Raw pre-demosaic + RGB models | Both (DNG/TIFF round-trip) | v1 RGB in-pipeline; v2 raw |
| Extreme-ISO fine texture | **Best** | Very close; "a touch softer" | Third; hallucination risk | Behind commercial | LR-class target (v1) |
| Non-raw input | No | No | **Yes** | RGB path yes | **Yes** (v1 is RGB-domain) |
| Full-image preview | No (magnifier patch) | Yes (post-compute) | No (patch) | Patch | **Yes, always** |
| Strength control | Luminance 0–100 (def 40) | Amount 0–100 (def 50), instant | Model + strength | Blend / texture-restore | Amount 0–100, instant, maskable |
| File litter | Linear DNG 2–4× (PureRAW) | None since 14.4 | DNG/TIFF copies | DNG/TIFF copies | None (purgeable cache) |
| Batch behavior | Monopolizes machine, hours | Anomalously slow (bug lore) | Monopolizes machine | Queue, skips failures | Background, progressive, preemptible |

Reported times per 45MP-class raw on Apple Silicon (approximate, 2024–26 reviews; LR rows verified):
DeepPRIME ~5–10 s (M2/M3), XD-class ~10–25 s, LR 15–20 s on M1 Max falling to ~5 s on M4 Max post-15.4,
Topaz ~10–30 s. Everyone is "seconds per keeper, coffee break per shoot." Our ≤10 s budget is
competitive, and the cache means we pay it exactly once per photo.

---

## Lumen's two-tier design

Two tiers, one panel (the "Noise" section of the Detail panel, below Sharpening — see
docs/06-spec-detail.md for the panel as a whole). Tier 1 is classical, profiled, and always live.
Tier 2 is the AI pass: an explicit, cached, non-destructive splice. Pipeline placement (stage order
owned by docs/14-pipeline.md):

```
RAW file ──► RAW stage (CIRAWFilter default │ RawSource escape hatch)
                 │                                │
                 │                                └─[v2] raw-domain AI denoise
                 │                                     (packed Bayer, pre-demosaic)
                 ▼
   linear scene-referred working image
                 ▼
   [Tier 2 splice] AI DENOISE ── cached artifact, Amount = blend vs input
                 ▼
   [Tier 1] profiled classical NR (VST + wavelet, live)
                 ▼
   capture sharpening ► tone ► color ► … ► one display transform
```

Tier 2 sits upstream of Tier 1 so the classical stage can act as a finishing pass (and so the σ the
capture sharpener estimates reflects what is actually in the image). When AI Denoise is enabled, the
ISO-adaptive Tier-1 defaults drop to zero automatically — the noise they compensated for is gone —
unless the user has hand-set them, in which case their values are respected.

---

### Tier 1 — Profiled classical noise reduction (always live)

**What it is.** Real-time luma/chroma noise reduction driven by a measured per-camera/ISO noise model,
plus a hot-pixel control. This is the NR that is simply *on*, costs nothing to use, and handles the
ISO 800–3200 bread-and-butter range without ever invoking a neural network.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Luminance | 0–100 | ISO-adaptive (0 at base ISO) | Gentle by doctrine; wavelet shrinkage strength on luma |
| Luminance Detail | 0–100 | 50 | Shrinkage threshold: higher preserves texture (and noise) |
| Luminance Contrast | 0–100 | 0 | Preserves luminance contrast at the cost of mottling (LR parity) |
| Color | 0–100 | Auto (profiled; shown resolved, e.g. "25 auto") | Aggressive by doctrine; chroma-channel shrinkage |
| Color Detail | 0–100 | 50 | Protects thin color edges |
| Color Smoothness | 0–100 | 50 | Large-scale chroma blotch suppression |
| Hot Pixels | 0–100 | 0 | Single-pixel outlier removal; the C1 nicety LR lacks |

Slider names, ranges, and the 50/50 sub-defaults deliberately match Lightroom's manual NR contract
(docs/02-research-lightroom.md): it is muscle memory for every LR refugee and there is no better
parameterization to invent. The two departures are both upgrades: Luminance and Color defaults are
*profiled and ISO-adaptive* rather than fixed (LR's flat "Color 25" is a guess that happens to be
acceptable), and Hot Pixels exists.

**How it works.** The darktable "denoise (profiled)" architecture, re-implemented for Metal:

- **Noise model**: Poisson-Gaussian, `variance = a·signal + b`, estimated per (camera, ISO). A
  generalized Anscombe variance-stabilizing transform makes noise approximately uniform; shrinkage
  operates in VST space; the inverse transform restores linearity.
- **Decomposition**: à-trous (undecimated) wavelet in a Y0U0V0-style luma/chroma space. Chroma channels
  get heavy shrinkage (visually nearly free); luma gets edge-aware, per-scale gentle shrinkage. An
  optional non-local-means pass (patch 5–7 px, search window ~21 px, GPU) engages at the "High" quality
  setting for 1:1 view and export.
- **Profiling**: darktable's `noiseprofiles.json` is GPL — we read its *numbers* for our own camera
  bodies as calibration reference (facts are not code) and measure our own from defocused test shots per
  darktable's documented procedure. For unknown (camera, ISO) pairs the model is estimated on first
  encounter from flat image regions and cached in the catalog; every subsequent photo from that body
  benefits. No profile-management UI is ever shown — profiles self-calibrate (the darktable
  tone-equalizer lesson: expose refinement, never prerequisites).
- **Hot Pixels**: detects single-pixel outliers deviating from their neighborhood by more than
  `k·σ` (slider maps inversely to k) and replaces them with a median of neighbors. In v1 this runs on
  the post-RAW-stage image (Apple's own despeckle runs upstream); with the v2 RawSource it moves to the
  CFA domain where hot pixels actually live, before demosaic can smear them into crosses.
- Milestone-1 stopgap: `CIRAWFilter`'s built-in luminance/color NR properties stand in until this stage
  ships (docs/16-roadmap.md).

**How it feels.** Ordinary live sliders under the D45 slider contract: preview-resolution response
within the one-frame budget (≤16.7 ms), full-resolution refinement ≤200 ms, NLM quality pass only at
1:1/export so the fit view never stutters. Alt-drag on Luminance shows a grayscale noise-only
difference view (what is being removed), the same teaching pattern as LR's sharpening alt-views.
Keyboard: sliders reachable via the panel focus system, arrow nudges, double-click reset.

**Vs. the field.** Versus **Lightroom Classic 15.5**: equal contract, better because profiled — LR's
manual NR is unprofiled, so users hand-tune per ISO or lean on buried ISO-adaptive presets; ours is
calibrated to the sensor and adapts by default. Versus **darktable 5.6** (best-in-class classical):
equal engine (we adopt their published architecture), better surface — no profile picker, no
wavelet-vs-NLM mode dropdown, no VST exposed; the app picks, the user overrides at most once. Versus
**Capture One 16.8.4**: Hot Pixels reaches parity with their single-pixel slider, inside a profiled
engine C1 doesn't have.

---

### Tier 2 — AI Denoise (cached, non-destructive, full-image)

**What it is.** A neural denoise pass over the full image, computed once in the background, stored as a
cached artifact, and controlled afterward by an instant Amount slider. Lightroom 14.4's final design,
adopted directly — skipping Adobe's two-year DNG detour — with three additions LR doesn't have: the
result is previewed on the **entire image** during and after compute, the Amount is spatially maskable
(see Local NR below), and it works on non-raw files.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Denoise (toggle) | on/off | off (auto-queue rule available, see ISO-adaptive defaults) | First enable computes; thereafter instant |
| Amount | 0–100 | 50 | Linear blend, denoised vs input, in scene-linear space; instant, no recompute |
| Model | list | bake-off winner | Behind disclosure; one active model (darktable registry pattern); swapping invalidates the artifact |

Amount semantics, precisely: `out = (1 − t)·input + t·artifact` per pixel in the linear working space,
`t = Amount/100`. A straight linear mix is predictable, trivially maskable, and GPU-free-instant. We
considered darktable's alternative semantics (wavelet-band-selective texture restore, which re-injects
fine luma grain without chroma speckle) and rejected it as the *primary* control: one slider must mean
one thing. Photographers who want grain back on top of a clean result use the grain engine
(docs/06-spec-detail.md), which produces better grain than re-injected sensor noise anyway.

**How it works.**

- **v1 model domain**: RGB, on the linear scene-referred output of the RAW stage (the Tier-2 splice in
  docs/14-pipeline.md). Candidates, all license-verified from LICENSE files: **NAFNet** (MIT; simple,
  fast, the width-32 class is the practical baseline), **SCUNet** (Apache-2.0; strongest blind-real-noise
  generalist), **Restormer** (MIT — commonly misremembered as research-only; verified MIT). The
  NIND-trained U-Net (GPL) joins the bake-off as a quality reference only — trained on real camera noise
  rather than smartphone data, which matters — but GPL weights/code do not ship in a closed app.
  No clearly-established successor to this model class for real-photo blind denoising surfaced in the
  2026 sweep; the frontier moved to raw-domain, which is our v2.
- **Conditioning**: models run with an ISO/gain-derived noise-level input where the architecture
  supports it (SCUNet-style noise map), fed from the same Poisson-Gaussian profile Tier 1 uses.
- **Execution**: Core ML, fp16, ANE-first with GPU fallback (ANE is fp16-only; darktable hit fp16
  overflow on ANE with its Bayer model — numeric robustness is validated per model before it enters the
  registry). **Tiled inference** is mandatory at 45MP: fixed tile shapes of 512–768 px (fixed shapes are
  what the ANE compiler wants), 32–64 px overlap, Hann-feathered accumulation — or exact halo-crop where
  the tile halo ≥ the network's receptive field, which is bit-stable and preferred. Tile size scales
  with available memory. Budget: **≤10 s per 45MP frame** on the owner's Apple Silicon machine; the
  Metal 4 `MTL4MachineLearningCommandEncoder` migration (docs/13-architecture.md) later removes the
  CoreML↔Metal sync overhead per tile.
- **Caching**: the result is a **cached artifact, never a file the user manages**. Key:
  (photo id, model id + version, fingerprint of upstream parameters that affect the network's input
  pixels — WB shifts materially change denoiser input, so WB is in the fingerprint; downstream edits are
  not). Storage: fp16 tile atlas in the preview-cache store (docs/15-catalog.md), versioned and
  self-healing per D52. Cost honesty: ~360 MB uncompressed per 45MP frame (45×10⁶ px × 4 ch × 2 B);
  the atlas is purgeable, LRU-bounded, and always recomputable — compare DxO's 2–4× Linear DNG bloat,
  which is permanent, user-visible, and user-managed. Upstream param changes invalidate the artifact;
  the toggle stays on, the image falls back to Tier-1 rendering with a badge, and recompute is offered
  (and auto-queued if the change came from batch sync — the D30 rule: recompute is always async and
  never blocks the UI).
- **Non-raw input**: because v1 is RGB-domain, the same pass runs on JPEG/TIFF/HEIC. LR's AI Denoise is
  raw-only; DxO won't open a JPEG at all. Our architectural "compromise" is also a capability — scans
  and phone JPEGs get real denoise in the same tool.

**How it feels.** This is the headline. Toggle Denoise on: compute starts in the background, the
image never locks, and denoised tiles composite into the **full-image preview progressively**, visible
viewport first. When it finishes (seconds), the whole photo is denoised at every zoom level — not a
magnifier patch (DxO), not a preview crop (Topaz), not an export surprise (both). Amount drags with
one-frame latency because it is a per-pixel blend against a resident artifact. Toggle off/on is
instant. A small progress indicator lives on the panel row and in the queue popover; cancel is always
available. Keyboard: the toggle is on the panel focus system like any control; no modal dialogs exist
anywhere in this feature.

**Vs. the field.** Versus **Lightroom Classic 15.5**: equal storage design (we adopted their
endpoint), equal-or-near quality target for v1 (LR is "a touch softer" than DxO; we aim at LR-class,
verified by the bake-off, and concede that Adobe's raw-domain model may retain an edge over our
RGB-domain v1 at extreme ISO until v2 — measured, not assumed); better because the preview is
progressive rather than compute-then-show, the Amount is maskable, non-raw files are eligible, and our
batch path is designed rather than accidental. Versus **DxO DeepPRIME XD2s/XD3**: consciously worse on
extreme-ISO fine texture for now — their raw mosaic domain plus twenty years of lab calibration data is
a real moat, and pretending otherwise would corrupt the bake-off. Better on every workflow axis: full
image vs magnifier patch, cache vs DNG copies, one app vs a pre-processor bolted onto someone else's
catalog, graceful handling of any camera vs refusing unsupported raws outright. Versus **Topaz Photo
AI 3.x**: better because deterministic — one model registry with one active model, nothing auto-applies,
identical inputs give identical outputs, and the result lands as inspectable, reversible state (D5).
Topaz's Autopilot is faster to first result on a folder of JPEGs and better at motion-blur rescue; both
are conceded, the second permanently (we cull blurry frames; we don't hallucinate them sharp).

---

### ISO-adaptive defaults (first-class, not buried)

**What it is.** Noise reduction and sharpening defaults that scale with ISO, interpolated between
per-ISO anchors the user can see and edit, installable as the import default per camera. Lightroom has
had ISO-adaptive presets since 9.3; r03's verdict is exact: "power users adore, beginners never find."
We promote it to a first-class onboarding step: *calibrate your camera once*.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Anchor rows (per camera model) | ≥2 anchors: ISO + full NR/sharpening state | Shipped curve: Tier-1 Luminance 0 @ ISO ≤400 → 25 @ 6400 → 40 @ 25600; Color follows profile | Add/remove/edit anchors; any Detail-panel slider may participate |
| Interpolation | fixed | linear in log2(ISO), clamped beyond anchors | LR-compatible semantics |
| Set as import default | on/off | on after first save | Applies at import per camera body |
| Auto-queue AI Denoise at ISO ≥ | off, 800–51200 | off (suggested: 6400) | Enabling queues Tier 2 in the background for qualifying imports |

**How it works.** At import, the default recipe is the anchor interpolation for the frame's ISO,
resolved to concrete slider values and written into the recipe (docs/15-catalog.md) — so later anchor
edits never silently shift already-imported photos (the LR semantic, kept deliberately; a "re-apply
current defaults" batch command handles the other intent explicitly). Sliders show the resolved values
per D11 doctrine: defaults are visible state the user can tune, never hidden magic. The auto-queue rule
feeds the batch queue below; it computes, it never auto-*commits* — Amount stays at its default and the
toggle is visible and reversible on every frame (the Topaz counter-lesson).

**How it feels.** A one-screen editor reachable from the Noise section header and offered once during
first-run onboarding after the first high-ISO import ("this camera hits ISO 12800 — set adaptive
defaults?"). Editing an anchor live-previews on the current photo at that ISO.

**Vs. the field.** Versus **Lightroom Classic 15.5**: same interpolation semantics, better because
discoverable — LR hides this behind a preset-creation checkbox gated on pre-selecting multiple edited
photos of differing ISOs; ours is a visible editor with shipped starting anchors. Versus **DxO**: DxO
bakes ISO adaptation into DeepPRIME invisibly, which is elegant until you disagree with it; ours is
inspectable and editable. No other competitor has the auto-queue bridge from defaults to a background
AI pass.

---

### Local noise reduction (in masks)

**What it is.** Per-mask noise controls inside the masking system (docs/08-spec-masking.md): Tier-1
strength locally, and — the part nobody else has — local modulation of the Tier-2 AI blend.

**Controls (per mask, in the mask adjustment stack).**

| Control | Range | Default | Notes |
|---|---|---|---|
| Noise | 0–100 | 0 | Local Tier-1 luma/chroma strength (LR mask-Noise parity) |
| AI Denoise | −100..+100 | 0 | Offsets the Tier-2 Amount inside the mask; requires the artifact |

**How it works.** Local Tier-1 runs the wavelet shrinkage with mask-modulated strength (the
decomposition is shared with the global pass, computed once). Local AI costs **zero extra inference**:
because global Amount is a per-pixel linear blend against a resident artifact, a mask simply modulates
the blend weight spatially — `t(x) = clamp(t_global + mask(x)·offset)`. Sky mask +40 AI on a
starscape's foreground, −60 over the stars so faint stars survive (the DxO astro complaint, solved with
one slider); face mask +30 at a reception, background left grainy for atmosphere.

**How it feels.** Two ordinary rows in the mask panel; drag and see, one-frame latency, because both
paths are cheap GPU ops against already-resident data.

**Vs. the field.** Versus **Lightroom Classic 15.5**: better — LR masks carry only a manual Noise
slider; AI Denoise "is not usable as a purely local adjustment" (Adobe's own constraint, unchanged
through 15.5). Versus **DxO PL8**: better — U-Point local adjustments include sharpness and blur but no
local NR of either kind. Versus **darktable 5.6**: darktable can instantiate denoise modules with masks
(strong, fiddly); ours is equal in capability for Tier 1 and ahead for AI, with two sliders instead of
module instances.

---

### Batch denoise and the queue

**What it is.** AI Denoise over a selection or an import, running as a background queue with
progressive results and viewing-priority scheduling. The direct answer to the field's shared failure:
DxO and Topaz batches monopolize the machine and the user's attention ("batch DeepPRIME ties up my
laptop for an hour"), and LR's batch path is community-reported ~5× slower per image than single runs.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Denoise selection | action | — | Grid/filmstrip context menu + shortcut; queues every selected frame |
| Queue popover | pause / resume / cancel / reorder | running | Menu-bar-adjacent popover; per-item status; failures skip and report, never abort the batch |
| Throttle on battery | on/off | on | Drops queue QoS on battery; a native-Mac courtesy no competitor bothers with |

**How it works.** One inference job at a time (serializing keeps the ANE efficient and the UI fluid),
scheduled at utility QoS below every interactive loop in D43. **Viewing-priority is tile-granular**:
tiles are independent, so when the user opens a queued photo, its visible-viewport tiles preempt the
queue head immediately — the region being looked at denoises first, the rest of the frame and the rest
of the queue follow. Completed frames get their artifact cached and their grid badge updated
progressively; the grid never blocks (D34 embedded-JPEG browse path is untouched by any of this).
Arithmetic for honesty: 300 event keepers × ≤10 s ≈ 50 minutes of background ANE time — comparable
wall-clock to a PureRAW batch, except the machine, the grid, and the develop module remain fully usable
throughout, and the photos come back one by one instead of all-or-nothing.

**How it feels.** Select the night's keepers, hit Denoise selection, keep culling. Badges tick across
the grid as frames finish. Open any frame early and its viewport clears first. Close the lid; the queue
resumes on wake. Nothing modal, ever.

**Vs. the field.** Versus **DxO PureRAW 5**: better — their queue is the product's whole UX and still
assumes you leave the machine alone; ours is invisible until consulted. Versus **Topaz Photo AI**:
better — their batch commits Autopilot's judgment per frame; ours computes and waits for yours. Versus
**Lightroom Classic 15.5**: better — LR's batch denoise exists but with no priority model, no
progressive grid feedback, and the reported per-image slowdown; we treat batch as the primary
high-volume workflow, not an afterthought.

---

### v2 ambition — raw-domain denoise (the DxO/Adobe architecture)

**What it is.** A Bayer-domain U-Net running pre-demosaic, the architecture both DxO and Adobe use and
the reason they lead at extreme ISO. Explicitly out of v1; specced now so the architecture reserves its
seat (the `RawSource` escape hatch, docs/13-architecture.md and docs/14-pipeline.md).

**Controls.** None new — the same Denoise toggle and Amount; the model registry gains a raw-domain
entry, and the pipeline splices it pre-demosaic instead of post-RAW-stage. Users notice quality, not
plumbing.

**How it works.** `CIRAWFilter` never exposes the mosaic, so this path requires the LibRaw-based
(CDDL) side-decode used just for the denoise input: pack Bayer into 4 half-resolution planes (tiles
aligned to the 2×2 CFA period), run a small NAFNet/UtNet2-class U-Net **conditioned on a per-pixel
σ-map** derived from the camera's Poisson-Gaussian profile (the PMRID k-Sigma insight, proven again by
Ansel's CFA-agnostic model: normalize by sensor noise parameters and one small network handles all ISOs
and new cameras — a new body needs a noise profile, not a retrain). Training: synthetic Poisson-Gaussian
noise over clean raw stacks (SIDD plus our own tripod stacks; clean provenance, vkdt's author trained
jddcnn on his own photos in hours — this is tractable for one developer). Output feeds our own Metal
demosaic (RCD default, LMMSE high-ISO). X-Trans follows the Markesteijn path later. Amount blends at
sensor level, darktable's raw-strength semantics.

**How it feels.** Identical to v1. That is the point of the cached-splice design: the quality ceiling
rises, the UX contract doesn't move.

**Vs. the field.** Versus **DxO XD3**: this is an honest run at their moat with a smaller dataset;
σ-map conditioning beats their module-gated coverage model — DxO refuses to open raws from unsupported
cameras, while our model generalizes by construction and degrades gracefully. Versus **Adobe**: same
architecture; our advantage is the splice (their raw-domain result still can't be locally modulated;
ours inherits mask-modulated Amount for free). Whether v2 actually closes the extreme-ISO texture gap
is decided by the bake-off below, on our files, not by this paragraph.

---

## Bake-off protocol (kept from v1, refined)

The default model is chosen by measurement, not reputation. Rules:

1. **Corpus**: 12 of our own frames, fixed forever: ISO 1600 → 25600, spanning low-light events
   (faces, mixed light), night sky (faint stars — the XD failure case), indoor people, and one
   landscape-at-dusk with fine foliage (the DxO strength case). Plus 2 non-raw rescues (a phone JPEG,
   a scan) for the RGB-domain capability check.
2. **Contenders per round**: Tier-1 best effort; each Tier-2 candidate (NAFNet, SCUNet, Restormer;
   NIND U-Net as GPL reference); **archived Lightroom AI Denoise exports** of the same frames, produced
   while the subscription lasts, as the standing reference; DxO trial exports if obtainable at test time.
3. **Method**: blind A/B at 100% and at full-frame fit, randomized order, no labels. Score 1–5 on:
   detail retention, chroma blotch suppression, texture worms/hallucination, star survival (astro
   frames), face rendering (plastic-skin check), and wall-clock on the owner's machine.
4. **Ship rule**: the winner becomes the registry default; full results are recorded in this doc and
   the model ledger in docs/17-appendix.md. Re-run the identical protocol for every model update and for
   the v2 raw-domain candidate — v2 ships only if it beats the shipping v1 on these files.

---

## License landmines (recorded so we never trip them)

Denoise-adjacent entries; the full ledger lives in docs/17-appendix.md.

| Model / asset | License | Verdict |
|---|---|---|
| NAFNet | MIT (verified) | Safe — ship |
| SCUNet | Apache-2.0 (verified) | Safe — ship |
| Restormer | MIT (verified; commonly misremembered as research-only) | Safe — ship |
| X-Restormer | MIT (verified) | Safe — backbone option |
| NIND U-Net / RawNIND UtNet2 (darktable-ai) | GPL | Bake-off reference only; never in the shipping binary |
| darktable `noiseprofiles.json` | GPL | Read the numbers as calibration facts for our own bodies; never bundle the file |
| MIRNet | Academic-only | Do not ship |
| BM3D (Tampere reference code) | Restricted | Do not ship; algorithm re-implementation from the paper is fine if ever wanted |
| SIDD dataset | Research terms — verify before commercial training | Flag for v2 training-data diligence; own captures are the clean core |
| MAT (inpainting, adjacent) | "Research purposes only" | Do not ship (owned by docs/09-geometry.md context) |
| LibRaw | LGPL-2.1 / CDDL-1.0 dual (verified) | Take CDDL for the v2 RawSource |

---

## Budgets and exit criteria (summary)

| Item | Budget |
|---|---|
| Tier-1 slider response (preview res) | ≤16.7 ms; full-res refine ≤200 ms |
| AI Denoise, 45MP, owner's machine | ≤10 s, background, cancelable |
| Amount / toggle after compute | ≤16.7 ms (blend against resident artifact) |
| Artifact cache | fp16 tile atlas, purgeable, versioned, self-healing; ~360 MB/45MP frame worst case |
| Batch | zero interactive-loop regressions while queue runs (D47 release gate) |
| Quality | ≥ archived LR AI Denoise references on the bake-off corpus before v1 default ships |

Exit test for the feature (echoed in docs/16-roadmap.md): a 300-frame ISO 6400 event is imported,
auto-queued, culled, and edited on the same machine in the same hour, and at no point does the user
wait on denoise or manage a denoise file. No product in the 2026 field can run that sentence.
