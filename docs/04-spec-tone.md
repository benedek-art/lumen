# 04 — Tone

The tone system: white balance, the six-slider panel, the Zones panel, contrast/pivot, the display
transform, the tone curve, Auto, and the instrumentation (histogram, clipping, HDR mode) that makes
tonal decisions verifiable instead of guessed.

Scope boundaries: Vibrance/Saturation, color grading wheels, printer lights, and scopes beyond the
histogram belong to `docs/05-spec-color.md`. Texture/Clarity/Dehaze belong to `docs/06-spec-detail.md`.
Pipeline stage order and the working space (linear Rec.2020, f32/fp16, unbounded) are owned by
`docs/14-pipeline.md`. The slider interaction contract (click-anywhere rows, scrubby numbers, typed
arithmetic, arrow nudges, double-click reset, soft/hard limits) is owned by `docs/12-spec-ux.md` and
applies to every control in this document without restating it.

Three commitments govern everything below:

1. **The Lightroom contract where muscle memory lives, a better engine underneath.** The six tone
   sliders keep LrC's names, order, and ranges verbatim (D6). What changes is invisible until you
   push hard: no halos, no hidden white-point games, no faux-HDR flattening.
2. **Scene-referred until the single display transform.** All tone controls operate on linear scene
   light denominated in stops. Exactly one transform maps scene to display (D8). This is why HDR
   editing is a parameter, not a rewrite, and why "recovered" highlights keep color instead of going
   flat gray.
3. **Every automatic move is visible and revertable.** Auto writes real slider values you can read,
   tune, and undo per-slider (D11). Nothing edits state you cannot see — the named anti-pattern is
   Adobe's Adaptive Profile, which corrects "as if the AI had changed the sliders" while the sliders
   sit at zero.

The tone panel stack, top to bottom (UI order — pipeline order is `docs/14-pipeline.md`'s):

```
┌─ HISTOGRAM ──────────────────────────────┐  draggable 5-zone, clipping triangles,
│  ▲ raw-truth toggle, readout space       │  SDR|HDR split in HDR mode
├─ RENDER ─────────────────────────────────┤  the display transform: preset + 2 sliders,
│  Neutral ▾   Contrast · Skew   [⋯]       │  disclosure for hue/primaries/peak
├─ WHITE BALANCE ──────────────────────────┤  As Shot ▾ · Temp (K) · Tint · eyedropper
├─ TONE ──────────────────────── [Auto] ───┤  Exposure / Contrast / Highlights /
│  six sliders, per-slider auto wands      │  Shadows / Whites / Blacks
├─ ZONES ──────────────────────── [⌄] ─────┤  advanced disclosure: 5 zones + Global,
│  stops · wheels · saturation · pivots    │  Resolve-HDR-palette model
├─ CURVE ──────────────────────── [👁] ────┤  parametric · point · R · G · B · Luma
└──────────────────────────────────────────┘
```

Render sits at the top of the stack the way LrC's Profile does, because the display transform *is*
the base look — everything else is judged through it. The Develop/Look split (`docs/00-vision.md`,
D4) places this whole panel in Develop; the Zones panel and Curve are also mountable inside Look
layers and masks (`docs/08-spec-masking.md`).

---

### White Balance

**What it is.** Temperature and tint for raw files in real Kelvin, with presets, an eyedropper with
a magnifying loupe, and a CAT16 chromatic adaptation transform underneath — one control surface, no
matter what the color math does internally (D9).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Temp | 2000–50000 K, log-scaled slider | As Shot | Blue→yellow track gradient; typed entry in K |
| Tint | −150…+150 soft, −300…+300 hard | As Shot | Green→magenta; hard range via typed entry/scrub past end |
| Preset | As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom | As Shot | Any manual move flips to Custom |
| Eyedropper | loupe 5×5 → 17×17 px | 5×5 | `W`; RGB % readouts under loupe; Esc dismisses |
| Advanced (disclosure) | illuminant hue/chroma; blue-LED gamut compression on/off | auto | Only shown when the solve leaves the Planckian/daylight locus |

**How it works.** WB is a CAT16 chromatic adaptation in a dedicated adaptation space, applied at the
head of the linear pipeline on scene-linear data (stage S6 in docs/14-pipeline.md; the decode itself
stays pinned at camera reference so its cache is WB-invariant) — not naive per-channel multipliers
on working RGB. The Temp/Tint
parameterization is a projection onto the Planckian locus plus its orthogonal axis; when a solve
lands far off-locus (stage lighting, deep underwater), the advanced disclosure re-parameterizes to
illuminant hue/chroma, the same auto-switching darktable's color calibration does — but Lumen never
shows two modules. darktable's two-module split (white balance at camera reference + color
calibration doing the real CAT, policed by cross-module warnings) is the named anti-pattern: model
correctness is our problem, not the user's. The eyedropper solves Temp+Tint so the sampled patch
gets R=G=B; the loupe's RGB percentages let you find a patch where channels converge before
clicking, and the tool coaches "pick a light neutral gray, not white" when the sample is within
0.3 EV of clipping. Blue-LED gamut compression (perceptual chroma compression for
UV-contaminated blues) is available behind the disclosure for event work. JPEG/HEIC fall back to
relative ±100 sliders on the same axes, labeled "relative" so nobody files the LR "why is my Temp
slider broken" thread.

