# 02 — Research: The Lightroom Classic Teardown

Lightroom Classic is the incumbent Lumen must beat and the muscle memory Lumen must respect. This
document is the complete teardown: every panel, slider, range, default, and hidden interaction of
**Lightroom Classic 15.5** (released 2026-08-03, verified 2026-08-19), plus the masking system, the
library machinery, the documented user sentiment of 2024–2026, and — at the end — the scope-decision
tables that assign every LR feature a Lumen verdict. The spec docs (04–12) point back into this file;
this file points forward to whichever spec doc owns each decision. Facts a research digest could not
verify are marked `(unverified)`.

Format per section: **finding → evidence → what Lumen takes.**

---

## 1. Version and process-version context

**Finding.** LrC's tone model has been frozen since 2012; its rendering engine is versioned, and the
version migrates silently.

**Evidence.** Current app version is 15.5 (Aug 3, 2026). The 2025–26 release cadence:

| Ver | Date | Highlights |
|---|---|---|
| 14.2 | Feb 2025 | Adaptive Profiles (AI base profiles, SDR+HDR); tether focus-point click |
| 14.3 | Apr 2025 | Landscape Masking (8 semantic classes) |
| 14.4 | Jun 2025 | Denoise/Raw Details/Super Resolution made **non-destructive** (no side-car DNG); AI Edit Status icon; Auto-XMP batching |
| 14.5 | Aug 2025 | GPU preview generation; custom copy/paste subsets |
| 15.0 | Oct 2025 | Assisted Culling; Auto Stacking; auto Dust Removal; Point Color **Variance**; faster hover previews — plus an AI-mask sync regression and broad perf regression |
| 15.1 | Dec 2025 | Import-review preview quality; PSB export; perf fixes |
| 15.2 | Feb 2026 | **Generative Upscale** (cloud Topaz Gigapixel, credits); Edit in Firefly; WebP read; new Subject/Eye models |
| 15.3 | Apr 2026 | Mask **Feather + Edge** sliders; AI metadata filters; background Denoise/SR |
| 15.4 | Jun 2026 | Neural Engine for Denoise; Faces culling panel; duplicate detection; **release pulled** (Denoise posterization + culling memory leaks) |
| 15.5 | Aug 2026 | Feather/Edge on AI masks; crop-shield opacity; Render to DNG; Denoise fixes |

Process versions — the rendering-engine contract:

| PV | Introduced | What changed |
|---|---|---|
| 1 (2003) | ACR/Lr1–2 | Legacy pipeline |
| 2 (2010) | Lr3 | Recovery/Fill Light/Brightness era; new demosaic/NR |
| 3 ("2012") | Lr4 | The current six-slider tone model; range-targeted sliders; midtone-adaptive Exposure |
| 4 (2017) | LrC 7.x | Compatibility for color/luminance range masks; no tone change |
| 5 (~late 2018) | LrC 8.x | Better negative Dehaze; less magenta cast in high-ISO shadows |
| 6 (Jun 2023) | LrC 12.4 | Reduces banding from Color Mixer/B&W edits — current |

Any new edit **silently auto-upgrades** a PV3–PV5 photo to PV6, with subtle rendering shifts
(banding, dehaze, noise). Users discover it after the fact via the Calibration panel's Process
dropdown and an exclamation badge. PV6 exists *because* 8-band HSL edits banded in earlier PVs — a
warning that per-band color tools need smooth falloff and high-precision intermediates.

**What Lumen takes.** Rendering is versioned from day 1 (`pipelineVersion` in every recipe,
docs/15-catalog.md), and migration is explicit and badged, never silent (docs/14-pipeline.md). The
PV6 banding lesson shapes the Color Mixer's periodic falloff design in docs/05-spec-color.md.

---

## 2. Develop module, panel by panel

### 2.1 Basic panel — Profiles and the Profile Browser

**Finding.** LR's default rendering hides a non-inspectable tone curve and color shift inside the
profile, and refuses to let users scale most profiles.

**Evidence.** Since 7.3 (Apr 2018) the Profile control tops the Basic panel: favorites dropdown +
grid icon opening the Profile Browser (List/Grid/Large views; hover live-previews; Alt-hover shows
Before; star-to-favorite). Groups:

