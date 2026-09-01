# R6 — the denoise decision

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r6-denoise-decision.md`.

The owner has lifted the deferral on denoise: *"we have to make the decision whether we
can find an open source denoise that is good and we can add onto it, or we build our
own… as long as it's free, find the best one."* Your dossier ends in a **recommendation**.

## Lumen today (read before recommending)
- `Sources/LumenCore/Image/DenoiseEngine.swift` — classical NR (VST + à-trous shrinkage
  + hot pixels) and an "AI splice" (`AIDenoiseSplice`) modelled but wired to no model;
  `.ai` mode drives the Apple decoder's own NR as a stand-in, on RAW only.
- `docs/07-spec-denoise.md` — the spec and bake-off protocol.
- `docs/17-appendix.md` — the licence ledger and model zoo as of last update.
- `Tests/LumenCoreTests/Proof/DenoiseQualityTests.swift` — the ground-truth pair
  (`noisyISO6400`/`cleanISO6400`) and what "good" is measured as.
- Delivery decided: **download on first use** from a GitHub release asset, hash-verified.

## Survey (search each; tag sources)
**Algorithmic (no model):** darktable `denoise (profiled)` NLM + wavelets; RT wavelet
NR; BM3D / BM3D-CFA; Neat-style profiled; Anscombe VST + shrinkage (what Lumen has).
**Learned, RGB domain:** NAFNet, Restormer, KBNet, SCUNet, DRUNet, SwinIR, Uformer,
MIRNet-v2, NBNet. **Learned, raw/CFA domain:** PMRID, LLPackNet, ELD-trained models,
"unprocessing"-trained UNets, SID (learning-to-see-in-the-dark) descendants,
DeepPRIME-class (closed; note only). **Self-supervised:** Noise2Noise/Noise2Void/
Neighbor2Neighbor (train-free-ish options).

For each candidate: licence (MIT/Apache/BSD/GPL/non-commercial — **flag anything not
free for commercial use**), model size (MB, params), input domain (RGB sRGB / linear /
raw CFA / packed 4-ch), pretrained weights availability and their noise model
(Gaussian σ / real SIDD / real raw), CoreML convertibility (ops used; known
conversions), Apple-silicon inference cost at 12–45 MP (tiles? ms per MP), published
PSNR/SSIM on SIDD/DND, and the integration surface: where in Lumen's stage order
(docs/14 S2/S3) it would splice, at what resolution, and what the classical engine
still does around it (hot pixels, chroma).

## Decide
Recommend ONE of: **adopt X** (name it) · **build on the classical engine** (what
specifically) · **hybrid** (X for luminance at ≤ N MP with the classical chroma pass).
Give: the integration steps in order (conversion → bundle/download → `AIDenoiseSplice`
wiring → the quality gate in `DenoiseQualityTests` → the export path), what it costs
(download MB, ms/MP, licence obligations), and the risk (what could make it fail on a
Mac we cannot test on). If nothing free is clearly better than the classical engine on
the measured ground-truth pair, say so and recommend the classical improvements instead.
