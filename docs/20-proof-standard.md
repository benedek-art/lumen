# 20 — The proof standard

Doc 18 scored features. Doc 19 measured some of them and found that the scores had been
generous — Texture was doing a twenty-fifth of what it claimed from behind a green test,
and Clarity a forty-eighth. The lesson was not that those two were badly written. It was
that **a test asserting a contract cannot tell you whether a control does enough to be
worth having**, and thirteen of twenty Sharpen Radius settings can render byte-identical
without a single assertion noticing.

This document defines what "proven" means, so that the claim is mechanical and a
regression cannot hide behind a green suite.

## The six proofs

A control is PROVEN only when all six are recorded and passing. Anything less is
UNPROVEN however good the code looks.

**P1 — REACHES.** Traced from the UI control, to the recipe field it writes, to a reader
on the **shipping path** — `RenderGraph` and `export`. The record stores the reader's
`file:line`. `ReferenceRenderer` renders no user pixels; a control whose only reader is
the reference fails P1 no matter how correct it is. This is the proof that catches an
inert control, and it is the one this project has failed most often.

**P2 — ALIVE.** Over at least twenty steps across its declared travel, every step changes
the render. No dead zone, no plateau the control does not declare.

The frame matters as much as the sweep. `colorDetail` measured dead on a near-neutral
frame because it scales a threshold where the *chroma* edge map is high, and `hotPixels`
measured dead on a frame with no hot pixels. **A control must be swept on a frame
containing what it acts on**, and the record names that frame. A dead reading on the
wrong frame is a defect in the probe, not the code.

The sweep must also stay inside the control's own bounds. Point Colour Hue is a ±60°
slider; driving it to ±100 and reporting saturation is measuring the clamp.

**P3 — AUTHORITY.** The peak separation between the two ends of the travel, in **sRGB
code values (0–255)** at the display, on the named proof frame. Recorded as a number,
with a floor asserted beneath it.

A number, not a boolean, because "it changes the picture" was true of Texture at 2.6% of
its reference. The floor is what makes the number load-bearing: Blacks moving 2.9 of 255
levels is below the visible threshold on an 8-bit display, and a control the user cannot
see is not a control.

**P4 — WELL-BEHAVED.** Monotone where it claims to be. No posterization. No clipping it
does not intend. No hue rotation where it claims to move luminance only, and no
luminance shift where it claims to move chroma only. Where the control can produce a
halo, a rim or a ringing edge, that artifact is bounded and the bound is asserted.

Circular controls are exempt from end-to-end authority and get a different metric: a
grading wheel's hue was reported dead for months because 0° and 360° are the same
setting. Sweep it in steps and assert every step moves.

**P5 — PARITY.** The GPU shipping path agrees with the f64 reference within a stated
tolerance, on the same frame, at both preview and export scale. This is the proof that a
shader has not drifted from the mathematics it was written against, and it runs on the
macOS lane.

Scale is part of it. A per-pixel edge gate that keeps 17.8% of a delta at preview scale
and a different fraction at export scale has passed a same-scale comparison and still
lies to the user about what they are judging.

**P6 — BASELINE.** Measured against a published reference for the same operation, with
the delta recorded and its direction stated.

## What P6 can honestly claim

Lumen cannot run Lightroom, Capture One or DxO, so no number in this repository is a
measurement against them. Saying otherwise would be the same class of dishonesty this
project keeps finding in its own panels. A P6 record must name which of three sources it
rests on:

- **(a) An open implementation.** darktable and RawTherapee publish their algorithms and
  their source. A local-contrast, tone-curve, sharpening, dehaze or wavelet-denoise
  operator can be reimplemented from them and compared numerically. This is the
  strongest form and the delta means what it says.
- **(b) A published standard or paper.** CIE and ISO definitions, the local-Laplacian and
  guided-filter papers, published film characteristic curves. Strong for anything with a
  defined correct answer — a colour transform, a film stock's curve — and the delta is
  an error, not a preference.
- **(c) Observed behaviour recorded in docs/02 and docs/03.** The Lightroom teardown
  measured LrC 15.5's panels; the field survey did the same for the others. Legitimate
  evidence, and **weaker than it looks**: it is a reading of someone else's product taken
  at one version, not a reimplementation.

A claim of "better than Lightroom" resting on (c) is an inference from a teardown, and
the record says so in those words. The owner is entitled to know which of his controls
are provably better and which are merely believed to be.

## The proof frame

A control is swept on the smallest synthetic frame that contains what it acts on, chosen
from a fixed set so that records are comparable across controls and across time:

