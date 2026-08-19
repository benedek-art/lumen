# 14 — The Imaging Pipeline

This document fixes the imaging engine: the color architecture and its non-negotiables, the exact
stage order and the reasoning behind every placement, the RAW stage contract, per-stage
implementation notes, the caching/tiling machinery that makes the pipeline interactive, the
HDR/EDR path, and the golden-image + `pipelineVersion` discipline that lets us change any of it
without silently changing three years of edits.

Ownership boundaries: `docs/13-architecture.md` owns the stack, actors, memory budget (D48), ML
runtime, and the `RawSource` protocol; `docs/15-catalog.md` owns recipe storage and cache
lifecycle on disk. Feature behavior — controls, ranges, feel, competitor verdicts — lives in the
spec docs (04–12). This doc owns what happens to pixels, in what order, at what precision, and how
we prove it stays correct.

## 1. Non-negotiables

Four decisions that everything else in this document assumes. They are ranked: if a feature ever
conflicts with one of these, the feature changes.

### 1.1 Scene-referred, linear, unbounded — from decode to picture formation

Pixel values stay proportional to scene light — linear, floating point, allowed to exceed 1.0 and
dip below 0.0 — from RAW decode until the single display transform near the end. Every serious
modern pipeline converged here (Lightroom internally, darktable since its decade-long scene-referred
migration, vkdt, RapidRAW, Resolve's whole color model), and the reasons are physical, not
fashionable:

- Optical operations — blur, sharpen, deconvolution, denoise, mask feathering, halation, any blend —
  are only correct on light-linear energy. Run them on gamma-encoded data and you get halos, dark
  edge fringes, and hue-twisted transitions. This is arithmetic, not taste.
- A 12–14 EV raw squeezed through an early tone curve destroys information every later stage could
  have used. Highlight recovery, zonal tone, and HDR output all depend on the unbounded headroom
  still being there when they run.
- Per-channel curves on nonlinear data skew hue and saturation uncontrollably (the "Notorious Six"
  collapse AgX exists to fix — r11). Keeping the data linear until one controlled transform is what
  makes hue-preservation a *parameter* instead of an accident.

Consequences: no stage may clamp (goldens assert survival of values > 1 and < 0 through every
scene-referred stage); "brightness" is primarily the linear exposure multiplier, never an early
curve; anything that wants display-referred behavior runs after picture formation, explicitly
(§2.4).

### 1.2 Exactly one display transform

One picture-formation stage, ever (D8). darktable ships four display transforms — base curve,
filmic rgb, sigmoid, AgX — each with documentation warning "never use together with another": a
museum of its own migrations that every new user must navigate (r09). Lumen's rule: new rendering
ideas become presets or parameters of the one transform, or they don't ship. The transform itself
(AgX-class sigmoid, hue-preserving, display-peak-parameterized) is specified in
`docs/04-spec-tone.md`; when the Film Lab is active, its baked negative+print chain *occupies the
same slot* (`docs/05-spec-color.md`) — one stage, parameterized, never two tone mappers in series.

### 1.3 Working space: linear Rec.2020

- **Big enough, and real.** Rec.2020 covers essentially all surface colors cameras capture, and its
  primaries are actual monochromatic lights — unlike ProPhoto RGB, whose imaginary primaries mean
  ordinary math routinely produces negative-energy nonsense values that then need policing.
- **HDR output is a near-no-op.** Rec.2020 is the container gamut of BT.2100 PQ/HLG; the HDR path
  (§7) is the same pipeline pointed at a higher display peak, with no gamut gymnastics at the end.
- **It is the convergent choice.** Blender's AgX renders in BT.2020; darktable's scene-referred
  pipe and ACES's working spaces are the same idea; fighting the convergence buys nothing.

Perceptual spaces are used *inside* specific operations and converted back: OKLCh for UI-facing
hue/color tools (two 3×3 matrices and a cube root — trivial GPU cost), a UCS-22-class
Helmholtz–Kohlrausch-aware model for saturation/vibrance and grading (D21; §5.4). No stage ever
persists a buffer in a perceptual space; the working format between stages is always linear
Rec.2020.

### 1.4 Precision: f32 semantics, fp16 storage, fp32 where it counts

The memory arithmetic forces a policy (full table in `docs/13-architecture.md` §4): a 61MP
(9504×6336) RGBA buffer is ~482 MB at fp16 and ~964 MB at fp32; a ten-buffer fp32 graph would be
~10 GB — unshippable on the 16 GB floor. So (D48):

- **The pipeline's math is defined and golden-tested as f32.** fp16 is a storage optimization,
  never a semantic. Every stage has an f32 reference implementation; the shipping fp16-buffered
  path must match it within stage-declared tolerance (§8.1).
- **Working buffers are RGBA fp16** (extended-range, unclamped — fp16 represents ±65504, which
  covers any real scene). The banding rationale for the exceptions: fp16 has a 10-bit mantissa,
  ~3 decimal digits. In deep shadows that a user then pushes +3 EV or more, quantization steps
  become visible as banding — precisely the region night shooters live in. Therefore:
- **Accumulation-sensitive kernels compute internally in fp32** — blur sums, pyramid construction,
  histograms and scopes, variance estimates, RL deconvolution division chains — reading fp16,
  accumulating f32 in registers/threadgroup memory, writing fp16. And **deep-shadow paths**
  (exposure pushes beyond +3 EV, denoise variance stabilization) read/write fp32 checkpoints.
- Masks are single-channel fp16 (~120 MB at 61MP); library/grid proxies are 8/10-bit. Interactive
  checkpoints live at working resolution where a buffer costs ~35 MB, not 482 (§6.1) — the fp16
  policy is what makes even the full-res tier affordable.

### 1.5 Rendering is a pure function

`render(originalFile, recipe, pipelineVersion, targetScale/ROI) → pixels`. No hidden state, no
order-of-edits dependence, no side effects. Everything downstream — caching (§6), export identity
with the viewport, golden tests (§8), the catalog's virtual copies — is only possible because this
function is pure. It is also why cache eviction is always safe: any cached texture is recomputable
from its inputs by construction.

## 2. Stage order

Fixed order, declarative recipe. The user never sees stage numbers; panels are free to group
controls by intent while the engine keeps one canonical order. Stages marked ◆ are materialized
checkpoints (§6.1).

```
══════════════ scene-referred · linear Rec.2020 · unbounded ══════════════
 S1  DECODE      RawSource: black/white levels → camera-reference WB →
                 highlight reconstruction → demosaic → camera matrix →
                 lens corrections                                        ◆
 S2  AI DENOISE  Tier-2 cached splice; Amount = blend vs input           ◆ (disk artifact)
 S3  DENOISE     Tier-1 classical: profiled VST + wavelet/NLM, hot-pixel
 S4  CAPTURE     auto-σ Richardson–Lucy deconvolution (cached with the
     SHARPEN     decode prefix; toggling = cache splice)
 S5  RETOUCH     heal / clone / remove patch composite                   ◆
 S6  LINEAR      white balance (CAT16), Exposure, Printer Lights
 S7  TONE        six sliders + Zones: EV-zone weights on guided mask
 S8  PRESENCE    Texture / Clarity / Dehaze from one base–detail node    ◆ (coefficients)
 S9  COLOR       mixer, point color, hue equalizer, skin, vibrance/
                 saturation (UCS), B&W mix
 S10 GRADE       3-way wheels + chroma/sat/brilliance grid, primaries
 S11 LOCAL       per-mask sub-recipes (params of S6–S10 + local NR/
                 detail), guided-feathered α-blend                       ◆
 S12 SHARPEN     manual/creative sharpening (luma, halo-suppressed)
 S13 EFFECTS     vignette (EV multiply) → Film Lab halation (linear
                 light, pre-curve)
══════════════ picture formation ══════════════
 S14 RENDER      THE display transform: AgX-class sigmoid │ film
                 negative+print chain (density-domain grain inside);
                 hue-preserving gamut mapping; display-peak-parameterized ◆
══════════════ display-referred · still linear-light, 0..peak ══════════════
 S15 CURVE       tone curve (parametric/point/R/G/B/Luma), local curve
                 tap, display-interpreted LUTs, soft clip
 S16 GEOMETRY    one warp: crop ∘ rotate ∘ perspective ∘ distortion —
                 single Lanczos-3 resample
 S17 OUTPUT      display: EDR composite to screen (§7)
                 export: resize → output sharpen → encode + tag (11-spec-output.md)
```

Note the encoding honesty at S14: "display-referred" does not mean gamma-encoded. S14 outputs
*display-linear* values (proportional to emitted display light, 0..peak). Gamma/PQ encoding
happens exactly once, at S17's encode. This keeps S15's curve LUT math and S16's resampling
physically correct (resampling gamma-encoded data is the classic downscale-darkening bug), and it
is what makes the HDR path a parameter instead of a fork.

### 2.1 Ordering rationale, stage by stage

1. **Denoise before everything that amplifies noise** (S2–S3 before S4+). Deconvolution, clarity,
   tone pushes, and grading all multiply noise; denoising after them is fighting your own pipeline.
   The AI splice (S2) sits *upstream* of classical NR (S3) so Tier 1 can act as a finishing pass
   and so the noise profile σ that Tier 1 uses matches its actual input (`docs/07-spec-denoise.md`
   owns the two-tier design).
2. **Capture sharpening immediately after denoise** (S4). RL deconvolution assumes it is undoing
   the optical PSF; it must see the cleanest, least-processed estimate of the optical image. On the
   custom `RawSource` path it runs inside the raw stage (RT/darktable placement); on the
   `CIRAWFilter` path it runs on the returned linear image immediately after decode — the honest
   approximation, on the record (`docs/06-spec-detail.md`).
3. **Retouch early** (S5). Healed pixels must inherit *everything* downstream — tone, grade, film
   grain — or fills reveal themselves the moment a look is applied. Early placement is also what
   makes the cache story work: retouch artifacts are keyed by stroke hash + upstream fingerprint
   (S1–S4), so no tone/color/look slider ever re-runs PatchMatch (`docs/09-spec-geometry.md`).
4. **WB as CAT16 in-pipeline, not in-decode** (S6). The decode always runs at camera-reference WB;
   the user's Kelvin/Tint is a CAT16 chromatic adaptation applied at S6 against the as-shot
   neutral from metadata (D9's "one control surface" on darktable's technically-correct two-module
   model, minus the two modules). Payoff: dragging WB never invalidates the decode, the AI-denoise
   artifact, or the retouch cache — the three most expensive things we own. Same reasoning moves
   Exposure out of the raw stage (v1 had it in-raw; v2 revises): a linear multiply is free at S6
   and catastrophic to cache locality at S1.
5. **Printer Lights with WB/Exposure** (S6). Per-channel gains of 2^(points/12) in scene-linear;
   they are exposure's siblings and must compose upstream of tone so zone definitions in stops
   stay put while riding the keys (`docs/05-spec-color.md`).
6. **Tone before color** (S7 → S9). Zonal tone changes what "shadows" and "highlights" contain;
   hue-selective work should see final tonality. The reverse order would also mean every tone
   slider invalidates color's caches for no benefit.
7. **Presence between tone and color** (S8). The base–detail decomposition node is computed on
   log2 luminance of its input; placing it after TONE means tone edits (which genuinely change the
   luminance structure) invalidate it, while color edits (constant-luminance by construction,
   §5.4) never do — the decomposition survives all of S9–S13. Dehaze lives here too so the mixer
   and grade see dehazed color, and because Dehaze shares the decomposition (D23: one
   decomposition, three sliders — `docs/06-spec-detail.md`).
8. **Grade after color correction** (S10 after S9). Cinema doctrine: secondaries and creative
   grading operate on corrected color. This is also the Develop→Look seam (§3).
9. **Local after global** (S11). A mask's sub-recipe is a delta over global parameters; evaluating
   it after the global stages means local edits compose on top of (never fight with) global ones,
   and mask luminance/color references sample a stable, fully-corrected scene
   (`docs/08-spec-masking.md`: masks compute from stage *input*, never their own output).
10. **Creative sharpening after local** (S12). So masked Clarity is never double-sharpened
    (`docs/06-spec-detail.md` calls this out; v1 had the same rule).
11. **Vignette before halation, both before the curve** (S13). Physical light path: the lens
    vignettes the light *before* it strikes the film; halation is the film base reflecting that
    light. Vignette as EV multiplication in scene-linear gets highlight-priority behavior free
    from the transform's shoulder; halation on linear light before the curve is why film glow
    looks right where post-curve "bloom" sliders look wrong (r10-verified placement).
12. **Geometry last** (S16). Every upstream cache — denoise artifacts, mask rasters, the developed
    image, the display-transformed picture — is crop-independent; dragging a crop or a perspective
    handle re-samples an already-rendered fp16 buffer (a texture sample, not a pipeline
    recompute). One warp, one resample (§5.8).

### 2.2 The resolved question: grading before the transform

The LOOK block's color work (S10 grade, S9's creative half, the Film Lab's pre-curve stages) runs
**scene-referred, before S14**. This was the open ordering question in v1; it is now settled, for
four reasons:

1. **Portability — the reason D4 exists.** A look defined on scene-referred stops is
   camera-independent and exposure-tolerant: "warm the shadows below −2 EV" means the same thing
   on every frame of an 800-frame wedding. A look defined post-transform is a rendition hack that
   breaks the moment exposure moves — exactly the documented failure of the LR preset economy
   (r10: DCP-based film presets fall apart ±1.5 EV from their calibration point).
2. **The transform is the safety net.** With grading upstream, the transform's chroma compression
   and hue-preserving gamut mapping act *after* the grade: pushed wheels soft-land into the
   display gamut instead of clipping to neon. Grade after the transform and you are painting on
   bounded display data with no net below you.
3. **SDR and HDR must agree.** S14 is display-peak-parameterized (§7). Grade once, render at
   peak 1.0 and peak 4.0, and both renditions carry the same look — which is what makes gain-map
   authoring (`docs/11-spec-output.md`) a render-twice operation. Post-transform grading would
   make the SDR and HDR renditions diverge and the gain map lie.
4. **It is the convergent professional practice.** Resolve grades in a wide log working space with
   the display transform last; darktable's color balance rgb is explicitly scene-referred before
   sigmoid/filmic. Nobody who got this right put creative color after picture formation.

### 2.3 The documented exceptions after the transform

Two things deliberately run post-transform, and only these:

- **The tone curve (S15).** A curve is a picture-domain instinct — fifty years of photographic
  muscle memory expects "midtones" to mean picture midtones, not scene log-luminance
  (`docs/04-spec-tone.md` owns this decision and its luminance-preserving default). A bounded
  remap of display-linear values cannot re-tone-map the scene or reintroduce the two-transform
  problem. Its UI presents the familiar encoded axis; the engine composes encode → curve → decode
  into one 1D LUT applied on display-linear data.
- **Display-interpreted LUTs** (`docs/05-spec-color.md`): user .cube files that expect an
  SDR-referred input, applied at the documented post-transform tap. (Log-interpreted LUTs get the
  pre-transform tap on a fixed log encoding.)

And one thing that *replaces* the transform rather than following it: an active Film Lab stock's
baked negative+print chain occupies S14 itself. The print stage of a film chain *is* picture
formation; stacking it after the AgX sigmoid would be two tone mappers in series — the exact
darktable pathology D8 forbids.

## 3. The Develop/Look split as pipeline structure (D4)

Every recipe parameter carries a register tag, `develop` or `look`:

```
recipe
├─ develop:  decode params, denoise, capture sharpen, retouch, WB,
│            exposure, printer lights, tone (sliders+zones), presence,
│            corrective color (mixer/point-color/skin), local masks*,
│            geometry, lens
└─ look:     grade wheels + advanced grid, primaries panel, creative
             color (B&W, harmonies), Film Lab (stock/push/halation/
             grain), LUTs, the transform's preset + params, look-tagged
             local masks*
```

\* masks declare their own register: a dust-removal mask is develop; a "darken sky in every frame"
mask is look. Default = the register of the panel that created it.

The split is a **recipe partition, not a pipeline bisection**. The guarantee that makes looks
portable is narrower and precisely stated: *every look-tagged color operation reads a
develop-normalized, scene-referred image* — all look color stages (S10, film components of S13,
S14's parameterization) sit downstream of all develop color stages (S6–S9). Two develop-tagged
conveniences run even later for engineering reasons documented above (the S15 curve's domain, S16
geometry's single-resample), and they are look-neutral: neither changes what a look computes from.

What this buys, concretely:

- **Copy Look / Paste Look / Apply Look to selection** copies exactly the look-tagged slice —
  grade, film stock, transform preset — and nothing else. Each target frame keeps its own WB,
  exposure, denoise, retouch. One look across 800 frames is a selection gesture, not a
  copy-paste-then-fix ritual (r10: the correction/grading split is *the* enabler of set-wide
  consistency; LR has no equivalent concept in 2026).
- **Looks are storable, versionable objects** (`docs/15-catalog.md` owns the format): a named look
  is the look-slice of a recipe plus its `pipelineVersion`.
- **The simplicity register falls out**: the minute-one user touches Look presets and Auto-develop
  and gets professional results; the depth user opens both columns (D3).

## 4. The RAW stage: Apple's contract vs our stages

`docs/13-architecture.md` §6 owns the `RawSource` protocol and the CIRAWFilter usage contract
(pinned `decoderVersion`, draft-mode previews, `linearSpaceFilter` injection, ProRAW mattes,
capability introspection). This section owns the pipeline-facing consequences: what the stage must
deliver, how recipe parameters map onto each implementation, and the stage decomposition we build
when the escape hatch opens.

**The S1 contract, implementation-independent.** S1 consumes `(file, decode params)` and delivers:
scene-linear Rec.2020 fp16 (unclamped, camera-reference WB), the as-shot neutral, black/white
level metadata, a per-channel **clipping mask** (which sensor photosites were at saturation —
published as a raster any downstream stage can consume: the true-raw histogram and clipped-percent
stats at cull time (D12/D36), highlight-aware tools, the Film Lab's highlight-energy
reconstruction), and per-file capability flags. Everything downstream of S1 is identical on both
paths — that is the point of the protocol.

### 4.1 What CIRAWFilter gives, what it costs

Gives, on day 1, for ~every mainstream camera: format decode, demosaic including X-Trans,
per-camera color matrices, embedded lens corrections, highlight recovery, draft-mode decodes for
cheap previews, and ProRAW semantic mattes free. We run it flat: `boostAmount = 0` (no Apple tone
curve), gamut mapping off, `linearSpaceFilter` as the attachment point while the image is still
scene-referred linear. Apple's display-referred machinery (`localToneMapAmount`, boost shadows) is
never used — D8 admits one transform and it is ours.

Costs, on the record: it is a black box — no access to the mosaic, no demosaic choice, no custom
highlight reconstruction, and no way to splice raw-domain ML between its internal stages (the one
real casualty: v2's Bayer-domain denoise ambition, `docs/07-spec-denoise.md`). Camera support and
rendering are tied to macOS releases — mitigated by the pinned decoder version recorded in every
recipe and goldens keyed to (macOS, decoderVersion), §8. The clipping mask on this path is
approximated from near-saturation values in the decoded image plus metadata white levels, honest
but coarser than mosaic-level truth.

### 4.2 Recipe → RAW-stage parameter mapping

| Recipe parameter | AppleRawSource | LumenRawSource | Why there |
|---|---|---|---|
| Decoder pin | `decoderVersion` | LibRaw + kernel version pin | Rendering stability (D52) |
| Draft/preview scale | `isDraftModeEnabled` + `scaleFactor` | half-res bilinear demosaic LOD | Browse/loupe cost |
| WB | *not applied here* — decode at camera reference | same | WB is S6 CAT16; keeps decode cache WB-invariant (§2.1.4) |
| Exposure | *not applied here* | same | S6 linear multiply; cache locality |
| Highlight reconstruction | `isHighlightRecoveryEnabled` (opaque) | inpaint-opposed (§4.4) | Pre-demosaic data need |
| Lens corrections | `isLensCorrectionEnabled` (embedded profiles) | lensfun-class profile + manual (09-spec-geometry.md) | Optical, belongs at decode |
| EDR decode headroom | `extendedDynamicRangeAmount` (0–2) | native — decode is always full-range | Source headroom for §7 |
| Camera NR (stopgap only) | luminance/color NR properties, until Tier 1 ships | never — Tier 1/2 own denoise | 07-spec-denoise.md |

### 4.3 LumenRawSource: the stage decomposition behind the escape hatch

Built when Apple's ceilings cost us image quality (trigger conditions in `docs/16-roadmap.md`);
designed now so nothing downstream has to move. **LibRaw under CDDL-1.0** (the friendlier half of
its LGPL-2.1/CDDL dual license for a closed-source app) decodes to the u16 mosaic + metadata; then
our Metal kernels:

| # | Stage | Algorithm | Notes |
|---|---|---|---|
| 1 | Black/white levels | per-channel subtraction/scale from metadata | u16 → f32 normalized |
| 2 | Reference WB | camera-neutral multipliers pre-demosaic | demosaic quality assumes sane channel balance |
| 3 | Highlight reconstruction | **inpaint opposed** (§4.4) | emits the clipping mask raster |
| 4 | Demosaic | **RCD** default (near-AMaZE quality, ~600-line reference, GPU-portable, darktable's Bayer default); **LMMSE** for high-ISO/moiré; **Markesteijn** (1-pass draft / 3-pass full) for X-Trans; bilinear for draft LOD | X-Trans first-class — RapidRAW's noted weakness, not ours |
| 5 | Capture sharpen | auto-σ RL, from Bayer greens, *pre-output* | true "at demosaic" placement (r09: darktable 5.4 moved it inside demosaic) |
| 6 | Camera matrix | dual-illuminant DNG `ColorMatrix1/2` interpolation → Rec.2020 | LibRaw ships the Adobe-derived coefficient table |
| 7 | Raw-domain ML splice point | packed 4-channel Bayer + σ-map in, mosaic out | the v2 denoise seat (07-spec-denoise.md); vkdt's jddcnn proves in-pipeline joint denoise+demosaic works |

### 4.4 Highlight reconstruction: one great automatic method

**Inpaint opposed** — darktable's default since 4.2, adopted by RawTherapee 5.10 from the same
author collaboration — reconstructs clipped channels from the opposing unclipped channels'
chromaticity in the clipped region's neighborhood. It is fast, artifact-free at defaults, and
needs zero user decisions. We ship it as the invisible automatic method, plus a single
"Reconstruct+" heavy toggle reserved for a segmentation-class rebuild later if the corpus ever
demands it. We do not ship darktable's five-method dropdown: its own docs concede segmentation
"disguises clipped areas with something plausible" and guided-laplacians is Bayer-only and heavy —
method proliferation is the RT failure mode (r09's complexity catalog), and one honest automatic
beats five explained ones. The transform's highlight desaturation (path-to-white) finishes
whatever reconstruction leaves, which is exactly how darktable's own docs advise capping the heavy
methods anyway.

## 5. Per-stage implementation notes

Engine-level notes: domain, math sketch, cost class, cache behavior. Feature-level detail
(controls, ranges, feel) lives in the owning spec doc.

**Kernel substrate.** Custom Core Image kernels in Metal Shading Language, one `.ci.metallib`.
CI provides lazy graph fusion (adjacent cheap stages compile into one kernel launch), ROI-driven
tiled evaluation, and RGBAh/RGBAf extended-range working formats. We use CI as a graph compiler,
not a filter library: every color-bearing stage is our kernel; stock CI filters appear only where
bit-exactness doesn't matter (thumbnail scaling).

### 5.1 S6 — linear corrections

WB = CAT16 adaptation matrix (as-shot neutral → user Kelvin/Tint target, D9); Exposure = 2^EV
multiply; Printer Lights = per-channel 2^(points/12). All three fuse into a single 3×3 matrix + 
gain per frame — one fused kernel, the cheapest stage in the pipeline, placed exactly where it
protects the expensive caches above it (§2.1.4).

### 5.2 S7 — tone: EV-zone weighting on a guided mask

The six sliders and the Zones panel are one engine (`docs/04-spec-tone.md` owns the recipe): per-
pixel `t = log2(lum/0.18)`, smooth zone windows over `t`, per-zone gains in stops. The luminance
driving `t` is a **guided-filter mask** (exposure-independent variant — darktable's "eigf"), so a
zone edit follows real edges without haloing: the mask is smooth within surfaces and sharp across
edges, which is precisely what LR's parametric highlights/shadows lack (its halos at sky/ridge
boundaries are the visible difference). The engineering lesson darktable's tone equalizer teaches
in reverse (r09): its users must hand-calibrate the mask (two compensation wands, five estimator
choices) before the sliders behave. Lumen **auto-normalizes the mask histogram continuously** —
mask exposure/contrast compensation are recomputed per image from the mask's own statistics, so
zone sliders always address a full, centered tonal axis. The mask computes at working resolution
(guided filter is O(1) box filters), is cached with the decomposition tier, and is shared with S8.

### 5.3 S8 — presence: one decomposition, three tools

One base–detail node computed once per render on log2 luminance (structure and budgets in
`docs/06-spec-detail.md`): guided-filter base (O(1), no gradient reversal — the reason it beats
bilateral for base–detail), an à-trous wavelet stack (Texture's band), a Gaussian pyramid feeding
**local Laplacian** Clarity (fast Aubry variant, 6 sampled remapping curves + piecewise
interpolation — darktable's `locallaplacian.c` parameterization, halo-free by construction), and a
lazily-computed **dark-channel transmission map** (He/Sun/Tang 2011) refined by the same guided
filter for Dehaze, with the color-stable mode neutralizing the estimated airlight cast before
inversion (the LR magenta-sky complaint, fixed at the algorithm level). Slider drags recombine
cached coefficients (≤5 ms); only upstream tone/WB changes recompute the node (≤35 ms at 2560-px
working res). Dehaze's global statistic (airlight) is estimated once at proxy resolution and
frozen for the render — required for tiled export correctness (§6.3).

### 5.4 S9 — color: OKLCh tools, UCS saturation, constant-luminance discipline

Hue-selective tools (mixer bands with periodic falloff, point color, hue equalizer) compute in
OKLCh; saturation/vibrance and the grade's saturation/brilliance compute in the UCS-22-class model
(xyY→UCS, JCH/HSB variants) because it models Helmholtz–Kohlrausch: saturation moves hold
*perceived* brightness constant, which naive HSL cannot do. Two invariants every S9 kernel must
satisfy, enforced by goldens: **luminance moves preserve chroma ratios** (no LR
luminance-slider-desaturates artifact) and **chroma moves preserve luminance** — the invariant
that also keeps the S8 decomposition cache valid under color edits (§2.1.7). Gamut handling
in-stage: a precomputed per-hue max-chroma LUT at the working gamut boundary with soft-clip at
constant hue and brightness (darktable UCS pattern) is always on — no color tool can push a pixel
somewhere the transform will later mangle. Final *display*-gamut mapping is S14's job, hue-
preserving, ACES-2.0-style (compression toward a per-hue focus point, not per-channel clipping).

### 5.5 S10 — grade

Zone windows over log2 luminance shared with S7's machinery (visible pivots/falloffs —
`docs/05-spec-color.md`); wheel tints as constant-luminance hue/chroma offsets; the advanced
chroma/saturation/brilliance grid in the same UCS as S9 with the same always-on soft gamut
mapping. Per-pixel math throughout; the whole stage fuses into a handful of kernels and never
threatens the one-frame budget.

### 5.6 S11 — local adjustments: one concept, two taps

A mask's sub-recipe holds parameter deltas for S6–S10 ops plus local NR and local
Texture/Clarity (which reuse the S8 global decomposition — a local instance is a masked
recombination, not a second decomposition). Evaluation: rasterize the mask stack
(`docs/08-spec-masking.md` owns components, guided-filter feathering at full res, async
recompute), evaluate the delta ops on the stage input, blend through mask alpha in scene-linear.
Multiple masks evaluate in recipe order against the same S11 input — no feedback, no
order-dependent surprises beyond documented painter's-order blending.

The honest wrinkle: D29 grants masks a **local tone curve**, and curves are picture-domain (S15).
So the local stage is one user concept with two engine taps: **tap L1** at S11 (scene-referred —
exposure, zones, color, grade, NR, detail deltas) and **tap L2** at S15 (the local curve
contribution, applied through the same mask raster). Both taps are pre-geometry, so one mask
raster serves both without reprojection. The alternative — forcing local curves scene-referred —
would make a mask's curve feel different from the global curve, a worse inconsistency than one
extra blend.

### 5.7 S13–S14 — the film-lab primitives (r10-verified recipes)

`docs/05-spec-color.md` owns the Film Lab feature; the engine primitives and their placements are
recorded here because they are pipeline structure:

- **Zonal film exposure** — pre-curve EV ("expose into the stock") is an S13-adjacent input to the
  film curve, distinct from display brightness by construction; it is why +1.5 EV into Portra
  produces pastel latitude instead of clipping.
- **Halation (S13, linear light)** — reconstruct highlight energy above the clip (boost range 0.3,
  protect 4.0 EV, seeded by S1's clipping mask), then a 3-bounce sum of Gaussians at σ₁·√k
  spacing (σ₁ = 65 µm at gate scale), geometric decay 0.5, per-channel strengths defaulting to the
  measured (0.05, 0.015, 0.0) RGB — red-dominant because red penetrates to the base and reflects.
  Computed at quarter resolution and upsampled (visually lossless, 4× cheaper); *global support*,
  so it follows the proxy-field rule in tiled export (§6.3).
- **Film characteristic curve (S14 slot)** — per-channel sigmoid in log-exposure→density:
  `D = Dmin + (Dmax−Dmin)·sigmoid(k·(log10 E + offset))`, `k = γ/(0.25·(Dmax−Dmin))`, defaults
  Dmin 0.01 / Dmax 4.0, mid-gray anchored at 0.18; density→transmittance `10^−D` makes color
  subtractive (saturated colors darken — the "expensive" film property). Negative + print = two in
  series with an inversion between. The spectral parts (layer sensitivities, masking couplers, DIR
  inhibition) never run live: baked offline per stock × print × push into 65³ LUTs.
- **Density-domain grain (inside S14)** — pre-baked tileable unit-variance plates per channel
  (particle-model authored offline: 0.2 µm² particles, channel size scale 0.8/1.0/2.0 RGB — blue
  record coarsest), applied in density space with amplitude ∝ √(p(1−p)), p = D/Dmax: grain peaks
  at mid densities and vanishes at Dmin/Dmax, anchored to output print size. Never applied in
  display RGB — that is LR's constant-σ overlay, the thing this model exists to beat.
- **Push/Pull** — one parameter that swaps/interpolates adjacent baked LUTs (curve steepening +
  crossover) while scaling grain amount and plate scale.

Licensing: the reference implementation (spektrafilm) is GPLv3 with an expansive derivative-work
claim; Lumen's implementation is clean-roomed from the primary literature (Giorgianni & Madden;
Hunt ch. 15) and our own datasheet digitization, using the constants above as measured physical
facts (`docs/05-spec-color.md` carries the full posture; ledger in `docs/17-appendix.md`).

### 5.8 S14–S16 — transform, curve, geometry

**S14 transform**: the AgX-class sigmoid with pre-curve primaries inset/rotation and post-curve
purity restore, hue preservation 0–100%, display-peak parameter (`docs/04-spec-tone.md` owns
parameters and presets; §7 owns the peak). Implementation: parameter change → rebake 1D curve
LUT + matrices (<1 ms) → per-pixel apply; the inverted-curve warning evaluates on the baked LUT.
Display-gamut mapping (hue-preserving compression at the display boundary) is the last color
operation inside S14.

**S15 curve**: all curves compile to 1D LUTs on the encoded axis, applied to display-linear
values via encode∘curve∘decode composition; luminance-preserving application by default
(`docs/04-spec-tone.md`).

**S16 geometry**: crop rectangle + angle, perspective homography, and lens-manual distortion
compose into **one** warp evaluated in a single Lanczos-3 resample — never sequential resamples
(each resample is a low-pass filter; two resamples are a blur). Inverse mapping with analytic
Jacobian-based footprint for correct sampling under perspective. Masks and retouch strokes are
stored in source coordinates and reprojected through the current warp — geometry edits after
masking never orphan a mask (the ART documented trap, engineered away; r09).

### 5.9 Scopes computation

All scopes bin from a ~1MP proxy of the viewport composite (post-S16 — scopes describe the picture
you are looking at, including crop) in a compute shader: histogram per channel in the selectable
readout space (working / sRGB 0–255 / output profile — D12), luma waveform and RGB parade as
column-major 256-bin textures, vectorscope as chroma scatter with the skin-tone line overlay.
Budget <1 ms per frame on any Apple Silicon GPU; scopes therefore update live during slider drags
— they are part of the one-frame contract, not a debounced afterthought (darktable bumped its
preview pipe to 1440×900 in 5.6 precisely because scope fidelity at low proxy res was hurting
pickers; ~1MP is that lesson applied from day 1). The **true raw histogram** at cull time comes
from S1's stats, not from this proxy (D36; `docs/10-spec-library.md`).

## 6. Caching and tiling

The Ansel numbers are the argument (measured against darktable 5.0, Feb 2026): recompute only
downstream of a changed parameter and mid-pipeline edits get **5.4–40× faster**; reuse the cached
prefix at export and it is **1.27–100× faster**; keep pipeline work off the GUI thread and idle
power drops from 103 mW to 0.85 mW. `docs/13-architecture.md` §3 owns the actor rules and the
fingerprint definition — `hash(source id, pipelineVersion, target scale, upstream fingerprints,
stage params)`; this section owns which checkpoints exist and how full-res work tiles.

### 6.1 Checkpoints: what gets materialized, at which tier

Cheap stages stay fused inside CI's lazy graph; expensive boundaries materialize as textures.
Two tiers, because the memory arithmetic demands it: at 61MP a full-res fp16 RGBA checkpoint is
~482 MB, but at the 2560-px working resolution it is ~35 MB — so the interactive path keeps many
working-res checkpoints and only two full-res residents.

| ◆ Checkpoint (after) | Tier | Backing | Why it earns materialization |
|---|---|---|---|
| S1 decode | full-res on demand, working-res resident | memory (purgeable heap) | seconds to recompute; everything depends on it |
| S2 AI denoise artifact | full-res | **disk** (versioned, self-healing — 15-catalog.md) | ≤10 s of ANE work; survives relaunch; Amount blends against it for free |
| S5 retouch composite | affected regions | memory + disk strokes | PatchMatch never re-runs on slider moves |
| S8 decomposition coefficients | working-res (export: tiled full-res) | memory | 35 ms to build, ≤5 ms to recombine; shared by three sliders and all masks |
| S11 local composite | working-res | memory | N masks cost one blend chain, re-entered only on mask/local edits |
| S14 input (the developed, graded scene) | working-res | memory | the most-dragged controls (transform, curve, film strength) re-render from here — the tail is per-pixel math, guaranteed ≤16.7 ms |
| Mask rasters, SAM embeddings | per-mask | disk, keyed by (photo, prefix hash, model version) | 08-spec-masking.md / 15-catalog.md own lifecycle |

Downstream-only recompute falls out of the fingerprint chain: a changed parameter changes its
stage's fingerprint and every fingerprint below it — never above. A Dehaze drag re-enters at S8's
recombination; a curve drag re-enters at S15 off the S14-input checkpoint; a WB drag re-enters at
S6 and, by design, invalidates nothing above it (§2.1.4).

All cache textures live in purgeable `MTLHeap`s; eviction under memory pressure is always safe
because every entry is recomputable from `(file, recipe, pipelineVersion)` — losing a cache costs
time, never correctness. `pipelineVersion` sits inside every fingerprint, so an engine upgrade
invalidates stale caches wholesale and automatically (D52); no hand-written invalidation code, no
darktable-`.lrcat-data`-style haunted artifacts.

### 6.2 Interactive rendering: ROI at working resolution

The viewport renders only the visible region of interest at view pixel dimensions (CI's native ROI
evaluation), off the S14-input or nearest-upstream checkpoint. Fit view runs on the high-quality
2560-px working downsample with radii of scale-dependent ops (guided filter, LLF, wavelets) scaled
to preserve apparent effect; the visible ROI then refines from full-res tiles in the background
within 200 ms (D43's approximation contract). This is the answer to the preview-infidelity failure
mode (darktable/RT's "only guaranteed at 100% zoom" — r09): the fit view is never a lie for longer
than one beat, and goldens include working-res-vs-full-res consistency assertions for every
scale-dependent stage.

### 6.3 Export: tiled, with declared halos

Export is the identical pure function at full resolution, reusing every valid checkpoint (above
all the AI-denoise artifact — editing then exporting costs roughly one pipeline tail, not two
pipelines). At 61MP full-res, buffers must tile. Every stage declares its **halo** — the input
support radius beyond a tile's output region — and the tiler renders tiles (2048-px default for
classical stages) with halo overlap and discards the aprons on stitching. Declared halos:

| Stage | Halo | Note |
|---|---|---|
| S1 demosaic | 8 px | RCD/Markesteijn neighborhood |
| S2 AI denoise | 32 px | fixed 512–1024 px ML tiles, fp16 (D26/D48) |
| S3 classical NR | 24 px | wavelet support at deepest level |
| S4 capture sharpen | 64 px | 13×13 max kernel × iteration diffusion, bounded |
| S8 guided base / wavelets | r₁ / 2⁵ px | radius-scaled at export res |
| S8 LLF clarity | pyramid support | computed per-tile with pyramid-depth apron |
| S13 halation | **global** | proxy-field rule (below) |
| S8 dehaze airlight | **global** | statistic frozen from proxy pass |
| S14 grain plates | 0 | pointwise plate lookup |
| S16 geometry | 3 px × warp scale | Lanczos-3 footprint |

**The proxy-field rule** for global-support ops: any operation whose result depends on pixels
arbitrarily far away (halation's glow field, dehaze's airlight, auto-analysis statistics) computes
its field or statistic once at proxy resolution over the whole frame, then applies it per-tile at
full resolution. Tiled and untiled renders must be bit-identical within stage tolerance — a golden
asserts exactly this (§8.1), because overlap-discard bugs are the classic silent export corrupter.

## 7. The HDR/EDR path

One pipeline, one transform, parameterized by display peak (D8/D42). There is no "HDR mode" fork
in the engine — there is a peak parameter.

- **Viewport**: fp16 extended-linear `CAMetalLayer` with `wantsExtendedDynamicRangeContent`.
  CAMetalLayer does not tone-map — values clamp at display max — so S14 always maps content into
  the *current* display headroom itself: white target = min(content's intended peak, live display
  headroom). Reads `NSScreen.maximumExtendedDynamicRangeColorComponentValue` (plus potential and
  reference variants), subscribes to `NSApplication.didChangeScreenParametersNotification`, and
  slews the transform's white target smoothly over ~200 ms when headroom changes (window dragged
  between displays, other EDR content lighting up the panel) — never a hard jump, which reads as
  a rendering glitch.
- **Headroom adaptation is the transform, not a post-op**: because the sigmoid's white target is a
  first-class parameter (20–1600% of SDR white), SDR at 100% and HDR at N× are the same curve
  family with the same grade underneath — the property §2.2 depends on.
- **SDR-proof toggle**: clamps the parameter to 1.0 so both renditions are graded deliberately
  (`docs/04-spec-tone.md`'s HDR Editing Mode owns the controls).
- **Export**: render twice — peak 1.0 (the SDR base rendition, always deliberate) and the chosen
  HDR peak (default 2–4× SDR white for photographic content) — and derive the gain map from the
  pair. Formats, gain-map math, and the delivery matrix are `docs/11-spec-output.md`'s; the
  pipeline's contribution is that "render twice at two peaks" is cheap (one shared S14-input
  checkpoint, two per-pixel tails).
- Source headroom: `extendedDynamicRangeAmount` at decode (Apple path) or native full-range decode
  (Lumen path) delivers whatever the file carries; scene-referred unboundedness (§1.1) preserves
  it to S14 untouched.

## 8. Golden-image testing and `pipelineVersion` discipline

The pipeline is only refactorable because it is testable, and only trustworthy because it never
changes silently.

### 8.1 Golden corpus and assertions

- **Corpus**: fixed 512² crops from the owner's own raws — Bayer and X-Trans, base-ISO landscape,
  ISO 12800 night, clipped-highlight stage light, skin under mixed light, an EDR-bright frame, a
  ProRAW DNG — plus synthetic ramps (banding detection) and a hue wheel (gamut/hue-skew
  detection). Small crops keep the suite seconds-fast so it runs on every commit.
- **Per-stage goldens**: each stage has reference outputs for a matrix of parameter points.
  Assertions: max ΔE00 against reference (stage-declared tolerance, typically ≤0.5; ≤0.1 for
  matrix-only stages) plus a perceptual hash for gross-structure regressions. Scene-referred
  stages additionally assert unboundedness survival (§1.1): values >1.0 and <0.0 must emerge
  intact.
- **Precision conformance**: every stage's fp16-buffered production path runs against its f32
  reference on the ramp corpus; deep-shadow crops are pushed +4 EV post-stage and inspected for
  banding energy (§1.4's rationale, mechanized).
- **Tiling conformance**: tiled full-res render vs untiled render, bit-identical within stage
  tolerance, including the proxy-field ops (§6.3).
- **Scale conformance**: working-res render upsampled vs full-res render downsampled, within
  perceptual tolerance, for every scale-dependent stage (§6.2's no-lying-preview contract).
- **Apple-stage goldens are environment-keyed**: expectations recorded per (macOS version,
  `decoderVersion`). A macOS update that shifts CIRAWFilter rendering fails CI loudly instead of
  shifting user images quietly — that is the alarm the pinned decoder contract needs.
- Golden re-baking happens only via an explicit script that (a) records the intent and the diff
  statistics in the migration ledger and (b) bumps `pipelineVersion` when the change is
  look-affecting. There is no other path to changing a golden.

### 8.2 `pipelineVersion` (D52): explicit, badged, never silent

Every recipe records the `pipelineVersion` (and, on the Apple path, decoder version) it was
authored under; the version is part of every cache fingerprint (§6.1). When the engine's rendering
changes look-affectingly:

1. **Old recipes keep rendering with their pinned version's math.** The renderer maintains
   per-version compatibility parameters (curve constants, mask estimator revisions) for shipped
   versions — the cost of carrying a few constant sets is trivial next to the trust it preserves.
2. **Migration is offered, badged, per-image or per-selection — never applied.** The UI shows a
   version badge on affected images and a side-by-side before/after preview of the upgrade;
   the user commits it as an undoable history step. This is the explicit negation of Lightroom's
   silent process-version upgrades, which taught a generation of photographers that opening an old
   catalog can change their pictures.
3. **The migration ledger** (in-repo, shipped in release notes) documents every bump: affected
   stages, visual delta description, golden diff statistics. A `pipelineVersion` bump without a
   ledger entry fails CI.

### 8.3 Performance harness

The latency budgets declared across docs 04–12 are measured here, on-device, in CI (D47's
five-loop release gate): instrumented stage timings around the render actor measure p95 slider →
frame at working resolution (budget 16.7 ms), photo-switch to first correct frame, cull paging,
AI round-trips, and export throughput, on the 16 GB floor machine and the comfort-spec machine.
A stage that busts its budget fails the build the same way a golden mismatch does — stability and
latency are product features with regression tests, not aspirations (LR 15.4's pulled release is
the standing cautionary tale).

---

*Provenance: stage math and constants in this doc trace to the session-verified sources in the
research digests — darktable `sigmoid.c` / `locallaplacian.c` / `hazeremoval.c` / UCS-22 helpers
(r09, r11), RawTherapee `capturesharpening.cc` (r11), the spektrafilm spectral film model and
Resolve-compatible DCTL recipes (r10), Apple's CIRAWFilter/EDR/Adaptive-HDR documentation (r11),
and Ansel's cache benchmarks (r09). Full bibliography: `docs/17-appendix.md`.*
