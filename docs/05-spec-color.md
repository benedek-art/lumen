# 05 — Color: The Full System, Feature by Feature

Color is where Lumen intends to win outright. The teardown verdict is stable across every digest:
Lightroom Classic 15.5 has the workflow but a 20-year-old color surface with known artifacts; Capture One
16.8.4 has the industry-reference selective color but burned its owners; DxO built the best-liked HSL
interaction and buried it in a weak app; Resolve has categorically deeper color than all of them and is the
wrong vehicle for stills ("best color tools, wrong vehicle" is the literal community consensus). Nobody has
fused them. This document specifies the fusion.

Three doctrines govern everything below:

1. **One engine, several faces.** Hullfish's finding — sliders, wheels, and curves are representations of
   the same small operation set — is an architecture requirement here, not a quote. The Color Mixer and the
   Hue-Selective Equalizer are two views of one parameter set. The grading wheels' simple face and its
   advanced zones drive one perceptual grading core. Switching views never stacks operations (D3: never two
   parallel tools for one intent).
2. **Develop/Look split (D4).** Correction tools (Mixer used correctively, Point Color, Skin, Printer
   Lights) default to the per-image Develop layer. Creative tools (Grading wheels, Film Lab, B&W, LUTs)
   default to the portable Look layer that applies set-wide. Every color block in a recipe carries a stage
   tag; docs/00-vision.md owns the doctrine, docs/15-catalog.md owns the recipe format.
3. **Perceptual math, hidden plumbing (D21).** UI-facing color ops compute in OKLab/OKLCh; saturation-class
   ops use a UCS-22-style model with Helmholtz–Kohlrausch handling; gamut mapping is always-on,
   hue-preserving soft-clip. The user never sees a color-space picker. Details in the policy entry at the
   end of this doc; the working space itself (linear Rec.2020 f32) is owned by docs/14-pipeline.md.

The color stack, in pipeline order (docs/14-pipeline.md owns the authoritative stage list):

```
  scene-referred linear Rec.2020 (f32)
  ─ Primaries (input primary remap)          ← D19, "calibration" made honest
  ─ WB / tone                                ← docs/04-spec-tone.md
  ─ Printer Lights (log-space trims)         ← D16, Develop
  ─ Color Mixer / Equalizer (OKLCh)          ← D13, one engine two faces
  ─ Point Color swatches (OKLab)             ← D14
  ─ Skin tools (OKLCh + vectorscope band)    ← D17
  ─ Vibrance / Saturation (UCS, subtractive) ← r10 recipes
  ─ Color Grading wheels + zones (UCS)       ← D15, Look
  ─ Film Lab / LUT / B&W                     ← D18, D20, Look
  ─ THE display transform (one, AgX-class)   ← docs/04-spec-tone.md, D8
  ─ output encoding + gamut mapping          ← docs/11-spec-output.md
```

Every slider in this doc obeys the Lumen slider contract (docs/12-spec-ux.md, D45) and the one-frame rule
(D43): visible change ≤16.7 ms at preview resolution. All ops here are per-pixel math or 1D/3D LUT lookups;
none threatens that budget. Pipeline-prefix caching (D49) means dragging any Color slider recomputes only
from that stage down.

---

### Color Mixer

**What it is.** The 8-band HSL tool, keeping Lightroom's band names for muscle memory but presented with
DxO ColorWheel's interaction grammar — the best-liked HSL surface in the industry — and computed without
Lightroom's two known artifacts (band seams and luminance-slider desaturation).

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Band selector | Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta | Red | Swatches on a hue ring; LrC-compatible naming |
| Eyedropper | — | — | Click image → selects band and re-centers its core range on the sampled hue |
| Core range handles | 2 inner handles on the hue ring | Band's canonical wedge | Draggable arc bounds; fully visual, no hidden numeric range |
| Feather handles | 2 outer handles | ±15° beyond core | Falloff extent per side, independently draggable |
| Hue | −100 .. +100 | 0 | Rotates band hues toward the adjacent band (max ±45° at ±100) |
| Saturation | −100 .. +100 | 0 | Chroma scale within the band |
| Luminance | −100 .. +100 | 0 | Chroma-preserving lightness move (see below) |
| Uniformity | 0 .. 100 | 0 | Converges hues inside the band toward its mean hue — DxO's signature, no LrC equivalent |
| View toggle | Sliders / Curves | Sliders | Switches to the Hue-Selective Equalizer face (same data, see that entry) |
| TAT (targeted adjustment) | drag on image | — | Per-attribute; Up/Down arrows work while active |

**How it works.** Band membership is a periodic partition of unity over OKLCh hue: raised-cosine weights
per band, wrapping at 360°, modified by the user's core/feather handles, always summing to 1. There are no
wedge edges, so there is nothing to band — LrC needed Process Version 6 (12.4, June 2023) specifically to
patch the banding its windowed-constant band model caused; Lumen's model cannot produce the artifact in the
first place. All three axes evaluate in OKLCh on f32 intermediates. Luminance moves scale OKLab L while
holding C (chroma) constant — the fix for LrC's most-reported Mixer artifact, where darkening a blue sky
visibly desaturates it. Uniformity computes the chroma-weighted mean hue of the band's members and rotates
each member toward it by the slider fraction; it shares one variance-compression kernel with Point Color's
Variance and the Skin tools' Uniformity sliders (three surfaces, one kernel — build it once). Adjustments
are weighted by chroma so near-neutral pixels, whose hue is numerically meaningless noise, are untouched.
Pipeline stage: mid-Color, scene-referred input converted to OKLab for the op and back.

**How it feels.** One panel: hue ring on top with the selected band's arc and four handles, three sliders
plus Uniformity beneath, TAT icons per attribute. The eyedropper is the primary entry: click the thing you
want to change and the right band lights up with its range visible on the ring — no guessing whether
foliage is Green or Yellow (it is both; TAT drags move both proportionally to membership, exactly LrC's
beloved behavior). Holding Alt while dragging any slider shows the affected pixels live; a persistent
"show reach" toggle renders the band's influence map (see the Equalizer entry for the two visualization
modes). Keyboard: bands cycle with `[`/`]`, attribute focus with H/S/L, arrows nudge. Latency: single-pass
per-pixel op, full 16.7 ms budget honored at any preview size.

