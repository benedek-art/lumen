# WS-41 Vignette: audit (BEFORE)

Branch `quality/ws-41-vignette`, no source changes. Auditor run 2026-10-21.
Owner: "The vignette is mediocre to say the least. It needs customizability."

Everything below lives in `/tmp/claude-0/ws41/audit/` (scripts in `scripts/`, sweep tiles in `tiles/<sweep>/`).
`sw.sh <lfi> <name> <key> <values> [args]` wraps
`lumen-render sweep --long-edge 1024 --as-shot-kelvin/--as-shot-tint/--iso <from sidecar> --out <name>.png --metrics <name>.json --tiles-dir tiles/<name>`.
Synthetic 3:2 frames that I added (`scripts/mkframes.py`, in `frames/`): `flat32` (1536×1024 at 0.18), `skytest` (blue sky at Y≈0.5, a 1.5 white patch, a 4.0 specular, a 0.6 "snow" band), `colour4` (red/blue/green/skin quadrants), `hlbars` (bars at 1…9 scene-linear).
Analysis: `measure.py` (falloff and banding), `chroma.py` (OKLab corner deltas), `corners.py` (100 % corner crops).

## Code under audit (what the control is today)

- Two recipe fields: `look.vignette` (EV at the corner, clamped to −4…+2) and `look.vignetteFeather` (0…100, default 50).
- CPU `DetailEngine.vignette` (DetailEngine.swift:807) and GPU `RG.applyVignette` (RenderGraph.swift:1671) with `KR.vignetteSource` (Kernels.swift:895) compute `gain = 2^(ev · smoothstep(inner, 1, r) · (1 − protect))`:
  - r is normalized per axis so that r = 1 at the four corners. The level sets are ellipses with the frame's aspect ratio.
  - `inner = 0.75·(1 − feather/100)`. The outer edge is pinned at r = 1.
  - `protect = 0.5 · smoothstep(2.88, 5.76, Y)`, with the midpoint and highlight protection hard-wired as constants (`vignetteMidpoint`, `vignetteHighlightProtection`).
- The vignette runs at S13: scene-linear, after S7 tone and S8 presence, before the finish LUT.
- UI (EffectsPanel.swift:116-185) has two sliders, Amount and Feather. No Style, Midpoint, Roundness or Highlights control exists, and there are no recipe keys for them.

## Findings

**F1. Feather is mainly a size/strength control, not a softness control, and Feather 0 is not a hard edge.**
Feather moves the onset radius, and the 50 % point moves with it. Nothing changes the softness on its own. Analytic falloff, identical on 3:2 and 1:1 (`scripts/measure.py`). r is in units of the half-diagonal; "edge-mid" is the share of Amount that reaches the long- and short-edge midpoints.

| feather | inner r | r at 10 % | r at 50 % | 10→90 % width | edge-mid | frame mean | frame ≥50 % | frame ≥90 % |
|---|---|---|---|---|---|---|---|---|
| 0 | 0.750 | 0.799 | 0.875 | 0.152 | **0.000** | 0.041 | 3.3 % | 0.49 % |
| 25 | 0.562 | 0.648 | 0.781 | 0.266 | 0.256 | 0.144 | 10.8 % | 1.52 % |
| 50 | 0.375 | 0.497 | 0.688 | 0.380 | 0.547 | 0.292 | 25.8 % | 3.15 % |
| 75 | 0.188 | 0.347 | 0.594 | 0.494 | 0.704 | 0.435 | 44.6 % | 5.44 % |
| 100 | 0.000 | 0.196 | 0.500 | 0.608 | 0.793 | 0.557 | 60.7 % | 8.46 % |

- At Feather 0 the edge midpoints get **zero** burn. Rendered on flat32 at −3: centre 118, long-edge midpoint 118, short-edge midpoint 118, corner 20. Only four corner blobs are darkened, and the frame edges are not.
- Feather 0 still has a 10→90 % ramp of 0.15 half-diagonals, which is 94 px on a 1024×683 tile and about 550 px on a 6000 px export. A hard-edged vignette cannot be made.
- Feather 100 at −2 darkens the centre third of real photos by 6-7 codes (983 75.1→69.4, 6933 66.2→60.4, 2545 93.8→86.7, 6929 56.0→50.6) and lowers the frame mean by about 27 codes. Feather 0 lowers the frame mean by about 2-3 codes. The tooltip itself states that "Feather is the strength control".
- Only 3.15 % of the frame gets ≥90 % of the stated EV at the default.
- A large-but-hard vignette and a small-but-soft vignette are both unreachable, so this coupling is the core of "needs customizability".
- Sheet: `flat32_fea.png` (`sw.sh frames/flat32.lfi flat32_fea look.vignetteFeather 0,25,50,75,100 --set look.vignette=-3 --no-dither`). Also `flat_grey_fea.png` and `r983_fea.png`. Evidence: `evidence/before_flat32_feather_sweep_ev-3.png`.

