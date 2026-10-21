# WS-05 needs from other lanes

These are causes the WS-05 spec found outside WS-05's owned functions. WS-05 does not edit
them. Each one has a non-regression line in `SPEC.md` that WS-05 must not make worse.

All numbers are on the base commit `84bcd7c`. Paths:
- `$A` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/audit`
- `$S` = `/tmp/claude-0/-home-user-lumen/2f222e11-8f88-5b13-8463-7c67916d787d/scratchpad/spec`

Renders are in `$S/base`. `python3 $S/measure.py <tree> --only <id>` re-measures a line.

---

## WS-07 (tone stage spatial application: guided mask, `logLuminance`, ε)

### N1. The zonal coordinate t ignores the max channel, so Highlights cannot reach a saturated blue sky (F4)

**Where.**
- `ReferenceRenderer.applyTone` builds the mask from `image.luminancePlane(space:)`, which
  is Rec.2020 Y (ReferenceRenderer.swift:234-240).
- `RenderGraph.applyTone` does the same through `logLuminance` (RenderGraph.swift:885,
  helper at :2020).
- `t` is therefore log2(Y / 0.18). A saturated blue has a low Y compared with its blue
  channel, so the tone engine treats it as a midtone while its blue channel is the one
  closest to clipping.

**Evidence.**
- Sky probe (`$S/base/sw/sky/highlights`; `cd $S/base && PYTHONPATH=$A python3 $A/sky_an.py highlights`):
  - rec709_blue at 0 EV luminance, whose B channel is code 247 at +3.4 EV: Highlights -100
    changes it by 0, because `highlightWeight(0) = 0`.
  - azure at +1 EV: B 237 → 232. Highlights -100 removes only 5 codes.
- 983 at exposure +2, sky Y at +0.67 EV and the blue channel at +1.8 EV: Highlights -100
  lowers sky OKLab L by only 0.011 (B 203 → 200).
- 983 at exposure +3 (`--only W6`): 44.5 % of the default-clipped pixels with scene max
  channel between +3.5 and +4 EV are still 255 at Whites -100. Those pixels have Y at
  about +2…+3 EV, which is below where Whites acts. Highlights -100 leaves 0.5 % of them
  clipped, because its shelf starts at 0 EV.

**Proposed fix.** Drive the mask from a norm that sees the max channel. Use the same norm
in both renderers:

- `n = max(Y, k·maxRGB)` with k ≈ 0.5–0.7, or
- `Y^(1-a)·maxRGB^a` with a ≈ 0.3–0.5.

The norm is still a scalar and still exposure-equivariant: scaling the input by 2^E shifts
log n by E. So the mask keeps its exposure-independence, the gain stays a scalar, and S7
stays hue-neutral. WS-05's weights need no change. With this, Highlights -100 becomes the
normal tool for a deep blue sky, as it is in Lightroom, and users stop reaching for Whites,
which has the hue problems in N4 and N6.

**Check.**
- On the sky probe, Highlights -100 on rec709_blue at 0 EV should reach B ≤ 235 (from 247).
- `--only R1,R2,H4,HA1` must not regress.

### N2. Halos at 1-2 EV edges (F6)

**Where.** The guided-filter mask radius is 2 % of the long edge (ReferenceRenderer.swift:237,
RenderGraph.swift:886). ε comes from `toneMaskContrastThresholdEV` = 0.375 EV
(ReferenceRenderer.swift:224). The GPU twin is `guidedSelfFilter` (RenderGraph.swift:2076).

**Evidence.**
- `edges` probe (`--only HA1`; `$A/halo_edges.py`), worst width / peak per control:

  | control | width | peak |
  |---|---|---|
  | Whites +100 | 34 px | 7.6 codes |
  | Shadows +100 | 29 px | 5.3 codes |
  | Highlights -100 | 25 px | 5.0 codes |
  | Shadows -100 | 25 px | 3.9 codes |

- There is no halo at a 9.7 EV step (`--only HA2`).
- Real skylines (`halo_real.py swx`):
  - 4213, Highlights -100: median 35 px, p90 excess 15.9 codes.
  - 1840, Whites +100: p90 excess 36.9 codes.
- Sky holes inside the canopy get the foliage's gain. On 1840 the open sky against the
  sky holes reads -13.6 against -10.2 codes for Highlights -100, and +26.8 against +16.7
  for Whites +100 (AUDIT F6).

**Proposed fix.**
- A two-scale mask: a small-radius guided base (about 0.5 % of the long edge) blended into
  the 2 % base by the local edge confidence `a` of the large-radius filter. Or a second
  guided iteration with ε reduced at the larger radius.
- Make sky holes take the sky's gain by guiding with a downsampled luminance that keeps
  small bright regions.
- WS-05 will keep its shelf slopes at or below today's maxima (the spec checks HA1 within
  +2 px / +0.5 code), so the amplitude does not grow from WS-05's side.

### N3. Texture finer than ε is preserved; texture coarser than ε gets the per-pixel curve (F5 texture, F8)

**Where.** ε = 0.375 EV (ReferenceRenderer.swift:224). Foliage, snow and roof texture
with amplitude above about 0.4 EV is treated as edge, so the mask follows it and the
shelf's slope applies per pixel. That slope is 0.4 stops per stop at the steepest point
of Highlights -100.

**Evidence** (`--only R3`; `$A/recover.py swx`). Highlights -100, local contrast
hp(-100) / hp(0):

| box | hp ratio |
|---|---|
| 983 lantern | 0.672 |
| 983 snow | 0.884 |
| 2545 roof | 0.775 |
| 4213 castle | 0.887 |

Lightroom keeps or raises highlight texture with Highlights -100. Shadows +100 also lost
16-24 % at baseline (`--only S3`). WS-05's reshaped Shadows window is expected to remove
most of that loss, so this need is mainly for Highlights.

**Proposed fix.** Apply the gain to the base layer only and let the detail layer pass
through unscaled, the way a local-Laplacian or a base/detail tone mapper does:
`out = gain(mask) · base + (in - base)` in log space, with the detail term limited near
edges so that halos (N2) do not grow. A plain alternative is to raise ε to about
0.6–0.75 EV. That trades texture for halo width, so it has to be measured against HA1
and HA3.

**Check.**
- R3 ≥ 0.90 on every box.
- HA1 and HA3 do not get worse.

---

## WS-13 (DisplayTransform hue behaviour, finish table)

### N4. Bright saturated blues drift toward violet, magenta and pink in the display transform, and Highlights and Whites slide pixels along that drift (F1, the owner's "funky blue highlights")

**Where** (`DisplayTransform.apply`, DisplayTransform.swift:357-410).

1. **Static rotation.** The inset primary rotation is `rotation = RGB(0.02, -0.03, 0.06)`
   (:62, used at :272). It adds a constant +6…+8° to every blue before any slider moves.
   With rotation off, hue is within 1° of the scene; with it on, it is +6.7°.
2. **Luminance-dependent drift.** The blend weight
   `t·(1 - shoulderU²)` (:396-399) takes `shoulderU` from the **max channel**
   (`peak = inset.maxComponent`, :383). sRGB blue at mid-grey *luminance* has its B
   channel at +3.4 EV, so it is rendered mostly per-channel. Per-channel compression of B,
   with R held by the rotated inset, raises R/B, which reads as violet and then magenta.

**Evidence** (`$A/harness`: `H trajectory`, `H decompose`; `$A/trajectory.txt`,
`$A/decompose.txt`).

At the default recipe, the OKLab hue of sRGB blue (20, 30, 255), scene hue 265.6°, goes
276.9 → 292.8 → 309.3 → 323.2 → 326.3° from -2 to +3 EV. That is a +49° drift, ending
pink (`[245,161,255]` at +2 EV).

Decomposition for sRGB blue:

| path | hue |
|---|---|
| pure max-norm path | 277.7 → 279.2° (stable) |
| blend without rotation | 270 → 310° |
| shipped path | 279 → 326° |

The gamut soft-clip holds hue, so it is not involved.

Slider-induced drift, which is this mechanism seen through WS-05's sliders:

| measurement | command | H-100 | H+100 | W-100 | W+100 |
|---|---|---|---|---|---|
| hue_wheel at exposure +2, \|Δh\| p95 | `--only H3` | 7.5° | 8.4° | 10.3° | 28.8° |
| sky probe, max \|Δh\| | `--only H4` | 9.1° | 3.4° | 14.6° | 9.7° |

The 2545 sky box at exposure +1.5 shifts -19.5° with Whites +100 (`--only H5`).

**Proposed fix.** Make the path to white hue-stable.

- Compute the per-channel result, then re-hue it to the hue of the ratio (max-norm) path
  in a perceptual space (OKLab / IPT), keeping the per-channel lightness and chroma. Or
  measure `shoulderU` on a luminance-weighted norm instead of the raw max channel, so a
  saturated blue at mid luminance is not treated as near-white.
- Revisit the blue rotation (0.06 rad). It is the whole of the static +6.7° offset.

**Acceptance proposal.** On the exact path, the sRGB-blue trajectory from -2 to +3 EV
drifts ≤ 10°, and mid sky has an offset of ≤ 2° against the scene hue.

**WS-05 coupling to note.** `shoulderU = log2(peak/0.18) / whiteAnchorEV`, so the blend
depends on the white anchor. WS-05 is removing or shrinking the Whites anchor move to
pass H1/H2 (F2). If WS-13 makes the blend independent of the live anchor, for example by
normalising by the default 5 EV, WS-05 could later bring back a full anchor move without
hue cost.

### N5. The 33³ finish LUT adds ±3-4° of hue jitter on blues; preview and export disagree (F9)

**Where.** The finish table is baked at the plan's `lutSize`: 33 for preview, 65 for
export (RenderPlan.swift:370-426). Lattice spacing is 0.75 EV per node across 24 EV of
log space.

**Evidence** (`H trajectory`, exact against `referenceColor`):
- mid sky at -1.5 EV: 260.5° exact, 264.6° at 33³.
- mid sky at +3 EV: 260.6° exact, 256.3° at 33³.
- With Highlights -100 at +3 EV, mid sky moves -0.3° exact but +3.3° through the LUT.
- At 65³ the difference is ≤ 1°.

**Proposed fix.** One of:
- 65³ for preview, if the PlanCostProbe budget allows;
- tetrahedral interpolation;
- a denser shaper near the shoulder (+1…+5 EV), where blues bend.

**Acceptance proposal.** \|exact - LUT\| ≤ 1° on the `H trajectory` blues from -2 to
+3 EV.

### N6. Near-white skies swing toward cyan on the way to white (F3)

**Where.** The same per-channel branch as N4. Pale and cyan skies move toward cyan
(per-channel hue 253 → 230°) as they approach white.

**Evidence** (`$A/slider_hue.txt`, `H slider`):

| patch | setting | Δh | chroma |
|---|---|---|---|
| mid sky at +3 EV | Highlights +100 | -28° | 0.049 → 0.005 |
| mid sky at +2 EV | Whites +100 | -23.9° | |
| azure at +2 EV | Whites +100 | -25.5° | |
| cyan sky at +2 EV | Whites +100 | -21.9° | |
| 2545 sky | Whites +100 | -19.5° | 0.076 → 0.016, B clipped on 100 % of the box |

**Proposed fix.** The same as N4: desaturate toward white at constant perceptual hue.
WS-05's part is strength. W2, W4 and W7 move the Whites +100 clip from +2.5 to at least
+3.5 EV, which keeps most real skies out of this region.

### N7. Chromatic pixels clip in one channel at a scene max channel of about +3 EV (information, low priority)

**Evidence.** On 983 at exposure +3, about half of the default-clipped pixels have a scene
max channel of only +2.7…+3.6 EV and Y of +1.4…+3.0 EV. A neutral at that max channel
renders at about code 234-243, but these render 255 in one channel. Whites -100 cannot
unclip them (44.5 % of the +3.5…+4 EV band remains, `--only W6`). Highlights -100 does
unclip them (0.5 % remain), because it lowers Y-driven t from 0 EV up.

**Ask.** Confirm whether this is the intended output-gamut behaviour (display gamut soft
clip after the outset, DisplayTransform.swift:403-410), or a per-channel shoulder artefact
of the same blend as N4. If it is the blend, the N4 fix covers it.
