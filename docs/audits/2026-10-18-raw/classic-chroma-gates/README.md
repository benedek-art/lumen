# Causal isolation of Color Detail's flat response on one synthetic field

This is diagnostic evidence only. The two functional changes below were built in isolated worktrees and are **not production changes or retune recommendations**. No shipped math/default/profile, existing test, tolerance or golden changed in the audit branch. Everything added by this commit is under this documentation directory.

## Question and design

The previous nine-call study found Color Detail 0/50/100 produced identical complete f32 images on the fixed period-four chroma sinusoid with Luminance NR disabled. That removed one cross-control confound, but did not prove whether chroma edge weighting or the later smoothing pass explained the missing authority.

This study compares the unchanged engine with two **separate single-functional-gate mutants** of Core base `5d1ff3a`:

- **E:** compute the original chroma-magnitude edge plane, record its scalar min/max/nonzero count, then replace only the edge plane consumed by shrinkage with all ones. Later smoothing and thresholds remain unchanged.
- **S:** leave the computed edge plane and threshold calculation unchanged, but set only the later blotch `mixAmount` to zero. Guided-filter calculation still runs; the existing mix routine returns its input at zero. This differs from setting Color Smoothness to zero, which would also change coarse-band thresholds and confound the question.

Both diagnostic builds additionally print the same scalar observations of the actual **pre-mutation** edge plane. That observational code is explicitly disclosed in the retained patches; the builds therefore differ from production by one functional gate plus observation logging. The mutants were built in new isolated scratch directories, not by overwriting the reference objects. Complete pre/post-build Core manifests match within each build; each differs from the reference in **only `Image/DenoiseEngine.swift`**. Exact build commands, source diffs, source states, compiler version and object/module hashes are retained. Build exits were zero (E 80.89s, S 80.43s); those times are infrastructure observations, not product performance measurements.

The original engine was rerun because the earlier study retained image hashes, not full arrays. All seven original output hashes reproduce the prior records exactly. Original/E/S each evaluate Off plus Color Detail 0/50/100 at Chroma25 and Chroma100, always with Luminance0 and Hot Pixels0: **21 actual calls total**, all outputs finite, three exact Off identities. The input raw-f32 XXH64 is asserted as **`4177df68f4a227fc`** in every run. All controls and profile values are recorded in the CSVs. No input clipping was applied; the input has zero negative or above-one RGB channels.

The known input is ISO6400/seed17, 64×64, analytic constant-Rec.2020-Y chroma sinusoid, amplitude0.04 at16 cycles per width, with matched-variance Gaussian RGB noise. Direct clean-RGB MSE and sine/cosine/DC projection are independent of production wavelet analysis. Constant Rec.2020 Y remains distinct from constant orthonormal VST Y0; see the preceding study for that basis qualification.

## Executed results

The original computed edge plane has **minimum0, maximum0, nonzero0 out of4096** in all six nonzero configurations, observed before E's replacement and in S's unchanged gate. This was measured, not inferred merely from the RGB field's appearance.

| Engine / block | Detail0 amplitude | Detail50 amplitude | Detail100 amplitude | Complete f32 arrays across Detail |
|---|---:|---:|---:|---|
| Original / Chroma25 | 0.314664 | 0.314664 | 0.314664 | Exactly equal |
| E: edge→1 / Chroma25 | 0.314664 | 0.602613 | 0.988989 | Different |
| S: late mix→0 / Chroma25 | 0.318165 | 0.318165 | 0.318165 | Exactly equal |
| Original / Chroma100 | 0.166774 | 0.166774 | 0.166774 | Exactly equal |
| E: edge→1 / Chroma100 | 0.166774 | 0.425755 | 0.960422 | Different |
| S: late mix→0 / Chroma100 | 0.169455 | 0.169455 | 0.169455 | Exactly equal |

E's Detail0 results are **byte-exact and float-array-exact to the unchanged engine**, for both blocks. This is the causal neutral control: the edge multiplier has no authority when Color Detail/protection is zero. At Detail100 E differs from its Detail0 by maximum absolute pixel differences 0.0305318683 (Chroma25) and 0.0402554274 (Chroma100). All Off outputs remain byte-exact and float-array-exact across builds. The comparison script asserts these neutral controls and also asserts that S's Detail0 output changes from the original in each block, demonstrating that the isolated late-mix intervention actually reaches the result. It asserts the recorded pre-mutation gate is zero in all4096 entries in both diagnostic builds.

At Detail0/50/100, E's MSE ratios against Off are 1.916640 / 1.218478 / 0.979097 for Chroma25 and 2.423117 / 1.585524 / 0.944888 for Chroma100. S gives1.909165 and2.414579 at all three positions, respectively. These measurements describe this constructed signal/noise trade-off; they do not establish an acceptable universal setting or justify forcing the gate open on real photographs. Full CSVs also retain phase and DC bias.

## Supported conclusion and limits

On **this exact field/configuration**, the zero computed edge plane causally suppresses Color Detail authority. The source's soft-threshold rule multiplies protection by the edge value, so edge0 removes dependence on Detail. Forcing that one gate open restores measured authority while retaining the downstream smoothing; disabling only later smoothing leaves the flat response intact. Later smoothing therefore is not the sole cause of the missing response here, although it measurably changes the output.

This does **not** establish why every computed edge value fell below its knees. The field's sign-changing nearly constant chroma magnitude, spatial blur, noise/model units and edge thresholds remain possible contributing factors. No second mutation separated those sub-causes. The experiment does not show Color Detail is globally ineffective, nor that all-one edge protection is a valid fix: it also protects noise and can undermine denoising elsewhere. Camera calibration, natural-texture aesthetics, GPU equivalence, AI denoise/model quality and private-photo acceptance remain separate.

## Reproduce and audit artifacts

- `executed-harness.swift`: exact common successful client; original/E/S use the same file hash.
- `E/` and `S/`: exact single-gate source patches, complete before/after source manifests, source states, build logs and command/object provenance.
- `original/`, `E/`, `S/`: raw metric CSVs, summaries and compilation/execution logs/provenance.
- `comparisons.json`: full-array comparisons within and across builds, including byte equality, numeric equality, maximum differences and SHA256 of each compared raw output.
- `raw-output-manifest.json`: sizes/hashes of the temporary full f32 outputs. Raw arrays and executable binaries remain scratch evidence and are not committed; they can be regenerated by the retained commands. No photographs were used.
- `build-mutant.py`, `run-mode.py`, `compare.py`: exact experiment orchestration. Paths identify the executed cloud worktrees and toolchain; reuse requires fresh output/build directories or deliberate path changes. Existing accepted metric CSVs are protected from accidental overwrite by `run-mode.py`.

The executed sequence was:

```sh
python docs/audits/2026-10-18-raw/classic-chroma-gates/build-mutant.py E
python docs/audits/2026-10-18-raw/classic-chroma-gates/build-mutant.py S
python docs/audits/2026-10-18-raw/classic-chroma-gates/run-mode.py original
python docs/audits/2026-10-18-raw/classic-chroma-gates/run-mode.py E
python docs/audits/2026-10-18-raw/classic-chroma-gates/run-mode.py S
python docs/audits/2026-10-18-raw/classic-chroma-gates/compare.py /workspace/scratch/2982a056243e/classic-chroma-gate-evidence
```

The two builds ran independently in parallel. All build/compile/execution exits were zero, and causal neutral controls passed. This is CPU mathematical diagnostic evidence, not a whole-app build, native GUI test or camera-quality acceptance result.
