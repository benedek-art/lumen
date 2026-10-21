# WS-08 Zones register: audit

Auditor pass, branch `quality/ws-02-08-pickers-zones`. No source changes. All renders are
CPU-reference (`lumen-render`, release build). Scratch files are in `/tmp/claude-0/ws08`
(not committed). Evidence PNGs are in `evidence/`.

## Where zones run

- **Maths.** `ToneEngine.zonePanelStops(t)` = `ZoneWeights.exposureStops(normalizedAxis(t), pivots, ev[5], global)`.
  It is summed into `stops(at:)` with the zonal Highlights/Shadows/Whites/Blacks solve (WS-05) and contrast (WS-06).
  `clampedResponse` (WS-07) bakes that sum into a 1024-sample gain LUT on the LumenLog
  domain (−12…+12 EV), with a forward running-max clamp.
- **CPU.** `ReferenceRenderer.applyTone` uses an exposure-independent guided filter on log luminance,
  radius 2 % of the long edge, then multiplies RGB by `toneGainLUT(mask)`. This is stage S7.
- **GPU.** `RenderGraph.applyTone` uses the same mask, then `plan.toneGainCubeBaked`, a **32³ cube
  (interactive) or a 65³ cube (export)** sampled from the same LUT, times `toneGainScale`. The GPU has no
  zone-specific code. Parity with the CPU depends on the cube resolution (Z-6).
- **Owners.** The RP S7 block, `RR/RG.applyTone`, the cube and `clampedResponse`/`zoneFlattening` belong to
  **WS-07**. The stage order belongs to WS-01. WS-08 owns only `normalizedAxis`, `zonePanelStops`,
  `ZoneWeights`, the structs, the panel and `AppliedReadout.zoneFlattening`.
- `ZoneWeights.crossfade` is also called by `GradeEngine.ZoneWindows` (WS-35), `CurveStack`
  (WS-10/11), `CurveEditorView` and `ColorEngine`. **Changing the kernel changes four other lanes'
  pictures**, so a zone fix belongs in `zonePanelStops`, not in `ZoneWeights`.

## Method

- **Ramp.** `corpus/synthetic/grey_ramp.lfi` rendered at its native 2800 px (200 px/EV, −10…+4 EV).
  The 200 continuous rows are averaged per column. Because the 8×8 dither is on, the average gives sub-code
  precision. I took the derivative after a 0.1 EV box smooth. Script: `/tmp/claude-0/ws08/scripts/ramp.py`.
- **Analytic probe.** A scratch package (`/tmp/claude-0/ws08/probe`, depends on LumenCore by
  path) prints `t + stops(t)` (requested) and the LUT-rendered response per 0.01 EV, plus
  `zoneFlattening()`. Usage: `probe/.build/release/probe dark=3 mid=-3 [p2=0.52 whites=100 …]`.
- **Real photos.** I swept `dark/mid/bright.ev` over −3,−1.5,0,1.5,3 at long edge 512 on 7 frames:
  6929 and 6933 (A7 IV), 2545 (GX85), 1569 (GX80), 4694 (R5), 983 (5D IV) and 1840 (D850).
  I also took 100 % crops at long edge 1600 of R5 and GX85. Other synthetic frames: colorchecker, hard_edge.

## Findings

### Z-1 (HIGH): the response inverts at about a third of the slider travel. The clamp then posterizes whole EV bands.
Adjacent zones are 2 EV apart, and a raised-cosine crossfade between them has a peak slope of π/2 × average.
The response slope is `1 − Δev·π/(2·gap)`. It reaches 0 at **Δev = 4/π = 1.27 EV**, but the
sliders run ±3 (hard limit ±5). Measured by the probe (`req slope min` / rendered flat span):