**F2. The shape is fixed: always an ellipse through the corners with the crop's aspect ratio. Roundness and Midpoint do not exist.**
- On flat32 at −3/F50 both edge midpoints read 50 (long 50, short 50). The ellipse is aspect-locked, so there is no circle (LR Roundness +100) and no rounded rectangle that follows the frame (LR −100).
- The 50 % point is fixed at r = 0.688 for the default feather. Midpoint is the constant `vignetteMidpoint = 0.5`, which is not in the recipe and has no UI.
- The falloff is a Hermite smoothstep that is flat at both ends: zero slope at r = 1. The burn stops deepening in the last tenth of the radius, so corners read as a soft cloud rather than a darkening edge. Sheets: `flat32_amt.png`, `flat_grey_amt.png`.

**F3. Highlight protection never engages on a real photo. Bright corners (sky, snow, white walls) burn to flat grey.**
- Protection starts at scene Y = 2.88 (mid-grey + 4 stops) and reaches only 50 % at 5.76.
- Max Y over all 25 corpus decodes is ≤ 1.11. **0.0000 % of pixels exceed 2.88 in every file** (inline numpy check over `corpus/lfi/*.lfi`). Sensor white is 1.0, so protection fires only after about +1.5 EV of exposure. In practice it is dead.
- `skytest` at −4 (`sky_amt.png`):

  | region | OKLab L at 0 | OKLab L at −4 | protection |
  |---|---|---|---|
  | "snow" Y = 0.6 | 0.827 | 0.260 | none |
  | white patch Y = 1.5 | 0.942 | 0.447 | none |
  | specular Y = 4.0 | 0.996 | 0.838 | only this one is protected |
  | sky | 0.755 | 0.268 | none (turns dark navy) |

- Real photos:
  - 1569 (GX80) bright sky in the TL corner: code 218 → 137 at −4 and 184 at −2 (`c_r1569_tl.png`).
  - 2545 (GX85) TR sky: L 0.626 → 0.181 at −4 (`c_r2545_tr.png`, `evidence/before_2545_gx85_corner_amount_sweep.png`).
  - 983: the snow in the bottom corners goes grey (`r983_amt.png`).
- This is the "muddy/grey corners" look. LR's Highlight Priority keeps those areas bright, and its Highlights slider adds punch.
- **Code ↔ docs mismatch.** The code comments call the 50 % protection "the documented Highlights-50 disclosure default (docs/06 §12)". LR's Highlights default is **0**, and the slider applies only to negative Amount. Lumen applies the protection to positive amounts as well.

**F4. The protection curve inverts tone for positive amounts and quadruples contrast for negative ones (scene-linear, analytic).**
`out = Y · 2^(a·(1 − 0.5·s(Y)))` over Y ∈ [2.88, 5.76]:
- a = +2: the slope d log out / d log Y reaches **−0.60** at Y = 4.54, so brighter input gives darker output.
- a = −4: the slope reaches **4.20**, a local contrast of ×4.2.
- With today's display shoulder both effects sit above white, so they are invisible on the corpus. `hlbars` at exposure −3 or highlights −100 showed no inversion in 8-bit.
- This becomes live as soon as anyone makes protection reachable, for example by lowering the threshold to fix F3. The Highlights design must be monotone by construction.

**F5. Negative Amount: hue is preserved and C/L is preserved, but corners lose chroma in proportion to L.**
OKLab measured on 16-40 px corner boxes with `chroma.py`, sweep at 0 versus −4/−2:
- `colour4` corners, all four:
  - (C/L)/(C0/L0) = 0.98-1.00 at −4.
  - |Δh| ≤ 1.5° except blue, which shifts +4.1° at −4.
  - Absolute C drops to 0.25-0.28×.
- Real photos (2545 TR sky, 6933 TL/TR foliage, skin_tones BR patch): C/L 1.01-1.07, |Δh| ≤ 3.1°.
- So the burn acts like "exposure in linear through a hue-preserving DRT" and avoids hue shift, which is good.
- At −4, mid-grey corners land at code 10. Shadow clipping rises: 1569 from 0.29 % to 5.47 %, 983 from 0 % to 1.24 %, 2545 from 0 % to 0.61 % (sweep metrics).
- There is no Colour-Priority option (luminance down, chroma held in a perceptual space) and no Paint-Overlay option (blend toward black in display space). The only behaviour is exposure-like.

**F6. Positive Amount washes corners to pastel/white.**
Measured at +2:
- `skytest` sky: C/L × 0.33, L 0.755 → 0.933.
- `skin_tones` top-left patch: C/L × 0.38.
- `colour4` red/blue/skin: C/L × 0.64-0.75.
- 2545 TR sky: C/L × 0.63, code ~240.

