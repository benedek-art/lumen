# FINDINGS: tone (AREAS 12-15) — saved by orchestrator from the tester's report

Shipping confirmation run 45748747396 (81 renders). Reference lane about 1,350 renders. Shipping matches reference within 0.27-0.56 codes on charts.
Repro manifests: manifests/ (tone-linux.json, tone-linux-raw.json, tone-zone-threshold.json, tone-macos.json, ToneAutoProbe.swift, autotone.txt). Images: img/.

1. MAJOR Zone sliders (Darks/Shadows/Midtones/Lights/Brights) flatten 1-3 stops into one tone above about +-1.25 and can reverse. Grey ramp Shadows +2: 116/131/129; Shadows +3: 175/174/175. 1346 checker Shadows +3: 176.9/177.4/177.7; Lights -2: 134.1 > 133.7. img/zones-plateau__1346__export.png
2. MAJOR Tint +150 gives blue-violet [135,91,230] (hue ~295), -150 gives yellow-olive [131,136,83] (hue ~115); + is 2.2x stronger; both within ~30 deg of the Temperature axis. Should be magenta/green, symmetric, orthogonal. img/tint__1346__export.png
3. MAJOR Protect Skin (0/70/100) does nothing for Monk 3-6 skin (hue 74-89): Vibrance +100 doubles chroma (x1.96-2.02). Works for pinker skin (Monk 7, checker light skin). img/protect-skin__chart-skin__export.png
4. MAJOR Auto Tone on low-key 5812: Exposure +3.27, Highlights -100; median 11 -> 92, 8.8% clipped channels. Others sensible. (Emulated app code path.) img/autotone_5812_export_neutral_vs_auto.png
5. MAJOR Dehaze + streaks/bands a smooth gradient, non-monotone (13 -> 1 -> 6), mostly darkens photos (-0.7 stop midtones). img/dehaze100_greyRamp_export.png
6. MINOR-MAJOR Clarity -100 almost no effect (0.35-0.47 mean abs codes) vs +100 (3.5-5.5). img/clarity_6929_export_ref_m100_p100.png
7. MINOR Whites -100 and Blacks +100 weak (Whites -100: -8.9 codes top quartile on 6929; Blacks +100: +1.2 to +3.3). img/whites-blacks__6929__export.png
8. MINOR Saturation -100 is not luminance-faithful B&W (blue x0.54 linear Y, orange x1.13).

TASTE: Saturation +100 darkens saturated colours x0.852 mean, x0.649 worst (purplish blue); Vibrance +100 x0.95. Recommendation: cut Saturation darkening to Vibrance level (<=5% mean, <=15% worst). Greens push to 0 channel at Sat +100 on 2607 (51% pixels) and drift teal.

WORKING: Exposure exact stops; Contrast hinges at mid-grey and monotone; Pivot; Highlights/Shadows band-limited, no hue shift; Temperature direction; as-shot neutral; WB presets; all identity curves bit-exact; per-channel curves; parametric curve; Density; extreme interactions clean.
NOT TESTED: UI journeys (eyedropper, curve editor gestures, Match Total Exposures, Auto on many photos), real-app Auto, a real sky for Dehaze.
