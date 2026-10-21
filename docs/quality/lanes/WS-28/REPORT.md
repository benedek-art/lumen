# WS-28 Lens corrections: report

Lane C3, branch `quality/c3-lens` from `claude/inspiring-dirac-ulgpch`. Final verdict after
three build/verify rounds: **FAIL, with the remaining lines BLOCKED** (section 6). Verifier
reports: `verify/VERIFY-{1,2,3}.md` (their evidence paths point at session scratch).

## For the owner

- Apple's decode corrects only distortion on the A7 IV and GX85. Lumen now adds Remove CA (on by default, like Lightroom), the A7 IV's own vignetting record (+0.46 EV in the outer ring) and Lightroom-style Defringe.
- Remove CA cuts corner colour misregistration by 72–96 % on the corpus frames that have it; two frames end slightly past the spec's limits (0.11 and 0.20 px), invisible at 100 % per the verifier's crops.
- Measuring CA from the photo has a ceiling: the same lens reads differently on different content. Lightroom's Remove CA has the same nature; a per-lens profile would not.
- Try by hand: Lens section on an A7 IV and a GX85 file, Defringe Purple 5 on a backlit branch, and how long the first open of a 45 MP file takes (CA is measured once per photo on native pixels).
- Best evidence: `evidence/4213-treeline-ca.png`, `evidence/defringe-sweep.png`, `evidence/6929-vignette.png`.

## 1. What Apple's decode corrects on the owner's cameras

Measured on macOS CI, RAW corpus lane run 39530459990 (`LensProfileRawCorpusTestsProbe`,
`lens-probe:` lines), decode scale 0.5, native px. Lens correction is supported and on by
default for both bodies.

| | A7 IV (6929, FE 50 F2.5 at f/5) | A7 IV APS-C (6934) | GX85 (2545, 4:3) | GX85 (2547, 16:9) |
|---|---|---|---|---|
| Distortion (green on vs off, r = 0.5 / 0.75 / 1) | 1.72 / 0.08 / −4.58 px | 1.75 / 1.19 / −1.09 | 4.84 / −6.60 / −34.67 | 5.56 / −2.25 / −22.76 |
| Lateral CA, B at r = 1, profile off → on | 0.22 → 0.21 px | 0.29 → 0.31 | 0.17 → 0.16 | 0.21 → 0.22 |
| Vignetting, r 0.9–1.0 luminance on/off | 0.9996 (the file's own record says 1.457) | 0.9996 (record 1.137) | 1.0024 (no record) | 1.0059 (no record) |

`isLensCorrectionEnabled` therefore means distortion only. The A7 IV writes vignetting
(0x7032, 0.65 EV at the corner here), lateral CA (0x7035) and distortion (0x7037) records;
Apple applies none of the first two. The GX85's RW2 has DistortionInfo (0x0119), which Apple
applies, and no vignetting record.

Added by this lane, after S3 and before S5, on both renderers:

- **Sony vignetting** from 0x7032 under `lens.profile` (darktable's knot encoding, fitted as
  1 + a·r² + b·r⁴ + c·r⁶ within 1 % of the knots). 6929: the r 0.9–1.0 ring rises 0.458 EV
  relative to the centre (spec 4.4, 0.45–0.70: passes at the low edge). No double correction:
  the probe shows Apple leaves the record unapplied.
- **Remove CA** for every camera (section 2).
- **Not added:** GX85 vignetting (no data in the file; needs a lens-profile database), Sony's
  embedded CA record (≤ 0.8 px at the corner by its own numbers; the estimator covers lateral CA
  for every camera).

## 2. Remove Chromatic Aberration

Engine `LateralCAEstimator` + `LensStage.warp` (`Sources/LumenCore/Engine/LensStage.swift`),
GPU twin `lumenLens` (CIKL generated beside the Swift), chained in `RenderGraph+Lens.swift`.
R and B are resampled (Catmull–Rom) at `centre + (p − centre)(1 + k0 + k2·r²)`.

Estimation (final): tiles ranked on a 2048 px preview and measured on native pixels (the app
renders them from a lazily evaluated full-size decode it opens itself; the CLI reads them from
its input; one path, verified equal within 0.03 px); per tile, a radial registration of R and B
against G in linear light with surface-colour and shading terms, clipped pixels excluded,
correlation gate 0.7; per-band medians; gates for coverage (a band past r = 0.65), sign
agreement, no direction reversal, split-half agreement with shrink to the weaker half, and a
0.12 px per-channel floor. One measurement per file, shared by preview and export.

Auditor tool `fringe_metrics.py --compare`, native renders, final code (round 3, reproduced
byte-for-byte by the verifier). R−G / B−G zone medians, px:

| photo | r 0.6–0.8 | r 0.8–1.0 | verdict |
|---|---|---|---|
| 1840 D850 | R +0.490 → +0.046, B −0.177 → −0.056 | R +0.520 → −0.038, B −0.103 → +0.045 | PASS |
| 4213 Z7II | R −0.228 → +0.021, B −0.155 → +0.056 | R −0.275 → +0.012, B −0.187 → +0.053 | PASS |
| 2545 GX85 | R +0.217 → −0.037, B −0.038 → −0.050 | R +0.224 → −0.062, B −0.015 → −0.033 | PASS |
| 3437 T7i | B −0.511 → −0.024 | **B −0.576 → +0.114** (overcorrection > 0.1) | **FAIL → BLOCKED** |
| 6001 X-H2 | R +0.134 → +0.002, B +0.247 → +0.018 | R +0.326 → +0.096, **B +0.071 → −0.203** | **2.7 FAIL → BLOCKED** |
| 6929 A7 IV | no model, byte-identical | | PASS |

How it got here: the first estimator overcorrected ~2× (log-domain fit read surface colour
as shift; tiles only in the centre); round 1 found it invented blue CA and differed by decode
scale; round 2 found the app's tile ranking differed from the CLI's. Each fix is in the
history and in comments at the code.

## 3. Defringe

Lightroom's controls and scales (Purple/Green Amount 0–20, two Hue ends 0–100, defaults
30/70 and 40/60, 10-unit minimum span). A pixel near a hard luminance edge whose OKLab hue
is in range is pulled toward its own Rec.2020 luminance by `1 − e^(−amount/4)`; luminance is
exact. The hue scale follows the only published measurement of Lightroom's (purple 30/70 →
279–351°, green 40/60 → 148–184°).

