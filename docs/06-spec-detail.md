# 06 — Presence & Detail

Texture, Clarity, Dehaze, the three-pass sharpening system, the heavy detail tools, vignette, and
the grain pointer. This is the panel where Lumen wins a *visible* quality fight with Lightroom:
LrC's Clarity halos at sky/land edges and Dehaze's magenta cast are its two most-documented image
quality complaints, and both are fixed here by construction, not by tuning.

Scope boundaries: noise reduction (classical and AI) is `docs/07-spec-denoise.md`. Film grain and
halation live in the Film Lab, `docs/05-spec-color.md` (the pointer entry at the end of this doc
explains why). Lens corrections, diffraction, and defringe are `docs/09-spec-geometry.md`. Output
sharpening execution and recipes are `docs/11-spec-output.md`; this doc owns the sharpening model
it plugs into. Pipeline stage order and caching are owned by `docs/14-pipeline.md`; the slider
interaction contract (click-anywhere rows, scrubby numbers, typed entry, Alt-drag diagnostics,
double-click reset) is owned by `docs/12-spec-ux.md` and applies to every control below.

Four commitments govern this panel:

1. **Halo-free by construction.** Local contrast runs on a local-Laplacian pyramid and base–detail
   splits run on guided filters — operators that cannot produce gradient-reversal halos — instead
   of the bilateral/USM machinery that makes LrC ring at high-contrast edges. Adobe shipped mask
   Feather/Edge controls in LrC 15.5 to help users *paint around* their halos; we decline to
   generate them.
2. **Luminance tools leave color alone.** Texture, Clarity (Natural), Dehaze (color-stable), and
   all sharpening operate on luminance and recombine preserving RGB ratios. Saturation moves only
   when a control says so in its name (Clarity Punch). This single rule retires three separate
   LrC complaint threads (Clarity saturation push, Dehaze casts, sharpening color fringing).
3. **Fraser's three-pass doctrine** (`docs/01-research-literature.md`): capture sharpening undoes
   the optical chain once, automatically; creative sharpening is a local, masked decision
   (`docs/08-spec-masking.md`); output sharpening is a function of output size and medium, applied
   at export (`docs/11-spec-output.md`). One mental model, three stages, no double-sharpening.
4. **One engine, many names (D25).** The heavy machinery — deconvolution, multiscale diffusion —
   is surfaced only as named tools with one or two sliders each. darktable's diffuse-or-sharpen,
   whose own docs admit "users are likely to be overwhelmed" and which survives only through its
   21 presets, is the named anti-pattern: ship the presets as products, never the math.

The Detail panel, top to bottom:

```
┌─ DETAIL ─────────────────────────────────────┐
│ PRESENCE                                     │
│   Texture   −100 ────○──── +100              │  wavelet band, edge-gated negative
│   Clarity   −100 ────○──── +100  Natural ▾   │  local Laplacian; Natural / Punch
│   Dehaze    −100 ────○──── +100  [⋯]         │  disclosure: Distance · Preserve color
│                                              │              · Ambient eyedropper
│ SHARPEN                                      │
│   ◉ Capture (auto)     σ 0.64 px    [⋯]      │  RL deconvolution; refine disclosure
│   Amount · Radius · Detail · Masking         │  LR 4-slider contract, Alt-views
│   Halo Suppression                           │  the C1 control LR never shipped
│                                              │
│ MORE TOOLS ──────────────────────── [⌄]      │
│   Deblur · Local Contrast · Bloom            │  named faces of one shared engine
│                                              │
│ EFFECTS                                      │
│   Vignette (post-crop, EV)                   │
│   Grain → lives in Film Lab (docs/05)        │
└──────────────────────────────────────────────┘
```

---

### Texture

**What it is.** Mid-frequency detail contrast — pores, fabric weave, bark, sand — as an explicit
wavelet band gain. Negative values are the skin smoother: they attenuate texture while an edge
gate preserves structural lines, so faces soften without the negative-Clarity "glow."

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Texture | −100…+100 | 0 | Same name and range as LrC (D23); Alt-drag shows the affected band as a signed overlay |

