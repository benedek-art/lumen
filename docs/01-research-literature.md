# 01 — Research: The Bookshelf

What the canonical literature of photographic post-processing and color grading actually teaches, and
what Lumen commits to building because of it. Twenty-odd books and canon sources, mined not for
inspiration but for tool-design decisions. Every entry follows the same shape: **finding** (what the
source teaches, with the memorable specifics), **evidence** (where that reading comes from), **what
Lumen takes** (concrete commitments, each pointing at the spec doc that owns the implementation).

Research sweep: August 2026. Facts that could only be corroborated through secondary summaries are
flagged `(unverified)` and stay flagged until someone holds the book. The full bibliography lives in
`17-appendix.md`; this doc names sources inline.

The shelf, grouped by school:

| School | Sources | What it contributes |
|---|---|---|
| Grading canon (moving image) | Van Hurkman; Hullfish | Scopes, wheels, workflow order, memory colors, skin-tone line |
| The Margulis school | *Professional Photoshop*; *Photoshop LAB Color*; PPW | Numbers over vibes, lightness/color decoupling, ordered passes |
| Fraser/Schewe school | *Real World Image Sharpening*; *Real World Camera Raw*; *The Digital Negative*; *The Digital Print* | Raw discipline, three-pass sharpening, print-side output craft |
| Lightroom teachers | Evening; Kelby; duChemin | Two UX registers; editing as expression |
| Tonal philosophers | Adams ×2; Barnbaum; Freeman | Zone system, previsualization, optimization vs. interpretation |
| Color-science canon | Fairchild; Hunt; Poynton; VES *Cinematic Color*; Sobotka/AgX | Appearance phenomena, preferred reproduction, which math in which space, picture formation |

---

## Part I — The grading canon

The professional colorist community's two standard texts. Moving-image books, but their tool doctrine
transfers to stills almost without translation — and almost no stills editor has absorbed it. That gap
is the core of Lumen's opening (see the synthesis at the end of this doc).

### Alexis Van Hurkman — *Color Correction Handbook: Professional Techniques for Video and Cinema* (2nd ed., 2014, Peachpit)

**Finding.** The book's ten-chapter structure is itself a workflow argument: color-critical viewing
environment first, then primary contrast, then primary color, then HSL secondaries and shapes, then an
entire chapter (Ch. 8) on **memory colors** — skin, skies, foliage — then shot matching and scene
balancing (Ch. 9), then QC (Ch. 10). Evaluation happens **through scopes**, not adapted eyes: luma
waveform for contrast and black level, RGB parade for casts, vectorscope for hue and saturation.
Memory colors are "those colors that are recalled in association with familiar objects"; audiences
judge skin, sky, and foliage against remembered ideals, not against the scene. The colorist's job on
these subjects is idealization, not measurement.

The book's single most portable instrument is the **vectorscope skin-tone line**: the legacy NTSC
in-phase (−I) axis. All human skin hues cluster along it regardless of ethnicity, because the hue
comes from blood and melanin; saturation and luminance vary widely, hue barely does. Modern scopes
(e.g. Nobe Omniscope) draw the line and add a tolerance band. The literature's own caveat: "the line
is a reference and not a rule."

**Evidence.** Publisher chapter listing (Peachpit/O'Reilly) confirms the ten-chapter progression and
Ch. 8's title ("Memory colours: skin tone, skies and foliage"). ProVideo Coalition's review singles
out the memory-colors chapter as deeper on skin than nearly any stills text. Skin-tone-line facts
corroborated across colorist references (Omniscope docs, working-colorist explainers). LiftGammaGain
professionals recommend this book alongside Hullfish as the pair to read.

**What Lumen takes.**
- A **vectorscope with the skin-tone line and a tolerance band** ships in the grading context, one
  disclosure away, alongside RGB parade and luma waveform. Histogram is always on. Owned by
  `05-spec-color.md`; overlay mechanics and latency in `12-spec-ux.md`. Almost no stills editor ships
  a vectorscope; for a portraits-and-events shooter it is cheap, objective differentiation.
- The **memory-color doctrine shapes Lumen's defaults**: dedicated skin tools (skin uniformity,
  skin-protected vibrance/saturation) and default renderings tuned toward pleasing skin and sky, not
  colorimetric truth. Owned by `05-spec-color.md`.
- **Shot matching as a first-class stills problem.** Van Hurkman devotes a chapter to it; Lightroom
  devotes nothing. Lumen's answer is the printer-lights tool (log-space master + R/G/B trims,
  keyboard-steppable) plus the set-wide Look layer. Owned by `05-spec-color.md` and the Develop/Look
  split in `00-vision.md`.
- **Skipped:** broadcast-safe QC and video legalization (Ch. 10). Irrelevant to stills beyond the
  soft-proof gamut warnings in `11-spec-output.md`.

### Steve Hullfish — *The Art and Technique of Digital Color Correction* (2nd ed., 2010, Focal)