On 6929 at Purple 20, purple-band edge pixels lose 85 % of their chroma, blue-band 6 %, green
0 %; nothing moves away from edges; whole-frame ΔE2000 at Purple 5 / Green 5 is 0.039 (1840)
and 0.0001 (4213). `evidence/defringe-sweep.png`: violet rims fade 0 → 2 → 5, gone at 20.

## 4. Spec verdicts (round 3)

| # | measured | verdict |
|---|---|---|
| 1.1, 1.2 | probe lines for 6929, 2545 (+6 more files); section 1 | PASS |
| 2.1–2.5 | `LensStageTests` 18/18 (incl. app-path, sign gate, hue span) | PASS |
| 2.6 1840, 4213, 2545 | section 2 | PASS |
| 2.6 3437 | corner B +0.114 (seed 99: +0.124) | FAIL → BLOCKED |
| 2.7 6929 | byte-identical | PASS |
| 2.7 6001 | corner B 0.132 px worse; every other zone improves | FAIL → BLOCKED |
| 2.8 | 6929 byte-identical; 6001 gets a model | FAIL → BLOCKED (spec premise) |
| 3.1–3.4 | unit tests | PASS |
| 3.5 ΔE | 0.039 / 0.0001 | PASS |
| 3.5 count | 1840 corner −30 % (needs −50 %); 6929 −5…−25 % | FAIL → BLOCKED (metric) |
| 4.1–4.4 | unit tests; +0.458 EV | PASS (4.4 at the low edge) |
| 5.1, 5.2 | macOS GPU parity, test-fast, build-macos green on a939139; no kernel changed since; `LensInputsCache` changed since and has not been through a macOS compiler at the final commit | PASS on a939139 |
| 6.1–6.4 | sheets in `evidence/`; verifier's own crops show no harm | PASS |

## 5. Gates

- Build: LumenCore and LumenRender clean on Linux; whole package incl. app on macOS CI (a939139).
- Linux tests: full bundle on 9bda872 3073 tests, 0 failures, 6 skipped; `LensStageTests`
  18/18 at the final commit; SettingsSubset, ResetSemantics, SliderEvidence and
  RecipeCodecTolerance re-run green by the verifier.
- macOS CI on a939139: GPU parity, UI layout, UI snapshots, CI build-macos, test-fast,
  app-bundle, engine-linux green. CI fixtures-linux (surface checker) failed on this lane's
  multi-declaration lines, fixed in 6458d84; the step's remaining findings are identical on the
  base commit (not this lane's).
- Verifier: FAIL in rounds 1, 2 and 3; what is left is below.

## 6. BLOCKED, and what it would take

1. **2.6 on 3437 and 2.7 on 6001 (blue, corner zone).** The estimator reads more CA in those
   corners than the auditor tool does (3437: −1.14 against −0.51 px; a centre crop of the same
   photo reads −0.35 px at the same radius). Measuring CA from image content has this ceiling:
   the answer depends on what the corner contains. The fix is a per-lens profile (Adobe's or
   lensfun's TCA coefficients), not more estimator tuning. Neither overshoot is visible at
   100 % in the verifier's crops (`r3/crops/`).
2. **2.8 on 6001.** The spec assumed 6001 has no CA; the auditor tool shows +0.326 px red at
   its corner, which the correction reduces to +0.096. The spec line should move 6001's red to
   2.6. Its blue is item 1.
3. **3.5 fringe count.** The tool classes a fringe by its departure from colours predicted from
   the edge's flat sides, so a pixel Defringe turns grey beside green foliage still counts as
   purple; a desaturating Defringe, Lightroom's included, cannot satisfy it. The direct chroma
   measurement (section 3) and the evidence sheet show the fringes going. A fair test needs a
   neutral-referenced metric or Lightroom references for these photos.

Known small gaps, not blocking: the split-half gate interleaves neighbouring tiles, so both
halves see the same objects and it caught neither failure above (untested for disagreeing
halves); a file only ever rendered below 1200 px keeps a vignetting cache entry that is never
evicted; the first render of each photo measures CA synchronously (time it on macOS).

## 7. Changes outside this lane's functions (NEEDS.md)

Four chain call lines (WS-01); `KernelLibrary` roster rows pending (WS-58); six
`SliderEvidenceTests` rows and six `SliderInventory` rows (106 → 112); one `raw-corpus.yml`
path so the probe runs on push. `CompareView.swift` does not parse on the Linux toolchain at
the base commit; patched locally for tests, not committed.
