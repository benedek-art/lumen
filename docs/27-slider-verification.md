# 27 — Every slider, verified: the coverage audit

**The owner's charge, verbatim:** "verify every slider and do a bunch of tests on
it, rigorous testing to make sure that they bring actual output that is measurable
and accurate." This document is the audit that makes "every" checkable: the full
inventory of user-facing sliders against the three kinds of evidence the project
maintains, with every gap either closed or dispositioned with a reason. A slider
missing from this table is a bug in this table.

The three evidence kinds:

- **Record** — a committed proof record (`Tests/LumenCoreTests/Proof/records/`):
  the control visibly moves the picture, monotonically (or with declared
  exceptions), across its whole panel travel, with an authority floor asserted at
  70% of its measurement. Answers *measurable*.
- **Contract** — a calibration assertion (`AccuracyProbeTests`,
  `SliderContractTests`, `EngineMathFixtureTests`, …): the control's numbers mean
  what the label and docs promise. Answers *accurate*.
- **Baseline** — an independent-implementation cross-check
  (`scripts/baselines/crosscheck.py`, docs/26): the semantics agree with the
  field, not just with ourselves.

## 1. Covered before this audit (111 records)

Tone (7, incl. contrast pivot) · Zones (11) · WB temp/tint (2) · Saturation +
Vibrance (2) · Parametric curve (4) · Mixer bands (24) · B&W mix (8) · Grade
wheels + geometry (16) · Printer lights (4) · Primaries (8) · Point Color (5) ·
Film (11) · Texture/Clarity/Dehaze (3) · Sharpen (4) · Denoise luma/chroma (2).

Contracts already standing: Exposure = 2^EV at 1e-9 (plus RawTherapee baseline);
contrast pivot invariance and calibrated slope (plus darktable baseline, docs/26
§3); zones pivots at documented EVs; path-to-white bleach (plus two-tool
baseline, docs/26 §2); WB eyedropper inverse; export-table fidelity bounds;
200-step travel smoothness; tone-cube knot fidelity.

## 2. Gaps found, closed this audit (25 new records)

Every one of these was a DRAGGABLE, IMAGE-AFFECTING slider with no record — no
assertion anywhere that it does anything at all:

| control(s) | note |
|---|---|
| `color.density` | The slider session A reported "doesn't seem to be able to be moved". Two defects hid here: no record (closed — measured with its saturation companion), and the row disables by design below Saturation 0 with only a hover tooltip saying why (closed — visible inline hint). |
| `color.protectSkin` | Measured with a vibrance companion; contract also added (attenuates the chart's skin patch >40%, leaks <15% to blue). |
| `cb.hueShift`, `cb.vibrance`, `cb.{chroma,saturation,brilliance}.{global,shadows,mid,high}` | The entire 14-slider Colour Balance grid — docs/05's headline claim over Lightroom — shipped with no record on any of it. Hue shift measured circularly (antipode rule). |
| `mixer.uniformity` | The mixer's 25th slider — and the audit's biggest catch: the contract probe convicted the shipped convergence field itself. Each band applied a full-deviation pull toward its own centre, so at seams two opposing pulls cancelled into small BACKWARDS moves — hues ~20° from a centre anti-converged, and wheel-wide aggregate convergence at uniformity 100 measured +0.1° on 54° of pair spread. Fixed before the first record pinned it: convergence now pulls toward the weighted circular mean of the member bands' targets, a monotone field with no anti-pockets. What remains (recorded, not hidden): the wide band feathers leave mid-band ramps near identity, so convergence is strong only in the ±6° flats around each centre — the honest cure is the measured `bandMeanHues` wiring (the engine's own documented plan) and rides the dossier's band-geometry item. Contract: 8° pairs at every centre converge >70%; every seam hue holds within 2.5°. |
| `sharpen.haloSuppression` | Measured on the step edge with Amount pushed, so there is a halo to suppress. |
| `look.vignette` | Record plus an exact-unit contract: −2 EV attenuates the corner to 2^−2 of the plain render, on the Linear preset so the curve cannot hide the number. |
| `denoise.{lumaDetail,lumaContrast,colorDetail,colorSmoothness,hotPixels}` | The whole classic disclosure, each with its master as companion; Hot Pixels gets the frame that actually contains impulses, plus a halving contract. |

New contracts beyond the table: Saturation −100 reaches true B&W at every
protectSkin setting (the documented anti-regression); Density darkens a saturated
push monotonically and cannot move a neutral; Vibrance's low-chroma weighting;
curve points pass through themselves; grain is bit-identical at 0 and
variance-monotone above it.

## 3. Dispositions — measured elsewhere, deferred, or exempt, each with its reason

| control | disposition |
|---|---|
| `detail.capture.amount` | LIVE but macOS-only measurable: it scales Apple's at-demosaic sharpener inside `AppleRawSource`, upstream of the Linux reference path. Owed to the gpu-parity/mac lane; the panel already discloses the mechanism honestly. |
| `detail.capture.radius` | Stored and NOT applied (Richardson–Lucy has no caller); the panel says so in prose. Dossier item 9's wire-or-remove decision stands — a record would measure a control that is documented as not running. |
| `denoise.amount` (AI mode) | Drives the decoder's denoise blend, macOS-only, same reason as capture amount. Mode/amount plumbing is contract-tested in LumenCore (`appleStandIn`). |
| Masked adjustment sliders (`mask.*`) | Deferred with a plan: the runner needs mask-raster support to sweep a masked Exposure against an actual mask. The GLOBAL engines they scale are all recorded; what a mask record adds is the Amount scaling path and the raster, which is its own harness. |
| Effects grain Amount/Size | Same recipe fields as `film.grain.*` (both panels bind `look.filmLab.grain`) — already recorded there; a second record would measure the same numbers twice. |
| `geometry.angle`, crop, flips | Geometric transforms: authority-in-code-values is the wrong metric (a 1° rotation moves every pixel and changes no tone). Verified by `CropGeometry` tests instead. |
| Export sheet sliders (quality, megapixels, resolution) | Output options, not image controls; verified by export tests. |
| Curve point EDITOR drags | Not a slider; the pass-through contract covers the mapping, and the editor's gestures are UI-lane. |

## 4. What "accurate" still owes, ranked

1. Lightroom reference exports (owner) — drop into docs/26's tables as the final
   independent row for exposure, bleach, and contrast slope.
2. Highlights/Shadows range-compression targets against dt/RT via the baseline
   harness (the machinery from docs/26 extends; the contracts define "how much at
   ±100" once a reference is chosen).
3. Temp-writes-the-Kelvin-it-shows as a full-pipeline contract (the eyedropper
   inverse pins the solver; the render-side assertion needs the RAW fixtures for
   an as-shot anchor worth trusting).
4. Colour Balance semantic contracts (chroma holds L and h; brilliance holds the
   ratio) — the struct documents them; asserting them needs the grade path's
   engine-level entry exposed to tests.
5. Sharpen radius in OUTPUT pixels (dossier item 2) — the preview/export
   disagreement is recorded; the fix is queued behind a Mac verification.