**Finding.** Built from recorded sessions with more than a dozen elite colorists (Bob Festa, Stefan
Sonnenfeld, Pankaj Bajpai, others), capturing not only what they do but why. The documented common
practice is strikingly consistent: most colorists **start with the black level** on a luma-only
waveform, set contrast before color, and do primaries (whole-frame tone and balance) strictly before
secondaries (region- or vector-limited refinements). Hullfish is explicitly tool-agnostic: the
techniques hold "regardless of whether the software has sliders, wheels or curves." The mental model
is adjust-shadow/mid/high tone and hue; the handle is incidental.

**Evidence.** Publisher page (Routledge) and the CineMontage review, which highlights the
black-level-first observation and the primary/secondary/pro-colorists structure.

**What Lumen takes.**
- **Controls are representations of operations, not the operations.** Lumen ships sliders, curves,
  wheels, and printer lights as different handles over one scene-referred engine — a user who thinks
  in curves and a user who thinks in wheels are served by the same math, and switching representation
  never changes the result. Tone handles in `04-spec-tone.md`, color handles in `05-spec-color.md`,
  engine in `14-pipeline.md`.
- **Contrast before color, primaries before secondaries** is encoded in the default panel order
  (tone panels above color panels, global panels above masking) rather than enforced. See the
  synthesis section and `12-spec-ux.md`.
- The colorists' shadow/mid/high mental model justifies the **Zones panel** (per-zone exposure in
  stops, per-zone wheels) as the advanced tone surface in `04-spec-tone.md` — it is the closest a
  stills tool has come to how these professionals actually describe their moves.

---

## Part II — The Margulis school

### Dan Margulis — *Professional Photoshop: The Classic Guide to Color Correction* (5 editions, 1994–2006)

**Finding.** The father of **"color by the numbers"**: verify known values numerically, because
monitors, ambient light, and chromatic adaptation make eyeball judgment unreliable. Known-color
anchors: neutrals must read neutral at highlight, midtone, and shadow; nearly every image deserves a
true (near-)white and (near-)black endpoint; skin must obey **channel relationships, not absolutes** —
for Caucasian skin, cyan ≈ 1/5–1/3 of magenta and yellow ≥ magenta (up to +1/3); darker skin adds
cyan and magenta. Example targets circulating from Margulis/Varis practice (tanned Caucasian):
highlight 242/204/168 → quartertone 235/175/142 → 3/4-tone 201/128/83 → shadow 124/52/20 — with
Margulis's own caveat that "across all ethnicities flesh can be light or dark; the relationship
between the inks is what counts, not their exact values." His classic full-range endpoint targets are
CMYK-era prepress numbers; exact RGB equivalents vary by edition `(unverified)`.

**Evidence.** Wikipedia's Margulis entry (method, editions); PhotoshopGurus thread preserving the
Margulis/Varis skin ratios and worked values; CambridgeInColour sentiment ("a must read for serious
colour correction"). A real dissenting camp finds him prepress-centric and dogmatic — noted, and the
CMYK machinery is exactly what Lumen does not take.

**What Lumen takes.**
- **Numbers in the UI, everywhere they earn their place**: the WB eyedropper carries a scalable loupe
  with live RGB readouts (`04-spec-tone.md`); the histogram offers a selectable readout space —
  working space, sRGB 0–255, or output — killing the 15-year "Melissa RGB" class of complaint where
  the numbers match no space the user can name (`04-spec-tone.md`).
- **Relational skin verification, not absolute targets.** Lumen's objective skin aids are the
  vectorscope skin-tone line with tolerance band and the skin-uniformity tool — hue-relationship
  instruments that work across all ethnicities — not CMYK readouts. Owned by `05-spec-color.md`.
- **Full-range doctrine** survives as the Whites/Blacks endpoint sliders and the crop-aware Auto that
  places endpoints deliberately (`04-spec-tone.md`).
- **Skipped:** CMYK tooling and prepress targets. The relational logic stays; the ink math goes.

### Dan Margulis — *Photoshop LAB Color: The Canyon Conundrum* (2005; 2nd ed. 2015)

**Finding.** Called by reviewers "probably the most important Photoshop book ever written," and built
on one idea: **decouple lightness from color** (L vs. a/b), then **put important image regions on the
steepest part of the curve** — "the steeper the curve, the more the contrast." Steepening the a/b
opponent axes around an unchanged neutral midpoint multiplies color *variation* — separation between
similar colors — without shifting neutrals. The famous canyon examples resurrect subtle rock, sand,
and dirt color differences this way.

**Evidence.** Google Books listing and the steepest-curve principle as stated in the book; the
"most important" quote from published reviews (via the community sentiment sweep).

**What Lumen takes.**
- **Lightness/color decoupling as engine law.** UI-facing color tools compute in OKLab/OKLCh;
  luminance moves in the Color Mixer are chroma-preserving (no Lightroom-style desaturation when
  darkening a sky); the default point-curve behavior is luminance-preserving, with legacy chroma
  amplification as an explicit opt-in; and a dedicated Luma curve exists for saturation-stable
  contrast. Spaces in `05-spec-color.md`, curves in `04-spec-tone.md`.
- **"Steepen a/b around pinned neutrals" is, mechanically, a variance expander** — and its modern
  descendant is the Variance control on Lumen's Point Color swatches, which spreads the hue/sat
  distribution inside a sampled range without moving its center. Owned by `05-spec-color.md`.
- **"Steepest part of the curve" as an interaction**: the parametric curve's four regions have movable
  splits, and the Zones panel's pivots are visible and draggable on the histogram — both are direct
  ways to put steepness where the image lives. Owned by `04-spec-tone.md`.

### Dan Margulis — *Modern Photoshop Color Workflow* (the Picture Postcard Workflow, 2013)

**Finding.** Late-career Margulis compresses correction to about **three minutes per image** in three
ordered passes: (1) kill color casts, (2) win contrast by building the best possible B&W version and
applying it as a luminosity layer, (3) boost color (LAB curves or masked multiply). "Separate passes
to eliminate color problems, to heighten contrast, and to make the color sing." The philosophy,
documented in Gerald Bakker's independent PPW analysis: speed comes from decisive, mostly-scripted
big moves, not from many timid slider nudges.

**Evidence.** Publisher description; geraldbakker.nl's PPW overview (steps, philosophy, timing
claims). The 2013 book drew a genuinely controversial DPReview thread — the *pass structure* is what
survives scrutiny, not every specific recipe.