**How it works.** The shared decomposition (engineering note below) includes an à-trous wavelet
stack of log2 luminance. Texture applies a gain to the mid scales — anchored in physical detail
size (~2–8 px at 24MP, scaled with sensor resolution so the band means the same thing on a 61MP
file), with smooth cosine band edges so adjacent scales blend rather than seam. Positive values
multiply band coefficients; negative values attenuate them through a gate derived from the local
gradient structure: coefficients that belong to coherent, high-contrast edges (eyelashes, jawline,
horizon) keep their energy, isotropic mid-frequency texture (pores, noise-adjacent detail) loses
it. This is the behavior Adobe's Max Wendt built Texture for in LrC 8.3 — born as a skin-smoothing
project — implemented as an explicit, inspectable band instead of a tuned black box. Chroma
coefficients are untouched; recombination scales RGB by the luma ratio, so color cannot shift.

**How it feels.** First slider in the panel. Drag cost is band recombination only (the wavelet
stack is cached), inside the 16.7 ms preview budget (D43). Alt-drag shows a signed overlay (red =
gained, blue = attenuated) — the same "show me what it changed" visualization darktable's color
equalizer proved out. Negative Texture inside a face-skin mask (`docs/08-spec-masking.md`) is the
canonical portrait recipe; the AI person mask makes it two clicks.