| recipe | requested slope min | flattened band (zoneFlattening) | rendered slope < 0.05 |
|---|---|---|---|
| Darks +1.0 | +0.21 | none | 0 |
| Darks +1.25 | **+0.02** | **none (no caption)** | 0.32 EV |
| Darks +1.5 | −0.18 | −3.32…−2.29 EV | 1.11 EV |
| Darks +3 | −1.36 | −3.70…−0.88 EV, worst 1.27 EV | 2.85 EV |
| Shadows/Mid/Lights ±3, Brights −3 | −1.36 | 2.3–2.9 EV each | 2.28–2.86 EV |
| Darks +3 & Mid −3 | −1.36 | −3.70…+0.88 EV, worst 2.27 EV | **4.61 EV** |

The direction that does not invert (Darks −, Brights +, Global) is clean.

On the ramp through the full pipeline, **Darks +3 renders input −3.75…−0.85 EV as code 77.0 ± 0.5**:
about 2.9 EV, from deep shadow to just below mid-grey, become one grey (`evidence/ramp-transfer-plateaus.png`;
orange is hidden under red below 0 EV, and default is hidden under green). Inside the band the output is not even
monotone. Because the mask is not the pixel, codes go 77.6 → 76.6 → 77.4 (pipeline slope ratio
down to −0.29). Each band edge is a C0 slope break (slope 1 → 0), which is a visible seam.

On the R5 (4694) frame, Darks +3 wipes out lemon-peel and potato texture and leaves flat patches outlined by
the guided-mask edge (`evidence/r5-darks-0-1.25-3-crop100.png`: 0 / +1.25 / +3; `evidence/r5-4694-darks-sweep.png`).
Mid +3 on the GX85 (2545) washes the lawn to one tone (`evidence/gx85-2545-midtones-sweep.png`).

**Fix (inside `zonePanelStops`).**
- Build the zone response monotone by construction instead of relying on WS-07's clamp.
- Use output knots `(p_i, p_i + ev_i)` with unit-slope shelves outside p0 and p4, and a monotone Hermite
  (Fritsch–Carlson) between them. This raises the no-ease limit from 1.27 to `gap·(1 − s_min)` (1.5 EV at s_min 0.25).
- Beyond that limit, ease the offending EV as `solveZonalLimits` does for the six sliders. Report requested vs
  applied through `AppliedReadout` instead of "flattened".
- Do not change `ZoneWeights` (shared).
- Spec targets:
  - rendered slope ≥ 0.25 everywhere for every zone at ±3 and the 5-zone ±3 corner combinations;
  - |requested − applied| ≤ 0.05 EV at each pivot when |Δev| ≤ 1.2;
  - `zoneFlattening()` nil for all of them.

### Z-2 (HIGH): Brights is inert on real photos, and the default pivots spend 2 of 5 zones on the outer 4 % of the display.
The defaults are −4/−2/0/+2/+4 EV scene (Adams I/III/V/VII/IX, as docs/04 specifies). Through the default
display transform they land at sRGB codes **10 / 42 / 118 / 208 / ~250**.
- Raw frames clip at 1.0, which is +2.47 EV. The 99.9th percentile of scene luminance on the 7 frames is +1.0…+2.5 EV, and
  0–2.3 % of pixels are above +2 EV, where the Brights weight starts.
- Result: **Brights ±3 gives mean ΔE2000 ≤ 0.0002 (max 0.96) on 7/7 real frames**
  (`/tmp/claude-0/ws08/real/*_bright.json`; `evidence/a7iv-6929-brights-sweep-dead.png`: five identical tiles).
- Darks ±3 is only 0.3–0.6 mean ΔE at ±1.5 on the A7 IV and GX85 frames.
- Lightroom splits its regions at 25/50/75 % display. darktable's tone equalizer puts 9 bands at 1 EV steps from −8 to 0 EV
  *relative to white*. It also has mask exposure/contrast compensation, with a wand that fits the mask histogram
  under the bands.

**Fix.**
- (a) Move the default pivots to display-meaningful places. Codes ≈ 20/50/118/190/235 are at
  **−3.1 / −1.7 / 0 / +1.5 / +3.0 EV**. This only works together with Z-1, because uneven gaps lower the inversion limit.