**What Lumen takes.**
- **Separate passes for cast, contrast, and color** is the strongest stills-side argument for the
  Develop/Look split: Develop normalizes each frame (cast, exposure, lens, noise); Look is the
  portable creative color layer applied set-wide. Owned by `00-vision.md`; surfaces in
  `04-spec-tone.md` and `05-spec-color.md`.
- **Three minutes per image is a design KPI, not a boast.** For the owner's event work the path to it
  is decisive compound moves: crop-aware face-weighted Auto that sets visible slider values, per-slider
  auto affordances, Speed Edit applying to the whole selection, and batch preset application.
  `04-spec-tone.md`, `12-spec-ux.md`, `10-spec-library.md`.
- **Contrast via the best B&W** validates investing in a real 8-band B&W mixing engine rather than a
  desaturate checkbox — the same machinery that makes `05-spec-color.md`'s B&W treatment credible.

---

## Part III — The Fraser/Schewe school

### Bruce Fraser & Jeff Schewe — *Real World Image Sharpening with Adobe Photoshop, Camera Raw, and Lightroom* (2nd ed., 2010)

**Finding.** Sharpening must be **three separate passes**, each with its own logic — Fraser's
invention, "subsequently adopted by Adobe and many other producers of photo editing software":

1. **Capture sharpening** — offset sensor/AA-filter/demosaic softness; tuned to the image source and
   detail character; applied once, conservatively, no visible halos.
2. **Creative sharpening** — local, optional, aesthetic. Eyes yes, skin no.
3. **Output sharpening** — computed *only* from final size, medium (screen/matte/glossy), and viewing
   distance. Visible halos are *correct* here: rule of thumb, 1/50"–1/100" halo width in print.
   Judge on the print or at 50%/25% zoom, never at 100%.

Halos decompose into a **light contour and a dark contour** deserving independent opacity — dark
halos offend more than light ones (PhotoKit Sharpener exposes exactly this). Noise reduction belongs
with capture sharpening, before everything else. And the decisive precedent: **Adobe licensed
PhotoKit's output-sharpening engine into Lightroom** as the three-choice Screen/Matte/Glossy ×
Low/Standard/High export control — proof that output sharpening should be an automated export-time
computation, not a parameter farm.

**Evidence.** O'Reilly edition page (three-stage structure); Luminous Landscape's PhotoKit Sharpener
coverage (halo widths, contour opacities, judgment distances) and its Schewe retrospective (the Adobe
licensing); DPReview practitioner threads on the three-pass workflow.

**What Lumen takes.** The doctrine wholesale, split across two docs:
- **Capture sharpening default-on for raw** — auto-radius Richardson–Lucy deconvolution with σ
  estimated from the Bayer greens and a corner boost — plus the Lightroom-compatible four-slider
  manual surface (Amount/Radius/Detail/Masking with alt-key visualizations) and C1-style halo
  suppression. Light/dark contour weighting is kept internal, never surfaced by default. Owned by
  `06-spec-detail.md`.
- **Creative sharpening is local-only** (inside masks), by design. `06-spec-detail.md`, `08-spec-masking.md`.
- **Output sharpening is automated at export**: Screen/Matte/Glossy × Low/Std/High, the licensed-into-
  Lightroom pattern, recomputed per recipe size. Owned by `11-spec-output.md`.
- **NR is coupled to capture sharpening** through ISO-adaptive defaults interpolated between per-ISO
  anchors, settable as import defaults. Owned by `07-spec-denoise.md`.

### Bruce Fraser (later Schewe) — *Real World Camera Raw* (multiple editions)