**Vs. the field.** **Better than Lightroom Classic 15.5** because: visible, draggable range+feather (LrC's
band extents are invisible and fixed), Uniformity (no LrC equivalent anywhere), chroma-preserving luminance
(LrC desaturates), and structurally banding-free (LrC mitigated theirs in PV6 rather than removing the
cause). **Equal to DxO PhotoLab's ColorWheel** on interaction grammar — we adopt it deliberately: eyedropper-
to-band, arc with core+feather handles, Uniformity — and better in reach, since Lumen's Mixer also works
inside any mask (docs/08-spec-masking.md) and shares its data with a full curve view. **Vs. Capture One's
Color Editor Basic tab**: equal on the 8-range model, better on falloff visibility (C1 exposes one global
Smoothness; we expose per-side feather). C1's Advanced-tab pick-anywhere slices are answered by Point Color,
next.

---

### Point Color swatches

**What it is.** Sampled-color editing: click a color, get a swatch with shift/range/refine controls and a
Variance slider — the LrC 15.x feature stack that reviewers called Adobe's biggest color-tooling leap since
Color Grading, reproduced with the falloff made visible by default.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Swatches | up to 8, global; up to 8 per mask | — | Eyedropper with magnified loupe creates one; pin marks the sample point |
| Hue Shift | −60° .. +60° | 0 | Relative to the sampled hue |
| Saturation Shift | −100 .. +100 | 0 | |
| Luminance Shift | −100 .. +100 | 0 | Chroma-preserving, same kernel as the Mixer |
| Range | 0 .. 100 | 50 | Master falloff radius in OKLab distance from the sample |
| Refine: Hue / Sat / Lum Range | 0 .. 100 each | linked to Range | Disclosure; per-axis falloff extents for surgical selections |
| Variance | −100 .. +100 | 0 | Compress (−) or expand (+) color variation around the sample; texture-preserving |
| Visualize Range | toggle | off | Everything outside the selection renders grayscale |
| 2D color field + luminance ramp | direct manipulation | — | Drag the pin in hue/sat space; ramp shows the color across lightness |

**How it works.** Selection weight is a smoothstep falloff over weighted OKLab distance from the sampled
color, with per-axis weights set by the refine ranges (an axis's range at maximum effectively removes that
axis from the distance — the same "value + importance" pairing ART's ΔE2000 mask uses, the most legible
design in the field). Shifts apply in OKLCh under that weight. Variance moves each member pixel's hue and
chroma toward (or away from) the sample proportionally to the slider, deviation measured against a
guided-filter local mean so expansion amplifies real color structure rather than chroma noise; lightness
deviation participates at half weight so evening out a blotchy sky doesn't flatten its luminance texture.
This is the same variance-compression kernel as Mixer Uniformity, parameterized per-swatch. Swatches
compose in creation order; each is a small closed-form op, all eight cost one pass.