- (b) Or add an "auto-fit to histogram" action, as darktable does.
- `Zones.defaultPivots` is what decoding falls back to when no pivots are stored, so changing it moves
  existing recipes. It needs a recipe-version migration (WS-58).

### Z-3 (MEDIUM): zone positions move when Basic Whites/Blacks move.
`normalizedAxis` divides by the **live** anchors. With Mid +1, the zone peak moves:

| Basic slider | Midtones peak |
|---|---|
| none | 0.00 EV |
| Whites +100 | **−0.96 EV** |
| Whites −100 | +0.96 EV |
| Blacks +100 | −0.54 EV |
| Blacks −100 | +0.54 EV |

The 2 EV gaps also scale to 1.79 or 2.21 EV. Setting a white point therefore re-targets a finished zone set. This
contradicts docs/04 ("defined in stops … means the same thing for every camera").

**Fix.** `zonePanelStops` (and the strip and readout x-mapping) should use the default anchors.
GradeEngine's own `normalizedAxis` has the same coupling. That is WS-35's call; note it there.

### Z-4 (MEDIUM): ordering is enforced, but pivots can collapse to 0.28 EV.
- `movePivot` clamps each pivot to its neighbours ± 0.02, and `Zones.decodedPivots` sorts and repairs. Pivots can
  never cross, and they cannot coincide (there is no divide by zero).
- But 0.02 of the axis is 0.28 EV. At that gap the inversion limit is 0.18 EV:
  - `p2=0.52, mid=+1` gives a slope of **6.6×** (contrast and noise amplified);
  - `mid=−1` flattens 0.9 EV.
- End pivots reach 0 or 1 (−9 or +5 EV). Darks +3 with p0=0, p1=0.02 flattens 2.96 EV.

**Fix.** Set `minimumGap`/`minimumPivotGap` to ≥ 1 EV (≈ 0.07). Keep both in step with the decode repair.

### Z-5 (LOW / PASS): identity, partition, smoothness away from the clamp, hue, halos.
- **Identity.** With all EVs 0, `isIdentity` is true and S7 is skipped. Moving only the pivots also leaves the picture unchanged. Exact.
- **Partition of unity.** `w` and `1 − w` over exactly two zones, by construction. The crossfade is C1: zero slope at
  each pivot. The second derivative jumps at pivots by `ev·π²/(2·gap²)` (1.2 /EV² at 1 EV), which is invisible next to Z-1.
- **Hue.** S7 is a per-pixel RGB gain, so chromaticity is preserved inside the stage. The ColorChecker OKLab hue change is
  max 4.2° / mean 1.1° (Mid +1.5) and 3.1° / 1.35° (Mid −1.5). Exposure ±1.5 gives 9.4° / 2.7°. The residual comes
  from the display transform (WS-13), not from zones.
- **Halos.** None found. On `hard_edge` with Darks +3, the −5 EV field next to a +4.5 EV disk reads 36.5 codes at 2, 8, 32 and
  150 px from the edge. On the GX85 tree/sky edge at 100 % with Mid +2 / Lights −3 there is no visible halo. The mask is an
  exposure-independent guided filter at 2 % radius, close to darktable's EIGF default (5 %).

### Z-6 (MEDIUM, owner WS-07): the GPU cube is too coarse for zone curves.
The cube has 32 knots over 24 EV (0.77 EV per knot) and interpolates linearly along the grey diagonal.
Estimated analytically, max |GPU − CPU| in EV inside −9…+5 EV:

| recipe | 32 knots (interactive) | 65 knots (export) |
|---|---|---|
| Mid +1 | 0.09 | 0.02 |
| Darks +3 | 0.19 | 0.08 |
| Mid −3 | **0.54** | 0.28 |
| Darks +3 & Mid −3 | 0.57 | 0.29 |
| six sliders alone (Highlights −100, Shadows +100) | ≤ 0.036 | — |