**How it feels.** Second block of the tone panel, under Render. `W` activates the eyedropper from
anywhere in Develop; the loupe scales with scroll; a single click applies and (optionally,
toggleable in the tool strip) dismisses. `Cmd+Shift+U` = Auto WB. WB is a raw-stage parameter, so a
drag re-renders the full pipeline — still inside the 16.7 ms preview budget at screen resolution,
because the raw decode is cached and only WB-downstream stages recompute (D49).

**Vs. the field.** **LrC 15.5:** equal on the contract (same 2000–50000 K range, same 9 presets, same
loupe — all deliberate, this is pure muscle memory), better on three documented complaints: Tint's
hard range reaches ±300 (Adobe's +150 ceiling fails underwater shooters — a verified community
request), the eyedropper coaches against clipped samples, and JPEGs get an honest "relative" label.
**darktable 5.6 (best-in-class science):** equal color math — CAT16, off-locus illuminant handling,
blue-LED gamut compression are all adopted — better UX because it is one surface with zero
cross-module warnings. We consciously hide the adaptation-space choice entirely; nobody grading
photos needs to pick Bradford vs CAT16.

---

### The Six-Slider Tone Panel

**What it is.** Lightroom's tone contract verbatim — Exposure, Contrast, Highlights, Shadows,
Whites, Blacks, same names, same order, same ranges — implemented as smooth EV-zone weighting on a
guided-filter luminance mask instead of Adobe's halo-prone decomposition (D6).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Exposure | −5.00…+5.00 EV | 0 | Pure scene-linear gain 2^EV; 0.01 EV precision |
| Contrast | −100…+100 | 0 | Log-space slope around an explicit pivot — see *Contrast + Pivot* |
| Highlights | −100…+100 | 0 | Zone-weighted EV; **never moves the white point** (by construction) |
| Shadows | −100…+100 | 0 | Zone-weighted EV; never moves the black point |
| Whites | −100…+100 | 0 | Owns the white point (which scene EV maps to display white) |
| Blacks | −100…+100 | 0 | Owns the black point |

All six: Alt-drag = threshold clipping view; per-slider auto wand on hover (also
Shift-double-click); double-click = reset; draggable from the histogram's five zones.

**How it works.** Everything operates on linear scene RGB, denominated in stops relative to mid-gray:
`t = log2(max(luma, ε) / 0.18)`.

- **Exposure** is an honest gain: `rgb × 2^EV`. LrC's Exposure is midtone-weighted with baked
  highlight compression because Adobe's pipeline needs the safety net; in Lumen the identical
  "safe" feel falls out of the Render transform's shoulder, which absorbs pushed highlights at
  display time while the scene data stays intact. Same behavior where it counts (the contract at
  display), none of the data destruction.
