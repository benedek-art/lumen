# 19 — The basics, made great

Doc 18 aimed at "70% of every feature". Five independent audits then measured the app
and the owner used it, and both said the same thing from different directions: the
engine is strong and the things a photographer touches every day are not. This
document narrows the target to those things.

## What changed about the goal

**Dropped: beating DXO at denoise.** It needs a trained network and it was never what
this editor is for. Tier 1 is a competent classical wavelet denoiser — measured, at
Luminance 25, it keeps 20.4% of the noise while holding 0.885 correlation with real
texture, where a matched Gaussian holds 0.424. That is honest and useful. If Tier 2
lands it will be a model somebody else trained, and the panel will say so.

**Dropped: Lightroom feature parity.** No ingest engine, no virtual copies, no HDR
merge, no tethering, no panorama, no print module. Lightroom is twenty years of that
tail and matching it is not a goal.

**Kept and sharpened: the creative darkroom.** Film stocks, per-channel density grain,
halation, printer lights, primaries, grading wheels, the colour-balance grid — the
audits scored these 72–80 and called the grain model ahead of Lightroom and Capture
One. This is the part with no equivalent in the competition, and it is why the app
exists. It needs saveable looks and LUT import to be usable, not more engine.

## The bar for "basic"

A control is basic if the owner touches it on an ordinary edit. That list:

open a folder · cull with flags · white balance · the six tone sliders · the curve ·
HSL · Texture / Clarity / Dehaze · a gradient mask · a brush mask · sharpen · denoise ·
crop · save a look · apply that look to another photo · export

Nothing else is in scope until every one of those is good.

## Phase 1 — the sliders feel right

The owner's report: "its slow finiky", and "while I'm dragging a different colour
comes up on the screen and then when I let go it applies something different."

| Fix | What it was |
|---|---|
| One LUT size for draft and settle | Draft baked at 17³, settle at 33³. Measured over 30 000 in-gamut colours, size 17's p99 error is 0.1465 — **37 of 255 levels** — against size 33's 0.0767. The drag preview was a different picture, worst in exactly the highlights and saturated tones a photographer watches |
| Draft follows the viewport | A fixed 1024 px blown up 2–3× into a Retina loupe, so the drag frame was soft as well as miscoloured |
| Canonicalization off the input path | `saveRecipe` ran 4 JSON encodes + 4 decodes of the whole recipe on the main actor per mouse event — ×40 on a batch drag — to build a string it then handed to a background queue |
| `AppState.photos` memoised | 1.68 ms to rebuild at 5 000 frames (+2.41 ms under filename sort), read from seven places, re-evaluated on every published write: ~12 ms of main-actor bookkeeping per mouse move before a pixel was requested |

## Phase 2 — the sliders are accurate

Measured authority over −8…+5 EV, full travel, in sRGB code values:

```
Exposure ±2 EV  169.5      Contrast    81.6      Highlights  79.4
Shadows          74.6      Whites      18.2      Blacks       2.9
```

- **Blacks moves the picture by 2.9 of 255 levels.** Below the visible threshold on an
  8-bit display. The ±1.5 EV anchor move lands in a toe that already puts scene −4 EV
  at code 9.4, so it has nowhere to act.
- **Highlights delivers 87% of its effect in its first half** (0→−50 moves 30 levels,
  −50→−100 moves 4.7) and its strength varies **×3.9 with Contrast** and ×1.8 with
  Whites, through `solveEffective`'s soft cap.
- **Sharpen Detail runs backwards.** Measured gain at a 2 px period, Amount 100:
  Detail 0 → 1.99, Detail 100 → 1.16. The reference goes 2.00 → 2.00.
- **80% of the Colour denoise slider is inert.** Chroma kept: 0→100%, 10→10.5%,
  20→2.8%, then flat to 100. Every shipped ISO anchor from ISO 400 up sits in the dead
  zone, so the Colour half of the ISO defaults changes nothing.

## Phase 3 — the daily workflow

- **Save a look.** Not a preset browser of other people's presets — the owner's own
  looks, stored in the catalog, applied to any photo in any folder.
- **LUT import.** The `.cube` parser exists and is tested; it needs an importer, a
  stage that reads `look.lut`, and a place in the panel. DaVinci exports would load.
- **UI truncation.** The histogram readout tabs overlap; sweep the panel for the rest.

## What this document does not do

It does not score anything. Doc 18's scores were claims about features; the five audits
replaced them with measurements, and those live in the audit records rather than here.
The only number that matters for this plan is whether the owner wants to keep using the
app after an hour with it.