**Finding.** The first book devoted to raw conversion. Chapters on linear capture, digital exposure
and **ETTR** (expose to the right), sensor noise vs. ISO, bit depth, and the standing command "Watch
the Histogram!" The raw file is not a picture; it is data whose rendering is the photographer's
decision, and the histogram the camera shows you is a JPEG's histogram, not the sensor's.

**Evidence.** O'Reilly edition contents.

**What Lumen takes.**
- **A true raw histogram** — per-channel, pre-rendering, with clipped-percent stats — available at
  cull time, not buried in a develop module. This folds FastRawViewer's core value into the culling
  loop. Owned by `04-spec-tone.md` (histogram) and `10-spec-library.md` (cull-time raw truth:
  hold-key shadow-boost and highlight-inspect overlays, per-channel clipped %).
- The ETTR shooter's real need is honest headroom reporting, which the scene-referred pipeline
  (`14-pipeline.md`) preserves by never clipping until the single display transform.

### Jeff Schewe — *The Digital Negative: Raw Image Processing in Lightroom, Camera Raw, and Photoshop* (2nd ed., 2015)

**Finding.** The raw file is a **latent image**: expose for the sensor, then *render* — tone, color,
capture sharpening and NR, B&W conversion, merges — in a parametric, non-destructive workflow. The
negative/render split assigns capture sharpening and noise reduction to the rendering stage, once,
per source.

**Evidence.** Peachpit contents listing.

**What Lumen takes.**
- **Non-destructive is not a feature, it is the edit model**: originals read-only, edits as
  declarative recipes, rendering as a pure function of (raw, recipe, pipelineVersion). Owned by
  `15-catalog.md` and `13-architecture.md`.
- Capture sharpening and profiled NR applied as part of default rendering, per camera/ISO
  (`06-spec-detail.md`, `07-spec-denoise.md`) — Schewe's assignment of these to the "negative" side,
  automated.

### Jeff Schewe — *The Digital Print: Preparing Images in Lightroom and Photoshop for Printing* (2013)

**Finding.** Output is its own discipline: soft proofing, rendering intents, output resolution and
interpolation, printer types, B&W printing, and print-side sharpening. Frames "the attributes that
define a perfect print" as a checklist — output quality is enumerable, therefore automatable.

**Evidence.** Peachpit contents listing.