| Frame | Contains | Used by |
|---|---|---|
| `neutralRamp` | a linear grey ramp over the working range | tone, curves, display transform |
| `colourChart` | 24 patches at known chromaticities, including two skin tones | white balance, mixer, point colour, the B&W mix |
| `stepEdge` | a hard edge at a known contrast | halo and rim bounds, edge-aware masks |
| `fineTexture` | band-limited detail at several spatial frequencies | texture, clarity, capture sharpening |
| `wideFineTexture` | `fineTexture` at 2048 px, where a frame-denominated sharpening radius is still several pixels wide | creative sharpening's Detail and Masking |
| `noisyISO6400` | a clean frame plus a measured sensor-noise model | every denoise control |
| `hazySky` | a veiled gradient with a known airlight | dehaze, and the gradient-vs-edge case that has twice reverted the Texture port |
| `hotPixels` | isolated spikes on an otherwise clean frame | hot pixels |
| `chromaEdge` | a saturated colour boundary | colour denoise, defringe, chromatic aberration |
| `noisyChromaEdge` | `chromaEdge` under the same sensor-noise model, with `chromaEdge` as ground truth | colour denoise scored on what it costs as well as what it removes |
| `tonalColourWedge` | eight band-centre hues over the whole −9…+5 EV zone axis, one luminance per row | grading wheels, zone geometry, primaries, film stocks |
| `wideStepEdge` | `stepEdge` at 2048 px, where a film-gate kernel is several pixels wide | halation, and creative sharpening's Amount, Radius and Halo Damping — at 128 px the frame-denominated sigma never clears `gaussianBlur`'s own support floor, so those controls measured 0.0000 authority with 20 dead steps |
| `grainField` | a grey ramp at 4096 px, where a grain plate cell clears its half-pixel floor | film grain amount and size |

A control swept on a frame that does not contain its subject records `INVALID PROBE`,
not a result.

The last four rows were added after the set was declared fixed, and each says which
existing frame it replaced and why — which is the bar for adding another one.
`noisyChromaEdge` exists because `noisyISO6400`'s clean twin is neutral, so a colour
denoiser that annihilates every chroma band scores perfectly on it: the frame could say
what the control removed and never what it cost. `tonalColourWedge` exists because
`colourChart` spans only about −2.5…+2.2 EV, which on the grading panel's −9…+5 axis is
the mid zone and nothing else — the shadows and highlights wheels, the zone pivots and
the primaries' shadow tint were all being asked to act through windows nearly shut over
every pixel in the frame, and a `neutralRamp` that spans the axis carries no chroma for
any of them to act on. `wideStepEdge` and `grainField` exist because the Film Lab's two
spatial stages are denominated in MICRONS AT THE GATE rather than in pixels: halation's
first bounce is 65 µm on a 36 mm gate, which is 0.23 pixels on a 128-pixel frame, and a
grain plate cell is floored at half a pixel, which the whole 0.5…2.0 travel of Grain Size
sits under on a 256-pixel one. Measured there, halation reads 4.31 code values and Grain
Size reads 0.00 with twenty dead steps of twenty. **A frame can be the wrong frame by
being too SMALL, not only by containing the wrong thing**, and that is the newest way this
project has found to record an INVALID PROBE as a finding.

## The record

Every proof writes `Tests/Proof/records/<control-id>.json`, committed. The suite
regenerates them and fails if a committed record no longer matches within tolerance.

That makes a behaviour change **visible in a diff**, which is the property this project
has been missing: every defect in docs/19 was invisible until somebody thought to
measure, and none of them would have shown up in a code review. A record that moves is
either a fix or a regression, and the commit message has to say which.

## Evidence images

Each control renders three frames — neutral, full negative, full positive — through the
reference at a fixed size, written as PNG under `Tests/Proof/evidence/`. These are not
assertions; they are what lets the owner judge with his eyes the moment he is at a Mac,
without re-deriving what was measured or trusting a number he did not watch being taken.

The reference renderer produces them because it runs on Linux. Where a control's GPU
path differs from the reference, P5 is the proof that the difference is bounded, and the
evidence image carries a note saying the picture shown is the reference's.

## The ledger

`docs/21-proof-ledger.md` is generated from the records: one row per control, six
columns, the authority number, and the P6 source letter. It is the answer to "does every
slider work well", and it is regenerated rather than edited.

## The rule that keeps this honest

**A control's status may only improve when a proof is recorded — never when code is
written.** Doc 18 stated this rule for scores and it held. It applies here with one
addition learned since: a proof that has never been observed to fail is not yet a proof.
Every assertion added under this standard is verified able to fail, by substituting
wrong behaviour and watching it go red, exactly as `scripts/check-swift-surface.py`
verifies each of its passes.