- **Adobe Raw** (raw-only): Color (default; "a bit warmer in the reds, yellows and oranges, a very
  small increase in contrast"), Monochrome, Landscape ("dampens highlights and opens up shadows"),
  Neutral (flat grading base), Portrait (gentler curve, skin-optimized), Vivid, and legacy Standard
  (community verdict: "flat and magenta").
- **Camera Matching** (raw-only): per-brand emulations — Canon Picture Styles, Nikon Picture
  Controls, Sony Creative Styles, Fujifilm Film Simulations, Pentax, Olympus. Every brand's
  "Standard" differs, so cross-brand shoots don't match.
- **Creative** (Artistic/B&W/Modern/Vintage; also apply to JPEG/TIFF). Widely reported to be
  LUT-based "enhanced profiles" vs. DCP camera profiles (unverified).
- **Adaptive** (LrC 14.2, Feb 2025): Adaptive Color / Adaptive B&W — an ML profile that corrects
  per-image "as if the AI had changed Exposure, Shadows, Highlights, Color Mixer, Curves… although
  the actual controls stay in their neutral position." Tuned especially for HDR raws.

**Amount slider: 0–200, default 100 — active only for Creative and Adaptive profiles, grayed out
for Adobe Raw and Camera Matching**, a documented and long-ignored user complaint. The criticism
thread that matters: Adobe Color's baked warm shift + contrast bump is invisible and uneditable
("Goodbye Adobe Color!" — f64 Academy), and Adobe's own docs admit the nonlinear curve means
"accuracy is not the be-all and end-all."

**What Lumen takes.** No hidden profile layer. Lumen's base rendering is a neutral scene-referred
develop plus exactly one visible display transform (docs/04-spec-tone.md); creative character lives
in the transparent Film Lab and Primaries panels (docs/05-spec-color.md), every look scalable, every
curve inspectable. The Adaptive Profile idea — per-image ML correction with sliders left at zero —
is rejected on principle: Lumen's Auto (docs/04-spec-tone.md) writes **visible slider values** the
user can tune, never an invisible correction layer.

### 2.2 Basic panel — White Balance

**Finding.** Raw WB is real Kelvin with a beloved eyedropper loupe; the Tint ceiling and the JPEG
degradation are the known warts.

**Evidence.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Temp (raw) | 2000–50000 K | As Shot | Blue→yellow gradient track; higher K = warmer render |
| Tint (raw) | −150…+150 | As Shot | Green→magenta; +150 cap fails underwater shooters (open Adobe thread) |
| Temp/Tint (JPEG/HEIC) | −100…+100 relative | 0 | WB is baked in; recurring "is this broken?" confusion |
| Presets (raw) | 9 | As Shot | As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom; JPEG gets only As Shot/Auto/Custom |

Eyedropper (**W**): click a *light neutral gray* (not white — near-clipped whites mislead the
solve); LR solves Temp+Tint so that patch reads R=G=B. Toolbar options: Auto Dismiss, Show Loupe,
and a Scale slider growing the sampling loupe from 5×5 to 17×17 px, with RGB percentage readouts
under the grid. Auto WB is a separate shortcut: Ctrl/Cmd+Shift+U.

**What Lumen takes.** The whole surface, verbatim mechanics, two upgrades: Tint range extended
beyond ±150 (a free win the underwater threads have begged for), and CAT16 chromatic adaptation
under the hood. Owned by docs/04-spec-tone.md.

### 2.3 Basic panel — the six tone sliders

**Finding.** The PV2012 six-slider contract is the industry's shared muscle memory; its slider
*semantics* are subtle and load-bearing.

**Evidence.** All default 0; panel order Exposure, Contrast, Highlights, Shadows, Whites, Blacks.

| Slider | Range | Semantics |
|---|---|---|
| Exposure | −5…+5 EV | Maps to camera stops (+1.0 ≈ +1 EV) but **midtone-weighted with automatic highlight compression** — never naive gain at the extremes; this is why it feels "safe" |
| Contrast | −100…+100 | Fixed S-curve pivoting near midtone (community measurement: ≈ Lab L 50) |
| Highlights | −100…+100 | Targets light-but-not-white tones; **never moves the white point** — even at +100 it works inside the boundary Whites sets |
| Shadows | −100…+100 | Dark-but-not-black tones; Blacks holds the floor |
| Whites | −100…+100 | Sets the **white point**; widest reach into brights |
| Blacks | −100…+100 | Sets the **black point** |

Educator-consensus order: Exposure, then Whites/Blacks endpoints, then Highlights/Shadows — the
sliders are interdependent by design.

Hidden interactions (all verified, all beloved):

- **Alt/Option-drag** Exposure/Highlights/Shadows/Whites/Blacks → threshold clipping view. Whites/
  Highlights/Exposure clip on black; Blacks/Shadows on white. Channel colors: r/g/b = single
  channel; cyan = G+B, magenta = R+B, yellow = R+G; solid white/black = all three.
- **Shift-double-click a slider label** → per-slider Auto. Nuance: Exposure/Contrast/Highlights/
  Shadows/Vibrance/Saturation use the Sensei value, but **Whites and Blacks compute a
  histogram-endpoint auto-stretch** — the automated version of drag-until-first-clip.
- **Double-click label or knob** → reset. **Alt held** → section headers become "Reset Tone" /
  "Reset Presence" click targets.
- Hover + Up/Down arrows nudge; Shift = larger steps, Alt = finer; click the number to type;
  scrubby-drag over the number works.

**What Lumen takes.** The contract verbatim — names, order, ±100 and ±5 EV ranges, midtone-weighted
Exposure, Highlights-bounded-by-Whites — implemented halo-free on a guided-filter EV-zone engine,
plus the advanced Zones disclosure. All owned by docs/04-spec-tone.md. Every hidden interaction
above ships as a *documented, discoverable* feature under the Lumen slider contract in
docs/12-spec-ux.md; Adobe never surfaced them, which is why each one needs a tutorial industry.

### 2.4 Basic panel — Presence, Vibrance, Saturation

**Finding.** Three local-contrast sliders on three frequency scales, each with a documented failure
mode; two saturation sliders with different protection philosophies.

**Evidence.**

| Slider | Range | Introduced | Behavior and failure mode |
|---|---|---|---|
| Texture | −100…+100 | 8.3, May 2019 | Mid-to-high-frequency detail contrast; born as engineer Max Wendt's skin-smoothing project; negative = skin smoothing without negative-Clarity "glow"; barely touches color |
| Clarity | −100…+100 | — | Midtone-weighted local contrast, wider radius; pushes saturation/luminance; **the classic halo generator** at sky/land edges; "obvious from a mile off" when overdone |
| Dehaze | −100…+100 | 2015; into Basic 7.3 | Strongest in shadows/lower histogram; positive values boost saturation and cast **magenta neutrals, blue/green shadows** (open Adobe bug thread); negative = photographic fog; PV5 reduced negative-dehaze noise |
| Vibrance | −100…+100 | — | Non-linear: boosts low-sat colors more, avoids channel clipping (S-curve saturation mapping), protects skin-tone hues |
| Saturation | −100…+100 | — | Linear and global: −100 = grayscale, +100 = double; drives channels into clip |

**What Lumen takes.** Same three names and ranges, better engines: Clarity via local Laplacian
(halo-free by construction), Texture as a wavelet band, Dehaze with a color-stable mode — all three
sharing one base-detail decomposition (docs/06-spec-detail.md). Vibrance/Saturation move to
H-K-aware perceptual math with explicit skin protection (docs/05-spec-color.md).

### 2.5 Basic panel — Auto (Sensei)

**Finding.** ML Auto sets eight sliders and has two famous blind spots users have reported for
years.

**Evidence.** Auto (Ctrl/Cmd+U; ML-based since 7.1, Dec 2017, "trained on thousands of
professionally edited images") sets exactly: Exposure, Contrast, Highlights, Shadows, Whites,
Blacks, Vibrance, Saturation. It does not touch WB, Presence, curves, or profile. Verified
complaints: (1) **it analyzes the pre-crop image** — a white scan border yields severe
underexposure; "make auto tone respect the crop" has been an open request for years; (2) it
habitually **over-lifts Shadows** ("I usually lower Shadows to about half of what auto applies");
(3) the Ctrl+U shortcut itself shipped broken in 13.3.

**What Lumen takes.** Auto is crop-aware, face-weighted, writes visible slider values, offers
per-slider auto affordances and a personality preference ("lift shadows less"). Owned by
docs/04-spec-tone.md.

### 2.6 Histogram

**Finding.** LR's histogram is a control, not a chart — and it reads out in a color space nobody
asked for.

**Evidence.** Five draggable zones — Blacks | Shadows | Exposure | Highlights | Whites — hovering
names the mapped slider, dragging moves it live. Corner clipping triangles: hover = temporary
overlay, click = locked overlay (blue = shadow clip, red = highlight clip in-image), **J** toggles
both; the triangle icon itself is channel-diagnostic (white = all three channels, r/g/b/c/m/y =
those channels). Readouts compute in **"Melissa RGB"** (ProPhoto primaries + sRGB tone curve),
displayed as 0–100 percentages; "RGB values 0–255 please" is a 15-year-old request. Capture info
(ISO/focal/aperture/shutter) displays under the graph (standard behavior; presence of the EXIF line
not re-verified). In HDR mode the histogram splits SDR | HDR with dashed f-stop gridlines above SDR
white (§2.19).

**What Lumen takes.** The draggable five-zone histogram, channel-diagnostic triangles, and J
overlay, plus a selectable readout space (working / sRGB 0–255 / output) and a true raw histogram
at cull time. Owned by docs/04-spec-tone.md (develop) and docs/10-spec-library.md (cull).

### 2.7 Tone Curve

**Finding.** One panel, five curves, and the 2023 Refine Saturation slider that quietly fixed a
20-year-old RGB-curve defect — but shipped defaulted to the legacy behavior.

**Evidence.** Since the 9.3/10.0 redesign (2020): icon toggles for **Parametric, Point (RGB
composite), Red, Green, Blue**. Parametric = four region sliders (Highlights/Lights/Darks/Shadows,
±100 widely documented, bound not re-verified from Adobe) + **three region-split triangles
defaulting to 25/50/75%** that re-scope the regions; parametric moves are inherently smooth — no
posterized or inverted curves possible. Point curve: click-to-add; right-click → Delete Control
Point / Flatten Curve; absolute 0–255 or % coordinates; typed input/output; arrow-key nudge.
Legacy Linear/Medium/Strong Contrast preset dropdown survival in the current UI (unverified).

**Refine Saturation** (12.4, Jun 2023): 0–100 on the Point Curve, **default 100 = legacy chroma
amplification**; at 0 the curve remaps brightness on the luma channel only — no saturation pumping.
Point curves (with Refine Saturation) work inside masks in ACR but **not** in LrC (§3.3).

**TAT** (Ctrl+Alt+Shift+T / Cmd+Opt+Shift+T): drag up/down on the image to move the curve region or
point under the cursor; Alt-drag lowers sensitivity; hover + arrows nudges. The panel has an on/off
eye (Alt-click latches off) — Basic and Lens Blur are the only panels without one; Adobe's forum
rationale: a raw file always needs profile + tone mapping.

**What Lumen takes.** Parametric + point + per-channel + a Luma curve, default
luminance-preserving (Refine Saturation 0 semantics — Adobe's default-100 is
backwards-compatibility baggage Lumen doesn't carry), TAT everywhere, movable splits. Owned by
docs/04-spec-tone.md. Local curves in masks from day 1 — see §3.3 and docs/08-spec-masking.md.

### 2.8 Color Mixer (Mixer tab)

**Finding.** Eight fixed hue bands, TAT to hide them, and a banding history that forced a new
process version.

**Evidence.** Panel renamed Color Mixer; tabs Mixer | Point Color (becomes B&W under monochrome
treatment). Mixer: view selector Hue/Saturation/Luminance/All; 8 channels (Red, Orange, Yellow,
Green, Aqua, Blue, Purple, Magenta), every slider −100…+100, default 0. Channels are overlapping
hue wedges; real colors span bands, so edits routinely need two adjacent sliders. TAT drags move
*all* sliders containing the clicked pixel's hue proportionally — users consider this the "right"
interaction. PV6 exists specifically because Mixer/B&W edits banded in earlier PVs. Documented
limitation: 8 fixed channels can't isolate two different blues — the gap Point Color fills.

**What Lumen takes.** 8 bands with smooth periodic falloff (no seams, no PV6-class banding),
DxO-style hue-ring presentation with core+feather handles, chroma-preserving Luminance moves, and a
Uniformity slider LR lacks. Owned by docs/05-spec-color.md.

### 2.9 Point Color (+ Variance)

**Finding.** LR's most-loved color feature since Color Grading — sample-based color editing whose
Variance slider (15.0) does what no other slider does.

**Evidence.** Added 13.0 (Oct 2023). Eyedropper samples a color (loupe-assisted) → swatch (up to
**8 per photo and per mask**), rendered split original/adjusted, black pin at sample point.
Controls per swatch: a 2-D hue×saturation field with a draggable pin + a luminance ramp; Hue/
Saturation/Luminance Shift sliders (relative to sample; numeric ranges unverified); **Range**
(master falloff in hue/sat/lum distance); expandable refine section with independent Hue/Sat/Lum
Range falloffs; **Visualize Range** (outside-range renders grayscale); Alt-drag on sliders shows
affected pixels live. **Variance** (15.0): compresses (left) or expands (right) color variation
around the sample *while preserving texture* — evens polarizer-blotched skies, unifies skin inside
a person mask, boosts foliage variety. Reviewed as "Lightroom's best new slider" (Fstoppers,
Matiash). Known confusion: the Range slider's semantics baffled users at launch — falloff must be
visualizable, not described.

**What Lumen takes.** Point-Color-class swatches with Variance and always-available falloff
visualization, global and per-mask, from day 1. Owned by docs/05-spec-color.md.

### 2.10 Color Grading

**Finding.** A competent 3-way wheel set whose zone boundaries are invisible and unadjustable
except through two blunt sliders.

**Evidence.** v10.0 (Oct 2020), replaced Split Toning. Five views: 3-Way, Shadows, Midtones,
Highlights, Global. Per wheel: rim drag = Hue 0–360°, center-out = Saturation 0–100, disclosure
reveals numeric sliders, plus **Luminance −100…+100**. Panel-level **Blending** (0–100, default 50:
zone overlap) and **Balance** (−100…+100, default 0: shifts what counts as shadow vs highlight).
Modifiers: Cmd = hue-only, Shift = sat-only, Alt = fine. Colorist criticism: not a true video
3-way — no per-zone exposure in linear, and the zone pivots themselves are invisible.

**What Lumen takes.** The wheels, Luminance, Blending/Balance, and modifiers — plus **visible,
draggable zone pivots** (the #1 advanced-user complaint) and a perceptual-math advanced disclosure.
Owned by docs/05-spec-color.md.

### 2.11 Calibration

**Finding.** The "legacy" panel that secretly powers a whole grading economy.

**Evidence.** Bottom of the stack. Process dropdown (V1–V6, §1). **Shadows Tint** (green↔magenta;
exact bound unverified) fixes shadow-only casts WB can't. **Red/Green/Blue Primary**, each with Hue
and Saturation −100…+100: redefines what the camera-profile primaries *mean* before HSL is applied.
Crucially different from HSL — Blue Primary affects every pixel containing blue in its mix, so
shifts are global, smooth, and can't posterize. The "calibration look" idiom (orange-teal via Blue
Primary Hue −100 + Red Primary Hue ≈ +50; Blue Primary Saturation + as the "richer without
oversaturation" move) is massively popular on YouTube/Instagram; Fstoppers: "the impressively
powerful tool that could change your editing forever."

**What Lumen takes.** This panel, made honest: a Primaries panel (R/G/B primary hue/purity +
shadows tint) with a friendlier name and explanation than "Calibration." Owned by
docs/05-spec-color.md. (v1 of this plan marked Calibration "never — legacy"; the research
overturns that verdict. See §6.)

### 2.12 B&W Mix

**Finding.** Solid tool, one long-standing state-loss bug.

**Evidence.** Treatment: Black & White (**V**). Eight channel sliders −100…+100 (negative darkens
that color's gray rendering; classic moves: Blue − for dark skies, Orange ± for skin brightness).
**Auto** computes a mix maximizing gray-tone distribution; a preference auto-applies it on
conversion (users often disable). TAT works. Bug lore: B&W and HSL mixes historically lost state
when toggling Treatment back and forth — a long-standing community report.

**What Lumen takes.** 8-band mix, auto as suggestion never silent default, per-channel state
preserved across treatment toggles, optional zone overlay. Owned by docs/05-spec-color.md.

### 2.13 Detail — Sharpening

**Finding.** The four-slider + alt-view design is still the reference capture-sharpening UI.

**Evidence.**

| Slider | Range | Raw default | Alt-drag view |
|---|---|---|---|
| Amount | 0–150 | 40 (raised from 25 ~2018; JPEG 0) | Grayscale preview |
| Radius | 0.5–3.0 | 1.0 | Edge-emphasis overlay |
| Detail | 0–100 | 25 (low = halo-suppressed/USM-like; high = deconvolution amplifying finest texture) | High-frequency structure |
| Masking | 0–100 | 0 | **White = sharpened, black = protected** — the single most-taught trick in LR sharpening |

**What Lumen takes.** The 4-slider contract and alt-views verbatim as the manual surface, inside
the Fraser three-pass doctrine (capture/creative/output) with auto-radius deconvolution capture
sharpening. Owned by docs/06-spec-detail.md.

### 2.14 Detail — Manual Noise Reduction

**Evidence.** Luminance 0–100 (default 0) + Detail (50) + Contrast (0); Color (raw default 25,
JPEG 0) + Detail (50) + Smoothness (50). Still load-bearing post-AI: it is the only NR for
JPEG/TIFF, the only *local* NR (masks get a single Noise slider), and stackable on AI Denoise
output.

**What Lumen takes.** One unified Noise section: profiled classical NR always live (chroma
aggressive, luma gentle), AI beneath, ISO-adaptive defaults, local NR in masks. Owned by
docs/07-spec-denoise.md.

### 2.15 Detail — AI Denoise

**Finding.** Excellent quality, a two-year design detour, and a trust-burning regression.

**Evidence.** Introduced 12.3 (Apr 2023) writing `-Enhanced.dng` side-cars; **14.4 (Jun 2025)
finally made it non-destructive** — Detail-panel toggle + Amount 0–100 (default 50); one
computation, then Amount changes are instant, result stored in `.lrcat-data`. Raw-only (Bayer,
X-Trans, linear DNG/ProRAW; since 14.0 HDR/pano merge DNGs); not JPEG/TIFF; not local. Enabling
Denoise auto-applies Raw Details. Performance scales with GPU cores; **15.4 enabled the Apple
Neural Engine** (M4 Mini 32MP: 40 s → 13 s; M1 Air: 85 s → 25 s; M4 Max: ~5 s). Quality reputation
2025–26: gap to DxO/Topaz closed to pixel-peeping level; DxO still edges extreme-ISO fine texture.
Then 15.4 shipped posterization/color-edge artifacts and **Adobe pulled the release**; fixed in
15.5.

**What Lumen takes.** Skip straight to LR's final design — cached non-destructive toggle + instant
Amount — with what LR still lacks: full-image preview, ≤10 s at 45MP budget, background queue,
viewing-priority scheduling. Owned by docs/07-spec-denoise.md.

### 2.16 Enhance family: Raw Details, Super Resolution, Generative Upscale

**Evidence.** **Raw Details** (2019): AI demosaic, same pixel count, raw-only, non-destructive
toggle since 14.4. **Super Resolution** (10.3, Jun 2021): 2× linear / 4× pixels; limits 65,000 px
long edge / 500MP; can't stack twice. **Generative Upscale** (15.2, Feb 2026): licensed **Topaz
Gigapixel models in Adobe's cloud**, 2×/4×, **consumes generative credits**, critiqued for
over-smoothing some areas and over-sharpening others vs. Super Resolution's natural texture — the
first third-party model embedded in LR.

**What Lumen takes.** Better demosaic is not a separate "enhance" toggle — it is the default
pipeline (RCD/LMMSE/Markesteijn via the RawSource escape hatch, docs/14-pipeline.md). Local 2×
upscale is deferred infrastructure-reuse once denoise ships; cloud upscale is never (§6).

### 2.17 Lens Blur

**Finding.** LR's weakest flagship AI feature — proof of demand and proof of how shipping slow
damages a product's reputation.

**Evidence.** 13.0 Early Access → GA 13.3 (May 2024). Apply checkbox triggers AI depth estimation
(or device depth); auto-focuses the subject. Blur Amount 0–100 (default 50); 6 bokeh styles
(Circle, Bubble, 5-blade, Ring, Oval, Cat-eye) + Boost; Focus Range depth strip with draggable
in-focus band; Visualize Depth false-color overlay; Refine brush paints Focus/Blur into the depth
map. Reputation: "very, very slow and laggy" even on strong hardware; session-wide GPU degradation
("Lightroom slow ever since I used Lens Blur" threads); halo edges from imperfect depth maps
needing tedious brushing; bokeh styles indistinguishable at typical sizes. No panel on/off eye.

**What Lumen takes.** Deferred. Lumen builds the substrate anyway — monocular depth for every photo
as a mask type (docs/08-spec-masking.md) — and ships synthetic blur only if depth + edge matting
beat LR's halos and the computation never touches the UI thread. One great circular bokeh with
cat-eye falloff beats six mediocre shapes.

### 2.18 Optics, Transform, Effects, Crop, Remove, Red Eye

**Optics — Profile tab.** Remove Chromatic Aberration checkbox (auto lateral-CA, cheap, safe).
Enable Profile Corrections: Distortion + Vignetting from Adobe's profile DB (Make → Model →
Profile; missing profiles user-assignable; defaults remembered), per-profile override sliders
**0–200, default 100**. Mirrorless/fixed-lens files show "Built-in Lens Profile applied" —
mandatory, can't be toggled.

**Optics — Manual tab.** Distortion; **Defringe**: Purple Amount 0–20 + Purple Hue dual-thumb range
(default 30/70), Green Amount 0–20 + Green Hue (default 40/60 — deliberately narrower to protect
foliage), eyedropper with loupe auto-sets amounts + ranges, **Alt-drag any Defringe slider = B&W
visualization of affected pixels** — a beloved micro-interaction; Vignetting Amount/Midpoint.

**Transform/Upright.** Buttons Off / Auto / Guided (Shift+T; draw up to 4 guides with a magnified
loupe, live once ≥2 exist) / Level / Vertical / Full. Manual sliders: Vertical, Horizontal, Rotate
−10…+10, Aspect, Scale, X/Y Offset (numeric bounds unverified; Scale commonly cited 50–150);
Constrain Crop checkbox. Content-analysis-based; best practice = lens profile first, then Upright.
Sentiment: Guided Upright is "basically solved."

**Effects.** Post-Crop Vignetting: Style = Highlight Priority (default) / Color Priority / Paint
Overlay (legacy, muddy, unused); Amount −100…+100, Midpoint 0–100 (default 50), Roundness
−100…+100, Feather 0–100, Highlights 0–100 (active only for negative amounts in the two priority
modes). Grain: Amount 0–100 (default 0), Size (default 25), Roughness (default 50) — monochrome
luminance grain, late in the pipe; the standing ask is per-channel/film-stock realism.

**Crop (R).** Aspect dropdown (Original, 1×1, 4×5/8×10, 8.5×11, 5×7, 2×3/4×6, 16×9, 16×10, Enter
Custom — stored), lock icon, **X** flips orientation. Angle slider + Auto straighten + ruler drag
(Cmd-drag anywhere in crop mode); angle limit ±45° (unverified). **O** cycles overlays (Grid,
Thirds, Diagonal, Triangle, Golden Ratio, Golden Spiral), **Shift+O** cycles 8 orientations,
cycle list user-trimmable. 15.5 added crop-shield opacity. Key interaction: LR crops by moving the
image under a fixed frame, with the full develop pipeline live inside the crop UI.

**Remove (Q).** Three modes: Remove (Content-Aware, 12.0+), Heal, Clone; Size/Feather/Opacity;
strokes are editable pins (source draggable, mode switchable, `/` re-rolls the source). **Use
Generative AI** = Firefly **cloud** inpainting (GA 14.0): 3 variations + Generate for 3 more;
Detect Objects snaps a rough scribble to a full object; 15.x auto-includes shadows. Offline =
"Generative Remove failed"; credit enforcement began 2025 (post-Jun-2025 base plan: **25
credits/mo**); meme-level failures (objects replaced with random animals) are widely shared.
**Visualize Spots** threshold view exposes sensor dust. **Distraction Removal → Dust** (15.0): one
checkbox scans and removes all dust spots via Content-Aware, each spot reviewable/deletable/
refreshable, fully local — instantly loved (Ask Tim Grey, Aug 2026).

**Red Eye.** Red Eye + Pet Eye variants; per-correction Pupil Size and Darken; Pet Eye adds
catchlight. Table stakes, rarely discussed.

**What Lumen takes.** Optics: Apple RAW built-in corrections by default, Remove CA checkbox, and a
clone of the Defringe dual-thumb + eyedropper + alt-view interaction; Guided Upright with 4 guides
(docs/09-spec-geometry.md). Crop grammar wholesale (docs/09-spec-geometry.md). Effects minus Paint
Overlay (docs/06-spec-detail.md; film-grade grain lives in the Film Lab, docs/05-spec-color.md).
Heal/clone with editable pins + local content-aware fill + one-click Dust Removal, all local
(docs/09-spec-geometry.md). Generative cloud anything: never. Red eye: never — the heal tool
covers the rare case.

### 2.19 HDR editing mode

**Finding.** The editing side is praised; the delivery side burned users — the lesson is that the
SDR rendition must be deliberate.

**Evidence.** Since 13.0 (Oct 2023): an HDR button in Basic switches the pipeline to extended
range. Histogram splits SDR | HDR with a vertical bar at SDR white and dashed gridlines per stop
above (typically up to +4); **Visualize HDR Ranges** color-codes over-white stops cyan→magenta; the
highlight triangle goes **yellow** (HDR-displayable) vs **red** (beyond the display); **HDR Limit**
caps headroom. Requires an EDR/HDR display (Apple XDR ideal). Export: HDR JPEG (gain map), AVIF,
JPEG XL, TIFF; a "Preview for SDR display" section hand-tunes the SDR rendition inside the gain map
(Greg Benz: "great HDR requires a great SDR in the gain map"). Sentiment: exports "look flat/washed
out" in non-HDR apps; browser support fragmented; Instagram "extremely flaky." 15.5's Render to DNG
bakes HDR edits into a portable DNG.

**What Lumen takes.** HDR is a headline macOS-native feature done Lumen's way: EDR viewport,
gain-map authoring, SDR-proof toggle, delivery preview (docs/11-spec-output.md). The SDR|HDR split
histogram and stop gridlines are adopted in docs/04-spec-tone.md.

### 2.20 Snapshots, History, Copy/Paste, Sync, Presets

**Evidence.** **History**: every edit, chronological, unlimited, per-catalog, click to time-travel,
hover = live preview (fast since 15.0); no branching — editing from an old state truncates forward.
**Snapshots**: named states, alphabetical, right-click to update. **Copy/Paste**
(Cmd+Shift+C/V): full checkbox tree of every panel/group incl. masks; 14.5 added saved custom
subsets; **Previous** pastes everything from the last photo. **Sync**: same dialog from the
most-selected photo; Option-click = silent sync with last subset; **Cmd-click toggles Auto Sync** —
live-applies every move to the whole selection, the backbone of event batch editing and a notorious
foot-gun when left on (users beg for a visible state indicator).

**Presets**: hover live preview; folders; per-camera/per-ISO raw defaults; **Amount 0–200**
(opt-in per preset at save; graying rules confuse users). **Adaptive presets** embed AI mask
recipes — the mask recomputes on the target photo at apply (Adobe ships premium Adaptive
Portrait/Sky/Subject packs). **ISO-adaptive presets** (9.3+): save from ≥2 photos at different
ISOs; settings linearly interpolate between anchor ISOs and clamp beyond; commonly installed as
the raw default — a feature power users adore and beginners never find.

**What Lumen takes.** History + timestamped snapshots with fast hover preview; copy/paste subsets +
Previous; Auto Sync with an unmissable state indicator (docs/10-spec-library.md,
docs/12-spec-ux.md). Presets with Amount; adaptive presets whose masks recompute in a background
queue (docs/08-spec-masking.md); ISO-adaptive defaults promoted to a first-class onboarding step
(docs/07-spec-denoise.md). The Reference View (Shift+R: locked reference beside active photo, then
Sync) is adopted for series matching in docs/12-spec-ux.md.

---

## 3. Masking system teardown

### 3.1 The model

**Finding.** Masks are stacks of combinable components — the right model, with one operation hidden
behind a modifier key.

**Evidence.** Entry: toolstrip icon or **Shift+W**. A photo has N masks; each mask contains N
components of any type, freely mixed (e.g., Select Sky minus Luminance Range minus Brush). **Add** =
union, **Subtract** = boolean subtract; **Intersect** hides in the ⋯ menu ("Intersect Mask
with...") or behind held Alt/Option converting the Add/Subtract buttons — it arrived in 2022 and
every tutorial still has to explain where it lives (community-documented equivalence: Intersect =
Subtract + Invert). Per-mask: eye toggle, overlay color swatch, Rename/Duplicate/Delete/Invert/
Duplicate-and-Invert, Convert to Brush for some component types (per-type availability unverified).
`'` inverts the selected component. Live grayscale thumbnails per component. Multiple masks
accumulate — users stack full-image masks to exceed +100 slider limits.

### 3.2 The component roster

| Type | Mechanics | Notes |
|---|---|---|
| Select Subject | One click, Sensei segmentation | 15.4 model is a major accuracy jump (old model bled into sky); GPU-driver failures = "Something went wrong" |
| Select Sky | One click | |
| Select Background | One click, own model | |
| Select Objects | **Brush Select** (scribble, AI snaps to boundary) or **Rectangle Select** (box) | |
| Select People | Per-person chips + **10 sub-region checkboxes**: Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Clothes, Entire Person | Combined mask or separate masks per feature; loved by portrait/event shooters; small/turned faces yield box-shaped or missing masks; no manual "this is a person" hint |
| Select Landscape (14.3) | 8 classes: Sky, Mountains, Architecture, Vegetation, Water, Snow, Natural Ground, Artificial Ground | Fast on clear scenes; fuzzy on intermingled vegetation/reflections |
| Brush (K) | Size (`[`/`]`), Feather (Shift+`[`/`]`), Flow (1–9/0), Density (opacity ceiling); **Auto Mask** (A) edge-aware; Alt = eraser with own settings | The standard AI-mask cleanup tool |
| Linear Gradient (M) | Drag ramp; Shift constrains; span is the feather | Aug 2026 ecosystem added a bidirectional gradient; LrC availability unverified |
| Radial Gradient (Shift+M) | Ellipse; Feather 0–100 (default 50); Invert | |
| Color Range | Eyedropper/drag-sample; Shift+click adds up to 5 samples; Refine slider; **Alt-drag Refine = matte preview** | Usually intersected with a spatial mask |
| Luminance Range | Min/max band with falloff ramps; Smoothness (default 50); **Show Luminance Map** | The go-to for sky recovery and tonal dodge/burn |
| Depth Range | Only when the file embeds a depth map (iPhone Portrait HEIC) | Grayed out for everything else — effectively an iPhone-only gimmick; whether Lens Blur's ML depth can feed it is unverified |

Refinement (2026): **Feather 0–100** softens the boundary; **Edge −50…+50** shifts it in/out —
announced 15.3, headlined for AI masks in 15.5. It took Adobe until mid-2026 to ship grow/shrink.

Overlays: 6 modes (Color Overlay; Color Overlay on B&W; Image on B&W; Image on Black; Image on
White; White on Black). `O` toggles, `Shift+O` cycles color (red/green/white/black), `Alt+O` cycles
mode; overlay auto-shows on hover/create and hides while dragging sliders.

### 3.3 Per-mask adjustments — and what is still missing

**Evidence.** Every mask has **Amount** — a multiplier over all of that mask's sliders, default
100, range 0–200 (bounds per multiple tutorials; not confirmed from Adobe's page), scrubbable by
Alt-dragging the mask's pin. The long-standing request Adobe refuses: **per-component amount within
a mask**.

Local slider roster (15.x): Exposure, Contrast, Highlights, Shadows, Whites, Blacks; Temp, Tint,
Hue (with Use Fine Adjustment), Saturation, full **Point Color** (since 13.0, Variance since 15.0),
Color tint swatch; Texture, Clarity, Dehaze, Grain (since 12.4/PV6); Sharpness, Noise (single
slider), Moiré, Defringe. **Not available locally in LrC 15.5: Tone Curve and Color Grading
wheels** — masked point curves shipped in Camera Raw but not LrC (users round-trip LrC→ACR to get
them; the gap has its own tracking thread, and Capture One is the competitor cited as having local
curves). Also absent locally: HSL mixer (Point Color covers most of it), Vibrance (unverified
whether any build includes it locally).

### 3.4 Lifecycle, invalidation, performance pathology

**Finding.** LR computes masks synchronously with the UI and stores rasters in a fragile side-car —
the two failure modes Lumen engineers against.

**Evidence.** AI masks are computed rasters in `.lrcat-data`, tied to source pixel state. Changing
those pixels (pre-14.4 Enhance/Denoise, some syncs) flags "Update AI Settings"; 15.3 added library
filters (Needs AI Update / Has AI / Has Generative AI). **LrC 15.0 regressed
auto-recompute-on-sync into a manual per-photo click**, breaking batch workflows — the top
complaint of the cycle; high-volume shooters rolled back to 14.5.2. Recurring bug class: masks
demand re-updating in loops or render as blank/black; the community fix is *delete
`<catalog>.lrcat-data` and let it regenerate* — folklore, not product UX. Performance: brush lag
once several masks exist; 0.5–10 s freezes switching photos in Develop with AI masks; multi-second
tool-open delays in 15.0. Adobe's countermeasures (GPU preview generation 14.5, background Denoise
15.3, brush responsiveness 15.4) confirm the root pattern: mask re-evaluation synchronous with the
UI.

**What Lumen takes (whole section).** LR's mask semantics with Intersect as a first-class visible
button; the full component roster including people-parts and landscape classes plus what LR lacks —
similarity point/line, depth range for *every* photo via monocular depth, per-component amount, and
**local tone curve + local color-grading wheels** (the single clearest color-depth win, still
absent from LrC in 2026); Feather + Edge from day 1; masks stored parametrically with versioned,
self-healing raster caches; recompute always async, auto on batch sync/preset-apply; honest error
surfaces naming the cause. All owned by docs/08-spec-masking.md.

---

## 4. Library and workflow teardown

### 4.1 Import model

**Evidence.** Modes: Copy as DNG / Copy / Move / Add (cards offer only the copies; Add disables
renaming and second copy). File Handling: Build Previews = Minimal | **Embedded & Sidecar** (the
community's #1 import-speed trick — "slash import time by 90%") | Standard | 1:1; Build Smart
Previews (lossy 2560px DNG proxies); Don't Import Suspected Duplicates; **Make a Second Copy To**;
Add to Collection. File Renaming templates (Filename/Sequence/Import #/Date/Custom Text/Shoot
Name). Apply During Import: develop preset (incl. adaptive), metadata preset, keywords.
Destination: date-folder schemes with preview tree. The whole dialog state saves as an Import
Preset. 15.0 added Assisted Culling at import. Four preview types × smart previews × quality
levels × discard windows is LR's most confusing subsystem.

**What Lumen takes.** No import ceremony at all — folders are the library, browsing never waits on
ingest (docs/10-spec-library.md). The optional verified-ingest screen keeps the good parts (rename
templates, second-copy backup, apply-preset, duplicate skip) and adds what LR lacks: checksummed
verified copy and cull-while-copying. One automatic preview pipeline replaces the four-type maze.

### 4.2 Culling grammar

**Evidence.** Views: Grid (G), Loupe (E), Compare (C: Select vs Candidate, synced zoom, swap/
promote), Survey (N: tiled, X drops a tile), People (O). Keys: **P** pick, **X** reject, **U**
unflag; **1–5** stars, 0 clears; **6–9** color labels; **Caps Lock = auto-advance** after any
flag/rating/label key — universally taught, "saves ~50 min per 2,000 photos"; Shift+key also
advances. **Painter tool** (spray can): payload = keywords/label/flag/rating/metadata/develop
preset/rotation/target collection; click-drag sprays across thumbnails, hover flips to eraser.
Lights Out (**L** cycles on/dim/off). Second window (Cmd+F11; Shift+G/E/C/N) — with a known
keyboard-focus-stealing annoyance. Sort orders per folder: Capture Time (default), Added Order,
Edit Time/Count, Rating, Pick, Label, File Name/Extension/Type, Aspect Ratio, User Order.

**AI Assisted Culling (15.0+)**: scores focus/eyes-open/exposure into a per-photo Culling Score
with adjustable strictness; hover shows per-criterion pass/fail. **15.4 Faces panel**: per-face Eye
Focus and Eyes Open scores. **Auto duplicate detection (15.4)**: exact matches auto-stack. **Auto
Stacking (15.0)**: by capture-time gap or visual similarity. Reviewer consensus: "revolutionary
tech, v1 models unreliable — don't trust it yet"; the per-face score surfacing is the direction
people like ("show me why, let me decide").

**What Lumen takes.** Keystroke-for-keystroke compatibility (P/X/U, 1–5, 6–9, G/E/C/N, auto-advance
default-on and visible), survey/compare with synced zoom, painter-style bulk tagging, second
pinnable window with sane focus — on an embedded-JPEG-first browse path that never decodes RAW
(docs/10-spec-library.md). AI culling as evidence-not-verdicts: per-face crops with eyes-open and
focus badges, burst grouping, adjustable strictness, flags only, never auto-reject.

### 4.3 Find and organize

**Evidence.** **Filter bar** (`\` in Grid): Text (all indexed metadata, field + rule dropdowns);
Attribute (flag, rating with ≥/=/≤, labels, kind, edit status, export status, stack state 15.0+);
Metadata (up to 8 configurable columns; within a column = OR, across columns = AND — **no OR across
different criteria**; the third-party "Any Filter" plugin exists precisely to fix this); saved
filter presets; 15.3/15.4 AI filters (Has AI / Has Generative AI / Needs AI Update). **Smart
Collections**: rule engine over ~all catalog metadata, Match all/any, **Alt-click "+" for nested
conditional groups**, shareable presets. Collections/Sets, Quick Collection (**B**), Target
Collection. Keywording: hierarchy, synonyms, suggestions, sets; **15.4 finally made keyword sync
bidirectional** (a decade-old complaint). Publish Services: Hard Drive + plugin providers, 4-state
queue (New → Published → Modified → Deleted); powerful, dated, plugin-patched. Folders panel
mirrors disk with real filesystem moves. Virtual Copies (Cmd+') = parametric duplicates, stack with
master. **Quick Develop**: *relative* adjustments (single arrow ≈ ⅓ stop, double ≈ 1 stop) across a
multi-selection — unlike Sync's absolute values.

**What Lumen takes.** Filter bar with native **OR across criteria**; smart albums as saved queries;
stacks; virtual copies as recipe rows; relative batch adjustments kept as a concept
(docs/10-spec-library.md). Publish Services' plugin platform: never — export presets + a
watched-folder re-export flag keep the useful 4-state idea (docs/11-spec-output.md).

### 4.4 Catalog machinery

**Evidence.** Catalog = SQLite `.lrcat` + `Previews.lrdata` + `Smart Previews.lrdata` +
**`.lrcat-data`** (AI masks, denoise results — the known corruption point behind black masks).
Backup scheduler (never → every exit) with Test Integrity + Optimize checkboxes; zipped copies the
user must prune manually. Catalog Settings: Standard Preview Size (up to 2880px/Auto), Preview
Quality, auto-discard 1:1 previews (Never → 30 days); auto-write XMP (14.4 batched flushes to every
10 s — per-edit writes were a measurable drag). File > Optimize Catalog is the standard "LrC is
slow" ritual, alongside Camera Raw cache resizing and GPU toggles.

**What Lumen takes.** SQLite + XMP, yes — rituals, no. Backups, vacuum, integrity checks, and
preview lifecycle run automatically; there is no "Optimize Catalog" menu item to know about
(docs/15-catalog.md). AI artifacts live in versioned, self-healing caches, never a
delete-this-file-yourself side-car.

---

## 5. Criticisms and sentiment, 2024–2026

The design ammunition, distilled from Adobe Community, Lightroom Queen, and reviewer threads:

1. **The five slownesses.** (a) Brush-stroke lag once several masks exist; (b) 0.5–10 s freezes
   switching photos in Develop with AI masks (15.0 regression; rollbacks to 14.5.2); (c)
   multi-second tool-open delays (masking, color mixer, crop) in 15.0; (d) permanent
   grid-scroll/folder-switch sluggishness on big catalogs; (e) Lens Blur degrading the whole
   session's GPU responsiveness. Root pattern: heavy work synchronous with the UI. The recurring
   paraphrase: "masking is the best thing Adobe added in a decade, and also the thing that makes my
   machine crawl." Adobe's own 15.0 marketing — "everyday editing gets faster" — is an admission of
   what users complain about most.
2. **Auto's blind spots.** Pre-crop analysis (white borders → severe underexposure), habitual
   shadow over-lift, a broken Ctrl+U in 13.3. "Make auto tone respect the crop" has been open for
   years.
3. **Dehaze/Clarity color and halo casts.** Open bug thread on dehaze shifting WB; magenta
   neutrals, blue/green shadows; Clarity halos at sky boundaries — the 2026 Edge mask control is
   Adobe's own tell that halos stayed real into 15.x.
4. **Credits anxiety.** Generative credit enforcement began 2025; post-Jun-2025 base photography
   plan = 25 credits/mo; Generative Remove "doesn't charge yet" but Adobe reserves the right;
   Generative Upscale charges today. Working photographers now budget attention around a meter
   inside a tool they already pay monthly for.
5. **The 15.4 pulled release.** Denoise posterization + AI-culling memory leaks freezing Macs;
   Adobe withdrew the release. Combined with the 15.0 mask-sync regression, the working-photographer
   habit is now "never update mid-season." Stability is a feature; QA failures are churn events.
6. **Slow-burn paper cuts.** Hidden non-inspectable profile contrast; Amount grayed out on
   camera-matching profiles; Melissa-RGB-percent readouts (15 years); Tint's +150 ceiling; silent
   PV upgrades; JPEG WB in ±100; `.lrcat-data` delete-it-yourself folklore; "Something went wrong"
   as an error message; the secondary window stealing keyboard focus.
7. **What users would riot without** (the adoption floor): draggable histogram, Alt-drag clipping,
   J overlays, shift-double-click per-slider auto, double-click resets, `\` before/after, TAT,
   hover-preview browsers, Caps-Lock auto-advance culling, Point Color + Variance, AI Denoise,
   people-parts masking, Dust Removal.

---

## 6. Scope decisions: every LR feature, Lumen's verdict

Verdicts: **adopt** (clone the proven design) · **adopt-improved** (clone the contract, fix the
documented weakness) · **defer** (real value, not v1) · **never** (deliberate refusal). Owning spec
doc in parentheses. These tables re-verdict the v1 product-spec tables against the research above.

### 6.1 Basic panel, tone, histogram

| LR feature | Verdict | Reason (one line) |
|---|---|---|
| Six tone sliders (ranges, order, semantics) | adopt-improved | Muscle memory is sacred; re-engine halo-free on EV-zone masks (docs/04-spec-tone.md) |
| Midtone-weighted Exposure, Highlights≤Whites contract | adopt | The semantics are why LR's tone feels safe — keep them exactly |
| WB Kelvin 2000–50000 + presets + eyedropper loupe | adopt-improved | Extend Tint past ±150 (underwater complaint); CAT16 underneath |
| Adobe Raw / Camera Matching / Creative profiles | never | No hidden uneditable layer; transparent base look + Film Lab instead (docs/05-spec-color.md) |
| Profile Amount 0–200 | adopt-improved | Every Lumen look is scalable — including the ones LR grays out |
| Adaptive (ML) Profiles | never | Invisible corrections violate AI doctrine; Auto writes visible slider values instead |
| Auto (Sensei, 8 sliders) | adopt-improved | Crop-aware, face-weighted, per-slider affordances, visible values (docs/04-spec-tone.md) |
| Per-slider auto (shift-double-click) | adopt-improved | Keep the behavior incl. endpoint-stretch for Whites/Blacks; make it discoverable |
| Alt-drag clipping, double-click resets, Alt group resets, arrow nudges | adopt | The riot-if-removed set; documented, not folklore (docs/12-spec-ux.md) |
| Texture / Clarity / Dehaze | adopt-improved | Same names/ranges; local-Laplacian Clarity, color-stable Dehaze, shared decomposition (docs/06-spec-detail.md) |
| Vibrance / Saturation | adopt-improved | Same contract on H-K-aware perceptual math with explicit skin protection (docs/05-spec-color.md) |
| Draggable 5-zone histogram + clipping triangles + J | adopt-improved | Add selectable readout space (kills Melissa RGB) + true raw histogram (docs/04-spec-tone.md) |
| Before/After (`\`, Y, Alt+Y, Shift+Y) + Reference View | adopt | Series-matching backbone for event work (docs/12-spec-ux.md) |
| Process versions | adopt-improved | `pipelineVersion` from day 1, migration explicit and badged, never silent (docs/15-catalog.md) |
| Legacy PV1/PV2 slider sets | never | History, not features |

### 6.2 Curves and color

| LR feature | Verdict | Reason |
|---|---|---|
| Tone Curve: parametric + splits + point + R/G/B + TAT | adopt-improved | Add C1-style Luma curve; default luminance-preserving, legacy chroma opt-in (docs/04-spec-tone.md) |
| Refine Saturation | adopt-improved | Right idea, wrong default — Lumen defaults to 0-equivalent semantics |
| Color Mixer (8-band HSL + TAT) | adopt-improved | Smooth periodic falloff (no PV6-class banding), hue-ring UI, Uniformity slider (docs/05-spec-color.md) |
| Point Color + Variance + Visualize Range | adopt-improved | Most-loved recent LR feature; falloff always visualizable; global and per-mask (docs/05-spec-color.md) |
| Color Grading wheels + Luminance + Blending/Balance | adopt-improved | Add visible draggable zone pivots — the #1 advanced complaint (docs/05-spec-color.md) |
| Calibration (RGB primaries + shadows tint) | adopt-improved | v1 said "never — legacy"; research overturns it: this powers the calibration-look economy (docs/05-spec-color.md) |
| B&W mix + Auto | adopt-improved | Preserve mix state across treatment toggles (fixes LR's state-loss bug); auto suggests, never silently applies |
| Creative-profile LUT packs | never | One photographer needs a handful of deep looks + an import path, not 40 canned packs |

### 6.3 Detail, denoise, enhance, blur

| LR feature | Verdict | Reason |
|---|---|---|
| Sharpening 4-slider + alt-views | adopt | The reference capture-sharpening UI; embedded in three-pass doctrine (docs/06-spec-detail.md) |
| Manual NR (Lum/Color groups) | adopt-improved | Unified Noise section: profiled classical tier, always live, local in masks (docs/07-spec-denoise.md) |
| AI Denoise (toggle + Amount, ANE) | adopt-improved | Skip the 2-year DNG detour; full-image preview, ≤10 s/45MP, background queue (docs/07-spec-denoise.md) |
| Raw Details (AI demosaic toggle) | never | Better demosaic is the default pipeline, not a toggle (docs/14-pipeline.md) |
| Super Resolution 2× | defer | Same infra as denoise; build after it ships |
| Generative Upscale (cloud Topaz) | never | Cloud + credits contradict the product thesis |
| Lens Blur | defer | Demand is proven; LR also proved slow+haloed damages the brand — ship only if depth/matting/async clear the bar |
| Grain (Effects) | adopt-improved | Simple grain in docs/06-spec-detail.md; film-stock density-domain grain in the Film Lab (docs/05-spec-color.md) |
| Post-crop vignette (Highlight/Color Priority) | adopt | Cheap, expected; drop Paint Overlay (legacy, unused) |

### 6.4 Optics, geometry, retouch, HDR

| LR feature | Verdict | Reason |
|---|---|---|
| Profile lens corrections + Remove CA | adopt | Apple RAW built-ins by default; override sliders kept (docs/09-spec-geometry.md) |
| Defringe (dual-thumb hues + eyedropper + alt-view) | adopt | A beloved micro-interaction; clone it exactly |
| Upright incl. Guided 4-guide + loupe | adopt | "Basically solved" — copy the solution (docs/09-spec-geometry.md) |
| Manual transform sliders + Constrain Crop | adopt | Table stakes |
| Crop grammar (R, presets, O overlays, ruler, X flip, shield opacity) | adopt | Image-under-fixed-frame, live pipeline in crop (docs/09-spec-geometry.md) |
| Heal / Clone / Content-Aware + editable pins | adopt-improved | PatchMatch + gradient-domain blending; pins editable forever (docs/09-spec-geometry.md) |
| Detect Objects (scribble→object removal) | adopt-improved | Local segmentation model, no cloud |
| Generative Remove (Firefly cloud) | never | Cloud, credits, meme failures; local inpainting covers ~90% of a solo shooter's needs |
| Dust Removal one-click + Visualize Spots | adopt | Instantly loved, fully local, tractable (docs/09-spec-geometry.md) |
| Red Eye / Pet Eye | never | Mirrorless-era rarity; heal covers it |
| HDR editing mode + gain-map export | adopt-improved | macOS-native EDR advantage; deliberate SDR rendition + delivery preview (docs/11-spec-output.md) |
| Render to DNG | never | The export engine already produces flattened deliverables (docs/11-spec-output.md) |
| Edit in Firefly | never | Cloud round-trip outside the raw pipeline |

### 6.5 Masking

| LR feature | Verdict | Reason |
|---|---|---|
| Mask = component stack, Add/Subtract/Invert | adopt | The right model (docs/08-spec-masking.md) |
| Intersect (hidden behind Alt / ⋯ menu) | adopt-improved | First-class visible button, not an easter egg |
| Subject / Sky / Background / Objects (scribble + box) | adopt | Full AI roster, local models |
| People with 10 sub-parts | adopt | Exactly the owner's portrait/event spread |
| Landscape classes (8) | adopt | Exactly the owner's landscape spread |
| Brush (size/feather/flow/density + Auto Mask + eraser) | adopt | The cleanup workhorse |
| Linear / Radial gradients | adopt | Table stakes |
| Color Range (5 samples + refine + matte preview) | adopt | Keep the Alt-drag matte preview |
| Luminance Range (band + smoothness + map view) | adopt-improved | Visual band handles by default |
| Depth Range (iPhone-HEIC-only) | adopt-improved | Monocular depth makes it work for **every** photo — LR's version is a gimmick |
| Per-mask Amount 0–200 + pin scrub | adopt-improved | Plus per-component amount — the thing Adobe refuses to ship |
| Feather + Edge refinement | adopt | Took Adobe until mid-2026; Lumen ships it day 1 |
| Overlay modes (6) + O/Shift+O/Alt+O | adopt | Cheap, expected |
| Local tone curve / local grading wheels | adopt-improved | LR still lacks both in 2026 — Lumen's clearest color-depth win (docs/08-spec-masking.md) |
| AI mask sync/preset recompute | adopt-improved | Always automatic, always background-queued — 15.0's regression is the named failure |
| `.lrcat-data` raster storage | never | Parametric masks + versioned self-healing caches (docs/15-catalog.md) |

### 6.6 Library, culling, catalog

| LR feature | Verdict | Reason |
|---|---|---|
| Import dialog (copy/move/add, renaming, apply-during, 2nd copy) | adopt-improved | One optional verified-ingest screen; browsing never requires it (docs/10-spec-library.md) |
| Preview system (4 types × smart × quality × discard) | adopt-improved | One automatic pipeline: embedded JPEG instantly, background proxies, invisible |
| Embedded & Sidecar fast culling | adopt | Promoted from community trick to the default browse path |
| P/X/U, 1–5, 6–9, Caps-Lock auto-advance | adopt | Keystroke-for-keystroke; auto-advance default-on and visible |
| Grid/Loupe/Compare/Survey + synced zoom | adopt | Table stakes |
| Painter (spray) bulk tagging | adopt | Genuinely fast for event triage |
| AI Assisted Culling + Faces panel + strictness | adopt-improved | Evidence-not-verdicts: per-face crops, badges, flags only, never auto-reject (docs/10-spec-library.md) |
| Duplicate detection + Auto Stacking | adopt | Capture time + feature-distance grouping |
| Filter bar (Text/Attribute/Metadata) | adopt-improved | Native OR across criteria — LR needs a plugin for it |
| Smart Collections rule engine | adopt | Smart albums = saved queries over SQLite |
| Collections / Quick Collection / Target (B) | adopt | Table stakes |
| Stacks, Virtual Copies | adopt | Virtual copies are cheap recipe rows in Lumen's model |
| Quick Develop relative adjustments | adopt | Relative deltas across a selection — kept, modernized |
| Keywords, hierarchy, synonyms | defer | Solo workflow rarely needs them; EXIF search covers most; revisit post-v1 |
| Face recognition / People view | never | Photos.app exists; culling Faces panel ≠ identity recognition |
| Map / GPS module | never | Out of scope |
| Publish Services plugin platform | never | Export presets + watched re-export flag keep the useful 4-state idea (docs/11-spec-output.md) |
| Book / Slideshow / Print / Web modules | never | Export to disk covers everything the owner does |
| Tethered capture | never | Not the owner's workflow |
| Second window | adopt-improved | Pinnable second viewer with sane keyboard focus (docs/12-spec-ux.md) |
| Lights Out | adopt-improved | Superseded by the one-key ISO 12646 assessment mode (docs/12-spec-ux.md) |
| Catalog backup / Optimize Catalog ritual | adopt-improved | Automatic backups, vacuum, integrity checks — no ritual (docs/15-catalog.md) |
| XMP sidecars | adopt | Everything inspectable, no lock-in (docs/15-catalog.md) |
| Multiple catalogs / import-export catalog | never | One library, done well |

### 6.7 Sync, presets, history

| LR feature | Verdict | Reason |
|---|---|---|
| History + Snapshots + hover preview | adopt-improved | Add timestamps to snapshots |
| Copy/Paste subsets + Previous | adopt | The batch backbone |
| Sync / Auto Sync | adopt-improved | Unmissable Auto Sync state indicator (fixes the foot-gun) |
| Develop presets + Amount 0–200 | adopt | Presets are saved partial recipes |
| Adaptive presets (embedded AI masks) | adopt-improved | Masks recompute in a background queue on apply |
| ISO-adaptive presets | adopt-improved | Promoted to first-class import defaults with onboarding (docs/07-spec-denoise.md) |
| Cloud sync / mobile ecosystem | never | Local-only is the thesis |
| Content Credentials | never | No cloud identity machinery in a local tool |

---

## Sources

Full bibliography lives in docs/17-appendix.md. Primary bases for this teardown (all accessed
2026-08-19 via search extracts; direct fetches of helpx.adobe.com were egress-blocked): Adobe Help
(tone controls, HDR output, masking, local adjustments, Lens Blur, Upright, Color Mixer,
ISO-adaptive presets, import, filter bar, smart collections, catalogs); Adobe blogs and Julieanne
Kost's guides (histogram zones, profiles, Adaptive Profile, Color Grading, masking shortcuts,
Painter tool, 15.4); Lightroom Queen what's-new archive (7.3 → 15.5) and forums; Computer Darkroom
(Aug 2026 Feather/Edge specs); the Melissa RGB technical PDF (Peachpit); PetaPixel, Fstoppers,
PhotoshopCAFE, Thomas Fitzgerald, Greg Benz, Ask Tim Grey, f64 Academy; and Adobe Community threads
for the sentiment record (Auto underexposure, dehaze casts, Tint ceiling, mask sync regression,
Lens Blur slowdowns, 15.4 pull, credit enforcement).
