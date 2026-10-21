# WS-28 Lens corrections: report

Lane C3, branch `quality/c3-lens` from `claude/inspiring-dirac-ulgpch`.

## For the owner

- Apple's decode fixes distortion on the A7 IV and GX85 and nothing else. Lumen now adds Remove CA (on by default, like Lightroom), the A7 IV's own vignetting record, and Lightroom-style Defringe.
- Remove CA cuts corner colour misregistration by 88–96 % on the corpus frames that have it, and leaves frames without it (your A7 IV file) bit-identical.
- GX85 vignetting stays uncorrected: the RW2 carries no vignetting data, so it needs a lens-profile database this build does not have.
- Try by hand: the Lens section on an A7 IV and a GX85 file, Defringe Purple 5 on a backlit branch, and how long the first open of a 45 MP file takes (Remove CA measures once per photo, on native pixels).
- Best evidence: `evidence/4213-treeline-ca.png`, `evidence/defringe-sweep.png`, `evidence/6929-vignette.png`.

## 1. What Apple's decode corrects on the owner's cameras

Measured on macOS CI, RAW corpus lane run 39530459990 (`LensProfileRawCorpusTestsProbe`,
`lens-probe:` lines), decode scale 0.5, numbers in native px. `isLensCorrectionSupported`
and default-enabled are true for both bodies.

