# WS-48 Colour Range: acceptance spec

Measured with `python3 docs/quality/lanes/WS-48/probe.py OUT` (real `MaskRaster.combine`
through `RangeMaskProbeTests`, alpha at the corpus' 2400 px long edge, the eyedropper as
a 5 x 5 mean). Regions are hand-defined in `regions.py`. Baseline = `claude/inspiring-dirac-ulgpch`.

| # | claim | threshold | baseline |
|---|---|---|---|
| C1 | 8559 red can, Refine 50: precision / recall (alpha > 0.5) | >= 0.98 / >= 0.95 | 0.965 / 0.838 |
| C2 | 8559, Refine 25 < 50 < 75 strictly widens (mean alpha), and Refine 75 does not leak into pot, bench, bins: precision | >= 0.90 at 75 | 0.553 |
| C3 | 3437 meadow green, Refine 50: precision / recall (hive, slab, trunks are negatives) | >= 0.95 / >= 0.85 | 0.814 / 0.880 |
| C4 | 2062 ISO 6400 poppy, Refine 50: speckle (islands + holes < 25 px, per MP) | <= 300 | 9925 |
| C5 | 2062: matte grain `hf` | <= 15 | 50.5 |
| C6 | 2062: precision / recall | >= 0.95 / >= 0.90 | 0.783 / 0.752 |
| C7 | 2348 ISO 3200 red stripe, Refine 50: precision / recall | >= 0.98 / >= 0.95 | 1.0 / 0.734 |
| C8 | hard cliffs on flat picture (`hardflat`, per MP), Refine 50: 8559 / 2062 | <= 10 / <= 200 | 6.5 / 6114 |
| C9 | unit: a chromatic sample (OKLab C >= 0.1) never selects a neutral, at any Refine | alpha < 0.01 at Refine 100 | fails (bench at r75) |
| C10 | unit: the sampled colour 1 EV darker and 1 EV brighter stays selected at Refine 50 | alpha >= 0.9 | — |
| C11 | unit: Refine is monotone: alpha at any pixel never decreases as Refine rises | 0 violations on a hue/chroma/L grid | — |
| C12 | no samples, or only non-finite samples: zero plane (existing behaviour) | exact | pass |
| C13 | cost: one sample at 2400 x 1602, release | <= 3x baseline (0.55 s) | 0.55 s |

Visual (human):
- V1 `evidence/cr_2062_crop.png`: the poppy reads solid, no salt-and-pepper inside or around it at 100%.
- V2 `evidence/cr_8559_sweep.png`: the whole can is selected including its shaded underside; the terracotta pot and the bench are not, at 25/50/75.
- V3 panel snapshot `panel-masks-colour-range`: sample chips, + / -, Refine slider are legible and fit.

## Revisions (made before verification, with the reason)

- Regions in `regions.py` were corrected once after the first measurement (rectangles
  that straddled a poppy edge, the stripe's edge, the can's weeds, the red cup lid in a
  "mug" negative; 3437's concrete slab removed as a negative because it sits within
  0.01 OKLab of the sampled grass). The baseline column above is re-measured on the
  corrected regions from the same baseline alpha files.
- Corrected baseline: C1 0.958 / 0.883, C2 0.495, C3 0.829 / 0.880, C6 0.847 / 0.855,
  C7 1.0 / 0.971.