**What Lumen takes.**
- **Soft proofing with gamut warning and a print-size-aware sharpening preview** (50%/25% zoom
  presets — Fraser's judgment rule made into a button). Owned by `11-spec-output.md`.
- Color-managed export to sRGB/P3/Adobe RGB with per-recipe output sharpening; the multi-recipe
  export engine treats Schewe's checklist as recipe fields. `11-spec-output.md`.

---

## Part IV — The Lightroom teachers

### Martin Evening — *The Adobe Photoshop Lightroom Classic Book* (editions tracking LR through ~2019+)

**Finding.** "Without a doubt the most comprehensive manual on the subject... considered the Lightroom
bible." Covers the *why* behind every Develop control — process versions, camera profiles, the
cataloging model. Forum verdict: deeper than anything else and harder to follow for it; "where
Kelby's book says 'that detail is for another book,' Evening's is that other book."

**Evidence.** Lightroom Queen forums, Nikon Cafe, CambridgeInColour recommendation threads.

**What Lumen takes.**
- Evening is the proof that a **full-depth register** has a real audience. In Lumen that register is
  never a separate mode: full depth sits exactly one disclosure away from the simple surface, per
  the two-registers law in `00-vision.md` and the disclosure patterns in `12-spec-ux.md`.
- The Evening ethos also sets the bar for *this planning package*: every control documented with its
  why, ranges, and engine behavior — the spec docs 04–12 are written to be Lumen's Evening.

### Scott Kelby — *The Adobe Photoshop Lightroom Classic Book for Digital Photographers*; *Lightroom 7-Point System* (2021, Rocky Nook)

**Finding.** Perennial #1 bestsellers, conversational and strictly recipe-ordered. The 7-Point System
teaches "just the seven major editing moves," practiced across 21 supplied raw files in fixed order —
per KelbyOne/Nikonites summaries of an earlier edition: camera profile → white balance → overall
exposure → contrast via tone curve → local adjustments (brush) → lens corrections/effects → sharpening.
The full canonical list for the 2021 edition was not independently verified this sweep `(unverified)`.
Forum criticism — recipe books teach "move this slider this far" without theory — coexists with the
observable fact that many learners need exactly that. "Kelby tells you how; Evening tells you how and
why." Both registers are real; both sell.

**Evidence.** Rocky Nook product page (seven moves, 21 practice raws); Nikonites enumeration of the
points; Nikon Cafe sentiment thread.

**What Lumen takes.**
- The **Kelby register** is Lumen's default face: an opinionated simple surface usable in minute one,
  auto/one-click entry points on top of every panel, manual controls beneath — never two parallel
  tools for one intent. Owned by `00-vision.md`; per-panel expression in each spec doc; layout in
  `12-spec-ux.md`.
- Kelby's fixed recipe order is one of the four independent sources that converge on the same
  canonical workflow order (see synthesis) — Lumen encodes it as the default panel order, guided but
  never enforced.

### David duChemin — *Vision & Voice: Refining Your Vision in Adobe Photoshop Lightroom* (2010, New Riders)

**Finding.** Develop-module work is *expression of intent*, not repair. His per-image process:
**identify your intention → minimize the distractions → maximize the mood → draw the viewer's eye**,
"while leaving room for play and serendipity," demonstrated start-to-finish on 20 of his own raws.
Notably, he treats local adjustments — burn/dodge, vignette, local contrast — as *compositional*
tools that direct the eye.

**Evidence.** O'Reilly edition page (definitions, process, worked images).

**What Lumen takes.**
- **Experimentation must be free**: virtual copies are just recipe rows (cheap by construction,
  `15-catalog.md`), before/after is instant and always available (`12-spec-ux.md`), and history is
  unlimited because recipes are declarative.
- **Local tools framed as light-shaping, not fixing**: Lumen's masking system carries full tonal and
  color depth per mask — including local tone curves and local color-grading wheels, which Lightroom
  still lacks in 2026 — because "draw the viewer's eye" deserves the same vocabulary as the global
  grade. Owned by `08-spec-masking.md`; vignette as a compositional tool in `06-spec-detail.md`.

---

## Part V — The tonal philosophers

### Ansel Adams — *The Negative* (1981) and *The Print* (1983)

**Finding.** The Zone System (with Fred Archer, late 1930s): eleven zones 0–X, one stop apart;
Zone V = middle gray (18%); Zone III = darkest shadow with full detail; Zone VII = brightest textured
highlight; 0 and X are pure black and paper white. **Previsualization**: decide where each tone
*should land* before touching anything, then *place* one luminance on a chosen zone and let the
others *fall*, using development (N+1/N−1 expansion and contraction) to control where the highlights
end up. And the license for all editing, from *The Print* p. 2: "The negative is comparable to the
composer's score and the print to its performance." The same negative legitimately yields different
prints over a lifetime.

The digital translation is already folklore: the histogram is the zone meter, the raw file is the
negative, tone controls are development. Lightroom's Basic panel is a de facto **five-zone digital
zone system** (Blacks / Shadows / Exposure / Highlights / Whites), and its parametric tone curve a
four-region one with movable splits.

**Evidence.** Zone definitions per the standard references (photoworkout's 2026 guide among others);
the score/performance quote sourced to *The Print* p. 2 via Photrio; the LR-as-zone-system mapping
documented by multiple commentators (marcosecchi, lifeafterphotoshop).

**What Lumen takes.**
- **The Zones panel is the Zone System made into a control surface**: five named zones plus Global,
  per-zone exposure denominated **in stops** (Adams's native unit — N+1 is literally +1.0 on a zone),
  with zone pivots and falloff visible and draggable on the histogram. "Place a tone" becomes a
  drag. Owned by `04-spec-tone.md`.
- The **draggable five-zone histogram** and channel-diagnostic clipping indicators are the zone meter
  and the Zone 0/X alarms. `04-spec-tone.md`.
- An optional **zone-system overlay** ships with the B&W treatment for previsualization.
  `05-spec-color.md`.
- **Score/performance is the philosophical warrant for the whole edit model**: non-destructive
  recipes, cheap versions, and explicit rendering-version migration — the performance can change;
  the score never does. `15-catalog.md`.

### Bruce Barnbaum — *The Art of Photography: A Personal Approach to Artistic Expression* (2nd ed., 2017, Rocky Nook; >100k copies)

**Finding.** A complete textbook spanning composition, light, and both the film and **digital zone
system** (a revised chapter), deep on *expansion and compression of tonal scale* and insistent on
"art versus technique": every darkroom or Lightroom move serves a communicative goal, not
correctness.

**Evidence.** Rocky Nook edition page (digital zone system chapter, sales figures).

**What Lumen takes.**
- Barnbaum is the check on Lumen's automation doctrine: tools **propose, the photographer disposes**.
  Auto sets visible slider values the user then tunes; AI assists produce evidence, never verdicts;
  a master off-switch exists. The expressive decision is never taken by the tool. `00-vision.md`.
- Expansion/compression of tonal scale is precisely what per-zone exposure in stops does — the Zones
  panel again, `04-spec-tone.md`.

### Michael Freeman — *Photo School: Digital Editing* (with Steve Luck, 2012); *Perfect Exposure* (2nd ed.)

**Finding.** Freeman's consistent angle: workflow as an explicit decision tree. He distinguishes
**optimization** (raw processing and post-production making the image look "as good as it possibly
can") from **interpretation**, and teaches a fixed order: exposure fixes → color adjustments →
sharpening/NR → specialized work (B&W, pano, HDR). *Perfect Exposure* organizes shooting and editing
around decision flowcharts, histogram literacy, and twelve canonical exposure situations.

**Evidence.** Apple Books listing for *Digital Editing* (optimization vs. post-production framing,
workflow trees).

**What Lumen takes.**
- **Optimization vs. interpretation is the stills-side ancestor of Lumen's Develop/Look split** — the
  cinema normalize-then-grade doctrine and Freeman's distinction are the same idea from two
  traditions, which is why the split is architectural from day 1. `00-vision.md`.
- Decision trees automated: ISO-adaptive defaults and the auto-personality preference ("lift shadows
  less") are Freeman's flowcharts executed by the tool and shown to the user as editable values.
  `07-spec-denoise.md`, `04-spec-tone.md`.

### Lee Varis — *Skin: The Complete Guide to Digitally Lighting, Photographing, and Retouching Faces and Bodies* (2nd ed., 2010, Wiley)

**Finding.** Skin by the numbers, stills-side: for Caucasian skin, magenta and yellow roughly equal,
cyan 1/4–1/3 of magenta; African-American skin runs higher cyan and magenta percentages — always
*ratios sampled from the image*, never absolute targets. Skin is the one subject where viewers detect
a 2–3% error. CMYK-style readouts persist as skin diagnostics even in RGB workflows because the
relationships are what the numbers are for.

**Evidence.** Wiley edition page; the PhotoshopGurus Margulis/Varis thread preserving the ratio rules.

**What Lumen takes.**
- **Skin as a protected class and a product pillar**: skin uniformity (variance compression of
  hue/sat/lightness toward a picked target), skin-protected vibrance/saturation, and the vectorscope
  skin line with tolerance band as the objective guardrail when batch-editing hundreds of event
  frames. All owned by `05-spec-color.md`.
- The 2–3% detection threshold justifies the engineering spend: skin tools get perceptual-space math
  and their own verification imagery in the golden-test set (`14-pipeline.md`).

---

## Part VI — The color-science canon

### Mark Fairchild — *Color Appearance Models* (2nd ed. 2005, 3rd ed. 2013, Wiley-IS&T)

**Finding.** The reference for everything beyond tristimulus matching: chromatic adaptation
transforms (the foundation of white balance), CIECAM02/CAM16, and the appearance-phenomena zoo that
breaks naive RGB math — the Hunt effect (colorfulness rises with luminance), Stevens effect (contrast
rises with luminance), **Bartleson–Breneman** (perceived contrast depends on *surround*: a dark
surround demands higher image contrast), simultaneous contrast, crispening,
**Helmholtz–Kohlrausch** (saturated colors look brighter), Abney and Bezold–Brücke hue shifts,
discounting-the-illuminant. Fairchild's own caveat: CIECAM-class models still don't fully handle
spatially complex stimuli — images — which motivates practical hue-linear working spaces over full
appearance modeling.

**Evidence.** Fairchild's published TOC; the appearance-phenomena chapter (Wiley).

**What Lumen takes.**
- **White balance runs on CAT16** under one control surface. `04-spec-tone.md`.
- **Helmholtz–Kohlrausch is handled, not ignored**: saturation/vibrance use an H-K-aware perceptual
  model, and the advanced grading math runs in a perceptual UCS. `05-spec-color.md`.
- **Bartleson–Breneman makes the UI part of the pipeline**: neutral-gray chrome at zero chroma,
  user-set canvas surround, and a one-key ISO 12646 assessment mode (mid-gray surround, white frame).
  The viewing environment chapter of Van Hurkman and this book agree; `12-spec-ux.md` implements it.
- **Skipped:** full CIECAM/CAM16 appearance modeling in the engine. Too heavy, wrong tool for images
  by Fairchild's own admission. Lumen takes the practical distillates and stops.

### R.W.G. Hunt — *The Reproduction of Colour* (6th ed., 2004, Wiley-IS&T)

**Finding.** Defines the six objectives of colour reproduction — spectral, colorimetric, exact,
equivalent, corresponding, **preferred** — and demonstrates that consumer photography's objective is
*preferred*: memory colors "are seldom colorimetrically accurate and are frequently influenced by
color preferences"; "a suntanned appearance is preferred in skintone reproduction, even when not
found in the original subject." Quality is judged relative to intended use, not measurement.

**Evidence.** Wiley edition page; Jim Kasson's color-reproduction-problem essay summarizing the six
objectives.

**What Lumen takes.**
- **Defaults aim at preferred reproduction, deliberately and on the record.** Lumen's default
  renderings and the named display-transform presets are tuned toward pleasing skin, clean skies, and
  believable foliage rather than colorimetric truth — accuracy is available (the linear/flat escape
  hatch and neutral preset), but it is not the default because Hunt showed it is not what
  photographs are for. `04-spec-tone.md` (transform presets), `05-spec-color.md` (memory-color
  defaults).

### Charles Poynton — *Digital Video and HD: Algorithms and Interfaces* (2nd ed., 2012) + the Gamma/Color FAQs

**Finding.** The engineering bible for gamma, luma vs. luminance, and encoding. The doctrine Lumen
cares about: sRGB/BT.709-class code values are approximately **perceptually uniform** — gamma is a
feature (perceptual quantization), not a bug — and correctness demands knowing which operations
belong where: **physical light math (blur, resample, exposure, compositing) in linear; perceptual
operations and quantization in uniform encodings.** Doing physical math in nonlinear space produces
wrong pictures; this is an engineering-correctness issue, not taste.

**Evidence.** The Color FAQ (Edinburgh mirror); Poynton's perceptual-uniformity paper.

**What Lumen takes.**
- **The Poynton rule is engine law**: all physical ops in linear scene-referred f32; perceptual moves
  (UI-facing color tools, saturation models) in OKLab/OKLCh-class spaces; quantization only at
  encode. The pipeline doc enforces which stage runs in which space per kernel. `14-pipeline.md`,
  `05-spec-color.md`.
- **No user-facing color-management picker.** The user never chooses a working space; there is
  exactly one correct managed path. `05-spec-color.md`, `11-spec-output.md`.

### VES — *Cinematic Color: From Your Monitor to the Big Screen* (Jeremy Selan, 2012, 54 pp.)

**Finding.** The free white paper that codified **scene-referred vs. display-referred** imaging for
the film industry — plus ACES, the ASC CDL, and OpenColorIO — written explicitly because these
practices were "not covered in traditional color-management textbooks... often passed along only by
word of mouth, user forums or scripts."

**Evidence.** The white paper itself (CGW mirror); VES press materials.

**What Lumen takes.**
- **Scene-referred is settled doctrine, not an implementation detail**: linear f32 scene-referred
  core, exactly one display transform, tone controls operating pre-transform so highlight rolloff
  stays graceful in high-DR night and event frames. `14-pipeline.md`, `04-spec-tone.md`.
- **The CDL lineage validates printer lights**: a tiny, standardized, log-space correction vocabulary
  proved sufficient to carry looks across an entire industry. Lumen's printer-lights tool is that
  vocabulary aimed at shot matching. `05-spec-color.md`.
- **Skipped:** OCIO-style user configurability. Cinematic Color's audience is facilities; a
  one-photographer tool ships one correct path.
- The paper's stated reason for existing — knowledge trapped in folklore — is the reason this
  planning package writes everything down.

### Troy Sobotka — *The Hitchhiker's Guide to Digital Colour* (hg2dc.com) and AgX

**Finding.** Site motto: "If you are confused about digital colour, it's not your fault." Core
doctrines: camera data is **open-domain, scene-referred** data, *not a picture*; a picture only
exists after a deliberate **picture formation** step (the display rendering transform); treating 0–1
sRGB as the working universe is the root of most broken editing math. Naive per-channel S-curves —
classic "filmic" and camera-JPEG style — skew hues on bright saturated values: the **"Notorious
Six"** (bright reds → orange/yellow, blues → magenta/cyan, and their cousins), worsening with
brightness and saturation. **AgX** (Sobotka with Eary_Chow, Sakari Kapanen et al.) forms pictures via
inset primaries ("attenuation"), log2 encoding, and a sigmoid — controlled highlight
desaturation-to-white and deliberate, bounded hue behavior instead of accidental skews. It is now
Blender's default view transform and a darktable module, whose documentation is the best public spec
of a modern DRT for a raw editor. The consequence Lumen refuses to dodge: **the default rendering
transform is the look.**

**Evidence.** hg2dc.com (thesis, question series); darktable's AgX module documentation (Notorious
Six mechanism, AgX design, authorship).

**What Lumen takes.**
- **Exactly one display transform, AgX/sigmoid-class**, hue-preserving with controllable
  preservation, display-peak-parameterized so SDR and HDR share a code path; a visible face of 2–3
  controls plus named presets, primaries behind disclosure; the linear/flat escape hatch always
  available. Never a second tone mapper — darktable's four-transform museum is the named
  anti-pattern. Owned by `04-spec-tone.md`; implementation in `14-pipeline.md`.
- **The Notorious Six become regression tests**: the golden-image suite includes bright saturated
  hue sweeps rendered through the transform, asserting bounded hue travel. `14-pipeline.md`.
- Per-channel curve behavior survives only as the explicit legacy opt-in on the point curve
  (`04-spec-tone.md`) — available because some looks want the skew, never the silent default.

---

## Part VII — Synthesis

### The canonical order, encoded

Four independent traditions — colorist practice (Hullfish), Photoshop craft (Margulis's PPW),
Lightroom teaching (Kelby), and stills workflow writing (Freeman) — converge on the same order of
operations. When practitioners who never read each other agree this precisely, the order is not a
style; it is the shape of the work:

| Step | Hullfish (colorists) | Margulis (PPW) | Kelby (7-Point) | Freeman | Lumen surface |
|---|---|---|---|---|---|
| 1. Base rendering | — | — | Camera profile | — | Default rendering + display transform preset (`04-spec-tone.md`) |
| 2. Cast / balance | Balance after tone¹ | Pass 1: kill casts | White balance | Exposure fixes | WB, CAT16 (`04-spec-tone.md`) |
| 3. Tone & contrast | Black level first, contrast before color | Pass 2: contrast via best B&W | Exposure, then contrast | Exposure fixes | Six sliders, Zones, curves (`04-spec-tone.md`) |
| 4. Global color | Primary color | Pass 3: make the color sing | — | Color adjustments | Mixer, grading, film lab (`05-spec-color.md`) |
| 5. Local / secondaries | Secondaries strictly after primaries | Masked moves | Local adjustments | — | Masking with full local depth (`08-spec-masking.md`) |
| 6. Memory-color check | (Van Hurkman Ch. 8) | Skin by the numbers | — | — | Skin tools, vectorscope skin line (`05-spec-color.md`) |
| 7. Detail | — | — | Sharpening last | Sharpening/NR | Capture defaults at import; creative local (`06-spec-detail.md`, `07-spec-denoise.md`) |
| 8. Output | QC | — | — | Specialized output | Automated output sharpening, soft proof, recipes (`11-spec-output.md`) |

¹ Hullfish's colorists set the full tonal range before touching color balance; the table's step split
is Lumen's, the ordering constraint (tone before color, global before local) is theirs.

Lumen's default panel order encodes this top to bottom — tone above color, global panels above
masking, detail after color, output at export — with three deliberate deviations, each taught by the
same literature:

1. **Capture sharpening and profiled NR run at import, not at step 7.** Fraser assigned them to the
   source, not the aesthetic; automated per camera/ISO they stop being workflow steps at all
   (`06-spec-detail.md`, `07-spec-denoise.md`).
2. **Output sharpening does not exist as a panel.** It is an export-recipe field, per the PhotoKit
   precedent (`11-spec-output.md`).
3. **The order is a default, never a gate.** Hullfish's tool-agnosticism and duChemin's play both
   forbid enforced sequences. Panels work in any order; the layout merely makes the canonical path
   the path of least resistance (`12-spec-ux.md`).

And spanning the whole table, the Develop/Look split (`00-vision.md`): steps 1–3 and 7 normalize each
frame (Develop); steps 4–6 are the portable creative layer (Look). Margulis's separate passes,
Freeman's optimization-vs-interpretation, and cinema's normalize-then-grade are the same doctrine
three times over, which is why the split is architectural rather than cosmetic.

### The seam no book fills

Lay the shelf end to end and one absence is glaring. The community meta-finding from the research
sweep: photographers' most-recommended books cluster exactly as this doc groups them — Kelby/Evening
for Lightroom, Margulis for color doctrine, Fraser/Schewe for raw and sharpening craft, Van
Hurkman/Hullfish for grading, Adams/Barnbaum for tonal philosophy. **No single book unifies stills
workflow with colorist-grade tooling.** The two literatures do not cite each other:

- The **grading canon** assumes video: it teaches scopes, wheels, shot matching, memory colors, and
  viewing environments — then hands you Resolve, a tool with no culling, no catalog, no raw stills
  workflow, no export recipes.
- The **stills canon** assumes Adobe: it teaches culling, raw discipline, sharpening, and printing —
  inside a tool with no vectorscope, no waveform, no wheels with visible pivots, no printer lights,
  no shot matching, and a legacy display-referred rendering whose hue skews Sobotka had to name to
  get anyone to see.
- The **color-science canon** (Fairchild, Hunt, Poynton, VES, Sobotka) explains exactly why the
  stills tools' math misbehaves — and its findings have shipped in Blender and darktable, but in no
  polished commercial stills application.

Every pairwise combination is missing from the market. A tool that gives a portraits-and-events
photographer Photo Mechanic-class culling *and* a vectorscope with a skin-tone line; that gives a
landscape shooter zone-system tone placement *and* an AgX-class picture formation; that gives a
high-volume shooter printer lights and set-wide Looks *and* Fraser's automated sharpening pipeline —
the literature has specified this tool across twenty books for forty years, and nobody has built it.
That synthesis is Lumen's one-line thesis (owned by `00-vision.md` and the README); this bookshelf is
the evidence that the thesis is not novelty but overdue assembly.

---

## Sources note

Primary-adjacent and community sources consulted for this doc (full bibliography with URLs in
`17-appendix.md`): publisher pages and TOCs (Peachpit, Focal/Routledge, Rocky Nook, Wiley, O'Reilly,
New Riders); ProVideo Coalition and CineMontage reviews (Van Hurkman, Hullfish); LiftGammaGain,
Lightroom Queen, Nikon Cafe, CambridgeInColour, DPReview, dgrin, and PhotoshopGurus threads
(sentiment, Margulis/Varis skin values, Kelby/Evening register split); geraldbakker.nl (PPW
analysis); Luminous Landscape (PhotoKit Sharpener, Schewe retrospective); Nobe Omniscope docs and
working-colorist explainers (skin-tone line); Photrio (Adams sourcing); marcosecchi and
lifeafterphotoshop (LR-as-zone-system mapping); Fairchild's published TOC and chapters; Kasson on
Hunt; the Poynton Color FAQ; the VES *Cinematic Color* white paper; hg2dc.com; darktable's AgX module
documentation. Direct fetches of several primary PDFs were blocked during the sweep; items resting
only on secondary summaries are flagged `(unverified)` inline.
