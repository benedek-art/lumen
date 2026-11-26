# Instruments (AREAS 8 + 29) findings -- see the agent report for full text
Proven runs: macOS render lab 45753929612 (repro/renderlab-request-1.json); Linux reference lane local (repro/charts.json, repro/hold.json); plates from run 45731193988 (rawtruth.py, plate.py).
Driver run 45751400903 (repro/run1.json) was STILL QUEUED at wind-down: no in-app results.

1 MAJOR  Shift-H raw truth treats 1.0 as saturation; decode sensor white is A7IV 2.912, Z30 1.939, 5D ~1.2, GH5S ~3.5.
         A7IV: R .38 G .30 B .50% "Recoverable" vs 0.006% at decode max (photos.tsv: ~0.05% sites). GH5S: R 3.9 G 5.3 B 1.8% "Not recoverable" vs 0.0013%; -2 EV shows texture (rt_2607.png).
2 MAJOR  Clip counts/overlay test exact code 255/0 on the DITHERED viewer frame: greyRamp ev+1 blown patch settled mean 254.6; clip255 settled 3.02% vs export 5.49%.
         Black %: settled 3.87 vs export 2.01 (ev0), 11.89 vs 6.97 (ev-2), 15.18 vs 9.52 (Blacks -100); about 20% of frame crushed into codes 0/1.
3 MAJOR  ] highlight inspect = CIExposureAdjust -3 EV on the 8-bit display frame; GH5S highlights: 308 colours/sd 2.8 vs real -3 EV render 3007/sd 14.9 (hold_2607.png, hold_6929_shipping.png).
4 MAJOR (rule proven, screen pending)  J paints only all-three-channel clips; triangle/headline are per-channel. A7IV ev-3 any0 0.51% vs all0 ~0; ev+3 any255 1.88% vs all255 0.75%.
5 MAJOR? (code only, NOT proven)  focus peaking not in LoupeView.regionActive -> region sampler stretched over full frame when zoomed.
6 MINOR  skin line 56.4+-10 deg: CC dark skin 45.9, light skin 47.9, Monk 1-6 at 72-89 deg.
Working: histogram code->bin exact (0 mismatches, 3x1.57 MP); clip counts equal lab stats; A7IV clip255 stable 800 vs 1600 px (0.26/0.24%).
Untested: everything in driver run 45751400903 (results.py 45751400903 --out DIR); [ ] holds cannot be held by the driver key verb.
