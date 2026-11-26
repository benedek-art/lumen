# FINDINGS: colour (AREAS 17-18) — saved by orchestrator from the tester's report
Shipping run 45748236431 (colour-mac, 135 renders). Shipping matches reference within ~1 deg hue, 0.01 chroma. Manifests in manifests/, scripts in tools/ (mkplate.py makes colour-plates/sweep.plate: continuous OKLCh hue sweep at 0.25 deg/px), numbers-*.txt, images ship-*.png / ref-*.png.
1. MAJOR Shadows grading wheel only reaches near-black (display L<0.18); Midtones wheel does what users call shadows. 6929 shadows teal 0.4: invisible (dMAE 0.05); mids teal 0.4: heavy wash. Colour-balance Shadows rows no effect above L 0.2. Jobs wheel-zones, wheel-split-real. ship-wheel-split-real__6929__export.png
2. MAJOR Point Colour HUE shift spills far beyond the sampled colour (skin sample, Hue +60 moves greens h120/h150 by +58/+57 deg; Hue -60 drags purples) while Sat/Lum shifts stay selective. Job pc-spill. ship-pc-spill__chart-hueRing__export.png, pointcolour-skin-h+60.png
3. MAJOR B&W band negative travel runs to pure black (gain = 1 + band/100). Azure -100: L 0.699 -> 0.067, 6.2% at 0, hard edge. Red+Orange -100 turns light skin black, unevenly by skin chroma. Job bw-neg. ship-bw-neg__chart-gradient__export.png
4. MAJOR Grading wheel hue/sat not luminance-neutral, hue-dependent: mids blue sat 0.3 brightens -3 EV by +0.55 stop (+1.02 at 0.6); highlights tint darkens -0.16..-0.23 stop; 6929 mids teal 0.4 red channel clip 0.81% -> 26.3%. wheel-mid-hue-luminance.png
5. MINOR Mixer Hue +-100 reverses hue order 13-18 deg at band edges (clean at +-50). tools/fold.py, mixer-orange-hue-fold.png
6. MINOR Mixer Sat+ / Lum- on saturated orange/yellow rotates hue toward red (-22..-25 deg at +100). mixer-orange-sat-hue-rotation.png
7. MINOR Primaries Purity + dead for red (x1.00), near-dead green; negative works.
8. MINOR Ring handles do not define band selection (core 5/feather 2 still 50-98 deg; stray 22% bump).
9. MINOR Skin answers Red band more than Orange; uneven across skin tones.
10. MINOR Shadows-wheel tint lifts true black; viewer vs export disagree (+1.08 vs +0.70 stop at -8 EV).
11. MINOR Upper half of Blending nearly dead (75 == 100).
12. MINOR Mixer sat+ skips lightest/darkest skin (chroma gate).
TASTE: wheel very sensitive; mixer Lum asymmetric; colour-balance Chroma vs Saturation identical; printer light +12 strong; Blue Primary Hue rotates skin +32 deg.
WORKING: mixer bands selective (FWHM 40-50 deg, no leakage), Hue +-100 = +-45 deg, Sat -100 neutral, Point Colour clamp and Range, B&W band peaks and no banding at flat, wheel hue wraps correctly, balance direction, printer lights exactly 1/12 stop, colour-balance hue exact.
NOT TESTED: UI gestures (ring handles, eyedroppers, keys), draft path, Point Colour Variance, a real portrait RAW.
