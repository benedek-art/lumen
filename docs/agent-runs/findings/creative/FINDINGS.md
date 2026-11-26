# FINDINGS: creative (AREAS 19-20) — saved by orchestrator from the tester's report
Code: integration 805455c0. Runs: reference CI 45745330093 (8 shards), macOS 45749613619. Repro in repro/ (cr-*.json, cr-mac.json); images in images/ and images/mac/.
VERDICT, trust today: creative LUTs at any amount (0 = off, linear, identity exact, preview = export); display presets (smooth highlight roll-off, blues stay blue, skin <=3 deg); Tri-X as B&W (not toning); Strength, Film Exposure, Push/Pull; halation; vignette shape.
Do NOT trust today: any colour stock on saturated subjects; Portra/Cine on skin, especially darker skin; choosing a stock by name.
1. MAJOR Tri-X discards all toning: grading wheels, colour balance, printer lights give chroma 0.0000 (grade S10 and printer lights S6 run before the film stage S14, which reduces to luma). docs/05 promises wheels are the B&W toning tool. images/mac/trix-tone__chart-greyRamp__export.png
2. MAJOR Every colour stock hard-clips ordinary saturated colours to a 0 channel: Portra orange 204,128,55 -> 212,132,0; ColorChecker pixels with a 0 channel Portra 14.6%, Gold 22.6%, Ektar/Velvia 25.8%, Cine 12.9% vs 0% no stock; 5812 red dome G=0 on 68-86%. Should gamut-compress, not clip. images/dome_5812.png
3. MAJOR Portra skin uneven: Monk 1-2 chroma -50%, Monk 6-8 and CC dark skin +45..+83% (orange-ochre). Ektar/Velvia worse. images/mac/stocks__chart-skin__export.png
4. MINOR Colour stocks barely differ in saturation (Portra/Cine +58..63% chroma on 6929, 87-90% of Velvia on checker).
5. MINOR Display transform Skew nearly inert; negative half dead.
6. MINOR Vignette Feather sets extent and strength (Feather 0 makes -4 EV nearly invisible); unlike Lightroom (Feather = softness, Midpoint = extent).
7. MINOR Saturated orange turns yellow in the display shoulder (59 -> 85 deg at +3 EV) despite Hue keep 100.
TASTE: Gold 200 pinkish neutrals; Velvia crushes deep shadows; halation orange not red, large at Size 2; Black target 9 very milky.
SEEN IN PASSING: 6929 bright sky is lavender on every preset incl. Linear (already in the decoded plate: decode/highlight handling). Grade shadows sat 0.5 drives R to 0 on 30% of grey ramp.
TOOLING: render-lab drift harness ignores look.lut (all LUT drift rows equal 'none').
NOT TESTED: saved Looks UI, disabled sliders under a stock, malformed .cube UI, grain, real portrait.