- **Highlights/Shadows/Whites/Blacks** are one zonal-exposure engine: smooth EV-window weight
  functions over `t`, multiplied into a per-pixel exposure field. The luminance that drives the
  weights is not raw pixel luma but an **edge-aware guided-filter mask** (darktable tone-equalizer
  engineering, eigf — the exposure-independent guided filter, so the mask never needs recomputing
  when Exposure moves). That mask is what makes the sliders spatially adaptive — lifting shadows
  preserves local contrast inside the shadows — while being halo-free by construction: the guided
  filter has no gradient reversal, so there is no bright rim where a dark ridge meets sky. The mask
  is **self-calibrating**: its histogram is continuously auto-normalized across the zone axis, so
  the sliders act at full, independent strength on every image with zero setup. darktable's
  tone equalizer demands a manual two-wand, five-combobox mask calibration before its sliders
  behave; that entire ritual is automated away (its docs' own failure mode #3).
- **Contract semantics, by construction:** Highlights' weight function tapers to zero at the white
  point that Whites defines, so Highlights can never push a pixel past display white — LrC's most
  load-bearing hidden rule, implemented as geometry rather than clamping. Whites shifts which scene
  EV maps to display white (feeding the Render transform's white anchor); Blacks mirrors it at the
  floor. Calibration: ±100 on Highlights/Shadows ≈ ∓2.0 EV of peak zonal gain; ±100 on
  Whites/Blacks ≈ ±1.5 EV of end-point shift — final constants tuned against LrC 15.5 renders of
  the golden corpus so a Lightroom refugee's habitual "−60 Highlights, +35 Shadows" lands within
  visual tolerance of what their hands expect.
- The six sliders compile to fixed weight curves on the same engine the Zones panel exposes freely;
  edits from both surfaces compose by summing their exposure-in-stops fields (see *The Zones
  Panel*). One engine, two registers — never two parallel tools fighting.

**How it feels.** The heart of the panel; identical vertical rhythm to LrC so the hand finds
Shadows without looking. Alt-drag on any of the five range sliders shows the threshold clipping
view (clipped pixels on black for Exposure/Highlights/Whites, on white for Shadows/Blacks; channel
colors r/g/b, cyan=G+B, magenta=R+B, yellow=R+G, solid white/black = all three). Per-slider auto is
a **visible** wand icon at the row's right edge on hover — Adobe shipped this as an undocumented
Shift-double-click for a decade; we keep the gesture and surface the affordance. Each zone of the
histogram is a drag handle for its slider (see *Histogram*). Slider drag → visible change ≤16.7 ms
at preview resolution (the zonal math is per-pixel; the guided-filter mask is cached and reused
across the whole drag). Alt on the section header = Reset Tone.

**Vs. the field.** **LrC 15.5:** equal by design on the contract — names, order, ranges, hidden
interactions (Alt-views, per-slider auto, resets) all cloned, because deviating here costs
Lightroom refugees their hands. Better on the two most-documented LR failures: halos at
dark-edge/sky boundaries (guided filter vs Adobe's decomposition — Adobe's own 2026 mask "Edge"
control is their admission halos persisted into 15.x) and the −100/+100 "faux-HDR" flatness (our
recovered highlights retain hue and micro-contrast because recovery happens scene-referred, before
the display transform, instead of bending display values). **Capture One 16.8.4 (High Dynamic Range
tool):** C1's four sliders (Highlight/Shadow/White/Black) recover cleanly but offer no Exposure/
Contrast integration and no per-slider auto; equal recovery quality is the bar, and we add the
five-zone histogram dragging C1 lacks. **darktable 5.6 tone equalizer (best-in-class engine):**
equal engineering — it is the engine, adopted — better product: zero mask calibration, LR names,
and no 9-slider EV ladder as the entry surface. We consciously drop dt's on-canvas
scroll-to-dodge cursor from the default surface (it collides with the "bare scroll never edits"
rule, D45) — the same gesture lives on as Speed Edit's hold-key form (`docs/12-spec-ux.md`).

---

### The Zones Panel

**What it is.** The advanced tonal surface, one disclosure below the six sliders: five named zones
plus Global, each with Exposure denominated in stops, a color wheel, and Saturation — the model of
Resolve's HDR Grade palette, the best tonal-zone tool shipping anywhere (D7). Zone pivots and
falloff are visible and draggable on the histogram.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Zone pivots: Blacks / Shadows / Mids / Highlights / Whites | −8…+6 EV re mid-gray | −4 / −2 / 0 / +2 / +4 EV | Draggable on the histogram; live zone-window overlay |
| Per-zone Exposure | −4.00…+4.00 EV | 0 | A dial in stops, not an arbitrary 0–100 |
| Per-zone color wheel | hue 0–360°, chroma 0–0.25 | neutral | Hue/chroma shift inside the zone |
| Per-zone Saturation | 0–200% | 100 | Fixes "lifted shadows go gray / pushed highlights go neon" in place |
| Per-zone Falloff | 0…1 | 0.5 | Transition softness at the zone boundary |
| Global | same Exposure/wheel/Saturation | neutral | Unwindowed; composes with everything |

Wire note (docs/15 §15.4): pivots are STORED as normalized positions on the tonal
axis [0,1] (defaults 0.08/0.25/0.5/0.75/0.92); the EV values above are the UI
denomination, mapped through the pipeline's log-luminance→axis function
(docs/14-pipeline.md owns the mapping). Per-zone Saturation stores UI% − 100
(so the sparse default is 0); per-zone Falloff stores 0…1 directly.

**How it works.** Scene-referred, per-pixel, one pass — the implementation recipe (verified against
Resolve-compatible colorist math, digest r10 §3.1):

```
// scene-referred linear in; work in log2 relative to mid-gray
t = log2(max(lum, eps) / 0.18)                  // stops from mid-gray
for each zone z (pivot_z in stops, falloff_z):
    w_z = smooth window over t centered per zone, width from neighboring
          pivots, edge softness = falloff_z      // weights sum ~1 across zones
    rgb *= exp2(exposure_z) ^ w_z                // per-zone exposure in stops
    rgb  = applyWheel(rgb, wheel_z, w_z)         // hue/chroma shift, weighted
    sat  = mix(sat, sat * sat_z, w_z)
```

The luminance driving `t` is the same guided-filter mask the six sliders use, so zone edits inherit
the same edge-aware, halo-free behavior, and the two surfaces are literally the same engine: the
six sliders are preset weight curves over these zones, and edits from both compose by summing
exposure fields in stops. Because zones are defined in stops on scene-referred signal, "Shadows"
means the same thing for every camera and every exposure — and in HDR mode the axis simply extends
above +4 EV with no new concepts (the Whites zone covers speculars; see *HDR Editing Mode*).
Per-zone saturation runs in the perceptual UCS defined in `docs/05-spec-color.md` (D21), with its
always-on soft gamut mapping. Wheel and saturation math is shared with the color grading wheels
(`docs/05-spec-color.md` owns the wheels' full spec; the Zones panel is their tonal-axis sibling).

**How it feels.** Collapsed by default under the Tone section — the simple register never sees it
(D3). Expanded, it renders five wheel-clusters plus Global in a horizontal strip; selecting a zone
highlights its window on the histogram, where the pivot is a draggable handle and falloff is a
drag on the window's shoulder. On-image: hovering with the panel open shows which zone the cursor's
luminance occupies (Adams's "place a tone," as an affordance); dragging vertically on the image
moves that zone's Exposure — TAT grammar, same as the curve. All per-pixel math: any dial or pivot
drag → ≤16.7 ms. Zones is mountable per-mask (`docs/08-spec-masking.md`) — local zonal tone is a
first-class consequence of the architecture, not a special case.

**Vs. the field.** **LrC 15.5:** no equivalent exists. LR's closest tools are the five tone sliders
(fixed, hidden, version-dependent range definitions) and the Color Grading wheels (three luma
ranges with invisible, non-adjustable pivots — the #1 advanced-user complaint). Exposure-in-stops
per zone, visible draggable pivots, and per-zone saturation are all absent from Lightroom in 2026:
better, category-creating for a stills editor. **Resolve 20 HDR Grade palette (best-in-class,
the model):** equal on the core model — zones, stops, wheels, saturation, range+falloff — with two
deliberate differences: five zones + Global instead of Resolve's six (Specular folds into Whites;
stills rarely need a dedicated specular zone at SDR, and HDR mode restores the headroom axis), and
pivots drawn on a photographer's histogram instead of a separate zone graph. The colorist consensus
that photographers round-trip TIFFs into Resolve *specifically for this palette* is the demand
signal; Lumen puts it in the raw editor. **darktable 5.6 tone equalizer:** its 9-EV-slider advanced
tab covers the exposure axis only — no per-zone color or saturation; ours is a superset with less
setup.

---

### Contrast + Pivot

**What it is.** The Contrast slider from the six-pack, with its anchor made explicit: a visible,
adjustable pivot instead of a hidden one (Resolve's Contrast+Pivot primitive).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Contrast | −100…+100 | 0 | Same slider as the Tone panel's; this is its disclosure |
| Pivot | −4.00…+4.00 EV re mid-gray | 0 | Draggable handle on the histogram; auto-picker |
| Pivot auto | — | — | Sets pivot to face-weighted mean luminance (falls back to frame mean) |

**How it works.** In log2 exposure space: `t′ = pivot + (t − pivot) × slope`, with
`slope = 1 + 0.6 × (contrast/100)`, applied at constant hue and chroma, with soft saturation of the
slope's effect beyond ±4 EV from the pivot so extremes compress instead of exploding (the Render
transform's toe and shoulder finish the job). Scene-referred slope-around-a-pivot is the CDL/
colorist primitive; LrC's Contrast is a fixed S-curve whose anchor sits near Lab L≈50 by community
measurement — Adobe has never documented it. An explicit pivot means contrast for a low-key stage
shot pivots on the performer's face, not on a gray the image doesn't contain.

**How it feels.** The Contrast row grows a small disclosure chevron; opening it reveals the Pivot
slider and lights up the pivot handle on the histogram. The face-weighted auto-picker is the wand
on the Pivot row. Drag → ≤16.7 ms; per-pixel math.

**Vs. the field.** **LrC 15.5:** better — same slider feel at default pivot (tuned to match), plus
an explicit anchor LR hides and cannot move. **Resolve 20 (best-in-class):** equal — this is
Resolve's Contrast+Pivot, adopted, with a face-weighted auto-pivot Resolve lacks.

---

### The Display Transform ("Render")

**What it is.** The single transform that turns scene-referred light into a picture: one AgX-class
sigmoid, hue-preserving with a controllable degree, parameterized by display peak so SDR and HDR
are one code path (D8). Its visible face is a preset menu and two sliders. It is the base look —
which is why it sits at the top of the panel, where LrC puts Profile.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Preset | Neutral, Soft, Punchy, Film Base, Linear | Neutral | Named parameter sets of the one transform; Linear = the escape hatch |
| Contrast | 0.1–10.0, log-scaled | 1.5 | Slope at mid-gray |
| Skew | −1…+1 | 0 | Shifts curve emphasis toe↔shoulder; slope at pivot unchanged |
| — disclosure: color — | | | |
| Hue preservation | 0–100% | 100 | 0 = full per-channel skew ("hotter" sunsets/fire), 100 = hue-stable |
| Color mode | per-channel \| RGB ratio | per-channel | RGB ratio = luma-only mapping, fully hue-preserving, flatter |
| — disclosure: primaries — | | | |
| Attenuation (R/G/B) | 0–0.99 each | preset-defined | Inset: purity reduction before the curve |
| Rotation (R/G/B) | ±0.4 rad each | preset-defined | Hue rotation before the curve |
| Purity restore | 0–1 | preset-defined | Post-curve purity recovery |
| Base primaries | working (Rec.2020) \| Display P3 \| Adobe RGB \| sRGB | working | Disclosure-only; honest about what the inset math runs on |
| — disclosure: display — | | | |
| White target | 20–1600% of SDR white | auto from display | The HDR parameterization; driven by EDR headroom in HDR mode |
| Black target | 0–15% | 0.0152 | Display black floor |

**How it works.** A generalized log-logistic sigmoid — the "film + paper" model:
`out = magnitude × (film_response / (paper_exp + film_response))^paper_power` with
`film_response = (film_fog + value)^film_power`; constraints are solved so scene mid-gray (0.1845)
maps to the target display value, scene black to the black target, and the white anchor (set by
Whites) to the white target, with contrast slope independent of skew. Before the curve, the
primaries inset attenuates and rotates R/G/B — the AgX mechanism that buys graceful highlight
desaturation ("path to white") and kills the Notorious Six per-channel hue skews (bright reds
snapping orange, blues going magenta) that plague every naive S-curve, including camera JPEGs and
LR profiles. Hue preservation blends between per-channel character and strict hue-linear mapping.
The white target is the display-peak parameter: at SDR it is 100%; in HDR mode it follows the
viewport's live EDR headroom — same curve, same code, higher anchor (this single decision is what
makes `docs/11-spec-output.md`'s gain-map authoring cheap). The transform is implemented from the
published math (darktable's sigmoid is GPL — clean-room from the equations, which are public).

Reference — the parameter space we adopt is darktable 5.6's sigmoid, source-verified:

| darktable sigmoid parameter | Range | Default |
|---|---|---|
| middle_grey_contrast | 0.1–10.0 | 1.5 |
| contrast_skewness | −1…+1 | 0 |
| display_white_target | 20–1600% | 100 |
| display_black_target | 0–15% | 0.0152 |
| hue_preservation | 0–100% | 100 |
| per-primary inset / rotation / purity | 0–0.99 / ±0.4 rad / 0–1 | profile-dependent |

**The doctrine: never a second transform.** darktable ships four display transforms (base curve,
filmic rgb, sigmoid, AgX), each with documentation warning "never use together with another" — a
museum of its own migrations that every new user must navigate. Lumen ships exactly one, forever.
New rendering ideas become presets or parameters of this transform, or they don't ship. Creative
curves elsewhere in the app (the tone curve below, the Film Lab's characteristic curves in
`docs/05-spec-color.md`) shape the picture within this architecture; none of them maps scene to
display a second time. The **Linear** preset is the escape hatch, always available: a flat
transform (straight scene-to-display scaling, clipped at display white) for round-tripping to
other tools, technical inspection, and "show me the data" honesty — LrC cannot show you a neutral
render at all (Basic cannot be disabled; Adobe's stated rationale is that a raw always needs their
profile + tone mapping — true for their pipeline, false for ours).

**How it feels.** A one-line row for 95% of use: preset menu, Contrast, Skew. The disclosure
chevron opens color, primaries, and display groups in that order. A small curve plot renders the
current transform over the image's log-histogram, with AgX-style inverted-curve warnings (the
offending segment highlights yellow with a tooltip) when extreme skew+contrast combinations
non-monotonize the curve. Parameter changes are a 1D-LUT rebake plus per-pixel math: ≤16.7 ms.
Switching presets live-previews on hover, commits on click.

**Vs. the field.** **LrC 15.5:** better, structurally. LR's rendering transform is baked invisibly
into profiles — Adobe Color carries a warm shift and a contrast bump users can neither inspect nor
edit ("Goodbye Adobe Color" backlash; Amount slider grayed out for Adobe Raw and Camera Matching
profiles is a top forum request Adobe ignores). Lumen's transform is one visible panel with two
sliders and named presets; what it does is never a secret. **darktable 5.6 (best-in-class
implementation):** equal math — its sigmoid parameterization is adopted wholesale, with AgX's
primaries mechanism and curve warnings — better product: one transform instead of four, and no
3-tab mode hidden behind hand-editing a config file. **Blender AgX / ACES 2.0:** acknowledged as
the lineage (AgX's inset-before-sigmoid; ACES 2.0's display-peak-parameterized single transform
family); we consciously skip a separate ACES-style "accurate" JMh rendering path — a second
transform is exactly what D8 forbids, and hue-preservation at 100% covers the accuracy need for
photographic work.

---

### Tone Curve

**What it is.** One curve panel, six curves behind icon toggles: Parametric, Point, R, G, B, and
**Luma** — with luminance-preserving behavior as the default, drag-on-image targeting, and
soft-clipped ends (D10).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Parametric: Highlights / Lights / Darks / Shadows | −100…+100 each | 0 | Smooth, bounded; cannot posterize or invert |
| Region splits | 3 triangles, 10–90% | 25 / 50 / 75% | Draggable; double-click resets |
| Point curve | unlimited points | linear | Click-to-add; right-click delete / Flatten; typed in/out values |
| Coordinate display | % \| absolute 0–255 | % | Right-click toggle |
| Channel curves | R, G, B | linear | For grading: teal shadows, matte fades |
| Luma curve | — | linear | Saturation-stable brightness curve (C1's signature) |
| Chroma boost (legacy) | 0–100 | 0 | 0 = luminance-preserving (default); 100 = legacy RGB chroma amplification |
| Soft clip (per end) | clip point 0–20%, softness 0–100 | 0 / 50 | Cubic shoulder blending into the clip level |
| Panel toggle | eye icon | on | Hold to peek off; Alt-click latches |

**How it works.** The curve evaluates on the display-referred signal after the Render transform —
the domain where a curve behaves the way fifty years of photographic instinct expects (an S on
scene-linear data is a different, less intuitive animal; the scene-side tools above are the ones
that live there). Default point-curve behavior is **luminance-preserving**: the curve remaps a luma
channel and RGB is rescaled at constant ratios, so a midtone lift does not pump saturation — LrC's
"Refine Saturation = 0" semantics, which Adobe ships defaulted to 100 purely as backwards-
compatibility baggage. Lumen has no legacy to protect; the correct behavior is the default and the
legacy chroma amplification is the opt-in (`Chroma boost`). The Luma curve is the same machinery
exposed as its own tab (C1's saturation-stable curve, which LR still lacks as a first-class curve).
Channel curves operate per-channel by definition — that is their job — with the Render transform's
gamut handling downstream keeping extremes in bounds. Soft clip implements Resolve's custom-curve
ends: a per-end clip point plus softness, as a cubic shoulder — a user-adjustable toe/shoulder for
matte-fade looks without stacking fake points near the ends. Parametric regions are bounded splines
over the four ranges with movable splits; they share the zonal weight machinery, and their
region-split triangles are the same handles the histogram zones use. Curves compile to 1D LUTs,
rebaked on change; per-pixel application.

**How it feels.** The curve plots over the image's luminance histogram. **TAT** (target adjustment
tool): activate from the panel's corner icon or `T` while the panel is focused, then drag up/down
directly on the image — the parametric region or placed point under the cursor's luminance moves;
Alt-drag lowers sensitivity; hover + arrow keys nudges without clicking. ART's curve niceties are
adopted: Shift-drag snaps a point to meaningful axes, Ctrl-drag is fine motion, dragging a point
out of the widget deletes it. Curves are available per-mask (`docs/08-spec-masking.md`) — the local
tone curve LR still lacks in 2026. Every gesture: ≤16.7 ms (1D LUT + per-pixel).

**Vs. the field.** **LrC 15.5:** equal on the full contract (parametric + splits, point curve with
typed I/O and absolute values, channel curves, TAT with sensitivity modifier, panel toggle — all
cloned), better on three counts: the Luma curve exists, luminance-preserving is the *default*
rather than a buried slider defaulted backwards, and soft-clipped ends replace point-stacking
hacks. LR's parametric is also global-only inside masks; ours mounts whole. **Capture One 16.8.4
(best-in-class Luma curve):** equal — the Luma curve is C1's idea, adopted with credit — better
ergonomics: C1 has no TAT and no movable parametric splits. **Resolve 20:** soft clip is its
custom-curve feature, adopted; we consciously skip Resolve's six Hue-vs/Sat-vs curves *here* —
they are color tools and live in `docs/05-spec-color.md` where they belong.

---

### Auto

**What it is.** One-click tone that analyzes what you actually framed, weights faces like a
photographer would, writes visible slider values, and learns your taste — plus per-slider auto on
every row (D11).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Auto button | — | — | `Cmd+U`; sets Exposure, Contrast, Highlights, Shadows, Whites, Blacks (Vibrance/Saturation: see `docs/05-spec-color.md`) |
| Per-slider wands | — | — | Visible on row hover; Shift-double-click gesture also kept |
| Personality: Shadows | lift less / default / lift more | default | Persistent preference, applied to every Auto |
| Personality: Contrast | flat / default / punchy | default | |
| Match my edits | on/off | off | v2: personalization from the user's own edit history |

**How it works.** v1 is deterministic scene statistics, not a cloud model: compute the log-luminance
histogram **of the cropped region only** (respecting the active crop is non-negotiable — LR's Auto
analyzes the full original, so a white scan border or a cropped-away dark corner poisons the
result; "make auto tone respect the crop" has been an open Adobe request for years), detect faces
via Vision and weight their luminance 3–5× in the target function (DxO Smart Lighting's
spot-weighted mode is the model here — PL8-era fact, current DxO not re-verified this cycle), then
solve for the six-slider vector that moves the observed zone distribution toward a target
distribution: mid-gray placement from the face-weighted mean, endpoints from a 0.1% clip-tolerance
histogram stretch (Whites/Blacks), and bounded Highlights/Shadows moves with an explicit shadow-
lift ceiling — LR's Auto habitually over-lifts Shadows (users report halving its value); ours caps
the lift and exposes the Personality bias for people who want even less. Per-slider auto: range
sliders use the model's value for that slider alone; Whites/Blacks wands run the endpoint stretch
(the automated Alt-drag-until-clipping technique, matching LR's split semantics). v2 ("Match my
edits") regresses Lumen's own slider vector with a small model personalized per shoot type from
the user's edit history — interpretable, overridable, undoable, and trained on nothing but the
user's own work: PPR10K and FiveK are research-only licenses and will never touch the shipping
model (D53 honesty; the datasets are architecture-prototyping references at most).

**How it feels.** Auto lives in the Tone header; the result is ordinary slider positions — every
value visible, every slider individually revertable (changed rows show a subtle tick; clicking it
reverts that slider). Auto is a discrete action: ≤100 ms budget for the statistics path, computed
on the ~1 MP proxy. Nothing about Auto is modal, and it never touches WB (`Cmd+Shift+U` is Auto WB,
separately, matching LR's split).

**Vs. the field.** **LrC 15.5:** better on every documented Auto complaint: crop-aware (their
most-reported Auto bug), face-weighted (Sensei's results on backlit portraits are the forum staple),
shadow-lift capped with a user bias, and per-slider revert affordances Adobe never surfaced. LR's
Adaptive Profiles hide the correction inside a profile with sliders at zero — the exact opposite of
D11's visible-values rule. **DxO PhotoLab (Smart Lighting, best-in-class face weighting; PL8-era
facts):** equal on face-weighted exposure intelligence; better on transparency — Smart Lighting is
a single intensity slider over an invisible correction, while Lumen writes the actual tone sliders
so you can see and edit what it decided. Consciously worse than none: Lumen ships no
"trained on thousands of professional edits" claim — for one photographer, statistics plus
personalization on their own edits beats a taste model trained on someone else's.

---

### Histogram & Clipping Instrumentation

**What it is.** LrC's beloved interactive histogram — five draggable zones, channel-diagnostic
clipping triangles, overlay toggle — plus the two things Adobe has refused for fifteen years: a
selectable readout space and a true raw histogram (D12).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Zone drag | 5 zones → Blacks / Shadows / Exposure / Highlights / Whites | — | Hover highlights zone + names slider and value; drag edits it |
| Clipping triangles | hover = temporary overlay; click = lock | unlocked | Left = shadow clip (blue overlay), right = highlight clip (red) |
| Overlay toggle | on/off | off | `J` toggles both persistent overlays |
| Readout space | Working (Rec.2020 linear, %) \| sRGB 0–255 \| Output space | sRGB 0–255 | Applies to histogram, cursor readouts, curve coordinates |
| Raw histogram | on/off toggle | off | Pre-development sensor histogram + per-channel clipped %. **Built as a scene-linear reading, not a sensor one** — see the note below and docs/10 §10.5 |
| Capture info line | on/off | on | ISO · focal length · aperture · shutter under the graph |

**How it works.** The histogram bins a ~1 MP proxy of the final rendered output on the GPU
(compute-shader binning, <1 ms), refreshed every frame during drags. Triangle icons are
channel-diagnostic: dark = no clipping, a channel color (r/g/b/c/m/y) = those channels clipping,
white = all three. The **readout space** selector ends the Melissa-RGB era: LR computes Develop
readouts in ProPhoto-primaries/sRGB-curve percentages that match no export space — "RGB values
0–255 please" is a 15-year-old Adobe request. Lumen shows the histogram and all pixel readouts in
the user's choice of working space, sRGB 0–255, or the current export target, labeled explicitly.
The **raw histogram** is computed from the sensor mosaic before development — actual raw clipping
truth with per-channel clipped-percent stats, the FastRawViewer capability folded in; it is the
same instrument that runs at cull time, where it earns its keep on every frame

> **As built, that paragraph describes the target and not the code.** The instrument
> exists and measures the **decoded scene-linear frame**, not the mosaic: Apple's RAW
> API does not expose CFA values and Lumen has no raw reader. It is scene-referred and
> carries the headroom above display white — which is the property this section is
> really about, and which the rendered-proxy histogram above it does not have — but it
> is post-demosaic. The cull-time surface is `⇧H` (docs/10 §10.5); the develop panel's
> corner toggle for it is **not built**. Everything the panel prints is named
> *Scene-linear (post-demosaic)*.

(`docs/10-spec-library.md` owns the cull-time surface and its hold-key shadow-boost/highlight-
inspect overlays). RGB parade, waveform, and the vectorscope live one disclosure away in the
grading context and are owned by `docs/05-spec-color.md` (D22).

**How it feels.** Top of the right rail, always on. Zones light up on hover with the mapped
slider's name and live value; dragging inside a zone scrubs that slider with full 16.7 ms preview.
Triangles: hover to peek, click to lock (locked state shows an outline), `J` for both. The raw
histogram is a toggle on the panel's corner — its render is visually distinct (stepped, per-channel,
no smoothing) so nobody mistakes sensor truth for the rendered picture.

**Vs. the field.** **LrC 15.5:** a strict superset — the draggable zones, triangle diagnostics, and
`J` overlay are cloned outright (features users would riot without), and the readout-space selector
plus raw histogram answer LR's two longest-standing histogram complaints. LR cannot show a raw
histogram at all. **FastRawViewer 2.x (best-in-class raw truth):** equal on the instrument (true
raw histogram, per-channel clipped %), better integrated — FRV is a separate app you run *before*
your editor; Lumen puts the same truth inside the develop loop and the cull loop. **darktable
5.6:** offers histogram/waveform/parade but no draggable zone→slider mapping and no raw histogram;
better here on both.

---

### HDR Editing Mode

**What it is.** Editing with real display headroom: an EDR viewport on capable displays, the Render
transform re-anchored to the display's live peak, and the histogram split into SDR|HDR halves with
stop gridlines — the same tone tools, a longer axis (D42 viewport; output authoring is
`docs/11-spec-output.md`'s).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| HDR editing | on/off per image | on when content headroom > 1.0 and display is EDR-capable | Persisted in the recipe |
| HDR Peak | 0–4 stops above SDR white | min(content, display headroom) | Where the Render white target anchors |
| Visualize HDR ranges | on/off | off | Color-codes stops above SDR white, cyan→magenta, in-image and on histogram |
| SDR proof | hold/toggle | — | Clamps viewport headroom to 1.0; the deliberate-SDR-rendition check |

**How it works.** The viewport is an fp16 extended-linear CAMetalLayer with
`wantsExtendedDynamicRangeContent` on; CAMetalLayer performs no tone mapping (values clamp at
display max), so Lumen's Render transform *is* the tone mapper: its white target follows
`NSScreen`'s current EDR headroom, re-anchoring smoothly (a short slew, never a snap) when headroom
changes — plug in a projector, drag to an SDR display, or watch macOS reclaim headroom, and the
picture re-renders correctly because SDR and HDR were one parameterized code path all along (D8).
Every tone tool in this document already speaks stops on scene-referred data, so nothing above
changes in HDR mode: the Zones axis extends past +4 EV, Whites sets which scene EV hits the HDR
peak, and the sigmoid's shoulder does at 400% white exactly what it did at 100%. The histogram
splits at SDR white — a vertical bar with dashed gridlines at each stop above it; the highlight
triangle goes **yellow** for tones inside the current display's capability and **red** only for
tones beyond it (LR 13.0's excellent convention, adopted). SDR proof clamps the viewport to 1.0×
so the SDR rendition is graded deliberately, never discovered by disappointed clients — the toggle
is the editing-side half of the gain-map story; `docs/11-spec-output.md` owns authoring (ISO
21496-1 HEIC, Ultra HDR JPEG, PQ HEIF), and `docs/13-architecture.md` owns the Metal/EDR plumbing.

**How it feels.** On an XDR display, opening an HDR-capable file just shows headroom — no mode
ceremony; the HDR badge in the histogram corner reports current peak in stops and opens the
controls. SDR proof is a hold-key peek and a latchable toggle. Headroom changes re-render within
one frame at preview resolution; the slew is cosmetic, not computational.

**Vs. the field.** **LrC 15.5:** equal on instrumentation — the SDR|HDR split histogram, stop
gridlines, Visualize HDR Ranges, and yellow/red triangle semantics are LR 13.0's design, cloned
because it is correct — better underneath: LR bolts HDR onto a display-referred pipeline with an
HDR Limit slider; Lumen's single display-peak-parameterized transform means HDR is not a mode of
the engine at all, only of the viewport, and the SDR-proof toggle makes the fallback rendition a
deliberate act. **Capture One 16.8.4:** C1 has no EDR stills editing story; better by existence.
**darktable 5.6 (best-in-class scene-referred discipline):** its sigmoid's 20–1600% white target
proves the parameterization, but dt has no EDR viewport on macOS and no gain-map authoring; better
integrated. This is a headline macOS-native advantage: the OS, the panels, and the APIs are already
HDR-first, and no cross-platform competitor can follow cheaply.

---

## Latency ledger (this doc's budgets, enforced per D43/D47)

| Interaction | Budget | Mechanism |
|---|---|---|
| Any tone slider / wheel / pivot drag | ≤16.7 ms to visible change | Per-pixel math + cached guided-filter mask; 1D-LUT rebakes |
| WB drag (raw-stage param) | ≤16.7 ms at preview res | Cached decode; downstream-only recompute (D49) |
| Auto (statistics path) | ≤100 ms | ~1 MP proxy analysis |
| Histogram/readout refresh | every frame, <1 ms | GPU compute-shader binning on proxy |
| EDR headroom change | ≤1 frame re-render + cosmetic slew | Display-peak is a transform parameter |

Golden-image tests pin every stage in this document (`docs/14-pipeline.md`): the six-slider
LrC-match calibration, the zone compositing math, the Render transform's mid-gray/white/black
anchoring, and the luma-preserving curve all carry fixed-raw, max-ΔE assertions from day one.
