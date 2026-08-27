# 26 — Tone baselines: Lumen against the field

**Why this document exists.** After session B the owner put the accuracy question
in its sharpest form yet: *"If I push the exposure up to 1.80 … it does not seem
like an exposed picture. It seems fake … can you prove that it is correct?"* A
test that checks Lumen against Lumen proves internal consistency and nothing
else. This document records Lumen measured against independent implementations —
RawTherapee 5.10 and darktable 4.6, both run headless on Linux by
`scripts/baselines/crosscheck.py`, which any machine with those two packages can
re-run. Lightroom cannot run headless on Linux; the owner-exported LR references
(master plan, M2) remain the final leg and slot into the same tables.

## 1. Exposure is a pure gain of 2^EV — confirmed against RawTherapee

Lumen's contract (asserted at 1e-9 in `testExposureIsCalibratedInStops`):
Exposure +1.00 multiplies scene-linear light by exactly 2. The same experiment
through RawTherapee's neutral pipeline, 16-bit sRGB TIFF in and out, measured
back in linear:

| patch (linear) | RT ratio at +1.0 EV |
|---|---|
| 0.02 / 0.05 / 0.09 / 0.18 / 0.36 grey | 1.9997 … 2.0001 |
| RGB(0.50, 0.36, 0.21) | 2.0000 / 1.9999 / 2.0002 per channel |

Deviation is quantization noise (16-bit round-trip). RawTherapee treats
exposure exactly as Lumen does: scene-linear, hue-neutral, channel-uniform pure
gain. The owner's kept divergence "pure-gain exposure" is not a divergence from
the field — it is the field.

## 2. Overexposure must bleach toward white — the defect, the fix, the field

The "fake" +1.80 EV picture had a mechanism. Lumen's display transform offers a
per-channel branch (each channel through the curve — bleaches by construction,
skews hue) and a hue-stable ratio branch (curve the max, keep the ratios), blended
by `huePreservation`. The shipped default was 100 — pure ratio — and the ratio
branch kept chroma FOREVER: measured 96% of the patch's chroma still present at
+5 EV. A sky pushed four stops stayed blue at 98% brightness. That is the pastel
wash in the owner's screenshot, and no real medium — film, sensor+curve, any
shipping raw developer — behaves that way.

The experiment (`testOverexposureBleachesTowardWhite` in Lumen;
`crosscheck.py bleach` for the field): sunset-orange RGB(1.0, 0.72, 0.42),
pushed +0..+5 EV, residual chroma (max−min)/max of the rendered output.

| implementation | +0 EV | +2 EV | +3 EV | +5 EV |
|---|---|---|---|---|
| **Lumen before the fix** | 0.612 | 0.597 | 0.587 | **0.587** |
| **Lumen after the fix** | 0.553 | 0.214 | 0.036 | **0.000** |
| darktable sigmoid, per-channel (hue 100) | 0.398 | 0.095 | 0.037 | 0.005 |
| darktable sigmoid, per-channel (hue 66) | 0.401 | 0.096 | 0.037 | 0.005 |
| darktable sigmoid, RGB-ratio | 0.551 | 0.158 | 0.061 | 0.008 |
| RawTherapee, Standard Film Curve | 0.222 | 0.000 | 0.000 | 0.000 |
| RawTherapee, neutral (hard clip) | 0.580 | 0.000 | 0.000 | 0.000 |

Three facts the table settles:

1. **Every implementation collapses to ~0 by +5 EV.** The pre-fix transform is
   the only member of the set that never bleaches — it was outside the field,
   which is exactly what "seems fake" was reporting.
2. **Even darktable's maximally hue-preserving modes bleach.** Their ratio mode
   builds the path to white in; their "preserve hue" slider corrects hue angle
   and leaves the bleach alone (hue 100 vs hue 66 chroma identical to 3
   decimals). Lumen's old parameter conflated "preserve hue" with "preserve
   saturation", which is the semantic the fix removes.
3. **Lumen's new curve sits inside the consensus, at its gentlest edge** —
   within a few hundredths of darktable's RGB-ratio mode at every step, holding
   colour slightly longer through +2 EV and reaching true white where everyone
   does. Whether the owner prefers this rate or Lightroom's exact slope is a
   taste call for the LR side-by-side; "never whitens" was not a taste call.

The fix itself: hue preservation now ramps quadratically to per-channel across
the shoulder — untouched at the tonal pivot (midtones stay fully hue-stable,
the virtue the parameter was for), fully per-channel at the white anchor (where
per-channel bleaching is the only honest rendering of more light). One
expression in `DisplayTransform.apply`, watched failing at the shipped default
before the change.

## 3. Contrast: same dial number, different semantics — measured

Lumen's `contrast` is a calibrated log-log slope: 1.5 means the rendered curve
climbs 1.5 stops of display per stop of scene at mid-grey, by construction (the
suite asserts the pivot; the fixture mirror pins the curve). darktable's sigmoid
carries the same range and the same 1.5 default, but measured through
`darktable-cli` (greys at ±0.2/±0.4 EV around 0.18, contrast=1.5), its realized
mid-grey slope is **1.23** — their parameter is a steepness knob, not a slope
contract. Both implementations pin mid-grey itself (dt 0.179, Lumen 0.180).

Two consequences worth knowing when comparing pictures: at the same dial number
Lumen renders more midtone contrast than darktable's sigmoid; and if the owner's
"contrast doesn't feel like Lightroom" persists after the path-to-white fix, the
LR reference exports should measure LR's realized slope the same way before
anyone touches Lumen's default — "1.5 means 1.5" is the defensible contract,
and matching a competitor means measuring the competitor first.

## 4. Method caveats, so nobody over-reads the table

- Chroma is measured in each tool's own output RGB after decoding the shared
  sRGB transfer; working primaries differ, so the comparison is of SHAPE, not
  third-decimal equality across tools. (Lumen's two rows ARE comparable to each
  other to the last digit.)
- The darktable sigmoid is driven by a hand-packed param struct in an XMP; the
  script carries a tripwire that detects the struct drifting on a darktable
  upgrade (the module silently dropping out degenerates to a hard clip, which
  the +0 EV patch exposes).
- RawTherapee "neutral" is a straight linear clip — included as the floor every
  tool must beat, not as a rendering anyone ships.

## 5. What this unlocks next

- The same harness extends to Highlights/Shadows range compression, and WB once
  the RAW fixtures arrive — each is one more measurement over the same
  patch/measure machinery (Contrast landed in §3 the same day the harness did).
- The owner's Lightroom reference exports drop into the bleach table as one
  more row, and into the exposure table as the second independent confirmation.
