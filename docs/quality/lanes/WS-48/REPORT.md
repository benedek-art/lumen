# WS-47 + WS-48 (lane M4): Luminance Range and Colour Range — report

Verdict: **PASS** (verifier, fresh agent, re-measured every line). Branch `quality/m4-range-masks`.
Specs: `WS-47/SPEC.md`, `WS-48/SPEC.md`. Measurement: `WS-48/probe.py` (real `MaskRaster`
through `RangeMaskProbeTests`, alpha at 2400 px, regions in `regions.py`).

## For the owner (try by hand)
1. Brightness Range: drag Smooth 0→100 on a sky/snow frame; the edge should soften, never move. Check the new luminance strip under From/To tracks the handles live.
2. Colour Range: sample a red at Tolerance 75 next to terracotta/orange; the pot takes up to ~25% (below 50%, but visible).
3. Open both editors (mask chevron) and check chips, +/−, Tolerance and the strip fit; no snapshot can reach them.
4. ISO 3200+ frame: band edge through a dark tone should read soft, not salty; mask thumbnails under 400 px still speckle.
5. Re-open an old recipe with a Brightness Range: its edge moved half a shoulder inward (0.5 EV at Smooth 50).

## Best evidence
- `WS-48/evidence/cr_2062_crop.png` — ISO 6400 poppy at 100%: salt-and-pepper before, solid after.
- `WS-48/evidence/cr_8559_sweep.png` — red can at Refine 25/50/75: before leaks into pot, bench, bins at 75; after selects the whole can only.
- `WS-47/evidence/lr_983_sweep.png` — snow at Smooth 0/50/100: before the sky floods in as Smooth rises; after the edge stays put.

## Verdict per spec line (after / baseline)

WS-48 Colour Range
| # | after | baseline | |
|---|---|---|---|
| C1 8559 can r50 P/R | 1.000 / 0.961 | 0.958 / 0.883 | PASS |
| C2 r25<50<75 widens; P@75 | 0.029<0.043<0.052; 1.000 | 0.495 | PASS |
| C3 3437 meadow P/R | 0.969 / 0.970 | 0.829 / 0.880 | PASS |
| C4 2062 speckle/MP | 7 | 9925 | PASS |
| C5 2062 hf | 3.6 | 50.5 | PASS |
| C6 2062 P/R | 0.962 / 0.922 | 0.847 / 0.855 | PASS |
| C7 2348 red stripe P/R | 1.000 / 0.999 | 1.000 / 0.971 | PASS |
| C8 hardflat 8559 / 2062 | 0.5 / 0.0 | 6.5 / 6114 | PASS |
| C9 chromatic sample never selects grey | 0 failures | fails | PASS |
| C10 ±1 EV shade stays selected | ≥0.9 | — | PASS |
| C11 Refine monotone | 0 violations | — | PASS |
| C12 no samples → zero | exact | pass | PASS |
| C13 cost | 1.3–1.5 s (2.3–2.7×) | 0.55 s | PASS (≤3×) |

WS-47 Luminance Range
| # | after | baseline | |
|---|---|---|---|
| L1 handles are the edge at every Smooth | 0 violations | edge moved 1 EV | PASS |
| L2 Smooth widens ramp; Smooth 0 a step | 0.076 → 1.45 → 2.88 EV | — | PASS |
| L3 open ends at −10 / +4 | α = 1 | — | PASS |
| L4 983 P at Smooth 0/50/100 | 0.964 each | 0.918 / 0.433 / 0.254 | PASS |
| L5 Smooth drift in P and R | 0.000 / 0.000 | 0.49 / 0.17 | PASS |
| L6 2348 ISO 3200 speckle/MP | 274 | 7887 | PASS |
| L7 2348 hf | 9.6 | 44.6 | PASS |
| L8 2348 Smooth 0 speckle/MP | 274 | 10044 | PASS |
| L9 no handles → zero | exact | pass | PASS |
| L10 cost | 0.48–0.63 s (2.4–3.2×) | 0.2 s | PASS (≤4×) |

Visual: WS-48 V1 holds; V2 holds at 25/50, **partly at 75** (pot mean α 0.25, max 0.47). WS-47 V1 holds; V2 holds (soft, though mottled mid-grey with a weave pattern at 100%). V3: only the strip is snapshotted (`panel-masks-luma-band-strip`); the editors are behind a chevron the harness cannot press.

## What changed and why
- **Noise-aware measurement** (`MaskRaster.rangeMeasured`): self-guided filter, radius = long edge / 800, ε = 9× the frame's own noise variance per half-stop bin (robust MAD of a 5×5 high-pass), two passes. Smooths flat noise, keeps edges (983's 1.2 EV snow/sky step survives). Off below 400 px.
- **Luminance Range**: shoulders centred on From/To (`lumaRangeValue`, public so the strip draws the same curve). Smooth softens without moving the edge; handles at −10/+4 are open-ended. Old shoulders sat outside the band, so Smooth grew the selection. Help text rewritten to match.
- **Colour Range**: OKLab chromaticity compared at the sample's lightness (shade is the same colour); hue tolerance 0.046 at Refine 50, saturation 2.5× that, toward-grey capped at 90% of the sample's chroma (never reaches neutral for C ≥ 0.1); EV gate ±3 EV; smoothstep falloffs. Replaced per-axis LCh trapezoids whose hue test switched off for any low-chroma pixel.
- **Panel**: luminance-map strip under the Brightness Range sliders; Tolerance help rewritten (kept "Tolerance": "Refine" already names the mask's edge chain in this editor).
- GPU unaffected: range masks are CPU-only on both paths (`MaskGPU.isParametric` takes only linear/radial).
- No existing test changed. Full LumenCoreTests (3057, `--parallel --skip ControlProofTests`) pass on Linux.

## Not fixed / for a human
- On-image luminance map (Lightroom's "Show Luminance Map") is an overlay mode, WS-42's: see `WS-47/NEEDS.md`.
- Behaviour change: existing Brightness Range recipes shift their edge by half a shoulder; From == To now selects nothing.
- Thumbnails < 400 px: denoise off, high-ISO band edges speckle (2348 at 390 px: 4470/MP).
- Low-chroma samples on textured scenes (3437 meadow, a grey bench) keep ~580 islands/MP: that is the texture, not noise.
- Regions were corrected once after first measurement (documented in `regions.py`); baselines re-measured on the same regions.
- Linux Swift 6.0.3 cannot parse two trailing commas in `CompareView.swift` (pre-existing, not this lane); worked around locally, not committed.