**Vs. the field.** **LrC 15.5:** equal contract (identical name/range — deliberate; Texture is one
of LrC's best-loved sliders and Adobe documents it as "doesn't affect color too much"). Better in
two specifics: ours affects color *not at all* (ratio recombination is exact, not approximate), and
the edge gate is stronger at the thing negative Texture exists for — Adobe's own docs say it "only
affects parts where there are no strong lines"; ours states the gate and shows it on Alt-drag.
**Capture One 16.8.4** (Structure slider, ±100): better, because C1's Structure is an ungated
micro-contrast boost — its negative direction smooths edges and texture alike; our negative
direction is skin-safe by design.

---

### Clarity

**What it is.** Midtone-weighted local contrast on a local-Laplacian pyramid — halo-free by
construction. This is the single most visible engine win over Lightroom: push +60 Clarity on a
mountain ridge against sky and LrC draws a bright halo; Lumen does not. Two character modes,
Natural (default) and Punch, follow Capture One's precedent.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Clarity | −100…+100 | 0 | Same name/range as LrC (D23) |
| Mode | Natural, Punch | Natural | Dropdown beside the slider; per-image, stored in the recipe |

**How it works.** Fast local Laplacian filtering (Paris/Hasinoff 2011, Aubry fast variant) on log2
luminance: a per-pixel remapping function applied across a Laplacian pyramid, evaluated with 6
sampled remap curves and piecewise interpolation — the exact architecture darktable's local
contrast module ships (verified in `locallaplacian.c`) and the published halo-free gold standard.
The remap curve is midtone-weighted (a smooth weight centered on mid-gray, falling off toward the
endpoints), so Clarity expands local contrast where LrC's does without touching the white/black
points `docs/04-spec-tone.md` owns. Negative Clarity compresses local contrast — a clean soft-focus
effect with no bloom leak, because the pyramid respects edges at every scale. **Natural** mode
recombines by RGB ratio: zero saturation change. **Punch** adds a chroma gain at ~35% of the
Clarity amount, applied in OKLCh with the skin-hue protection band and soft gamut clip from
`docs/05-spec-color.md` (D21) — the landscape "pop" mode, safe on incidental faces. Why halo-free
matters mechanically: USM and bilateral-based local contrast overshoot across strong edges
(gradient reversal); the local Laplacian's per-level remapping cannot overshoot, which is why
darktable adopted it and why LrC — still on its 2012-era decomposition — halos to this day.

**How it feels.** Second slider. The Gaussian pyramid is part of the shared decomposition, so drags
recombine cached levels: ≤16.7 ms at screen resolution, full-res refine ≤200 ms (D43). Alt-drag
shows the signed change overlay. Mode dropdown defaults to Natural and most users should never
touch it; the recipe records it so a Punch landscape preset travels correctly.

**Vs. the field.** **LrC 15.5:** better, and visibly — halos at dark-edge/sky boundaries are LrC's
most-documented Clarity failure ("the effect of too much Clarity is still obvious from a mile
off"), plus LrC's Clarity pushes saturation as a side effect; Natural mode moves chroma zero.
This comparison is the marquee A/B screenshot for the whole product. **Capture One 16.8.4**
(best-in-class — 4 methods: Natural/Punch/Neutral/Classic + Structure): equal on character range —
our 2 modes cover C1's useful space (C1's Neutral is Punch-without-chroma, which Natural already
is; Classic is its legacy halo-prone algorithm kept for compatibility we don't carry) — and better
on engine: C1's Natural *suppresses* false halos heuristically; the local Laplacian cannot create
them. Negative-Clarity skin softening, C1's beloved trick, works identically here and is halo-free
at larger negative values than C1 tolerates.

---

### Dehaze

**What it is.** Physically-modeled haze removal — dark-channel prior with guided-filter
transmission refinement — with a Distance control LrC lacks and a color-stable mode that kills the
magenta/blue casts Adobe has an open bug thread about (D23). Negative values add photographic
atmosphere.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Dehaze | −100…+100 | 0 | Same name/range as LrC (D23) |
| Distance (disclosure) | 0–100 | 20 | How deep into the haze the correction reaches; maps darktable's `distance` 0–1 |
| Preserve color (disclosure) | on/off | on | Ratio-preserving application; off = "Atmospheric" per-channel physics |
| Ambient (disclosure) | eyedropper | auto | Overrides the estimated atmospheric light color; C1's Shadow Tone idea |

**How it works.** He/Sun/Tang's dark channel prior (TPAMI 2011), the algorithm darktable ships
verbatim in `hazeremoval.c`: per-pixel windowed min across RGB gives the dark channel; atmospheric
light **A** is estimated from the brightest fraction of the dark channel (eyedropper overrides);
transmission `t = 1 − ω·darkchannel/A` is refined with a guided filter on luminance (edge-aligned,
no blocky transmission seams — the refinement reuses the shared decomposition's guided-filter
machinery); recovery is `J = (I − A)/max(t, t_min) + A` on scene-linear data, where the haze model
is actually valid — one advantage of running pre-display-transform that display-referred dehazes
cannot have. Dehaze ±100 maps to ω and the recovery blend; negative values blend toward A,
synthesizing haze for atmosphere (LrC's PV5 negative-dehaze noise fix is moot here — scene-linear
synthesis adds no noise). Distance caps `t_min`: low values correct only nearby haze and leave
distant atmosphere as depth cue — the control that makes Dehaze usable on mountain layers, absent
in LrC. **Preserve color** (default on) computes the recovery on luminance and applies the ratio
to RGB: neutrals stay neutral, no magenta shift, no saturation surge. Toggling it off gives the
per-channel physical model for genuinely color-casted haze (smog, sandstorm), where shifting color
is the point. A transmission floor on high-luminance/low-gradient regions keeps skies from
over-darkening (tuning detail, gated by golden tests, `docs/14-pipeline.md`).

**How it feels.** Third slider. Transmission is computed lazily on first non-zero drag, then cached
with the decomposition; subsequent drags are recombination-only, ≤16.7 ms at screen resolution.
Alt-drag visualizes the transmission map (near = dark, far = bright) — instantly explains what
Distance does. The disclosure row exists because 95% of uses are the single slider (D3).

**Vs. the field.** **LrC 15.5:** better on three documented complaints — "Dehaze altering the
color balance" is an open Adobe bug (magenta neutrals, blue/green shadow casts, saturation surge);
our default mode makes the failure impossible; and LrC has no Distance and no ambient override.
**Capture One 16.8.4** (best-in-class color stability — auto Shadow Tone + eyedropper, rated "more
natural than LR's"): equal on color stability (we adopt their eyedropper idea), better on Distance
and on interactivity (C1 recomputes fully per drag; our cached transmission recombines).
**darktable 5.6:** identical science — same algorithm, same parameterization; better surface: LR
range denominations, color-stable default, transmission Alt-view. We take their engine and finish
the product around it.

---

## Engineering note: one decomposition, three sliders (and the masks too)

Texture, Clarity, and Dehaze share a single **base–detail decomposition node**, computed once per
render at working resolution (D23):

```
                       log2(luma) of stage input
                                │
        ┌───────────────┬───────┴────────┬──────────────────┐
        ▼               ▼                ▼                  ▼
  guided-filter    à-trous wavelet   Gaussian pyramid   dark channel +
  base (r₁, O(1)   stack, 5 scales   (feeds local       guided-refined
  box filters)     (feeds Texture)   Laplacian:         transmission
                                     Clarity)           (lazy; Dehaze only)
```

Properties that matter:

- **Adjustment-independent.** The decomposition is a function of the *image*, not of any slider.
  Dragging Texture, Clarity, or Dehaze recombines cached coefficients — that is why all three hit
  the 16.7 ms one-frame budget simultaneously, where LrC recomputes per drag. Budget: full
  decomposition ≤35 ms at 2560-px working resolution on a base M-series GPU; recombination ≤5 ms.
- **Shared with masks.** Per-mask Texture/Clarity/Dehaze (`docs/08-spec-masking.md`) reuse the
  same global decomposition — a local instance is a masked recombination, not a second
  decomposition. Sixteen masked clarity adjustments cost roughly one.
- **Cache discipline.** The node participates in pipeline-prefix caching (D49): upstream changes
  (WB, tone) invalidate it; downstream changes never do. Export recomputes it tiled at full
  resolution with declared halo = max(guided radius, pyramid depth support) —
  `docs/14-pipeline.md` owns the tiling contract.
- **Scale honesty.** darktable and RT both warn their detail modules are "only guaranteed at 100%
  zoom" — preview infidelity that erodes trust (r09's failure-mode list). Lumen's fit-view runs
  the same decomposition on the high-quality downsample with radii scaled to preserve apparent
  effect, and the visible ROI refines from full-res tiles in the background within 200 ms. The
  fit view is never a lie for longer than one beat.

---

### Capture Sharpening (automatic, on by default)

**What it is.** Pass one of the Fraser doctrine: auto-radius Richardson–Lucy deconvolution that
undoes the blur of the optical chain (lens + AA filter + demosaic) once, at the raw stage, with
the PSF radius measured from the image's own Bayer data. On by default for raw files. This is
RawTherapee's proven recipe (verified in `capturesharpening.cc`, r11) shipped as a product instead
of an option (D24).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Capture sharpening | on/off | on (raw only) | Header toggle; readout shows measured σ, e.g. "σ 0.64 px · corner +0.3" |
| Radius (disclosure) | Auto, or 0.4–2.0 px | Auto | Manual override for the estimated σ |
| Iterations (disclosure) | 4–24 | 8 | RL iteration count; more = crisper, slower, riskier on noise |
| Corner boost (disclosure) | 0–100 | 50 | Radial σ increase toward corners, capped at σ+0.5 (≤2.0) |
| Threshold (disclosure) | 0–100 | Auto from ISO | Contrast-sensitivity noise gate; Alt-drag = gate mask view |

**How it works.** Iterative RL-style Gaussian deconvolution on luminance immediately after
demosaic: repeat {blur the estimate; divide the original by the blur; multiply}. The kernel is
σ-adaptive (3×3 below σ 0.6 up to 13×13 above σ 1.5 — RT's table), with early stop when per-pixel
change falls below threshold. The differentiating trick is **auto-radius**: σ is estimated as
`sqrt(1/log(maxRatio))` over adjacent *unclipped Bayer green* ratios — the sensor's own greens
measure the real system PSF of this exposure, this lens, this aperture, no lens database required.
**Corner boost** interpolates σ upward with field distance, approximating lens field softness. The
noise gate masks deconvolution away from low-contrast regions so it never amplifies noise; its
threshold interpolates from the ISO-adaptive anchors (`docs/07-spec-denoise.md`, D27), so ISO
12800 frames automatically gate harder and drop to 6 iterations. Runs once per decode at full
resolution inside the raw stage (custom `RawSource` path; on the `CIRAWFilter` path it runs on the
returned linear image immediately after decode — the honest approximation of "at demosaic," noted
in `docs/14-pipeline.md`), cached with the decode: toggling it is a cache splice, not a recompute.

**How it feels.** One toggle with a readout. The σ readout is the trust device — it tells you the
system measured *your* lens ("σ 0.58 on the 35/1.8, σ 0.71 wide open") rather than applied a
constant. Two Alt-view visualizations from darktable 5.4's version: the noise-gate mask and the
corner-boost field. Off for JPEG/HEIC (already sharpened in camera). The disclosure exists for the
1% — the default posture is: never open it.

**Vs. the field.** **LrC 15.5:** better — LrC has no capture-stage deconvolution; its Detail
slider blends toward deconvolution but with a hand-set radius, and its default Amount 40 is a
constant, not a measurement. **DxO PhotoLab Lens Sharpness** (the category leader; PL8-era facts —
current PL9/Nik generation was not verifiable this session, D53): **consciously an approximation
and honest about it** — DxO applies per-lens-module *measured* MTF softness maps, field position
by field position, and where a module exists it will beat a single-σ-plus-radial-boost model. Our
counter: the image-derived σ adapts to *every* lens ever made, including adapted glass and lenses
DxO never profiled, and it measures the actual shooting aperture's blur rather than a lab profile.
We state the gap; we do not claim parity. **RawTherapee 5.13 / darktable 5.6:** equal math — it is
their recipe, credited (RT originated it; dt 5.4 adopted it inside demosaic; RT 5.13 extended it
with presharpening denoise) — better product: on by default, self-calibrating, one toggle with a
readout, where RT buries it among 30 Detail options and dt hides it inside the demosaic module.

---

### Manual Sharpening

**What it is.** The familiar four-slider surface — Lightroom's Amount/Radius/Detail/Masking
contract with its Alt-drag diagnostic views, cloned exactly — plus the fifth slider Adobe never
shipped: Capture One's Halo Suppression (D24).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Amount | 0–150 | 0 (raw), 0 (JPEG) | Capture auto does the raw baseline; inline hint offers LR-classic 40/1.0/25/0 when capture is off |
| Radius | 0.5–3.0 px | 1.0 | Alt-drag = edge-emphasis view |
| Detail | 0–100 | 25 | 0 = halo-suppressed USM; 100 = deconvolution-weighted fine texture — LR semantics kept |
| Masking | 0–100 | 0 | Edge mask; Alt-drag = white/black mask view (the most-taught trick in LR pedagogy) |
| Halo Suppression | 0–100 | 0 | Damps bright edge outlines; lets Amount ≥80 stay clean — C1's control |

**How it works.** Luma-only sharpening late in the pipeline (after local edits, so masked Clarity
is never double-sharpened — ordering owned by `docs/14-pipeline.md`). Amount scales edge-contrast
gain; Detail cross-fades between a halo-damped unsharp component and a deconvolution component
that amplifies the finest wavelet scales (reusing the shared wavelet stack — the Masking edge mask
is derived from it for free). Halo Suppression asymmetrically limits the *bright* overshoot of
sharpened edges (bright halos are perceptually much more objectionable than dark lines — the
insight behind C1's control). All sharpening recombines by RGB ratio: no color fringing at edges.

**How it feels.** Sits under the Capture toggle. Clicking any sharpen slider's label opens a 1:1
detail loupe at the image center (draggable) — sharpening judged at fit zoom is guesswork, and the
loupe removes the zoom-in ritual. All four Alt-views match LR's exactly: grayscale for Amount,
edge overlays for Radius/Detail, white/black for Masking. Muscle memory transfers untouched.

**Vs. the field.** **LrC 15.5:** better — the identical contract (deliberate: this 4-slider +
alt-view design is the reference capture-sharpening UX and every refugee knows it) plus Halo
Suppression, which LR/ACR have no equivalent for. **Capture One 16.8.4:** better — C1 has Halo
Suppression and a Threshold but lacks LR's Detail-slider USM/deconvolution blend and its
diagnostic Alt-views; we ship the union of both control sets. Nobody else does.

---

### Output Sharpening

**What it is.** Pass three: fully automated, export-time sharpening as a function of output pixel
size and medium — the Screen / Matte / Glossy × Low / Standard / High matrix Lightroom licensed
from Pixel Genius PhotoKit (Fraser's own productization of his doctrine), reimplemented.

**Controls.** Medium (Screen/Matte/Glossy) × Strength (Low/Standard/High), per export recipe;
defaults Screen/Standard. Owned by `docs/11-spec-output.md` — this entry defines the model only.

**How it works.** Applied after resize, on the final output-resolution pixels: radius and gain
derive from output PPI and medium (print media diffuse ink dots and need larger-radius, stronger
sharpening than screens). It reuses the halo-suppressed USM kernel from Manual Sharpening at
output scale. Because it is a pure function of (pixels, medium, strength), it is a recipe field,
not an editing decision — set once per export recipe and forgotten.

**How it feels.** Two dropdowns in the export recipe editor; soft-proofing shows a print-size
sharpening preview (D41). Never appears in the Develop UI.

**Vs. the field.** **LrC 15.5:** equal — same licensed-pattern matrix, same automation level
(deliberate; this is a solved problem). Better only through context: Lumen's multi-recipe export
(D40, `docs/11-spec-output.md`) applies *different* output sharpening per recipe in one export
click — full-res Glossy for print and 2048-px Screen for web simultaneously — which LrC's
single-shot export dialog cannot. **Capture One 16.8.4:** equal — C1's per-recipe output
sharpening is exactly this design and validates it.

---

## One engine, many names (D25)

The heavy detail machinery — iterative deconvolution and multiscale edge-aware diffusion — can
express deblurring, dehazing, local contrast, bloom, denoise finishing, and inpainting from one
parameterization. darktable ships that engine raw as diffuse-or-sharpen: 4 diffusion orders ×
speed × anisotropy plus edge thresholds, docs that literally warn users off, and 21 presets that
are the only way anyone uses it. The presets prove the engine; the exposed math disproves the UI.

Lumen ships the same class of engine (shared wavelet/diffusion solver + the RL deconvolution
kernel from Capture Sharpening) surfaced **only** as three named tools, in the More Tools
disclosure, each with one or two sliders and honest names:

### Deblur · Local Contrast · Bloom

**What it is.** Three named tools over the shared engine: Deblur recovers slight defocus/AA
softness beyond what capture sharpening targets; Local Contrast is large-radius scene punch
(bigger structures than Clarity); Bloom is a soft highlight diffusion glow.

**Controls.**

| Tool | Control | Range | Default | Engine mapping |
|---|---|---|---|---|
| Deblur | Amount | 0–100 | 0 | Extra RL iterations at user σ |
| Deblur | Radius | 0.5–3.0 px | 1.0 | Deconvolution σ |
| Local Contrast | Amount | 0–100 | 0 | Local-Laplacian remap gain at coarse pyramid levels |
| Local Contrast | Radius | 20–200 px | 80 | Pyramid level weighting center |
| Bloom | Amount | 0–100 | 0 | Isophote-directed diffusion of values >1 EV above mid-gray, screened back |

**How it works.** Deblur is the capture-sharpening deconvolution kernel with user-set σ and more
iterations — for the frame that is *almost* sharp (missed focus by a hair, heat shimmer). Local
Contrast drives the same local-Laplacian pyramid as Clarity but weighted at coarse levels: it
moves hillsides and cloud banks where Clarity moves faces and rocks — two named tools, two honest
scales, one engine, no double compute (shared pyramid). Bloom diffuses only above-threshold
scene-linear highlights along isophotes and screens the result back — atmosphere without lifting
blacks. All three run at ≤200 ms refine (D43's approximation budget) with an immediate screen-res
approximation; Deblur is the heaviest and shows a subtle progress shimmer on the loupe.

**How it feels.** Collapsed by default; zero cost to the 95% who never open it. Each tool is one
row: name, slider(s), off by default. No dropdown of methods, no anisotropy, no orders.

**Vs. the field.** **darktable 5.6 diffuse-or-sharpen** (the engine donor): consciously narrower —
we ship 3 named tools where dt's presets list 21, because the other 18 are covered elsewhere in
Lumen (dehaze here, denoise in `docs/07-spec-denoise.md`, sharpen at capture, inpaint in
`docs/09-spec-geometry.md`) or are novelty (watercolor, line drawing). What we drop is the math
surface, and that is the point. **LrC 15.5:** better — Lightroom has no deblur of any kind, no
large-radius local contrast (users fake it with Dehaze+Contrast), no bloom (users abuse negative
Clarity). **Capture One 16.8.4:** better — C1's Classic Clarity approximates large-radius local
contrast but with the halo-prone legacy algorithm; no deblur, no bloom. Note: Bloom is neutral
optical diffusion; the Film Lab's halation (`docs/05-spec-color.md`, D18) is red-dominant
pre-curve film physics. Different intent, different tool, per the never-two-tools-for-one-intent
rule (D3) — the intents genuinely differ.

---

### Vignette

**What it is.** Creative post-crop vignette, denominated in stops. In a scene-referred pipeline
this needs one style, not Lightroom's three: EV-multiplication before the display transform gives
highlight-priority behavior and hue stability by construction.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Amount | −3.00…+1.00 EV | 0 | Negative darkens corners; EV-denominated (C1's idea) |
| Midpoint | 0–100 | 50 | How far the falloff reaches toward center |
| Roundness | −100…+100 | 0 | −100 rectangular … +100 circular |
| Feather | 0–100 | 50 | Falloff softness |
| Highlight protection | 0–100 | 50 | Reduces darkening on pixels above scene white ÷ 2; specular sparkle survives the corner |

**How it works.** A radial falloff mask parameterized on the **crop rectangle** (recomputed
whenever crop changes — post-crop semantics), applied as an EV multiply (`2^(Amount·falloff)`) on
scene-linear RGB before the display transform. Because the display transform's shoulder compresses
what remains bright, clipped speculars and lamps punch through the darkening naturally — LrC's
"Highlight Priority" behavior emerges from pipeline position instead of being one of three modes.
Because the transform is hue-preserving (D8), darkened corners do not color-shift — the documented
failure of LrC's Highlight Priority mode. Highlight protection blends the multiply toward identity
above the threshold for stronger-than-natural specular punch-through. Corrective lens vignetting
is a different job and lives with lens corrections in `docs/09-spec-geometry.md` — C1's clean
corrective/creative separation, adopted.

**How it feels.** Effects section, four sliders and a disclosure for protection. Amount reads in
stops ("−1.3 EV"), which makes vignettes transferable across images in a way LrC's unitless −100
never was — a −0.7 EV edge burn means the same thing on every exposure. Trivial compute; always
inside the frame budget.

**Vs. the field.** **LrC 15.5:** better — equal control vocabulary (Midpoint/Roundness/Feather
kept with LR's ranges and defaults) but EV denomination, no color shift in darkened areas, and
highlight-priority behavior without a style dropdown. Consciously dropped: Color Priority (our
default *is* color-stable) and Paint Overlay (legacy LR2 flat-paint blend, community-documented as
muddy and unused). **Capture One 16.8.4:** better — we adopt C1's EV denomination and its
corrective/creative split, then add the Midpoint/Roundness/Feather shaping and post-crop semantics
C1's simpler tool lacks.

---

### Grain (pointer — lives in the Film Lab)

**What it is.** A pointer, not a tool: Lumen has film grain, but it is part of the Film Lab
(`docs/05-spec-color.md`, D18), not the Detail panel.

**Why it lives there.** LrC's Effects-panel grain (Amount/Size/Roughness) is screen-space
monochrome luminance noise stirred in near the end of the pipe — the same everywhere in the frame,
the same at every density, resolution-dependent. Real film grain is a property of *density*:
strongest at mid densities (the p(1−p) statistics of developed silver), nearly absent in clear
shadows and blocked highlights, per-channel in size (blue-sensitive layer coarsest), and anchored
to print size. That behavior requires living where the Film Lab computes density — inside its
characteristic-curve chain — which is why grain is specified there, alongside halation and
Push/Pull (which couples grain to contrast, as pushing film actually did). One consequence stays
in this doc's domain: **re-graining** — matching synthesized grain into AI-denoised areas
(`docs/07-spec-denoise.md`) and healed patches (`docs/09-spec-geometry.md`) uses the Film Lab's
grain engine so fills never read as plastic against a grained frame.

**Vs. the field.** **LrC 15.5:** better — LR's grain is competent but generic (its historic user
ask is per-channel/film-stock realism; Adobe never shipped it); density-domain grain holds up at
100% and in prints where screen-space noise falls apart. **Capture One 16.8.4:** better — C1's
five grain *types* (Fine/Silver Rich/Soft/Cubic/Tabular) acknowledge the physics but still apply
output-referred; density-domain simulation is the next rung. Full spec and verdict detail in
`docs/05-spec-color.md`.

---

## Latency budget summary (enforced per D43/D47; measurement harness in docs/14-pipeline.md)

| Operation | Budget |
|---|---|
| Texture / Clarity / Dehaze drag (decomposition cached) | ≤16.7 ms screen-res; ≤200 ms full-res ROI refine |
| Shared decomposition recompute (upstream change) | ≤35 ms at 2560-px working res |
| Capture sharpening (per decode, cached) | background; never blocks first preview |
| Manual sharpening drag | ≤16.7 ms in loupe ROI |
| Deblur / Local Contrast / Bloom | immediate approximation; ≤200 ms refine |
| Vignette drag | ≤16.7 ms |

Sources for the claims above (RT `capturesharpening.cc`, darktable `locallaplacian.c` /
`hazeremoval.c` / diffuse-or-sharpen presets, LrC 15.5 and C1 16.8.4 behavior, Paris/Hasinoff and
He/Sun/Tang papers) are catalogued in `docs/17-appendix.md`.