Script: `/tmp/claude-0/ws08/scripts/cube.py`. This is an estimate, not a GPU measurement: there is no macOS here.
No `LumenPipelineTests` parity test uses a zones recipe.

**NEEDS WS-07.** Use a 1D gain texture, or ≥ 256 samples along grey, and add a zones parity golden.

### Z-7 (MEDIUM): wheel, sat and falloff are dead.
**What reads them.** `zonePanelStops` and `zonePanelIsIdentity` read `.ev` only. A grep of LumenCore and
LumenPipeline finds no other reader of `.sat`, `.wheel` or `.falloff` on any zone.

**Renders.** I rendered `mid.sat=100, mid.wheel=(0.5,−0.5), shadow.sat=−100, light.wheel.0=−1, global.sat=100,
dark.falloff=0, bright.falloff=1`. The output is **byte-identical** (`cmp`) to default on both grey_ramp and
colorchecker (`/tmp/claude-0/ws08/{ramp/dead.png, syn/cc_dead.png}`).

**UI.** The panel does not show them (header comment, ZonesPanel.swift:13-19). But they are still live in four places:
- `lumen-render keys`: `RecipeKeys.swift:254-256` lists them with ranges.
- The S7 cache key: `ToneKeyInputs(tone, zones)` holds all of `Zones`, so a sat edit re-bakes the cube for nothing. This
  contradicts the panel comment that they do "not even force a re-render".
- `WorkspaceModification` (line 65, `develop.zones != Zones()`): a recipe carrying only a dead sat shows Tone as modified.
- Canonical JSON and the fingerprint: by construction the fingerprint changes, so caches are invalidated.

docs/04 §Zones still promises all three.

**Recommendation: remove them from the live surface. Do not implement them.**
1. *Duplication.* Colour Grading already does colour by tonal range on the same
   `normalizedAxis` and the same `ZoneWeights` kernel:
   - `look.wheels.{shadows,mid,high,global}` hue/sat/lum, with pivots, blending and balance;
   - the advanced `colorBalance` chroma/saturation/brilliance per shadows/mid/high.
   This covers docs/04's own use case ("lifted shadows go grey"). A second tint/sat in S7 would compose with S10
   in an order the user cannot see.
2. *Cost and ownership.* S7 is a scalar gain from a 1D mask. Wheel and sat need a per-pixel chroma op in UCS, so
   S7 would have to become a colour stage on CPU and GPU, with new kernels, parity goldens and a new cube. That means the RP S7
   block and `RR/RG.applyTone` (WS-07), the kernel registry (WS-58) and possibly the chain (WS-01). WS-08
   owns none of these.
3. *Falloff conflicts with the model.* The crossfade is a two-zone partition with no free width. A per-zone
   softness needs 3+ overlapping, renormalised weights, and the strip would stop reading as "one pivot = one
   centre". Its only real benefit is more room before flattening, and Z-1 fixes that directly.

**How to remove them safely.**
- Keep `ZoneAdjust.init(from:)` tolerant, using `decodeIfPresent` as now. Keep round-tripping any non-default stored values
  untouched so no file loses data, and mark the fields legacy.
- Exclude them from `ToneKeyInputs` (WS-07/01) and from `WorkspaceModification` (WS-58).
- Drop them from `RecipeKeys` (lumen-render, WS-58).
- docs/04 needs an update, which is outside this lane's folder: flag it to the integrator.
- Add a decode test: an old recipe with `sat/wheel/falloff` decodes, renders identically and re-encodes losslessly.

### Z-8 (MEDIUM): no UI snapshot shows the Zones panel.
In the baseline set `claude-inspiring-dirac-ulgpch/a93efb2/`, `panel-develop-tone-zones-open.png` shows the
fold **closed**. `index.md` notes: `could not find "Zones" to open it`. The Noise Reduction fold fails the same way, so the
harness click is at fault. `column-develop-all-open`, `column-develop-tone-open` and both `window-*-develop` show Zones
closed. The panel's layout cannot be judged from any PNG.