| | A7 IV (6929, FE 50 F2.5 at f/5) | A7 IV APS-C (6934) | GX85 (2545, 4:3) | GX85 (2547, 16:9) |
|---|---|---|---|---|
| Distortion (green on vs off, r = 0.5 / 0.75 / 1) | 1.72 / 0.08 / −4.58 px | 1.75 / 1.19 / −1.09 | 4.84 / −6.60 / −34.67 | 5.56 / −2.25 / −22.76 |
| Lateral CA, B at r = 1, profile off → on | 0.22 → 0.21 px | 0.29 → 0.31 | 0.17 → 0.16 | 0.21 → 0.22 |
| Vignetting, r 0.9–1.0 luminance on/off | 0.9996 (the file's own record says 1.457) | 0.9996 (record 1.137) | 1.0024 (no record) | 1.0059 (no record) |

So `isLensCorrectionEnabled` = distortion only. Lateral CA is untouched, and so is vignetting,
including the 0.65 EV corner fall-off the A7 IV writes into the file
(0x7032; 0x7035 lateral CA and 0x7037 distortion also present, all "Auto"). The GX85's RW2
carries DistortionInfo (0x0119), which Apple applies, and no vignetting record.

What this lane adds, after the decode, before S5:

- **Sony vignetting** from 0x7032 under `lens.profile` (darktable's knot encoding, fitted as
  1 + a·r² + b·r⁴ + c·r⁶; the fit is within 1 % of the knots). On 6929 the r 0.9–1.0 ring
  rises 0.46 EV relative to the centre (spec 4.4 window 0.45–0.70: passes, at the low edge,
  because the ring averages the record's 0.45–0.65 EV over its radii). Nothing doubles: the
  probe shows Apple leaves the record unapplied.
- **Remove CA**, measured on the photograph (section 2), for every camera.
- **Not added:** GX85 vignetting (no data), Sony embedded CA (0x7035 says ≤ 0.8 px at the A7 IV's
  corner and the estimator finds nothing significant; Remove CA covers it if a lens has more).

## 2. Remove Chromatic Aberration

Engine: `LateralCAEstimator` + `LensStage.warp` (`Sources/LumenCore/Engine/LensStage.swift`),
GPU twin `lumenLens` (CIKL, generated beside the Swift), chained in `RenderGraph+Lens.swift`.
Model: R and B resampled (Catmull–Rom) at `centre + (p − centre)(1 + k0 + k2·r²)`.

Estimation, as it ended after verifier round 1:

1. Tiles (48 px) are ranked on a preview and measured on **native pixels**, each a radial
   registration of R and of B against G in linear light with a per-tile fit
   C ≈ αG + β + γρG + δρ (surface colour and colour shading absorbed), clipped pixels excluded,
   correlation gate 0.7.
2. Per 0.1-wide radial band, the median shift; the model is fitted to band medians.
3. Gates: no model without a measured band past r = 0.65; a channel whose bands disagree in
   sign by more than a quarter of their tiles is left alone; a cubic that reverses direction
   inside the frame falls back to a plain magnification; a channel under 0.12 px anywhere is
   left alone.

In the app, `LensInputsCache` measures once per file on native tiles rendered from a lazily
evaluated full-size decode it opens itself, so preview and export get the same model. The
CLI measures on its input at full size.

Results, auditor tool `fringe_metrics.py --compare`, native renders, R−G / B−G zone medians
in px (before → after):

| photo | r 0.6–0.8 | r 0.8–1.0 | verdict |
|---|---|---|---|
| 1840 D850 | R +0.490 → +0.051, B −0.177 → −0.075 | R +0.520 → −0.009, B −0.103 → +0.032 | PASS |
| 4213 Z7II | R −0.228 → +0.028, B −0.155 → +0.071 | R −0.275 → +0.015, B −0.187 → +0.069 | PASS |
| 2545 GX85 | R +0.217 → −0.022, B −0.038 → −0.004 | R +0.224 → −0.022, B −0.015 → +0.026 | PASS |
| 3437 T7i | R −0.066 → −0.066, B −0.511 → −0.041 | R −0.039 → −0.046, B −0.576 → +0.073 | PASS |
| 6001 X-H2 | no model: bit-identical | | PASS (2.7) |
| 6929 A7 IV | no model: bit-identical | | PASS (2.7, 2.8) |

VERIFY2_PLACEHOLDER

## 3. Defringe

Lightroom's controls and scales (Purple/Green Amount 0–20, two Hue ends 0–100, defaults 30/70
and 40/60, minimum span 10). A pixel within a few px of a ≥ 0.7–2 stop luminance edge, with
OKLab hue inside the range, is pulled toward its own Rec.2020 luminance by
`1 − e^(−amount/4)`; luminance is kept exactly. The 0–100 hue scale uses the one published
measurement of Lightroom's (purple 30/70 → OKLab 279–351°, green 40/60 → 148–184°); Adobe
does not document it.

On 6929 at Purple 20, purple-band edge pixels lose 85 % of their chroma, blue-band (230–279°)
6 % and green 0 %, nothing moves away from edges, and whole-frame ΔE2000 at Purple 5 /
Green 5 is 0.038 (1840) and 0.0001 (4213). `evidence/defringe-sweep.png` shows the violet
rims fading from 0 to 2 to 5 and gone at 20, foliage and sky untouched.

**Spec 3.5's second clause FAILS and is reported as such:** the auditor tool's
purple+green fringe-edge count in the corner zone falls 7 % (1840, Purple 5 / Green 5) and
5–25 % (6929, Purple 20), against ≥ 50 %. Two reasons, neither fixed here:

- The tool calls a pixel a fringe when its colour departs from a prediction interpolated
  from the two flat sides of the edge, and classes the DEPARTURE's hue. Defringe pulls a
  purple pixel to grey; beside green foliage the prediction is green, so grey departs from it
  toward magenta and is still counted purple. A desaturating Defringe, Lightroom's included,
  cannot satisfy this metric beside coloured surfaces. The chroma measurement above shows
  the pixels did lose their colour.
- Much of 6929's rim is blue-violet (230–279° OKLab), below Lightroom's default purple
  range (279–351° on the one published measurement). Widening Hue From to ~10 reaches it but
  also greys blue sky along every branch, which is why the default does not.

A fair test of 3.5 needs a fringe metric that compares against the pixel's neutral rather
than a predicted colour, or Lightroom references (`corpus/lightroom/` holds none for these
photos).

## 4. Changes outside this lane's functions (see NEEDS.md)

Four chain call lines (WS-01), `KernelLibrary` roster rows pending (WS-58), six
`SliderEvidenceTests` and `SliderInventory` rows (106 → 112), and one `raw-corpus.yml`
path so the probe runs. `CompareView.swift` has a trailing-comma syntax Swift 6.0.3 on Linux
rejects at the base commit; patched locally for tests, not committed.

## 5. Gates

- `swift build` of LumenCore and LumenRender: clean.
- Linux tests: LINUX_PLACEHOLDER
- macOS CI: CI_PLACEHOLDER