Other observations:
- Hard clipping stays small: `skytest` 0.38 %, real photos ≤ 0.001 %. The display shoulder compresses rather than clips.
- Mid-grey corners reach code 207 at +2, so the corners turn milky. That is roughly LR's "lighten toward white".
- There is no style choice between "exposure lift" (this) and "paint white".
- Sheets: `r2545_amt.png`, `skin_tones_amt.png`, `r6929_amt.png` (+2 gives the hazy grey-white corners).

**F7. Crop: the CPU reference ignores the crop, and the GPU path honours it. Every cropped recipe renders differently on the two paths.**
- `DetailEngine.vignette` normalizes on `image.width/height`, the full uncropped source. `ReferenceRenderer` (line 132) passes no geometry.
- `PipelineRenderer.renderReference` (the app's CPU fallback, around line 2977) never applies `applyGeometry`. The fallback's output is not even cropped.
- `lumen-render` has no geometry stage (main.swift header: "geometry … the reference path has no geometry stage, GEO-17"). The crop cannot be tested on Linux today.
- The GPU `applyVignette(…, geometry:)` centres the ellipse on `PipelineRenderer.geometryRects(geo).target.integral` and follows rotation and flip through the orientation matrix. That is correct post-crop behaviour, pinned by the macOS-only `VignetteGeometryContractTests`.
- Analytic CPU-minus-GPU EV difference at −2/F50, over the crop. The CPU column is the EV that CPU puts on the four crop corners; the GPU puts −2.00 on all four.

  | crop (x, y, w, h) | max \|ΔEV\| | mean \|ΔEV\| | CPU EV at the crop's corners |
  |---|---|---|---|
  | contract-test .1, .1, .35×.7 | **1.98** | 0.40 | −1.52 / −0.46 / −1.09 / −0.04 |
  | centred 50 % | 1.83 | 0.58 | −0.21 each |
  | centred 1:1 of a 3:2 frame | 0.98 | 0.25 | −1.71 each, and the shape is a 3:2 ellipse instead of a circle |

- Parity goldens use uncropped frames, so CI does not see this.

**F8. 8-bit banding on the CPU path is clean.**
flat32, horizontal ramp from centre to edge, undithered (`flat32_amt` with `--no-dither`):

| amount | distinct codes | longest flat run | max step |
|---|---|---|---|
| −4 | 82 | 15 px | 1 |
| −1 | 26 | 30 px (at onset) | 1 |
| +2 | 55 | 11 px | 1 |

- The response is monotone at every amount.
- With dither at −3 the longest run is 10 px.
- A contrast-stretched 100 % crop (`stretch_nodither_m3.png`) shows faint 1-code rings, which the dither removes (`stretch_dither_m3.png`).
- The GPU fp16 exponent dither (`encodedFP16QuantumEV`) cannot be checked on Linux. The CPU path has no equivalent, which is fine because it is f64.

**F9. Range and units do not match LR's model.**
- Amount is in EV at the corner: −4…+2, asymmetric. LR uses −100…+100, symmetric.
- −4 EV takes mid-grey corners to code 10, near black. LR −100 Highlight Priority is commonly seen as very dark but not crushed; that is a guess with no reference export here.
- Several things are pinned as tests and must be deliberately re-pinned if the model changes:
  - the "corner number" semantics;
  - the Feather tooltip's "about a twenty-fifth / a third / over half";
  - `VignetteResponseTests` (12 tests);
  - `VignetteFeatherTests` (10 tests);
  - `VignetteGeometryContractTests` (3 tests, macOS).
- `corpus/lightroom/` does not exist, so there are no LR reference exports for comparison.

**F10. Visual verdict on the photos** (all sheets opened, corners cropped at 100 % with `corners.py`). The photos were 6933 and 6929 (A7 IV), 2545 (GX85), 983, 1346, 2348, 1569 and 2242.
- −1…−2 at F50 looks like a decent lens-falloff vignette on foliage (6933, 6929).
- Anything stronger reads as a grey-black haze on the corners: dark navy skies, grey snow and walls.
- Feather cannot widen the darkening without also darkening the subject.
- Positive amounts look foggy.
- No banding and no hue shifts were seen.

## What Lightroom does (Post-Crop Vignetting)

| control | range / default | documented (source) | commonly observed (not in docs) | Lumen today |
|---|---|---|---|---|
| Style | Highlight Priority / Color Priority / Paint Overlay; default HP | HP "enables highlight recovery but can lead to color shifts in darkened areas"; CP "minimizes color shifts … cannot perform highlight recovery"; both "behave more like a traditional exposure burn" [1]. Paint Overlay "similar to an overlay of black or white paint … can create slightly muddy looking edges", "adding the same amount of density" [1]; ACR: "blends original image colors with black or white … can reduce highlight contrast" [2] | HP is roughly exposure in linear light plus highlight recovery. CP is a luminance-only scale with chroma kept in a perceptual space. PO is a display-space mix toward black or white with a flat look | exposure-like only (between HP and CP); no style |
| Amount | −100…+100, 0 | "darkening/lightening of the vignette area" [1]; "positive values lighten the corners, negative values darken them" [2] | +100 lightens toward white | −4…+2 EV at the corner |
| Midpoint | 0…100, 50 | "reposition the vignette inwards towards the center or outwards towards the edge" [1]; "higher values restrict the adjustment to the area closer to the corners" [2] | moves the 50 % contour; 0 reaches near the centre | fixed constant, coupled into Feather |
| Roundness | −100…+100, 0 | "shape the vignette (from rectangular to elliptical)" [1]; "positive values make the effect more circular; negative values make it more oval" [2] | −100 is a rounded rectangle hugging the crop edges, 0 an ellipse with the crop's aspect, +100 a circle | fixed crop-aspect ellipse |
| Feather | 0…100, 50 | "soften the edge of the vignette" [1]; "higher values increase the softening …" [2] | 0 gives a hard edge; the size stays put | changes size and strength; 0 is still soft |
| Highlights | 0…100, 0 | only with HP or CP, "and only when Amount is negative"; "degree of highlight 'punch' in bright areas … streetlight" [2]; unavailable for Paint Overlay [3] | restores clipped and bright areas inside the burn | hidden constant 50 % above Y 2.88; never fires on real raws |
| crop | n/a | "applied after cropping", updates with the crop [1] | follows straighten as well | GPU yes; CPU reference and lumen-render no |

Sources:
1. Julieanne Kost (Adobe), Adding Vignette and Grain Effects in Lightroom Classic, https://jkost.com/blog/2024/08/adding-vignette-and-grain-effects-in-lightroom-classic.html
2. Adobe Camera Raw help, Vignette, grain, and dehaze effects, https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/tone-and-color/vignette-grain-effects-camera-raw.html. WebFetch and curl get 403; quotes are from search-engine extracts of this page and its regional mirrors.
3. Digital Photography School, https://digital-photography-school.com/?p=163176
4. Also: https://thedigitalstory.com/2010/10/post-crop-vignetting.html (ACR 6.1 walkthrough).

The ranges and defaults in the second column come from the LR/ACR UI. The helpx text I could reach does not list them numerically. The "commonly observed" column is general practitioner knowledge, not verified against an LR render here.

Physics and colour science, for the spec:
- **Highlight Priority** should be a multiply in scene-linear light, which is what Lumen does. Values that would clip should be protected or recovered, through a monotone, shoulder-style compression rather than the current band-limited blend (F3/F4).
- **Color Priority** should scale lightness only, holding OKLab hue and C/L or chroma, so that dark corners do not lose saturation.
- **Paint Overlay** is `mix(display, black|white, k·falloff)` in display space. It reduces contrast by design ("flat look").
- In LR, a positive Amount lightens toward white.

## Gap list (for SPEC)

1. Add Style (HP/CP/PO), Midpoint, Roundness and Highlights recipe keys via WS-58. The defaults must be an exact identity of today's render: Amount 0 is a no-op whatever the other fields are.
2. Decouple Feather (edge softness) from Midpoint (size). Feather 0 must be a hard edge. Midpoint must move the 50 % contour without changing the softness (F1).
3. Roundness −100…+100: rounded rectangle → crop-aspect ellipse → circle (F2). Rethink the corner-pinned normalization: with Midpoint, the corner need not be the only place that reaches the full Amount.
4. Highlights must actually fire on real raws, where bright content sits at Y ≤ 1: a recovery threshold relative to display white or to the input's white. It must be monotone in Y for every Amount (F3, F4), apply only for Amount < 0 and the HP/CP styles, and have default 0. Today's always-on 50 % must be replaced or exposed.
5. Color Priority: hold OKLab chroma or C/L and hue in burned corners. Paint Overlay: display-space mix (F5, F6).
6. Positive Amount must have a controlled lift. Decide exposure-lift versus paint-toward-white per style, and measure C/L at +max (F6).
7. Map Amount to −100…+100. Pick the EV at −100 from a photographer's view rather than code 10 on mid-grey (F9).
8. **Fix the CPU/GPU crop mismatch.** `DetailEngine.vignette` must take the crop or target rectangle (and orientation) the way `RG.applyVignette` does. `lumen-render` needs crop support so this can be measured on Linux. This is GEO-17 territory, so put it in NEEDS.md if it is outside WS-41's functions (F7).
9. Update the tooltips and re-pin `VignetteResponseTests` and `VignetteFeatherTests`. Keep the GPU-parity and banding goldens green. Add a cropped CPU↔GPU parity case.