**How it feels.** Swatch chips at the top of the Color panel, split-rendered original→adjusted like LrC's,
each deletable and solo-able. The Range slider — the one control LrC users demonstrably found opaque
(Adobe's own forums are full of "what does Range actually do") — always offers Visualize Range one click
away, and Alt-dragging any slider shows affected pixels live. Per-mask Point Color is how skin unification
and sky repair actually get done (AI mask + swatch + Variance, cross-ref docs/08-spec-masking.md).
Keyboard: swatch cycle with `,`/`.`, sliders per the standard contract. Latency: within the one-frame
budget; the guided-filter local mean is computed once per image at preview res and cached.

**Vs. the field.** **Equal to Lightroom Classic 15.5's Point Color including Variance** — this is a
deliberate clone of the most-loved recent LR feature (15.0's Variance was reviewed as "Lightroom's best
new slider") — and **better on legibility**: falloff visible by default, refine ranges surfaced instead of
nested, distance semantics documented. **Better than Capture One's Advanced Color Editor** on the same job:
C1's slices select in hue/sat only and offer one smoothness; Point Color selects in all three axes with
per-axis refine, and C1 has no Variance-class control. **Vs. Resolve**: Resolve's qualifier + Color Warper
reach similar results with more ceremony; the Warper's direct "grab the sky and drag it" idea is on the
long-term list (r10 steal #14) but ships later, if ever — swatches cover the need without the mesh's
banding foot-guns.

---

### Color Grading wheels

**What it is.** Three-way grading wheels (Shadows/Midtones/Highlights) plus Global, with per-wheel
Luminance, Blending and Balance — Lightroom's exact grammar — plus the two things advanced users have
begged Adobe for since v10 (2020): visible, draggable zone pivots, and a real perceptual grading core one
disclosure down.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Wheels: Shadows / Midtones / Highlights / Global | Hue 0–360°, Sat 0–100 per wheel | centered | Rim drag = hue, center-out = saturation; numeric H/S entry behind disclosure triangle |
| Luminance (per wheel) | −100 .. +100 | 0 | |
| Blending | 0 .. 100 | 50 | Zone crossover softness |
| Balance | −100 .. +100 | 0 | Shifts the shadow/highlight reach, LrC semantics |
| Zone pivots | Shadow pivot −6 .. 0 EV; Highlight pivot 0 .. +4 EV (relative to mid-gray) | −2.0 / +1.5 EV | Drawn and draggable on a histogram strip above the wheels |
| Zone falloff (per pivot) | 0 .. 1 | 0.5 | Transition width; Blending scales both |
| Mask preview (per zone) | toggle | off | Checkerboard preview showing the module's output only inside the zone |
| Modifier keys | Cmd = hue-only, Shift = sat-only, Alt = fine | — | LrC-compatible |
| **Advanced disclosure** | | | |
| Hue shift (master) | −180° .. +180° | 0 | Constant luminance+chroma rotation |
| Vibrance (master) | −100 .. +100 | 0 | Low-chroma-prioritized (see Vibrance entry; same core) |
| Chroma × global/shadows/mid/high | −100 .. +100 each | 0 | Linear chroma at constant hue and luminance |
| Saturation × global/shadows/mid/high | −100 .. +100 each | 0 | Perceptual, moves along the CIE saturation direction |
| Brilliance × global/shadows/mid/high | −100 .. +100 each | 0 | Perceptually-scaled exposure-like; soft warning past ±20 (artifact territory, per darktable's own docs) |
| Opponent picker (per wheel) | eyedropper | — | Click a cast; the wheel jumps to its neutralizing opposite |

**How it works.** The zone weights are smooth windows over log2 luminance relative to mid-gray, defined by
the visible pivots and falloffs; Balance translates both pivots, Blending scales both falloffs, so the
simple controls and the advanced pivots are one parameter set viewed two ways. Wheel tints apply as
constant-luminance hue/chroma offsets per zone; Luminance is a per-zone perceptual lightness gain. The
advanced grid is darktable color balance rgb's perceptual core, adopted as the settled best design in the
field (r09): chroma operates scene-linear at constant hue, saturation and brilliance operate in a
UCS-22-class space with Helmholtz–Kohlrausch handling, and soft gamut clipping at constant hue is
permanently on — pushed grades compress gracefully instead of clipping to neon. What Lumen hides from
darktable's surface: the white fulcrum (auto-set from scene white, picker available in the advanced
drawer), the saturation-formula picker (there is one formula), and checkerboard preferences. Zone masks
are computed at module input, so grading a zone never shifts the zone.

**How it feels.** Default view is the LrC 3-Way layout — four small wheels, familiar in the first second —
with the histogram strip and its two pivot handles directly above. Dragging a pivot updates live; the
checkerboard zone preview makes "what counts as shadow" a visible fact instead of forum lore. The advanced
grid unfolds below for the users who want colorist-grade control; it is one disclosure, not a second tool.
Lives in the Look layer by default: grade one frame, apply to 800 (D4). Also available per-mask — local
grading wheels inside masks is a headline capability LrC still lacks in 2026 (D29; docs/08-spec-masking.md
owns the mask side). Keyboard: wheel focus 1–4, arrows nudge hue, Shift+arrows saturation. Per-pixel math;
full one-frame budget.

**Vs. the field.** **Better than Lightroom Classic 15.5** because pivots are visible and adjustable — the
#1 advanced-user complaint about LR's wheels since 2020 — while keeping LrC's exact Blending/Balance/
modifier grammar so nothing is unlearned; and because the advanced grid (chroma/saturation/brilliance ×
four zones) simply has no LR equivalent. **Better than Capture One's Color Balance**: C1's wheels predate
LR's and its crossfades are well-regarded, but it exposes neither Blending/Balance nor pivots; we ship
both. **Vs. Resolve**: equal to the Log wheels' core virtue (clean zone separation via adjustable Low/High
range pivots — Resolve's defaults ≈0.33/0.66 in normalized signal, ours denominated in EV because this is
a scene-referred stills tool); consciously narrower than the full node-graph grading environment, which is
the explicit tradeoff of a fixed-pipeline stills editor (r10's verdict: fixed stages capture ~90% of the
node graph's value at none of its UX cost). Tonal-zone *exposure* work belongs to the Zones panel in
docs/04-spec-tone.md (D7), not these wheels; the two share the pivot UI convention.

---

### Printer Lights

**What it is.** The lab-heritage shot-matching tool: master exposure plus R/G/B (equivalently C/M/Y) trims
in log space, stepped in keyboard "points." The fastest known way to balance exposure and color together
across a set, at near-zero implementation cost. No stills editor has ever shipped it.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Master | −48 .. +48 points | 0 | 12 points = exactly 1 stop |
| Red / Green / Blue trim | −24 .. +24 points each | 0 | Cyan/Magenta/Yellow labels shown on the negative side |
| Point step keys | `,` / `.` master; with R/G/B held, per channel | — | Shift = 4-point coarse step, Alt = quarter-point fine |
| Apply-to-selection | toggle | on when multi-selected | Steps apply to every selected frame |

**How it works.** One point multiplies the channel by 2^(1/12) in scene-linear — a semitone of exposure.
(Resolve's formulation is ×10^(0.025·points/negGamma), heritage of printing through a real negative's
gamma; Lumen fixes the semantics at exactly 2^(points/12) so points are honest twelfth-stops with no hidden
gamma parameter.) Trims are per-channel gains applied immediately after WB/exposure in the linear pipeline;
they compose with everything downstream and cost three multiplies per pixel. Because the steps are
discrete, matching is repeatable and reversible by count: "+3R −2 master" is a communicable, undoable fact,
which is exactly why labs and DI suites never abandoned the model.

**How it feels.** A single compact row in the Develop column, but the real interface is the keyboard:
step points while looking at the image (or at the reference frame in 2-up compare, docs/10-spec-library.md),
with an on-image ghost readout showing the current point offsets — the Speed Edit pattern (D44). Matching
thirty mixed-light reception frames becomes: anchor one frame, select the rest, ride four keys. Latency:
this is the cheapest op in the entire pipeline; budget is irrelevant.

**Vs. the field.** **Better than Lightroom Classic 15.5, Capture One 16.8.4, and DxO PhotoLab** trivially —
none has anything in the category; LR users approximate it with WB+Tint+Exposure sliders that neither step
nor communicate. **Equal to Resolve's printer lights** in math and keyboard-first spirit (we adopt its
design wholesale, minus the negGamma parameter); Resolve remains ahead for moving-image ergonomics
(point steps mapped to grading panels), which is out of scope for a stills tool.

---

### Vibrance & Saturation

**What it is.** Two sliders with the familiar names and the unfamiliar property of being safe to push:
Vibrance is chroma gain prioritizing muted colors with skin protection; Saturation is a subtractive,
density-weighted control — film-print math, not RGB stretching — with saturation compression and
tonal-extreme rolloff built in.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Vibrance | −100 .. +100 | 0 | Low-chroma-weighted, skin-protected |
| Saturation | −100 .. +100 | 0 | Subtractive density model |
| Density (disclosure) | 0 .. 100 | 50 | Blends additive ↔ subtractive behavior of the Saturation slider |
| Protect skin (disclosure) | 0 .. 100 | 70 | Attenuates both sliders inside the skin-tone tolerance band |

**How it works.** Both compute in the UCS-22-style perceptual model (D21) so equal slider moves read as
equal saturation changes and the Helmholtz–Kohlrausch effect doesn't make saturated colors mysteriously
"brighten." Saturation at positive values applies per-channel gamma to chromaticity ratios against a
density-weighted norm (the verified subtractive-saturation recipe from r10 §2.5): color intensifies by
*densifying* — darkening as it saturates, the way stacked dye does — instead of pushing RGB channels apart
toward neon. Two internal 1D curves shape every push: a Sat-vs-Sat compression that soft-clips the top of
the saturation range (already-saturated colors resist further push) and a Lum-vs-Sat rolloff that tapers
saturation at both tonal extremes (no chroma-noise shadows, no neon highlights). These two curves are,
per the colorist consensus, the actual mechanism of "expensive," filmic color — film's apparent richness
is saturation rolloff at the extremes — and they are nearly free (1D LUTs). Vibrance weights its gain
toward low-chroma pixels and multiplies by the skin-protection attenuation, which is the vectorscope
skin-band membership from the Skin tools entry below. Negative Saturation reaches true B&W at −100.

**How it feels.** Two sliders in the Color panel where every LR refugee expects them; the disclosure
exists for the 5% who want to tune the physics. The honest pitch, which the spec commits to demonstrating
in golden tests (docs/14-pipeline.md): +60 Saturation in Lumen looks like a deliberate grade; +60 in LrC
looks like a mistake. Keyboard per the slider contract; single-pass math, full one-frame budget.

**Vs. the field.** **Better than Lightroom Classic 15.5**, whose Saturation is a linear chroma multiplier
with none of the rolloff behavior and whose Vibrance's skin awareness is implicit and untunable.
**Better than Capture One's** single asymmetric Saturation slider (vibrance-like positive / true-desat
negative — a nice design we match) because C1 has no subtractive density model either. **Equal to Resolve**
in mechanism — Sat-vs-Sat, Lum-vs-Sat, and Color Slice's per-vector Density are exactly the tools we
internalized — and better for this audience because Resolve makes you build the rig from three curves and
a palette; Lumen ships it as the default behavior of two sliders.

---

### Skin tools

**What it is.** A dedicated skin toolset as a product pillar for a portraits/events owner: Capture
One-style uniformity sliders that compress variance toward a picked target, a vectorscope skin-tone line
with tolerance band as an objective guardrail, and skin as a protected class in batch operations.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Target picker | eyedropper | — | Pick good skin; loupe + RGB/OKLCh readouts; per-face auto-suggest from the person mask |
| Uniformity: Hue | 0 .. 100 | 0 | Compresses hue variance toward target |
| Uniformity: Saturation | 0 .. 100 | 0 | Same, chroma |
| Uniformity: Lightness | 0 .. 100 | 0 | Same, lightness, texture-preserving |
| Range / Smoothness | 0 .. 100 | 50 | Selection breadth around target + falloff |
| Amount (H/S/L shift) | standard HSL shifts | 0 | Ordinary corrective shifts of the selected range |
| Skin line + band (scope) | band width 0 .. 30° | 10° | Drawn on the vectorscope; readout flags out-of-band samples |
| Protect skin in batch | toggle | on | Global sat/contrast/Look moves hold skin inside the band |

**How it works.** The uniformity sliders are the third face of the shared variance-compression kernel
(Mixer Uniformity, Point Color Variance): per-axis compression of hue/chroma/lightness deviation toward
the picked target within the selected range, deviation measured against a guided-filter local mean so pores
and texture survive while blotch, redness, and uneven makeup converge. The selection is the intersection of
a hue/chroma range around the target and, when available, the AI face-skin/body-skin mask components
(docs/08-spec-masking.md) — qualification by mask means a red brick wall behind the subject is never
"unified." The vectorscope skin line is the legacy −I axis along which all human skin hues cluster
regardless of ethnicity (the hue comes from blood and melanin; luminance varies, hue barely does — Van
Hurkman's literature, adopted as doctrine); the tolerance band renders on the scope and drives the
protected-class behavior: any global or batch operation that would push sampled skin outside the band is
attenuated inside the skin selection, evaluated per-frame during sync so one guardrail covers a whole
wedding. Memory-color doctrine (Hunt: consumer reproduction targets *preferred*, not colorimetric, skin)
shapes the default target suggestions slightly warm of measured.

**How it feels.** A Skin section in the Color panel: pick target, drag Uniformity, done — the C1 wow-moment
("the uniformity sliders are where the real power lies") reproduced with less hunting, because Lumen
auto-suggests the target from detected faces. The same tool deliberately works on skies: pick sky, drag
Uniformity-Hue, polarizer blotch evens out — the famous C1 off-label use, promoted to intended use. The
scope band lives one disclosure away with the other scopes. Latency: guided-filter mean is cached per
image; slider drags are single-pass.

**Vs. the field.** **Better than Lightroom Classic 15.5**, which has no uniformity concept at all — the LR
workflow for the same result is AI skin mask + Point Color + Variance, which Lumen also supports, but the
dedicated tool with target picking, per-axis control, and the scope guardrail is a different class.
**Equal to Capture One's Skin Tone tab** on the core mechanic (three uniformity sliders — the single most
differentiated color feature in C1, adopted deliberately) and **better around it**: C1 has no vectorscope,
no tolerance-band guardrail, no AI face-skin qualification (its AI masking has no person-part
decomposition), and no protected-class batch semantics. **Vs. Resolve**: Resolve gives a skin-tone line
and qualifiers but nothing variance-compressing; its Color Slice skin vector shifts skin, ours normalizes
it. Verdict: better for this job.

---

### Hue-Selective Equalizer

**What it is.** The curve face of the Color Mixer: three periodic curves (hue-vs-hue, hue-vs-saturation,
hue-vs-luminance) over 8 fixed nodes, with guided smoothing and the two visualization toggles that make
selective color trustworthy — darktable's color equalizer design, adopted as the settled artifact-free
architecture for hue-selective editing.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Tab: Hue / Saturation / Luminance | — | Saturation | Three curves over hue, one per attribute |
| 8 nodes | drag / scroll; ±100 vertical | 0 | Fixed, equally spaced hues; Ctrl = slow, Shift = fast, right-click = fine entry |
| Node placement | −22.5° .. +22.5° | 0 | Rotates all nodes together to center a target hue |
| Picker | eyedropper | — | Shows the sampled hue's position on the curve; click-drag pushes the curve there |
| Precision | 0 .. 100 | 50 | One slider folding curve tension + smoothing radius (internals never exposed) |
| Show reach | toggle | off | Influence map: which pixels this curve can touch (chroma weighting rendered blue→red) |
| Show change | toggle | off | Signed change map for the active tab (red = increased, blue = decreased) |
| White level | picker + slider | auto | Upper bound for luminance pushes |

**How it works.** Same parameter set as the Mixer — the 8 bands are the 8 nodes; band range/feather handles
reshape local curve falloff; editing either view edits the other (D3). Curves are periodic splines wrapping
at 360°, which is why Lumen's band edges cannot seam the way LrC's windowed bands do (r10's implementation
note: Resolve's hue curves are periodic; LR's bands are windowed constants, hence the visible seams on
gradients). Corrections are chroma-weighted so near-neutral pixels are untouched — the precise mitigation
for the shimmer that makes naive hue-vs-luminance "the artifact factory" in Resolve practice; with the
weighting plus a light guided-filter spatial smoothing (default on), Lumen ships hue-vs-lum safely instead
of skipping it. Fixed nodes are a considered decision, not a limitation: darktable replaced free-node color
zones with fixed nodes + smoothing specifically because it produces smoother results with fewer artifacts,
and Lumen takes that conclusion rather than re-learning it.

**How it feels.** Toggle from the Mixer's slider face; the curve view is where you see the whole transfer
function at once and where the two visualization toggles live. "Show reach" answers *what can this touch*;
"show change" answers *what did I do* — every selective tool in Lumen aspires to answer both (r09's design
lesson), and this panel is the reference implementation. Middle-click a node for its numeric sliders.
Latency: 1D periodic LUT per tab, evaluated per-pixel in OKLCh; nowhere near the budget.

**Vs. the field.** **Better than Lightroom Classic 15.5's Mixer** for the same reasons as the Mixer entry,
plus a whole capability LrC lacks: LR has no curve view of hue-selective edits at all and no visualization
of reach or change beyond Alt-drag. **Vs. Resolve's curve suite**: equal on the three workhorse curves
(Hue-vs-Hue/Sat/Lum with eyedropper anchoring) with better artifact behavior at the default settings
(chroma weighting and smoothing are always on; Resolve leaves you to discover why your gradient shimmers);
consciously narrower — no Sat-vs-Lum, and Sat-vs-Sat/Lum-vs-Sat exist as internal machinery of the
Saturation slider rather than user curves, because two exposed saturation-curve editors would violate the
one-intent rule for a photographer audience. **Vs. darktable 5.6's color equalizer**: equal by adoption,
minus the leaked internals (hue curve tension, filter radii) folded into one Precision slider.

---

### Primaries

**What it is.** LrC's Calibration panel made honest: R/G/B primary hue and purity plus a shadows tint —
the back-end remap that powers the entire "calibration look" economy — using darktable's rgb primaries
parameterization, which preserves grays by construction.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Red primary: Hue | −100 (→magenta) .. +100 (→yellow) | 0 | |
| Red primary: Purity | −100 .. +100 | 0 | |
| Green primary: Hue | −100 (→cyan) .. +100 (→yellow) | 0 | |
| Green primary: Purity | −100 .. +100 | 0 | |
| Blue primary: Hue | −100 (→magenta) .. +100 (→cyan) | 0 | |
| Blue primary: Purity | −100 .. +100 | 0 | |
| Shadows Tint | −100 (green) .. +100 (magenta) | 0 | Shadow-only cast fix WB can't reach |

**How it works.** Rotating and de/re-purifying the working-space primaries themselves, early in the
pipeline before any hue-selective tool. The crucial property, and why this is not redundant with the
Mixer (LrC's community rediscovers this distinction weekly): the Mixer targets pixels *that look blue*;
Blue Primary affects *every pixel containing blue in its RGB mix* — shifts are global, smooth, and cannot
posterize. The darktable parameterization preserves the achromatic axis and opponent balance, so grays
stay gray at any setting — an actual improvement over LrC's Calibration, where extreme primary moves can
drag neutrals. The canonical idioms transfer directly: orange-teal = Blue Primary Hue −100 + Red Primary
Hue ≈ +50, then tame with Mixer Orange/Aqua saturation; Blue Primary Purity + is the classic "richer
without oversaturated" move.

**How it feels.** Bottom of the Color panel, deliberately quiet — seven sliders, no drama, with a
one-line caption ("redefines what red, green and blue mean for this image") because Adobe's refusal to
explain this panel is why it took YouTube a decade to discover it. Preset-friendly: Primaries settings are
prime Look-layer material and serialize into portable Looks (docs/15-catalog.md).

**Vs. the field.** **Equal to Lightroom Classic 15.5's Calibration** in grammar and idiom compatibility
(deliberate: the calibration-look recipes people know must transfer), **better in math** (gray-axis
preservation, no legacy Process Version baggage — Lumen's pipeline is versioned from day 1, D52).
**Better than Capture One**, which has no user-facing primary remap at all (its answer is fixed ICC
profiles). **Vs. Resolve**: Resolve reaches the same space through log-wheel gain-into-gamut tricks or
the HDR palette's color controls; darktable's parameterization — which sigmoid/AgX also embed as their
primaries sections — is the version sized for a photographer.

---

### Black & White

**What it is.** An 8-band B&W mixer with auto-suggest that never fires silently, per-channel state that
survives treatment toggling (fixing LR's decade-old state-loss bug), and an optional zone-system overlay.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Treatment toggle | Color / B&W | Color | Key: V; both states' settings always preserved |
| 8 band sliders | −100 .. +100 | 0 | Same 8 hues as the Mixer; negative darkens that color's gray rendering |
| Auto | button | — | Suggests a mix maximizing gray-tone separation; applied visibly, undoable, never on by default |
| TAT | drag on image | — | Drag on a gray region; underlying color bands move |
| Zone overlay | toggle | off | False-color Ansel Adams zones 0–X over the image |
| Toning | — | — | Not duplicated here: the Color Grading wheels remain active in B&W and are the toning tool |

**How it works.** Per-hue luminance weighting computed from scene-referred RGB before the display
transform, using the same smooth periodic band model as the Mixer — so aggressive mixes (Blue −80 skies)
darken cleanly instead of banding, the exact failure LrC's PV6 exists to mitigate. Chroma-weighted so
noise in near-neutrals doesn't modulate the gray. The zone overlay quantizes display-referred luminance
into the 11 zones for previsualization (Adams via Silver Efex, the beloved cheap nicety). B&W film
*stocks* — grain character, characteristic curves, filter simulation — are deliberately not here; they are
Film Lab stocks (Tri-X-class ships at launch), because stock emulation and channel mixing are different
intents.

**How it feels.** Hit V, the Mixer panel becomes the B&W panel (same spatial layout, muscle memory intact),
Auto offers a starting mix as a visible suggestion chip. Toggle back to color and nothing is lost — the
LrC bug where B&W and HSL mixes clobber each other on treatment toggle is a decade-old community report we
simply fix. Keyboard: V toggles, bands cycle with `[`/`]`.

**Vs. the field.** **Better than Lightroom Classic 15.5**: state preservation (their long-standing bug),
auto-as-suggestion (LR can silently auto-mix on conversion depending on a buried preference), zone
overlay (LR has nothing). **Consciously worse than Nik Silver Efex** as a total B&W environment — no ~39
named emulations, no per-stock sensitivity curves in this panel, no edge burns — because that depth lives
in Film Lab's B&W stocks and in ordinary local tools; Silver Efex remains the reference for B&W-first
photographers, and Lumen accepts covering the 90% case here. **Better than Capture One's** 6-channel
Color Sensitivity + Split Tones (we have 8 bands, zone overlay, and full grading wheels for toning).

---

### Film Lab

**What it is.** One panel, preset-first (the Film Look Creator product lesson: Blackmagic collapsed a
ten-node grade into one panel with strong presets and it became a headline feature). A physically-grounded
film chain — characteristic curves in density space, subtractive color, halation, density-domain grain,
push/pull — for 8 stocks done deeply, baked to LUTs for interactive speed. This is the panel the entire
LR preset economy cannot build, because presets are display-referred slider stacks and this is a model.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Stock | 8 at launch (below) | none | Large visual preset cards, hover live-preview |
| Strength | 0 .. 100 | 100 | Blend of the whole chain against the neutral rendering |
| Film Exposure | −2 .. +3 EV | 0 | Exposure *into the film curve*, pre-curve; distinct from display brightness by design |
| Push / Pull | −1 .. +2 stops | 0 | Detented at whole stops; couples curve steepening + grain + crossover |
| Halation: Amount | 0 .. 100 | per stock | 0 for slide stocks; high for the 500T "rem-jet removed" variant |
| Halation: Size | 0.5× .. 2× | 1× | 1× = 65 µm first-bounce sigma at the stock's gate width |
| Halation: Redness | 0 .. 100 | per stock | Blends channel strengths toward pure red |
| Grain: Amount | 0 .. 100 | per stock | |
| Grain: Format | 35mm / half-frame / 120 / off | 35mm | Grain size anchors to output print size, not pixels |
| Print stock | per-stock pairing | on for cine stocks | Vision3 stocks pair with 2383; negative stocks with an Endura-class paper curve |

Launch stocks (5–10 deep beats 60 shallow — D18): Portra 400, Portra 160, Ektar 100, Gold 200,
Vision3 250D → 2383, Vision3 500T → 2383 (plus a high-halation variant), Provia 100F, Tri-X 400 (B&W).

**How it works.** The chain follows the verified reference pipeline (r10, code-verified against the
spektrafilm model): per-channel characteristic curves as sigmoids in log-exposure→density space
(D = Dmin + (Dmax−Dmin)·sigmoid(k·(log10 E + offset)), k = γ/(0.25·(Dmax−Dmin)); Dmin ≈ 0.01, Dmax ≈ 4.0,
mid-gray anchored at 0.18), density→transmittance as 10^−D — which makes color inherently subtractive:
saturated colors darken, the "rich" film property. Saturation rolloff at the tonal extremes and top-end
saturation compression are inherent to the curve+density model and reinforced by the internal Lum-vs-Sat /
Sat-vs-Sat machinery shared with the Saturation slider. **Halation** runs on linear light *before* the
curve (this placement is why digital "glow" sliders look wrong), driven by reconstructed highlight energy
(boost range 0.3, protect 4.0 EV): a 3-bounce sum of Gaussians at σ₁·√k spacing with geometric decay 0.5,
per-channel strengths defaulting to the physically measured (0.05, 0.015, 0.0) RGB — red-dominant because
red penetrates to the film base and reflects; the anti-halation layer kills the rest. That constant set is
the exact recipe for the CineStill-style red halo when raised. **Grain** applies in the density domain
during "development": pre-baked tileable unit-variance plates per channel generated offline by a particle
model (particle area 0.2 µm²; per-channel size scale 0.8/1.0/2.0 RGB — the blue-record layer is coarsest,
so grain is chromatically structured, never gray), modulated at apply time by amplitude ∝ √(p(1−p)) where
p = D/Dmax — grain peaks at mid densities and vanishes at Dmin/Dmax, matching real film and nothing like a
constant-σ noise overlay. **Push/Pull** multiplies grain amount and plate scale while steepening the
per-channel gammas with slight divergence (the shipped Portra-800-push profiles in the reference model are
distinct stocks, not a slider — divergent gammas are what create push crossover), and nudges shadows
toward the stock's crossover color: one slider, three coherent consequences, the highest
authenticity-per-slider ratio available. **Film Exposure vs display brightness**: because the curve lives
in log-exposure space, pre-curve EV overexposes *into the stock* — +1.5 EV into Portra produces the pastel
low-saturation airiness film shooters know — while post-curve brightness is just brightness. No preset
pack can express this distinction; it requires the model.

**Bake strategy.** The spectral parts (layer sensitivities vs Bayer response, masking couplers, DIR
inter-layer inhibition — the actual source of film's hue skews and edge micro-contrast; ~10 s per 6 MP
frame on CPU in the reference implementation) never run live. Each stock × print × push combination bakes
offline, at authoring time, into a 65³ 3D LUT over a fixed log-encoded input; at edit time the chain is
LUT + halation blurs + grain plates, comfortably inside the one-frame budget with the halation glow
computed at quarter resolution and upsampled (visually lossless, 4× cheaper). Changing Push swaps to the
adjacent baked LUT and interpolates; the refine lands asynchronously ≤200 ms (D43's approximation rule).

**Pipeline position.** Film Lab is a Look block, and its print stage *is* picture formation: when a stock
is active, the baked negative+print chain occupies the single display-transform slot in place of the
AgX-class curve, inside the same stage — same gamut mapping, same output encoding, same HDR
parameterization (docs/04-spec-tone.md, D8). One transform stage, parameterized; never two tone mappers
in series.

**Licensing.** The reference implementation (spektrafilm) is GPLv3 and its README asserts derivative
status even for software "directly inspired by its methods," while inviting collaboration. Lumen ships no
spektrafilm code and does not port it: the implementation is clean-roomed from the primary literature it
itself cites — Giorgianni & Madden, *Digital Color Management*; Hunt, *The Reproduction of Colour* 6e,
ch. 15 (couplers) — plus manufacturer datasheet digitization done by us. The physical constants quoted
above are measured facts about film, not creative expression, and are used as such. Negotiating a license
or collaboration with the author remains an open option worth pursuing (docs/17-appendix.md ledger).

**How it feels.** One panel in the Look column: stock cards on top (hover = live preview), five sliders
and a disclosure beneath. Default interaction is choose-a-stock, done; the sliders exist for the second
pass. Because it is a Look block, a stock graded onto one frame applies to the whole set with per-frame
film-exposure intact — the 800-frame wedding gets Portra in one gesture (D4). Keyboard: stocks cycle with
Shift+`[`/`]`.

**Vs. the field.** **Better than the entire Lightroom Classic preset/profile ecosystem** (VSCO Film —
discontinued 2019 — Mastin, RNI): a DCP profile is a fixed display-referred rendition that falls apart
±1.5 EV from its calibration point, with zero spatial phenomena — no halation, no density grain (LR's
Grain is constant-amplitude luma noise in screen space), no print stage, no push/pull, no latitude
behavior. Lumen's film mode survives exposure moves because it is a curve in log-exposure space, which is
what film is. **Better than DxO FilmPack 7's** ~80 measured emulations on model depth (FilmPack measures
renditions; it does not model exposure-into-stock, halation, or density-domain grain) while consciously
shipping far fewer stocks. **Vs. Dehancer**: we adopt its best idea — the stage-per-analog-process mental
model and the coupled Push control — at a fraction of its panel length; Dehancer remains more
stock-diverse. **Vs. Filmbox** (the accuracy ceiling, unverified in current detail): its lesson — accuracy
plus few controls beats flexibility plus many — is this panel's founding constraint; parity with a
spectrally-profiled cine emulation is the quality bar for the two Vision3 stocks, verified against side-by-
side stills in the bake-off protocol (docs/14-pipeline.md golden tests).

---

### LUT import

**What it is.** Import of user .cube 3D LUTs as Look blocks, with a defined application space and a
strength control — for the looks people already own.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Import | .cube (17³–65³) | — | Stored in the Look library, referenced by recipes |
| Interpretation | Display (sRGB) / Log | Display | Declares the space the LUT expects; previewed live at import |
| Strength | 0 .. 100 | 100 | Blend against input |

**How it works.** Tetrahedral interpolation, f16 texture, applied at a documented tap: Display-interpreted
LUTs run after the display transform on the SDR-referred image; Log-interpreted LUTs run pre-transform on
a fixed, documented log encoding of the working image. Out-of-range results pass through the always-on
gamut soft-clip, so a sloppy LUT clips gracefully instead of posterizing. LUT output is cached as part of
the Look prefix (D49).

**How it feels.** Drag a .cube onto the Look panel; it becomes a preset card next to the film stocks, with
Strength. Nothing else to learn. The honest caption stays visible: LUTs are baked renditions — they don't
get Film Lab's exposure latitude; for that, use a stock.

**Vs. the field.** **Better than Lightroom Classic 15.5**, which still has no direct user LUT import —
LUTs must be smuggled inside Creative Profiles built with external tooling. **Better than Capture One**,
which has none (ICC styles only). **Equal to darktable's lut3d and DxO PhotoLab's** (PL7+) .cube support.
**Consciously worse than Resolve**, which applies LUTs at arbitrary node positions in arbitrary spaces;
two documented taps cover photographic reality without exporting color management to the user.

---

### Scopes

**What it is.** The colorist's instrument panel for stills: RGB parade, luma waveform, and a vectorscope
with the skin-tone line and tolerance band — one disclosure away in the grading context. Histogram
behavior (including the raw histogram) is owned by docs/04-spec-tone.md (D12). No mainstream stills
editor ships any of these three; every grading text treats them as the way you see past your own adapted
eyes.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| Scope selector | Parade / Waveform / Vectorscope / off | off | One key (`~`) cycles; panel docks under the histogram |
| Vectorscope zoom | 1× / 2× | 1× | 2× for the low-saturation region where photos actually live |
| Skin line + band | toggle, band 0–30° | on, 10° | Shared with the Skin tools' guardrail |
| Readout space | working / output | output | Matches the histogram's selectable readout (D12) |

**How it works.** Compute-shader binning at preview resolution into small textures (parade/waveform:
per-column channel histograms; vectorscope: chroma scatter in the OKLab a/b plane with the skin line
drawn at the traditional I-bar angle). Budget <1 ms per frame at 1080p-class preview on any Apple Silicon
GPU — scopes update live during slider drags, because a scope that lags is a scope you stop trusting.

**How it feels.** Off by default (photographers first meet the histogram), one keystroke away forever. The
parade is the cast-detector — "blacks are blue" is invisible in a histogram and unmissable as one channel's
floor sitting high; the waveform shows *where* in the frame clipping lives; the vectorscope with the band
is how an event set keeps thirty skin tones on one line. The scope teaches: hovering any scope region
highlights the corresponding image pixels. Deferred, deliberately: scope-as-controller (darktable 5.6's
draggable harmony overlays) is a genuinely novel idea noted for later; v1 scopes are read-only. No CIE
chromaticity scope, ever (D22) — it answers questions photographers don't ask.

**Vs. the field.** **Better than Lightroom Classic 15.5, Capture One 16.8.4, and DxO PhotoLab**, none of
which ship a parade, waveform, or vectorscope at all. **Equal to Resolve's core scope trio** in function
(minus CIE, consciously omitted; minus broadcast QC graticules, irrelevant for stills), with a stills-first
addition Resolve lacks: the hover-to-highlight linkage between scope and image.

---

### Color-space policy

**What it is.** The doctrine that makes every entry above behave: which math runs in which space, decided
once, invisible to the user. There is no color-settings panel. That absence is the feature.

**Controls.**
| Control | Range | Default | Notes |
|---|---|---|---|
| (none user-facing) | — | — | Export color space lives in docs/11-spec-output.md; everything else is fixed |

**How it works.** One table, enforced by code review and golden tests:

| Operation class | Space | Reason |
|---|---|---|
| Physical ops (exposure, WB gains, printer lights, blur, halation, resize) | linear Rec.2020 f32 | Light math must be linear (Poynton); working space owned by docs/14-pipeline.md |
| Hue-selective ops (Mixer/Equalizer, Point Color, Skin, B&W weighting) | OKLab / OKLCh | Hue-linear, cheap, well-conditioned; dodges Abney-effect hue skews |
| Saturation-class ops (Vibrance, Saturation, grading chroma/sat/brilliance) | UCS-22-style model | Helmholtz–Kohlrausch handling; equal moves read equal (darktable UCS 2022 is the reference implementation of the idea) |
| Film Lab curves | log-exposure → density | The domain film is defined in |
| Gamut mapping (always on, every path) | hue-preserving soft-clip, ACES-2.0-style compression at constant hue | Pushed grades compress, never twist or clip to neon |

The display transform (docs/04-spec-tone.md) is hue-preserving with controllable preservation and comes
last; no tool in this document ever runs display-referred except the Display-interpreted LUT tap, which is
documented as such. There is no working-space picker, no ProPhoto-vs-sRGB trap, no "saturation formula"
dropdown: darktable exposes all three and its own documentation then warns users about the combinations —
the named anti-pattern (r09 complexity failure #4: one user intent, one control surface, whatever the
pipeline does internally).

**How it feels.** Like nothing. Colors don't twist when tone moves; grades don't clip to neon; no photo
ever renders differently because a hidden dropdown changed. The only place a user meets a color-space
word is export (docs/11-spec-output.md) and soft proofing.

**Vs. the field.** **Better than darktable 5.6**, which has the most correct FOSS color science and leaks
it (working profiles, saturation formulas, cross-module warnings). **Equal to Lightroom Classic 15.5's**
hide-the-plumbing instinct, better documented — Adobe hides the architecture *and* the explanation, which
is how the 15-year Melissa-RGB histogram complaint happened (fixed on our side via D12's selectable
readout). **Vs. Resolve**: consciously less flexible — Resolve's user-configurable color management is
correct for facilities grading mixed camera fleets and wrong for one photographer's tool; Lumen has
exactly one managed path because that is the number of correct paths for this product.

---

## What this document promised, in one table

| Capability | LrC 15.5 | C1 16.8.4 | DxO PL | Resolve | Lumen |
|---|---|---|---|---|---|
| HSL with visible range+feather, Uniformity | ✗ | partial (Smoothness) | ✓ (the origin) | ✗ | ✓ + per-mask + curve face |
| Point Color-class swatches + Variance | ✓ (the origin) | ✗ | ✗ | ✗ | ✓ + visible falloff |
| Grading wheels with visible pivots | ✗ | ✗ | ✗ | ✓ (log wheels) | ✓ + perceptual zone grid |
| Printer lights | ✗ | ✗ | ✗ | ✓ (the origin) | ✓ |
| Subtractive/density saturation | ✗ | ✗ | ✗ | ✓ (Color Slice, curves) | ✓ as the default sliders |
| Skin uniformity + scope guardrail | ✗ | ✓ uniformity only | ✗ | partial | ✓ all three |
| Physically-modeled film (latitude, halation, density grain) | ✗ | ✗ | partial (FilmPack) | plugin territory | ✓ |
| Parade / waveform / vectorscope | ✗ | ✗ | ✗ | ✓ | ✓ |
| Zero color-management surface | ✓ (unexplained) | partial | ✗ | ✗ (expert-facing) | ✓ (documented) |

No single competitor holds more than three columns. That is the argument for this document's existence,
and the roadmap slots for building it live in docs/16-roadmap.md.
