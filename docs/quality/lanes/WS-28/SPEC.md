# WS-28 Lens corrections: acceptance spec

Owner lane C3. Each line is a claim, a threshold and the command that measures it.
`BIN=$(swift build -c release --show-bin-path)/lumen-render`. Native-resolution
decodes live in `corpus/lfi-native/` (`decode_raw.py … --long-edge 0`; LibRaw applies no
lens correction, so these are the uncorrected lens). The independent measurement tool
is `tools/fringe_metrics.py`, written by the auditor and sharing no code with the
estimator under test.

Note on order: the spec was written after the first engine draft, from the audit's
first numbers and Lightroom's documented behaviour. The thresholds were set before any
corpus measurement of the corrected output.

## 1. What Apple's decode corrects (owner's cameras)

1.1 For every lens-correction-supported file in the RAW corpus lane (incl. 6929 A7 IV,
6934 A7 IV APS-C, 2545/2547 GX85), the macOS probe logs: green on-vs-off radial
displacement (distortion), R−G and B−G misregistration with the profile off and on
(lateral CA), and the on/off luminance ratio per radial ring beside the file's own
vignetting record. PASS = the lines exist for 6929 and 2545.
`raw-corpus.yml` (workflow_dispatch on the lane branch), grep `lens-probe:`.

1.2 The REPORT states, per camera, what is and is not corrected, with those numbers.

## 2. Remove Chromatic Aberration (lateral CA)

2.1 Synthetic, known magnification (constant R 1.0006 / B 0.99945; and r²-dependent):
the estimated scale is within 6e-5 (7e-5 for the r² case) of truth at r = 0.3, 0.6, 0.9.
`swift test --filter LensStageTests.testEstimatorRecovers`

2.2 Synthetic, after correction: |median R−G| and |median B−G| radial misregistration
over tiles at r > 0.6 < 0.05 px (before > 0.4 px), and re-estimation finds no
significant model. `swift test --filter LensStageTests.testCorrectionLeaves`

2.3 A CA-free frame (tinted, sharp edges) yields no model and the stage output is
bit-identical to its input. `…testCAFreeFrameIsAnExactIdentity`

2.4 Remove CA off is bit-identical even when a model exists. `…testRemoveCAOffIsIdentity`

2.5 Colour edges (red/blue patches, no lens CA) do not invent a model.
`…testColourEdgesDoNotInventCA`

2.6 Corpus 1840 (D850) and 4213 (Z7II), native decodes: the fitted R−G and B−G
misregistration at r = 1.0 (auditor tool) is reduced by ≥ 60 % and is < 0.25 px after
correction. Command: render `--long-edge 0 --no-dither` with
`--set develop.geometry.lens.removeCA=false` and `=true`, then
`python3 docs/quality/lanes/WS-28/tools/fringe_metrics.py before.png after.png`.

2.7 Same two photos: p90 colour-fringe width in the 0.8–1.0 zone does not grow, and the
median falls (a lens-CA fringe is a misregistration, so its width must shrink with it).

2.8 Photos whose lens shows no significant lateral CA (6929 at its 2400 px or native
decode, if the estimator returns none) are bit-identical with Remove CA on and off.

## 3. Defringe

3.1 Amount 0 (both families) is an exact identity. `…testDefringeZeroIsIdentity`

3.2 Purple Amount 1, 2, 5, 10, 20: the fringe pixel's OKLab chroma falls strictly
monotonically, is < 5 % of the original at 20; Rec.2020 luminance is preserved to 1e-6
relative; the green fringe and a purple object 120 px from any edge are bit-identical.
`…testPurpleFringeRemovedMonotonically`

3.3 Green Amount 10 cuts the green fringe's chroma below 15 %; the purple fringe is
bit-identical. `…testGreenFringe`

3.4 A hue range excluding the fringe's hue leaves it bit-identical. `…testHueRangeExcludes`

3.5 Corpus 1840 and 4213 at Purple 5 / Green 5: whole-frame mean ΔE2000 against
Defringe off < 0.5 (Defringe is local; a global desaturation would show here), and the
purple/green fringe pixel count in the 0.8–1.0 zone falls by ≥ 50 % (auditor tool).
`$BIN sweep --key develop.geometry.lens.defringe.purpleAmount --values 0,5 --set develop.geometry.lens.defringe.greenAmount=…`
(the sweep's ΔE table), plus `fringe_metrics.py`.

## 4. Embedded lens profile (part 4 of the brief)

4.1 The Sony record (0x7032/0x7035/0x7037 in the raw SubIFD) is read; 6929's corner
fall-off decodes to −0.651 EV ± 0.002; a non-Sony file reads as nothing.
`…testSonyRecordIsRead`

4.2 The kernel's polynomial gain × the knot fall-off = 1 ± 1 % for r in [0, 1].
`…testVignettePolynomialTracksKnots`

4.3 Profile on flattens a frame shaded by the record to ±1 %; profile off is
bit-identical. `…testVignetteGainFlattensFalloff`

4.4 Corpus 6929: lumen-render with profile on vs off, the mean luminance of the ring
r 0.9–1.0 rises by 0.45–0.70 EV relative to the ring r < 0.2 (the record says 0.65 at the
corner, less averaged over the ring). Measured with the auditor tool's ring option or
the one-liner in REPORT.md.

## 5. CPU/GPU parity (macOS CI)

5.1 Lens kernels compile; warp+vignette and Defringe match `LensStage.apply` within 2e-3
at 256², 331×197, 128×320, each case moving pixels by > 0.03; defaults with no inputs
return the input image object. `LensStageGPUParityTests` in `gpu-parity.yml`.

5.2 Existing parity and golden suites stay green (`ci.yml`, `gpu-parity.yml`).

## 6. Visual claims (human-judged, sheets in `evidence/`)

6.1 `evidence/1840-corner-ca.png`: 100 % crop of branches against sky in the corner,
Remove CA off | on. The red/cyan (or blue/yellow) edge pairs visible off are gone on;
no new halo, no edge softening of the red or blue channel.

6.2 `evidence/4213-castle-ca.png`: castle edge against flat sky, off | on, same reading.

6.3 `evidence/defringe-sweep.png`: Purple Amount 0/2/5/10/20 on a high-contrast corner
crop; fringes fade progressively; nothing away from edges changes colour.

6.4 `evidence/6929-vignette.png`: A7 IV profile off | on, whole frame; corners lifted to
match the centre without a visible ring.
