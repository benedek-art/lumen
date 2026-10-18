# Lumen cloud accuracy and reliability audit

Qualified source: **`a4bc1506e0e744f58089b56bfbc8953b2d3e6fc0`**, continuing checkpoint `0f57d65710e8f13b919a06257825507bdd6ff1b4` on `codex/raw-accuracy-qualification`, [draft PR10](https://github.com/benedek-art/lumen/pull/10). A later evidence-only commit may be the branch head; the executed source SHA stays explicit. No release, main merge, Mac installation or private-photo upload occurred.

**The complete ordinary suite passes, but mathematical and camera qualification is incomplete.** A targeted native diagnostic confirms a positive local Amount discontinuity; it remains strict and RED. This report separates that failure from verified repairs and camera/denoise quality.

## Executed results

| Scope and source | Exact result | Limit |
|---|---|---|
| a4bc full optimized Mac | **3509 tests,42 intentional skips,0 unexpected failures**,301.137 test/631.694 wall seconds; [CI39136447281](https://github.com/benedek-art/lumen/actions/runs/39136447281) | All3 new neutral-WB methods positively passed. Skips are not camera or opt-in acceptance |
| a4bc ordinary GPU | **263/32skip/0fail**,466.093s; [GPU39136447337](https://github.com/benedek-art/lumen/actions/runs/39136447337) | The separate diagnostic in this workflow fails; the workflow is not wholly green |
| a4bc Core/proof/build | Linux2646 selected passed; proof6/0fail33.798s; app build/bundle/fixtures passed | [Proof39136447315](https://github.com/benedek-art/lumen/actions/runs/39136447315); no release |
| a4bc layout |19/0unexpected,1.137s; [39136447269](https://github.com/benedek-art/lumen/actions/runs/39136447269) |3 existing expected precision-floor findings remain |
| a4bc neutral-WB causal check | Baseline3/0fail7.626s; restoring only old flag gives3tests/**10 genuine assertions**3.322s; nonneutral control stays green; source restored | [Job117701884220](https://github.com/benedek-art/lumen/actions/runs/39136447281/job/117701884220); exact neutral synthetic inputs, not all WB/camera behavior |
| a4bc targeted Amount diagnostic | **1test/1 genuine parity assertion failure**,10.562s; all28JSON records valid | [Job117701803273](https://github.com/benedek-art/lumen/actions/runs/39136447337/job/117701803273); independent equations, finite/zero/exposure/scalar-alpha controls pass; parity does not |
| c7 combined geometry causal check | Baseline5/0fail; wrong-order mutant16assertions across all3 new methods; old2methods green; restored | [CI39132544299](https://github.com/benedek-art/lumen/actions/runs/39132544299); no production geometry defect established |
| B752 public RAW consumers |180/180 consumer pairs +18/18 fresh-process pairs exactly equal; separate RAW9 display12/12 pairs,16 nonblack renders | [RAW39130688910](https://github.com/benedek-art/lumen/actions/runs/39130688910), [RAW9 runtime39130688862](https://github.com/benedek-art/lumen/actions/runs/39130688862); limited public fixtures, not owner's photographs |
| B752 full public RAW corpus |13tests/**5 retained assertion failures** | Older-runtime Leica black output plus2 guessed neutral-chroma alarms; not erased by consumer identity passes |

No RAW job triggered at a4bc through its narrow path filters; B752 remains the explicitly executed camera/corpus source. The test-only4fba revision was compile-blocked by ambiguous `pow(2,12)`; explicitDouble literals repaired the fixture. The subsequent2b96 full Mac run was superseded/cancelled after about20minutes, not counted as a pass. Its production matched fully tested c7. New a4bc production was then fully tested. Exact commands, selected raw records, skips, SHA manifests and chronological failures are in CLOUD-PROGRESS.md.

## Verified changes and before/after evidence

| Problem | Repair and concrete evidence |
|---|---|
| First lazy RAW decode differed from later half-plane cache promotion | Eligible first decode uses the same canonical plane as hits; public Sony boundary reproduced421 changed bytes/max1 code before. Later legacy198 pairs and RAW9 display12 pairs were exact zero. Oversized/allocation-failure policy stays explicit; private first-ROI acceptance is still owed |
| Rounded numeric text/off-grid nudges and stale gestures could write unintended values/targets | Unchanged text preserves the original precise value; outward nudges hold off-grid values; sessions capture target/geometry and final release. Independent nudge witness8 failures→0. Native state/injected-button tests pass; real pointer/focus events remain local gates |
| Recovery and large-batch publication could lose/conflict with edits or settle debt incorrectly | Refuse unsafe future/corrupt/missing-painting recovery; retain exact external bytes and durable debt. Atomic observation/settlement and bounded64-document/8MiB nominal staging passed Core/native causal tests. In-flight keyword rescan previously resurrected a removed tag while XMP/debt settled; durable overlay/current-membership filtering passed2 native tests and two independent mutants (3/1 assertions) |
| Async picks/mattes/exports could use replaced source generations | Per-source identity/epoch checks, bounded matte retry and captured export generation; native races passed. Removing only final publication guard caused2 real assertions while the intact test passed. Regular-file-only implicit binding repairs the `/dev/null` fixture regression; explicit binding and destination preservation remain enforced |
| Brush stabilization used separate-axis coordinates as physical distance | Source long-edge metric removes landscape/portrait anisotropy:1000×500 with30px travel previously gave10px horizontal/20px vertical output. Portable18 tests pass; old metric causes10 assertions, legacy13 controls remain green. Native complete suites include all5 new methods; seed/release/stored stroke coordinates preserved |
| Absolute local WB declared an exactly neutral adaptation nonidentity | **One production assignment** now propagates the existing engine's exact identity flag. Native signed/HDR pixels pass unchanged at33/65, absent/zeroTint; old assignment causes10 assertions. Matrix and interpolation unchanged, nonneutral control exact. Bounded actual-Core20 evaluations including fractional/float-derived Kelvin also all exact; the earlier3333.3 rounding hypothesis was not reproduced |
| Isolated geometry tests missed composed transform order | Added independent array-permutation pixels, pointer math and CPU/GPU mask placement with asymmetric two-axis crop:9 configurations/7 distinct nonidentity transforms plus2 equivalence controls. Wrong-order mutation proves added detection; AA/feather/native events remain unqualified |

COMPATIBILITY-REVIEW.md records the targeted checkpoint diff review. Existing math tolerances, goldens and creative defaults were not loosened/retuned. Stronger preservation assertions replace older permissive export/culling expectations.

## Confirmed mathematical gates still open

**Local/group Amount:** at wheel Amount1e-8, actual GPU S11 maps R−.009999999776/1024 to−.000004937138783/737.280029297, while CPU reference remains essentially unchanged. Maximum stage gap286.719970703. With directly measured alpha.25/.75, HDR gaps are71.679992676/215.039978027. Independent endpoint/composite equations pass (composite error≤2.1973e-5); strict existing1e-3 CPU/GPU parity fails20 configurations, bundled into **one assertion/test**, not20failed tests. Four zero-stage cases and one zero-alpha composite are exact; both exposure-only controls have CPU/GPUerror0. Mask/group and33/65 reproduce it.

This confirms bounded-LUT activation at positive Amount, not a denoise/camera/beauty verdict. Source review predicts related risks for tone/WB/hue/tint and the separate local-curve LUT; the wheel diagnostic does not execute those other controls. See local-amount-epsilon/CONTROL-SCOPE.md. A broad remedy needs independent accuracy, performance and saved-look/versioning evaluation; none was guessed into production.

The first soft-alpha fixture used colour-managed CIColor constants and one JSON record interleaved withstderr. Those limitations remain archived. Corrected scalarRGBAf/nilCS masks read back exactly0/.25/.75, and direct JSON writes yield all28records. Production's scalarRf/nilCS mask bridge differs from that faulty fixture. Historical zero-Amount tests established identity under rendered soft masks, not independently measured literal.25/.75 alpha.

**Dehaze:** independent bright-flat witness still shows CPU/GPU errors≈.222222 at+100 and.043200 at−100. Sky protections differ. Formulas and saved looks were preserved; ordinary suite passes do not certify this parity.

**Layout:**3 expected findings retain the1logical-point/unit target. At320pt minimum column, the model gives142pt track/200units=.71pt/unit. That is a layout model, not a measurement of actual mouse/trackpad subpixel reachability. Fine readout/typed input and native interaction remain separate checks.

## Camera and denoise qualification, separately

On macOS15.7.9, public Leica1087 is black; Nikon5812/Panasonic2607 neutral-chroma values39.276/23.224 exceed the unchanged guessed20 alarm. On same-source B752/macOS27, Leica's3 focused content/option/context methods pass and RAW9 display pairs are nonblack/exact. OS, hardware and toolchain differ together: no OS-only cause or production decoder repair is claimed. These alarms are not calibrated colorimetric acceptance. Original private FIRST-ROI Off/AI0 discrepancy of1–4codes must still be checked locally without weakening exact identity.

Classic ships VST/wavelets; AI is Apple's RAW-denoise stand-in, with no bundled learned model. Both owner's cameras use generic full-frame ISO seeds; estimator/model calibration was not guessed. Independent analytic clean-ground-truth diagnostics found **14/56 nonzero Classic cells worse than Off**, alongside30 exact zero identities. One period-four chroma fixture had no Color Detail authority; controlled edge-gate mutation explains that fixture, not a globally dead slider or acceptable all-ones repair. See CLASSIC-INDEPENDENT-PROJECTION.md. Noise variance, texture/color retention, camera calibration and subjective beauty remain distinct.

## Measured responsiveness

FD source `fd071ea8c79ddf73c85ce1b3ae2a8588857c76fe`, [native benchmark CI39127974196](https://github.com/benedek-art/lumen/actions/runs/39127974196), compared with8376 using unchanged generated fixtures:1000-selection release→completeXMP54.611/49.819s→9.574/8.244s for5k/20k catalogs; synchronous flush48.044/43.990s→2.506/2.342s. Catalog barrier and drag p95 did **not** materially improve. Single cells/shared hosted storage/generated16×12PNGs; no owner-drive/GUI/RAW or peak-memory guarantee.64/8MiB is staged output Data, not totalRSS. No redundant benchmark was run after unrelated source changes.

## Reproduce and tomorrow's gates

On macOS at the qualified source:

```sh
swift test -c release
swift test -c release --filter 'NeutralAbsoluteWhiteBalanceIdentityTests|NeutralAbsoluteWhiteBalanceGPUIdentityTests'
LUMEN_LOCAL_AMOUNT_EPSILON=1 swift test -c release --filter LocalAmountEpsilonDiagnosticTests/testCurrentPositiveAmountDomainAndCPUAgreement
```

The last command currently exits RED by design of the strict qualification assertion; no expected-failure annotation masks it. Controlled mutations/recovery commands and artifact hashes are recorded with their exact CI links in CLOUD-PROGRESS.md.

Use TOMORROW-ACCEPTANCE.md in order: initial private native Off/AI0/cache/Off-return identity; real pointer/focus/final-release/retarget/undo; same-URL source replacement; XMP/blob/failure/interruption/restart and physical-drive recovery; matching preview/export colour/geometry/detail/masks; A7IV/GX85 ISO-specific denoise/color/texture and actual response/memory. Keep private assets/results local. Interrupted private sweeps are partial progress, not passes. No exhaustive accuracy or aesthetic certification is claimed.