**Fix (append-only, inside the lane).** In `PanelSnapshotTests` render `ZonesPanel()` directly, with its own header and no fold,
in three states:
- default;
- Darks +3, so the flattened band and caption appear;
- moved pivots.

`zonesExpanded` is private `@State` in `BasicPanel` (WS-05). Making it injectable is WS-05's call.

### Z-9 (MEDIUM): panel design, judged from code (ZonesPanel.swift), because no PNG exists.
- **Strip axis.** The strip is 46 pt tall and linear in the normalized axis (−9…+5 EV).
  - 36 % of its width lies left of the Darks pivot, which is display codes 0–10.
  - It has no EV ticks, no mid-grey mark and no histogram behind it. docs/04 says the pivots sit on the histogram, but
    `HistogramView` uses its own pivots (`HistogramView.swift:349`).
- **Pivot readout.** The handles are 3 pt capsules. A pivot's position is shown nowhere except a VoiceOver percentage. Show EV
  while dragging and on hover.
- **Names.** The labels Darks/Shadows/Midtones/Lights/Brights sit under Basic's Highlights/Shadows/Whites/Blacks in the same card.
  "Shadows" appears twice with different windows. Suggest a secondary EV caption per row ("−2 EV"), or Adams
  numerals.
- **Slider range.** ±3, of which beyond ±1.27 flattens (Z-1). The flattened caption only appears once the clamp moves a sample.
- **Guarantees differ.** Basic sliders get a monotone solve (`AppliedReadout.Eased`). Zones get only the clamp.
- **What works.** The dead controls are correctly not shown, Reset is owned by the Tone header, and the step is 0.05 EV
  (argued in code). `LayoutMetricSupport` covers Midtones and Global (lines 694-696).

### Z-10 (LOW): `zoneFlattening` under-reports.
- It is binary on exact clamp. Darks +1.25 has slope 0.02 over 0.32 EV and the readout is nil.
- It reports first…last moved sample as one band, so two separate bands (Shadows +3, Mid −3, Lights +3) are merged into one.
- After Z-1 it should report eased amounts instead. Its engine half (`ToneEngine.zoneFlattening`) belongs to WS-07.

## Reference behaviour
- **Lightroom.** It has no per-zone EV. Highlights/Shadows/Whites/Blacks are fixed hidden windows. The Parametric curve has 3
  draggable splits (25/50/75 % display L). Neither can invert.
- **Capture One.** Levels and Luma Range masks.
- **darktable tone equalizer** (docs.darktable.org 4.6, tone-equalizer):
  - 9 bands, −8…0 EV relative to white, 1 EV apart;
  - "curve smoothing" between bands (above 0.6 it can oscillate);
  - preserve-details mask with EIGF as default (exposure-independent), smoothing diameter 5 % of the long side;
  - mask exposure/contrast compensation with auto-fit.
  Its curve view shows the user how steep the response is. Lumen's mask design matches it. Lumen's band placement (Z-2)
  and its unlimited inversion (Z-1) do not.

## Evidence
| file | shows |
|---|---|
| `evidence/ramp-transfer-plateaus.png` | ramp transfer curves: plateaus for Darks +3, Mid −3, Lights −3, Darks +3 & Mid −3 |
| `evidence/r5-darks-0-1.25-3-crop100.png` | R5 4694 at 100 %: Darks 0 / +1.25 / +3, texture loss at +3 |
| `evidence/r5-4694-darks-sweep.png` | Darks −3…+3 sheet |
| `evidence/gx85-2545-midtones-sweep.png` | GX85 Midtones −3…+3 sheet |
| `evidence/a7iv-6929-brights-sweep-dead.png` | A7 IV Brights −3…+3: five identical tiles |
