# Independent Classic sinusoid and step diagnostic

This optional CPU diagnostic addresses a gap in `DenoiseQualityTests`: its fine-texture correlation calls the same production à-trous decomposition used by Classic. The new oracle projects known analytic sinusoids directly onto sine/cosine bases and measures known step contrasts. No production algorithm, profile, defaults, saved looks, existing test, tolerance or golden changed.

## Executed source and scope

Harness checkout base: `99b2db8`; linked optimized Core objects came from the earlier `/lumen` build checkout (HEAD `5ced9c3` with working-tree changes). This is **not an exact99b2 whole-package build**. Harness commits: `1b76163` (initial sweep), followed by the Detail/Smoothness extension in this branch. Runs link existing optimized LumenCore objects, rather than copying Classic. `DenoiseEngine.swift` matches the built checkout exactly: SHA256 `1ce07c09fa944aaffac3bdc89824ddec7cdeb7021fadb7d8c271d67aed19788e`. Each provenance file records the complete compile command, Swift version, harness hash, object/module hashes and execution status. The run-time harness hashes describe the actual executed contents, including uncommitted edits at execution; the Git base field alone does not identify those edits. Each successful evidence directory also contains the exact executed Swift harness, verified against that hash; the maintained harness differs from the successful follow-up only in explanatory comments.

Baseline: **84 metric rows, 28 exact zero-stage identities, 84 finite images**, compile/execution exits both zero. Seven patterns × two ISOs (1600/6400) × two seeds (17/29), evaluated Off/ISO-default/maximum. This is 56 nonzero Classic calls, plus 28 identity calls. Four neutral sinusoidal fields cover 2/16 cycles per 64 pixels and amplitudes 0.01/0.08; one constant-luminance chroma sinusoid and two neutral/chroma steps complete the set.

Follow-up: **22 metric rows, 19 unique actual Classic calls**, two exact zero identities, all 22 outputs finite, compile/execution exits zero. It uses ISO6400/seed17 on the high-frequency high-contrast neutral field and chroma sinusoid, varying the corresponding Detail at 0/50/100, plus chroma Smoothness at 0/100. Duplicate complete configurations reuse the computed output. Four master baselines and two Off rows reproduce the prior MSE/sine/cosine/DC values exactly. The original run did not log input hashes. The follow-up logs one shared raw-f32 XXH64 per field across all its variants: neutral `bdd09a895f86d4d2`, chroma `4177df68f4a227fc`.

Noise is independent RGB Gaussian with variance `a*clean+b` using the actual generic profile's coefficients, with common deterministic standard-normal draws across patterns. It is **variance-matched Gaussian**, not exact low-count Poisson sampling, measured camera noise or a learned model. No clipping was applied; both runs recorded zero negative and zero above-one noisy RGB channels. Sinusoid projections include the entire 64×64 field, with integer cycles and no window. Step measurements use four columns each side of the midpoint and separate far plateaus at x=8...15 and x=48...55, over all rows. Clean-input projection/contrast checks bound f32 construction error at 1e-7; this is an oracle-construction check, not a denoise quality threshold.

The historical snapshot comparison is archived as `classic-independent-projection/historical-current-v-built-core.json`. It finds five modified files (catalog, XMP, slider interaction and ReferenceRenderer) plus the current-only ScalarDragSession file. DenoiseEngine, Recipe, spatial/image and math source snapshots match. Those observations do not turn a post-execution snapshot into a build-time source manifest; original object/module hashes remain authoritative for the executed binary. The maintained runner now records complete Core manifests and **requires every Core source to match** the declared built checkout. No mismatch allowlist or historical-provenance rewrite is used. A fresh candidate Core release build and metric replay subsequently executed; see below.

## Measurements, not new acceptance bars

Baseline contains **14 of 56 nonzero cells with MSE worse than Off**. All four chroma-sinusoid ISO-default cells have MSE ratios 1.7533–2.9260 and amplitude retention 0.2504–0.5603. At maximum these become 2.3355–6.5048 and 0.0590–0.2438. High-frequency, high-contrast neutral fields at maximum have MSE ratios 2.4534–2.5663, with amplitude retention 0.7185–0.8650. Two low-contrast high-frequency neutral cells at maximum also worsen MSE.

Neutral step near-edge contrast retention is 0.9829–0.9974 at ISO defaults and 0.9549–0.9805 at maximum. Chroma step near-edge retention is 0.7189–0.8696 and 0.5907–0.7706, respectively, even though its full-frame MSE improves. Far chroma plateau retention remains 0.9555–0.9829 at defaults and 0.9466–0.9729 at maximum: near-edge loss and broad plateau drift are different measurements.

The bounded Detail follow-up gives:

| Field / masters | Detail 0: MSE ratio / amplitude | Detail 50 | Detail 100 |
|---|---:|---:|---:|
| Neutral / ISO defaults | 0.9582 / 0.8521 | 0.6124 / 0.9014 | 0.4070 / 0.9508 |
| Neutral / maximum | 5.3708 / 0.5794 | 2.5663 / 0.7192 | 0.8787 / 0.8596 |
| Chroma / ISO defaults | 1.7879 / 0.2514 | 1.7879 / 0.2514 | 1.7879 / 0.2514 |
| Chroma / maximum | 2.3672 / 0.0611 | 2.3672 / 0.0611 | 2.3672 / 0.0611 |

Luminance Detail has measured authority here. Color Detail's three tested positions produce identical observed metrics in this particular chroma field; this does not establish that the slider is globally ineffective. Source review shows it protects according to a gradient of **chroma magnitude**, and this period-four sign-changing field has nearly constant magnitude. Chroma Smoothness 0→100 further reduces amplitude here: 0.3088→0.2351 at default masters and 0.0940→0.0496 at maximum, with MSE ratios worsening 1.5940→1.8427 and 2.2266→2.4149.

The ISO-default neutral baseline uses adaptive Luminance Detail 45.0375, not 50. The first follow-up attempt incorrectly assumed a Detail50 baseline would replay it; the explicit baseline check rejected that run. Its exit1 log is preserved under `detail-initial-rejected`. The corrected run replays the actual baseline configuration before varying Detail. This was a harness assumption failure, not a production failure or an infrastructure crash.

Raw CSV includes phase, DC bias, clean projections, profile coefficients, complete varied slider settings and every worse-MSE cell. No aesthetic threshold was invented, and these measurements do not justify an automatic retune. Two seeds, fixed patch dimensions and a generic profile do not establish camera or natural-texture calibration. Full-frame MSE, sinusoidal authority, noise suppression and edge survival can trade off. GPU equivalence, private-photo detail, camera color and AI denoise quality are separate gates.

## Reproduce

Build the matching LumenCore source in release, then use the printed exact command in each `provenance.json`. The historical executed cloud command was (the runner then checked DenoiseEngine only; its legacy build does not satisfy the maintained full-Core check):

```sh
LD_LIBRARY_PATH=/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu \
python scripts/audit-classic-projection.py \
  --build-dir /workspace/scratch/2982a056243e/build-sqlite/x86_64-unknown-linux-gnu/release \
  --built-source-root /workspace/scratch/2982a056243e/lumen \
  --output-dir /workspace/scratch/2982a056243e/classic-projection-evidence \
  --swiftc /workspace/scratch/2982a056243e/swift/usr/bin/swiftc \
  --include-dir /workspace/scratch/2982a056243e/swift-deps/usr/include \
  --library-dir /workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu
```

Use a **new output directory** for each run. For the follow-up add `--mode detail --baseline-csv PATH/metrics.csv`, pointing at the baseline CSV. This diagnostic is optional and is not attached to required CI or substituted for the existing denoise qualifications. Compile/execution seconds in provenance describe this tiny harness, not editor responsiveness or native-camera denoise performance.

## Fresh candidate-source replay

After the sidecar/pick/regular-export candidate Core was frozen, `swift build -c release --scratch-path /workspace/scratch/2982a056243e/build-final-core --jobs 2 --target LumenCore -Xcc -I/workspace/scratch/2982a056243e/swift-deps/usr/include` completed exit0 in78.41s (toolchain/dependency environment as above). No denoise source/default changed. The maintained full-Core-matching runner then executed84 baseline rows and22 Detail rows against these fresh optimized objects: both compile/execution exits0,28+2 exact zero-stage identities and all106 outputs finite. Baseline14/56 worse-than-Off cells and Detail results remain unchanged.

Every original field in all84 baseline rows is exactly equal to the historical sweep; the maintained harness adds4 explicit configuration/input-hash columns, so whole baseline CSV bytes/dictionaries differ. Initial whole-file/full-dictionary comparisons rejected that format difference; no numeric tolerance was introduced to clear it. The complete22-row Detail CSV is byte-identical. `fresh-source-replay.json` records both comparisons and hashes. `fresh-baseline/` and `fresh-detail/` contain exact executed harnesses, commands, object/module hashes and complete Core manifests with **zero** current-versus-built-checkout differences. `fresh-core-build-manifest.json` is a post-build snapshot of the unchanged frozen Core, explicitly not a compiler-generated build-time manifest. The pending publication's file hashes identify this uncommitted candidate; hosted exact-head validation remains separate.

The maintained runner requires a fresh full-Core match. Historical legacy-build results remain qualified separately and were not rewritten. These are mathematical CPU texture diagnostics, not macOS GPU, real-camera, AI-model or subjective denoise acceptance.
